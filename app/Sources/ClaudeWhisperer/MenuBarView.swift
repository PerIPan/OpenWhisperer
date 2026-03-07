import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var setupManager: SetupManager
    @State private var autoSubmit = false
    @State private var autoFocusEnabled = false
    @State private var focusAppName = ""
    @State private var focusSelection = "Code"  // visual default; only written on explicit toggle
    @State private var customFocusApp = ""
    @State private var saveDebounce: DispatchWorkItem?

    private static let focusApps = [
        "Code",
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "Terminal",
        "iTerm2",
        "Warp",
        "Alacritty",
        "Ghostty",
        "Custom"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(.linearGradient(
                        colors: [.purple, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                Text("Claude Whisperer")
                    .font(.headline)
            }
            .padding(.bottom, 2)

            Divider().opacity(0.5)

            // Setup in progress
            if case .inProgress(let step) = setupManager.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ProgressView(value: setupManager.progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }
                .padding(.vertical, 4)
            } else if case .failed(let reason) = setupManager.state {
                VStack(alignment: .leading, spacing: 4) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.red)
                    Button("Retry Setup") {
                        setupManager.resetAndRerun { success in
                            if success { serverManager.startAll() }
                        }
                    }
                    .buttonStyle(MenuBarButtonStyle(tint: .orange))
                }
                .padding(.vertical, 4)
            } else {
                // Server status
                StatusRow(label: "Whisper STT", port: "\(serverManager.sttPort)", status: serverManager.sttStatus)
                StatusRow(label: "Kokoro TTS", port: "\(serverManager.ttsPort)", status: serverManager.ttsStatus)
            }

            Divider().opacity(0.5)

            // Automation group
            HStack(spacing: 4) {
                Image(systemName: "gearshape.2")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Automation")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Text("(Accessibility)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Toggle(isOn: $autoSubmit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Submit")
                    Text("Say \"submit\" / \"send\" at end of phrase")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .onChange(of: autoSubmit) { _, enabled in
                if enabled {
                    try? "on".write(to: Paths.autoSubmitFlag, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(at: Paths.autoSubmitFlag)
                }
            }

            Toggle(isOn: $autoFocusEnabled) {
                Text("Auto-Focus")
            }
            .toggleStyle(.checkbox)
            .onChange(of: autoFocusEnabled) { _, enabled in
                if enabled {
                    if focusAppName.isEmpty {
                        focusAppName = focusSelection == "Custom" ? customFocusApp : focusSelection
                    }
                    saveFocusApp()
                } else {
                    try? FileManager.default.removeItem(at: Paths.autoFocusApp)
                }
            }

            if autoFocusEnabled {
                Picker("", selection: $focusSelection) {
                    ForEach(Self.focusApps, id: \.self) { app in
                        Text(app).tag(app)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.leading, 20)
                .onChange(of: focusSelection) { _, newValue in
                    if newValue == "Custom" {
                        focusAppName = customFocusApp
                    } else {
                        focusAppName = newValue
                    }
                    saveFocusApp()
                }

                if focusSelection == "Custom" {
                    TextField("App name", text: $customFocusApp)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .padding(.leading, 20)
                        .onChange(of: customFocusApp) { _, newValue in
                            if !newValue.isEmpty {
                                focusAppName = newValue
                                debouncedSaveFocusApp()
                            }
                        }
                }
            }

            Divider().opacity(0.5)

            // Ports (always visible, editable only when stopped)
            let isStopped = serverManager.sttStatus == .stopped && serverManager.ttsStatus == .stopped
            PortField(label: "STT Port", port: $serverManager.sttPort, disabled: !isStopped)
            PortField(label: "TTS Port", port: $serverManager.ttsPort, disabled: !isStopped)

            // Server controls
            HStack(spacing: 6) {
                if isStopped {
                    Button(action: { serverManager.startAll() }) {
                        Label("Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarButtonStyle(tint: .green))
                } else {
                    Button(action: {
                        serverManager.stopAll()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            showStoppedAlert()
                        }
                    }) {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarButtonStyle(tint: .red))

                    Button(action: { serverManager.restartAll() }) {
                        Label("Restart", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MenuBarButtonStyle(tint: .orange))
                }
            }
            .padding(.top, 2)

            Divider().opacity(0.5)

            // Claude setup
            SectionHeader(title: "Claude Setup", icon: "hammer")

            Button(action: { ConfigManager.showClaudeSettingsInstructions() }) {
                Label("settings.json (Hook)", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(MenuBarRowButtonStyle())

            Button(action: { ConfigManager.showClaudeMdInstructions() }) {
                Label("CLAUDE.md (Voice Tag)", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(MenuBarRowButtonStyle())

            Divider().opacity(0.5)

            // Voquill
            SectionHeader(title: "Voquill", icon: "mic")

            Button(action: { ConfigManager.showVoquillInstructions(sttPort: serverManager.sttPort) }) {
                Label("Voquill Setup", systemImage: "mic.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(MenuBarRowButtonStyle())

            Button(action: { ConfigManager.showVoquillDownload() }) {
                Label("Get Voquill", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(MenuBarRowButtonStyle())

            Divider().opacity(0.5)

            // Logs
            SectionHeader(title: "Logs", icon: "doc.text.magnifyingglass")

            HStack(spacing: 6) {
                Button(action: { ConfigManager.showLog(name: "Whisper STT", url: Paths.sttLog) }) {
                    Label("STT", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())

                Button(action: { ConfigManager.showLog(name: "Kokoro TTS", url: Paths.ttsLog) }) {
                    Label("TTS", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuBarRowButtonStyle())
            }

            Divider().opacity(0.5)

            HStack {
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit", systemImage: "power")
                        .font(.caption)
                }
                .buttonStyle(MenuBarRowButtonStyle())
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear {
            autoSubmit = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
            autoFocusEnabled = FileManager.default.fileExists(atPath: Paths.autoFocusApp.path)
            if let saved = try? String(contentsOf: Paths.autoFocusApp, encoding: .utf8),
               !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = saved.trimmingCharacters(in: .whitespacesAndNewlines)
                focusAppName = name
                if Self.focusApps.contains(name) {
                    focusSelection = name
                } else {
                    focusSelection = "Custom"
                    customFocusApp = name
                }
            }
        }
    }

    private func saveFocusApp() {
        guard autoFocusEnabled, !focusAppName.isEmpty else { return }
        try? focusAppName.write(to: Paths.autoFocusApp, atomically: true, encoding: .utf8)
    }

    private func debouncedSaveFocusApp() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { saveFocusApp() }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func showStoppedAlert() {
        let alert = NSAlert()
        alert.messageText = "Servers Stopped"
        alert.informativeText = "Both STT and TTS servers have been stopped."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Button Styles

struct MenuBarButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(configuration.isPressed ? 0.25 : 0.15))
            )
            .foregroundColor(tint)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .foregroundColor(.primary)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Port Field

struct PortField: View {
    let label: String
    @Binding var port: Int
    var disabled: Bool = false
    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 60, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1.0)
                .onAppear { text = "\(port)" }
                .onChange(of: text) { _, newValue in
                    if let p = Int(newValue), p >= 1024, p <= 65535 {
                        port = p
                    }
                }
                .onChange(of: port) { _, newPort in
                    let portStr = "\(newPort)"
                    if text != portStr { text = portStr }
                }
        }
    }
}

// MARK: - Status Row

struct StatusRow: View {
    let label: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.6), radius: status == .running ? 3 : 0)
            Text(label)
                .font(.system(.caption, design: .default))
            Spacer()
            Text(":\(port)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}
