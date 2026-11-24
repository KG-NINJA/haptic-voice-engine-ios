import Foundation

/// Enforces the safety rules: max duration, cooldown between plays, bounded sessions and thermal stop.
struct SafetyGovernor {
    var cooldown: Double = HapticLimits.defaultCooldown
    var maxPlays: Int = HapticLimits.maxPlaysPerSession
    var maxSessionLength: TimeInterval = HapticLimits.maxSessionLength
    private(set) var plays = 0
    private(set) var sessionStart: Date?
    private(set) var lastPlayEnd: Date?

    func remainingCooldown(now: Date = Date()) -> Double {
        guard let lastPlayEnd else { return 0 }
        return max(0, cooldown - now.timeIntervalSince(lastPlayEnd))
    }

    func check(now: Date = Date(), thermal: ProcessInfo.ThermalState) throws {
        if thermal == .serious || thermal == .critical { throw HapticError.thermal }
        if plays >= maxPlays { throw HapticError.sessionExhausted }
        if let sessionStart, now.timeIntervalSince(sessionStart) > maxSessionLength { throw HapticError.sessionExhausted }
        let wait = remainingCooldown(now: now)
        if wait > 0 { throw HapticError.cooldown(wait) }
    }

    mutating func recordStart(now: Date = Date()) {
        if sessionStart == nil { sessionStart = now }
        plays += 1
    }

    mutating func recordEnd(now: Date = Date()) { lastPlayEnd = now }

    mutating func resetSession() {
        plays = 0
        sessionStart = nil
        lastPlayEnd = nil
    }
}
