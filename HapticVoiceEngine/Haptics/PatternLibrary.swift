import Foundation

enum ModulationRate: Double, CaseIterable, Identifiable, Codable {
    case none = 0, hz2 = 2, hz5 = 5, hz10 = 10, hz20 = 20, hz40 = 40

    var id: Double { rawValue }
    var label: String { self == .none ? "None" : "\(Int(rawValue)) Hz" }
}

/// Builds the manual and preset experiment patterns. Requested values are stored with each
/// result; nothing here assumes the hardware reproduces a requested rate or "frequency".
enum PatternLibrary {
    enum Preset: String, CaseIterable, Identifiable, Codable {
        case singlePulse = "Single pulse"
        case continuous = "Continuous vibration"
        case intensitySweep = "Intensity sweep"
        case sharpnessSweep = "Sharpness sweep"
        case amplitudeModulation = "Amplitude modulation"
        case rhythmicPulses = "Rhythmic pulse sequence"
        var id: String { rawValue }
    }

    static func manual(intensity: Float, sharpness: Float, duration: Double, modulation: ModulationRate) -> HapticPatternSpec {
        let d = HapticLimits.clampDuration(duration)
        var spec = HapticPatternSpec(name: "Manual I=\(fmt(intensity)) S=\(fmt(sharpness)) D=\(fmt(d))s M=\(modulation.label)")
        spec.events = [.init(kind: .continuous, time: 0, duration: d, intensity: intensity, sharpness: sharpness)]
        if modulation != .none {
            spec.curves = amCurve(rate: modulation.rawValue, duration: d)
        }
        return spec
    }

    static func preset(_ preset: Preset, intensity: Float = 1.0, sharpness: Float = 0.5, rate: ModulationRate = .hz5) -> HapticPatternSpec {
        var spec = HapticPatternSpec(name: preset.rawValue)
        switch preset {
        case .singlePulse:
            spec.events = [.init(kind: .transient, time: 0, duration: 0, intensity: intensity, sharpness: sharpness)]
        case .continuous:
            spec.events = [.init(kind: .continuous, time: 0, duration: 1.0, intensity: intensity, sharpness: sharpness)]
        case .intensitySweep:
            spec.events = [.init(kind: .continuous, time: 0, duration: 2.0, intensity: 1.0, sharpness: sharpness)]
            spec.curves = HapticPatternSpec.chunkedCurves(parameter: .intensity, points: ramp(duration: 2.0, from: 0.05, to: 1.0, steps: 20))
        case .sharpnessSweep:
            spec.events = [.init(kind: .continuous, time: 0, duration: 2.0, intensity: intensity, sharpness: 0)]
            spec.curves = HapticPatternSpec.chunkedCurves(parameter: .sharpness, points: ramp(duration: 2.0, from: 0, to: 1.0, steps: 20))
        case .amplitudeModulation:
            let r = rate == .none ? 5 : rate.rawValue
            spec.name = "Amplitude modulation \(Int(r)) Hz (requested)"
            spec.events = [.init(kind: .continuous, time: 0, duration: 2.0, intensity: intensity, sharpness: sharpness)]
            spec.curves = amCurve(rate: r, duration: 2.0)
        case .rhythmicPulses:
            let times: [Double] = [0, 0.25, 0.5, 1.0, 1.125, 1.25, 1.5, 2.0]
            spec.events = times.map { .init(kind: .transient, time: $0, duration: 0, intensity: intensity, sharpness: sharpness) }
        }
        return spec
    }

    struct MatrixCell: Identifiable, Hashable, Codable {
        var intensity: Float
        var sharpness: Float
        var id: String { "I\(fmt(intensity))-S\(fmt(sharpness))" }
    }

    static let matrixIntensities: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0]
    static let matrixSharpness: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
    static let matrixDuration = 1.0

    static var matrix: [MatrixCell] {
        matrixIntensities.flatMap { i in matrixSharpness.map { MatrixCell(intensity: i, sharpness: $0) } }
    }

    static func matrixPattern(_ cell: MatrixCell) -> HapticPatternSpec {
        var spec = HapticPatternSpec(name: "Matrix \(cell.id)")
        spec.events = [.init(kind: .continuous, time: 0, duration: matrixDuration, intensity: cell.intensity, sharpness: cell.sharpness)]
        return spec
    }

    /// Square-ish amplitude modulation via intensity control curve, 4 control points per period.
    /// At high rates the curve interpolation and actuator response may smooth it out; the requested
    /// rate is recorded, the reproduced rate must be measured.
    static func amCurve(rate: Double, duration: Double) -> [HapticPatternSpec.Curve] {
        guard rate > 0 else { return [] }
        let period = 1.0 / rate
        var points: [HapticPatternSpec.CurvePoint] = []
        let cycles = Int((duration * rate - 1e-9).rounded(.up))
        for k in 0..<cycles {
            let t = Double(k) * period
            points.append(.init(time: t, value: 1.0))
            points.append(.init(time: min(t + period * 0.45, duration), value: 1.0))
            points.append(.init(time: min(t + period * 0.5, duration), value: 0.0))
            points.append(.init(time: min(t + period * 0.95, duration), value: 0.0))
        }
        return HapticPatternSpec.chunkedCurves(parameter: .intensity, points: points)
    }

    static func ramp(duration: Double, from: Float, to: Float, steps: Int) -> [HapticPatternSpec.CurvePoint] {
        (0...steps).map { i in
            let f = Double(i) / Double(steps)
            return .init(time: duration * f, value: from + (to - from) * Float(f))
        }
    }

    static func fmt(_ v: Float) -> String { String(format: "%.2f", v) }
    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
