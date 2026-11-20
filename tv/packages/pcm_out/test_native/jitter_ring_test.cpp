// Host tests for JitterRing. No framework: a failed assert aborts the run.
#undef NDEBUG
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

#include "jitter_ring.h"

using namespace lanmic;

namespace {
constexpr int64_t MS = 1'000'000;
constexpr int64_t T0 = 1'000'000'000;  // arbitrary monotonic start

struct Fx {
    JitterRing ring;
    int16_t buf[kFrameSamples];
    void push(uint32_t seq, int16_t v, int64_t nowNs) {
        int16_t f[kFrameSamples];
        for (auto& s : f) s = v;
        ring.push(f, seq, nowNs);
    }
    // Reads one 10 ms frame and returns its first sample (all samples must be equal).
    int16_t readFrame(int64_t nowNs) {
        ring.read(buf, kFrameSamples, nowNs);
        for (int i = 1; i < kFrameSamples; ++i) assert(buf[i] == buf[0]);
        return buf[0];
    }
};

void prebuffers_to_target() {
    Fx f;
    f.push(0, 1000, T0);
    assert(f.readFrame(T0) == 0);
    assert(f.ring.counters().played == 0 && f.ring.counters().lost == 0);
    f.push(1, 2000, T0 + 10 * MS);
    assert(f.readFrame(T0 + 10 * MS) == 1000);
    assert(f.readFrame(T0 + 20 * MS) == 2000);
}

void in_order_across_burst_sized_reads() {
    Fx f;
    for (uint32_t i = 0; i < 3; ++i) f.push(i, int16_t(100 * (i + 1)), T0 + i * 10 * MS);
    std::vector<int16_t> out(3 * kFrameSamples);
    for (int off = 0; off < 3 * kFrameSamples; off += 192) {
        int n = std::min(192, 3 * kFrameSamples - off);
        f.ring.read(out.data() + off, n, T0 + 30 * MS);
    }
    for (int i = 0; i < 3 * kFrameSamples; ++i) assert(out[i] == 100 * (i / kFrameSamples + 1));
    assert(f.ring.counters().lost == 0 && f.ring.counters().played == 3);
}

void gap_plays_plc_and_counts_lost() {
    Fx f;
    f.push(0, 8000, T0);
    f.push(2, 6000, T0 + 20 * MS);
    assert(f.readFrame(T0 + 20 * MS) == 8000);
    assert(f.readFrame(T0 + 30 * MS) == 4000);  // last frame at -6 dB
    assert(f.ring.counters().lost == 1);
    assert(f.readFrame(T0 + 40 * MS) == 6000);
    f.push(1, 7000, T0 + 40 * MS);  // arrives after its slot was played
    assert(f.ring.counters().late == 1 && f.ring.counters().lost == 1);
}

void plc_fades_to_silence_after_3() {
    Fx f;
    f.push(0, 8000, T0);
    f.push(5, 6000, T0 + 50 * MS);
    assert(f.readFrame(T0 + 50 * MS) == 8000);
    assert(f.readFrame(T0 + 50 * MS) == 4000);
    assert(f.readFrame(T0 + 50 * MS) == 2000);
    assert(f.readFrame(T0 + 50 * MS) == 1000);
    assert(f.readFrame(T0 + 50 * MS) == 0);  // 4th missing slot: exact silence
    assert(f.ring.counters().lost == 4);
    assert(f.readFrame(T0 + 50 * MS) == 6000);
}

void underrun_counts_only_within_grace() {
    Fx f;
    f.push(0, 5000, T0);
    f.push(1, 5000, T0 + 10 * MS);
    f.readFrame(T0 + 10 * MS);
    f.readFrame(T0 + 20 * MS);
    f.readFrame(T0 + 60 * MS);  // empty 50 ms after the last push
    assert(f.ring.counters().lost == 1);
    assert(f.readFrame(T0 + 160 * MS) == 0);  // 150 ms: idle, not counted
    assert(f.ring.counters().lost == 1);
    // Back to wait-for-target: one new frame is not enough.
    f.push(2, 9000, T0 + 170 * MS);
    assert(f.readFrame(T0 + 170 * MS) == 0);
}

void idle_returns_to_wait_for_target() {
    Fx f;
    f.push(0, 5000, T0);
    f.push(1, 5000, T0 + 10 * MS);
    f.readFrame(T0 + 10 * MS);
    f.readFrame(T0 + 20 * MS);
    // 1 s gap with no reads at all, then a new burst continuing the sequence.
    f.push(2, 7000, T0 + 1000 * MS);
    assert(f.readFrame(T0 + 1000 * MS) == 0);
    f.push(3, 7100, T0 + 1010 * MS);
    assert(f.readFrame(T0 + 1010 * MS) == 7000);
    assert(f.ring.counters().lost == 0);
}

void duplicates_and_late_are_not_lost() {
    Fx f;
    f.push(0, 1000, T0);
    f.push(1, 2000, T0 + 10 * MS);
    f.push(1, 2000, T0 + 10 * MS);  // duplicate
    f.readFrame(T0 + 10 * MS);
    f.readFrame(T0 + 20 * MS);
    f.push(0, 1000, T0 + 20 * MS);  // late
    auto c = f.ring.counters();
    assert(c.late == 2 && c.lost == 0 && c.played == 2);
}

void drain_skips_quiet_frame_when_above_target() {
    Fx f;
    f.push(0, 1000, T0);
    f.push(1, 1100, T0);
    assert(f.readFrame(T0) == 1000);
    int16_t v[4] = {1200, 0, 1400, 1500};  // seq 3 is quiet
    for (uint32_t i = 0; i < 4; ++i) f.push(2 + i, v[i], T0);
    assert(f.readFrame(T0 + 10 * MS) == 1100);   // depth 5 > target + 1: timer starts
    assert(f.readFrame(T0 + 120 * MS) == 1200);  // held 100 ms: the quiet frame is chosen
    assert(f.readFrame(T0 + 130 * MS) == 1400);  // and skipped
    assert(f.ring.counters().discarded == 1);
    assert(f.ring.counters().depthFrames <= 3);
    assert(f.readFrame(T0 + 140 * MS) == 1500);
    assert(f.ring.counters().lost == 0);
}

void overflow_beyond_16_counts_discarded() {
    Fx f;
    f.push(0, 1000, T0);
    f.push(1, 1000, T0);
    f.readFrame(T0);  // plays 0; frame 1 is next
    for (uint32_t i = 2; i < 17; ++i) f.push(i, 1000, T0);
    assert(f.ring.counters().discarded == 0);  // seq 2..16 fit (next + 16 slots)
    f.push(17, 7000, T0);                      // overrun: the 16 queued frames are dropped, 17 starts a new burst
    assert(f.ring.counters().discarded == 16);
    f.push(18, 7100, T0);
    assert(f.readFrame(T0 + 10 * MS) == 7000);
}

// The sender runs at twice the consumer's rate (as seen on the emulator): audio must keep playing.
void sender_2x_keeps_playing() {
    Fx f;
    uint32_t seq = 0;
    uint64_t playedBefore = 0;
    int16_t out[kFrameSamples];
    for (int tick = 0; tick < 200; ++tick) {  // 2 s of consumer time
        int64_t t = T0 + int64_t(tick) * 10 * MS;
        f.push(seq, int16_t(2000 + seq % 500), t);
        ++seq;
        f.push(seq, int16_t(2000 + seq % 500), t + 5 * MS);
        ++seq;
        f.ring.read(out, kFrameSamples, t + 5 * MS);
        if (tick == 149) playedBefore = f.ring.counters().played;
        assert(f.ring.counters().depthFrames <= 16);
    }
    auto c = f.ring.counters();
    assert(c.played - playedBefore >= 25);  // real frames still played in the last 500 ms
    assert(c.lost * 10 < c.played);
    assert(c.discarded * 100 >= c.received * 35 && c.discarded * 100 <= c.received * 65);
}

void burst_after_stall_recovers() {
    Fx f;
    uint32_t seq = 0;
    int16_t out[kFrameSamples];
    int tick = 0;
    for (; tick < 30; ++tick) {  // steady 10 ms stream
        int64_t t = T0 + int64_t(tick) * 10 * MS;
        f.push(seq, int16_t(2000 + seq % 500), t);
        ++seq;
        f.ring.read(out, kFrameSamples, t);
    }
    for (int k = 0; k < 6; ++k, ++tick) f.ring.read(out, kFrameSamples, T0 + int64_t(tick) * 10 * MS);  // 60 ms stall
    for (int k = 0; k < 30; ++k, ++seq) {
        f.push(seq, int16_t(2000 + seq % 500), T0 + int64_t(tick) * 10 * MS);
    }
    bool fresh = false;
    for (int k = 0; k < 5; ++k, ++tick) {  // within 50 ms
        f.ring.read(out, kFrameSamples, T0 + int64_t(tick) * 10 * MS);
        if (k == 0) assert(out[0] >= 2000 && out[0] < 2500);  // fresh audio on the very next read
        if (out[0] >= 2000) fresh = true;
    }
    assert(fresh);
}

void resync_on_big_seq_jump() {
    Fx f;
    for (uint32_t i = 0; i < 3; ++i) f.push(i, 1000, T0 + i * 10 * MS);
    f.readFrame(T0 + 30 * MS);
    f.readFrame(T0 + 30 * MS);
    f.readFrame(T0 + 30 * MS);
    f.push(1002, 3000, T0 + 40 * MS);  // sender restarted: +1000
    assert(f.readFrame(T0 + 40 * MS) == 0);
    f.push(1003, 3100, T0 + 50 * MS);
    assert(f.readFrame(T0 + 50 * MS) == 3000);
    assert(f.readFrame(T0 + 60 * MS) == 3100);
    assert(f.ring.counters().lost == 0);
}

void u32_wrap() {
    Fx f;
    f.push(0xFFFFFFFDu, 1000, T0);
    f.push(0xFFFFFFFEu, 2000, T0 + 10 * MS);
    assert(f.readFrame(T0 + 10 * MS) == 1000);
    // 0xFFFFFFFF never arrives; the gap sits across the wrap.
    f.push(0, 3000, T0 + 30 * MS);
    f.push(1, 4000, T0 + 40 * MS);
    f.push(2, 5000, T0 + 50 * MS);
    assert(f.readFrame(T0 + 50 * MS) == 2000);
    assert(f.readFrame(T0 + 50 * MS) == 1000);  // PLC: last frame (2000) at half
    assert(f.ring.counters().lost == 1);
    assert(f.readFrame(T0 + 50 * MS) == 3000);
    assert(f.readFrame(T0 + 50 * MS) == 4000);
    assert(f.readFrame(T0 + 50 * MS) == 5000);
    assert(f.ring.counters().lost == 1);
}

void reorder_within_target_plays_in_order() {
    Fx f;
    f.push(0, 1000, T0);
    f.push(2, 3000, T0 + 10 * MS);
    f.push(1, 2000, T0 + 12 * MS);  // n, n+2, n+1
    assert(f.readFrame(T0 + 20 * MS) == 1000);
    assert(f.readFrame(T0 + 30 * MS) == 2000);
    assert(f.readFrame(T0 + 40 * MS) == 3000);
    auto c = f.ring.counters();
    assert(c.lost == 0 && c.late == 0 && c.played == 3);
}

// Consumer-side idle (cFloor_): the producer's own >100 ms pause flush is not involved, because the
// pushes keep a 10 ms cadence on the producer's clock while the reader's clock jumps ahead.
void idle_floor_ignores_played_frames() {
    Fx f;
    f.push(0, 1000, T0);
    f.push(1, 2000, T0 + 10 * MS);
    f.readFrame(T0 + 20 * MS);
    f.readFrame(T0 + 30 * MS);
    assert(f.readFrame(T0 + 500 * MS) == 0);  // idle: back to waiting, floor = 2
    assert(f.readFrame(T0 + 510 * MS) == 0);  // the two played frames are still tagged but must not replay
    f.push(2, 3000, T0 + 20 * MS);
    f.push(3, 4000, T0 + 30 * MS);
    assert(f.readFrame(T0 + 520 * MS) == 3000);
    assert(f.readFrame(T0 + 530 * MS) == 4000);
}

void flush_via_generation() {
    Fx f;
    f.push(0, 1000, T0);
    f.push(1, 1100, T0);
    f.push(2, 1200, T0);
    f.ring.flush();
    f.push(10, 5000, T0 + 10 * MS);
    assert(f.readFrame(T0 + 10 * MS) == 0);  // still prebuffering, nothing from before the flush
    f.push(11, 5100, T0 + 20 * MS);
    assert(f.readFrame(T0 + 20 * MS) == 5000);
    assert(f.readFrame(T0 + 30 * MS) == 5100);
}

void flush_mid_frame() {
    Fx f;
    f.push(0, 1000, T0);
    f.push(1, 1100, T0);
    int16_t half[kFrameSamples / 2];
    f.ring.read(half, kFrameSamples / 2, T0);
    f.ring.flush();
    f.ring.read(half, kFrameSamples / 2, T0);  // the rest of the old frame must not play
    for (int16_t s : half) assert(s == 0);
}

void adaptive_target() {
    {
        Fx f;
        for (uint32_t i = 0; i < 19; ++i) f.push(i, 1, T0 + i * 10 * MS);
        assert(f.ring.counters().targetFrames == 2);  // under 20 packets
    }
    {
        Fx f;
        for (uint32_t i = 0; i < 40; ++i) f.push(i, 1, T0 + i * 10 * MS);
        assert(f.ring.counters().targetFrames == 1);
    }
    {
        Fx f;
        for (uint32_t i = 0; i < 60; ++i) {
            int64_t jit = (i % 2) ? 15 * MS : -15 * MS;
            f.push(i, 1, T0 + 100 * MS + int64_t(i) * 10 * MS + jit);
        }
        assert(f.ring.counters().targetFrames == 4);  // clamped
    }
}

void jitter_matches_rfc3550() {
    Fx f;
    f.push(0, 1, T0);
    f.push(1, 1, T0 + 26 * MS);  // |26 - 10| / 16 = 1 ms
    assert(f.ring.counters().jitterMs == 1);
}
}  // namespace

int main() {
    prebuffers_to_target();
    in_order_across_burst_sized_reads();
    gap_plays_plc_and_counts_lost();
    plc_fades_to_silence_after_3();
    underrun_counts_only_within_grace();
    idle_returns_to_wait_for_target();
    duplicates_and_late_are_not_lost();
    drain_skips_quiet_frame_when_above_target();
    overflow_beyond_16_counts_discarded();
    sender_2x_keeps_playing();
    burst_after_stall_recovers();
    resync_on_big_seq_jump();
    u32_wrap();
    reorder_within_target_plays_in_order();
    idle_floor_ignores_played_frames();
    flush_via_generation();
    flush_mid_frame();
    adaptive_target();
    jitter_matches_rfc3550();
    std::puts("jitter_ring_test: all passed");
}
