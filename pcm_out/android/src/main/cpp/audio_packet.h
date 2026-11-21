// 12-byte little-endian header (magic 0x4D54, version 1, type, seq, pin) + payload; see protocol/lib/src/packet.dart.
#pragma once
#include <cstdint>
#include <cstring>

#include "jitter_ring.h"  // kFrameSamples

namespace lanmic {

constexpr int kHeaderBytes = 12;
constexpr int kAudioPacketBytes = kHeaderBytes + kFrameSamples * 2;  // 972

inline void putLe32(uint8_t* p, uint32_t v) {
    for (int i = 0; i < 4; ++i) p[i] = uint8_t(v >> (8 * i));
}

// Samples are copied as-is: every Android ABI (and the host tests) is little-endian.
inline void buildAudioPacket(uint8_t out[kAudioPacketBytes], uint32_t seq, uint32_t pin, const int16_t* frame480) {
    out[0] = 0x54;
    out[1] = 0x4D;
    out[2] = 1;  // version
    out[3] = 0;  // type AUDIO
    putLe32(out + 4, seq);
    putLe32(out + 8, pin);
    std::memcpy(out + kHeaderBytes, frame480, sizeof(int16_t) * kFrameSamples);
}

}  // namespace lanmic
