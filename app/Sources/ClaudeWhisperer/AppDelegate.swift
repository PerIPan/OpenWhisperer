import AppKit
import SwiftUI
import CoreText

class AppDelegate: NSObject, NSApplicationDelegate {
    let serverManager = ServerManager()
    let setupManager = SetupManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }
}
