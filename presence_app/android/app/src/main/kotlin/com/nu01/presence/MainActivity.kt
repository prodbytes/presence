package com.nu01.presence

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var cameras: PresenceCamerasPlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // First, so everything after is logged, crashes included.
        FileLog.init(this, "app opened")
        KeepAlive.installCrashHandler(this)
        alive = true
        FileLog.i("app screen created")
        KeepAlive.schedule(this)
        super.onCreate(savedInstanceState)
        // A surveillance screen shouldn't go to sleep.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        askToSkipBatteryOptimization()
    }

    override fun onStart() {
        super.onStart()
        FileLog.i("app shown")
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
        FileLog.i("app hidden (screen off or another app in front); capture goes on")
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
            FileLog.w("could not ask to skip battery optimization", e)
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
                    "log" -> {
                        FileLog.fromDart(
                            call.argument<String>("message") ?: "",
                            call.argument<Boolean>("error") == true,
                        )
                        result.success(null)
                    }
                    "logDirectory" -> result.success(FileLog.directory?.path)
                    "memoryStatus" -> result.success(memoryStatus())
                    "googleAccount" -> result.success(GoogleSilentSignIn.remembered(this))
                    "rememberGoogleAccount" -> {
                        val email = call.argument<String>("email")
                        if (email.isNullOrEmpty()) {
                            result.error("bad_args", "email is required", null)
                        } else {
                            GoogleSilentSignIn.remember(this, email)
                            result.success(null)
                        }
                    }
                    "forgetGoogleAccount" ->
                        GoogleSilentSignIn.forget(this, call.argument<String>("serverClientId")) {
                            result.success(null)
                        }
                    "silentGoogleSignIn" -> {
                        val email = call.argument<String>("email")
                        val serverClientId = call.argument<String>("serverClientId")
                        if (email.isNullOrEmpty() || serverClientId.isNullOrEmpty()) {
                            result.error("bad_args", "email and serverClientId are required", null)
                        } else {
                            GoogleSilentSignIn.signIn(this, email, serverClientId) {
                                result.success(it)
                            }
                        }
                    }
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

    /// How much memory is left, as the system judges it: recognition waits
    /// while it's low, so the low-memory killer doesn't take the app.
    private fun memoryStatus(): Map<String, Any> {
        val activities = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo().also { activities.getMemoryInfo(it) }
        return mapOf(
            "lowMemory" to info.lowMemory,
            "availMem" to info.availMem,
            "threshold" to info.threshold,
            "totalMem" to info.totalMem,
            "lowRamDevice" to activities.isLowRamDevice,
        )
    }

    companion object {
        /// Device readings beyond the cameras (the battery's temperature,
        /// free memory), the app's log, and the silent Google sign-in of
        /// the remembered account ([GoogleSilentSignIn]).
        const val DEVICE_CHANNEL = "presence/device"

        /** Whether the app's screen exists (the watchdog opens it if not). */
        @Volatile var alive = false

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
        FileLog.i("app screen destroyed (finishing: $isFinishing); the watchdog reopens it")
        alive = false
        cameras?.dispose()
        cameras = null
        super.onDestroy()
    }
}
