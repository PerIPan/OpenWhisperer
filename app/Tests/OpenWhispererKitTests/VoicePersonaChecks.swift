import Foundation
import OpenWhispererKit

/// Guards the persona disclosure. Whether a persona is *well written* is a review concern;
/// what a test can prove is that the right voices get one, the wrong ones don't, and the
/// sentence shown to the user is actually about the voice they picked.
///
/// Parity with `resolve_flavor()` is asserted separately, in `HookTests` — only that runner
/// can read the bash side.
func voicePersonaFailures() -> [String] {
    var failures: [String] = []
    func check(_ label: String, _ ok: Bool) {
        if !ok { failures.append("VoicePersona: \(label)") }
    }

    // Every Kokoro voice the picker offers carries a persona, because the hook keys on the
    // same first character. A voice in the roster with no persona would be one whose tone
    // changes with nothing said about it.
    // Pocket voices carry their speaker's documented accent instead; one without a documented
    // accent (Alba) carries none, exactly as the hook gives her none.
    for voice in TTSVoiceRegistry.allVoices where !TTSVoiceRouter.isSupertonic(voice.id) {
        if let pocket = PocketTTS.voice(forID: voice.id) {
            let expected = pocket.personaKey.flatMap { VoicePersona.byPrefix[$0] }
            check("\(voice.id) persona follows its speaker's accent", VoicePersona.forVoice(voice.id) == expected)
            continue
        }
        check("\(voice.id) has a persona", VoicePersona.forVoice(voice.id) != nil)
    }
    // `pocket:` must never fall through to the first-character map (p → Brazilian).
    check("pocket:heart is American, not Brazilian", VoicePersona.forVoice("pocket:heart")?.name == "American")
    check("pocket:vera is British", VoicePersona.forVoice("pocket:vera")?.name == "British")
    check("unknown pocket voice has no persona", VoicePersona.forVoice("pocket:nobody") == nil)

    // Supertonic voices get the reply-language line *instead of* a persona. Disclosing one
    // for them would describe a nudge the model never receives.
    for voice in TTSVoiceRegistry.allVoices where TTSVoiceRouter.isSupertonic(voice.id) {
        check("\(voice.id) has no persona", VoicePersona.forVoice(voice.id) == nil)
    }

    // Spot-check the mapping itself, so a regression names the voice rather than a count.
    check("af_heart is American", VoicePersona.forVoice("af_heart")?.name == "American")
    check("bm_george is British", VoicePersona.forVoice("bm_george")?.name == "British")
    check("ff_siwis is French", VoicePersona.forVoice("ff_siwis")?.name == "French")
    check("jf_alpha is Japanese", VoicePersona.forVoice("jf_alpha")?.name == "Japanese")
    check("zm_yunxi is Chinese", VoicePersona.forVoice("zm_yunxi")?.name == "Chinese")

    // Accent and persona name are different strings for the English voices and must stay so:
    // the accent is a language ("American English"), the persona a nationality ("American").
    check("af_heart accent is the language name",
          VoicePersona.forVoice("af_heart")?.accent == "American English")

    // The hook trims whitespace off the stored voice before matching; a stray newline in
    // `tts_voice` must not silently drop the disclosure while the model still gets the persona.
    check("a trailing newline still resolves", VoicePersona.forVoice("af_heart\n")?.name == "American")

    // Unknown and empty inputs fall out rather than defaulting to a persona.
    check("unknown prefix has none", VoicePersona.forVoice("qq_nobody") == nil)
    check("empty id has none", VoicePersona.forVoice("") == nil)
    check("supertonic id has none", VoicePersona.forVoice("supertonic:nl:F1") == nil)

    // The disclosure sentence must name the persona and disclaim scope — those two clauses
    // are the whole point of showing it.
    if let line = VoicePersona.disclosure(for: "ff_siwis") {
        check("disclosure names the persona", line.contains("French"))
        check("disclosure carries the descriptor", line.contains("philosophical shrug"))
        check("disclosure disclaims scope", line.contains("Tone only"))
    } else {
        failures.append("VoicePersona: ff_siwis produced no disclosure")
    }
    check("no disclosure without a persona", VoicePersona.disclosure(for: "supertonic:nl:F1") == nil)

    // Article agreement. "a American" / "a Italian" is the whole reason `article` exists, and
    // it is the kind of wrong that undermines a sentence whose job is to sound considered.
    check("American takes 'an'",
          VoicePersona.disclosure(for: "af_heart")?.contains("an American persona") == true)
    check("Italian takes 'an'",
          VoicePersona.disclosure(for: "if_sara")?.contains("an Italian persona") == true)
    check("British takes 'a'",
          VoicePersona.disclosure(for: "bm_george")?.contains("a British persona") == true)
    // Catches a new vowel-initial persona added without thinking about the article.
    for voice in TTSVoiceRegistry.allVoices where !TTSVoiceRouter.isSupertonic(voice.id) {
        guard let line = VoicePersona.disclosure(for: voice.id) else { continue }
        let slip = [" a A", " a E", " a I", " a O", " a U"].contains { line.contains($0) }
        check("\(voice.id) has no 'a <vowel>' slip", !slip)
    }

    // The picker keys each Kokoro group's caption off that group's FIRST voice, so every
    // voice in the group must resolve to the same persona. If a group ever mixed prefixes
    // the header would quietly describe a persona most of its rows don't carry.
    for group in TTSVoiceRegistry.groups {
        let kokoro = group.voices.filter { !TTSVoiceRouter.isSupertonic($0.id) }
        guard let first = kokoro.first else { continue }
        // A group of only accent-undocumented Pocket voices (Alba) has, rightly, no caption.
        if kokoro.allSatisfy({ PocketTTS.voice(forID: $0.id).map { $0.personaKey == nil } ?? false }) { continue }
        guard let expected = VoicePersona.forVoice(first.id) else {
            failures.append("VoicePersona: Kokoro group '\(group.name)' has no persona for \(first.id) — its picker header would be blank")
            continue
        }
        for voice in kokoro.dropFirst() where VoicePersona.forVoice(voice.id) != expected {
            failures.append("VoicePersona: group '\(group.name)' mixes personas — \(first.id) is \(expected.name) but \(voice.id) is \(VoicePersona.forVoice(voice.id)?.name ?? "none")")
        }
    }

    // `summary` is the picker form: names the persona, carries the descriptor, and drops
    // the "Tone only" clause that `disclosure` ends on.
    if let s = VoicePersona.summary(for: "af_heart") {
        check("summary names the persona", s.contains("An American persona"))
        check("summary carries the descriptor", s.contains("Silicon Valley hype"))
        check("summary drops the Tone only clause", !s.contains("Tone only"))
    } else {
        failures.append("VoicePersona: af_heart produced no summary")
    }
    check("summary capitalises the article", VoicePersona.summary(for: "bm_george")?.hasPrefix("A British") == true)
    check("no summary without a persona", VoicePersona.summary(for: "supertonic:nl:F1") == nil)

    // --- Override resolution -------------------------------------------------------

    // Automatic: absent, empty, and the explicit sentinel must all mean "follow the voice".
    check("nil override follows the voice",
          VoicePersona.resolve(voiceID: "af_heart", override: nil)?.id == "american")
    check("empty override follows the voice",
          VoicePersona.resolve(voiceID: "af_heart", override: "")?.id == "american")
    check("auto follows the voice",
          VoicePersona.resolve(voiceID: "af_heart", override: "auto")?.id == "american")

    // A valid override wins, including a cross-pairing the automatic path could never make.
    check("override wins over the voice",
          VoicePersona.resolve(voiceID: "ff_siwis", override: "japanese")?.id == "japanese")
    check("override reaches an override-only persona",
          VoicePersona.resolve(voiceID: "supertonic:nl:F1", override: "dutch")?.id == "dutch")
    check("override is case-insensitive",
          VoicePersona.resolve(voiceID: "af_heart", override: "  BRITISH ")?.id == "british")

    // Unrecognized degrades to the voice rather than going silent — matching the hook, so a
    // typo or a pref from a newer build cannot strip the persona entirely.
    check("unknown override falls back to the voice",
          VoicePersona.resolve(voiceID: "af_heart", override: "nonsense")?.id == "american")
    check("unknown override on a personaless voice stays nil",
          VoicePersona.resolve(voiceID: "supertonic:nl:F1", override: "nonsense") == nil)
    check("automatic on a Supertonic voice stays nil",
          VoicePersona.resolve(voiceID: "supertonic:nl:F1", override: "auto") == nil)

    // Every persona is addressable by id; only the nine Kokoro ones by prefix.
    for persona in VoicePersona.all {
        check("\(persona.id) resolves by id", VoicePersona.forID(persona.id)?.id == persona.id)
    }
    check("nine personas are automatic", VoicePersona.automaticPersonas.count == 9)
    check("override-only personas have no prefix",
          VoicePersona.overrideOnlyPersonas.allSatisfy { $0.prefix == nil })
    check("automatic and override-only partition the set",
          VoicePersona.automaticPersonas.count + VoicePersona.overrideOnlyPersonas.count
              == VoicePersona.all.count)
    check("ids are unique", Set(VoicePersona.all.map(\.id)).count == VoicePersona.all.count)

    // The caption must say when the persona is *not* the voice's own, or it would describe
    // a character while implying the voice picked it.
    if let overridden = VoicePersona.disclosure(voiceID: "ff_siwis", override: "japanese") {
        check("overridden disclosure names the chosen persona", overridden.contains("Japanese"))
        check("overridden disclosure says it was chosen", overridden.contains("chosen over the voice"))
    } else {
        failures.append("VoicePersona: overridden disclosure was nil")
    }
    if let automatic = VoicePersona.disclosure(voiceID: "ff_siwis", override: "auto") {
        check("automatic disclosure does not claim an override",
              !automatic.contains("chosen over the voice"))
    } else {
        failures.append("VoicePersona: automatic disclosure was nil")
    }

    return failures
}
