# Antigravity CLI (agy) Voice Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fourth `Platform.antigravity` case so Antigravity CLI (agy) gets
the same early-speak voice experience as Claude Code, Codex, and Pi.

**Architecture:** Factor the platform-agnostic decision logic (response mode,
`voice_turn` hash-match, style/voice/persona resolution, nudge text) out of
`hooks/voice-context.sh` into a new sourced `hooks/voice-shared.sh`. Add
`hooks/agy-previnvocation.sh`, agy's `PreInvocation` hook, which gates on
`invocationNum == 0` (confirmed live to mark the first model call of a fresh
user turn) and reads the just-submitted prompt from `transcriptPath` instead
of stdin. Wire both into `ConfigManager` as a new platform: register the
existing `/mcp` endpoint via agy's `serverUrl` (SSE) transport in
`mcp_config.json`, and the `PreInvocation` hook in the **global**
`~/.gemini/config/hooks.json` (confirmed live to fire for any workspace, not
just one project).

**Tech Stack:** Bash (hooks), Swift/SwiftUI (`ConfigManager`, `MenuBarView`),
`jq` (JSON parsing in hooks), the plain-executable `HookTests` runner.

## Global Constraints

- MCP endpoint: `http://localhost:8000/mcp` (already implemented, unchanged).
- `voice_turn` TTL: 900 seconds (`FRESHNESS`), unchanged, shared across all hooks.
- agy's `PreInvocation` hook config location: **global** `~/.gemini/config/hooks.json`, not a per-workspace `.agents/hooks.json`.
- agy's MCP config location: `~/.gemini/config/mcp_config.json`, `mcpServers.<name>.serverUrl`.
- No fallback (no Stop hook) for agy — matches Claude/Codex's KISS stance: a missed `speak` call means a silent turn.
- No per-project override mechanism invented for agy — `voice-shared.sh` reads `$OW_TTS_STYLE`/`$OW_TTS_RESPONSE`/`$OW_TTS_VOICE`/`$OW_TTS_SPEED` from its own process env, same as `voice-context.sh` today.
- Commit messages: Conventional Commits (`type(scope): subject`), imperative mood, ~50-char subject, hard cap 72 chars including prefix. No `Co-Authored-By` / tool attribution.
- Build/test commands run from `app/`: `swift run OpenWhispererKitTests`, `swift run HookTests`.
- Reference spec: `docs/superpowers/specs/2026-07-06-agy-voice-support-design.md`.

---

### Task 1: Extract shared hook logic into `hooks/voice-shared.sh`

**Files:**
- Create: `hooks/voice-shared.sh`
- Modify: `hooks/voice-context.sh` (full rewrite, same behavior)
- Test: `app/Tests/HookTests/VoiceContextChecks.swift` (no changes — used as the regression oracle)

**Interfaces:**
- Produces (for Task 2 to consume): `resolve_mode`, `match_and_claim_voice_turn "<prompt>"` (echoes `0`/`1`), `build_nudge "<is_voice 0|1>"` (echoes the nudge sentence), and the `$VOICE_TURN` variable — all defined in `hooks/voice-shared.sh`, sourced via `source "$SCRIPT_DIR/voice-shared.sh"`.

- [ ] **Step 1: Run the existing hook test suite as a baseline**

Run: `cd app && swift run HookTests`
Expected: `✅ HookTests: all checks passed`

- [ ] **Step 2: Create `hooks/voice-shared.sh`**

