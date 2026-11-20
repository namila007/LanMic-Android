package me.namila.app.lanmic.pcm_out

import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.EventChannel
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

private const val MAGIC_LO = 0x54
private const val MAGIC_HI = 0x4D
private const val VERSION = 1
private const val TYPE_AUDIO = 0
private const val TYPE_END = 3
private const val HEADER = 12
private const val FRAME_BYTES = 960
private const val MAX_DATAGRAM = 972
private const val DSCP_EF = 0xB8
private const val MAX_CONTROL_BYTES = 64
private const val MAX_CONTROL_PER_SECOND = 20
private const val MAX_ACCEPTED_CONTROL_PER_SECOND = 50

/** The phone whose audio is accepted: sender address, port and the PIN in the header. */
private class Accepted(val address: InetAddress, val port: Int, val pin: Int)

/**
 * Process singleton that owns UDP port 5004. Valid AUDIO from the accepted phone goes straight into the
 * native ring; every other valid packet is posted to Dart. Only explicit start/stop change it.
 */
object NativeReceiver {
    private val main = Handler(Looper.getMainLooper())
    private var thread: Thread? = null
    // One flag per receive thread: a stale thread (stopped, or still in a backoff sleep) sees its own flag
    // go false and exits, so a stop -> start can never leave two threads fighting over the port.
    private var alive: AtomicBoolean? = null
    @Volatile private var socket: DatagramSocket? = null
    @Volatile private var accepted: Accepted? = null
    @Volatile var sink: EventChannel.EventSink? = null

    // Non-AUDIO packets forwarded to the main thread: small and rate-limited so a flood cannot swamp it.
    private var windowStartNs = 0L
    private var windowCount = 0
    private var acceptedWindowNs = 0L
    private var acceptedCount = 0

    @Synchronized
    fun start(port: Int) {
        if (alive?.get() == true) return
        val flag = AtomicBoolean(true)
        alive = flag
        thread = Thread({ run(port, flag) }, "lanmic-udp").also { it.start() }
    }

    fun stop() {
        val t = synchronized(this) { // not held while joining: the thread's exit path takes it too
            alive?.set(false)
            alive = null
            thread.also { thread = null }
        }
        socket?.close()
        t?.interrupt() // ends a backoff sleep at once
        t?.join(1000)
    }

    /** Null host accepts nobody. Flushes the ring when the accepted phone changes. */
    fun accept(host: String?, port: Int?, pin: Int?) {
        val next = if (host == null || port == null || pin == null) null
        else Accepted(InetAddress.getByName(host), port, pin) // IP literal: no DNS lookup
        val prev = accepted
        accepted = next
        val same = prev != null && next != null && prev.address == next.address && prev.port == next.port && prev.pin == next.pin
        if (!same) NativeAudio.nativeFlush()
    }

    /** Sends from the bound socket so the phone sees replies from port 5004. Throws IOException. */
    fun send(data: ByteArray, host: String, port: Int) {
        val s = socket ?: throw IOException("socket not bound")
        s.send(DatagramPacket(data, data.size, InetAddress.getByName(host), port))
    }

    private fun event(vararg kv: Pair<String, Any?>) {
        val m = mapOf(*kv)
        main.post { sink?.success(m) }
    }

