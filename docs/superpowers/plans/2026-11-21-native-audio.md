# Native Low-Latency TV Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **This plan gives guidelines, names and test cases, not code bodies.** Write idiomatic code from them in ponytail mode (smallest complete change).

**Goal:** Cut the TV share of the delay from ~200 ms to ≤ 40 ms by replacing the Dart timer → Kotlin queue → AudioTrack path with a Kotlin UDP receiver feeding a C++ jitter ring that an Oboe/AAudio output callback pulls from. Also add low-latency Wi-Fi and voice-traffic marking, and fix two phone layout issues.

**Architecture:** Kotlin owns UDP port 5004 (a process singleton). It pushes valid AUDIO from the accepted phone into a lock-free C++ jitter ring through JNI, and forwards every other packet to Dart. Dart keeps the protocol brain: registry, PIN, ACK/REJECT and STATS. It tells native which phone to accept, and polls native stats. A native stream-manager thread opens and closes the Oboe stream; the data callback only reads the ring.

**Tech Stack:** Oboe (Google Maven, prefab) · NDK + CMake 3.22.1 · C++17 · Kotlin · Flutter MethodChannel/EventChannel · Dart.

**Spec:** `docs/superpowers/specs/2026-11-21-native-audio-design.md`. Section 9 holds the binding decisions. **Context spec:** `docs/superpowers/specs/2026-11-20-connection-stats-design.md` (lost-audio rules, STATS packet).

## Global Constraints

- **Real-time safety:** the Oboe data callback never locks, allocates, logs, does I/O, calls `getTimestamp`/`calculateLatencyMillis`, or stops or closes a stream. It reads only atomics and the ring.
- **Ring thread contract:** the ring has exactly one producer (the Kotlin receive thread through JNI) and one consumer (the callback). Flush is an atomic generation bump (spec 9.1).
- **No protocol change:** wire format, port 5004 and the STATS layout are unchanged. targetSdk stays 34. No new pub dependencies.
- **Oboe:** the latest stable `com.google.oboe:oboe` from Google Maven, exact version pinned, `buildFeatures { prefab = true }`, `find_package(oboe REQUIRED CONFIG)`.
- **Stream request:** 48 kHz; format and channel count unspecified; `LowLatency` + `Exclusive`; `Usage::Media`, `ContentType::Speech`; buffer = 2 × `framesPerBurst` after open.
- **Ring parameters:** 16 slots × 480 samples; target 2 frames until 20 packets, then `ceil((2·jitterMs + 2)/10)` clamped 1..4; drain when depth > target + 1 for 100 ms; PLC = last frame at −6 dB per repeat for up to 3 frames, then silence; the underrun counts as lost only within 100 ms of the last push; resync when the seq distance is outside ±16.
- **Lifecycle:** open the stream on the first accepted push (manager thread). Close after 10 s without a push. Reopen after `ErrorDisconnected` if audio arrived in the last 10 s.
- **Files never to commit:** `settings.gradle*`, `.gradle/`, `local.properties`, `phone/android/gradle/gradle-daemon-jvm.properties`. `git add <paths>` only.
- **Testing:** TDD everywhere a test can run off-device (host C++, Dart). Kotlin/Oboe behaviour is checked on the device in Task 7. Use release builds for measurements.

## Review Focus

1. **Flush while the callback is mid-frame** (END or a new phone during playback): no torn frame, no stale slot played after the flush. Pinned in Task 3 ("flush via generation").
2. **Back-to-back push-to-talk bursts** with a ~1 s gap: the second burst re-prebuffers and its first word isn't eaten by stale PLC. Pinned in Task 3 ("idle returns to wait-for-target").
3. **Phone app restarted mid-session** (seq jumps by millions or wraps): resync, no seconds of silence. Pinned in Task 3 ("resync on a big seq jump", "u32 wrap").
4. **TV boots before Wi-Fi, or Wi-Fi drops:** Kotlin rebinds by itself and Dart keeps serving HELLO afterwards. Pinned in Task 5 (Dart wrapper surfaces `bound`/`error`) and Task 7 (device: toggle Wi-Fi).
5. **HDMI or audio route change while talking:** the stream reopens and audio resumes. Pinned in Task 7 (device: switch TV input/audio output during a burst).

