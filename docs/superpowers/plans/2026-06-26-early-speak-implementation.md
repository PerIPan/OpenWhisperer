# Early-Speak (`speak` MCP tool) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Claude Code Stop-hook spoken-summary with an in-app `speak` MCP tool the model calls *first*, so audio starts mid-turn instead of after the reply finishes.

**Architecture:** The pure `MCPServer` JSON-RPC dispatch (`OpenWhispererKit`) and the `POST /mcp` route in `TTSHTTPServer` already exist (built + verified in the spike, commits `2f64512`). This plan does the rest: rewrite `voice-context.sh` to nudge the model to call `speak` first (dropping the `speak_pending` marker), delete the Stop hooks, have `ConfigManager` register the MCP server + the shared nudge hook and stop registering the Stop hooks, and rewrite the docs. **No version bump** — releasing/versioning is left to the upstream maintainer. **Both Claude Code and Codex are migrated.** Codex was spiked (2026-06-26): HTTP MCP works with no flag, a `UserPromptSubmit` hook gives 5/5 speak-first, and Codex's hook stdin carries `prompt`+`session_id`, so the *same* `voice-context.sh` serves both platforms. The Claude Stop hook (`tts-hook.sh`) and the Codex `notify` hook (`codex-tts-hook.sh`) are both deleted. **Open Codex detail:** Codex silently skips *untrusted* hooks, so the setup must establish persisted hook trust (Task 4).

**Tech Stack:** Swift 5.9 (SwiftPM, CLT-only — no XCTest), bash hooks, JSON-RPC 2.0 / MCP Streamable HTTP (protocol `2025-11-25`), FluidAudio Kokoro TTS.

## Global Constraints

- **KISS variant — no fallback.** Delete both Stop hooks outright; do **not** add a `spoke_early` dedupe path. A missed `speak` call = a silent turn, accepted by decision.
- **Both platforms.** Migrate Claude Code *and* Codex to the shared `voice-context.sh` nudge + `speak` tool. Delete `tts-hook.sh` (Claude Stop) and `codex-tts-hook.sh` (Codex notify). Once both are gone, `speakable-text.sh` + `SpeakableTextChecks` are unused — delete them too (after a `grep` confirms no other consumer). **Codex hook trust** must be established or the hook is silently skipped (Task 4).
- **Hashing parity is sacred.** Do not touch `VoiceSignal.canonicalHash` or the bash `shasum` classification in `voice-context.sh`; the `IS_VOICE` block is copied verbatim. Run `HookTests` after any hook edit.
- **Pure logic lives in `OpenWhispererKit`** (CLT-testable). `ConfigManager`/`TTSHTTPServer` are AppKit/Network-linked and verified by build + manual smoke, not unit tests — matching the existing repo norm.
- **Server URL is fixed:** `http://localhost:8000/mcp`. MCP entry shape in `~/.claude.json` → `mcpServers.<name>`: `{"type":"http","url":"http://localhost:8000/mcp"}`.
- **Do not bump the version.** Leave `Info.plist` / `build-dmg.sh` at `1.5.1`; cutting the release + version is the upstream maintainer's (Perikles's) call. The launch migration strips stale hooks regardless of version, so nothing here depends on a version number.
- **Codex MCP/hook config** (`~/.codex/config.toml`): `[mcp_servers.OpenWhisperer]` with `url = "http://localhost:8000/mcp"` (no experimental flag); the nudge hook is `[[hooks.UserPromptSubmit]]` → `[[hooks.UserPromptSubmit.hooks]]` with `type="command"`, `command=<voice-context.sh path>`. Codex's hook I/O schema matches Claude Code's exactly.
- **Commands run from `app/`:** `swift run OpenWhispererKitTests`, `swift run HookTests` (both `exit(1)` on failure).
- **Branch:** `worktree-speak-mcp-spike` (already created). Commit after each task.

---

### Task 1: Rewrite `voice-context.sh` — nudge `speak`-first, drop `speak_pending`

The UserPromptSubmit hook keeps its `IS_VOICE` classification and response-mode gate, but on a "speak" decision it now emits a nudge to **call the `speak` tool first** and writes **no marker** (nothing consumes it once the Stop hook is gone).

