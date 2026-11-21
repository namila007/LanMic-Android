#include "gain.h"

#include <algorithm>
#include <cmath>

namespace lanmic {
namespace {
constexpr int kRampSamples = 480;                 // 10 ms at 48 kHz
constexpr float kFull = 32767.0f;
constexpr float kKnee = kFull * 0.70794578f;      // -3 dBFS
constexpr float kRoom = kFull - kKnee;
}  // namespace

GainState::GainState() {
    for (int i = 0; i < 2 * kMaxGainDb + 1; ++i) lin_[i] = std::pow(10.0f, float(i - kMaxGainDb) / 20.0f);
}

void GainState::setDb(int db) { db_.store(std::clamp(db, -kMaxGainDb, kMaxGainDb), std::memory_order_relaxed); }

uint32_t GainState::takeLimitedPermille() {
    const uint32_t l = limited_.exchange(0, std::memory_order_relaxed);
    const uint32_t t = total_.exchange(0, std::memory_order_relaxed);
    return t == 0 ? 0 : uint32_t(uint64_t(l) * 1000 / t);
}

void applyGain(int16_t* s, int32_t n, GainState& g) {
    const int want = g.db_.load(std::memory_order_relaxed);
    if (want != g.seenDb_) {  // start (or retarget) a linear ramp to the new gain over the next 10 ms
        g.seenDb_ = want;
        g.step_ = (g.lin_[want + kMaxGainDb] - g.cur_) / float(kRampSamples);
        g.rampLeft_ = kRampSamples;
    }
    const float target = g.lin_[g.seenDb_ + kMaxGainDb];
    if (g.rampLeft_ == 0 && target == 1.0f) return;  // 0 dB: untouched
    uint32_t limited = 0;
    for (int32_t i = 0; i < n; ++i) {
        if (g.rampLeft_ > 0) {
            g.cur_ = --g.rampLeft_ == 0 ? target : g.cur_ + g.step_;
        }
        float v = float(s[i]) * g.cur_;
        const float a = std::fabs(v);
        // Attenuation (gain <= 1) cannot clip: a plain multiply, never limited. Above the knee a rational soft
        // clip (no tanh in the audio thread): monotonic, slope 1 at the knee, always under full scale.
        if (g.cur_ > 1.0f && a > kKnee) {
            ++limited;
            const float u = (a - kKnee) / kRoom;
            v = std::copysign(std::min(kFull, kKnee + kRoom * u / (1.0f + u)), v);
        }
        s[i] = int16_t(std::lround(v));
    }
    // total first: a concurrent read can then never see more limited than total (ratio > 1000)
    g.total_.fetch_add(uint32_t(n), std::memory_order_relaxed);
    g.limited_.fetch_add(limited, std::memory_order_relaxed);
}

}  // namespace lanmic
