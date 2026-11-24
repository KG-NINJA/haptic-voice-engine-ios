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
        _store = StateObject(wrappedValue: ExperimentStore(controller: controller, persist: !isUITest))
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
