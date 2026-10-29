import Foundation

/// Which synthesis engine backs a voice id.
public enum TTSEngineKind: String, Sendable, Equatable, Codable {
    /// Kokoro-82M via FluidAudio's `KokoroAneManager` — the default, 9 languages, ANE.
    case kokoro
    /// Supertonic-3 via FluidAudio's `Supertonic3Manager` — 31 languages, ANE, 44.1 kHz.
    case supertonic
    /// Pocket TTS (Kyutai) — English, the default since 2.0.9, CPU, one program run per sentence.
    /// Kokoro stands in for any line it can't say. See `PocketTTS`.
    case pocket
}

/// A voice id resolved into the engine that can speak it plus that engine's parameters.
public struct TTSVoiceRoute: Sendable, Equatable {
    public let engine: TTSEngineKind
    /// Kokoro: the bare voice id (`af_heart`). Supertonic: the voice-style name (`F1`).
    /// Pocket: the voice's name (`heart`).
    public let voice: String
    /// Supertonic: the ISO language code (`nl`). `nil` for Kokoro, whose ids fuse language
    /// into the voice itself (`af_heart` *is* American English female), and for Pocket, which
    /// is English only and never gets a language line.
    public let language: String?

    public init(engine: TTSEngineKind, voice: String, language: String? = nil) {
        self.engine = engine
        self.voice = voice
        self.language = language
    }
}

/// Resolves a `tts_voice` string to an engine. Pure and dependency-free so it unit-tests under
/// Command Line Tools; the app's `TTSEngines` hub is the only caller that needs FluidAudio.
///
/// Kokoro ids stay bare (`af_heart`) so every existing pref value keeps working with no
/// migration. Supertonic voices carry an explicit `supertonic:<lang>:<style>` tag — the
/// language rides *inside* the id, which is why Settings needs no separate language control
/// and why per-project `OW_TTS_VOICE` overrides work unchanged.
public enum TTSVoiceRouter {
    public static let supertonicPrefix = "supertonic:"

    /// Supertonic-3's full language set (`Supertonic3Constants.availableLanguages`, minus the
    /// `na` language-agnostic entry). All 31 ride in the one model, so accepting a language
    /// here costs no extra download — `TTSVoiceRegistry` curates which ones Settings *shows*,
    /// while `OW_TTS_VOICE` can name any of these.
    ///
    /// Note: no `zh`. Supertonic-3 was not trained on Mandarin; Kokoro's `z*` voices keep it.
    public static let supertonicLanguages: Set<String> = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi",
        "fr", "hi", "hr", "hu", "id", "it", "lt", "lv", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "tr", "uk", "vi",
    ]

    /// The ten built-in voice styles (`Supertonic3Voice`): five female, five male.
    public static let supertonicStyles: Set<String> = [
        "F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5",
    ]

    /// Style used when a `supertonic:<lang>` id names a language but no (or an unknown) style.
    public static let defaultSupertonicStyle = "F1"

    /// Fallback when an id is unusable — matches the existing "ignore invalid voice names"
    /// behavior rather than failing a turn's audio — and the voice Kokoro speaks a line in
    /// when Pocket can't (Heart *is* af_heart, cloned, so the stand-in sounds the same).
    public static let defaultKokoroVoice = "af_heart"

    /// What an unset `tts_voice` means: Heart on Pocket TTS (owner, 2026-10-29). The one place
    /// the default is written in Swift — the hook's `resolve_speak_args` must say the same, and
    /// `HookTests` holds them equal.
    public static let defaultVoice = PocketTTS.defaultVoiceID

    /// Compose a Supertonic voice id. The single place the id shape is written, so the
    /// registry and any callers can't drift from `route(_:)`.
    public static func supertonicID(language: String, style: String) -> String {
        "\(supertonicPrefix)\(language):\(style)"
    }

    /// Resolve a voice id to its engine.
    ///
    /// - A bare id routes to Kokoro verbatim (no validation — Kokoro's own roster is large and
    ///   `KokoroTTS.ensureVoicePack` already handles an unknown pack gracefully).
    /// - `supertonic:<lang>:<style>` routes to Supertonic when `<lang>` is supported; an
    ///   unknown or missing `<style>` clamps to `F1`.
    /// - An unsupported language, or an empty id, falls back to the default Kokoro voice —
    ///   we can't guess a language, and silence would be worse than an English voice.
    public static func route(_ voiceID: String) -> TTSVoiceRoute {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TTSVoiceRoute(engine: .pocket, voice: PocketTTS.defaultVoiceName)
        }

        // `pocket:<name>`: a known voice routes to Pocket; an unknown name can't be spoken by
        // it, so Kokoro's af_heart takes it (Heart's own original) rather than silence.
        if PocketTTS.isPocketID(trimmed) {
            guard let voice = PocketTTS.voice(forID: trimmed) else {
                return TTSVoiceRoute(engine: .kokoro, voice: defaultKokoroVoice)
            }
            return TTSVoiceRoute(engine: .pocket, voice: voice.name)
        }

        guard trimmed.lowercased().hasPrefix(supertonicPrefix) else {
            return TTSVoiceRoute(engine: .kokoro, voice: trimmed)
        }

        let body = trimmed.dropFirst(supertonicPrefix.count)
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let language = (parts.first ?? "").lowercased()
        guard supertonicLanguages.contains(language) else {
            return TTSVoiceRoute(engine: .kokoro, voice: defaultKokoroVoice)
        }

        let requested = parts.count > 1 ? parts[1].uppercased() : ""
        let style = supertonicStyles.contains(requested) ? requested : defaultSupertonicStyle
        return TTSVoiceRoute(engine: .supertonic, voice: style, language: language)
    }

    /// Whether `voiceID` names a Supertonic voice. Convenience for call sites that only need
    /// the engine, so they don't re-parse.
    public static func isSupertonic(_ voiceID: String) -> Bool {
        route(voiceID).engine == .supertonic
    }

    /// Whether `voiceID` is spoken by Pocket TTS (an empty id included: it means the default).
    public static func isPocket(_ voiceID: String) -> Bool {
        route(voiceID).engine == .pocket
    }
}
