import Foundation

/// The national-character persona carried into spoken replies.
///
/// `hooks/voice-shared.sh`'s `resolve_flavor()` adds a persona line to the nudge on every
/// turn, so picking `ff_siwis` doesn't just change the accent — it tells the model to be
/// "dry and faintly unimpressed" for as long as that voice is selected.
///
/// Two ways in, both resolved by the hook:
///
/// - **Automatic** (the default): keyed off the voice id's first character, as it always was.
/// - **Override**: the `tts_persona` pref (or `OW_TTS_PERSONA`) names a persona by `id`,
///   decoupling character from voice. The accent still comes from the voice — the nudge
///   already names accent and persona in separate clauses, so "a French accent, adopt a
///   Japanese persona" reads as intended rather than as a contradiction.
///
/// This is the **display and resolution** half. The hook is still the only thing that steers
/// the model; nothing here is read at nudge time.
/// `HookTests.voicePersonaParityFailures()` parses `resolve_flavor()` and fails if the two
/// drift, the same guarantee `VoiceLanguageParityChecks` gives the language map.
public enum VoicePersona {
    public struct Persona: Equatable, Sendable, Identifiable {
        /// Stable lowercase key, written to `tts_persona` and matched by the hook's case
        /// arms. Distinct from `name` so the stored value survives a copy edit to the label.
        public let id: String
        /// How the voice sounds — "American English". Full language name, as the hook says it.
        public let accent: String
        /// The character adopted — "American". Bare nationality, not the language name.
        public let name: String
        /// The character itself, lowercase and mid-sentence: "quietly self-assured, …".
        public let descriptor: String
        /// The Kokoro voice-id prefix that selects this persona automatically. Nil for a
        /// persona reachable only by explicit override — which is what a Supertonic-language
        /// persona would be, since every Supertonic id begins `supertonic:`.
        public let prefix: Character?

        public init(id: String, accent: String, name: String, descriptor: String, prefix: Character?) {
            self.id = id
            self.accent = accent
            self.name = name
            self.descriptor = descriptor
            self.prefix = prefix
        }

        /// "a" or "an" for `name`. Two of the nine ("American", "Italian") are vowel-initial,
        /// so a hardcoded "a" is wrong often enough to notice. Every persona name here is
        /// English and unambiguous on its first letter, so this need not handle the
        /// "an hour" / "a university" exceptions.
        public var article: String {
            "aeiouAEIOU".contains(name.first ?? "x") ? "an" : "a"
        }
    }

    /// The sentinel stored in `tts_persona` meaning "follow the voice". Also the default when
    /// nothing is stored, so an absent file and an explicit `auto` behave identically.
    public static let automatic = "auto"

    /// Mirrors `resolve_flavor()`'s case arms verbatim, in picker order. Reword in
    /// `voice-shared.sh` first — that copy is what the model is actually told — then bring
    /// this one along; `HookTests` fails until they match.
    public static let all: [Persona] = [
        Persona(id: "american", accent: "American English", name: "American",
                descriptor: "quietly self-assured, with a light touch of Silicon Valley hype", prefix: "a"),
        Persona(id: "british", accent: "British English", name: "British",
                descriptor: "dry and unflappable, with a streak of deadpan wit and gentle irony", prefix: "b"),
        Persona(id: "french", accent: "French", name: "French",
                descriptor: "dry and faintly unimpressed, given to the occasional philosophical shrug", prefix: "f"),
        Persona(id: "italian", accent: "Italian", name: "Italian",
                descriptor: "warm and expressive; things are either wonderful or a small catastrophe, rarely in between", prefix: "i"),
        Persona(id: "spanish", accent: "Spanish", name: "Spanish",
                descriptor: "relaxed and direct; there's always time, and it'll all be fine", prefix: "e"),
        Persona(id: "brazilian", accent: "Brazilian Portuguese", name: "Brazilian",
                descriptor: "sunny and easygoing, unbothered, always a friendly way around things", prefix: "p"),
        Persona(id: "hindi", accent: "Hindi", name: "Hindi",
                descriptor: "warm and irrepressibly helpful, the eternal problem-solver, assuring you it's no trouble at all", prefix: "h"),
        Persona(id: "japanese", accent: "Japanese", name: "Japanese",
                descriptor: "courteous and understated, meticulous, softening things, quietly prizing care and subtlety", prefix: "j"),
        Persona(id: "chinese", accent: "Mandarin Chinese", name: "Chinese",
                descriptor: "pragmatic and modest, understated, fond of a proverb, unfussed by small things", prefix: "z"),

        // Override-only (`prefix: nil`): every Supertonic id begins `supertonic:`, so no
        // first-character lookup can ever reach these. Until issue #39 decides how
        // `resolve_flavor()` should key Supertonic voices automatically, choosing one here
        // is the only way a Dutch or German voice gets any character at all.
        //
        // Text is hakan's, drafted in #39 to the bar he set there: manner not vocabulary,
        // fond not mocking, and each persona owning its *own axis* rather than being a
        // fourth synonym for "warm". Not reworded here — inventing replacements would be
        // exactly the failure that bar exists to prevent. The remaining Supertonic
        // languages stay unwritten rather than padded out.
        Persona(id: "dutch", accent: "Dutch", name: "Dutch",
                descriptor: "direct to the point of bluntness and considers that a courtesy; says the plain thing and trusts you can take it", prefix: nil),
        Persona(id: "german", accent: "German", name: "German",
                descriptor: "precise and thorough, quietly certain there is a correct way; jokes arrive deadpan and structurally sound", prefix: nil),
        Persona(id: "polish", accent: "Polish", name: "Polish",
                descriptor: "warm underneath a matter-of-fact surface; expects the worst, copes admirably, mentions neither", prefix: nil),
        Persona(id: "russian", accent: "Russian", name: "Russian",
                descriptor: "sombre and unhurried, fond of a bleak aphorism, unimpressed by enthusiasm", prefix: nil),
        Persona(id: "turkish", accent: "Turkish", name: "Turkish",
                descriptor: "hospitable and generous with reassurance; takes personal responsibility for your comfort", prefix: nil),
        Persona(id: "finnish", accent: "Finnish", name: "Finnish",
                descriptor: "sparing with words, comfortable with silence; says the necessary thing and stops", prefix: nil),
        Persona(id: "korean", accent: "Korean", name: "Korean",
                descriptor: "brisk and thorough, quietly competitive about doing it properly", prefix: nil),
        Persona(id: "greek", accent: "Greek", name: "Greek",
                descriptor: "expansive and quick to debate, always warmly; takes the long view, having watched empires come and go", prefix: nil),
    ]

