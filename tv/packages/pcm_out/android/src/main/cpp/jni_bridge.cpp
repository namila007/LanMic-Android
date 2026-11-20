#include <jni.h>

#include "audio_out.h"

using lanmic::AudioOut;

extern "C" {

JNIEXPORT jint JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeVersion(JNIEnv*, jobject) {
    return 1;
}

JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeStart(JNIEnv*, jobject) {
    AudioOut::instance().start();
}

JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeStop(JNIEnv*, jobject) {
    AudioOut::instance().stop();
}

// buf: direct ByteBuffer holding 960 bytes of PCM16 LE (native byte order on every Android ABI).
JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativePush(
    JNIEnv* env, jobject, jobject buf, jint seq, jlong nowNs) {
    if (buf == nullptr) return;
    void* p = env->GetDirectBufferAddress(buf);
    if (p == nullptr || env->GetDirectBufferCapacity(buf) < lanmic::kFrameSamples * 2) return;
    AudioOut::instance().push(static_cast<const int16_t*>(p), static_cast<uint32_t>(seq), nowNs);
}

JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeFlush(JNIEnv*, jobject) {
    AudioOut::instance().flush();
}

// out: LongArray(16), layout = lanmic::StatIndex in audio_out.h.
JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeStats(
    JNIEnv* env, jobject, jlongArray out) {
    if (out == nullptr || env->GetArrayLength(out) < lanmic::kStatsSize) return;
    int64_t v[lanmic::kStatsSize];
    AudioOut::instance().stats(v);
    env->SetLongArrayRegion(out, 0, lanmic::kStatsSize, reinterpret_cast<const jlong*>(v));
}

}  // extern "C"
