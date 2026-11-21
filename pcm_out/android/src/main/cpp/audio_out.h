// Oboe low-latency output pulling from a JitterRing, with a manager thread that owns open/close.
#pragma once
#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <oboe/Oboe.h>

#include "gain.h"
#include "jitter_ring.h"

namespace lanmic {

// Index order of the stats array; must match NativeAudio.kt (STATS_SIZE = 17).
enum StatIndex {
    kReceived, kPlayed, kLost, kDiscarded, kLate, kDepthMs, kTargetMs, kJitterMs,
    kLastAudioAgeMs,  // -1 if never
    kLatencyMs,       // -1 unknown
    kOpen, kExclusive,
    kMmap,            // 0/1, -1 unknown
    kBurst, kBufferFrames, kXruns,
    kLimitedPermille,  // share of samples the gain limiter touched since the last read
    kStatsSize
};

int64_t monotonicNs();

class AudioOut : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
public:
    static AudioOut& instance();

    void start();  // idempotent
    void stop();   // idempotent
    void push(const int16_t* pcm480, uint32_t seq, int64_t nowNs);
    void flush() { ring_.flush(); }
    void setGainDb(int db) { gain_.setDb(db); }  // Voice volume
    void stats(int64_t* out);  // kStatsSize values; called from a JNI thread, never the audio callback

    // Real-time: reads atomics and the ring only.
    oboe::DataCallbackResult onAudioReady(oboe::AudioStream*, void* audioData, int32_t numFrames) override;
    void onErrorAfterClose(oboe::AudioStream*, oboe::Result error) override;

private:
    AudioOut() = default;
    void managerLoop();
    bool openStream();
    void closeStream();
    void wake();

    JitterRing ring_;
    GainState gain_;
    std::shared_ptr<AudioOut> self_;  // oboe wants shared_ptr callbacks

    std::mutex lifeMu_;  // serialises start()/stop() (including the join) so a quick stop -> start cannot overlap
    std::mutex mu_;      // manager thread only (cv wait); the callback never touches it
    std::condition_variable cv_;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> wantOpen_{false};
    std::atomic<bool> reopen_{false};

    std::mutex streamMu_;  // guards stream_ and every call on it (open/close vs stats()); the audio callback must never take it
    std::shared_ptr<oboe::AudioStream> stream_;

    // Written by the manager before requestStart(), read by the callback.
    std::vector<int16_t> scratch_;
    int channels_ = 1;
    bool isFloat_ = false;

    std::atomic<bool> open_{false};
    std::atomic<bool> exclusive_{false};
    std::atomic<int> mmap_{-1};
    std::atomic<int> burst_{0};
    // Last values read from the stream; stats() serves these when the manager holds streamMu_ (close can be slow).
    std::atomic<int> cachedBuffer_{0}, cachedXruns_{0};
    std::atomic<int64_t> cachedLatency_{-1};
};

}  // namespace lanmic
