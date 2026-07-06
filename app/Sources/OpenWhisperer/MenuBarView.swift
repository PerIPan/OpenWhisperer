import AppKit
import SwiftUI
import ServiceManagement
import OpenWhispererKit

// MARK: - Design Tokens

// Warm "Open Whisperer" palette (openwhisperer.com). Tokens are light/dark dynamic —
// see Theme.swift for the `Color.ow(light, dark)` helper. Module-internal so the overlay
// and any other view can share the same design tokens.
enum OWColor {
    // Surfaces
    static let page = Color.ow(0xFAF7F1, 0x1E1B16)            // popover background (cream / warm-dark)
    static let surface = Color.ow(0xFFFFFF, 0x2A2520)          // card surface
    static let cardBackground = surface                        // legacy alias (OWCard)
    // Lines
    static let line = Color.ow(0xDCCFB8, 0x3A332B)             // borders + dividers (deepened for visible cards)
    static let divider = line                                  // legacy alias
    // Text ramp (warm ink → cream)
    static let ink = Color.ow(0x2A2520, 0xF3ECDF)
    static let inkSoft = Color.ow(0x6A6157, 0xB6AC9C)
    static let inkFaint = Color.ow(0x978C7E, 0x877D6F)
    static let muted = inkSoft                                 // legacy alias
    // Accent (gold)
    static let accent = Color.ow(0xC0A06A, 0xCBA86A)
    static let accentDeep = Color.ow(0x98763F, 0xD8B677)
    static let onAccent = Color.ow(0x2A2520, 0x211B12)         // text/icon on a gold fill (WCAG-safe ink)
    static let success = accentDeep                            // "applied" state → deep gold (WCAG-safe as text)
    // Fills
    static let pillFill = Color.ow(0xEADFC8, 0x342D24)
    static let pickerBg = Color.ow(0xF3EBDD, 0x332C23)
    static let pickerBorder = Color.ow(0xE0D4BD, 0x423A30)
    static let checkboxBorder = Color.ow(0xCBBFA9, 0x4A4136)
    static let pillBackground = pillFill                       // legacy alias
    // Status semantics — warm equivalents of system red/amber/green so dots + badges don't
    // clash with the cream/gold palette (the system colors are especially jarring in dark mode).
    static let recording = Color.ow(0xCC3D33, 0xE2675A)        // recording / error
    static let warn = Color.ow(0xB8822E, 0xE0B25C)             // transient / warning
    static let live = Color.ow(0x5E8C4E, 0x86C06A)             // listening / running / ready
    static let danger = recording                             // alias for error states
}

