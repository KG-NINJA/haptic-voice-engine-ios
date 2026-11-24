# Haptic Voice Engine — iOS Experimental MVP

Research app that asks one question: **can controlled Taptic Engine vibrations (Core Haptics,
haptics-only) produce distinguishable vowels or intelligible speech, without the speaker?**
It does not assume the answer is yes. Every speech pattern is labelled *(experimental)*;
nothing in the app claims speech is reproduced.

**On-device status:** on the owner's iPhone SE (3rd gen) the vibration is felt, and the
*Simple voice* method (pitch-rate click train) was heard as voice-like by the owner (informal
listening). Microphone measurements and blind listener tests have not been run. The technique and
its reusable Swift package are documented in [docs/VOICE_LIKE_VIBRATION.md](docs/VOICE_LIKE_VIBRATION.md).

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
- Audio file: pick a file (Files app), the first 3 s are analysed (never played) and played back with
  the selected method. Only pitch (80–300 Hz) and rhythm carry over; this is not a speaker replacement.
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
| `HapticVoiceKit` | reusable Swift package: offline synthesis, feature extraction, Simple voice click-train synthesis |
| `HapticVoiceEngine/Haptics` | `HapticEngineController` (UI-independent, App-Clip-ready), backends, safety, patterns |
| `HapticVoiceEngine/Speech` | speech→haptic mapping methods (Method 4 uses `HapticVoiceKit`) |
| `HapticVoiceEngine/Experiments` | records, blind trials, JSON export |
| `HapticVoiceEngine/UI` | SwiftUI screen |
| `HapticVoiceEngineTests`, `HapticVoiceEngineUITests` | unit + UI tests (UI tests use a clearly-labelled simulated backend) |
| `tools/acoustic_lab.py` | microphone recording / FFT / spectrogram / baseline + reference comparison |
| `docs/` | build, protocol, test report, hardware limitations, results template |

See [docs/BUILD_INSTRUCTIONS.md](docs/BUILD_INSTRUCTIONS.md) and
[docs/EXPERIMENT_PROTOCOL.md](docs/EXPERIMENT_PROTOCOL.md).
