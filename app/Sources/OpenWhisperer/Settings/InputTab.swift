import SwiftUI
import OpenWhispererKit

struct InputTab: View {
    @EnvironmentObject var dictationManager: DictationManager
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    @State private var selectedMode: InteractionMode = .holdToTalk
    @State private var selectedPTTKey = "ctrl"
    @State private var silenceThreshold = 3
    @State private var pttKeyChanged = false
    @State private var selectedLanguage = "en"
    @State private var vocabularyText = ""
    @State private var vocabularySaveWork: DispatchWorkItem?
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var autoFocusReturn = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"  // visual default; only written on explicit toggle
    @State private var customFocusApp = ""
    @State private var installedApps: [AppEntry] = []
    @State private var saveDebounce: DispatchWorkItem?
    @State private var loaded = false

    private static let languages: [(id: String, label: String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"),
        ("hi", "Hindi"), ("ru", "Russian"), ("pl", "Polish"), ("tr", "Turkish"),
        ("uk", "Ukrainian"), ("sv", "Swedish"),
    ]

    private static let focusApps: [(id: String, label: String)] = [
        ("Code", "VS Code"), ("Code - Insiders", "VS Code Insiders"),
        ("Cursor", "Cursor (AI Editor)"), ("Windsurf", "Windsurf (AI Editor)"),
        ("Zed", "Zed (Editor)"), ("Xcode", "Xcode (Apple IDE)"),
        ("Sublime Text", "Sublime Text (Editor)"), ("Nova", "Nova (Panic)"),
        ("Fleet", "Fleet (JetBrains)"), ("Claude", "Claude (Desktop)"),
        ("Terminal", "Terminal (macOS)"), ("iTerm2", "iTerm2 (Terminal)"),
        ("Warp", "Warp (Terminal)"), ("Alacritty", "Alacritty (Terminal)"),
        ("Ghostty", "Ghostty (Terminal)"),
    ]

    var body: some View {
        Form {
            dictationSection
            languageSection
            appFocusSection
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onDisappear {
            // Flush a pending vocabulary debounce so a quick tab switch can't lose edits.
            if let work = vocabularySaveWork, !work.isCancelled {
                work.cancel()
                saveVocabulary(vocabularyText)
            }
        }
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Section {
            Picker("Mode", selection: $selectedMode) {
                ForEach(InteractionMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .onChange(of: selectedMode) { _, newValue in
                guard loaded else { return }
                newValue.save()
                dictationManager.interactionMode = newValue
            }

            if selectedMode != .handsFree {
                Picker("Key", selection: $selectedPTTKey) {
                    ForEach(PTTKey.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: selectedPTTKey) { _, newValue in
                    guard loaded else { return }
                    try? newValue.write(to: Paths.pttHotkey, atomically: true, encoding: .utf8)
                    if let key = PTTKey(rawValue: newValue) {
                        TranscriptionOverlay.shared.pttKeyLabel = key.label
                    }
                    pttKeyChanged = true
                }
            } else {
                Picker("Auto-submit after silence", selection: $silenceThreshold) {
                    ForEach([3, 4, 5, 7, 10, 20], id: \.self) { Text("\($0) s").tag($0) }
                }
                .onChange(of: silenceThreshold) { _, newValue in
                    guard loaded else { return }
                    try? String(newValue).write(to: Paths.silenceThreshold, atomically: true, encoding: .utf8)
                    dictationManager.recorder.silenceThresholdSeconds = TimeInterval(newValue)
                }
            }

            Toggle("Show transcription overlay", isOn: Binding(
                get: { overlay.isVisible },
                set: { $0 ? overlay.show() : overlay.hide() }
            ))

            if !dictationManager.recorder.micPermission {
                Button("Grant Microphone Access…") { dictationManager.recorder.openMicSettings() }
                Text("Required for built-in dictation").font(.caption).foregroundStyle(.orange)
            } else {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(stateColor).frame(width: 8, height: 8)
                        Text(stateLabel).foregroundStyle(.secondary)
                    }
                }
                if selectedMode == .handsFree, dictationManager.isCalibrating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Calibrating microphone...").font(.caption).foregroundStyle(.orange)
                    }
                }
                if selectedMode == .handsFree, dictationManager.ttsPlaying {
                    Text("say \"hold on\" to interrupt playback").font(.caption).foregroundStyle(.secondary)
                }
            }

            if pttKeyChanged {
                Label("Restart the app to apply the new hotkey", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let err = dictationManager.error {
                Label(err, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text(selectedMode.description)
        }
    }

    // MARK: Language & Vocabulary

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $selectedLanguage) {
                ForEach(Self.languages, id: \.id) { Text($0.label).tag($0.id) }
            }
            .onChange(of: selectedLanguage) { _, newValue in
                guard loaded else { return }
                if newValue == "auto" {
                    try? FileManager.default.removeItem(at: Paths.sttLanguage)
                } else {
                    try? newValue.write(to: Paths.sttLanguage, atomically: true, encoding: .utf8)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Vocabulary")
                    Spacer()
                    Text("one term per line").font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: $vocabularyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .overlay(alignment: .topLeading) {
                        if vocabularyText.isEmpty {
                            Text("WhisperKit\nCodex CLI\nKokoro")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: vocabularyText) { _, newValue in
                        guard loaded else { return }
                        vocabularySaveWork?.cancel()
                        let work = DispatchWorkItem { saveVocabulary(newValue) }
                        vocabularySaveWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                    }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Biases dictation toward these spellings — product names, CLI jargon, APIs. Keep it to a dozen or two.")
        }
    }

    // MARK: App Focus

    private var appFocusSection: some View {
        Section {
            Toggle("Focus a target app", isOn: $autoFocusEnabled)
                .onChange(of: autoFocusEnabled) { _, enabled in
                    guard loaded else { return }
                    if enabled {
                        if focusAppName.isEmpty {
                            focusAppName = focusSelection == "CUSTOM" ? customFocusApp : focusSelection
                        }
                        saveFocusApp()
                    } else {
                        try? FileManager.default.removeItem(at: Paths.autoFocusApp)
                    }
                }

            if autoFocusEnabled {
                Picker("Target app", selection: $focusSelection) {
                    Section("Favorites") {
                        ForEach(Self.focusApps, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Section("Installed") {
                        ForEach(installedApps, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                    }
                    Text("Custom…").tag("CUSTOM")
                }
                .onChange(of: focusSelection) { _, id in
                    guard loaded else { return }
                    if id == "CUSTOM" {
                        focusAppName = customFocusApp
                    } else if installedApps.contains(where: { $0.bundleID == id }) {
                        focusAppName = FocusTarget.tag(bundleID: id)
                    } else {
                        focusAppName = id
                    }
                    saveFocusApp()
                }

                if focusSelection == "CUSTOM" {
                    TextField("App name", text: $customFocusApp)
                        .onChange(of: customFocusApp) { _, newValue in
                            guard loaded, !newValue.isEmpty else { return }
                            focusAppName = newValue
                            debouncedSaveFocusApp()
                        }
                }

                Toggle("Return to previous app", isOn: $autoFocusReturn)
                    .onChange(of: autoFocusReturn) { _, enabled in
                        guard loaded else { return }
                        if enabled {
                            try? "on".write(to: Paths.autoFocusReturn, atomically: true, encoding: .utf8)
                        } else {
                            try? FileManager.default.removeItem(at: Paths.autoFocusReturn)
                        }
                    }
            }

            Toggle("Press Enter after inserting", isOn: $autoSubmit)
                .onChange(of: autoSubmit) { _, enabled in
                    guard loaded else { return }
                    if enabled {
                        try? "on".write(to: Paths.autoSubmitFlag, atomically: true, encoding: .utf8)
                    } else {
                        try? FileManager.default.removeItem(at: Paths.autoSubmitFlag)
                    }
                }
        } header: {
            Text("App Focus")
        } footer: {
            if let hint = automationHint { Text(hint) }
        }
    }

    private var automationHint: String? {
        if autoFocusEnabled {
            var steps = ["focus target app", "insert text"]
            if autoSubmit { steps.append("press enter") }
            if autoFocusReturn { steps.append("return to previous") }
            return steps.joined(separator: ", ")
        }
        if autoSubmit { return "enter is auto-applied after text insertion" }
        return nil
    }

    private var stateColor: Color {
        switch dictationManager.recorderState {
        case .recording: return .red
        case .uploading: return .orange
        case .listening: return .green
        case .idle: return dictationManager.ttsPlaying ? .blue : .green
        }
    }

    private var stateLabel: String {
        if dictationManager.isCalibrating { return "Calibrating..." }
        if dictationManager.ttsPlaying { return "Playing..." }
        switch dictationManager.recorderState {
        case .recording: return "Recording..."
        case .uploading: return "Transcribing..."
        case .listening: return "Listening..."
        case .idle: return dictationManager.speakArmed ? "Standby · will speak" : "Standby"
        }
    }

    // MARK: Persistence (verbatim from the legacy view)

    private func load() {
        selectedMode = InteractionMode.load()
        if let savedKey = try? String(contentsOf: Paths.pttHotkey, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let key = PTTKey(rawValue: savedKey) {
            selectedPTTKey = savedKey
            TranscriptionOverlay.shared.pttKeyLabel = key.label
        }
        if let savedStr = try? String(contentsOf: Paths.silenceThreshold, encoding: .utf8),
           let saved = Int(savedStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            silenceThreshold = saved
        }
        if let savedLang = try? String(contentsOf: Paths.sttLanguage, encoding: .utf8),
           !savedLang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lang = savedLang.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.languages.contains(where: { $0.id == lang }) { selectedLanguage = lang }
        }
        vocabularyText = (try? String(contentsOf: Paths.sttVocabulary, encoding: .utf8)) ?? ""
        autoSubmit = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
        autoFocusEnabled = FileManager.default.fileExists(atPath: Paths.autoFocusApp.path)
        autoFocusReturn = FileManager.default.fileExists(atPath: Paths.autoFocusReturn.path)
        if installedApps.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = InstalledApps.all()
                DispatchQueue.main.async { installedApps = apps }
            }
        }
        if let saved = try? String(contentsOf: Paths.autoFocusApp, encoding: .utf8),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            focusAppName = value
            switch FocusTarget.parse(value) {
            case .bundleID(let bid):
                focusSelection = bid
            case .name(let name):
                if Self.focusApps.contains(where: { $0.id == name }) {
                    focusSelection = name
                } else {
                    focusSelection = "CUSTOM"
                    customFocusApp = name
                }
            }
        }
        dictationManager.recorder.checkPermission()
        // Defer the loaded flag one runloop so the initial @State assignments above
        // can't fire the persistence onChange handlers.
        DispatchQueue.main.async { loaded = true }
    }

    private func saveVocabulary(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: Paths.sttVocabulary)
        } else {
            try? text.write(to: Paths.sttVocabulary, atomically: true, encoding: .utf8)
        }
    }

    private func saveFocusApp() {
        guard autoFocusEnabled, !focusAppName.isEmpty else { return }
        try? focusAppName.write(to: Paths.autoFocusApp, atomically: true, encoding: .utf8)
        // Owner-only — the target app name is read by the local server (T2.5)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.autoFocusApp.path)
    }

    private func debouncedSaveFocusApp() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { saveFocusApp() }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
