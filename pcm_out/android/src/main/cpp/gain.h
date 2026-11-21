// Voice gain (-12..+12 dB) with a 10 ms ramp on change and a soft limiter. Shared by the phone's capture sender
// (Mic boost) and the TV's output callback (Voice volume). Pure C++, no allocation, no locks.
#pragma once
#include <atomic>
#include <cstdint>

namespace lanmic {

constexpr int kMaxGainDb = 12;

class GainState {
public:
    GainState();

    void setDb(int db);  // any thread; clamped to +-12
    int db() const { return db_.load(std::memory_order_relaxed); }
    // Share of samples the limiter touched since the last call, in permille. Resets on read.
    uint32_t takeLimitedPermille();

private:
    friend void applyGain(int16_t*, int32_t, GainState&);

    float lin_[2 * kMaxGainDb + 1];  // 10^(dB/20), built once so no pow() runs in the audio thread
    std::atomic<int> db_{0};
    std::atomic<uint32_t> limited_{0}, total_{0};
    // Audio thread only.
    int seenDb_ = 0;
    float cur_ = 1.0f, step_ = 0.0f;
    int rampLeft_ = 0;
};

// In place. Gain 1.0 with no ramp running is a bit-exact passthrough.
void applyGain(int16_t* samples, int32_t n, GainState& g);

}  // namespace lanmic
