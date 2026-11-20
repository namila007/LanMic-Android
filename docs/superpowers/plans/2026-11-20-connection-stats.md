# Connection Stats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live Delay / Network / Lost audio / Wi-Fi band stats on the phone (connected area) and the TV (under the status row), measured end to end.

**Architecture:** The phone numbers its HELLOs, so the TV's ACK echo gives RTT. The TV measures its own part (jitter-buffer depth + native output latency), lost audio and jitter, and sends a 7-byte `STATS` packet to the active phone once a second. The phone adds up the total delay and sends it back in the HELLO payload, so both screens show the same number. Pure logic lives in `lib/domain` (phone `LinkStats`; TV `LossMeter`, `JitterMeter`) and in `protocol/` (wire codec + `qualityOf`). A new local plugin `wifi_band/` reads the Wi-Fi frequency on both apps.

**Tech Stack:** Flutter/Dart 3, `lanmic_protocol` (pure Dart), Kotlin `AudioTrack` (`pcm_out`), Kotlin `ConnectivityManager`/`WifiManager` (`wifi_band`), `fake_async` for engine tests.

**Spec:** `docs/superpowers/specs/2026-11-20-connection-stats-design.md`. **UI source of truth:** Design artifact https://claude.ai/artifact/73i2z1nSKDbrgfdQKxQk9J. Its boards are `Before.dc.html`, `Main.dc.html` and `Tv.dc.html`. Values are restated in Tasks 8–9, so the executor does not need the artifact.

## Global Constraints

- Protocol version stays `1`; all changes are additive. Unknown u16 = `0xFFFF`; encode clamps to `0..0xFFFE`.
- HELLO payload: 4 bytes LE `u16 rttMs, u16 delayMs`. STATS = type `5`, 7 bytes LE `u16 tvDelayMs, u16 lostPermille, u16 jitterMs, u8 band` (band: 0 unknown, 1 = 2.4 GHz, 2 = 5 GHz, 3 = 6 GHz). **User approved the band byte (2026-11-20).**
- Quality: **Good** = delay < 100 ms and lost < 1 %; **Slow** = delay ≥ 200 ms or lost ≥ 5 %; else **OK**. Unknown loss counts as 0; unknown delay = no quality word.
- No extra buffering or per-frame allocation on the audio path; counters only. UI refresh ≤ 1 Hz.
- targetSdk stays 34. No new pub dependencies; `wifi_band` is a local path plugin. Both manifests already have `ACCESS_WIFI_STATE`.
- MVVM: `lib/domain` has no Flutter imports. TDD: failing test first, every task.
- Never commit `settings.gradle*`, `.gradle/`, `local.properties`, `phone/android/gradle/gradle-daemon-jvm.properties`.
- Copy (exact): "Delay", "about N ms", "Good"/"OK"/"Slow", "Network", "Lost audio", "N.N%", "Talk to measure", "Measuring…", "Update the TV app to see the full delay", "Details", grid labels "Phone", "Wi-Fi", "TV", "Jitter", "Phone Wi-Fi", "TV Wi-Fi", band "2.4 GHz"/"5 GHz"/"6 GHz", unknown "—", TV fallback "TV delay about N ms".

## Review Focus

1. **Stale or foreign ACK seq** (an ACK for a ping already answered, or from before a wrap): no bogus RTT. Pinned in Task 3 (`link_stats_test`).
2. **Reconnect** (to the same TV or another one, or after Lost): all stats reset and the old-TV clock restarts. Pinned in Task 3 (reset test) and Task 4 (`session_service` test).
3. **A new phone takes over the TV:** TV delay mean, loss and jitter clear; STATS go only to the new phone. Pinned in Task 7.
4. **Huge values** (output latency > 65 s, negative maths): clamp, never wrap into "unknown". Pinned in Task 1 (clamp test).
5. **Band read fails or the TV is on Ethernet:** "—", no crash, no thrown `PlatformException`. Pinned in Task 2.

## File Structure

