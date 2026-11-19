# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"LAN Mic": the phone is a live microphone, and a TV app plays the voice in near real time over the local network. Design docs in `plan/` are the source of truth: `plan/01-research-and-mvp-plan.md` (decisions), `plan/02-design.md` (UX, one screen per app), `plan/03-architecture.md` (modules, protocol, services).

## Layout (two separate Flutter apps, no shared workspace)

- `phone/` : phone app (`lanmic`, `lib/main.dart` is still the Hello World stub).
- `tv/` : Android TV app (`lanmic_tv`, Android only, stub UI). Manifest declares leanback and `LEANBACK_LAUNCHER`.
- `protocol/` : shared Dart package (`lanmic_protocol`) for the UDP packet format; still the generated stub, not yet a dependency of either app.
- `plan/` holds the design docs; the root has a catch-all `.gitignore` and each package has its own.

Each package has its own `pubspec.yaml`, so run Flutter commands from inside `phone/`, `tv/` or `protocol/`.

## Commands

Flutter SDK is at `/Users/namila007/namz/sdk/flutter/flutter` (on PATH).

```bash
flutter pub get
flutter analyze            # lints via flutter_lints; android/ and build/ are excluded
flutter test               # all tests
flutter test test/foo_test.dart --plain-name "case name"   # single test
flutter run                # in tv/, needs an Android TV device or emulator
```

`tv/` has no tests yet (the generated `test/` was removed).

## Architecture gotchas

- `plan/03-architecture.md` was written for **Kotlin with three Gradle modules** (`protocol`, `phone`, `tv`), no NDK. The repo is Flutter instead, so the design must be mapped onto it. Audio capture/playback (`AudioRecord`/`AudioTrack`), foreground services and boot auto-start have no pure-Dart equivalent and need platform channels or a plugin.
- Wire protocol is UDP on port 5004, little-endian, 12-byte header (`magic 0x4D54`, `version 1`, `type`, `seq`, `pin`) plus payload. Types: `AUDIO` 0 (960 B = 480 PCM16 mono samples at 48 kHz, 10 ms), `HELLO` 1 (also heartbeat), `ACK` 2, `END` 3, `REJECT` 4. The TV drops bad magic, version or PIN, and accepts `AUDIO` only from the last phone that completed a valid `HELLO`. Keep any shared packet code in one place used by both apps.
- TV targets Android targetSdk 34 deliberately, to keep boot auto-start allowed. Do not bump it casually.
