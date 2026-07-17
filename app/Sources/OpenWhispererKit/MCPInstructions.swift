import Foundation

/// Builds the MCP tier's standing instruction — shipped in the `initialize` response's
/// `instructions` field and appended to the `speak` tool description, regenerated from
/// prefs on every request by the app layer.
///
/// Ports the length-phrase, persona-flavor, and nudge wording of hooks/voice-shared.sh
/// (resolve_length_phrase / resolve_flavor / build_nudge) with the hook's per-turn prefix
/// replaced by a standing condition: the leading `VoiceMarker.glyph` in voice mode, or
/// every turn in always mode. The hook keeps its own copy of this wording for its
/// platforms; if you tune one side, tune the other and run both test suites.
public enum MCPInstructions {
    public enum Mode: String {
        case voice
        case always
    }

    /// Parse a `tts_response_mode` pref value; unknown/absent falls back to `.voice`.
    public static func mode(from raw: String?) -> Mode {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Mode(rawValue: trimmed) ?? .voice
    }

    /// The full standing instruction for the given response mode, style, and voice.
    public static func standing(mode: Mode, style: String?, voice: String?) -> String {
        let len = lengthPhrase(style: style)
        let condition: String
        switch mode {
        case .voice:
            condition = "If the user's latest message begins with \(VoiceMarker.glyph), it was dictated by voice."
        case .always:
            condition = "On every user turn, this applies."
        }
        let core = condition
            + " Before writing your on-screen reply, your FIRST action must be to call the `speak` tool"
            + " exactly once, passing \(len) that summarizes your answer and stands alone when heard."
            + " Then write your full reply on screen as usual."
            + " Treat the \(VoiceMarker.glyph) as invisible; never mention it or the tool in your written reply."
        return core + flavor(voice: voice)
    }

    /// Mirrors resolve_length_phrase in hooks/voice-shared.sh.
    static func lengthPhrase(style raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
        case "terse": return "one short, plain spoken sentence"
        case "rich", "full": return "a sentence or two of plain spoken summary"
        default: return "one plain spoken sentence"
        }
    }

    /// Mirrors resolve_flavor in hooks/voice-shared.sh: a light, subdued national persona
    /// keyed off the voice id's first character. Personality only, no vocabulary steering.
    static func flavor(voice raw: String?) -> String {
        let voice = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = voice.first else { return "" }
        let accent: String, persona: String, desc: String
        switch first {
        case "a": (accent, persona, desc) = ("American English", "American",
            "quietly self-assured, with a light touch of Silicon Valley hype")
        case "b": (accent, persona, desc) = ("British English", "British",
            "dry and unflappable, with a streak of deadpan wit and gentle irony")
        case "f": (accent, persona, desc) = ("French", "French",
            "dry and faintly unimpressed, given to the occasional philosophical shrug")
        case "i": (accent, persona, desc) = ("Italian", "Italian",
            "warm and expressive; things are either wonderful or a small catastrophe, rarely in between")
        case "e": (accent, persona, desc) = ("Spanish", "Spanish",
            "relaxed and direct; there's always time, and it'll all be fine")
        case "p": (accent, persona, desc) = ("Brazilian Portuguese", "Brazilian",
            "sunny and easygoing, unbothered, always a friendly way around things")
        case "h": (accent, persona, desc) = ("Hindi", "Hindi",
            "warm and irrepressibly helpful, the eternal problem-solver, assuring you it's no trouble at all")
        case "j": (accent, persona, desc) = ("Japanese", "Japanese",
            "courteous and understated, meticulous, softening things, quietly prizing care and subtlety")
        case "z": (accent, persona, desc) = ("Mandarin Chinese", "Chinese",
            "pragmatic and modest, understated, fond of a proverb, unfussed by small things")
        default: return ""
        }
        return " The voice speaking your reply has a \(accent) accent."
            + " Adopt a \(persona) persona: \(desc)."
    }
}
