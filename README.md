# link-audio-osc (LinkOSC)

**Receive Ableton Link Audio or a macOS audio input, analyze it, and send OSC — a macOS utility for audio-reactive visuals.**

[![Release](https://img.shields.io/github/v/release/daitomanabe/link-osc-app)](https://github.com/daitomanabe/link-osc-app/releases)
[![License: GPL-2.0-or-later](https://img.shields.io/badge/License-GPL--2.0--or--later-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS_13%2B-Apple_Silicon-lightgrey)

📖 **[User Manual](docs/MANUAL.md)** · **[ユーザーマニュアル (日本語)](docs/MANUAL.ja.md)** · **[OSC spec for receiver builders / AI assistants](OSC-SPEC.md)** · **[Monitor output design](docs/MONITORING.md)**

Offline sibling: **[vjbake](https://github.com/daitomanabe/vjbake)** bakes the
same analysis (identical source & calibration) from audio files into 60 fps
JSON + a pixel data video — build a show against vjbake data, run it live
against LinkOSC.

![LinkOSC main window](docs/images/main-window.png)

LinkOSC joins an [Ableton Link](https://github.com/Ableton/link) session, subscribes to a
**Link Audio** channel (Live 12.4+ publishes its tracks/Main natively — no BlackHole or
virtual audio driver needed) or a selected macOS input device, runs a realtime analysis
chain, and streams the results as OSC to up to 4 destinations. Beat position comes from
the Link timeline. A dev mode loops a bundled WAV + MIDI at a fixed BPM so you can build
OSC receivers without Live running.

Built with SwiftUI + Metal + Accelerate (vDSP) + the official Link SDK (`abl_link` C API).
Apple Silicon, macOS 13+.

## OSC output

**Building a receiver (or asking an AI to)?** Feed [`OSC-SPEC.md`](OSC-SPEC.md) to your
assistant — it is a self-contained, machine-oriented specification of everything below
(exact typetags, ranges, calibration, pacing, keepalive rules, JSON summary).

| Address | Payload | Rate |
|---|---|---|
| `/fft` | float × 128 (0..1, linear bands 0..Nyquist) | 60 fps |
| `/vol` | float (RMS 0..1) | 60 fps |
| `/pfft` | float × 128 — **percussive-only** spectrum (HPSS) | 60 fps |
| `/pvol` | float — percussive-only volume | 60 fps |
| `/hfft` | float × 128 — harmonic-only spectrum (HPSS) | 60 fps |
| `/hvol` | float — harmonic-only volume | 60 fps |
| `/hpss` | float harmonic, float percussive (0..1 energies) | 60 fps |
| `/novelty` | float 0..1 (spectral novelty) | 60 fps |
| `/chroma` | float × 12 (pitch classes C..B, max-normalized) | 60 fps |
| `/beat` | int 0,1,2,3 (quarter notes, Link timeline) | on change |
| `/attack` | float strength — fullband onset | on detection |
| `/pattack` | float strength — onset on the HPSS **percussive** component only | on detection |
| `/section` | float magnitude + float×5 deltas (sub/low/mid/high/perc) | at bar heads, on big change |
| `/note` | int note, int velocity (dev mode, from the MIDI loop) | on note-on |
| `/ping` | int 1 (keepalive) | every 500 ms |

Checked analyses in the UI are always computed & sent; unchecked ones cost no CPU.
`/pfft`/`/pvol` make it easy to drive effects from drums only — tonal material is
filtered out by the HPSS separation, and `/pattack` fires on percussive onsets only.

![Destinations section](docs/images/destinations.png)

**Per-destination options**: an address-filter preset (All / Streams / Events /
Percussive — `/ping` always sent), an opt-in **bundle mode** (`#bundle` packets,
chunked ≤1400 B, receiver must unpack), and **multicast** — set the host to a
`239.x.x.x` group address (wired LAN recommended; receivers join the group).

**Interface pinning**: by default OSC leaves via OS routing (*Auto* — correct for
most unicast). The Interface picker pins all output to a specific NIC. This
matters when a **multicast** group must leave a specific port (the OS otherwise
emits multicast on the *primary* interface), or when Wi-Fi and Ethernet share a
subnet. Connections are rebuilt automatically on network changes (cable
plug/unplug, Wi-Fi switch); if the pinned NIC disappears the app falls back to
Auto with a warning and re-pins when it returns. Hover a destination's status
dot to see the actual egress path (e.g. `via en5 · 10.0.0.23`).

**Network efficiency**: per-frame sends are batched per connection
(`NWConnection.batch`, ~36% lower send-path cost), packets are DSCP-marked as
interactive video (Wi-Fi WMM priority), and **idle suppression** (default on)
skips stream messages whose values haven't changed, with a 2 Hz refresh floor —
silence costs ~96% fewer packets. `/ping` and events are never suppressed.

**Send pacing**: events and small messages go out immediately; the three large
spectrum packets (`/fft` `/pfft` `/hfft`, ~670 B each) are staggered into 1 ms slots
(+1/+2/+3 ms) instead of bursting in one instant. This avoids receiver-side UDP
buffer overruns (single-threaded Max/TouchDesigner patches) and Wi-Fi burst loss;
the few-ms skew is imperceptible at 60 fps. Sends are also gated on connection
readiness with an in-flight cap — stalled destinations drop packets instead of
queueing unboundedly. Verify pacing with `./.build/debug/LinkOSC --pacetest <port>`.

![Monitor column](docs/images/monitor.png)

**Monitoring**: the Monitor column has a mute toggle and volume fader for the
audible output — they control both the dev-mode WAV playback and a built-in
monitor of the received Link Audio stream (jitter-buffered). Local input devices
are not played back, preventing microphone feedback. Muting or changing volume
never affects analysis or OSC output. Analysis gain has two modes: **Auto**
summarizes each 4-second block (minimum, maximum, median, average and peak),
updates once at the block boundary, and holds that gain for the next block. It
targets a 0.95 peak, permits brief overshoot up to 1.05, and clamps published
analysis values to 0...1;
**Manual** exposes the `×0.1…×8.0` gain fader. The selected mode and manual value
are saved. The Monitor header's **Adjusted / Raw** selector changes only the
on-screen spectrum, L/R meters, and history: Adjusted shows the gain-processed
signal, while Raw shows the input before analysis gain. OSC output is unchanged.

**UI**: two-column layout (settings left, monitor right) sized for up to 1280×900 —
tall enough that the settings column never scrolls, and shrinkable to 620 pt high
on small screens (the left column becomes scrollable).
Rendering **auto-pauses while the window is fully occluded** (zero draw cost in the
background; verified by profiler) and each OSC destination row shows a live status
dot — gray disabled / orange connecting / green sending / red dropping.
**Lite mode** (switch in the Monitor header) stops all Metal rendering and slows UI
refresh to 1 Hz once you're done checking the signal — analysis and OSC output are
completely unaffected. `/ping 1` is sent every 500 ms as a receiver keepalive.

### Analysis chain (lightweight 60 fps ports of flucoma-core ideas)

![Analysis section](docs/images/analysis.png)

- **Curves**: independent response curves for /fft and /vol (Linear / Sqrt / Log / Pow² / Pow³),
  also applied to the HPSS variants
- **/attack**: spectral flux + adaptive threshold (running median × ratio). Golden presets:
  `Tight` / `Standard` / `Smooth`
- **/pattack**: the same onset detector fed with the HPSS percussive spectrum
- **HPSS**: median filtering (temporal → harmonic, spectral → percussive) + Wiener soft
  masks. Presets `Fast`(7,17) / `Standard`(17,31) / `Deep`(31,63) = (time, freq) kernels
- **/novelty**: cosine distance between the mean spectra of the last 8 frames and the 8 before
- **/chroma**: 55 Hz–8 kHz bins folded into 12 pitch classes
- **/section**: averages a band profile [sub, low, mid, high, percussive] over a
  configurable **judge window** after each bar head (1/256, 1/128, 1/64, 1/32,
  1/16, 1/8, ¼, ½, 1, or 2 beats; default 1 beat) and compares against recent bar
  heads. Windows shorter than one 60 fps analysis frame judge on the next frame;
  longer windows react later but average more audio.
  sensitivity High/Medium/Low. Fires on overall change **or** on a strong
  single-band change (so a kick dropping out of a loud mix is not missed).
  Negative deltas mean a band disappeared (kick drop → strongly negative sub/perc)
- **Visualizers (Metal)**: spectrum with harmonic (cyan) / percussive (orange) overlays,
  L/R + H/P meters, stereo correlation bar, 12-color chroma bars, and an 8-second history
  graph (vol / novelty / harmonic / percussive + attack / pattack / section markers)

## Install

1. Download `LinkOSC-x.y.z.zip` from Releases, unzip, move `LinkOSC.app` anywhere
2. First launch: the app is ad-hoc signed (not notarized) — right-click → **Open**,
   or `xattr -dr com.apple.quarantine LinkOSC.app`
3. Allow **Local Network** access when prompted (required for Link's UDP multicast)
4. If you select a macOS input device, also allow **Microphone** access when prompted

## Use with Ableton Live 12.4+

![Link Audio channel setup](docs/images/link-setup.png)

1. In Live: Settings → Link → **Link Audio: On**, *and* turn on the **LINK toggle in
   Live's top bar** (if Live's Peers list says "Enable Link to show available peers",
   Link itself is still off)
2. In LinkOSC, choose **Ableton Link Audio** under Audio Input, then pick a channel —
   `Live | Main` is the master output. Audio can take a few seconds to start; the channel
   list re-polls every 2 s and ↻ restarts discovery
3. Enable OSC destinations (host/port). Everything is saved automatically

To analyze a microphone, audio interface, aggregate device, or virtual device instead,
select it from **Audio Input → Source**. The stable Core Audio device UID is saved. Link
can remain enabled so `/beat` still follows the Link session while audio comes from the
selected device. For multi-channel interfaces, choose a non-overlapping stereo pair
(`Stereo 1–2`, `Stereo 3–4`, …) or an individual input (`Mono 1`, `Mono 2`, …) from
the **Channel** menu.

Verify with the bundled monitor: `python3 tools/osc_monitor.py 9001`

## Dev mode

![Dev mode](docs/images/devmode.png)

Toggle **Dev Mode** to work without Live: Link is disabled and a bundled 140 BPM WAV
(32 beats) + drum MIDI loop plays through the same analysis → OSC chain, with `/beat`
free-running at the set BPM and `/note` emitted from the MIDI loop. Use the **Bundled**
menu to switch between dry and effects versions of the loop. The test data is embedded
in the app bundle; custom WAV/MIDI paths are saved and fall back to the bundled data if
missing. Click **Auto BPM** to count the loop tempo continuously; it locks after roughly
4–6 seconds, searches only 90–180 BPM, and uses 110–140 BPM as a weak preference.

## Build from source

```bash
git clone --recursive https://github.com/daitomanabe/link-osc-app
cd link-audio-osc
./build_app.sh        # → dist/LinkOSC.app (release, ad-hoc signed)
```

Requires macOS 13+ and a Swift 6 toolchain (Command Line Tools are enough).
`--recursive` matters: the Link SDK lives in `vendor/link` as a git submodule
(with its own nested submodules).

CLI diagnostics (debug build: `swift build`):

```bash
./.build/debug/LinkOSC --probe          # show Link peers & Link Audio channels for 10 s
./.build/debug/LinkOSC --publish        # publish a 440 Hz test channel (fake Live)
./.build/debug/LinkOSC --rxtest 9099 Main   # subscribe & report received frames
./.build/debug/LinkOSC --devtest 9099   # dev-mode loop + full analysis self-test
./.build/debug/LinkOSC --selftest 9099  # FFT calibration / Link timeline / OSC encoding
./.build/debug/LinkOSC --ifacetest      # interface pinning: enumerate NICs, prove routing constraint, multicast egress
./.build/debug/LinkOSC --inputtest --capture  # enumerate inputs; also capture when permission is already granted
./.build/debug/LinkOSC --autogaintest   # automatic-gain block hold / statistics / silence regression
./.build/debug/LinkOSC --docshot out.png 12   # self-screenshot of the live UI (regenerates the docs images)
```

Runtime lifecycle and stall diagnostics are written as JSON Lines to
`~/Library/Logs/LinkOSC/runtime.log` (rotated at 512 KB; previous file is
`runtime.log.1`). Audio samples and per-frame OSC values are not logged.

## License

**GPL-2.0-or-later.** This project links against the
[Ableton Link SDK](https://github.com/Ableton/link) (including Link Audio and the
`abl_link` C extension), which Ableton distributes under **GPLv2+**; this repository is
licensed under the same terms — see [LICENSE](LICENSE). If you need to use Link in a
proprietary application, Ableton offers separate licensing (<link-devs@ableton.com>).
The bundled test loops (`loop-test.wav`, `loop-test-effects.wav`) and MIDI
(`loop-test.mid`) are provided under the repository license. Test media
copyright: Copyright (c) 2026 Daito Manabe

---

## 日本語メモ

- **構成**: Ableton Link (beat) + Link Audio (audio) を受信 → vDSP で解析 → OSC 送信。
  BlackHole 等の仮想オーディオドライバは不要（Live 12.4+ がネイティブでチャンネルを公開）
- **Live 側設定**: 設定 → Link → Link Audio「On」と、**メイン画面左上の LINK トグル**の
  両方が必要（設定画面の Peers 欄に "Enable Link to show available peers" と出ている間は
  Link 本体が OFF）
- **開発モード**: Live なしで内蔵 WAV+MIDI（140BPM・32拍、dry/effects）をループし、
  同じ解析チェーンで OSC を送信。`/note` は MIDI ノートオンから。**Auto BPM** は
  90〜180 BPM の範囲を約4〜6秒で推定（110〜140 BPMを弱く優先）
- **チェック連動**: 解析トグルにチェックが付いているものだけが計算・送信・可視化される
- **/pfft /pvol /pattack**: HPSS で分離した percussive 成分だけの spectrum / volume /
  onset。ドラムにだけ反応するエフェクトを作るときに便利
- 設定はすべて自動保存（UserDefaults）