enum OWFont {
    /// Brand serif for the wordmark + titled headers. The bundled cut is a single SemiBold static
    /// face (family "Fraunces SemiBold"), so the weight is intrinsic — no `.weight()` needed.
    static func title(_ size: CGFloat = 15) -> Font {
        .custom("Fraunces SemiBold", size: size)
    }
    static func serif(_ size: CGFloat = 15) -> Font {
        .custom("Fraunces SemiBold", size: size)
    }
    static func sectionLabel(_ size: CGFloat = 11) -> Font {
        .custom("Outfit", size: size).weight(.semibold)
    }
    static func body(_ size: CGFloat = 13) -> Font {
        .custom("Outfit", size: size)
    }
    static func caption(_ size: CGFloat = 10) -> Font {
        .custom("Outfit", size: size)
    }
    static func mono(_ size: CGFloat = 11) -> Font {
        .custom("Outfit", size: size).monospaced()
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @EnvironmentObject var dictationManager: DictationManager
    @EnvironmentObject var accessibilityManager: AccessibilityManager
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var autoFocusReturn = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"  // visual default; only written on explicit toggle
    @State private var customFocusApp = ""
    @State private var installedApps: [AppEntry] = []
    @State private var saveDebounce: DispatchWorkItem?
    @State private var selectedPTTKey = "ctrl"
    @State private var selectedMode: InteractionMode = .holdToTalk
    @State private var silenceThreshold: Int = 3
    @State private var selectedVolume = "medium"
    @State private var selectedVoice = "af_heart"
    @State private var selectedLanguage = "en"
    @State private var selectedStyle = "normal"
    @State private var selectedResponse = "voice"
    @State private var showStoppedBanner = false
    @State private var pttKeyChanged = false
    @State private var selectedPlatform: Platform = .claudeCode
    @State private var hookApplied = false
    @State private var superpowersApplied = false
    @State private var applyMessage = ""
    @State private var serverReachable = false
    @State private var deletedModelsBanner = false
    @State private var launchAtLogin = false
    @State private var diagnosticsCopied = false
    @State private var voiceSettingsExpanded = false  // always collapsed by default on launch
    @State private var setupExpanded = false   // always collapsed by default on launch
    @State private var serverExpanded = false  // always collapsed by default on launch
    // logsExpanded removed — merged into serverExpanded
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    private static let voices: [(id: String, label: String)] = [
        // English
        ("af_heart", "Heart (English F)"),
        ("af_bella", "Bella (English F)"),
        ("am_michael", "Michael (English M)"),
        // French
        ("ff_siwis", "Siwis (French F)"),
        // Italian
        ("if_sara", "Sara (Italian F)"),
        ("im_nicola", "Nicola (Italian M)"),
    ]

    private static let languages: [(id: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("ru", "Russian"),
        ("pl", "Polish"),
        ("tr", "Turkish"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
    ]

    private static let styleLevels: [(id: String, label: String)] = [
        ("terse", "Terse"),
        ("normal", "Normal"),
        ("rich", "Rich"),
        ("full", "Full"),
    ]

    // When replies are spoken. "voice" (default) = only dictated turns; matches
    // the tts_response_mode values read by voice-context.sh / codex-tts-hook.sh.
    private static let responseModes: [(id: String, label: String)] = [
        ("voice", "when Voice"),
        ("text", "when Text"),
        ("always", "Always"),
    ]

    private static let volumeLevels: [(id: String, label: String, value: String)] = [
        ("low", "Low", "0.3"),
        ("medium", "Medium", "1"),
        ("high", "High", "4"),
    ]

    private static let focusApps: [(id: String, label: String)] = [
        ("Code", "VS Code"),
        ("Code - Insiders", "VS Code Insiders"),
        ("Cursor", "Cursor (AI Editor)"),
        ("Windsurf", "Windsurf (AI Editor)"),
        ("Zed", "Zed (Editor)"),
        ("Xcode", "Xcode (Apple IDE)"),
        ("Sublime Text", "Sublime Text (Editor)"),
        ("Nova", "Nova (Panic)"),
        ("Fleet", "Fleet (JetBrains)"),
        ("Claude", "Claude (Desktop)"),
        ("Terminal", "Terminal (macOS)"),
        ("iTerm2", "iTerm2 (Terminal)"),
        ("Warp", "Warp (Terminal)"),
        ("Alacritty", "Alacritty (Terminal)"),
        ("Ghostty", "Ghostty (Terminal)"),
        ("CUSTOM", "CUSTOM"),
    ]

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.bottom, 12)

            setupProgressSection

            modelLoadingBanner

            voiceInputCard
                .padding(.bottom, 8)

            voiceSettingsCard
                .padding(.bottom, 8)

            automationCard
                .padding(.bottom, 8)

            setupCard
                .padding(.bottom, 8)

            serverCard
                .padding(.bottom, 8)

            footerSection
        }
        .padding(14)
        .font(OWFont.body())
        .foregroundStyle(OWColor.ink)
        .tint(OWColor.accent)
        .frame(width: 310)
        // Native AppKit controls replaced with custom OWMenuPicker/OWCheckbox.
        // Warm solid surface (no material) to match openwhisperer.com; window chrome
        // tinted to match in both light + dark via OWWindowBackground.
        .background(OWColor.page)
        .background(OWWindowBackground())
        .onAppear {
            selectedPlatform = Platform.load()
            // SMAppService.mainApp.status is a synchronous XPC call to launchservicesd and
            // can block the main thread for seconds (freezing the menu). Resolve it off the
            // main thread and assign the flag back on main.
            DispatchQueue.global(qos: .userInitiated).async {
                let enabled = SMAppService.mainApp.status == .enabled
                DispatchQueue.main.async { launchAtLogin = enabled }
            }
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
                    focusSelection = bid              // installed-app pick ("bundleid:" tagged)
                case .name(let name):
                    if Self.focusApps.contains(where: { $0.id == name }) {
                        focusSelection = name         // curated favorite
                    } else {
                        focusSelection = "CUSTOM"
                        customFocusApp = name         // typed custom name (or legacy value)
                    }
                }
            }
            if let savedKey = try? String(contentsOf: Paths.pttHotkey, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let key = PTTKey(rawValue: savedKey) {
                selectedPTTKey = savedKey
                TranscriptionOverlay.shared.pttKeyLabel = key.label
            }
            if let savedVoice = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8),
               !savedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let voice = savedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.voices.contains(where: { $0.id == voice }) {
                    selectedVoice = voice
                }
            }
            if let savedLang = try? String(contentsOf: Paths.sttLanguage, encoding: .utf8),
               !savedLang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lang = savedLang.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.languages.contains(where: { $0.id == lang }) {
                    selectedLanguage = lang
                }
            }
            if let savedStyle = try? String(contentsOf: Paths.ttsStyle, encoding: .utf8),
               !savedStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let style = savedStyle.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.styleLevels.contains(where: { $0.id == style }) {
                    selectedStyle = style
                }
            }
            if let savedResponse = try? String(contentsOf: Paths.ttsResponseMode, encoding: .utf8),
               !savedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let mode = savedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.responseModes.contains(where: { $0.id == mode }) {
                    selectedResponse = mode
                }
            }
            if let savedVolume = try? String(contentsOf: Paths.ttsVolume, encoding: .utf8),
               !savedVolume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let val = savedVolume.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = Self.volumeLevels.first(where: { $0.value == val }) {
                    selectedVolume = match.id
                }
            }
            selectedMode = InteractionMode.load()
            if let savedStr = try? String(contentsOf: Paths.silenceThreshold, encoding: .utf8),
               let saved = Int(savedStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                silenceThreshold = saved
            }
            refreshDiagnostics()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text("Open Whisperer")
                .font(OWFont.title(17))
                .foregroundColor(OWColor.ink)
            Spacer()
        }
    }

    // MARK: - Setup Progress (conditional)

    @ViewBuilder
    private var setupProgressSection: some View {
        if case .inProgress(let step) = setupManager.state {
            OWCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step)
                        .font(OWFont.caption())
                        .foregroundColor(.secondary)
                    ProgressView(value: setupManager.progress)
                        .progressViewStyle(.linear)
                        .tint(OWColor.accent)
                }
            }
            .padding(.bottom, 8)
        } else if case .failed(let reason) = setupManager.state {
            OWCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(OWFont.caption())
                        .foregroundColor(OWColor.danger)
                    Button("Retry Setup") {
                        setupManager.resetAndRerun { success in
                            guard success else { return }
                            DispatchQueue.main.async { serverManager.startAll() }
                        }
                    }
                    .buttonStyle(OWPrimaryButtonStyle())
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Model Loading Banner (first-run signal)

    /// Prominent banner shown only while a model is still loading — most visible on the very
    /// first launch (download + Neural-Engine compile can take 1–2 min). Disappears once ready.
    @ViewBuilder
    private var modelLoadingBanner: some View {
        let sttLoading = !dictationManager.sttModelReady && !dictationManager.sttFailed
        let ttsLoading = serverManager.status == .starting
        if dictationManager.sttFailed {
            OWCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(OWColor.danger)
                        Text("Speech model failed to load")
                            .font(OWFont.body(11).weight(.semibold))
                            .foregroundColor(OWColor.ink)
                    }
                    Text(dictationManager.sttStatus ?? "Speech model failed to load.")
                        .font(OWFont.caption(11))
                        .foregroundColor(OWColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button(action: { dictationManager.retrySTT() }) {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle(tinted: true))
                        Button(action: {
                            Diagnostics.copyToClipboard(dictation: dictationManager, server: serverManager)
                            diagnosticsCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
                        }) {
                            Label(diagnosticsCopied ? "Copied" : "Copy Diagnostics",
                                  systemImage: diagnosticsCopied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle())
                    }
                }
            }
            .padding(.bottom, 10)
        } else if sttLoading || ttsLoading {
            OWCard {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Preparing models…")
                            .font(OWFont.body(11).weight(.semibold))
                            .foregroundColor(OWColor.ink)
                        Text(sttLoading
                            ? (dictationManager.sttStatus ?? "Loading the speech model…")
                            : "Loading the voice model…")
                            .font(OWFont.caption(11))
                            .foregroundColor(OWColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: - Voice Input Card

    private var voiceInputCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "Voice Input", icon: "mic.fill",
                             help: "How you start dictation — Press-to-Talk, Hold-to-Talk, or Hands-Free — plus the trigger key and how the app listens.")

                // Mode dropdown
                OWPickerRow(label: "Mode", labelWidth: 52) {
                    OWMenuPicker(
                        selection: $selectedMode,
                        options: InteractionMode.allCases.map { (id: $0, label: $0.label) }
                    )
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedMode) { _, newValue in
                    newValue.save()
                    dictationManager.interactionMode = newValue
                }

                // Mode description hint — wrap to multiple lines instead of truncating
                Text(selectedMode.description)
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !dictationManager.recorder.micPermission {
                    OWInternalDivider()

                    Button(action: { dictationManager.recorder.openMicSettings() }) {
                        Label("Grant Microphone Access", systemImage: "mic.slash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(OWRowButtonStyle())

                    Text("Required for built-in dictation")
                        .font(OWFont.caption())
                        .foregroundColor(OWColor.warn)
                } else {
                    OWInternalDivider()

                    // Recording state + PTT key — aligned icon column
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
                            OWMenuPicker(
                                selection: $selectedPTTKey,
                                options: PTTKey.allCases.map { (id: $0.rawValue, label: $0.label) }
                            )
                            .frame(width: 76)
                        }
                    }
                    .onChange(of: selectedPTTKey) { _, newValue in
                        try? newValue.write(to: Paths.pttHotkey, atomically: true, encoding: .utf8)
                        if let key = PTTKey(rawValue: newValue) {
                            TranscriptionOverlay.shared.pttKeyLabel = key.label
                        }
                        pttKeyChanged = true
                    }

                    // Hands-free: silence threshold
                    if selectedMode == .handsFree {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.slash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text("Silence")
                                .font(OWFont.body(11))
                            Spacer()
                            OWMenuPicker(
                                selection: $silenceThreshold,
                                options: [3, 4, 5, 7, 10, 20].map { (id: $0, label: "\($0)s") }
                            )
                            .frame(width: 76)
                            .onChange(of: silenceThreshold) { _, newValue in
                                let str = String(newValue)
                                try? str.write(to: Paths.silenceThreshold, atomically: true, encoding: .utf8)
                                dictationManager.recorder.silenceThresholdSeconds = TimeInterval(newValue)
                            }
                        }

                        if dictationManager.isCalibrating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Calibrating microphone...")
                                    .font(OWFont.caption())
                                    .foregroundColor(OWColor.warn)
                            }
                        }

                        if dictationManager.ttsPlaying {
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(OWColor.accentDeep)
                                Text("say \"hold on\" to interrupt TTS")
                                    .font(OWFont.caption())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Overlay toggle — aligned icon column
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundColor(overlay.isVisible ? OWColor.live : OWColor.inkFaint)
                            .frame(width: 16)
                        Text("Transcription Overlay")
                            .font(OWFont.body(11))
                        Spacer()
                        OWMenuPicker(
                            selection: Binding(
                                get: { overlay.isVisible ? "on" : "off" },
                                set: { newValue in
                                    if newValue == "on" { overlay.show() } else { overlay.hide() }
                                }
                            ),
                            options: [(id: "on", label: "ON"), (id: "off", label: "OFF")]
                        )
                        .frame(width: 76)
                    }

                    // Hotkey-change notice
                    if pttKeyChanged {
                        InlineBadge(text: "Restart app to apply new hotkey", color: OWColor.warn)
                    }

                    // Error display
                    if let err = dictationManager.error {
                        InlineBadge(text: err, color: OWColor.danger)
                    }
                }
            }
        }
    }

    // MARK: - Voice Settings Card

    private var voiceSettingsCard: some View {
        OWCollapsibleCard(
            title: "Voice Settings",
            icon: "slider.horizontal.3",
            help: "Dictation language, the voice that reads replies aloud, and Response — how much of a reply is spoken, and when.",
            expanded: $voiceSettingsExpanded
        ) {
            EmptyView()
        } expandedContent: {
            VStack(alignment: .leading, spacing: 10) {
                OWPickerRow(label: "Dictate in", labelWidth: 62) {
                    OWMenuPicker(selection: $selectedLanguage, options: Self.languages)
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    if newValue == "auto" {
                        try? FileManager.default.removeItem(at: Paths.sttLanguage)
                    } else {
                        try? newValue.write(to: Paths.sttLanguage, atomically: true, encoding: .utf8)
                    }
                }

                OWInternalDivider()

                OWPickerRow(label: "Voice", labelWidth: 62) {
                    OWMenuPicker(selection: $selectedVoice, options: Self.voices)
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedVoice) { _, newValue in
                    try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                }

                // No visible separator between Voice and Response, but keep the same
                // gap (the divider was 0.5pt) so the rows don't move closer.
                Color.clear.frame(height: 0.5)

                // Both dropdowns are Response settings: spoken-summary length (left)
                // + when replies are spoken (right). One "Response" label, formatted
                // like the other rows.
                OWPickerRow(label: "Response", labelWidth: 62) {
                    HStack(spacing: 8) {
                        OWMenuPicker(selection: $selectedStyle, options: Self.styleLevels)
                            .frame(maxWidth: .infinity)
                            .onChange(of: selectedStyle) { _, newValue in
                                try? newValue.write(to: Paths.ttsStyle, atomically: true, encoding: .utf8)
                            }
                        OWMenuPicker(selection: $selectedResponse, options: Self.responseModes)
                            .frame(maxWidth: .infinity)
                            .onChange(of: selectedResponse) { _, newValue in
                                try? newValue.write(to: Paths.ttsResponseMode, atomically: true, encoding: .utf8)
                            }
                    }
                }

            }
        }
        .onChange(of: voiceSettingsExpanded) { _, newValue in
            if newValue {
                try? "open".write(to: Paths.voiceSettingsCardExpanded, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: Paths.voiceSettingsCardExpanded)
            }
        }
    }

    // MARK: - Automation Card

    private var automationCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "App Focus Automation", icon: "gearshape.2",
                             help: "Force dictation into a chosen app: focus that app, type your words, optionally press Enter to submit, then (with return) hop back to where you were.")

                HStack(spacing: 20) {
                    OWCheckbox(label: "auto-focus", isOn: $autoFocusEnabled)
                    OWCheckbox(label: "auto-submit", isOn: $autoSubmit)
                }
                .onChange(of: autoSubmit) { _, enabled in
                    if enabled {
                        try? "on".write(to: Paths.autoSubmitFlag, atomically: true, encoding: .utf8)
                    } else {
                        do {
                            try FileManager.default.removeItem(at: Paths.autoSubmitFlag)
                        } catch {
                            NSLog("Failed to remove auto-submit flag: \(error)")
                        }
                    }
                }
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

                // Auto-focus sub-options — nested under the auto-focus toggle,
                // shown only while auto-focus is on.
                if autoFocusEnabled {
                    OWInternalDivider()

                    VStack(alignment: .leading, spacing: 8) {
                        OWAppPicker(
                            selection: $focusSelection,
                            favorites: Self.focusApps.filter { $0.id != "CUSTOM" }
                                .map { AppEntry(bundleID: $0.id, name: $0.label) },
                            installed: installedApps
                        ) { id in
                            if id == "CUSTOM" {
                                focusAppName = customFocusApp
                            } else if installedApps.contains(where: { $0.bundleID == id }) {
                                focusAppName = FocusTarget.tag(bundleID: id)   // installed pick
                            } else {
                                focusAppName = id                             // curated favorite
                            }
                            saveFocusApp()
                        }
                        .frame(maxWidth: .infinity)

                        if focusSelection == "CUSTOM" {
                            TextField("App name", text: $customFocusApp)
                                .textFieldStyle(.roundedBorder)
                                .font(OWFont.body(11))
                                .onChange(of: customFocusApp) { _, newValue in
                                    if !newValue.isEmpty {
                                        focusAppName = newValue
                                        debouncedSaveFocusApp()
                                    }
                                }
                        }

                        OWCheckbox(label: "with return", isOn: $autoFocusReturn)
                            .onChange(of: autoFocusReturn) { _, enabled in
                                if enabled {
                                    try? "on".write(to: Paths.autoFocusReturn, atomically: true, encoding: .utf8)
                                } else {
                                    try? FileManager.default.removeItem(at: Paths.autoFocusReturn)
                                }
                            }
                    }
                    .padding(.leading, 6)
                }

                // Behavior hint — reflects the active auto-focus / with-return /
                // auto-submit combination.
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

    /// One-line description of what a dictation will do, given the active
    /// Automation toggles. Nil when no automation is on.
    private var automationHint: String? {
        if autoFocusEnabled {
            var steps = ["focus target app", "insert text"]
            if autoSubmit { steps.append("press enter") }
            if autoFocusReturn { steps.append("return to previous") }
            return steps.joined(separator: ", ")
        }
        if autoSubmit {
            return "enter is auto-applied after text insertion"
        }
        return nil
    }

    // MARK: - Setup Card

    private var setupCard: some View {
        OWCollapsibleCard(
            title: "Setup TTS for",
            icon: "hammer",
            help: "Wire up spoken replies for your CLI (Claude Code or Codex) — Auto-Apply writes the hooks. Volume here sets playback loudness.",
            expanded: $setupExpanded
        ) {
            OWMenuPicker(
                selection: $selectedPlatform,
                options: Platform.allCases.map { (id: $0, label: $0.label) }
            )
            .frame(width: 104)
            .onChange(of: selectedPlatform) { _, newValue in
                newValue.save()
                refreshDiagnostics()
            }
        } expandedContent: {
            VStack(alignment: .leading, spacing: 8) {
                // Hook row — aligned label + info + apply
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Hook")
                            .font(OWFont.body(11))
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 80, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { ConfigManager.showHookInstructions(for: selectedPlatform) }

                    Button(action: {
                        let result = ConfigManager.applyHook(for: selectedPlatform)
                        hookApplied = result.success
                        applyMessage = result.message
                        refreshDiagnostics()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyMessage = "" }
                    }) {
                        Label(
                            hookApplied ? "Applied" : "Auto-Apply",
                            systemImage: hookApplied ? "checkmark.circle.fill" : "bolt.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle(tinted: hookApplied, urgent: !hookApplied))
                }

                // Superpowers row — Claude Code only
                if selectedPlatform == .claudeCode {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Superpowers")
                                .font(OWFont.body(11))
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 80, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { ConfigManager.showSuperpowersInstructions() }

                        Button(action: {
                            let result = ConfigManager.applySuperpowers()
                            superpowersApplied = ConfigManager.checkSuperpowersInstalled()
                            applyMessage = result.message
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { applyMessage = "" }
                        }) {
                            Label(
                                superpowersApplied ? "Installed" : "Copy Install",
                                systemImage: superpowersApplied ? "checkmark.circle.fill" : "doc.on.clipboard"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle(tinted: superpowersApplied, urgent: !superpowersApplied))
                    }
                }

                // Apply message feedback
                if !applyMessage.isEmpty {
                    Text(applyMessage)
                        .font(OWFont.caption())
                        .foregroundColor(
                            applyMessage.lowercased().contains("fail") ? OWColor.danger : OWColor.live
                        )
                        .transition(.opacity)
                }
                // (Removed the redundant "HOOK configured" / "superpowers installed" diagnostic
                // rows — the Applied/Installed pills above already convey this state.)

                OWInternalDivider()

                // Volume — low-level TTS playback gain; tucked at the bottom of Setup.
                OWPickerRow(label: "Volume", labelWidth: 62) {
                    OWMenuPicker(selection: $selectedVolume, options: Self.volumeLevels.map { (id: $0.id, label: $0.label) })
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedVolume) { _, newValue in
                    if let level = Self.volumeLevels.first(where: { $0.id == newValue }) {
                        try? level.value.write(to: Paths.ttsVolume, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        .onChange(of: setupExpanded) { _, newValue in
            if newValue {
                try? FileManager.default.removeItem(at: Paths.setupCardExpanded)
            } else {
                try? "closed".write(to: Paths.setupCardExpanded, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Server Card

    private var serverCard: some View {
        OWCollapsibleCard(
            title: "Server & Logs",
            icon: "gearshape",
            help: "The on-device text-to-speech server (local port 8000), downloaded models, and logs. Dictation runs separately from this.",
            expanded: $serverExpanded
        ) {
            EmptyView()
        } expandedContent: {
            VStack(alignment: .leading, spacing: 8) {
                // Model status rows (moved here from the top of the menu)
                VStack(spacing: 0) {
                    ModernStatusRow(
                        label: "Whisper STT",
                        subtitle: dictationManager.sttModelReady
                            ? "large-v3-turbo"
                            : (dictationManager.sttStatus ?? "Loading…"),
                        port: "local",
                        status: dictationManager.sttModelReady ? .running : .starting
                    )
                    OWInternalDivider()
                    ModernStatusRow(
                        label: "Kokoro TTS",
                        subtitle: serverManager.ttsModel,
                        port: "\(serverManager.port)",
                        status: serverManager.status
                    )
                }
                OWInternalDivider()

                let serverStopped = serverManager.status == .stopped

                HStack(spacing: 6) {
                    if serverStopped || serverManager.status == .error {
                        Button(action: { serverManager.startAll() }) {
                            Label("Start Server", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle())
                    } else {
                        Button(action: {
                            serverManager.stopAll()
                            showStoppedBanner = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showStoppedBanner = false
                            }
                        }) {
                            Label("Stop", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle())
                    }

                    Button(action: {
                        // A SwiftUI `.alert` is hosted inside the MenuBarExtra(.window) popover,
                        // which resigns key and tears down on the first click — so the confirm
                        // could never complete. Present a standalone AppKit NSAlert instead
                        // (the app's existing pattern for windows; see ConfigManager.showLog).
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
                            alert.addButton(withTitle: "Delete")   // rightmost
                            alert.addButton(withTitle: "Cancel")
                            alert.buttons[0].keyEquivalent = ""     // don't let Return delete
                            alert.buttons[1].keyEquivalent = "\r"   // Cancel is the default
                        }
                        NSApp.activate(ignoringOtherApps: true)
                        if total > 0, alert.runModal() == .alertFirstButtonReturn {
                            serverManager.stopAll()
                            ModelStorage.deleteAll()
                            deletedModelsBanner = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { deletedModelsBanner = false }
                        }
                    }) {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle())

                    PortField(label: "", port: $serverManager.port, disabled: !serverStopped)
                }

                if deletedModelsBanner {
                    Text("Models deleted — they'll re-download on next use")
                        .font(OWFont.body(11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }

                if showStoppedBanner {
                    Text("Server stopped")
                        .font(OWFont.body(11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                }

                ModernDiagnosticRow(label: "Server reachable", ok: serverReachable)

                OWInternalDivider()

                HStack(spacing: 6) {
                    Button(action: { ConfigManager.showLog(name: "Server", url: Paths.serverLog) }) {
                        Label("Server Log", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle())

                    Button(action: {
                        ConfigManager.showLog(
                            name: "Events",
                            url: Paths.appSupport.appendingPathComponent("paste_debug.log")
                        )
                    }) {
                        Label("Events Log", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OWRowButtonStyle())
                }

                Button(action: {
                    Diagnostics.copyToClipboard(dictation: dictationManager, server: serverManager)
                    diagnosticsCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
                }) {
                    Label(diagnosticsCopied ? "Copied to clipboard" : "Copy Diagnostics",
                          systemImage: diagnosticsCopied ? "checkmark" : "stethoscope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(OWRowButtonStyle())
            }
        }
        .onChange(of: serverExpanded) { _, newValue in
            if newValue {
                try? "open".write(to: Paths.serverCardExpanded, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: Paths.serverCardExpanded)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 8) {
                OWCardHeader(title: "Permissions Required", icon: "lock.shield",
                             help: "macOS grants Open Whisperer needs: Accessibility (type into the focused app), Microphone (record dictation), and Speech Recognition (hands-free wake words). Tap a row to open Settings.")

                ModernDiagnosticRow(label: "Accessibility", ok: accessibilityManager.isGranted)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                ModernDiagnosticRow(label: "Microphone", ok: dictationManager.recorder.micPermission)
                    .contentShape(Rectangle())
                    .onTapGesture { dictationManager.recorder.openMicSettings() }
                ModernDiagnosticRow(label: "Speech Recognition", ok: dictationManager.keywordDetector.permissionGranted)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                OWInternalDivider()

                // Launch at login
                ModernDiagnosticRow(label: "Start on startup", ok: launchAtLogin)
                    .contentShape(Rectangle())
                    .onTapGesture { launchAtLogin.toggle() }
                    .onChange(of: launchAtLogin) { _, enabled in
                        let service = SMAppService.mainApp
                        do {
                            if enabled {
                                try service.register()
                            } else {
                                try service.unregister()
                            }
                        } catch {
                            NSLog("Login item toggle failed: \(error)")
                            DispatchQueue.main.async {
                                launchAtLogin = service.status == .enabled
                            }
                        }
                    }

                OWInternalDivider()

                HStack {
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(OWFont.caption())
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        Label("Quit", systemImage: "power")
                            .font(OWFont.body(11))
                    }
                    .buttonStyle(OWRowButtonStyle())
                    .keyboardShortcut("q")
                }
            }
        }
    }

    // MARK: - Computed helpers

    private var stateColor: Color {
        switch dictationManager.recorderState {
        case .recording: return OWColor.recording
        case .uploading: return OWColor.warn
        case .listening: return OWColor.live
        case .idle: return dictationManager.ttsPlaying ? OWColor.accentDeep : OWColor.live
        }
    }

    /// The status dot glows for the "live" states (recording / listening / idle-ready),
    /// not for transient transcribing or while TTS is playing — derived from state, not
    /// from a fragile color comparison.
    private var stateGlows: Bool {
        switch dictationManager.recorderState {
        case .recording, .listening: return true
        case .uploading: return false
        case .idle: return !dictationManager.ttsPlaying
        }
    }

    private var stateLabel: String {
        if dictationManager.isCalibrating { return "Calibrating..." }
        if dictationManager.ttsPlaying { return "Playing..." }
        switch dictationManager.recorderState {
        case .recording: return "Recording..."
        case .uploading: return "Transcribing..."
        case .listening: return "Listening..."
        case .idle: return "Standby"
        }
    }

    private func refreshDiagnostics() {
        hookApplied = ConfigManager.checkHookConfigured(for: selectedPlatform)
        superpowersApplied = ConfigManager.checkSuperpowersInstalled()
        ConfigManager.testTTS(port: serverManager.port) { ok in
            DispatchQueue.main.async { serverReachable = ok }
        }
    }

    private func saveFocusApp() {
        guard autoFocusEnabled, !focusAppName.isEmpty else { return }
        try? focusAppName.write(to: Paths.autoFocusApp, atomically: true, encoding: .utf8)
        // Owner-only — the target app name is read by the local server (T2.5)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.autoFocusApp.path)
    }

    private func debouncedSaveFocusApp() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { saveFocusApp() }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

// MARK: - OWCard (rounded card container)

struct OWCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OWColor.cardBackground)
                    .shadow(color: Color(red: 0.18, green: 0.14, blue: 0.08).opacity(0.08), radius: 5, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(OWColor.line, lineWidth: 0.6)
            )
    }
}

// MARK: - OWCollapsibleCard

struct OWCollapsibleCard<Trailing: View, Expanded: View>: View {
    let title: String
    let icon: String
    let help: String?
    @Binding var expanded: Bool
    let trailing: Trailing
    let expandedContent: Expanded

    init(
        title: String,
        icon: String,
        help: String? = nil,
        expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder expandedContent: () -> Expanded
    ) {
        self.title = title
        self.icon = icon
        self.help = help
        self._expanded = expanded
        self.trailing = trailing()
        self.expandedContent = expandedContent()
    }

    var body: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 0) {
                // Header row — always visible
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(OWColor.inkFaint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: expanded)

                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundColor(OWColor.accent.opacity(0.75))

                        Text(title)
                            .font(OWFont.sectionLabel(11))
                            .foregroundColor(OWColor.inkSoft)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded.toggle() } }

                    if let help {
                        OWInfoTip(text: help)
                            .padding(.leading, 6)
                    }

                    Spacer()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { expanded.toggle() } }

                    trailing
                }

                // Expanded content
                if expanded {
                    OWInternalDivider()
                        .padding(.top, 10)
                    expandedContent
                        .padding(.top, 8)
                }
            }
        }
    }
}

// MARK: - OWCardHeader

struct OWCardHeader: View {
    let title: String
    let icon: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(OWColor.accent)
                .frame(width: 2, height: 13)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(OWColor.accent.opacity(0.75))
            Text(title)
                .font(OWFont.sectionLabel(11))
                .foregroundColor(OWColor.inkSoft)
            if let help {
                OWInfoTip(text: help)
            }
        }
    }
}

// MARK: - OWInfoTip (visible ⓘ that reveals a help bubble on hover)

/// A small info icon next to a label; hovering it shows a styled help bubble.
/// Uses a popover (not `.help()`, which is unreliable inside a MenuBarExtra popover)
/// so the bubble is always visible and never clipped by the card bounds.
struct OWInfoTip: View {
    let text: String
    @State private var show = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundColor(OWColor.accent.opacity(0.7))
            .contentShape(Rectangle())
            .onHover { show = $0 }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .frame(width: 232, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(OWColor.page)
            }
    }
}

// MARK: - OWPickerRow

struct OWPickerRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    let content: Content

    init(label: String, labelWidth: CGFloat = 60, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(OWFont.body(11))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content
        }
    }
}

// MARK: - OWInternalDivider

struct OWInternalDivider: View {
    var body: some View {
        Rectangle()
            .fill(OWColor.line)
            .frame(height: 0.5)
    }
}

// MARK: - OWMenuPicker (custom SwiftUI dropdown — avoids dark AppKit NSPopUpButton)

struct OWMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(id: T, label: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    selection = option.id
                } label: {
                    if option.id == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(OWColor.accent.opacity(0.6))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(OWColor.pickerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(OWColor.checkboxBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var currentLabel: String {
        options.first(where: { $0.id == selection })?.label ?? ""
    }
}

// MARK: - OWAppPicker (searchable picker: favorites + every installed app)

/// Like `OWMenuPicker`, but backs a long, searchable list. The collapsed control
/// shows the current selection; tapping it opens a popover with a search field,
/// a "Favorites" section (the curated dev/terminal apps), an "Installed apps"
/// section (everything found on disk, type-to-filter), and a "Custom…" escape.
///
/// `selection` carries: a favorite id (its name), an installed app's bundle id,
/// or `"CUSTOM"`. `onSelect` fires with that id after a pick.
struct OWAppPicker: View {
    @Binding var selection: String
    let favorites: [AppEntry]   // bundleID holds the favorite's id (a display name)
    let installed: [AppEntry]
    let onSelect: (String) -> Void

    @State private var showPopover = false
    @State private var query = ""

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(OWColor.accent.opacity(0.6))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(OWColor.pickerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(OWColor.checkboxBorder, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search apps…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(OWFont.body(11))

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !filteredFavorites.isEmpty {
                            header("Favorites")
                            ForEach(filteredFavorites, id: \.bundleID) { fav in
                                row(id: fav.bundleID, label: fav.name)
                            }
                        }
                        if !filteredApps.isEmpty {
                            header("Installed apps")
                            ForEach(filteredApps, id: \.bundleID) { app in
                                row(id: app.bundleID, label: app.name)
                            }
                        }
                        Divider().padding(.vertical, 3)
                        row(id: "CUSTOM", label: "Custom…")
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 240, height: 250)
            }
            .padding(8)
            .background(OWColor.page)
        }
    }

    private var filteredApps: [AppEntry] {
        AppFilter.match(installed, query: query)
    }

    private var filteredFavorites: [AppEntry] {
        AppFilter.match(favorites, query: query)
    }

    private var currentLabel: String {
        if selection == "CUSTOM" { return "Custom…" }
        if let fav = favorites.first(where: { $0.bundleID == selection }) { return fav.name }
        if let app = installed.first(where: { $0.bundleID == selection }) { return app.name }
        return selection.isEmpty ? "Select app…" : selection
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(OWFont.body(9))
            .foregroundColor(OWColor.ink.opacity(0.5))
            .padding(.top, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(id: String, label: String) -> some View {
        Button {
            selection = id
            onSelect(id)
            query = ""
            showPopover = false
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
                    .foregroundColor(OWColor.accent)
                    .opacity(id == selection ? 1 : 0)
                Text(label)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OWCheckbox (custom SwiftUI checkbox — avoids dark AppKit NSButton)

struct OWCheckbox: View {
    let label: String
    @Binding var isOn: Bool
    var tint: Color = OWColor.accent

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? tint : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    isOn ? tint : OWColor.checkboxBorder,
                                    lineWidth: 1
                                )
                        )
                        .frame(width: 13, height: 13)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(OWColor.onAccent)
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: isOn)
                Text(label)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - InlineBadge

struct InlineBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(OWFont.caption())
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.10))
            )
    }
}

