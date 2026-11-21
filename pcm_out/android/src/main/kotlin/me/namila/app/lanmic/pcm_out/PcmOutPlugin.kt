package me.namila.app.lanmic.pcm_out

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Channels for the native receiver. The receiver and audio engine are process singletons: detaching an
 * engine only drops this engine's handlers, never the socket or the stream.
 */
class PcmOutPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private var mySink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "pcm_out").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "pcm_out/packets").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        if (NativeReceiver.sink === mySink) NativeReceiver.sink = null
        mySink = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        mySink = sink
        NativeReceiver.sink = sink // the most recent listener (the service engine) wins
        NativeReceiver.replayBound() // the port may have been bound before this listener existed
    }

    override fun onCancel(arguments: Any?) {
        if (NativeReceiver.sink === mySink) NativeReceiver.sink = null
        mySink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                NativeReceiver.start(call.argument<Int>("port") ?: 5004)
                NativeAudio.nativeStart()
                result.success(null)
            }
            "stop" -> sender.execute { // joins threads: keep it off the main thread
                NativeReceiver.stop()
                NativeAudio.nativeStop()
                main.post { result.success(null) }
            }
            "accept" -> {
                try {
                    NativeReceiver.accept(call.argument("host"), call.argument("port"), call.argument("pin"))
                    result.success(null)
                } catch (e: IOException) {
                    result.error("bad_host", e.message, null)
                }
            }
            "send" -> {
                val data = call.argument<ByteArray>("data")
                val host = call.argument<String>("host")
                val port = call.argument<Int>("port")
                if (data == null || host == null || port == null) return result.error("bad_args", "need data, host, port", null)
                // UDP sends are network I/O: not allowed on the main thread.
                sender.execute {
                    val err = try { NativeReceiver.send(data, host, port); null } catch (e: IOException) { e.message ?: "io" }
                    main.post { if (err == null) result.success(null) else result.error("send_failed", err, null) }
                }
            }
            "rebind" -> {
                NativeReceiver.rebind()
                result.success(null)
            }
            // Capture methods block (open / drain on stop), so they run on the sender executor.
            "captureStart" -> sender.execute {
                val rc = NativeAudio.nativeCaptureStart()
                main.post {
                    when (rc) {
                        0 -> result.success(null)
                        -2 -> result.error("format_unsupported", "input is not 48 kHz mono PCM16", null)
                        else -> result.error("open_failed", "could not open the microphone stream", null)
                    }
                }
            }
            "captureStop" -> sender.execute {
                NativeAudio.nativeCaptureStop()
                main.post { result.success(null) }
            }
            "setTarget" -> {
                NativeAudio.nativeSetTarget(
                    call.argument<String>("host"), call.argument<Int>("port") ?: 0, call.argument<Int>("pin") ?: 0,
                )
                result.success(null)
            }
            "captureStats" -> {
                val out = LongArray(NativeAudio.CAPTURE_STATS_SIZE)
                NativeAudio.nativeCaptureStats(out)
                result.success(out.toList())
            }
            "stats" -> {
                val out = LongArray(NativeAudio.STATS_SIZE)
                NativeAudio.nativeStats(out)
                result.success(out.toList())
            }
            else -> result.notImplemented()
        }
    }

    private companion object {
        val main = Handler(Looper.getMainLooper())
        val sender = Executors.newSingleThreadExecutor { r -> Thread(r, "lanmic-udp-send").also { it.isDaemon = true } }
    }
}
