import Foundation
import SwiftUI
import OpenWhispererKit

// MARK: - Platform

enum Platform: String, CaseIterable {
    case claudeCode = "claudeCode"
    case codexCLI = "codexCLI"

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        }
    }

    static func load() -> Platform {
        guard let raw = try? String(contentsOf: Paths.selectedPlatform, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let p = Platform(rawValue: raw) else { return .claudeCode }
        return p
    }

    func save() {
        try? rawValue.write(to: Paths.selectedPlatform, atomically: true, encoding: .utf8)
    }
}

enum ConfigManager {

    // MARK: - Claude Code: settings.json

    static func showClaudeSettingsInstructions() {
        let hookPath = Paths.ttsHook.path
        let window = InstructionWindow(
            title: "Step 1: Claude Code Hook (settings.json)",
            instructions: """
            Add the TTS hook to your Claude Code settings:

            1. Open ~/.claude/settings.json
               (or your project's .claude/settings.json)

            2. Add the following:

            {
              "hooks": {
                "Stop": [{
                  "hooks": [{
                    "type": "command",
                    "command": "\(hookPath)",
                    "timeout": 60,
                    "async": true
                  }]
                }]
              }
            }

            This makes Claude speak every response aloud.
            """
        )
        window.show()
    }

    // MARK: - Voquill Detection & Configuration

