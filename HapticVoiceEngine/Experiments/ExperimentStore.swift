import Foundation
import HapticVoiceKit
import SwiftUI

/// App model: connects the haptic controller, speech pipeline, experiment log and blind test.
@MainActor
final class ExperimentStore: ObservableObject {
    @Published var material: TestMaterial = .woodenDesk
    @Published private(set) var records: [ExperimentRecord] = []
    @Published private(set) var blindTrials: [BlindTrial] = []
    @Published private(set) var activeMethod = "None"
    @Published private(set) var speechStatus = ""
    @Published private(set) var preparingSpeech = false
    @Published private(set) var matrixRunning = false
    @Published private(set) var matrixProgress = ""
    @Published var listener = "listener-1"
    @Published var pitchScale: Double = 1
    @Published private(set) var pendingBlindTrial: BlindTrial?
    @Published private(set) var lastExportURL: URL?

    let controller: HapticEngineController
    private let renderer = SpeechSynthesisRenderer()
    private var speechCache: [String: (SynthesizedSpeech, SpeechFeatures)] = [:]
    private var pending: (category: String, method: String, requested: [String: Double], notes: [String], features: SpeechFeatures.Summary?)?
    private var matrixTask: Task<Void, Never>?
    private var counter = 0
    private let persistence: URL?

    init(controller: HapticEngineController, persist: Bool = true) {
        self.controller = controller
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        persistence = persist ? docs?.appendingPathComponent("experiment_log.json") : nil
        load()
        controller.onPlayFinished = { [weak self] result in self?.record(result) }
    }

    var physicalConfirmation: PhysicalConfirmation? {
        if records.contains(where: { $0.physicalConfirmation == .felt && !$0.simulated }) { return .felt }
        if records.contains(where: { $0.physicalConfirmation == .notFelt && !$0.simulated }) { return .notFelt }
        if records.contains(where: { $0.physicalConfirmation == .felt }) { return .felt }
        return records.contains(where: { $0.physicalConfirmation == .notFelt }) ? .notFelt : nil
    }

    var lastRecord: ExperimentRecord? { records.first }

    // MARK: Playback entry points

    func playManual(intensity: Float, sharpness: Float, duration: Double, modulation: ModulationRate) {
        let spec = PatternLibrary.manual(intensity: intensity, sharpness: sharpness, duration: duration, modulation: modulation)
        start(spec, category: "manual", method: "Manual control",
              requested: ["intensity": Double(intensity), "sharpness": Double(sharpness), "duration": duration, "modulationHz": modulation.rawValue])
    }

    func playPreset(_ preset: PatternLibrary.Preset, intensity: Float, sharpness: Float, rate: ModulationRate) {
        let spec = PatternLibrary.preset(preset, intensity: intensity, sharpness: sharpness, rate: rate)
        start(spec, category: "preset", method: "Preset: \(preset.rawValue)",
              requested: ["intensity": Double(intensity), "sharpness": Double(sharpness), "modulationHz": rate.rawValue])
    }

    func playMatrixCell(_ cell: PatternLibrary.MatrixCell) {
        start(PatternLibrary.matrixPattern(cell), category: "matrix", method: "Experiment A: characterization matrix",
              requested: ["intensity": Double(cell.intensity), "sharpness": Double(cell.sharpness), "duration": PatternLibrary.matrixDuration])
    }

