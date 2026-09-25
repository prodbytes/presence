package com.example.presence_app

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/**
 * The last few seconds of encoded video and audio, kept in memory so a clip
 * can include the moments before it was requested.
 *
 * Samples are stored exactly as the hardware encoders produced them. A clip
 * is written by muxing the stored samples into an MP4, starting at the video
 * keyframe at or before the window start (MP4 can't start mid-GOP). The
 * returned offsets tell the player where the window lies inside the file,
 * the same model the web version uses.
 *
 * Thread-safe: encoder threads append while clips are muxed elsewhere.
 */
class SampleRing {
    class Sample(
        val track: Int,
        val data: ByteArray,
        val ptsUs: Long,
        val flags: Int,
    ) {
        val isKeyframe get() = flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
    }

    /** Where a clip's window lies inside the written file. */
    data class Written(val file: File, val startMs: Long, val endMs: Long)

    private val lock = Object()
    private val samples = ArrayDeque<Sample>()
    private var videoFormat: MediaFormat? = null
    private var audioFormat: MediaFormat? = null

    /** Samples at or after this time are never pruned (clips in progress). */
    private val pins = mutableMapOf<Long, Long>()
    private var nextPin = 0L

    /** How much history to keep, in microseconds. */
    @Volatile var retainUs: Long = 15_000_000

    fun setFormat(track: Int, format: MediaFormat) = synchronized(lock) {
        if (track == VIDEO) videoFormat = format else audioFormat = format
    }

    val hasAudio get() = synchronized(lock) { audioFormat != null }

    fun append(track: Int, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        if (info.size <= 0 || info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) return
        val data = ByteArray(info.size)
        buffer.position(info.offset)
        buffer.get(data, 0, info.size)
        synchronized(lock) {
            samples.addLast(Sample(track, data, info.presentationTimeUs, info.flags))
            prune(info.presentationTimeUs)
            lock.notifyAll()
        }
    }

    /** Latest video timestamp, or null before the first frame. */
    fun latestVideoUs(): Long? = synchronized(lock) {
        samples.lastOrNull { it.track == VIDEO }?.ptsUs
    }

    /** Keeps samples from [fromUs] on until [unpin] is called. */
    fun pin(fromUs: Long): Long = synchronized(lock) {
        val id = nextPin++
        pins[id] = fromUs
        id
    }

    fun unpin(id: Long) = synchronized(lock) { pins.remove(id) }

    /** Blocks until video up to [us] has been recorded, or [timeoutMs] passes. */
    fun awaitVideo(us: Long, timeoutMs: Long): Boolean = synchronized(lock) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while ((samples.lastOrNull { it.track == VIDEO }?.ptsUs ?: Long.MIN_VALUE) < us) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) return false
            lock.wait(left)
        }
        true
    }

    /**
     * Writes [fromUs, toUs] to [file] as an MP4. Returns null if there's no
     * video in that range yet.
     */
    fun write(fromUs: Long, toUs: Long, file: File, orientation: Int): Written? {
        val (video, audio, snapshot) = synchronized(lock) {
            Triple(videoFormat, audioFormat, samples.toList())
        }
        if (video == null) return null
        val keyframe = snapshot.lastOrNull {
            it.track == VIDEO && it.isKeyframe && it.ptsUs <= fromUs
        } ?: snapshot.firstOrNull { it.track == VIDEO && it.isKeyframe } ?: return null
        val startUs = keyframe.ptsUs
        val inRange = snapshot.filter { it.ptsUs in startUs..toUs }
        val lastVideoUs = inRange.lastOrNull { it.track == VIDEO }?.ptsUs ?: return null

        file.parentFile?.mkdirs()
        val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            muxer.setOrientationHint(orientation)
            val videoTrack = muxer.addTrack(video)
            val audioTrack = if (audio != null) muxer.addTrack(audio) else -1
            muxer.start()
            val info = MediaCodec.BufferInfo()
            // MP4 needs strictly increasing timestamps per track; drop any
            // sample that isn't, instead of aborting the whole file.
            val lastPts = longArrayOf(Long.MIN_VALUE, Long.MIN_VALUE)
            for (s in inRange) {
                val track = if (s.track == VIDEO) videoTrack else audioTrack
                if (track < 0 || s.ptsUs <= lastPts[s.track]) continue
                lastPts[s.track] = s.ptsUs
                info.set(0, s.data.size, s.ptsUs - startUs, s.flags)
                muxer.writeSampleData(track, ByteBuffer.wrap(s.data), info)
            }
            muxer.stop()
        } finally {
            muxer.release()
        }
        val endUs = minOf(toUs, lastVideoUs)
        return Written(
            file,
            startMs = maxOf(0L, fromUs - startUs) / 1000,
            endMs = maxOf(0L, endUs - startUs) / 1000,
        )
    }

    /**
     * Drops history older than [retainUs], but only whole GOPs (from one
     * video keyframe to the next), and never anything a clip has pinned.
     */
    private fun prune(nowUs: Long) {
        val keepFrom = minOf(nowUs - retainUs - 1_000_000, pins.values.minOrNull() ?: Long.MAX_VALUE)
        while (true) {
            // The first keyframe after the oldest sample: everything before
            // it can go if that keyframe is itself old enough.
            val next = samples.asSequence().drop(1)
                .firstOrNull { it.track == VIDEO && it.isKeyframe } ?: return
            if (next.ptsUs > keepFrom) return
            while (samples.first() !== next) samples.removeFirst()
        }
    }

    companion object {
        const val VIDEO = 0
        const val AUDIO = 1
    }
}
