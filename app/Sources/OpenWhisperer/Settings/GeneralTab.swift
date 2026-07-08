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
