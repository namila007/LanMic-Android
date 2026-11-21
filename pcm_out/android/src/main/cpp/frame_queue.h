// Phone capture: SPSC queue of 10 ms mono PCM16 frames, plus an assembler that cuts arbitrary callback
// chunks into frames. Pure C++ (no Android headers) so it is host-tested.
#pragma once
#include <atomic>
#include <cstdint>

#include "jitter_ring.h"  // kFrameSamples

namespace lanmic {

constexpr int kQueueSlots = 8;

// Single producer (the input callback), single consumer (the sender thread). A full queue drops the NEWEST
// frame, so the producer never touches the consumer's index and stays wait-free.
class FrameQueue {
public:
    bool push(const int16_t* frame480);  // false (and dropped()++) when full
    bool pop(int16_t* out480);           // false when empty
    uint64_t dropped() const { return dropped_.load(std::memory_order_relaxed); }

private:
    int16_t slots_[kQueueSlots][kFrameSamples];
    std::atomic<uint32_t> head_{0};  // next slot to pop; written by the consumer
    std::atomic<uint32_t> tail_{0};  // next slot to fill; written by the producer
    std::atomic<uint64_t> dropped_{0};
};

// Producer side: collects samples into 480-sample frames and pushes each full one.
class FrameAssembler {
public:
    // Returns how many frames were completed (pushed or dropped), so the caller can wake the consumer.
    int append(const int16_t* samples, int32_t n, FrameQueue& q);
    void reset() { fill_ = 0; }

private:
    int16_t buf_[kFrameSamples];
    int fill_ = 0;
};

// Sender-thread body. `stopping` is read BEFORE draining: everything pushed before it was set (the input is
// closed first) is then visible, so the final pass sends every queued frame and the loop returns only after.
template <class Wait, class Send>
void senderLoop(FrameQueue& q, const std::atomic<bool>& stopping, Wait wait, Send send) {
    int16_t f[kFrameSamples];
    for (;;) {
        const bool last = stopping.load(std::memory_order_acquire);
        while (q.pop(f)) send(f);
        if (last) return;
        wait();
    }
}

}  // namespace lanmic