```bash
#!/bin/bash
# Shared logic for OpenWhisperer's voice-turn hooks: response-mode resolution, voice_turn
# hash-match-and-claim, style/voice/persona resolution, and nudge-sentence construction.
# Sourced by hooks/voice-context.sh (Claude Code + Codex UserPromptSubmit) and
# hooks/agy-previnvocation.sh (Antigravity CLI PreInvocation) — the two hooks differ in
# stdin/stdout shape but share this decision.

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VOICE_TURN="$APP_SUPPORT/voice_turn"
# voice_turn time-to-live (seconds) — kept uniform across the hooks.
FRESHNESS=900

# Response mode. Precedence: per-project OW_TTS_RESPONSE env → global file → "voice".
resolve_mode() {
  local mode="$OW_TTS_RESPONSE"
  [ -z "$mode" ] && mode=$(cat "$APP_SUPPORT/tts_response_mode" 2>/dev/null | tr -d '[:space:]')
  [ -z "$mode" ] && mode="voice"
  printf '%s' "$mode"
}

# Determine whether THIS turn was voice-dictated: a fresh voice_turn whose hash matches the
# given prompt text. On a match, atomically claim (consume) the signal so a later typed turn
# isn't also matched. A stale signal is swept. Echoes "1" (matched+claimed) or "0" (no match).
# (Hashing MUST match VoiceSignal.canonicalHash.)
match_and_claim_voice_turn() {
  local prompt="$1"
  [ -f "$VOICE_TURN" ] || { echo 0; return; }
  local stored_hash stored_ts
  stored_hash=$(sed -n '1p' "$VOICE_TURN" 2>/dev/null)
  stored_ts=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
  [ -z "$stored_hash" ] && { echo 0; return; }
  local now
  now=$(date +%s)
  if [ -n "$stored_ts" ] && [ "$((now - stored_ts))" -gt "$FRESHNESS" ]; then
    rm -f "$VOICE_TURN"
    echo 0
    return
  fi
  trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
  local trimmed prompt_hash
  trimmed=$(trim "$prompt")
  if command -v shasum >/dev/null 2>&1; then
    prompt_hash=$(printf '%s' "$trimmed" | shasum -a 256 | awk '{print $1}')
  else
    prompt_hash=$(printf '%s' "$trimmed" | openssl dgst -sha256 | awk '{print $NF}')
  fi
  if [ "$prompt_hash" = "$stored_hash" ]; then
    local claim="$APP_SUPPORT/.voice_turn.claimed.$$"
    if mv "$VOICE_TURN" "$claim" 2>/dev/null; then
      rm -f "$claim"
      echo 1
      return
    fi
  fi
  echo 0
}

# Spoken-summary length hint. Precedence: OW_TTS_STYLE env → tts_style file → legacy voice_detail.
resolve_length_phrase() {
  local style="$OW_TTS_STYLE"
  [ -z "$style" ] && style=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
  [ -z "$style" ] && style=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
  case "$style" in
    terse)     echo "one short, plain spoken sentence" ;;
    rich|full) echo "a sentence or two of plain spoken summary" ;;
    *)         echo "one plain spoken sentence" ;;
  esac
}

# Native-tongue flavor: for a personified voice, an ungated persona keyed off the voice id's
# first char: a light national character, set for English (a/b) too. The flavors stay subdued,
# so they don't detract from the message. Personality only, no vocabulary steering; whatever
# code-switching happens is the model's own.
# The map lives ONLY here (unknown/no voice → nothing); HookTests is its guard.
# Resolved voice: per-project OW_TTS_VOICE env → global tts_voice file.
resolve_flavor() {
  local voice="$OW_TTS_VOICE"
  [ -z "$voice" ] && voice=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null)
  voice=$(printf '%s' "$voice" | tr -d '[:space:]')
  local lang="" persona=""
  case "${voice:0:1}" in
    a) lang="American English"; persona="quietly self-assured, with a light touch of Silicon Valley hype" ;;
    b) lang="British English"; persona="dry and unflappable, with a streak of deadpan wit and gentle irony" ;;
    f) lang="French"; persona="dry and faintly unimpressed, given to the occasional philosophical shrug" ;;
    i) lang="Italian"; persona="warm and expressive; things are either wonderful or a small catastrophe, rarely in between" ;;
    e) lang="Spanish"; persona="relaxed and direct; there's always time, and it'll all be fine" ;;
    p) lang="Brazilian Portuguese"; persona="sunny and easygoing, unbothered, always a friendly way around things" ;;
    h) lang="Hindi"; persona="warm and irrepressibly helpful, the eternal problem-solver, assuring you it's no trouble at all" ;;
    j) lang="Japanese"; persona="courteous and understated, meticulous, softening things, quietly prizing care and subtlety" ;;
    z) lang="Mandarin Chinese"; persona="pragmatic and modest, understated, fond of a proverb, unfussed by small things" ;;
  esac
  if [ -n "$persona" ]; then
    echo " The voice reading this aloud is ${lang}. Play it ${persona}."
  else
    echo ""
  fi
}

# Per-project overrides → tell the model to pass them to `speak`. Only an override needs
# injecting; the global voice/speed are already the tool's defaults. Speed must be numeric.
resolve_speak_args() {
  local voice="$OW_TTS_VOICE"
  [ -z "$voice" ] && voice=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null)
  voice=$(printf '%s' "$voice" | tr -d '[:space:]')
  local ovr=""
  [ -n "$OW_TTS_VOICE" ] && ovr=" voice=\"$voice\""
  if [ -n "$OW_TTS_SPEED" ] && printf '%s' "$OW_TTS_SPEED" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    ovr="${ovr} speed=$OW_TTS_SPEED"
  fi
  if [ -n "$ovr" ]; then echo " Call it with${ovr}."; else echo ""; fi
}

# Build the full nudge sentence. $1 = IS_VOICE (0/1).
build_nudge() {
  local is_voice="$1"
  local len flavor speak_args prefix
  len=$(resolve_length_phrase)
  flavor=$(resolve_flavor)
  speak_args=$(resolve_speak_args)
  if [ "$is_voice" -eq 1 ]; then
    prefix="This turn was dictated by voice."
  else
    prefix="This reply should be spoken aloud."
  fi
  printf '%s Before writing your on-screen reply, your FIRST action must be to call the `speak` tool exactly once, passing %s that summarizes your answer and stands alone when heard.%s Then write your full reply on screen as usual. Do not skip the speak call, and do not mention the tool in your written reply.%s' \
    "$prefix" "$len" "$speak_args" "$flavor"
}
```

