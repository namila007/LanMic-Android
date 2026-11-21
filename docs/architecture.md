# LAN Mic architecture

Two Flutter apps share one native audio plugin. Dart handles the screens, connection state and stats. Audio frames never pass through Dart: they move between the microphone, the network and the speaker entirely in C++ and Kotlin.

## High-level components

```mermaid
flowchart LR
    subgraph Phone["Phone app · LAN Mic (me.namila.app.lanmic)"]
        direction TB
        PUI["MicScreen · StatsCard · Mic boost row"]
        PVM["MicViewModel · TalkGate"]
        PSES["SessionService · ConnectionMachine · LinkStats"]
        PMIC["MicService (native capture, level, stats poll)"]
        subgraph PPlug["pcm_out plugin (shared)"]
            PK["Kotlin NativeReceiver<br/>UDP socket on an ephemeral port"]
            PC["C++ AudioIn<br/>Oboe input · FrameQueue · NoiseGate · Gain · sender thread"]
        end
        PWB["wifi_band plugin<br/>Wi-Fi band · low-latency lock"]
        PUI --> PVM --> PSES
        PVM --> PMIC --> PC
        PSES -- "HELLO / END · targets" --> PK
        PK -- "socket fd" --> PC
        PVM --> PWB
    end

    subgraph TV["TV app · LAN Mic Receiver (me.namila.app.lanmic.tv)"]
        direction TB
        TUI["ReceiverScreen · stats line · Voice volume"]
        TVM["ReceiverViewModel"]
        subgraph SVC["Foreground service isolate (starts on boot)"]
            TENG["ReceiverEngine · SessionRegistry · LossMeter"]
        end
        subgraph TPlug["pcm_out plugin (shared)"]
            TK["Kotlin NativeReceiver<br/>UDP 5004 · validates AUDIO"]
            TC["C++ JitterRing → AudioOut<br/>Oboe output · Gain"]
        end
        TWB["wifi_band plugin"]
        TUI --> TVM
        TENG -- "status 4×/s" --> TVM
        TENG -- "accept(phone, pin) · STATS · ACK" --> TK
        TK -- "AUDIO frames (JNI)" --> TC
        TC -- "stats" --> TENG
        TENG --> TWB
    end

    PC == "AUDIO · 972 B every 10 ms<br/>UDP 5004 · DSCP EF" ==> TK
    PK -- "HELLO (+RTT, delay) · END" --> TK
    TK -- "ACK / REJECT · STATS 1/s" --> PK
```

| Component | Role |
|---|---|
| `protocol/` | Pure Dart packet codec: 12-byte header and types `AUDIO`, `HELLO`, `ACK`, `END`, `REJECT`, `STATS`; plus the Good/OK/Slow rule |
| `pcm_out/` | Shared native plugin. C++: Oboe input and output, `JitterRing`, `FrameQueue`, `NoiseGate`, voice gain and limiter. Kotlin: the UDP socket and JNI bridge |
| `wifi_band/` | Reads the Wi-Fi band and holds a low-latency Wi-Fi lock |
| Phone `SessionService` | Connection state (HELLO every 2 s), round-trip time, STATS intake, and the native send target |
| TV `ReceiverEngine` | PIN check, "last valid HELLO wins", ACK/REJECT, STATS once a second, and the stats shown on screen |

## Connect and talk

```mermaid
sequenceDiagram
    participant P as Phone (Dart)
    participant PN as Phone native
    participant TN as TV native (Kotlin)
    participant T as TV (Dart engine)
    P->>TN: HELLO (seq = ping id, PIN)
    TN->>T: control packet
    T->>TN: accept(phone ip:port, PIN)
    T-->>P: ACK (echoes seq → RTT)
    P->>PN: setTarget(TV, 5004, PIN)
    Note over P,PN: user holds / taps Talk
    P->>PN: start capture
    loop every 10 ms
        PN->>TN: AUDIO frame (native → native)
    end
    T-->>P: STATS 1/s (TV delay, lost audio, jitter, band)
    P->>TN: HELLO every 2 s (+ RTT, total delay)
    Note over P,PN: user releases
    P->>PN: stop capture (drains every queued frame)
    P->>TN: END
    TN->>TN: flush jitter ring
```

## Phone audio path

```mermaid
flowchart LR
    MIC["Mic (VoicePerformance preset)"] --> OB["Oboe input stream<br/>LowLatency · Exclusive · MMAP<br/>48 kHz mono I16"]
    OB -->|"data callback:<br/>copy only, no locks"| FA["FrameAssembler<br/>chunks → 480-sample frames"]
    FA --> FQ["FrameQueue<br/>SPSC, 8 frames<br/>full → drop newest"]
    FQ -->|"sem_post wake"| ST["Sender thread"]
    ST --> NG["NoiseGate<br/>open −38 dBFS · close −44 · hold 250 ms"]
    NG --> GN["Mic boost gain<br/>−12..+12 dB · 10 ms ramp<br/>soft limiter above −3 dBFS"]
    GN --> PK["AUDIO packet<br/>12 B header + 960 B PCM"]
    PK -->|"sendto(dup'd socket fd)"| NET(("Wi-Fi<br/>UDP 5004"))
    ST -.->|"stats: level, send gap,<br/>input latency, limiting"| DART["Dart MicService<br/>level meter · stall watchdog · LinkStats"]
```

- Frames leave the moment they fill, no more than about 10 ms apart. The `record` plugin used to hand over audio in clumps.
- `stopCapture` is synchronous: it drains the queue before Dart sends `END`, so END never overtakes the last frame.

## TV audio path

```mermaid
flowchart LR
    NET(("Wi-Fi<br/>UDP 5004")) --> RX["Kotlin receive thread<br/>URGENT_AUDIO priority"]
    RX -->|"valid AUDIO from accepted<br/>phone + PIN (JNI push)"| JR["JitterRing<br/>16 slots · seqlock · SPSC"]
    RX -->|"HELLO / END / other"| ENG["Dart ReceiverEngine<br/>(service isolate)"]
    JR --> TGT{"adaptive target<br/>10–40 ms from jitter"}
    TGT -->|"in order"| RD["ring.read"]
    TGT -->|"gap / late"| PLC["PLC: repeat last frame<br/>−6 dB each, then silence"]
    TGT -->|"too deep"| DR["drain: skip a quiet frame"]
    PLC --> RD
    DR --> RD
    RD --> GV["Voice volume gain<br/>−12..+12 dB · soft limiter"]
    GV --> AO["Oboe output callback<br/>LowLatency · MMAP · 2 bursts"]
    AO --> HDMI["HDMI → TV speakers"]
    AO -.->|"stats: depth, output latency,<br/>lost, jitter, limiting"| ENG
    ENG -->|"STATS 1/s"| PHONE(("phone"))
    ENG -->|"status"| UI["ReceiverScreen<br/>stats line · Voice volume"]
```

- The output stream opens on the first frame of a burst and closes after 10 s of quiet. It reopens itself after an HDMI or route change.
- An empty buffer holds the current frame instead of skipping it, so a frame that arrives a few ms late still plays. Playback then runs one frame later.

## Where the delay goes (Pixel 7 → Chromecast with Google TV, 5 GHz)

```mermaid
pie showData title Mouth to TV output, about 75 ms
    "Phone capture + frame fill" : 7
    "Wi-Fi (half the round trip)" : 6
    "TV jitter buffer" : 20
    "TV output (shared MMAP)" : 42
```

HDMI and the TV's own sound processing come after this and aren't measured by the app.