    /// Personas a voice can select on its own — the nine Kokoro prefixes.
    public static var automaticPersonas: [Persona] { all.filter { $0.prefix != nil } }

    /// Personas reachable only by explicit choice. Surfaced in Settings only when a
    /// Supertonic voice is selected: they exist because those voices get no persona
    /// automatically, and offering "Dutch" beside an American-English voice is a pairing
    /// nobody asked for.
    public static var overrideOnlyPersonas: [Persona] { all.filter { $0.prefix == nil } }

    /// Prefix → persona, for the automatic path.
    public static let byPrefix: [Character: Persona] = {
        var map: [Character: Persona] = [:]
        for persona in all { if let p = persona.prefix { map[p] = persona } }
        return map
    }()

    /// The persona a voice selects on its own, ignoring any override.
    ///
    /// Keyed on the first character exactly as the hook is (`${voice:0:1}`). No
    /// `isSupertonic` guard: a `supertonic:nl:F1` id starts with `s`, which is not a key, so
    /// it falls out as `nil` for the same reason it does in bash. A guard would make Swift
    /// stricter than the hook in the one case the test cannot see.
    ///
    /// A Pocket voice has no meaningful first character (`pocket:` would read as Brazilian), so
    /// it uses its speaker's accent instead — `PocketVoice.personaKey`, which mirrors the hook's
    /// `voice_persona_key()` and is held equal to it by `HookTests`.
    public static func forVoice(_ voiceID: String) -> Persona? {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if PocketTTS.isPocketID(trimmed) {
            return PocketTTS.voice(forID: trimmed)?.personaKey.flatMap { byPrefix[$0] }
        }
        guard let first = trimmed.first else { return nil }
        return byPrefix[first]
    }

    /// Look up an explicitly chosen persona by its stored id.
    public static func forID(_ id: String) -> Persona? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == key }
    }

    /// What the model will actually be told, given the selected voice and the stored
    /// override. Mirrors `resolve_flavor()`'s precedence: a valid override wins; `auto`,
    /// empty, and unrecognized values all fall back to the voice.
    ///
    /// Unrecognized falls back rather than going silent so a typo in `tts_persona` — or a
    /// pref written by a newer build that knows a persona this one doesn't — degrades to the
    /// old behaviour instead of stripping the persona entirely.
    public static func resolve(voiceID: String, override: String?) -> Persona? {
        let key = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty, key != automatic, let chosen = forID(key) { return chosen }
        return forVoice(voiceID)
    }

    /// Compact form for the voice picker's section headers, where the point is comparing
    /// personas *before* committing to a voice. Drops `disclosure`'s "Tone only" clause —
    /// that qualifier belongs where the choice has been made, and repeating it on every
    /// group turns a browsable list into a wall of identical disclaimers.
    public static func summary(for voiceID: String) -> String? {
        forVoice(voiceID).map { summary(of: $0) }
    }

    public static func summary(of persona: Persona) -> String {
        "\(persona.article.capitalized) \(persona.name) persona — \(persona.descriptor)."
    }

    /// One sentence for Settings, phrased so the trade is legible at a glance: what changes
    /// (tone) and what does not (the work). Deliberately not the nudge's wording — that one
    /// is an instruction to a model, this one is a disclosure to a person.
    public static func disclosure(for voiceID: String) -> String? {
        disclosure(voiceID: voiceID, override: nil)
    }

    /// As above, honoring an override. Says *which* persona is actually in force, and notes
    /// when it is not the voice's own — otherwise the caption would describe a character the
    /// model was never given.
    public static func disclosure(voiceID: String, override: String?) -> String? {
        guard let persona = resolve(voiceID: voiceID, override: override) else { return nil }
        let overridden = persona != forVoice(voiceID)
        let lead = overridden
            ? "Spoken replies take on \(persona.article) \(persona.name) persona, chosen over the voice's own"
            : "Spoken replies take on \(persona.article) \(persona.name) persona"
        return "\(lead) — \(persona.descriptor). "
            + "Tone only: it never changes what gets done, or your on-screen reply."
    }
}
