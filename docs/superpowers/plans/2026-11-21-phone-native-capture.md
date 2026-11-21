# Phone Native Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Guidelines, names and test cases only, no code bodies.** Ponytail mode: smallest complete change; reuse the TV plugin's patterns.

**Goal:** The phone records with Oboe/AAudio and sends each 10 ms frame from a native thread the moment it is full. That removes the send clumps that inflate TV jitter, and replaces the 40 ms phone-delay guess with a measured value.

**Architecture:**
- The shared plugin `pcm_out` moves to the repo root.
- On the phone, its Kotlin `NativeReceiver` binds an ephemeral UDP port and owns the only socket.
- An Oboe input callback fills 480-sample frames into an SPSC queue.
- A C++ sender thread gates each frame, builds the AUDIO packet and `sendto`s it on a dup'd fd of that socket.
- Dart keeps HELLO/ACK/STATS/END and tells native the target.

**Tech Stack:** Oboe 1.11.0 (already in the plugin) · C++17 · Kotlin · Flutter MethodChannel/EventChannel · Dart.

**Spec:** `docs/superpowers/specs/2026-11-21-phone-native-capture-design.md`. Section 7 holds the binding decisions. **Context:** `2026-11-21-native-audio-design.md` (the TV side, same plugin).

## Global Constraints

- **Input callback:** copy and publish only. No socket I/O, locks, allocation, logging, or `getTimestamp`/`calculateLatencyMillis`.
- **SPSC frame queue:** 8 frames. When it's full, the producer drops the **newest** frame and counts it. A non-blocking wake (`sem_post` or equivalent) is the only signal from the callback.
- **One socket:** audio leaves only from the socket that sent the HELLO. After a rebind the port changes, so the target is cleared until the next ACK.
- **END ordering:** `stopCapture()` is synchronous. It stops the input, drains and sends every queued full frame, then returns. Only after that does Dart send END.
- **Send condition:** native sends only while capture is started **and** a target is set.
- **Stream request:** input, `LowLatency`, `Exclusive` (shared fallback), `InputPreset::VoicePerformance` (fall back to `Unprocessed` if open fails, and on API < 29), 48 kHz, mono, I16, conversion allowed. After open, the app-side rate must be 48000 and channels 1, else `format_unsupported`.
- **NoiseGate parity with today's Dart gate:** open at −38 dBFS, close below −44 dBFS, hold 25 frames, 1-frame linear fade, gated frames become silence (never drops), and stats reset on read.
- **No protocol change** (10 ms / 960 B / port 5004). Phone minSdk 26, targetSdk 34. The plugin manifest declares no permissions.
- **Never commit** `settings.gradle*`, `.gradle/`, `local.properties`, `phone/android/gradle/gradle-daemon-jvm.properties`. Use `git add <paths>` only.
- **TDD:** host C++ tests and Dart tests run off-device. Oboe and Kotlin are checked on the emulator and on devices.

## Review Focus

1. **Rebind while talking** (backgrounded EPERM, Wi-Fi blip): audio stops until the ACK on the new port. No audio goes out from an unannounced port, and capture never dies. Pinned in Task 5 ("rebind clears target, HELLO now, target back on ACK").
2. **Release during a burst:** END arrives after the last audio frame, never before. Pinned in Task 3 (`stop_drains_before_return`) and Task 5 ("stop capture completes before END is sent").
3. **The callback produces faster than the sender drains** (sender stalled by the scheduler): newest frames are dropped and counted; no torn frames. Pinned in Task 2 (TSan queue stress, `full_queue_drops_newest`).
4. **Gate behaviour matches today:** the same thresholds and hold, so there's no echo-loop regression. Pinned in Task 2 (ported Dart gate tests).
5. **The TV keeps working after the plugin move.** Pinned in Task 1 (all TV tests, `test_native.sh` and the TV release build unchanged).

## File Structure

