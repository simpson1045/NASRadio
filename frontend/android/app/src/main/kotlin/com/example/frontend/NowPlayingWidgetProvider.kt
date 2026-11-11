package com.example.frontend

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import androidx.palette.graphics.Palette
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Home-screen Now Playing widget. The app (widget_service.dart) writes the
 * song, progress, shuffle/repeat state and the song's waveform into
 * HomeWidgetPreferences about once a second; this draws it:
 * the album art blurred across the whole widget, the waveform as the progress
 * bar in a colour taken from the art, and Shuffle/Repeat that work and show
 * their state (Nov 9: they were drawn but never wired).
 * Everything derived from the art is made once per song, not every second.
 */
class NowPlayingWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_PLAY_PAUSE = "com.example.frontend.WIDGET_PLAY_PAUSE"
        const val ACTION_SKIP_NEXT = "com.example.frontend.WIDGET_SKIP_NEXT"
        const val ACTION_SKIP_PREV = "com.example.frontend.WIDGET_SKIP_PREV"
        const val ACTION_SHUFFLE = "com.example.frontend.WIDGET_SHUFFLE"
        const val ACTION_REPEAT = "com.example.frontend.WIDGET_REPEAT"
        const val PREFS_NAME = "HomeWidgetPreferences"
        private const val WIDGET_CHANNEL = "com.nasradio/widget"
        private const val DEFAULT_ACCENT = 0xFF00D4FF.toInt()

        // widget_artwork.jpg is rewritten for every song, so key on its mtime.
        private var cachedPath: String? = null
        private var cachedMtime = 0L
        private var cachedArt: Bitmap? = null
        private var cachedBg: Bitmap? = null
        private var cachedAccent = DEFAULT_ACCENT
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val isPodcast = prefs.getBoolean("is_podcast", false)

        when (intent.action) {
            ACTION_PLAY_PAUSE -> {
                // Immediately toggle the icon so the widget feels responsive
                val wasPlaying = prefs.getBoolean("is_playing", false)
                prefs.edit().putBoolean("is_playing", !wasPlaying).apply()
                refreshAllWidgets(context)
                sendMediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            }
            ACTION_SKIP_NEXT -> sendMediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT)
            ACTION_SKIP_PREV -> sendMediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            ACTION_SHUFFLE -> {
                if (isPodcast) {
                    tellApp("seekBy", -10000) // podcasts: -10 s
                } else {
                    val on = prefs.getBoolean("shuffle_on", false)
                    prefs.edit().putBoolean("shuffle_on", !on).apply()
                    refreshAllWidgets(context)
                    tellApp("shuffle", null)
                }
            }
            ACTION_REPEAT -> {
                if (isPodcast) tellApp("seekBy", 30000) else tellApp("repeat", null)
            }
        }
    }

    /** Hand a widget button to the running app (main.dart, com.nasradio/widget).
     *  No running app = nothing to shuffle; the tap is ignored. */
    private fun tellApp(method: String, arg: Any?) {
        val engine = FlutterEngineCache.getInstance()
            .get(AudioServicePlugin.getFlutterEngineId()) ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
            .invokeMethod(method, arg)
    }

    private fun sendMediaButton(context: Context, keyCode: Int) {
        val downIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            component = ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver")
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        }
        context.sendBroadcast(downIntent)

        val upIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            component = ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver")
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_UP, keyCode))
        }
        context.sendBroadcast(upIntent)
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val views = RemoteViews(context.packageName, R.layout.widget_now_playing)

        val songTitle = prefs.getString("song_title", "Not Playing") ?: "Not Playing"
        val artistName = prefs.getString("artist_name", "") ?: ""
        val albumName = prefs.getString("album_name", "") ?: ""
        val format = prefs.getString("format", "") ?: ""
        val isPlaying = prefs.getBoolean("is_playing", false)
        val isPodcast = prefs.getBoolean("is_podcast", false)
        val progress = prefs.getInt("progress", 0)
        val artworkPath = prefs.getString("artwork_path", null)
        val currentTime = prefs.getString("current_time", "0:00") ?: "0:00"
        val totalTime = prefs.getString("total_time", "0:00") ?: "0:00"
        val shuffleOn = prefs.getBoolean("shuffle_on", false)
        val repeatMode = prefs.getInt("repeat_mode", 0) // 0 off, 1 all, 2 one
        val waveform = prefs.getString("waveform", "") ?: ""

        views.setTextViewText(R.id.widget_song_title, songTitle)
        views.setTextViewText(R.id.widget_artist_name, artistName)
        views.setTextViewText(R.id.widget_album_name, albumName)
        views.setTextViewText(R.id.widget_time_current, currentTime)
        views.setTextViewText(R.id.widget_time_total, totalTime)

        // Art, its blurred background and accent colour (cached per song).
        val art = loadArt(artworkPath)
        val accent = if (art != null) cachedAccent else DEFAULT_ACCENT
        if (art != null) {
            views.setImageViewBitmap(R.id.widget_album_art, art)
            views.setImageViewBitmap(R.id.widget_bg_art, cachedBg)
        } else {
            views.setImageViewResource(R.id.widget_album_art, R.drawable.widget_album_placeholder)
            views.setImageViewResource(R.id.widget_bg_art, R.drawable.widget_bg_rounded)
        }

        // Format badge — hide for podcasts
        if (format.isNotEmpty() && !isPodcast) {
            views.setTextViewText(R.id.widget_format_badge, format)
            views.setTextColor(R.id.widget_format_badge, accent)
            views.setViewVisibility(R.id.widget_format_badge, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_format_badge, View.GONE)
        }

        views.setImageViewResource(
            R.id.widget_play_pause,
            if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
        )
        views.setImageViewResource(R.id.widget_skip_prev, R.drawable.ic_skip_previous)
        views.setImageViewResource(R.id.widget_skip_next, R.drawable.ic_skip_next)

        // Shuffle / Repeat: lit in the accent colour when on. Podcasts get
        // -10 s / +30 s in their place.
        if (isPodcast) {
            views.setImageViewResource(R.id.widget_shuffle, R.drawable.ic_replay_10)
            views.setImageViewResource(R.id.widget_repeat, R.drawable.ic_forward_30)
            views.setInt(R.id.widget_shuffle, "setColorFilter", 0)
            views.setInt(R.id.widget_repeat, "setColorFilter", 0)
        } else {
            views.setImageViewResource(R.id.widget_shuffle, R.drawable.ic_shuffle)
            views.setImageViewResource(R.id.widget_repeat, R.drawable.ic_repeat)
            views.setInt(R.id.widget_shuffle, "setColorFilter", if (shuffleOn) accent else 0)
            views.setInt(R.id.widget_repeat, "setColorFilter", if (repeatMode != 0) accent else 0)
        }

        // The waveform as the progress bar, else the plain bar.
        val samples = parseWaveform(waveform)
        if (samples != null) {
            views.setImageViewBitmap(R.id.widget_waveform, drawWaveform(samples, progress / 1000f, accent))
            views.setViewVisibility(R.id.widget_waveform, View.VISIBLE)
            views.setViewVisibility(R.id.widget_progress, View.GONE)
        } else {
            views.setProgressBar(R.id.widget_progress, 1000, progress, false)
            views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
            views.setViewVisibility(R.id.widget_waveform, View.GONE)
        }
        views.setTextColor(R.id.widget_time_current, accent)

        // Buttons
        views.setOnClickPendingIntent(R.id.widget_play_pause, getPendingIntent(context, ACTION_PLAY_PAUSE, 0))
        views.setOnClickPendingIntent(R.id.widget_skip_next, getPendingIntent(context, ACTION_SKIP_NEXT, 1))
        views.setOnClickPendingIntent(R.id.widget_skip_prev, getPendingIntent(context, ACTION_SKIP_PREV, 2))
        views.setOnClickPendingIntent(R.id.widget_shuffle, getPendingIntent(context, ACTION_SHUFFLE, 4))
        views.setOnClickPendingIntent(R.id.widget_repeat, getPendingIntent(context, ACTION_REPEAT, 5))

        // Tap widget background to open app
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launchIntent != null) {
            val launchPendingIntent = PendingIntent.getActivity(
                context, 3, launchIntent, PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_background, launchPendingIntent)
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    /** The album art scaled down, plus (cached alongside) its blurred
     *  background and accent colour. Only redone when the file changes. */
    private fun loadArt(path: String?): Bitmap? {
        if (path == null) return null
        val file = File(path)
        if (!file.exists()) return null
        val mtime = file.lastModified()
        if (path == cachedPath && mtime == cachedMtime && cachedArt != null) return cachedArt
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= 320) sample *= 2
            val decoded = BitmapFactory.decodeFile(
                path, BitmapFactory.Options().apply { inSampleSize = sample }
            ) ?: return null
            val art = if (decoded.width > 320) {
                Bitmap.createScaledBitmap(decoded, 320, decoded.height * 320 / decoded.width, true)
            } else decoded
            val palette = Palette.from(art).generate()
            cachedAccent = readable(
                palette.getVibrantColor(
                    palette.getLightVibrantColor(palette.getDominantColor(DEFAULT_ACCENT))
                )
            )
            cachedBg = blurredBackground(art)
            cachedArt = art
            cachedPath = path
            cachedMtime = mtime
            art
        } catch (e: Exception) {
            null
        }
    }

    /** Bright enough to read on the darkened background. */
    private fun readable(color: Int): Int {
        val hsv = FloatArray(3)
        Color.colorToHSV(color, hsv)
        if (hsv[1] < 0.25f) return DEFAULT_ACCENT // greys: use the app's cyan
        hsv[2] = maxOf(hsv[2], 0.9f)
        return Color.HSVToColor(hsv)
    }

    /** The art's middle band at the widget's shape, blurred for real (three
     *  box-blur passes on a small copy ≈ a Gaussian; the old shrink-and-grow
     *  left blotches, Nov 9), then darkened by how bright it is, so white
     *  text reads even on a white cover (Like a Prayer came out pale grey). */
    private fun blurredBackground(art: Bitmap): Bitmap {
        val w = 480
        val h = 160
        val bandH = minOf(art.height, art.width * h / w).coerceAtLeast(1)
        val top = ((art.height - bandH) / 2).coerceAtLeast(0)
        val band = Bitmap.createBitmap(art, 0, top, art.width, bandH)
        val small = Bitmap.createScaledBitmap(band, 120, 40, true)
            .copy(Bitmap.Config.ARGB_8888, true)
        repeat(3) { boxBlur(small, 4) }
        val lum = averageLuminance(small) // 0 (black) .. 1 (white)
        val out = Bitmap.createScaledBitmap(small, w, h, true).copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)
        canvas.drawColor(Color.argb((105 + 125 * lum).toInt().coerceIn(105, 225), 0, 0, 0))
        val shade = Paint().apply {
            shader = LinearGradient(
                0f, 0f, w.toFloat(), 0f,
                Color.argb(0, 0, 0, 0), Color.argb(70, 0, 0, 0), Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, w.toFloat(), h.toFloat(), shade)
        return out
    }

    /** One horizontal + one vertical box-blur pass of radius [r], in place. */
    private fun boxBlur(bmp: Bitmap, r: Int) {
        val w = bmp.width
        val h = bmp.height
        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)
        val tmp = IntArray(w * h)
        blurPass(px, tmp, w, h, r, horizontal = true)
        blurPass(tmp, px, w, h, r, horizontal = false)
        bmp.setPixels(px, 0, w, 0, 0, w, h)
    }

    private fun blurPass(src: IntArray, dst: IntArray, w: Int, h: Int, r: Int, horizontal: Boolean) {
        val lines = if (horizontal) h else w
        val len = if (horizontal) w else h
        for (line in 0 until lines) {
            for (i in 0 until len) {
                var rs = 0
                var gs = 0
                var bs = 0
                for (k in -r..r) {
                    val j = (i + k).coerceIn(0, len - 1)
                    val p = if (horizontal) src[line * w + j] else src[j * w + line]
                    rs += (p shr 16) and 0xFF
                    gs += (p shr 8) and 0xFF
                    bs += p and 0xFF
                }
                val n = 2 * r + 1
                val idx = if (horizontal) line * w + i else i * w + line
                dst[idx] = (0xFF shl 24) or ((rs / n) shl 16) or ((gs / n) shl 8) or (bs / n)
            }
        }
    }

    private fun averageLuminance(bmp: Bitmap): Float {
        val w = bmp.width
        val h = bmp.height
        val px = IntArray(w * h)
        bmp.getPixels(px, 0, w, 0, 0, w, h)
        var sum = 0.0
        for (p in px) {
            sum += 0.299 * ((p shr 16) and 0xFF) + 0.587 * ((p shr 8) and 0xFF) + 0.114 * (p and 0xFF)
        }
        return (sum / px.size / 255.0).toFloat()
    }

    /** "12,40,77,..." (0-100) from the app; null if missing or malformed. */
    private fun parseWaveform(s: String): FloatArray? {
        if (s.isEmpty()) return null
        val parts = s.split(',')
        if (parts.size < 8) return null
        return try {
            FloatArray(parts.size) { parts[it].trim().toInt() / 100f }
        } catch (e: NumberFormatException) {
            null
        }
    }

    /** Rounded bars; the played part in [accent], the rest dim white. */
    private fun drawWaveform(values: FloatArray, progress: Float, accent: Int): Bitmap {
        val w = 600
        val h = 52
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val n = values.size
        val slot = w.toFloat() / n
        val bar = slot * 0.62f
        val played = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = accent }
        val rest = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(95, 255, 255, 255) }
        for (i in 0 until n) {
            val v = values[i].coerceIn(0f, 1f)
            val bh = h * (0.14f + 0.86f * v)
            val x = i * slot + (slot - bar) / 2f
            val y = (h - bh) / 2f
            canvas.drawRoundRect(
                x, y, x + bar, y + bh, bar / 2f, bar / 2f,
                if ((i + 0.5f) / n <= progress) played else rest
            )
        }
        return bmp
    }

    private fun refreshAllWidgets(context: Context) {
        val appWidgetManager = AppWidgetManager.getInstance(context)
        val widgetIds = appWidgetManager.getAppWidgetIds(
            ComponentName(context, NowPlayingWidgetProvider::class.java)
        )
        for (id in widgetIds) {
            updateAppWidget(context, appWidgetManager, id)
        }
    }

    private fun getPendingIntent(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, NowPlayingWidgetProvider::class.java).apply {
            this.action = action
        }
        return PendingIntent.getBroadcast(
            context, requestCode, intent, PendingIntent.FLAG_IMMUTABLE
        )
    }
}
