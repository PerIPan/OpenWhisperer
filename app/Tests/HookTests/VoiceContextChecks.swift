import Foundation

/// Port of `tests/test_voice_context.py`. `voice-context.sh` is the UserPromptSubmit hook: it
/// matches the submitted prompt against the app's `voice_turn` signal and, on a match, marks the
/// session (`speak_pending/<id>`) and emits a nudge. Returns failures.
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

    // 1) Matching prompt → session marked, signal claimed, nudge emitted.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "fix the login bug", session: "abc-123"), sandbox: s)
        if !s.markerExists(session: "abc-123") { fail("matchClaimsAndMarks: session not marked") }
        if s.voiceTurnExists() { fail("matchClaimsAndMarks: signal not claimed") }
        if let d = r.stdout.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if o["suppressOutput"] as? Bool != true { fail("matchClaimsAndMarks: suppressOutput not true") }
            if (o["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String != "UserPromptSubmit" {
                fail("matchClaimsAndMarks: wrong hookEventName")
            }
            if nudge(r.stdout)?.contains("read aloud") != true { fail("matchClaimsAndMarks: nudge missing 'read aloud'") }
        } else {
            fail("matchClaimsAndMarks: stdout not JSON: \(r.stdout.debugDescription)")
        }
    }

    // 2) Non-matching prompt → silent, marker absent, signal preserved for the real session.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "something I typed", session: "abc-123"), sandbox: s)
        if !r.stdout.isEmpty { fail("noMatchSilent: expected no nudge, got \(r.stdout.debugDescription)") }
        if s.markerExists(session: "abc-123") { fail("noMatchSilent: should not mark session") }
        if !s.voiceTurnExists() { fail("noMatchSilent: signal should be preserved") }
    }

    // 3) No signal at all → silent.
    do {
        let s = newSandbox()
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "anything", session: "abc-123"), sandbox: s)
        if !r.stdout.isEmpty { fail("noSignalSilent: expected silence") }
        if s.markerExists(session: "abc-123") { fail("noSignalSilent: should not mark") }
    }

    // 4) Stale signal (ancient timestamp) → swept and rejected.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug", timestamp: 1)
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "fix the login bug", session: "abc-123"), sandbox: s)
        if !r.stdout.isEmpty { fail("staleRejected: expected silence") }
        if s.voiceTurnExists() { fail("staleRejected: stale signal should be swept") }
    }

    // 5) Session id with unsafe chars → marker filename sanitized.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go")
        _ = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "a/b c:d"), sandbox: s)
        if !s.markerExists(session: "a/b c:d") { fail("sessionIdSanitized: expected speak_pending/a_b_c_d") }
    }

    // 6) terse style → terser nudge.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("terse")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("one short, plain spoken sentence") != true {
            fail("terseStyle: nudge not terse: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 7) rich style → richer nudge.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("rich")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("a sentence or two") != true {
            fail("richStyle: nudge not rich: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 8) per-project OW_TTS_STYLE env overrides the global tts_style file.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("rich")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_STYLE": "terse"])
        if nudge(r.stdout)?.contains("one short, plain spoken sentence") != true {
            fail("envStyleOverride: env did not win over file: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 9) legacy voice_detail still honored when tts_style is absent (migration safety net).
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeLegacyVoiceDetail("rich")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("a sentence or two") != true {
            fail("legacyDetailFallback: legacy voice_detail not honored: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 10) full style → "speak the whole reply" nudge, not a summary opener.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("full")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("entire reply") != true {
            fail("fullStyle: nudge missing 'entire reply': \(n?.debugDescription ?? "nil")")
        }
        if n?.contains("read aloud") != true {
            fail("fullStyle: nudge missing 'read aloud': \(n?.debugDescription ?? "nil")")
        }
        if n?.contains("Open with") == true {
            fail("fullStyle: nudge should not ask for a summary opener: \(n?.debugDescription ?? "nil")")
        }
    }

    return failures
}
