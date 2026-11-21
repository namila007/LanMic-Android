// Phone capture: Oboe low-latency input -> SPSC FrameQueue -> sender thread (gate, AUDIO packet, sendto).
// The input callback only copies and publishes; everything else runs on the sender thread.
#pragma once
#include <semaphore.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <netinet/in.h>
#include <oboe/Oboe.h>

#include "frame_queue.h"
#include "gain.h"
#include "noise_gate.h"

namespace lanmic {

// Index order of the capture stats array; must match NativeAudio.kt (CAPTURE_STATS_SIZE = 17).
enum CaptureStatIndex {
    kCapCapturing, kCapInputLatencyMs,  // -1 unknown
    kCapFramesCaptured, kCapFramesSent, kCapFramesDropped, kCapSendErrors,
    kCapSendGapMaxMs,                   // max gap between consecutive sends in the last second; -1 none
    kCapLevelRmsPermille,
    kCapGateOpenFrames, kCapGateFrames, kCapGateMinDbX10, kCapGateMaxDbX10,  // gate fields reset on read
    kCapMmap,                           // 0/1, -1 unknown
    kCapExclusive, kCapBurst, kCapXruns,
    kCapLimitedPermille,                // share of samples the gain limiter touched since the last read
    kCapStatsSize
};

constexpr int kCaptureOk = 0, kCaptureOpenFailed = -1, kCaptureFormatUnsupported = -2;

class AudioIn : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
public:
    static AudioIn& instance();

    int start();  // idempotent; 0 ok, else a negative code
    void stop();  // synchronous: input closed, every queued frame sent, sender joined
    void setTarget(const char* ipv4, int port, int pin);  // null/invalid clears
    void setGainDb(int db) { gain_.setDb(db); }  // Mic boost
    void setSendFd(int fd);  // takes ownership of the dup; closes the one it replaces
    void stats(int64_t* out);  // JNI thread, never the callback

    // Real-time: copies into the queue and posts a semaphore. Nothing else.
    oboe::DataCallbackResult onAudioReady(oboe::AudioStream*, void* audioData, int32_t numFrames) override;
    void onErrorAfterClose(oboe::AudioStream*, oboe::Result error) override;

private:
    AudioIn() = default;
    int openStream();  // streamMu_ must be held
    void closeStream();
    void senderMain();
    void maybeReopen();
    void waitForFrame();

    std::shared_ptr<AudioIn> self_;  // oboe wants shared_ptr callbacks

    std::mutex lifeMu_;  // serialises start()/stop()
    std::thread sender_;
    bool running_ = false;  // lifeMu_
    std::atomic<bool> capturing_{false};
    std::atomic<bool> stopping_{false};
    std::atomic<bool> reopen_{false};
    sem_t sem_;
    bool semInit_ = false;

    std::mutex streamMu_;  // guards stream_ and calls on it; the callback never takes it
    std::shared_ptr<oboe::AudioStream> stream_;

    FrameQueue queue_;
    FrameAssembler assembler_;  // callback thread only
    GainState gain_;            // sender thread applies, any thread sets
    NoiseGate gate_;            // sender thread only (stats read under gateMu_)
    std::mutex gateMu_;

    std::mutex sendMu_;  // guards target and fd; held across sendto so a swap can close the old fd safely
    bool hasTarget_ = false;
    sockaddr_in target_{};
    uint32_t pin_ = 0;
    int fd_ = -1;
    uint32_t seq_ = 0;  // process-wide: continues across bursts and reopens

    std::atomic<uint64_t> framesCaptured_{0}, framesSent_{0}, sendErrors_{0};
    std::atomic<int64_t> gapMaxMs_{-1}, lastSendNs_{0};
    std::atomic<int> levelPermille_{0};
    std::atomic<int> mmap_{-1}, exclusive_{0}, burst_{0};
    std::atomic<int64_t> cachedLatency_{-1};
    std::atomic<int> cachedXruns_{0};
    int64_t reopenAtNs_ = 0, backoffNs_ = 100'000'000;  // sender thread only
};

}  // namespace lanmic
