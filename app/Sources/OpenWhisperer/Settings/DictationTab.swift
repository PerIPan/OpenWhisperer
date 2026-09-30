import SwiftUI
import OpenWhispererKit

/// The whole speech→typed-text pipeline: trigger, live feedback, overlay, language,
/// vocabulary, and where the text lands.
struct DictationTab: View {
    @EnvironmentObject var dictationManager: DictationManager
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    // How you talk
    @State private var selectedMode: InteractionMode = .holdToTalk
    @State private var selectedPTTKey = "ctrl"
    @State private var silenceThreshold: Int = 3
    @State private var pttKeyChanged = false
    @State private var overlayStyle: OverlayStyle = .defaultStyle

    // Language & vocabulary
    @State private var selectedLanguage = "en"
    @State private var vocabulary = ""

    // App focus
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var autoFocusReturn = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"   // visual default; only written on explicit toggle
    @State private var customFocusApp = ""
    @State private var installedApps: [AppEntry] = []
    @State private var saveDebounce: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            howYouTalkCard
            languageCard
            appFocusCard
        }
        .onAppear(perform: load)
    }

    // MARK: - How you talk

    private var howYouTalkCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "How you talk", icon: "mic.fill",
                             help: "How you start dictation — Press-to-Talk, Hold-to-Talk, or Hands-Free — plus the trigger key and how the app listens.")

                OWPickerRow(label: "Mode", labelWidth: 74) {
                    OWMenuPicker(selection: $selectedMode,
                                 options: InteractionMode.allCases.map { (id: $0, label: $0.label) })
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedMode) { _, newValue in
                    newValue.save()
                    dictationManager.interactionMode = newValue
                }

                Text(selectedMode.description)
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                OWInternalDivider()

                // Contextual permission mirror: the canonical list lives in General, but a
                // missing mic blocks dictation entirely, so surface it right here too.
                if !dictationManager.recorder.micPermission {
                    Button(action: { dictationManager.recorder.openMicSettings() }) {
                        Label("Grant Microphone Access", systemImage: "mic.slash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(OWRowButtonStyle())
                    Text("Required for built-in dictation")
                        .font(OWFont.caption())
                        .foregroundColor(OWColor.warn)
                } else {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(stateColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: stateColor.opacity(0.5), radius: stateGlows ? 3 : 0)
                            .frame(width: 16)
                        Text(stateLabel)
                            .font(OWFont.body(11))
                            .foregroundColor(OWColor.ink)
                        Spacer()
                        if selectedMode != .handsFree {
                            OWMenuPicker(selection: $selectedPTTKey,
                                         options: PTTKey.allCases.map { (id: $0.rawValue, label: $0.label) })
                                .frame(width: 90)
                        }
                    }
                    .onChange(of: selectedPTTKey) { _, newValue in
                        try? newValue.write(to: Paths.pttHotkey, atomically: true, encoding: .utf8)
                        if let key = PTTKey(rawValue: newValue) {
                            TranscriptionOverlay.shared.pttKeyLabel = key.label
                        }
                        pttKeyChanged = true
                    }

                    if selectedMode == .handsFree {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.slash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text("Silence").font(OWFont.body(11))
                            Spacer()
                            OWMenuPicker(selection: $silenceThreshold,
                                         options: [3, 4, 5, 7, 10, 20].map { (id: $0, label: "\($0)s") })
                                .frame(width: 90)
                                .onChange(of: silenceThreshold) { _, newValue in
                                    try? String(newValue).write(to: Paths.silenceThreshold, atomically: true, encoding: .utf8)
                                    dictationManager.recorder.silenceThresholdSeconds = TimeInterval(newValue)
                                }
                        }

                        if !dictationManager.keywordDetector.permissionGranted {
                            Text("Hands-Free needs Speech Recognition — grant it in General.")
                                .font(OWFont.caption())
                                .foregroundColor(OWColor.warn)
                        }
                        if dictationManager.isCalibrating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Calibrating microphone…")
                                    .font(OWFont.caption())
                                    .foregroundColor(OWColor.warn)
                            }
                        }
                        if dictationManager.ttsPlaying {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(OWColor.accentDeep)
                                Text("Say \"hold on\" to interrupt the reply")
                                    .font(OWFont.caption())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // One control: OFF, or pick a style (which also shows the overlay).
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundColor(overlay.isVisible ? OWColor.live : OWColor.inkFaint)
                        .frame(width: 16)
                    Text("Overlay").font(OWFont.body(11))
                    Spacer()
                    OWMenuPicker(
                        selection: Binding(
                            get: { overlay.isVisible ? overlayStyle.rawValue : "off" },
                            set: { newValue in
                                if newValue == "off" {
                                    overlay.hide()
                                } else {
                                    let style = OverlayStyle.parse(newValue)
                                    overlayStyle = style
                                    try? style.rawValue.write(to: Paths.overlayStyle, atomically: true, encoding: .utf8)
                                    TranscriptionOverlay.shared.analyzerStyle = style
                                    overlay.show()
                                }
                            }
                        ),
                        options: [
                            (id: "off", label: "Off"),
                            (id: OverlayStyle.wave.rawValue, label: "Wave"),
                            (id: OverlayStyle.ledBars.rawValue, label: "LED Bars"),
                            (id: OverlayStyle.graph.rawValue, label: "Graph"),
                            (id: OverlayStyle.curtain.rawValue, label: "Curtain"),
                        ]
                    )
                    .frame(width: 110)
                }

                if pttKeyChanged {
                    InlineBadge(text: "Restart app to apply new hotkey", color: OWColor.warn)
                }
                if let err = dictationManager.error {
                    InlineBadge(text: err, color: OWColor.danger)
                }
            }
        }
    }

    // MARK: - Language & vocabulary

    private var languageCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "Language & vocabulary", icon: "character.book.closed",
                             help: "The language you dictate in, and a glossary of your own terms that transcripts are fuzzy-corrected against.")

                OWPickerRow(label: "Language", labelWidth: 74) {
                    OWSearchablePicker(
                        selection: $selectedLanguage,
                        sections: SettingsData.languageSections,
                        placeholder: "Search languages…",
                        emptyLabel: "Auto-detect"
                    )
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    // Auto-detect writes the literal sentinel rather than deleting the file.
                    // Deleting it used to mean "detect", but an absent file now means "never
                    // chose" and `migrateDefaultSTTLanguage()` fills it with `en` on the next
                    // launch — so removing it here would silently undo the user's choice.
                    try? newValue.write(to: Paths.sttLanguage, atomically: true, encoding: .utf8)
                }

                // "Translate to English" is NOT here: it swaps the whole speech model, so it
                // lives with the model rows in Settings → Advanced. While it is on, the
                // Language picker above is overridden (translate mode auto-detects) — hence
                // the note below rather than a silent contradiction between the two tabs.
                if dictationManager.translateToEnglish {
                    Text("Translating to English — the spoken language is detected automatically, so this setting is ignored. Turn it off in Advanced, or from the menubar menu.")
                        .font(OWFont.caption(11))
                        .foregroundColor(OWColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                OWInternalDivider()

                HStack(spacing: 8) {
                    Text("Custom vocabulary").font(OWFont.body(11))
                    Spacer()
                    let count = vocabulary.split(whereSeparator: \.isNewline)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                    if count > 0 {
                        Text("\(count) term\(count == 1 ? "" : "s")")
                            .font(OWFont.body(11))
                            .foregroundColor(OWColor.inkSoft)
                    }
                    Button("Edit…") { VocabularyWindow.show() }
                        .buttonStyle(OWRowButtonStyle())
                }
            }
        }
    }

    // MARK: - App Focus

    private var appFocusCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "App Focus", icon: "arrow.right.square",
                             help: "Optionally bring a target app to the front before inserting dictated text, press Enter for you, and hand focus back.")

                OWCheckbox(label: "Switch to a target app before typing", isOn: $autoFocusEnabled)
                    .onChange(of: autoFocusEnabled) { _, enabled in
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
                    OWInternalDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        OWAppPicker(
                            selection: $focusSelection,
                            favorites: SettingsData.focusApps.filter { $0.id != "CUSTOM" }
                                .map { AppEntry(bundleID: $0.id, name: $0.label) },
                            installed: installedApps
                        ) { id in
                            if id == "CUSTOM" {
                                focusAppName = customFocusApp
                            } else if installedApps.contains(where: { $0.bundleID == id }) {
                                focusAppName = FocusTarget.tag(bundleID: id)
                            } else {
                                focusAppName = id
                            }
                            saveFocusApp()
                        }
                        .frame(maxWidth: .infinity)

                        if focusSelection == "CUSTOM" {
                            OWTextField(placeholder: "App name", text: $customFocusApp)
                                .onChange(of: customFocusApp) { _, newValue in
                                    if !newValue.isEmpty {
                                        focusAppName = newValue
                                        debouncedSaveFocusApp()
                                    }
                                }
                        }

                        OWCheckbox(label: "Return to the previous app afterwards", isOn: $autoFocusReturn)
                            .onChange(of: autoFocusReturn) { _, enabled in
                                if enabled {
                                    try? "on".write(to: Paths.autoFocusReturn, atomically: true, encoding: .utf8)
                                } else {
                                    try? FileManager.default.removeItem(at: Paths.autoFocusReturn)
                                }
                            }
                    }
                }

                OWCheckbox(label: "Press Return after inserting text", isOn: $autoSubmit)
                    .onChange(of: autoSubmit) { _, enabled in
                        if enabled {
                            try? "on".write(to: Paths.autoSubmitFlag, atomically: true, encoding: .utf8)
                        } else {
                            do { try FileManager.default.removeItem(at: Paths.autoSubmitFlag) }
                            catch { NSLog("Failed to remove auto-submit flag: \(error)") }
                        }
                    }

                if let hint = automationHint {
                    Text(hint)
                        .font(OWFont.caption())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Helpers

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
        case .recording: return OWColor.recording
        case .uploading: return OWColor.warn
        case .listening: return OWColor.live
        case .idle: return dictationManager.ttsPlaying ? OWColor.accentDeep : OWColor.live
        }
    }

    private var stateGlows: Bool {
        switch dictationManager.recorderState {
        case .recording, .listening: return true
        case .uploading: return false
        case .idle: return !dictationManager.ttsPlaying
        }
    }

    private var stateLabel: String {
        if dictationManager.isCalibrating { return "Calibrating…" }
        if dictationManager.ttsPlaying { return "Playing…" }
        switch dictationManager.recorderState {
        case .recording: return "Recording…"
        case .uploading: return "Transcribing…"
        case .listening: return "Listening…"
        case .idle: return dictationManager.speakArmed ? "Ready · next reply will be spoken" : "Ready"
        }
    }

    private func saveFocusApp() {
        guard autoFocusEnabled, !focusAppName.isEmpty else { return }
        try? focusAppName.write(to: Paths.autoFocusApp, atomically: true, encoding: .utf8)
        // Owner-only — the target app name is read by the local server.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.autoFocusApp.path)
    }

    private func debouncedSaveFocusApp() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { saveFocusApp() }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func load() {
        selectedMode = InteractionMode.load()
        // Re-read authorization so a grant made in System Settings appears without a
        // relaunch (the inline mic-grant button below depends on this being current).
        dictationManager.recorder.checkPermission()
        if selectedMode == .handsFree {
            dictationManager.keywordDetector.checkPermission()
        }
        overlayStyle = OverlayStyle.parse(try? String(contentsOf: Paths.overlayStyle, encoding: .utf8))
        vocabulary = (try? String(contentsOf: Paths.sttVocabulary, encoding: .utf8)) ?? ""
        autoSubmit = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
        autoFocusEnabled = FileManager.default.fileExists(atPath: Paths.autoFocusApp.path)
        autoFocusReturn = FileManager.default.fileExists(atPath: Paths.autoFocusReturn.path)

        if let savedStr = try? String(contentsOf: Paths.silenceThreshold, encoding: .utf8),
           let saved = Int(savedStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            silenceThreshold = saved
        }
        if let savedKey = try? String(contentsOf: Paths.pttHotkey, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let key = PTTKey(rawValue: savedKey) {
            selectedPTTKey = savedKey
            TranscriptionOverlay.shared.pttKeyLabel = key.label
        }
        if let savedLang = try? String(contentsOf: Paths.sttLanguage, encoding: .utf8),
           !savedLang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lang = savedLang.trimmingCharacters(in: .whitespacesAndNewlines)
            if SettingsData.languages.contains(where: { $0.id == lang }) { selectedLanguage = lang }
        }
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
                if SettingsData.focusApps.contains(where: { $0.id == name }) {
                    focusSelection = name
                } else {
                    focusSelection = "CUSTOM"
                    customFocusApp = name
                }
            }
        }
    }
}
