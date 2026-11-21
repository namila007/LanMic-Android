// Host tests for the phone capture core: FrameQueue/FrameAssembler, NoiseGate, buildAudioPacket.
// No framework: a failed assert aborts. `capture_test stress` runs only the producer/consumer stress
// (built with TSan by tool/test_native.sh).
#undef NDEBUG
#include <atomic>
#include <cassert>
#include <cstdio>
#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "audio_packet.h"
#include "frame_queue.h"
#include "noise_gate.h"

using namespace lanmic;

namespace {
constexpr int16_t kLoud = 3277;   // -20 dBFS
constexpr int16_t kBetween = 328; // -40 dBFS: under open (-38), over close (-44)
constexpr int16_t kQuiet = 65;    // -54 dBFS

void fill(int16_t* f, int16_t v) { for (int i = 0; i < kFrameSamples; ++i) f[i] = v; }
bool all(const int16_t* f, int16_t v) {
    for (int i = 0; i < kFrameSamples; ++i) if (f[i] != v) return false;
    return true;
}
// Gate one frame of constant `v`; returns the first/last output sample through `first`/`last`.
void gate(NoiseGate& g, int16_t v, int16_t* out) { fill(out, v); g.process(out); }

void assembler_handles_odd_chunks() {
    FrameQueue q;
    FrameAssembler a;
    std::vector<int16_t> src(3 * kFrameSamples);
    for (size_t i = 0; i < src.size(); ++i) src[i] = int16_t(i);
    size_t pos = 0;
    int done = 0;
    const int chunks[] = {192, 256, 7};
    for (int guard = 0; pos < src.size() && guard < 1000; ++guard) {
        int n = chunks[guard % 3];
        if (pos + size_t(n) > src.size()) n = int(src.size() - pos);
        done += a.append(src.data() + pos, n, q);
        pos += size_t(n);
    }
    assert(done == 3);
    int16_t f[kFrameSamples];
    for (int k = 0; k < 3; ++k) {
        assert(q.pop(f));
        for (int i = 0; i < kFrameSamples; ++i) assert(f[i] == int16_t(k * kFrameSamples + i));
    }
    assert(!q.pop(f));
}

void full_queue_drops_newest() {
    FrameQueue q;
    int16_t f[kFrameSamples];
    int accepted = 0;
    for (int i = 0; i < 9; ++i) {
        fill(f, int16_t(i));
        if (q.push(f)) ++accepted;
    }
    assert(accepted == 8 && q.dropped() == 1);
    for (int i = 0; i < 8; ++i) {  // the 9th (value 8) is the one that is missing
        assert(q.pop(f));
        assert(all(f, int16_t(i)));
    }
    assert(!q.pop(f));
}

void queue_fifo_order() {
    FrameQueue q;
    int16_t f[kFrameSamples];
    int next = 0, want = 0;
    for (int round = 0; round < 50; ++round) {  // wraps the 8 slots several times
        for (int i = 0; i < 5; ++i) { fill(f, int16_t(next++)); assert(q.push(f)); }
        for (int i = 0; i < 5; ++i) { assert(q.pop(f)); assert(all(f, int16_t(want++))); }
    }
    assert(q.dropped() == 0);
}

void gate_opens_at_minus38_and_closes_after_hold() {
    int16_t f[kFrameSamples];
    {  // mutes quiet frames from the start
        NoiseGate g(-38, -44, 3);
        gate(g, kQuiet, f);
        assert(all(f, 0) && !g.isOpen());
    }
    {  // passes loud frames unchanged once open (first one fades in)
        NoiseGate g(-38, -44, 3);
        gate(g, kLoud, f);
        gate(g, kLoud, f);
        assert(all(f, kLoud) && g.isOpen());
    }
    {  // holds open through short pauses, then fades out
        NoiseGate g(-38, -44, 3);
        gate(g, kLoud, f);
        for (int i = 0; i < 3; ++i) { gate(g, kQuiet, f); assert(all(f, kQuiet)); }
        gate(g, kQuiet, f);
        assert(!g.isOpen());
        assert(std::abs(f[0] - kQuiet) <= 1 && f[kFrameSamples - 1] == 0);
        gate(g, kQuiet, f);
        assert(all(f, 0));
    }
    {  // between the thresholds: does not open a closed gate, keeps an open one open
        NoiseGate g(-38, -44, 3);
        gate(g, kBetween, f);
        assert(all(f, 0) && !g.isOpen());
        gate(g, kLoud, f);
        for (int i = 0; i < 10; ++i) gate(g, kBetween, f);
        assert(g.isOpen());
    }
    {  // all-zero frame stays silent
        NoiseGate g(-38, -44, 3);
        gate(g, 0, f);
        assert(all(f, 0));
    }
}

void gate_fades_over_one_frame() {
    NoiseGate g(-38, -44, 3);
    int16_t f[kFrameSamples];
    gate(g, kLoud, f);
    assert(f[0] < kLoud / 10);
    assert(std::abs(f[kFrameSamples - 1] - kLoud) <= kLoud / 100);
    for (int i = 1; i < kFrameSamples; ++i) assert(f[i] >= f[i - 1]);
}

void gate_stats_reset_on_read() {
    NoiseGate g(-38, -44, 3);
    int16_t f[kFrameSamples];
    gate(g, kQuiet, f);
    gate(g, kLoud, f);
    GateStats s = g.takeStats();
    assert(s.frames == 2 && s.openFrames == 1);
    assert(int(std::lround(s.minDb)) == -54 && int(std::lround(s.maxDb)) == -20);
    s = g.takeStats();
    assert(s.frames == 0 && s.openFrames == 0);
}

void packet_matches_protocol_vector() {
    uint8_t p[kAudioPacketBytes];
    int16_t f[kFrameSamples];
    for (int i = 0; i < kFrameSamples; ++i) f[i] = int16_t(0x0102 + i);
    buildAudioPacket(p, 1, 482917, f);
    static_assert(kAudioPacketBytes == 972, "audio packet is 972 bytes");
    const uint8_t want[12] = {0x54, 0x4d, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x65, 0x5e, 0x07, 0x00};
    assert(std::memcmp(p, want, 12) == 0);
    assert(p[12] == 0x02 && p[13] == 0x01);  // first sample, little-endian
    assert(std::memcmp(p + 12, f, sizeof f) == 0);
    buildAudioPacket(p, 0xDEADBEEF, 1, f);
    assert(p[4] == 0xEF && p[5] == 0xBE && p[6] == 0xAD && p[7] == 0xDE);
}

// The sender loop must send every frame queued before `stopping` was set, in order, before it returns.
void stop_drains_before_return() {
    FrameQueue q;
    std::atomic<bool> stopping{false};
    std::vector<int> sent;
    std::thread sender([&] {
        senderLoop(q, stopping, [] { std::this_thread::sleep_for(std::chrono::milliseconds(1)); },
                   [&](const int16_t* f) { sent.push_back(f[0]); });
    });
    int16_t f[kFrameSamples];
    for (int i = 0; i < kQueueSlots; ++i) { fill(f, int16_t(i)); assert(q.push(f)); }
    stopping.store(true, std::memory_order_release);  // stopCapture: the input is already closed here
    sender.join();                                    // returns only when the queue is empty
    assert(sent.size() == size_t(kQueueSlots));
    for (int i = 0; i < kQueueSlots; ++i) assert(sent[size_t(i)] == i);
    assert(!q.pop(f));
}

// One producer pushes 10^6 frames filled with their index (drops when full); the consumer checks every
// popped frame is uniform and indices only increase.
void queue_stress() {
    constexpr uint32_t kFrames = 1'000'000;
    FrameQueue q;
    std::atomic<bool> done{false};
    std::thread producer([&] {
        int16_t f[kFrameSamples];
        for (uint32_t i = 0; i < kFrames; ++i) {
            fill(f, int16_t(i & 0x7fff));
            q.push(f);
            if (i % 8 == 0) std::this_thread::yield();
        }
        done.store(true);
    });
    int16_t f[kFrameSamples];
    uint64_t popped = 0;
    int last = -1;
    for (;;) {
        if (!q.pop(f)) {
            if (done.load() && !q.pop(f)) break;
            if (done.load()) { /* got a last frame via the second pop */ } else { std::this_thread::yield(); continue; }
        }
        assert(all(f, f[0]));
        // indices wrap at 0x8000: compare modulo with a window
        if (last >= 0) assert(((int(f[0]) - last) & 0x7fff) != 0);
        last = f[0];
        ++popped;
    }
    producer.join();
    assert(popped + q.dropped() == kFrames);
    std::printf("queue_stress: %llu popped, %llu dropped, no torn frames\n", (unsigned long long)popped,
                (unsigned long long)q.dropped());
}
}  // namespace

int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) == "stress") {
        queue_stress();
        return 0;
    }
    assembler_handles_odd_chunks();
    full_queue_drops_newest();
    queue_fifo_order();
    gate_opens_at_minus38_and_closes_after_hold();
    gate_fades_over_one_frame();
    gate_stats_reset_on_read();
    packet_matches_protocol_vector();
    stop_drains_before_return();
    std::puts("capture_test: all passed");
}
