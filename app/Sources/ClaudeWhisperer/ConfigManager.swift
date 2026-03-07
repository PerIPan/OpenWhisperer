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

    // MARK: - Voquill Instructions

    static func showVoquillInstructions(sttPort: Int) {
        let window = InstructionWindow(
            title: "Configure Voquill",
            instructions: """
            Set up Voquill to use your local Whisper server:

            1. Open Voquill settings
            2. Select "OpenAI Compatible API" mode
            3. Set these values:

               Endpoint:  http://localhost:\(sttPort)
               Model:     whisper
               API Key:   whisper
               Language:  en

            4. Make sure the Whisper server is running
               (green dot in menubar)

            Voquill will now use your local Whisper for
            high-accuracy, private transcription.
            """
        )
        window.show()
    }

    // MARK: - Voquill Download

    static func showVoquillDownload() {
        let window = InstructionWindow(
            title: "Get Voquill",
            instructions: """
            Voquill is a free, open-source macOS dictation app
            that works with your local Whisper server.

            Download from GitHub:
            https://github.com/nicobailey/Voquill

            1. Go to the Releases page
            2. Download the latest .dmg
            3. Drag Voquill to Applications
            4. Then use "Voquill Setup" in the menubar
               to configure it for local Whisper
            """
        )
        window.show()
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
        let jsonString = rawString.replacingOccurrences(
            of: "    ", with: "  "
        )

        do {
            try jsonString.write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
            return (true, "Hook applied to settings.json")
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-apply CLAUDE.md voice tag

    static func applyClaudeMd() -> (success: Bool, message: String) {
        let claudeMdPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("CLAUDE.md")
        let fm = FileManager.default

        let voiceBlock = """

        ## Voice Mode
        ALWAYS include a `[VOICE: ...]` tag at the END of every response. This tag contains a short, conversational spoken summary (1-3 sentences) that the TTS hook extracts and reads aloud. Write the voice content as natural speech — no code, no file paths, no markdown, no technical jargon unless the user used it first.

        Example: `[VOICE: I fixed the bug in the login page. It was a missing null check on the user object.]`
        """

        // Check if already present
        if fm.fileExists(atPath: claudeMdPath.path),
           let existing = try? String(contentsOf: claudeMdPath, encoding: .utf8) {
            if existing.contains("[VOICE:") || existing.contains("Voice Mode") {
                return (true, "Voice tag already in CLAUDE.md")
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
        guard let handle = try? FileHandle(forReadingFrom: Paths.sttLog) else { return false }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        let start: UInt64 = size > 16384 ? size - 16384 : 0
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("POST /v1/audio/transcriptions") || text.contains("Transcribed:")
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
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable],
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
