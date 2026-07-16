import Foundation

enum Paths {
    /// ~/Library/Application Support/OpenWhisperer
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenWhisperer")
    }()

    /// App Resources directory (safe unwrap)
    private static let resources: URL = {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
    }()

    /// Bundled UserPromptSubmit hook (Claude Code + Codex voice-turn detection)
    static let voiceContextHook = resources.appendingPathComponent("hooks").appendingPathComponent("voice-context.sh")

    /// Bundled speak script
    static let speakScript = resources.appendingPathComponent("scripts").appendingPathComponent("speak.sh")

    /// Setup marker file
    static let setupComplete = appSupport.appendingPathComponent(".setup-complete")

    /// Log file (native TTS server)
    static let serverLog = appSupport.appendingPathComponent("server.log")
    static let setupLog = appSupport.appendingPathComponent("setup.log")

    /// Legacy model space from the removed WhisperKit engine (2026-07-13). Nothing
    /// downloads here anymore; ModelStorage lists it so "Delete models" reclaims an
    /// orphaned Whisper cache. (FluidAudio's models live in Application Support/
    /// FluidAudio and ~/.cache/fluidaudio — upstream pins the shared G2P/lexicon
    /// assets to the latter, so they can't be cleanly relocated.)
    static let modelsDir = appSupport.appendingPathComponent("models")

    /// Auto-submit flag file (read in-process by the Swift app)
    static let autoSubmitFlag = appSupport.appendingPathComponent("auto_submit")

    /// Auto-focus app file (target app name, read in-process by the Swift app)
    static let autoFocusApp = appSupport.appendingPathComponent("auto_focus_app")

    /// Auto-focus "with return" flag — return to origin app after text insertion
    static let autoFocusReturn = appSupport.appendingPathComponent("auto_focus_return")

    /// STT language file (script-filter hint for in-process Parakeet STT;
    /// absent/"auto" = model auto-detect)
    static let sttLanguage = appSupport.appendingPathComponent("stt_language")

    /// TTS voice file (tts-hook.sh reads voice name from this)
    static let ttsVoice = appSupport.appendingPathComponent("tts_voice")

    /// TTS spoken-summary style/length: terse | normal | rich. Read by
    /// voice-context.sh to shape the nudge; overridable per-project via OW_TTS_STYLE.
    static let ttsStyle = appSupport.appendingPathComponent("tts_style")

    /// Legacy name for `ttsStyle` (pre-rename). Migrated to `tts_style` on launch.
    static let legacyVoiceDetail = appSupport.appendingPathComponent("voice_detail")

    /// When replies are spoken: `voice` (default — only dictated turns) | `text`
    /// (only typed turns) | `always`. Read by voice-context.sh / codex-tts-hook.sh;
    /// overridable per-project via OW_TTS_RESPONSE.
    static let ttsResponseMode = appSupport.appendingPathComponent("tts_response_mode")

    /// Voice-turn signal (hash + unix timestamp) written by the app on each
    /// dictation; read & claimed by the UserPromptSubmit hook (voice-context.sh).
    static let voiceTurn = appSupport.appendingPathComponent("voice_turn")

    /// Per-session "speak this turn" markers: speak_pending/<session_id>.
    /// Created by the UPS hook on a voice-turn claim, consumed by the Stop hook.
    static let speakPendingDir = appSupport.appendingPathComponent("speak_pending")

    /// Push-to-talk hotkey preference (ctrl, option, cmd, fn)
    static let pttHotkey = appSupport.appendingPathComponent("ptt_hotkey")

    /// Interaction mode preference (pressToTalk, holdToTalk, handsFree)
    static let interactionMode = appSupport.appendingPathComponent("interaction_mode")

    /// Silence threshold for hands-free mode (seconds, default 3)
    static let silenceThreshold = appSupport.appendingPathComponent("silence_threshold")

    /// TTS volume file (tts-hook.sh reads volume level from this)
    static let ttsVolume = appSupport.appendingPathComponent("tts_volume")

    /// TTS speed file
    static let ttsSpeed = appSupport.appendingPathComponent("tts_speed")

    /// Legacy (pre menubar-history): the overlay resize grip's persisted line count.
    /// Kept only so `ConfigManager.removeLegacyOverlayLines()` can delete stale files.
    static let legacyOverlayLines = appSupport.appendingPathComponent("overlay_lines")

    /// Overlay visibility flag — present when the user hid the floating overlay
    /// (menu toggle off, or the overlay's X button). Absent = show on launch.
    static let overlayHidden = appSupport.appendingPathComponent("overlay_hidden")

    /// Overlay analyzer style: led_bars | graph | curtain (see OverlayStyle.parse).
    static let overlayStyle = appSupport.appendingPathComponent("overlay_style")

    /// Selected AI platform (claudeCode, codexCLI)
    static let selectedPlatform = appSupport.appendingPathComponent("selected_platform")

    /// Claude Code settings
    static let claudeSettings: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
    }()

    /// Claude Code user config (~/.claude.json) — holds user-scope MCP servers under `mcpServers`.
    static let claudeJSON: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }()

    /// Codex CLI config (~/.codex/config.toml)
    static let codexConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex").appendingPathComponent("config.toml")
    }()

    /// Pi coding agent — bundled extension source (Resources/pi/openwhisperer.ts).
    static let piExtensionSource = resources.appendingPathComponent("pi").appendingPathComponent("openwhisperer.ts")

    /// Pi coding agent — install destination (~/.pi/agent/extensions/openwhisperer.ts).
    static let piExtensionDest: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi").appendingPathComponent("agent")
            .appendingPathComponent("extensions").appendingPathComponent("openwhisperer.ts")
    }()

    /// Bundled PreInvocation hook (Antigravity CLI voice-turn detection).
    static let agyPreInvocationHook = resources.appendingPathComponent("hooks").appendingPathComponent("agy-previnvocation.sh")

    /// Antigravity CLI global MCP config (~/.gemini/config/mcp_config.json) — holds the
    /// `speak` tool registration over its SSE (serverUrl) transport.
    static let agyMCPConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini").appendingPathComponent("config").appendingPathComponent("mcp_config.json")
    }()

    /// Antigravity CLI global hooks config (~/.gemini/config/hooks.json) — holds the
    /// PreInvocation early-speak hook. Global, not per-workspace: confirmed live to fire for
    /// any workspace, matching how Claude/Codex/Pi are one-time, not per-project, installs.
    static let agyHooksConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini").appendingPathComponent("config").appendingPathComponent("hooks.json")
    }()

    /// Ensure directories exist
    static func ensureDirectories() {
        // Owner-only perms — the support dir holds config + logs read by the local server (T2.5)
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Tighten perms on a dir created by an older version (e.g. 0755 -> 0700)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)
    }
}
