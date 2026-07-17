# MCP-Only Voice Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Voice support for Claude Desktop (and any future MCP client) with zero hook infrastructure: a leading 🎙 marker on dictated transcripts + a standing instruction shipped by the MCP server.

**Architecture:** Dictations targeting an allowlisted bundle (v1: Claude Desktop) are typed with a leading `🎙` (U+1F399, bare). The MCP server ships a standing instruction — in the `initialize` response's `instructions` field and appended to the `speak` tool description — telling the model to call `speak` first when the latest user message begins with 🎙 (or on every turn in `always` mode). The instruction text is regenerated from pref files on every request, injected into the pure Kit dispatcher from the app layer (same pattern as `isVoiceCached`). A new `--mcp-stdio` mode bridges stdio⇄HTTP for Claude Desktop, whose `claude_desktop_config.json` only launches stdio servers. Hooks and all existing platforms are untouched.

**Tech Stack:** Swift 5 / SwiftPM (package root `app/`), Foundation only in `OpenWhispererKit`, Network.framework HTTP server in the app target. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md`. One deviation, made deliberately (Task 10 records it in the spec): the spec's `clientInfo` scoping is dropped. The MCP transport is stateless (no session header; a fresh `MCPServer()` per request — `TTSHTTPServer.swift:151`), so correlating `initialize` with later `tools/list` calls would require new session plumbing. The marker makes the instruction self-scoping instead: "begins with 🎙" is never true on hook platforms, so identical instructions are safe everywhere. In `always` mode the standing instruction and the hook nudge agree rather than conflict.

## Global Constraints

- macOS 14+, Apple Silicon. This machine has **Command Line Tools only** — no XCTest; tests are plain executables.
- All Swift commands run from `app/` (the SwiftPM package root).
- Test commands: `swift run OpenWhispererKitTests` and `swift run HookTests` — both `exit(1)` on failure. There is no per-test filter.
- `OpenWhispererKit` stays pure and dependency-free (Foundation only, no AppKit/AVFoundation/FluidAudio). All new testable logic goes there.
- `Paths` is app-target-internal — Kit code must never read pref files directly; the app layer reads and injects (the `isVoiceCached` closure at `TTSHTTPServer.swift:140-150` is the pattern).
- The marker glyph is `U+1F399` **bare** (no `U+FE0F` variation selector): Swift literal `"\u{1F399}"`. Claude Desktop's bundle ID is `com.anthropic.claudefordesktop`.
- MCP protocol version stays `2025-11-25`; the server remains request/response only (no SSE, no `tools/list_changed`; `capabilities.tools` stays an empty object).
- Hooks (`hooks/*.sh`), `HookTests`, the Pi extension, and all existing platform behavior are untouched.
- Commits: Conventional Commits, imperative, hard cap 72 chars including `type(scope):` prefix. No Co-Authored-By/tool attribution.
- Work in a worktree branch off `main` (`git worktree add .claude/worktrees/mcp-voice-tier -b mcp-voice-tier`), per AGENTS.md PR workflow.
- The clipboard is never touched by dictation. Do not alter the typing tiers (Accessibility / CGEvent Unicode).

---

### Task 1: `VoiceMarker` (Kit) — glyph, allowlist, apply

**Files:**
- Create: `app/Sources/OpenWhispererKit/VoiceMarker.swift`
- Test: `app/Tests/OpenWhispererKitTests/VoiceMarkerChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (runner list, after line 27)

**Interfaces:**
- Consumes: nothing.
- Produces: `VoiceMarker.glyph: String`, `VoiceMarker.targetBundleIDs: Set<String>`, `VoiceMarker.shouldMark(bundleID: String?) -> Bool`, `VoiceMarker.apply(_ text: String, bundleID: String?) -> String`. Tasks 2 and 9 use `glyph` and `apply`.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/OpenWhispererKitTests/VoiceMarkerChecks.swift`:

```swift
import OpenWhispererKit

/// Checks for `VoiceMarker` — the MCP-tier leading dictation marker.
func voiceMarkerFailures() -> [String] {
    var failures: [String] = []

    // The glyph is exactly bare U+1F399 (no variation selector).
    if VoiceMarker.glyph != "\u{1F399}" {
        failures.append("VoiceMarker.glyph: expected bare U+1F399, got \(VoiceMarker.glyph.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))")
    }
    if VoiceMarker.glyph.unicodeScalars.count != 1 {
        failures.append("VoiceMarker.glyph: expected a single scalar, got \(VoiceMarker.glyph.unicodeScalars.count)")
    }

    // Claude Desktop is in the v1 allowlist.
    if !VoiceMarker.shouldMark(bundleID: "com.anthropic.claudefordesktop") {
        failures.append("VoiceMarker.shouldMark: Claude Desktop bundle not matched")
    }
    if VoiceMarker.shouldMark(bundleID: nil) {
        failures.append("VoiceMarker.shouldMark: nil bundle must not match")
    }
    if VoiceMarker.shouldMark(bundleID: "com.apple.Terminal") {
        failures.append("VoiceMarker.shouldMark: Terminal must not match (terminal-focus problem)")
    }
    if VoiceMarker.shouldMark(bundleID: "com.tinyspeck.slackmacgap") {
        failures.append("VoiceMarker.shouldMark: Slack must not match")
    }

    // apply prepends "🎙 " for targets and passes through otherwise.
    if VoiceMarker.apply("hello", bundleID: "com.anthropic.claudefordesktop") != "\u{1F399} hello" {
        failures.append("VoiceMarker.apply: marker not prepended for Claude Desktop")
    }
    if VoiceMarker.apply("hello", bundleID: "com.apple.Notes") != "hello" {
        failures.append("VoiceMarker.apply: text changed for non-target bundle")
    }
    if VoiceMarker.apply("hello", bundleID: nil) != "hello" {
        failures.append("VoiceMarker.apply: text changed for nil bundle")
    }

    return failures
}
```

Register the group in `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` — add after `failures += vocabularyCorrectorFailures()` (line 27):

```swift
        failures += voiceMarkerFailures()
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `app/`): `swift run OpenWhispererKitTests`
Expected: build FAILS with "cannot find 'VoiceMarker' in scope" (a compile failure is this suite's red state for a new type).

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/OpenWhispererKit/VoiceMarker.swift`:

```swift
import Foundation

/// The MCP-tier dictation marker. Apps with no hook system (Claude Desktop) get voice-gating
/// from a leading glyph typed with the transcript: the MCP server's standing instruction
/// (`MCPInstructions`) tells the model to call `speak` first when the latest user message
/// begins with it. Only allowlisted bundles get the marker — a terminal's frontmost app tells
/// us nothing about whether an agent, a shell, or vim has focus, so CLI hosts must never be
/// listed (see docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
public enum VoiceMarker {
    /// U+1F399 STUDIO MICROPHONE, bare — text presentation (monochrome) where honored.
    public static let glyph = "\u{1F399}"

    /// Bundle IDs whose dictations are marked (the MCP tier).
    public static let targetBundleIDs: Set<String> = ["com.anthropic.claudefordesktop"]

    public static func shouldMark(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targetBundleIDs.contains(bundleID)
    }

    /// Prepend the marker for MCP-tier targets; return the text unchanged otherwise.
    public static func apply(_ text: String, bundleID: String?) -> String {
        shouldMark(bundleID: bundleID) ? "\(glyph) \(text)" : text
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhispererKit/VoiceMarker.swift app/Tests/OpenWhispererKitTests/VoiceMarkerChecks.swift app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(voice): add VoiceMarker for MCP-tier dictation"
```

---

### Task 2: `MCPInstructions` (Kit) — the standing instruction builder

**Files:**
- Create: `app/Sources/OpenWhispererKit/MCPInstructions.swift`
- Test: `app/Tests/OpenWhispererKitTests/MCPInstructionsChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (runner list)

**Interfaces:**
- Consumes: `VoiceMarker.glyph` (Task 1).
- Produces: `MCPInstructions.Mode` (`.voice`/`.always`), `MCPInstructions.mode(from: String?) -> Mode`, `MCPInstructions.standing(mode: Mode, style: String?, voice: String?) -> String`. Task 4 calls these from the app layer.

This ports three functions from `hooks/voice-shared.sh` into Swift for the MCP tier: `resolve_length_phrase` (lines 59–68), `resolve_flavor` (lines 76–97, the persona map), and the nudge shape of `build_nudge` (lines 115–128), with the hook's per-turn prefix replaced by the marker/always condition. The hook keeps its own copy — `HookTests` guards the bash side (sentinel `voice speaking your reply`), this task's checks guard the Swift side. Task 10 updates AGENTS.md's "map lives only in the hook" claim.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/OpenWhispererKitTests/MCPInstructionsChecks.swift`:

```swift
import OpenWhispererKit

/// Checks for `MCPInstructions` — the MCP-tier standing instruction builder.
/// Persona wording must stay in step with hooks/voice-shared.sh resolve_flavor
/// (same sentinel HookTests uses: "voice speaking your reply").
func mcpInstructionsFailures() -> [String] {
    var failures: [String] = []

    // Mode parsing: default and whitespace tolerance.
    if MCPInstructions.mode(from: nil) != .voice { failures.append("mode: nil should default to .voice") }
    if MCPInstructions.mode(from: "always\n") != .always { failures.append("mode: 'always\\n' should parse as .always") }
    if MCPInstructions.mode(from: "bogus") != .voice { failures.append("mode: unknown should fall back to .voice") }

    // Voice mode: keys off the marker glyph, speak-first, marker treated as invisible.
    let voice = MCPInstructions.standing(mode: .voice, style: nil, voice: nil)
    if !voice.contains(VoiceMarker.glyph) { failures.append("standing(voice): missing marker glyph") }
    if !voice.contains("begins with") { failures.append("standing(voice): missing 'begins with' condition") }
    if !voice.contains("`speak`") { failures.append("standing(voice): missing speak tool reference") }
    if !voice.contains("exactly once") { failures.append("standing(voice): missing 'exactly once'") }
    if !voice.contains("never mention") { failures.append("standing(voice): marker/tool must be unmentionable") }

    // Always mode: every turn, no marker condition.
    let always = MCPInstructions.standing(mode: .always, style: nil, voice: nil)
    if !always.contains("every user turn") { failures.append("standing(always): missing 'every user turn'") }
    if always.contains("begins with") { failures.append("standing(always): must not carry the marker condition") }

    // Style length phrases mirror resolve_length_phrase.
    let terse = MCPInstructions.standing(mode: .voice, style: "terse", voice: nil)
    if !terse.contains("one short, plain spoken sentence") { failures.append("style terse: wrong length phrase") }
    let rich = MCPInstructions.standing(mode: .voice, style: "rich", voice: nil)
    if !rich.contains("a sentence or two of plain spoken summary") { failures.append("style rich: wrong length phrase") }
    let full = MCPInstructions.standing(mode: .voice, style: "full", voice: nil)
    if !full.contains("a sentence or two of plain spoken summary") { failures.append("style full: must fold into rich") }
    let normal = MCPInstructions.standing(mode: .voice, style: "normal", voice: nil)
    if !normal.contains("one plain spoken sentence") { failures.append("style normal: wrong length phrase") }

    // Persona map parity with resolve_flavor: sentinel + all nine first-chars; none without a voice.
    let sentinel = "voice speaking your reply"
    let personas: [(String, String)] = [
        ("af_heart", "American"), ("bf_emma", "British"), ("ff_siwis", "French"),
        ("if_sara", "Italian"), ("ef_dora", "Spanish"), ("pf_dora", "Brazilian"),
        ("hf_alpha", "Hindi"), ("jf_alpha", "Japanese"), ("zf_xiaobei", "Chinese"),
    ]
    for (voiceID, persona) in personas {
        let s = MCPInstructions.standing(mode: .voice, style: nil, voice: voiceID)
        if !s.contains(sentinel) { failures.append("persona \(voiceID): missing sentinel '\(sentinel)'") }
        if !s.contains("\(persona) persona") { failures.append("persona \(voiceID): missing '\(persona) persona'") }
    }
    let bare = MCPInstructions.standing(mode: .voice, style: nil, voice: nil)
    if bare.contains(sentinel) { failures.append("persona: nil voice must add no flavor") }
    let unknown = MCPInstructions.standing(mode: .voice, style: nil, voice: "xf_nobody")
    if unknown.contains(sentinel) { failures.append("persona: unknown first-char must add no flavor") }

    return failures
}
```

Register in the runner: add `failures += mcpInstructionsFailures()` after the `voiceMarkerFailures()` line.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run OpenWhispererKitTests`
Expected: build FAILS with "cannot find 'MCPInstructions' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/OpenWhispererKit/MCPInstructions.swift`:

```swift
import Foundation

/// Builds the MCP tier's standing instruction — shipped in the `initialize` response's
/// `instructions` field and appended to the `speak` tool description, regenerated from
/// prefs on every request by the app layer.
///
/// Ports the length-phrase, persona-flavor, and nudge wording of hooks/voice-shared.sh
/// (resolve_length_phrase / resolve_flavor / build_nudge) with the hook's per-turn prefix
/// replaced by a standing condition: the leading `VoiceMarker.glyph` in voice mode, or
/// every turn in always mode. The hook keeps its own copy of this wording for its
/// platforms; if you tune one side, tune the other and run both test suites.
public enum MCPInstructions {
    public enum Mode: String {
        case voice
        case always
    }

    /// Parse a `tts_response_mode` pref value; unknown/absent falls back to `.voice`.
    public static func mode(from raw: String?) -> Mode {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Mode(rawValue: trimmed) ?? .voice
    }

    /// The full standing instruction for the given response mode, style, and voice.
    public static func standing(mode: Mode, style: String?, voice: String?) -> String {
        let len = lengthPhrase(style: style)
        let condition: String
        switch mode {
        case .voice:
            condition = "If the user's latest message begins with \(VoiceMarker.glyph), it was dictated by voice."
        case .always:
            condition = "On every user turn, this applies."
        }
        let core = condition
            + " Before writing your on-screen reply, your FIRST action must be to call the `speak` tool"
            + " exactly once, passing \(len) that summarizes your answer and stands alone when heard."
            + " Then write your full reply on screen as usual."
            + " Treat the \(VoiceMarker.glyph) as invisible; never mention it or the tool in your written reply."
        return core + flavor(voice: voice)
    }

    /// Mirrors resolve_length_phrase in hooks/voice-shared.sh.
    static func lengthPhrase(style raw: String?) -> String {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
        case "terse": return "one short, plain spoken sentence"
        case "rich", "full": return "a sentence or two of plain spoken summary"
        default: return "one plain spoken sentence"
        }
    }

    /// Mirrors resolve_flavor in hooks/voice-shared.sh: a light, subdued national persona
    /// keyed off the voice id's first character. Personality only, no vocabulary steering.
    static func flavor(voice raw: String?) -> String {
        let voice = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = voice.first else { return "" }
        let accent: String, persona: String, desc: String
        switch first {
        case "a": (accent, persona, desc) = ("American English", "American",
            "quietly self-assured, with a light touch of Silicon Valley hype")
        case "b": (accent, persona, desc) = ("British English", "British",
            "dry and unflappable, with a streak of deadpan wit and gentle irony")
        case "f": (accent, persona, desc) = ("French", "French",
            "dry and faintly unimpressed, given to the occasional philosophical shrug")
        case "i": (accent, persona, desc) = ("Italian", "Italian",
            "warm and expressive; things are either wonderful or a small catastrophe, rarely in between")
        case "e": (accent, persona, desc) = ("Spanish", "Spanish",
            "relaxed and direct; there's always time, and it'll all be fine")
        case "p": (accent, persona, desc) = ("Brazilian Portuguese", "Brazilian",
            "sunny and easygoing, unbothered, always a friendly way around things")
        case "h": (accent, persona, desc) = ("Hindi", "Hindi",
            "warm and irrepressibly helpful, the eternal problem-solver, assuring you it's no trouble at all")
        case "j": (accent, persona, desc) = ("Japanese", "Japanese",
            "courteous and understated, meticulous, softening things, quietly prizing care and subtlety")
        case "z": (accent, persona, desc) = ("Mandarin Chinese", "Chinese",
            "pragmatic and modest, understated, fond of a proverb, unfussed by small things")
        default: return ""
        }
        return " The voice speaking your reply has a \(accent) accent."
            + " Adopt a \(persona) persona: \(desc)."
    }
}
```

Note the `always` branch also emits the "Treat the 🎙 as invisible" sentence — harmless when no marker exists, and it keeps the core a single string. The test's only always-mode negative assertion is on the *condition* ("begins with"), which this satisfies.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhispererKit/MCPInstructions.swift app/Tests/OpenWhispererKitTests/MCPInstructionsChecks.swift app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(tts): add MCPInstructions standing-instruction builder"
```

---

### Task 3: `MCPServer` — `guidance` parameter → `instructions` + speak description

**Files:**
- Modify: `app/Sources/OpenWhispererKit/MCPServer.swift:23` (signature), `:38-46` (initialize), `:51-74` (tools/list)
- Test: `app/Tests/OpenWhispererKitTests/MCPServerChecks.swift` (append new checks inside `mcpServerFailures()`)

**Interfaces:**
- Consumes: nothing new (the guidance string is opaque to the server).
- Produces: `MCPServer.handle(_ body: Data, isVoiceCached: (String) -> Bool = { _ in false }, guidance: String? = nil) -> MCPOutcome`. The default `nil` keeps every existing call site and test source-compatible. Task 4 passes a real guidance string.

- [ ] **Step 1: Write the failing test**

In `app/Tests/OpenWhispererKitTests/MCPServerChecks.swift`, add inside `mcpServerFailures()` before the final `return failures` (reusing the file's existing `decode` helper and `server` instance):

```swift
    // initialize with guidance → instructions field present; without → absent.
    let initReq = #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Claude Desktop","version":"1"}}}"#
    if case let .json(data) = server.handle(Data(initReq.utf8), guidance: "SPEAK-FIRST GUIDANCE"),
       let r = decode(data) {
        let result = r["result"] as? [String: Any]
        if (result?["instructions"] as? String) != "SPEAK-FIRST GUIDANCE" {
            failures.append("initialize: guidance not surfaced as instructions")
        }
    } else {
        failures.append("initialize+guidance: expected .json outcome")
    }
    if case let .json(data) = server.handle(Data(initReq.utf8)), let r = decode(data) {
        if (r["result"] as? [String: Any])?["instructions"] != nil {
            failures.append("initialize: instructions present without guidance")
        }
    }

    // tools/list with guidance → speak description carries it; list_voices does not.
    let listReq = #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#
    if case let .json(data) = server.handle(Data(listReq.utf8), guidance: "SPEAK-FIRST GUIDANCE"),
       let r = decode(data),
       let tools = (r["result"] as? [String: Any])?["tools"] as? [[String: Any]] {
        let speak = tools.first { ($0["name"] as? String) == "speak" }
        let voices = tools.first { ($0["name"] as? String) == "list_voices" }
        if ((speak?["description"] as? String)?.contains("SPEAK-FIRST GUIDANCE")) != true {
            failures.append("tools/list: speak description missing guidance")
        }
        if ((voices?["description"] as? String)?.contains("SPEAK-FIRST GUIDANCE")) == true {
            failures.append("tools/list: guidance leaked into list_voices description")
        }
    } else {
        failures.append("tools/list+guidance: expected .json outcome with tools")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run OpenWhispererKitTests`
Expected: build FAILS with "extra argument 'guidance' in call".

- [ ] **Step 3: Write minimal implementation**

In `app/Sources/OpenWhispererKit/MCPServer.swift`:

Change the `handle` signature (line 23):

```swift
    public func handle(_ body: Data, isVoiceCached: (String) -> Bool = { _ in false }, guidance: String? = nil) -> MCPOutcome {
```

In the `initialize` case, build the result mutably and attach `instructions` (replacing lines 38–46):

```swift
        case "initialize":
            // Echo the client's requested protocol version when it sends one, so we interop with
            // whatever Claude Code release connects; fall back to ours otherwise.
            let version = (params["protocolVersion"] as? String) ?? Self.protocolVersion
            var result: [String: Any] = [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "OpenWhisperer", "version": "1.0"],
            ]
            // The standing voice instruction (MCP tier): marker-gated, so it is inert for
            // clients whose prompts never carry the marker (hook platforms).
            if let guidance { result["instructions"] = guidance }
            return .json(Self.resultResponse(id: requestID, result: result))
```

In the `tools/list` case, make the speak description a `var` seeded with the existing literal, and append the guidance before building the dictionary. Replace the `let speak: [String: Any] = [` block's `"description":` value construction with:

```swift
        case "tools/list":
            var speakDescription = "Synthesize and play the given text aloud through OpenWhisperer's "
                + "local voice (text-to-speech). Fire-and-forget: returns immediately while audio plays; subsequent requests are automatically queued by the engine to play sequentially and gaplessly. To orchestrate a multi-actor conversation or dialogue, do NOT write scripts or add delays/sleeps; instead, call this tool sequentially multiple times with different voice IDs (discovered using the list_voices tool)."
            if let guidance { speakDescription += "\n\n" + guidance }
            let speak: [String: Any] = [
                "name": "speak",
                "description": speakDescription,
```

(the rest of the `speak` dictionary — `inputSchema` etc. — and the `list_voices` definition stay exactly as they are).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhispererKit/MCPServer.swift app/Tests/OpenWhispererKitTests/MCPServerChecks.swift
git commit -m "feat(tts): surface standing guidance via MCP initialize + speak tool"
```

---

### Task 4: App wiring — regenerate guidance from prefs on every `/mcp` request

**Files:**
- Modify: `app/Sources/OpenWhisperer/TTSHTTPServer.swift:151` (the `MCPServer().handle` call) and the private helpers block at `:171-183`

**Interfaces:**
- Consumes: `MCPInstructions.mode(from:)`, `MCPInstructions.standing(mode:style:voice:)` (Task 2); `Paths.ttsResponseMode`, `Paths.ttsStyle`, `Paths.ttsVoice` (existing); existing `userVoice()` helper (`TTSHTTPServer.swift:173-178`).
- Produces: every `POST /mcp` response reflects the *current* pref files — this is the "regenerated fresh on every request" property the spec asks for (stronger than per-`tools/list`).

The app target has no unit tests by convention (all logic worth testing was pushed into Kit in Tasks 1–3); this task is verified by build + a live curl probe.

- [ ] **Step 1: Add the guidance helper**

In `app/Sources/OpenWhisperer/TTSHTTPServer.swift`, add below `userSpeed()` (after line 183):

```swift
    /// The MCP tier's standing voice instruction, rebuilt from prefs on every request so
    /// settings changes (mode, style, voice/persona) apply without a client reconnect.
    private static func speakGuidance() -> String {
        let mode = MCPInstructions.mode(
            from: try? String(contentsOf: Paths.ttsResponseMode, encoding: .utf8))
        let style = try? String(contentsOf: Paths.ttsStyle, encoding: .utf8)
        return MCPInstructions.standing(mode: mode, style: style, voice: userVoice())
    }
```

- [ ] **Step 2: Inject it at the dispatch site**

Change line 151 from:

```swift
                switch MCPServer().handle(req.body, isVoiceCached: isVoiceCached) {
```

to:

```swift
                switch MCPServer().handle(req.body, isVoiceCached: isVoiceCached, guidance: Self.speakGuidance()) {
```

- [ ] **Step 3: Build and probe live**

Run (from `app/`): `swift build`
Expected: succeeds.

Then start the headless server and probe (the GUI app must not be running, or use `TTS_PORT=8099` on both sides):

```bash
swift run OpenWhisperer --serve-tts &
sleep 20   # first run may load models; the HTTP server is up before synthesis is needed
curl -s -X POST http://localhost:8000/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' | python3 -m json.tool
curl -s -X POST http://localhost:8000/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | python3 -m json.tool
kill %1
```

Expected: the initialize result contains an `"instructions"` string with the 🎙 condition, and the speak tool description ends with the same standing instruction. If `tts_response_mode` is `always` on this machine, the "every user turn" variant appears instead — both are correct.

- [ ] **Step 4: Run the full suites**

Run: `swift run OpenWhispererKitTests && swift run HookTests`
Expected: both pass (hooks untouched; this catches accidental drift).

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/TTSHTTPServer.swift
git commit -m "feat(tts): rebuild speak guidance from prefs per /mcp request"
```

---

### Task 5: `MCPBridge` (Kit) — transport-failure shaping for the stdio bridge

**Files:**
- Create: `app/Sources/OpenWhispererKit/MCPBridge.swift`
- Test: `app/Tests/OpenWhispererKitTests/MCPBridgeChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (runner list)

**Interfaces:**
- Consumes: nothing.
- Produces: `MCPBridge.transportFailureResponse(for request: Data) -> Data?` — a JSON-RPC internal-error response echoing the request's `id`, or `nil` when the frame is a notification (no `id`) or unparseable, in which case the bridge must write nothing. Task 6 calls this when `POST /mcp` is unreachable.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/OpenWhispererKitTests/MCPBridgeChecks.swift`:

```swift
import Foundation
import OpenWhispererKit

/// Checks for `MCPBridge` — pure shaping for the --mcp-stdio bridge's failure path.
func mcpBridgeFailures() -> [String] {
    var failures: [String] = []

    func decode(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // A request (has id) gets a JSON-RPC error echoing the id.
    let request = Data(#"{"jsonrpc":"2.0","id":42,"method":"tools/list"}"#.utf8)
    if let r = decode(MCPBridge.transportFailureResponse(for: request)) {
        if (r["jsonrpc"] as? String) != "2.0" { failures.append("transportFailure: jsonrpc != 2.0") }
        if (r["id"] as? Int) != 42 { failures.append("transportFailure: id not echoed") }
        let error = r["error"] as? [String: Any]
        if (error?["code"] as? Int) != -32603 { failures.append("transportFailure: expected code -32603") }
        if ((error?["message"] as? String)?.contains("not running")) != true {
            failures.append("transportFailure: message should say the app is not running")
        }
    } else {
        failures.append("transportFailure: expected a response for a request with id")
    }

    // A string id is echoed as a string.
    let stringID = Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)
    if (decode(MCPBridge.transportFailureResponse(for: stringID))?["id"] as? String) != "abc" {
        failures.append("transportFailure: string id not echoed")
    }

    // Notifications (no id) and garbage produce nothing — the bridge stays silent.
    let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
    if MCPBridge.transportFailureResponse(for: notification) != nil {
        failures.append("transportFailure: notification must yield nil")
    }
    if MCPBridge.transportFailureResponse(for: Data("not json".utf8)) != nil {
        failures.append("transportFailure: garbage must yield nil")
    }

    return failures
}
```

Register in the runner: add `failures += mcpBridgeFailures()` after `mcpInstructionsFailures()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run OpenWhispererKitTests`
Expected: build FAILS with "cannot find 'MCPBridge' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/OpenWhispererKit/MCPBridge.swift`:

```swift
import Foundation

/// Pure shaping for the `--mcp-stdio` bridge (stdio⇄HTTP proxy for MCP clients that only
/// launch stdio servers, e.g. Claude Desktop). The bridge itself lives in the app target;
/// the one decision worth testing — what to write when the menubar app's HTTP server is
/// unreachable — lives here.
public enum MCPBridge {
    /// A JSON-RPC internal error echoing the request's `id`, for when `POST /mcp` cannot be
    /// reached. Returns nil for notifications (no `id`) or unparseable frames: per JSON-RPC,
    /// nothing may be written in reply to those.
    public static func transportFailureResponse(for request: Data) -> Data? {
        guard let msg = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any],
              let id = msg["id"], !(id is NSNull) else { return nil }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32603,
                "message": "OpenWhisperer is not running — start the menubar app and retry",
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhispererKit/MCPBridge.swift app/Tests/OpenWhispererKitTests/MCPBridgeChecks.swift app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(tts): add MCPBridge failure shaping for stdio bridge"
```

---

### Task 6: `--mcp-stdio` mode — the stdio⇄HTTP bridge

**Files:**
- Create: `app/Sources/OpenWhisperer/MCPStdioMode.swift`
- Modify: `app/Sources/OpenWhisperer/OpenWhispererApp.swift:9` (add the branch after `--serve-tts`)

**Interfaces:**
- Consumes: `MCPBridge.transportFailureResponse(for:)` (Task 5); the running app's `POST /mcp` endpoint (Tasks 3–4).
- Produces: `MCPStdioMode.run()` — a process mode Claude Desktop launches via `claude_desktop_config.json` (Task 8 writes that entry: `command` = the bundled binary, `args` = `["--mcp-stdio"]`).

Design notes for the implementer: MCP stdio transport frames are newline-delimited JSON-RPC. The bridge must NOT run its own `MCPServer` — playback has to happen in the running menubar app (which owns the TTS engine), so every frame is proxied to `POST /mcp`. The HTTP layer answers `202` with an empty body for notifications (`MCPOutcome.accepted`); the bridge writes nothing in that case. Synchronous per-frame handling is correct here — MCP clients await responses, and playback itself is fire-and-forget inside the app.

- [ ] **Step 1: Write the bridge**

Create `app/Sources/OpenWhisperer/MCPStdioMode.swift`:

```swift
import Foundation
import OpenWhispererKit

/// `--mcp-stdio`: a thin stdio⇄HTTP bridge for MCP clients that can only launch stdio
/// servers (Claude Desktop). Each newline-delimited JSON-RPC frame from stdin is forwarded
/// to the running menubar app's `POST /mcp`, so synthesis and playback happen there; the
/// response body is written back to stdout. If the app isn't running, requests get a
/// JSON-RPC error (MCPBridge) and notifications are dropped, per JSON-RPC.
enum MCPStdioMode {
    static func run() {
        let port = ProcessInfo.processInfo.environment["TTS_PORT"].flatMap { UInt16($0) } ?? 8000
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let out = FileHandle.standardOutput

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let body = Data(line.utf8)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 120  // speak synthesis on a cold model can be slow

            let done = DispatchSemaphore(value: 0)
            var reply: Data?
            URLSession.shared.dataTask(with: request) { data, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data, !data.isEmpty {
                    reply = data
                }
                // 202 (notification ack) and errors both leave reply nil.
                done.signal()
            }.resume()
            done.wait()

            if let frame = reply ?? MCPBridge.transportFailureResponse(for: body) {
                out.write(frame)
                out.write(Data("\n".utf8))
            }
        }
    }
}
```

- [ ] **Step 2: Add the entry-point branch**

In `app/Sources/OpenWhisperer/OpenWhispererApp.swift`, after the `--serve-tts` branch (line 9), insert:

```swift
        } else if CommandLine.arguments.contains("--mcp-stdio") {
            MCPStdioMode.run()
```

(the existing `else if let flagIndex = … "--diag-parakeet"` and final `else` stay as they are).

- [ ] **Step 3: Build and verify both bridge paths live**

Run: `swift build`
Expected: succeeds.

App-not-running path (nothing on :8099):

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n' | TTS_PORT=8099 swift run OpenWhisperer --mcp-stdio
```

Expected: one line — a JSON-RPC error with `"code":-32603` and `"id":1`, then clean exit on EOF.

Proxy path:

```bash
swift run OpenWhisperer --serve-tts &
sleep 20
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n' | swift run OpenWhisperer --mcp-stdio
kill %1
```

Expected: exactly two output lines — the initialize result (with `instructions`) and the tools list (speak description carrying the standing instruction); the notification produces no line.

- [ ] **Step 4: Run the full suites**

Run: `swift run OpenWhispererKitTests && swift run HookTests`
Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/MCPStdioMode.swift app/Sources/OpenWhisperer/OpenWhispererApp.swift
git commit -m "feat(tts): add --mcp-stdio bridge for stdio-only MCP clients"
```

---

### Task 7: `DesktopConfigMerge` (Kit) — claude_desktop_config.json shaping

**Files:**
- Create: `app/Sources/OpenWhispererKit/DesktopConfigMerge.swift`
- Test: `app/Tests/OpenWhispererKitTests/DesktopConfigMergeChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (runner list)

**Interfaces:**
- Consumes: nothing.
- Produces: `DesktopConfigMerge.merged(existingJSON: Data?, executablePath: String) -> Data?` and `DesktopConfigMerge.isConfigured(configJSON: Data?) -> Bool`. Task 8 uses both from `ConfigManager`.

Claude Desktop's config on this machine already holds unrelated top-level keys (`coworkUserFilesPath`, `preferences`) and **no** `mcpServers` key — the merge must preserve everything foreign and add/replace only `mcpServers.OpenWhisperer`.

- [ ] **Step 1: Write the failing test**

Create `app/Tests/OpenWhispererKitTests/DesktopConfigMergeChecks.swift`:

```swift
import Foundation
import OpenWhispererKit

/// Checks for `DesktopConfigMerge` — read-modify-write shaping for claude_desktop_config.json.
func desktopConfigMergeFailures() -> [String] {
    var failures: [String] = []

    func decode(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func entry(_ root: [String: Any]?) -> [String: Any]? {
        ((root?["mcpServers"] as? [String: Any])?["OpenWhisperer"]) as? [String: Any]
    }

    // No existing file → a fresh config with just our entry.
    let fresh = decode(DesktopConfigMerge.merged(existingJSON: nil, executablePath: "/Applications/OpenWhisperer.app/Contents/MacOS/OpenWhisperer"))
    if (entry(fresh)?["command"] as? String) != "/Applications/OpenWhisperer.app/Contents/MacOS/OpenWhisperer" {
        failures.append("merged(nil): command wrong or missing")
    }
    if (entry(fresh)?["args"] as? [String]) != ["--mcp-stdio"] {
        failures.append("merged(nil): args wrong or missing")
    }

    // Foreign top-level keys and sibling servers survive; a stale entry is replaced.
    let existing = Data(#"""
    {"coworkUserFilesPath":"/Users/x/Claude",
     "preferences":{"sidebarMode":"chat"},
     "mcpServers":{"other":{"command":"/bin/other"},
                   "OpenWhisperer":{"command":"/old/path","args":["--old-flag"]}}}
    """#.utf8)
    let merged = decode(DesktopConfigMerge.merged(existingJSON: existing, executablePath: "/new/path"))
    if (merged?["coworkUserFilesPath"] as? String) != "/Users/x/Claude" {
        failures.append("merged: foreign top-level key dropped")
    }
    if ((merged?["preferences"] as? [String: Any])?["sidebarMode"] as? String) != "chat" {
        failures.append("merged: preferences dropped")
    }
    if (((merged?["mcpServers"] as? [String: Any])?["other"] as? [String: Any])?["command"] as? String) != "/bin/other" {
        failures.append("merged: sibling server dropped")
    }
    if (entry(merged)?["command"] as? String) != "/new/path" || (entry(merged)?["args"] as? [String]) != ["--mcp-stdio"] {
        failures.append("merged: stale OpenWhisperer entry not replaced")
    }

    // Unparseable existing content is treated as absent (don't crash, don't propagate garbage).
    if decode(DesktopConfigMerge.merged(existingJSON: Data("nonsense".utf8), executablePath: "/p")) == nil {
        failures.append("merged(garbage): should still produce a valid config")
    }

    // isConfigured: true only for an entry with --mcp-stdio in args.
    if !DesktopConfigMerge.isConfigured(configJSON: DesktopConfigMerge.merged(existingJSON: nil, executablePath: "/p")) {
        failures.append("isConfigured: freshly merged config not recognized")
    }
    if DesktopConfigMerge.isConfigured(configJSON: nil) {
        failures.append("isConfigured(nil): must be false")
    }
    if DesktopConfigMerge.isConfigured(configJSON: existing) {
        failures.append("isConfigured: stale entry without --mcp-stdio must be false")
    }

    return failures
}
```

Register in the runner: add `failures += desktopConfigMergeFailures()` after `mcpBridgeFailures()`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift run OpenWhispererKitTests`
Expected: build FAILS with "cannot find 'DesktopConfigMerge' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `app/Sources/OpenWhispererKit/DesktopConfigMerge.swift`:

```swift
import Foundation

/// Shapes Claude Desktop's `claude_desktop_config.json`: merge in (or verify) the
/// OpenWhisperer stdio MCP entry while preserving every foreign key. Claude Desktop only
/// launches stdio servers from this file, hence `--mcp-stdio` rather than an HTTP URL.
/// Pure so it's testable in Kit; ConfigManager does the file I/O.
public enum DesktopConfigMerge {
    /// The merged config document, or nil only if serialization itself fails.
    /// Unparseable existing content is treated as an empty config.
    public static func merged(existingJSON: Data?, executablePath: String) -> Data? {
        var root: [String: Any] = [:]
        if let existingJSON,
           let json = (try? JSONSerialization.jsonObject(with: existingJSON)) as? [String: Any] {
            root = json
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["OpenWhisperer"] = ["command": executablePath, "args": ["--mcp-stdio"]]
        root["mcpServers"] = servers
        return try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether the config already carries a current OpenWhisperer stdio entry.
    public static func isConfigured(configJSON: Data?) -> Bool {
        guard let configJSON,
              let json = (try? JSONSerialization.jsonObject(with: configJSON)) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let entry = servers["OpenWhisperer"] as? [String: Any],
              let args = entry["args"] as? [String] else { return false }
        return args.contains("--mcp-stdio")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhispererKit/DesktopConfigMerge.swift app/Tests/OpenWhispererKitTests/DesktopConfigMergeChecks.swift app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(settings): add DesktopConfigMerge for Claude Desktop config"
```

---

### Task 8: Claude Desktop platform — `Platform` case, `ConfigManager`, Settings UI

**Files:**
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift:7-32` (Platform enum), `:370-395` (dispatch switches), plus a new `applyToClaudeDesktop()` near `applyToPi()` (line 248)
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (new external-config constant, alongside `claudeJSON`)
- Modify: `app/Sources/OpenWhisperer/Settings/AgentsTab.swift:60-71` (footerText) and the `HowItWorksSheet` switch (lines 79–223)

**Interfaces:**
- Consumes: `DesktopConfigMerge.merged/isConfigured` (Task 7); `Bundle.main.executablePath` (resolves to `…/OpenWhisperer.app/Contents/MacOS/OpenWhisperer` in the bundled app, or the debug binary under `swift run` — both valid `command` values).
- Produces: `Platform.claudeDesktop` (raw value `"claudeDesktop"`, label `"Claude Desktop"`), `ConfigManager.applyToClaudeDesktop() -> (success: Bool, message: String)`, `Paths.claudeDesktopConfig: URL`.

`Platform` is a non-`@unknown` exhaustively-switched enum: after adding the case, **the compiler lists every switch that needs a new arm** (`applyHook`, `checkHookConfigured`, `showHookInstructions`, `Platform.label`, `AgentsTab.footerText`, `HowItWorksSheet`). Use the build errors as the checklist; the required copy for each is below.

- [ ] **Step 1: Add the Paths constant**

In `app/Sources/OpenWhisperer/Paths.swift`, alongside the other external-config URLs (near `claudeJSON`, lines 108–150), following the file's `homeDirectoryForCurrentUser` closure idiom:

```swift
    /// Claude Desktop's MCP config (stdio servers only — hence the --mcp-stdio bridge).
    static let claudeDesktopConfig = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }()
```

- [ ] **Step 2: Add the Platform case and apply method**

In `app/Sources/OpenWhisperer/ConfigManager.swift`:

Add to the `Platform` enum (after `case antigravity`):

```swift
    case claudeDesktop = "claudeDesktop"
```

and to its `label` switch:

```swift
        case .claudeDesktop: return "Claude Desktop"
```

Add near `applyToPi()` (line 248):

```swift
    /// Claude Desktop has no hook system; the whole integration is the MCP entry. The
    /// standing instruction + 🎙 marker replace the UserPromptSubmit handshake (see
    /// docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md).
    static func applyToClaudeDesktop() -> (success: Bool, message: String) {
        guard let exe = Bundle.main.executablePath else {
            return (false, "Cannot resolve the app binary path")
        }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: Paths.claudeDesktopConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let existing = try? Data(contentsOf: Paths.claudeDesktopConfig)
        guard let out = DesktopConfigMerge.merged(existingJSON: existing, executablePath: exe) else {
            return (false, "Failed to serialize claude_desktop_config.json")
        }
        do {
            try out.write(to: Paths.claudeDesktopConfig)
            return (true, "speak tool registered — restart Claude Desktop to load it")
        } catch {
            return (false, "Write failed: \(error.localizedDescription)")
        }
    }
```

Extend the dispatch switches (lines 370–395):

```swift
        // in applyHook(for:)
        case .claudeDesktop: return applyToClaudeDesktop()

        // in checkHookConfigured(for:)
        case .claudeDesktop:
            return DesktopConfigMerge.isConfigured(
                configJSON: try? Data(contentsOf: Paths.claudeDesktopConfig))
```

For `showHookInstructions(for:)`, follow the existing per-platform `InstructionWindow` pattern with this copy (title `"Claude Desktop Setup"`):

```
OpenWhisperer adds its speak tool to Claude Desktop via MCP — no hooks needed.

1. Click Auto-Apply (writes the entry into claude_desktop_config.json).
2. Quit and reopen Claude Desktop so it launches the server.
3. Dictate into Claude Desktop: the transcript gets a leading 🎙 that cues the
   spoken reply. Delete the 🎙 before sending to keep a turn silent; type 🎙
   yourself to force one.

Keep the OpenWhisperer menubar app running — it does the actual speaking.
```

- [ ] **Step 3: Update AgentsTab copy**

In `app/Sources/OpenWhisperer/Settings/AgentsTab.swift`, the compiler will demand new arms in `footerText` (lines 60–71) and `HowItWorksSheet` (lines 79–223). Use:

footerText:

```swift
        case .claudeDesktop:
            return "Registers the speak tool in claude_desktop_config.json. Restart Claude Desktop after applying; dictated prompts get a leading 🎙 that cues spoken replies."
```

HowItWorksSheet — match the structure of the existing per-platform sections with these points: dictation types a leading 🎙 into Claude Desktop; the MCP server's standing instruction tells the model to call `speak` first on 🎙 turns (every turn in `always` mode); playback runs in the menubar app; there is no hook and nothing to trust; removing the 🎙 before sending keeps that turn silent.

- [ ] **Step 4: Build, run suites, and verify the config write**

Run: `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: all pass (compile errors from unhandled `Platform` switches mean a missed arm — fix until clean).

Verify the write against the real file (safe: read-modify-write preserves it; back it up first regardless):

```bash
cp "$HOME/Library/Application Support/Claude/claude_desktop_config.json" /tmp/cdc-backup.json
cd app && swift run OpenWhisperer --serve-tts &
sleep 5; kill %1   # any run works; simplest is invoking the apply from a scratch swift file — or defer to Task 11's GUI pass
```

The GUI-driven verification happens in Task 11; at this stage a code-review read of `applyToClaudeDesktop` against `DesktopConfigMergeChecks` expectations suffices. Restore the backup if anything wrote unexpectedly: `cp /tmp/cdc-backup.json "$HOME/Library/Application Support/Claude/claude_desktop_config.json"`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/ConfigManager.swift app/Sources/OpenWhisperer/Paths.swift app/Sources/OpenWhisperer/Settings/AgentsTab.swift
git commit -m "feat(settings): add Claude Desktop platform (MCP, no hooks)"
```

---

### Task 9: Marker injection — bundle capture + apply in DictationManager

**Files:**
- Modify: `app/Sources/OpenWhisperer/DictationManager.swift` — fields near line 66, `captureTargetApp()` (lines 270–286), the `didActivateApplicationNotification` observer (lines 138–152), `finishAndTranscribe()` (lines 600–651), `handsFreeFlushAndTranscribe()` (lines 439–487), `handlePushToTalkResult` (lines 657–680), `handleHandsFreeResult` (lines 492–524)

**Interfaces:**
- Consumes: `VoiceMarker.apply(_:bundleID:)` (Task 1).
- Produces: dictations into Claude Desktop are typed as `🎙 <transcript>`; everything else is byte-identical to today. `voice_turn` keeps being written for every dictation (`insertText` is untouched) — harmless, since no hook fires for Desktop.

The bundle ID must be captured at hotkey time alongside `targetPID` (a PID could in principle be reused by typing time; `NSRunningApplication` lookup at result time is the fallback pattern, not the primary). The marker is applied in the result handlers — after `SubmitTrigger` cleanup, immediately before `insertText` — so the hash in `voice_turn` covers the marked text exactly as typed.

- [ ] **Step 1: Carry the bundle ID next to the PID**

In `app/Sources/OpenWhisperer/DictationManager.swift`:

Add fields next to `targetPID` (line 66) and `lastRegularAppPID` (line 71):

```swift
    private var targetBundleID: String?
    private var lastRegularAppBundleID: String?
```

In `captureTargetApp()` (lines 270–286), set them in both branches:

```swift
        if let front = NSWorkspace.shared.frontmostApplication,
           front.activationPolicy == .regular,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetPID = front.processIdentifier
            targetBundleID = front.bundleIdentifier
            lastRegularAppPID = targetPID
            lastRegularAppBundleID = targetBundleID
            os_log(.default, log: dictLog, "Captured target PID %d (%{public}@)", targetPID, front.localizedName ?? "?")
        } else if lastRegularAppPID != 0 {
            targetPID = lastRegularAppPID
            targetBundleID = lastRegularAppBundleID
            os_log(.default, log: dictLog, "Frontmost not a regular app; using last regular PID %d", targetPID)
        }
```

In the `didActivateApplicationNotification` observer (lines 138–152), where `lastRegularAppPID` is seeded from `app`, also seed `lastRegularAppBundleID = app.bundleIdentifier`.

- [ ] **Step 2: Thread it through the transcribe tasks into the handlers**

In `finishAndTranscribe()` (lines 600–651) and `handsFreeFlushAndTranscribe()` (lines 439–487), next to the existing `let pid = targetPID` capture add:

```swift
        let bundleID = targetBundleID
```

and extend the completion calls and handler signatures:

```swift
    private func handlePushToTalkResult(_ result: Result<String, Error>, pid: pid_t, bundleID: String?)
    private func handleHandsFreeResult(_ result: Result<String, Error>, pid: pid_t, bundleID: String?)
```

(update the two `self?.handle…Result(result, pid: pid)` call sites to pass `bundleID: bundleID`).

- [ ] **Step 3: Apply the marker at the seam**

In `handlePushToTalkResult`, change the success arm (currently lines 664–671) to:

```swift
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let autoSubmit = FileManager.default.fileExists(atPath: Paths.autoSubmitFlag.path)
            let cleaned = autoSubmit ? SubmitTrigger.process(trimmed).cleaned : trimmed
            let finalText = VoiceMarker.apply(cleaned, bundleID: bundleID)
            os_log(.default, log: dictLog, "Transcribed: %{public}@, inserting into PID %d", finalText, pid)
```

(the rest of the arm — `lastTranscription`, `insertText` — unchanged, now receiving the marked text). Make the mirror-image change in `handleHandsFreeResult` where `SubmitTrigger.process(...)` runs (line ~500).

- [ ] **Step 4: Build and run suites**

Run: `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: all pass. (The marker decision itself is covered by Task 1's Kit checks; the app target has no unit tests by convention — live dictation is verified in Task 11.)

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/DictationManager.swift
git commit -m "feat(voice): type leading marker for MCP-tier dictation targets"
```

---

### Task 10: Docs — AGENTS.md, spec addendum

**Files:**
- Modify: `AGENTS.md` (Commands section; the "Voice-turn handshake" section; the "Native-tongue flavor" paragraph; the platform list in Conventions)
- Modify: `docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md` (addendum)

- [ ] **Step 1: Update AGENTS.md**

Make these targeted edits (keep the existing voice — dense, parenthetical, past-decision-aware):

1. **Commands block:** after the `--serve-tts` line add:
   ```
   swift run OpenWhisperer --mcp-stdio   # stdio⇄HTTP MCP bridge (Claude Desktop); proxies to :8000/mcp
   ```
2. **Voice-turn handshake section:** add a paragraph headed **"MCP-only tier (Claude Desktop, 2026-07-17)"** stating: Claude Desktop has no hooks; dictations targeting it get a leading `🎙` (U+1F399 bare, `VoiceMarker` in Kit, applied only for allowlisted bundle IDs — `com.anthropic.claudefordesktop`); the MCP server ships a standing instruction (`MCPInstructions` in Kit) via `initialize.instructions` + the speak tool description, regenerated from prefs on every request; deleting the 🎙 silences a turn, typing one force-speaks; the instruction is marker-gated and therefore inert on hook platforms (no clientInfo scoping — the transport is stateless); Claude Desktop launches the `--mcp-stdio` bridge from `claude_desktop_config.json`, which proxies to the running app's `:8000/mcp`; hooks remain the gold path on Claude Code/Codex/agy pending the compliance data in the spec; the marker deliberately does NOT extend to terminal-hosted CLIs (frontmost app ≠ agent focus).
3. **Native-tongue flavor paragraph:** amend "The map + personas live **only** in the hook — no Swift parity pair" to note the 2026-07-17 exception: `MCPInstructions.flavor` in Kit now carries a copy for the MCP tier; `HookTests` guards the bash side, `MCPInstructionsChecks` the Swift side; tune both together.
4. **Conventions platform bullet:** extend the platform list with: Claude Desktop → MCP entry in `~/Library/Application Support/Claude/claude_desktop_config.json` (stdio bridge, no hook, no trust step).

- [ ] **Step 2: Add the spec addendum**

Append to `docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md`:

```markdown
## Addendum (implementation, 2026-07-17)

- **`clientInfo` scoping dropped.** The MCP transport is stateless (no session
  header; a fresh `MCPServer` per request), so correlating `initialize` with
  later `tools/list` calls would need new session plumbing. Unnecessary: the
  standing instruction is marker-gated, and markers are only ever typed into
  allowlisted apps, so identical instructions are inert on hook platforms. In
  `always` mode the instruction and the hook nudge agree rather than conflict.
  Side effect kept: any MCP-connected platform gains type-🎙-to-force-speak.
- **Regeneration is per-request, not per-`tools/list`** — strictly fresher
  than specced; settings changes apply without reconnect wherever the client
  re-reads tool schemas.
- **Connectivity spike resolved by inspection:** `claude_desktop_config.json`
  is stdio-only (`command`/`args`), so the `--mcp-stdio` bridge is the route;
  the HTTP-connector question is moot for v1. Bundle ID confirmed:
  `com.anthropic.claudefordesktop`.
```

- [ ] **Step 3: Verify docs accuracy by readback**

Re-read both edited files end-to-end; every claim must match the shipped code (file names, symbol names, flag names, bundle ID).

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md docs/superpowers/specs/2026-07-17-mcp-only-voice-design.md
git commit -m "docs: document MCP-only voice tier and spec addendum"
```

---

### Task 11: Live verification + compliance measurement (human-in-the-loop)

**Files:** none (verification only; findings recorded as a further spec addendum if they force changes).

This is the spec's rendering + compliance spike, run against the finished build. It needs Hakan at the microphone.

- [ ] **Step 1: Build and install the signed bundle**

```bash
cd app && OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh
killall OpenWhisperer || true
rm -rf /Applications/OpenWhisperer.app
cp -R app/.build/OpenWhisperer.app /Applications/
open /Applications/OpenWhisperer.app   # rerun with sandbox disabled if error -600
```

(Stable cert = TCC grants persist; re-grant only if prompted.)

- [ ] **Step 2: Apply the platform and restart Claude Desktop**

Settings → Agents → Platform: Claude Desktop → Auto-Apply. Confirm `claude_desktop_config.json` now has the `mcpServers.OpenWhisperer` entry with the `/Applications/...` command path and that `coworkUserFilesPath`/`preferences` survived. Quit and reopen Claude Desktop; confirm the OpenWhisperer server and its `speak`/`list_voices` tools appear in Desktop's tools UI.

- [ ] **Step 3: Rendering check (spec spike #2)**

Dictate once into Claude Desktop. Inspect the composer and the sent message: the transcript must begin with the mic glyph. Judge bare U+1F399's rendering; if it renders as an ugly placeholder/tofu, flip `VoiceMarker.glyph` to `"\u{1F399}\u{FE0F}"`, update the Task 1 scalar-count check to expect 2, rebuild, reinstall.

- [ ] **Step 4: Compliance batch (spec spike #3 — the promotion-gate data)**

With `tts_response_mode` = `voice` (default):
- 10 dictated turns (mix short questions and longer prompts): count how many produce a spoken reply that starts before/near the start of the written one, and note any turn where the model mentions the 🎙 or the tool.
- 5 typed turns (no marker): count false positives (any spoken reply).
- 2 control turns: delete the 🎙 before sending (expect silence); type a 🎙 manually (expect speech).

Record the counts in the spec addendum. Baseline to beat/meet: hooks went 13/13 (Claude) and 5/5 (Codex). If compliance is materially worse, stop and reassess wording of `MCPInstructions.standing` before any thought of promotion.

- [ ] **Step 5: Regression sweep on a hook platform**

In this repo (Claude Code + hook active): one dictated turn (expect: spoken exactly once, no double-speak, no 🎙 typed into the terminal), one typed turn (expect: silent, no stray speak call). This validates the self-scoping claim.

- [ ] **Step 6: Record results and close out**

Append the measured counts to the spec addendum (commit as `docs: record MCP tier compliance results`). Then follow the AGENTS.md PR path: rebase onto `origin/main` if it moved, push the branch, `gh pr create`.

---

## Self-Review Notes

- **Spec coverage:** marker + placement (Task 1, 9), standing instruction both channels + persona/style/mode (Tasks 2–4), per-request regeneration (Task 4), stdio bridge (Tasks 5–6), platform setup (Tasks 7–8), guard against non-target apps (Tasks 1, 9), hooks untouched (global constraint; regression-swept in Task 11), spike items (connectivity resolved by inspection — Task 10 addendum; rendering — Task 11 §3; compliance — Task 11 §4). `tools/list_changed` explicitly deferred (spec v2) — not planned.
- **Spec deviation** (clientInfo scoping → self-scoping instructions) is declared in the header and recorded in the spec by Task 10.
- **Type consistency:** `VoiceMarker.apply(_:bundleID:)`, `MCPInstructions.standing(mode:style:voice:)`, `MCPBridge.transportFailureResponse(for:)`, `DesktopConfigMerge.merged(existingJSON:executablePath:)` are used with identical spellings across Tasks 1–9.
