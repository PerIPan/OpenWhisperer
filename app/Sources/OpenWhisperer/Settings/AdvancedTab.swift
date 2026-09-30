import AppKit
import SwiftUI
import OpenWhispererKit

/// Local engine internals — model status, the TTS server process, and logs.
/// Troubleshooting surface; a typical user never opens this.
struct AdvancedTab: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var dictationManager: DictationManager

    @State private var serverReachable = false
    @State private var showStoppedBanner = false
    @State private var deletedModelsBanner = false
    @State private var diagnosticsCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OWCard {
                VStack(alignment: .leading, spacing: 8) {
                    OWCardHeader(title: "Models", icon: "cpu",
                                 help: "The on-device speech models. They re-download automatically after deletion.")

                    VStack(spacing: 0) {
                        ModernStatusRow(
                            label: "Whisper STT",
                            subtitle: dictationManager.sttModelReady
                                ? SpeechTranscriber.activeChoice.displayName
                                : (dictationManager.sttStatus ?? "Loading…"),
                            port: "local",
                            status: dictationManager.sttModelReady ? .running : .starting
                        )
                        OWInternalDivider()
                        ModernStatusRow(
                            label: "TTS engines",
                            subtitle: serverManager.ttsModel,
                            port: "\(serverManager.port)",
                            status: serverManager.status
                        )
                    }

                    OWInternalDivider()

                    // Translation lives here, beside the model rows, because it *is* a model
                    // decision: the default turbo checkpoint cannot translate at all, so
                    // enabling this swaps the whole speech model (see `STTModelChoice`).
                    VStack(alignment: .leading, spacing: 6) {
                        OWCheckbox(
                            label: "Translate to English",
                            isOn: Binding(get: { dictationManager.translateToEnglish },
                                          set: { TranslateToggle.request($0, on: dictationManager) })
                        )
                        Text(translateHint)
                            .font(OWFont.caption(11))
                            .foregroundColor(dictationManager.sttFailed ? OWColor.warn : OWColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Destructive: must not look identical to "Server Log".
                    Button(action: deleteModels) {
                        Label("Delete downloaded models…", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(OWColor.danger)
                    }
                    .buttonStyle(OWRowButtonStyle())

                    if deletedModelsBanner {
                        Text("Models deleted — they'll re-download on next use")
                            .font(OWFont.body(11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .transition(.opacity)
                    }
                }
            }

            OWCard {
                VStack(alignment: .leading, spacing: 8) {
                    OWCardHeader(title: "Server", icon: "server.rack",
                                 help: "The loopback text-to-speech server (localhost only). Dictation runs separately from this.")

                    let serverStopped = serverManager.status == .stopped
                    HStack(spacing: 6) {
                        if serverStopped || serverManager.status == .error {
                            Button(action: { serverManager.startAll() }) {
                                Label("Start Server", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(OWRowButtonStyle())
                        } else {
                            Button(action: {
                                serverManager.stopAll()
                                showStoppedBanner = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showStoppedBanner = false }
                            }) {
                                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(OWRowButtonStyle())
                        }
                        PortField(label: "", port: $serverManager.port, disabled: !serverStopped)
                    }

                    if showStoppedBanner {
                        Text("Server stopped")
                            .font(OWFont.body(11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .transition(.opacity)
                    }

                    // Tri-state: a stopped server is off on purpose, not an error.
                    if serverManager.status == .stopped {
                        ModernDiagnosticRow(label: "Stopped", ok: false, notInstalled: true)
                    } else {
                        ModernDiagnosticRow(label: "Reachable on :\(serverManager.port)",
                                            ok: serverReachable)
                    }

                    if serverManager.status != .stopped {
                        Text("Stop the server to change the port.")
                            .font(OWFont.caption())
                            .foregroundColor(OWColor.inkFaint)
                    }
                }
            }

            OWCard {
                VStack(alignment: .leading, spacing: 8) {
                    OWCardHeader(title: "Diagnostics", icon: "stethoscope",
                                 help: "Logs and a support-ready report you can paste into an issue.")

                    HStack(spacing: 6) {
                        Button(action: { ConfigManager.showLog(name: "Server", url: Paths.serverLog) }) {
                            Label("Server Log", systemImage: "doc.text").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OWRowButtonStyle())

                        Button(action: {
                            ConfigManager.showLog(
                                name: "Events",
                                url: Paths.appSupport.appendingPathComponent("paste_debug.log")
                            )
                        }) {
                            Label("Events Log", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity)
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
        }
        // A real loopback probe (not just the manager's status flag) — the server can be
        // "running" but unreachable if the port is taken or it failed to bind.
        .onAppear(perform: probeServer)
        .onChange(of: serverManager.status) { _, _ in probeServer() }
    }

    private var translateHint: String {
        // A failed swap leaves translation *selected* but no model resident, so saying it
        // works would be a lie and the user would have no idea why dictation went quiet.
        if dictationManager.sttFailed {
            return dictationManager.translateToEnglish
                ? "The translation model couldn't be loaded, so dictation is unavailable. Turn this off to go back to the normal speech model, or retry from the model row above."
                : "The speech model couldn't be loaded — dictation is unavailable until it succeeds."
        }
        if !dictationManager.sttModelReady, dictationManager.translateToEnglish {
            return "Getting the translation model ready — this takes a couple of minutes the first time. Dictation is unavailable until it finishes."
        }
        return dictationManager.translateToEnglish
            ? "Speak any language — it's typed out in English. Uses a larger speech model, so dictation takes about twice as long, and the spoken language is detected automatically (your Dictation → Language choice is ignored while this is on)."
            : "Off — transcripts stay in the language you speak."
    }

    private func probeServer() {
        ConfigManager.testTTS(port: serverManager.port) { ok in
            DispatchQueue.main.async { serverReachable = ok }
        }
    }

    /// A SwiftUI `.alert` was unreliable inside the old popover; the standalone
    /// window makes that moot, but NSAlert stays for consistency with other confirms.
    private func deleteModels() {
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
