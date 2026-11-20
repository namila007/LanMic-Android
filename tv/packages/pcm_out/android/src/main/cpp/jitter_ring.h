// Single-producer / single-consumer jitter ring for 10 ms mono PCM16 frames.
// Pure C++ (no Android headers) so it can be tested on the host. Time is always passed in.
#pragma once
#include <atomic>
#include <cstdint>

namespace lanmic {

constexpr int kSlots = 16;
constexpr int kFrameSamples = 480;
constexpr int64_t kNever = INT64_MIN;

struct RingCounters {
    uint64_t received, played, lost, discarded, late;
    int32_t depthFrames, targetFrames, jitterMs;
    int64_t lastPushNs;  // kNever until the first push
};

class JitterRing {
public:
    JitterRing();

    // Producer thread only.
    void push(const int16_t* pcm480, uint32_t seq, int64_t nowNs);
    // Consumer thread only (the audio callback). Always fills `frames` samples. No locks, no allocation.
    void read(int16_t* out, int32_t frames, int64_t nowNs);
    // Any thread: bumps the generation; the consumer and producer reset their own state lazily.
    void flush();
    // Any thread.
    RingCounters counters() const;

private:
    struct Slot {
        std::atomic<uint64_t> tag{0};  // (generation << 32) | seq; 0 = empty (generation starts at 1)
        // Relaxed atomics: the seqlock (tag) detects a torn copy, and per-sample atomics keep the race defined.
        std::atomic<int16_t> pcm[kFrameSamples];
    };
    struct Scan {
        uint32_t present = 0;  // bit k: frame cur+k is present
        int depth = 0;
    };

    static void writeSlot(Slot& s, const int16_t* src, uint64_t tag);
    static bool readSlot(const Slot& s, uint64_t expect, int16_t* dst);
    static bool slotQuiet(const Slot& s);
    static uint64_t makeTag(uint32_t gen, uint32_t seq) { return (uint64_t(gen) << 32) | seq; }
    Scan scan(uint32_t gen, uint32_t cur) const;
    void resetProducer(uint32_t gen);
    bool tryAnchor(uint32_t gen, int target);
    void startFrame(uint32_t gen, int64_t nowNs);
    void playPlc();

    Slot slots_[kSlots];
    std::atomic<uint32_t> gen_{1};
    std::atomic<uint32_t> consNext_{0};     // next seq the consumer will start; written by the consumer
    std::atomic<uint32_t> consGen_{0};      // generation the consumer has caught up with
    std::atomic<bool> waiting_{true};       // consumer is waiting for the target depth
    std::atomic<int32_t> target_{2};
    std::atomic<int32_t> jitterUs_{0};
    std::atomic<int64_t> lastPushNs_{kNever};
    std::atomic<uint64_t> received_{0}, played_{0}, lost_{0}, discarded_{0}, late_{0};

    // Producer-only state.
    uint32_t pGen_ = 0;
    bool pHave_ = false;
    uint32_t pExpected_ = 0;
    uint32_t pCount_ = 0;
    double pJitterMs_ = 0;
    bool pPrev_ = false;
    int64_t pPrevNs_ = 0;
    uint32_t pPrevSeq_ = 0;

    // Consumer-only state.
    uint32_t cGen_ = 0;
    bool cWaiting_ = true;
    uint32_t cNext_ = 0;
    bool cFloorValid_ = false;  // after idle: frames older than cFloor_ are stale
    uint32_t cFloor_ = 0;
    bool cHave_ = false;
    int cPos_ = 0;
    int16_t cur_[kFrameSamples];
    int16_t lastGood_[kFrameSamples];
    bool haveGood_ = false;
    int plcRun_ = 0;
    int64_t aboveSinceNs_ = kNever;
    bool skipValid_ = false;
    uint32_t skipSeq_ = 0;
};

}  // namespace lanmic
