import CoreHaptics
import XCTest
@testable import HapticVoiceEngine
import HapticVoiceKit

final class HapticPatternTests: XCTestCase {
    func testChunkedCurvesRespectPointLimitAndStayContinuous() {
        let points = (0..<100).map { HapticPatternSpec.CurvePoint(time: Double($0) * 0.02, value: Float($0) / 100) }
        let curves = HapticPatternSpec.chunkedCurves(parameter: .intensity, points: points)
        XCTAssertTrue(curves.allSatisfy { $0.points.count <= HapticLimits.maxPointsPerCurve })
        for (a, b) in zip(curves, curves.dropFirst()) {
            XCTAssertEqual(a.startTime + a.points.last!.time, b.startTime, accuracy: 1e-9)
            XCTAssertEqual(a.points.last!.value, b.points.first!.value)
        }
        XCTAssertEqual(curves.last!.startTime + curves.last!.points.last!.time, points.last!.time, accuracy: 1e-9)
    }

    func testValidationClampsAndTruncatesToSafetyLimit() {
        var spec = HapticPatternSpec(name: "x")
        spec.events = [.init(kind: .continuous, time: 0, duration: 10, intensity: 2, sharpness: -1),
                       .init(kind: .transient, time: 5, duration: 0, intensity: 1, sharpness: 1)]
        let (v, warnings) = spec.validated()
        XCTAssertEqual(v.events.count, 1)
        XCTAssertEqual(v.events[0].duration, HapticLimits.maxPlaybackDuration)
        XCTAssertEqual(v.events[0].intensity, 1)
        XCTAssertEqual(v.events[0].sharpness, 0)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertLessThanOrEqual(v.duration, HapticLimits.maxPlaybackDuration)
    }

    func testManualDurationIsClamped() {
        XCTAssertEqual(PatternLibrary.manual(intensity: 1, sharpness: 1, duration: 9, modulation: .none).duration, 3.0)
        XCTAssertEqual(PatternLibrary.manual(intensity: 1, sharpness: 1, duration: 0.01, modulation: .none).duration, 0.1)
    }

    func testMatrixHas25OneSecondCells() {
        XCTAssertEqual(PatternLibrary.matrix.count, 25)
        XCTAssertEqual(Set(PatternLibrary.matrix.map(\.id)).count, 25)
        XCTAssertTrue(PatternLibrary.matrix.allSatisfy { PatternLibrary.matrixPattern($0).duration == 1.0 })
    }

    /// Every pattern the app can generate must be accepted by Core Haptics' own validation.
    func testAllGeneratedPatternsAreAcceptedByCoreHaptics() throws {
        var specs = PatternLibrary.Preset.allCases.map { PatternLibrary.preset($0) }
        specs += PatternLibrary.matrix.map(PatternLibrary.matrixPattern)
        specs += ModulationRate.allCases.map { PatternLibrary.manual(intensity: 0.8, sharpness: 0.3, duration: 3, modulation: $0) }
        let features = SpeechFeatureExtractor.extract(samples: SyntheticSignal.vowel(f0: 140, seconds: 2.5), sampleRate: 22050)
        specs += SpeechMappingMethod.allCases.map { SpeechHapticMapper.map(features, method: $0, label: "t").spec }
        for spec in specs {
            let (v, _) = spec.validated()
            XCTAssertNoThrow(try CoreHapticsBackend.makePattern(v), spec.name)
            XCTAssertLessThanOrEqual(v.duration, HapticLimits.maxPlaybackDuration + 0.05, spec.name)
            XCTAssertTrue(v.curves.allSatisfy { $0.points.count <= HapticLimits.maxPointsPerCurve }, spec.name)
        }
    }