**Files:**
- Modify: `hooks/voice-context.sh` (full rewrite of the decision/emit half; `IS_VOICE` block unchanged)
- Modify: `app/Tests/HookTests/VoiceContextChecks.swift` (rewrite assertions)

**Interfaces:**
- Consumes: `voice_turn` signal (hash+ts), `tts_response_mode`, `tts_style`/`voice_detail`, env `OW_TTS_RESPONSE`/`OW_TTS_STYLE`.
- Produces: stdout JSON `{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:<nudge>}, suppressOutput:true}` on a speak decision; empty stdout otherwise. **No `speak_pending/<id>` file.** The nudge text contains the literal substring `` `speak` tool ``.

- [ ] **Step 1: Rewrite the tests first (RED).** Replace the body of `voiceContextFailures()` in `app/Tests/HookTests/VoiceContextChecks.swift` with the version below. Key changes from the current file: a speak decision asserts a nudge containing `` `speak` tool `` and **`!markerExists`** (no marker is ever written now); the `full`-style "entire reply" case is gone; style length phrases (`one short, plain spoken sentence`, `a sentence or two`) are unchanged.

```swift
import Foundation

/// `voice-context.sh` (UserPromptSubmit): classify the turn against the `voice_turn` signal,
/// apply the response mode, and on a "speak" decision nudge the model to call the `speak` MCP
/// tool first. No `speak_pending` marker is written (the Stop hook is gone). Returns failures.
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

    // --- Response mode (tts_response_mode): voice (default) | text | always ---

    // 10) always + typed turn → speak-tool nudge, signal-free, no marker.
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

    // 12) text + typed turn → speaks.
    do {
        let s = newSandbox(); s.writeResponseMode("text")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "typed thing", session: "s-tt"), sandbox: s)
        if nudge(r.stdout)?.contains("`speak` tool") != true { fail("textTyped: missing nudge") }
    }

    // 13) text + dictated turn → silent, signal still consumed.
    do {
        let s = newSandbox(); s.writeResponseMode("text"); s.writeVoiceTurn(forPrompt: "spoke this")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "spoke this", session: "s-tv"), sandbox: s)
        if !r.stdout.isEmpty { fail("textVoice: expected silence, got \(r.stdout.debugDescription)") }
        if s.voiceTurnExists() { fail("textVoice: voice_turn should be consumed") }
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

    return failures
}
```

- [ ] **Step 2: Run the tests to verify they FAIL.** From `app/`: `swift run HookTests`. Expected: multiple `voice-context.*` failures (the current script writes a marker and a "read aloud" nudge, so `matchClaims`, the style cases, and the mode cases fail).

- [ ] **Step 3: Rewrite `hooks/voice-context.sh` (GREEN).** Replace the whole file with:

