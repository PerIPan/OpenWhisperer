# Native Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the branded card-scroll settings window with a standard macOS Settings window — native toolbar tabs (General / Input / Voice / Agents / Advanced) + grouped forms.

**Architecture:** A SwiftUI `Settings` scene whose `TabView` renders native toolbar tabs; each tab is a `Form` + `.formStyle(.grouped)` in its own file under `Settings/`, keeping the existing load-on-appear / write-on-change flat-file persistence verbatim. `MenuBarView.swift` and its custom OW controls are deleted; `OWColor` moves to `Theme.swift` for the transcription overlay.

**Tech Stack:** Swift 5.9+/SwiftUI, macOS 14+, SwiftPM (Command Line Tools only — no XCTest; UI code is verified by `swift build` + the two executable test suites + manual launch).

**Spec:** `docs/superpowers/specs/2026-07-08-native-settings-window-design.md`

## Global Constraints

- Zero behavior change: identical flat-file writes/reads (`Paths.*`), identical debounce (0.5 s vocabulary + focus-app), identical `NSAlert` confirms.
- Slider bounds MUST stay equal to the pure-Kit clamps: Speed `0.7...1.5` (`TTSSpeed`), Volume `0.3...2.0` (`TTSVolume`).
- Port validity range `1024...65535`; port editable only while the server is stopped.
- No new dependencies, no `OpenWhispererKit` changes, no hook changes.
- System colors/fonts only in the new window (no `OWColor`/`OWFont` in `Settings/`).
- Every task ends with `cd app && swift build` succeeding ("Build complete!").
- Commits: Conventional Commits, ≤72-char subject, `Claude-Session:` trailer, no co-author lines.
- Renamed labels change UI text only — file names and written values never change.

---

### Task 1: Worktree + move `OWColor` to Theme.swift

**Files:**
- Modify: `app/Sources/OpenWhisperer/Theme.swift`
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift` (cut the `OWColor` enum only)

**Interfaces:**
- Produces: `OWColor` (unchanged API) now lives in `Theme.swift`; `TranscriptionOverlay` keeps compiling untouched.

- [ ] **Step 1: Create the worktree**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git worktree add .claude/worktrees/native-settings -b native-settings
cd .claude/worktrees/native-settings
```

- [ ] **Step 2: Move the enum**

Cut the whole `enum OWColor { … }` block (with its two comment lines above it) from `MenuBarView.swift` (starts at the `// Warm "Open Whisperer" palette` comment under `// MARK: - Design Tokens`) and paste it verbatim into `Theme.swift` after the `Color.ow` extension. Leave `enum OWFont` in `MenuBarView.swift` (it dies with the file in Task 8). Do not touch `OWWindowBackground` yet.

- [ ] **Step 3: Build**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(ui): move OWColor tokens to Theme.swift"
```

---

### Task 2: Settings scene + tab scaffolding

**Files:**
- Create: `app/Sources/OpenWhisperer/Settings/SettingsView.swift`
- Create: `app/Sources/OpenWhisperer/Settings/SettingsRows.swift`
- Create: `app/Sources/OpenWhisperer/Settings/GeneralTab.swift` (stub)
- Create: `app/Sources/OpenWhisperer/Settings/InputTab.swift` (stub)
- Create: `app/Sources/OpenWhisperer/Settings/VoiceTab.swift` (stub)
- Create: `app/Sources/OpenWhisperer/Settings/AgentsTab.swift` (stub)
- Create: `app/Sources/OpenWhisperer/Settings/AdvancedTab.swift` (stub)
- Modify: `app/Sources/OpenWhisperer/OpenWhispererApp.swift`

**Interfaces:**
- Consumes: `AppDelegate` env objects (`ServerManager`, `SetupManager`, `DictationManager`, `AccessibilityManager`).
- Produces: `SettingsView` (TabView shell), `PermissionRow`, `SettingsPortField` used by Tasks 3–7. Each stub tab is `struct <Name>Tab: View { var body: some View { Form { Text("…") }.formStyle(.grouped) } }` until its task fills it in.

- [ ] **Step 1: Write `SettingsView.swift`**

```swift
import SwiftUI

