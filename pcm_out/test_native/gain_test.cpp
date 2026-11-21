// Host tests for the shared voice gain + soft limiter (phone Mic boost, TV Voice volume).
// No framework: a failed assert aborts.
#undef NDEBUG
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "gain.h"

using namespace lanmic;

namespace {
constexpr int kN = 480;  // one 10 ms frame

void fill(int16_t* f, int16_t v) { for (int i = 0; i < kN; ++i) f[i] = v; }
// Settles the 10 ms ramp after a gain change.
void settle(GainState& g) { int16_t f[kN]; fill(f, 0); applyGain(f, kN, g); }

void zero_db_is_bit_exact_even_at_full_scale() {
    GainState g;
    int16_t f[kN];
    for (int i = 0; i < kN; ++i) f[i] = int16_t(i % 2 ? 32767 : -32768 + i);
    int16_t ref[kN];
    for (int i = 0; i < kN; ++i) ref[i] = f[i];
    applyGain(f, kN, g);
    for (int i = 0; i < kN; ++i) assert(f[i] == ref[i]);
    assert(g.takeLimitedPermille() == 0);
}

void plus6_doubles_quiet_samples() {
    GainState g;
    g.setDb(6);
    settle(g);
    int16_t f[kN];
    fill(f, 1000);
    applyGain(f, kN, g);
    assert(std::abs(f[kN - 1] - 1995) <= 2);  // 10^(6/20) = 1.995
}

void minus12_is_about_a_quarter() {
    GainState g;
    g.setDb(-12);
    settle(g);
    int16_t f[kN];
    fill(f, 10000);
    applyGain(f, kN, g);
    assert(std::abs(f[kN - 1] - 2512) <= 3);  // 10^(-12/20) = 0.2512
}

void plus12_full_scale_sine_never_clips_and_counts_limited() {
    GainState g;
    g.setDb(12);
    settle(g);
    g.takeLimitedPermille();
    int16_t f[kN];
    for (int i = 0; i < kN; ++i) f[i] = int16_t(std::lround(32767 * std::sin(2 * M_PI * 440 * i / 48000.0)));
    applyGain(f, kN, g);
    for (int i = 0; i < kN; ++i) assert(f[i] <= 32767 && f[i] >= -32767);
    assert(g.takeLimitedPermille() > 20);
    assert(g.takeLimitedPermille() == 0);  // reset on read
}

void limiter_is_monotonic() {
    GainState g;
    g.setDb(12);
    settle(g);
    int16_t prev = 0;
    for (int v = 0; v <= 32767; v += 97) {
        int16_t f[1] = {int16_t(v)};
        applyGain(f, 1, g);
        assert(f[0] >= prev);
        prev = f[0];
    }
}

void gain_change_ramps_over_one_frame() {
    GainState g;
    settle(g);
    g.setDb(12);
    int16_t f[kN];
    fill(f, 1000);
    applyGain(f, kN, g);
    // Ramps 1000 -> ~3981 across the frame: rises every few samples, never jumps.
    assert(f[0] < 1100);
    assert(std::abs(f[kN - 1] - 3981) <= 4);
    for (int i = 1; i < kN; ++i) assert(f[i] >= f[i - 1] && f[i] - f[i - 1] <= 10);
}

void negative_gain_never_limits() {
    GainState g;
    g.setDb(-1);
    settle(g);
    g.takeLimitedPermille();
    int16_t f[kN];
    fill(f, 32767);
    applyGain(f, kN, g);
    assert(std::abs(f[kN - 1] - 29204) <= 2);  // a plain multiply: 10^(-1/20) = 0.8913
    assert(g.takeLimitedPermille() == 0);
}

void minus32768_with_boost_stays_in_range() {
    GainState g;
    g.setDb(12);
    settle(g);
    int16_t f[kN];
    fill(f, -32768);
    applyGain(f, kN, g);
    for (int i = 0; i < kN; ++i) assert(f[i] >= -32767 && f[i] <= 0);
}

void retarget_mid_ramp_has_no_jump() {
    GainState g;
    settle(g);
    g.setDb(12);
    int16_t a[kN / 2], b[kN];
    for (auto& v : a) v = 1000;
    for (auto& v : b) v = 1000;
    applyGain(a, kN / 2, g);  // halfway up the ramp
    g.setDb(-12);
    applyGain(b, kN, g);
    int prev = a[kN / 2 - 1];
    for (int i = 0; i < kN; ++i) {
        assert(std::abs(b[i] - prev) <= 10);  // the ramp turns around without a step
        prev = b[i];
    }
}

void set_db_clamps_to_plus_minus_12() {
    GainState g;
    g.setDb(40);
    assert(g.db() == 12);
    g.setDb(-40);
    assert(g.db() == -12);
}
}  // namespace

int main() {
    zero_db_is_bit_exact_even_at_full_scale();
    plus6_doubles_quiet_samples();
    minus12_is_about_a_quarter();
    plus12_full_scale_sine_never_clips_and_counts_limited();
    limiter_is_monotonic();
    gain_change_ramps_over_one_frame();
    negative_gain_never_limits();
    minus32768_with_boost_stays_in_range();
    retarget_mid_ramp_has_no_jump();
    set_db_clamps_to_plus_minus_12();
    std::puts("gain_test: all passed");
}
