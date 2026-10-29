import Foundation
import OpenWhispererKit

/// Whether a voice's model bytes are already on disk.
///
/// Extracted verbatim from the closure that used to live inline in `TTSHTTPServer`'s
/// `/mcp` case, so the Settings → Voice picker's download dot and the `list_voices` MCP
/// tool answer from one definition. Two copies would drift the moment either cache path
/// moved, and the picker would then promise a download state the server disagreed with.
enum VoiceCache {
    private static let kokoroANE = ".cache/fluidaudio/Models/kokoro-82m-coreml/ANE"
    /// Present only once the whole Supertonic pipeline has been fetched, so it stands in
    /// for the model as a whole.
    private static let supertonicMarker = ".cache/fluidaudio/Models/supertonic-3/TextEncoder.mlmodelc"

    /// A voice pack under this many bytes is an error page cached under a `.bin` name,
    /// not a voice — `KokoroTTS.ensureVoicePack` uses the same floor when deciding to
    /// re-fetch, and the two must agree or the dot contradicts the download.
    private static let minimumVoicePackBytes: UInt64 = 1000

    static func isCached(_ voice: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Multilingual voices share one Supertonic model across every language and style,
        // so cache state is per-model, not per-voice: all of them flip to cached together
        // once the pipeline is on disk.
        // Pocket: Heart ships with the app; a stock voice is cached once its file is on disk.
        if PocketTTS.isPocketID(voice) {
            return PocketTTS.voice(forID: voice).map(PocketSpeaker.isCached) ?? false
        }

        if TTSVoiceRouter.isSupertonic(voice) {
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent(supertonicMarker).path)
        }

        let sanitized = voice.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !sanitized.isEmpty else { return false }
        // Ships inside the Kokoro model itself, so it is never a separate download.
        if sanitized == "af_heart" { return true }

        let path = home.appendingPathComponent("\(kokoroANE)/\(sanitized).bin").path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return size > minimumVoicePackBytes
    }
}
