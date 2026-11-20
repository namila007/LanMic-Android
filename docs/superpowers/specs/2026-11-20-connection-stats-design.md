# Connection stats view (phone + TV): requirements

Status: draft for approval · 2026-11-20 · branch `feat/latency-stats-low-latency-audio`

## 1. Why

Anyone using LAN Mic should be able to see **how far behind the TV is** and **whether the link is healthy**, in plain words. A second reason: the next piece of work (cutting the audio delay) needs a before/after number, so the stats must be honest about what they measure.

The UI is designed separately (by the owner). This document says **what each screen must show, when, and where the numbers come from**. Layout, styling and exact placement within the stated area are the designer's.

## 2. Goals, non-goals, anti-goals

**Goals**
- Phone, in the connected area: one headline **Delay** number with a plain quality word, plus **Network** round trip and **Lost audio**.
- TV, under the status line: the same Delay number and quality word, plus Lost audio, readable from a sofa.
- An optional, collapsed **breakdown** on the phone (phone / network / TV parts), so the delay work can be measured.
- Works when only one side is updated (old TV or old phone): show what is known, never garbage.

**Non-goals**
- No graphs, history, export or saved sessions.
- No settings or thresholds the user can change.
- No true one-way measurement (no clock sync) and no acoustic measurement. The clap test in the research doc stays a manual check.

**Anti-goals** (a failure even if it "works")
- The stats make audio worse: extra per-frame work, extra buffering, or UI jank while live.
- A guess dressed up as a precise number. Estimates say "about".
- Stats compete with the talk button or the live state for attention.

## 3. What the user sees

### 3.1 Phone

Placement: the area the connection card leaves when it collapses after connecting (between the status chip and the mode switch). Hidden when not connected.

```
●  Connected · Living Room
┌───────────────────────────────┐
│ Delay   about 140 ms   · OK   │   headline
│ Network 9 ms   Lost audio 0.3%│   secondary
│ ▸ Details                      │   collapsed breakdown (optional)
└───────────────────────────────┘
   Phone ~20 ms · Wi-Fi ~5 ms · TV ~115 ms · Wi-Fi jitter 3 ms   (when expanded)
```

| Phone state | Delay | Network | Lost audio | Details |
|---|---|---|---|---|
| Not connected / connecting / no response / wrong PIN | hidden | hidden | hidden | hidden |
| Connected, never talked this connection | "Talk to measure" | value | "—" | phone + Wi-Fi only |
| Live (talking) | value + quality word | value | value | all three parts |
| Connected after talking | last value, kept | value | last value | last values |
| Connection lost | "—" (greyed) | "—" | "—" | greyed |
| TV app is an older version (no STATS within 3 s of connecting; a new TV sends STATS whenever the phone is connected, talking or not) | "—" with hint "Update the TV app to see the full delay" | value | "—" | phone + Wi-Fi only |

- Values refresh at most once a second. No animation on number changes beyond what the designer adds.
- Before the first network sample: "Measuring…".

### 3.2 TV

Placement: below the existing status row ("● Receiving audio"). Large text, same sofa-readability rule as the rest of the TV screen.

```
● Receiving audio  ▂▅▃
Delay about 140 ms · OK      Lost audio 0.3%
```

| TV state | What shows |
|---|---|
| Listening | nothing |
| Phone connected (not receiving) | Network round trip, if the phone sent it; otherwise nothing |
| Receiving audio | Delay + quality word, Lost audio |
| Receiving, but the phone's HELLO has no delay yet (first 2–4 s of a session, or `delayMs` = unknown) | "TV delay about N ms" (TV part only) + Lost audio |
| Phone app is an older version (HELLO has no payload) | "TV delay about N ms" (TV part only) + Lost audio |

The phone keeps sending its last known `delayMs` between bursts (the value the phone shows as "last value, kept"), and sends `0xFFFF` only before its first measurement in a connection.

### 3.3 Quality word

