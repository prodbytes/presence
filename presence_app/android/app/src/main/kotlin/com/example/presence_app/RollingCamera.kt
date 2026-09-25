package com.example.presence_app

import android.annotation.SuppressLint
import android.graphics.Bitmap
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
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaRecorder
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
                @Suppress("DEPRECATION")
                camera.createCaptureSession(
                    listOf(preview, encoderSurface),
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(s: CameraCaptureSession) {
                            session = s
                            val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                                addTarget(preview)
                                addTarget(encoderSurface)
                                chooseFpsRange()?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                            }.build()
                            s.setRepeatingRequest(request, null, cameraHandler)
                            ready.complete(Unit)
                        }

                        override fun onConfigureFailed(s: CameraCaptureSession) {
                            ready.completeExceptionally(IllegalStateException("Camera session failed"))
                        }
                    },
                    cameraHandler,
                )
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                if (!ready.isDone) ready.completeExceptionally(IllegalStateException("Camera disconnected"))
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                val reason = when (error) {
                    ERROR_CAMERA_IN_USE -> "Camera is in use by another app"
                    ERROR_MAX_CAMERAS_IN_USE -> "Too many cameras open at once"
                    ERROR_CAMERA_DISABLED -> "Camera is disabled"
                    else -> "Camera error $error"
                }
                if (!ready.isDone) ready.completeExceptionally(IllegalStateException(reason))
            }
        }, cameraHandler)
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
            val frame = retriever.getFrameAtTime(
                maxOf(0L, endUs - 100_000),
                MediaMetadataRetriever.OPTION_CLOSEST,
            ) ?: retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return@supplyAsync null
            val upright = rotate(frame, orientationHint)
            val scale = minOf(1f, 480f / upright.width)
            val thumb = Bitmap.createScaledBitmap(
                upright,
                (upright.width * scale).toInt(),
                (upright.height * scale).toInt(),
                true,
            )
            ByteArrayOutputStream().use { out ->
                thumb.compress(Bitmap.CompressFormat.JPEG, 80, out)
                out.toByteArray()
            }
        } finally {
            retriever.release()
            file.delete()
        }
    }, frameExecutor)

    fun close() {
        running = false
        runCatching { session?.close() }
        runCatching { device?.close() }
        runCatching { audioRecord?.stop() }
        runCatching { audioRecord?.release() }
        runCatching { videoEncoder?.stop() }
        runCatching { videoEncoder?.release() }
        runCatching { audioEncoder?.stop() }
        runCatching { audioEncoder?.release() }
        runCatching { previewSurface?.release() }
        cameraThread.quitSafely()
        clipExecutor.shutdown()
        frameExecutor.shutdown()
        waitExecutor.shutdown()
    }

    private fun startVideoEncoder(): Surface {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size.width, size.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, if (size.width >= 1280) 2_500_000 else 1_500_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            // A keyframe every second: clips can start at most 1 s before
            // their window, and history is pruned in 1 s steps.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = encoder.createInputSurface()
        encoder.start()
        videoEncoder = encoder
        thread(name = "video-encoder-$id") { drain(encoder, SampleRing.VIDEO) }
        return surface
    }

    @SuppressLint("MissingPermission")
    private fun startAudio() {
        val sampleRate = 44_100
        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val record = runCatching {
            AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuffer * 4,
            )
        }.getOrNull()
        if (record == null || record.state != AudioRecord.STATE_INITIALIZED) {
            record?.release()
            return // Record video only.
        }
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, minBuffer * 4)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()
        record.startRecording()
        audioRecord = record
        audioEncoder = encoder

        thread(name = "audio-capture-$id") {
            val pcm = ByteArray(minBuffer)
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
                val index = runCatching { encoder.dequeueInputBuffer(10_000) }.getOrDefault(-1)
                if (index < 0) continue
                val input = encoder.getInputBuffer(index) ?: continue
                input.clear()
                input.put(pcm, 0, minOf(read, input.remaining()))
                encoder.queueInputBuffer(index, 0, minOf(read, input.capacity()), pts, 0)
            }
        }
        thread(name = "audio-encoder-$id") { drain(encoder, SampleRing.AUDIO) }
    }

    /** Moves encoder output into the ring until the camera closes. */
    private fun drain(encoder: MediaCodec, track: Int) {
        val info = MediaCodec.BufferInfo()
        while (running) {
            val index = try {
                encoder.dequeueOutputBuffer(info, 10_000)
            } catch (_: IllegalStateException) {
                return
            }
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> ring.setFormat(track, encoder.outputFormat)
                index >= 0 -> {
                    val buffer = encoder.getOutputBuffer(index)
                    if (buffer != null) ring.append(track, buffer, info)
                    encoder.releaseOutputBuffer(index, false)
                }
            }
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

    /** A steady 30 fps (or the closest available), for smooth recordings. */
    private fun chooseFpsRange(): Range<Int>? {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?: return null
        return ranges.filter { it.upper <= 30 }.maxWithOrNull(compareBy({ it.upper }, { it.lower }))
    }

    private fun rotate(bitmap: Bitmap, degrees: Int): Bitmap {
        if (degrees % 360 == 0) return bitmap
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }
}