```bash
#!/bin/bash
# UserPromptSubmit hook (Claude Code) — decides whether THIS turn's reply is spoken and, if so,
# nudges the model to call the `speak` MCP tool FIRST with a standalone spoken summary.
#
# Response mode (tts_response_mode, or per-project OW_TTS_RESPONSE):
#   voice  (default) — speak only voice-dictated turns (prompt hash matches voice_turn)
#   text             — speak only typed turns (no fresh voice_turn match)
#   always           — speak every turn
# There is no Stop hook and no speak_pending marker: the model's own `speak` call is the audio.
export LANG="${LANG:-en_US.UTF-8}"

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VOICE_TURN="$APP_SUPPORT/voice_turn"
# voice_turn TTL (s) — kept uniform with codex-tts-hook.sh.
FRESHNESS=900

# Response mode. Precedence: per-project OW_TTS_RESPONSE env → global file → "voice".
MODE="$OW_TTS_RESPONSE"
[ -z "$MODE" ] && MODE=$(cat "$APP_SUPPORT/tts_response_mode" 2>/dev/null | tr -d '[:space:]')
[ -z "$MODE" ] && MODE="voice"

# Fast path: default "voice" mode with no pending dictation has nothing to do.
[ "$MODE" = "voice" ] && [ ! -f "$VOICE_TURN" ] && exit 0

# Find jq (system, then bundled next to the hooks dir).
if ! command -v jq >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else exit 0; fi
fi

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
[ -z "$PROMPT" ] && exit 0

# Determine whether THIS turn was voice-dictated: a fresh voice_turn whose hash matches the
# submitted prompt. On a match, atomically claim (consume) the signal. A stale signal is swept.
# (Hashing MUST match VoiceSignal.canonicalHash — do not change.)
IS_VOICE=0
if [ -f "$VOICE_TURN" ]; then
  STORED_HASH=$(sed -n '1p' "$VOICE_TURN" 2>/dev/null)
  STORED_TS=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
  if [ -n "$STORED_HASH" ]; then
    NOW=$(date +%s)
    if [ -n "$STORED_TS" ] && [ "$((NOW - STORED_TS))" -gt "$FRESHNESS" ]; then
      rm -f "$VOICE_TURN"
    else
      trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
      TRIMMED=$(trim "$PROMPT")
      if command -v shasum >/dev/null 2>&1; then
        PROMPT_HASH=$(printf '%s' "$TRIMMED" | shasum -a 256 | awk '{print $1}')
      else
        PROMPT_HASH=$(printf '%s' "$TRIMMED" | openssl dgst -sha256 | awk '{print $NF}')
      fi
      if [ "$PROMPT_HASH" = "$STORED_HASH" ]; then
        CLAIM="$APP_SUPPORT/.voice_turn.claimed.$$"
        if mv "$VOICE_TURN" "$CLAIM" 2>/dev/null; then rm -f "$CLAIM"; IS_VOICE=1; fi
      fi
    fi
  fi
fi

# Decide whether to speak this turn, per Response mode.
SPEAK=0
case "$MODE" in
  always) SPEAK=1 ;;
  text)   [ "$IS_VOICE" -eq 0 ] && SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;   # voice (default)
esac
[ "$SPEAK" -eq 1 ] || exit 0

# Spoken-summary length hint. Precedence: OW_TTS_STYLE env → tts_style file → legacy voice_detail.
STYLE="$OW_TTS_STYLE"
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
case "$STYLE" in
  terse)     LEN="one short, plain spoken sentence" ;;
  rich|full) LEN="a sentence or two of plain spoken summary" ;;
  *)         LEN="one plain spoken sentence" ;;
esac

if [ "$IS_VOICE" -eq 1 ]; then PREFIX="This turn was dictated by voice."; else PREFIX="This reply should be spoken aloud."; fi
NUDGE="${PREFIX} Before writing your on-screen reply, your FIRST action must be to call the \`speak\` tool exactly once, passing ${LEN} that summarizes your answer and stands alone when heard. Then write your full reply on screen as usual. Do not skip the speak call, and do not mention the tool in your written reply."

jq -n --arg ctx "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}'
exit 0
```

- [ ] **Step 4: Run the tests to verify they PASS.** From `app/`: `swift run HookTests`. Expected: `✅ HookTests: all checks passed` (the other groups — speakable-text, tts-hook gate, codex — are still present and unchanged at this point).

- [ ] **Step 5: Commit.**

```bash
git add hooks/voice-context.sh app/Tests/HookTests/VoiceContextChecks.swift
git commit -m "feat(voice): nudge speak-first via MCP tool; drop speak_pending"
```

---

### Task 2: Delete the Claude Stop hook (`tts-hook.sh`) and its registration

The Stop hook and its marker are obsolete. Remove the script, its test group, and every `ConfigManager` reference that registers or instructs it; add a launch migration that strips a stale Stop entry from existing `~/.claude/settings.json`.

