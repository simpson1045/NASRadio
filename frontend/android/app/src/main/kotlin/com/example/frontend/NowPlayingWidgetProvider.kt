package com.example.frontend

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.view.KeyEvent
import android.widget.RemoteViews
import androidx.palette.graphics.Palette

class NowPlayingWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_PLAY_PAUSE = "com.example.frontend.WIDGET_PLAY_PAUSE"
        const val ACTION_SKIP_NEXT = "com.example.frontend.WIDGET_SKIP_NEXT"
        const val ACTION_SKIP_PREV = "com.example.frontend.WIDGET_SKIP_PREV"
        const val PREFS_NAME = "HomeWidgetPreferences"
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

        when (intent.action) {
            ACTION_PLAY_PAUSE -> {
                // Immediately toggle the icon so the widget feels responsive
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val wasPlaying = prefs.getBoolean("is_playing", false)
                prefs.edit().putBoolean("is_playing", !wasPlaying).apply()
                refreshAllWidgets(context)
                sendMediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            }
            ACTION_SKIP_NEXT -> sendMediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT)
            ACTION_SKIP_PREV -> sendMediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
        }
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

        // Read data from shared preferences
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

        // Set text
        views.setTextViewText(R.id.widget_song_title, songTitle)
        views.setTextViewText(R.id.widget_artist_name, artistName)
        views.setTextViewText(R.id.widget_album_name, albumName)
        views.setTextViewText(R.id.widget_time_current, currentTime)
        views.setTextViewText(R.id.widget_time_total, totalTime)

        // Format badge — hide for podcasts
        if (format.isNotEmpty() && !isPodcast) {
            views.setTextViewText(R.id.widget_format_badge, format)
            views.setViewVisibility(R.id.widget_format_badge, android.view.View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_format_badge, android.view.View.GONE)
        }

        // Set play/pause icon
        views.setImageViewResource(
            R.id.widget_play_pause,
            if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
        )

        // Swap shuffle/repeat icons for -10s/+30s when podcast
        // Only replace shuffle and repeat — leave prev/next as normal transport controls
        if (isPodcast) {
            views.setImageViewResource(R.id.widget_shuffle, R.drawable.ic_replay_10)
            views.setImageViewResource(R.id.widget_repeat, R.drawable.ic_forward_30)
        } else {
            views.setImageViewResource(R.id.widget_shuffle, R.drawable.ic_shuffle)
            views.setImageViewResource(R.id.widget_repeat, R.drawable.ic_repeat)
        }
        views.setImageViewResource(R.id.widget_skip_prev, R.drawable.ic_skip_previous)
        views.setImageViewResource(R.id.widget_skip_next, R.drawable.ic_skip_next)

        // Set progress bar
        views.setProgressBar(R.id.widget_progress, 1000, progress, false)

        // Load artwork and extract color
        var backgroundColor = Color.argb(200, 30, 30, 46) // default dark
        if (artworkPath != null) {
            try {
                val bitmap = BitmapFactory.decodeFile(artworkPath)
                if (bitmap != null) {
                    // Set artwork
                    views.setImageViewBitmap(R.id.widget_album_art, bitmap)

                    // Extract dominant color for background
                    val palette = Palette.from(bitmap).generate()
                    val dominantColor = palette.getDarkMutedColor(
                        palette.getMutedColor(Color.argb(255, 30, 30, 46))
                    )
                    backgroundColor = Color.argb(
                        200,
                        Color.red(dominantColor),
                        Color.green(dominantColor),
                        Color.blue(dominantColor)
                    )
                }
            } catch (e: Exception) {
                // Fall back to placeholder
                views.setImageViewResource(R.id.widget_album_art, R.drawable.widget_album_placeholder)
            }
        } else {
            views.setImageViewResource(R.id.widget_album_art, R.drawable.widget_album_placeholder)
        }

        // Set background color
        views.setInt(R.id.widget_background, "setBackgroundColor", backgroundColor)

        // Set up button click intents
        views.setOnClickPendingIntent(
            R.id.widget_play_pause,
            getPendingIntent(context, ACTION_PLAY_PAUSE, 0)
        )
        views.setOnClickPendingIntent(
            R.id.widget_skip_next,
            getPendingIntent(context, ACTION_SKIP_NEXT, 1)
        )
        views.setOnClickPendingIntent(
            R.id.widget_skip_prev,
            getPendingIntent(context, ACTION_SKIP_PREV, 2)
        )

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
