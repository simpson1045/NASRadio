package com.example.frontend

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Bridge to Dart. MainActivity sets [channel] when the Flutter engine is up;
 * the ring service reports "ringing" (with the current track) / "stopped"
 * through it. When Flutter isn't running the events are simply dropped:
 * Dart asks getRinging on start.
 */
object AlarmBridge {
    @Volatile var channel: MethodChannel? = null
    @Volatile var onRingingChanged: ((Boolean) -> Unit)? = null

    fun send(method: String, args: Any?) {
        Handler(Looper.getMainLooper()).post {
            try { channel?.invokeMethod(method, args) } catch (e: Exception) { /* engine gone */ }
            onRingingChanged?.invoke(method == "ringing")
        }
    }
}

/**
 * The ringing alarm. A foreground service so it works with the app closed,
 * and it plays the alarm's music ITSELF (a native player on the ALARM
 * stream), so music starts even when Flutter isn't running.
 *
 * The alarm's stored JSON (written by Flutter) carries what to play:
 *   queue:  [{path | url, title, artist, album, albumId, station}]
 *   hosts:  [lan "/api" base, wan "/api" base], tried in order per song
 *   volume: 0-100, the alarm-stream level for this ring (phone's own
 *           alarm volume is restored afterwards)
 *   fadeSeconds: music and tone rise from near-silent to that level
 *
 * Safety net: unless music is actually playing within [FALLBACK_DELAY_MS]
 * (NAS down, Wi-Fi asleep, expired link), the phone's own alarm sound loops
 * instead, and vibration starts. An alarm must never fail silently.
 */
class AlarmRingService : Service() {
    companion object {
        private const val TAG = "NASRadioAlarm"
        const val ACTION_START = "com.example.frontend.ALARM_START"
        const val ACTION_STOP = "com.example.frontend.ALARM_STOP"
        const val ACTION_SNOOZE = "com.example.frontend.ALARM_SNOOZE"
        const val ACTION_RING_UI = "com.example.frontend.ALARM_RING_UI"
        private const val CHANNEL_ID = "nasradio_alarm"
        private const val NOTIF_ID = 4242
        const val FALLBACK_DELAY_MS = 15_000L
        const val AUTO_SILENCE_MS = 20 * 60_000L
        const val SNOOZE_MINUTES = 9
        private const val MAX_SONG_FAILURES = 5
        private const val MIN_GAIN = 0.04f

        /** {id, label, since, track?, tone?} while ringing, else null. */
        @Volatile var ringing: Map<String, Any?>? = null
        @Volatile private var instance: AlarmRingService? = null

        fun start(ctx: Context, id: Int, label: String) {
            val i = Intent(ctx, AlarmRingService::class.java)
                .setAction(ACTION_START)
                .putExtra(AlarmScheduler.EXTRA_ALARM_ID, id)
                .putExtra(AlarmScheduler.EXTRA_LABEL, label)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
            else ctx.startService(i)
        }

        /** Stop / snooze from the app. No-op when not ringing. */
        fun command(ctx: Context, action: String) {
            if (ringing == null) return
            ctx.startService(Intent(ctx, AlarmRingService::class.java).setAction(action))
        }

        /**
         * "I'm up, keep playing": end the alarm and report where the music
         * was, so Flutter's normal player continues from there. Main thread.
         */
        fun handOff(): Map<String, Any>? = instance?.handOffInternal()
    }

    private val handler = Handler(Looper.getMainLooper())
    private var alarmId = -1
    private var label = "Alarm"
    private var ringStart = 0L
    private var fadeMs = 60_000L
    private var gain = 1f

    private var queue = JSONArray()
    private var hosts = listOf<String>()
    private var queueIndex = 0
    private var hostIndex = 0
    private var songFailures = 0
    private var music: MediaPlayer? = null
    private var musicPlaying = false
    private var track: Map<String, Any?>? = null

