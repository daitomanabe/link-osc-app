# LinkOSC — OSC Output Specification

**Audience: AI assistants and developers implementing a receiver.**
This document is self-contained: everything needed to build a correct receiver
(TouchDesigner, Max/MSP, openFrameworks, p5.js, Python, Unity, …) is specified
here. No knowledge of the LinkOSC source code is required.

- Spec version: 5 (current as of app v1.0.13; rev 5 = sender-side egress interface pinning — wire format unchanged)
- Sender: LinkOSC (macOS) — receives Ableton Link Audio, analyzes at 60 fps, emits OSC

---

## 1. Transport

| Property | Value |
|---|---|
| Protocol | **UDP unicast**, OSC 1.0 encoding |
| Bundles | Not used by default (one message per datagram). **Per-destination opt-in bundle mode** exists — see §1.1 |
| Timetags | Not used |
| Type tags | Only `f` (float32, big-endian, IEEE 754) and `i` (int32, big-endian) |
| Byte layout | Standard OSC 1.0: null-terminated address padded to 4 bytes, `,`-prefixed typetag string padded to 4 bytes, then arguments |
| Largest datagram | ~656 bytes (128-float messages) — no IP fragmentation on standard LAN MTU |
| Destinations | Up to 4, configured sender-side. Each destination may apply an **address filter** preset — All / Streams (`/fft /vol /pfft /pvol /hfft /hvol /hpss /novelty /chroma`) / Events (`/beat /note /attack /pattack /section`) / Percussive (`/pfft /pvol /pattack /hpss /beat`). **`/ping` is always sent** regardless of filter |
| Multicast | A destination host of `224.0.0.0–239.255.255.255` sends to that multicast group (TTL 1 = same LAN segment). Receivers must join the group (`IP_ADD_MEMBERSHIP`). Wired LAN recommended — Wi-Fi multicast is slow and lossy |
| Egress interface | Sender-side setting, **does not change the wire format**. Default *Auto* = OS routing. The sender can pin all output to one NIC — relevant for receivers only as troubleshooting context: if a multicast group is not arriving on a multi-homed sender, the sender likely needs to pin the interface (the OS otherwise emits multicast on its *primary* interface) |
| Delivery | **Lossy by design.** The sender drops packets when a destination is unreachable or slow (in-flight cap). Receivers MUST tolerate missing frames and MUST NOT assume reliable or ordered delivery |

### 1.1 Bundle mode (per-destination opt-in)

When enabled for a destination, each frame's messages are packed into OSC
**`#bundle`** packets instead of individual datagrams:

- Layout: `"#bundle\0"` (8 B) + timetag (8 B, always **immediate** = `0x0000000000000001`)
  + per element: `int32` size (big-endian) + the OSC message bytes.
- Bundles are **chunked to ≤ 1400 bytes** so no IP fragmentation occurs; a typical
  full frame arrives as 2 bundles. Intra-frame pacing (§2.1) does not apply to
  bundled destinations — the whole frame is sent at t+0.
- Receivers on a bundled destination MUST unpack `#bundle` recursively.
  The address filter still applies.

## 2. Frame model and rates

The sender runs a fixed **60 fps** loop (16.67 ms period, absolute-scheduled).

- **Stream messages** — sent **up to** 60 fps while enabled sender-side:
  `/fft /vol /pfft /pvol /hfft /hvol /novelty /chroma /hpss`
- **Event messages** — sent only when the event occurs:
  `/beat /attack /pattack /section /note`
- **Keepalive** — `/ping` every 500 ms (every 30th frame), **never suppressed**.

**Idle suppression** (sender setting, default ON): a stream message is skipped
when none of its values changed by more than **0.002** since its last
transmission, and is re-sent at least every **500 ms (2 Hz floor)** regardless.
During silence or frozen audio this cuts traffic by ~96%. Consequences:
- A latest-value-store receiver (the recommended pattern) needs no changes.
- Do NOT infer "sender offline" from a stream pausing — use `/ping` (2 s timeout).
- Do NOT use stream message arrival as a frame clock; drive your own render clock.

