package com.example.frontend

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * Wake-up alarms. The Kotlin side owns storage and ALL time math, so alarms
 * keep firing after a reboot or an app update even if Flutter never starts.
 *
 * Scheduling uses setAlarmClock(): the Clock-app mechanism. It is exempt
 * from Doze, fires on the dot and shows the status-bar alarm icon.
 *
 * Storage is device-protected, so a phone that restarts overnight (Samsung
 * auto-restart, an OS update) re-arms its alarms before anyone unlocks it.
 *
 * Alarm JSON: {id, hour, minute, days, enabled, label, ...}. days is a
 * bitmask, Mon=1 ... Sun=64, and 0 means one-time. Any other keys (what to
 * play, volume) belong to Flutter and are stored untouched.
 */
object AlarmScheduler {
    private const val TAG = "NASRadioAlarm"
    private const val PREFS = "nasradio_alarms"
    private const val KEY_ALARMS = "alarms"
    private const val KEY_SNOOZES = "snoozes"      // [{id, at, label}]
    private const val KEY_SCHEDULED = "scheduled"  // request codes we registered

    const val EXTRA_ALARM_ID = "nasradio_alarm_id"
    const val EXTRA_LABEL = "nasradio_alarm_label"
    const val EXTRA_SNOOZE = "nasradio_alarm_snooze"
    const val TEST_ALARM_ID = 999_999
    private const val SNOOZE_CODE_OFFSET = 100_000