## File Structure

| File | Responsibility |
|---|---|
| `wifi_band/lib/wifi_band.dart`, `wifi_band/android/.../WifiBandPlugin.kt` (modify) | add `setLowLatency(bool)` |
| `phone/lib/data/services/udp_sender.dart` (modify) | DSCP EF on bind |
| `phone/lib/ui/features/mic/view_models/mic_view_model.dart`, `views/mic_screen.dart`, `views/stats_card.dart` (modify) | Wi-Fi lock while connected; Delay no-wrap; Disconnect visible |
| `tv/packages/pcm_out/android/build.gradle.kts` (modify) | NDK/CMake, prefab, Oboe dependency |
| `tv/packages/pcm_out/android/src/main/cpp/CMakeLists.txt` (create) | `lanmic_audio` shared lib |
| `.../cpp/jitter_ring.h/.cpp` (create) | pure C++ ring: ordering, target, drain, PLC, counters, generation flush |
| `.../cpp/audio_out.h/.cpp` (create) | Oboe stream, manager thread, data and error callbacks, stats snapshot |
| `.../cpp/jni_bridge.cpp` (create) | JNI entry points |
| `tv/packages/pcm_out/test_native/jitter_ring_test.cpp` + `tool/test_native.sh` (create) | host-run ring tests (clang++, ASan/UBSan) |
| `tv/packages/pcm_out/android/src/main/kotlin/.../NativeReceiver.kt` (create), `PcmOutPlugin.kt` (rewrite) | socket singleton, validation, JNI push, channels |
| `tv/packages/pcm_out/lib/pcm_out.dart` (rewrite) | Dart API `NativeReceiver` + `NativeStats` |
| `tv/lib/domain/audio_engine.dart` (create), `receiver_engine.dart` (rewrite), `receiver_status.dart` (keep) | domain interface + engine on top of it |
| `tv/lib/data/services/engine_factory.dart`, `receiver_task_handler.dart` (modify) | adapter, Wi-Fi lock, log line |
| **delete:** `tv/lib/domain/jitter_buffer.dart`, `playback_pump.dart`, `jitter_meter.dart`, `tv/lib/data/services/udp_socket_service.dart` and their tests | replaced by native |

---

### Task 1: Phone quick wins (Wi-Fi lock, DSCP, layout)

**Files:** `wifi_band/lib/wifi_band.dart`, `WifiBandPlugin.kt`, `wifi_band/test/wifi_band_test.dart`, `phone/lib/data/services/udp_sender.dart`, `mic_view_model.dart`, `mic_screen.dart`, `stats_card.dart`, phone tests.

**Interfaces — Produces:** `WifiBandReader.setLowLatency(bool on) → Future<void>` (channel method `setLowLatency`). It never throws; failures are swallowed with a debug log.

Guidelines:
- **Kotlin:** a single lazily created `WifiLock` (`WIFI_MODE_FULL_LOW_LATENCY` on API ≥ 29, else `WIFI_MODE_FULL_HIGH_PERF`), `setReferenceCounted(false)`. Acquire/release on demand.
- **Phone VM:** call `setLowLatency(true)` when the state reaches connected and `false` on disconnect/dispose. Inject it the same way as `readBand`, with a no-op default.
- **`UdpSender`:** after bind, best-effort `setRawOption(RawSocketOption.fromInt(0 /*IPPROTO_IP*/, 1 /*IP_TOS*/, 0xB8))` in a try/catch. One-line comment: Android/Linux constants, best effort.
- **Stats card:** the Delay value sits on one line and scales down to fit (no wrap). Keep the quality word right-aligned.
- **Mic screen:** on a 412×915 logical viewport, live, Details open, the Disconnect button is fully on screen. Use tighter gaps and/or a talk circle ≥ 176 dp; don't change the design's order.

- [ ] **Step 1: Write the failing tests.**
  - `wifi_band`: "setLowLatency sends the flag" and "setLowLatency swallows PlatformException".
  - Phone VM: "low-latency lock on at connected, off at disconnect".
  - Widget: "Delay value never wraps (one line at 'about 294 ms')". Assert the rendered value's height ≈ one line; use `tester.getSize`.
  - Widget: "Disconnect fully visible at 412×915 live with Details open". Assert its rect lies inside the screen.
