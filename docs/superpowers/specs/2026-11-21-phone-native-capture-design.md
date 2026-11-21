# Phone native capture (Oboe/AAudio input): design

Status: draft for approval · 2026-11-21 · branch `feat/latency-stats-low-latency-audio`
Builds on: `2026-11-21-native-audio-design.md` (TV native playout), `2026-11-20-connection-stats-design.md`.

## 1. Why

Measured on the Pixel 7 → Chromecast after the TV went native (2026-11-21): **Delay ≈ 90–110 ms "OK"**.

What's left:
- **Phone part:** a fixed 40 ms guess.
- **TV jitter buffer target:** 30 ms, set by about 12 ms of measured jitter.
- **TV output:** about 40 ms of shared MMAP (the TV's limit).

The jitter comes mostly from the phone. The `record` plugin hands over large chunks, so `FrameSlicer` emits several frames at once and they leave in clumps. The TV log showed 120 ms gaps followed by piles of frames.

On the emulator, the plugin also returned 2× the data despite asking for mono 48 kHz, and nothing checks for that.

The owner chose **approach A: Oboe input in a shared native plugin**.

## 2. Goals, non-goals, anti-goals

**Goals**
- Frames leave the phone one at a time, every 10 ms: the send-gap p99 is ≤ 12 ms while talking.
- The phone part is **measured** (input latency + frame assembly), and is ≤ 15 ms on the Pixel 7.
- TV-measured jitter ≤ 5 ms on the hotspot, so the TV target drops to 10–20 ms.
- Delay shows **Good** (< 100 ms) on the hotspot.
- The recorder must deliver mono 48 kHz, or the start fails with a clear error. It never silently sends 2× data.
- Talking keeps working with the app in the background (Keep talking mode), as today.

**Non-goals**
- 5 ms frames or any protocol change. The wire stays 10 ms / 960 B.
- Echo cancellation, iOS, and UI changes.
- Changes to the TV beyond the plugin's new path.

**Anti-goals**
- Socket I/O, locks, allocation or logging inside the input callback.
- Audio sent from a different socket or port than the HELLO. The TV would drop it.
- Losing the noise gate (the TV → mic echo-loop fix) or its calibration log line.

## 3. Approaches

| | What | Trade-off |
|---|---|---|
| **A (picked)** | Oboe/AAudio input in C++ inside a shared root-level plugin, with a native sender thread | Lowest and measured latency (MMAP input on the Pixel 7). Reuses the TV's proven Oboe/CMake/JNI/socket code. Moving the plugin touches the TV's pubspec. |
| B | Kotlin `AudioRecord` low-latency, with a Kotlin sender | No C++ on the phone; input ~10–20 ms; a second audio stack to maintain. |
| C | Shrink the `record` plugin's buffer | Cheapest, but chunks and Dart hops remain, and small buffers fail on some phones. Rejected. |

## 4. Design

### 4.1 Shared plugin

- **Move:** `tv/packages/pcm_out` → repo root `pcm_out/` (like `wifi_band/`). It keeps its package name and Kotlin package (my call: no JNI or package renames). `test_native.sh` moves with it.
- **Paths:**
  - `tv/pubspec.yaml`: `path: ../pcm_out`.
  - `phone/pubspec.yaml`: adds `pcm_out: path: ../pcm_out` and drops `record`.
- **CLAUDE.md:** update its layout section.

### 4.2 Who does what on the phone

```
Mic ─▶ Oboe input callback (C++) ─▶ SPSC frame queue (480-sample frames) ─▶ sender thread (C++):
        gate → 12 B header (magic, v1, type 0, seq, pin) + 960 B → sendto(fd) ─▶ TV :5004
Kotlin NativeReceiver(port 0) owns the UDP socket (DSCP EF), receives ACK/REJECT/STATS ─▶ EventChannel ─▶ Dart
Dart SessionService: HELLO/heartbeat, ACK/RTT, STATS, END via send(); tells native the target (TV ip:port, pin)
Dart MicViewModel/TalkGate: unchanged; the mic service now starts/stops native capture and reads the level from stats
```

- **One socket.** The phone reuses `NativeReceiver` with `start(port: 0)` (an ephemeral port), so HELLO, END and audio all leave from the same ip:port.
  - Kotlin hands a **duplicated fd** of that socket to native (`ParcelFileDescriptor.fromDatagramSocket(...)`) and re-hands it after every rebind.
  - The sender thread uses `sendto` on it. An `EPERM`/`ENETUNREACH` counts as a send error and never stops the thread; Kotlin's rebind loop recovers the socket.
  - AUDIO never arrives at the phone, so the jitter ring stays unused there.
- **The input callback does only this:** copy samples into the current 480-sample frame. When the frame is full, publish it to an SPSC queue (8 frames) and wake the sender with a non-blocking signal (`sem_post`, or the builder's equivalent).
  - If the queue is full, the oldest frame is dropped and counted.
  - No socket I/O, no locks, no allocation.
- **The sender thread** (normal thread, high priority) runs per frame:
  - **NoiseGate**, ported from `phone/lib/domain/noise_gate.dart`: opens at −38 dBFS, closes below −44 dBFS, hold 25 frames, 1-frame fades, gated frames become silence (never drops). Its open/close counters feed the calibration line.
  - **Packet:** builds the AUDIO packet with its own u32 `seq` (wraps) and the configured PIN, then `sendto`s the target.
  - **Send only when** both capture and a target are set.
- **Stream request:**
  - Input, `LowLatency`, `Exclusive` (falls back to shared), `InputPreset::VoicePerformance` (falls back to `Unprocessed` if open fails).
  - 48 kHz, mono, I16. Sample-rate and channel conversion are allowed.
  - **After open, the stream must report 48000 Hz and 1 channel**, else close it and fail the start with `format_unsupported`.
  - Buffer: Oboe's default for input.
  - **Logging:** log one config line (API, sharing, perf mode, burst, rate, channels, MMAP).
- **Lifecycle:** capture starts on talk-open and stops on talk-close, as `record` does today. The stream is opened on start and closed on stop, by the calling thread. Then error callback → if still capturing, ask a manager to reopen, the same pattern as the TV `AudioOut`.

### 4.3 Dart side (phone)

- **`SessionService`** sends HELLO and END through the plugin `send`, and reads ACK, REJECT and STATS from the plugin `packets`.
  - When the state becomes connected it calls `setTarget(tvHost, 5004, pin)`; when it leaves connected it calls `setTarget(null)`.
  - `sendAudio` is removed: native sends audio.
  - The burst order stays correct: **stop capture first, then send END**, so END can't overtake the last frames.
- **The mic service** keeps today's interface (`open`, `close`, `isOpen`, `error`, `level`), so `MicViewModel` and `TalkGate` don't change.
  - `open` starts native capture; `close` stops it.
  - `level` is polled from native stats at 10 Hz (RMS 0..1, as now), which also feeds the 1 s stall watchdog.
  - A start failure (`format_unsupported`, permission, device busy) sets `error`, as `record` failures do today.
- **Measured phone part:** `LinkStats` gets `phoneMs` = native `inputLatencyMs` + 5 ms (the average wait to fill a 10 ms frame) once it's known. Until then, the 40 ms constant stays as the fallback.
- **Debug lines are kept,** fed from native stats: `audio sent=N nextSeq=S rtt=… delay=…` and `gate open=x/100 min=..dB max=..dB`, plus a new `sendGapMaxMs=…`.
- **Removed:** `RecordPcmSource`, the old `MicService` internals, `FrameSlicer`, the Dart `NoiseGate` (its tests move to C++ host tests), `UdpSender` (tests switch to a fake port), and the `record` dependency.
- **Unchanged:** `AudioFocus` (our own focus handling), permissions, the foreground service, the Wi-Fi lock, DSCP (now on the Kotlin socket) and the UI.

### 4.4 Native stats (phone)

`captureStats()` → `{capturing, inputLatencyMs, framesCaptured, framesSent, framesDropped, sendErrors, sendGapMaxMs (last 1 s), levelRms, gateOpenFrames, gateFrames, gateMinDb, gateMaxDb, mmap, exclusive, burst, xruns}`. The gate fields reset on read, matching today's `takeStats`.

## 5. Constraints

- The same real-time rules as the TV: the callback only copies and publishes. The SPSC queue uses the seqlock or atomics pattern from `JitterRing`.
- `test_native.sh` grows host tests for the frame queue and the ported gate (ASan/UBSan plus a TSan producer/consumer pass). The JNI-name check covers the new `external fun`s.
- The phone stays at minSdk 26 and targetSdk 34. `VoicePerformance` needs API 29; on API 26–28 use `Unprocessed`/`Generic`.
- `RECORD_AUDIO` is still requested by the Dart `PermissionService` before capture.
- Release builds for any measurement.

## 6. How we know it worked

- Phone log: `sendGapMaxMs` ≤ 12 while talking, and `inputLatencyMs` reported, with MMAP true on the Pixel 7.
- TV log, on the hotspot and the router, before and after: `jitter` ≤ 5 and `target` 10–20 ms.
- The phone card shows Delay "Good" on the hotspot.
- The emulator sends 100 frames/s, not 200 (Oboe converts its real format; see section 7.6).
- Back-to-back bursts, Keep talking in the background for 60 s, and a phone call interruption all behave as today.

## 7. Decisions after the builder check (my calls, 2026-11-21)

1. **fd ownership:** Kotlin hands native a dup'd fd through `nativeSetSendFd(fd)`; native stores it in an atomic.
   - Only the sender thread uses or closes fds. On the next frame after a swap, it closes the replaced dup.
   - Kotlin never closes a dup it handed over.
2. **Rebind:**
   - **The new port:** a phone rebind (port 0) gets a **new source port**. Kotlin emits `bound` with the port.
   - **HELLO first:** on that event, Dart clears the target (`setTarget(null)`) and makes the connection machine send a HELLO at once. Audio resumes only after the next ACK sets the target again. Audio is never sent from an unannounced port.
   - **Send errors trigger it:** native counts send errors (EPERM while backgrounded, ENETUNREACH). If they keep rising across polls for ≥ 1 s, Dart calls a new `rebind()` method (Kotlin closes and rebinds). This replaces the Dart `UdpSender`'s close-on-error rebind.
3. **The END ordering is enforced natively:**
   - `stopCapture()` is synchronous. It stops the input stream, lets the sender drain and send every queued full frame, and returns only when the sender is idle.
   - Then Dart sends END.
   - Native sends only while capture is started **and** a target is set. That's the native equivalent of today's `_talking` guard.
4. **Background:** the foreground service, its microphone type and the manifest stay as they are today; the `record` plugin already captured under them. The plugin's own manifest declares **no** permissions or service types: RECORD_AUDIO stays in the phone app manifest only, so nothing leaks into the TV.
5. **Plugin move:**
   - The shared library holds both the ring and capture. The phone carrying the unused ring (tens of KB) is accepted.
   - `nativeFlush` on the phone is harmless: the ring exists and stays idle.
   - Update `pubspec.lock` (via `flutter pub get`), `test_native.sh` paths, CLAUDE.md and any script that names `tv/packages/pcm_out`.
6. **Oboe format (this replaces the §4.2 check):**
   - Request 48 kHz, mono and I16 with conversion **allowed**. Oboe's flowgraph converts the device's real format correctly, so a 2× stream can't happen (that was the `record` plugin's bug).
   - After open, the sanity check stays: the app-side rate is 48000 and channels is 1. If either is off, fail with `format_unsupported`.
   - The §6 emulator check becomes "the emulator sends 100 frames/s, not 200".
7. **Latency:**
   - `inputLatencyMs` = `calculateLatencyMillis()` from the stats call. It's "known" after the first successful value, MMAP or not.
   - The ≤ 15 ms goal applies when MMAP is granted. Otherwise record the value and don't tune blindly.
8. **Continuity:**
   - The sender thread runs from `startCapture` to `stopCapture`.
   - On a stream disconnect, a manager reopens the stream while the sender keeps waiting.
   - The gate state and the u32 AUDIO `seq` carry on across reopen and across bursts in the same process. The TV's resync handles any jump.
9. **Full-queue policy:** when the SPSC queue is full, the **producer drops the newest** frame and counts it in `framesDropped`. The producer never pops, so it stays single-producer/single-consumer.

## 8. Left to the builder

- C++ class names (`AudioIn`, `FrameQueue`, `NoiseGateC` or similar).
- The JNI method shapes.
- Semaphore vs polling for the sender wake.
- How the fd hand-off API is shaped.
- Whether the Dart mic service is a new class or the old one rewritten.
