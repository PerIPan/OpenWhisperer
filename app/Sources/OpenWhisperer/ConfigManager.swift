import Foundation
import SwiftUI
import OpenWhispererKit

// MARK: - Platform

enum Platform: String, CaseIterable {
    case claudeCode = "claudeCode"
    case codexCLI = "codexCLI"
    case pi = "pi"
    case antigravity = "antigravity"

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .pi: return "Pi"
        case .antigravity: return "Antigravity"
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
                 OpenWhisperer \(mcpURL)

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

    // MARK: - Codex CLI: config.toml + hooks.json

    static func showCodexConfigInstructions() {
        let window = InstructionWindow(
            title: "Step 1: Codex voice (config.toml + hooks.json + hook trust)",
            instructions: """
            OpenWhisperer adds voice to Codex in two pieces. "Apply" wires both
            automatically; to do it by hand:

            1) The `speak` MCP tool (in ~/.codex/config.toml):

               [mcp_servers.OpenWhisperer]
               url = "\(mcpURL)"

            2) UserPromptSubmit hook (in ~/.codex/hooks.json, merged with any hooks
               already there) — nudges Codex to speak a summary first on dictated turns:

               {
                 "hooks": {
                   "UserPromptSubmit": [{
                     "hooks": [{ "type": "command", "command": "\(Paths.voiceContextHook.path)", "timeout": 30 }]
                   }]
                 }
               }

            Older versions put the hook inline in config.toml; Codex warns when a
            layer has both, so "Apply" moves it over.

            IMPORTANT — hook trust: Codex silently ignores untrusted hooks. The
            first time you run `codex` after this, approve trusting the
            OpenWhisperer hook when prompted, or the spoken summary won't fire.

            By default only voice-dictated turns are spoken; typed turns stay silent. Change this in Settings → Voice under “Speak replies”.
            """
        )
        window.show()
    }

    // MARK: - Auto-apply: Codex config.toml + hooks.json

    /// Register the `speak` MCP server in ~/.codex/config.toml and the shared `voice-context.sh`
    /// UserPromptSubmit hook in ~/.codex/hooks.json. Codex reads hooks from both files but warns
    /// whenever one layer carries both, and other tools (Herdr) already keep theirs in hooks.json,
    /// so the hook goes there and any inline copy an earlier version wrote into config.toml is
    /// lifted out (`CodexConfigTOML`, along with the older `notify` line). Both edits are scoped
    /// to our own entries and idempotent; a hooks.json that won't parse is left alone rather than
    /// clobbered. NB: Codex silently skips *untrusted* hooks, and trust is keyed by file and
    /// position, so after the move the user must approve the hook once more in Codex (see
    /// showCodexConfigInstructions).
    static func applyHookToCodexConfig() -> (success: Bool, message: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)

