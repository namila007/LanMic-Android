# Native low-latency TV audio (Oboe/AAudio): design

Status: draft for approval · 2026-11-21 · branch `feat/latency-stats-low-latency-audio`
Inputs: research doc `plan/Cutting Delay in a Phone-Mic-to-TV-Speaker Talk Live App…md` (local), connection stats spec `2026-11-20-connection-stats-design.md`.

## 1. Why

On-device stats (Pixel 7 → Chromecast with Google TV, 2026-11-21):

| | Router | Hotspot |
|---|---|---|
| Phone (fixed estimate) | ~40 ms | ~40 ms |
| Wi-Fi (RTT/2) | ~36 ms (RTT 71) | ~4 ms (RTT 8) |
| **TV app buffers** | **~218 ms** | **~200 ms** |
| Total | ~294 ms "Slow" | ~244 ms "Slow" |
| Jitter | 12 ms | 12 ms |

About 75% of the delay is the TV app's own queueing: the Dart jitter buffer (up to 80 ms), the Dart 10 ms timer pump, the 8-frame Kotlin queue and the blocking AudioTrack. HDMI and the TV's own DSP come on top and are not measured. The owner chose the research's end state: **native Oboe/AAudio playout on the TV**, done TV-first.

## 2. Goals, non-goals, anti-goals

**Goals**
- TV share (buffer depth + output latency) **≤ 40 ms** on the hotspot, and Delay shows **Good** (< 100 ms).
- Lost audio **< 1 %** over a 60 s talk on the hotspot, with no audible clicks at burst start or end.
- The stats feature keeps working unchanged on screen, and its TV number becomes the real figure.
- Router spikes reduced: low-latency Wi-Fi lock on both devices, and phone audio marked as voice traffic.
- Two phone layout fixes seen on device: the Delay value wraps ("about 294 / ms"), and Disconnect is pushed off-screen while live with Details open.

**Non-goals**
- Phone native capture (Oboe input, 5 ms frames). This is the follow-up project, and the phone part stays the 40 ms estimate.
- Codec or protocol changes. PCM on the LAN is already the fastest; the wire format stays as it is.
- An AudioTrack fallback. The TV is API 34, so AAudio exists. Oboe chooses the API by itself.
- Clock-drift resampling. Push-to-talk bursts reset the buffer, and drain/PLC absorb drift.

