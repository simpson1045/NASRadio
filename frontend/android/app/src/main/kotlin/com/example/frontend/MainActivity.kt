package com.example.frontend

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.SearchManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val LIFECYCLE_CHANNEL = "com.nasradio/lifecycle"
    private val KEEPALIVE_CHANNEL = "com.nasradio/castkeepalive"
    private val ALARM_CHANNEL = "com.nasradio/alarm"
    private val VOICE_CHANNEL = "com.nasradio/voice"
    private var voiceChannel: MethodChannel? = null
    private var pendingVoice: Map<String, Any?>? = null

    // Held while casting so locking the phone doesn't drop the LAN connection
    // to the TV. The foreground service keeps the CPU alive, but it does NOT
    // stop Wi-Fi from entering power-save when the screen turns off — which
    // dropped the cast within seconds of locking. A FULL_HIGH_PERF Wi-Fi lock
    // keeps the radio active across screen-off (LOW_LATENCY only works while
    // foreground, so it's the wrong mode here). The partial wake lock is
    // belt-and-suspenders for the CPU.
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Voice requests that arrive before Dart is listening wait here.
        voiceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    result.success(pendingVoice)
                    pendingVoice = null
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIFECYCLE_CHANNEL)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEPALIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireLocks()
                        result.success(true)
                    }
                    "release" -> {
                        releaseLocks()
                        result.success(true)
                    }
                    "ensureBatteryExemption" -> {
                        result.success(ensureBatteryExemption())
                    }
                    else -> result.notImplemented()
                }
            }

        // Wake-up alarms (AlarmScheduler / AlarmRingService own the logic).
        val alarmChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALARM_CHANNEL)
        AlarmBridge.channel = alarmChannel
        AlarmBridge.onRingingChanged = { on -> showOverLockScreen(on) }
        alarmChannel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getAlarms" -> result.success(AlarmScheduler.loadAlarms(this).toString())
                    "saveAlarms" -> {
                        AlarmScheduler.saveAlarms(this, call.arguments as String)
                        result.success(AlarmScheduler.nextAlarmAt(this))
                    }
                    "nextAlarmAt" -> result.success(AlarmScheduler.nextAlarmAt(this))
                    "testIn" -> {
                        // Ring a real alarm (its music, volume, fade) in N seconds.
                        val args = call.arguments as Map<*, *>
                        val id = (args["id"] as Number).toInt()
                        val seconds = (args["seconds"] as Number).toLong()
                        val label = AlarmScheduler.findAlarm(this, id)?.optString("label", "Alarm")
                            ?: "Test alarm"
                        AlarmScheduler.addSnooze(this, id, label, System.currentTimeMillis() + seconds * 1000)
                        result.success(AlarmScheduler.nextAlarmAt(this))
                    }
                    "getRinging" -> result.success(AlarmRingService.ringing)
                    "stop" -> {
                        AlarmRingService.command(this, AlarmRingService.ACTION_STOP)
                        result.success(true)
                    }
                    "snooze" -> {
                        AlarmRingService.command(this, AlarmRingService.ACTION_SNOOZE)
                        result.success(true)
                    }
                    "keepPlaying" -> result.success(AlarmRingService.handOff())
                    "preview" -> {
                        AlarmPreview.play(this, (call.arguments as Number).toInt())
                        result.success(true)
                    }
                    "stopPreview" -> {
                        AlarmPreview.stop(this)
                        result.success(true)
                    }
                    "permissions" -> result.success(alarmPermissions())
                    "openFullScreenSettings" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                                    .setData(Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(true)
                    }
                    "openExactAlarmSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            startActivity(
                                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                    .setData(Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("alarm", e.toString(), null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.action == AlarmRingService.ACTION_RING_UI) showOverLockScreen(true)
        takeVoice(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == AlarmRingService.ACTION_RING_UI) showOverLockScreen(true)
        takeVoice(intent)
    }

    // "Hey Google, play ___ on NASRadio" (phone / Google TV). Sent straight to
    // Dart when it's listening; otherwise (cold start) parked until Dart asks
    // with "takePending".
    private fun takeVoice(maybeIntent: Intent?) {
        val intent = maybeIntent ?: return
        if (intent.action != MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH) return
        val extras = HashMap<String, Any?>()
        intent.extras?.let { b ->
            for (k in b.keySet()) {
                @Suppress("DEPRECATION")
                when (val v = b.get(k)) {
                    is String, is Int, is Long, is Boolean -> extras[k] = v
                }
            }
        }
        val voice = hashMapOf<String, Any?>(
            "query" to (intent.getStringExtra(SearchManager.QUERY) ?: ""),
            "extras" to extras
        )
        intent.action = null // don't replay it on a config change
        val ch = voiceChannel
        if (ch == null) {
            pendingVoice = voice
            return
        }
        ch.invokeMethod("playFromSearch", voice, object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(code: String, message: String?, details: Any?) { pendingVoice = voice }
            override fun notImplemented() { pendingVoice = voice }
        })
    }

    override fun onResume() {
        super.onResume()
        // The alarm may have ended (notification Stop, auto-silence) while we
        // were away: never keep showing over the lock screen after that.
        if (AlarmRingService.ringing == null) showOverLockScreen(false)
    }

    /** While an alarm rings: light the screen and show over the lock screen. */
    private fun showOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    /** What the alarm needs and whether Android currently allows it. */
    private fun alarmPermissions(): Map<String, Boolean> {
        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return mapOf(
            "exact" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()),
            "fullScreen" to (Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent()),
            "notifications" to nm.areNotificationsEnabled(),
        )
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "NASRadio:castWifi"
                )
                wifiLock?.setReferenceCounted(false)
            }
            if (wifiLock?.isHeld == false) wifiLock?.acquire()

            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "NASRadio:castCpu"
                )
                wakeLock?.setReferenceCounted(false)
            }
            if (wakeLock?.isHeld == false) wakeLock?.acquire()
            android.util.Log.i("NASRadio", "cast keep-alive locks acquired")
        } catch (e: Exception) {
            android.util.Log.w("NASRadio", "acquireLocks failed: $e")
        }
    }

    // Doze is the cast-killer: while casting, the phone outputs no audio,
    // so after ~30-45 min stationary + screen-off Android suspends the
    // app's networking — wake locks and Wi-Fi locks are explicitly ignored
    // by Doze. (Aug 12 forensics: phone had ZERO network for ~10 min —
    // no LAN, no cellular — and recovered the instant the screen woke.)
    // Battery-optimization exemption is the sanctioned escape hatch.
    // Returns true if already exempt; otherwise fires the one-time system
    // prompt and returns false (exempt on the NEXT cast if user allows).
    private fun ensureBatteryExemption(): Boolean {
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                android.util.Log.i("NASRadio", "battery optimization: already exempt")
                true
            } else {
                android.util.Log.i("NASRadio", "battery optimization: not exempt — prompting")
                val intent = android.content.Intent(
                    android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    android.net.Uri.parse("package:$packageName")
                )
                startActivity(intent)
                false
            }
        } catch (e: Exception) {
            android.util.Log.w("NASRadio", "ensureBatteryExemption failed: $e")
            false
        }
    }

    private fun releaseLocks() {
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
            if (wakeLock?.isHeld == true) wakeLock?.release()
            android.util.Log.i("NASRadio", "cast keep-alive locks released")
        } catch (e: Exception) {
            android.util.Log.w("NASRadio", "releaseLocks failed: $e")
        }
    }

    override fun onDestroy() {
        // App swiped away — never leave the locks held.
        releaseLocks()
        // The ring service keeps working without us; Dart re-asks on start.
        AlarmBridge.channel = null
        AlarmBridge.onRingingChanged = null
        val audioServiceIntent = android.content.Intent(this, com.ryanheise.audioservice.AudioService::class.java)
        stopService(audioServiceIntent)
        super.onDestroy()
    }
}
