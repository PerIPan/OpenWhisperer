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

    // 9) full style → folds into the richest summary tier (a sentence or two), NOT a whole-reply nudge.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("full")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("a sentence or two") != true { fail("fullStyle: not richest tier: \(n?.debugDescription ?? "nil")") }
        if n?.contains("entire reply") == true { fail("fullStyle: should not ask for whole reply") }
        if n?.contains("`speak` tool") != true { fail("fullStyle: missing speak-tool instruction") }
    }

    // --- Response mode (tts_response_mode): voice (default) | always ---

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
    }

    // 22) a different non-English branch (Italian) → persona present, its language named.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("if_sara")
        let n = nudge(Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s).stdout)
        if n?.contains("Italian") != true { fail("italianPersona: \(n?.debugDescription ?? "nil")") }
        if n?.contains("voice speaking your reply") != true { fail("italianPersona: missing persona") }
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

    return failures
}
