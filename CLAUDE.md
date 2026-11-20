# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"LAN Mic": the phone is a live microphone, and a TV app plays the voice in near real time over the local network. Design docs in `plan/` are the source of truth: `plan/01-research-and-mvp-plan.md` (decisions), `plan/02-design.md` (UX, one screen per app), `plan/03-architecture.md` (modules, protocol, services), `plan/05-07-milestones*.md` (TDD milestone plans). `plan/` is gitignored, so it is local only.

## Layout (separate Flutter/Dart packages, no shared workspace)

- `protocol/` : pure Dart `lanmic_protocol` (packet codec in `lib/src/packet.dart`, golden `test/vectors.json`, `tool/send_sine.dart` test sender). Both apps depend on it by `path: ../protocol`; keep all packet code here.
- `phone/` : sender app `lanmic`, package id `me.namila.app.lanmic`, minSdk 26.
- `tv/` : Android TV receiver `lanmic_tv`, package id `me.namila.app.lanmic.tv`, Android only, leanback + `LEANBACK_LAUNCHER`, banner `res/drawable-xhdpi/banner.png`.
- `tv/packages/pcm_out/` : local Flutter plugin, Kotlin low-latency `AudioTrack` (`start` / `write` 960 B frames / `stop`).

Both apps use MVVM (decision D3): `lib/domain` is pure Dart logic (no Flutter imports), `lib/data/services` wraps plugins and sockets, `lib/ui/features/<x>/{view_models,views}`. Tests mirror it under `test/`, with fakes in `test/support`.

- Phone domain: `ConnectionMachine` (HELLO every 2 s, noResponse at 3 s, lost at 6 s), `TalkGate` (Hold / Keep), `FrameSlicer`, `NoiseGate` (opens at -38 dBFS, closes below -44, 250 ms hold, 10 ms fades; gated frames become silence, never drops).
- TV domain: `JitterBuffer` (prebuffer 3, max 8), `SessionRegistry` (last valid HELLO wins), `ReceiverEngine` (500 ms audio timeout, socket rebind supervisor), `PinStore`. Runs inside a `flutter_foreground_task` service that also starts on boot.

## Commands

Flutter SDK is at `/Users/namila007/namz/sdk/flutter/flutter` (on PATH). Run each from inside its package dir.

```bash
flutter pub get
flutter analyze            # phone/, tv/ (dart analyze in protocol/)
flutter test               # phone/, tv/, tv/packages/pcm_out (dart test in protocol/)
flutter test test/foo_test.dart --plain-name "case name"   # single test
flutter test --exclude-tags integration   # phone: skip the real-socket loopback tests
flutter build apk --release               # use release builds for any latency/underrun measurement
```

## Device testing

- Real devices are on wireless adb: Pixel 7 phone, Chromecast with Google TV (Android 14, armeabi-v7a), which reconnects by mDNS (`adb mdns services`). Ports change after wireless debugging is toggled.
- macOS Local Network privacy blocks LAN traffic from processes started inside the Claude app (`adb connect` gives "No route to host" while `nc` works). Start the adb server from Terminal.app (`adb kill-server && adb connect ...`); never `adb kill-server` from inside Claude. A Mac-side UDP test responder hits the same block.
- Emulators: `emu redir` only reaches guest 10.0.2.15, and Wi-Fi AVD images only have 10.0.2.16, so phone emulator to TV emulator UDP does not work. For an integrated test on emulators, run both apps on one emulator over 127.0.0.1.
- Log lines for checks (logcat tag `flutter`): TV `[lanmic] <state> rx=N (+n/s) dropped=N underruns=N` each second; phone `audio sent=N nextSeq=S` (seq-gap check) and `gate open=x/100 min=..dB max=..dB` (gate calibration).
- On the user's personal phone, touch only our app; the user types IP and PIN (agent-device `fill` is unreliable over wireless adb).

## Architecture gotchas

- `plan/03-architecture.md` was written for **Kotlin with three Gradle modules**; the repo maps it onto Flutter (decision D1, Dart-first). Audio playback, foreground service and boot start go through plugins (`record`, `flutter_foreground_task`, `pcm_out`).
- Wire protocol is UDP on port 5004, little-endian, 12-byte header (`magic 0x4D54`, `version 1`, `type`, `seq`, `pin`) plus payload. Types: `AUDIO` 0 (960 B = 480 PCM16 mono samples at 48 kHz, 10 ms), `HELLO` 1 (also heartbeat), `ACK` 2, `END` 3, `REJECT` 4. The TV drops bad magic, version or PIN, and accepts `AUDIO` only from the last phone that completed a valid `HELLO`.
- dart:io reports a UDP send OS error (e.g. EPERM when Android blocks a backgrounded app) asynchronously on the socket stream and then **closes the socket**. Catching `SocketException` around `send` is not enough: `phone/lib/data/services/udp_sender.dart` rebinds on error/done; the TV rebinds via `ReceiverEngine`'s `onDone`.
- The `record` plugin must use `audioInterruption: AudioInterruptionMode.none`, otherwise it takes audio focus itself and the app's own `AudioFocus` sees a fake "call" interruption. Mic source is `AndroidAudioSource.mic` (bottom mic), echo cancel / noise suppress / AGC off.
- Echo near the TV is the TV speaker feeding the phone mic; phone AEC cannot cancel it. Mitigations: hold the mic close, `NoiseGate`, lower TV volume.
- Both apps target Android targetSdk 34 deliberately (keeps TV boot auto-start allowed). Do not bump it casually.
- Never commit local Gradle files: root `settings.gradle`, `.gradle/`, `local.properties`, `phone/android/gradle/gradle-daemon-jvm.properties`.