- [ ] **Step 3: Rewrite `hooks/voice-context.sh` to source the shared file**

Replace the entire file with:

```bash
#!/bin/bash
# UserPromptSubmit hook (Claude Code + Codex) — decides whether THIS turn's reply is spoken and,
# if so, nudges the model to call the `speak` MCP tool FIRST with a standalone spoken summary.
#
# Response mode (tts_response_mode, or per-project OW_TTS_RESPONSE):
#   voice  (default) — speak only voice-dictated turns (prompt hash matches voice_turn)
#   always           — speak every turn
# There is no Stop hook and no speak_pending marker: the model's own `speak` call is the audio.
# Both platforms pass {prompt, session_id, hook_event_name:"UserPromptSubmit"} and accept the
# {hookSpecificOutput:{additionalContext}} output, so one script serves both.
#
# The mode/hash/style/voice/flavor logic lives in voice-shared.sh, shared with
# agy-previnvocation.sh (Antigravity CLI), which has a different stdin/stdout shape but the same
# underlying decision.
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/voice-shared.sh"

MODE=$(resolve_mode)

# Fast path: default "voice" mode with no pending dictation has nothing to do.
[ "$MODE" = "voice" ] && [ ! -f "$VOICE_TURN" ] && exit 0

# Find jq (system, then bundled next to the hooks dir).
if ! command -v jq >/dev/null 2>&1; then
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else exit 0; fi
fi

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
[ -z "$PROMPT" ] && exit 0

IS_VOICE=$(match_and_claim_voice_turn "$PROMPT")

# Decide whether to speak this turn, per Response mode.
SPEAK=0
case "$MODE" in
  always) SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;   # voice (default); a stale "text" falls here
esac
[ "$SPEAK" -eq 1 ] || exit 0

NUDGE=$(build_nudge "$IS_VOICE")

jq -n --arg ctx "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}'
exit 0
```

- [ ] **Step 4: Make the new file executable**

Run: `chmod +x hooks/voice-shared.sh`
(`voice-context.sh` is already executable and unchanged in that respect.)

- [ ] **Step 5: Re-run the test suite to confirm no regression**

Run: `cd app && swift run HookTests`
Expected: `✅ HookTests: all checks passed` (identical result to Step 1 — this was a pure refactor)

- [ ] **Step 6: Commit**

```bash
git add hooks/voice-shared.sh hooks/voice-context.sh
git commit -m "refactor(voice): extract shared hook logic into voice-shared.sh"
```

---

### Task 2: Add `hooks/agy-previnvocation.sh` (agy's PreInvocation hook)

**Files:**
- Create: `hooks/agy-previnvocation.sh`
- Modify: `app/Tests/HookTests/HookHarness.swift` (add a transcript-fixture helper)
- Create: `app/Tests/HookTests/AgyPreInvocationChecks.swift`
- Modify: `app/Tests/HookTests/main.swift`

**Interfaces:**
- Consumes: `resolve_mode`, `match_and_claim_voice_turn`, `build_nudge`, `$VOICE_TURN` from `hooks/voice-shared.sh` (Task 1).
- Produces: `hooks/agy-previnvocation.sh`, invoked as `/bin/bash hooks/agy-previnvocation.sh` with agy's `PreInvocation` JSON on stdin (`invocationNum`, `transcriptPath`, ...), emitting `{}` or `{"injectSteps":[{"ephemeralMessage": "..."}]}` on stdout.

- [ ] **Step 1: Add a transcript-fixture helper to `HookHarness.swift`**

In `app/Tests/HookTests/HookHarness.swift`, add this method inside `final class Sandbox` (after `writeLegacyVoiceDetail`, before `writeMarker`):

```swift
        /// Write a minimal agy `transcript_full.jsonl` fixture: one `USER_EXPLICIT` line per
        /// entry in `userTexts`, each wrapped exactly as agy wraps a real submitted prompt
        /// (`<USER_REQUEST>\n<text>\n</USER_REQUEST>\n<ADDITIONAL_METADATA>...`). The hook always
        /// reads the LAST `USER_EXPLICIT` entry, so a multi-entry fixture proves it ignores
        /// earlier turns. Returns the transcript file's path.
        func writeAgyTranscript(_ userTexts: [String]) -> URL {
            let path = home.appendingPathComponent("transcript_full.jsonl")
            var lines: [String] = []
            for (i, text) in userTexts.enumerated() {
                let stamp = String(format: "2026-07-06T09:12:%02dZ", i)
                let content = "<USER_REQUEST>\n\(text)\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: \(stamp).\n</ADDITIONAL_METADATA>"
                let obj: [String: Any] = [
                    "step_index": i, "source": "USER_EXPLICIT", "type": "text",
                    "status": "done", "created_at": stamp, "content": content,
                ]
                let data = try! JSONSerialization.data(withJSONObject: obj)
                lines.append(String(data: data, encoding: .utf8)!)
            }
            try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
            return path
        }
```

