package com.nu01.presence

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.CompletableFuture

/**
 * The `presence/cameras` channel: lists and opens always-recording cameras,
 * and cuts clips from them. See `lib/cameras/native_cameras.dart`.
 */
class PresenceCamerasPlugin(
    private val activity: Activity,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val main = Handler(Looper.getMainLooper())
    private val open = mutableMapOf<String, Pair<RollingCamera, TextureRegistry.SurfaceTextureEntry>>()
    private var permissionResult: MethodChannel.Result? = null

    /** The `presence/motion` event stream: `{id, luma}` frames. */
    private var motionSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        motionSink = events
    }

    override fun onCancel(arguments: Any?) {
        motionSink = null
    }

    private val clipDir get() = File(activity.cacheDir, "clips")

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestPermissions" -> requestPermissions(result)
                "listCameras" -> result.success(listCameras())
                "open" -> openCamera(call.argument<String>("id")!!, call.longArg("preRollMs"), result)
                "setBrightness" -> {
                    camera(call)?.setBrightness((call.argument<Number>("ev") ?: 0).toFloat())
                    result.success(null)
                }
                "setPreRoll" -> {
                    camera(call)?.setPreRoll(call.longArg("preRollMs"))
                    result.success(null)
                }
                "requestClip" -> result.success(
                    camera(call)?.requestClip(call.longArg("beforeMs"), call.longArg("afterMs")),
                )
                "clipPast" -> reply(result, camera(call)?.clipPast(call.longArg("token"))) { it?.toMap() }
                "clipFull" -> reply(result, camera(call)?.clipFull(call.longArg("token"))) { it?.toMap() }
                "captureFrame" -> reply(result, camera(call)?.captureFrame()) { it }
                "close" -> {
                    val entry = open.remove(call.argument<String>("id"))
                    if (entry == null) {
                        result.success(null)
                    } else {
                        // Reply once the device is really closed: phones allow
                        // one open camera, and the next open would fail.
                        entry.first.close().whenComplete { _, _ ->
                            main.post {
                                entry.second.release()
                                result.success(null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("camera", e.message ?: e.toString(), null)
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grants: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionResult?.success(permissionState())
        permissionResult = null
        return true
    }

    fun dispose() {
        for ((cam, texture) in open.values) {
            cam.close()
            texture.release()
        }
        open.clear()
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val missing = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            .filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            result.success(permissionState())
            return
        }
        permissionResult = result
        activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
    }

    private fun permissionState() = mapOf(
        "camera" to granted(Manifest.permission.CAMERA),
        "microphone" to granted(Manifest.permission.RECORD_AUDIO),
    )

    private fun granted(permission: String) =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Every camera, back ones first (the first is the default). */
    private fun listCameras(): List<Map<String, Any?>> {
        val ids = manager.cameraIdList.sortedBy { facing(it) == CameraMetadata.LENS_FACING_FRONT }
        return ids.map { id ->
            val front = facing(id) == CameraMetadata.LENS_FACING_FRONT
            mapOf(
                "id" to id,
                "label" to (if (front) "Front camera" else "Back camera") + if (ids.size > 2) " $id" else "",
                "front" to front,
            )
        }
    }

    private fun facing(id: String) =
        manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)

    private fun openCamera(id: String, preRollMs: Long, result: MethodChannel.Result) {
        // A camera reopened after a failure replaces the old one.
        open.remove(id)?.let { (cam, texture) ->
            cam.close()
            texture.release()
        }
        // The texture must be created on the main thread; everything slow
        // (encoders, microphone, opening the camera) happens off it.
        val texture = textures.createSurfaceTexture()
        val withAudio = granted(Manifest.permission.RECORD_AUDIO)
        CompletableFuture.supplyAsync {
            RollingCamera(manager, id, texture.surfaceTexture(), clipDir, withAudio).also {
                it.setPreRoll(preRollMs)
            }
        }.thenCompose { cam ->
            cam.start().handle { _, error ->
                if (error != null) {
                    cam.close()
                    throw error
                }
                cam
            }
        }.whenComplete { cam, error ->
            main.post {
                if (error != null) {
                    texture.release()
                    result.error("camera", describe(error), null)
                } else {
                    cam.onMotionFrame = { luma ->
                        main.post { motionSink?.success(mapOf("id" to id, "luma" to luma)) }
                    }
                    open[id] = cam to texture
                    result.success(
                        mapOf(
                            "textureId" to texture.id(),
                            "width" to cam.size.width,
                            "height" to cam.size.height,
                            "sensorOrientation" to cam.sensorOrientation,
                            "front" to cam.facingFront,
                            "audio" to granted(Manifest.permission.RECORD_AUDIO),
                            "motion" to cam.hasMotion,
                        ),
                    )
                }
            }
        }
    }

    private fun camera(call: MethodCall) = open[call.argument<String>("id")]?.first

    /** A readable reason for a camera that failed to open. */
    private fun describe(error: Throwable): String {
        var e: Throwable = error
        while (e.cause != null && (e is java.util.concurrent.CompletionException || e is java.util.concurrent.ExecutionException)) {
            e = e.cause!!
        }
        if (e is CameraAccessException) {
            return when (e.reason) {
                CameraAccessException.CAMERA_DISABLED ->
                    "Blocked by Android while the screen was off or the app was in the background"
                CameraAccessException.CAMERA_IN_USE -> "In use by another app"
                CameraAccessException.MAX_CAMERAS_IN_USE -> "Too many cameras open at once"
                CameraAccessException.CAMERA_DISCONNECTED -> "Disconnected"
                else -> "Couldn't open (error ${e.reason})"
            }
        }
        return e.message ?: e.toString()
    }

    private fun <T> reply(
        result: MethodChannel.Result,
        future: CompletableFuture<T>?,
        convert: (T) -> Any?,
    ) {
        if (future == null) {
            result.success(null)
            return
        }
        future.whenComplete { value, error ->
            main.post {
                if (error != null) {
                    result.error("camera", error.cause?.message ?: error.message, null)
                } else {
                    result.success(convert(value))
                }
            }
        }
    }

    private fun SampleRing.Written.toMap() = mapOf(
        "path" to file.path,
        "startMs" to startMs,
        "endMs" to endMs,
        "mimeType" to "video/mp4",
    )

    private fun MethodCall.longArg(name: String): Long = (argument<Number>(name) ?: 0).toLong()

    companion object {
        const val CHANNEL = "presence/cameras"
        const val MOTION_CHANNEL = "presence/motion"
        private const val PERMISSION_REQUEST = 4201
    }
}
