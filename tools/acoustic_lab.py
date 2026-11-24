#!/usr/bin/env python3
"""Haptic Voice Engine acoustic measurement utility (runs on the Omarchy Linux PC).

Records the external microphone, exports WAV, and analyses vibration-generated sound:
FFT, dominant frequency, harmonics, RMS, spectral bandwidth, background comparison,
reference comparison, spectrogram and repeatability across trials.

Only numpy is required. Recording uses `pw-record` (PipeWire) or `arecord` (ALSA);
spectrogram PNGs need matplotlib. Results are appended to a JSONL file keyed by
experiment ID and UTC timestamp so they can be joined with the app's
experiment_results.json.

Examples:
  python3 acoustic_lab.py record --id baseline --seconds 5
  python3 acoustic_lab.py record --id HVE-20261124-101500-0003 --seconds 3
  python3 acoustic_lab.py analyze recordings/HVE-...wav --baseline recordings/baseline.wav --spectrogram
  python3 acoustic_lab.py compare recordings/a.wav recordings/b.wav
  python3 acoustic_lab.py repeatability recordings/trial1.wav recordings/trial2.wav recordings/trial3.wav
  python3 acoustic_lab.py selftest
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

DEFAULT_RATE = 48000
RESULTS = Path("recordings/measurements.jsonl")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


# ---------- I/O ----------

def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        rate, ch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    if width == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif width == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
    elif width == 1:
        x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128) / 128.0
    else:
        raise ValueError(f"unsupported sample width {width}")
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, rate


def write_wav(path: Path, x: np.ndarray, rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())


def record(path: Path, seconds: float, rate: int, device: str | None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if shutil.which("pw-record"):
        cmd = ["pw-record", "--rate", str(rate), "--channels", "1", "--format", "s16"]
        if device:
            cmd += ["--target", device]
        cmd.append(str(path))
        proc = subprocess.Popen(cmd)
        try:
            proc.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=5)
    elif shutil.which("arecord"):
        cmd = ["arecord", "-q", "-f", "S16_LE", "-c", "1", "-r", str(rate), "-d", str(int(round(seconds)))]
        if device:
            cmd += ["-D", device]
        subprocess.run(cmd + [str(path)], check=True)
    else:
        sys.exit("Neither pw-record nor arecord found; install pipewire or alsa-utils.")


# ---------- analysis ----------

def rms_db(x: np.ndarray) -> float:
    r = float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0
    return 20 * np.log10(max(r, 1e-12))


def spectrum(x: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    """Welch-averaged power spectrum (Hann, 8192-point segments, 50% overlap)."""
    n = 8192 if len(x) >= 8192 else 1 << max(8, int(np.log2(max(len(x), 256))))
    if len(x) < n:
        x = np.pad(x, (0, n - len(x)))
    win = np.hanning(n)
    hop = n // 2
    segs = [x[i:i + n] * win for i in range(0, len(x) - n + 1, hop)]
    p = np.mean([np.abs(np.fft.rfft(s)) ** 2 for s in segs], axis=0)
    return np.fft.rfftfreq(n, 1 / rate), p


def active_region(x: np.ndarray, rate: int, baseline_db: float | None) -> np.ndarray:
    """Samples whose 20 ms RMS exceeds baseline + 6 dB (or the quietest decile + 6 dB)."""
    frame = max(1, int(0.02 * rate))
    frames = [x[i:i + frame] for i in range(0, len(x) - frame + 1, frame)]
    if not frames:
        return x
    levels = np.array([rms_db(f) for f in frames])
    floor = baseline_db if baseline_db is not None else float(np.percentile(levels, 10))
    keep = levels > floor + 6
    if not keep.any():
        return x
    return np.concatenate([f for f, k in zip(frames, keep) if k])


def features(x: np.ndarray, rate: int, fmin: float = 20, fmax: float = 8000, baseline: np.ndarray | None = None) -> dict:
    f, p = spectrum(x, rate)
    band = (f >= fmin) & (f <= min(fmax, rate / 2))
    pb, fb = p[band], f[band]
    if baseline is not None:
        bf, bp = spectrum(baseline, rate)
        bp_i = np.interp(fb, bf, bp)
        excess = np.clip(pb - bp_i, 0, None)
    else:
        bp_i = None
        excess = pb
    total = float(excess.sum()) or 1e-30
    k = int(np.argmax(excess))
    dom = float(fb[k])
    centroid = float((fb * excess).sum() / total)
    bandwidth = float(np.sqrt(((fb - centroid) ** 2 * excess).sum() / total))
    harmonics = []
    for h in range(2, 7):
        target = dom * h
        if target > fb[-1]:
            break
        win = np.abs(fb - target) <= max(5.0, 0.03 * target)
        if win.any():
            j = np.argmax(np.where(win, pb, 0))
            harmonics.append({"n": h, "hz": round(float(fb[j]), 1),
                              "rel_db": round(10 * np.log10(max(pb[j], 1e-30) / max(pb[k], 1e-30)), 1)})
    top = np.argsort(excess)[::-1]
    peaks: list[float] = []
    for j in top:
        if len(peaks) >= 5:
            break
        if all(abs(fb[j] - q) > 15 for q in peaks):
            peaks.append(float(fb[j]))
    out = {
        "duration_s": round(len(x) / rate, 3),
        "rms_dbfs": round(rms_db(x), 2),
        "dominant_hz": round(dom, 1),
        "spectral_centroid_hz": round(centroid, 1),
        "spectral_bandwidth_hz": round(bandwidth, 1),
        "top_peaks_hz": [round(q, 1) for q in peaks],
        "harmonics": harmonics,
    }
    if bp_i is not None:
        out["peak_snr_db"] = round(10 * np.log10(max(pb[k], 1e-30) / max(bp_i[k], 1e-30)), 1)
    return out


def envelope(x: np.ndarray, rate: int, hop_s: float = 0.01) -> np.ndarray:
    hop = max(1, int(hop_s * rate))
    return np.array([np.sqrt(np.mean(x[i:i + hop] ** 2)) for i in range(0, len(x) - hop + 1, hop)])


def log_spectrum(x: np.ndarray, rate: int, fmax: float = 8000) -> tuple[np.ndarray, np.ndarray]:
    f, p = spectrum(x, rate)
    band = f <= fmax
    return f[band], 10 * np.log10(p[band] + 1e-20)


def compare(a: np.ndarray, ra: int, b: np.ndarray, rb: int) -> dict:
    if ra != rb:
        b = np.interp(np.arange(0, len(b) * ra / rb) * rb / ra, np.arange(len(b)), b)
    fa, la = log_spectrum(a, ra)
    _, lb = log_spectrum(b, ra)
    m = min(len(la), len(lb))
    spec_corr = float(np.corrcoef(la[:m], lb[:m])[0, 1])
    ea, eb = envelope(a, ra), envelope(b, ra)
    n = min(len(ea), len(eb))
    env_corr = float(np.corrcoef(ea[:n], eb[:n])[0, 1]) if n > 2 and ea[:n].std() > 0 and eb[:n].std() > 0 else float("nan")
    xc = np.correlate((ea - ea.mean()), (eb - eb.mean()), mode="full")
    lag = (int(np.argmax(xc)) - (len(eb) - 1)) * 0.01
    return {"log_spectrum_correlation": round(spec_corr, 3), "envelope_correlation": round(env_corr, 3),
            "best_envelope_lag_s": round(lag, 3)}


def save_spectrogram(x: np.ndarray, rate: int, out: Path, title: str) -> Path | None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed; skipping spectrogram", file=sys.stderr)
        return None
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.specgram(x, NFFT=2048, Fs=rate, noverlap=1536, cmap="magma")
    ax.set_ylim(0, 4000)
    ax.set_xlabel("time (s)")
    ax.set_ylabel("Hz")
    ax.set_title(title)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)
    return out


def append_result(entry: dict, path: Path = RESULTS) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


# ---------- commands ----------

def cmd_record(a):
    out = Path(a.out or f"recordings/{a.id}.wav")
    started = utc_now()
    print(f"recording {a.seconds}s -> {out} (start {started}); keep the mic off the phone")
    record(out, a.seconds, a.rate, a.device)
    entry = {"type": "recording", "experiment_id": a.id, "file": str(out), "started_utc": started,
             "ended_utc": utc_now(), "material": a.material, "note": a.note}
    append_result(entry)
    print(json.dumps(entry, ensure_ascii=False))


def cmd_analyze(a):
    x, rate = read_wav(Path(a.wav))
    base = None
    result: dict = {"type": "analysis", "file": a.wav, "analyzed_utc": utc_now(), "experiment_id": a.id or Path(a.wav).stem}
    if a.baseline:
        base, br = read_wav(Path(a.baseline))
        if br != rate:
            sys.exit("baseline sample rate differs")
        result["baseline_file"] = a.baseline
        result["baseline_rms_dbfs"] = round(rms_db(base), 2)
    seg = active_region(x, rate, result.get("baseline_rms_dbfs"))
    result["whole"] = features(x, rate, baseline=base)
    result["active"] = features(seg, rate, baseline=base)
    if base is not None:
        result["rms_above_baseline_db"] = round(rms_db(seg) - rms_db(base), 2)
        result["level2_detected_above_baseline"] = bool(result["rms_above_baseline_db"] >= 6.0)
    if a.reference:
        r, rr = read_wav(Path(a.reference))
        result["reference_file"] = a.reference
        result["reference_comparison"] = compare(seg, rate, r, rr)
    if a.spectrogram:
        png = save_spectrogram(x, rate, Path(a.wav).with_suffix(".png"), result["experiment_id"])
        if png:
            result["spectrogram"] = str(png)
    append_result(result)
    print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_compare(a):
    x, rx = read_wav(Path(a.a))
    y, ry = read_wav(Path(a.b))
    print(json.dumps(compare(x, rx, y, ry), indent=2))


def cmd_repeatability(a):
    feats = []
    for p in a.wavs:
        x, rate = read_wav(Path(p))
        feats.append(features(active_region(x, rate, None), rate))
    def stats(key):
        v = np.array([f[key] for f in feats], dtype=float)
        return {"mean": round(float(v.mean()), 2), "std": round(float(v.std(ddof=1)) if len(v) > 1 else 0.0, 2),
                "cv": round(float(v.std(ddof=1) / v.mean()) if len(v) > 1 and v.mean() else 0.0, 3)}
    out = {"type": "repeatability", "files": a.wavs, "n": len(feats),
           "dominant_hz": stats("dominant_hz"), "rms_dbfs": stats("rms_dbfs"),
           "spectral_centroid_hz": stats("spectral_centroid_hz"), "spectral_bandwidth_hz": stats("spectral_bandwidth_hz")}
    append_result(out)
    print(json.dumps(out, indent=2))


def cmd_selftest(_a):
    """Checks the analysis on synthetic signals; no microphone needed."""
    rate = 48000
    t = np.arange(int(rate * 1.0)) / rate
    rng = np.random.default_rng(0)
    noise = 0.001 * rng.standard_normal(len(t))
    tone = 0.2 * np.sin(2 * np.pi * 230 * t) + 0.05 * np.sin(2 * np.pi * 460 * t) + noise
    f = features(tone, rate, baseline=noise)
    assert abs(f["dominant_hz"] - 230) < 6, f
    assert any(abs(h["hz"] - 460) < 10 for h in f["harmonics"]), f
    assert f["peak_snr_db"] > 30, f
    assert rms_db(tone) - rms_db(noise) > 40
    c = compare(tone, rate, tone, rate)
    assert c["log_spectrum_correlation"] > 0.99, c
    c2 = compare(tone, rate, noise, rate)
    assert c2["log_spectrum_correlation"] < c["log_spectrum_correlation"], c2
    tmp = Path("recordings/_selftest.wav")
    write_wav(tmp, tone, rate)
    y, r = read_wav(tmp)
    assert r == rate and abs(len(y) - len(tone)) == 0
    tmp.unlink()
    print("selftest OK", json.dumps(f))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record", help="record the microphone to WAV")
    r.add_argument("--id", required=True, help="experiment ID shown in the app (or 'baseline')")
    r.add_argument("--seconds", type=float, default=3.0)
    r.add_argument("--rate", type=int, default=DEFAULT_RATE)
    r.add_argument("--device", help="PipeWire target / ALSA device")
    r.add_argument("--material", default="")
    r.add_argument("--note", default="")
    r.add_argument("--out")
    r.set_defaults(func=cmd_record)
    an = sub.add_parser("analyze", help="FFT / dominant frequency / RMS / bandwidth / harmonics")
    an.add_argument("wav")
    an.add_argument("--id")
    an.add_argument("--baseline", help="no-vibration recording made with the same setup")
    an.add_argument("--reference", help="reference waveform (e.g. offline TTS WAV) to compare against")
    an.add_argument("--spectrogram", action="store_true")
    an.set_defaults(func=cmd_analyze)
    c = sub.add_parser("compare", help="compare two recordings")
    c.add_argument("a")
    c.add_argument("b")
    c.set_defaults(func=cmd_compare)
    rp = sub.add_parser("repeatability", help="variation of features across repeated trials")
    rp.add_argument("wavs", nargs="+")
    rp.set_defaults(func=cmd_repeatability)
    s = sub.add_parser("selftest", help="verify analysis on synthetic signals")
    s.set_defaults(func=cmd_selftest)
    a = p.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