// MARK: - ModernStatusRow

struct ModernStatusRow: View {
    let label: String
    let subtitle: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.18))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(OWFont.body(11))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OWFont.caption(10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(":\(port)")
                .font(OWFont.mono(10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(OWColor.pillFill)
                )
        }
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        switch status {
        case .running: return OWColor.live
        case .starting: return OWColor.warn
        case .error: return OWColor.recording
        case .stopped: return OWColor.inkFaint
        }
    }
}

// MARK: - ModernDiagnosticRow

struct ModernDiagnosticRow: View {
    let label: String
    let ok: Bool
    var notInstalled: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(iconColor)

            Text(notInstalled ? "\(label) (not installed)" : label)
                .font(OWFont.body(11))
                .foregroundColor(notInstalled ? OWColor.inkFaint : (ok ? OWColor.ink : OWColor.inkSoft))
        }
    }

    private var iconName: String {
        if notInstalled { return "minus.circle" }
        return ok ? "checkmark.circle.fill" : "xmark.circle"
    }

    private var iconColor: Color {
        if notInstalled { return OWColor.inkFaint }
        return ok ? OWColor.live : OWColor.inkFaint
    }
}

// MARK: - SectionHeader (kept for backward compatibility)

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(title)
                .font(OWFont.sectionLabel())
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - CollapsibleHeader (kept for backward compatibility)