    private fun prefs(ctx: Context): SharedPreferences {
        val c = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
            ctx.createDeviceProtectedStorageContext() else ctx
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    fun loadAlarms(ctx: Context): JSONArray =
        try { JSONArray(prefs(ctx).getString(KEY_ALARMS, "[]")) } catch (e: Exception) { JSONArray() }

    /** Replace the whole alarm list (Flutter's editor saves it as one unit). */
    fun saveAlarms(ctx: Context, json: String) {
        JSONArray(json)  // throws on bad input before anything is stored
        prefs(ctx).edit().putString(KEY_ALARMS, json).apply()
        rescheduleAll(ctx)
    }

    /** The stored alarm with this id (its queue, volume, fade), or null. */
    fun findAlarm(ctx: Context, id: Int): JSONObject? {
        val alarms = loadAlarms(ctx)
        for (i in 0 until alarms.length()) {
            val a = alarms.getJSONObject(i)
            if (a.optInt("id") == id) return a
        }
        return null
    }

    private fun loadSnoozes(ctx: Context): JSONArray =
        try { JSONArray(prefs(ctx).getString(KEY_SNOOZES, "[]")) } catch (e: Exception) { JSONArray() }

    /** One-off ring at [at]: snoozes, and the "test alarm" button. */
    fun addSnooze(ctx: Context, id: Int, label: String, at: Long) {
        val keep = JSONArray()
        val old = loadSnoozes(ctx)
        for (i in 0 until old.length()) {
            val s = old.getJSONObject(i)
            if (s.optInt("id") != id) keep.put(s)
        }
        keep.put(JSONObject().put("id", id).put("at", at).put("label", label))
        prefs(ctx).edit().putString(KEY_SNOOZES, keep.toString()).apply()
        rescheduleAll(ctx)
    }

    /** Next time this alarm should ring after [now], or null if never. */
    fun nextTrigger(alarm: JSONObject, now: Calendar): Long? {
        val days = alarm.optInt("days", 0)
        val c = now.clone() as Calendar
        c.set(Calendar.HOUR_OF_DAY, alarm.optInt("hour"))
        c.set(Calendar.MINUTE, alarm.optInt("minute"))
        c.set(Calendar.SECOND, 0)
        c.set(Calendar.MILLISECOND, 0)
        for (i in 0..7) {
            if (i > 0) c.add(Calendar.DAY_OF_MONTH, 1)
            if (c.timeInMillis <= now.timeInMillis) continue
            if (days == 0) return c.timeInMillis
            // Calendar: SUNDAY=1 ... SATURDAY=7  ->  bit Mon=0 ... Sun=6
            val bit = (c.get(Calendar.DAY_OF_WEEK) + 5) % 7
            if (days and (1 shl bit) != 0) return c.timeInMillis
        }
        return null
    }

    /** Called when an alarm fires: one-time alarms switch off, snoozes are used up. */
    fun onFired(ctx: Context, id: Int, snooze: Boolean) {
        if (snooze) {
            val keep = JSONArray()
            val old = loadSnoozes(ctx)
            for (i in 0 until old.length()) {
                val s = old.getJSONObject(i)
                if (s.optInt("id") != id) keep.put(s)
            }
            prefs(ctx).edit().putString(KEY_SNOOZES, keep.toString()).apply()
        } else {
            val alarms = loadAlarms(ctx)
            for (i in 0 until alarms.length()) {
                val a = alarms.getJSONObject(i)
                if (a.optInt("id") == id && a.optInt("days", 0) == 0) a.put("enabled", false)
            }
            prefs(ctx).edit().putString(KEY_ALARMS, alarms.toString()).apply()
        }
        rescheduleAll(ctx)
    }

    /** Soonest upcoming ring (alarm or snooze), epoch ms, or null. */
    fun nextAlarmAt(ctx: Context): Long? {
        val now = Calendar.getInstance()
        var best: Long? = null
        val alarms = loadAlarms(ctx)
        for (i in 0 until alarms.length()) {
            val a = alarms.getJSONObject(i)
            if (!a.optBoolean("enabled", true)) continue
            val t = nextTrigger(a, now) ?: continue
            if (best == null || t < best) best = t
        }
        val snoozes = loadSnoozes(ctx)
        for (i in 0 until snoozes.length()) {
            val t = snoozes.getJSONObject(i).optLong("at")
            if (t > now.timeInMillis && (best == null || t < best)) best = t
        }
        return best
    }

    /** Cancel everything we registered, then register what's current. */
    fun rescheduleAll(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val p = prefs(ctx)
        for (code in p.getStringSet(KEY_SCHEDULED, emptySet()) ?: emptySet()) {
            code.toIntOrNull()?.let { cancel(ctx, am, it) }
        }

        val scheduled = mutableSetOf<String>()
        val now = Calendar.getInstance()
        val alarms = loadAlarms(ctx)
        for (i in 0 until alarms.length()) {
            val a = alarms.getJSONObject(i)
            if (!a.optBoolean("enabled", true)) continue
            val id = a.optInt("id")
            val at = nextTrigger(a, now) ?: continue
            if (schedule(ctx, am, id, id, a.optString("label", "Alarm"), at, false)) {
                scheduled.add(id.toString())
            }
        }

        val liveSnoozes = JSONArray()
        val snoozes = loadSnoozes(ctx)
        for (i in 0 until snoozes.length()) {
            val s = snoozes.getJSONObject(i)
            val at = s.optLong("at")
            if (at <= now.timeInMillis) continue  // stale: drop it
            liveSnoozes.put(s)
            val id = s.optInt("id")
            val code = id + SNOOZE_CODE_OFFSET
            if (schedule(ctx, am, code, id, s.optString("label", "Alarm"), at, true)) {
                scheduled.add(code.toString())
            }
        }

        p.edit()
            .putString(KEY_SNOOZES, liveSnoozes.toString())
            .putStringSet(KEY_SCHEDULED, scheduled)
            .apply()
        Log.i(TAG, "rescheduled ${scheduled.size} alarm(s), next=${nextAlarmAt(ctx)}")
    }

    private fun fireIntent(ctx: Context) = Intent(ctx, AlarmReceiver::class.java)

    private fun schedule(
        ctx: Context, am: AlarmManager, code: Int, id: Int,
        label: String, at: Long, snooze: Boolean,
    ): Boolean {
        val fire = PendingIntent.getBroadcast(
            ctx, code,
            fireIntent(ctx)
                .putExtra(EXTRA_ALARM_ID, id)
                .putExtra(EXTRA_LABEL, label)
                .putExtra(EXTRA_SNOOZE, snooze),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // What tapping the status-bar alarm icon opens.
        val show = PendingIntent.getActivity(
            ctx, code, Intent(ctx, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return try {
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, show), fire)
            true
        } catch (e: SecurityException) {
            // Exact alarms denied (Android 12 only; 13+ grants USE_EXACT_ALARM).
            Log.e(TAG, "setAlarmClock refused for $id: $e")
            false
        }
    }

    private fun cancel(ctx: Context, am: AlarmManager, code: Int) {
        PendingIntent.getBroadcast(
            ctx, code, fireIntent(ctx),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )?.let {
            am.cancel(it)
            it.cancel()
        }
    }
}