| File | Responsibility |
|---|---|
| `pcm_out/` (moved from `tv/packages/pcm_out/`) | shared plugin |
| `pcm_out/android/src/main/cpp/frame_queue.h/.cpp` (create) | SPSC 480-sample frame queue + assembler from arbitrary callback chunks |
| `.../cpp/noise_gate.h/.cpp` (create) | C++ port of the Dart NoiseGate |
| `.../cpp/audio_packet.h` (create) | 12 B LE header + 960 B AUDIO packet builder |
| `.../cpp/audio_in.h/.cpp` (create) | Oboe input stream, sender thread, target/fd/seq, capture stats |
| `.../cpp/jni_bridge.cpp` (modify) | capture JNI entry points |
| `pcm_out/test_native/capture_test.cpp` + `tool/test_native.sh` (modify) | host tests for the queue, gate and packet (+ TSan pass) |
| `.../kotlin/.../NativeReceiver.kt`, `NativeAudio.kt`, `PcmOutPlugin.kt` (modify) | port-0 mode, fd hand-off, `rebind`, capture methods |
| `pcm_out/lib/pcm_out.dart` (modify) | `NativeCapture` + `CaptureStats`; `NativeReceiver.rebind()` |
| `phone/lib/data/services/session_service.dart`, `mic_service.dart` (rewrite), `main.dart` (modify) | wire to the plugin |
| `phone/lib/domain/link_stats.dart` (modify) | measured phone part |
| **delete:** `phone/lib/data/services/udp_sender.dart`, `phone/lib/domain/frame_slicer.dart`, `phone/lib/domain/noise_gate.dart`, `RecordPcmSource`, the `record` dependency, and their tests | replaced by native |

---

### Task 1: Move `pcm_out` to the repo root (no behaviour change)

**Files:** `git mv tv/packages/pcm_out pcm_out`; `tv/pubspec.yaml` (`path: ../pcm_out`); `tv/pubspec.lock` (via `flutter pub get`); `pcm_out/tool/test_native.sh` (paths); CLAUDE.md (layout line); any script or doc naming `tv/packages/pcm_out` (find them with `tokensave_search literal`).

- [ ] **Step 1:** `git mv`, update the paths, run `flutter pub get` in `tv/`.
- [ ] **Step 2:** Run `pcm_out/tool/test_native.sh`, `flutter test` and `flutter analyze` in `pcm_out/` and `tv/`, then `flutter build apk --release` in `tv/`. Expected: all green, and the same test counts as before the move (pcm_out 6, tv 61, 20 ring tests).
- [ ] **Step 3:** Commit: `refactor: move pcm_out plugin to repo root for phone + TV`.

### Task 2: C++ capture core (pure, host-tested)

**Files:** create `frame_queue.h/.cpp`, `noise_gate.h/.cpp` and `audio_packet.h` in `pcm_out/android/src/main/cpp/`; create `pcm_out/test_native/capture_test.cpp`; modify `tool/test_native.sh` to build and run it under ASan/UBSan, plus a TSan pass for the queue; add the new `.cpp` files to `CMakeLists.txt`.

**Interfaces — Produces** (names binding):
- **`FrameQueue`** (capacity 8):
  - `bool push(const int16_t* frame480)`: producer only. False means the queue was full; the newest frame is dropped and `dropped` is counted.
  - `bool pop(int16_t* out480)`: consumer only.
  - `uint64_t dropped() const`.
- **`FrameAssembler`:** `template/fn append(const int16_t* samples, int32_t n, FrameQueue&)` collects arbitrary chunk sizes into 480-sample frames and pushes each full one. `reset()`.
- **`NoiseGate`:**
  - `void process(int16_t* frame480)` (in place).
  - `bool isOpen() const`.
  - `GateStats takeStats()` returns `{frames, openFrames, minDb, maxDb}` and resets.
- **`buildAudioPacket(uint8_t out[972], uint32_t seq, uint32_t pin, const int16_t* frame480)`:** LE magic `0x4D54`, version 1, type 0, seq, pin, then 960 B of PCM.

