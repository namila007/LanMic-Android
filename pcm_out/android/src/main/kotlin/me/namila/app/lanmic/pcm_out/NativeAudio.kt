package me.namila.app.lanmic.pcm_out

import java.nio.ByteBuffer

/** JNI entry points of liblanmic_audio. */
object NativeAudio {
    init {
        System.loadLibrary("lanmic_audio")
    }

    /**
     * Index order of [nativeStats] (matches StatIndex in audio_out.h): received, played, lost, discarded,
     * late, depthMs, targetMs, jitterMs, lastAudioAgeMs (-1 never), latencyMs (-1 unknown), open (0/1),
     * exclusive (0/1), mmap (0/1, -1 unknown), burst, bufferFrames, xruns, limitedPermille.
     */
    const val STATS_SIZE = 17

    external fun nativeVersion(): Int
    external fun nativeStart()
    external fun nativeStop()

    /** [buf] must be a direct ByteBuffer holding one 960-byte frame at position 0. */
    external fun nativePush(buf: ByteBuffer, seq: Int, nowNs: Long)
    external fun nativeFlush()
    external fun nativeStats(out: LongArray)

    /**
     * Index order of [nativeCaptureStats] (matches CaptureStatIndex in audio_in.h): capturing (0/1),
     * inputLatencyMs (-1 unknown), framesCaptured, framesSent, framesDropped, sendErrors, sendGapMaxMs
     * (last 1 s, -1 none), levelRmsPermille, gateOpenFrames, gateFrames, gateMinDbX10, gateMaxDbX10
     * (the gate fields reset on read), mmap (0/1, -1 unknown), exclusive (0/1), burst, xruns,
     * limitedPermille (resets on read).
     */
    const val CAPTURE_STATS_SIZE = 17

    /** 0 ok, -1 open failed, -2 format unsupported. Phone only. */
    external fun nativeCaptureStart(): Int

    /** Synchronous: returns after every queued frame was sent, so END can follow safely. */
    external fun nativeCaptureStop()

    /** Native sends audio only while capturing and a target is set. A null [host] clears the target. */
    external fun nativeSetTarget(host: String?, port: Int, pin: Int)

    /** Hands over a dup of the UDP socket fd; native owns it and closes it on the next swap. */
    external fun nativeSetSendFd(fd: Int)
    external fun nativeCaptureStats(out: LongArray)

    /** Mic boost / Voice volume, -12..+12 dB; ramped over 10 ms natively. */
    external fun nativeSetCaptureGainDb(db: Int)
    external fun nativeSetPlaybackGainDb(db: Int)
}