Every stream can be disabled in the sender UI. **Absence of an address means it
is disabled, not that the signal is zero.** Defaults: everything enabled except
`/hfft` `/hvol`; `/note` exists only in the sender's dev mode.

### 2.1 Intra-frame pacing (burst smoothing)

Within one frame the sender staggers packets to avoid bursts:

| Time offset | Messages |
|---|---|
| t+0 | all events (`/beat /note /attack /pattack /section`), then `/ping` (if due), `/vol /pvol /hvol /novelty /hpss /chroma` |
| t+1 ms | `/fft` |
| t+2 ms | `/pfft` (if enabled; otherwise the next large message shifts up) |
| t+3 ms | `/hfft` (if enabled) |

Offsets have ±≈1 ms scheduler jitter. Consequences for receivers:
- Do **not** assume `/fft` and `/vol` of the same frame arrive together.
- The natural grouping key is time: messages within ~5 ms belong to the same frame.
- For visuals, simply keep a latest-value store per address; frame association
  is almost never needed.

## 3. Message reference

### 3.1 `/fft` — full spectrum
- Typetag: `,ffff…` (128 floats), range **[0, 1]**
- 128 **linear** bands covering 0 Hz → Nyquist. Band width = `sampleRate / 256`
  (48 kHz → 187.5 Hz per band; band *b* covers `b·sr/256 … (b+1)·sr/256` Hz).
  `sampleRate` is the Link Audio stream rate, typically 44100 or 48000.
- Computation: 2048-point FFT, Hann window, ~60 analyses/s on a sliding window;
  each band is the **max** of its 8 underlying FFT bins.
- Calibration: a full-scale sine ≈ 1.0 at its band. Values are clamped to 1.
- Sender-side **gain** (×0.1…8) and a **response curve**
  (`linear | sqrt | log | pow2 | pow3`) are already applied — treat the values
  as display-ready 0..1, do not assume a linear amplitude scale.

### 3.2 `/vol` — volume
- Typetag: `,f`, range **[0, 1]**
- RMS of the last 2048 mono samples (L+R mixed), × gain, then the `/vol` curve.
- Calibration: full-scale sine → **0.707** before curve.

### 3.3 `/pfft`, `/pvol`, `/hfft`, `/hvol` — HPSS-separated variants
- Same typetags, ranges, band layout, curves and calibration as `/fft` and `/vol`.
- `p*` = **percussive-only** (drums, transients), `h*` = **harmonic-only**
  (tonal, sustained), separated by median-filtering HPSS
  (temporal median → harmonic, spectral median → percussive, Wiener soft masks).
- `/pvol`/`/hvol` are Parseval spectral RMS (full-scale sine → 0.707), curved.
- Use case: drive effects from drums only via `/pfft`/`/pvol`/`/pattack`.

### 3.4 `/hpss` — separation energies
- Typetag: `,ff` → `[harmonic, percussive]`, each **[0, 1]**
- Sqrt-companded mean magnitude of each separated spectrum. Good as a compact
  "how tonal vs how percussive is the music right now" pair.

### 3.5 `/novelty` — spectral novelty
- Typetag: `,f`, range **[0, 1]**
- Cosine distance between the mean spectrum of the last 8 frames (~133 ms) and
  the 8 frames before. High values = the sound just changed character.
  Repetitive loops sit near 0–0.3; section changes spike.

### 3.6 `/chroma` — 12 pitch classes
- Typetag: `,ffffffffffff` (12 floats), range **[0, 1]**
- Index 0 = C, 1 = C#, … 11 = B. FFT bins between 55 Hz and 8 kHz are folded
  onto pitch classes; the frame is **max-normalized** (loudest class = 1.0).
  All zeros when silent. Absolute loudness is NOT encoded — combine with `/vol`.

### 3.7 `/beat` — musical beat
- Typetag: `,i`, values **0, 1, 2, 3** (quarter notes within a 4/4 bar, quantum 4)
- Sent **only when the value changes** (i.e., once per beat). At 140 BPM that is
  every ~429 ms. `0` marks the bar head.
- Clock source: the Ableton Link timeline (or the sender's internal clock in dev
  mode). The first value after connect can be any of 0..3.
- The sender may be configured to emit `/beat` only while Live's transport is
  playing; otherwise it also ticks while stopped.

