import Foundation
import SwiftUI
import OpenWhispererKit

// MARK: - Platform

enum Platform: String, CaseIterable {
    case claudeCode = "claudeCode"
    case codexCLI = "codexCLI"
    case pi = "pi"
    case antigravity = "antigravity"
    case claudeDesktop = "claudeDesktop"

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .pi: return "Pi"
        case .antigravity: return "Antigravity"
        case .claudeDesktop: return "Claude Desktop"
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

    static func showClaudeMCPInstructions() {
        let window = InstructionWindow(
            title: "Step 1: Claude Code voice (hook + speak tool)",
            instructions: """
            OpenWhisperer adds voice to Claude Code in two pieces. "Apply" wires
            both automatically; to do it by hand:

            1) UserPromptSubmit hook (in ~/.claude/settings.json) — nudges Claude to
               speak a summary first on dictated turns:

               {
                 "hooks": {
                   "UserPromptSubmit": [{
                     "hooks": [{ "type": "command", "command": "\(Paths.voiceContextHook.path)" }]
                   }]
                 }
               }

            2) The `speak` MCP tool (in ~/.claude.json) — lets Claude play that summary:

               claude mcp add --scope user --transport http \\
                 OpenWhisperer http://localhost:8000/mcp

            Then RESTART Claude Code so it loads the tool. Verify with:  /mcp
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

    // MARK: - Codex CLI: config.toml

    static func showCodexConfigInstructions() {
        let window = InstructionWindow(
            title: "Step 1: Codex voice (config.toml + hook trust)",
            instructions: """
            "Apply" wires these into ~/.codex/config.toml automatically. To do it
            by hand, add:

            [mcp_servers.OpenWhisperer]
            url = "http://localhost:8000/mcp"

            [[hooks.UserPromptSubmit]]

            [[hooks.UserPromptSubmit.hooks]]
            type = "command"
            command = "\(Paths.voiceContextHook.path)"
            timeout = 30

            IMPORTANT — hook trust: Codex silently ignores untrusted hooks. The
            first time you run `codex` after this, approve trusting the
            OpenWhisperer hook when prompted, or the spoken summary won't fire.

            By default only voice-dictated turns are spoken; typed turns stay silent. Change this in Settings → Voice under “Speak replies”.
            """
        )
        window.show()
    }

    // MARK: - Auto-apply hook to Codex config.toml

    /// Register the `speak` MCP server + the shared `voice-context.sh` UserPromptSubmit hook in
    /// ~/.codex/config.toml, and drop the obsolete `notify` (Stop-style) line. Idempotent
    /// append-if-absent; preserves the user's other config. NB: Codex silently skips *untrusted*
    /// hooks, so the user must approve the hook once in Codex (see showCodexConfigInstructions).
    static func applyHookToCodexConfig() -> (success: Bool, message: String) {
        let configURL = Paths.codexConfig
        let fm = FileManager.default
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var content = ""
        if fm.fileExists(atPath: configURL.path), let existing = try? String(contentsOf: configURL, encoding: .utf8) {
            content = existing
        }

        // Drop our obsolete `notify = [...]` line (matched exactly to avoid keys like notify_on_error;
        // only ours — referencing our hook — so a user's unrelated notify is left alone).
        var lines = content.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("notify") else { return true }
            let rest = t.dropFirst("notify".count)
            guard let f = rest.first, f == " " || f == "=" || f == "\t" else { return true }
            return !(line.contains("codex-tts-hook") || line.contains("OpenWhisperer"))
        }

        var added: [String] = []
        if !content.contains("[mcp_servers.OpenWhisperer]") {
            added += ["", "[mcp_servers.OpenWhisperer]", "url = \"http://localhost:8000/mcp\""]
        }
        if !content.contains("voice-context.sh") {
            added += ["", "[[hooks.UserPromptSubmit]]", "",
                      "[[hooks.UserPromptSubmit.hooks]]",
                      "type = \"command\"",
                      "command = \"\(Paths.voiceContextHook.path)\"",
                      "timeout = 30"]
        }
        if !added.isEmpty {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += added
        }

        do {
            try lines.joined(separator: "\n").write(to: configURL, atomically: true, encoding: .utf8)
            return (true, added.isEmpty ? "Already configured" : "Configured — approve the hook once in Codex to enable it")
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Codex Diagnostics

    static func checkCodexHookConfigured() -> Bool {
        guard let content = try? String(contentsOf: Paths.codexConfig, encoding: .utf8) else { return false }
        return content.contains("[mcp_servers.OpenWhisperer]") && content.contains("voice-context.sh")
    }

    // MARK: - Pi: extension (no MCP)

    static func showPiInstructions() {
        let window = InstructionWindow(
            title: "Step 1: Pi voice (extension — no MCP)",
            instructions: """
            Pi has no MCP. "Apply" copies one extension into Pi's extensions
            folder; it registers an `openwhisperer_speak` tool and a per-turn
            voice nudge, talking to OpenWhisperer's local TTS server over HTTP.

            To do it by hand, copy the extension:

              cp "\(Paths.piExtensionSource.path)" \\
                 "\(Paths.piExtensionDest.path)"

            Then run /reload in Pi (or restart it) to load it.

            By default only voice-dictated turns are spoken; typed turns stay silent. Change this in Settings → Voice under “Speak replies”.
            """
        )
        window.show()
    }

    /// Install the Pi extension: copy the bundled `openwhisperer.ts` into
    /// ~/.pi/agent/extensions/. Idempotent (overwrites). Pi loads it on /reload.
    static func applyToPi() -> (success: Bool, message: String) {
        let fm = FileManager.default
        let src = Paths.piExtensionSource
        let dest = Paths.piExtensionDest
        guard fm.fileExists(atPath: src.path) else {
            return (false, "Bundled extension missing (\(src.lastPathComponent))")
        }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            return (true, "Extension installed — run /reload in Pi to load it")
        } catch {
            return (false, "Copy failed: \(error.localizedDescription)")
        }
    }

    static func checkPiConfigured() -> Bool {
        FileManager.default.fileExists(atPath: Paths.piExtensionDest.path)
    }

    // MARK: - Claude Desktop: claude_desktop_config.json (MCP only, no hooks)

    static func showClaudeDesktopInstructions() {
        let window = InstructionWindow(
            title: "Claude Desktop Setup",
            instructions: """
            OpenWhisperer adds its speak tool to Claude Desktop via MCP — no hooks needed.

            1. Click Auto-Apply (writes the entry into claude_desktop_config.json).
            2. Quit and reopen Claude Desktop so it launches the server and loads the tool.
            3. Dictate into Claude Desktop: the transcript gets a trailing
               "Speak back." line that cues the spoken reply.
               Delete it before sending to keep a turn silent; type it yourself to force one.

            Keep the OpenWhisperer menubar app running — it does the actual speaking.
            """
        )
        window.show()
    }

    /// Claude Desktop has no hook system; the whole integration is the MCP entry. The
    /// standing instruction + trailing "Speak back." line replace
    /// the UserPromptSubmit handshake (see docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
    static func applyToClaudeDesktop() -> (success: Bool, message: String) {
        guard let exe = Bundle.main.executablePath else {
            return (false, "Cannot resolve the app binary path")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: Paths.claudeDesktopConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            return (false, "Couldn't create the Claude config directory: \(error.localizedDescription)")
        }
        var existing: Data?
        if fm.fileExists(atPath: Paths.claudeDesktopConfig.path) {
            do {
                existing = try Data(contentsOf: Paths.claudeDesktopConfig)
            } catch {
                return (false, "Couldn't read claude_desktop_config.json: \(error.localizedDescription)")
            }
        }
        guard let out = DesktopConfigMerge.merged(existingJSON: existing, executablePath: exe) else {
            return (false, "claude_desktop_config.json exists but isn't a valid JSON object — fix or remove it, then retry")
        }
        do {
            try out.write(to: Paths.claudeDesktopConfig, options: .atomic)
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }

        return (true, "speak tool registered — restart Claude Desktop to load it")
    }

    // MARK: - Antigravity CLI (agy): mcp_config.json + hooks.json

    static func showAntigravityInstructions() {
        let window = InstructionWindow(
            title: "Step 1: Antigravity CLI voice (mcp_config.json + hooks.json)",
            instructions: """
            OpenWhisperer adds voice to Antigravity CLI (agy) in two pieces. "Apply"
            wires both automatically; to do it by hand:

            1) The `speak` MCP tool (in ~/.gemini/config/mcp_config.json) — reuses
               the same endpoint Claude/Codex/Pi talk to, over agy's SSE transport:

               {
                 "mcpServers": {
                   "openwhisperer": { "serverUrl": "http://localhost:8000/mcp" }
                 }
               }

            2) The PreInvocation hook (in ~/.gemini/config/hooks.json) — nudges the
               model to speak a summary first on dictated turns:

