# Monitor output controls

LinkOSC provides one mute button and one volume fader for its audible monitor
output. The controls apply to both audio sources:

- received Link Audio
- the WAV loop used in Dev Mode

Monitoring is intentionally separate from analysis and OSC output. Muting the
monitor or changing its volume does not change `/fft`, `/vol`, onset detection,
or any other analysis result.

## Using the controls

The controls are in the **Monitor** column:

- Click the speaker button to mute or unmute the monitor.
- Drag the volume fader to set the audible output level from 0–100%.
- The fader is disabled while muted; its previous level is restored when the
  monitor is unmuted.

Mute and volume settings are saved automatically. The default is unmuted at
80% volume.

The nearby **gain** control is different: gain is applied before analysis and
therefore changes the OSC values. Use monitor volume for listening level and
gain for input normalization.

## Signal-path design

| Source | Analysis path | Monitor path |
|---|---|---|
| Link Audio | Incoming samples are written to the analysis ring buffer. | The same samples are copied to a jitter-buffered `MonitorOutput`. |
| Dev Mode WAV | An analysis tap reads the player node before the main mixer. | The main mixer's output volume controls audible playback. |

The mute button sets the effective monitor volume to zero. It does not stop the
audio nodes, which keeps unmuting responsive and avoids restarting the monitor
pipeline.

For received Link Audio, `LinkEngine` splits incoming samples into two
independent branches: the analysis ring buffer and `MonitorOutput`. The monitor
uses a short FIFO to absorb timing differences between the sender and the local
audio device. Overflow drops the oldest samples; underrun briefly re-primes the
buffer before playback resumes.

For the Dev Mode WAV, the analysis tap is upstream of the main mixer. Changing
the mixer's output volume therefore changes only what is heard locally.

## Implementation map

- [`AppModel.swift`](../Sources/LinkOSC/AppModel.swift) owns the persisted mute
  and volume state and applies it to both monitor paths.
- [`ContentView.swift`](../Sources/LinkOSC/ContentView.swift) provides the mute
  button, volume fader, and percentage display.
- [`MonitorOutput.swift`](../Sources/LinkOSC/MonitorOutput.swift) renders the
  received Link Audio stream through a jitter-buffered audio engine.
- [`LinkEngine.swift`](../Sources/LinkOSC/LinkEngine.swift) sends received samples
  to the analysis and monitor branches.
- [`DevLooper.swift`](../Sources/LinkOSC/DevLooper.swift) applies monitor volume
  to Dev Mode playback while keeping its analysis tap independent.

## Validation

Build the app from the repository root:

```bash
swift build
swift run LinkOSC
```

Then verify both paths:

1. Enable **Dev Mode**. Move the monitor fader and toggle mute. Confirm that the
   audible WAV changes while the spectrum, volume meters, and OSC output keep
   updating.
2. Disable **Dev Mode**, enable Link and Link Audio in Live 12.4 or later, and
   select a published channel in LinkOSC. Repeat the same checks with the
   received stream.

In Live, the top-bar **LINK** switch and **Link Audio** in Live's settings must
both be enabled. They are separate controls.