| File | Responsibility |
|---|---|
| `protocol/lib/src/packet.dart` (modify) | `PacketType.stats`, `WifiBand`, `HelloInfo`, `StatsReport`, `Packet.hello(…, [info])`, `Packet.stats`, getters, decode rules |
| `protocol/lib/src/quality.dart` (create) | `Quality`, `qualityOf` (shared by both apps) |
| `wifi_band/` (create, Flutter plugin, Android only) | `bandFromMhz`, `WifiBandReader.read()`; Kotlin `WifiBandPlugin` |
| `phone/lib/domain/link_stats.dart` (create) | RTT window, TV report memory, delay sum, old-TV flag → `LinkSnapshot` |
| `phone/lib/data/services/session_service.dart` (modify) | ping ids, RTT, STATS intake, HELLO info, 1 Hz `linkUpdates` |
| `tv/lib/domain/jitter_buffer.dart` (modify) | `PopKind lastPop`, `discarded` counter |
| `tv/lib/domain/loss_meter.dart`, `jitter_meter.dart` (create) | 10 s loss window; RFC 3550 jitter |
| `tv/packages/pcm_out/**` (modify) | `stats()` → output latency ms + drop-oldest count |
| `tv/lib/domain/receiver_engine.dart`, `session_registry.dart`, `receiver_status.dart` (modify) | wire meters, 1 Hz STATS send, status fields |
| `tv/lib/data/services/receiver_task_handler.dart`, `engine_factory.dart` (modify) | band polling, log line, sink adapter |
| phone/tv `ui/features/**` (modify/create) | view-model fields, formatters, stats card, TV stats line |

---

### Task 1: Protocol: STATS, HELLO info, Wi-Fi band, quality

**Files:**
- Modify: `protocol/lib/src/packet.dart`, `protocol/lib/lanmic_protocol.dart` (export `src/quality.dart`), `protocol/test/vectors.json`
- Create: `protocol/lib/src/quality.dart`
- Test (already written, failing): `protocol/test/stats_test.dart`, `protocol/test/quality_test.dart`, and the two new vectors in `vectors.json`

**Interfaces — Produces:**
```dart
enum PacketType { audio, hello, ack, end, reject, stats }   // stats = 5
enum WifiBand { unknown, ghz2_4, ghz5, ghz6 }                // wire = index; byte > 3 decodes as unknown
const kUnknownU16 = 0xFFFF; const kHelloInfoBytes = 4; const kStatsBytes = 7;
typedef HelloInfo = ({int? rttMs, int? delayMs});
class StatsReport { const StatsReport({int? tvDelayMs, int? lostPermille, int? jitterMs, WifiBand band = WifiBand.unknown}); /* value ==, hashCode */ }
Packet.hello(int seq, int pin, [HelloInfo? info])   // empty payload when info == null
Packet.stats(int seq, int pin, StatsReport r)
HelloInfo? get helloInfo     // null unless hello with payload >= 4 bytes
StatsReport? get statsReport // null unless stats
enum Quality { good, ok, slow }
Quality? qualityOf({required int? delayMs, int? lostPermille})
```
Decode: a STATS payload shorter than 7 bytes → `null`; longer is accepted and the extra bytes ignored. A HELLO with any payload length still decodes.

- [ ] **Step 1:** Tests are already in place. Run `cd protocol && dart test`. Expected: FAIL (compile errors: `PacketType.stats`, `StatsReport`, `qualityOf` undefined).
- [ ] **Step 2:** Implement the interfaces above in `packet.dart` and `quality.dart`, and export them.
- [ ] **Step 3:** Run `dart test && dart analyze` in `protocol/`. Expected: all pass, including the `hello_info` and `stats` golden vectors.
- [ ] **Step 4:** Commit: `feat(protocol): STATS packet, HELLO info payload, Wi-Fi band, quality rule`.

### Task 2: `wifi_band` local plugin