**Files:**
- Delete: `hooks/tts-hook.sh`
- Delete: `app/Tests/HookTests/TTSHookGateChecks.swift`
- Modify: `app/Tests/HookTests/main.swift` (remove `ttsHookGateFailures()` call)
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift` (`applyHookToSettings`, `showClaudeSettingsInstructions`, `checkHookConfigured`, add `migrateRemoveClaudeStopHook`)
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (drop `ttsHook`; keep `speakableTextScript`)
- Modify: `app/Sources/OpenWhisperer/AppDelegate.swift` (call the migration on launch)

**Interfaces:**
- Produces: `ConfigManager.applyHookToSettings()` registers **only** `UserPromptSubmit` (→ `voice-context.sh`) and leaves no `Stop` entry of ours. `ConfigManager.migrateRemoveClaudeStopHook()` strips our `Stop` hook from `~/.claude/settings.json` idempotently.

- [ ] **Step 1: Delete the Stop hook + its test, and de-wire the runner.**

```bash
git rm hooks/tts-hook.sh app/Tests/HookTests/TTSHookGateChecks.swift
```
Then in `app/Tests/HookTests/main.swift` remove the line `failures += ttsHookGateFailures()`.

- [ ] **Step 2: Verify HookTests still builds + passes (no Stop-hook group).** From `app/`: `swift run HookTests`. Expected: `✅ HookTests: all checks passed` (now running speakable-text, voice-context, codex only).

- [ ] **Step 3: Update `ConfigManager` — stop registering the Stop hook.** In `applyHookToSettings()`, delete the block that builds `stopArray`/`stopEntry`/`hooks["Stop"]` (lines that compute `countBefore`, `removeAll` on `stopArray`, append `stopEntry`, and set `hooks["Stop"]`). Keep the `UserPromptSubmit` registration block intact. Replace the success-message `removed` logic with a flat `"Hook applied"`. Then delete `showClaudeSettingsInstructions()` (Stop-hook instructions) and repurpose `checkHookConfigured()` to check for our `UserPromptSubmit` entry instead of `Stop`:

```swift
static func checkHookConfigured() -> Bool {
    guard let data = try? Data(contentsOf: Paths.claudeSettings),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = json["hooks"] as? [String: Any],
          let ups = hooks["UserPromptSubmit"] as? [[String: Any]] else { return false }
    return ups.contains { entry in
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { (($0["command"] as? String).map(isOurHook) ?? false) }
    }
}
```
Update `showHookInstructions(for:)` so the `.claudeCode` case no longer calls the deleted `showClaudeSettingsInstructions()` — point it at the MCP instructions added in Task 3 (Task 3 Step 4 defines `showClaudeMCPInstructions()`).

- [ ] **Step 4: Add the launch migration.** Append to `ConfigManager` (Migration section):

```swift
/// One-shot upgrade cleanup: remove our obsolete Stop hook from ~/.claude/settings.json so an
/// old install doesn't keep a dead `tts-hook.sh` entry (the script no longer ships).
static func migrateRemoveClaudeStopHook() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: Paths.claudeSettings.path),
          let data = try? Data(contentsOf: Paths.claudeSettings),
          var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          var hooks = settings["hooks"] as? [String: Any],
          var stop = hooks["Stop"] as? [[String: Any]] else { return }
    let before = stop.count
    stop.removeAll { entry in
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { (($0["command"] as? String).map(isOurHook) ?? false) }
    }
    guard stop.count != before else { return }
    if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
    settings["hooks"] = hooks
    if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        try? out.write(to: Paths.claudeSettings)
    }
}
```
Call it once on launch in `AppDelegate` next to the existing `ConfigManager.migrate…()` calls (search `applicationDidFinishLaunching` for `migrateVoiceDetailToTtsStyle` and add `ConfigManager.migrateRemoveClaudeStopHook()` beside it).

- [ ] **Step 5: Remove the dead `Paths.ttsHook`.** In `Paths.swift` delete the `ttsHook` declaration (lines 16–17). Keep `speakableTextScript` (used by `codex-tts-hook.sh`). Build will flag any remaining reference.

- [ ] **Step 6: Build the app to confirm no dangling references.** From `app/`: `swift build`. Expected: `Build complete!` with no errors (if `Paths.ttsHook` is referenced anywhere else, fix that reference).

- [ ] **Step 7: Commit.**

```bash
git add -A
git commit -m "feat(voice): remove Claude Stop hook; strip stale Stop entry on upgrade"
```

---

### Task 3: `ConfigManager` registers the `speak` MCP server (Claude Code)

On "Apply hooks" for Claude Code, also register the in-app MCP server in `~/.claude.json` so the model gets the `speak` tool. Read-modify-write to preserve the rest of that file.

**Files:**
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (add `claudeJSON`)
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift` (`registerClaudeMCPServer`, call from `applyHookToSettings`, add `showClaudeMCPInstructions`, extend `checkHookConfigured`’s sibling diagnostic)

