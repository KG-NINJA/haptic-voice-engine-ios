# Voice-like vibration on iPhone: the "Simple voice" technique

How this project makes the Taptic Engine produce a sound heard as voice-like, using Core Haptics
in haptics-only mode (no speaker, no audio events). Reusable code: [`HapticVoiceKit`](../HapticVoiceKit).

## Status: what is confirmed and what is not

| Claim | Status | Evidence |
|---|---|---|
| Vibration is physically felt on device | Confirmed | Owner, iPhone, 2026-11-24 |
| Continuous-event mappings (Methods 1–3: envelope, spectral, combined curves) sound like speech | **No** | Owner: "vibrates but does not sound like a voice" |
| Simple voice (Method 4) is heard as voice-like | Reported by the owner | Owner's informal listening on iPhone SE (3rd gen), 2026-11-24. Which words, pitch setting and surface were used was not recorded |
| Output frequency / harmonics match the requested click rate | **Not measured** | No external-microphone FFT yet |
| Vowels are distinguishable above chance (Level 4) | **Not tested** | No blind trials yet |
| Speech is intelligible to independent listeners (Level 5) | **Not tested** | — |
| Works the same on other iPhone models | **Unknown** | Only iPhone SE (3rd gen) tried |

Until microphone measurements and blind listener tests are done, treat "voice-like" as one
listener's impression, not as reproduced speech.

## Why the earlier methods failed and this one differs

Methods 1–3 drive one long `hapticContinuous` event and shape it with intensity/sharpness
parameter curves (20 ms control points). The actuator then vibrates at its own carrier; the curves
only change loudness and texture slowly, so there is no voice pitch in the sound.

Simple voice instead emits **one `hapticTransient` click per pitch period**. Each click is a short
mechanical impulse; a train of them at 100–300 Hz is heard as a buzz whose pitch is the click rate,
similar to the glottal pulse train that excites a human voice. Turning the train on and off with
the speech's syllables keeps the rhythm and intonation of the word.

## Algorithm

1. Render the text offline with `AVSpeechSynthesizer.write(_:toBufferCallback:)` and keep the PCM
   in memory (never played).
2. Analyse in 10 ms hops / 25 ms windows: RMS envelope (normalized to peak, smoothed),
   autocorrelation F0 (70–400 Hz), spectral centroid.
3. For each frame, below 3 s:
   - envelope ≤ 0.15 → **silence**, no events;
   - active but unvoiced (no F0: consonants such as s, h, k) → part of a **burst**:
     one `hapticContinuous` event, intensity 0.6, sharpness 1.0, at least 30 ms;
   - voiced → **clicks** `hapticTransient` every `1 / clamp(F0 × pitchScale, 80, 300)` s,
     intensity `0.4 + 0.6 × envelope`, sharpness `0.2 + 0.6 × normalizedCentroid`.
     The last known F0 carries across frames where pitch tracking drops out.
4. Build a `CHHapticPattern` from the events only (no parameter curves) and play it on a
   `CHHapticEngine` with `playsHapticsOnly = true`.

`pitchScale` (×1, ×1.5, ×2 in the app) raises the click rate. Which setting sounds most voice-like
has not been recorded.

## Using it in another app

```swift
import CoreHaptics
import HapticVoiceKit

let engine = try CHHapticEngine()
engine.playsHapticsOnly = true
try engine.start()

let speech = try await SpeechSynthesisRenderer().render(text: "こんにちは")
let events = PulseVoice.events(samples: speech.samples, sampleRate: speech.sampleRate,
                               options: PulseVoiceOptions(pitchScale: 1))
let player = try engine.makePlayer(with: PulseVoice.pattern(events))
try player.start(atTime: CHHapticTimeImmediate)
```

### From an audio file

```swift
let events = try PulseVoice.events(audioFile: url)          // first options.maxDuration (default 3 s) only
// or: let audio = try AudioFileLoader.load(url: url, maxDuration: 60)
//     PulseVoice.events(samples: audio.samples, sampleRate: audio.sampleRate)
let player = try engine.makePlayer(with: PulseVoice.pattern(events))
```

`AudioFileLoader` decodes anything `AVAudioFile` reads (WAV, AIFF, CAF, M4A/AAC, MP3), mixes to mono
and only analyses the samples; nothing is played. This is **not a speaker**: the output is the same
pitch-rate click train, so a recorded voice keeps only its pitch (clamped 80–300 Hz) and rhythm.
Timbre, formants, music, chords and effects are not reproduced. Audio without a detectable pitch
(music, noise) mostly turns into consonant bursts. Not yet listened to on a device.

Add the package with Xcode → Add Package Dependencies → Add Local… (or by URL to this repository,
path `HapticVoiceKit`). iOS 17+.

## Practical notes and limits

- Keep each play ≤ 3 s and leave a cooldown between plays; the app enforces 3 s / 2 s.
- Placing the phone on a hard or hollow surface (wooden desk, box) is expected to make it louder;
  not measured yet.
- Core Haptics does not document a minimum transient spacing; at 300 Hz clicks are 3.3 ms apart
  and may merge on some devices. Measure before relying on a rate.
- Sharpness is not a frequency in Hz; the centroid→sharpness mapping is a choice, not a measurement.
- Formants (what distinguishes vowels) are not reproduced; expect pitch and rhythm only.

## How to verify (next steps)

Follow [EXPERIMENT_PROTOCOL.md](EXPERIMENT_PROTOCOL.md): record a silent baseline and each
pitch setting with `tools/acoustic_lab.py`, check that the dominant frequency follows the click
rate, then run ≥ 25 blind vowel trials per setting.
