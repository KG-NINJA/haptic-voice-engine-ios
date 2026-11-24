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

    func testMissingFileThrows() {
        XCTAssertThrowsError(try AudioFileLoader.load(url: URL(fileURLWithPath: "/nonexistent.wav")))
    }
}
