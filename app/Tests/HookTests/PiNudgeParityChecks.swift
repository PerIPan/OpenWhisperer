import Foundation
import OpenWhispererKit

/// Cross-target parity: the Pi extension's nudge must carry the same persona map and the same
/// reply-language map as `hooks/voice-shared.sh`.
///
/// Pi cannot source the bash hook — its extension is a single self-contained TypeScript file
/// by design — so `resolve_flavor()` and `resolve_language_line()` are mirrored there by hand.
/// From 2026-07-02 to 2026-09-02 that mirror simply did not exist: a British voice on Pi got
/// no British persona and a Dutch Supertonic voice was never told to write Dutch, and nothing
/// noticed because the existing parity checks compare the hook with the Swift Kit only. This
/// check closes that gap in both directions: a persona or language the hook has and Pi lacks,
/// or one Pi has that the hook lacks, both fail.
func piNudgeParityFailures() -> [String] {
    var failures: [String] = []

    let sharedPath = Hook.hooksDir.appendingPathComponent("voice-shared.sh")
    let extensionPath = Hook.repoRoot.appendingPathComponent("pi").appendingPathComponent("openwhisperer.ts")
    guard let shared = try? String(contentsOf: sharedPath, encoding: .utf8) else {
        return ["voice-shared.sh could not be read at \(sharedPath.path)"]
    }
    guard let ext = try? String(contentsOf: extensionPath, encoding: .utf8) else {
        return ["pi/openwhisperer.ts could not be read at \(extensionPath.path)"]
    }

    guard let flavorBody = VoiceSharedMaps.body(of: "resolve_flavor", in: shared) else {
        return ["voice-shared.sh: resolve_flavor() not found — did it get renamed?"]
    }
    guard let languageBody = VoiceSharedMaps.body(of: "resolve_language_line", in: shared) else {
        return ["voice-shared.sh: resolve_language_line() not found — did it get renamed?"]
    }

    let hookPersonas = VoiceSharedMaps.personas(inFlavorBody: flavorBody)
    let hookLanguages = VoiceSharedMaps.languages(inLanguageBody: languageBody)
    let piPersonas = VoiceSharedMaps.personas(inTypeScript: ext)
    let piLanguages = VoiceSharedMaps.languages(inTypeScript: ext)

    // Mute (#51): the hook silences every turn while tts_muted exists; Pi must honour the same
    // flag, or a muted user still hears every Pi reply.
    if shared.contains("tts_muted"), !ext.contains("\"tts_muted\"") {
        failures.append("pi/openwhisperer.ts: voice-shared.sh honours tts_muted (Mute Spoken Replies) but the Pi extension never reads it")
    }
    if !ext.contains(MCPServer.mutedMessage) {
        failures.append("pi/openwhisperer.ts: its muted reply differs from MCPServer.mutedMessage — the model would be told two different things")
    }

    if hookPersonas.isEmpty { failures.append("voice-shared.sh: resolve_flavor's case arms did not parse") }
    if hookLanguages.isEmpty { failures.append("voice-shared.sh: resolve_language_line's case arms did not parse") }
    if piPersonas.isEmpty { failures.append("pi/openwhisperer.ts: PERSONAS did not parse — Pi would apply no persona") }
    if piLanguages.isEmpty { failures.append("pi/openwhisperer.ts: LANGUAGES did not parse — a Supertonic voice on Pi would read English") }
    guard failures.isEmpty else { return failures }

    // Personas, both directions, field by field.
    for (key, hook) in hookPersonas.sorted(by: { $0.key < $1.key }) {
        guard let pi = piPersonas[key] else {
            failures.append("pi/openwhisperer.ts: no '\(key)' persona — the hook applies \(hook.name), Pi would apply nothing")
            continue
        }
        if pi.accent != hook.accent {
            failures.append("accent mismatch for '\(key)': hook says '\(hook.accent)', Pi says '\(pi.accent)'")
        }
        if pi.name != hook.name {
            failures.append("persona name mismatch for '\(key)': hook says '\(hook.name)', Pi says '\(pi.name)'")
        }
        if pi.descriptor != hook.descriptor {
            failures.append("descriptor mismatch for '\(key)': hook says '\(hook.descriptor)', Pi says '\(pi.descriptor)'")
        }
    }
    for key in piPersonas.keys.sorted() where hookPersonas[key] == nil {
        failures.append("pi/openwhisperer.ts has a '\(key)' persona that resolve_flavor() does not — reword the hook first")
    }

    // Languages, both directions.
    for (code, name) in hookLanguages.sorted(by: { $0.key < $1.key }) {
        guard let piName = piLanguages[code] else {
            failures.append("pi/openwhisperer.ts: no language line for '\(code)' (\(name)) — that voice would read English on Pi")
            continue
        }
        if piName != name {
            failures.append("language name mismatch for '\(code)': hook says '\(name)', Pi says '\(piName)'")
        }
    }
    for code in piLanguages.keys.sorted() where hookLanguages[code] == nil {
        failures.append("pi/openwhisperer.ts has a '\(code)' language that resolve_language_line() does not")
    }

    // The two sentinel phrases the hook side is keyed on must survive in the mirror, and both
    // resolvers must actually be wired into the nudge — a map nobody calls is no parity.
    for sentinel in ["voice speaking your reply", "Write the text you pass to"] where !ext.contains(sentinel) {
        failures.append("pi/openwhisperer.ts: sentinel '\(sentinel)' missing — the nudge layer it marks is not applied")
    }
    for call in ["resolveFlavor()", "resolveLanguageLine()"] where !ext.contains(call) {
        failures.append("pi/openwhisperer.ts: \(call) is never called — the nudge does not carry that layer")
    }

    // The article must follow the word: "an American English accent", "an Italian persona".
    // A hard-coded "a ${…}" is the regression this guards against; the hook picks a/an too.
    for literal in ["has a ${", "Adopt a ${"] where ext.contains(literal) {
        failures.append("pi/openwhisperer.ts: hard-coded article in '\(literal)…' — American and Italian read 'a American', 'a Italian'")
    }

    // Syntax gate. Nothing in this repo compiles the extension (Pi does, on /reload), so borrow
    // node's parser when one is on PATH. Skipped silently otherwise: parity above is the check
    // that matters, this only stops a stray brace from shipping.
    failures += nodeSyntaxFailures(for: extensionPath)

    return failures
}

/// `node --check <file>` (Node ≥ 23 strips TypeScript types itself). Empty when node is absent.
private func nodeSyntaxFailures(for file: URL) -> [String] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["node", "--check", file.path]
    let err = Pipe()
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = err
    guard (try? proc.run()) != nil else { return [] }
    let output = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    proc.waitUntilExit()
    switch proc.terminationStatus {
    case 0, 127: return []   // clean, or no node on PATH
    default:
        let firstLines = output.split(separator: "\n").prefix(6).joined(separator: "\n")
        return ["pi/openwhisperer.ts does not parse (node --check exit \(proc.terminationStatus)):\n\(firstLines)"]
    }
}