### 3.8 `/attack` — full-band onset
- Typetag: `,f`, strength typically **1.0 … 8.0** (≈ flux / adaptive threshold; capped at 8)
- Sent once per detected onset (spectral flux vs. running-median threshold).
  Sender presets change density: `Tight` (fast repeats, min gap 67 ms),
  `Standard` (133 ms), `Smooth` (strong hits only, 250 ms).

### 3.9 `/pattack` — percussive-only onset
- Same as `/attack` but computed on the HPSS percussive spectrum: fires on
  drum hits, ignores tonal swells. Independent preset. Use for drum-triggered effects.

### 3.10 `/section` — arrangement change at bar heads
- Typetag: `,ffffff` → `[magnitude, dSub, dLow, dMid, dHigh, dPerc]`
- Emitted one **judge window** after a bar head (`/beat 0`) **only when** the
  bar-head sound differs strongly from previous bars. The window is a sender
  setting: ¼ / ½ / 1 / 2 beats (default **1 beat** — e.g. 429 ms at 140 BPM).
  Longer windows react later but are far less likely to miss a change.
- Fire condition (either): overall relative change > threshold
  (High/Medium/Low = 0.25/0.4/0.6), **or** a single band's relative change >
  threshold × 1.75 — this catches one element dropping out (e.g. the kick)
  while the rest of the mix stays loud.
- `magnitude` = max(overall change, largest single-band relative change),
  capped at 4.0. Larger = bigger arrangement change.
- Deltas are **signed** differences (current bar head minus the mean of up to 4
  previous bar heads) of the band profile:
  `sub` = bands 0–2 (0…~560 Hz @48k), `low` = 3–8, `mid` = 9–42,
  `high` = 43–127, `perc` = the `/hpss` percussive value.
- Interpretation: **negative delta = that element disappeared**. A kick drop-out
  produces strongly negative `dSub` and `dPerc`; a build-up entering produces
  positive `dHigh`/`dPerc`.

### 3.11 `/note` — MIDI notes (dev mode only)
- Typetag: `,ii` → `[note 0–127, velocity 1–127]`
- Emitted at note-on times of the sender's looping test MIDI file, sample-locked
  to the looping test audio. Never sent outside dev mode. GM drum numbers in the
  bundled loop: 36 kick, 38/40 snares, 41 tom, 42 closed hat.

### 3.12 `/ping` — keepalive
- Typetag: `,i`, always **1**, every **500 ms**
- Sent as long as the destination is enabled sender-side — even when all
  analyses are disabled. Recommended liveness rule: *sender alive* if any packet
  arrived in the last **2 s**; use `/ping` so this works when streams are off.

## 4. Latency & synchronization notes

- Audio path: Link Audio network buffering (~100 ms, Live-side setting) +
  analysis window (2048 samples ≈ 43 ms @48 kHz). Treat values as "musically
  now" for visuals; do not use for sample-accurate triggering.
- `/beat` comes from the Link timeline (not the audio), so it is **not** delayed
  by the audio buffering — it can lead the analyzed audio by ~100 ms.
- All messages of one frame reflect the same analysis window.

## 5. Receiver implementation guidance

1. Bind a UDP socket on the configured port. Parse OSC 1.0 messages; only
   `f`/`i` argument decoding is required. Bundle handling is needed **only**
   if your destination has bundle mode enabled sender-side (§1.1) — the
   default is one message per datagram.
2. Keep a **latest-value store** for stream addresses and fire **callbacks**
   for event addresses (`/beat /attack /pattack /section /note`).
3. Tolerate: missing frames, missing addresses (disabled sender-side), rate
   drift (send loop is 60 fps but your receive thread may batch), duplicate-free
   but unordered arrival within a few ms.
4. Don't accumulate unbounded queues: if you render slower than 60 fps,
   overwrite with the newest values.
5. A reference parser/monitor ships in the repo: `tools/osc_monitor.py`.

Minimal OSC message parser (Python, sufficient for this spec):

