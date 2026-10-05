package com.nu01.presence

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
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
 * alarms, until the app is opened again. Android 10 and later may refuse to
 * open an app from the background; the attempt is logged.
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

    /** Opens the app's screen unless it's open already. */
    fun open(context: Context, why: String) {
        if (MainActivity.alive) return
        FileLog.i("opening the app: $why")
        try {
            context.startActivity(
                // A fresh task: a screen left on top of the app's old task
                // (Google's account chooser) would otherwise be shown
                // instead, and the app wouldn't start at all.
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
            )
        } catch (e: Exception) {
            FileLog.e("could not open the app ($why)", e)
        }
    }

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
 * (an install stops it, and nothing else would start it again).
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
