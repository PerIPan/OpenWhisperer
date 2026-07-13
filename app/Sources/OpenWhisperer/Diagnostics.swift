import AppKit
import AVFoundation
import ApplicationServices

/// One-shot diagnostics report for support: everything needed to triage a
/// "models won't download / dictation won't start" report without a screen share.
/// Assembled synchronously from cheap checks; copied to the clipboard by the UI.
enum Diagnostics {
    @MainActor
    static func report(dictation: DictationManager, server: ServerManager) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var lines: [String] = []
        lines.append("=== OpenWhisperer Diagnostics ===")
        lines.append("App: \(version) (\(build))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("— Permissions —")
        lines.append("Accessibility: \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        lines.append("Microphone: \(micPermission)")
        lines.append("")

        lines.append("— Speech model (Parakeet TDT v3) —")
        lines.append("Cached on disk: \(ParakeetTranscriber.isModelCached ? "yes" : "no")")
        lines.append("Ready: \(dictation.sttModelReady ? "yes" : "no")\(dictation.sttFailed ? " (FAILED)" : "")")
        if let status = dictation.sttStatus { lines.append("Status: \(status)") }
        if let error = dictation.error { lines.append("Last error: \(error)") }
        lines.append("")

        lines.append("— Voice model (Kokoro) —")
        let kokoroCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio")
        lines.append("Cache present: \(FileManager.default.fileExists(atPath: kokoroCache.path) ? "yes" : "no")")
        lines.append("Server: \(server.status) on port \(server.port)")
        lines.append("")

        lines.append("— Disk —")
        if let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            lines.append("Free space: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        lines.append("")

        lines.append(logTail(name: "server.log", url: Paths.serverLog))
        lines.append(logTail(name: "paste_debug.log",
                             url: Paths.appSupport.appendingPathComponent("paste_debug.log")))
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func copyToClipboard(dictation: DictationManager, server: ServerManager) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report(dictation: dictation, server: server), forType: .string)
    }

    private static var micPermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    /// Last lines of a log file, size-capped so a huge log can't bloat the report.
    private static func logTail(name: String, url: URL, lines maxLines: Int = 15) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "— \(name) — (not present)"
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readFrom = size > 16_384 ? size - 16_384 : 0
        try? handle.seek(toOffset: readFrom)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return "— \(name) — (unreadable)"
        }
        let tail = text.split(separator: "\n").suffix(maxLines).joined(separator: "\n")
        return "— \(name) (last \(maxLines) lines) —\n\(tail)"
    }
}
