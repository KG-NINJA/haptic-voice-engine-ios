import Foundation
import HapticVoiceKit

enum TestMaterial: String, CaseIterable, Identifiable, Codable {
    case hand = "Phone held in hand"
    case woodenDesk = "Wooden desk"
    case cardboardBox = "Cardboard box"
    case hollowWoodenBox = "Hollow wooden box"
    case metal = "Metal surface"
    case glass = "Glass surface"
    var id: String { rawValue }
}

enum PhysicalConfirmation: String, Codable {
    case felt, notFelt = "not_felt"
}

struct ExperimentRecord: Codable, Identifiable, Equatable {
    var id: String
    var timestamp: String
    var category: String
    var name: String
    var method: String
    var material: TestMaterial
    var requested: [String: Double]
    var requestedPattern: HapticPatternSpec
    var executedEventCount: Int
    var executedCurveCount: Int
    var executedDuration: Double
    var warnings: [String]
    var notes: [String]
    var status: String
    var error: String?
    var startedAt: String
    var endedAt: String?
    var measuredPlaybackSeconds: Double?
    var physicalConfirmation: PhysicalConfirmation?
    var speechFeatures: SpeechFeatures.Summary?
    var simulated: Bool
    var audioEventCount: Int
}

struct BlindTrial: Codable, Identifiable, Equatable {
    var id: String
    var timestamp: String
    var listener: String
    var method: SpeechMappingMethod
    var material: TestMaterial
    var target: String
    var answer: String?
    var pitchScale: Double?
}

enum BlindTestStats {
    static let vowels = ["あ", "い", "う", "え", "お"]
    static let chance = 0.2

    static func answered(_ trials: [BlindTrial]) -> [BlindTrial] { trials.filter { $0.answer != nil } }

    static func accuracy(_ trials: [BlindTrial]) -> Double? {
        let a = answered(trials)
        guard !a.isEmpty else { return nil }
        return Double(a.filter { $0.answer == $0.target }.count) / Double(a.count)
    }

    /// rows: target, columns: answer
    static func confusion(_ trials: [BlindTrial]) -> [[Int]] {
        var m = Array(repeating: Array(repeating: 0, count: vowels.count), count: vowels.count)
        for t in answered(trials) {
            if let r = vowels.firstIndex(of: t.target), let c = vowels.firstIndex(of: t.answer!) { m[r][c] += 1 }
        }
        return m
    }

    /// One-sided exact binomial p-value P(X >= k | n, p = 0.2).
    static func pValue(correct k: Int, trials n: Int, p: Double = chance) -> Double {
        guard n > 0, k > 0 else { return 1 }
        var total = 0.0
        for i in k...n { total += exp(logChoose(n, i) + Double(i) * log(p) + Double(n - i) * log(1 - p)) }
        return min(1, total)
    }

    private static func logChoose(_ n: Int, _ k: Int) -> Double { lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1)) }
}

/// Everything written to `experiment_results.json` in the app's Documents folder.
struct ExperimentExport: Codable {
    var schema = "haptic-voice-engine/experiment-results/v1"
    var exportedAt: String
    var app: String
    var device: String
    var os: String
    var capabilities: [String: Bool]
    var playsHapticsOnly: Bool
    var physicalVibrationConfirmed: Bool?
    var records: [ExperimentRecord]
    var blindTrials: [BlindTrial]
    var engineLog: [String]
}
