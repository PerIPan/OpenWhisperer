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

    // Codex agent-turn-complete payload (the hook reads .["last-assistant-message"]).
    let payload: String = {
        let d = try! JSONSerialization.data(withJSONObject: [
            "type": "agent-turn-complete",
            "last-assistant-message": "Done. The build is green.",
        ])
        return String(data: d, encoding: .utf8)!
    }()

    func run(_ s: Hook.Sandbox, env: [String: String] = [:]) {
        s.installCurlStub()
        _ = Hook.run("codex-tts-hook.sh", args: [payload], stdin: "", sandbox: s, env: env)
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

    return failures
}
