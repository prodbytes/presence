package com.nu01.presence

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Range
import android.util.Size
import android.view.Surface
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * One camera that is always recording: Camera2 feeds both a preview texture
 * and a hardware H.264 encoder, the default microphone feeds an AAC encoder,
 * and both encoders write into a [SampleRing]. Clips are cut from the ring.
 */
class RollingCamera(
    private val manager: CameraManager,
    val id: String,
    private val previewTexture: SurfaceTexture,
    private val clipDir: File,
    private val withAudio: Boolean,
) {
    val characteristics: CameraCharacteristics = manager.getCameraCharacteristics(id)
    val sensorOrientation: Int = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
    val facingFront: Boolean =
        characteristics.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_FRONT
    val size: Size = chooseSize()

    val ring = SampleRing()

    /**
     * Camera frames are stamped with either the boot-time clock (counts deep
     * sleep) or the monotonic clock. Audio and clip requests use the same one.
     */
    private val realtimeClock =
        characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE) ==
            CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME

    fun nowUs(): Long =
        if (realtimeClock) SystemClock.elapsedRealtimeNanos() / 1000 else System.nanoTime() / 1000

    private val cameraThread = HandlerThread("camera-$id").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)
    private val clipExecutor = Executors.newSingleThreadExecutor()

    /** Thumbnails, kept apart so they never delay a clip's "before" part. */
    private val frameExecutor = Executors.newSingleThreadExecutor()

    /** Clips waiting for their "after" part each park a thread here. */
    private val waitExecutor = Executors.newCachedThreadPool()

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var videoEncoder: MediaCodec? = null
    private var audioEncoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var previewSurface: Surface? = null
    @Volatile private var running = true

    /** The encoder and microphone threads, joined on [close]. */
    private val workers = mutableListOf<Thread>()

    /** Completes when the camera device has closed (or never opened). */
    private val closed = CompletableFuture<Unit>()

    private val pending = mutableMapOf<Long, Clip>()
    private var nextClip = 0L

    private class Clip(val pressUs: Long, val fromUs: Long, val toUs: Long, val pin: Long)

    /** Mux orientation: the rotation that makes the recording upright on a portrait phone. */
    private val orientationHint = sensorOrientation

    /** Opens the camera and starts recording; completes once frames flow. */
    @SuppressLint("MissingPermission")
    fun start(): CompletableFuture<Unit> {
        val ready = CompletableFuture<Unit>()
        val encoderSurface = startVideoEncoder()
        if (withAudio) startAudio()

        previewTexture.setDefaultBufferSize(size.width, size.height)
        val preview = Surface(previewTexture).also { previewSurface = it }

        try {
            openDevice(preview, encoderSurface, ready)
        } catch (e: Exception) {
            ready.completeExceptionally(e)
        }
        return ready
    }

    @SuppressLint("MissingPermission")
    private fun openDevice(preview: Surface, encoderSurface: Surface, ready: CompletableFuture<Unit>) {
        manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                device = camera
                configure(camera, preview, encoderSurface, startMotionReader(), ready)
            }

            override fun onClosed(camera: CameraDevice) {
                closed.complete(Unit)
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                fail(ready, "Camera disconnected")
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                fail(
                    ready,
                    when (error) {
                        ERROR_CAMERA_IN_USE -> "Camera is in use by another app"
                        ERROR_MAX_CAMERAS_IN_USE -> "Too many cameras open at once"
                        ERROR_CAMERA_DISABLED -> "Camera is disabled"
                        else -> "Camera error $error"
                    },
                )
            }
        }, cameraHandler)
    }

    /**
     * Fails opening with [reason], or, once the camera is running, reports
     * that the system took it away ([onLost]), so it can be reopened.
     */
    private fun fail(ready: CompletableFuture<Unit>, reason: String) {
        if (!ready.isDone) {
            ready.completeExceptionally(IllegalStateException(reason))
        } else {
            reportLost(reason)
        }
    }

    @Volatile private var lostReported = false

    /** Tells [onLost], once, that this running camera is gone (or stuck). */
    fun reportLost(reason: String) {
        if (!running || lostReported) return
        lostReported = true
        onLost?.invoke(reason)
    }

    /** Called when the running camera is taken away (disconnected or failed). */
    @Volatile var onLost: ((String) -> Unit)? = null

    /**
     * Preview + encoder, plus a small YUV stream for motion detection if the
     * camera accepts three outputs. If it refuses, retry without motion:
     * recording matters more.
     */
    private fun configure(
        camera: CameraDevice,
        preview: Surface,
        encoderSurface: Surface,
        motion: ImageReader?,
        ready: CompletableFuture<Unit>,
    ) {
        val outputs = listOfNotNull(preview, encoderSurface, motion?.surface)
        @Suppress("DEPRECATION")
        camera.createCaptureSession(
            outputs,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        outputs.filter { it !== preview }.forEach { addTarget(it) }
                        set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                        set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                        chooseFpsRange()?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                    }
                    applyRequest()
                    ready.complete(Unit)
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    if (motion != null) {
                        motion.close()
                        motionReader = null
                        configure(camera, preview, encoderSurface, null, ready)
                    } else {
                        ready.completeExceptionally(IllegalStateException("Camera session failed"))
                    }
                }
            },
            cameraHandler,
        )
    }

    /** Called with each 64×48 luma frame (about 5 per second). */
    @Volatile var onMotionFrame: ((ByteArray) -> Unit)? = null

    /** Whether the camera accepted the motion stream. */
    val hasMotion get() = motionReader != null

    private var motionReader: ImageReader? = null
    @Volatile private var lastMotionFrameMs = 0L

    /** How long since the latest motion frame (ms); null before the first. */
    fun frameAgeMs(): Long? =
        lastMotionFrameMs.takeIf { it > 0 }?.let { SystemClock.elapsedRealtime() - it }

    private fun startMotionReader(): ImageReader? {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        // The smallest YUV size that's still at least 160 px wide.
        val size = map?.getOutputSizes(ImageFormat.YUV_420_888)
            ?.filter { it.width >= 160 }
            ?.minByOrNull { it.width * it.height } ?: return null
        val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
        // Every camera frame (~30/s) lands here, on the camera thread, and
        // must be released or the camera stalls. Between the ~5 used per
        // second, just release it: one acquire, no other work.
        reader.setOnImageAvailableListener({ r ->
            val now = SystemClock.elapsedRealtime()
            if (now - lastMotionFrameMs < 200) {
                runCatching { r.acquireNextImage()?.close() }
                return@setOnImageAvailableListener
            }
            val image = runCatching { r.acquireLatestImage() }.getOrNull() ?: return@setOnImageAvailableListener
            image.use { img ->
                lastMotionFrameMs = now
                onMotionFrame?.invoke(downsampleLuma(img))
            }
        }, cameraHandler)
        motionReader = reader
        return reader
    }

    /** Nearest-neighbour 64×48 sample of the Y (luma) plane. */
    private fun downsampleLuma(image: Image): ByteArray {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val out = ByteArray(MOTION_W * MOTION_H)
        for (y in 0 until MOTION_H) {
            val row = (y * image.height / MOTION_H) * plane.rowStride
            for (x in 0 until MOTION_W) {
                out[y * MOTION_W + x] = buffer.get(row + (x * image.width / MOTION_W) * plane.pixelStride)
            }
        }
        return out
    }

    /** The repeating capture request, kept so settings can change live. */
    private var request: CaptureRequest.Builder? = null

    /**
     * Whether frames go to the preview. Off while the app isn't shown (the
     * screen is off or it's in the background): nothing draws the preview
     * then, its buffers fill up, and the camera would stall every output,
     * the recording too.
     */
    @Volatile private var previewOn = true

    fun setPreview(on: Boolean) {
        previewOn = on
        cameraHandler.post { applyRequest() }
    }

    /** Requested brightness, in EV (exposure compensation). */
    @Volatile private var brightnessEv = 0f

    /**
     * Brighter or darker picture: auto-exposure compensation in EV, clamped
     * to what this camera supports. Applied live, and to recordings too.
     */
    fun setBrightness(ev: Float) {
        brightnessEv = ev
        cameraHandler.post { applyRequest() }
    }

    private fun applyRequest() {
        val builder = request ?: return
        val s = session ?: return
        previewSurface?.let { if (previewOn) builder.addTarget(it) else builder.removeTarget(it) }
        val range = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val step = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)
        if (range != null && step != null && step.toFloat() > 0f) {
            val index = Math.round(brightnessEv / step.toFloat()).coerceIn(range.lower, range.upper)
            builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, index)
        }
        runCatching { s.setRepeatingRequest(builder.build(), null, cameraHandler) }
    }

    fun setPreRoll(ms: Long) {
        ring.retainUs = ms * 1000
    }

    /** Marks a clip at this moment; the two parts are fetched separately. */
    fun requestClip(beforeMs: Long, afterMs: Long): Long {
        val press = nowUs()
        val from = press - beforeMs * 1000
        val clip = Clip(press, from, press + afterMs * 1000, ring.pin(from - 2_000_000))
        synchronized(pending) {
            val token = nextClip++
            pending[token] = clip
            return token
        }
    }

    /** Writes the "before" part: everything from the window start to the press. */
    fun clipPast(token: Long): CompletableFuture<SampleRing.Written?> {
        val clip = synchronized(pending) { pending[token] } ?: return CompletableFuture.completedFuture(null)
        return CompletableFuture.supplyAsync({
            ring.write(clip.fromUs, clip.pressUs, File(clipDir, "clip-$id-$token-past.mp4"), orientationHint)
        }, clipExecutor)
    }

    /** Waits for the "after" part, then writes the whole clip. */
    fun clipFull(token: Long): CompletableFuture<SampleRing.Written?> {
        val clip = synchronized(pending) { pending[token] } ?: return CompletableFuture.completedFuture(null)
        return CompletableFuture.supplyAsync({
            try {
                val waitMs = (clip.toUs - nowUs()) / 1000 + 5_000
                ring.awaitVideo(clip.toUs, maxOf(waitMs, 0))
                ring.write(clip.fromUs, clip.toUs, File(clipDir, "clip-$id-$token-full.mp4"), orientationHint)
            } finally {
                ring.unpin(clip.pin)
                synchronized(pending) { pending.remove(token) }
            }
        }, waitExecutor)
    }

    /** The latest frame as a JPEG, upright, at most 480 px wide. */
    fun captureFrame(): CompletableFuture<ByteArray?> = CompletableFuture.supplyAsync({
        val now = ring.latestVideoUs() ?: return@supplyAsync null
        val file = File(clipDir, "frame-$id.mp4")
        val written = ring.write(now, now, file, 0) ?: return@supplyAsync null
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.path)
            // Some decoders return nothing for the file's very last frame:
            // ask just before it, then fall back to the (≤1 s old) keyframe.
            val endUs = written.endMs * 1000
            val frame = frameAt(retriever, maxOf(0L, endUs - 100_000), MediaMetadataRetriever.OPTION_CLOSEST)
                ?: frameAt(retriever, 0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return@supplyAsync null
            // Scale before rotating: the rotation then works on a small bitmap.
            val sideways = orientationHint % 180 != 0
            val scale = minOf(1f, 480f / (if (sideways) frame.height else frame.width))
            val small = if (scale < 1f) {
                Bitmap.createScaledBitmap(
                    frame,
                    (frame.width * scale).toInt(),
                    (frame.height * scale).toInt(),
                    true,
                ).also { if (it !== frame) frame.recycle() }
            } else {
                frame
            }
            val thumb = rotate(small, orientationHint).also { if (it !== small) small.recycle() }
            try {
                ByteArrayOutputStream().use { out ->
                    thumb.compress(Bitmap.CompressFormat.JPEG, 80, out)
                    out.toByteArray()
                }
            } finally {
                thumb.recycle()
            }
        } finally {
            retriever.release()
            file.delete()
        }
    }, frameExecutor)

    /**
     * Closes everything; completes once the camera device has closed.
     * Returns at once: closing the camera and the codecs can block for
     * hundreds of ms, so that happens on the camera thread, not the caller's.
     */
    fun close(): CompletableFuture<Unit> {
        running = false
        onMotionFrame = null
        clipExecutor.shutdown()
        frameExecutor.shutdown()
        waitExecutor.shutdown()
        cameraHandler.post {
            runCatching { session?.close() }
            if (device == null) closed.complete(Unit) else runCatching { device?.close() }
            runCatching { motionReader?.close() }
            // Unblock the microphone read, then let the encoder threads see
            // `running` and stop (they wait at most CODEC_TIMEOUT_US), so no
            // thread is inside a codec while it's stopped and released.
            runCatching { audioRecord?.stop() }
            workers.forEach { runCatching { it.join(1_000) } }
            runCatching { audioRecord?.release() }
            runCatching { videoEncoder?.stop() }
            runCatching { videoEncoder?.release() }
            runCatching { audioEncoder?.stop() }
            runCatching { audioEncoder?.release() }
            runCatching { previewSurface?.release() }
            // The closed callback arrives on the camera thread: stop it only
            // afterwards. Don't wait forever on a device that never reports
            // back (orTimeout needs Android 12, so time out by hand).
            cameraHandler.postDelayed({ closed.complete(Unit) }, 3_000)
        }
        closed.whenComplete { _, _ -> cameraThread.quitSafely() }
        return closed
    }

    private fun startVideoEncoder(): Surface {
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size.width, size.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, if (size.width >= 1280) 1_500_000 else 1_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            // A keyframe every second: clips can start at most 1 s before
            // their window, and history is pruned in 1 s steps.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        // Variable bitrate where offered: a still scene (most of the time)
        // then costs far fewer bits than the cap.
        val vbr = runCatching {
            encoder.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).encoderCapabilities
                .isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        }.getOrDefault(false)
        if (vbr) format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        try {
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (e: Exception) {
            if (!vbr) throw e
            // The mode was refused after all: configure without it.
            encoder.reset()
            format.removeKey(MediaFormat.KEY_BITRATE_MODE)
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
        val surface = encoder.createInputSurface()
        encoder.start()
        videoEncoder = encoder
        workers += thread(name = "video-encoder-$id") { drain(encoder, SampleRing.VIDEO) }
        return surface
    }

    /**
     * The microphone at 16 kHz mono, AAC at 32 kbps: plenty for speech and
     * room sound, with well under half the encoding work of 44.1 kHz. Falls
     * back to 44.1 kHz at 64 kbps (which every phone supports) if refused.
     */
    private fun startAudio() {
        for ((sampleRate, bitRate) in listOf(16_000 to 32_000, 44_100 to 64_000)) {
            if (startAudio(sampleRate, bitRate)) return
        }
        // Record video only.
    }

    @SuppressLint("MissingPermission")
    private fun startAudio(sampleRate: Int, bitRate: Int): Boolean {
        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return false
        // Read 100 ms (16-bit samples) at a time: fewer wake-ups than the
        // minimum buffer's ~20-40 ms, and the recorder holds four of them.
        val chunk = maxOf(minBuffer, sampleRate / 10 * 2)
        val record = runCatching {
            AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                chunk * 4,
            )
        }.getOrNull()
        if (record == null || record.state != AudioRecord.STATE_INITIALIZED) {
            record?.release()
            return false
        }
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, chunk)
        }
        val encoder = runCatching {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).also {
                try {
                    it.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    it.start()
                } catch (e: Exception) {
                    it.release()
                    throw e
                }
            }
        }.getOrNull()
        if (encoder == null) {
            record.release()
            return false
        }
        record.startRecording()
        audioRecord = record
        audioEncoder = encoder

        workers += thread(name = "audio-capture-$id") {
            val pcm = ByteArray(chunk)
            // Timestamps come from the sample count, anchored to the camera
            // clock: "now minus the buffer length" jitters by a few ms, and
            // MP4 rejects audio that goes back in time even slightly.
            var anchorUs = -1L
            var samples = 0L
            var lastPts = Long.MIN_VALUE
            while (running) {
                val read = record.read(pcm, 0, pcm.size)
                if (read <= 0) continue
                val count = read / 2
                val wallStartUs = nowUs() - count * 1_000_000L / sampleRate
                var pts = anchorUs + samples * 1_000_000L / sampleRate
                // Re-anchor on start and whenever the sample clock drifts
                // more than 100 ms from the camera clock (e.g. after a stall).
                if (anchorUs < 0 || kotlin.math.abs(pts - wallStartUs) > 100_000) {
                    anchorUs = wallStartUs - samples * 1_000_000L / sampleRate
                    pts = wallStartUs
                }
                pts = maxOf(pts, lastPts + 1)
                lastPts = pts
                samples += count
                try {
                    val index = encoder.dequeueInputBuffer(CODEC_TIMEOUT_US)
                    if (index < 0) continue
                    val input = encoder.getInputBuffer(index) ?: continue
                    input.clear()
                    input.put(pcm, 0, minOf(read, input.remaining()))
                    encoder.queueInputBuffer(index, 0, minOf(read, input.capacity()), pts, 0)
                } catch (_: IllegalStateException) {
                    return@thread // The encoder was stopped or failed.
                }
            }
        }
        workers += thread(name = "audio-encoder-$id") { drain(encoder, SampleRing.AUDIO) }
        return true
    }

    /**
     * Moves encoder output into the ring until the camera closes. The wait
     * returns as soon as output is ready: its timeout only bounds an idle
     * wait, so a long one adds no delay, just fewer wake-ups.
     */
    private fun drain(encoder: MediaCodec, track: Int) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = encoder.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> ring.setFormat(track, encoder.outputFormat)
                    index >= 0 -> {
                        val buffer = encoder.getOutputBuffer(index)
                        if (buffer != null) ring.append(track, buffer, info)
                        encoder.releaseOutputBuffer(index, false)
                    }
                }
            }
        } catch (_: IllegalStateException) {
            // The encoder was stopped or failed.
        }
    }

    /** Largest 16:9 (or else 4:3) size up to 1280×720 that the encoder path supports. */
    private fun chooseSize(): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(MediaRecorder::class.java)?.toList().orEmpty()
        fun fits(s: Size) = s.width <= 1280 && s.height <= 720
        return sizes.filter { fits(it) && it.width * 9 == it.height * 16 }.maxByOrNull { it.width * it.height }
            ?: sizes.filter { fits(it) && it.width * 3 == it.height * 4 }.maxByOrNull { it.width * it.height }
            ?: sizes.filter(::fits).maxByOrNull { it.width * it.height }
            ?: Size(640, 480)
    }

    /**
     * Up to 30 fps, but variable: a fixed 30 fps caps exposure at 1/30 s,
     * which makes a small sensor very dark indoors. A range like 15–30 lets
     * auto-exposure slow down in low light. It only drops below 30 fps when
     * it's dark, so prefer the lowest floor down to 5 fps (e.g. the S40
     * offers only [5, 30] and [30, 30]; below 5, motion is unwatchable).
     */
    private fun chooseFpsRange(): Range<Int>? {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?: return null
        val candidates = ranges.filter { it.upper <= 30 }
        val bestUpper = candidates.maxOfOrNull { it.upper } ?: return null
        val top = candidates.filter { it.upper == bestUpper }
        return top.filter { it.lower >= 5 }.minByOrNull { it.lower }
            ?: top.minByOrNull { it.lower }
    }

    /**
     * The frame at [timeUs], decoded straight to thumbnail size where the
     * system can (Android 8.1+): no full-size bitmap to allocate and scale.
     */
    private fun frameAt(retriever: MediaMetadataRetriever, timeUs: Long, option: Int): Bitmap? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) return retriever.getFrameAtTime(timeUs, option)
        // Fits within this box, keeping the aspect ratio: 480 px across once upright.
        val sideways = orientationHint % 180 != 0
        val across = if (sideways) size.height else size.width
        val scale = minOf(1f, 480f / across)
        return retriever.getScaledFrameAtTime(
            timeUs,
            option,
            (size.width * scale).toInt(),
            (size.height * scale).toInt(),
        )
    }

    private fun rotate(bitmap: Bitmap, degrees: Int): Bitmap {
        if (degrees % 360 == 0) return bitmap
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    companion object {
        const val MOTION_W = 64
        const val MOTION_H = 48

        /** Longest idle wait for a codec buffer (µs); output never waits on it. */
        const val CODEC_TIMEOUT_US = 100_000L
    }
}
