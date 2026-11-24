import SwiftUI

struct ContentView: View {
    @ObservedObject var store: ExperimentStore
    @ObservedObject var controller: HapticEngineController

    @State private var intensity: Double = 0.8
    @State private var sharpness: Double = 0.5
    @State private var duration: Double = 1.0
    @State private var modulation: ModulationRate = .none
    @State private var method: SpeechMappingMethod = .envelope
    @State private var customText = ""
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hardwareSection
                    manualSection
                    presetSection
                    speechSection
                    matrixSection
                    blindSection
                    recordsSection
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Header with always-visible STOP

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text("HAPTIC VOICE ENGINE")
                    .font(.system(.headline, design: .monospaced)).bold()
                    .accessibilityIdentifier("title")
                Spacer()
                Button(role: .destructive) { store.stopAll() } label: {
                    Text("STOP").font(.headline.bold()).frame(minWidth: 70, minHeight: 36)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .accessibilityIdentifier("stopButton")
            }
            HStack {
                Text(controller.playbackState.label)
                    .font(.caption.monospaced()).lineLimit(2)
                    .accessibilityIdentifier("playbackState")
                Spacer()
                if controller.cooldownRemaining > 0 {
                    Text(String(format: "cooldown %.1fs", controller.cooldownRemaining))
                        .font(.caption.monospaced()).foregroundStyle(.orange)
                        .accessibilityIdentifier("cooldown")
                }
            }
            if let refusal = controller.lastRefusal {
                Text("Refused: \(refusal)")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("lastRefusal")
            }
            Text("Active method: \(store.activeMethod)")
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("activeMethod")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Hardware

