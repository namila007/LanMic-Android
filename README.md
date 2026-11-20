# LAN Mic

Use your Android phone as a live wireless microphone for your Android TV. Your voice goes over your home Wi‑Fi and plays on the TV in near real time. No cables, no Bluetooth, no extra hardware.

<table>
  <tr>
    <th>Phone: LAN Mic</th>
    <th>TV: LAN Mic Receiver</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/phone-mic.png" alt="Phone app: TV address, PIN, Hold to talk / Keep talking, mic button" width="260"></td>
    <td><img src="docs/screenshots/tv-receiver.png" alt="TV app: address and PIN to type on the phone, Listening status" width="520"></td>
  </tr>
</table>

## How it works

```
 phone mic ──48 kHz PCM, 10 ms frames──▶ UDP 5004 ──▶ jitter buffer ──▶ TV speakers
  (LAN Mic)          same Wi‑Fi network            (LAN Mic Receiver)
```

The TV shows its IP address and a 6‑digit PIN. Type both into the phone, tap **Connect**, and talk.

## Features

**Phone**
- **Hold to talk** (push‑to‑talk) or **Keep talking** (mic stays on).
- Clear status: Not connected, Connected, No response, Lost.
- Keeps working with the screen locked or while you're in another app. A phone call pauses the mic, and it stays paused until you tap again.
- A noise gate mutes the mic between phrases, which cuts echo from the TV speakers.
- Reconnects on its own after another app (for example the camera) takes the mic.

**TV**
- Runs in the background and starts automatically when the TV boots.
- Shows the address and PIN to enter on the phone.
- Smooth, low‑delay playback: a jitter buffer plus low‑latency `AudioTrack` output.
- **Exit** stops the receiver completely. Home or Back leaves it running.

## Requirements

- Phone: Android 8.0 (API 26) or newer.
- TV: Android TV / Google TV, Android 7.0 (API 24) or newer.
- Both on the **same Wi‑Fi network**. Guest networks with client isolation block device‑to‑device traffic.

Tested on a Pixel 7 with a Chromecast with Google TV: a steady 100 frames/s with no dropped frames.

## Install

1. Download the two APKs from [Releases](https://github.com/namila007/LanMic-Android/releases).
2. Phone: open the APK and allow installing from your browser or file manager.
3. TV: sideload with adb (Developer options → Wireless debugging), then install:

   ```bash
   adb connect <tv-ip>:<port>
   adb install lanmic-tv.apk
   ```

## Use

1. Open **LAN Mic Receiver** on the TV. Note the address and PIN.
2. Open **LAN Mic** on the phone, enter the address and PIN, then tap **Connect**.
3. Hold the mic button to talk, or switch to **Keep talking** to leave the mic on.

**Less echo:** hold the phone close to your mouth (bottom edge, 2–5 cm), point it away from the TV speakers, and keep the TV volume moderate.

## Build from source

Needs the Flutter SDK. Each package is separate, so run commands inside it.

```bash
cd protocol && dart test
cd phone && flutter test && flutter build apk --release
cd tv && flutter test && flutter build apk --release
```

| Folder | What it is |
|---|---|
| `phone/` | Phone sender app (`me.namila.app.lanmic`) |
| `tv/` | Android TV receiver app (`me.namila.app.lanmic.tv`) |
| `tv/packages/pcm_out/` | Local plugin: low‑latency `AudioTrack` playback (Kotlin) |
| `protocol/` | Shared Dart packet codec used by both apps |

**Wire protocol:** UDP on port 5004, little‑endian, with a 12‑byte header (magic `0x4D54`, version 1, type, seq, PIN) followed by the payload.
- **Types:** `AUDIO` (960 B = 10 ms of 48 kHz mono PCM16), `HELLO` (also the heartbeat), `ACK`, `END`, `REJECT`.
- **Rules:** the TV drops packets with a bad PIN, and plays audio only from the last phone that sent a valid `HELLO`.

## Known limitations

- The PIN stops accidental connections, but it isn't encryption. Use the app only on a home network you trust.
- Release APKs are signed with a debug key. They're for sideloading, not Google Play.
- Android only; there is no iOS app.