/// The standard macOS Settings window: native toolbar tabs, one grouped Form per tab.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            InputTab()
                .tabItem { Label("Input", systemImage: "mic") }
            VoiceTab()
                .tabItem { Label("Voice", systemImage: "speaker.wave.2") }
            AgentsTab()
                .tabItem { Label("Agents", systemImage: "wand.and.stars") }
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
    }
}
```

- [ ] **Step 2: Write `SettingsRows.swift`**

```swift
import SwiftUI

/// Permission status row: green check / red cross + an "Open Settings…" affordance.
struct PermissionRow: View {
    let label: String
    let granted: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open Settings…", action: action)
            }
        } label: {
            Label(label, systemImage: granted ? "checkmark" : "exclamationmark.triangle")
                .labelStyle(.titleOnly)
        }
        .help(help)
    }
}

/// Port editor with the legacy validity rules: accepts 1024–65535, red text while
/// out of range, and only ever writes a valid value back to the binding.
struct SettingsPortField: View {
    @Binding var port: Int
    var disabled: Bool
    @State private var text: String = ""

    private var isValid: Bool {
        guard let p = Int(text) else { return false }
        return p >= 1024 && p <= 65535
    }

    var body: some View {
        TextField("", text: $text)
            .frame(width: 70)
            .multilineTextAlignment(.trailing)
            .disabled(disabled)
            .foregroundStyle(isValid || text.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
            .onAppear { text = "\(port)" }
            .onChange(of: text) { _, newValue in
                if let p = Int(newValue), p >= 1024, p <= 65535 { port = p }
            }
            .onChange(of: port) { _, newPort in
                let s = "\(newPort)"
                if text != s { text = s }
            }
    }
}
```

- [ ] **Step 3: Write the five stub tabs** (one file each, e.g. `GeneralTab.swift`):

```swift
import SwiftUI

struct GeneralTab: View {
    var body: some View {
        Form { Text("General") }.formStyle(.grouped)
    }
}
```

(Repeat for `InputTab`, `VoiceTab`, `AgentsTab`, `AdvancedTab` with their names.)

- [ ] **Step 4: Swap the scene in `OpenWhispererApp.swift`**

Replace the `Window("OpenWhisperer Settings", id: "settings") { … }` scene and the `openWindow` button with:

```swift
struct OpenWhispererApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        registerBundledFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            SettingsMenuItems()
        } label: {
            MenuBarStatusIcon(dictation: appDelegate.dictationManager, server: appDelegate.serverManager)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.serverManager)
                .environmentObject(appDelegate.setupManager)
                .environmentObject(appDelegate.dictationManager)
                .environmentObject(appDelegate.accessibilityManager)
        }
        .windowResizability(.contentSize)
    }
}

/// Menubar menu content. `openSettings` + explicit activation — required for an
/// LSUIElement app so the Settings window actually comes forward.
private struct SettingsMenuItems: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings...") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit OpenWhisperer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
```

Delete the now-unused `@Environment(\.openWindow)` property. `MenuBarStatusIcon` stays unchanged.

- [ ] **Step 5: Build**

Run: `cd app && swift build`
Expected: `Build complete!` (MenuBarView is now dead code but still compiles.)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(ui): native Settings scene with tab scaffolding"
```

---

### Task 3: General tab

**Files:**
- Modify: `app/Sources/OpenWhisperer/Settings/GeneralTab.swift` (replace stub)

**Interfaces:**
- Consumes: `PermissionRow`; `SetupManager.state/.progress/.resetAndRerun`, `ServerManager.status/.startAll`, `DictationManager.sttModelReady/.sttFailed/.sttStatus/.retrySTT/.recorder/.keywordDetector`, `AccessibilityManager.isGranted`, `Diagnostics.copyToClipboard`, `InteractionMode.load()`, `SMAppService`.

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import ServiceManagement

