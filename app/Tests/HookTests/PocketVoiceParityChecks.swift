import Foundation
import OpenWhispererKit

/// Pocket TTS voices across the three copies that must agree:
///
/// - `hooks/voice-shared.sh` — `voice_persona_key()` (the persona the model is actually told)
///   and `resolve_speak_args`'s default voice (what an unset `tts_voice` means to the hook);
/// - the Kit — `PocketVoice.personaKey` (what Settings discloses) and `TTSVoiceRouter.defaultVoice`;
/// - `pi/openwhisperer.ts` — `POCKET_PERSONA_KEYS`.
///
/// A Pocket id can't use the first-character rule the Kokoro voices do: `pocket:` starts with
/// `p`, which is the Brazilian persona's key, so every Pocket voice would silently turn
/// Brazilian. Also checks `build-dmg.sh` bundles exactly the program the Kit pins.
func pocketVoiceParityFailures() -> [String] {
    var failures: [String] = []

    let sharedPath = Hook.hooksDir.appendingPathComponent("voice-shared.sh")
    let piPath = Hook.repoRoot.appendingPathComponent("pi/openwhisperer.ts")
    let dmgPath = Hook.repoRoot.appendingPathComponent("app/build-dmg.sh")
    guard let shared = try? String(contentsOf: sharedPath, encoding: .utf8) else { return ["voice-shared.sh unreadable"] }
    guard let pi = try? String(contentsOf: piPath, encoding: .utf8) else { return ["pi/openwhisperer.ts unreadable"] }
    guard let dmg = try? String(contentsOf: dmgPath, encoding: .utf8) else { return ["build-dmg.sh unreadable"] }

    func pairs(_ text: String, _ pattern: String) -> [String: String] {
        let re = try! NSRegularExpression(pattern: pattern)
        var out: [String: String] = [:]
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) else { continue }
            out[String(text[a])] = String(text[b])
        }
        return out
    }

    // The Kit's view: name → key ("" for none).
    var kit: [String: String] = [:]
    for v in PocketTTS.voices { kit[v.name] = v.personaKey.map(String.init) ?? "" }

    // Hook: `pocket:<name>) echo "<key>"` arms inside voice_persona_key().
    guard let body = VoiceSharedMaps.body(of: "voice_persona_key", in: shared) else {
        return ["voice-shared.sh: voice_persona_key() not found — Pocket voices would fall back to `p` (Brazilian)"]
    }
    let hook = pairs(body, #"pocket:([a-z]+)\)\s*echo\s*"([a-z]?)""#)
    let hookHasCatchAll = body.contains("pocket:*)")
    if !hookHasCatchAll {
        failures.append("voice_persona_key(): no `pocket:*)` arm — an unlisted Pocket voice would read as Brazilian")
    }
    for (name, key) in kit {
        let hookKey = hook[name] ?? (hookHasCatchAll ? "" : "p")
        if hookKey != key {
            failures.append("persona key for pocket:\(name): Kit says '\(key)', voice_persona_key() gives '\(hookKey)'")
        }
    }
    for name in hook.keys where kit[name] == nil {
        failures.append("voice_persona_key() names pocket:\(name), which the Kit has no voice for")
    }

    // Pi: `POCKET_PERSONA_KEYS: Record<string, string> = { heart: "a", ... }`.
    if let open = pi.range(of: "POCKET_PERSONA_KEYS"), let close = pi[open.upperBound...].range(of: "}") {
        let literal = String(pi[open.upperBound..<close.lowerBound])
        let piMap = pairs(literal, #"([a-z]+):\s*"([a-z])""#)
        for (name, key) in kit where (piMap[name] ?? "") != key {
            failures.append("persona key for pocket:\(name): Kit says '\(key)', Pi's POCKET_PERSONA_KEYS gives '\(piMap[name] ?? "")'")
        }
        for name in piMap.keys where kit[name] == nil {
            failures.append("Pi's POCKET_PERSONA_KEYS names \(name), which the Kit has no voice for")
        }
    } else {
        failures.append("pi/openwhisperer.ts: POCKET_PERSONA_KEYS not found — Pi would give Pocket voices the Brazilian persona")
    }

    // The default voice, hook vs Kit.
    if let speak = VoiceSharedMaps.body(of: "resolve_speak_args", in: shared) {
        let hookDefault = pairs(speak, #"(\[\s*-z\s*"\$voice"\s*\]\s*&&\s*voice=)"([^"]+)""#).values.first
        if hookDefault != TTSVoiceRouter.defaultVoice {
            failures.append("default voice: hook's resolve_speak_args says '\(hookDefault ?? "?")', Kit's TTSVoiceRouter.defaultVoice is '\(TTSVoiceRouter.defaultVoice)'")
        }
    } else {
        failures.append("voice-shared.sh: resolve_speak_args() not found")
    }

    // build-dmg.sh must bundle exactly the program the Kit pins.
    for (what, pin) in [("release URL", PocketTTS.releaseURL.absoluteString),
                        ("tarball sha256", PocketTTS.releaseTarballSHA256),
                        ("program sha256", PocketTTS.programSHA256),
                        ("licence sha256", PocketTTS.licenseSHA256)] where !dmg.contains(pin) {
        failures.append("build-dmg.sh: Pocket \(what) differs from PocketTTS's pin (\(pin.prefix(16))…)")
    }
    if let heart = PocketTTS.voice(named: "heart"), !dmg.contains(heart.file.sha256) {
        failures.append("build-dmg.sh: Heart's sha256 differs from PocketTTS's pin")
    }

    // The crates' licence notices must ship with the program, and describe this release: the DMG
    // redistributes the binary, so its MIT/Apache/MPL obligations travel with it.
    let notices = Hook.repoRoot.appendingPathComponent("app/Resources/pocket/THIRD_PARTY_LICENSES-pocket-tts.txt")
    if let text = try? String(contentsOf: notices, encoding: .utf8) {
        let release = PocketTTS.releaseURL.pathComponents.first { $0.hasPrefix("v") } ?? "?"
        if !text.contains("release \(release)") {
            failures.append("THIRD_PARTY_LICENSES-pocket-tts.txt doesn't describe release \(release) — regenerate it (scripts/pocket-licences/)")
        }
    } else {
        failures.append("app/Resources/pocket/THIRD_PARTY_LICENSES-pocket-tts.txt is missing — the bundled binary's crate notices")
    }
    if !dmg.contains("THIRD_PARTY_LICENSES-pocket-tts.txt") {
        failures.append("build-dmg.sh doesn't bundle THIRD_PARTY_LICENSES-pocket-tts.txt")
    }
    return failures
}
