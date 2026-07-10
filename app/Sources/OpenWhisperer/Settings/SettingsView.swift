import SwiftUI

/// The standard macOS Settings window: native toolbar tabs, one grouped Form per tab.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            InputTab()
                .tabItem { Label("Input", systemImage: "mic") }
            VoiceTab()
                .tabItem { Label("Voice", systemImage: "speaker.wave.2") }
            AgentsTab()
                .tabItem { Label("Agents", systemImage: "wand.and.stars") }
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
    }
}
