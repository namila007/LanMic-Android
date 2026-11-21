#include "noise_gate.h"

#include <algorithm>
#include <cmath>

namespace lanmic {

namespace {
double dbfs(const int16_t* f) {
    double sum = 0;
    for (int i = 0; i < kFrameSamples; ++i) sum += double(f[i]) * f[i];
    const double rms = std::sqrt(sum / kFrameSamples) / 32768;
    return rms == 0 ? -120 : 20 * std::log10(rms);
}
}  // namespace

void NoiseGate::process(int16_t* f) {
    const double db = dbfs(f);
    if (db >= (open_ ? closeDb_ : openDb_)) {
        open_ = true;
        quiet_ = 0;
    } else if (open_ && ++quiet_ > holdFrames_) {
        open_ = false;
    }
    if (frames_ == 0) {
        minDb_ = maxDb_ = db;
    } else {
        minDb_ = std::min(minDb_, db);
        maxDb_ = std::max(maxDb_, db);
    }
    ++frames_;
    if (open_) ++openFrames_;

    const double from = gain_, to = open_ ? 1.0 : 0.0;
    gain_ = to;
    if (from == to) {
        if (to == 0) std::fill(f, f + kFrameSamples, int16_t(0));
        return;
    }
    for (int i = 0; i < kFrameSamples; ++i) {
        const double g = from + (to - from) * (i + 1) / kFrameSamples;
        f[i] = int16_t(std::lround(f[i] * g));
    }
}

GateStats NoiseGate::takeStats() {
    GateStats s;
    s.frames = frames_;
    s.openFrames = openFrames_;
    s.minDb = frames_ ? minDb_ : 0;
    s.maxDb = frames_ ? maxDb_ : 0;
    frames_ = openFrames_ = 0;
    return s;
}

}  // namespace lanmic