**Files:**
- Create: `wifi_band/pubspec.yaml` (Flutter plugin, `android: package: me.namila.app.lanmic.wifi_band, pluginClass: WifiBandPlugin`, depends on `lanmic_protocol: path: ../protocol`), `wifi_band/lib/wifi_band.dart`, `wifi_band/android/build.gradle.kts` (copy `tv/packages/pcm_out/android/build.gradle.kts`, rename namespace), `wifi_band/android/src/main/kotlin/me/namila/app/lanmic/wifi_band/WifiBandPlugin.kt`, `wifi_band/analysis_options.yaml` (copy pcm_out's)
- Modify: `phone/pubspec.yaml`, `tv/pubspec.yaml` (`wifi_band: path: ../wifi_band`)
- Test: `wifi_band/test/wifi_band_test.dart`

**Interfaces — Produces:**
```dart
WifiBand bandFromMhz(int? mhz)  // 2400..2500 → ghz2_4; 4900..5899 → ghz5; 5925..7125 → ghz6; else unknown
class WifiBandReader { const WifiBandReader(); Future<WifiBand> read(); } // channel 'wifi_band', method 'frequencyMhz' → int?; any PlatformException/MissingPluginException → unknown
```
Kotlin `frequencyMhz`: API ≥ 31: `ConnectivityManager.getNetworkCapabilities(activeNetwork)?.transportInfo as? WifiInfo`; below that: `WifiManager.connectionInfo`. Return `frequency`, or `null` when it is ≤ 0 or the network isn't Wi-Fi. No location permission is needed: frequency isn't a location-redacted field.

- [ ] **Step 1: Write the failing tests.** `bandFromMhz`: `null→unknown`, `2412→ghz2_4`, `5180→ghz5`, `5955→ghz6`, `900→unknown`. `read()` with `TestDefaultBinaryMessengerBinding` mock handler: `5180 → ghz5`; `null → unknown`; handler throws `PlatformException → unknown`.
- [ ] **Step 2:** Run `cd wifi_band && flutter test`. Expected: FAIL (file missing).
- [ ] **Step 3:** Implement the Dart side and the Kotlin plugin.
- [ ] **Step 4:** Run `flutter test && flutter analyze` in `wifi_band/`, then `flutter pub get && flutter build apk --debug` in `phone/` and `tv/`. Expected: pass and both builds succeed.
- [ ] **Step 5:** Commit: `feat: wifi_band plugin reads the Wi-Fi band`.

### Task 3: Phone `LinkStats` domain

**Files:**
- Create: `phone/lib/domain/link_stats.dart`
- Test (already written, failing): `phone/test/domain/link_stats_test.dart`

**Interfaces — Produces:**
```dart
const kPhoneDelayEstimateMs = 40; // shortcut: half the ~80 ms `record` chunk; replace with a measured value in the native-capture work
class LinkSnapshot { final int? rttMs, wifiMs, tvMs, delayMs, lostPermille, jitterMs; final int phoneMs; final WifiBand tvBand; final Quality? quality; final bool tvTooOld; }
class LinkStats {
  LinkStats({int phoneMs = kPhoneDelayEstimateMs});
  void reset(Duration now);                 // on every connect
  void helloSent(int pingId, Duration now); // remembers the last 5 pending ids
  void ackReceived(int pingId, Duration now);
  void statsReceived(StatsReport r);        // null fields and WifiBand.unknown keep the last known value
  HelloInfo get helloInfo;                  // (rttMs: mean, delayMs: snapshot delay)
  LinkSnapshot snapshot(Duration now);
}
```
Rules: RTT = mean of the last 5 samples, rounded. `wifiMs = (rtt / 2).round()`. `delayMs = phoneMs + wifiMs + tvMs` when RTT and TV are both known, else `null`. `quality = qualityOf(delayMs, lostPermille)`. `tvTooOld` = `reset` was called, no STATS since then, and `now − resetAt ≥ 3 s`.

- [ ] **Step 1:** Run `cd phone && flutter test test/domain/link_stats_test.dart`. Expected: FAIL (`link_stats.dart` missing).
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Run the same test. Expected: PASS.
- [ ] **Step 4:** Commit: `feat(phone): LinkStats domain for RTT and delay`.

### Task 4: Phone `SessionService` wiring

**Files:**
- Modify: `phone/lib/data/services/session_service.dart`, `phone/test/support/fake_tv.dart` (ACK echoes the HELLO `seq`; add `sendStats(StatsReport r)` to the last HELLO sender), `phone/test/support/fakes.dart` (`FakeSession` gains `link` / `linkUpdates`)
- Test: `phone/test/data/session_service_stats_test.dart` (fake `UdpSender` or the loopback `FakeTv`; tag `integration` if it uses real sockets)

**Interfaces:**
- Consumes: `LinkStats` (Task 3), `Packet.hello(…, info)`, `Packet.statsReport` (Task 1).
- Produces: `SessionService({…, Duration Function()? elapsed})`. The default is a started `Stopwatch().elapsed` (monotonic, never `DateTime`). Also `LinkSnapshot get link`, and `Stream<LinkSnapshot> get linkUpdates`, which emits every 4th 250 ms tick while the state is connected or lost.

Behaviour:
- `connect()` calls `_link.reset(elapsed())`.
- Each HELLO uses `_pingId` (u32, wraps), calls `helloSent`, and carries `_link.helloInfo`.
- An ACK calls `ackReceived(p.seq, …)`.
- A STATS from the TV address and port with `p.pin == _pin` calls `statsReceived`. Any other STATS is ignored.
- The 1 s debug line becomes `audio sent=N nextSeq=S rtt=R delay=D`.

- [ ] **Step 1: Write the failing tests.**
  - "HELLO seq increments and the ACK echo yields rttMs".
  - "STATS with a wrong PIN or from another port is ignored".
  - "connect again resets link (rttMs null, tvTooOld false)".
  - "HELLO after STATS carries delayMs".
  - "linkUpdates emits once per second while connected".
  
  Use `fake_async` and an injected `elapsed`.
- [ ] **Step 2:** Run `flutter test test/data/session_service_stats_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test` (the whole phone suite, including `integration`). Expected: PASS. Existing loopback tests must still pass with the echoing `FakeTv`.
- [ ] **Step 5:** Commit: `feat(phone): measure RTT and receive TV stats`.

### Task 5: TV meters

**Files:**
- Modify: `tv/lib/domain/jitter_buffer.dart`
- Create: `tv/lib/domain/loss_meter.dart`, `tv/lib/domain/jitter_meter.dart`
- Test (already written, failing): `tv/test/domain/jitter_buffer_counters_test.dart`, `tv/test/domain/loss_meter_test.dart`, `tv/test/domain/jitter_meter_test.dart`

**Interfaces — Produces:**
```dart
enum PopKind { voice, gap, underrun }   // in jitter_buffer.dart
// JitterBuffer gains: PopKind? lastPop (null after flush / before playing); int discarded (cumulative overflow-trim count)
class LossMeter { void played(DateTime now, {required bool lost}); void discarded(DateTime now, int n); int? lostPermille(DateTime now); void clear(); }
// 1 s buckets, the last 10 buckets count (bucket = ms ~/ 1000 > nowBucket - 10); permille = round(lost * 1000 / slots); null when there are no slots
class JitterMeter { void onAudio(int seq, DateTime at); void restart(); void clear(); int? get jitterMs; }
// RFC 3550: D = (at - prevAt).ms - signedU32(seq - prevSeq) * 10; J += (|D| - J) / 16; jitterMs = J.round(); null until the first update
```
- [ ] **Step 1:** Run `cd tv && flutter test test/domain`. Expected: FAIL (missing symbols).
- [ ] **Step 2:** Implement. `JitterBuffer` keeps its existing behaviour, and the existing `jitter_buffer_test.dart` must stay green.
- [ ] **Step 3:** Run `flutter test test/domain`. Expected: PASS.
- [ ] **Step 4:** Commit: `feat(tv): loss and jitter meters`.

### Task 6: `pcm_out` stats

**Files:**
- Modify: `tv/packages/pcm_out/lib/pcm_out.dart`, `tv/packages/pcm_out/android/src/main/kotlin/me/namila/app/lanmic/pcm_out/PcmOutPlugin.kt`
- Test: `tv/packages/pcm_out/test/pcm_out_test.dart`

**Interfaces — Produces:** `Future<({int? latencyMs, int dropped})> PcmOut.stats()` (method `stats` → `{'latencyMs': int?, 'dropped': int}`). Kotlin side:
- `dropped` is an `AtomicInteger`, incremented in the drop-oldest loop and reset on `start`.
- The writer thread adds `f.size / 2` to an `AtomicLong framesWritten` after each write.
- `latencyMs = queue.size * 10 + outputMs`, where `outputMs = (framesWritten − AudioTimestamp.framePosition) * 1000 / sampleRate` when `track.getTimestamp(ts)` is true, otherwise `track.bufferSizeInFrames * 1000 / sampleRate`.
- `latencyMs = null` when no track exists.

- [ ] **Step 1: Write the failing test.** With a mock channel answering `{'latencyMs': 42, 'dropped': 3}`, `stats()` returns `(latencyMs: 42, dropped: 3)`; with `{'latencyMs': null, 'dropped': 0}` it returns a null latency.
- [ ] **Step 2:** Run `cd tv/packages/pcm_out && flutter test`. Expected: FAIL.
- [ ] **Step 3:** Implement the Dart and Kotlin sides.
- [ ] **Step 4:** Run `flutter test`, then `cd ../.. && flutter build apk --debug`. Expected: PASS and the build succeeds.
- [ ] **Step 5:** Commit: `feat(pcm_out): report output latency and dropped frames`.

### Task 7: TV engine, registry, status, service

**Files:**
- Modify: `tv/lib/domain/receiver_engine.dart`, `tv/lib/domain/session_registry.dart`, `tv/lib/domain/receiver_status.dart`, `tv/lib/data/services/engine_factory.dart`, `tv/lib/data/services/receiver_task_handler.dart`
- Test: `tv/test/domain/receiver_engine_stats_test.dart` (reuse `Rig`/`FakePort`/`FakeSink` from `receiver_engine_test.dart`; move them to `tv/test/support/engine_rig.dart` if a second file needs them), plus `receiver_status_codec_test.dart` and `session_registry_test.dart` additions

**Interfaces:**
- Consumes: Tasks 1, 5, 6.
- Produces:
  - `PcmSink` gains `Future<({int? latencyMs, int dropped})> stats();`.
  - `ReceiverEngine({…, WifiBand Function() wifiBand = _unknownBand})`.
  - `SessionRegistry.phoneInfo` is a `HelloInfo?`, set from every valid HELLO (null for an old phone).
  - `ReceiverStatus` gains `int? rttMs, delayMs, tvDelayMs, lostPermille; WifiBand band`, included in `toMap`/`fromMap` (band as index), `==` and `hashCode`.

Engine behaviour:
- **Every popped frame in `tick()`:** `voice` → `loss.played(lost: false)`. `gap` → `played(lost: true)`. `underrun` → `played(lost: true)` only if `now − _lastAudioAt < 100 ms`, otherwise not counted.
- **After each `push`:** add the delta of `buffer.discarded` to `loss.discarded`. Every AUDIO also goes to `jitter.onAudio(seq, now)`.
- **`_flush()`** calls `jitter.restart()`. A phone change additionally clears `loss`, `jitter` and the TV-delay samples.
- **Every 10th housekeeping tick (1 s):**
  - If the sink is ready, call `sink.stats()`, add the `dropped` delta to `loss.discarded`, and store `latencyMs`.
  - While receiving, take a sample `depth × 10 + (latencyMs ?? 0)` and keep the last 5. `tvDelayMs` is their rounded mean; it persists after a burst and clears on a phone change.
  - If `activePhone != null`, send `Packet.stats(0, registry.pin, StatsReport(tvDelayMs, loss.lostPermille(now), jitter.jitterMs, band))` to it, using the same `SocketException` guard as the replies. **Band is sent once per phone:** `band = wifiBand()` only in the first 3 STATS after a phone becomes active (3 copies survive UDP loss), `WifiBand.unknown` after that. The count resets when the active phone changes. (Owner decision 2026-11-20: Wi-Fi info is sent once, not repeatedly.)

Service:
- `ReceiverTaskHandler` reads `const WifiBandReader().read()` **once** at start (no polling), and passes `() => band` to the engine.
- Its log line appends `delay=D tv=T lost=L‰ jitter=J band=B`.
- `PcmOutSink.stats()` delegates to `PcmOut.stats()`.

- [ ] **Step 1: Write the failing tests.**
  - "sends one STATS per second to the active phone only".
  - "band is in the first 3 STATS to a phone, unknown afterwards; a new phone gets it again".
  - "STATS carries tvDelayMs from depth and sink latency".
  - "gap and underrun count as lost; underrun 100 ms after the last audio does not".
  - "discarded and native-dropped frames count as lost".
  - "new phone clears tvDelayMs, loss and jitter".
  - "status carries phone rttMs/delayMs from HELLO; old phone leaves them null".
  - "ReceiverStatus map round-trips the new fields".
- [ ] **Step 2:** Run `cd tv && flutter test test/domain`. Expected: FAIL.
- [ ] **Step 3:** Implement. Update `FakeSink` with `stats()`.
- [ ] **Step 4:** Run `flutter test && flutter analyze`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(tv): measure and send connection stats`.

### Task 8: Phone UI: stats card

**Files:**
- Create: `phone/lib/ui/features/mic/view_models/stats_text.dart` (pure formatters), `phone/lib/ui/features/mic/views/stats_card.dart`
- Modify: `phone/lib/ui/features/mic/view_models/mic_view_model.dart`, `phone/lib/ui/features/mic/views/mic_screen.dart`, `phone/lib/main.dart`
- Test: `phone/test/ui/features/mic/stats_text_test.dart`, `phone/test/ui/features/mic/stats_card_test.dart`, `mic_view_model_test.dart` additions

**Interfaces:**
- Consumes: `SessionService.link` / `linkUpdates`, `WifiBandReader`.
- Produces:
  - `MicViewModel({…, Future<WifiBand> Function()? readBand})`, defaulting to `() async => WifiBand.unknown`.
  - `LinkSnapshot? get link`: null unless the state is connected, live or lost.
  - `WifiBand phoneBand`, read **once** each time the state reaches connected (no polling).
  - `bool detailsOpen = true` (in memory only) and `void toggleDetails()`.
  - `notifyListeners` on each `linkUpdates` event.

Formatters:
- `aboutMs(140) → 'about 140 ms'`, `tildeMs(20) → '~20 ms'`, `ms(9) → '9 ms'`.
- `percent(3) → '0.3%'` (permille in, one decimal).
- `bandLabel(WifiBand.ghz2_4) → '2.4 GHz'`; unknown → `'—'`.
- `qualityLabel(Quality.ok) → 'OK'`.
- `statsSemantics(LinkSnapshot) → 'Delay about 140 milliseconds, OK. Network 9 milliseconds. Lost audio 0.3 percent.'`

Card contents by state (spec 3.1):
- **Delay text:** `Measuring…` when `rttMs == null`; else the old-TV hint when `tvTooOld`; else `Talk to measure` when `tvMs == null`; else `about N ms` + quality.
- **Lost:** greys values and shows `—`.

Visual values from `Main.dc.html` (dark; light uses existing `_light` tokens):
- **Card:** `margin 20/24/0`, padding `16 20 4`, radius 18, bg `t.card`, children gap 12.
- **Delay row:** label 14 muted; value 20 w600 tabular; quality right-aligned with an 8 px dot. Dot colours: Good `#30D158`, OK `#FF9F0A`, Slow `#FF453A`. Label 14 w600.
- **Secondary row:** gap 32, label 14 muted + value 17 w600 tabular.
- **Details grid:** 3 columns, gap 12, `padding-top 12`, top border 1 px `fg @ 12 %`. Each cell is label 14 muted over value 17.
- **Toggle:** text button, `▾ Details` / `▸ Details`, 14 w600, colour `t.accent`, min height 44, with Semantics `expanded`.

Layout change: the talk area is top-aligned 24 px below the mode switch. Replace the `Spacer` above `_talk` with `SizedBox(height: 24)`, so collapsing Details moves the mic section up. The Spacer above Disconnect stays.

- [ ] **Step 1: Write the failing tests.**
  - Formatter table tests.
  - Widget tests:
    - "card hidden when not connected".
    - "Measuring… before first RTT".
    - "Talk to measure before TV delay".
    - "full values + OK".
    - "old-TV hint".
    - "lost shows — greyed".
    - "Details toggle hides grid and moves talk button up" (compare `tester.getTopLeft(find.bySemanticsLabel(RegExp('Talk button')))`).
    - "semantics label".
  - VM test: "phoneBand read on connect".
- [ ] **Step 2:** Run `flutter test test/ui`. Expected: FAIL.
- [ ] **Step 3:** Implement. Wire `readBand: const WifiBandReader().read` in `main.dart`.
- [ ] **Step 4:** Run `flutter test && flutter analyze`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(phone): connection stats card`.

### Task 9: TV UI: stats line

**Files:**
- Create: `tv/lib/ui/features/receiver/view_models/stats_line.dart`
- Modify: `tv/lib/ui/features/receiver/view_models/receiver_view_model.dart`, `tv/lib/ui/features/receiver/views/receiver_screen.dart`
- Test: `tv/test/ui/features/receiver/stats_line_test.dart`, `receiver_screen_test.dart` and `receiver_view_model_test.dart` additions

**Interfaces — Produces:**
- `ReceiverViewModel.status` (the whole `ReceiverStatus`), which notifies when any field changes, not only the state.
- `List<(String label, String value, Quality? q)> statsLine(ReceiverStatus s)`, per spec 3.2:
  - **listening:** `[]`.
  - **connected:** `[('Network', '9 ms')]` if `rttMs` is known, else `[]`.
  - **receiving:**
    - `('Delay', 'about N ms', quality)` when `delayMs` is known; otherwise `('TV delay', 'about N ms', null)` when `tvDelayMs` is known.
    - Then `('Lost audio', '0.3%' or '—')`.
    - Then `('Wi-Fi', band label)`.

Visual values from `Tv.dc.html`:
- **Line position and type:** under the status row with a 16 px gap; font 32, height 1.19, tabular figures. Labels are `#CCCCCC`; values are w600. Item gap 40; label/value gap 12. The quality dot is 14 px and comes before the word.
- **Section gaps:** `_Layout`'s section gaps become 28 (was 40).
- **Semantics label:** `'Delay about 140 milliseconds, OK. Lost audio 0.3 percent. Wi-Fi 2.4 gigahertz.'`

- [ ] **Step 1: Write the failing tests.**
  - `statsLine` table for each state, plus the old-phone fallback.
  - Screen test: "line shown only when receiving / connected-with-rtt".
  - VM test: "notifies on stats-only change".
- [ ] **Step 2:** Run `flutter test test/ui`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `flutter test && flutter analyze`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(tv): stats line on the receiver screen`.

### Task 10: Device check and audit

- [ ] **Step 1:** Build and install release APKs (`flutter build apk --release`) on the Pixel 7 and the Chromecast. The user starts adb from Terminal.app (see CLAUDE.md).
- [ ] **Step 2:** Walk each state in spec 3.1/3.2. Check logcat for `rtt=`/`delay=` (phone) and `tv=`/`lost=`/`band=` (TV), and check the numbers match the screens within one refresh.
- [ ] **Step 3:** Review the whole branch with `flutter-reviewer` and `kotlin-reviewer`. Fix CRITICAL/HIGH issues.
- [ ] **Step 4:** Commit any fixes, plus a CHANGELOG entry.
