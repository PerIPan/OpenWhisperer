import Foundation
import OpenWhispererKit
import WhisperKit

/// Static option tables shared by the Settings tabs (moved verbatim from MenuBarView
/// so Dictation/Voice don't each keep their own copy).
enum SettingsData {
    static let allVoices: [(id: String, label: String)] = {
        TTSVoiceRegistry.allVoices.map { ($0.id, "\($0.name) (\($0.gender.prefix(1)))") }
    }()

    // MARK: - Voice (TTS)

    /// Voice picker sections: Kokoro's nine language groups, then the 24 Supertonic
    /// languages Kokoro can't speak. Rows are self-describing because the picker is
    /// searchable — under a query, section headers scroll out of view.
    static var voiceSections: [OWPickerSection] {
        TTSVoiceRegistry.groups.map { group in
            let isSupertonic = group.voices.allSatisfy { TTSVoiceRouter.isSupertonic($0.id) }
            // The engine word only when one engine speaks the whole group. Since 2.1 the English
            // groups mix Pocket voices (first) with Kokoro's, and calling them "Kokoro" put the
            // default voice under the wrong engine (review, 2026-10-29).
            let engines = Set(group.voices.map { TTSVoiceRouter.route($0.id).engine })
            let engineWord: String? = engines.count == 1
                ? [.pocket: "Pocket TTS", .kokoro: "Kokoro", .supertonic: "Supertonic"][engines.first!] : nil
            let unplaced = group.voices.allSatisfy { PocketTTS.voice(forID: $0.id).map { $0.personaKey == nil } ?? false }
            return OWPickerSection(
                id: group.name,
                title: engineWord.map { "\(group.name) · \($0)" } ?? group.name,
                // Each engine's groups need a different thing explained.
                //
                // Supertonic: F1/M1 read as accents or quality grades unless told otherwise
                // (settled in the 2.0.0 design, and only ever lived in that doc until now).
                //
                // Kokoro: the group carries a persona that shapes every spoken reply, so the
                // header says which one — letting you compare personas before committing to
                // a voice, rather than reading about the one already chosen. Keyed off the
                // group's first voice: persona is per-language, and `VoicePersonaChecks`
                // asserts every voice in a group agrees rather than trusting it.
                caption: isSupertonic
                    ? "Speaker styles, not regional accents."
                    : unplaced
                        ? "No persona: this speaker's accent isn't documented."
                        : group.voices.first.flatMap { VoicePersona.summary(for: $0.id) },
                options: group.voices.map { voice in
                    OWPickerOption(
                        id: voice.id,
                        label: "\(voice.name) · \(voice.gender)",
                        searchLabel: "\(group.name) · \(voice.name) · \(voice.gender)",
                        badge: VoiceCache.isCached(voice.id) ? nil : "downloads",
                        keywords: [voice.language, TTSVoiceRouter.route(voice.id).language ?? ""]
                    )
                }
            )
        }
    }

    /// Persona options for the selected voice. "Automatic" first, then the nine a voice can
    /// select on its own — and the override-only personas *only* when a Supertonic voice is
    /// active, since those exist precisely because Supertonic voices get none automatically.
    /// Offering "Dutch" beside an American-English voice is a pairing nobody asked for.
    static func personaOptions(for voiceID: String) -> [(id: String, label: String)] {
        var options: [(id: String, label: String)] = [
            (VoicePersona.automatic, automaticPersonaLabel(for: voiceID))
        ]
        options += VoicePersona.automaticPersonas.map { ($0.id, $0.name) }
        if TTSVoiceRouter.isSupertonic(voiceID) {
            options += VoicePersona.overrideOnlyPersonas.map { ($0.id, $0.name) }
        }
        return options
    }

    /// Names what "Automatic" resolves to, so the default is not a mystery — and says
    /// plainly when it resolves to nothing, which is every Supertonic voice today (issue #39).
    private static func automaticPersonaLabel(for voiceID: String) -> String {
        if let persona = VoicePersona.forVoice(voiceID) { return "Automatic (\(persona.name))" }
        return "Automatic (none for this voice)"
    }

    /// Fully-qualified label for the collapsed control — `Greek · F1 (Female)`. The bare
    /// voice name is ambiguous once the menu is closed: `F1 (F)` named no language at all.
    static func voiceLabel(_ voiceID: String) -> String {
        for group in TTSVoiceRegistry.groups {
            if let voice = group.voices.first(where: { $0.id == voiceID }) {
                return "\(group.name) · \(voice.name) (\(voice.gender))"
            }
        }
        return voiceID
    }

    /// The language a voice speaks, when that differs from the conversation's language and
    /// so changes what the model is told to write. Nil for English voices and unknowns.
    static func voiceLanguageName(_ voiceID: String) -> String? {
        guard TTSVoiceRouter.isSupertonic(voiceID) else { return nil }
        for group in TTSVoiceRegistry.groups where group.voices.contains(where: { $0.id == voiceID }) {
            return group.name
        }
        return nil
    }