- [ ] **Step 2: Write the failing test file `AgyPreInvocationChecks.swift`**

```swift
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
```

- [ ] **Step 3: Wire the new check group into `main.swift`**

In `app/Tests/HookTests/main.swift`, change:

```swift
var failures: [String] = []
failures += voiceContextFailures()
```

to:

```swift
var failures: [String] = []
failures += voiceContextFailures()
failures += agyPreInvocationFailures()
```

- [ ] **Step 4: Run the suite to verify the new tests fail (script doesn't exist yet)**

Run: `cd app && swift run HookTests`
Expected: FAIL — check group `agy-previnvocation.*` reports errors (the hook script is missing, so `Hook.run` returns a non-`{}` "RUN ERROR" result).

- [ ] **Step 5: Create `hooks/agy-previnvocation.sh`**

```bash
#!/bin/bash
# PreInvocation hook (Antigravity CLI / agy) — fires before every model call in the agent loop.
# invocationNum resets to 0 at the start of each new user turn (confirmed live 2026-07-06: one
# session produced three turns, each starting invocationNum=0, while a separate initialNumSteps
# field climbed monotonically across all of them), so we gate on that to behave like a
# once-per-turn hook. No prompt text is given on stdin; it's read from transcriptPath's last
# USER_EXPLICIT entry instead. See voice-shared.sh for the shared mode/hash/style/voice/flavor
# logic also used by voice-context.sh (Claude Code + Codex).
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/voice-shared.sh"

if ! command -v jq >/dev/null 2>&1; then
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else echo '{}'; exit 0; fi
fi

INPUT=$(cat)
INVOCATION_NUM=$(printf '%s' "$INPUT" | jq -r '.invocationNum // empty')
[ "$INVOCATION_NUM" = "0" ] || { echo '{}'; exit 0; }

MODE=$(resolve_mode)
[ "$MODE" = "voice" ] && [ ! -f "$VOICE_TURN" ] && { echo '{}'; exit 0; }

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcriptPath // empty')
PROMPT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  LAST=$(jq -c 'select(.source=="USER_EXPLICIT")' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
  if [ -n "$LAST" ]; then
    CONTENT=$(printf '%s' "$LAST" | jq -r '.content // empty')
    PROMPT=$(printf '%s' "$CONTENT" | sed -n '/<USER_REQUEST>/,/<\/USER_REQUEST>/p' | sed '1d;$d')
  fi
fi
[ -z "$PROMPT" ] && { echo '{}'; exit 0; }

IS_VOICE=$(match_and_claim_voice_turn "$PROMPT")

SPEAK=0
case "$MODE" in
  always) SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;
esac
[ "$SPEAK" -eq 1 ] || { echo '{}'; exit 0; }

NUDGE=$(build_nudge "$IS_VOICE")

jq -n --arg msg "$NUDGE" '{injectSteps: [{ephemeralMessage: $msg}]}'
exit 0
```

- [ ] **Step 6: Make it executable**

Run: `chmod +x hooks/agy-previnvocation.sh`

- [ ] **Step 7: Run the suite to verify all tests pass**

Run: `cd app && swift run HookTests`
Expected: `✅ HookTests: all checks passed`

- [ ] **Step 8: Commit**

```bash
git add hooks/agy-previnvocation.sh app/Tests/HookTests/HookHarness.swift \
        app/Tests/HookTests/AgyPreInvocationChecks.swift app/Tests/HookTests/main.swift
git commit -m "feat(voice): add agy PreInvocation hook for early-speak nudge"
```

---

### Task 3: Bundle the new hook files into the app package

**Files:**
- Modify: `app/build-dmg.sh:52-58`
- Modify: `app/Package.swift` (comment only, near the `HookTests` target)

**Interfaces:**
- Consumes: `hooks/voice-shared.sh`, `hooks/agy-previnvocation.sh` (Tasks 1–2).
- Produces: both files present, executable, at `Contents/Resources/hooks/` in the packaged `.app`, alongside the existing `voice-context.sh`.

- [ ] **Step 1: Update the hook-copying block in `build-dmg.sh`**

In `app/build-dmg.sh`, change:

```bash
# Step 3: Bundle the voice hook (Claude + Codex), speak.sh, and the Pi extension
cp "$PROJECT_DIR/hooks/voice-context.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/scripts/speak.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
cp "$PROJECT_DIR/pi/openwhisperer.ts" "$APP_BUNDLE/Contents/Resources/pi/"

# Make scripts executable
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/voice-context.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/speak.sh"
```

to:

```bash
# Step 3: Bundle the voice hooks (Claude/Codex + Antigravity), their shared logic, speak.sh,
# and the Pi extension
cp "$PROJECT_DIR/hooks/voice-context.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/voice-shared.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/hooks/agy-previnvocation.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$PROJECT_DIR/scripts/speak.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
cp "$PROJECT_DIR/pi/openwhisperer.ts" "$APP_BUNDLE/Contents/Resources/pi/"

# Make scripts executable
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/voice-context.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/voice-shared.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/agy-previnvocation.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/scripts/speak.sh"
```

- [ ] **Step 2: Update the `HookTests` target comment in `Package.swift`**

Change:

```swift
        // Integration tests for the bash hooks (Stop + UserPromptSubmit + speakable-text).
        // Shells out to ../../hooks/*.sh in an isolated temp HOME with a stubbed curl — the
        // Swift port of the deleted pytest suite. Run with: `swift run HookTests`.
```

to:

```swift
        // Integration tests for the bash hooks (UserPromptSubmit for Claude/Codex,
        // PreInvocation for Antigravity CLI). Shells out to ../../hooks/*.sh in an isolated
        // temp HOME with a stubbed curl — the Swift port of the deleted pytest suite.
        // Run with: `swift run HookTests`.
```

- [ ] **Step 3: Verify the build still compiles**

Run: `cd app && swift build`
Expected: builds with no errors (this task touches no Swift logic, only a comment and a shell script — confirms nothing else broke).

- [ ] **Step 4: Commit**

```bash
git add app/build-dmg.sh app/Package.swift
git commit -m "build: bundle voice-shared.sh and agy-previnvocation.sh"
```

---

### Task 4: Add Antigravity paths to `Paths.swift`

**Files:**
- Modify: `app/Sources/OpenWhisperer/Paths.swift`

**Interfaces:**
- Produces: `Paths.agyPreInvocationHook`, `Paths.agyMCPConfig`, `Paths.agyHooksConfig` — consumed by Task 5 (`ConfigManager`).

- [ ] **Step 1: Add the new path constants**

In `app/Sources/OpenWhisperer/Paths.swift`, after the existing Pi block (after line 112, `}()`), insert:

```swift

    /// Bundled PreInvocation hook (Antigravity CLI voice-turn detection).
    static let agyPreInvocationHook = resources.appendingPathComponent("hooks").appendingPathComponent("agy-previnvocation.sh")

    /// Antigravity CLI global MCP config (~/.gemini/config/mcp_config.json) — holds the
    /// `speak` tool registration over its SSE (serverUrl) transport.
    static let agyMCPConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini").appendingPathComponent("config").appendingPathComponent("mcp_config.json")
    }()

    /// Antigravity CLI global hooks config (~/.gemini/config/hooks.json) — holds the
    /// PreInvocation early-speak hook. Global, not per-workspace: confirmed live to fire for
    /// any workspace, matching how Claude/Codex/Pi are one-time, not per-project, installs.
    static let agyHooksConfig: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini").appendingPathComponent("config").appendingPathComponent("hooks.json")
    }()
```

- [ ] **Step 2: Verify the build compiles**

Run: `cd app && swift build`
Expected: builds with no errors (new unused constants compile fine; they're consumed in Task 5).

- [ ] **Step 3: Commit**

```bash
git add app/Sources/OpenWhisperer/Paths.swift
git commit -m "feat(voice): add Antigravity CLI config paths"
```

---

### Task 5: Wire `Platform.antigravity` into `ConfigManager`

**Files:**
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift`

**Interfaces:**
- Consumes: `Paths.agyPreInvocationHook`, `Paths.agyMCPConfig`, `Paths.agyHooksConfig` (Task 4).
- Produces: `Platform.antigravity` case; `ConfigManager.applyToAntigravity() -> (success: Bool, message: String)`; `ConfigManager.checkAntigravityConfigured() -> Bool`; `ConfigManager.showAntigravityInstructions()` — all consumed by Task 6 (`MenuBarView`) via the existing `applyHook(for:)` / `checkHookConfigured(for:)` / `showHookInstructions(for:)` dispatchers, which this task also updates.

- [ ] **Step 1: Add the new `Platform` case**

In `app/Sources/OpenWhisperer/ConfigManager.swift`, change:

```swift
enum Platform: String, CaseIterable {
    case claudeCode = "claudeCode"
    case codexCLI = "codexCLI"
    case pi = "pi"

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .pi: return "Pi"
        }
    }
```

to:

```swift
enum Platform: String, CaseIterable {
    case claudeCode = "claudeCode"
    case codexCLI = "codexCLI"
    case pi = "pi"
    case antigravity = "antigravity"

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .pi: return "Pi"
        case .antigravity: return "Antigravity"
        }
    }
