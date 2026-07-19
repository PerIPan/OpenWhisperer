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
            MenuBarView()
                .environmentObject(appDelegate.serverManager)
                .environmentObject(appDelegate.setupManager)
                .environmentObject(appDelegate.dictationManager)
                .environmentObject(appDelegate.accessibilityManager)
                .onAppear {
                    appDelegate.setupDictation()
                }
        } label: {
            // Always-visible first-run signal: hourglass while the models load, waveform once ready.
            MenuBarStatusIcon(dictation: appDelegate.dictationManager, server: appDelegate.serverManager)
        }
        .menuBarExtraStyle(.window)
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
