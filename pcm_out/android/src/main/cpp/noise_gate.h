// C++ port of the phone's old Dart NoiseGate: mutes 10 ms frames while the mic only hears background
// (the TV itself), breaking the TV -> mic -> TV echo loop. Muted frames become silence, never drops.
#pragma once
#include <cstdint>

#include "jitter_ring.h"  // kFrameSamples

namespace lanmic {

struct GateStats {
    uint32_t frames = 0, openFrames = 0;
    double minDb = 0, maxDb = 0;  // 0 when frames == 0
};

class NoiseGate {
public:
    // shortcut: fixed thresholds tuned on a Pixel 7 held close; make them a user setting if other phones
    // or singing distances need different values.
    explicit NoiseGate(double openDb = -38, double closeDb = -44, int holdFrames = 25)
        : openDb_(openDb), closeDb_(closeDb), holdFrames_(holdFrames) {}

    void process(int16_t* frame480);  // in place; fades over one frame on every open/close change
    bool isOpen() const { return open_; }
    GateStats takeStats();            // resets the counters

private:
    double openDb_, closeDb_;
    int holdFrames_;
    bool open_ = false;
    double gain_ = 0;
    int quiet_ = 0;
    uint32_t frames_ = 0, openFrames_ = 0;
    double minDb_ = 0, maxDb_ = 0;
};

}  // namespace lanmic
