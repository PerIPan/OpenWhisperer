import Foundation

/// Replaces the former `tests/test_tts_hook_gate.py` (now deleted; it asserted the removed `tts_hook.lockdir`
/// / `tts_hook.pid` / afplay machinery). Tests the Phase 3 `tts-hook.sh`: gate on the
/// `speak_pending` marker, then a fire-and-forget `POST /v1/audio/play`. Returns failures.
func ttsHookGateFailures() -> [String] {
    var failures: [String] = []
    var sandboxes: [Hook.Sandbox] = []
    defer { sandboxes.forEach { $0.cleanup() } }
    func newSandbox() -> Hook.Sandbox { let s = Hook.Sandbox(); s.installCurlStub(); sandboxes.append(s); return s }
    func input(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    func fail(_ s: String) { failures.append("tts-hook.\(s)") }

    // 1) stop_hook_active → bail before the gate; marker untouched, nothing POSTed.
    do {
        let s = newSandbox()
        s.writeMarker(session: "s1")
        let r = Hook.run("tts-hook.sh",
                         stdin: input(["stop_hook_active": true, "session_id": "s1", "last_assistant_message": "x"]),
                         sandbox: s)
        if r.exit != 0 { fail("stopHookActive: nonzero exit \(r.exit)") }
        if !s.markerExists(session: "s1") { fail("stopHookActive: marker should be untouched") }
        if !s.noCurlWithin() { fail("stopHookActive: should not POST") }
    }

    // 2) No marker → bail silently, nothing POSTed.
    do {
        let s = newSandbox()
        let r = Hook.run("tts-hook.sh",
                         stdin: input(["session_id": "s1", "last_assistant_message": "Hi there."]),
                         sandbox: s)
        if r.exit != 0 { fail("noMarker: nonzero exit \(r.exit)") }
        if !s.noCurlWithin() { fail("noMarker: should not POST") }
    }

    // 3) Marker + message → marker consumed and the first paragraph POSTed to /v1/audio/play.
    do {
        let s = newSandbox()
        s.writeMarker(session: "s1")
        _ = Hook.run("tts-hook.sh",
                     stdin: input(["session_id": "s1", "last_assistant_message": "Done and verified. Details follow."]),
                     sandbox: s)
        if s.markerExists(session: "s1") { fail("marksAndPosts: marker not consumed") }
        let calls = s.curlCalls()
        if !calls.contains("localhost:8000/v1/audio/play") { fail("marksAndPosts: did not POST to /v1/audio/play; calls=\(calls.debugDescription)") }
        if !calls.contains("Done and verified") { fail("marksAndPosts: payload missing spoken text; calls=\(calls.debugDescription)") }
    }

    // 4) Marker but empty message → marker consumed (gate ran) but nothing to speak → no POST.
    do {
        let s = newSandbox()
        s.writeMarker(session: "s1")
        _ = Hook.run("tts-hook.sh", stdin: input(["session_id": "s1"]), sandbox: s)
        if s.markerExists(session: "s1") { fail("emptyMessage: marker should be consumed") }
        if !s.noCurlWithin() { fail("emptyMessage: should not POST with no message") }
    }

    // 5) Non-localhost TTS_PLAY_URL → forced back to localhost.
    do {
        let s = newSandbox()
        s.writeMarker(session: "s1")
        _ = Hook.run("tts-hook.sh",
                     stdin: input(["session_id": "s1", "last_assistant_message": "Shipped it."]),
                     sandbox: s, env: ["TTS_PLAY_URL": "http://evil.example.com/v1/audio/play"])
        let calls = s.curlCalls()
        if calls.contains("evil.example.com") { fail("localhostGuard: POSTed to non-local host; calls=\(calls.debugDescription)") }
        if !calls.contains("localhost:8000/v1/audio/play") { fail("localhostGuard: did not fall back to localhost; calls=\(calls.debugDescription)") }
    }

    // 6) Unsafe session id → sanitized marker matched + consumed + POSTed.
    do {
        let s = newSandbox()
        s.writeMarker(session: "a/b c:d")
        _ = Hook.run("tts-hook.sh",
                     stdin: input(["session_id": "a/b c:d", "last_assistant_message": "Okay."]),
                     sandbox: s)
        if s.markerExists(session: "a/b c:d") { fail("sessionIdSanitized: sanitized marker not consumed") }
        if !s.curlCalls().contains("v1/audio/play") { fail("sessionIdSanitized: did not POST") }
    }

    // 7) full style → whole reply spoken (all paragraphs), code dropped — not just first paragraph.
    do {
        let s = newSandbox()
        s.writeMarker(session: "s1")
        s.writeTtsStyle("full")
        _ = Hook.run("tts-hook.sh",
                     stdin: input(["session_id": "s1",
                                   "last_assistant_message": "First spoken part.\n\n```swift\nlet x = 1\n```\n\nSecond spoken part."]),
                     sandbox: s)
        let calls = s.curlCalls()
        if !calls.contains("First spoken part") { fail("fullStyle: missing first paragraph; calls=\(calls.debugDescription)") }
        if !calls.contains("Second spoken part") { fail("fullStyle: only first paragraph spoken, expected whole reply; calls=\(calls.debugDescription)") }
        if calls.contains("let x = 1") { fail("fullStyle: code block leaked into speech; calls=\(calls.debugDescription)") }
    }

    return failures
}
