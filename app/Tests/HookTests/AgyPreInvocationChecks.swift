import Foundation

/// `agy-previnvocation.sh` (Antigravity CLI PreInvocation): gate on invocationNum==0 (first model
/// call of a fresh turn), read the just-submitted prompt from the transcript file, classify it
/// against voice_turn, and on a "speak" decision inject an ephemeralMessage nudge. Shares its
/// mode/hash/style/voice/flavor decision with voice-context.sh via voice-shared.sh.
func agyPreInvocationFailures() -> [String] {
    var failures: [String] = []
    var sandboxes: [Hook.Sandbox] = []
    defer { sandboxes.forEach { $0.cleanup() } }
    func newSandbox() -> Hook.Sandbox { let s = Hook.Sandbox(); sandboxes.append(s); return s }

    func input(invocationNum: Int, transcriptPath: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "invocationNum": invocationNum,
            "initialNumSteps": invocationNum + 1,
            "conversationId": "c1",
            "modelName": "gemini-3-flash-agent",
            "transcriptPath": transcriptPath,
            "workspacePaths": ["/tmp/ow-agy-test"],
        ])
        return String(data: data, encoding: .utf8)!
    }
    func ephemeralMessage(_ stdout: String) -> String? {
        guard let d = stdout.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let steps = o["injectSteps"] as? [[String: Any]],
              let first = steps.first else { return nil }
        return first["ephemeralMessage"] as? String
    }
    func isEmptyObject(_ stdout: String) -> Bool {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"
    }
    func fail(_ s: String) { failures.append("agy-previnvocation.\(s)") }

    // 1) invocationNum != 0 (mid-turn tool-loop call) → exactly {}, no transcript read at all.
    do {
        let s = newSandbox()
        let r = Hook.run("agy-previnvocation.sh", stdin: input(invocationNum: 1, transcriptPath: "/nonexistent"), sandbox: s)
        if !isEmptyObject(r.stdout) { fail("midTurnSilent: expected {}, got \(r.stdout.debugDescription)") }
    }

    // 2) invocationNum == 0, default voice mode, no voice_turn pending → {} (fast path).
    do {
        let s = newSandbox()
        let r = Hook.run("agy-previnvocation.sh", stdin: input(invocationNum: 0, transcriptPath: "/nonexistent"), sandbox: s)
        if !isEmptyObject(r.stdout) { fail("noPendingSilent: expected {}, got \(r.stdout.debugDescription)") }
    }

    // 3) invocationNum == 0, voice_turn matches the transcript's last USER_EXPLICIT text →
    //    ephemeralMessage nudge, voice_turn claimed.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug")
        let transcript = s.writeAgyTranscript(["fix the login bug"])
        let r = Hook.run("agy-previnvocation.sh", stdin: input(invocationNum: 0, transcriptPath: transcript.path), sandbox: s)
        if s.voiceTurnExists() { fail("matchClaims: signal not claimed") }
        let msg = ephemeralMessage(r.stdout)
        if msg?.contains("`speak` tool") != true { fail("matchClaims: nudge missing '`speak` tool': \(msg?.debugDescription ?? "nil")") }
        if msg?.contains("dictated by voice") != true { fail("matchClaims: missing voice-dictated prefix") }
    }

    // 4) invocationNum == 0, voice_turn present but transcript text does NOT match → {}, signal preserved.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "fix the login bug")
        let transcript = s.writeAgyTranscript(["something totally different"])
        let r = Hook.run("agy-previnvocation.sh", stdin: input(invocationNum: 0, transcriptPath: transcript.path), sandbox: s)
        if !isEmptyObject(r.stdout) { fail("noMatchSilent: expected {}, got \(r.stdout.debugDescription)") }
        if !s.voiceTurnExists() { fail("noMatchSilent: signal should be preserved") }
    }

    // 5) always mode + no voice_turn (typed-equivalent) → nudge with the typed-reply prefix.
    do {
        let s = newSandbox()
        s.writeResponseMode("always")
        let transcript = s.writeAgyTranscript(["just a typed-style request"])
        let r = Hook.run("agy-previnvocation.sh", stdin: input(invocationNum: 0, transcriptPath: transcript.path), sandbox: s)
        let msg = ephemeralMessage(r.stdout)
        if msg?.contains("should be spoken aloud") != true { fail("alwaysMode: \(msg?.debugDescription ?? "nil")") }
    }

    // 6) style/voice/persona pass-through: proves voice-shared.sh wiring, not just the base nudge.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go")
        s.writeTtsStyle("terse")
        s.writeTtsVoice("ff_siwis")
        let transcript = s.writeAgyTranscript(["go"])
        let r = Hook.run("agy-previnvocation.sh", stdin: input(invocationNum: 0, transcriptPath: transcript.path), sandbox: s)
        let msg = ephemeralMessage(r.stdout)
        if msg?.contains("one short, plain spoken sentence") != true { fail("styleVoicePassthrough: terse length missing: \(msg?.debugDescription ?? "nil")") }
        if msg?.contains("French") != true { fail("styleVoicePassthrough: French persona missing") }
    }

    // 7) multiple turns in the transcript → the hook reads the LAST USER_EXPLICIT entry only.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "the second thing")
        let transcript = s.writeAgyTranscript(["the first thing", "the second thing"])
        let r = Hook.run("agy-previnvocation.sh", stdin: input(invocationNum: 0, transcriptPath: transcript.path), sandbox: s)
        if s.voiceTurnExists() { fail("lastEntryOnly: expected the second (last) entry to match and claim voice_turn") }
        if ephemeralMessage(r.stdout) == nil { fail("lastEntryOnly: expected a nudge") }
    }

    return failures
}
