import Foundation
import FluidAudio
import OpenWhispererKit

/// Routes synthesis to whichever engine can speak a given voice id: `KokoroTTS` for its nine
/// languages (the default), `Supertonic3TTS` for the twenty-plus it has no voice for.
///
/// Deliberately exposes the same surface `KokoroTTS` did — `prepare()`, `synthesize`,
/// `synthesizeSamples` — so `TTSPlaybackController`, `TTSHTTPServer`, and `ServeTTSMode` are
/// type-swapped rather than rewritten, and every downstream concern (sentence streaming,
/// barge-in, the `speak` MCP tool, `/v1/audio/speech`) is untouched. `AudioPlaybackEngine`
/// already takes a per-item sample rate, so Supertonic's 44.1 kHz mixes with Kokoro's 24 kHz
/// with no resampling.
///
/// A plain `final class` rather than an actor: it holds no mutable state of its own and both
/// engines are actors that serialize themselves on the compute unit.
final class TTSEngines: Sendable {
    private let kokoro = KokoroTTS()
    private let supertonic = Supertonic3TTS()

    /// Pre-warm the model the *currently selected* voice will actually use.
    ///
    /// Kokoro always warms: it's the default, it's already cached for existing users, and it's
    /// small. Supertonic warms only when the selected voice routes to it — otherwise a user who
    /// never leaves English would pay a ~260 MB download at every launch for nothing. The first
    /// use of a newly selected Supertonic voice therefore loads inside the synthesis call, which
    /// the measured 0.10 s warm load makes a non-event after the initial fetch.
    /// Only Kokoro's load can fail this call. The Supertonic pre-warm is **best-effort**: it is
    /// purely an optimization, and letting it throw here would flip `ServerManager` to
    /// `status = .error` — reporting the whole TTS server as broken — whenever its download is
    /// blocked (the documented Little Snitch / Xet-CDN case), even though English TTS is fine.
    /// On failure the model simply loads lazily inside the first `synthesizeSamples`, where
    /// `TTSPlaybackController`'s catch ends that one utterance instead of the server.
    func prepare() async throws {
        try await kokoro.prepare()
        guard TTSVoiceRouter.isSupertonic(Self.selectedVoice()) else { return }
        do {
            try await supertonic.prepare()
        } catch {
            NSLog("TTSEngines: multilingual pre-warm failed (will retry on first use): \(error)")
        }
    }

    /// Synthesize → WAV `Data` (blocking `/v1/audio/speech`).
    func synthesize(
        _ text: String, voice: String = KokoroTTS.defaultVoice, speed: Float = TTSSpeed.default
    ) async throws -> Data {
        let route = TTSVoiceRouter.route(voice)
        switch route.engine {
        case .kokoro:
            return try await kokoro.synthesize(text, voice: route.voice, speed: speed)
        case .supertonic:
            return try await supertonic.synthesize(
                text, language: Self.supertonicLanguage(for: text, route: route), style: route.voice, speed: speed)
        }
    }

    /// Supertonic follows the language of the *text*, not the voice: a `supertonic:de:M1` voice
    /// handed an English sentence speaks English (same style), instead of phonemizing English
    /// as German. Falls back to the voice's own language whenever the detector is unsure or
    /// names a language Supertonic can't speak — see `TTSLanguageFollow`.
    private static func supertonicLanguage(for text: String, route: TTSVoiceRoute) -> String {
        let voiceLanguage = route.language ?? "en"
        let guess = TextLanguageDetector.guess(for: text)
        let language = TTSLanguageFollow.language(forVoiceLanguage: voiceLanguage, text: text, guess: guess)
        if language != voiceLanguage {
            // A heuristic that can misfire deserves a trace: this is the line to look for when a
            // sentence comes out in the wrong language. Metadata only — the text is the user's
            // conversation and NSLog lands in system logs.
            let confidence = guess.map { String(format: "%.2f", $0.confidence) } ?? "n/a"
            NSLog("TTSEngines: supertonic \(voiceLanguage) → \(language) (confidence \(confidence), \(text.count) chars)")
        }
        return language
    }

    /// The rate `AudioPlaybackEngine`'s node is wired at. It builds one fixed-format graph in
    /// `init` and `schedule` takes no per-item rate, so everything reaching it must be at this
    /// rate — a 44.1 kHz buffer would otherwise play ~1.8× too slow. Read from the engine
    /// itself so the two can't drift apart.
    private static let playbackSampleRate = Int(AudioPlaybackEngine.defaultSampleRate)

    /// Synthesize → fp32 PCM samples at `playbackSampleRate` (streaming playback).
    ///
    /// Supertonic synthesizes at 44.1 kHz and is downsampled here rather than reconfiguring the
    /// playback graph per utterance. That costs content above 12 kHz — inaudible for speech, and
    /// Kokoro has always been 24 kHz — and avoids tearing down a graph with a history of wedging
    /// on reconfiguration (see the `AVAudioEngineConfigurationChange` handler). The native rate
    /// is preserved on the WAV path, which has no such constraint.
    func synthesizeSamples(
        _ text: String, voice: String = KokoroTTS.defaultVoice, speed: Float = TTSSpeed.default
    ) async throws -> (samples: [Float], sampleRate: Int) {
        let route = TTSVoiceRouter.route(voice)
        switch route.engine {
        case .kokoro:
            return try await kokoro.synthesizeSamples(text, voice: route.voice, speed: speed)
        case .supertonic:
            let native = try await supertonic.synthesizeSamples(
                text, language: Self.supertonicLanguage(for: text, route: route), style: route.voice, speed: speed)
            guard native.sampleRate != Self.playbackSampleRate else { return native }
            let converter = AudioConverter(sampleRate: Double(Self.playbackSampleRate))
            let resampled = try converter.resample(native.samples, from: Double(native.sampleRate))
            return (resampled, Self.playbackSampleRate)
        }
    }

    /// The globally selected voice, as the hooks and Settings see it. Per-project `OW_TTS_VOICE`
    /// overrides arrive as an explicit `voice` argument on the `speak` call instead, so this is
    /// only used to decide what to pre-warm.
    private static func selectedVoice() -> String {
        (try? String(contentsOf: Paths.ttsVoice, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? KokoroTTS.defaultVoice
    }
}
