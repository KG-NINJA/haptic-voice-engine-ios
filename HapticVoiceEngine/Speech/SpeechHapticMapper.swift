import Foundation

enum SpeechMappingMethod: String, CaseIterable, Identifiable, Codable {
    case pulseVoice = "Method 4: Simple voice (pitch pulse train)"
    case envelope = "Method 1: Envelope mapping"
    case spectral = "Method 2: Spectral mapping"
    case combined = "Method 3: Combined modulation"

    var id: String { rawValue }
    var short: String {
        switch self {
        case .pulseVoice: return "Simple voice"
        case .envelope: return "Envelope"
        case .spectral: return "Spectral"
        case .combined: return "Combined"
        }
    }

    var explanation: String {
        switch self {
        case .pulseVoice: return "Simplified: voiced parts become clicks at the voice's pitch (×1/×1.5/×2, 80–300 Hz) so the actuator buzzes at that pitch; consonants become short sharp bursts; silence is silent. Experimental, not speech reproduction."
        case .envelope: return "Speech RMS envelope → haptic intensity curve. Sharpness fixed at 0.5."
        case .spectral: return "Normalized log spectral centroid → sharpness curve (an experimental mapping, not frequency reproduction). Intensity gated by speech activity."
        case .combined: return "Envelope → intensity, centroid → sharpness, 25 Hz requested intensity modulation in voiced frames, transients at onsets/phoneme markers."
        }
    }
}

/// Converts extracted speech features to haptic patterns. Outputs are experimental vibration
/// patterns; they are never labelled as reproduced speech.
enum SpeechHapticMapper {
    /// Control-point rate for parameter curves (one point every 20 ms).
    static let controlInterval = 0.02
    static let centroidRange: (Float, Float) = (200, 5000)

    struct Result {
        var spec: HapticPatternSpec
        var notes: [String]
    }

    static func map(_ f: SpeechFeatures, method: SpeechMappingMethod, label: String, markers: [SynthesizedSpeech.Marker] = [], pitchScale: Double = 1) -> Result {
        var notes: [String] = []
        var duration = f.duration
        if duration > HapticLimits.maxPlaybackDuration {
            notes.append(String(format: "speech is %.2fs; truncated to %.1fs safety limit", duration, HapticLimits.maxPlaybackDuration))
            duration = HapticLimits.maxPlaybackDuration
        }
        duration = max(duration, HapticLimits.minDuration)
        let step = max(1, Int((controlInterval / max(f.hop, 1e-6)).rounded()))
        let idx = Array(stride(from: 0, to: f.times.count, by: step)).filter { f.times[$0] <= duration }

        var spec = HapticPatternSpec(name: "\(label) · \(method.short) (experimental)")
        let envPoints = idx.map { HapticPatternSpec.CurvePoint(time: f.times[$0], value: f.envelope[$0]) }
        let sharpPoints = idx.map { HapticPatternSpec.CurvePoint(time: f.times[$0], value: normalizedCentroid(f.centroid[$0])) }

        switch method {
        case .pulseVoice:
            let voice = pulseVoice(f, duration: duration, pitchScale: pitchScale)
            spec.events = voice.events
            notes += voice.notes
        case .envelope:
            spec.events = [.init(kind: .continuous, time: 0, duration: duration, intensity: 1, sharpness: 0.5)]
            spec.curves = HapticPatternSpec.chunkedCurves(parameter: .intensity, points: envPoints)
        case .spectral:
            spec.events = [.init(kind: .continuous, time: 0, duration: duration, intensity: 1, sharpness: 0.5)]
            let gate = idx.map { HapticPatternSpec.CurvePoint(time: f.times[$0], value: f.envelope[$0] > 0.1 ? 0.8 : 0) }
            spec.curves = HapticPatternSpec.chunkedCurves(parameter: .intensity, points: gate)
                + HapticPatternSpec.chunkedCurves(parameter: .sharpness, points: sharpPoints)
        case .combined:
            spec.events = [.init(kind: .continuous, time: 0, duration: duration, intensity: 1, sharpness: 0.5)]
            let modulated = idx.enumerated().map { n, i -> HapticPatternSpec.CurvePoint in
                let depth: Float = f.voiced[i] ? (n % 2 == 0 ? 1.0 : 0.4) : 1.0
                return .init(time: f.times[i], value: f.envelope[i] * depth)
            }
            let sharp = idx.map { i in HapticPatternSpec.CurvePoint(time: f.times[i], value: f.voiced[i] ? normalizedCentroid(f.centroid[i]) : 1.0) }
            spec.curves = HapticPatternSpec.chunkedCurves(parameter: .intensity, points: modulated)
                + HapticPatternSpec.chunkedCurves(parameter: .sharpness, points: sharp)
            let phonemes = markers.filter { $0.type == "phoneme" }.map(\.time).filter { $0 < duration }
            let onsetTimes = phonemes.isEmpty ? onsets(f).filter { $0 < duration } : phonemes
            notes.append(phonemes.isEmpty ? "transients at \(onsetTimes.count) envelope onsets" : "transients at \(phonemes.count) phoneme markers")
            spec.events += spaced(onsetTimes).map { t in
                let i = min(f.times.count - 1, max(0, Int(t / max(f.hop, 1e-6))))
                return .init(kind: .transient, time: t, duration: 0, intensity: max(0.3, f.envelope.isEmpty ? 1 : f.envelope[i]),
                             sharpness: f.centroid.isEmpty ? 0.5 : normalizedCentroid(f.centroid[i]))
            }
            notes.append("25 Hz modulation is requested via curve points; the actuator may not reproduce it")
        }
        return Result(spec: spec, notes: notes)
    }

