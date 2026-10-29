import SwiftUI
import OpenWhispererKit

// MARK: - 1. Permissions

/// The only pane gating anything real: without Accessibility and Microphone the app cannot
/// work at all. It still does not block — see `FirstRunPane.blocksAdvance`.
struct FirstRunPermissionsPane: View {
    @EnvironmentObject var dictationManager: DictationManager
    @EnvironmentObject var accessibilityManager: AccessibilityManager

    var body: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWPermissionRow(label: "Accessibility", granted: accessibilityManager.isGranted) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                // The clipboard promise is a genuine trust asset and appeared nowhere a new
                // user would read it. First run is the one moment they are asking "what is
                // this thing about to do to my machine".
                Text("Lets Open Whisperer type dictated text into whatever app you're using. Your clipboard is never touched.")
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                OWInternalDivider()

                OWPermissionRow(label: "Microphone", granted: dictationManager.recorder.micPermission) {
                    dictationManager.recorder.openMicSettings()
                }
                Text("Lets it hear you. Audio is transcribed on this Mac and never leaves it.")
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)

                if !accessibilityManager.isGranted || !dictationManager.recorder.micPermission {
                    OWInternalDivider()
                    Text("You can grant these later in Settings → General — dictation just won't work until you do.")
                        .font(OWFont.caption(11))
                        .foregroundColor(OWColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 2. Dictate

struct FirstRunDictatePane: View {
    @EnvironmentObject var dictationManager: DictationManager

    @State private var selectedMode: InteractionMode = .holdToTalk
    @State private var selectedPTTKey = PTTKey.ctrl.rawValue
    @State private var selectedLanguage = "en"

    var body: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWPickerRow(label: "Mode", labelWidth: 78) {
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

                if selectedMode != .handsFree {
                    OWPickerRow(label: "Hold key", labelWidth: 78) {
                        OWMenuPicker(selection: $selectedPTTKey,
                                     options: PTTKey.allCases.map { (id: $0.rawValue, label: $0.label) })
                            .frame(maxWidth: .infinity)
                    }
                    .onChange(of: selectedPTTKey) { _, newValue in
                        try? newValue.write(to: Paths.pttHotkey, atomically: true, encoding: .utf8)
                        if let key = PTTKey(rawValue: newValue) {
                            TranscriptionOverlay.shared.pttKeyLabel = key.label
                        }
                    }
                }

                OWInternalDivider()

                OWPickerRow(label: "Language", labelWidth: 78) {
                    OWSearchablePicker(
                        selection: $selectedLanguage,
                        sections: SettingsData.languageSections,
                        placeholder: "Search languages…",
                        emptyLabel: "Auto-detect"
                    )
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    try? newValue.write(to: Paths.sttLanguage, atomically: true, encoding: .utf8)
                }

                // Sets the expectation the roster's tiers exist to set, without dragging the
                // full three-tier explanation into first run.
                Text("English by default. Pinning the language you actually speak beats Auto-detect — detection costs a decoder pass and is least reliable on short clips.")
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        selectedMode = InteractionMode.load()
        if let key = try? String(contentsOf: Paths.pttHotkey, encoding: .utf8) {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if PTTKey(rawValue: trimmed) != nil { selectedPTTKey = trimmed }
        }
        // Membership-checked like `DictationTab.load()`: an unrecognized code from a stale
        // `stt_language` would otherwise show as a raw string in the picker's label instead
        // of falling back to the default.
        if let lang = try? String(contentsOf: Paths.sttLanguage, encoding: .utf8) {
            let trimmed = lang.trimmingCharacters(in: .whitespacesAndNewlines)
            if SettingsData.languages.contains(where: { $0.id == trimmed }) {
                selectedLanguage = trimmed
            }
        }
    }
}

// MARK: - 3. Voice

/// Carries the disclosure this whole pane exists for: a Kokoro voice attaches a national
/// persona to every spoken reply, and until `VoicePersona` landed that was stated nowhere
/// in the app.
struct FirstRunVoicePane: View {
    @EnvironmentObject var serverManager: ServerManager

    @State private var selectedVoice = TTSVoiceRouter.defaultVoice
    @State private var selectedStyle = "normal"
    @State private var voiceSections: [OWPickerSection] = []

    var body: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWPickerRow(label: "Voice", labelWidth: 78) {
                    HStack(spacing: 6) {
                        OWSearchablePicker(
                            selection: $selectedVoice,
                            sections: voiceSections,
                            placeholder: "Search voices…",
                            emptyLabel: "Select voice…",
                            currentLabelOverride: SettingsData.voiceLabel(selectedVoice)
                        )
                        .frame(maxWidth: .infinity)

                        Button(action: preview) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(OWColor.accent)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Hear this voice read a fixed sample in its own language. It previews the voice, not the persona — a persona changes the words the model writes, not how the voice sounds.")
                    }
                }
                .onChange(of: selectedVoice) { _, newValue in
                    try? newValue.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
                    voiceSections = SettingsData.voiceSections
                }

                // Exactly one of these two ever renders: Supertonic voices carry a reply
                // language, Kokoro voices carry a persona.
                if let language = SettingsData.voiceLanguageName(selectedVoice) {
                    Text("Replies will be spoken in \(language). Your on-screen reply stays in the language of the conversation.")
                        .font(OWFont.caption(11))
                        .foregroundColor(OWColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let persona = VoicePersona.disclosure(for: selectedVoice) {
                    Text(persona)
                        .font(OWFont.caption(11))
                        .foregroundColor(OWColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Non-default voices download the first time they're used.")
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkFaint)

                OWInternalDivider()

                OWPickerRow(label: "Length", labelWidth: 78) {
                    OWMenuPicker(selection: $selectedStyle, options: SettingsData.styleLevels)
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedStyle) { _, newValue in
                    try? newValue.write(to: Paths.ttsStyle, atomically: true, encoding: .utf8)
                }
                Text("How much of a reply is spoken aloud.")
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
            }
        }
        .onAppear(perform: load)
    }

    private func preview() {
        let voice = selectedVoice
        Task {
            await serverManager.playback.replaceNow(
                text: TTSSampleText.sample(forVoiceID: voice),
                voice: voice,
                speed: TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8)))
        }
    }

    private func load() {
        voiceSections = SettingsData.voiceSections
        if let saved = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8) {
            let voice = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if SettingsData.allVoices.contains(where: { $0.id == voice }) { selectedVoice = voice }
        }
        if let saved = try? String(contentsOf: Paths.ttsStyle, encoding: .utf8) {
            let style = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if SettingsData.styleLevels.contains(where: { $0.id == style }) { selectedStyle = style }
        }
    }
}