    /// Runs the 25-cell matrix once, waiting for each result plus the cooldown. Bounded: one pass.
    func runMatrix() {
        guard !matrixRunning else { return }
        matrixRunning = true
        matrixTask = Task { [weak self] in
            guard let self else { return }
            let cells = PatternLibrary.matrix
            for (n, cell) in cells.enumerated() {
                if Task.isCancelled { break }
                self.matrixProgress = "Matrix \(n + 1)/\(cells.count): \(cell.id)"
                while self.controller.cooldownRemaining > 0 || self.controller.isPlaying {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if Task.isCancelled { break }
                self.playMatrixCell(cell)
                guard self.controller.isPlaying else { break }
                while self.controller.isPlaying { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            self.matrixProgress = Task.isCancelled ? "Matrix stopped" : "Matrix pass complete"
            self.matrixRunning = false
        }
    }

    func stopAll(reason: String = "user STOP") {
        matrixTask?.cancel()
        matrixRunning = false
        controller.stop(reason: reason)
    }

    func playSpeech(_ text: String, method: SpeechMappingMethod) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { speechStatus = "Enter text first"; return }
        guard let (speech, features) = await prepare(trimmed) else { return }
        let mapped = SpeechHapticMapper.map(features, method: method, label: "\"\(trimmed)\"", markers: speech.markers, pitchScale: pitchScale)
        let s = features.summary
        start(mapped.spec, category: "speech", method: method.rawValue,
              requested: ["speechDuration": speech.duration, "sampleRate": speech.sampleRate, "pitchScale": pitchScale],
              notes: mapped.notes + ["text=\(trimmed)", "language=\(speech.language)", "markers=\(speech.markers.count)"], features: s)
    }

    func prepare(_ text: String) async -> (SynthesizedSpeech, SpeechFeatures)? {
        if let cached = speechCache[text] { return cached }
        preparingSpeech = true
        speechStatus = "Rendering \"\(text)\" offline (no audio output)…"
        defer { preparingSpeech = false }
        do {
            let speech = try await renderer.render(text: text)
            let features = SpeechFeatureExtractor.extract(samples: speech.samples, sampleRate: speech.sampleRate)
            speechCache[text] = (speech, features)
            let s = features.summary
            speechStatus = String(format: "\"%@\" %.2fs, voiced %.0f%%, F0 %@, centroid %.0f Hz, F1/F2 %@", text, s.duration, s.voicedFraction * 100,
                                  s.meanF0.map { String(format: "%.0f Hz", $0) } ?? "n/a", s.meanCentroid,
                                  (s.medianF1 != nil && s.medianF2 != nil) ? String(format: "%.0f/%.0f Hz (est.)", s.medianF1!, s.medianF2!) : "n/a")
            return (speech, features)
        } catch {
            speechStatus = "Speech rendering failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Blind test

    func startBlindTrial(method: SpeechMappingMethod) async {
        guard pendingBlindTrial == nil else { return }
        guard let target = BlindTestStats.vowels.randomElement() else { return }
        guard let (speech, features) = await prepare(target) else { return }
        let mapped = SpeechHapticMapper.map(features, method: method, label: "Blind trial", markers: speech.markers, pitchScale: pitchScale)
        var spec = mapped.spec
        spec.name = "Blind trial · \(method.short)"
        let trial = BlindTrial(id: nextID(prefix: "BLIND"), timestamp: now(), listener: listener, method: method, material: material, target: target)
        if start(spec, category: "blind", method: method.rawValue, requested: [:], notes: ["blind trial \(trial.id); target hidden"]) {
            pendingBlindTrial = trial
        }
    }

    func answerBlindTrial(_ answer: String) {
        guard var trial = pendingBlindTrial else { return }
        trial.answer = answer
        blindTrials.insert(trial, at: 0)
        pendingBlindTrial = nil
        save()
    }

    func discardBlindTrial() { pendingBlindTrial = nil }

    // MARK: Records

    func confirmLast(_ c: PhysicalConfirmation) {
        guard !records.isEmpty else { return }
        records[0].physicalConfirmation = c
        save()
    }

    func clearAll() {
        records = []
        blindTrials = []
        save()
    }

    @discardableResult
    private func start(_ spec: HapticPatternSpec, category: String, method: String, requested: [String: Double],
                       notes: [String] = [], features: SpeechFeatures.Summary? = nil) -> Bool {
        pending = (category, method, requested, notes, features)
        activeMethod = method
        let ok = controller.play(spec)
        if !ok { pending = nil }
        return ok
    }

    private func record(_ r: HapticEngineController.PlayResult) {
        let p = pending
        pending = nil
        let rec = ExperimentRecord(
            id: nextID(prefix: "HVE"), timestamp: ISO8601DateFormatter.fractional.string(from: r.startedAt),
            category: p?.category ?? "unknown", name: r.requested.name, method: p?.method ?? activeMethod, material: material,
            requested: p?.requested ?? [:], requestedPattern: r.requested,
            executedEventCount: r.executed.events.count, executedCurveCount: r.executed.curves.count, executedDuration: r.executed.duration,
            warnings: r.warnings, notes: p?.notes ?? [], status: r.status, error: r.error,
            startedAt: ISO8601DateFormatter.fractional.string(from: r.startedAt),
            endedAt: r.endedAt.map { ISO8601DateFormatter.fractional.string(from: $0) },
            measuredPlaybackSeconds: r.endedAt.map { $0.timeIntervalSince(r.startedAt) },
            physicalConfirmation: nil, speechFeatures: p?.features, simulated: controller.capabilities.simulated,
            audioEventCount: 0)
        records.insert(rec, at: 0)
        save()
    }

    // MARK: Persistence / export

    func export() -> URL? {
        let caps = controller.capabilities
        let payload = ExperimentExport(
            exportedAt: now(), app: "HapticVoiceEngine \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")",
            device: DeviceInfo.friendlyModel, os: DeviceInfo.systemVersion,
            capabilities: ["supportsHaptics": caps.supportsHaptics, "supportsAudio": caps.supportsAudio, "simulated": caps.simulated],
            playsHapticsOnly: controller.playsHapticsOnly,
            physicalVibrationConfirmed: physicalConfirmation.map { $0 == .felt },
            records: records, blindTrials: blindTrials, engineLog: controller.events)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent("experiment_results.json")
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(payload).write(to: url, options: .atomic)
            lastExportURL = url
            return url
        } catch {
            return nil
        }
    }

    private struct Saved: Codable { var records: [ExperimentRecord]; var blindTrials: [BlindTrial]; var counter: Int }

    private func save() {
        guard let persistence else { return }
        try? JSONEncoder().encode(Saved(records: records, blindTrials: blindTrials, counter: counter)).write(to: persistence, options: .atomic)
    }

    private func load() {
        guard let persistence, let data = try? Data(contentsOf: persistence),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        records = saved.records
        blindTrials = saved.blindTrials
        counter = saved.counter
    }

    private func nextID(prefix: String) -> String {
        counter += 1
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return String(format: "%@-%@-%04d", prefix, f.string(from: Date()), counter)
    }

    private func now() -> String { ISO8601DateFormatter.fractional.string(from: Date()) }
}
