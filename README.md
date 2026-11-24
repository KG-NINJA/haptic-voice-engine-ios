# Haptic Voice Engine — iOS Experimental MVP

Research app that asks one question: **can controlled Taptic Engine vibrations (Core Haptics,
haptics-only) produce distinguishable vowels or intelligible speech, without the speaker?**
It does not assume the answer is yes. Every speech pattern is labelled *(experimental)*;
nothing in the app claims speech is reproduced.

## What it does
- Single SwiftUI screen: hardware status (Core Haptics / audio capability, engine state,
  `playsHapticsOnly`, device model, iOS version), manual controls (intensity, sharpness,
  duration 0.1–3.0 s, modulation rate), always-visible **STOP**.
- Presets: single pulse, continuous, intensity sweep, sharpness sweep, amplitude modulation,
  rhythmic pulses.
- Speech experiments for あ い う え お / Hello / AI / custom text: `AVSpeechSynthesizer.write`
  renders PCM **offline only** (never played), features are extracted (RMS envelope,
  autocorrelation F0, spectral centroid, LPC formants F1/F2 where voiced) and mapped with
  four methods: simple voice (clicks at the voice pitch, default), envelope→intensity, spectrum→sharpness, combined curves + transients.
- 5×5 characterization matrix (intensity 0.2–1.0 × sharpness 0–1, 1 s each) per material.
- Blind vowel test (target hidden), accuracy, confusion matrix, 20 % chance, binomial p-value.
- Physical confirmation per play ("Felt vibration" / "Nothing felt") — API success ≠ vibration.
- `experiment_results.json` export (share sheet, also in Files → On My iPhone → HapticVoice).
- Safety: 3 s max per play, 2 s cooldown, 300 plays / 20 min session cap, watchdog,
  stop on background, engine stop/reset, serious/critical thermal state.

Only `hapticContinuous` / `hapticTransient` events are created; no audio events,
no `AVAudioPlayer`, no private APIs.

## Layout
| Path | Contents |
|---|---|
| `HapticVoiceEngine/Haptics` | `HapticEngineController` (UI-independent, App-Clip-ready), backends, safety, patterns |
| `HapticVoiceEngine/Speech` | offline synthesis, vDSP feature extraction, haptic mappings |
| `HapticVoiceEngine/Experiments` | records, blind trials, JSON export |
| `HapticVoiceEngine/UI` | SwiftUI screen |
| `HapticVoiceEngineTests`, `HapticVoiceEngineUITests` | unit + UI tests (UI tests use a clearly-labelled simulated backend) |
| `tools/acoustic_lab.py` | microphone recording / FFT / spectrogram / baseline + reference comparison |
| `docs/` | build, protocol, test report, hardware limitations, results template |

See [docs/BUILD_INSTRUCTIONS.md](docs/BUILD_INSTRUCTIONS.md) and
[docs/EXPERIMENT_PROTOCOL.md](docs/EXPERIMENT_PROTOCOL.md).
