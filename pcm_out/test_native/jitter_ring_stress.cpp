// ThreadSanitizer stress: one producer, one consumer. A torn slot read shows up as a run of equal
// samples whose length is not a multiple of 480 (outside a flush). Built by tool/test_native.sh with
// -fsanitize=thread (TSan and ASan cannot share a binary).
#undef NDEBUG
#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>

#include "jitter_ring.h"

using namespace lanmic;

namespace {
constexpr uint32_t kFrames = 1'000'000;

// Virtual clock driven by the producer (10 ms per frame plus +-6 ms of arrival jitter), so scheduler
// stalls on the test machine never look like a >100 ms pause.
std::atomic<int64_t> gNowNs{1'000'000'000};
}  // namespace

int main() {
    JitterRing ring;
    std::atomic<bool> done{false};
    std::atomic<uint64_t> flushes{0};

    std::thread producer([&] {
        uint32_t seq = 0;
        int16_t f[kFrameSamples];
        for (uint32_t i = 0; i < kFrames; ++i) {
            if (i % 1000 == 999) {
                flushes.fetch_add(1);  // odd while the flush is in flight
                if ((i / 1000) % 2) {
                    ring.flush();
                } else {
                    seq += 100000;  // sender restart: the ring resyncs by itself (flush happens in push)
                }
            }
            // Stay within one ring of the consumer: an overrun resync would be a flush the test cannot see.
            while (ring.counters().depthFrames > 8) std::this_thread::yield();
            for (auto& s : f) s = int16_t(seq & 0x7fff);
            const int64_t t = 1'000'000'000 + int64_t(i) * 10'000'000 + (int64_t(i * 7919 % 13) - 6) * 1'000'000;
            gNowNs.store(t);
            ring.push(f, seq++, t);
            if (i % 1000 == 999) flushes.fetch_add(1);  // even again: the new generation is published
            if (i % 8 == 0) std::this_thread::yield();
        }
        done.store(true);
    });

    int16_t buf[kFrameSamples];
    int16_t runVal = 0;
    int64_t runLen = 0;
    uint64_t runFlushes = 0, checked = 0, torn = 0;
    auto endRun = [&](uint64_t flushesNow) {
        // A truncated run is legal only when a flush or resync happened while it played. The counter is
        // bumped just before the flush, so a run that started in that gap sees the change one run earlier.
        const bool flushed = flushesNow != runFlushes || (runFlushes & 1);
        if (runVal != 0 && runLen > 0 && runLen % kFrameSamples != 0 && !flushed) {
            ++torn;
            std::fprintf(stderr, "torn run: value %d length %lld\n", runVal, (long long)runLen);
        }
                if (runLen >= kFrameSamples) ++checked;
        runLen = 0;
    };
    for (uint32_t n = 0; !done.load() || n % 3 != 0; ++n) {
        const int chunk = (n % 2) ? 192 : 480;
        const uint64_t before = flushes.load();  // taken before the samples exist: attributes a run start
        ring.read(buf, chunk, gNowNs.load());
        const uint64_t fl = flushes.load();
        for (int i = 0; i < chunk; ++i) {
            if (runLen > 0 && buf[i] != runVal) endRun(fl);
            if (runLen == 0) {
                runVal = buf[i];
                runFlushes = before;
            }
            ++runLen;
        }
        if (done.load() && n > 50) break;
    }
    producer.join();
    std::printf("stress: %llu full frames checked, %llu torn\n", (unsigned long long)checked,
                (unsigned long long)torn);
    assert(torn == 0);
    assert(checked > 100);
}
