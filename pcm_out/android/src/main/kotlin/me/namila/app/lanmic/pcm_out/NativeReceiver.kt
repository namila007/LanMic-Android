package me.namila.app.lanmic.pcm_out

import android.os.Handler
import android.os.ParcelFileDescriptor
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
    @Volatile private var rebindingSocket: DatagramSocket? = null // rebind() closed exactly this socket on purpose
    @Volatile private var lastBound: String? = null // "port N": replayed to a late listener or a new engine
    private val sleepLock = Object()
    private var wake = false // sleepLock: rebind() during a back-off sleep skips the rest of it

    // Non-AUDIO packets forwarded to the main thread: small and rate-limited so a flood cannot swamp it.
    private var windowStartNs = 0L
    private var windowCount = 0
    private var acceptedWindowNs = 0L
    private var acceptedCount = 0

    @Synchronized
    fun start(port: Int) {
        if (alive?.get() == true) {
            replayBound() // already running: a new engine still has to learn the port
            return
        }
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
        lastBound = null
        // Phone mode: native must not keep sending from a dead socket's dup or to an old target.
        NativeAudio.nativeSetTarget(null, 0, 0)
        NativeAudio.nativeSetSendFd(-1)
    }

    /** Re-emits the last `bound` event, if any (the UI isolate may have subscribed after it fired). */
    fun replayBound() {
        lastBound?.let { event("event" to "bound", "message" to it) }
    }

    /** Closes the socket so the receive loop binds a fresh one at once (a new port when started with 0). */
    fun rebind() {
        val s = socket
        if (s == null) { // between sockets (back-off sleep): bind now
            synchronized(sleepLock) { wake = true; sleepLock.notifyAll() }
            return
        }
        synchronized(this) {
            if (socket !== s) return // already replaced
            rebindingSocket = s
        }
        s.close()
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
                    val sock = DatagramSocket(null).apply {
                        trafficClass = DSCP_EF
                        soTimeout = 200 // wakes the loop so stop() ends it promptly
                        bind(InetSocketAddress(port))
                    }
                    try {
                        // Port 0 = the phone: native audio sends from a dup of this very socket (the TV never
                        // does, or the dup would keep port 5004 busy after a rebind).
                        if (port == 0) {
                            NativeAudio.nativeSetTarget(null, 0, 0) // new source port: the TV must hear a HELLO first
                            val fd = ParcelFileDescriptor.fromDatagramSocket(sock).detachFd()
                            try {
                                NativeAudio.nativeSetSendFd(fd)
                            } catch (e: Throwable) {
                                ParcelFileDescriptor.adoptFd(fd).close() // native never took it
                                throw e
                            }
                        }
                    } catch (e: Exception) {
                        sock.close()
                        throw if (e is IOException) e else IOException(e)
                    }
                    sock
                } catch (e: IOException) {
                    event("event" to "error", "message" to "bind failed: ${e.message}")
                    if (!sleep(backoffMs, alive)) break
                    backoffMs = minOf(backoffMs * 2, 5000L) // boot before Wi-Fi: 1, 2, 4, 5 s
                    continue
                }
                if (!alive.get()) { s.close(); break }
                socket = s
                lastBound = "port ${s.localPort}"
                event("event" to "bound", "message" to lastBound)
                while (alive.get()) {
                    try {
                        pkt.length = buf.size
                        s.receive(pkt)
                        backoffMs = 1000L // only a working socket resets the back-off, not a bind
                        handle(buf, pkt, direct)
                    } catch (_: SocketTimeoutException) {
                        continue
                    } catch (e: IOException) {
                        if (alive.get() && rebindingSocket !== s) event("event" to "error", "message" to "receive failed: ${e.message}")
                        break
                    } catch (e: Throwable) { // a bad packet must not kill the thread
                        event("event" to "error", "message" to "packet failed: $e")
                    }
                }
                socket = null
                s.close()
                if (port == 0) NativeAudio.nativeSetSendFd(-1) // stop sending from the dead socket's dup
                val deliberate = rebindingSocket === s
                if (deliberate) rebindingSocket = null
                if (alive.get() && !deliberate) { // no tight rebind loop after a receive failure
                    if (!sleep(backoffMs, alive)) break
                    backoffMs = minOf(backoffMs * 2, 5000L)
                }
            }
        } catch (e: Throwable) {
            event("event" to "error", "message" to "receiver died: $e")
        } finally {
            socket?.close()
            socket = null
            if (port == 0) NativeAudio.nativeSetSendFd(-1)
            synchronized(this) { if (this.alive === alive) this.alive = null } // lets start() relaunch it
        }
    }

    /** False if stopped (or interrupted); a [rebind] during the sleep ends it early. */
    private fun sleep(ms: Long, alive: AtomicBoolean): Boolean = try {
        synchronized(sleepLock) {
            val end = System.nanoTime() + ms * 1_000_000
            while (!wake && alive.get()) {
                val left = (end - System.nanoTime()) / 1_000_000
                if (left <= 0) break
                sleepLock.wait(left)
            }
            wake = false
        }
        alive.get()
    } catch (_: InterruptedException) { false }

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
