# Test report

Environment: macOS 26.6.2, Xcode 26.6, iOS SDK 26.5, iPhone 17 Simulator (iOS 26.5).
Date: 2026-11-24 (JST).

## Automated tests — all passing
| Suite | Tests | Result |
|---|---|---|
| `HapticVoiceEngineTests` (unit) | 16 | pass |
| `HapticVoiceEngineUITests` (UI, simulated backend) | 6 | pass |

Unit tests cover: curve chunking (≤ 16 points, continuous), validation/clamping/3 s truncation,
the 25-cell matrix, every generated pattern (presets, AM rates, all three speech mappings)
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
