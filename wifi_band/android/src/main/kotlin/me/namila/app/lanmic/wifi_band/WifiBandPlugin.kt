package me.namila.app.lanmic.wifi_band

import android.content.Context
import android.net.ConnectivityManager
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Reports the connected Wi-Fi frequency in MHz (null when not on Wi-Fi) and holds the low-latency Wi-Fi lock. */
class WifiBandPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "wifi_band")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        setLowLatency(false) // never leave the lock held for a dead engine
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "frequencyMhz" -> result.success(frequencyMhz())
            "setLowLatency" -> {
                setLowLatency(call.arguments as? Boolean ?: false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private var lock: WifiManager.WifiLock? = null

    private fun setLowLatency(on: Boolean) {
        try {
            if (on) {
                val l = lock ?: (context?.applicationContext?.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
                    ?.createWifiLock(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                        else @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                        "lanmic:low-latency",
                    )?.apply { setReferenceCounted(false) }
                lock = l
                if (l?.isHeld == false) l.acquire()
            } else if (lock?.isHeld == true) {
                lock?.release()
            }
        } catch (e: RuntimeException) {
            Log.w("wifi_band", "low-latency Wi-Fi lock failed: $e") // best effort: audio still works
        }
    }

    @Suppress("DEPRECATION")
    private fun frequencyMhz(): Int? = try {
        val ctx = context ?: return null
        val info: WifiInfo? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val net = cm?.activeNetwork
            cm?.getNetworkCapabilities(net)?.transportInfo as? WifiInfo
        } else {
            (ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.connectionInfo
        }
        info?.frequency?.takeIf { it > 0 }
    } catch (_: RuntimeException) {
        null
    }
}
