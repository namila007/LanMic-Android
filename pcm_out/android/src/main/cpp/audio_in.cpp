#include "audio_in.h"

#include <android/api-level.h>
#include <android/log.h>
#include <arpa/inet.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#include "audio_packet.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "lanmic_audio", __VA_ARGS__)

namespace lanmic {
namespace {
constexpr int kSampleRate = 48000;
constexpr int64_t kWaitMs = 50;  // sender wake-up when no frame arrives (reopen retries, stop)
constexpr int64_t kMaxBackoffNs = 2'000'000'000;

int64_t nowNs() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return int64_t(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}
}  // namespace

AudioIn& AudioIn::instance() {
    static AudioIn* a = [] {  // never destroyed: the callback thread may outlive static teardown
        auto* p = new AudioIn();
        p->self_.reset(p, [](AudioIn*) {});
        sem_init(&p->sem_, 0, 0);
        p->semInit_ = true;
        return p;
    }();
    return *a;
}

int AudioIn::start() {
    std::lock_guard<std::mutex> life(lifeMu_);
    if (running_) return kCaptureOk;
    int rc;
    stopping_.store(false);
    reopen_.store(false);
    backoffNs_ = 100'000'000;
    reopenAtNs_ = 0;
    {
        std::lock_guard<std::mutex> lk(streamMu_);
        capturing_.store(true);
        assembler_.reset();
        while (sem_trywait(&sem_) == 0) {}
        rc = openStream();
        if (rc != kCaptureOk) capturing_.store(false);
    }
    if (rc != kCaptureOk) return rc;
    sender_ = std::thread([this] { senderMain(); });
    running_ = true;
    return kCaptureOk;
}

void AudioIn::stop() {
    std::lock_guard<std::mutex> life(lifeMu_);
    if (!running_) return;
    capturing_.store(false);  // a pending reopen must not run
    closeStream();            // the input callback has returned for good
    stopping_.store(true, std::memory_order_release);
    sem_post(&sem_);
    if (sender_.joinable()) sender_.join();  // the sender drains the queue before it exits
    running_ = false;
}

void AudioIn::setTarget(const char* ipv4, int port, int pin) {
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(uint16_t(port));
    const bool ok = ipv4 != nullptr && port > 0 && port <= 65535 && inet_pton(AF_INET, ipv4, &a.sin_addr) == 1;
    std::lock_guard<std::mutex> lk(sendMu_);
    hasTarget_ = ok;
    if (ok) target_ = a;
    pin_ = uint32_t(pin);
}

// Departure from spec 7.1: the replaced dup is closed here, under sendMu_ (the sender holds it across
// sendto), not lazily by the sender. Same safety, and no fd leaks while capture is idle.
void AudioIn::setSendFd(int fd) {
    std::lock_guard<std::mutex> lk(sendMu_);
    if (fd_ >= 0 && fd_ != fd) close(fd_);
    fd_ = fd;
}

int AudioIn::openStream() {
    const bool api29 = android_get_device_api_level() >= 29;
    oboe::AudioStreamBuilder b;
    b.setDirection(oboe::Direction::Input)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)  // Oboe falls back to shared if it is not granted
        ->setSampleRate(kSampleRate)
        ->setChannelCount(oboe::ChannelCount::Mono)
        ->setFormat(oboe::AudioFormat::I16)
        ->setChannelConversionAllowed(true)
        ->setFormatConversionAllowed(true)
        ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
        ->setInputPreset(api29 ? oboe::InputPreset::VoicePerformance : oboe::InputPreset::Unprocessed)
        ->setDataCallback(self_)
        ->setErrorCallback(self_);
    std::shared_ptr<oboe::AudioStream> s;
    oboe::Result r = b.openStream(s);
    if (r != oboe::Result::OK && api29) {  // some devices reject VoicePerformance
        LOGI("capture open with VoicePerformance failed: %s; trying Unprocessed", oboe::convertToText(r));
        b.setInputPreset(oboe::InputPreset::Unprocessed);
        r = b.openStream(s);
    }
    if (r != oboe::Result::OK) {
        LOGI("capture open failed: %s", oboe::convertToText(r));
        return kCaptureOpenFailed;
    }
    if (s->getSampleRate() != kSampleRate || s->getChannelCount() != 1 || s->getFormat() != oboe::AudioFormat::I16) {
        LOGI("capture format unsupported: rate=%d ch=%d fmt=%s", s->getSampleRate(), s->getChannelCount(),
             oboe::convertToText(s->getFormat()));
        s->close();
        return kCaptureFormatUnsupported;
    }
    const int burst = s->getFramesPerBurst();
    mmap_.store(oboe::OboeExtensions::isMMapUsed(s.get()) ? 1 : 0);
    exclusive_.store(s->getSharingMode() == oboe::SharingMode::Exclusive ? 1 : 0);
    burst_.store(burst);
    LOGI("capture open api=%s sharing=%s perf=%s preset=%s burst=%d buffer=%d rate=%d ch=%d mmap=%d",
         oboe::convertToText(s->getAudioApi()), oboe::convertToText(s->getSharingMode()),
         oboe::convertToText(s->getPerformanceMode()), oboe::convertToText(s->getInputPreset()), burst,
         s->getBufferSizeInFrames(), s->getSampleRate(), s->getChannelCount(), mmap_.load());
    stream_ = s;
    r = s->requestStart();
    if (r != oboe::Result::OK) {
        LOGI("capture start failed: %s", oboe::convertToText(r));
        reopen_.store(true);
    }
    return kCaptureOk;
}