```python
import struct
def parse(data):
    def s(pos):
        end = data.index(b"\x00", pos)
        return data[pos:end].decode(), (end + 4) & ~3
    addr, pos = s(0)
    tags, pos = s(pos)
    args = []
    for t in tags[1:]:
        if t == "f":
            args.append(struct.unpack(">f", data[pos:pos+4])[0]); pos += 4
        elif t == "i":
            args.append(struct.unpack(">i", data[pos:pos+4])[0]); pos += 4
    return addr, args
```

## 6. Machine-readable summary

```json
{
  "spec_version": 5,
  "transport": {
    "protocol": "udp",
    "encoding": "osc1.0",
    "bundles": false,
    "typetags_used": ["f", "i"],
    "lossy": true,
    "frame_rate_hz": 60,
    "idle_suppression": {"default": true, "epsilon": 0.002, "min_rate_hz": 2, "applies_to": "streams only"},
    "qos": "serviceClass interactiveVideo (DSCP marked)",
    "egress_interface": "sender-side pin (default Auto = OS routing); wire format unaffected",
    "per_destination": {"filters": ["all", "streams", "events", "percussive"], "ping_always_sent": true, "bundle_mode": {"opt_in": true, "timetag": "immediate", "max_bundle_bytes": 1400}, "multicast": "host 224-239.x.x.x, TTL 1, receivers join group"},
    "intra_frame_pacing_ms": {"events_and_small": 0, "/fft": 1, "/pfft": 2, "/hfft": 3}
  },
  "messages": [
    {"address": "/fft",     "args": "f*128", "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "128 linear bands 0..Nyquist, band width sr/256 Hz, curve+gain applied", "default_enabled": true},
    {"address": "/vol",     "args": "f",     "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "RMS of last 2048 samples, fullscale sine=0.707 pre-curve", "default_enabled": true},
    {"address": "/pfft",    "args": "f*128", "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "percussive-only spectrum (HPSS)", "default_enabled": true},
    {"address": "/pvol",    "args": "f",     "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "percussive-only volume", "default_enabled": true},
    {"address": "/hfft",    "args": "f*128", "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "harmonic-only spectrum (HPSS)", "default_enabled": false},
    {"address": "/hvol",    "args": "f",     "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "harmonic-only volume", "default_enabled": false},
    {"address": "/hpss",    "args": "ff",    "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "[harmonic, percussive] energies", "default_enabled": true},
    {"address": "/novelty", "args": "f",     "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "spectral novelty, ~133ms vs previous ~133ms", "default_enabled": true},
    {"address": "/chroma",  "args": "f*12",  "range": [0,1], "kind": "stream", "rate_hz": "<=60, floor 2", "meaning": "pitch classes C..B, max-normalized per frame", "default_enabled": true},
    {"address": "/beat",    "args": "i",     "values": [0,1,2,3], "kind": "event", "meaning": "quarter note in bar (Link timeline), on change only; 0 = bar head", "default_enabled": true},
    {"address": "/attack",  "args": "f",     "range": [1,8], "kind": "event", "meaning": "fullband onset strength", "default_enabled": true},
    {"address": "/pattack", "args": "f",     "range": [1,8], "kind": "event", "meaning": "percussive-only onset strength", "default_enabled": true},
    {"address": "/section", "args": "ffffff","kind": "event", "meaning": "[magnitude<=4, dSub, dLow, dMid, dHigh, dPerc] one judge-window (0.25-2 beats, default 1) after a bar head, on overall OR strong single-band change; negative delta = element disappeared", "default_enabled": true},
    {"address": "/note",    "args": "ii",    "kind": "event", "meaning": "[midi note, velocity] note-on, dev mode only", "default_enabled": "dev mode only"},
    {"address": "/ping",    "args": "i",     "values": [1], "kind": "keepalive", "rate_hz": 2, "meaning": "sender alive; suggest 2s timeout", "default_enabled": true}
  ]
}
```

## 7. Prompt template (paste when asking an AI to build a receiver)

> Implement an OSC receiver for the LinkOSC protocol described in OSC-SPEC.md.
> Requirements: UDP port <PORT>; latest-value store for stream addresses;
> callbacks for /beat /attack /pattack /section /note; consider the sender
> offline if no packet (including /ping) arrives for 2 seconds; never block the
> render loop on the socket; tolerate missing addresses and dropped frames.
