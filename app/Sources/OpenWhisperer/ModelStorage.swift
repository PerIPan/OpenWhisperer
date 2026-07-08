import Foundation

/// On-disk locations of everything OpenWhisperer downloads or compiles, with helpers to
/// total their size and wipe them — backing the "Delete models" maintenance button in
/// Server & Logs. Removing these forces a clean re-download + Neural-Engine recompile on
/// next use (the same reset that fixes a wedged/corrupt model cache).
enum ModelStorage {
    struct Location {
        let name: String
        let url: URL
    }

    /// The caches OpenWhisperer populates: the Whisper STT model (WhisperKit hub, now under
    /// Application Support), the Kokoro TTS models + lexicon (FluidAudio, in ~/.cache), and
    /// the compiled CoreML/ANE bytecode. The legacy ~/Documents Whisper path is listed too so
    /// a pre-relocation cache (or a skipped migration) is still cleaned up; empty locations
    /// are hidden from the breakdown.
    static var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Location(
                name: "Whisper STT model",
                url: Paths.whisperHubBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")),
            Location(
                name: "Whisper STT model (old location)",
                url: home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")),
            Location(
                name: "Kokoro TTS models",
                url: home.appendingPathComponent(".cache/fluidaudio")),
            Location(
                name: "Compiled model cache",
                url: home.appendingPathComponent("Library/Caches/OpenWhisperer/com.apple.e5rt.e5bundlecache")),
        ]
    }

    /// One-time move of the Whisper (WhisperKit) hub from its legacy ~/Documents/huggingface
    /// location into the app's Application Support space — so a 1.5 GB model isn't dumped in
    /// the user's (often iCloud-synced) Documents, and everything the app downloads sits under
    /// one removable folder. A same-volume move is an instant rename (no 1.5 GB copy); skipped
    /// when the new location already exists. Call at launch BEFORE the model is loaded.
    static func migrateWhisperHubIfNeeded() {
        let fm = FileManager.default
        let old = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/huggingface")
        let new = Paths.whisperHubBase
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            NSLog("ModelStorage: migrated Whisper hub → \(new.path)")
        } catch {
            // Non-fatal: leave the legacy cache; WhisperKit re-downloads to the new path.
            NSLog("ModelStorage: Whisper hub migration failed (\(error.localizedDescription)); leaving legacy cache")
        }
    }

    /// Recursive on-disk (allocated) size of a file or directory; 0 when missing.
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let key: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: key))?.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(key)) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: key))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// Per-location breakdown (non-empty only) + the grand total, for the confirm dialog.
    static func breakdown() -> (lines: [String], total: Int64) {
        var lines: [String] = []
        var total: Int64 = 0
        for loc in locations {
            let s = size(of: loc.url)
            total += s
            if s > 0 { lines.append("•  \(loc.name) — \(format(s))") }
        }
        return (lines, total)
    }

    /// Human-readable confirmation body: what gets removed + how much space it frees.
    static func confirmationMessage() -> String {
        let (lines, total) = breakdown()
        guard total > 0 else { return "No downloaded models were found — nothing to delete." }
        return "Frees \(format(total)):\n\n" + lines.joined(separator: "\n")
            + "\n\nThe models re-download automatically the next time you dictate or use speech."
    }

    /// Best-effort wipe of every location. Missing paths are ignored.
    static func deleteAll() {
        let fm = FileManager.default
        for loc in locations { try? fm.removeItem(at: loc.url) }
    }
}