    static func isVoquillInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Voquill.app")
    }

    /// Check if Voquill's SQLite config points to the local Whisper server.
    /// NOTE: This runs a subprocess — call from a background thread to avoid blocking UI.
    static func isVoquillConfigured(port: Int) -> Bool {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.voquill.desktop/voquill.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPath, "SELECT base_url FROM api_keys WHERE provider='openai-compatible' LIMIT 1;"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        // Set a qualityOfService to ensure the process completes quickly
        proc.qualityOfService = .userInitiated
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return false }
            return output.contains("localhost:\(port)") || output.contains("127.0.0.1:\(port)")
        } catch {
            return false
        }
    }

    static func showVoquillInstructions(sttPort: Int) {
        let window = InstructionWindow(
            title: "Configure Voquill",
            instructions: """
            Set up Voquill to use your local Whisper server:

            1. Open Voquill → Settings → Providers
            2. Add or edit an "OpenAI Compatible" provider
            3. Set these values:

               Base URL:  http://localhost:\(sttPort)
               Model:     whisper
               API Key:   whisper

            4. Go to Settings → General
               Set Transcription to your new provider

            5. Make sure the Whisper server is running
               (green dot in menubar)

            Voquill will now use your local Whisper for
            high-accuracy, private transcription.
            """
        )
        window.show()
    }

    static func openVoquill() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Voquill.app"))
    }

    static func showVoquillDownload() {
        if let url = URL(string: "https://github.com/josiahsrc/voquill/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Superpowers (obra/superpowers plugin)

    static func showSuperpowersInstructions() {
        let window = InstructionWindow(
            title: "Superpowers — obra/superpowers",
            instructions: """
            Superpowers is an agentic skills framework that
            gives your coding agent a structured workflow:

            • Spec-first design before coding
            • Subagent-driven development
            • True red/green TDD, YAGNI, DRY
            • Autonomous multi-hour work sessions

            Auto-Apply runs:
              claude /plugin install superpowers@claude-plugins-official

            Or install manually in Claude Code:
              /plugin install superpowers@claude-plugins-official

            GitHub: https://github.com/obra/superpowers
            """
        )
        window.show()
    }

    static func applySuperpowers() -> (success: Bool, message: String) {
        let command = "claude '/plugin install superpowers@claude-plugins-official'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        return (true, "Copied! Paste in terminal, or ask Claude: 'install superpowers plugin'")
    }

    static func checkSuperpowersInstalled() -> Bool {
        // Check installed_plugins.json for any superpowers entry
        let installedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: installedPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return false }
        return plugins.keys.contains { $0.lowercased().contains("superpowers") }
    }

    // MARK: - Codex CLI: config.toml

    static func showCodexConfigInstructions() {
        let hookPath = Paths.codexTtsHook.path
        let window = InstructionWindow(
            title: "Step 1: Codex CLI Hook (config.toml)",
            instructions: """
            Add the TTS notify hook to your Codex CLI config:

            1. Open ~/.codex/config.toml
               (create it if it doesn't exist)

            2. Add the following line:

            notify = ["\(hookPath)"]

            This makes Codex speak every response aloud
            via the local TTS server.
            """
        )
        window.show()
    }

    // MARK: - Auto-apply hook to Codex config.toml

    static func applyHookToCodexConfig() -> (success: Bool, message: String) {
        let hookPath = Paths.codexTtsHook.path
        let configURL = Paths.codexConfig
        let fm = FileManager.default

        // Ensure ~/.codex/ exists
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lines: [String] = []
        if fm.fileExists(atPath: configURL.path),
           let content = try? String(contentsOf: configURL, encoding: .utf8) {
            lines = content.components(separatedBy: "\n")
        }

        // Find and replace existing `notify = ...` line, or append
        // Match exactly "notify" followed by optional whitespace and "=" to avoid
        // corrupting other keys like "notify_on_error"
        var found = false
        let newNotifyLine = "notify = [\"\(hookPath)\"]"
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            // Exact key match: "notify" followed by whitespace or "="
            if trimmed.hasPrefix("notify") {
                let rest = trimmed.dropFirst("notify".count)
                guard let first = rest.first, first == " " || first == "=" || first == "\t" else { continue }
                lines[i] = newNotifyLine
                found = true
                break
            }
        }
        if !found {
            // Add under existing content, ensure newline separation
            if !lines.isEmpty && !(lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                lines.append("")
            }
            lines.append(newNotifyLine)
        }

        let result = lines.joined(separator: "\n")
        do {
            try result.write(to: configURL, atomically: true, encoding: .utf8)
            return (true, found ? "Hook updated" : "Hook applied")
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Codex Diagnostics

    static func checkCodexHookConfigured() -> Bool {
        guard let content = try? String(contentsOf: Paths.codexConfig, encoding: .utf8) else { return false }
        return content.contains("codex-tts-hook") || content.contains("OpenWhisperer")
    }

    // MARK: - Platform-dispatching wrappers

    static func applyHook(for platform: Platform) -> (success: Bool, message: String) {
        switch platform {
        case .claudeCode: return applyHookToSettings()
        case .codexCLI: return applyHookToCodexConfig()
        }
    }

    static func checkHookConfigured(for platform: Platform) -> Bool {
        switch platform {
        case .claudeCode: return checkHookConfigured()
        case .codexCLI: return checkCodexHookConfigured()
        }
    }

    static func showHookInstructions(for platform: Platform) {
        switch platform {
        case .claudeCode: showClaudeSettingsInstructions()
        case .codexCLI: showCodexConfigInstructions()
        }
    }

    // MARK: - Auto-apply hook to settings.json

    /// Patterns that identify any Open Whisperer TTS hook command
    private static let hookPatterns = [
        "tts-hook.sh",
        "voice-context.sh",
        "Open Whisperer",
        "OpenWhisperer",
        "mlx-openai-whisper",
    ]

    /// Returns true if a hook command string belongs to Claude Whisper (any variant)
    private static func isOurHook(_ command: String) -> Bool {
        hookPatterns.contains { command.contains($0) }
    }

    static func applyHookToSettings() -> (success: Bool, message: String) {
        let hookPath = Paths.ttsHook.path
        let settingsDir = Paths.claudeSettings.deletingLastPathComponent()
        let fm = FileManager.default

        // Ensure ~/.claude/ exists
        try? fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: Paths.claudeSettings.path),
           let data = try? Data(contentsOf: Paths.claudeSettings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Get or create hooks.Stop array
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var stopArray = hooks["Stop"] as? [[String: Any]] ?? []

        // Remove ALL existing Claude Whisper/Whisperer hooks (any path variant)
        let countBefore = stopArray.count
        stopArray.removeAll { entry in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return isOurHook(cmd)
            }
        }
        let removed = countBefore - stopArray.count

        // Add exactly one hook with the current path
        let hookEntry: [String: Any] = ["type": "command", "command": hookPath, "timeout": 60, "async": true]
        let stopEntry: [String: Any] = ["hooks": [hookEntry]]
        stopArray.append(stopEntry)

        hooks["Stop"] = stopArray

        // Register the UserPromptSubmit voice-turn hook (idempotent: drop our old entries first).
        var upsArray = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
        upsArray.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { (($0["command"] as? String).map(isOurHook) ?? false) }
        }
        let upsHook: [String: Any] = ["type": "command", "command": Paths.voiceContextHook.path]
        upsArray.append(["hooks": [upsHook]])
        hooks["UserPromptSubmit"] = upsArray

        settings["hooks"] = hooks

        // Write back (convert to 2-space indent to match Claude Code style)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let rawString = String(data: jsonData, encoding: .utf8) else {
            return (false, "Failed to serialize JSON")
        }
        // Only replace leading indentation (not spaces inside string values)
        let jsonString = rawString
            .components(separatedBy: "\n")
            .map { line in
                let leading = line.prefix(while: { $0 == " " })
                let rest = line.dropFirst(leading.count)
                let halved = String(repeating: " ", count: leading.count / 2)
                return halved + rest
            }
            .joined(separator: "\n")

        do {
            try jsonString.write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
            let msg = removed > 0 ? "Replaced \(removed) old hook(s)" : "Hook applied"
            return (true, msg)
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Migration

    /// One-shot cleanup for existing installs: strip the legacy `## Voice Mode`
    /// block from the user's CLAUDE.md and Codex instructions.md.
    static func migrateRemoveVoiceTags() {
        let targets = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/instructions.md"),
        ]
        for url in targets {
            guard let existing = try? String(contentsOf: url, encoding: .utf8),
                  existing.contains("[VOICE:") || existing.contains("## Voice Mode") else { continue }
            let cleaned = VoiceMigration.stripVoiceBlock(from: existing).trimmingCharacters(in: .whitespacesAndNewlines)
            try? (cleaned + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Diagnostics

    static func checkHookConfigured() -> Bool {
        guard let data = try? Data(contentsOf: Paths.claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let stopArray = hooks["Stop"] as? [[String: Any]] else { return false }
        // Accept any Claude Whisper hook variant as "configured"
        return stopArray.contains { entry in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return isOurHook(cmd)
            }
        }
    }

    static func testTTS(port: Int, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://localhost:\(port)/v1/models") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    static func sttHasReceivedRequests() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: Paths.serverLog) else { return false }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        let start: UInt64 = size > 16384 ? size - 16384 : 0
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return false }
        return text.contains("POST /v1/audio/transcriptions") || text.contains("Transcribed:")
    }

    // MARK: - Clean Temp Files

    /// Remove stale TTS temp files, lock files, and PID files. Returns count of files removed.
    static func cleanTempFiles() -> Int {
        let fm = FileManager.default
        var count = 0

        // Clean TTS temp dir: ~/tmp or $TMPDIR/claude-tts-<uid>
        let uid = getuid()
        let tmpBase = NSTemporaryDirectory()
        let ttsTmpDir = (tmpBase as NSString).appendingPathComponent("claude-tts-\(uid)")
        if let files = try? fm.contentsOfDirectory(atPath: ttsTmpDir) {
            for file in files where file.hasPrefix("tts_") && file.hasSuffix(".wav") {
                try? fm.removeItem(atPath: (ttsTmpDir as NSString).appendingPathComponent(file))
                count += 1
            }
        }

        // Clean lock/pid files in app support (includes legacy two-server artifacts)
        let cleanFiles = [
            Paths.appSupport.appendingPathComponent("tts_hook.pid"),
            Paths.appSupport.appendingPathComponent("tts_playing.lock"),
            Paths.appSupport.appendingPathComponent("tts_hook.lock"),
            Paths.appSupport.appendingPathComponent("whisper.pid"),
            Paths.appSupport.appendingPathComponent("tts.pid"),
        ]
        for url in cleanFiles {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                count += 1
            }
        }

        return count
    }

    // MARK: - View Logs (individual)

    static func showLog(name: String, url: URL) {
        // Read only last 32KB to avoid memory spike on large logs (BUG-16)
        var content = ""
        if let fileHandle = try? FileHandle(forReadingFrom: url) {
            defer { fileHandle.closeFile() }
            let fileSize = fileHandle.seekToEndOfFile()
            let readStart: UInt64 = fileSize > 32768 ? fileSize - 32768 : 0
            fileHandle.seek(toFileOffset: readStart)
            let rawData = fileHandle.readDataToEndOfFile()
            // Try UTF-8 first, fall back to lossy Latin-1
            let decoded = String(data: rawData, encoding: .utf8)
                ?? String(data: rawData, encoding: .isoLatin1)
                ?? "(unable to read log)"
            if decoded == "(unable to read log)" {
                content = decoded
            } else {
                let lines = decoded.components(separatedBy: "\n")
                let cleanLines = readStart > 0 ? Array(lines.dropFirst()) : lines
                let tail = cleanLines.suffix(80).joined(separator: "\n")
                content = tail.isEmpty ? "(empty)" : tail
            }
        } else {
            content = "(no log file yet)"
        }

        let window = InstructionWindow(
            title: "\(name) Log",
            instructions: content
        )
        window.show()
    }
}

// MARK: - Instruction Window

class InstructionWindow: NSObject, NSWindowDelegate {
    private let title: String
    private let instructions: String
    private var window: NSWindow?

    // Keep alive until window closes — all access on main thread (BUG-10)
    private static var activeWindows: [InstructionWindow] = []

    init(title: String, instructions: String) {
        self.title = title
        self.instructions = instructions
    }

    func show() {
        DispatchQueue.main.async { [self] in
            // Append on main thread to avoid data race (BUG-10)
            InstructionWindow.activeWindows.append(self)

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = title
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self

            let hostingView = NSHostingView(rootView: InstructionView(
                title: title,
                instructions: instructions
            ))
            w.contentView = hostingView
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()

            self.window = w
        }
    }

    func windowWillClose(_ notification: Notification) {
        let cleanup = { InstructionWindow.activeWindows.removeAll { $0 === self } }
        if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
    }
}

struct InstructionView: View {
    let title: String
    let instructions: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(instructions)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            HStack {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instructions, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }) {
                    Label(copied ? "Copied!" : "Copy to Clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
            }
        }
        .padding(16)
    }
}
