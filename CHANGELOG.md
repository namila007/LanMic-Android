# Changelog

## 1.0.0 — 2026-11-20

The first release. Use your Android phone as a wireless mic and hear your voice on your Android TV, over your home Wi‑Fi with no extra hardware.

### Phone app (LAN Mic)
- **Hold to talk**, or tap **Keep talking** to leave the mic on.
- Pair by entering the TV's IP and 6‑digit PIN. The app shows Connected, No response or Lost.
- Keeps running when you leave the app or lock the screen. A phone call pauses the mic, and it stays off until you tap again.
- A noise gate mutes the mic between phrases, which cuts echo from the TV speakers.
- Reconnects on its own after another app (for example the camera) takes over the mic.

### TV app (LAN Mic Receiver)
- Runs in the background and starts automatically when the TV boots.
- Shows the IP and PIN to type into the phone.
- Smooth, low‑delay playback: a jitter buffer plus low‑latency audio output.
- **Exit** fully stops the receiver. Home or Back leaves it running.

### Notes
- The phone and TV must be on the same Wi‑Fi network. Guest networks with client isolation won't work.
- For less echo, hold the phone close to your mouth and keep the TV volume moderate.
- Requires Android 8.0+ on the phone and Android TV / Google TV 7.0+. Tested on a Pixel 7 with a Chromecast with Google TV.

### Known limitations
- The PIN stops accidental connections, but it isn't encryption. Use the app only on a home network you trust.
- Builds are signed with a debug key: sideload only, not on Google Play.
