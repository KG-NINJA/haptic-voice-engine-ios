import Foundation

/// A backend-neutral description of a haptic pattern. Only haptic event types exist here:
/// audio event types are deliberately unrepresentable so the speaker can never be driven.
struct HapticPatternSpec: Codable, Equatable {
    enum EventKind: String, Codable { case continuous, transient }

    struct Event: Codable, Equatable {
        var kind: EventKind
        var time: Double
        var duration: Double
        var intensity: Float
        var sharpness: Float
    }

    struct CurvePoint: Codable, Equatable {
        var time: Double
        var value: Float
    }

    struct Curve: Codable, Equatable {
        enum Parameter: String, Codable { case intensity, sharpness }
        var parameter: Parameter
        var startTime: Double
        var points: [CurvePoint]
    }

    var name: String
    var events: [Event] = []
    var curves: [Curve] = []

    var duration: Double {
        let eventEnd = events.map { $0.time + ($0.kind == .transient ? HapticLimits.transientNominalDuration : $0.duration) }.max() ?? 0
        let curveEnd = curves.map { c in c.startTime + (c.points.last?.time ?? 0) }.max() ?? 0
        return max(eventEnd, curveEnd)
    }
}

enum HapticLimits {
    static let maxPlaybackDuration: Double = 3.0
    static let minDuration: Double = 0.1
    static let transientNominalDuration: Double = 0.03
    /// Minimum spacing used between transient events we generate. Core Haptics does not document a
    /// hard limit; closer transients tend to merge, so this is a conservative choice, not a measured one.
    static let minTransientSpacing: Double = 0.02
    /// Core Haptics rejects parameter curves with more control points than this.
    static let maxPointsPerCurve = 16
    static let defaultCooldown: Double = 2.0
    static let maxPlaysPerSession = 300
    static let maxSessionLength: TimeInterval = 20 * 60

    static func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
    static func clampDuration(_ d: Double) -> Double { min(max(d, minDuration), maxPlaybackDuration) }
}

extension HapticPatternSpec {
    /// Splits a dense list of absolute-time points into several curves that each respect
    /// `HapticLimits.maxPointsPerCurve`. Consecutive curves share their boundary point so that
    /// interpolation is continuous.
    static func chunkedCurves(parameter: Curve.Parameter, points: [CurvePoint]) -> [Curve] {
        guard !points.isEmpty else { return [] }
        let size = HapticLimits.maxPointsPerCurve
        var curves: [Curve] = []
        var index = 0
        while index < points.count {
            let end = min(index + size, points.count)
            let slice = Array(points[index..<end])
            let start = slice[0].time
            curves.append(Curve(parameter: parameter, startTime: start,
                                points: slice.map { CurvePoint(time: $0.time - start, value: $0.value) }))
            if end == points.count { break }
            index = end - 1
        }
        return curves
    }

    /// Returns a copy with all values clamped to the documented ranges and the pattern
    /// truncated to the safety limit. `warnings` lists what had to change.
    func validated() -> (HapticPatternSpec, [String]) {
        var warnings: [String] = []
        var copy = self
        let limit = HapticLimits.maxPlaybackDuration
        copy.events = events.compactMap { e in
            guard e.time < limit else { return nil }
            var e = e
            if e.intensity < 0 || e.intensity > 1 || e.sharpness < 0 || e.sharpness > 1 {
                warnings.append("event parameter clamped to 0...1")
            }
            e.intensity = HapticLimits.clamp01(e.intensity)
            e.sharpness = HapticLimits.clamp01(e.sharpness)
            if e.kind == .continuous && e.time + e.duration > limit {
                e.duration = limit - e.time
                warnings.append("continuous event truncated to \(limit)s limit")
            }
            return e
        }
        if copy.events.count < events.count { warnings.append("events after \(limit)s dropped") }
        copy.curves = curves.compactMap { c in
            guard c.startTime < limit else { return nil }
            var c = c
            c.points = c.points.filter { c.startTime + $0.time <= limit }.map {
                CurvePoint(time: $0.time, value: HapticLimits.clamp01($0.value))
            }
            if c.points.count > HapticLimits.maxPointsPerCurve {
                warnings.append("curve truncated to \(HapticLimits.maxPointsPerCurve) points")
                c.points = Array(c.points.prefix(HapticLimits.maxPointsPerCurve))
            }
            return c.points.isEmpty ? nil : c
        }
        return (copy, Array(Set(warnings)).sorted())
    }
}