    private var hardwareSection: some View {
        Card("Hardware Status") {
            if controller.capabilities.simulated {
                Text("SIMULATED BACKEND (UI testing) — no vibration is produced")
                    .font(.caption.bold()).foregroundStyle(.orange).accessibilityIdentifier("simulatedBanner")
            }
            StatusRow("Core Haptics supported", controller.capabilities.supportsHaptics ? "Yes" : "No", ok: controller.capabilities.supportsHaptics, id: "supportsHaptics")
            StatusRow("supportsAudio (unused)", controller.capabilities.supportsAudio ? "Yes" : "No", ok: nil, id: "supportsAudio")
            StatusRow("Engine ready", controller.engineStatus, ok: controller.engineReady, id: "engineStatus")
            StatusRow("Haptics-only mode", controller.playsHapticsOnly ? "playsHapticsOnly = true" : "Off", ok: controller.playsHapticsOnly, id: "hapticsOnly")
            StatusRow("Audio events used", "0 (haptic event types only)", ok: true, id: "audioEvents")
            StatusRow("Physical vibration", confirmationText, ok: store.physicalConfirmation.map { $0 == .felt }, id: "physicalConfirmation")
            StatusRow("Device", DeviceInfo.friendlyModel, ok: nil, id: "device")
            StatusRow("OS", DeviceInfo.systemVersion, ok: nil, id: "os")
            StatusRow("Session", "\(controller.governor.plays)/\(controller.governor.maxPlays) plays, cooldown \(String(format: "%.1f", controller.governor.cooldown))s", ok: nil, id: "session")
            HStack {
                Button("Restart engine") { controller.startEngine() }.accessibilityIdentifier("restartEngine")
                Spacer()
                Button("Reset session") { controller.resetSession() }.accessibilityIdentifier("resetSession")
            }.font(.caption)
            if let last = store.lastRecord, last.physicalConfirmation == nil, !controller.isPlaying {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Did you physically feel \"\(last.name)\"?").font(.caption.bold())
                    HStack {
                        Button("Felt vibration") { store.confirmLast(.felt) }
                            .buttonStyle(.bordered).accessibilityIdentifier("confirmFelt")
                        Button("Nothing felt") { store.confirmLast(.notFelt) }
                            .buttonStyle(.bordered).accessibilityIdentifier("confirmNotFelt")
                    }
                }
                .padding(8).background(Color.yellow.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("Engine events (\(controller.events.count))") {
                ForEach(Array(controller.events.prefix(30).enumerated()), id: \.offset) { _, e in
                    Text(e).font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.caption).accessibilityIdentifier("engineEvents")
        }
    }

    private var confirmationText: String {
        switch store.physicalConfirmation {
        case .felt: return controller.capabilities.simulated ? "Confirmed (simulated run)" : "Confirmed by user"
        case .notFelt: return "User reported nothing felt"
        case nil: return "Not confirmed"
        }
    }

    // MARK: Manual

    private var manualSection: some View {
        Card("Manual Control") {
            LabeledSlider("Intensity", value: $intensity, range: 0...1, format: "%.2f", id: "intensitySlider")
                .onChange(of: intensity) { _, v in controller.sendDynamic(intensity: Float(v), sharpness: nil) }
            LabeledSlider("Sharpness", value: $sharpness, range: 0...1, format: "%.2f", id: "sharpnessSlider")
                .onChange(of: sharpness) { _, v in controller.sendDynamic(intensity: nil, sharpness: Float(v)) }
            LabeledSlider("Duration (s)", value: $duration, range: 0.1...3.0, format: "%.1f", id: "durationSlider")
            Picker("Modulation rate (requested)", selection: $modulation) {
                ForEach(ModulationRate.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("modulationPicker")
            Text("Sharpness is not a frequency in Hz; requested modulation rates are not guaranteed to be reproduced.")
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                store.playManual(intensity: Float(intensity), sharpness: Float(sharpness), duration: duration, modulation: modulation)
            } label: { Text("Play").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .disabled(!canPlay)
                .accessibilityIdentifier("playManual")
        }
    }

    private var canPlay: Bool { controller.engineReady && !controller.isPlaying && !store.matrixRunning }

    // MARK: Presets

    private var presetSection: some View {
        Card("Preset Experiments") {
            EagerGrid(columns: 2, items: PatternLibrary.Preset.allCases) { preset in
                    Button(preset.rawValue) {
                        store.playPreset(preset, intensity: Float(intensity), sharpness: Float(sharpness), rate: modulation)
                    }
                    .buttonStyle(.bordered).font(.caption)
                    .frame(maxWidth: .infinity)
                    .disabled(!canPlay)
                    .accessibilityIdentifier("preset-\(preset.rawValue)")
            }
            Text("Presets use the manual intensity/sharpness; AM uses the selected rate (5 Hz if None).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Speech

    private var speechSection: some View {
        Card("Speech Experiments") {
            Picker("Method", selection: $method) {
                ForEach(SpeechMappingMethod.allCases) { Text($0.short).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("methodPicker")
            Text(method.explanation).font(.caption2).foregroundStyle(.secondary)
            EagerGrid(columns: 4, items: ["あ", "い", "う", "え", "お", "Hello", "AI"]) { word in
                    Button(word) { Task { await store.playSpeech(word, method: method) } }
                        .buttonStyle(.bordered)
                        .disabled(!canPlay || store.preparingSpeech)
                        .accessibilityIdentifier("speech-\(word)")
            }
            HStack {
                TextField("Custom text", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("customText")
                Button("Play") { Task { await store.playSpeech(customText, method: method) } }
                    .buttonStyle(.bordered)
                    .disabled(!canPlay || store.preparingSpeech)
                    .accessibilityIdentifier("speech-custom")
            }
            if store.preparingSpeech { ProgressView().frame(maxWidth: .infinity) }
            if !store.speechStatus.isEmpty {
                Text(store.speechStatus).font(.caption.monospaced()).accessibilityIdentifier("speechStatus")
            }
            Text("Speech is synthesized offline to PCM only. Outputs are experimental vibration patterns, not verified speech.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Experiment A / C

    private var matrixSection: some View {
        Card("Experiment A · Characterization (1 s each)") {
            Picker("Test surface (Experiment C)", selection: $store.material) {
                ForEach(TestMaterial.allCases) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("materialPicker")
            Text("Secure the phone so it cannot fall or slide. Keep the microphone off the phone.")
                .font(.caption2).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Text("I \\ S").font(.caption2)
                    ForEach(PatternLibrary.matrixSharpness, id: \.self) { Text(String(format: "%.2f", $0)).font(.caption2) }
                }
                ForEach(PatternLibrary.matrixIntensities, id: \.self) { i in
                    GridRow {
                        Text(String(format: "%.1f", i)).font(.caption2)
                        ForEach(PatternLibrary.matrixSharpness, id: \.self) { s in
                            let cell = PatternLibrary.MatrixCell(intensity: i, sharpness: s)
                            Button { store.playMatrixCell(cell) } label: {
                                Image(systemName: matrixDone(cell) ? "checkmark.circle.fill" : "play.circle")
                            }
                            .disabled(!canPlay)
                            .accessibilityIdentifier("matrix-\(cell.id)")
                        }
                    }
                }
            }
            HStack {
                Button(store.matrixRunning ? "Running…" : "Run full matrix once") { store.runMatrix() }
                    .buttonStyle(.bordered).disabled(!canPlay)
                    .accessibilityIdentifier("runMatrix")
                Spacer()
                Text(store.matrixProgress).font(.caption2.monospaced()).accessibilityIdentifier("matrixProgress")
            }
        }
    }

    private func matrixDone(_ cell: PatternLibrary.MatrixCell) -> Bool {
        store.records.contains { $0.category == "matrix" && $0.material == store.material && $0.status == "finished"
            && $0.requested["intensity"].map { abs($0 - Double(cell.intensity)) < 0.001 } == true
            && $0.requested["sharpness"].map { abs($0 - Double(cell.sharpness)) < 0.001 } == true }
    }

    // MARK: Blind test

    private var blindSection: some View {
        Card("Blind Listening Test (5 vowels, chance 20%)") {
            HStack {
                Text("Listener ID").font(.caption)
                TextField("listener", text: $store.listener).textFieldStyle(.roundedBorder).accessibilityIdentifier("listenerField")
            }
            if store.pendingBlindTrial != nil {
                Text("Which vowel was it?").font(.caption.bold())
                HStack {
                    ForEach(BlindTestStats.vowels, id: \.self) { v in
                        Button(v) { store.answerBlindTrial(v) }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("answer-\(v)")
                    }
                }
                Button("Discard trial") { store.discardBlindTrial() }.font(.caption).accessibilityIdentifier("discardTrial")
            } else {
                Button("Play random hidden vowel (\(method.short))") { Task { await store.startBlindTrial(method: method) } }
                    .buttonStyle(.bordered).disabled(!canPlay || store.preparingSpeech)
                    .accessibilityIdentifier("startBlind")
            }
            let trials = store.blindTrials.filter { $0.method == method }
            let correct = trials.filter { $0.answer == $0.target }.count
            let acc = BlindTestStats.accuracy(trials)
            Text("\(method.short): \(trials.count) trials, \(correct) correct" + (acc.map { String(format: ", accuracy %.0f%%, p=%.3f vs 20%%", $0 * 100, BlindTestStats.pValue(correct: correct, trials: trials.count)) } ?? ""))
                .font(.caption.monospaced()).accessibilityIdentifier("blindSummary")
            ConfusionMatrixView(matrix: BlindTestStats.confusion(trials))
            Text("This measures recognition of vibration patterns. It is not evidence of speech intelligibility (Level 5).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Records

    private var recordsSection: some View {
        Card("Results (\(store.records.count))") {
            HStack {
                if let url = store.lastExportURL {
                    ShareLink(item: url) { Label("Share JSON", systemImage: "square.and.arrow.up") }
                }
                Spacer()
                Button("Export experiment_results.json") { _ = store.export() }.accessibilityIdentifier("exportButton")
            }.font(.caption)
            ForEach(store.records.prefix(15)) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(r.id) · \(r.status)").font(.caption.monospaced().bold())
                    Text(r.name).font(.caption)
                    Text(String(format: "%@ · %@ · %.2fs measured", r.method, r.material.rawValue, r.measuredPlaybackSeconds ?? 0)
                         + (r.physicalConfirmation.map { " · \($0.rawValue)" } ?? "") + (r.simulated ? " · SIMULATED" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("record-\(r.category)")
                Divider()
            }
            Button("Clear all results", role: .destructive) { store.clearAll() }.font(.caption)
        }
    }
}

// MARK: Components

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct StatusRow: View {
    let label: String, value: String, ok: Bool?, id: String
    init(_ label: String, _ value: String, ok: Bool?, id: String) { self.label = label; self.value = value; self.ok = ok; self.id = id }

    var body: some View {
        HStack(alignment: .top) {
            Circle().fill(ok == nil ? Color.gray : (ok! ? Color.green : Color.red)).frame(width: 8, height: 8).padding(.top, 5)
            Text(label).font(.caption)
            Spacer()
            Text(value).font(.caption.monospaced()).multilineTextAlignment(.trailing).accessibilityIdentifier(id)
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let id: String
    init(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, id: String) {
        self.label = label; _value = value; self.range = range; self.format = format; self.id = id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(label).font(.caption); Spacer(); Text(String(format: format, value)).font(.caption.monospaced()) }
            Slider(value: $value, in: range).accessibilityIdentifier(id)
        }
    }
}

struct ConfusionMatrixView: View {
    let matrix: [[Int]]
    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 2) {
            GridRow {
                Text("target\\ans").font(.system(size: 9))
                ForEach(BlindTestStats.vowels, id: \.self) { Text($0).font(.caption2) }
            }
            ForEach(Array(BlindTestStats.vowels.enumerated()), id: \.offset) { r, v in
                GridRow {
                    Text(v).font(.caption2)
                    ForEach(0..<BlindTestStats.vowels.count, id: \.self) { c in
                        Text("\(matrix[r][c])").font(.caption2.monospaced())
                            .foregroundStyle(r == c ? Color.green : Color.primary)
                    }
                }
            }
        }
        .accessibilityIdentifier("confusionMatrix")
    }
}

/// Non-lazy grid so every control stays in the accessibility tree (LazyVGrid drops off-screen items).
struct EagerGrid<Item: Hashable, Content: View>: View {
    let columns: Int
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)], id: \.self) { content($0) }
                }
            }
        }
    }
}