- [ ] **Step 1: Write the failing tests** (functions in `capture_test.cpp`):
  - `assembler_handles_odd_chunks`: chunks of 192, 256 and 7 samples come out as exact 480-sample frames, in order.
  - `full_queue_drops_newest`: after 9 pushes, 8 are queued and `dropped == 1`; the 9th frame is the missing one.
  - `queue_fifo_order`.
  - `gate_opens_at_minus38_and_closes_after_hold`: port the cases from `phone/test/domain/noise_gate_test.dart` 1:1, with the same inputs and the same expectations.
  - `gate_fades_over_one_frame`: the first open frame ramps from 0 linearly.
  - `gate_stats_reset_on_read`.
  - `packet_matches_protocol_vector`: header bytes equal `protocol/test/vectors.json` conventions, e.g. seq 1 and pin 482917 → `544d0100 01000000 655e0700`, and the length is 972.
  - TSan: `queue_stress` has a producer pushing 10^6 frames, each filled with its index, and a consumer popping; every popped frame is uniform and indices only increase.
- [ ] **Step 2:** Run `test_native.sh`. Expected: FAIL (missing symbols).
- [ ] **Step 3:** Implement. The queue uses the same seqlock/atomic pattern as `JitterRing`.
- [ ] **Step 4:** Run `test_native.sh` (all passes plus the JNI check) and `flutter build apk --release` in `tv/`. Expected: green.
- [ ] **Step 5:** Commit: `feat(pcm_out): native frame queue, noise gate and audio packet for capture`.

### Task 3: Oboe input + sender thread + JNI

**Files:** create `pcm_out/android/src/main/cpp/audio_in.h/.cpp`; modify `jni_bridge.cpp`, `NativeAudio.kt` (new `external fun`s) and `CMakeLists.txt`.

**Interfaces — Produces** (JNI on `NativeAudio`):
- `nativeCaptureStart(): Int` returns 0 for OK, else a negative code: `-1` open failed, `-2` format_unsupported.
- `nativeCaptureStop()`: synchronous drain (see Global Constraints).
- `nativeSetTarget(host: String?, port: Int, pin: Int)`: a null host clears the target.
- `nativeSetSendFd(fd: Int)`: native owns that dup from now on and closes it after the next swap.
- `nativeCaptureStats(out: LongArray)`: fixed index order, documented in both C++ and Kotlin: capturing, inputLatencyMs (−1 unknown), framesCaptured, framesSent, framesDropped, sendErrors, sendGapMaxMs (last 1 s; −1 none), levelRmsPermille, gateOpenFrames, gateFrames, gateMinDbX10, gateMaxDbX10, mmap (−1/0/1), exclusive, burst, xruns.

Guidelines:
- **Input callback:** `FrameAssembler.append` into `FrameQueue`, then `sem_post` (or equivalent) once per full frame. Return `Continue`.
- **Sender thread** (started by `nativeCaptureStart`, `setpriority` high):
  - Loop: wait on the semaphore with about a 50 ms timeout, then pop every frame.
  - Per frame: gate, `buildAudioPacket` with the native `seq` (process-wide u32, continues across bursts), then `sendto(fd, target)` when a target is set.
  - Track the max gap between consecutive sends over the last second, and `levelRms`.
  - A send error increments `sendErrors` and is otherwise ignored.
  - Read the target behind a small mutex: the sender thread is not real-time. Read the fd from an atomic; on a change, close the old dup.
- **Stop:** stop and close the input stream, then signal the sender to drain the queue and exit, join it, then return.
- **Error callback → reopen:** same pattern as `AudioOut` (a manager reopens while still capturing; the sender keeps waiting).
- **Stats:** `inputLatencyMs` via `calculateLatencyMillis()` from the stats caller, under the same try-lock pattern as `AudioOut::stats()`.
- **Logging:** log the open config line once, like `AudioOut`.

- [ ] **Step 1:** Add a host test `stop_drains_before_return` against a small test seam. Pull the drain loop into a function that takes a `FrameQueue&` and a send callback, so it can run without Oboe. It must send all queued frames, then return. Run it: FAIL.
- [ ] **Step 2:** Implement `audio_in` and the JNI. Run `test_native.sh` (the JNI-name check must cover the new functions) and `flutter build apk --release` in `tv/` and `phone/` (the phone build runs once Task 5 adds the dependency; until then the tv build is enough).
- [ ] **Step 3:** Commit: `feat(pcm_out): Oboe input with native sender thread`.

