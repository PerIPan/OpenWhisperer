import SwiftUI
import OpenWhispererKit

/// Entry point. Normal launch runs the SwiftUI menu-bar app; `--serve-tts` runs a headless
/// native-TTS HTTP server (for testing/diagnostics and CI) without the GUI.
@main
enum OpenWhispererMain {
    static func main() {
        if CommandLine.arguments.contains("--serve-tts") {
            ServeTTSMode.run()
        } else if CommandLine.arguments.contains("--diag-stt") {
            // Headless STT load probe — spins the main run loop (so MainActor work can
            // proceed, unlike a main-thread semaphore wait) and prints the exact
            // WhisperKit load result. Exercises model fetch → ANE compile without mic/TCC.
            Task {
                do {
                    print("DIAG: preparing WhisperKit (offline-first)…")
                    let t0 = Date()
                    _ = try await SpeechTranscriber().prepare()
                    print("DIAG: STT model LOADED OK in \(Int(-t0.timeIntervalSinceNow))s")
                } catch {
                    print("DIAG: STT load FAILED: \(error)")
                    print("DIAG: localizedDescription: \(error.localizedDescription)")
                    exit(1)   // non-zero so CI/scripts see the failure
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

    init() {
        // Register custom fonts before SwiftUI composes the first layout pass.
        registerBundledFonts()
    }

    var body: some Scene {
        // Plain menu dropdown — the settings themselves live in the branded
        // SettingsWindow (see Settings/SettingsWindow.swift).
        MenuBarExtra {
            MenuBarMenu(appDelegate: appDelegate)
        } label: {
            // Always-visible first-run signal: hourglass while the models load, waveform once ready.
            MenuBarStatusIcon(dictation: appDelegate.dictationManager,
                              server: appDelegate.serverManager,
                              accessibility: appDelegate.accessibilityManager)
        }
    }
}

/// Menubar dropdown contents.
private struct MenuBarMenu: View {
    let appDelegate: AppDelegate
    @ObservedObject private var overlay = TranscriptionOverlay.shared
    /// Observed so the checkmark tracks changes made in Settings → Advanced too.
    @ObservedObject private var dictation: DictationManager

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.dictation = appDelegate.dictationManager
    }

    var body: some View {
        Button("Settings…") {
            SettingsWindow.show(tab: SettingsWindow.preferredTab(for: appDelegate),
                                appDelegate: appDelegate)
        }
        .keyboardShortcut(",", modifiers: .command)

        Toggle("Show Overlay", isOn: Binding(
            get: { overlay.isVisible },
            set: { $0 ? overlay.show() : overlay.hide() }
        ))

        Button("Record Voice & Text") { RecordingWindow.show() }

        // Quick access on purpose: this gets flipped mid-conversation, which is exactly when
        // you don't want to go hunting through Settings. Same consent + model swap as the
        // Advanced tab — both go through `TranslateToggle`.
        Toggle("Translate to English", isOn: Binding(
            get: { dictation.translateToEnglish },
            set: { TranslateToggle.request($0, on: dictation) }
        ))

        Divider()

        // The setup sheet's "Skip setup" tooltip promises you can reopen it from here, and
        // a first run that can only ever happen once is hostile anyway: connecting a second
        // agent, or granting a permission you skipped, is exactly when you want it back.
        Button("Setup…") {
            FirstRunWindow.show(appDelegate: appDelegate) {
                appDelegate.setupManager.runFirstLaunchSetup { _ in }
            }
        }

        Button("Quit Open Whisperer") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

/// The menu-bar icon. Shows an hourglass while a model is still loading (most visible on the
/// very first launch), a speaker while a dictated turn is armed to be spoken (the will-speak
/// indicator), an exclamation badge when a required permission is missing, and the waveform
/// otherwise. The badge is the only permission signal visible with the window closed.
private struct MenuBarStatusIcon: View {
    @ObservedObject var dictation: DictationManager
    @ObservedObject var server: ServerManager
    @ObservedObject var accessibility: AccessibilityManager

    var body: some View {
        let loading = (!dictation.sttModelReady && !dictation.sttFailed) || server.status == .starting
        let needsGrant = !accessibility.isGranted || !dictation.recorder.micPermission
        if loading {
            Image(systemName: "hourglass")
        } else if needsGrant {
            Image(systemName: "exclamationmark.triangle")
        } else {
            Image(systemName: dictation.speakArmed ? "speaker.wave.2" : "waveform")
        }
    }
}