struct GeneralTab: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @EnvironmentObject var dictationManager: DictationManager
    @EnvironmentObject var accessibilityManager: AccessibilityManager
    @State private var launchAtLogin = false
    @State private var launchAtLoginLoaded = false
    @State private var handsFree = false
    @State private var diagnosticsCopied = false

    var body: some View {
        Form {
            firstRunSection

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard launchAtLoginLoaded else { return }
                        let service = SMAppService.mainApp
                        do {
                            if enabled { try service.register() } else { try service.unregister() }
                        } catch {
                            NSLog("Login item toggle failed: \(error)")
                            DispatchQueue.main.async { launchAtLogin = service.status == .enabled }
                        }
                    }
            }

            Section("Permissions") {
                PermissionRow(
                    label: "Accessibility",
                    granted: accessibilityManager.isGranted,
                    help: "Lets the app type dictated text into the focused app via keystrokes — the clipboard is never touched."
                ) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                PermissionRow(
                    label: "Microphone",
                    granted: dictationManager.recorder.micPermission,
                    help: "Lets the app record your microphone to capture dictation."
                ) {
                    dictationManager.recorder.openMicSettings()
                }
                if handsFree {
                    PermissionRow(
                        label: "Speech Recognition",
                        granted: dictationManager.keywordDetector.permissionGranted,
                        help: "Hands-Free only: Apple Speech detects the wake words \"initiate\" and \"hold on\"."
                    ) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section {
                LabeledContent("Version",
                               value: "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            handsFree = InteractionMode.load() == .handsFree
            // SMAppService.mainApp.status is a synchronous XPC call that can block for
            // seconds — resolve off-main (legacy behavior), and gate the onChange so the
            // initial assignment can't unregister the service.
            DispatchQueue.global(qos: .userInitiated).async {
                let enabled = SMAppService.mainApp.status == .enabled
                DispatchQueue.main.async {
                    launchAtLogin = enabled
                    launchAtLoginLoaded = true
                }
            }
            dictationManager.recorder.checkPermission()
            if handsFree { dictationManager.keywordDetector.checkPermission() }
        }
    }

    /// First-run signals: setup progress/failure and model loading/failure. Replaces the
    /// old setup-progress card and model-loading banner. Invisible in steady state.
    @ViewBuilder
    private var firstRunSection: some View {
        if case .inProgress(let step) = setupManager.state {
            Section("Setting up") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step).foregroundStyle(.secondary)
                    ProgressView(value: setupManager.progress)
                }
            }
        } else if case .failed(let reason) = setupManager.state {
            Section("Setup failed") {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Retry Setup") {
                    setupManager.resetAndRerun { success in
                        guard success else { return }
                        DispatchQueue.main.async { serverManager.startAll() }
                    }
                }
            }
        }

        let sttLoading = !dictationManager.sttModelReady && !dictationManager.sttFailed
        let ttsLoading = serverManager.status == .starting
        if dictationManager.sttFailed {
            Section {
                Label("Speech model failed to load", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(dictationManager.sttStatus ?? "Speech model failed to load.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { dictationManager.retrySTT() }
                    Button(diagnosticsCopied ? "Copied" : "Copy Diagnostics") {
                        Diagnostics.copyToClipboard(dictation: dictationManager, server: serverManager)
                        diagnosticsCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
                    }
                }
                if ttsLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Voice model still loading…").foregroundStyle(.secondary)
                    }
                }
            }
        } else if sttLoading || ttsLoading {
            Section {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Preparing models…")
                        Text(sttLoading
                            ? (dictationManager.sttStatus ?? "Loading the speech model…")
                            : "Loading the voice model…")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(ui): General tab — login item, permissions, first-run"
```

---

### Task 4: Input tab

**Files:**
- Modify: `app/Sources/OpenWhisperer/Settings/InputTab.swift` (replace stub)

**Interfaces:**
- Consumes: `InteractionMode`, `PTTKey`, `TranscriptionOverlay.shared`, `DictationManager` (recorder state, error, `interactionMode`), `InstalledApps.all()`, `AppEntry`, `FocusTarget`, `Paths.{pttHotkey,silenceThreshold,sttLanguage,sttVocabulary,autoSubmitFlag,autoFocusApp,autoFocusReturn}`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Implement**

The full translation of the old Voice Input card + language/vocabulary rows + App Focus Automation card. All persistence identical; labels per spec ("Language", "Press Enter after inserting", "Return to previous app", "Auto-submit after N s of silence").

```swift
import SwiftUI

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
```

- [ ] **Step 2: Build**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(ui): Input tab — dictation, language, app focus"
```

---

### Task 5: Voice tab

**Files:**
- Modify: `app/Sources/OpenWhisperer/Settings/VoiceTab.swift` (replace stub)

**Interfaces:**
- Consumes: `TTSVoiceRegistry.groups` (`.name`, `.voices[].id/.name/.gender`), `TTSSpeed`, `TTSVolume`, `Paths.{ttsVoice,ttsSpeed,ttsVolume,ttsStyle,ttsResponseMode}`.

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import OpenWhispererKit

struct VoiceTab: View {
    @State private var selectedVoice = "af_heart"
    @State private var selectedSpeed = Double(TTSSpeed.default)
    @State private var selectedVolume = 1.0
    @State private var selectedStyle = "normal"
    @State private var selectedResponse = "voice"
    @State private var loaded = false

    private static let styleLevels: [(id: String, label: String)] = [
        ("terse", "Terse"), ("normal", "Normal"), ("rich", "Rich"), ("full", "Full"),
    ]
    private static let responseModes: [(id: String, label: String)] = [
        ("voice", "Only dictated turns"), ("always", "Every turn"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: $selectedVoice) {
                    ForEach(TTSVoiceRegistry.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.voices, id: \.id) { v in
                                Text("\(v.name) (\(v.gender.prefix(1)))").tag(v.id)
                            }
                        }
                    }
                }
                .onChange(of: selectedVoice) { _, newValue in
                    guard loaded else { return }
                    try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                }

                // Bounds MUST equal TTSSpeed.min/max (see TTSSpeed.swift).
                LabeledContent("Speed") {
                    HStack(spacing: 8) {
                        Slider(value: $selectedSpeed, in: 0.7...1.5, step: 0.05)
                        Text(multiplierLabel(selectedSpeed))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: selectedSpeed) { _, newValue in
                    guard loaded else { return }
                    try? String(format: "%.2f", newValue)
                        .write(to: Paths.ttsSpeed, atomically: true, encoding: .utf8)
                }

                // Bounds MUST equal TTSVolume.min/max (see TTSVolume.swift).
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Slider(value: $selectedVolume, in: 0.3...2.0, step: 0.05)
                        Text(multiplierLabel(selectedVolume))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .onChange(of: selectedVolume) { _, newValue in
                    guard loaded else { return }
                    try? String(format: "%.2f", newValue)
                        .write(to: Paths.ttsVolume, atomically: true, encoding: .utf8)
                }
            }

            Section {
                Picker("Reply detail", selection: $selectedStyle) {
                    ForEach(Self.styleLevels, id: \.id) { Text($0.label).tag($0.id) }
                }
                .onChange(of: selectedStyle) { _, newValue in
                    guard loaded else { return }
                    try? newValue.write(to: Paths.ttsStyle, atomically: true, encoding: .utf8)
                }
                Picker("Speak replies", selection: $selectedResponse) {
                    ForEach(Self.responseModes, id: \.id) { Text($0.label).tag($0.id) }
                }
                .onChange(of: selectedResponse) { _, newValue in
                    guard loaded else { return }
                    try? newValue.write(to: Paths.ttsResponseMode, atomically: true, encoding: .utf8)
                }
            } header: {
                Text("Response")
            } footer: {
                Text("\"Only dictated turns\" speaks replies to voice input; \"Every turn\" speaks typed turns too.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func multiplierLabel(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s + "×"
    }

    private func load() {
        if let savedVoice = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8),
           !savedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let voice = savedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            if TTSVoiceRegistry.allVoices.contains(where: { $0.id == voice }) {
                selectedVoice = voice
            }
        }
        selectedSpeed = Double(TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8)))
        selectedVolume = Double(TTSVolume.parse(try? String(contentsOf: Paths.ttsVolume, encoding: .utf8)))
        if let savedStyle = try? String(contentsOf: Paths.ttsStyle, encoding: .utf8),
           !savedStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let style = savedStyle.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.styleLevels.contains(where: { $0.id == style }) { selectedStyle = style }
        }
        if let savedResponse = try? String(contentsOf: Paths.ttsResponseMode, encoding: .utf8),
           !savedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mode = savedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.responseModes.contains(where: { $0.id == mode }) { selectedResponse = mode }
        }
        DispatchQueue.main.async { loaded = true }
    }
}
```

Note: the old "when Voice"/"Always" copy becomes "Only dictated turns"/"Every turn" — display labels only; the written values stay `voice`/`always`.

- [ ] **Step 2: Build**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(ui): Voice tab — voice, speed, volume, response"
```