    static let pulsePitchRange: (Double, Double) = (80, 300)
    static let pitchScales: [Double] = [1, 1.5, 2]
    static let fallbackPitch: Double = 120

    /// Voiced frames → transient clicks one pitch period apart, consonant frames → short sharp
    /// continuous bursts, silence → nothing. Click trains at the voice pitch are the simplest
    /// pattern that can make the actuator buzz at a speech-like pitch with speech-like rhythm.
    static func pulseVoice(_ f: SpeechFeatures, duration: Double, pitchScale: Double = 1, gate: Float = 0.15) -> (events: [HapticPatternSpec.Event], notes: [String]) {
        var events: [HapticPatternSpec.Event] = []
        var lastPitch = f.summary.meanF0 ?? fallbackPitch
        var nextPulse = 0.0
        var burstStart: Double?
        let hop = max(f.hop, 1e-6)
        let (lo, hi) = pulsePitchRange

        func closeBurst(at t: Double) {
            guard let start = burstStart else { return }
            burstStart = nil
            let d = max(0.03, t - start)
            events.append(.init(kind: .continuous, time: start, duration: min(d, duration - start), intensity: 0.6, sharpness: 1.0))
        }

        for i in f.times.indices where f.times[i] < duration {
            let t = f.times[i]
            let active = f.envelope[i] > gate
            if active && !f.voiced[i] {
                if burstStart == nil { burstStart = t }
                continue
            }
            closeBurst(at: t)
            guard active else { continue }
            if f.f0[i] > 0 { lastPitch = Double(f.f0[i]) }
            let period = 1 / min(max(lastPitch * pitchScale, lo), hi)
            nextPulse = max(nextPulse, t)
            let intensity = 0.4 + 0.6 * f.envelope[i]
            let sharpness = 0.2 + 0.6 * normalizedCentroid(f.centroid[i])
            while nextPulse < min(t + hop, duration) {
                events.append(.init(kind: .transient, time: nextPulse, duration: 0, intensity: intensity, sharpness: sharpness))
                nextPulse += period
            }
        }
        closeBurst(at: min(f.times.last.map { $0 + hop } ?? duration, duration))
        let pulses = events.filter { $0.kind == .transient }.count
        let notes = [
            String(format: "%d pitch clicks, %d consonant bursts, pitch ×%.1f clamped to %.0f–%.0f Hz", pulses, events.count - pulses, pitchScale, lo, hi),
            "click rate is requested; whether the actuator reproduces it must be measured",
        ]
        return (events, notes)
    }

    static func normalizedCentroid(_ hz: Float) -> Float {
        guard hz > 0 else { return 0 }
        let (lo, hi) = centroidRange
        return HapticLimits.clamp01((log(max(hz, lo)) - log(lo)) / (log(hi) - log(lo)))
    }

    /// Times where the smoothed envelope rises by more than `threshold` within one frame.
    static func onsets(_ f: SpeechFeatures, threshold: Float = 0.08) -> [Double] {
        guard f.envelope.count > 1 else { return f.times.first.map { [$0] } ?? [] }
        var result: [Double] = []
        for i in 1..<f.envelope.count where f.envelope[i] - f.envelope[i - 1] > threshold {
            result.append(f.times[i])
        }
        return result.isEmpty ? [0] : result
    }

    static func spaced(_ times: [Double], minSpacing: Double = 0.06) -> [Double] {
        var out: [Double] = []
        for t in times.sorted() where (out.last.map { t - $0 >= max(minSpacing, HapticLimits.minTransientSpacing) } ?? true) {
            out.append(t)
        }
        return out
    }
}
