package com.nu01.presence

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the app capturing while nobody touches the phone: a foreground
 * service (with its ongoing notification) so Android lets the app keep the
 * camera and microphone with the screen off or the app in the background,
 * plus a partial wake lock (the CPU keeps running) and a Wi-Fi lock (events
 * keep syncing). The screen itself may turn off.
 *
 * Started while the app is shown, once a camera is open (Android only lets
 * a camera service start from the foreground); stopped when the app closes.
 */
class CaptureService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // No intent: Android restarted it after the process was killed.
        FileLog.init(this, if (intent == null) "capture service restarted by Android" else "capture service")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification(), types())
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
        } catch (e: Exception) {
            // Not allowed now (e.g. started from the background): capture
            // goes on while the app is shown, as before.
            FileLog.w("could not keep capturing in the background", e)
            stopSelf()
            return START_NOT_STICKY
        }
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "presence:capture")
                .apply { setReferenceCounted(false); acquire() }
        }
        if (wifiLock == null) {
            @Suppress("DEPRECATION")
            wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "presence:sync")
                .apply { setReferenceCounted(false); acquire() }
        }
        // Restarted by Android after the process was killed (no intent): the
        // camera lives in the app's screen, so open it.
        if (intent == null) KeepAlive.open(this, "capture service restarted by Android")
        FileLog.i("capturing in the foreground service")
        return START_STICKY
    }

    override fun onDestroy() {
        FileLog.i("capture service stopped")
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
        super.onDestroy()
    }

    /** Camera, and the microphone when it may be used. */
    private fun types(): Int {
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        return types
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Capturing", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while Presence keeps the camera recording"
                    setShowBadge(false)
                },
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        return builder
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("Presence is capturing")
            .setContentText("The camera keeps recording with the screen off")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "capture"
        private const val NOTIFICATION_ID = 1

        /**
         * Starts it while the app is shown. A plain start, not
         * `startForegroundService`: that one kills the app when the service
         * doesn't go foreground within 10 s, which a busy main thread at
         * launch (a debug build) can miss. Started from the foreground, it
         * goes foreground as soon as it runs.
         */
        fun start(context: Context) {
            try {
                context.startService(Intent(context, CaptureService::class.java))
            } catch (e: Exception) {
                FileLog.w("could not start the capture service", e)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CaptureService::class.java))
        }
    }
}
