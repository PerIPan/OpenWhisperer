import Foundation

enum Paths {
    /// ~/Library/Application Support/ClaudeWhisperer
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ClaudeWhisperer")
    }()

    /// Python venv location
    static let venv = appSupport.appendingPathComponent("venv")

    /// Python binary inside venv
    static let python = venv.appendingPathComponent("bin").appendingPathComponent("python")

    /// App Resources directory (safe unwrap)
    private static var resources: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
    }

    /// uv binary (bundled in app Resources)
    static var uvBinary: URL {
        resources.appendingPathComponent("uv")
    }

    /// Unified server script (TTS + STT in one process)
    static var unifiedServer: URL {
        resources.appendingPathComponent("servers").appendingPathComponent("unified_server.py")
    }

    /// Bundled hook script
    static var ttsHook: URL {
        resources.appendingPathComponent("hooks").appendingPathComponent("tts-hook.sh")
    }

    /// Bundled speak script
    static var speakScript: URL {
        resources.appendingPathComponent("scripts").appendingPathComponent("speak.sh")
    }

    /// Setup marker file
    static let setupComplete = appSupport.appendingPathComponent(".setup-complete")

    /// Server PID file (single unified server)
    static let serverPidFile = appSupport.appendingPathComponent("server.pid")

    /// Log file (single unified server)
    static let serverLog = appSupport.appendingPathComponent("server.log")
    static let setupLog = appSupport.appendingPathComponent("setup.log")

    /// Auto-submit flag file (unified_server.py checks this)
    static let autoSubmitFlag = appSupport.appendingPathComponent("auto_submit")

    /// Auto-focus app file (unified_server.py reads target app name from this)
    static let autoFocusApp = appSupport.appendingPathComponent("auto_focus_app")

    /// STT language file (unified_server.py reads default language from this)
    static let sttLanguage = appSupport.appendingPathComponent("stt_language")

    /// TTS voice file (tts-hook.sh reads voice name from this)
    static let ttsVoice = appSupport.appendingPathComponent("tts_voice")

    /// Voice detail level file (controls VOICE tag verbosity in CLAUDE.md)
    static let voiceDetail = appSupport.appendingPathComponent("voice_detail")

    /// Claude Code settings
    static let claudeSettings: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("settings.json")
    }()

    /// Ensure directories exist
    static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }
}