### Task 4: Kotlin + Dart plugin API for the phone

**Files:** `NativeReceiver.kt`, `PcmOutPlugin.kt`, `pcm_out/lib/pcm_out.dart`, `pcm_out/test/pcm_out_test.dart`.

**Interfaces — Produces (Dart):**
- **`NativeReceiver`:**
  - `start({int port = 5004})` already exists; the phone passes `0`.
  - New `Future<void> rebind()`.
  - `socketEvents` emits `'bound <port>'` on each (re)bind (the TV's existing log text keeps working).
- **`class CaptureStats`:** fields mirroring the JNI order; −1 maps to null; `levelRms` is a double from permille; the dB fields are doubles.
- **`class NativeCapture`:**
  - `Future<void> start()` throws `PlatformException` with code `open_failed` or `format_unsupported`.
  - `Future<void> stop()`.
  - `Future<void> setTarget(String? host, int port, int pin)`.
  - `Future<CaptureStats> stats()`.

Guidelines (Kotlin):
- **Port 0:** `NativeReceiver` binds `port` as given (0 = ephemeral). After every bind, call `NativeAudio.nativeSetSendFd(ParcelFileDescriptor.fromDatagramSocket(s).detachFd())`. `detachFd` gives native sole ownership of the dup.
- **`rebind()`:** closes the current socket so the receive loop's existing rebind path runs. Return after the new bind, or immediately with the event to follow; the builder chooses.
- **Off the main thread:** capture methods run on the existing sender executor, not the main thread, because `stop()` blocks for the drain.
- **TV unaffected:** the TV calls none of the capture methods; `start(5004)` behaves exactly as before.

- [ ] **Step 1: Write the failing Dart tests** (mock channels):
  - "capture start maps error codes to PlatformException".
  - "setTarget passes host/port/pin and null clears".
  - "CaptureStats maps −1 to null and permille to 0..1".
  - "socketEvents carries the bound port".
  - "rebind invokes the channel".
- [ ] **Step 2:** Run `flutter test` in `pcm_out/`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test && flutter analyze` in `pcm_out/` and `tv/`, then `flutter build apk --release` in `tv/`. Expected: green.
- [ ] **Step 5:** Commit: `feat(pcm_out): capture API and ephemeral-port socket for the phone`.

### Task 5: Phone Dart on the native plugin

**Files:**
- Modify: `phone/pubspec.yaml` (add `pcm_out: path: ../pcm_out`, remove `record`), `session_service.dart`, `link_stats.dart`, `main.dart`.
- Rewrite: `mic_service.dart`.
- Tests: `phone/test/support/fakes.dart`, `phone/test/support/fake_tv.dart`; replace `phone/test/integration/session_loopback_test.dart` and `phone/test/data/udp_sender_test.dart` with fake-port session tests.
- Delete: `udp_sender.dart`, `frame_slicer.dart`, `noise_gate.dart` (Dart) and their tests, plus `phone/test/data/mic_service_test.dart` (rewritten).

**Interfaces:**
- **Consumes:** Task 4's `NativeReceiver` (port 0) and `NativeCapture`.
- **Produces:**
  - `abstract class PacketPort` in `session_service.dart`:
    - `Stream<Incoming> get incoming`
    - `void send(Uint8List bytes, String host, int port)`
    - `Future<void> rebind()`
    - `Stream<int> get boundPorts`
    
    It is implemented by a small adapter over `NativeReceiver` in `main.dart` or `data/services`.
  - `abstract class Mic { Future<void> open(); Future<void> close(); bool get isOpen; Object? get error; Stream<double> get level; }`. `MicService` implements it, over `NativeCapture`. `MicViewModel` depends on `Mic`, which is why `FakeMic` exists.
  - `SessionService({required PacketPort port, required NativeCaptureTarget target /* setTarget */, …})`. Keep it testable: inject a `Future<void> Function(String? host, int port, int pin) setTarget`.

Guidelines:
- **Target:** when the state becomes connected, call `setTarget(tv, 5004, pin)`. On any other state, call `setTarget(null, 0, 0)`.
- **Rebind:** on a `boundPorts` event after the first, clear the target and make `ConnectionMachine` send a HELLO now. Add a small `rebound(now)` method to the machine: it sets `connecting` and sends HELLO, keeping today's timeouts. The target is set again on the next ACK.
- **Send-error monitor:** the mic service already polls stats at 10 Hz. If `sendErrors` increased in every poll for ≥ 1 s while capturing, call `port.rebind()` once (re-arm after the next bound event).
- **Talk stop:** in `MicViewModel._onClose` / `TalkGate`, call `mic.close()` **before** `session.sendEnd()`. Check and keep the existing order of the haptics, foreground service and focus calls. `sendAudio`/`beginTalk` go away; the native send condition replaces `_talking`.
- **Mic service:** `open` = `capture.start()`, then 10 Hz stats polling → `level` (levelRms × 4 for the meter, as today's RMS); `close` = `capture.stop()`. Map errors to `error`, and `format_unsupported` to the copy "This phone's microphone format isn't supported.".
- **`LinkStats`:** `phoneMs` = `inputLatencyMs + 5` when non-null, else `kPhoneDelayEstimateMs`. Add a setter `setPhoneLatency(int? ms)`, fed from the mic service's stats.
- **Debug lines** from the 1 s stats: `audio sent=… nextSeq=… rtt=… delay=… sendGapMaxMs=…` and `gate open=x/y min=..dB max=..dB`.

- [ ] **Step 1: Write the failing tests:**
  - "connected sets the target; lost/disconnected clears it".
  - "rebind clears target, HELLO now, target back on ACK".
  - "stop capture completes before END is sent" (the fake capture records the order).
  - "send errors rising for 1 s call rebind once".
  - "phoneMs uses measured input latency + 5, falls back to 40".
  - "mic service maps format_unsupported to the error copy".
  - "level stream from stats".
  
  Keep the existing `MicViewModel` and stats-card tests passing.
- [ ] **Step 2:** Run `flutter test` in `phone/`. Expected: FAIL.
- [ ] **Step 3:** Implement. Delete the replaced files and their tests. Run `tokensave_search literal` for `UdpSender|FrameSlicer|RecordPcmSource|NoiseGate(|package:record`; expected: no hits in `phone/lib` or `phone/test`.
- [ ] **Step 4:** Run `flutter test && flutter analyze` in `phone/`, `test_native.sh`, and `flutter build apk --release` in `phone/` and `tv/`. Expected: green. `unzip -l` on the phone APK shows `liblanmic_audio.so` for arm64-v8a.
- [ ] **Step 5:** Commit: `feat(phone): native Oboe capture and sender`.

> **Stop here** and report to the owner.

### Task 6: Emulator + device check (main session with the owner)

- [ ] Emulator (phone and TV apps on one AVD over 127.0.0.1): the phone log shows `audio sent≈100/s` (not 200) and `sendGapMaxMs ≤ 12`; the TV is receiving with low loss.
- [ ] Pixel 7 + Chromecast, hotspot then router:
  - phone `inputLatencyMs`, `mmap`, `sendGapMaxMs`;
  - TV `jitter`, `target`, `tv`, `lost`;
  - Delay on the card.
  
  Targets: TV jitter ≤ 5 ms, target 10–20 ms, Delay "Good".
- [ ] Keep talking in the background for 60 s; a call interruption; back-to-back bursts; Wi-Fi toggle (rebind → reconnect).

### Task 7: Audit

- [ ] Run `cpp-reviewer` on the capture C++ (callback safety, SPSC, fd ownership and swap, the drain on stop).
- [ ] Run `kotlin-reviewer` on the port-0 mode, the fd hand-off, `rebind` and the capture executor.
- [ ] Run `flutter-reviewer` on `phone/lib` and `pcm_out/lib` (target lifecycle, rebind, END ordering, deletions).
- [ ] Fix CRITICAL/HIGH, re-run everything, and commit `fix: …` per area.