               {
                 "openwhisperer": {
                   "PreInvocation": [
                     { "type": "command", "command": "\(Paths.agyPreInvocationHook.path)", "timeout": 10 }
                   ]
                 }
               }

            Start a NEW agy session afterward so it picks up both changes.

            By default only voice-dictated turns are spoken; typed turns stay silent. Change this in Settings → Voice under “Speak replies”.
            """
        )
        window.show()
    }

    /// Register the `speak` MCP server (SSE transport, same /mcp endpoint Claude/Codex/Pi use)
    /// in ~/.gemini/config/mcp_config.json, and the shared PreInvocation hook in the GLOBAL
    /// ~/.gemini/config/hooks.json (confirmed live: the global file fires for any workspace).
    /// Merges into existing config rather than overwriting it; idempotent.
    static func applyToAntigravity() -> (success: Bool, message: String) {
        let fm = FileManager.default

        // MCP registration.
        try? fm.createDirectory(at: Paths.agyMCPConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        var mcpRoot: [String: Any] = [:]
        if fm.fileExists(atPath: Paths.agyMCPConfig.path),
           let data = try? Data(contentsOf: Paths.agyMCPConfig),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            mcpRoot = json
        }
        var servers = mcpRoot["mcpServers"] as? [String: Any] ?? [:]
        servers["openwhisperer"] = ["serverUrl": "http://localhost:8000/mcp"]
        mcpRoot["mcpServers"] = servers
        guard let mcpOut = try? JSONSerialization.data(withJSONObject: mcpRoot, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return (false, "Failed to serialize mcp_config.json")
        }
        do {
            try mcpOut.write(to: Paths.agyMCPConfig)
        } catch {
            return (false, "mcp_config.json write failed: \(error.localizedDescription)")
        }

        // Hook registration.
        try? fm.createDirectory(at: Paths.agyHooksConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        var hooksRoot: [String: Any] = [:]
        if fm.fileExists(atPath: Paths.agyHooksConfig.path),
           let data = try? Data(contentsOf: Paths.agyHooksConfig),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hooksRoot = json
        }
        hooksRoot["openwhisperer"] = [
            "PreInvocation": [
                ["type": "command", "command": Paths.agyPreInvocationHook.path, "timeout": 10]
            ]
        ]
        guard let hooksOut = try? JSONSerialization.data(withJSONObject: hooksRoot, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return (false, "Failed to serialize hooks.json")
        }
        do {
            try hooksOut.write(to: Paths.agyHooksConfig)
            return (true, "MCP server + PreInvocation hook applied — start a new agy session")
        } catch {
            return (false, "hooks.json write failed: \(error.localizedDescription)")
        }
    }

    static func checkAntigravityConfigured() -> Bool {
        guard let mcpData = try? Data(contentsOf: Paths.agyMCPConfig),
              let mcpJSON = try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any],
              let servers = mcpJSON["mcpServers"] as? [String: Any],
              servers["openwhisperer"] != nil else { return false }
        guard let hooksData = try? Data(contentsOf: Paths.agyHooksConfig),
              let hooksJSON = try? JSONSerialization.jsonObject(with: hooksData) as? [String: Any],
              hooksJSON["openwhisperer"] != nil else { return false }
        return true
    }

    // MARK: - Platform-dispatching wrappers

    static func applyHook(for platform: Platform) -> (success: Bool, message: String) {
        switch platform {
        case .claudeCode: return applyHookToSettings()
        case .codexCLI: return applyHookToCodexConfig()
        case .pi: return applyToPi()
        case .antigravity: return applyToAntigravity()
        case .claudeDesktop: return applyToClaudeDesktop()
        }
    }

    static func checkHookConfigured(for platform: Platform) -> Bool {
        switch platform {
        case .claudeCode: return checkHookConfigured()
        case .codexCLI: return checkCodexHookConfigured()
        case .pi: return checkPiConfigured()
        case .antigravity: return checkAntigravityConfigured()
        case .claudeDesktop:
            return DesktopConfigMerge.isConfigured(
                configJSON: try? Data(contentsOf: Paths.claudeDesktopConfig),
                executablePath: Bundle.main.executablePath ?? "")
        }
    }

    static func showHookInstructions(for platform: Platform) {
        switch platform {
        case .claudeCode: showClaudeMCPInstructions()
        case .codexCLI: showCodexConfigInstructions()
        case .pi: showPiInstructions()
        case .antigravity: showAntigravityInstructions()
        case .claudeDesktop: showClaudeDesktopInstructions()
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

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Drop any obsolete Stop hook of ours — the `speak` MCP tool replaced it.
        if var stopArray = hooks["Stop"] as? [[String: Any]] {
            stopArray.removeAll { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { (($0["command"] as? String).map(isOurHook) ?? false) }
            }
            if stopArray.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stopArray }
        }

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
            let mcp = registerClaudeMCPServer()
            return (true, mcp.success ? "Hook + speak tool applied" : "Hook applied (\(mcp.message))")
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }

    /// Register the in-app `speak` MCP server in ~/.claude.json (user scope). Read-modify-write so
    /// the rest of the (large, Claude-Code-managed) file is preserved. Idempotent.
    @discardableResult
    static func registerClaudeMCPServer() -> (success: Bool, message: String) {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: Paths.claudeJSON.path),
           let data = try? Data(contentsOf: Paths.claudeJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["OpenWhisperer"] = ["type": "http", "url": "http://localhost:8000/mcp"]
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return (false, "Failed to serialize ~/.claude.json")
        }
        do { try out.write(to: Paths.claudeJSON); return (true, "speak tool registered") }
        catch { return (false, "Write failed: \(error.localizedDescription)") }
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

    /// One-shot: rename the legacy `voice_detail` settings file to `tts_style` so
    /// existing installs keep their spoken-summary style after the rename.
    static func migrateVoiceDetailToTtsStyle() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Paths.ttsStyle.path),
              fm.fileExists(atPath: Paths.legacyVoiceDetail.path) else { return }
        try? fm.moveItem(at: Paths.legacyVoiceDetail, to: Paths.ttsStyle)
    }

    /// One-shot cleanup: transcription history moved to the menubar dropdown (2026-07-13)
    /// and the overlay's resize grip went with it — delete the grip's orphaned pref file.
    static func removeLegacyOverlayLines() {
        try? FileManager.default.removeItem(at: Paths.legacyOverlayLines)
    }

    /// One-shot: the `text` response mode was removed (no sensible use case). Rewrite any
    /// persisted `tts_response_mode` == "text" to the default "voice" so the picker and hook agree.
    static func migrateRemoveTextResponseMode() {
        guard let raw = try? String(contentsOf: Paths.ttsResponseMode, encoding: .utf8),
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == "text" else { return }
        try? "voice".write(to: Paths.ttsResponseMode, atomically: true, encoding: .utf8)
    }

    /// One-shot upgrade cleanup: remove our obsolete Stop hook from ~/.claude/settings.json so an
    /// old install doesn't keep a dead `tts-hook.sh` entry (the script no longer ships).
    static func migrateRemoveClaudeStopHook() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.claudeSettings.path),
              let data = try? Data(contentsOf: Paths.claudeSettings),
              var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any],
              var stop = hooks["Stop"] as? [[String: Any]] else { return }
        let before = stop.count
        stop.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { (($0["command"] as? String).map(isOurHook) ?? false) }
        }
        guard stop.count != before else { return }
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        settings["hooks"] = hooks
        if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: Paths.claudeSettings)
        }
    }

    // MARK: - Diagnostics

    static func checkHookConfigured() -> Bool {
        guard let data = try? Data(contentsOf: Paths.claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let ups = hooks["UserPromptSubmit"] as? [[String: Any]] else { return false }
        // Accept any Claude Whisper hook variant as "configured"
        return ups.contains { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { (($0["command"] as? String).map(isOurHook) ?? false) }
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

        // Clean lock/pid/config files in app support (includes legacy two-server/queue artifacts)
        let cleanFiles = [
            Paths.appSupport.appendingPathComponent("tts_hook.pid"),
            Paths.appSupport.appendingPathComponent("tts_playing.lock"),
            Paths.appSupport.appendingPathComponent("tts_hook.lock"),
            Paths.appSupport.appendingPathComponent("whisper.pid"),
            Paths.appSupport.appendingPathComponent("tts.pid"),
            Paths.appSupport.appendingPathComponent("tts_queue"),
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