    private fun run(port: Int, alive: AtomicBoolean) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buf = ByteArray(MAX_DATAGRAM + 1) // one spare byte so an oversize datagram is detected
        val pkt = DatagramPacket(buf, buf.size)
        val direct = ByteBuffer.allocateDirect(FRAME_BYTES)
        var backoffMs = 1000L
        try {
            while (alive.get()) {
                val s = try {
                    // No reuseAddress: a busy port (an old socket not yet gone) just retries with backoff.
                    DatagramSocket(null).apply {
                        trafficClass = DSCP_EF
                        soTimeout = 200 // wakes the loop so stop() ends it promptly
                        bind(InetSocketAddress(port))
                    }
                } catch (e: IOException) {
                    event("event" to "error", "message" to "bind failed: ${e.message}")
                    if (!sleep(backoffMs)) break
                    backoffMs = minOf(backoffMs * 2, 5000L) // boot before Wi-Fi: 1, 2, 4, 5 s
                    continue
                }
                if (!alive.get()) { s.close(); break }
                socket = s
                backoffMs = 1000L
                event("event" to "bound", "message" to "port $port")
                while (alive.get()) {
                    try {
                        pkt.length = buf.size
                        s.receive(pkt)
                        handle(buf, pkt, direct)
                    } catch (_: SocketTimeoutException) {
                        continue
                    } catch (e: IOException) {
                        if (alive.get()) event("event" to "error", "message" to "receive failed: ${e.message}")
                        break
                    } catch (e: Throwable) { // a bad packet must not kill the thread
                        event("event" to "error", "message" to "packet failed: $e")
                    }
                }
                socket = null
                s.close()
                if (alive.get() && !sleep(backoffMs)) break // no tight rebind loop after a receive failure
            }
        } catch (e: Throwable) {
            event("event" to "error", "message" to "receiver died: $e")
        } finally {
            socket?.close()
            socket = null
            synchronized(this) { if (this.alive === alive) this.alive = null } // lets start() relaunch it
        }
    }

    /** False if interrupted (stop). */
    private fun sleep(ms: Long): Boolean = try { Thread.sleep(ms); true } catch (_: InterruptedException) { false }

    private fun handle(b: ByteArray, p: DatagramPacket, direct: ByteBuffer) {
        val n = p.length
        if (n < HEADER || n > MAX_DATAGRAM) return
        if ((b[0].toInt() and 0xFF) != MAGIC_LO || (b[1].toInt() and 0xFF) != MAGIC_HI || b[2].toInt() != VERSION) return
        val type = b[3].toInt() and 0xFF
        val acc = accepted
        val fromAccepted = acc != null && p.port == acc.port && p.address == acc.address &&
            le32(b, 8) == acc.pin
        when (type) {
            TYPE_AUDIO -> {
                // AUDIO never goes to Dart: a stray or wrong-PIN sender is dropped here.
                if (n != MAX_DATAGRAM || !fromAccepted) return
                direct.position(0)
                direct.put(b, HEADER, FRAME_BYTES)
                NativeAudio.nativePush(direct, le32(b, 4), System.nanoTime())
            }
            TYPE_END -> {
                if (fromAccepted) NativeAudio.nativeFlush()
                post(b, n, p, fromAccepted)
            }
            else -> post(b, n, p, fromAccepted)
        }
    }

    /**
     * Two per-second windows, no allocation: packets that match the accepted phone (address, port and PIN)
     * get their own, higher cap so a flood from other senders cannot starve its HELLO/END; a spoofed
     * source address alone does not earn it, and even the accepted path is capped.
     */
    private fun post(b: ByteArray, n: Int, p: DatagramPacket, fromAccepted: Boolean) {
        if (n > MAX_CONTROL_BYTES) return
        val now = System.nanoTime()
        if (fromAccepted) {
            if (now - acceptedWindowNs >= 1_000_000_000L) { acceptedWindowNs = now; acceptedCount = 0 }
            if (++acceptedCount > MAX_ACCEPTED_CONTROL_PER_SECOND) return
        } else {
            if (now - windowStartNs >= 1_000_000_000L) { windowStartNs = now; windowCount = 0 }
            if (++windowCount > MAX_CONTROL_PER_SECOND) return
        }
        val m = mapOf("data" to b.copyOf(n), "host" to p.address.hostAddress, "port" to p.port)
        main.post { sink?.success(m) }
    }

    private fun le32(b: ByteArray, o: Int): Int =
        (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8) or
            ((b[o + 2].toInt() and 0xFF) shl 16) or ((b[o + 3].toInt() and 0xFF) shl 24)
}
