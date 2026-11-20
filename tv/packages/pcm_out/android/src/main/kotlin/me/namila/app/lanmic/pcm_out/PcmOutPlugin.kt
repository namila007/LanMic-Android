package me.namila.app.lanmic.pcm_out

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Process
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

private const val FRAME_BYTES = 960
private const val QUEUE_FRAMES = 8

/** AudioTrack output. write() only enqueues; one URGENT_AUDIO thread does the blocking AudioTrack writes. */
class PcmOutPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var track: AudioTrack? = null
    private var queue = ArrayBlockingQueue<ByteArray>(QUEUE_FRAMES)
    private var thread: Thread? = null
    private val dropped = AtomicInteger()
    // One counter per start(): a late write from an old thread must not touch the new session's count.
    private var framesWritten = AtomicLong()
    private var sampleRate = 48000

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "pcm_out")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        stop()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> { start(call.argument<Int>("sampleRate") ?: 48000); result.success(null) }
            "write" -> {
                val frame = call.arguments as? ByteArray
                if (frame == null || frame.size != FRAME_BYTES) return result.error("bad_frame", "need $FRAME_BYTES bytes", null)
                // Drop the oldest frame when the writer thread falls behind, so latency cannot grow.
                while (!queue.offer(frame)) if (queue.poll() != null) dropped.incrementAndGet()
                result.success(null)
            }
            "stats" -> result.success(mapOf("latencyMs" to latencyMs(), "dropped" to dropped.get()))
            "stop" -> { stop(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    /** Queued frames plus what the AudioTrack still has to play; null without a track. */
    private fun latencyMs(): Int? {
        val t = track ?: return null
        return try {
            val ts = AudioTimestamp()
            val outFrames = if (t.getTimestamp(ts)) {
                maxOf(0L, framesWritten.get() - ts.framePosition)
            } else {
                minOf(framesWritten.get(), t.bufferSizeInFrames.toLong())
            }
            (queue.size * 10 + outFrames * 1000 / sampleRate).toInt()
        } catch (_: IllegalStateException) { // track released concurrently
            null
        }
    }

    private fun start(sampleRate: Int) {
        stop()
        this.sampleRate = sampleRate
        dropped.set(0)
        val written = AtomicLong()
        framesWritten = written
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        val min = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(format)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(min, 4 * FRAME_BYTES))
            .build()
        val q = ArrayBlockingQueue<ByteArray>(QUEUE_FRAMES)
        queue = q
        track = t
        t.play()
        thread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            try {
                while (!Thread.currentThread().isInterrupted) {
                    val f = q.take()
                    val n = t.write(f, 0, f.size, AudioTrack.WRITE_BLOCKING)
                    if (n < 0) break // track error or released
                    if (n > 0) written.addAndGet((n / 2).toLong())
                }
            } catch (_: Exception) { // interrupted by stop(), or the track was released mid-write
            }
        }, "pcm-out").also { it.start() }
    }

    private fun stop() {
        thread?.interrupt()
        thread = null
        track?.let { it.pause(); it.flush(); it.release() }
        track = null
        queue.clear()
    }
}