---

### Task 6: Agents tab

**Files:**
- Modify: `app/Sources/OpenWhisperer/Settings/AgentsTab.swift` (replace stub)

**Interfaces:**
- Consumes: `Platform` (`.allCases/.label/.load()/.save()`), `ConfigManager.{applyHook,checkHookConfigured,showHookInstructions}`.

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct AgentsTab: View {
    @State private var selectedPlatform: Platform = .claudeCode
    @State private var hookApplied = false
    @State private var applyMessage = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Platform", selection: $selectedPlatform) {
                    ForEach(Platform.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: selectedPlatform) { _, newValue in
                    guard loaded else { return }
                    newValue.save()
                    hookApplied = ConfigManager.checkHookConfigured(for: newValue)
                }

                LabeledContent("Voice hook") {
                    Button {
                        let result = ConfigManager.applyHook(for: selectedPlatform)
                        hookApplied = result.success
                        applyMessage = result.message
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                    } label: {
                        Label(hookApplied ? "Applied" : "Auto-Apply",
                              systemImage: hookApplied ? "checkmark.circle.fill" : "bolt.fill")
                    }
                }

                if !applyMessage.isEmpty {
                    Text(applyMessage)
                        .font(.caption)
                        .foregroundStyle(applyMessage.lowercased().contains("fail") ? .red : .green)
                }

                Button("How it works…") {
                    ConfigManager.showHookInstructions(for: selectedPlatform)
                }
            } header: {
                Text("Spoken replies for your coding agent")
            } footer: {
                Text(footerText)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            selectedPlatform = Platform.load()
            hookApplied = ConfigManager.checkHookConfigured(for: selectedPlatform)
            DispatchQueue.main.async { loaded = true }
        }
    }

    private var footerText: String {
        switch selectedPlatform {
        case .claudeCode:
            return "Writes the UserPromptSubmit hook into ~/.claude/settings.json and the speak MCP server into ~/.claude.json. Re-applies cleanly on rebuild."
        case .codexCLI:
            return "Writes the speak MCP server and UserPromptSubmit hook into ~/.codex/config.toml (needs one-time hook trust). Re-applies cleanly on rebuild."
        case .pi:
            return "Copies the OpenWhisperer extension into ~/.pi/agent/extensions/ (no MCP). Run /reload in Pi afterward."
        case .antigravity:
            return "Writes the speak MCP server into ~/.gemini/config/mcp_config.json and the PreInvocation hook into ~/.gemini/config/hooks.json. Start a new agy session afterward."
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(ui): Agents tab — platform picker and hook apply"
```

---

### Task 7: Advanced tab

**Files:**
- Modify: `app/Sources/OpenWhisperer/Settings/AdvancedTab.swift` (replace stub)

**Interfaces:**
- Consumes: `SettingsPortField`; `ServerManager` (`status/.port/.ttsModel/.startAll/.stopAll`), `DictationManager` (`sttModelReady/.sttStatus`), `ModelStorage.{breakdown,format,deleteAll}`, `ConfigManager.{showLog,testTTS}`, `Diagnostics.copyToClipboard`, `Paths.{serverLog,appSupport}`.

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct AdvancedTab: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var dictationManager: DictationManager
    @State private var serverReachable = false
    @State private var deletedModelsBanner = false
    @State private var diagnosticsCopied = false

    var body: some View {
        Form {
            Section("Models") {
                LabeledContent("Whisper STT") {
                    Text(dictationManager.sttModelReady
                        ? "large-v3-turbo · on-device"
                        : (dictationManager.sttStatus ?? "Loading…"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Kokoro TTS") {
                    Text("\(serverManager.ttsModel) · \(serverManager.status.rawValue)")
                        .foregroundStyle(.secondary)
                }
                Button("Delete Downloaded Models…", action: confirmDeleteModels)
                if deletedModelsBanner {
                    Text("Models deleted — they'll re-download on next use")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Server") {
                let serverStopped = serverManager.status == .stopped
                LabeledContent("Text-to-speech server") {
                    if serverStopped || serverManager.status == .error {
                        Button("Start") { serverManager.startAll() }
                    } else {
                        Button("Stop") { serverManager.stopAll() }
                    }
                }
                LabeledContent("Port") {
                    SettingsPortField(port: $serverManager.port, disabled: !serverStopped)
                }
                LabeledContent("Reachable") {
                    Image(systemName: serverReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(serverReachable ? .green : .red)
                }
            }

            Section("Diagnostics") {
                Button("Show Server Log") {
                    ConfigManager.showLog(name: "Server", url: Paths.serverLog)
                }
                Button("Show Events Log") {
                    ConfigManager.showLog(
                        name: "Events",
                        url: Paths.appSupport.appendingPathComponent("paste_debug.log"))
                }
                Button(diagnosticsCopied ? "Copied to Clipboard" : "Copy Diagnostics") {
                    Diagnostics.copyToClipboard(dictation: dictationManager, server: serverManager)
                    diagnosticsCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ConfigManager.testTTS(port: serverManager.port) { ok in
                DispatchQueue.main.async { serverReachable = ok }
            }
        }
        .onChange(of: serverManager.status) { _, _ in
            ConfigManager.testTTS(port: serverManager.port) { ok in
                DispatchQueue.main.async { serverReachable = ok }
            }
        }
    }

    /// Standalone NSAlert (the app's existing pattern for confirms) — kept verbatim
    /// from the legacy view, including the Cancel-as-default key equivalents.
    private func confirmDeleteModels() {
        let (lines, total) = ModelStorage.breakdown()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete downloaded models?"
        alert.informativeText = total == 0
            ? "No downloaded models were found — nothing to delete."
            : "Frees \(ModelStorage.format(total)):\n\n"
                + lines.joined(separator: "\n")
                + "\n\nThe models re-download automatically the next time you dictate or use speech."
        if total == 0 {
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        NSApp.activate(ignoringOtherApps: true)
        if total > 0, alert.runModal() == .alertFirstButtonReturn {
            serverManager.stopAll()
            ModelStorage.deleteAll()
            deletedModelsBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { deletedModelsBanner = false }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(ui): Advanced tab — models, server, diagnostics"
```

---

### Task 8: Delete the legacy view + dead paths

**Files:**
- Delete: `app/Sources/OpenWhisperer/MenuBarView.swift`
- Modify: `app/Sources/OpenWhisperer/Theme.swift` (delete `OWWindowBackground`)
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (delete the three expansion entries)

**Interfaces:**
- Consumes: nothing. Produces: a tree with no references to `MenuBarView`, `OWFont`, `OWCard*`, `OWMenuPicker`, `OWWindowBackground`, or the `*_expanded` paths.

- [ ] **Step 1: Delete**

```bash
git rm app/Sources/OpenWhisperer/MenuBarView.swift
```

In `Theme.swift`, delete the `OWWindowBackground` struct and its `// MARK: - Window background` comment block (its only consumer was MenuBarView). Keep `registerBundledFonts` — `TranscriptionOverlay` uses `.custom("Outfit", …)` directly.

In `Paths.swift`, delete these three lines (written-never-read; the collapsible cards are gone):

```swift
static let setupCardExpanded = appSupport.appendingPathComponent("setup_expanded")
static let voiceSettingsCardExpanded = appSupport.appendingPathComponent("voice_settings_expanded")
static let serverCardExpanded = appSupport.appendingPathComponent("server_expanded")
```

- [ ] **Step 2: Verify no dangling references**

Run: `grep -rn "MenuBarView\|OWFont\|OWCard\|OWMenuPicker\|OWCheckbox\|OWWindowBackground\|CardExpanded" app/Sources`
Expected: no output.

- [ ] **Step 3: Build + run both test suites**

Run: `cd app && swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: `Build complete!` and both suites exit 0 (all groups pass).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor(ui): delete legacy MenuBarView and dead paths"
```

---

### Task 9: Manual verification + PR

**Files:** none (verification + PR).

- [ ] **Step 1: Launch and walk the tabs**

Run: `cd app && swift build && .build/debug/OpenWhisperer &`
Click the menubar waveform → Settings… (or ⌘,). Verify: window opens with 5 toolbar tabs; each tab renders grouped native forms; no branded colors/fonts.

- [ ] **Step 2: Behavior parity spot-checks (flat-file bus)**

From each tab, toggle one representative setting and confirm the write in
`~/Library/Application Support/OpenWhisperer/`:

```bash
AS=~/Library/"Application Support"/OpenWhisperer
# Voice tab: move Speed → check tts_speed updates (e.g. 1.15)
cat "$AS/tts_speed"
# Input tab: change Language to Turkish → stt_language == tr; back to Auto-detect → file gone
cat "$AS/stt_language"
# Input tab: type a vocabulary term, wait 1 s → stt_vocabulary contains it
cat "$AS/stt_vocabulary"
# Input tab: enable "Press Enter after inserting" → auto_submit exists
ls "$AS/auto_submit"
# Agents tab: platform → selected_platform
cat "$AS/selected_platform"
```

Then kill the app: `killall OpenWhisperer`.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin native-settings
gh pr create --title "feat(ui): native tabbed Settings window" --body "..."
```

PR body: summary of the redesign (spec link), the 5-tab map, zero-behavior-change note, test results.

---

## Self-Review (done at write time)

- **Spec coverage:** scene swap (T2), tab map + contents (T3–T7), first-run signals (T3), label renames (T4/T5), deletions + OWColor move (T1/T8), zero-behavior-change (persistence code copied verbatim into T4–T7 with a `loaded` guard added so initial `@State` assignment can't echo writes — the legacy view had the same implicit behavior because writes were idempotent; the guard makes it explicit and prevents the language `onChange` from deleting `stt_language` on open when set to auto), testing (T8/T9). Gap check: none found.
- **Placeholder scan:** PR body says "..." — intentional (written at PR time from actual results). No TBDs elsewhere.
- **Type consistency:** `PermissionRow(label:granted:help:action:)` and `SettingsPortField(port:disabled:)` defined in T2, consumed with those exact signatures in T3/T7. `loaded` guard pattern consistent across T4–T6.