**Interfaces:**
- Consumes: `Paths.claudeJSON` = `~/.claude.json`.
- Produces: `~/.claude.json` → `mcpServers["OpenWhisperer"] = {"type":"http","url":"http://localhost:8000/mcp"}`, all other keys preserved.

- [ ] **Step 1: Add the path.** In `Paths.swift`:

```swift
/// Claude Code user config (holds user-scope MCP servers under `mcpServers`).
static let claudeJSON: URL = {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
}()
```

- [ ] **Step 2: Add the registration function** to `ConfigManager`:

```swift
/// Register the in-app `speak` MCP server in ~/.claude.json (user scope). Read-modify-write so
/// the rest of the (large, Claude-Code-managed) file is preserved. Idempotent.
@discardableResult
static func registerClaudeMCPServer() -> (success: Bool, message: String) {
    let fm = FileManager.default
    var root: [String: Any] = [:]
    if fm.fileExists(atPath: Paths.claudeJSON.path),
       let data = try? Data(contentsOf: Paths.claudeJSON),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        root = json
    }
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    servers["OpenWhisperer"] = ["type": "http", "url": "http://localhost:8000/mcp"]
    root["mcpServers"] = servers
    guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
        return (false, "Failed to serialize ~/.claude.json")
    }
    do { try out.write(to: Paths.claudeJSON); return (true, "speak tool registered") }
    catch { return (false, "Write failed: \(error.localizedDescription)") }
}
```

- [ ] **Step 3: Call it from `applyHookToSettings()`.** After the `UserPromptSubmit` registration writes `settings.json` successfully (just before `return (true, …)`), add `registerClaudeMCPServer()` so a single "Apply" wires both the hook and the tool.

- [ ] **Step 4: Replace the Claude instruction window** (manual-setup path). Add:

```swift
static func showClaudeMCPInstructions() {
    let window = InstructionWindow(
        title: "Step 1: Claude Code voice (hook + speak tool)",
        instructions: """
        OpenWhisperer adds voice to Claude Code in two pieces:

        1) UserPromptSubmit hook (in ~/.claude/settings.json) — nudges Claude to
           speak a summary on dictated turns. "Apply" wires this automatically.

        2) The `speak` MCP tool (in ~/.claude.json) — lets Claude play that summary
           through OpenWhisperer:

           claude mcp add --scope user --transport http \\
             OpenWhisperer http://localhost:8000/mcp

        Then RESTART Claude Code so it loads the tool. Verify with:  /mcp
        """
    )
    window.show()
}
```
Point `showHookInstructions(for:)`’s `.claudeCode` case at `showClaudeMCPInstructions()`.

- [ ] **Step 5: Build to confirm it compiles.** From `app/`: `swift build`. Expected: `Build complete!`.

- [ ] **Step 6: Commit.**

```bash
git add -A
git commit -m "feat(mcp): register speak MCP server in ~/.claude.json on apply"
```

---

### Task 4: Migrate Codex — `speak` tool + shared nudge hook; delete `codex-tts-hook.sh`

Codex now gets the same treatment as Claude: register the MCP server and the shared
`voice-context.sh` as a `UserPromptSubmit` hook in `~/.codex/config.toml`, and delete the old
`notify` → `codex-tts-hook.sh` path. Spiked 2026-06-26 (5/5 speak-first). **Two parts need care
during execution:** (a) robust TOML editing of `config.toml` (the existing code does line-based
`notify` editing; adding `[mcp_servers.*]` + `[[hooks.*]]` tables needs idempotent append-if-absent),
and (b) **hook trust** — Codex skips untrusted hooks, so the setup must establish persisted trust
(resolve the mechanism: a one-time `codex` trust prompt the user approves, vs. an app-written trust
record). Surface trust in the instruction window regardless.