- [ ] **Step 2:** Run `flutter test` in `wifi_band/` and `phone/`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test && flutter analyze` (wifi_band, phone) and `flutter build apk --debug` (phone). Expected: PASS.
- [ ] **Step 5:** Commit: `feat(phone): low-latency Wi-Fi lock, voice DSCP, stats layout fixes`.

### Task 2: Native scaffold in `pcm_out` (NDK + Oboe builds)

**Files:** `tv/packages/pcm_out/android/build.gradle.kts`, `.../src/main/cpp/CMakeLists.txt`, `.../cpp/jni_bridge.cpp` (stub), `PcmOutPlugin.kt` (load the lib only).

Guidelines:
- **Gradle:** `externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }`, `buildFeatures { prefab = true }`, `dependencies { implementation("com.google.oboe:oboe:<latest stable>") }`, and `ndkVersion` matching the app's `flutter.ndkVersion`, or omit it if the plugin inherits.
- **CMake:** C++17, `-Wall -Werror`, shared lib `lanmic_audio` linking `oboe::oboe log`.
- **JNI stub:** one native method `nativeVersion(): Int` returning a constant. Kotlin calls `System.loadLibrary("lanmic_audio")` in a companion/singleton init.

- [ ] **Step 1:** Run `cd tv && flutter build apk --debug`. Expected: it builds before the change (baseline).
- [ ] **Step 2:** Add the scaffold. Run `flutter build apk --debug` and `flutter build apk --release`. Expected: both build. `unzip -l` on the release APK shows `lib/armeabi-v7a/liblanmic_audio.so` and `lib/arm64-v8a/liblanmic_audio.so`.
- [ ] **Step 3:** Commit: `build(pcm_out): NDK + Oboe scaffold`.

### Task 3: C++ jitter ring with host tests

**Files:** `.../cpp/jitter_ring.h`, `.../cpp/jitter_ring.cpp`, `tv/packages/pcm_out/test_native/jitter_ring_test.cpp`, `tv/packages/pcm_out/tool/test_native.sh` (compile with `clang++ -std=c++17 -O1 -g -fsanitize=address,undefined` and run; plain `assert`, no test framework).

**Interfaces — Produces** (names binding, bodies yours):
- `JitterRing` with:
  - `push(const int16_t* pcm480, uint32_t seq, int64_t nowNs)`: producer only.
  - `read(int16_t* out, int32_t frames, int64_t nowNs)`: consumer only. It always fills `frames` samples, using PLC or silence.
  - `flush()`: any thread; bumps the generation.
  - `counters()`: any thread; returns a POD snapshot `{received, played, lost, discarded, late, depthFrames, targetFrames, jitterMs, lastPushNs}`.
- Time is always passed in (`nowNs`), never read inside, so the tests are deterministic.

Ring rules (from spec 4.2 and section 9): see Global Constraints. Jitter uses the RFC 3550 estimator (gain 1/16) on arrival time vs `seq × 10 ms`, exactly like the Dart `JitterMeter` it replaces.

- [ ] **Step 1: Write the failing tests** (each a function in `jitter_ring_test.cpp`, named as below):
  - `prebuffers_to_target`: no samples out (silence, not counted) until 2 frames are pushed.
  - `in_order_across_burst_sized_reads`: push 3 frames tagged by value; reading 192 samples at a time returns them in order with no gaps.
  - `gap_plays_plc_and_counts_lost`: frame `n+1` missing → that slot is the last frame at about half amplitude (−6 dB), `lost == 1`; a later arrival of `n+1` counts as `late`, not played.
  - `plc_fades_to_silence_after_3`: 4 missing slots → the 4th is exact silence.
  - `underrun_counts_only_within_grace`: empty at 50 ms after the last push → lost; at 150 ms → not counted and back to wait-for-target.
  - `idle_returns_to_wait_for_target`: after a 1 s gap, a new burst re-prebuffers before playing.
  - `duplicates_and_late_are_not_lost`.
  - `drain_skips_quiet_frame_when_above_target`: depth target + 3 held for 100 ms → one frame skipped, a quiet one is preferred; `discarded` increments; depth returns to ≤ target + 1.
  - `overflow_beyond_16_counts_discarded`.
  - `resync_on_big_seq_jump`: a jump of +1000 → plays the new seq after prebuffer, with no PLC run.
  - `u32_wrap`: seq `0xFFFFFFFF` then `0` plays in order.
  - `flush_via_generation`: push 3, flush, push new seq → no pre-flush sample is ever read.
  - `adaptive_target`: under 20 packets → 2; steady 10 ms arrivals → 1; arrivals with ±15 ms jitter → 4 (clamped).
  - `jitter_matches_rfc3550`: arrivals 0 ms and 26 ms for seq 0, 1 → `jitterMs == 1`.
- [ ] **Step 2:** Run `tv/packages/pcm_out/tool/test_native.sh`. Expected: FAIL (it doesn't compile, or the asserts fail).
- [ ] **Step 3:** Implement `JitterRing`.
- [ ] **Step 4:** Run the script. Expected: all PASS, with no ASan/UBSan reports. Then run `flutter build apk --debug` in `tv/`. Expected: builds.
- [ ] **Step 5:** Commit: `feat(pcm_out): native jitter ring with host tests`.

### Task 4: Oboe output + manager thread + JNI

**Files:** `.../cpp/audio_out.h/.cpp`, `.../cpp/jni_bridge.cpp`.

**Interfaces — Produces** (JNI on a Kotlin `object NativeAudio`):
- `nativeStart()` / `nativeStop()`: start or stop the manager thread; idempotent.
- `nativePush(buf: ByteBuffer /*direct, 960 B*/, seq: Int, nowNs: Long)`: called from the receive thread; wakes the manager if the stream is closed.
- `nativeFlush()`.
- `nativeStats(out: LongArray)`: fills a fixed layout. Document the index order in one comment in both C++ and Kotlin: received, played, lost, discarded, late, depthMs, targetMs, jitterMs, lastAudioAgeMs (−1 if never), latencyMs (−1 unknown), open (0/1), exclusive (0/1), mmap (0/1/−1 unknown), burst, bufferFrames, xruns.

Guidelines:
- **Manager thread:** sleeps on a condition variable (its own mutex, never shared with the callback). It handles open on demand, close after 10 s without a push, and reopen requested by the error callback.
- **Open:** follow the Global Constraints request. Then `setBufferSizeInFrames(2 × burst)`, and log one `__android_log_print` line with the API, sharing, performance mode, burst, buffer/capacity, rate, channels, format and mmap (`oboe::OboeExtensions::isMMapUsed` if the pinned version has it, else −1).
- **Data callback:** `ring.read` into a small preallocated mono I16 scratch buffer (sized at open for the maximum callback frames). Then write to the stream format (I16 or float), copying mono into every channel. Return `Continue`.
- **Error callback:** `onErrorAfterClose` with `ErrorDisconnected` → ask the manager to reopen if `lastPush` is within 10 s. Never reopen inside the callback itself if the manager can do it.
- **Stats:** `latencyMs` via `calculateLatencyMillis()`, called on the JNI caller's thread, only while open. `xruns` via `getXRunCount()` when supported.

- [ ] **Step 1:** There's no host test for Oboe. Write a short manual check list in the commit body: open log line seen, `dumpsys media.aaudio` shows the stream, reopen after HDMI change. These are run in Task 7.
- [ ] **Step 2:** Implement. Run `test_native.sh` (the ring is still green) and `flutter build apk --release` in `tv/`. Expected: both pass.
- [ ] **Step 3:** Commit: `feat(pcm_out): Oboe low-latency output pulling from the ring`.

### Task 5: Kotlin receiver singleton + Dart plugin API

**Files:** `.../kotlin/.../NativeReceiver.kt` (create), `PcmOutPlugin.kt` (rewrite), `tv/packages/pcm_out/lib/pcm_out.dart` (rewrite), `tv/packages/pcm_out/test/pcm_out_test.dart` (rewrite).

**Interfaces — Produces (Dart, in `pcm_out.dart`):**
- `class NativeStats` with fields mirroring the stats layout; nullable where the native value is −1.
- `class NativeReceiver` with:
  - `Stream<({Uint8List data, String host, int port})> get packets`: EventChannel `pcm_out/packets`. Events are maps `{data, host, port}`; also `{event: 'bound'|'error', message}`, which are exposed separately as `Stream<String> get socketEvents`.
  - `Future<void> start({int port = 5004})`, `Future<void> stop()`.
  - `Future<void> accept(String? host, int? port, int? pin)` (null = accept nobody).
  - `Future<void> send(Uint8List data, String host, int port)`: throws `PlatformException` on IOException.
  - `Future<NativeStats> stats()`.

Guidelines (Kotlin):
- **`NativeReceiver` is an `object` (process singleton).**
  - `start` is idempotent. It spawns a thread at `THREAD_PRIORITY_URGENT_AUDIO` that binds `DatagramSocket(null)` with `reuseAddress = true` on 5004, `trafficClass = 0xB8`, and a 200 ms `soTimeout` for clean shutdown.
  - It retries the bind with a 1→5 s backoff and rebinds after an error, emitting `bound`/`error` events.
- **Per packet:**
  - Reuse one `DatagramPacket` with a 972 B array and one direct `ByteBuffer`.
  - **Valid AUDIO** (magic `0x4D54` LE, version 1, type 0, length 972, PIN = accepted pin, sender = accepted host:port): copy the payload into the direct buffer, then `nativePush`.
  - **END** from the accepted peer: `nativeFlush()` and forward.
  - **Anything else with valid magic/version:** copy the bytes and post `{data, host, port}` to the main looper → EventSink.
  - **Malformed:** drop.
- **`accept`** stores an immutable `(host, port, pin)` triple in an `@Volatile` field and calls `nativeFlush()` when the peer changes.
- **`PcmOutPlugin`:**
  - Methods `start/stop/accept/send/stats`, with `send` on the socket (IOException → `result.error`).
  - `stop` stops both the receive thread and the native side.
  - `onDetachedFromEngine` only clears this engine's channel handlers and EventSink; it never stops the singleton.
  - The EventSink is the most recent `onListen`.

- [ ] **Step 1: Write the failing Dart tests** (mock MethodChannel and EventChannel):
  - "stats maps −1 to null".
  - "accept passes host/port/pin and null clears".
  - "send forwards bytes and surfaces PlatformException".
  - "packets stream decodes {data,host,port} events and routes bound/error to socketEvents".
- [ ] **Step 2:** Run `cd tv/packages/pcm_out && flutter test`. Expected: FAIL.
- [ ] **Step 3:** Implement Kotlin and Dart.
- [ ] **Step 4:** Run `flutter test && flutter analyze` in `pcm_out`, and `flutter build apk --release` in `tv/`. Expected: PASS and the build succeeds.
- [ ] **Step 5:** Commit: `feat(pcm_out): native UDP receiver feeding the ring`.

### Task 6: TV Dart engine on the native receiver

**Files:**
- Create: `tv/lib/domain/audio_engine.dart`.
- Rewrite: `tv/lib/domain/receiver_engine.dart`.
- Modify: `tv/lib/data/services/engine_factory.dart`, `tv/lib/data/services/receiver_task_handler.dart`.
- Tests: rewrite `tv/test/domain/receiver_engine_test.dart` and `receiver_engine_stats_test.dart`, update `tv/test/support/engine_rig.dart`.
- Delete: `jitter_buffer.dart`, `playback_pump.dart`, `jitter_meter.dart`, `udp_socket_service.dart` and their tests.

**Interfaces:**
- **Consumes:** Task 5's `NativeReceiver` (data layer only), plus `SessionRegistry`, `LossMeter`, `ReceiverStatus` (unchanged).
- **Produces (domain, no Flutter imports):** `abstract class AudioEngine` with:
  - `Stream<Datagram> get packets`
  - `Future<void> start()`, `Future<void> stop()`
  - `Future<void> accept(Peer? peer, int pin)`
  - `void send(Uint8List d, Peer to)`
  - `Future<AudioStats> stats()`

  `AudioStats` is a domain record with the same fields as `NativeStats`.
- **Adapter:** `NativeAudioEngine implements AudioEngine` in `engine_factory.dart`.

Guidelines (engine behaviour):
- **Packets:** decode with `decodePacket` and route through `registry.onPacket` as today.
- **Active phone changes:** when `registry.activePhone` changes (new phone, or `null` by timeout), call `accept(phone, pin)` **before** sending the ACK, then send it. The 100 ms housekeeping detects a timeout and calls `accept(null, pin)`.
- **Stats poll** every 250 ms (guarded against overlap):
  - `TvState.receiving` iff `lastAudioAgeMs != null && < 500`.
  - Once a second: deltas of played/lost/discarded go into `LossMeter`. Use `played` for clean slots, `lost` as lost, and `discarded` via `LossMeter.discarded`. Watch for counter resets on native restart: a negative delta means rebaseline.
  - While receiving, `tvDelay` sample = `depthMs + (latencyMs ?? 0)`, mean of the last 5 as before.
  - Send STATS with the native `jitterMs`.
- **`ReceiverStatus` counters:** `framesRx` = received, `framesDropped` = late, `underruns` = lost.
- **No more** pump timer, sink start/stop, audio timeout or bind supervisor in Dart. `start()` calls `engine.start()` once; native retries the bind.
- **Task handler:**
  - Wi-Fi: call `const WifiBandReader().setLowLatency(true)` at `onStart` and `false` at `onDestroy`.
  - The log line adds `target=… depth=… out=… mmap=… burst=… xruns=…`.
  - Log the `socketEvents` lines.

- [ ] **Step 1: Write the failing tests** (`FakeAudioEngine` records `accept`/`send`, emits packets, returns scripted `AudioStats`):
  - "HELLO from a new phone: accept(peer) is called before the ACK is sent".
  - "activePhone timeout calls accept(null)".
  - "wrong PIN → REJECT, no accept".
  - "receiving iff lastAudioAgeMs < 500".
  - "loss deltas feed LossMeter; a native counter reset rebaselines instead of going negative".
  - "tvDelayMs = mean of last 5 (depth + latency) while receiving, kept after the burst".
  - "STATS once a second to the active phone with native jitter; band only in the first 3".
  - "stats poll does not overlap".
  - "status counters map received/late/lost".
- [ ] **Step 2:** Run `cd tv && flutter test test/domain`. Expected: FAIL.
- [ ] **Step 3:** Implement. Delete the old files and their tests.
- [ ] **Step 4:** Run `flutter test && flutter analyze` in `tv/`, then `flutter build apk --release`. Expected: PASS and the build succeeds. Also run `tokensave_search literal` for `JitterBuffer|PlaybackPump|UdpSocketService|PcmOutSink`. Expected: no references left.
- [ ] **Step 5:** Commit: `feat(tv): drive audio through the native receiver`.

> **Stop here.** Report to the owner. Task 7 needs the devices; Task 8 is the audit.

### Task 7: Device check and measurement (owner + main session)

- [ ] Install the release APKs on the Pixel 7 and the Chromecast.
- [ ] Talk for 60 s on the hotspot, then on the router. Record Delay, TV share, Lost audio and Jitter from the screens, and the TV log line (`target/depth/out/mmap/burst/xruns`).
- [ ] While talking, run `adb shell dumpsys media.aaudio` on the TV. Record whether the stream is MMAP/exclusive, plus burst and buffer.
- [ ] Back-to-back bursts: no first-word cut after the first burst.
- [ ] Toggle the TV's Wi-Fi. The receiver rebinds and the phone reconnects.
- [ ] Change the TV's audio route/HDMI input during a burst. Audio resumes.
- [ ] Clap test (research doc) for true mouth-to-speaker time.
- [ ] Acceptance: TV share ≤ 40 ms (≤ 60 ms if MMAP was refused), Lost audio < 1 %, no clicks.

### Task 8: Audit

- [ ] Run `cpp-reviewer` on `pcm_out/android/src/main/cpp/**`. Focus on real-time safety in the callback, atomics/memory order, the generation flush, and manager-thread lifetime.
- [ ] Run `kotlin-reviewer` on `NativeReceiver.kt`/`PcmOutPlugin.kt`. Focus on the singleton across two engines, socket rebind, JNI buffer reuse, and main-thread EventSink.
- [ ] Run `flutter-reviewer` on `tv/lib`, `phone/lib`, `wifi_band`, `pcm_out/lib`.
- [ ] Fix CRITICAL/HIGH, re-run all tests and `test_native.sh`, and commit `fix: …` per area.
