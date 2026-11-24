import HapticVoiceKit
import SwiftUI

@main
struct HapticVoiceEngineApp: App {
    @StateObject private var store: ExperimentStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let args = ProcessInfo.processInfo.arguments
        let simulated = args.contains("-uiTestingSimulatedHaptics")
        let backend: HapticBackend = simulated ? SimulatedHapticBackend() : CoreHapticsBackend()
        let controller = HapticEngineController(backend: backend)
        if args.contains("-uiTestingShortCooldown") { controller.governor.cooldown = 0.5 }
        if let i = args.firstIndex(of: "-uiTestingCooldown"), i + 1 < args.count, let s = Double(args[i + 1]) {
            controller.governor.cooldown = s
        }
        let isUITest = args.contains { $0.hasPrefix("-uiTesting") }
        let store = ExperimentStore(controller: controller, persist: !isUITest)
        _store = StateObject(wrappedValue: store)
        if args.contains("-uiTestingAudioFixture") { Self.loadFixture(into: store) }
    }

    /// UI tests cannot drive the system file picker, so they load a generated 150 Hz WAV through the same loader.
    private static func loadFixture(into store: ExperimentStore) {
        let sr = 22050.0
        let samples = (0..<Int(sr)).map { i -> Float in
            let t = Double(i) / sr
            return Float(0.3 * (1...5).reduce(0.0) { $0 + sin(2 * .pi * 150 * Double($1) * t) / Double($1) })
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-150Hz.wav")
        guard (try? AudioFileLoader.writeWAV(samples, sampleRate: sr, to: url)) != nil else { return }
        Task { await store.loadAudioFile(url) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, controller: store.controller)
                .onAppear { store.controller.startEngine() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                if phase == .background || store.controller.isPlaying { store.stopAll(reason: "app left foreground") }
                if phase == .background { store.controller.enterBackground() }
            case .active:
                if !store.controller.engineReady { store.controller.startEngine() }
            @unknown default: break
            }
        }
    }
}