**Files:**
- Delete: `hooks/codex-tts-hook.sh`, `app/Tests/HookTests/CodexTtsHookChecks.swift`
- Delete (after `grep` confirms no other consumer): `hooks/speakable-text.sh`, `app/Tests/HookTests/SpeakableTextChecks.swift`
- Modify: `app/Tests/HookTests/main.swift` (drop `codexTtsHookFailures()`, `speakableTextFailures()`)
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift` (`applyHookToCodexConfig`, `showCodexConfigInstructions`, `checkCodexHookConfigured`)
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (drop `codexTtsHook`; drop `speakableTextScript` if deleted)

**Interfaces:**
- Consumes: `Paths.codexConfig` (`~/.codex/config.toml`), `Paths.voiceContextHook`.
- Produces: `applyHookToCodexConfig()` writes `[mcp_servers.OpenWhisperer]` + the `UserPromptSubmit` command hook into `config.toml` and removes any stale `notify = […codex-tts-hook…]` line; preserves all other content.

- [ ] **Step 1: Confirm `speakable-text.sh` has no remaining consumer.** `grep -rn "speakable-text" hooks scripts app` — both Stop hooks are its only callers; once they're gone it's dead. If `scripts/speak.sh` or anything else references it, keep it (and its test) and skip those deletions.

- [ ] **Step 2: Delete the Codex notify hook + its test, de-wire the runner.**

```bash
git rm hooks/codex-tts-hook.sh app/Tests/HookTests/CodexTtsHookChecks.swift
# only if Step 1 showed no other consumer:
git rm hooks/speakable-text.sh app/Tests/HookTests/SpeakableTextChecks.swift
```
In `app/Tests/HookTests/main.swift` remove `failures += codexTtsHookFailures()` (and `failures += speakableTextFailures()` if that test was deleted).

- [ ] **Step 3: Verify HookTests builds + passes.** From `app/`: `swift run HookTests`. Expected: `✅` (now just `voice-context` — shared by both platforms).

- [ ] **Step 4: Rewrite `applyHookToCodexConfig()`** to register the MCP server + the shared nudge hook instead of `notify`. Read `config.toml`, then: remove any line matching `^notify\s*=` that references our hook; ensure a `[mcp_servers.OpenWhisperer]` block with `url = "http://localhost:8000/mcp"` exists (append if absent); ensure the `[[hooks.UserPromptSubmit]]` + `[[hooks.UserPromptSubmit.hooks]]` (`type="command"`, `command="<Paths.voiceContextHook.path>"`) block exists (append if absent). Idempotent: detect our blocks by the `OpenWhisperer`/`voice-context.sh` substrings before appending. Preserve all other content.

- [ ] **Step 5: Update `showCodexConfigInstructions()`** to document the two config blocks AND the hook-trust step (e.g. "run `codex` once and approve trusting the OpenWhisperer hook, or it won't fire"). Update `checkCodexHookConfigured()` to look for `mcp_servers.OpenWhisperer` / `voice-context.sh` instead of `codex-tts-hook`.

- [ ] **Step 6: Drop dead Paths.** Remove `Paths.codexTtsHook`; remove `Paths.speakableTextScript` if the script was deleted. Build will flag stragglers.

- [ ] **Step 7: Build to confirm no dangling references.** From `app/`: `swift build`. Expected: `Build complete!`.

- [ ] **Step 8: Commit.**

```bash
git add -A
git commit -m "feat(codex): migrate Codex to the speak tool + shared nudge hook"
```

---

### Task 5: Docs — rewrite the voice-turn handshake sections

Replace the Stop-hook narrative in `CLAUDE.md` / `AGENTS.md` with the new one (response-mode gate + `speak`-first nudge + `speak` MCP tool; Codex unchanged on its Stop path).

**Files:**
- Modify: `AGENTS.md` (§ "Voice-turn handshake", § "TTS …", state/IPC notes referencing `speak_pending`/`tts-hook.sh`)
- Modify: `CLAUDE.md` (the `[VOICE:]`/handshake pointer paragraph if it references the Stop hook)

- [ ] **Step 1: Rewrite the AGENTS.md "Voice-turn handshake" section** so it reads: app writes `voice_turn` on dictation → `voice-context.sh` (UserPromptSubmit) hash-matches + claims it, applies `tts_response_mode`, and on a speak decision injects a hidden nudge to **call the `speak` MCP tool first** → the model calls `speak`, which the app synthesizes + plays in-process. State plainly: **there is no Stop hook and no `speak_pending` marker** — *both* Claude Code and Codex now use the shared `voice-context.sh` nudge + the `speak` MCP tool (the Codex `notify` → `codex-tts-hook.sh` path is deleted; note Codex's one-time hook-trust step). Update the `ServerManager`/TTS section to mention `POST /mcp` alongside `/v1/audio/play`. Remove `speak_pending`/`tts-hook.sh`/`codex-tts-hook.sh` from the Paths-list and architecture narrative.

- [ ] **Step 2: Fix the CLAUDE.md pointer** — its "Voice-turn handshake" mention should say the spoken summary is delivered by the model calling the `speak` tool (no Stop hook), keeping the existing "README is obsolete" framing.

- [ ] **Step 3: Read back both files** and confirm no remaining claim that Claude Code speaks via a Stop hook / `tts-hook.sh` / `speak_pending`.

- [ ] **Step 4: Commit.**

```bash
git add AGENTS.md CLAUDE.md
git commit -m "docs: rewrite voice-turn handshake for the speak MCP tool"
```

---

### Task 6: Signed rebuild + interactive validation (manual — needs the user)

Closes the spike's one untested gap: real interactive long turns. Requires the user (mic, dictation, replacing the running app).

**Files:** none (build + manual test).

- [ ] **Step 1: Stop the spike's headless server** still on `:8000` (from the spike) so the GUI can bind it:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN -t | xargs -r kill
```

