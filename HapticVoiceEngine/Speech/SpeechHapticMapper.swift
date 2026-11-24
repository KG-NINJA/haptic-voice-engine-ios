import Foundation
import HapticVoiceKit

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
            var options = PulseVoiceOptions(pitchScale: pitchScale)
            options.maxDuration = duration
            let voice = PulseVoice.events(from: f, options: options)
            spec.events = voice.map {
                .init(kind: $0.kind == .click ? .transient : .continuous, time: $0.time, duration: $0.duration,
                      intensity: $0.intensity, sharpness: $0.sharpness)
            }
            let clicks = voice.filter { $0.kind == .click }.count
            notes.append(String(format: "%d pitch clicks, %d consonant bursts, pitch ×%.1f clamped to %.0f–%.0f Hz",
                                clicks, voice.count - clicks, pitchScale, options.minPitch, options.maxPitch))
            notes.append("click rate is requested; whether the actuator reproduces it must be measured")
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

    static let pitchScales: [Double] = [1, 1.5, 2]

    static func normalizedCentroid(_ hz: Float) -> Float { PulseVoice.normalizedCentroid(hz) }

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