    func testAMCurveAlternatesAtRequestedRate() {
        let curves = PatternLibrary.amCurve(rate: 10, duration: 1)
        let points = curves.flatMap { c in c.points.map { (c.startTime + $0.time, $0.value) } }
        let rises = zip(points, points.dropFirst()).filter { $0.0.1 == 0 && $0.1.1 == 1 }.count
        XCTAssertEqual(rises, 9)
    }
}

final class SafetyGovernorTests: XCTestCase {
    func testCooldownSessionAndThermal() {
        var g = SafetyGovernor(cooldown: 2, maxPlays: 2)
        let t0 = Date()
        XCTAssertNoThrow(try g.check(now: t0, thermal: .nominal))
        g.recordStart(now: t0); g.recordEnd(now: t0.addingTimeInterval(1))
        XCTAssertThrowsError(try g.check(now: t0.addingTimeInterval(2), thermal: .nominal))
        XCTAssertNoThrow(try g.check(now: t0.addingTimeInterval(3.1), thermal: .nominal))
        XCTAssertThrowsError(try g.check(now: t0.addingTimeInterval(10), thermal: .serious))
        g.recordStart(now: t0.addingTimeInterval(4)); g.recordEnd(now: t0.addingTimeInterval(5))
        XCTAssertThrowsError(try g.check(now: t0.addingTimeInterval(20), thermal: .nominal)) { error in
            guard case HapticError.sessionExhausted = error else { return XCTFail("\(error)") }
        }
        g.resetSession()
        XCTAssertNoThrow(try g.check(now: t0.addingTimeInterval(20), thermal: .nominal))
    }

    @MainActor
    func testControllerRefusesDuringCooldownAndRecordsResult() async throws {
        let backend = SimulatedHapticBackend()
        let controller = HapticEngineController(backend: backend)
        controller.governor.cooldown = 1
        controller.startEngine()
        XCTAssertTrue(controller.playsHapticsOnly)
        var results: [HapticEngineController.PlayResult] = []
        controller.onPlayFinished = { results.append($0) }
        XCTAssertTrue(controller.play(PatternLibrary.preset(.singlePulse)))
        XCTAssertFalse(controller.play(PatternLibrary.preset(.singlePulse)), "busy")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(results.first?.status, "finished")
        XCTAssertFalse(controller.play(PatternLibrary.preset(.singlePulse)), "cooldown")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(controller.play(PatternLibrary.preset(.continuous)))
        controller.stop()
        XCTAssertEqual(results.last?.status, "stopped")
        XCTAssertEqual(backend.played.count, 2)
    }

    @MainActor
    func testThermalStateBlocksPlayback() {
        let controller = HapticEngineController(backend: SimulatedHapticBackend())
        controller.thermalState = { .critical }
        controller.startEngine()
        XCTAssertFalse(controller.play(PatternLibrary.preset(.singlePulse)))
    }
}

final class BlindStatsTests: XCTestCase {
    func testAccuracyConfusionAndPValue() {
        func trial(_ t: String, _ a: String) -> BlindTrial {
            BlindTrial(id: UUID().uuidString, timestamp: "", listener: "l", method: .envelope, material: .hand, target: t, answer: a)
        }
        let trials = [trial("あ", "あ"), trial("い", "う"), trial("う", "う"), trial("お", "あ")]
        XCTAssertEqual(BlindTestStats.accuracy(trials), 0.5)
        let m = BlindTestStats.confusion(trials)
        XCTAssertEqual(m[0][0], 1); XCTAssertEqual(m[1][2], 1); XCTAssertEqual(m[4][0], 1)
        XCTAssertEqual(m.flatMap { $0 }.reduce(0, +), 4)
        XCTAssertEqual(BlindTestStats.pValue(correct: 10, trials: 10), pow(0.2, 10), accuracy: 1e-12)
        XCTAssertEqual(BlindTestStats.pValue(correct: 0, trials: 10), 1)
        XCTAssertEqual(BlindTestStats.pValue(correct: 4, trials: 20), 0.5886, accuracy: 0.001)
    }
}
