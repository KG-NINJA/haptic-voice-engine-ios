# Hardware limitations (known and expected)

- The Taptic Engine is a linear resonant actuator tuned for tactile feedback. Its acoustic
  output is a by-product; Apple documents no frequency response for it.
- Core Haptics exposes *intensity* and *sharpness* (0–1), not frequency, waveform or sample
  data. Sharpness changes the felt character; any mapping to Hz must be measured, not assumed.
- Parameter curves are limited to 16 points each (the app chunks longer curves) and are
  interpolated by the system; fast modulation (≥ 20–40 Hz requested) may be smoothed. The
  app records the **requested** rate only.
- Speech needs roughly 100 Hz–4 kHz with formant structure. If the actuator's output stays
  near one resonance, vowel formants cannot be reproduced; at best an envelope (rhythm,
  syllable timing) is conveyed. Distinguishing vowels by sound may therefore fail; that is a
  valid result.
- Touching surfaces (desk, box, glass) change loudness and resonance; results are per-material.
- The Simulator has no Taptic Engine (`supportsHaptics = false`). The UI tests use a
  simulated backend that produces no output and is labelled SIMULATED.
- `playsHapticsOnly = true` prevents audio from the haptic engine; the device speaker is never
  used, so any sound measured comes from mechanical vibration.
- Thermal state, Low Power Mode, and system haptics settings (Settings → Sounds & Haptics)
  can suppress or weaken output. If *System Haptics* is off, Core Haptics may still play in
  the foreground, but verify physically.
- Free Apple Account signing expires after 7 days.
