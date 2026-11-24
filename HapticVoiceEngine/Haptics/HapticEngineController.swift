import Foundation
import UIKit

/// Reusable controller that owns the haptic backend, safety rules and playback state.
/// It has no SwiftUI dependency so it can later be reused by an App Clip target.
@MainActor
final class HapticEngineController: ObservableObject {
    enum PlaybackState: Equatable {
        case idle, playing(String), finished(String), stopped(String), failed(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .playing(let n): return "Playing: \(n)"
            case .finished(let n): return "Finished: \(n)"
            case .stopped(let r): return "Stopped: \(r)"
            case .failed(let e): return "Error: \(e)"
            }
        }
    }

    struct PlayResult {
        var requested: HapticPatternSpec
        var executed: HapticPatternSpec
        var warnings: [String]
        var startedAt: Date
        var endedAt: Date?
        var status: String
        var error: String?
    }

    @Published private(set) var capabilities: HapticCapabilities
    @Published private(set) var engineReady = false
    @Published private(set) var engineStatus = "Not started"
    @Published private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var events: [String] = []
    @Published private(set) var cooldownRemaining: Double = 0
    @Published private(set) var lastRefusal: String?
    @Published var governor = SafetyGovernor()

    let backend: HapticBackend
    var thermalState: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    var onPlayFinished: ((PlayResult) -> Void)?

    private var current: PlayResult?
    private var watchdog: Task<Void, Never>?
    private var cooldownTicker: Timer?

    var isPlaying: Bool { if case .playing = playbackState { return true } else { return false } }
    var playsHapticsOnly: Bool { backend.playsHapticsOnly }

    init(backend: HapticBackend) {
        self.backend = backend
        self.capabilities = backend.capabilities
        backend.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkThermal() }
        }
    }

    func startEngine() {
        capabilities = backend.capabilities
        guard capabilities.supportsHaptics else {
            engineReady = false
            engineStatus = "Unsupported hardware"
            log("capabilitiesForHardware: supportsHaptics=false")
            return
        }
        do {
            try backend.start()
            engineReady = true
            engineStatus = capabilities.simulated ? "Running (SIMULATED)" : "Running"
            log("engine started, playsHapticsOnly=\(backend.playsHapticsOnly)")
        } catch {
            engineReady = false
            engineStatus = "Start failed: \(error.localizedDescription)"
            log("engine start failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func play(_ spec: HapticPatternSpec, maxDuration: Double = HapticLimits.maxPlaybackDuration) -> Bool {
        guard capabilities.supportsHaptics else { fail(HapticError.unsupportedHardware); return false }
        guard engineReady else { fail(HapticError.engineNotReady); return false }
        guard !isPlaying else { fail(HapticError.busy); return false }
        do {
            try governor.check(thermal: thermalState())
        } catch {
            fail(error)
            return false
        }
        lastRefusal = nil
        let (executed, warnings) = spec.validated(limit: maxDuration)
        current = PlayResult(requested: spec, executed: executed, warnings: warnings, startedAt: Date(), status: "started")
        do {
            try backend.play(executed)
            governor.recordStart()
            playbackState = .playing(spec.name)
            log("play \(spec.name) duration=\(String(format: "%.2f", executed.duration))s events=\(executed.events.count) curves=\(executed.curves.count)" + (warnings.isEmpty ? "" : " warnings=\(warnings.joined(separator: "; "))"))
            armWatchdog(for: min(executed.duration, HapticLimits.maxAudioFileDuration))
            return true
        } catch {
            current?.status = "failed"
            current?.error = error.localizedDescription
            finish(state: .failed(error.localizedDescription))
            return false
        }
    }

    func sendDynamic(intensity: Float?, sharpness: Float?) {
        guard isPlaying else { return }
        do { try backend.sendDynamic(intensity: intensity.map(HapticLimits.clamp01), sharpness: sharpness.map(HapticLimits.clamp01)) }
        catch { log("dynamic parameter failed: \(error.localizedDescription)") }
    }

    func stop(reason: String = "user STOP") {
        backend.stopPlayback()
        if isPlaying {
            current?.status = "stopped"
            current?.error = reason
            finish(state: .stopped(reason))
        } else {
            playbackState = .stopped(reason)
        }
        log("stop: \(reason)")
    }

    func enterBackground() {
        stop(reason: "app entered background")
        backend.shutdown()
        engineReady = false
        engineStatus = "Stopped (background)"
    }

    func resetSession() {
        governor.resetSession()
        updateCooldown()
        log("session reset")
    }

    private func handle(_ event: BackendEvent) {
        switch event {
        case .playerFinished(let error):
            guard isPlaying else { return }
            if let error {
                current?.status = "failed"
                current?.error = error
                finish(state: .failed(error))
            } else {
                current?.status = "finished"
                finish(state: .finished(current?.requested.name ?? ""))
            }
        case .stopped(let reason):
            log("engine stopped: \(reason)")
            engineReady = false
            engineStatus = "Stopped: \(reason)"
            if isPlaying {
                current?.status = "engine stopped"
                current?.error = reason
                finish(state: .stopped("engine stopped: \(reason)"))
            }
        case .reset:
            log("engine reset by system; restarted")
            engineStatus = "Running (after reset)"
            engineReady = true
            if isPlaying {
                current?.status = "engine reset"
                finish(state: .stopped("engine reset"))
            }
        }
    }

    private func finish(state: PlaybackState) {
        watchdog?.cancel()
        playbackState = state
        guard var result = current else { return }
        result.endedAt = Date()
        current = nil
        governor.recordEnd()
        updateCooldown()
        log("result \(result.requested.name): \(result.status)" + (result.error.map { " (\($0))" } ?? ""))
        onPlayFinished?(result)
    }

    private func fail(_ error: Error) {
        lastRefusal = error.localizedDescription
        if !isPlaying { playbackState = .failed(error.localizedDescription) }
        log("refused: \(error.localizedDescription)")
        if case HapticError.thermal = error { stop(reason: "thermal state") }
    }

    /// Hard stop in case the completion callback never arrives.
    private func armWatchdog(for duration: Double) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 1.0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isPlaying else { return }
                self.backend.stopPlayback()
                self.current?.status = "watchdog stop"
                self.finish(state: .stopped("watchdog: no completion callback"))
            }
        }
    }

    private func checkThermal() {
        let t = thermalState()
        log("thermal state: \(t.label)")
        if (t == .serious || t == .critical) && isPlaying { stop(reason: "thermal state \(t.label)") }
    }

    private func updateCooldown() {
        cooldownRemaining = governor.remainingCooldown()
        cooldownTicker?.invalidate()
        guard cooldownRemaining > 0 else { return }
        cooldownTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.cooldownRemaining = self.governor.remainingCooldown()
                if self.cooldownRemaining <= 0 { timer.invalidate() }
            }
        }
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter.fractional.string(from: Date())
        events.insert("\(stamp) \(message)", at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

enum DeviceInfo {
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "\(sim) (Simulator)" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var friendlyModel: String {
        let id = modelIdentifier
        let names = ["iPhone14,6": "iPhone SE (3rd generation)", "iPhone12,8": "iPhone SE (2nd generation)"]
        return names[id].map { "\($0) [\(id)]" } ?? id
    }

    @MainActor static var systemVersion: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }
}