```

- [ ] **Step 2: Add the Antigravity section**

In `app/Sources/OpenWhisperer/ConfigManager.swift`, immediately after `checkPiConfigured()` (after the closing brace of):

```swift
    static func checkPiConfigured() -> Bool {
        FileManager.default.fileExists(atPath: Paths.piExtensionDest.path)
    }
```

insert:

```swift

    // MARK: - Antigravity CLI (agy): mcp_config.json + hooks.json

    static func showAntigravityInstructions() {
        let window = InstructionWindow(
            title: "Step 1: Antigravity CLI voice (mcp_config.json + hooks.json)",
            instructions: """
            OpenWhisperer adds voice to Antigravity CLI (agy) in two pieces. "Apply"
            wires both automatically; to do it by hand:

            1) The `speak` MCP tool (in ~/.gemini/config/mcp_config.json) — reuses
               the same endpoint Claude/Codex/Pi talk to, over agy's SSE transport:

               {
                 "mcpServers": {
                   "openwhisperer": { "serverUrl": "http://localhost:8000/mcp" }
                 }
               }

            2) The PreInvocation hook (in ~/.gemini/config/hooks.json) — nudges the
               model to speak a summary first on dictated turns:

               {
                 "openwhisperer": {
                   "PreInvocation": [
                     { "type": "command", "command": "\\(Paths.agyPreInvocationHook.path)", "timeout": 10 }
                   ]
                 }
               }

            Start a NEW agy session afterward so it picks up both changes.

            By default only voice-dictated turns are spoken; typed turns stay silent. Change this with the Response setting (text = typed turns only; always = every turn).
            """
        )
        window.show()
    }

    /// Register the `speak` MCP server (SSE transport, same /mcp endpoint Claude/Codex/Pi use)
    /// in ~/.gemini/config/mcp_config.json, and the shared PreInvocation hook in the GLOBAL
    /// ~/.gemini/config/hooks.json (confirmed live: the global file fires for any workspace).
    /// Merges into existing config rather than overwriting it; idempotent.
    static func applyToAntigravity() -> (success: Bool, message: String) {
        let fm = FileManager.default

        // MCP registration.
        try? fm.createDirectory(at: Paths.agyMCPConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        var mcpRoot: [String: Any] = [:]
        if fm.fileExists(atPath: Paths.agyMCPConfig.path),
           let data = try? Data(contentsOf: Paths.agyMCPConfig),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            mcpRoot = json
        }
        var servers = mcpRoot["mcpServers"] as? [String: Any] ?? [:]
        servers["openwhisperer"] = ["serverUrl": "http://localhost:8000/mcp"]
        mcpRoot["mcpServers"] = servers
        guard let mcpOut = try? JSONSerialization.data(withJSONObject: mcpRoot, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return (false, "Failed to serialize mcp_config.json")
        }
        do {
            try mcpOut.write(to: Paths.agyMCPConfig)
        } catch {
            return (false, "mcp_config.json write failed: \\(error.localizedDescription)")
        }

        // Hook registration.
        try? fm.createDirectory(at: Paths.agyHooksConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        var hooksRoot: [String: Any] = [:]
        if fm.fileExists(atPath: Paths.agyHooksConfig.path),
           let data = try? Data(contentsOf: Paths.agyHooksConfig),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hooksRoot = json
        }
        hooksRoot["openwhisperer"] = [
            "PreInvocation": [
                ["type": "command", "command": Paths.agyPreInvocationHook.path, "timeout": 10]
            ]
        ]
        guard let hooksOut = try? JSONSerialization.data(withJSONObject: hooksRoot, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return (false, "Failed to serialize hooks.json")
        }
        do {
            try hooksOut.write(to: Paths.agyHooksConfig)
            return (true, "MCP server + PreInvocation hook applied — start a new agy session")
        } catch {
            return (false, "hooks.json write failed: \\(error.localizedDescription)")
        }
    }

    static func checkAntigravityConfigured() -> Bool {
        guard let mcpData = try? Data(contentsOf: Paths.agyMCPConfig),
              let mcpJSON = try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any],
              let servers = mcpJSON["mcpServers"] as? [String: Any],
              servers["openwhisperer"] != nil else { return false }
        guard let hooksData = try? Data(contentsOf: Paths.agyHooksConfig),
              let hooksJSON = try? JSONSerialization.jsonObject(with: hooksData) as? [String: Any],
              hooksJSON["openwhisperer"] != nil else { return false }
        return true
    }
