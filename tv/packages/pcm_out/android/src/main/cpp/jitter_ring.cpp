#include "jitter_ring.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace lanmic {
namespace {
constexpr int kInitialTarget = 2;
constexpr uint32_t kWarmupPackets = 20;
constexpr int kMinTarget = 1, kMaxTarget = 4;
constexpr int64_t kGraceNs = 100'000'000;  // underrun counts as lost only this soon after the last push
constexpr int64_t kDrainHoldNs = 100'000'000;
constexpr int kMaxPlc = 3;
constexpr int64_t kResyncDistance = 16;
constexpr int64_t kQuietSumSq = int64_t(207) * 207 * kFrameSamples;  // RMS below about -44 dBFS

int32_t dist(uint32_t a, uint32_t b) { return int32_t(a - b); }  // signed, wraps correctly

}  // namespace

// Seqlock writer: invalidate the tag, copy, publish the new tag.
void JitterRing::writeSlot(Slot& s, const int16_t* src, uint64_t tag) {
    s.tag.store(0, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    for (int i = 0; i < kFrameSamples; ++i) s.pcm[i].store(src[i], std::memory_order_relaxed);
    s.tag.store(tag, std::memory_order_release);
}

// Seqlock reader: the copy counts only if the tag was `expect` before and after it.
bool JitterRing::readSlot(const Slot& s, uint64_t expect, int16_t* dst) {
    if (s.tag.load(std::memory_order_acquire) != expect) return false;
    for (int i = 0; i < kFrameSamples; ++i) dst[i] = s.pcm[i].load(std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_acquire);
    return s.tag.load(std::memory_order_relaxed) == expect;
}

bool JitterRing::slotQuiet(const Slot& s) {  // approximate: a torn read only skews a drain choice
    int64_t sum = 0;
    for (int i = 0; i < kFrameSamples; ++i) {
        int64_t v = s.pcm[i].load(std::memory_order_relaxed);
        sum += v * v;
    }
    return sum < kQuietSumSq;
}

JitterRing::JitterRing() {
    std::memset(cur_, 0, sizeof cur_);
    std::memset(lastGood_, 0, sizeof lastGood_);
}

void JitterRing::flush() { gen_.fetch_add(1, std::memory_order_acq_rel); }

JitterRing::Scan JitterRing::scan(uint32_t gen, uint32_t cur) const {
    Scan s;
    for (int k = 0; k < kSlots; ++k) {
        uint32_t seq = cur + k;
        if (slots_[seq % kSlots].tag.load(std::memory_order_acquire) == makeTag(gen, seq)) {
            s.present |= 1u << k;
            ++s.depth;
        }
    }
    return s;
}

void JitterRing::resetProducer(uint32_t gen) {
    pGen_ = gen;
    pHave_ = false;
    pCount_ = 0;
    pJitterMs_ = 0;
    pPrev_ = false;
    target_.store(kInitialTarget, std::memory_order_relaxed);
    jitterUs_.store(0, std::memory_order_relaxed);
}

void JitterRing::push(const int16_t* pcm, uint32_t seq, int64_t nowNs) {
    uint32_t gen = gen_.load(std::memory_order_acquire);
    if (gen != pGen_) resetProducer(gen);
    // A seq far from the expected one means the sender restarted: start a new burst.
    // A pause over 100 ms is a new burst too: re-prebuffer.
    if ((pHave_ && std::llabs(int64_t(dist(seq, pExpected_))) > kResyncDistance) ||
        (pPrev_ && nowNs - pPrevNs_ > kGraceNs)) {
        flush();
        gen = gen_.load(std::memory_order_acquire);
        resetProducer(gen);
    }
    received_.fetch_add(1, std::memory_order_relaxed);
    lastPushNs_.store(nowNs, std::memory_order_relaxed);

    // RFC 3550 interarrival jitter (gain 1/16) of arrival time against seq * 10 ms.
    if (pPrev_) {
        double d = double(nowNs - pPrevNs_) / 1e6 - double(dist(seq, pPrevSeq_)) * 10.0;
        pJitterMs_ += (std::fabs(d) - pJitterMs_) / 16.0;
    }
    pPrev_ = true;
    pPrevNs_ = nowNs;
    pPrevSeq_ = seq;
    ++pCount_;
    int target = kInitialTarget;
    if (pCount_ >= kWarmupPackets) {
        target = std::clamp(int(std::ceil((2 * pJitterMs_ + 2) / 10)), kMinTarget, kMaxTarget);
    }
    target_.store(target, std::memory_order_relaxed);
    jitterUs_.store(int32_t(pJitterMs_ * 1000), std::memory_order_relaxed);

    if (!pHave_ || dist(seq, pExpected_ - 1) > 0) pExpected_ = seq + 1;
    pHave_ = true;

    Slot& slot = slots_[seq % kSlots];
    if (slot.tag.load(std::memory_order_acquire) == makeTag(gen, seq)) {  // duplicate
        late_.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    // Late/overflow checks only apply once the consumer plays this generation.
    if (consGen_.load(std::memory_order_acquire) == gen && !waiting_.load(std::memory_order_acquire)) {
        int32_t d = dist(seq, consNext_.load(std::memory_order_acquire));
        if (d < 0) { late_.fetch_add(1, std::memory_order_relaxed); return; }
        if (d >= kSlots) {
            // The sender is more than a ring ahead (fast clock, or a stall burst): dropping new frames would
            // starve the consumer for good. Drop what is queued and start a new burst at this frame.
            discarded_.fetch_add(uint64_t(scan(gen, consNext_.load(std::memory_order_acquire)).depth),
                                 std::memory_order_relaxed);
            flush();
            gen = gen_.load(std::memory_order_acquire);
            resetProducer(gen);
            pHave_ = true;
            pExpected_ = seq + 1;
        }
    }
    writeSlot(slot, pcm, makeTag(gen, seq));
}

// Pick the start frame: the (target + 1)-th newest present frame (or the oldest if fewer), so a backlog
// from a cold stream open is cut to the depth the drain rule tolerates.
bool JitterRing::tryAnchor(uint32_t gen, int target) {
    uint32_t seqs[kSlots];
    int n = 0;
    uint32_t newest = 0;
    for (int i = 0; i < kSlots; ++i) {
        uint64_t t = slots_[i].tag.load(std::memory_order_acquire);
        if (uint32_t(t >> 32) != gen) continue;
        uint32_t s = uint32_t(t);
        if (s % kSlots != uint32_t(i)) continue;
        if (cFloorValid_ && dist(s, cFloor_) < 0) continue;  // already played before going idle
        if (n == 0 || dist(s, newest) > 0) newest = s;
        seqs[n++] = s;
    }
    if (n < target) return false;
    // Frames present within 16 of the newest, ordered by age: take the target-th newest.
    std::sort(seqs, seqs + n, [&](uint32_t a, uint32_t b) { return dist(a, b) > 0; });
    const int keep = std::min(n, target + 1);
    cNext_ = seqs[keep - 1];
    discarded_.fetch_add(uint64_t(n - keep), std::memory_order_relaxed);  // older backlog we skip
    return true;
}

void JitterRing::playPlc() {
    if (haveGood_ && plcRun_ < kMaxPlc) {
        ++plcRun_;
        for (int i = 0; i < kFrameSamples; ++i) cur_[i] = int16_t(lastGood_[i] / (1 << plcRun_));  // not >>: negatives
    } else {
        std::memset(cur_, 0, sizeof cur_);
    }
}

// Starts the next 10 ms frame in cur_ (real data, PLC or silence), or goes back to waiting.
void JitterRing::startFrame(uint32_t gen, int64_t nowNs) {
    const int target = target_.load(std::memory_order_relaxed);
    auto advance = [&] {
        ++cNext_;
        consNext_.store(cNext_, std::memory_order_release);
    };
    Scan s = scan(gen, cNext_);
    if (skipValid_ && cNext_ == skipSeq_) {  // the frame chosen earlier for draining
        skipValid_ = false;
        if (s.present & 1) {
            discarded_.fetch_add(1, std::memory_order_relaxed);
            advance();
            s = scan(gen, cNext_);
        }
    }
    // Drain: depth stayed above target + 1 for 100 ms. Skip one frame, a quiet one if there is one.
    if (s.depth > target + 1) {
        if (aboveSinceNs_ == kNever) {
            aboveSinceNs_ = nowNs;
        } else if (nowNs - aboveSinceNs_ >= kDrainHoldNs) {
            int pick = -1, first = -1;
            for (int k = 0; k < kSlots && pick < 0; ++k) {
                if (!(s.present & (1u << k))) continue;
                if (first < 0) first = k;
                if (slotQuiet(slots_[(cNext_ + k) % kSlots])) pick = k;
            }
            if (pick < 0) pick = first;
            if (pick == 0) {
                discarded_.fetch_add(1, std::memory_order_relaxed);
                advance();
                s = scan(gen, cNext_);
            } else {
                skipValid_ = true;
                skipSeq_ = cNext_ + pick;
            }
            aboveSinceNs_ = nowNs;
        }
    } else {
        aboveSinceNs_ = kNever;
    }

    Slot& slot = slots_[cNext_ % kSlots];
    const bool ok = (s.present & 1) && readSlot(slot, makeTag(gen, cNext_), cur_);
    if (ok) {
        std::memcpy(lastGood_, cur_, sizeof cur_);
        haveGood_ = true;
        plcRun_ = 0;
        played_.fetch_add(1, std::memory_order_relaxed);
    } else {
        int64_t lp = lastPushNs_.load(std::memory_order_relaxed);
        bool recent = lp != kNever && nowNs - lp <= kGraceNs;
        if (!(s.present & ~1u) && !recent) {  // empty and idle: wait for the next burst
            cWaiting_ = true;
            cFloorValid_ = true;
            cFloor_ = cNext_;
            waiting_.store(true, std::memory_order_release);
            haveGood_ = false;
            plcRun_ = 0;
            skipValid_ = false;
            aboveSinceNs_ = kNever;
            return;
        }
        lost_.fetch_add(1, std::memory_order_relaxed);
        playPlc();
        if (!(s.present & ~1u)) {  // nothing newer: the frame is late, not lost. Hold it so playout slips later.
            cHave_ = true;
            cPos_ = 0;
            return;
        }
    }
    advance();
    cHave_ = true;
    cPos_ = 0;
}

void JitterRing::read(int16_t* out, int32_t frames, int64_t nowNs) {
    int32_t done = 0;
    while (done < frames) {
        const uint32_t gen = gen_.load(std::memory_order_acquire);
        if (gen != cGen_) {  // flushed: drop everything held
            cGen_ = gen;
            cFloorValid_ = false;
            cWaiting_ = true;
            waiting_.store(true, std::memory_order_release);
            consGen_.store(gen, std::memory_order_release);
            cHave_ = false;
            haveGood_ = false;
            plcRun_ = 0;
            skipValid_ = false;
            aboveSinceNs_ = kNever;
        }
        if (cWaiting_) {
            if (!tryAnchor(gen, target_.load(std::memory_order_relaxed))) break;
            cWaiting_ = false;
            consNext_.store(cNext_, std::memory_order_relaxed);
            waiting_.store(false, std::memory_order_release);
        }
        if (!cHave_) {
            startFrame(gen, nowNs);
            if (!cHave_) break;  // went idle
        }
        int32_t n = std::min<int32_t>(kFrameSamples - cPos_, frames - done);
        std::memcpy(out + done, cur_ + cPos_, size_t(n) * sizeof(int16_t));
        cPos_ += n;
        done += n;
        if (cPos_ == kFrameSamples) cHave_ = false;
    }
    if (done < frames) std::memset(out + done, 0, size_t(frames - done) * sizeof(int16_t));
}

RingCounters JitterRing::counters() const {
    const uint32_t gen = gen_.load(std::memory_order_acquire);
    // While waiting the queue is still filling (and may hold stale frames), so report 0.
    int depth = waiting_.load(std::memory_order_acquire)
                    ? 0
                    : scan(gen, consNext_.load(std::memory_order_acquire)).depth;
    return {received_.load(std::memory_order_relaxed), played_.load(std::memory_order_relaxed),
            lost_.load(std::memory_order_relaxed),     discarded_.load(std::memory_order_relaxed),
            late_.load(std::memory_order_relaxed),     depth,
            target_.load(std::memory_order_relaxed),   int32_t(std::lround(jitterUs_.load(std::memory_order_relaxed) / 1000.0)),
            lastPushNs_.load(std::memory_order_relaxed)};
}

}  // namespace lanmic