void AudioIn::closeStream() {
    std::lock_guard<std::mutex> lk(streamMu_);
    if (stream_) stream_->close();  // returns once the data callback is done
    stream_.reset();
    mmap_.store(-1);
}

oboe::DataCallbackResult AudioIn::onAudioReady(oboe::AudioStream*, void* audioData, int32_t numFrames) {
    const int done = assembler_.append(static_cast<const int16_t*>(audioData), numFrames, queue_);
    for (int i = 0; i < done; ++i) sem_post(&sem_);
    if (done) framesCaptured_.fetch_add(uint64_t(done), std::memory_order_relaxed);
    return oboe::DataCallbackResult::Continue;
}

void AudioIn::onErrorAfterClose(oboe::AudioStream*, oboe::Result) {
    reopen_.store(true);  // the sender thread reopens while we are still capturing
    sem_post(&sem_);
}

void AudioIn::waitForFrame() {
    timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);  // sem_timedwait takes an absolute realtime deadline
    ts.tv_nsec += kWaitMs * 1'000'000;
    ts.tv_sec += ts.tv_nsec / 1'000'000'000;
    ts.tv_nsec %= 1'000'000'000;
    sem_timedwait(&sem_, &ts);
}

void AudioIn::maybeReopen() {
    if (!reopen_.load() || !capturing_.load()) return;
    const int64_t now = nowNs();
    if (now < reopenAtNs_) return;
    std::lock_guard<std::mutex> lk(streamMu_);
    if (!capturing_.load()) return;  // stop() won the race
    reopen_.store(false);
    if (stream_) stream_->close();
    stream_.reset();
    if (openStream() == kCaptureOk) {
        backoffNs_ = 100'000'000;
    } else {  // retry with doubling back-off up to 2 s
        reopen_.store(true);
        reopenAtNs_ = now + backoffNs_;
        backoffNs_ = std::min(backoffNs_ * 2, kMaxBackoffNs);
    }
}