Shown next to Delay on both screens, as text (not colour alone; colour is the designer's choice).

| Word | Rule |
|---|---|
| **Good** | delay < 100 ms **and** lost audio < 1% |
| **OK** | anything between Good and Slow |
| **Slow** | delay ≥ 200 ms **or** lost audio ≥ 5% |

Thresholds are my call (not tunable by the user). Expect "Slow" or "OK" on today's build; the delay work should move it to "Good".

### 3.4 Copy

- "Delay" · "about 140 ms" · "Good" / "OK" / "Slow"
- "Network" · "9 ms"
- "Lost audio" · "0.3%"
- "Talk to measure", "Measuring…", "Update the TV app to see the full delay"
- Details labels: "Phone", "Wi-Fi", "TV", "Wi-Fi jitter"
- Accessibility label for the phone card: "Delay about 140 milliseconds, OK. Network 9 milliseconds. Lost audio 0.3 percent."

## 4. What the numbers mean

All averages are over a short window so the numbers are steady but follow change within a few seconds.

| Number | Definition | Window | Measured where |
|---|---|---|---|
| **Network (RTT)** | Time from the phone sending a HELLO to receiving the matching ACK | mean of last 5 samples (≈10 s at the 2 s heartbeat) | phone, monotonic clock (`Stopwatch`), never wall clock |
| **Wi-Fi part** | RTT / 2 | same | phone |
| **TV part** | jitter buffer depth + native output queue + device output latency, in ms | mean over last 5 s of receiving | TV |
| **Phone part** | audio held on the phone before send. Until native capture exists this is a fixed per-build estimate constant | constant | phone |
| **Delay** | Phone part + Wi-Fi part + TV part | — | phone computes; sends to TV |
| **Lost audio** | lost slots / (played slots + discarded frames), see definition below | last 10 s of receiving | TV |
| **Jitter** (Details only, label "Wi-Fi jitter") | RFC 3550 interarrival jitter of AUDIO packets, in ms | running estimator (RFC 3550 1/16 gain) | TV |

**Lost audio, exact definition** (my call; each 10 ms slot counts at most once):
- *Lost* = slots the listener heard as silence instead of voice **within a burst**: gap-fill silence (`pop()` found a hole in the sequence) + empty-buffer underruns, plus frames **discarded** without being played (jitter-buffer overflow trim, native queue drop-oldest).
- A packet that arrives after its slot already played as silence is **not** counted again (the slot was already counted as lost). Duplicates are never counted.
- Underruns stop counting once no AUDIO has arrived for 100 ms, so the trailing silence after the speaker stops (or a lost END) is not "lost audio".
- Today's code lumps some of these together and must be split: `JitterBuffer.underruns` counts only empty-buffer silence (gap-fill is not counted), and `ReceiverEngine._framesDropped` mixes duplicates with late frames (`push()` returns false for both).

Notes:
- Output latency on the TV comes from the audio output itself (for AudioTrack: frames written minus playback head position from `getTimestamp`). If the device gives no timestamp, use the output buffer size and mark the value as an estimate internally; the UI still says "about".
- "Lost audio" counts **audio the listener did not hear**, not packets that arrived late and were replaced. Duplicates are not losses.
- The phone part is honest about being an estimate; the low-latency audio work will replace the constant with a measured value.

## 5. How the numbers travel

### 5.1 Approaches considered

| Approach | What it is | Trade-off |
|---|---|---|
| **A. RTT only** | Phone numbers its HELLOs; no new packets. TV shows only its own numbers. | Cheapest, but the phone cannot show the real delay: most of it is on the TV. Fails the main goal. |
| **B. TV sends a small STATS report; phone adds its numbers to HELLO** (picked) | New packet type `STATS` (TV → phone, 1 per second while the phone is active). HELLO gains an optional small payload (phone → TV). | Small, additive protocol change; old apps ignore it (unknown types are already dropped). Both screens show the same Delay. |
| **C. Pack TV stats into ACK** | Append numbers after the TV name in ACK. | Only every 2 s, and old phones would show the numbers as part of the TV name. Rejected. |

**B is my call.** Reason: it is the only one that meets the main goal without breaking old installs.

### 5.2 Wire changes (protocol package, version stays 1)

- **HELLO `seq`** becomes an incrementing ping id (u32, wraps). The TV already echoes HELLO `seq` in its ACK, so RTT needs no TV change.
- **HELLO payload** (optional, 4 bytes, little-endian): `u16 rttMs`, `u16 delayMs`. `0xFFFF` = unknown. Old TVs ignore HELLO payloads already.
- **New type `STATS` = 5**, TV → active phone only, once per second while that phone is active. Payload (6 bytes, little-endian): `u16 tvDelayMs`, `u16 lostPermille` (loss × 1000), `u16 jitterMs`. `0xFFFF` = unknown. Header PIN = TV PIN; the phone accepts it only from the TV address/port it connected to.
- Old phones drop type 5 (decode rejects unknown types). Old TVs never send it; the phone detects that by "no STATS within 3 s of going live".
- Golden vectors for HELLO-with-payload and STATS go in `protocol/test/vectors.json`.

**Wi-Fi band** (owner decision, 2026-11-20): one byte at the end of STATS (0 unknown, 1 = 2.4 GHz, 2 = 5 GHz, 3 = 6 GHz). It is read once, not polled, and sent once per phone: only in the first 3 STATS after a phone becomes active (3 copies to survive UDP loss), then `unknown`. The phone keeps the last known band. Each app reads its own band once (the TV at service start, the phone on connect).

`jitterMs` is not shown in the main UI. It appears in the phone's Details as "Wi-Fi jitter" and feeds the delay work (it sets how small the jitter buffer can be). Its meaning is fixed as RFC 3550 interarrival jitter so it can't drift after release.

### 5.3 Where it lives in the code (for the builder)

- `protocol/`: STATS type, HELLO payload encode/decode, vectors.
- Phone: a pure-Dart stats domain object (RTT window, delay sum, "TV report seen" flag, quality word) fed by `SessionService`; exposed through `MicViewModel`.
- TV: counters for played/lost/discarded slots and buffer depth in the receiver engine; output latency and native queue depth from `pcm_out`, which needs one new method (e.g. `latencyMs`: queued frames × 10 ms + frames written − `AudioTrack.getTimestamp` position, falling back to buffer size) and a counter for its drop-oldest discards. That is new Kotlin work inside the existing local plugin; extend `ReceiverStatus` (already sent from the service isolate to the UI 4×/s) with the stats; `ReceiverViewModel` exposes them.
- The stats source must not depend on today's Dart jitter buffer staying where it is: the delay work moves playout to native code, which then reports depth and output latency itself.

## 6. Constraints

- No extra buffering or per-frame allocation on the audio path; counters only.
- UI refresh ≤ 1 Hz on both screens.
- Both apps keep targetSdk 34; no new plugins needed for this feature.
- TDD per project convention: domain logic (RTT window, quality rule, loss window, wire codec) gets unit tests first.
- Device check on the Pixel 7 + Chromecast with Google TV: numbers appear in each state of 3.1/3.2, and logcat lines gain the same values.

## 7. Left to the builder

- Exact class/file names and how the stats object is wired into the existing view models.
- The phone-part constant's value (pick from the current `record` chunking estimate; document it next to the constant).
- Rounding (whole ms; loss to one decimal).