**Anti-goals**
- Any lock, allocation, logging or I/O inside the audio callback.
- A buffer that can grow and stay grown (today's failure). Depth must return to target on its own.
- Breaking the TV's PIN check, "last HELLO wins" rule, rebinding at boot, or the stats/STATS packet.

## 3. Approaches

| | What | Trade-off |
|---|---|---|
| A | Shrink the queues and add a drain rule in today's Dart/AudioTrack path | Cheapest, but keeps the Dart timer and AudioTrack. The research says AudioTrack is often refused the fast path on Android TV over HDMI. |
| B | Move UDP, jitter buffer and an AudioTrack writer into Kotlin | No Dart in the audio path, but still AudioTrack. |
| **C (picked by the owner)** | **Oboe/AAudio output whose callback pulls from a native jitter buffer** | Lowest floor and the known fix for Android TV. NDK, CMake and Oboe are new to the repo. |

## 4. Design (TV)

### 4.1 Who does what

```
UDP :5004 ─▶ Kotlin receive thread (URGENT_AUDIO)
              ├─ AUDIO from accepted peer + PIN ─▶ JNI push ─▶ C++ JitterRing ◀─ Oboe data callback (pull) ─▶ HDMI
              └─ everything else (HELLO, END, …) ─▶ EventChannel ─▶ Dart ReceiverEngine (registry, PIN, ACK/REJECT, STATS)
Dart ─ send(bytes, peer) ─▶ Kotlin (same socket)      Dart ─ accept(peer?, pin) / stats() ─▶ Kotlin/C++
```

- **Kotlin owns the socket.** Port 5004 can't have two listeners, and the phone only accepts replies from port 5004, so Dart's replies also go out through this socket.
- **Kotlin's receive thread:** reuses one receive buffer and one direct `ByteBuffer`, so there is no allocation per packet.
  - It checks magic, version, type AUDIO, length 972, header PIN = accepted PIN, and sender = accepted peer.
  - It pushes the 960 B payload, `seq` and the arrival time (monotonic ns) into C++ through JNI.
  - Anything else that decodes (valid magic/version) is copied and posted to Dart. That's rare (HELLO every 2 s).
  - END from the accepted peer is posted to Dart **and** flushes the ring at once.
- **Dart keeps the protocol brain:** `SessionRegistry` (PIN, last valid HELLO wins, 6 s timeout), ACK/REJECT, and STATS at 1 Hz.
  - Whenever `activePhone` changes (including to `null`), Dart calls `accept(peer, pin)`. Native flushes on a change of peer.
  - AUDIO never enters Dart.
- **C++ does only audio:** the jitter ring, the Oboe stream and the stats counters.

### 4.2 Jitter ring (C++, pure, no Android headers so it can be host-tested)

- **Storage:** 16 slots of 480 samples, keyed by `seq % 16` with the seq stored, written by one producer (the receive thread) and read by one consumer (the callback). Slot hand-off uses atomics with acquire/release; no mutex.
- **Reading:** the consumer reads sample by sample across frame boundaries, because the callback asks for burst-sized chunks such as 192 frames, not 480.
- **Burst start:** wait until `target` frames are queued, then play.
- **Adaptive target (frames):** `ceil((2 × jitterMs + 2) / 10)`, clamped to **1..4** (10–40 ms). `jitterMs` is the RFC 3550 estimate, updated on each push from the arrival time and seq, as `JitterMeter` does today.
- **Drain:** if depth has stayed above `target + 1` frames for 100 ms, skip one frame, preferring a frame whose RMS is below the noise-gate floor (−44 dBFS). It never lets depth grow and stay grown.
- **Gap (seq missing at read time):** PLC repeats the last frame at −6 dB per repeat for up to 3 frames, then plays silence. It counts as *lost*.
- **Underrun (ring empty during a burst):** the same PLC, counted as *lost* only within 100 ms of the last push (same rule as the stats spec). After that it is idle silence and not counted.
- **Late frame (seq already played) or duplicate:** dropped and not counted as lost. The stats spec's rule holds: one slot is counted once.
- **Counters** (atomics, read at ≤ 4 Hz): `played`, `lost`, `discarded` (drain skips + overflow), `depthFrames`, `targetFrames`, `jitterMs`, `lastPushNs`.

### 4.3 Oboe output stream (C++)

- **Settings:** output, `PerformanceMode::LowLatency`, `SharingMode::Exclusive` (Oboe falls back to shared), 48 kHz, mono, `I16`, `Usage::Media`, `ContentType::Speech`. Channel and sample-rate conversion are allowed, so the HAL can run stereo or another rate.
- **Callback:** a data callback that pulls exactly `numFrames` from the ring.
- **Buffer size:** after open, `setBufferSizeInFrames(2 × framesPerBurst)`.
- **Lifecycle:**
  - Open on the first AUDIO push from an accepted peer.
  - Keep it open while bursts continue, and close after **10 s with no push**. Bursts after the first then skip cold start, and the TV isn't held while idle.
  - Use an error callback: after `ErrorDisconnected` (HDMI or route change), reopen in `onErrorAfterClose` if audio arrived in the last 10 s.
- **Logging:** on open, log one line with the API (AAudio or OpenSL), sharing mode, performance mode, `framesPerBurst`, buffer size and capacity, sample rate, channel count, and MMAP-used if the Oboe version exposes it.
- **Latency:** `calculateLatencyMillis()` is called **only from the stats call**, never in the callback.

### 4.4 Stats bridge

- Native `stats()` returns `{latencyMs, depthMs, targetMs, played, lost, discarded, jitterMs, lastAudioAgeMs, open, exclusive, mmap, burst, bufferFrames, xruns}`.
- **The Dart `ReceiverEngine` polls it every 250 ms.**
  - `receiving` = `lastAudioAgeMs < 500`, which replaces the Dart audio timeout.
  - Once a second, `played`/`lost`/`discarded` deltas feed the existing `LossMeter`.
  - `tvDelayMs` sample = `depthMs + latencyMs` while receiving (mean of the last 5, as today).
  - The STATS `jitterMs` comes from native.
- **The TV log line** gains `target=…ms depth=…ms out=…ms mmap=… burst=…`.

### 4.5 Removed (TV)

`JitterBuffer`, `PlaybackPump`, `JitterMeter`, `UdpSocketService`, `PcmOutSink`, the Kotlin AudioTrack writer, and their tests. `PcmSink` is replaced by an `AudioEngine` interface: start, stop, accept, send, stats, and the incoming packet stream. The `pcm_out` package keeps its name (my call: avoids rename churn).

## 5. Network hygiene (both devices)

- **Low-latency Wi-Fi lock:** `WifiManager.createWifiLock(WIFI_MODE_FULL_LOW_LATENCY)`, added as `setLowLatency(bool)` in the shared `wifi_band` plugin.
  - The phone holds it while connected.
  - The TV holds it while the receiver runs.
  - It needs `WAKE_LOCK`, which both apps already have.
  - Android only honours it in the foreground with the screen on, and otherwise falls back silently. That is acceptable.
- **Voice traffic marking:** the phone's UDP socket gets DSCP EF (`IP_TOS = 0xB8`) through Dart `RawSocketOption`. The TV's socket gets the same through `DatagramSocket.trafficClass`.

## 6. Phone layout fixes

- The Delay value never wraps. It stays on one line and scales down if needed.
- On a 412 × 915 dp viewport (Pixel 7), live, with Details open, Disconnect is fully visible without scrolling.
  - Levers, builder's choice: tighter vertical gaps, and a talk button of no less than 176 dp (design floor 160).

## 7. Constraints

- Oboe from Google Maven, exact latest stable version pinned; prefab on; CMake 3.22.1 (installed); C++17; ABIs as Flutter builds them (the TV is armeabi-v7a, the phone arm64).
- No protocol change. targetSdk stays 34. No new pub dependencies.
- Release builds for any measurement (CLAUDE.md).
- TDD: the jitter ring has host-run C++ tests; the Dart engine is tested with fakes; Kotlin/Oboe are checked on the device.

## 8. How we know it worked

- Run `adb shell dumpsys media.aaudio` on the TV while talking. Record whether the stream is MMAP/exclusive, plus the burst and buffer size.
- On-screen stats on the hotspot and the router, before and after: TV share, Delay, Lost audio.
- Manual clap test from the research doc for true mouth-to-speaker time, including HDMI.

## 9. Decisions after the builder check (my calls, 2026-11-21)

1. **Flush.** It must not break single-producer/single-consumer. END and `accept()` only bump an atomic **generation**. Slots are stamped with the generation they were written in. The callback (the only consumer) sees the new generation, ignores older slots and resets its own read state. No other thread touches consumer state.
2. **Burst start / sender restart (native replacement for Dart's 500 ms timeout):**
   - If the ring is empty and nothing has been pushed for 100 ms, the ring goes back to *wait for target* (re-prebuffer).
   - A signed u32 seq distance outside ±16 from the expected seq means a sender restart: resync to the new seq as a new burst, with no PLC run.
   - Dart's "receiving" state uses `lastAudioAgeMs < 500`.
3. **Stream open/close/reopen run on a native stream-manager thread,** woken by the receive thread through an atomic flag plus a condition variable on the manager side only. Neither the receive thread nor the callback ever blocks on it.
   - The very first burst may lose its head while the stream cold-opens. The consumer starts at the newest `target` frames.
   - The 10 s keep-open means later bursts don't pay this.
4. **The socket supervisor moves to Kotlin.**
   - Bind 5004 with a retry backoff of 1 s doubling to 5 s (boot before Wi-Fi), and rebind after a socket error.
   - Report `bound` / `error` events to Dart for the log.
   - A `send()` IOException is returned as a method error; Dart logs it and carries on, as today.
   - Dart keeps a `DatagramPort`-shaped wrapper: incoming = control packets, send = the method.
5. **Plugin lifetime:** a process-level Kotlin singleton.
   - Only explicit `start`/`stop` calls (from the service engine) change it. `start` is idempotent.
   - `onDetachedFromEngine` never stops it.
   - Packet events go to whichever engine listened last, which is the service engine.
6. **The accept race.** Dart calls `accept(peer, pin)` **before** sending the ACK for a new active phone. The phone sends audio only after ACK, so no audio is dropped. The 100 ms `_refresh` calls `accept(null)` when `activePhone` times out.
7. **Targets:**
   - Start each connection at a target of 2 frames (20 ms) until 20 packets have given a jitter estimate, then adapt (1..4 frames).
   - If `dumpsys` shows MMAP/exclusive was refused, the TV-share goal becomes ≤ 60 ms. Record it and revisit; don't tune blindly.
8. **Format/channels:** request 48 kHz and leave format and channel count **unspecified**, so Oboe opens the device's native layout and the MMAP path isn't lost to conversion. The callback writes I16 or float and copies mono into every channel.
9. **Corrections:**
   - Kotlin's `receive` allocates a sender address per packet. That's acceptable (it's not the audio thread), so "no allocation" applies to the callback and the payload path only.
   - `WIFI_MODE_FULL_LOW_LATENCY` needs an API ≥ 29 guard. It coexists with flutter_foreground_task's existing Wi-Fi lock; the stronger mode wins.
   - DSCP marking is best-effort and not verified.
   - The on-screen TV figure leaves out HDMI and TV DSP. The UI already says "about", and the clap test measures the rest.
10. **Status counters stay fed from native:** `framesRx` = accepted pushes, `framesDropped` = late/duplicate, `underruns` = lost slots.

## 10. Left to the builder

- Class and file names inside the plugin, the JNI method shapes, the RMS threshold maths, and how the ring counts the PLC fade steps.
- How Kotlin posts packets to the EventChannel (main-thread handler).
- Whether a stats poll is one method call or several.
