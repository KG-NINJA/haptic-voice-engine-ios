import CoreHaptics
import Foundation

struct HapticCapabilities: Equatable {
    var supportsHaptics: Bool
    var supportsAudio: Bool
    var simulated: Bool
}

enum BackendEvent {
    case stopped(reason: String)
    case reset
    case playerFinished(error: String?)
}

protocol HapticBackend: AnyObject {
    var capabilities: HapticCapabilities { get }
    var playsHapticsOnly: Bool { get }
    var eventHandler: ((BackendEvent) -> Void)? { get set }
    func start() throws
    func play(_ spec: HapticPatternSpec) throws
    /// Live modulation of the currently playing pattern (CHHapticDynamicParameter).
    func sendDynamic(intensity: Float?, sharpness: Float?) throws
    func stopPlayback()
    func shutdown()
}

/// Real backend: CHHapticEngine in haptics-only mode with CHHapticAdvancedPatternPlayer.
final class CoreHapticsBackend: HapticBackend {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    var eventHandler: ((BackendEvent) -> Void)?

    var capabilities: HapticCapabilities {
        let caps = CHHapticEngine.capabilitiesForHardware()
        return HapticCapabilities(supportsHaptics: caps.supportsHaptics, supportsAudio: caps.supportsAudio, simulated: false)
    }

    var playsHapticsOnly: Bool { engine?.playsHapticsOnly ?? false }

    func start() throws {
        if engine == nil {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] reason in
                self?.eventHandler?(.stopped(reason: Self.describe(reason)))
            }
            engine.resetHandler = { [weak self] in
                guard let self else { return }
                self.player = nil
                try? self.engine?.start()
                self.eventHandler?(.reset)
            }
            self.engine = engine
        }
        try engine?.start()
    }

    func play(_ spec: HapticPatternSpec) throws {
        guard let engine else { throw HapticError.engineNotReady }
        try? player?.stop(atTime: CHHapticTimeImmediate)
        let pattern = try Self.makePattern(spec)
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.completionHandler = { [weak self] error in
            self?.eventHandler?(.playerFinished(error: error?.localizedDescription))
        }
        self.player = player
        try engine.start()
        try player.start(atTime: CHHapticTimeImmediate)
    }

    func sendDynamic(intensity: Float?, sharpness: Float?) throws {
        guard let player else { return }
        var params: [CHHapticDynamicParameter] = []
        if let intensity { params.append(.init(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)) }
        if let sharpness { params.append(.init(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0)) }
        try player.sendParameters(params, atTime: CHHapticTimeImmediate)
    }

    func stopPlayback() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    func shutdown() {
        stopPlayback()
        engine?.stop(completionHandler: nil)
    }

    static func makePattern(_ spec: HapticPatternSpec) throws -> CHHapticPattern {
        try CHHapticPattern(events: spec.events.map(makeEvent), parameterCurves: spec.curves.map(makeCurve))
    }

    private static func makeEvent(_ e: HapticPatternSpec.Event) -> CHHapticEvent {
        let params = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: e.intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: e.sharpness),
        ]
        switch e.kind {
        case .continuous:
            return CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: e.time, duration: e.duration)
        case .transient:
            return CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: e.time)
        }
    }

    private static func makeCurve(_ c: HapticPatternSpec.Curve) -> CHHapticParameterCurve {
        let id: CHHapticDynamicParameter.ID = c.parameter == .intensity ? .hapticIntensityControl : .hapticSharpnessControl
        return CHHapticParameterCurve(parameterID: id,
                                      controlPoints: c.points.map { .init(relativeTime: $0.time, value: $0.value) },
                                      relativeTime: c.startTime)
    }

    static func describe(_ reason: CHHapticEngine.StoppedReason) -> String {
        switch reason {
        case .audioSessionInterrupt: return "audio session interrupted"
        case .applicationSuspended: return "application suspended"
        case .idleTimeout: return "idle timeout"
        case .systemError: return "system error"
        case .notifyWhenFinished: return "finished"
        case .engineDestroyed: return "engine destroyed"
        case .gameControllerDisconnect: return "game controller disconnected"
        @unknown default: return "unknown (\(reason.rawValue))"
        }
    }
}

/// UI-test backend, enabled only with the `-uiTestingSimulatedHaptics` launch argument.
/// It produces no output and is always labelled SIMULATED in the UI.
final class SimulatedHapticBackend: HapticBackend {
    var eventHandler: ((BackendEvent) -> Void)?
    private(set) var played: [HapticPatternSpec] = []
    private var started = false
    private var pending: DispatchWorkItem?

    var capabilities: HapticCapabilities { .init(supportsHaptics: true, supportsAudio: false, simulated: true) }
    var playsHapticsOnly: Bool { started }

    func start() throws { started = true }

    func play(_ spec: HapticPatternSpec) throws {
        guard started else { throw HapticError.engineNotReady }
        played.append(spec)
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.eventHandler?(.playerFinished(error: nil)) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + spec.duration, execute: item)
    }

    func sendDynamic(intensity: Float?, sharpness: Float?) throws {}
    func stopPlayback() { pending?.cancel(); pending = nil }
    func shutdown() { stopPlayback(); started = false }
}

enum HapticError: LocalizedError {
    case engineNotReady, unsupportedHardware, cooldown(Double), sessionExhausted, thermal, busy

    var errorDescription: String? {
        switch self {
        case .engineNotReady: return "Haptic engine is not running"
        case .unsupportedHardware: return "This device does not support Core Haptics"
        case .cooldown(let s): return String(format: "Cooldown: wait %.1fs", s)
        case .sessionExhausted: return "Session budget reached. Reset the session to continue."
        case .thermal: return "Device thermal state is elevated. Let it cool down."
        case .busy: return "A pattern is already playing"
        }
    }
}
