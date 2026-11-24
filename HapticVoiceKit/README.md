# HapticVoiceKit

Swift package for the "Simple voice" technique: turns text-to-speech PCM into a Core Haptics
pattern of pitch-rate transient clicks (voiced), short sharp bursts (consonants) and silence.
Haptics only; nothing is played through the speaker.

- `SpeechSynthesisRenderer` — offline `AVSpeechSynthesizer.write` rendering to `[Float]` PCM.
- `SpeechFeatureExtractor` — RMS envelope, F0, spectral centroid, rough F1/F2 (vDSP).
- `PulseVoice.events(samples:sampleRate:options:)` → `[PulseVoiceEvent]`; `PulseVoice.pattern(_:)` → `CHHapticPattern`.

Technique, usage example and what has / has not been verified: [docs/VOICE_LIKE_VIBRATION.md](../docs/VOICE_LIKE_VIBRATION.md).

`swift test` runs on macOS (synthetic-signal tests; no hardware).
