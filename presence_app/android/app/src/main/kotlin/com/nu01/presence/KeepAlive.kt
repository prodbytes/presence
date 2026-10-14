package com.nu01.presence

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock

/**
 * Brings the app back when it isn't running, so an unattended phone keeps
 * capturing:
 * - a **watchdog** alarm every [INTERVAL_MS] ([WatchdogReceiver]) reopens
 *   the app if its screen is gone (killed, crashed, closed with Back);
 * - after a **crash**, the app reopens [CRASH_RESTART_MS] later;
 * - after the phone **boots**, or the app is **updated** ([BootReceiver]),
 *   the app opens.
 *
 * Only a force stop (Settings > Apps) keeps it closed: that cancels the
 * alarms, until the app is opened again. Android 10 and later refuse to
 * open an app from the background (silently): there it also posts a
 * high-priority notification, "Presence stopped — tap to resume", whose tap
 * opens it ([notifyStopped]); the app's screen removes it once it's up.
 */
object KeepAlive {
    const val INTERVAL_MS = 15 * 60_000L
    const val CRASH_RESTART_MS = 10_000L

    private fun watchdog(context: Context) = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, WatchdogReceiver::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** (Re)arms the watchdog to check in [delayMs], even in Doze. */
    fun schedule(context: Context, delayMs: Long = INTERVAL_MS) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarms.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + delayMs,
            watchdog(context),
        )
    }

    // A fresh task: a screen left on top of the app's old task (Google's
    // account chooser) would otherwise be shown instead, and the app
    // wouldn't start at all.
    private fun openIntent(context: Context) =
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)

    /**
     * Opens the app's screen unless it's open already. Android 10 and later
     * don't let an app in the background start its screen (without an
     * error), so there it also says so in a notification to tap.
     */
    fun open(context: Context, why: String) {
        if (MainActivity.alive) return
        FileLog.i("opening the app: $why")
        try {
            context.startActivity(openIntent(context))
        } catch (e: Exception) {
            FileLog.e("could not open the app ($why)", e)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) notifyStopped(context, why)
    }

    /**
     * "Presence stopped — tap to resume": a high-priority notification whose
     * tap opens the app (a notification's tap may start a screen from the
     * background). It alerts once; the watchdog only updates it.
     */
    private fun notifyStopped(context: Context, why: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            FileLog.w("can't notify that the app stopped ($why): notifications aren't allowed")
            return
        }
        try {
            val manager = context.getSystemService(NotificationManager::class.java)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        STOPPED_CHANNEL_ID,
                        context.getString(R.string.resume_channel),
                        NotificationManager.IMPORTANCE_HIGH,
                    ).apply {
                        description = context.getString(R.string.resume_channel_description)
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    },
                )
                Notification.Builder(context, STOPPED_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
                    .setPriority(Notification.PRIORITY_HIGH)
                    .setDefaults(Notification.DEFAULT_ALL)
            }
            val tap = PendingIntent.getActivity(
                context,
                STOPPED_NOTIFICATION_ID,
                openIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            manager.notify(
                STOPPED_NOTIFICATION_ID,
                builder
                    .setSmallIcon(android.R.drawable.presence_video_busy)
                    .setContentTitle(context.getString(R.string.resume_title))
                    .setContentText(context.getString(R.string.resume_text))
                    .setCategory(Notification.CATEGORY_REMINDER)
                    .setVisibility(Notification.VISIBILITY_PUBLIC)
                    .setContentIntent(tap)
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    .build(),
            )
            FileLog.i("notified that the app stopped ($why)")
        } catch (e: Exception) {
            FileLog.e("could not notify that the app stopped ($why)", e)
        }
    }

    /** The app's screen is up: the "stopped" notification is out of date. */
    fun clearStopped(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(STOPPED_NOTIFICATION_ID)
    }

    private const val STOPPED_CHANNEL_ID = "stopped"

    /** The capture service's is 1. */
    private const val STOPPED_NOTIFICATION_ID = 2

    /**
     * Logs an uncaught exception (on the spot: the process is about to
     * die), has the watchdog reopen the app shortly, then lets Android's
     * handler end the process as before.
     */
    fun installCrashHandler(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is CrashHandler) return
        Thread.setDefaultUncaughtExceptionHandler(CrashHandler(app, previous))
    }

    private class CrashHandler(
        private val context: Context,
        private val previous: Thread.UncaughtExceptionHandler?,
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, error: Throwable) {
            runCatching {
                FileLog.now("crash in thread ${thread.name}; reopening in ${CRASH_RESTART_MS / 1000} s", error)
                schedule(context, CRASH_RESTART_MS)
            }
            previous?.uncaughtException(thread, error)
        }
    }
}

/** The watchdog's alarm: re-arms itself and reopens the app if it's gone. */
class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        FileLog.init(context, "watchdog")
        KeepAlive.schedule(context)
        KeepAlive.open(context, "watchdog found it closed")
    }
}

/**
 * Opens the app once the phone has booted, and after the app is updated
 * (an install stops it, and nothing else would start it again). It only
 * asks for the app's screen (or, on Android 10+, notifies): it never starts
 * the camera and microphone service, which Android 15 forbids from
 * `BOOT_COMPLETED`; the screen starts it once it's shown.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val why = when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> "the phone booted"
            Intent.ACTION_MY_PACKAGE_REPLACED -> "the app was updated"
            else -> return
        }
        FileLog.init(context, why)
        KeepAlive.schedule(context)
        KeepAlive.open(context, why)
    }
}
