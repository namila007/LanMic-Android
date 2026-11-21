#include "frame_queue.h"

#include <algorithm>
#include <cstring>

namespace lanmic {

bool FrameQueue::push(const int16_t* frame480) {
    const uint32_t t = tail_.load(std::memory_order_relaxed);
    if (t - head_.load(std::memory_order_acquire) >= uint32_t(kQueueSlots)) {
        dropped_.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    std::memcpy(slots_[t % kQueueSlots], frame480, sizeof(int16_t) * kFrameSamples);
    tail_.store(t + 1, std::memory_order_release);
    return true;
}

bool FrameQueue::pop(int16_t* out480) {
    const uint32_t h = head_.load(std::memory_order_relaxed);
    if (h == tail_.load(std::memory_order_acquire)) return false;
    std::memcpy(out480, slots_[h % kQueueSlots], sizeof(int16_t) * kFrameSamples);
    head_.store(h + 1, std::memory_order_release);
    return true;
}

int FrameAssembler::append(const int16_t* samples, int32_t n, FrameQueue& q) {
    int completed = 0;
    while (n > 0) {
        const int32_t take = std::min<int32_t>(n, kFrameSamples - fill_);
        std::memcpy(buf_ + fill_, samples, sizeof(int16_t) * size_t(take));
        fill_ += take;
        samples += take;
        n -= take;
        if (fill_ == kFrameSamples) {
            q.push(buf_);
            fill_ = 0;
            ++completed;
        }
    }
    return completed;
}

}  // namespace lanmic
