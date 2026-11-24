import AVFoundation
import XCTest
@testable import HapticVoiceKit

final class AudioFileLoaderTests: XCTestCase {
    func testWavRoundTripTruncatesAndClicksAtFilePitch() throws {
        let sr = 22050.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hvk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioFileLoader.writeWAV(PulseVoiceTests.vowel(f0: 150, seconds: 4, sampleRate: sr), sampleRate: sr, to: url)

        let audio = try AudioFileLoader.load(url: url, maxDuration: 3)
        XCTAssertEqual(audio.sampleRate, sr)
        XCTAssertEqual(audio.duration, 3, accuracy: 0.001)
        XCTAssertEqual(audio.sourceDuration, 4, accuracy: 0.001)
        XCTAssertTrue(audio.truncated)

        let clicks = try PulseVoice.events(audioFile: url).filter { $0.kind == .click }.map(\.time)
        XCTAssertGreaterThan(clicks.count, 300)
        XCTAssertLessThan(clicks.last ?? 99, 3)
        let gaps = zip(clicks.dropFirst(), clicks).map { $0 - $1 }.sorted()
        XCTAssertEqual(gaps[gaps.count / 2], 1.0 / 150, accuracy: 0.0005)
    }

    func testNonFiniteSamplesAreZeroed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hvk-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000.0, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4))
        buffer.frameLength = 4
        for (i, v) in [Float(0.5), .infinity, .nan, -0.5].enumerated() { buffer.floatChannelData![0][i] = v }
        try file.write(from: buffer)
        let audio = try AudioFileLoader.load(url: url)
        XCTAssertEqual(audio.samples, [0.5, 0, 0, -0.5])
    }

    func testSoundShorterThanAnalysisWindowStillGetsAFrame() {
        let sr = 22050.0
        let burst = PulseVoiceTests.vowel(f0: 150, seconds: 0.015, sampleRate: sr).map { $0 * 3 }
        let f = SpeechFeatureExtractor.extract(samples: [Float](repeating: 0, count: 2000) + burst, sampleRate: sr)
        XCTAssertGreaterThanOrEqual(f.times.count, 1)
        XCTAssertLessThanOrEqual(f.duration, 0.016)
        XCTAssertTrue(PulseVoice.events(from: f).allSatisfy { $0.time + $0.duration <= f.duration + 1e-9 })
        XCTAssertTrue(SpeechFeatureExtractor.extract(samples: [Float](repeating: 0, count: 200), sampleRate: sr).times.isEmpty)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try AudioFileLoader.load(url: URL(fileURLWithPath: "/nonexistent.wav")))
    }
}
