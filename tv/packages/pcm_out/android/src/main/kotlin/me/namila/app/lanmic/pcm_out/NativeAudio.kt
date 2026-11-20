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
     * exclusive (0/1), mmap (0/1, -1 unknown), burst, bufferFrames, xruns.
     */
    const val STATS_SIZE = 16

    external fun nativeVersion(): Int
    external fun nativeStart()
    external fun nativeStop()

    /** [buf] must be a direct ByteBuffer holding one 960-byte frame at position 0. */
    external fun nativePush(buf: ByteBuffer, seq: Int, nowNs: Long)
    external fun nativeFlush()
    external fun nativeStats(out: LongArray)
}
