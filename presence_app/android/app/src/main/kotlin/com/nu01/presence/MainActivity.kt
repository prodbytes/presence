package com.nu01.presence

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
