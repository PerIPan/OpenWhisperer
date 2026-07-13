import SwiftUI
import OpenWhispererKit

/// Entry point. Normal launch runs the SwiftUI menu-bar app; `--serve-tts` runs a headless
/// native-TTS HTTP server (for testing/diagnostics and CI) without the GUI.
@main
enum OpenWhispererMain {
    static func main() {
        if CommandLine.arguments.contains("--serve-tts") {
            ServeTTSMode.run()
        } else if let flagIndex = CommandLine.arguments.firstIndex(of: "--diag-parakeet") {
            // Headless Parakeet probe — downloads/loads the TDT v3 CoreML models, then
            // transcribes any audio files listed after the flag. Exercises the full STT
            // path (model fetch → ANE compile → decode) without mic/TCC:
            //   swift run OpenWhisperer --diag-parakeet clip1.wav clip2.wav
            let files = CommandLine.arguments.suffix(from: flagIndex + 1)
            Task {
                do {
                    print("DIAG: preparing Parakeet TDT v3 (downloads ~460 MB if uncached)…")
                    let t0 = Date()
                    let parakeet = ParakeetTranscriber()
                    try await parakeet.prepare()
                    print("DIAG: Parakeet LOADED OK in \(Int(-t0.timeIntervalSinceNow))s")
                    for path in files {
                        let t1 = Date()
                        let text = try await parakeet.transcribe(
                            url: URL(fileURLWithPath: path), language: nil)
                        print("DIAG: \(path) [\(Int(-t1.timeIntervalSinceNow * 1000)) ms] → \(text)")
                    }
                } catch {
                    print("DIAG: Parakeet FAILED: \(error)")
                    print("DIAG: localizedDescription: \(error.localizedDescription)")
                    exit(1)
                }
                exit(0)
            }
            Task {
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                print("DIAG: TIMEOUT after 600s — Parakeet probe did not complete")
                exit(2)
            }
            RunLoop.main.run()
        } else {
            OpenWhispererApp.main()
        }
    }
}

struct OpenWhispererApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Register custom fonts before SwiftUI composes the first layout pass.
        registerBundledFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            SettingsMenuItems(history: appDelegate.transcriptionHistory)
        } label: {
            // Always-visible first-run signal: hourglass while the models load, waveform once ready.
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

/// Menubar menu content.
private struct SettingsMenuItems: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var history: TranscriptionHistory
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    /// Rows the dropdown shows; the buffer keeps `TranscriptHistoryBuffer.maxEntries`.
    private static let visibleRows = 10

    var body: some View {
        if history.items.isEmpty {
            // A plain Text renders as a disabled menu item.
            Text("No transcriptions yet")
        } else {
            // Newest first. The label is truncated; clicking copies the full text.
            ForEach(Array(history.items.prefix(Self.visibleRows).enumerated()), id: \.offset) { _, text in
                Button(TranscriptHistoryBuffer.menuLabel(text)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }

        Divider()

        Button("Clear History") { history.clear() }
            .disabled(history.items.isEmpty)

        Divider()

        // Model/setup status — the overlay shows only a red dot; the words live here.
        if let status = overlay.statusText {
            if overlay.statusIsError, let dm = overlay.dictationManager, dm.sttFailed {
                Button("\(status) — Retry") { dm.retrySTT() }
            } else {
                Text(status)
            }
            Divider()
        }

        Toggle("Show Overlay", isOn: Binding(
            get: { overlay.isVisible },
            set: { $0 ? overlay.show() : overlay.hide() }
        ))

        Divider()

        Button("Settings...") {
            // Activate the app to bring the Settings window to the front
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit OpenWhisperer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

/// The menu-bar icon. Shows an hourglass while a model is still loading (most visible on the
/// very first launch), a speaker while a dictated turn is armed to be spoken (the will-speak
/// indicator), and the waveform otherwise.
private struct MenuBarStatusIcon: View {
    @ObservedObject var dictation: DictationManager
    @ObservedObject var server: ServerManager

    var body: some View {
        let loading = (!dictation.sttModelReady && !dictation.sttFailed) || server.status == .starting
        Image(systemName: loading ? "hourglass" : (dictation.speakArmed ? "speaker.wave.2" : "waveform"))
    }
}