    private var tone: MediaPlayer? = null
    private var toneGen: ToneGenerator? = null
    private var toneReason: String? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var savedAlarmVolume = -1

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startRinging(
                intent.getIntExtra(AlarmScheduler.EXTRA_ALARM_ID, -1),
                intent.getStringExtra(AlarmScheduler.EXTRA_LABEL) ?: "Alarm",
            )
            ACTION_STOP -> finish("stopped")
            ACTION_SNOOZE -> {
                if (ringing != null) {
                    AlarmScheduler.addSnooze(
                        this, alarmId, label,
                        System.currentTimeMillis() + SNOOZE_MINUTES * 60_000L,
                    )
                }
                finish("snoozed")
            }
            else -> if (ringing == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    // ---- start ----------------------------------------------------------

    private fun startRinging(id: Int, lbl: String) {
        // A second alarm while one is ringing replaces it.
        stopMusic()
        stopTone()
        handler.removeCallbacksAndMessages(null)
        instance = this
        alarmId = id
        label = lbl
        ringStart = System.currentTimeMillis()
        musicPlaying = false
        songFailures = 0
        track = null
        toneReason = null

        val alarm = AlarmScheduler.findAlarm(this, id)
        queue = alarm?.optJSONArray("queue") ?: JSONArray()
        hosts = alarm?.optJSONArray("hosts")?.let { h ->
            (0 until h.length()).map { h.optString(it) }.filter { it.isNotEmpty() }
        } ?: emptyList()
        fadeMs = (alarm?.optInt("fadeSeconds", 60) ?: 60) * 1000L
        setAlarmVolume(alarm?.optInt("volume", 50) ?: 50)
        Log.i(TAG, "ringing id=$id label=$lbl songs=${queue.length()} fade=${fadeMs / 1000}s")

        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIF_ID, notification)
        }
        acquireLocks()