void AudioIn::senderMain() {
    setpriority(PRIO_PROCESS, gettid(), -19);  // best effort (ANDROID_PRIORITY_URGENT_AUDIO)
    int64_t prevSendNs = 0, windowStartNs = nowNs(), windowMaxNs = 0;
    senderLoop(
        queue_, stopping_,
        [this] {
            waitForFrame();
            maybeReopen();
        },
        [&](const int16_t* in) {
            int16_t frame[kFrameSamples];
            std::memcpy(frame, in, sizeof frame);
            double sum = 0;
            for (int16_t v : frame) sum += double(v) * v;
            levelPermille_.store(int(std::sqrt(sum / kFrameSamples) / 32768 * 1000 + 0.5), std::memory_order_relaxed);
            {
                std::lock_guard<std::mutex> g(gateMu_);
                gate_.process(frame);
            }
            uint8_t pkt[kAudioPacketBytes];
            bool sent = false;
            {
                std::lock_guard<std::mutex> lk(sendMu_);
                if (hasTarget_ && fd_ >= 0) {
                    buildAudioPacket(pkt, seq_++, pin_, frame);
                    const ssize_t n = sendto(fd_, pkt, sizeof pkt, MSG_DONTWAIT,
                                             reinterpret_cast<const sockaddr*>(&target_), sizeof target_);
                    if (n == ssize_t(sizeof pkt)) framesSent_.fetch_add(1, std::memory_order_relaxed);
                    else sendErrors_.fetch_add(1, std::memory_order_relaxed);
                    sent = true;
                }
            }
            const int64_t now = nowNs();
            if (!sent) { prevSendNs = 0; return; }  // a new send run: no gap against the last one
            if (prevSendNs) windowMaxNs = std::max(windowMaxNs, now - prevSendNs);
            prevSendNs = now;
            lastSendNs_.store(now, std::memory_order_relaxed);
            if (now - windowStartNs >= 1'000'000'000) {
                gapMaxMs_.store(windowMaxNs / 1'000'000, std::memory_order_relaxed);
                windowStartNs = now;
                windowMaxNs = 0;
            }
        });
}

void AudioIn::stats(int64_t* out) {
    const int64_t now = nowNs();
    const int64_t last = lastSendNs_.load(std::memory_order_relaxed);
    out[kCapCapturing] = capturing_.load() ? 1 : 0;
    out[kCapFramesCaptured] = int64_t(framesCaptured_.load());
    out[kCapFramesSent] = int64_t(framesSent_.load());
    out[kCapFramesDropped] = int64_t(queue_.dropped());
    out[kCapSendErrors] = int64_t(sendErrors_.load());
    out[kCapSendGapMaxMs] = (last != 0 && now - last < 1'500'000'000) ? gapMaxMs_.load() : -1;
    out[kCapLevelRmsPermille] = capturing_.load() ? levelPermille_.load() : 0;
    GateStats g;
    {
        std::lock_guard<std::mutex> lk(gateMu_);
        g = gate_.takeStats();
    }
    out[kCapGateOpenFrames] = g.openFrames;
    out[kCapGateFrames] = g.frames;
    out[kCapGateMinDbX10] = std::llround(g.minDb * 10);
    out[kCapGateMaxDbX10] = std::llround(g.maxDb * 10);
    out[kCapExclusive] = exclusive_.load();
    out[kCapBurst] = burst_.load();
    // close() can be slow while the manager holds streamMu_: serve cached values instead of waiting.
    std::unique_lock<std::mutex> lk(streamMu_, std::try_to_lock);
    if (lk.owns_lock() && stream_ && stream_->getState() == oboe::StreamState::Started) {
        auto lat = stream_->calculateLatencyMillis();  // only here, never in the callback
        if (lat) cachedLatency_.store(std::llround(lat.value()));
        auto x = stream_->getXRunCount();
        if (x) cachedXruns_.store(x.value());
    } else if (lk.owns_lock() && !stream_) {
        cachedLatency_.store(-1);
    }
    out[kCapInputLatencyMs] = cachedLatency_.load();
    out[kCapMmap] = mmap_.load();
    out[kCapXruns] = cachedXruns_.load();
}

}  // namespace lanmic
