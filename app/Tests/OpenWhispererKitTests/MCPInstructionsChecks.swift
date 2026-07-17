import OpenWhispererKit

/// Checks for `MCPInstructions` — the MCP-tier standing instruction builder.
/// Persona wording must stay in step with hooks/voice-shared.sh resolve_flavor
/// (same sentinel HookTests uses: "voice speaking your reply").
func mcpInstructionsFailures() -> [String] {
    var failures: [String] = []

    // Mode parsing: default and whitespace tolerance.
    if MCPInstructions.mode(from: nil) != .voice { failures.append("mode: nil should default to .voice") }
    if MCPInstructions.mode(from: "always\n") != .always { failures.append("mode: 'always\\n' should parse as .always") }
    if MCPInstructions.mode(from: "bogus") != .voice { failures.append("mode: unknown should fall back to .voice") }

    // Voice mode: keys off the trailing footer, speak-first, footer treated as invisible.
    let voice = MCPInstructions.standing(mode: .voice, style: nil, voice: nil)
    if !voice.contains(VoiceMarker.glyph) { failures.append("standing(voice): missing marker glyph") }
    if !voice.contains("dictated footer") { failures.append("standing(voice): missing 'dictated footer' condition") }
    if !voice.contains("`speak`") { failures.append("standing(voice): missing speak tool reference") }
    if !voice.contains("exactly once") { failures.append("standing(voice): missing 'exactly once'") }
    if !voice.contains("never mention") { failures.append("standing(voice): marker/tool must be unmentionable") }
    if !voice.contains("Never ask whether to speak") { failures.append("standing(voice): missing 'Never ask whether to speak'") }

    // Always mode: every turn, no marker condition.
    let always = MCPInstructions.standing(mode: .always, style: nil, voice: nil)
    if !always.contains("every user turn") { failures.append("standing(always): missing 'every user turn'") }
    if always.contains("begins with") { failures.append("standing(always): must not carry the marker condition") }
    if !always.contains("Never ask whether to speak") { failures.append("standing(always): missing 'Never ask whether to speak'") }

    // Style length phrases mirror resolve_length_phrase.
    let terse = MCPInstructions.standing(mode: .voice, style: "terse", voice: nil)
    if !terse.contains("one short, plain spoken sentence") { failures.append("style terse: wrong length phrase") }
    let rich = MCPInstructions.standing(mode: .voice, style: "rich", voice: nil)
    if !rich.contains("a sentence or two of plain spoken summary") { failures.append("style rich: wrong length phrase") }
    let full = MCPInstructions.standing(mode: .voice, style: "full", voice: nil)
    if !full.contains("a sentence or two of plain spoken summary") { failures.append("style full: must fold into rich") }
    let normal = MCPInstructions.standing(mode: .voice, style: "normal", voice: nil)
    if !normal.contains("one plain spoken sentence") { failures.append("style normal: wrong length phrase") }

    // Persona map parity with resolve_flavor: sentinel + all nine first-chars; none without a voice.
    let sentinel = "voice speaking your reply"
    let personas: [(String, String)] = [
        ("af_heart", "American"), ("bf_emma", "British"), ("ff_siwis", "French"),
        ("if_sara", "Italian"), ("ef_dora", "Spanish"), ("pf_dora", "Brazilian"),
        ("hf_alpha", "Hindi"), ("jf_alpha", "Japanese"), ("zf_xiaobei", "Chinese"),
    ]
    for (voiceID, persona) in personas {
        let s = MCPInstructions.standing(mode: .voice, style: nil, voice: voiceID)
        if !s.contains(sentinel) { failures.append("persona \(voiceID): missing sentinel '\(sentinel)'") }
        if !s.contains("\(persona) persona") { failures.append("persona \(voiceID): missing '\(persona) persona'") }
    }
    let bare = MCPInstructions.standing(mode: .voice, style: nil, voice: nil)
    if bare.contains(sentinel) { failures.append("persona: nil voice must add no flavor") }
    let unknown = MCPInstructions.standing(mode: .voice, style: nil, voice: "xf_nobody")
    if unknown.contains(sentinel) { failures.append("persona: unknown first-char must add no flavor") }

    return failures
}
