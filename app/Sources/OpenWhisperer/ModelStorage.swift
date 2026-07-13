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

    /// The caches OpenWhisperer populates: the Parakeet STT models (FluidAudio, in
    /// Application Support/FluidAudio), the Kokoro TTS models + lexicon (FluidAudio,
    /// in ~/.cache), and the compiled CoreML/ANE bytecode. The two Whisper paths are
    /// orphans of the removed WhisperKit engine (2026-07-13) — listed so "Delete
    /// models" reclaims their ~1.5 GB; empty locations are hidden from the breakdown.
    static var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Location(
                name: "Parakeet STT models",
                url: home.appendingPathComponent("Library/Application Support/FluidAudio/Models")),
            Location(
                name: "Kokoro TTS models",
                url: home.appendingPathComponent(".cache/fluidaudio")),
            Location(
                name: "Whisper STT model (removed engine)",
                url: Paths.modelsDir.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")),
            Location(
                name: "Whisper STT model (legacy location)",
                url: home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")),
            Location(
                name: "Compiled model cache",
                url: home.appendingPathComponent("Library/Caches/OpenWhisperer/com.apple.e5rt.e5bundlecache")),
        ]
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
