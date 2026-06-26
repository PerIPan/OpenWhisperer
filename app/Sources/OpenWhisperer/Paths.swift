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

    /// Auto-submit flag file (read in-process by the Swift app)
    static let autoSubmitFlag = appSupport.appendingPathComponent("auto_submit")

    /// Auto-focus app file (target app name, read in-process by the Swift app)
    static let autoFocusApp = appSupport.appendingPathComponent("auto_focus_app")

    /// Auto-focus "with return" flag — return to origin app after text insertion
    static let autoFocusReturn = appSupport.appendingPathComponent("auto_focus_return")

    /// STT language file (default language for in-process WhisperKit STT)
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

    /// Card expanded states (persisted so user's collapse/expand survives restarts)
    static let setupCardExpanded = appSupport.appendingPathComponent("setup_expanded")
    static let voiceSettingsCardExpanded = appSupport.appendingPathComponent("voice_settings_expanded")
    static let serverCardExpanded = appSupport.appendingPathComponent("server_expanded")

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
