import Foundation

/// Integration checks for `codex-tts-hook.sh` (Codex notify hook). Codex passes the
/// payload as the last CLI argument; the hook gates on the Response mode + the
/// `voice_turn` signal (presence + freshness, no per-session marker) and POSTs the
/// spoken text via curl. We stub curl and assert spoke/silent + signal claim across
/// the mode × input matrix. Returns failures.
func codexTtsHookFailures() -> [String] {
    var failures: [String] = []
    var sandboxes: [Hook.Sandbox] = []
    defer { sandboxes.forEach { $0.cleanup() } }
    func newSandbox() -> Hook.Sandbox { let s = Hook.Sandbox(); sandboxes.append(s); return s }
    func fail(_ s: String) { failures.append("codex-tts-hook.\(s)") }

    // Codex agent-turn-complete payload (the hook reads .["last-assistant-message"];
    // newer builds also carry the turn's user messages as input_messages).
    func makePayload(inputMessages: [String]? = nil) -> String {
        var obj: [String: Any] = [
            "type": "agent-turn-complete",
            "last-assistant-message": "Done. The build is green.",
        ]
        if let inputMessages { obj["input_messages"] = inputMessages }
        let d = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: d, encoding: .utf8)!
    }
    let payload = makePayload()

    func run(_ s: Hook.Sandbox, payload override: String? = nil, env: [String: String] = [:]) {
        s.installCurlStub()
        _ = Hook.run("codex-tts-hook.sh", args: [override ?? payload], stdin: "", sandbox: s, env: env)
    }

    // voice (default) + dictated → speaks, signal claimed.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "anything"); run(s)
        if s.curlCalls().isEmpty { fail("voiceDictatedSpeaks: expected a POST") }
        if s.voiceTurnExists() { fail("voiceDictatedSpeaks: voice_turn not claimed") }
    }
    // voice (default) + typed (no signal) → silent.
    do {
        let s = newSandbox(); run(s)
        if !s.noCurlWithin() { fail("voiceTypedSilent: should not POST") }
    }
    // text + dictated → silent, signal still consumed.
    do {
        let s = newSandbox(); s.writeResponseMode("text"); s.writeVoiceTurn(forPrompt: "x"); run(s)
        if !s.noCurlWithin() { fail("textDictatedSilent: should not POST") }
        if s.voiceTurnExists() { fail("textDictatedSilent: voice_turn not consumed") }
    }
    // text + typed → speaks.
    do {
        let s = newSandbox(); s.writeResponseMode("text"); run(s)
        if s.curlCalls().isEmpty { fail("textTypedSpeaks: expected a POST") }
    }
    // always + dictated → speaks, signal claimed.
    do {
        let s = newSandbox(); s.writeResponseMode("always"); s.writeVoiceTurn(forPrompt: "x"); run(s)
        if s.curlCalls().isEmpty { fail("alwaysDictatedSpeaks: expected a POST") }
        if s.voiceTurnExists() { fail("alwaysDictatedSpeaks: voice_turn not claimed") }
    }
    // always + typed → speaks.
    do {
        let s = newSandbox(); s.writeResponseMode("always"); run(s)
        if s.curlCalls().isEmpty { fail("alwaysTypedSpeaks: expected a POST") }
    }
    // always + stale signal → speaks, stale signal swept.
    do {
        let s = newSandbox(); s.writeResponseMode("always"); s.writeVoiceTurn(forPrompt: "x", timestamp: 1); run(s)
        if s.curlCalls().isEmpty { fail("alwaysStaleSpeaks: expected a POST") }
        if s.voiceTurnExists() { fail("alwaysStaleSpeaks: stale signal should be swept") }
    }
    // unknown/corrupt mode → safe voice-fallback: typed turn stays silent.
    do {
        let s = newSandbox(); s.writeResponseMode("garbage"); run(s)
        if !s.noCurlWithin() { fail("unknownModeFallsBackToVoice: typed should be silent") }
    }
    // per-project OW_TTS_RESPONSE env overrides the global file (file=voice, env=always).
    do {
        let s = newSandbox(); s.writeResponseMode("voice")
        run(s, env: ["OW_TTS_RESPONSE": "always"])
        if s.curlCalls().isEmpty { fail("envOverrideSpeaks: env=always did not POST a typed turn") }
    }

    // --- input_messages content-correlation (newer Codex payloads) ---

    // Matching input message → dictated turn: speaks, signal claimed. Uses the real
    // Swift-side hash via writeVoiceTurn, proving bash/Swift parity on this path too.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "fix the login bug")
        run(s, payload: makePayload(inputMessages: ["fix the login bug"]))
        if s.curlCalls().isEmpty { fail("inputMatchSpeaks: expected a POST") }
        if s.voiceTurnExists() { fail("inputMatchSpeaks: voice_turn not claimed") }
    }
    // Non-matching input (a different/parallel turn) → silent AND the signal survives
    // for the dictated turn's own event; that later matching event then speaks.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "fix the login bug")
        run(s, payload: makePayload(inputMessages: ["unrelated typed prompt"]))
        if !s.noCurlWithin() { fail("inputMismatchSilent: should not POST") }
        if !s.voiceTurnExists() { fail("inputMismatchSilent: signal must survive a foreign turn") }
        run(s, payload: makePayload(inputMessages: ["fix the login bug"]))
        if s.curlCalls().isEmpty { fail("inputMismatchThenMatch: dictated turn should still speak") }
        if s.voiceTurnExists() { fail("inputMismatchThenMatch: voice_turn not claimed") }
    }
    // Multi-message turn → match on any element.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "run the tests")
        run(s, payload: makePayload(inputMessages: ["context blob", "run the tests"]))
        if s.curlCalls().isEmpty { fail("inputAnyMatchSpeaks: expected a POST") }
        if s.voiceTurnExists() { fail("inputAnyMatchSpeaks: voice_turn not claimed") }
    }
    // Whitespace parity: dictated text is trimmed on both sides before hashing.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "hello world")
        run(s, payload: makePayload(inputMessages: ["  hello world \n"]))
        if s.curlCalls().isEmpty { fail("inputTrimParity: trimmed message should match") }
    }
    // Empty input_messages array → treated as a foreign turn: silent, signal survives.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "x")
        run(s, payload: makePayload(inputMessages: []))
        if !s.noCurlWithin() { fail("inputEmptySilent: should not POST") }
        if !s.voiceTurnExists() { fail("inputEmptySilent: signal must survive") }
    }

    return failures
}
