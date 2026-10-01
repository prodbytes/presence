package com.nu01.presence

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Bundle
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
