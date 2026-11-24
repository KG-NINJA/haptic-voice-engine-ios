import XCTest
@testable import HapticVoiceKit

final class PulseVoiceTests: XCTestCase {
    static func vowel(f0: Double, seconds: Double, sampleRate: Double = 22050) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let env = min(1, t / 0.05) * min(1, (seconds - t) / 0.1)
            let v = [1, 0.6, 0.4, 0.3, 0.2].enumerated().reduce(0.0) { $0 + $1.element * sin(2 * .pi * f0 * Double($1.offset + 1) * t) }
            return Float(0.3 * env * v)
        }
    }

    func medianGap(_ times: [Double]) -> Double {
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        return gaps[gaps.count / 2]
    }

    func testClicksFollowVoicePitchAndSilenceStaysSilent() {
        let sr = 22050.0
        let samples = Self.vowel(f0: 150, seconds: 0.5) + [Float](repeating: 0, count: Int(sr * 0.3)) + Self.vowel(f0: 150, seconds: 0.5)
        let clicks = PulseVoice.events(samples: samples, sampleRate: sr).filter { $0.kind == .click }.map(\.time)
        XCTAssertGreaterThan(clicks.count, 100)
        XCTAssertEqual(medianGap(clicks), 1.0 / 150, accuracy: 0.0005)
        XCTAssertGreaterThan(zip(clicks.dropFirst(), clicks).map { $0 - $1 }.max() ?? 0, 0.2)
    }

    func testPitchScaleIsClamped() {
        let samples = Self.vowel(f0: 150, seconds: 1.0)
        let raised = PulseVoice.events(samples: samples, sampleRate: 22050, options: .init(pitchScale: 2)).map(\.time)
        XCTAssertEqual(medianGap(raised), 1.0 / 300, accuracy: 0.0005)
    }

    func testRespectsMaxDurationAndBuildsHapticPattern() throws {
        let events = PulseVoice.events(samples: Self.vowel(f0: 120, seconds: 4.0), sampleRate: 22050)
        XCTAssertLessThan(events.map { $0.time + $0.duration }.max() ?? 0, 3.0 + 1e-9)
        XCTAssertNoThrow(try PulseVoice.pattern(events))
    }
}