- [ ] **Step 2: Run all tests once more.** From `app/`: `swift run OpenWhispererKitTests && swift run HookTests`. Expected: both `✅`.

- [ ] **Step 3: Signed build + install** (stable cert so mic/Accessibility grants persist):

```bash
cd app && OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh
```
Install the built `.app` (replace the menubar app), launch it, click **Apply** for Claude Code (registers the UserPromptSubmit hook + the `speak` MCP server), then **restart Claude Code**.

- [ ] **Step 4: Validate in a real session (both platforms).** Claude Code: `claude mcp list` shows `OpenWhisperer ✔ Connected`; a **dictated** conversational turn → audio starts early; a dictated **coding** turn (the long-turn case) → `speak` still fires and audio leads the written reply; a **typed** turn in default `voice` mode → silent. Codex: after the one-time hook-trust approval, a dictated turn → `speak` fires (watch the `hook: UserPromptSubmit` line). Watch for any silent dictated turn (the accepted KISS risk) on either platform and note frequency.

- [ ] **Step 5: Update the spec's "Remaining gap"** with the interactive long-turn result for both platforms (pass/fail + any silent-turn rate), then commit:

```bash
git add docs/superpowers/specs/2026-06-25-early-speak-tool-design.md
git commit -m "docs(spec): record interactive long-turn validation"
```

---

## Self-Review

**Spec coverage:** Components 1 (`speak` MCP tool) + transport — done in spike (referenced). Component 2 (positive nudge) → Task 1 (shared by both platforms). Component 3 (`ConfigManager` register MCP + remove Stop hooks) → Tasks 2–4. Response-mode gate preserved → Task 1 (tests 10–15). `tts_style`/`full` redefine → Task 1 (test 9 + script `rich|full`). Removed-vs-today (both Stop hooks, `speak_pending`) → Tasks 2 + 4. ConfigManager removal-on-upgrade → Task 2 migration. Docs impact → Task 5. KISS/no-fallback + both-platforms honored throughout; **no version bump** (maintainer's call). Now matches the spec's "delete both Stop hooks" since the Codex spike cleared it.

**Placeholder scan:** Task 1 ships the full script + full test file. Tasks 2–3 give exact files/lines/commands + functions verbatim. Task 4 (Codex) is concrete on files/commands but deliberately leaves two items to resolve at execution — robust `config.toml` TOML editing and the hook-trust mechanism — because both are genuine unknowns flagged in the task header, not hand-waving. Task 5 is prose-editing; Task 6 is manual with exact commands.

**Type consistency:** `registerClaudeMCPServer()`, `migrateRemoveClaudeStopHook()`, `showClaudeMCPInstructions()`, `Paths.claudeJSON`, `isOurHook(_:)`, `Paths.voiceContextHook`, `Paths.codexConfig` referenced consistently across tasks. Nudge substring `` `speak` tool `` is the assertion contract between the script (Task 1 Step 3) and tests (Task 1 Step 1), for both platforms.
