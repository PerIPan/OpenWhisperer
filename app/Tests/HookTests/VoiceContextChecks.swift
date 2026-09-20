import Foundation

/// `voice-context.sh` (UserPromptSubmit, shared by Claude Code + Codex): classify the turn against
/// the `voice_turn` signal, apply the response mode, and on a "speak" decision nudge the model to
/// call the `speak` MCP tool first. No `speak_pending` marker is written (the Stop hooks are gone).
func voiceContextFailures() -> [String] {
    var failures: [String] = []
    var sandboxes: [Hook.Sandbox] = []
    defer { sandboxes.forEach { $0.cleanup() } }
    func newSandbox() -> Hook.Sandbox { let s = Hook.Sandbox(); sandboxes.append(s); return s }

    func input(prompt: String, session: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["prompt": prompt, "session_id": session])
        return String(data: data, encoding: .utf8)!
    }
    func nudge(_ stdout: String) -> String? {
        guard let d = stdout.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let hso = o["hookSpecificOutput"] as? [String: Any] else { return nil }
        return hso["additionalContext"] as? String
    }
    func fail(_ s: String) { failures.append("voice-context.\(s)") }

    // 1) Matching prompt → signal claimed, speak-tool nudge emitted, NO marker written.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "fix the login bug", session: "abc-123"), sandbox: s)
        if s.voiceTurnExists() { fail("matchClaims: signal not claimed") }
        if s.markerExists(session: "abc-123") { fail("matchClaims: should NOT write a speak_pending marker") }
        if let d = r.stdout.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if o["suppressOutput"] as? Bool != true { fail("matchClaims: suppressOutput not true") }
            if (o["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String != "UserPromptSubmit" {
                fail("matchClaims: wrong hookEventName")
            }
            if nudge(r.stdout)?.contains("`speak` tool") != true { fail("matchClaims: nudge missing '`speak` tool'") }
        } else {
            fail("matchClaims: stdout not JSON: \(r.stdout.debugDescription)")
        }
    }

    // 2) Non-matching prompt → silent, signal preserved.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "something I typed", session: "abc-123"), sandbox: s)
        if !r.stdout.isEmpty { fail("noMatchSilent: expected no nudge, got \(r.stdout.debugDescription)") }
        if !s.voiceTurnExists() { fail("noMatchSilent: signal should be preserved") }
    }

    // 3) No signal → silent.
    do {
        let s = newSandbox()
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "anything", session: "abc-123"), sandbox: s)
        if !r.stdout.isEmpty { fail("noSignalSilent: expected silence") }
    }

    // 4) Stale signal → swept and rejected.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug", timestamp: 1)
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "fix the login bug", session: "abc-123"), sandbox: s)
        if !r.stdout.isEmpty { fail("staleRejected: expected silence") }
        if s.voiceTurnExists() { fail("staleRejected: stale signal should be swept") }
    }

    // 5) terse style → terser length phrase in the nudge.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("terse")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("one short, plain spoken sentence") != true {
            fail("terseStyle: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 6) rich style → richer length phrase.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("rich")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("a sentence or two") != true {
            fail("richStyle: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 7) per-project OW_TTS_STYLE env overrides the global file.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("rich")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_STYLE": "terse"])
        if nudge(r.stdout)?.contains("one short, plain spoken sentence") != true {
            fail("envStyleOverride: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 8) legacy voice_detail still honored when tts_style absent.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeLegacyVoiceDetail("rich")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("a sentence or two") != true {
            fail("legacyDetailFallback: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 9) full style → its own longest tier since 2.0.0: a spoken paragraph that explains,
    //    no longer folded into "rich". Still a spoken summary, NOT a whole-reply nudge.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("full")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("a spoken paragraph") != true { fail("fullStyle: not the paragraph tier: \(n?.debugDescription ?? "nil")") }
        if n?.contains("explain your reasoning") != true { fail("fullStyle: missing depth instruction") }
        if n?.contains("a sentence or two") == true { fail("fullStyle: still folded into rich") }
        if n?.contains("entire reply") == true { fail("fullStyle: should not ask for whole reply") }
        if n?.contains("`speak` tool") != true { fail("fullStyle: missing speak-tool instruction") }
    }

    // 9a) the depth instruction is exclusive to `full` — the other tiers stay lean.
    for style in ["terse", "normal", "rich"] {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle(style)
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("explain your reasoning") == true {
            fail("depthLineLeak: '\(style)' should not carry the paragraph depth instruction")
        }
        if n?.contains("a spoken paragraph") == true {
            fail("depthLineLeak: '\(style)' should not use the paragraph length phrase")
        }
    }

    // 9b) OW_TTS_STYLE=full overrides a global of a shorter tier, like the other styles do.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("terse")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_STYLE": "full"])
        let n = nudge(r.stdout)
        if n?.contains("a spoken paragraph") != true { fail("fullOverride: \(n?.debugDescription ?? "nil")") }
        if n?.contains("explain your reasoning") != true { fail("fullOverride: depth line missing") }
    }

    // --- Response mode (tts_response_mode): voice (default) | always | needed ---

    // 10a) needed + typed turn → a nudge IS emitted (every turn is a candidate), but it must
    //      hand the decision to the model rather than demanding speech unconditionally.
    do {
        let s = newSandbox(); s.writeResponseMode("needed")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "typed thing", session: "s-nt"), sandbox: s).stdout)
        if n?.contains("`speak` tool") != true { fail("neededTyped: missing speak-tool nudge: \(n?.debugDescription ?? "nil")") }
        if n?.contains("ONLY if it needs something from me") != true { fail("neededTyped: missing conditional gate") }
        if n?.contains("do NOT call the tool at all") != true { fail("neededTyped: missing silence branch") }
        // The unconditional compliance line belongs to the other modes; here skipping is correct.
        if n?.contains("Do not skip the speak call") == true { fail("neededTyped: must not demand an unconditional call") }
    }

    // 10b) needed + dictated turn → same conditional nudge, and the signal is still claimed
    //      so a later typed turn can't re-match it.
    do {
        let s = newSandbox(); s.writeResponseMode("needed"); s.writeVoiceTurn(forPrompt: "do it")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "do it", session: "s-nv"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("ONLY if it needs something from me") != true { fail("neededVoice: missing conditional gate") }
        if s.voiceTurnExists() { fail("neededVoice: voice_turn should be claimed") }
    }

    // 10c) the conditional gate is exclusive to `needed` — voice/always stay unconditional.
    for mode in ["voice", "always"] {
        let s = newSandbox(); s.writeResponseMode(mode); s.writeVoiceTurn(forPrompt: "go")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s-u"), sandbox: s).stdout)
        if n?.contains("ONLY if it needs something from me") == true {
            fail("conditionalLeak: '\(mode)' must not carry the needed-mode gate")
        }
        if n?.contains("Do not skip the speak call") != true {
            fail("conditionalLeak: '\(mode)' lost the unconditional compliance line")
        }
    }

    // 10d) OW_TTS_RESPONSE=needed overrides a global of "voice" on a typed turn, which would
    //      otherwise be silent — proving the per-project override reaches the new mode.
    do {
        let s = newSandbox(); s.writeResponseMode("voice")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "typed thing", session: "s-no"),
                         sandbox: s, env: ["OW_TTS_RESPONSE": "needed"])
        if nudge(r.stdout)?.contains("ONLY if it needs something from me") != true {
            fail("neededOverride: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }


    // 10) always + typed turn → speak-tool nudge, no marker.
    do {
        let s = newSandbox(); s.writeResponseMode("always")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "typed thing", session: "s-at"), sandbox: s)
        if nudge(r.stdout)?.contains("`speak` tool") != true { fail("alwaysTyped: \(nudge(r.stdout)?.debugDescription ?? "nil")") }
        if s.markerExists(session: "s-at") { fail("alwaysTyped: no marker expected") }
    }

    // 11) always + dictated turn → nudge AND signal claimed.
    do {
        let s = newSandbox(); s.writeResponseMode("always"); s.writeVoiceTurn(forPrompt: "do it")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "do it", session: "s-av"), sandbox: s)
        if nudge(r.stdout)?.contains("`speak` tool") != true { fail("alwaysVoice: missing nudge") }
        if s.voiceTurnExists() { fail("alwaysVoice: voice_turn should be claimed") }
    }

    // 12) removed `text` mode + dictated turn → behaves as voice: speaks and claims the signal.
    do {
        let s = newSandbox(); s.writeResponseMode("text"); s.writeVoiceTurn(forPrompt: "spoke this")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "spoke this", session: "s-tv"), sandbox: s)
        if nudge(r.stdout)?.contains("`speak` tool") != true { fail("textIsVoiceDictated: expected nudge, got \(r.stdout.debugDescription)") }
        if s.voiceTurnExists() { fail("textIsVoiceDictated: voice_turn should be claimed") }
    }

    // 13) removed `text` mode + typed turn → behaves as voice: stays silent.
    do {
        let s = newSandbox(); s.writeResponseMode("text")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "typed thing", session: "s-tt"), sandbox: s)
        if !r.stdout.isEmpty { fail("textIsVoiceTyped: expected silence, got \(r.stdout.debugDescription)") }
    }

    // 14) per-project OW_TTS_RESPONSE env overrides the global file.
    do {
        let s = newSandbox(); s.writeResponseMode("voice")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "typed", session: "s-env"),
                         sandbox: s, env: ["OW_TTS_RESPONSE": "always"])
        if nudge(r.stdout)?.contains("`speak` tool") != true { fail("envResponse: env=always did not speak a typed turn") }
    }

    // 15) unknown/corrupt mode → safe voice-fallback (typed turn stays silent).
    do {
        let s = newSandbox(); s.writeResponseMode("garbage")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "typed", session: "s-unk"), sandbox: s)
        if !r.stdout.isEmpty { fail("unknownMode: expected silence, got \(r.stdout.debugDescription)") }
    }

    // --- Native-tongue flavor: an ungated per-nation persona, personality only ---
    // Persona is present on EVERY voiced turn for a mapped voice (sentinel: "voice reading
    // this aloud"); there is no vocabulary steering and no native-word layer.

    // 16) non-English voice (French) → persona present (ungated), naming the language.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("ff_siwis")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("French") != true { fail("frenchPersona: missing 'French': \(n?.debugDescription ?? "nil")") }
        if n?.contains("voice speaking your reply") != true { fail("frenchPersona: missing persona: \(n?.debugDescription ?? "nil")") }
        if n?.contains("`speak` tool") != true { fail("frenchPersona: base nudge lost") }
    }

    // 17) another non-English voice (Japanese) → persona present, its language named.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("jf_alpha")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("Japanese") != true { fail("japanesePersona: \(n?.debugDescription ?? "nil")") }
        if n?.contains("voice speaking your reply") != true { fail("japanesePersona: missing persona") }
    }

    // 18) American English voice (af_heart, the default) → persona present (US).
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("American") != true { fail("americanPersona: missing 'American': \(n?.debugDescription ?? "nil")") }
        if n?.contains("voice speaking your reply") != true { fail("americanPersona: missing persona") }
        // Vowel-initial accent and persona take "an", not the template's old hard-coded "a".
        if n?.contains("has an American English accent") != true { fail("americanPersona: article: \(n?.debugDescription ?? "nil")") }
        if n?.contains("Adopt an American persona") != true { fail("americanPersona: persona article: \(n?.debugDescription ?? "nil")") }
    }

    // 19) no voice set → NO flavor (safe default).
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("voice speaking your reply") == true { fail("noVoiceNoFlavor: unexpected persona") }
    }

    // 20) persona composes with a non-default length style: terse + a French voice → both present.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("ff_siwis"); s.writeTtsStyle("terse")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("one short, plain spoken sentence") != true { fail("terseFrenchCompose: terse length lost") }
        if n?.contains("voice speaking your reply") != true { fail("terseFrenchCompose: persona missing") }
    }

    // 21) British English voice (b-prefix) → persona present (UK).
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("bf_alice")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("British") != true { fail("britishPersona: missing 'British'") }
        if n?.contains("voice speaking your reply") != true { fail("britishPersona: missing persona") }
        // Consonant-initial keeps "a".
        if n?.contains("has a British English accent") != true { fail("britishPersona: article: \(n?.debugDescription ?? "nil")") }
        if n?.contains("Adopt a British persona") != true { fail("britishPersona: persona article: \(n?.debugDescription ?? "nil")") }
    }

    // 22) a different non-English branch (Italian) → persona present, its language named.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("if_sara")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("Italian") != true { fail("italianPersona: \(n?.debugDescription ?? "nil")") }
        if n?.contains("voice speaking your reply") != true { fail("italianPersona: missing persona") }
        if n?.contains("has an Italian accent") != true { fail("italianPersona: article: \(n?.debugDescription ?? "nil")") }
        if n?.contains("Adopt an Italian persona") != true { fail("italianPersona: persona article: \(n?.debugDescription ?? "nil")") }
    }

    // 22b) the override path drops the accent clause and still gets the article right.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("bf_alice")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                               sandbox: s, env: ["OW_TTS_PERSONA": "italian"]).stdout)
        if n?.contains("Adopt an Italian persona for the voice speaking your reply") != true { fail("overrideArticle: \(n?.debugDescription ?? "nil")") }
        if n?.contains("accent") == true { fail("overrideArticle: accent clause should be dropped on override") }
    }

    // --- Per-project voice/speed overrides (env → nudge args; flavor follows the override) ---

    // 23) OW_TTS_VOICE override → nudge instructs speak with that voice arg.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_VOICE": "ff_siwis"])
        if nudge(r.stdout)?.contains("voice=\"ff_siwis\"") != true {
            fail("voiceOverrideArg: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 24) OW_TTS_SPEED (numeric) override → nudge instructs speak with that speed arg.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_SPEED": "1.2"])
        if nudge(r.stdout)?.contains("speed=1.2") != true {
            fail("speedOverrideArg: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 25) no override → nudge carries voice="af_heart" fallback arg but no speed arg.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("voice=\"af_heart\"") != true {
            fail("noOverrideFallbackVoice: expected voice=\"af_heart\" fallback: \(n?.debugDescription ?? "nil")")
        }
        if n?.contains("speed=") == true {
            fail("noOverrideNoSpeed: unexpected speed arg injected: \(n?.debugDescription ?? "nil")")
        }
    }

    // 26) non-numeric OW_TTS_SPEED is dropped (garbage never reaches the nudge).
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_SPEED": "fast"])
        if nudge(r.stdout)?.contains("speed=") == true {
            fail("badSpeedDropped: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 27) flavor follows OW_TTS_VOICE, not the global file: French override beats an English global.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_VOICE": "ff_siwis"])
        if nudge(r.stdout)?.contains("French") != true {
            fail("flavorFollowsOverride: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // --- Reply language for the multilingual (Supertonic) voices ---
    // The voice's language is the *default* reply language, not a directive: the engine follows
    // whatever language the model writes (TTSLanguageFollow), so the model may switch when asked
    // or when the conversation is in another language. A hard pin is `tts_language` /
    // `OW_TTS_LANGUAGE` (cases 35–37). Sentinel: "Write the text you pass to `speak` in" —
    // deliberately distinct from the persona sentinel.
    let langSentinel = "Write the text you pass to `speak` in"
    let followsText = "the voice follows the language you write"

    // 28) Dutch voice → nudge carries the "write it in Dutch" instruction and the full voice id.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:nl:F1")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains(langSentinel) != true { fail("dutchLanguageLine: missing: \(n?.debugDescription ?? "nil")") }
        if n?.contains("in Dutch by default") != true { fail("dutchLanguageLine: language not named Dutch as the default") }
        if n?.contains(followsText) != true { fail("dutchLanguageLine: model not told it may switch languages") }
        if n?.contains("voice=\"supertonic:nl:F1\"") != true { fail("dutchLanguageLine: speak voice arg lost") }
        if n?.contains("`speak` tool") != true { fail("dutchLanguageLine: base nudge lost") }
    }

    // 29) another language routes to its own name (not hard-coded to Dutch).
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:uk:M1")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("in Ukrainian by default") != true { fail("ukrainianLanguageLine: \(n?.debugDescription ?? "nil")") }
    }

    // 30) a multilingual voice gets NO persona — personas are keyed to Kokoro's first-char scheme
    //     and the language instruction takes their place.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:de:F1")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("voice speaking your reply") == true { fail("supertonicNoPersona: unexpected persona") }
        if n?.contains("in German by default") != true { fail("supertonicNoPersona: language line missing") }
    }

    // 31) a Kokoro voice gets NO language line — English users see zero change.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains(langSentinel) == true { fail("kokoroNoLanguageLine: unexpected language line") }
    }

    // 32) English Supertonic gets no language line either (English is already the default).
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:en:F1")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains(langSentinel) == true { fail("supertonicEnglishNoLine: unexpected language line") }
    }

    // 33) the language line follows OW_TTS_VOICE, matching how the persona layer behaves.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_VOICE": "supertonic:pl:F1"])
        let n = nudge(r.stdout)
        if n?.contains("in Polish by default") != true { fail("languageFollowsOverride: \(n?.debugDescription ?? "nil")") }
        if n?.contains("voice speaking your reply") == true { fail("languageFollowsOverride: unexpected persona from global") }
    }

    // 34a) Vietnamese — the router dropped `vi` once while claiming to carry every Supertonic
    //      language, silently degrading it to an English voice. Pin the hook's map too.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:vi:F1")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("in Vietnamese by default") != true { fail("vietnameseLanguageLine: \(n?.debugDescription ?? "nil")") }
    }

    // 34) an unknown language code yields no line rather than a broken sentence.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:xx:F1")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains(langSentinel) == true { fail("unknownLanguageNoLine: unexpected language line") }
    }

    // --- Pinned reply language: tts_language / OW_TTS_LANGUAGE ---
    // The one way to make the spoken language *not* follow the conversation. Any language the
    // voice map knows, for any voice — a Kokoro voice can be pinned too.

    // 35) tts_language=de with a Kokoro voice → a hard pin, named German, no "by default".
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart"); s.writeTtsLanguage("de")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("in German, whatever language the conversation is in") != true { fail("pinnedGerman: \(n?.debugDescription ?? "nil")") }
        if n?.contains("by default") == true { fail("pinnedGerman: a pin must not read as a default") }
    }

    // 36) OW_TTS_LANGUAGE=en beats a German Supertonic voice: English is pinned, and the
    //     per-project env var wins over the voice, matching every other OW_* override.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:de:M1")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_LANGUAGE": "en"])
        let n = nudge(r.stdout)
        if n?.contains("in English, whatever language the conversation is in") != true { fail("pinnedEnglishOverVoice: \(n?.debugDescription ?? "nil")") }
        if n?.contains("in German") == true { fail("pinnedEnglishOverVoice: voice language leaked into a pinned line") }
    }

    // 38) a BCP-47 pin with a region or script subtag pins the base language: `pt-BR`, `pt_BR`.
    do {
        for raw in ["pt-BR", "pt_BR", "PT-br"] {
            let s = newSandbox()
            s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart"); s.writeTtsLanguage(raw)
            let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
            if n?.contains("in Portuguese, whatever language the conversation is in") != true { fail("pinSubtag(\(raw)): \(n?.debugDescription ?? "nil")") }
        }
    }

    // 39) `english` keeps working as a pin — the first cut of OW_TTS_LANGUAGE accepted it, and
    //     a hand-written tts_language file may still say so. Case-insensitive, like the codes.
    do {
        for raw in ["english", "English", " ENGLISH "] {
            let s = newSandbox()
            s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:de:M1"); s.writeTtsLanguage(raw)
            let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
            if n?.contains("in English, whatever language the conversation is in") != true { fail("pinEnglishAlias(\(raw)): \(n?.debugDescription ?? "nil")") }
        }
    }

    // 37) an unknown tts_language is ignored, not turned into a broken pin: the voice rule applies.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("supertonic:de:M1"); s.writeTtsLanguage("klingon")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("in German by default") != true { fail("unknownPinIgnored: \(n?.debugDescription ?? "nil")") }
    }

    return failures
}