    // MARK: - Dictate (STT)

    /// The roster (`STTLanguages`) intersected with what the linked WhisperKit build actually
    /// knows, so the picker can never offer a code the decoder would reject and the About
    /// panel can never claim more languages than are on offer.
    ///
    /// The table is hand-maintained because WhisperKit's own map is a dictionary — no stable
    /// order — and carries alias names (`castilian`/`spanish`). This intersection is the guard
    /// against that table drifting from a future pin bump; it can only ever shrink the list.
    static let supportedLanguages: [STTLanguage] = {
        let supported = Constants.languageCodes
        return STTLanguages.all.filter { supported.contains($0.code) }
    }()

    /// What Settings offers, Auto-detect included.
    static let languages: [(id: String, label: String)] =
        [(STTLanguages.autoCode, "Auto-detect")] + supportedLanguages.map { ($0.code, $0.name) }

    /// Dictate picker sections. Auto-detect is pinned first, then the shortlist, then the
    /// full roster split by measured quality. Nothing is hidden — the tiers only say how
    /// much to expect, which is a judgement the app can't make for the user.
    static var languageSections: [OWPickerSection] {
        let available = supportedLanguages

        func options(_ langs: [STTLanguage], badged: Bool) -> [OWPickerOption] {
            langs.map { lang in
                OWPickerOption(
                    id: lang.code,
                    label: lang.name,
                    // Each language's own number, not the tier boundary: Bengali at 40%
                    // and Albanian at 56% are not the same choice.
                    badge: badged ? lang.errorRate.map { "~\(Int($0.rounded()))% errors" } : nil,
                    keywords: [lang.code]
                )
            }
        }

        var sections: [OWPickerSection] = [
            OWPickerSection(id: "auto", title: "", caption: nil, options: [
                OWPickerOption(id: STTLanguages.autoCode, label: "Auto-detect",
                               keywords: ["auto", "detect"])
            ]),
            OWPickerSection(
                id: "common", title: "Common",
                caption: "The usual shortlist. All also appear under Good accuracy.",
                isShortcut: true,
                options: options(STTLanguages.common.compactMap { code in
                    available.first { $0.code == code }
                }, badged: false)
            ),
        ]

        let good = available.filter { $0.tier == .good }
        if !good.isEmpty {
            sections.append(OWPickerSection(
                id: "good", title: "Good accuracy",
                caption: "35% word errors or fewer in OpenAI's large-v3 benchmarks.",
                options: options(good, badged: false)))
        }
        let limited = available.filter { $0.tier == .limited }
        if !limited.isEmpty {
            sections.append(OWPickerSection(
                id: "limited", title: "Limited accuracy",
                caption: "More than 35% word errors. Fine for short phrases; expect to correct.",
                options: options(limited, badged: true)))
        }
        let untested = available.filter { $0.tier == .untested }
        if !untested.isEmpty {
            // No per-row badge: 35 rows repeating one string is noise, so the caption
            // carries it once.
            sections.append(OWPickerSection(
                id: "untested", title: "Untested",
                caption: "Whisper accepts these, but OpenAI published no accuracy figures.",
                options: options(untested, badged: false)))
        }
        return sections
    }

    /// Spoken-summary length, shortest to longest. "Full" is a real tier again as of 2.0.0
    /// (a spoken paragraph that explains rather than summarizes); it used to be a legacy
    /// alias folded into "Rich".
    static let styleLevels: [(id: String, label: String)] = [
        ("terse", "Terse"), ("normal", "Normal"), ("rich", "Rich"), ("full", "Full"),
    ]

    /// When replies are spoken; values match what `voice-context.sh` reads.
    /// Labels are self-describing so no explanatory caption is needed.
    static let responseModes: [(id: String, label: String)] = [
        ("voice", "Only when I dictate"), ("always", "On every turn"),
        ("needed", "Only when I'm needed"),
    ]

    static let focusApps: [(id: String, label: String)] = [
        ("Code", "VS Code"), ("Code - Insiders", "VS Code Insiders"),
        ("Cursor", "Cursor (AI Editor)"), ("Windsurf", "Windsurf (AI Editor)"),
        ("Zed", "Zed (Editor)"), ("Xcode", "Xcode (Apple IDE)"),
        ("Sublime Text", "Sublime Text (Editor)"), ("Nova", "Nova (Panic)"),
        ("Fleet", "Fleet (JetBrains)"), ("Claude", "Claude (Desktop)"),
        ("Terminal", "Terminal (macOS)"), ("iTerm2", "iTerm2 (Terminal)"),
        ("Warp", "Warp (Terminal)"), ("Alacritty", "Alacritty (Terminal)"),
        ("Ghostty", "Ghostty (Terminal)"), ("CUSTOM", "Custom…"),
    ]

    /// "1×", "1.15×" — trims trailing zeros so slider readouts stay tidy.
    static func multiplierLabel(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s + "×"
    }
}
