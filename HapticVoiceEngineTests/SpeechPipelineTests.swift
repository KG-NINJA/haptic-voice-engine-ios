import XCTest
@testable import HapticVoiceEngine

enum SyntheticSignal {
    /// Harmonic tone with an attack/decay envelope, a stand-in for a voiced vowel.
    static func vowel(f0: Double, seconds: Double, sampleRate: Double = 22050, harmonics: [Double] = [1, 0.6, 0.4, 0.3, 0.2]) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let env = min(1, t / 0.05) * min(1, (seconds - t) / 0.1)
            let v = harmonics.enumerated().reduce(0.0) { $0 + $1.element * sin(2 * .pi * f0 * Double($1.offset + 1) * t) }
            return Float(0.3 * env * v)
        }
    }
}

final class SpeechPipelineTests: XCTestCase {
    func testFeatureExtractionOnKnownSignal() {
        let samples = SyntheticSignal.vowel(f0: 150, seconds: 1.0)
        let f = SpeechFeatureExtractor.extract(samples: samples, sampleRate: 22050)
        let s = f.summary
        XCTAssertEqual(s.duration, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(s.voicedFraction, 0.8)
        XCTAssertEqual(s.meanF0 ?? 0, 150, accuracy: 5)
        XCTAssertGreaterThan(s.meanCentroid, 150)
        XCTAssertLessThan(s.meanCentroid, 750)
        XCTAssertEqual(f.envelope.max() ?? 0, 1, accuracy: 0.05)
        XCTAssertEqual(f.times.count, f.rms.count)
    }

    func testSilenceIsUnvoiced() {
        let f = SpeechFeatureExtractor.extract(samples: [Float](repeating: 0, count: 22050), sampleRate: 22050)
        XCTAssertTrue(f.voiced.allSatisfy { !$0 })
    }

    func testCentroidNormalizationIsMonotonicAndBounded() {
        let values = [0, 100, 200, 500, 1000, 3000, 5000, 9000].map { SpeechHapticMapper.normalizedCentroid(Float($0)) }
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
    }

    func testMappingMethodsDifferAndAreLabelledExperimental() {
        let f = SpeechFeatureExtractor.extract(samples: SyntheticSignal.vowel(f0: 120, seconds: 4.0), sampleRate: 22050)
        let results = SpeechMappingMethod.allCases.map { SpeechHapticMapper.map(f, method: $0, label: "x") }
        for r in results {
            XCTAssertTrue(r.spec.name.contains("experimental"))
            XCTAssertLessThanOrEqual(r.spec.duration, HapticLimits.maxPlaybackDuration + 0.05)
            XCTAssertTrue(r.notes.contains { $0.contains("truncated") })
        }
        XCTAssertFalse(results[0].spec.curves.contains { $0.parameter == .sharpness })
        XCTAssertTrue(results[1].spec.curves.contains { $0.parameter == .sharpness })
        XCTAssertTrue(results[2].spec.events.contains { $0.kind == .transient })
    }

    /// Real offline synthesis on the simulator: PCM comes back and nothing needs an audio output.
    @MainActor
    func testOfflineSynthesisProducesPCM() async throws {
        let renderer = SpeechSynthesisRenderer()
        let speech = try await renderer.render(text: "Hello", language: "en-US", timeout: 30)
        XCTAssertGreaterThan(speech.samples.count, 1000)
        XCTAssertGreaterThan(speech.duration, 0.2)
        let f = SpeechFeatureExtractor.extract(samples: speech.samples, sampleRate: speech.sampleRate)
        XCTAssertGreaterThan(f.summary.voicedFraction, 0.1)
    }

    func testLanguageDetection() {
        XCTAssertEqual(SpeechSynthesisRenderer.language(for: "あ"), "ja-JP")
        XCTAssertEqual(SpeechSynthesisRenderer.language(for: "Hello"), "en-US")
        XCTAssertEqual(SpeechSynthesisRenderer.language(for: "AIです"), "ja-JP")
    }
}
