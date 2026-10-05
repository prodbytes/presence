package com.nu01.presence

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import kotlin.math.roundToInt

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

    /**
     * Every [STALL_CHECK_MS], a camera whose motion frames stopped for
     * [STALL_MS] is reported lost, so Dart reopens it: a stuck camera
     * records nothing either.
     */
    private val stallCheck = object : Runnable {
        override fun run() {
            for ((cam, _) in open.values) {
                if (!cam.hasMotion) continue
                val age = cam.frameAgeMs() ?: continue
                if (age > STALL_MS) {
                    FileLog.w("camera ${cam.id}: no frames for ${age / 1000} s; reopening it")
                    cam.reportLost("No camera frames for ${age / 1000} s")
                }
            }
            main.postDelayed(this, STALL_CHECK_MS)
        }
    }

    init {
        main.postDelayed(stallCheck, STALL_CHECK_MS)
    }

    /** Whether the app is shown, so cameras feed their previews. */
    private var previewVisible = true

    /**
     * The app is shown or not: cameras feed their previews only while it is
     * (nothing draws them otherwise), and keep recording either way.
     */
    fun setPreviewVisible(visible: Boolean) {
        previewVisible = visible
        for ((cam, _) in open.values) cam.setPreview(visible)
    }

    /** The `presence/motion` event stream: `{id, luma}` frames. */
    private var motionSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        motionSink = events
    }

    override fun onCancel(arguments: Any?) {
        motionSink = null
    }

    private val clipDir get() = File(activity.cacheDir, "clips")

    /** Decodes frames for tagging, off the main thread. */
    private val frames = Executors.newSingleThreadExecutor()

    /**
     * The frame of the recording at [path] closest to [ms], upright (the
     * file's rotation flag applied), at most [maxWidth] px wide, as a JPEG.
     */
    private fun frameAt(path: String, ms: Long, maxWidth: Int): CompletableFuture<ByteArray?> =
        framesAt(path, listOf(ms), maxWidth).thenApply { it.first() }

    /**
     * The frames at each of [times] (ms) of the recording at [path], as
     * [frameAt] makes them, with the file opened once; null where a frame
     * can't be read.
     */
    private fun framesAt(path: String, times: List<Long>, maxWidth: Int): CompletableFuture<List<ByteArray?>> =
        CompletableFuture.supplyAsync({
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                val degrees = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                )?.toIntOrNull() ?: 0
                // One unreadable frame doesn't lose the others.
                times.map { ms -> runCatching { jpegAt(retriever, ms, degrees, maxWidth) }.getOrNull() }
            } finally {
                retriever.release()
            }
        }, frames)

    private fun jpegAt(retriever: MediaMetadataRetriever, ms: Long, degrees: Int, maxWidth: Int): ByteArray? {
        val frame = retriever.getFrameAtTime(ms * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
            ?: return null
        val upright = if (degrees == 0) {
            frame
        } else {
            Bitmap.createBitmap(
                frame, 0, 0, frame.width, frame.height,
                Matrix().apply { postRotate(degrees.toFloat()) }, true,
            )
        }
        val scale = minOf(1f, maxWidth.toFloat() / upright.width)
        val scaled = Bitmap.createScaledBitmap(
            upright,
            (upright.width * scale).toInt(),
            (upright.height * scale).toInt(),
            true,
        )
        return try {
            ByteArrayOutputStream().use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
                out.toByteArray()
            }
        } finally {
            // A batch decodes many frames: free each as soon as it's encoded.
            for (bitmap in setOf(frame, upright, scaled)) bitmap.recycle()
        }
    }

    /**
     * Recognition's frames of the recording at [path]: for each of [times]
     * (ms), the keyframe nearest to it, each keyframe once (decoding one
     * needs no other frame, so it's the cheapest to read), upright, at most
     * [maxWidth] px wide, as raw RGBA: `{ms, width, height, pixels}`, `ms`
     * being the keyframe's own time. Frames that can't be read are left out.
     */
    private fun keyframesAt(path: String, times: List<Long>, maxWidth: Int): CompletableFuture<List<Map<String, Any>>> =
        CompletableFuture.supplyAsync({
            val retriever = MediaMetadataRetriever()
            val extractor = MediaExtractor()
            try {
                retriever.setDataSource(path)
                extractor.setDataSource(path)
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                }
                if (track == null) {
                    emptyList()
                } else {
                    extractor.selectTrack(track)
                    // Where the keyframes are, from the file's index: nothing
                    // is decoded for this.
                    val keyframes = LinkedHashSet<Long>()
                    for (ms in times) {
                        extractor.seekTo(ms * 1000, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                        val us = extractor.sampleTime
                        if (us >= 0) keyframes.add(us)
                    }
                    fun metadata(key: Int) = retriever.extractMetadata(key)?.toIntOrNull() ?: 0
                    val degrees = metadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    val width = metadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    val height = metadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    // One unreadable frame doesn't lose the others.
                    keyframes.mapNotNull { us ->
                        runCatching { rgbaAt(retriever, us, degrees, width, height, maxWidth) }.getOrNull()
                    }
                }
            } finally {
                extractor.release()
                retriever.release()
            }
        }, frames)

    /**
     * The keyframe at [us], scaled to at most [maxWidth] px wide upright
     * before it's turned [degrees] (so only the small copy is turned), as
     * [keyframesAt] gives it. The file's frames are [width] × [height] as
     * stored (0 if unknown).
     */
    private fun rgbaAt(
        retriever: MediaMetadataRetriever,
        us: Long,
        degrees: Int,
        width: Int,
        height: Int,
        maxWidth: Int,
    ): Map<String, Any>? {
        val sync = MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        // Turned a quarter, the upright width is the stored height.
        val uprightWidth = if (degrees % 180 == 0) width else height
        val scale = if (uprightWidth > maxWidth) maxWidth.toFloat() / uprightWidth else 1f
        val frame = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 && width > 0 && height > 0) {
            // Decoded straight to the small size: no full-size bitmap.
            retriever.getScaledFrameAtTime(
                us, sync,
                maxOf(1, (width * scale).roundToInt()),
                maxOf(1, (height * scale).roundToInt()),
            )
        } else {
            retriever.getFrameAtTime(us, sync)?.let { full ->
                val s = if (degrees % 180 == 0) full.width else full.height
                if (s <= maxWidth) {
                    full
                } else {
                    val k = maxWidth.toFloat() / s
                    Bitmap.createScaledBitmap(
                        full,
                        maxOf(1, (full.width * k).roundToInt()),
                        maxOf(1, (full.height * k).roundToInt()),
                        true,
                    ).also { if (it !== full) full.recycle() }
                }
            }
        } ?: return null
        val upright = if (degrees % 360 == 0) {
            frame
        } else {
            Bitmap.createBitmap(
                frame, 0, 0, frame.width, frame.height,
                Matrix().apply { postRotate(degrees.toFloat()) }, true,
            ).also { if (it !== frame) frame.recycle() }
        }
        try {
            val w = upright.width
            val h = upright.height
            val colors = IntArray(w * h)
            upright.getPixels(colors, 0, w, 0, 0, w, h)
            val pixels = ByteArray(w * h * 4)
            for (i in colors.indices) {
                val c = colors[i]
                pixels[i * 4] = (c shr 16).toByte()
                pixels[i * 4 + 1] = (c shr 8).toByte()
                pixels[i * 4 + 2] = c.toByte()
                pixels[i * 4 + 3] = 0xFF.toByte()
            }
            return mapOf("ms" to us / 1000, "width" to w, "height" to h, "pixels" to pixels)
        } finally {
            upright.recycle()
        }
    }

    /** [rgba] ([width] × [height], as [keyframesAt] gives) as a JPEG. */
    private fun jpegOf(width: Int, height: Int, rgba: ByteArray): CompletableFuture<ByteArray> =
        CompletableFuture.supplyAsync({
            require(width > 0 && height > 0 && rgba.size.toLong() == width.toLong() * height * 4) {
                "not $width × $height RGBA"
            }
            val colors = IntArray(width * height) { i ->
                val o = i * 4
                (0xFF shl 24) or
                    ((rgba[o].toInt() and 0xFF) shl 16) or
                    ((rgba[o + 1].toInt() and 0xFF) shl 8) or
                    (rgba[o + 2].toInt() and 0xFF)
            }
            val bitmap = Bitmap.createBitmap(colors, width, height, Bitmap.Config.ARGB_8888)
            try {
                ByteArrayOutputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    out.toByteArray()
                }
            } finally {
                bitmap.recycle()
            }
        }, frames)

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
                "frameAt" -> reply(
                    result,
                    frameAt(
                        call.argument<String>("path")!!,
                        call.longArg("ms"),
                        (call.argument<Number>("maxWidth") ?: 960).toInt(),
                    ),
                ) { it }
                "keyframesAt" -> reply(
                    result,
                    keyframesAt(
                        call.argument<String>("path")!!,
                        call.argument<List<Number>>("ms")!!.map { it.toLong() },
                        (call.argument<Number>("maxWidth") ?: 640).toInt(),
                    ),
                ) { it }
                "encodeJpeg" -> reply(
                    result,
                    jpegOf(
                        (call.argument<Number>("width") ?: 0).toInt(),
                        (call.argument<Number>("height") ?: 0).toInt(),
                        call.argument<ByteArray>("pixels")!!,
                    ),
                ) { it }
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
        if (granted(Manifest.permission.CAMERA)) CaptureService.start(activity)
        permissionResult?.success(permissionState())
        permissionResult = null
        return true
    }

    fun dispose() {
        main.removeCallbacks(stallCheck)
        CaptureService.stop(activity)
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
                    FileLog.w("camera $id failed to open: ${describe(error)}")
                    result.error("camera", describe(error), null)
                } else {
                    cam.onMotionFrame = { luma ->
                        main.post { motionSink?.success(mapOf("id" to id, "luma" to luma)) }
                    }
                    // Taken away while running: Dart closes and reopens it.
                    cam.onLost = { reason ->
                        FileLog.w("camera $id lost: $reason")
                        main.post { motionSink?.success(mapOf("id" to id, "lost" to reason)) }
                    }
                    FileLog.i("camera $id open, ${cam.size.width}x${cam.size.height}, motion ${cam.hasMotion}")
                    cam.setPreview(previewVisible)
                    open[id] = cam to texture
                    // Keep capturing untouched and with the screen off (the
                    // activity starts it too, but not before the first grant).
                    CaptureService.start(activity)
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
        private const val STALL_CHECK_MS = 30_000L
        private const val STALL_MS = 60_000L
    }
}
