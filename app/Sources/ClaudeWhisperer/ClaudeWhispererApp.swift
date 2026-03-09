import SwiftUI

@main
struct ClaudeWhispererApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Claude Whisperer", systemImage: "waveform") {
            MenuBarView()
                .environmentObject(appDelegate.serverManager)
                .environmentObject(appDelegate.setupManager)
                .environmentObject(appDelegate.dictationManager)
                .onAppear {
                    appDelegate.dictationManager.updatePort(appDelegate.serverManager.port)
                    appDelegate.setupDictation()
                }
                .onChange(of: appDelegate.serverManager.port) { _, newPort in
                    appDelegate.dictationManager.updatePort(newPort)
                }
        }
        .menuBarExtraStyle(.window)
    }
}