        gain = if (fadeMs > 0) MIN_GAIN else 1f
        handler.post(fadeTick)
        if (queue.length() > 0) {
            queueIndex = 0
            hostIndex = 0
            playCurrent()
            handler.postDelayed({
                if (!musicPlaying) fallback("Music didn't start in time")
            }, FALLBACK_DELAY_MS)
        } else {
            fallback("No music picked for this alarm")
        }
        handler.postDelayed({ finish("timeout") }, AUTO_SILENCE_MS)
        publish()
    }

    /** Raise gain from near-silent to full over fadeMs (squared: even to the ear). */
    private val fadeTick = object : Runnable {
        override fun run() {
            val p = if (fadeMs <= 0) 1f
                else ((System.currentTimeMillis() - ringStart).toFloat() / fadeMs).coerceIn(0f, 1f)
            gain = MIN_GAIN + (1f - MIN_GAIN) * p * p
            try { music?.setVolume(gain, gain) } catch (e: Exception) { }
            try { tone?.setVolume(gain, gain) } catch (e: Exception) { }
            if (p < 1f) handler.postDelayed(this, 250)
        }
    }

    // ---- music ----------------------------------------------------------

    private fun entry(): JSONObject? = queue.optJSONObject(queueIndex)

    private fun urlFor(e: JSONObject): String? {
        e.optString("url").takeIf { it.isNotEmpty() }?.let { return it }  // station: absolute
        val path = e.optString("path").takeIf { it.isNotEmpty() } ?: return null
        val host = hosts.getOrNull(hostIndex) ?: return null
        return host + path
    }

    private fun playCurrent() {
        stopMusic()
        val e = entry() ?: return
        val url = urlFor(e)
        if (url == null) { songFailed("no link"); return }
        try {
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            mp.setVolume(gain, gain)
            mp.setOnPreparedListener {
                if (music !== it) return@setOnPreparedListener
                it.setVolume(gain, gain)
                it.start()
                onMusicStarted(e)
            }
            mp.setOnCompletionListener {
                if (music !== it) return@setOnCompletionListener
                queueIndex = (queueIndex + 1) % queue.length()
                hostIndex = 0
                playCurrent()
            }
            mp.setOnErrorListener { p, what, extra ->
                if (music === p) songFailed("error $what/$extra")
                true
            }
            mp.setDataSource(this, Uri.parse(url))
            mp.prepareAsync()
            music = mp
        } catch (ex: Exception) {
            songFailed(ex.toString())
        }
    }

    /** Try the other server address, then the next song; give up to the tone. */
    private fun songFailed(why: String) {
        Log.w(TAG, "song ${queueIndex} host $hostIndex failed: $why")
        stopMusic()
        val e = entry()
        val isStation = e?.optString("url")?.isNotEmpty() == true
        if (!isStation && hostIndex + 1 < hosts.size) {
            hostIndex++
            handler.post { playCurrent() }
            return
        }
        songFailures++
        if (songFailures >= minOf(MAX_SONG_FAILURES, queue.length())) {
            musicPlaying = false
            fallback("Couldn't reach NASRadio")
            return
        }
        queueIndex = (queueIndex + 1) % queue.length()
        hostIndex = 0
        handler.postDelayed({ playCurrent() }, 500)
    }

    private fun onMusicStarted(e: JSONObject) {
        musicPlaying = true
        songFailures = 0
        track = mapOf(
            "title" to e.optString("title"),
            "artist" to e.optString("artist"),
            "album" to e.optString("album"),
            "albumId" to e.optInt("albumId", 0),
            "art" to e.optString("art"),
            "station" to e.optBoolean("station", false),
            "index" to queueIndex,
        )
        Log.i(TAG, "music: ${e.optString("title")} (host $hostIndex)")
        if (tone != null || toneGen != null) {
            stopTone()
            stopVibration()
            toneReason = null
        }
        publish()
    }

    private fun stopMusic() {
        music?.let {
            try { it.stop() } catch (e: Exception) { }
            it.release()
        }
        music = null
    }

    // ---- fallback tone ----------------------------------------------------

    /** The phone's own alarm sound, looping on the ALARM stream, plus vibration. */
    private fun fallback(reason: String) {
        if (tone != null || toneGen != null) return
        Log.i(TAG, "fallback tone: $reason")
        toneReason = reason
        startVibration()
        val candidates = listOfNotNull(
            RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM),
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
        )
        for (uri in candidates) {
            try {
                val mp = MediaPlayer()
                mp.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                mp.setDataSource(this, uri)
                mp.isLooping = true
                mp.setVolume(gain, gain)
                mp.prepare()
                mp.start()
                tone = mp
                publish()
                return
            } catch (e: Exception) {
                Log.w(TAG, "tone $uri failed: $e")
            }
        }
        // Last resort: a generated beep every 2 s. Never silent.
        try {
            toneGen = ToneGenerator(AudioManager.STREAM_ALARM, ToneGenerator.MAX_VOLUME)
            val beep = object : Runnable {
                override fun run() {
                    toneGen?.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 1000)
                    if (toneGen != null) handler.postDelayed(this, 2000)
                }
            }
            handler.post(beep)
        } catch (e: Exception) {
            Log.e(TAG, "even ToneGenerator failed: $e")
        }
        publish()
    }

    private fun stopTone() {
        tone?.let {
            try { it.stop() } catch (e: Exception) { }
            it.release()
        }
        tone = null
        toneGen?.release()
        toneGen = null
    }

    // ---- volume, vibration, locks ------------------------------------------

    /** This alarm's level on the ALARM stream; the phone's own level comes back after. */
    private fun setAlarmVolume(pct: Int) {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (savedAlarmVolume < 0) savedAlarmVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
            val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            val level = Math.round(max * pct.coerceIn(0, 100) / 100f).coerceIn(1, max)
            am.setStreamVolume(AudioManager.STREAM_ALARM, level, 0)
        } catch (e: Exception) {
            Log.w(TAG, "could not set alarm volume: $e")
        }
    }

    private fun restoreAlarmVolume() {
        if (savedAlarmVolume < 0) return
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.setStreamVolume(AudioManager.STREAM_ALARM, savedAlarmVolume, 0)
        } catch (e: Exception) { }
        savedAlarmVolume = -1
    }

    private fun vibrator(): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

    private fun startVibration() {
        try {
            val pattern = longArrayOf(0, 600, 900)  // buzz, pause, repeat
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator().vibrate(
                    VibrationEffect.createWaveform(pattern, 0),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator().vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            Log.w(TAG, "vibration failed: $e")
        }
    }

    private fun stopVibration() {
        try { vibrator().cancel() } catch (e: Exception) { }
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NASRadio:alarm")
            wakeLock?.setReferenceCounted(false)
        }
        wakeLock?.acquire(AUTO_SILENCE_MS + 60_000L)
        // Wi-Fi is often in deep power-save at dawn: keep the radio fully up
        // so the first song buffers fast.
        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "NASRadio:alarmWifi")
                wifiLock?.setReferenceCounted(false)
            }
            wifiLock?.acquire()
        } catch (e: Exception) {
            Log.w(TAG, "wifi lock failed: $e")
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
    }

    // ---- reporting --------------------------------------------------------

    /** Push the current state to Dart and the notification. */
    private fun publish() {
        if (alarmId == -1 && ringing == null && track == null) return
        ringing = mapOf(
            "id" to alarmId,
            "label" to label,
            "since" to ringStart,
            "track" to track,
            "tone" to toneReason,
        )
        AlarmBridge.send("ringing", ringing)
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotification())
        } catch (e: Exception) { }
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "Alarms", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "Wake-up alarms"
            ch.setSound(null, null)       // the service plays the sound itself
            ch.enableVibration(false)     // and vibrates itself
            ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            nm.createNotificationChannel(ch)
        }

        val ringUi = PendingIntent.getActivity(
            this, NOTIF_ID,
            Intent(this, MainActivity::class.java)
                .setAction(ACTION_RING_UI)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(AlarmScheduler.EXTRA_ALARM_ID, alarmId)
                .putExtra(AlarmScheduler.EXTRA_LABEL, label),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        fun action(act: String, code: Int) = PendingIntent.getService(
            this, code, Intent(this, AlarmRingService::class.java).setAction(act),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val t = track
        val text = when {
            t != null -> "♪ ${t["title"]} · ${t["artist"]}"
            toneReason != null -> "Alarm tone: $toneReason"
            else -> "Starting your music…"
        }

        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        b.setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(label)
            .setContentText(text)
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(ringUi)
            .setFullScreenIntent(ringUi, true)
        @Suppress("DEPRECATION")
        b.addAction(0, "Snooze", action(ACTION_SNOOZE, NOTIF_ID + 1))
        @Suppress("DEPRECATION")
        b.addAction(0, "Stop", action(ACTION_STOP, NOTIF_ID + 2))
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            b.setPriority(Notification.PRIORITY_MAX)
        }
        return b.build()
    }

    // ---- end --------------------------------------------------------------

    private fun handOffInternal(): Map<String, Any>? {
        if (ringing == null) return null
        val state = mapOf<String, Any>(
            "alarmId" to alarmId,
            "index" to queueIndex,
            "positionMs" to (try { music?.currentPosition ?: 0 } catch (e: Exception) { 0 }),
            "playing" to musicPlaying,
        )
        finish("handoff")
        return state
    }

    private fun finish(reason: String) {
        Log.i(TAG, "alarm $reason")
        handler.removeCallbacksAndMessages(null)
        stopMusic()
        stopTone()
        stopVibration()
        restoreAlarmVolume()
        releaseLocks()
        val was = ringing
        ringing = null
        track = null
        alarmId = -1
        if (instance === this) instance = null
        if (was != null) AlarmBridge.send("stopped", reason)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        stopMusic()
        stopTone()
        restoreAlarmVolume()
        releaseLocks()
        if (instance === this) instance = null
        super.onDestroy()
    }
}

/**
 * "Preview" in the alarm editor: the phone's alarm sound for 3 s at the
 * chosen level, then the phone's own alarm volume comes back.
 */
object AlarmPreview {
    private var player: MediaPlayer? = null
    private var savedVolume = -1
    private val handler = Handler(Looper.getMainLooper())

    fun play(ctx: Context, pct: Int) {
        if (AlarmRingService.ringing != null) return
        stop(ctx)
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
            val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(
                AudioManager.STREAM_ALARM,
                Math.round(max * pct.coerceIn(0, 100) / 100f).coerceIn(1, max), 0,
            )
            val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            mp.setDataSource(ctx, uri)
            mp.prepare()
            mp.start()
            player = mp
            handler.postDelayed({ stop(ctx) }, 3000)
        } catch (e: Exception) {
            Log.w("NASRadioAlarm", "preview failed: $e")
            stop(ctx)
        }
    }

    fun stop(ctx: Context) {
        handler.removeCallbacksAndMessages(null)
        player?.let {
            try { it.stop() } catch (e: Exception) { }
            it.release()
        }
        player = null
        if (savedVolume >= 0) {
            try {
                val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0)
            } catch (e: Exception) { }
            savedVolume = -1
        }
    }
}
