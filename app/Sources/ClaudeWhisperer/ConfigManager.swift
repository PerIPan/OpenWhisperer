import Foundation
import SwiftUI

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
                    "timeout": 60
                  }]
                }]
              }
            }

            This makes Claude speak every response aloud.
            """
        )
        window.show()
    }

    // MARK: - Claude Code: CLAUDE.md

    static func showClaudeMdInstructions() {
        let window = InstructionWindow(
            title: "Step 2: CLAUDE.md (Voice Tag)",
            instructions: """
            Add this to your project's CLAUDE.md file:

            ## Voice Mode
            ALWAYS include a [VOICE: ...] tag at the END
            of every response. This tag contains a short,
            conversational spoken summary (1-3 sentences)
            that the TTS hook extracts and reads aloud.

            Write the voice content as natural speech -
            no code, no file paths, no markdown.

            Example:
            [VOICE: I fixed the bug in the login page.
            It was a missing null check on the user object.]

            This tells Claude to add a spoken summary
            to every response.
            """
        )
        window.show()
    }

    // MARK: - Voquill Detection & Configuration

    static func isVoquillInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Voquill.app")
    }

    /// Check if Voquill's SQLite config points to the local Whisper server.
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

    // MARK: - Auto-apply hook to settings.json

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

        // Build the hook entry
        let hookEntry: [String: Any] = ["type": "command", "command": hookPath, "timeout": 60]
        let stopEntry: [String: Any] = ["hooks": [hookEntry]]

        // Get or create hooks.Stop array
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var stopArray = hooks["Stop"] as? [[String: Any]] ?? []

        // Check if hook is already present
        let alreadyPresent = stopArray.contains { entry in
            if let innerHooks = entry["hooks"] as? [[String: Any]] {
                return innerHooks.contains { $0["command"] as? String == hookPath }
            }
            return false
        }

        if alreadyPresent {
            return (true, "Hook already configured")
        }

        stopArray.append(stopEntry)
        hooks["Stop"] = stopArray
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
            return (true, "Hook applied to settings.json")
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-apply CLAUDE.md voice tag

    static func applyClaudeMd(forceUpdate: Bool = false) -> (success: Bool, message: String) {
        let claudeMdPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("CLAUDE.md")
        let fm = FileManager.default

        // Read detail level preference
        let detail = (try? String(contentsOf: Paths.voiceDetail, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "natural"

        let voiceBlock = voiceBlockForDetail(detail)

        // Check if already present
        if fm.fileExists(atPath: claudeMdPath.path),
           let existing = try? String(contentsOf: claudeMdPath, encoding: .utf8) {
            if existing.contains("[VOICE:") || existing.contains("Voice Mode") {
                if forceUpdate {
                    // Replace existing voice block with updated one
                    let cleaned = removeVoiceBlock(from: existing)
                    let updated = cleaned.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + voiceBlock + "\n"
                    do {
                        try updated.write(to: claudeMdPath, atomically: true, encoding: .utf8)
                        return (true, "New VOICE detail applied")
                    } catch {
                        return (false, "Write failed: \(error.localizedDescription)")
                    }
                }
                return (true, "Voice tag active")
            }
            // Append to existing
            let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + voiceBlock + "\n"
            do {
                try updated.write(to: claudeMdPath, atomically: true, encoding: .utf8)
                return (true, "Voice tag appended to CLAUDE.md")
            } catch {
                return (false, "Write failed: \(error.localizedDescription)")
            }
        }

        // Create new file
        try? fm.createDirectory(at: claudeMdPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try voiceBlock.trimmingCharacters(in: .newlines).write(to: claudeMdPath, atomically: true, encoding: .utf8)
            return (true, "CLAUDE.md created with voice tag")
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }

    private static func voiceBlockForDetail(_ detail: String) -> String {
        switch detail {
        case "brief":
            return """

            ## Voice Mode
            ALWAYS include a `[VOICE: ...]` tag at the END of every response. Keep it to 1 short sentence — just the key outcome. No code, no file paths, no markdown. Write as natural speech.

            Example: `[VOICE: Fixed the login bug.]`
            """
        case "detailed":
            return """

            ## Voice Mode
            ALWAYS include a `[VOICE: ...]` tag at the END of every response. Give a thorough spoken summary (3-6 sentences) covering what you did, why, and any important details the user should know. Write as natural conversational speech — no code, no file paths, no markdown, no technical jargon unless the user used it first.

            Example: `[VOICE: I fixed the bug in the login page. The issue was a missing null check on the user object, which caused a crash when the session expired. I also added a fallback redirect to the login screen. You should test it with an expired session to make sure it works correctly.]`
            """
        default: // "natural"
            return """

            ## Voice Mode
            ALWAYS include a `[VOICE: ...]` tag at the END of every response. This tag contains a short, conversational spoken summary (1-3 sentences) that the TTS hook extracts and reads aloud. Write the voice content as natural speech — no code, no file paths, no markdown, no technical jargon unless the user used it first.

            Example: `[VOICE: I fixed the bug in the login page. It was a missing null check on the user object.]`
            """
        }
    }

    private static func removeVoiceBlock(from content: String) -> String {
        // Remove the ## Voice Mode section (from header to next ## or end of file)
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var skipping = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## Voice Mode") {
                skipping = true
                continue
            }
            if skipping && line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                skipping = false
            }
            if !skipping {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Diagnostics

    static func checkHookConfigured() -> Bool {
        guard let data = try? Data(contentsOf: Paths.claudeSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let stopArray = hooks["Stop"] as? [[String: Any]] else { return false }
        let hookPath = Paths.ttsHook.path
        return stopArray.contains { entry in
            if let innerHooks = entry["hooks"] as? [[String: Any]] {
                return innerHooks.contains { $0["command"] as? String == hookPath }
            }
            return false
        }
    }

    static func checkClaudeMdConfigured() -> Bool {
        let claudeMdPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("CLAUDE.md")
        guard let content = try? String(contentsOf: claudeMdPath, encoding: .utf8) else { return false }
        return content.contains("[VOICE:") || content.contains("Voice Mode")
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
        guard let text = String(data: data, encoding: .utf8) else { return false }
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