        // hooks.json first, so a failure here leaves the inline hook (and Codex's warning) in
        // place rather than leaving Codex with no hook at all.
        var hooksRoot: [String: Any] = [:]
        if fm.fileExists(atPath: Paths.codexHooks.path) {
            guard let data = try? Data(contentsOf: Paths.codexHooks),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "~/.codex/hooks.json isn't valid JSON — fix it, then connect again")
            }
            hooksRoot = json
        }
        let hook: [String: Any] = ["type": "command", "command": Paths.voiceContextHook.path, "timeout": 30]
        let merged = HooksJSON.upsertingOwnHook(in: hooksRoot, event: "UserPromptSubmit", hook: hook)
        let hooksChanged = !NSDictionary(dictionary: merged).isEqual(to: hooksRoot)
        if hooksChanged {
            guard let rendered = HooksJSON.render(merged) else { return (false, "Failed to serialize hooks.json") }
            do { try rendered.write(to: Paths.codexHooks, atomically: true, encoding: .utf8) }
            catch { return (false, "hooks.json write failed: \(error.localizedDescription)") }
        }

        // config.toml keeps the MCP server; our inline hook tables and the legacy notify line go.
        let existing = (try? String(contentsOf: Paths.codexConfig, encoding: .utf8)) ?? ""
        // Sets the URL even when the table exists: it used to be added once and never updated,
        // so a port change silently cost Codex its speak tool.
        let toml = CodexConfigTOML.settingOwnMCPServerURL(
            mcpURL, in: CodexConfigTOML.strippingOwnHooks(from: existing))
        let tomlChanged = toml != existing
        if tomlChanged {
            do { try toml.write(to: Paths.codexConfig, atomically: true, encoding: .utf8) }
            catch { return (false, "config.toml write failed: \(error.localizedDescription)") }
        }

        return (true, hooksChanged || tomlChanged
                ? "Configured — approve the hook once in Codex to enable it"
                : "Already configured")
    }

    // MARK: - Codex Diagnostics

    /// Connected means the new shape: MCP server in config.toml, hook in hooks.json, and no
    /// inline copy left behind to trip Codex's both-representations warning.
    static func checkCodexHookConfigured() -> Bool {
        guard let toml = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              CodexConfigTOML.hasOwnMCPServerTable(toml),
              !CodexConfigTOML.hasOwnInlineHook(toml),
              let data = try? Data(contentsOf: Paths.codexHooks),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return HooksJSON.containsOwnHook(json, event: "UserPromptSubmit")
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
                   "openwhisperer": { "serverUrl": "\(mcpURL)" }
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
        if fm.fileExists(atPath: Paths.agyMCPConfig.path) {
            // Same rule as ~/.claude.json: never treat a file that won't parse as empty.
            guard let data = try? Data(contentsOf: Paths.agyMCPConfig),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "mcp_config.json isn't valid JSON — fix it, then connect again")
            }
            mcpRoot = json
        }
        var servers = mcpRoot["mcpServers"] as? [String: Any] ?? [:]
        servers["openwhisperer"] = ["serverUrl": mcpURL]
        mcpRoot["mcpServers"] = servers
        guard let mcpOut = try? JSONSerialization.data(withJSONObject: mcpRoot, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return (false, "Failed to serialize mcp_config.json")
        }
        do {
            try mcpOut.write(to: Paths.agyMCPConfig, options: .atomic)
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

    /// The `speak` MCP endpoint every agent is pointed at — on the port the server last bound.
    static var mcpURL: String { TTSPort.mcpURL(port: TTSPort.stored) }

    /// After the TTS port changed: re-point every agent config that already names our MCP
    /// server. Deliberately narrower than Connect — review found the first cut re-ran the full
    /// apply, which would re-add a server the user had removed (`claude mcp remove`) and, via
    /// `registerClaudeMCPServer`, replace an unparsable `~/.claude.json` wholesale. Here a file
    /// that won't parse is skipped, an absent entry is skipped, and only the URL of an existing
    /// entry changes. Pi needs nothing: its extension reads `tts_port` itself.
    static func reapplyConnectedAgents() {
        let url = mcpURL
        repointJSONServer(at: Paths.claudeJSON, key: "OpenWhisperer", field: "url", url: url, label: "Claude")
        repointJSONServer(at: Paths.agyMCPConfig, key: "openwhisperer", field: "serverUrl", url: url, label: "Antigravity")
        repointCodexServer(url: url)
    }

    /// Change `mcpServers.<key>.<field>` in a JSON config to `url`, only if the file parses and
    /// the entry exists. Written atomically so a crash mid-write can't leave a truncated file.
    private static func repointJSONServer(at file: URL, key: String, field: String, url: String, label: String) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("TTS port: \(label) config at \(file.lastPathComponent) isn't valid JSON — left alone")
            return
        }
        guard var servers = root["mcpServers"] as? [String: Any],
              var entry = servers[key] as? [String: Any] else { return }   // not connected: nothing to re-point
        if entry[field] as? String == url { return }
        entry[field] = url
        servers[key] = entry
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        do {
            try out.write(to: file, options: .atomic)
            NSLog("TTS port: \(label) re-pointed to \(url)")
        } catch {
            NSLog("TTS port: \(label) write failed: \(error.localizedDescription)")
        }
    }

    /// Codex: edit only an existing `[mcp_servers.OpenWhisperer]` table's `url` line.
    private static func repointCodexServer(url: String) {
        guard let toml = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              CodexConfigTOML.hasOwnMCPServerTable(toml) else { return }
        let updated = CodexConfigTOML.settingOwnMCPServerURL(url, in: toml)
        guard updated != toml else { return }
        do {
            try updated.write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
            NSLog("TTS port: Codex re-pointed to \(url)")
        } catch {
            NSLog("TTS port: Codex write failed: \(error.localizedDescription)")
        }
    }

    static func applyHook(for platform: Platform) -> (success: Bool, message: String) {
        switch platform {
        case .claudeCode: return applyHookToSettings()
        case .codexCLI: return applyHookToCodexConfig()
        case .pi: return applyToPi()
        case .antigravity: return applyToAntigravity()
        }
    }

    static func checkHookConfigured(for platform: Platform) -> Bool {
        switch platform {
        case .claudeCode: return checkHookConfigured()
        case .codexCLI: return checkCodexHookConfigured()
        case .pi: return checkPiConfigured()
        case .antigravity: return checkAntigravityConfigured()
        }
    }

    static func showHookInstructions(for platform: Platform) {
        switch platform {
        case .claudeCode: showClaudeMCPInstructions()
        case .codexCLI: showCodexConfigInstructions()
        case .pi: showPiInstructions()
        case .antigravity: showAntigravityInstructions()
        }
    }

    // MARK: - Auto-apply hook to settings.json

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

        // Drop any obsolete Stop hook of ours — the `speak` MCP tool replaced it — then register
        // the UserPromptSubmit voice-turn hook (idempotent: our old entries go first). Both edits
        // leave every other hook in the file alone.
        settings = HooksJSON.removingOwnHooks(from: settings, event: "Stop")
        settings = HooksJSON.upsertingOwnHook(in: settings, event: "UserPromptSubmit",
                                              hook: ["type": "command", "command": Paths.voiceContextHook.path])

        // Write back in Claude Code's own style (2-space indent).
        guard let jsonString = HooksJSON.render(settings) else {
            return (false, "Failed to serialize JSON")
        }

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
        if fm.fileExists(atPath: Paths.claudeJSON.path) {
            // A file that doesn't parse must not be treated as empty: ~/.claude.json also holds
            // the user's account, projects and per-project MCP config, and writing `{mcpServers}`
            // over it would lose all of that.
            guard let data = try? Data(contentsOf: Paths.claudeJSON),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "~/.claude.json isn't valid JSON — fix it, then connect again")
            }
            root = json
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["OpenWhisperer"] = ["type": "http", "url": mcpURL]
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return (false, "Failed to serialize ~/.claude.json")
        }
        do { try out.write(to: Paths.claudeJSON, options: .atomic); return (true, "speak tool registered") }
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

    /// One-shot: make English the stored dictation language when nothing is stored.
    ///
    /// Auto-detect used to be the implicit default (a missing `stt_language` file leaves
    /// `DecodingOptions.detectLanguage` on). It is now an explicit choice instead: detection
    /// costs a decoder pass and is least reliable on short clips, which is most of what
    /// dictation produces, and the owner measured fewer errors with English pinned
    /// (2026-08-01). **Do not restore Auto-detect as the default.**
    ///
    /// Writing the file rather than defaulting in the reader keeps Settings honest — the
    /// picker shows the language actually in force instead of an invisible fallback. A
    /// stored value of any kind, `auto` included, is left alone.
    /// 2.1: move af_heart to Heart on Pocket TTS (`VoiceMigration.pocketHeart`), once. A marker
    /// rather than the usual "old state present" check, because af_heart is also a choice someone
    /// can make again afterwards ("Heart (Kokoro)") — that must stick. Per-project `OW_TTS_VOICE`
    /// overrides are left alone: they are written by hand, per repository, on purpose.
    static func migrateAfHeartToPocketHeart() {
        let marker = Paths.appSupport.appendingPathComponent(".migrated-pocket-heart")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        Paths.ensureDirectories()
        let current = try? String(contentsOf: Paths.ttsVoice, encoding: .utf8)
        if let moved = VoiceMigration.pocketHeart(current: current) {
            try? moved.write(to: Paths.ttsVoice, atomically: true, encoding: .utf8)
            NSLog("Voice moved from af_heart to \(moved) (2.1)")
        }
        try? "".write(to: marker, atomically: true, encoding: .utf8)
    }

    static func migrateDefaultSTTLanguage() {
        let stored = try? String(contentsOf: Paths.sttLanguage, encoding: .utf8)
        guard let language = STTLanguages.defaultedLanguage(existing: stored) else { return }
        // Unlike the other migrations — which only rewrite files that already exist — this
        // one creates a file, and on a first-ever launch Application Support/OpenWhisperer
        // doesn't exist yet (`ensureDirectories()` runs later, from ServerManager/Setup).
        // Without this the write fails silently and the whole first session runs on
        // auto-detect, which is the behavior this migration exists to replace.
        Paths.ensureDirectories()
        try? language.write(to: Paths.sttLanguage, atomically: true, encoding: .utf8)
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
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              HooksJSON.containsOwnHook(settings, event: "Stop"),
              let out = HooksJSON.render(HooksJSON.removingOwnHooks(from: settings, event: "Stop")) else { return }
        try? out.write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
    }

    /// One-shot for installs whose Codex hook still sits inline in ~/.codex/config.toml: move it
    /// to ~/.codex/hooks.json (Codex warns while a layer carries both). Runs the same idempotent
    /// apply Connect does, so a fresh or already-migrated install is a no-op.
    static func migrateCodexInlineHook() {
        guard let toml = try? String(contentsOf: Paths.codexConfig, encoding: .utf8),
              CodexConfigTOML.hasOwnInlineHook(toml) else { return }
        _ = applyHookToCodexConfig()
    }

    // MARK: - Diagnostics

    static func checkHookConfigured() -> Bool {
        guard let data = try? Data(contentsOf: Paths.claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        // Accept any Open Whisperer hook variant as "configured"
        return HooksJSON.containsOwnHook(json, event: "UserPromptSubmit")
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
