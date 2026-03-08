import AppKit
import SwiftUI
import CoreText

class AppDelegate: NSObject, NSApplicationDelegate {
    let serverManager = ServerManager()
    let setupManager = SetupManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationWillTerminate(_ notification: Notification) {
        serverManager.stopAll(synchronous: true)
        _ = ConfigManager.cleanTempFiles()
    }
}
