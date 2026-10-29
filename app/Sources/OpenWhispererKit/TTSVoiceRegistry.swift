import Foundation

public struct TTSVoice: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let language: String
    public let region: String
    public let gender: String
    public var cached: Bool?

    public init(id: String, name: String, language: String, region: String, gender: String, cached: Bool? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.region = region
        self.gender = gender
        self.cached = cached
    }
}

public struct TTSVoiceGroup: Sendable {
    public let name: String
    public let voices: [TTSVoice]
    
    public init(name: String, voices: [TTSVoice]) {
        self.name = name
        self.voices = voices
    }
}

public enum TTSVoiceRegistry {
    public static let groups: [TTSVoiceGroup] = [
        TTSVoiceGroup(name: "English (US)", voices: pocketVoices(region: "US") + [
            // Kokoro's own Heart — the stand-in for every Pocket line, still selectable.
            TTSVoice(id: "af_heart", name: "Heart (Kokoro)", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_bella", name: "Bella", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_alloy", name: "Alloy", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_aoede", name: "Aoede", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_jessica", name: "Jessica", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_kore", name: "Kore", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_nicole", name: "Nicole", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_nova", name: "Nova", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_river", name: "River", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_sarah", name: "Sarah", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "af_sky", name: "Sky", language: "English", region: "US", gender: "Female"),
            TTSVoice(id: "am_adam", name: "Adam", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_echo", name: "Echo", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_eric", name: "Eric", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_fenrir", name: "Fenrir", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_liam", name: "Liam", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_michael", name: "Michael", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_onyx", name: "Onyx", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_puck", name: "Puck", language: "English", region: "US", gender: "Male"),
            TTSVoice(id: "am_santa", name: "Santa", language: "English", region: "US", gender: "Male")
        ]),
        TTSVoiceGroup(name: "English (UK)", voices: pocketVoices(region: "UK") + [
            TTSVoice(id: "bf_alice", name: "Alice", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bf_emma", name: "Emma", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bf_isabella", name: "Isabella", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bf_lily", name: "Lily", language: "English", region: "UK", gender: "Female"),
            TTSVoice(id: "bm_daniel", name: "Daniel", language: "English", region: "UK", gender: "Male"),
            TTSVoice(id: "bm_fable", name: "Fable", language: "English", region: "UK", gender: "Male"),
            TTSVoice(id: "bm_george", name: "George", language: "English", region: "UK", gender: "Male"),
            TTSVoice(id: "bm_lewis", name: "Lewis", language: "English", region: "UK", gender: "Male")
        ]),
        // Alba: Pocket's voice-acted speaker, accent not documented — her own group, so neither
        // English header (and its persona caption) claims her.
        TTSVoiceGroup(name: "English", voices: pocketVoices(region: "")),
        TTSVoiceGroup(name: "French", voices: [
            TTSVoice(id: "ff_siwis", name: "Siwis", language: "French", region: "FR", gender: "Female")
        ]),
        TTSVoiceGroup(name: "Italian", voices: [
            TTSVoice(id: "if_sara", name: "Sara", language: "Italian", region: "IT", gender: "Female"),
            TTSVoice(id: "im_nicola", name: "Nicola", language: "Italian", region: "IT", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Spanish", voices: [
            TTSVoice(id: "ef_dora", name: "Dora", language: "Spanish", region: "ES", gender: "Female"),
            TTSVoice(id: "em_alex", name: "Alex", language: "Spanish", region: "ES", gender: "Male"),
            TTSVoice(id: "em_santa", name: "Santa", language: "Spanish", region: "ES", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Portuguese (BR)", voices: [
            TTSVoice(id: "pf_dora", name: "Dora", language: "Portuguese", region: "BR", gender: "Female"),
            TTSVoice(id: "pm_alex", name: "Alex", language: "Portuguese", region: "BR", gender: "Male"),
            TTSVoice(id: "pm_santa", name: "Santa", language: "Portuguese", region: "BR", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Hindi", voices: [
            TTSVoice(id: "hf_alpha", name: "Alpha", language: "Hindi", region: "IN", gender: "Female"),
            TTSVoice(id: "hf_beta", name: "Beta", language: "Hindi", region: "IN", gender: "Female"),
            TTSVoice(id: "hm_omega", name: "Omega", language: "Hindi", region: "IN", gender: "Male"),
            TTSVoice(id: "hm_psi", name: "Psi", language: "Hindi", region: "IN", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Japanese", voices: [
            TTSVoice(id: "jf_alpha", name: "Alpha", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jf_gongitsune", name: "Gongitsune", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jf_nezumi", name: "Nezumi", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jf_tebukuro", name: "Tebukuro", language: "Japanese", region: "JP", gender: "Female"),
            TTSVoice(id: "jm_kumo", name: "Kumo", language: "Japanese", region: "JP", gender: "Male")
        ]),
        TTSVoiceGroup(name: "Chinese", voices: [
            TTSVoice(id: "zf_xiaobei", name: "Xiaobei", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zf_xiaoni", name: "Xiaoni", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zf_xiaoxiao", name: "Xiaoxiao", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zf_xiaoyi", name: "Xiaoyi", language: "Chinese", region: "CN", gender: "Female"),
            TTSVoice(id: "zm_yunjian", name: "Yunjian", language: "Chinese", region: "CN", gender: "Male"),
            TTSVoice(id: "zm_yunxi", name: "Yunxi", language: "Chinese", region: "CN", gender: "Male"),
            TTSVoice(id: "zm_yunxia", name: "Yunxia", language: "Chinese", region: "CN", gender: "Male"),
            TTSVoice(id: "zm_yunyang", name: "Yunyang", language: "Chinese", region: "CN", gender: "Male")
        ])
    ] + supertonicGroups

    /// Languages Kokoro-82M cannot speak at all, served by Supertonic-3 instead. Kokoro renders
    /// these as an English voice reading foreign text — measurably unintelligible (a Dutch ASR
    /// read-back of Kokoro's Dutch scores ~100% WER; Supertonic-3's scores ~4%).
    ///
    /// **Every** Supertonic language Kokoro cannot speak, as of 2026-08-01 — widened from a
    /// curated five on owner request. All 31 ride in the one ~264 MB model, fetched on demand
    /// the first time any `supertonic:*` voice is used, so listing a language costs zero extra
    /// bytes. The earlier five were the ones that had been listened to and ASR-verified; the
    /// rest are the same model and the same pipeline, so withholding them bought nothing but a
    /// shorter menu. **Do not re-narrow this list.**
    ///
    /// The seven languages Kokoro also covers (en, es, fr, it, pt, hi, ja) stay Kokoro-only,
    /// so no language appears under two groups and the picker never asks the user to choose an
    /// engine. `TTSVoiceRouter.supertonicLanguages` still accepts all 31 for `OW_TTS_VOICE`.
    ///
    /// Group names must match the language names `resolve_language_line()` emits in
    /// `hooks/voice-shared.sh` — the Voice tab caption and the model's nudge would otherwise
    /// disagree. `HookTests` asserts it.
    ///
    /// Two styles each (one female, one male) rather than all ten: F1–F5/M1–M5 are generic
    /// speaker styles, not per-language accents, so eight more rows per language would add
    /// length without adding meaningful choice.
    static let supertonicGroups: [TTSVoiceGroup] = [
        ("Arabic", "ar", "SA"),
        ("Bulgarian", "bg", "BG"),
        ("Croatian", "hr", "HR"),
        ("Czech", "cs", "CZ"),
        ("Danish", "da", "DK"),
        ("Dutch", "nl", "NL"),
        ("Estonian", "et", "EE"),
        ("Finnish", "fi", "FI"),
        ("German", "de", "DE"),
        ("Greek", "el", "GR"),
        ("Hungarian", "hu", "HU"),
        ("Indonesian", "id", "ID"),
        ("Korean", "ko", "KR"),
        ("Latvian", "lv", "LV"),
        ("Lithuanian", "lt", "LT"),
        ("Polish", "pl", "PL"),
        ("Romanian", "ro", "RO"),
        ("Russian", "ru", "RU"),
        ("Slovak", "sk", "SK"),
        ("Slovenian", "sl", "SI"),
        ("Swedish", "sv", "SE"),
        ("Turkish", "tr", "TR"),
        ("Ukrainian", "uk", "UA"),
        ("Vietnamese", "vi", "VN"),
    ].map { label, code, region in
        TTSVoiceGroup(name: label, voices: [
            TTSVoice(
                id: TTSVoiceRouter.supertonicID(language: code, style: "F1"),
                name: "F1", language: label, region: region, gender: "Female"),
            TTSVoice(
                id: TTSVoiceRouter.supertonicID(language: code, style: "M1"),
                name: "M1", language: label, region: region, gender: "Male"),
        ])
    }

    /// Pocket TTS's English voices of one accent, first in that accent's group: Heart (af_heart
    /// cloned onto Pocket, the default, ships with the app) and the stock voices, each downloaded
    /// on first use. Grouped by accent, not by engine — the picker never asks anyone to choose an
    /// engine, and each group's header shows one persona, which every row in it must share
    /// (`VoicePersonaChecks`). Their routes carry no language, so the language-line parity check
    /// passes them by, as it does Kokoro's English groups.
    static func pocketVoices(region: String) -> [TTSVoice] {
        PocketTTS.voices.filter { $0.region == region }.map {
            TTSVoice(id: $0.id, name: $0.displayName, language: "English", region: $0.region, gender: $0.gender)
        }
    }

    public static var allVoices: [TTSVoice] {
        groups.flatMap { $0.voices }
    }

    /// Distinct spoken languages across both engines — fewer than `groups.count`, since
    /// English is split into US and UK groups.
    ///
    /// Exists so user-facing copy can count the roster instead of restating it. The About
    /// panel's hardcoded "9 languages, plus Supertonic-3 for Dutch, German, Polish,
    /// Russian and Ukrainian" survived the 2026-08-01 widening unnoticed and was wrong in
    /// the shipped build.
    public static var languageCount: Int {
        Set(allVoices.map(\.language)).count
    }
}
