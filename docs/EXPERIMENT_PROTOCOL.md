# Experiment protocol

Goal: test, without assuming success, whether Core Haptics vibration produces measurable
and recognisable sound. Run in a quiet room, phone not charging, short sessions
(≤ 20 min, the app enforces it), stop immediately if the phone gets warm or behaves oddly.

## Setup
- External microphone (USB/headset mic on the Linux PC), 10–20 cm from the phone, not touching it.
- Same mic position and gain for every trial; write them down.
- `python3 tools/acoustic_lab.py selftest` once to check the analysis.

## Level 1 — physical output
Play *Single pulse* and *Continuous* on the hand. Tap **Felt vibration** or **Nothing felt**
under the played pattern; audibility is judged by the microphone measurements below. Engine "Running" alone is not evidence.

## Level 2 — above background
1. `acoustic_lab.py record --id baseline --seconds 5` with the phone silent.
2. For each experiment, start `record --id <experiment ID shown in the app> --seconds 4`, then press Play.
3. `analyze <wav> --baseline recordings/baseline.wav --spectrogram`.
   `level2_detected_above_baseline` is true when active RMS ≥ baseline + 6 dB.

## Level 3 — characterization matrix
For each material (hand, wooden desk, cardboard box, hollow wooden box, metal, glass):
select the material, **Run 5×5 matrix** (25 × 1 s, cooldown between cells; ≈ 1.5 min) while
recording one continuous WAV. Analyse each cell (dominant Hz, harmonics, RMS, bandwidth) and
repeat 3× for `repeatability`. Report whether sharpness changes dominant/centroid frequency —
**sharpness is not assumed to be a frequency**.

## Level 4 — blind vowels
Only after Level 3 shows a usable contrast. A second person (listener) faces away, or the
operator uses the Blind test which hides the target. Choose mapping method and material,
run ≥ 25 trials (≥ 50 preferred), answer あ/い/う/え/お. The app reports accuracy, confusion
matrix and exact binomial p against 20 % chance. p < 0.05 with ≥ 25 trials = above chance.
Record whether the listener could feel the phone (tactile cues invalidate an *acoustic* claim:
put the phone on the material, listener not touching it).

## Level 5 — speech
Only claim if independent listeners, not told the word, transcribe Hello / AI / custom
phrases correctly. Level 4 alone does not imply Level 5.

## Closed-loop optimization (not implemented as automatic)
After Level 3 succeeds: pick one target (e.g. a vowel's F1/F2), vary one parameter at a time
within the safety limits, record and compare with `analyze --reference`, at most one bounded
session per run. No overnight / unattended loops.

## Recording results
Export `experiment_results.json` from the app (records, blind trials with targets, engine log; accuracy, confusion matrix and p-value are shown in the app and recomputable from `blindTrials`); keep it with `recordings/measurements.jsonl`
(joined by experiment ID and UTC time).
