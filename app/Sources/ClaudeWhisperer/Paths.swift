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

    /// Bundled server scripts
    static var whisperServer: URL {
        resources.appendingPathComponent("servers").appendingPathComponent("whisper_server.py")
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

    /// Server PID files
    static let sttPidFile = appSupport.appendingPathComponent("whisper.pid")
    static let ttsPidFile = appSupport.appendingPathComponent("tts.pid")

    /// Log files
    static let sttLog = appSupport.appendingPathComponent("whisper.log")
    static let ttsLog = appSupport.appendingPathComponent("tts.log")
    static let setupLog = appSupport.appendingPathComponent("setup.log")

    /// Auto-submit flag file (whisper_server.py checks this)
    static let autoSubmitFlag = appSupport.appendingPathComponent("auto_submit")

    /// Auto-focus app file (whisper_server.py reads target app name from this)
    static let autoFocusApp = appSupport.appendingPathComponent("auto_focus_app")

    /// TTS voice file (tts-hook.sh reads voice name from this)
    static let ttsVoice = appSupport.appendingPathComponent("tts_voice")

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
