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
    }
}
