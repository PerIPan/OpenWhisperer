import SwiftUI

/// Entry point. Normal launch runs the SwiftUI menu-bar app; `--serve-tts` runs a headless
/// native-TTS HTTP server (for testing/diagnostics and CI) without the GUI.
@main
enum OpenWhispererMain {
    static func main() {
        if CommandLine.arguments.contains("--serve-tts") {
            ServeTTSMode.run()
        } else if CommandLine.arguments.contains("--diag-stt") {
            // Headless STT load probe — spins the main run loop (so MainActor work can proceed,
            // unlike a main-thread semaphore wait) and prints the exact WhisperKit load result.
            Task {
                do {
                    print("DIAG: preparing WhisperKit (offline-first)…")
                    let t0 = Date()
                    _ = try await SpeechTranscriber().prepare()
                    print("DIAG: STT model LOADED OK in \(Int(-t0.timeIntervalSinceNow))s")
                } catch {
                    print("DIAG: STT load FAILED: \(error)")
                    print("DIAG: localizedDescription: \(error.localizedDescription)")
                }
                exit(0)
            }
            Task {
                try? await Task.sleep(nanoseconds: 240 * 1_000_000_000)
                print("DIAG: TIMEOUT after 240s — load did not complete")
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
    @Environment(\.openWindow) private var openWindow

    init() {
        // Register custom fonts before SwiftUI composes the first layout pass.
        registerBundledFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit OpenWhisperer") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            // Always-visible first-run signal: hourglass while the models load, waveform once ready.
            MenuBarStatusIcon(dictation: appDelegate.dictationManager, server: appDelegate.serverManager)
        }

        Window("OpenWhisperer Settings", id: "settings") {
            MenuBarView()
                .environmentObject(appDelegate.serverManager)
                .environmentObject(appDelegate.setupManager)
                .environmentObject(appDelegate.dictationManager)
                .environmentObject(appDelegate.accessibilityManager)
        }
        .windowResizability(.contentSize)
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
