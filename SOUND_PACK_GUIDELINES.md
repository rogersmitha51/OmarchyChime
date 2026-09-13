# Sound Theme Pack Guidelines

Use this specification when creating or remastering an Omarchy Chime sound-theme pack.

## Core requirement

Every pack must have comparable perceived loudness at the same Chime setting. Theme selection may change character, but it must never change basic audibility.

The pack must remain clearly audible at 30–40% system output with Chime level at 100%. Chime's runtime volume is a relative gain: 100% applies no amplification and does not bypass system volume. Loudness must therefore be built into the assets. Never assume runtime gain above `1.0`.

Do not deliver raw generated audio. Generation is only the source step; mastering and validation are mandatory.

## Required files

A complete pack contains exactly these files:

- `window-opened.wav`
- `window-closed.wav`
- `workspace-switched.wav`
- `notification-received.wav`
- `volume-up.wav`
- `volume-down.wav`
- `power-connected.wav`
- `power-disconnected.wav`
- `manifest.json`

The manifest must identify the pack and record each cue's filename or stable cue ID, duration, measured peak dBFS, and measured whole-file RMS/mean dBFS. It must also record the source or synthesis method and applicable license information.

## Audio format

Every cue must use:

- WAV container
- Mono audio
- 44,100 Hz sample rate
- Signed 16-bit PCM
- No metadata-dependent playback behavior

Every cue must also satisfy these technical requirements:

- No clipping, invalid samples, material DC offset, background noise, or accidental reverb tail.
- Normally no more than 10 ms of leading silence.
- A clean ending with a short fade to digital silence; never cut a waveform abruptly.
- At least 3 dB of true-peak headroom.

## Loudness hierarchy

Master by perceived loudness, not peak normalization alone.

### Notification and power cues

These cues must be prominent and unmistakable.

- Target sample peak: **−6 dBFS**
- Acceptable sample-peak range: **−8 to −4 dBFS**

Applies to:

- `notification-received.wav`
- `power-connected.wav`
- `power-disconnected.wav`

### Volume feedback

These cues must be short but immediately audible. Do not make them quiet merely because they are short.

- Target sample peak: **−7 dBFS**
- Acceptable sample-peak range: **−9 to −5 dBFS**

Applies to:

- `volume-up.wav`
- `volume-down.wav`

### Window and workspace feedback

These cues must be audible but subordinate to notifications and power events.

- Target sample peak: **−9 dBFS**
- Acceptable sample-peak range: **−11 to −7 dBFS**

Applies to:

- `window-opened.wav`
- `window-closed.wav`
- `workspace-switched.wav`

### Limits

- No asset may peak below −12 dBFS without a documented perceptual reason and a successful audibility test.
- The absolute sample-peak ceiling is −3 dBFS.
- Never normalize to 0 dBFS.
- Do not make every event equally loud; preserve the hierarchy above.

Peak level alone is insufficient. A narrow transient can reach the target peak and still be inaudible. Control crest factor with synthesis, envelopes, gentle compression, or limiting so each cue contains enough sustained audible energy.

## Consistency

Opposite pairs must have nearly equal perceived loudness:

- `window-opened.wav` and `window-closed.wav`
- `volume-up.wav` and `volume-down.wav`
- `power-connected.wav` and `power-disconnected.wav`

Paired sounds should normally remain within 1 dB of active-region RMS. The same event across different packs should normally remain within 2 dB of the shared reference.

A pack may vary timbre, pitch, envelope, and character. It must not introduce a large volume change when selected in place of another pack.

## Timing

Recommended durations:

| Event | Duration |
|---|---:|
| Window opened/closed | 150–450 ms |
| Workspace switched | 100–350 ms |
| Volume up/down | 80–250 ms |
| Notification received | 400–1,000 ms |
| Power connected/disconnected | 300–800 ms |

Volume cues must remain understandable when volume keys are pressed repeatedly. Avoid long attacks, long tails, or designs whose identifying pitch occurs only near the end.

Longer cues require a documented design reason and must still pass the runtime listening tests.

## Spectral requirements

- Include meaningful energy between roughly 500 Hz and 5 kHz so cues survive laptop speakers.
- Do not depend on sub-bass for identity or loudness.
- Avoid piercing narrow resonances, excessive high-frequency clicks, and harshness.
- A notification must remain recognizable on a small mono speaker.
- Up/down and connected/disconnected pairs must be distinguishable without looking at the screen.

## Measurement rules

Measure at least:

- Duration
- Sample peak in dBFS
- True peak in dBTP
- Whole-file RMS/mean level in dBFS
- Active-region RMS in dBFS

For sub-second interface sounds, standard integrated LUFS can return invalid or misleading results because of loudness gating. Never use LUFS as the only acceptance measurement. Use peak, true peak, active-region RMS, whole-file RMS, crest factor, and controlled listening tests together.

Measurements support the listening test; they do not replace it.

## Required validation

For every final file:

1. Verify the container, codec, channel count, sample rate, and sample format with `ffprobe`.
2. Measure sample peak, true peak, whole-file RMS/mean level, and active-region RMS.
3. Confirm there are no clipped or invalid samples.
4. Confirm the beginning and ending contain no accidental clicks.
5. Compare every paired event and correct obvious loudness imbalance.
6. Audition through actual laptop speakers at 35% system output and 100% Chime level.
7. Repeat the audition with quiet speech or music playing.
8. Confirm notifications and volume feedback remain clearly detectable.
9. Audition at 100% system output and confirm no cue is painfully loud, harsh, or distorted.
10. Compare the pack against the shared reference pack at identical system and Chime settings.

Reject the pack if any cue is technically valid but difficult to hear during the required 35% system-output test.

## Delivery

Deliver only:

- The eight final mastered WAV files
- `manifest.json`
- Measurement results for every cue
- A short report covering the 35% and 100% speaker auditions
- Source and license information

A complete delivery must be ready for direct playback. It must not require a runtime volume boost, a hidden equalizer, or follow-up mastering.
