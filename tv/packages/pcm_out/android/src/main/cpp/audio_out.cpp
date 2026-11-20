#include "audio_out.h"

#include <android/log.h>

#include <algorithm>
#include <chrono>
#include <cmath>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "lanmic_audio", __VA_ARGS__)

namespace lanmic {
namespace {
constexpr int64_t kKeepOpenNs = 10'000'000'000;  // close after 10 s without a push
constexpr int kSampleRate = 48000;
}  // namespace

int64_t monotonicNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

AudioOut& AudioOut::instance() {
    static AudioOut* a = [] {  // never destroyed: the callback thread may outlive static teardown
        auto* p = new AudioOut();
        p->self_.reset(p, [](AudioOut*) {});
        return p;
    }();
    return *a;
}

void AudioOut::start() {
    std::lock_guard<std::mutex> life(lifeMu_);
    if (running_.exchange(true)) return;
    thread_ = std::thread([this] { managerLoop(); });
}

void AudioOut::stop() {
    std::lock_guard<std::mutex> life(lifeMu_);
    if (!running_.exchange(false)) return;
    cv_.notify_all();
    if (thread_.joinable()) thread_.join();
    wantOpen_.store(false);
    reopen_.store(false);
    closeStream();
    ring_.flush();
}

void AudioOut::wake() { cv_.notify_one(); }  // no lock: the manager also polls every 100 ms

void AudioOut::push(const int16_t* pcm, uint32_t seq, int64_t nowNs) {
    ring_.push(pcm, seq, nowNs);
    if (!open_.load(std::memory_order_relaxed) && !wantOpen_.exchange(true)) wake();
}

void AudioOut::managerLoop() {
    constexpr int64_t kMinBackoffNs = 100'000'000, kMaxBackoffNs = 2'000'000'000;
    bool retry = false;
    int64_t backoffNs = kMinBackoffNs, nextTryNs = 0;
    while (running_.load()) {
        {
            std::unique_lock<std::mutex> lk(mu_);
            cv_.wait_for(lk, std::chrono::milliseconds(100), [this] {
                return !running_.load() || wantOpen_.load() || reopen_.load();
            });
        }
        if (!running_.load()) break;
        const int64_t now = monotonicNs();
        const int64_t lastPush = ring_.counters().lastPushNs;
        const bool recent = lastPush != kNever && now - lastPush < kKeepOpenNs;
        if (open_.load()) {
            wantOpen_.store(false);  // stale request from a push that raced the open; avoids a spin
            retry = false;
            if (reopen_.exchange(false)) {
                closeStream();
                retry = recent;
                nextTryNs = 0;
            } else if (!recent) {
                closeStream();
            }
        } else {
            if (wantOpen_.exchange(false) | reopen_.exchange(false)) retry = true;
        }
        if (!open_.load() && retry) {
            if (!recent) {
                retry = false;
            } else if (now >= nextTryNs) {
                if (openStream()) {
                    retry = false;
                    backoffNs = kMinBackoffNs;
                } else {  // failed open: back off 100 ms, doubling up to 2 s
                    nextTryNs = now + backoffNs;
                    backoffNs = std::min(backoffNs * 2, kMaxBackoffNs);
                }
            }
        }
    }
}

bool AudioOut::openStream() {
    oboe::AudioStreamBuilder b;
    b.setDirection(oboe::Direction::Output)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setSampleRate(kSampleRate)  // format and channel count stay unspecified: keep the fast path
        ->setUsage(oboe::Usage::Media)
        ->setContentType(oboe::ContentType::Speech)
        ->setDataCallback(self_)
        ->setErrorCallback(self_);
    std::shared_ptr<oboe::AudioStream> s;
    oboe::Result r = b.openStream(s);
    if (r != oboe::Result::OK) {
        LOGI("open failed: %s", oboe::convertToText(r));
        return false;
    }
    const int burst = s->getFramesPerBurst();
    s->setBufferSizeInFrames(2 * burst);
    channels_ = std::max(1, s->getChannelCount());
    isFloat_ = s->getFormat() == oboe::AudioFormat::Float;
    scratch_.assign(size_t(std::max(burst * 4, 4096)), 0);
    mmap_.store(oboe::OboeExtensions::isMMapUsed(s.get()) ? 1 : 0);
    exclusive_.store(s->getSharingMode() == oboe::SharingMode::Exclusive);
    burst_.store(burst);
    LOGI("open api=%s sharing=%s perf=%s burst=%d buffer=%d capacity=%d rate=%d ch=%d fmt=%s mmap=%d",
         oboe::convertToText(s->getAudioApi()), oboe::convertToText(s->getSharingMode()),
         oboe::convertToText(s->getPerformanceMode()), burst, s->getBufferSizeInFrames(),
         s->getBufferCapacityInFrames(), s->getSampleRate(), channels_,
         oboe::convertToText(s->getFormat()), mmap_.load());
    {
        std::lock_guard<std::mutex> lk(streamMu_);
        stream_ = s;
    }
    open_.store(true);
    r = s->requestStart();
    if (r != oboe::Result::OK) {
        LOGI("start failed: %s", oboe::convertToText(r));
        reopen_.store(true);
    }
    return true;
}

void AudioOut::closeStream() {
    std::lock_guard<std::mutex> lk(streamMu_);  // stats() must not query a stream that is closing
    open_.store(false);
    if (stream_) stream_->close();
    stream_.reset();
}

oboe::DataCallbackResult AudioOut::onAudioReady(oboe::AudioStream*, void* audioData, int32_t numFrames) {
    const int64_t now = monotonicNs();
    const int ch = channels_;
    const int32_t cap = int32_t(scratch_.size());
    int16_t* i16 = static_cast<int16_t*>(audioData);
    float* f32 = static_cast<float*>(audioData);
    for (int32_t done = 0; done < numFrames;) {
        const int32_t n = std::min(numFrames - done, cap);
        ring_.read(scratch_.data(), n, now);
        for (int32_t i = 0; i < n; ++i) {
            const int16_t v = scratch_[size_t(i)];
            const size_t o = size_t(done + i) * size_t(ch);
            if (isFloat_) {
                const float f = float(v) * (1.0f / 32768.0f);
                for (int c = 0; c < ch; ++c) f32[o + size_t(c)] = f;
            } else {
                for (int c = 0; c < ch; ++c) i16[o + size_t(c)] = v;
            }
        }
        done += n;
    }
    return oboe::DataCallbackResult::Continue;
}

void AudioOut::onErrorAfterClose(oboe::AudioStream*, oboe::Result error) {
    (void)error;  // any error closed the stream: the manager reopens it if audio is still arriving
    reopen_.store(true);
    wake();
}

void AudioOut::stats(int64_t* out) {
    const RingCounters c = ring_.counters();
    const int64_t now = monotonicNs();
    out[kReceived] = int64_t(c.received);
    out[kPlayed] = int64_t(c.played);
    out[kLost] = int64_t(c.lost);
    out[kDiscarded] = int64_t(c.discarded);
    out[kLate] = int64_t(c.late);
    out[kDepthMs] = int64_t(c.depthFrames) * 10;
    out[kTargetMs] = int64_t(c.targetFrames) * 10;
    out[kJitterMs] = c.jitterMs;
    out[kLastAudioAgeMs] = c.lastPushNs == kNever ? -1 : (now - c.lastPushNs) / 1'000'000;
    // The manager holds streamMu_ across a (possibly slow) close(): serve cached values instead of waiting.
    std::unique_lock<std::mutex> lk(streamMu_, std::try_to_lock);
    if (!lk.owns_lock()) {
        out[kOpen] = open_.load() ? 1 : 0;
        out[kExclusive] = exclusive_.load() ? 1 : 0;
        out[kMmap] = open_.load() ? mmap_.load() : -1;
        out[kBurst] = burst_.load();
        out[kBufferFrames] = cachedBuffer_.load();
        out[kLatencyMs] = cachedLatency_.load();
        out[kXruns] = cachedXruns_.load();
        return;
    }
    const std::shared_ptr<oboe::AudioStream>& s = stream_;
    out[kLatencyMs] = -1;
    out[kXruns] = 0;
    out[kOpen] = s ? 1 : 0;
    out[kExclusive] = s && exclusive_.load() ? 1 : 0;
    out[kMmap] = s ? mmap_.load() : -1;
    out[kBurst] = s ? burst_.load() : 0;
    out[kBufferFrames] = s ? s->getBufferSizeInFrames() : 0;
    if (s && s->getState() == oboe::StreamState::Started) {
        auto lat = s->calculateLatencyMillis();  // only here, never in the callback
        if (lat) out[kLatencyMs] = std::llround(lat.value());
        auto x = s->getXRunCount();
        if (x) out[kXruns] = x.value();
    }
    cachedBuffer_.store(int(out[kBufferFrames]));
    cachedLatency_.store(out[kLatencyMs]);
    cachedXruns_.store(int(out[kXruns]));
}

}  // namespace lanmic
