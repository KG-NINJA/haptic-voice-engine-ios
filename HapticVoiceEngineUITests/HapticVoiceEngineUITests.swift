import XCTest

final class HapticVoiceEngineUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(simulated: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (simulated ? ["-uiTestingSimulatedHaptics", "-uiTestingShortCooldown"] : ["-uiTestingRealBackend"]) + extra
        app.launch()
        return app
    }

    private func label(_ app: XCUIApplication, _ id: String) -> String { app.staticTexts[id].label }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false) {
        var n = 0
        while !element.isHittable && n < 15 { up ? app.swipeDown() : app.swipeUp(); n += 1 }
    }

    /// On the Simulator Core Haptics is unavailable; the app must report that honestly and refuse to play.
    func testRealBackendReportsUnsupportedHardwareOnSimulator() {
        let app = launch(simulated: false)
        XCTAssertTrue(app.staticTexts["title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["title"].label, "HAPTIC VOICE ENGINE")
        XCTAssertEqual(label(app, "supportsHaptics"), "No")
        XCTAssertEqual(label(app, "engineStatus"), "Unsupported hardware")
        XCTAssertEqual(label(app, "physicalConfirmation"), "Not confirmed")
        XCTAssertFalse(app.staticTexts["simulatedBanner"].exists)
        XCTAssertFalse(app.buttons["playManual"].isEnabled)
    }

    func testStatusPlaybackStopAndPhysicalConfirmation() {
        let app = launch(extra: ["-uiTestingCooldown", "4"])
        XCTAssertTrue(app.staticTexts["simulatedBanner"].waitForExistence(timeout: 10))
        XCTAssertEqual(label(app, "engineStatus"), "Running (SIMULATED)")
        XCTAssertEqual(label(app, "hapticsOnly"), "playsHapticsOnly = true")

        app.sliders["durationSlider"].adjust(toNormalizedSliderPosition: 1.0)
        let play = app.buttons["playManual"]
        scrollTo(play, in: app)
        play.tap()
        XCTAssertTrue(label(app, "playbackState").hasPrefix("Playing: Manual"))
        XCTAssertEqual(label(app, "activeMethod"), "Active method: Manual control")
        app.buttons["stopButton"].tap()
        XCTAssertEqual(label(app, "playbackState"), "Stopped: user STOP")
        XCTAssertTrue(app.staticTexts["cooldown"].waitForExistence(timeout: 2))
        play.tap()
        XCTAssertTrue(app.staticTexts["lastRefusal"].waitForLabel(containing: "Cooldown", timeout: 2))

        scrollTo(app.buttons["confirmFelt"], in: app, up: true)
        app.buttons["confirmFelt"].tap()
        XCTAssertEqual(label(app, "physicalConfirmation"), "Confirmed (simulated run)")
    }

    func testPresetFinishesAndIsRecorded() {
        let app = launch()
        let pulse = app.buttons["preset-Single pulse"]
        XCTAssertTrue(pulse.waitForExistence(timeout: 10))
        scrollTo(pulse, in: app)
        pulse.tap()
        XCTAssertTrue(app.staticTexts["playbackState"].waitForLabel("Finished: Single pulse", timeout: 3))
        XCTAssertEqual(label(app, "activeMethod"), "Active method: Preset: Single pulse")
        let exportButton = app.buttons["exportButton"]
        scrollTo(exportButton, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["record-preset"].firstMatch.waitForExistence(timeout: 2))
    }

    func testMatrixCellRunsWithSelectedMaterial() {
        let app = launch()
        let cell = app.buttons["matrix-I0.60-S0.25"]
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        scrollTo(cell, in: app)
        cell.tap()
        XCTAssertTrue(app.staticTexts["playbackState"].waitForLabel("Finished: Matrix I0.60-S0.25", timeout: 4))
        XCTAssertEqual(label(app, "activeMethod"), "Active method: Experiment A: characterization matrix")
    }

    func testSpeechVowelEnvelopeMapping() {
        let app = launch()
        let a = app.buttons["speech-あ"]
        XCTAssertTrue(a.waitForExistence(timeout: 10))
        scrollTo(a, in: app)
        a.tap()
        let status = app.staticTexts["speechStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["playbackState"].waitForLabel(containing: "(experimental)", timeout: 30), label(app, "playbackState"))
        XCTAssertFalse(label(app, "playbackState").localizedCaseInsensitiveContains("reproduced"))
        XCTAssertEqual(label(app, "activeMethod"), "Active method: Method 4: Simple voice (pitch pulse train)")
    }

    func testBlindTrialHidesTargetAndRecordsAnswer() {
        let app = launch()
        let start = app.buttons["startBlind"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        scrollTo(start, in: app)
        start.tap()
        let answer = app.buttons["answer-う"]
        XCTAssertTrue(answer.waitForExistence(timeout: 40))
        XCTAssertFalse(label(app, "playbackState").contains("あ") || label(app, "playbackState").contains("い"), "target must stay hidden")
        answer.tap()
        XCTAssertTrue(app.staticTexts["blindSummary"].waitForLabel(containing: "Simple voice: 1 trials", timeout: 3), label(app, "blindSummary"))
    }
}

extension XCUIElement {
    func waitForLabel(_ expected: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: self)], timeout: timeout) == .completed
    }

    func waitForLabel(containing expected: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: self)], timeout: timeout) == .completed
    }
}
