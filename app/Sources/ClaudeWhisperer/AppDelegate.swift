import AppKit
import SwiftUI
import CoreText

class AppDelegate: NSObject, NSApplicationDelegate {
    let serverManager = ServerManager()
    let setupManager = SetupManager()
    let dictationManager = DictationManager()
    let hotkeyManager = HotkeyManager()
    let accessibilityManager = AccessibilityManager()
    private var dictationSetupDone = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for Accessibility permission if not already granted
        accessibilityManager.requestIfNeeded()
        // Clean stale temp/lock/pid files from previous sessions (background, delayed)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            _ = ConfigManager.cleanTempFiles()
        }

        // Register bundled Outfit font
        if let fontURL = Bundle.main.url(forResource: "Outfit-VariableFont_wght", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }

        // Hide dock icon (menubar-only app)
        NSApp.setActivationPolicy(.accessory)

        // Start hotkey listener immediately so Ctrl works without opening the menubar first
        setupDictation()

        if setupManager.isSetupComplete {
            serverManager.startAll()
        } else {
            setupManager.runFirstLaunchSetup { [weak self] success in
                guard success else { return }
                // startAll must run on main thread (BUG-11: timer + process management)
                DispatchQueue.main.async {
                    self?.serverManager.startAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        ConfigManager.showClaudeSettingsInstructions()
                    }
                }
            }
        }
    }

    func setupDictation() {
        // Bug 4: guard against duplicate calls from onAppear
        guard !dictationSetupDone else { return }
        dictationSetupDone = true

        // Capture the frontmost app PID at the moment Ctrl is pressed down,
        // before recording UI or any window can steal focus away.
        hotkeyManager.onCtrlDown = { [weak self] in
            self?.dictationManager.captureTargetApp()
        }
        hotkeyManager.onToggle = { [weak self] in
            self?.dictationManager.toggle()
        }
        hotkeyManager.start()

        TranscriptionOverlay.shared.dictationManager = dictationManager
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        serverManager.stopAll(synchronous: true)
        _ = ConfigManager.cleanTempFiles()
    }
}
