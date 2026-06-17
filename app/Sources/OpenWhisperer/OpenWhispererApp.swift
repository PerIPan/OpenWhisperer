import SwiftUI

@main
struct OpenWhispererApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Open Whisperer", systemImage: "waveform") {
            MenuBarView()
                .environmentObject(appDelegate.serverManager)
                .environmentObject(appDelegate.setupManager)
                .environmentObject(appDelegate.dictationManager)
                .environmentObject(appDelegate.accessibilityManager)
                .onAppear {
                    appDelegate.setupDictation()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
