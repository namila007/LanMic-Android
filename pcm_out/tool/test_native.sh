#!/bin/sh
# Host-run tests for the C++ jitter ring and phone capture core: ASan/UBSan unit tests, TSan stress passes, and a JNI name check.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
cpp="$here/android/src/main/cpp"
out="${TMPDIR:-/tmp}"

# Every `external fun X` in NativeAudio.kt needs Java_<package, '_' escaped as '_1'>_NativeAudio_X in the bridge.
kt="$here/android/src/main/kotlin/me/namila/app/lanmic/pcm_out/NativeAudio.kt"
for f in $(sed -n 's/.*external fun \([A-Za-z0-9_]*\).*/\1/p' "$kt"); do
  grep -q "Java_me_namila_app_lanmic_pcm_1out_NativeAudio_$f" "$cpp/jni_bridge.cpp" || {
    echo "JNI name check FAILED: Java_me_namila_app_lanmic_pcm_1out_NativeAudio_$f missing in jni_bridge.cpp" >&2
    exit 1
  }
done
echo "jni names: ok"

clang++ -std=c++17 -O1 -g -Wall -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
  -I"$cpp" "$here/test_native/jitter_ring_test.cpp" "$cpp/jitter_ring.cpp" -o "$out/jitter_ring_test"
"$out/jitter_ring_test"

clang++ -std=c++17 -O1 -g -Wall -Werror -fsanitize=thread \
  -I"$cpp" "$here/test_native/jitter_ring_stress.cpp" "$cpp/jitter_ring.cpp" -o "$out/jitter_ring_stress"
"$out/jitter_ring_stress"

clang++ -std=c++17 -O1 -g -Wall -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
  -I"$cpp" "$here/test_native/capture_test.cpp" "$cpp/frame_queue.cpp" "$cpp/noise_gate.cpp" -o "$out/capture_test"
"$out/capture_test"

clang++ -std=c++17 -O1 -g -Wall -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
  -I"$cpp" "$here/test_native/gain_test.cpp" "$cpp/gain.cpp" -o "$out/gain_test"
"$out/gain_test"

clang++ -std=c++17 -O1 -g -Wall -Werror -fsanitize=thread \
  -I"$cpp" "$here/test_native/capture_test.cpp" "$cpp/frame_queue.cpp" "$cpp/noise_gate.cpp" -o "$out/capture_stress"
"$out/capture_stress" stress