```

- [ ] **Step 3: Update the three platform-dispatching wrappers**

In `app/Sources/OpenWhisperer/ConfigManager.swift`, change:

```swift
    static func applyHook(for platform: Platform) -> (success: Bool, message: String) {
        switch platform {
        case .claudeCode: return applyHookToSettings()
        case .codexCLI: return applyHookToCodexConfig()
        case .pi: return applyToPi()
        }
    }

    static func checkHookConfigured(for platform: Platform) -> Bool {
        switch platform {
        case .claudeCode: return checkHookConfigured()
        case .codexCLI: return checkCodexHookConfigured()
        case .pi: return checkPiConfigured()
        }
    }

    static func showHookInstructions(for platform: Platform) {
        switch platform {
        case .claudeCode: showClaudeMCPInstructions()
        case .codexCLI: showCodexConfigInstructions()
        case .pi: showPiInstructions()
        }
    }
```

to:

```swift
    static func applyHook(for platform: Platform) -> (success: Bool, message: String) {
        switch platform {
        case .claudeCode: return applyHookToSettings()
        case .codexCLI: return applyHookToCodexConfig()
        case .pi: return applyToPi()
        case .antigravity: return applyToAntigravity()
        }
    }

    static func checkHookConfigured(for platform: Platform) -> Bool {
        switch platform {
        case .claudeCode: return checkHookConfigured()
        case .codexCLI: return checkCodexHookConfigured()
        case .pi: return checkPiConfigured()
        case .antigravity: return checkAntigravityConfigured()
        }
    }

    static func showHookInstructions(for platform: Platform) {
        switch platform {
        case .claudeCode: showClaudeMCPInstructions()
        case .codexCLI: showCodexConfigInstructions()
        case .pi: showPiInstructions()
        case .antigravity: showAntigravityInstructions()
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd app && swift build`
Expected: builds with no errors. (`Platform` is `CaseIterable`, so any switch missing a case would fail to compile — a clean build here proves all four dispatchers are exhaustive.)

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/ConfigManager.swift
git commit -m "feat(voice): add Antigravity CLI platform to ConfigManager"
```

---

### Task 6: Update `MenuBarView.swift` copy for the fourth platform

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift:793,801,836-840`

**Interfaces:**
- Consumes: `Platform.antigravity` (Task 5) — the picker already iterates `Platform.allCases`, so no structural UI change is needed, only copy.

- [ ] **Step 1: Update the Setup card's static help text**

Change (line 793):

```swift
            help: "Wire up spoken replies for your CLI (Claude Code or Codex) — Auto-Apply writes the hooks.",
```

to:

```swift
            help: "Wire up spoken replies for your CLI (Claude Code, Codex, Antigravity, or Pi) — Auto-Apply writes the hooks.",
```

- [ ] **Step 2: Update the platform-picker help text**

Change (line 801):

```swift
            .help("Which coding agent you're setting up. Claude/Codex get a hook + speak tool; Pi gets an extension.")
```

to:

```swift
            .help("Which coding agent you're setting up. Claude/Codex/Antigravity get a hook + speak tool; Pi gets an extension.")
```

- [ ] **Step 3: Add the Antigravity branch to the Auto-Apply button's help ternary**

Change (lines 836–840):

```swift
                    .help(selectedPlatform == .claudeCode
                        ? "Writes the UserPromptSubmit hook into ~/.claude/settings.json + the speak MCP server into ~/.claude.json. Re-applies cleanly on rebuild."
                        : selectedPlatform == .codexCLI
                        ? "Writes the speak MCP server + UserPromptSubmit hook into ~/.codex/config.toml (needs one-time hook trust). Re-applies cleanly on rebuild."
                        : "Copies the OpenWhisperer extension into ~/.pi/agent/extensions/ (no MCP). Run /reload in Pi afterward.")
```

to:

```swift
                    .help(selectedPlatform == .claudeCode
                        ? "Writes the UserPromptSubmit hook into ~/.claude/settings.json + the speak MCP server into ~/.claude.json. Re-applies cleanly on rebuild."
                        : selectedPlatform == .codexCLI
                        ? "Writes the speak MCP server + UserPromptSubmit hook into ~/.codex/config.toml (needs one-time hook trust). Re-applies cleanly on rebuild."
                        : selectedPlatform == .pi
                        ? "Copies the OpenWhisperer extension into ~/.pi/agent/extensions/ (no MCP). Run /reload in Pi afterward."
                        : "Writes the speak MCP server into ~/.gemini/config/mcp_config.json + the PreInvocation hook into ~/.gemini/config/hooks.json. Start a new agy session afterward.")
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd app && swift build`
Expected: builds with no errors.

- [ ] **Step 5: Manual smoke test**

Run: `cd app && swift build -c release && ./build-dmg.sh` (or launch the debug build), open the menubar app, expand the **Setup** card, select **Antigravity** in the platform picker, click **Auto-Apply**, and confirm:
- The button flips to "Applied".
- `cat ~/.gemini/config/mcp_config.json` shows the `openwhisperer` entry under `mcpServers`.
- `cat ~/.gemini/config/hooks.json` shows the `openwhisperer` entry with a `PreInvocation` array pointing at the bundled `agy-previnvocation.sh`.
- A fresh agy session in any workspace, given a real dictated turn, calls `speak` before writing its on-screen reply.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/OpenWhisperer/MenuBarView.swift
git commit -m "feat(voice): surface Antigravity in the Setup card"
```

---

### Task 7: Docs + version bump

**Files:**
- Modify: `AGENTS.md` (Antigravity section under "Voice-turn handshake")
- Modify: `app/build-dmg.sh:10` (`DMG_NAME`)
- Modify: `app/Resources/Info.plist:12,14` (`CFBundleVersion`, `CFBundleShortVersionString`)

- [ ] **Step 1: Rewrite the Antigravity paragraph in `AGENTS.md`**

Find this paragraph (in the "Voice-turn handshake" section, "Known limitations" list):

```
- **Antigravity (agy) is not supported — the gap is structural** (spiked 2026-06-29; don't re-litigate). agy *can* host the `speak` MCP tool — validated live, audio played. But early-speak also needs a **per-turn pre-prompt hook** to inject the nudge, and **agy's CLI has none**. Its entire configurable hook surface is `Stop` (global `~/.gemini/config/hooks.json`, flat schema) + `PreToolUse`/`PostToolUse` (workspace `.agents/hooks.json`, nested schema). `UserPromptSubmit` is **absent from the binary** (silently ignored in the global file; **hangs agy** in workspace config); `SessionStart` exists internally (36× in the binary) but is **not a usable CLI hook** (ignored globally, hangs in workspace). So nothing can inject context pre-turn *or* at session start. The only agy-achievable voice paths are the old `Stop`-hook scrape (post-turn, first paragraph) or a standing `GEMINI.md`/plugin instruction (always-on) — neither delivers early-speak's gated mid-turn nudge, so agy was dropped. **Don't re-spike expecting a pre-prompt or session-start hook; there isn't one.**
```

Replace it with:

```
- **Antigravity (agy) is supported** (2026-07-06, superseding the earlier "unsupported" finding). agy's `PreInvocation` hook — undocumented in the 2026-06-29 spike, present in agy v1.0.16 — fires before every model call, and `invocationNum` resets to `0` at the start of each new user turn (confirmed live), giving early-speak the once-per-turn gate it needs. `hooks/agy-previnvocation.sh` reads the just-submitted prompt from `transcriptPath`'s last `USER_EXPLICIT` entry (no prompt text is given on stdin), classifies it against `voice_turn` via the shared `hooks/voice-shared.sh` (also used by `voice-context.sh`), and on a "speak" decision emits `{"injectSteps":[{"ephemeralMessage": "..."}]}`. The `speak` MCP tool is reached over agy's `serverUrl` (SSE) transport in `~/.gemini/config/mcp_config.json`, pointed at the same `POST /mcp` endpoint Claude/Codex/Pi use — no stdio shim needed, contrary to an earlier design review. The hook is registered in the **global** `~/.gemini/config/hooks.json`, not a per-workspace `.agents/hooks.json` (confirmed live: the global file fires for any workspace). Like Claude/Codex, there is no Stop-hook fallback — a missed `speak` call means a silent turn. See `docs/superpowers/specs/2026-07-06-agy-voice-support-design.md` for the full spike findings.
```

- [ ] **Step 2: Bump the version**

In `app/build-dmg.sh`, change:

```bash
DMG_NAME="OpenWhisperer-1.5.1"
```

to:

```bash
DMG_NAME="OpenWhisperer-1.6.0"
```

In `app/Resources/Info.plist`, change both:

```xml
    <key>CFBundleVersion</key>
    <string>1.5.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.5.1</string>
```

to:

```xml
    <key>CFBundleVersion</key>
    <string>1.6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.6.0</string>
```

- [ ] **Step 3: Verify the doc change reads correctly and the build still compiles**

Run: `cd app && swift build`
Expected: builds with no errors (this task touches no Swift logic besides the version string literals).

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md app/build-dmg.sh app/Resources/Info.plist
git commit -m "docs(voice): document Antigravity support, bump to 1.6.0"
```

---

## Final verification (after all tasks)

- [ ] Run `cd app && swift run OpenWhispererKitTests` — expect `exit 0`.
- [ ] Run `cd app && swift run HookTests` — expect `✅ HookTests: all checks passed`.
- [ ] Run `cd app && ./build-dmg.sh` — expect a signed `.app`/`.dmg` in `app/.build/`.
- [ ] Manual smoke test per Task 6 Step 5, on a real dictated turn in a fresh agy session, in a workspace other than `OpenWhisperer` (to prove the global hook, not a per-project artifact, is what fires).
- [ ] Rebase onto `origin/main` if it moved, push the branch, open the PR per AGENTS.md's PR workflow.