// MARK: - 4. Agent

/// Lists every agent, but puts the ones actually present on this machine first.
///
/// What this replaces: `showHookInstructions(for: Platform.load())` fired one second after
/// first launch, and `load()` falls back to `.claudeCode` when nothing is stored — which is
/// exactly the first-run state. Every new user got Claude Code JSON regardless of what they
/// run. The manual config is still reachable, just no longer the opening move.
struct FirstRunAgentPane: View {
    @State private var connected: [Platform: Bool] = [:]
    @State private var ordered: [Platform] = Platform.allCases
    @State private var present: Set<Platform> = []
    @State private var lastResult: (platform: Platform, ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OWCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(ordered.enumerated()), id: \.element) { index, platform in
                        if index > 0 { OWInternalDivider() }
                        row(platform)
                    }
                }
            }

            if let result = lastResult {
                OWCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(result.ok ? OWColor.live : OWColor.danger)
                            Text(result.message)
                                .font(OWFont.body(11))
                                .foregroundColor(OWColor.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Codex silently skips untrusted hooks, so this is a hard blocker
                        // rather than a nicety. AGENTS.md promised "the setup window says
                        // so" for years while no setup window existed; this is that window.
                        if result.ok, let step = nextStep(for: result.platform) {
                            Text(step)
                                .font(OWFont.caption(11))
                                .foregroundColor(OWColor.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func row(_ platform: Platform) -> some View {
        let isConnected = connected[platform] ?? false
        let isPresent = present.contains(platform)
        return HStack(spacing: 8) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundColor(isConnected ? OWColor.live : OWColor.inkFaint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(platform.label)
                        .font(OWFont.body(12))
                        .foregroundColor(OWColor.ink)
                    Button { ConfigManager.showHookInstructions(for: platform) } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(OWColor.inkFaint)
                    }
                    .buttonStyle(.plain)
                    .help("Show the config to apply by hand")
                }
                Text(isConnected ? "Connected"
                     : (isPresent ? "Found on this Mac" : "Not detected"))
                    .font(OWFont.caption())
                    .foregroundColor(isConnected ? OWColor.inkSoft
                                     : (isPresent ? OWColor.accentDeep : OWColor.inkFaint))
            }

            Spacer(minLength: 6)

            Button(isConnected ? "Reconnect" : "Connect") { connect(platform) }
                .buttonStyle(OWRowButtonStyle(tinted: isConnected, urgent: !isConnected && isPresent))
                .frame(width: 104)
        }
    }

    private func connect(_ platform: Platform) {
        let result = ConfigManager.applyHook(for: platform)
        lastResult = (platform, result.success, result.message)
        if result.success { platform.save() }
        refresh()
    }

    private func refresh() {
        var next: [Platform: Bool] = [:]
        for platform in Platform.allCases {
            next[platform] = ConfigManager.checkHookConfigured(for: platform)
        }
        connected = next
        present = Set(AgentDetection.presentPlatforms())
        ordered = AgentDetection.orderedByPresence()
    }

    private func nextStep(for platform: Platform) -> String? {
        switch platform {
        case .claudeCode: return "Start a new Claude Code session to pick up the hook."
        case .codexCLI: return "Codex skips untrusted hooks — approve the Open Whisperer hook once when Codex prompts you, or dictated turns stay silent."
        case .pi: return "Run /reload in Pi to load the extension."
        case .antigravity: return "Start a new agy session to pick up the hook."
        }
    }
}
