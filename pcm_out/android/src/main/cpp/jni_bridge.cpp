#include <jni.h>

#include "audio_in.h"
#include "audio_out.h"

using lanmic::AudioIn;
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

// 0 ok, -1 open failed, -2 format unsupported.
JNIEXPORT jint JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeCaptureStart(JNIEnv*, jobject) {
    return AudioIn::instance().start();
}

// Synchronous: returns after every queued frame has been sent.
JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeCaptureStop(JNIEnv*, jobject) {
    AudioIn::instance().stop();
}

// host: IPv4 literal; null clears the target.
JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeSetTarget(
    JNIEnv* env, jobject, jstring host, jint port, jint pin) {
    if (host == nullptr) {
        AudioIn::instance().setTarget(nullptr, 0, 0);
        return;
    }
    const char* h = env->GetStringUTFChars(host, nullptr);
    if (h == nullptr) return;
    AudioIn::instance().setTarget(h, port, pin);
    env->ReleaseStringUTFChars(host, h);
}

JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeSetSendFd(JNIEnv*, jobject, jint fd) {
    AudioIn::instance().setSendFd(fd);
}

// out: LongArray(16), layout = lanmic::CaptureStatIndex in audio_in.h.
JNIEXPORT void JNICALL Java_me_namila_app_lanmic_pcm_1out_NativeAudio_nativeCaptureStats(
    JNIEnv* env, jobject, jlongArray out) {
    if (out == nullptr || env->GetArrayLength(out) < lanmic::kCapStatsSize) return;
    int64_t v[lanmic::kCapStatsSize];
    AudioIn::instance().stats(v);
    env->SetLongArrayRegion(out, 0, lanmic::kCapStatsSize, reinterpret_cast<const jlong*>(v));
}

}  // extern "C"
