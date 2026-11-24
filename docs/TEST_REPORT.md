# Test report

Environment: macOS 26.6.2, Xcode 26.6, iOS SDK 26.5, iPhone 17 Simulator (iOS 26.5).
Date: 2026-11-24 (JST).

## Automated tests — all passing
| Suite | Tests | Result |
|---|---|---|
| `HapticVoiceEngineTests` (unit) | 16 | pass |
| `HapticVoiceEngineUITests` (UI, simulated backend) | 6 | pass |

Unit tests cover: curve chunking (≤ 16 points, continuous), validation/clamping/3 s truncation,
the 25-cell matrix, every generated pattern (presets, AM rates, all four speech mappings)
being accepted by `CHHapticPattern`, AM curve cycle count, safety governor (cooldown, session
cap, thermal), controller refusal while busy / in cooldown and STOP result, feature extraction
on a synthetic 150 Hz vowel (F0 within ±5 Hz), silence detection, centroid normalisation,
mapping methods differing and labelled *(experimental)*, offline `AVSpeechSynthesizer.write`
producing PCM, language detection, blind-test accuracy / confusion / binomial p.

UI tests cover: real backend on the Simulator reports *Unsupported hardware* and disables
Play; simulated status / playback / STOP / cooldown refusal / physical confirmation;
preset finish + record; matrix cell; speech vowel (envelope mapping, no "reproduced" claim);
blind trial hides the target and records the answer.

## Device build
`scripts/build_unsigned_ipa.sh` → `HapticVoiceEngine-unsigned.ipa`, arm64, Release,
MinimumOSVersion 17.0, unsigned (to be signed by iloader).

## On-device result (owner, 2026-11-24)
- Installed with iloader and run on the owner's iPhone: **vibration is felt** (Level 1 reached).
- Speech experiments **do not sound like speech** to the owner (Level 5 not reached, informal
  listening, no blind protocol). This matches the expected limits in HARDWARE_LIMITATIONS.md.

## Not verified yet
- Microphone measurements against a silent baseline (Level 2) and the 5×5 matrix per material (Level 3).
- Blind vowel test with ≥ 25 trials (Level 4).
- Thermal behaviour during long sessions.

No hardware measurement has been performed; nothing in this repository reports one.

## Iteration 2: simple voice method (2026-11-24)
- Added Method 4 "Simple voice": transient clicks one pitch period apart in voiced parts (pitch ×1/×1.5/×2,
  clamped 80–300 Hz), short sharp bursts for consonants, nothing in silence. Default speech method.
- Simulator: 17 unit + 6 UI tests pass. Whether it sounds more voice-like needs the owner's listening on device.
- Owner, iPhone SE (3rd gen): Simple voice was heard as voice-like (informal listening; words, pitch
  setting and surface not recorded). Not yet backed by microphone measurements or blind trials.

## Iteration 3: reusable package
- Speech rendering, feature extraction and the Simple voice algorithm moved to the `HapticVoiceKit`
  Swift package used by the app. `swift test` in `HapticVoiceKit` runs 3 package tests on macOS.

## Iteration 4: audio file input
- `AudioFileLoader` / `PulseVoice.events(audioFile:)` in `HapticVoiceKit`. The app has "Choose audio file…" and "Play <file>"
  (first 3 s, same methods and safety limits, `playsHapticsOnly` unchanged).
- Simulator: 17 unit + 7 UI tests pass (a UI test loads a generated 150 Hz WAV through the real loader). `swift test`: 5 package tests.
- Not verified: how file playback sounds on a device; file formats other than WAV in tests.

## Iteration 5: longer audio file playback
- Owner, physical iPhone: install and song playback via the audio-file path worked, but stopped after 3 s.
- Audio-file playback length is now selectable 3 / 15 / 30 / 60 s (default 60 s). Other experiments keep the 3 s limit.
  STOP, cooldown, play/session caps, thermal, background and engine-error stops are unchanged; the watchdog follows the cap.
- Not verified on device: 60 s patterns (tens of thousands of transient events), heat over a full minute.
