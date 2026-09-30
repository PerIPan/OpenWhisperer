import SwiftUI
import ServiceManagement
import OpenWhispererKit

/// "Is everything OK" tab: first-run/model health, startup, the canonical permission
/// list, and the version footer.
struct GeneralTab: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @EnvironmentObject var dictationManager: DictationManager
    @EnvironmentObject var accessibilityManager: AccessibilityManager
    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var launchAtLogin = false
    @State private var diagnosticsCopied = false
    @State private var selectedMode: InteractionMode = .holdToTalk

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            setupProgressSection
            modelLoadingBanner
            aboutCard

            OWCard {
                VStack(alignment: .leading, spacing: 8) {
                    OWCardHeader(title: allPermissionsGranted ? "Permissions" : "Permissions Required",
                                 icon: "lock.shield",
                                 help: "macOS grants Open Whisperer needs: Accessibility (type into the focused app), Microphone (record dictation), and Speech Recognition (hands-free wake words). Click a row to open Settings.")

                    OWPermissionRow(label: "Accessibility", granted: accessibilityManager.isGranted) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .help("Lets the app type dictated text into the focused app — the clipboard is never touched.")

                    OWPermissionRow(label: "Microphone", granted: dictationManager.recorder.micPermission) {
                        dictationManager.recorder.openMicSettings()
                    }
                    .help("Lets the app record your microphone to capture dictation.")

                    // Hands-free only — don't nag for a grant the current mode never uses.
                    if selectedMode == .handsFree {
                        OWPermissionRow(label: "Speech Recognition",
                                        granted: dictationManager.keywordDetector.permissionGranted) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .help("Hands-Free only: Apple Speech detects the wake words \"initiate\" and \"hold on\".")
                    } else {
                        Text("Speech Recognition is only needed in Hands-Free mode.")
                            .font(OWFont.caption())
                            .foregroundColor(OWColor.inkFaint)
                    }
                }
            }

            themesCard
            startupCard
        }
        // Version now lives in the tab bar (right of the tabs), so no footer here.
        .onAppear {
            selectedMode = InteractionMode.load()
            // Re-read mic/speech authorization on every appearance so a grant (or
            // revocation) made in System Settings shows up without relaunching.
            // Accessibility has its own continuous poll. Speech only in hands-free —
            // otherwise we'd re-request a permission that mode never uses.
            dictationManager.recorder.checkPermission()
            if selectedMode == .handsFree {
                dictationManager.keywordDetector.checkPermission()
            }
            // SMAppService.mainApp.status is a synchronous XPC call to launchservicesd and
            // can block the main thread for seconds; resolve it off-main.
            DispatchQueue.global(qos: .userInitiated).async {
                let enabled = SMAppService.mainApp.status == .enabled
                DispatchQueue.main.async { launchAtLogin = enabled }
            }
        }
    }

    /// Appearance picker. Sits above Startup so the set-once login toggle stays last.
    private var themesCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "Themes", icon: "paintpalette",
                             help: "The app's colour palette — Settings, the menubar popover and "
                                 + "the overlay all follow it. Cream is Open Whisperer's own "
                                 + "identity and the only theme that follows your system's "
                                 + "light/dark setting; the rest hold their look either way.")

                OWPickerRow(label: "Theme", labelWidth: 74) {
                    OWMenuPicker(
                        selection: Binding(
                            get: { themeManager.theme.rawValue },
                            set: { themeManager.theme = OWTheme.parse($0) }
                        ),
                        options: OWTheme.allCases.map { ($0.rawValue, $0.label) })
                        .frame(maxWidth: .infinity)
                }

                // Matches the Dictation tab's mode caption (11pt / inkSoft) rather than the
                // fainter 10pt default — this line carries the follows-system-vs-fixed caveat,
                // so it is the last place to under-emphasise.
                Text(themeManager.theme.summary)
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Set-once preference, so it sits last — below Permissions, which is the tab's
    /// actionable content (a missing grant breaks dictation outright).
    private var startupCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                OWCardHeader(title: "Startup", icon: "power",
                             help: "Launch Open Whisperer automatically when you log in.")
                OWCheckbox(label: "Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        let service = SMAppService.mainApp
                        do {
                            if enabled { try service.register() } else { try service.unregister() }
                        } catch {
                            NSLog("Login item toggle failed: \(error)")
                            DispatchQueue.main.async { launchAtLogin = service.status == .enabled }
                        }
                    }
            }
        }
    }

    /// Speech Recognition is hands-free-only, so it counts toward "all granted" only in
    /// that mode — otherwise a hold-to-talk user who never granted it reads as incomplete.
    private var allPermissionsGranted: Bool {
        let speechNeeded = selectedMode == .handsFree
        return accessibilityManager.isGranted
            && dictationManager.recorder.micPermission
            && (!speechNeeded || dictationManager.keywordDetector.permissionGranted)
    }

    // MARK: - About

    /// Identity block: wordmark, version, and what the app actually is — the engines
    /// and the headline features. The version used to sit in the tab bar, where it
    /// read as a fifth, disabled tab.
    private var aboutCard: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Whisperer")
                            .font(OWFont.title(17))
                            .foregroundColor(OWColor.ink)
                        Text("Voice mode for your coding agent — dictation in, spoken replies out. Everything runs on this Mac; nothing is sent to the cloud.")
                            .font(OWFont.caption(11))
                            .foregroundColor(OWColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(OWFont.body(11))
                        .foregroundColor(OWColor.inkSoft)
                        .monospacedDigit()
                }

                OWInternalDivider()

                // Counts are read from the rosters, never written here: the previous
                // hardcoded copy ("9 languages, plus Supertonic-3 for Dutch, German,
                // Polish, Russian and Ukrainian") silently went stale when the pickers
                // were widened, and shipped wrong.
                // Model name is read from the active checkpoint, never written here: it
                // changes when "Translate to English" swaps the model, and the hardcoded
                // copy in this card has already shipped stale once.
                engineRow(icon: "waveform",
                          title: "Speech to text",
                          detail: "\(SpeechTranscriber.activeChoice.displayName) — on the Apple Neural Engine, \(SettingsData.supportedLanguages.count) languages")
                engineRow(icon: "speaker.wave.2",
                          title: "Text to speech",
                          detail: "Kokoro-82M and Supertonic-3 — \(TTSVoiceRegistry.allVoices.count) voices across \(TTSVoiceRegistry.languageCount) languages, on the Neural Engine")

                OWInternalDivider()

                Text("Three ways to dictate (hold, press, or hands-free), spoken replies for Claude Code, Codex, Pi and Antigravity, and a live transcription overlay. Settings → Advanced can also translate what you say into English as you dictate.")
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func engineRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(OWColor.accentDeep)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                Text(detail)
                    .font(OWFont.caption(11))
                    .foregroundColor(OWColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - First-run signals

    @ViewBuilder
    private var setupProgressSection: some View {
        if case .inProgress(let step) = setupManager.state {
            OWCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(step).font(OWFont.caption()).foregroundColor(.secondary)
                    ProgressView(value: setupManager.progress)
                        .progressViewStyle(.linear)
                        .tint(OWColor.accent)
                }
            }
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
        }
    }

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
                            Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
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
                    if ttsLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Voice model still loading…")
                                .font(OWFont.caption(11))
                                .foregroundColor(OWColor.inkSoft)
                        }
                    }
                }
            }
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
        }
    }
}
