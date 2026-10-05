package com.nu01.presence

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var cameras: PresenceCamerasPlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A surveillance screen shouldn't go to sleep.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        askToSkipBatteryOptimization()
    }

    override fun onStart() {
        super.onStart()
        cameras?.setPreviewVisible(true)
        // Before the camera opens: covered (e.g. by Google's sign-in
        // chooser) or with the screen off, Android only lets an app with a
        // camera service use the camera, and the service may only start now,
        // while the app is shown.
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            CaptureService.start(this)
        }
    }

    override fun onStop() {
        // The screen went off or the app was left: keep recording, without
        // the preview nobody sees.
        cameras?.setPreviewVisible(false)
        super.onStop()
    }

    /**
     * Asks once (per install) to leave the app out of battery optimization,
     * so Doze doesn't cut its network or wake lock while the phone lies
     * untouched on battery. Plugged in, Doze doesn't apply anyway.
     */
    private fun askToSkipBatteryOptimization() {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (power.isIgnoringBatteryOptimizations(packageName)) return
        val prefs = getSharedPreferences("presence", Context.MODE_PRIVATE)
        if (prefs.getBoolean(ASKED_BATTERY, false)) return
        prefs.edit().putBoolean(ASKED_BATTERY, true).apply()
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName")),
            )
        } catch (e: Exception) {
            Log.w("Presence", "Presence: could not ask to skip battery optimization: $e")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val plugin = PresenceCamerasPlugin(this, flutterEngine.renderer)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PresenceCamerasPlugin.CHANNEL)
            .setMethodCallHandler(plugin)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PresenceCamerasPlugin.MOTION_CHANNEL)
            .setStreamHandler(plugin)
        cameras = plugin
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "batteryTemperature" -> result.success(batteryTemperature())
                    else -> result.notImplemented()
                }
            }
    }

    /// The battery's temperature in °C, from the sticky battery broadcast
    /// (no permission needed), or null when the device doesn't report it.
    private fun batteryTemperature(): Double? {
        val battery: Intent? =
            registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val tenths = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            ?: Int.MIN_VALUE
        return if (tenths == Int.MIN_VALUE) null else tenths / 10.0
    }

    companion object {
        /// Device readings beyond the cameras (the battery's temperature).
        const val DEVICE_CHANNEL = "presence/device"

        private const val ASKED_BATTERY = "askedBatteryOptimization"
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        cameras?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        cameras?.dispose()
        cameras = null
        super.onDestroy()
    }
}
