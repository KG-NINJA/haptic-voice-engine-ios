import Foundation
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// Tuning for `PulseVoice`. Defaults are the values used in the Haptic Voice Engine app.
public struct PulseVoiceOptions: Equatable, Codable {
    /// Multiplies the voice's pitch before clamping (the app offers ×1, ×1.5, ×2).
    public var pitchScale: Double = 1
    /// Click rate is clamped to this range (Hz).
    public var minPitch: Double = 80
    public var maxPitch: Double = 300
    /// Pitch used before the first voiced frame when the voice's mean pitch is unknown.
    public var fallbackPitch: Double = 120
    /// Frames whose normalized envelope is at or below this are silent.
    public var gate: Float = 0.15
    /// Output stops at this time (s). Keep it short: the app caps a play at 3 s.
    public var maxDuration: Double = 3.0
    public var consonantIntensity: Float = 0.6
    public var consonantSharpness: Float = 1.0
    public var minConsonantBurst: Double = 0.03

    public init(pitchScale: Double = 1) { self.pitchScale = pitchScale }
}

/// One haptic event. `click` maps to a Core Haptics transient, `burst` to a continuous event.
public struct PulseVoiceEvent: Equatable, Codable {
    public enum Kind: String, Codable { case click, burst }
    public var kind: Kind
    public var time: Double
    public var duration: Double
    public var intensity: Float
    public var sharpness: Float
}

/// "Simple voice": voiced frames become transient clicks one pitch period apart, unvoiced
/// (consonant) frames become short sharp continuous bursts, silence stays silent.
/// A click train at the voice's pitch is the simplest pattern that makes the actuator buzz at a
/// speech-like pitch with speech-like rhythm. It does not reproduce formants.
public enum PulseVoice {
    public static let centroidRange: (Float, Float) = (200, 5000)

    public static func events(samples: [Float], sampleRate: Double, options: PulseVoiceOptions = .init()) -> [PulseVoiceEvent] {
        events(from: SpeechFeatureExtractor.extract(samples: samples, sampleRate: sampleRate), options: options)
    }

    public static func events(from f: SpeechFeatures, options o: PulseVoiceOptions = .init()) -> [PulseVoiceEvent] {
        let duration = min(f.duration, o.maxDuration)
        var events: [PulseVoiceEvent] = []
        var lastPitch = f.summary.meanF0 ?? o.fallbackPitch
        var nextPulse = 0.0
        var burstStart: Double?
        let hop = max(f.hop, 1e-6)

        func closeBurst(at t: Double) {
            guard let start = burstStart else { return }
            burstStart = nil
            let d = min(max(o.minConsonantBurst, t - start), duration - start)
            guard d > 0 else { return }
            events.append(.init(kind: .burst, time: start, duration: d, intensity: o.consonantIntensity, sharpness: o.consonantSharpness))
        }

        for i in f.times.indices where f.times[i] < duration {
            let t = f.times[i]
            let active = f.envelope[i] > o.gate
            if active && !f.voiced[i] {
                if burstStart == nil { burstStart = t }
                continue
            }
            closeBurst(at: t)
            guard active else { continue }
            if f.f0[i] > 0 { lastPitch = Double(f.f0[i]) }
            let period = 1 / min(max(lastPitch * o.pitchScale, o.minPitch), o.maxPitch)
            nextPulse = max(nextPulse, t)
            let intensity = 0.4 + 0.6 * f.envelope[i]
            let sharpness = 0.2 + 0.6 * normalizedCentroid(f.centroid[i])
            while nextPulse < min(t + hop, duration) {
                events.append(.init(kind: .click, time: nextPulse, duration: 0, intensity: intensity, sharpness: sharpness))
                nextPulse += period
            }
        }
        closeBurst(at: min(f.times.last.map { $0 + hop } ?? duration, duration))
        return events
    }

    /// Log-scaled spectral centroid in 0...1 (200 Hz → 0, 5 kHz → 1). An experimental mapping to
    /// haptic sharpness, not a physical frequency.
    public static func normalizedCentroid(_ hz: Float) -> Float {
        guard hz > 0 else { return 0 }
        let (lo, hi) = centroidRange
        return min(max((log(max(hz, lo)) - log(lo)) / (log(hi) - log(lo)), 0), 1)
    }

    #if canImport(CoreHaptics)
    /// Builds a haptic-only pattern (transient + continuous events, no audio events).
    /// Play it on a `CHHapticEngine` with `playsHapticsOnly = true`.
    public static func pattern(_ events: [PulseVoiceEvent]) throws -> CHHapticPattern {
        let hapticEvents = events.map { e in
            CHHapticEvent(eventType: e.kind == .click ? .hapticTransient : .hapticContinuous,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: e.intensity),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: e.sharpness)],
                          relativeTime: e.time, duration: e.duration)
        }
        return try CHHapticPattern(events: hapticEvents, parameters: [])
    }
    #endif
}