struct CollapsibleHeader<Trailing: View>: View {
    let title: String
    let icon: String
    @Binding var expanded: Bool
    let trailing: Trailing

    init(title: String, icon: String, expanded: Binding<Bool>, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self._expanded = expanded
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: expanded)
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(OWFont.sectionLabel())
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            trailing
        }
    }
}

extension CollapsibleHeader where Trailing == EmptyView {
    init(title: String, icon: String, expanded: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self._expanded = expanded
        self.trailing = EmptyView()
    }
}

// MARK: - Button Styles

struct OWPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OWFont.body(11).weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(OWColor.accent.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
            .foregroundColor(OWColor.onAccent)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct OWRowButtonStyle: ButtonStyle {
    var tinted: Bool = false
    var urgent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let color: Color = tinted ? OWColor.success : (urgent ? OWColor.warn : OWColor.inkSoft)
        configuration.label
            .font(OWFont.body(11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tinted || urgent
                          ? color.opacity(configuration.isPressed ? 0.22 : 0.14)
                          : OWColor.pillFill.opacity(configuration.isPressed ? 1.0 : 0.7))
            )
            .foregroundColor(color)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Legacy alias so existing call sites that use MenuBarButtonStyle still compile.
typealias MenuBarButtonStyle = OWPrimaryButtonStyle

/// Legacy alias so existing call sites that use MenuBarRowButtonStyle still compile.
typealias MenuBarRowButtonStyle = OWRowButtonStyle

// MARK: - PortField

struct PortField: View {
    let label: String
    @Binding var port: Int
    var disabled: Bool = false
    @State private var text: String = ""

    private var isValid: Bool {
        guard let p = Int(text) else { return false }
        return p >= 1024 && p <= 65535
    }

    var body: some View {
        HStack {
            if !label.isEmpty {
                Text(label)
                    .font(OWFont.body(11))
                    .frame(minWidth: 60, alignment: .leading)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1.0)
                .foregroundColor(isValid || text.isEmpty ? OWColor.ink : OWColor.danger)
                .onAppear { text = "\(port)" }
                .onChange(of: text) { _, newValue in
                    if let p = Int(newValue), p >= 1024, p <= 65535 {
                        port = p
                    }
                }
                .onChange(of: port) { _, newPort in
                    let portStr = "\(newPort)"
                    if text != portStr { text = portStr }
                }
        }
    }
}

// MARK: - DiagnosticRow (legacy alias → ModernDiagnosticRow)

struct DiagnosticRow: View {
    let label: String
    let ok: Bool
    var notInstalled: Bool = false

    var body: some View {
        ModernDiagnosticRow(label: label, ok: ok, notInstalled: notInstalled)
    }
}

// MARK: - StatusRow (legacy alias → ModernStatusRow)

struct StatusRow: View {
    let label: String
    let subtitle: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        ModernStatusRow(label: label, subtitle: subtitle, port: port, status: status)
    }
}
