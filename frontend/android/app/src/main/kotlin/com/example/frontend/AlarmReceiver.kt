package com.example.frontend

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** A scheduled alarm (or snooze) went off: start ringing. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(AlarmScheduler.EXTRA_ALARM_ID, -1)
        val label = intent.getStringExtra(AlarmScheduler.EXTRA_LABEL) ?: "Alarm"
        val snooze = intent.getBooleanExtra(AlarmScheduler.EXTRA_SNOOZE, false)
        // Ring first: re-arming the next occurrence must never delay the alarm.
        AlarmRingService.start(context, id, label)
        AlarmScheduler.onFired(context, id, snooze)
    }
}

/**
 * Android drops every scheduled alarm on reboot, and on an app update
 * (every beta install), so re-arm them. Also on clock or time-zone changes.
 */
class AlarmBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AlarmScheduler.rescheduleAll(context)
    }
}
