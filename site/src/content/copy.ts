// All user-facing copy lives here so it can be translated later.
// Facts verified against README.md, CHANGELOG.md and docs/architecture.md (v1.1.0).

export const REPO = 'https://github.com/namila007/LanMic-Android';
export const RELEASES = `${REPO}/releases`;
export const RELEASES_LATEST = `${REPO}/releases/latest`;
export const SITE = 'https://lanmicapp.namila.me';

// TODO(owner): set the license name once confirmed; the footer shows it only when set.
export const LICENSE: string | null = null;

export const meta = {
  title: 'LAN Mic: use your Android phone as a wireless mic on your TV',
  description:
    'Sing or talk into your Android phone and hear it on your Android TV in about 70-80 ms. Free, no cables, no Bluetooth, no account. Works on your home Wi-Fi.',
};

export const nav = [
  { href: '#how', label: 'How it works' },
  { href: '#features', label: 'Features' },
  { href: '#download', label: 'Download' },
  { href: '#faq', label: 'FAQ' },
];

export const hero = {
  title: 'Your phone is the microphone. Your TV is the speaker.',
  sub: 'Sing or talk into your Android phone and hear it on your Android TV in about 70–80 ms. Free, no cables, no Bluetooth.',
  cta: 'Download for Android',
  play: 'Google Play: coming soon',
  badges: ['Free', 'No account', 'Works on your Wi-Fi', 'No internet needed'],
  sceneLabel:
    'Animation: a phone types the TV address and PIN, connects, and its microphone voice is received by the TV with about 75 ms delay.',
};

export const steps = [
  { t: 'Open the TV app', d: 'It shows an address and a 6-digit PIN.' },
  { t: 'Type them on your phone', d: 'Enter the address and PIN, then tap Connect.' },
  { t: 'Talk or sing', d: 'Hold to talk, or tap Keep talking.' },
];

export const voicePath = {
  eyebrow: 'Under the hood',
  title: 'How your voice travels',
  lead: 'One 10 ms slice of your voice takes this path from the phone to the TV, about 100 times a second. Packet speed in the drawing is illustrative, not to scale.',
  groups: [
    {
      name: 'Phone',
      nodes: [
        ['Microphone', 'Your voice'],
        ['Native capture', 'Oboe, 10 ms frames'],
        ['Noise gate', 'Mutes the gaps between phrases'],
        ['Mic boost', '−12 to +12 dB, soft limiter'],
        ['Send', 'One UDP packet per 10 ms frame'],
      ],
    },
    { name: 'Network', nodes: [['Your Wi-Fi', 'UDP port 5004, 100 packets/s, never leaves your home']] },
    {
      name: 'TV',
      nodes: [
        ['PIN check', 'Wrong PIN? Dropped'],
        ['Jitter buffer', '10–40 ms, smooths Wi-Fi bumps'],
        ['Voice volume', '−12 to +12 dB'],
        ['Speakers', 'Native low-delay playback'],
      ],
    },
  ],
  returnEdge: 'Stats and connection check, once a second',
  pill: '~75 ms end to end',
};

export const features = {
  eyebrow: 'Features',
  title: 'Made for singing along',
};

export const featureRows = [
  {
    h: 'Near-real-time voice',
    p: [
      'About 70–80 ms from your mouth to the TV output, measured on a Pixel 7 sending to a Chromecast with Google TV, with under 0.5% lost audio. Native Oboe audio runs on both ends.',
      'HDMI and your TV’s own sound processing add a little on top.',
    ],
  },
  {
    h: 'Built-in noise gate',
    p: [
      'The gate mutes the mic between phrases, which cuts the echo of the TV speakers coming back into the phone.',
      'Tip: hold the phone 2–5 cm from your mouth and point it away from the TV.',
    ],
  },
  {
    h: 'Mic volume',
    p: [
      'Phone Mic boost goes from −12 to +12 dB, with a soft limiter that tells you when you are too loud.',
      'TV Voice volume has the same range and is set from the remote D-pad, separate from the TV’s own volume.',
    ],
  },
  {
    h: 'PIN-protected pairing',
    p: [
      'The TV shows a 6-digit PIN. Packets with a wrong PIN are dropped, and only the last phone that paired can play audio.',
      'PIN-protected pairing keeps stray devices out. Made for your trusted home Wi-Fi.',
    ],
  },
  {
    h: 'Hold to talk or Keep talking',
    p: [
      'Use push-to-talk, or switch to always-on.',
      'It keeps working with the screen locked or while you use another app.',
    ],
  },
  {
    h: 'Lives on your TV',
    p: [
      'The TV app starts when the TV boots and runs in the background, so it is ready when you pick up the phone.',
      'Exit stops it completely.',
    ],
  },
  {
    h: 'Live connection stats',
    p: [
      'See the delay as Good, OK or Slow, the network round trip, lost audio and the Wi-Fi band, on the phone and on the TV.',
    ],
  },
];

export const requirements = {
  title: 'What you need',
  items: [
    ['Phone', 'Android 8.0 or newer'],
    ['TV', 'Android TV or Google TV 7.0 or newer'],
    ['Network', 'Both on the same Wi-Fi'],
  ],
  note: 'Guest networks that isolate devices from each other block the connection.',
};

export const download = {
  title: 'Download LAN Mic',
  lead: 'Two free apps: one for the phone, one for the TV. Grab both from GitHub Releases.',
  phone: { name: 'Phone app', file: 'Android 8.0+', note: 'The microphone.' },
  tv: { name: 'TV app', file: 'Android TV / Google TV 7.0+', note: 'The speaker.' },
  phoneInstall: [
    'Download the phone APK from Releases.',
    'Open it and allow installing from your browser or file manager.',
  ],
  tvInstall: [
    'On the TV, turn on Developer options, then Wireless debugging.',
    'Download the TV APK to your computer.',
  ],
  adb: ['adb connect <tv-ip>:<port>', 'adb install lanmic-tv.apk'],
  play: 'Google Play: coming soon',
  signing: 'APKs are for sideloading and are signed with a debug key, so Android may warn you.',
};

export const faq = [
  ['Does it need internet?', 'No. Only your home Wi-Fi, both devices on the same network.'],
  [
    'Why do I hear a small echo?',
    'The phone mic hears the TV speaker. Hold the phone close to your mouth (2–5 cm), point it away from the TV and keep the TV volume moderate.',
  ],
  ['Does it use Bluetooth or mobile data?', 'No. It runs over your Wi-Fi only.'],
  ['Does it work with an iPhone?', 'No. LAN Mic is Android only.'],
  [
    'Is it safe?',
    'Pairing needs the PIN shown on the TV, packets with a wrong PIN are dropped, and audio stays on your local network with no cloud and no account. The PIN is not encryption, so use LAN Mic on a home network you trust.',
  ],
  [
    'Why does Android warn me when I install?',
    'The APKs are sideloaded and currently signed with a debug key. A Google Play release is planned.',
  ],
  ['How much does it cost?', 'Nothing. It is free.'],
];

export const footer = {
  made: 'Made with ❤️ by Namila',
  privacy: 'Audio travels only over your local Wi-Fi. LAN Mic needs no account.',
  legal: 'Android, Google Play and Google TV are trademarks of Google LLC. LAN Mic is not affiliated with Google.',
  links: [
    ['GitHub', REPO],
    ['Releases', RELEASES],
    ['Changelog', `${REPO}/blob/master/CHANGELOG.md`],
    ['Issues', `${REPO}/issues`],
    ['Privacy', '/privacy'],
    ['Architecture', `${REPO}/blob/master/docs/architecture.md`],
  ],
};
