# Tagless Voice Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CLAUDE.md `[VOICE:]` tag with a hook-driven, content-correlated voice-turn handshake so dictated turns are spoken (first paragraph) and typed turns are silent — with nothing added to the transcript and nothing in CLAUDE.md.

**Architecture:** The dictation app records a SHA-256 of the exact text it dictated to a side file (`voice_turn`). A `UserPromptSubmit` hook hashes the prompt it receives; on a match it knows THIS session is the voice turn, injects a hidden nudge, and marks the session (`speak_pending/<session_id>`). The `Stop` hook speaks the response's first paragraph only if its session is marked. Routing is exact because the prompt is the only artifact shared between the app (knows the window) and the hook (knows the session_id).

**Tech Stack:** Swift 5.9 / SwiftPM (macOS 14+, CryptoKit), bash hooks (`jq`, `shasum`/`openssl`), pytest for hook tests.

**Spec:** `docs/superpowers/specs/2026-06-17-tagless-voice-mode-design.md`

**Sequencing:** Implement after Phase 2 (native TTS). Build on the `phase1-native-stt` line (which has `OpenWhispererKit`, the native `DictationManager`, and the plain-executable test runner). Rebase this branch onto the integration point before starting.

## Global Constraints

- **macOS 14+, Swift 5.9.** Pure, dependency-free logic lives in `OpenWhispererKit` (no AppKit/AVFoundation/WhisperKit).
- **Test runner:** CLT-only — no XCTest/Testing module. Tests are `xxxFailures() -> [String]` check groups aggregated in `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (`@main`), run with `swift run OpenWhispererKitTests` (exits non-zero on any failure).
- **Hook tests:** pytest under `tests/` (shell out to the hooks via `subprocess`), run with `pytest`.
- **App Support dir:** `~/Library/Application Support/OpenWhisperer` (mode `0700`), referenced in Swift via `Paths`.
- **Signal ordering:** the app MUST write `voice_turn` BEFORE posting the auto-submit Enter, so the signal exists when `UserPromptSubmit` fires.
- **Freshness window:** `300` seconds (constant in both the UPS hook and Codex hook).
- **Nudge:** injected as `hookSpecificOutput.additionalContext` with `suppressOutput: true` (visible to the model, hidden from the transcript).
- **Speak rule:** always the first paragraph (markdown-stripped, capped ~600 chars at a sentence boundary). `voice_detail` ∈ {`terse`, `natural`(default), `rich`, …} shapes ONLY the nudge wording; the Stop hook never reads it.
- **Hash parity:** `VoiceSignal.canonicalHash` (Swift) and `printf '%s' "<trimmed>" | shasum -a 256` (bash) MUST agree — SHA-256 over the same trimmed UTF-8 bytes, lowercase hex.
- **Do not regress playback:** the streaming player, afplay fallback, `tts_hook.lockdir` lock, `tts_hook.pid`, and barge-in stay intact. The voice-turn gate runs BEFORE the kill-prior block so a non-voice turn never interrupts an in-progress reply.
- **Scope:** Claude Code gets the full handshake + nudge. Codex gets signal-gated first-paragraph speak (anonymous, single-session), NO nudge.

---

### Task 1: `VoiceSignal` canonical hashing (OpenWhispererKit)

**Files:**
- Create: `app/Sources/OpenWhispererKit/VoiceSignal.swift`
- Create: `app/Tests/OpenWhispererKitTests/VoiceSignalChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (wire the new check group into `@main`)

**Interfaces:**
- Produces: `VoiceSignal.canonicalHash(_ text: String) -> String` (lowercase hex SHA-256 of the whitespace/newline-trimmed UTF-8 bytes); `VoiceSignal.signalContents(hash: String, timestamp: Int) -> String` (the `voice_turn` file body: `"<hash>\n<ts>\n"`).
- Consumes: nothing.

- [ ] **Step 1: Write the failing check group**

Create `app/Tests/OpenWhispererKitTests/VoiceSignalChecks.swift`:

```swift
import OpenWhispererKit

/// Checks for `VoiceSignal`. Parity-critical: these hashes MUST equal what
/// `shasum -a 256` produces for the same trimmed bytes (see tests/test_voice_context.py).
func voiceSignalFailures() -> [String] {
    var failures: [String] = []

    func expectHash(_ input: String, _ expected: String, _ name: String) {
        let r = VoiceSignal.canonicalHash(input)
        if r != expected {
            failures.append("VoiceSignal.\(name): canonicalHash(\(input.debugDescription)) -> \(r); expected \(expected)")
        }
    }

    // Known SHA-256 vectors (verify: `printf '%s' 'hello' | shasum -a 256`).
    expectHash("hello", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "knownVectorHello")
    // Surrounding whitespace/newlines must not change the hash.
    expectHash("  hello\n", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "trimsWhitespace")
    // Empty after trim → SHA-256 of "".
    expectHash("   \n  ", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "emptyAfterTrim")

    // signalContents formatting.
    let body = VoiceSignal.signalContents(hash: "abc", timestamp: 1700000000)
    if body != "abc\n1700000000\n" {
        failures.append("VoiceSignal.signalContents: got \(body.debugDescription); expected \"abc\\n1700000000\\n\"")
    }

    return failures
}
```

Wire it into the runner — in `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift`, add the line marked `+`:

```swift
        var failures: [String] = []
        failures += submitTriggerFailures()
        failures += pcmConversionFailures()
+       failures += voiceSignalFailures()
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: FAIL to **build** ("cannot find 'VoiceSignal' in scope") — `VoiceSignal` does not exist yet.

- [ ] **Step 3: Implement `VoiceSignal`**

Create `app/Sources/OpenWhispererKit/VoiceSignal.swift`:

```swift
import Foundation
import CryptoKit

/// Shared, dependency-free helpers for the voice-turn handshake between the
/// dictation app (signal writer) and the Claude Code hooks (signal readers).
///
/// The app records a hash of the exact text it dictated; the UserPromptSubmit
/// hook recomputes the hash of the prompt it receives and, on a match, knows
/// THIS session is the voice turn. Canonicalization lives here (and is unit
/// tested) to guard parity with the bash reader (`shasum -a 256`).
public enum VoiceSignal {

    /// Lowercase-hex SHA-256 of `text` after trimming leading/trailing
    /// whitespace and newlines. MUST match: `printf '%s' "<trimmed>" | shasum -a 256`.
    public static func canonicalHash(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `voice_turn` file body: line 1 = hash, line 2 = unix seconds.
    public static func signalContents(hash: String, timestamp: Int) -> String {
        "\(hash)\n\(timestamp)\n"
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: PASS — prints `✅ OpenWhispererKit: all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhispererKit/VoiceSignal.swift \
        app/Tests/OpenWhispererKitTests/VoiceSignalChecks.swift \
        app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(voice): add VoiceSignal canonical hash for voice-turn handshake"
```

---

### Task 2: App writes the `voice_turn` signal on dictation

**Files:**
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (add `voiceTurn`, `speakPendingDir`)
- Modify: `app/Sources/OpenWhisperer/DictationManager.swift` (write the signal at the top of `insertText(_:intoPID:forceSubmit:completion:)`)

**Interfaces:**
- Consumes: `VoiceSignal.canonicalHash`, `VoiceSignal.signalContents` (Task 1), `Paths.voiceTurn`.
- Produces: `~/Library/Application Support/OpenWhisperer/voice_turn` = `"<hash>\n<unix-seconds>\n"` on every dictation insertion (the single funnel `insertText`, used by both push-to-talk and hands-free).

- [ ] **Step 1: Add `Paths` entries**

In `app/Sources/OpenWhisperer/Paths.swift`, after the `voiceDetail` entry, add:

```swift
    /// Voice-turn signal (hash + unix timestamp) written by the app on each
    /// dictation; read & claimed by the UserPromptSubmit hook (voice-context.sh).
    static let voiceTurn = appSupport.appendingPathComponent("voice_turn")

    /// Per-session "speak this turn" markers: speak_pending/<session_id>.
    /// Created by the UPS hook on a voice-turn claim, consumed by the Stop hook.
    static let speakPendingDir = appSupport.appendingPathComponent("speak_pending")
```

- [ ] **Step 2: Write the signal in `insertText`**

In `app/Sources/OpenWhisperer/DictationManager.swift`:

1. Ensure the file imports the Kit module — add `import OpenWhispererKit` near the top if not already present.
2. At the very top of `insertText(_ text: String, intoPID pid: pid_t, forceSubmit: Bool = false, completion: @escaping () -> Void)`, immediately after the `dispatchPrecondition(condition: .onQueue(.main))` line, insert:

```swift
        // Record the voice-turn signal so the UserPromptSubmit hook can recognise
        // THIS dictation as the voice turn (content-correlation). Written BEFORE the
        // auto-submit Enter so the signal exists when the hook fires.
        let voiceHash = VoiceSignal.canonicalHash(text)
        let voiceTS = Int(Date().timeIntervalSince1970)
        try? VoiceSignal.signalContents(hash: voiceHash, timestamp: voiceTS)
            .write(to: Paths.voiceTurn, atomically: true, encoding: .utf8)
```

- [ ] **Step 3: Build**

Run: `cd app && swift build`
Expected: builds cleanly.

- [ ] **Step 4: Manual verification**

Run the app, dictate "hello" into any window, then:

Run: `cat ~/Library/Application\ Support/OpenWhisperer/voice_turn`
Expected: two lines — `2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824` then a unix timestamp. (Hash matches Task 1's `hello` vector, confirming Swift↔bash parity.)

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/Paths.swift app/Sources/OpenWhisperer/DictationManager.swift
git commit -m "feat(voice): write voice_turn signal on every dictation insert"
```

---

### Task 3: `first-paragraph.sh` extractor

**Files:**
- Create: `hooks/first-paragraph.sh`
- Create: `tests/test_first_paragraph.py`

**Interfaces:**
- Consumes: raw assistant message (markdown) on stdin.
- Produces: the spoken first paragraph on stdout — leading code fences/headings/table rows skipped, first prose block taken up to the first blank line, inline markdown/links/URLs stripped, capped ~600 chars at a sentence boundary. Empty stdout if no prose paragraph.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_first_paragraph.py`:

```python
import subprocess
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "first-paragraph.sh"


def first_para(text: str) -> str:
    out = subprocess.run([str(HOOK)], input=text, capture_output=True, text=True)
    return out.stdout


def test_single_paragraph_plain():
    assert first_para("Fixed it. Tests pass now.\n") == "Fixed it. Tests pass now."


def test_stops_at_blank_line():
    assert first_para("First line stays.\n\nSecond paragraph dropped.\n") == "First line stays."


def test_skips_leading_code_fence():
    md = "```swift\nlet x = 1\n```\n\nThe real summary sentence.\n"
    assert first_para(md) == "The real summary sentence."


def test_skips_leading_heading():
    assert first_para("## Result\nDone and verified.\n") == "Done and verified."


def test_strips_inline_markdown_and_links():
    md = "Updated **auth** in `login.swift` see [docs](http://x.io/y) now.\n"
    assert first_para(md) == "Updated auth in login.swift see docs now."


def test_empty_when_no_prose():
    assert first_para("```\ncode only\n```\n") == ""


def test_caps_long_paragraph_at_sentence_boundary():
    long = ("Sentence one is here. " * 40).strip() + "\n"
    out = first_para(long)
    assert len(out) <= 600
    assert out.endswith(".")
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_first_paragraph.py -v`
Expected: FAIL — `hooks/first-paragraph.sh` does not exist (FileNotFoundError / non-zero).

- [ ] **Step 3: Implement the extractor**

Create `hooks/first-paragraph.sh` (and `chmod +x`):

```bash
#!/bin/bash
# Reads a markdown assistant message on stdin; prints the spoken first paragraph.
export LANG="${LANG:-en_US.UTF-8}"

TEXT=$(cat)

# 1) Take the first prose paragraph: drop fenced code blocks + their content,
#    drop heading and table lines, de-bullet list items, and stop at the first
#    blank line after prose has started.
PARA=$(printf '%s\n' "$TEXT" | awk '
  /^[[:space:]]*```/ { infence = !infence; next }   # toggle + drop fence lines
  infence { next }                                  # drop fenced content
  /^[[:space:]]*#/  { next }                         # drop ATX headings
  /^[[:space:]]*\|/ { next }                          # drop table rows
  {
    line = $0
    sub(/^[[:space:]]*[-*+][[:space:]]+/, "", line)        # de-bullet
    sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", line)     # de-number
    if (line ~ /^[[:space:]]*$/) { if (started) exit; else next }
    started = 1
    print line
  }
')

# 2) Strip inline markdown / links / URLs, join lines, collapse whitespace.
SPEECH=$(printf '%s\n' "$PARA" | \
  sed -E 's/`([^`]*)`/\1/g; s/\*\*//g; s/\*//g' | \
  sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | \
  sed -E 's|https?://[^ ]*||g' | \
  tr '\n' ' ' | \
  sed -E 's/  */ /g; s/^ *//; s/ *$//')

# 3) Cap at ~600 chars on a sentence boundary.
if [ ${#SPEECH} -gt 600 ]; then
  SPEECH="${SPEECH:0:600}"
  SPEECH=$(printf '%s' "$SPEECH" | sed -E 's/([.!?])[^.!?]*$/\1/')
fi

printf '%s' "$SPEECH"
```

- [ ] **Step 4: Run to verify it passes**

Run: `chmod +x hooks/first-paragraph.sh && pytest tests/test_first_paragraph.py -v`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add hooks/first-paragraph.sh tests/test_first_paragraph.py
git commit -m "feat(voice): add first-paragraph extractor for spoken output"
```

---

### Task 4: `voice-context.sh` UserPromptSubmit hook (Claude Code)

**Files:**
- Create: `hooks/voice-context.sh`
- Create: `tests/test_voice_context.py`

**Interfaces:**
- Consumes: `UserPromptSubmit` JSON on stdin (`.prompt`, `.session_id`); `voice_turn` (written by Task 2); `voice_detail`.
- Produces: on a hash match — deletes/claims `voice_turn`, creates `speak_pending/<sanitized session_id>`, and prints `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<nudge>"},"suppressOutput":true}`. On no match / no signal — exits 0 with no output.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_voice_context.py`:

```python
import hashlib
import json
import subprocess
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "voice-context.sh"


def run_hook(input_obj, app_support, voice_turn_text=None, ts=None, detail=None):
    """Run voice-context.sh with HOME pointed at a temp dir; return (stdout, app_support)."""
    appdir = app_support / "Library" / "Application Support" / "OpenWhisperer"
    appdir.mkdir(parents=True, exist_ok=True)
    if voice_turn_text is not None:
        h = hashlib.sha256(voice_turn_text.strip().encode()).hexdigest()
        t = ts if ts is not None else _now(app_support)
        (appdir / "voice_turn").write_text(f"{h}\n{t}\n")
    if detail is not None:
        (appdir / "voice_detail").write_text(detail)
    proc = subprocess.run(
        [str(HOOK)], input=json.dumps(input_obj),
        capture_output=True, text=True,
        env={"HOME": str(app_support), "PATH": "/usr/bin:/bin:/usr/local/bin"},
    )
    return proc.stdout, appdir


def _now(app_support):
    return int(subprocess.run(["date", "+%s"], capture_output=True, text=True).stdout.strip())


def test_match_claims_and_marks(tmp_path):
    out, appdir = run_hook(
        {"prompt": "fix the login bug", "session_id": "abc-123"},
        tmp_path, voice_turn_text="fix the login bug",
    )
    assert (appdir / "speak_pending" / "abc-123").exists()      # session marked
    assert not (appdir / "voice_turn").exists()                 # signal claimed
    payload = json.loads(out)
    assert payload["suppressOutput"] is True
    assert payload["hookSpecificOutput"]["hookEventName"] == "UserPromptSubmit"
    assert "read aloud" in payload["hookSpecificOutput"]["additionalContext"]


def test_no_match_leaves_signal_and_is_silent(tmp_path):
    out, appdir = run_hook(
        {"prompt": "something I typed", "session_id": "abc-123"},
        tmp_path, voice_turn_text="fix the login bug",
    )
    assert out == ""                                            # no nudge
    assert not (appdir / "speak_pending" / "abc-123").exists()  # not marked
    assert (appdir / "voice_turn").exists()                     # signal preserved for the real session


def test_no_signal_is_silent(tmp_path):
    out, appdir = run_hook(
        {"prompt": "anything", "session_id": "abc-123"}, tmp_path,
    )
    assert out == ""
    assert not (appdir / "speak_pending").exists()


def test_stale_signal_rejected(tmp_path):
    out, appdir = run_hook(
        {"prompt": "fix the login bug", "session_id": "abc-123"},
        tmp_path, voice_turn_text="fix the login bug", ts=1,  # ancient
    )
    assert out == ""
    assert not (appdir / "voice_turn").exists()                 # stale signal swept


def test_session_id_sanitized_in_filename(tmp_path):
    out, appdir = run_hook(
        {"prompt": "go", "session_id": "a/b c:d"},
        tmp_path, voice_turn_text="go",
    )
    assert (appdir / "speak_pending" / "a_b_c_d").exists()


def test_terse_detail_changes_nudge(tmp_path):
    out, _ = run_hook(
        {"prompt": "go", "session_id": "s1"},
        tmp_path, voice_turn_text="go", detail="terse",
    )
    assert "one short, plain spoken sentence" in json.loads(out)["hookSpecificOutput"]["additionalContext"]
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_voice_context.py -v`
Expected: FAIL — `hooks/voice-context.sh` does not exist.

- [ ] **Step 3: Implement the hook**

Create `hooks/voice-context.sh` (and `chmod +x`):

```bash
#!/bin/bash
# UserPromptSubmit hook (Claude Code) — voice-turn detection via content-correlation.
# If the submitted prompt matches the hash the app recorded for the last dictation,
# THIS session is the voice turn: nudge the model (hidden from the transcript) and
# mark the session so the Stop hook speaks the reply's first paragraph.
export LANG="${LANG:-en_US.UTF-8}"

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VOICE_TURN="$APP_SUPPORT/voice_turn"
PENDING_DIR="$APP_SUPPORT/speak_pending"
FRESHNESS=300

# Fast path for typed turns: no pending dictation → nothing to do.
[ -f "$VOICE_TURN" ] || exit 0

# Find jq (system, then bundled next to the hooks dir).
if ! command -v jq >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else exit 0; fi
fi

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -z "$PROMPT" ] && exit 0
[ -z "$SESSION_ID" ] && exit 0

STORED_HASH=$(sed -n '1p' "$VOICE_TURN" 2>/dev/null)
STORED_TS=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
[ -z "$STORED_HASH" ] && exit 0

# Freshness: drop a stale signal and bail.
NOW=$(date +%s)
if [ -n "$STORED_TS" ] && [ "$((NOW - STORED_TS))" -gt "$FRESHNESS" ]; then
  rm -f "$VOICE_TURN"
  exit 0
fi

# Hash the trimmed prompt — must match VoiceSignal.canonicalHash.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
TRIMMED=$(trim "$PROMPT")
if command -v shasum >/dev/null 2>&1; then
  PROMPT_HASH=$(printf '%s' "$TRIMMED" | shasum -a 256 | awk '{print $1}')
else
  PROMPT_HASH=$(printf '%s' "$TRIMMED" | openssl dgst -sha256 | awk '{print $NF}')
fi
[ "$PROMPT_HASH" = "$STORED_HASH" ] || exit 0   # not the voice turn

# Atomic claim: only one session wins even if two submit identical text.
CLAIM="$APP_SUPPORT/.voice_turn.claimed.$$"
mv "$VOICE_TURN" "$CLAIM" 2>/dev/null || exit 0
rm -f "$CLAIM"

# Mark this session for the Stop hook.
mkdir -p "$PENDING_DIR"
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_.-' '_')
: > "$PENDING_DIR/$SAFE_ID"

# Nudge verbosity from voice_detail (shapes only the nudge; Stop speaks the first paragraph).
DETAIL=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
case "$DETAIL" in
  terse) LEN="one short, plain spoken sentence" ;;
  rich)  LEN="a sentence or two of plain spoken summary" ;;
  *)     LEN="one plain spoken sentence" ;;
esac
NUDGE="This turn was dictated by voice and your reply will be read aloud. Open with ${LEN} that stands alone as a summary; details can follow."

# additionalContext is visible to the model; suppressOutput keeps it out of the transcript.
jq -n --arg ctx "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}'
exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `chmod +x hooks/voice-context.sh && pytest tests/test_voice_context.py -v`
Expected: PASS (6 tests). This also confirms bash `shasum` parity with Python `hashlib.sha256` (and thus with `VoiceSignal`).

- [ ] **Step 5: Commit**

```bash
git add hooks/voice-context.sh tests/test_voice_context.py
git commit -m "feat(voice): add UserPromptSubmit hook for content-correlated voice turns"
```

---

### Task 5: `tts-hook.sh` — voice-turn gate + first-paragraph speak

**Files:**
- Modify: `hooks/tts-hook.sh`
- Create: `tests/test_tts_hook_gate.py`

**Interfaces:**
- Consumes: `Stop` JSON on stdin (`.stop_hook_active`, `.session_id`, `.last_assistant_message`); `speak_pending/<session_id>` (Task 4); `hooks/first-paragraph.sh` (Task 3).
- Produces: speaks the first paragraph via the EXISTING playback path only if `speak_pending/<session_id>` exists; otherwise exits 0 without acquiring the lock or killing prior playback. Deletes the marker after consuming; sweeps markers older than 5 min.

- [ ] **Step 1: Write the failing gate test**

Create `tests/test_tts_hook_gate.py` (verifies the gate WITHOUT real TTS — a non-voice turn must not touch the lock/pid; a voice turn with no TTS server must consume the marker and not hang):

```python
import json
import subprocess
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "tts-hook.sh"


def run(input_obj, home):
    appdir = home / "Library" / "Application Support" / "OpenWhisperer"
    appdir.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [str(HOOK)], input=json.dumps(input_obj), capture_output=True, text=True,
        env={"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/local/bin",
             "TTS_URL": "http://localhost:1/v1/audio/speech"},  # unreachable
        timeout=20,
    )
    return proc, appdir


def test_no_marker_exits_without_locking(tmp_path):
    proc, appdir = run({"session_id": "s1", "last_assistant_message": "Hi there."}, tmp_path)
    assert proc.returncode == 0
    assert not (appdir / "tts_hook.lockdir").exists()   # never acquired the lock
    assert not (appdir / "tts_hook.pid").exists()


def test_marker_consumed_when_present(tmp_path):
    appdir = tmp_path / "Library" / "Application Support" / "OpenWhisperer"
    (appdir / "speak_pending").mkdir(parents=True)
    (appdir / "speak_pending" / "s1").touch()
    proc, appdir = run({"session_id": "s1", "last_assistant_message": "Done and verified."}, tmp_path)
    assert proc.returncode == 0
    assert not (appdir / "speak_pending" / "s1").exists()   # marker consumed


def test_stop_hook_active_is_ignored(tmp_path):
    proc, appdir = run({"stop_hook_active": True, "session_id": "s1",
                        "last_assistant_message": "x"}, tmp_path)
    assert proc.returncode == 0
    assert not (appdir / "tts_hook.lockdir").exists()
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_tts_hook_gate.py -v`
Expected: FAIL — current `tts-hook.sh` ignores `speak_pending` and acquires the lock unconditionally, so `test_no_marker_exits_without_locking` fails.

- [ ] **Step 3: Reorder the top of `tts-hook.sh`**

In `hooks/tts-hook.sh`, **replace the block from the lock-acquisition comment through the `SPEECH` guard** (currently `# Serialize concurrent hook invocations …` down to the `[ -z "$SPEECH" ] && exit 0` that precedes `# Lock AFTER validation`) with the following. Lines 1–24 (shebang/vars/jq) and everything from `touch "$LOCKFILE"` onward stay unchanged.

```bash
INPUT=$(cat)

# Prevent loops
if [ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active')" = "true" ]; then
  exit 0
fi

# --- Voice-turn gate (runs BEFORE we kill prior playback, so a typed/non-voice
#     turn never interrupts an in-progress voice reply) ---
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0
PENDING_DIR="$APP_SUPPORT/speak_pending"
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_.-' '_')
PENDING="$PENDING_DIR/$SAFE_ID"
# Sweep markers orphaned by sessions that died between prompt and response.
find "$PENDING_DIR" -type f -mmin +5 -delete 2>/dev/null
# Only speak if THIS session was marked a voice turn by the UPS hook.
[ -f "$PENDING" ] || exit 0
rm -f "$PENDING"

# Serialize concurrent hook invocations with mkdir-based lock (atomic on all filesystems)
HOOK_LOCK="$APP_SUPPORT/tts_hook.lockdir"
if [ -d "$HOOK_LOCK" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$HOOK_LOCK" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -gt 30 ]; then rm -rf "$HOOK_LOCK"; fi
fi
LOCK_ACQUIRED=false
for _try in 1 2 3; do
  if mkdir "$HOOK_LOCK" 2>/dev/null; then LOCK_ACQUIRED=true; break; fi
  sleep 0.1
done
trap 'rm -rf "$HOOK_LOCK"' EXIT
if [ "$LOCK_ACQUIRED" = "false" ]; then exit 0; fi

# Kill any previous TTS playback (validate PID before killing)
if [ -f "$PIDFILE" ] && [ ! -L "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    OLD_COMM=$(ps -p "$OLD_PID" -o comm= 2>/dev/null)
    if [[ "$OLD_COMM" == *"bash"* ]] || [[ "$OLD_COMM" == *"afplay"* ]] || [[ "$OLD_COMM" == *"python"* ]]; then
      pkill -INT -P "$OLD_PID" 2>/dev/null
      kill "$OLD_PID" 2>/dev/null
      pkill -P "$OLD_PID" 2>/dev/null
    fi
    pkill -f tts_stream_player 2>/dev/null
  fi
  find "$TTS_TMPDIR" -name "tts_*" -mmin +1 -delete 2>/dev/null
  rm -f "$PIDFILE"
fi

# Extract the FIRST PARAGRAPH of the response (markdown-stripped) as the spoken text.
TEXT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')
[ -z "$TEXT" ] && exit 0
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/first-paragraph.sh")
[ -z "$SPEECH" ] && exit 0
```

(The original `# Lock AFTER validation — only when we know we'll play audio` / `touch "$LOCKFILE"` line and the entire streaming/afplay playback section below it remain exactly as-is.)

- [ ] **Step 4: Run to verify it passes**

Run: `pytest tests/test_tts_hook_gate.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add hooks/tts-hook.sh tests/test_tts_hook_gate.py
git commit -m "feat(voice): gate tts-hook on speak_pending + speak first paragraph"
```

---

### Task 6: `codex-tts-hook.sh` — signal-gated first-paragraph (no nudge)

**Files:**
- Modify: `hooks/codex-tts-hook.sh`

**Interfaces:**
- Consumes: Codex notify JSON (`.type == "agent-turn-complete"`, `.["last-assistant-message"]`); `voice_turn` (Task 2); `hooks/first-paragraph.sh`.
- Produces: speaks the first paragraph only if `voice_turn` exists and is fresh; clears `voice_turn` on claim. Codex has no per-prompt `session_id` in the notify payload, so this is the anonymous, single-session timestamp gate (no hash match, no nudge).

- [ ] **Step 1: Reorder + gate**

In `hooks/codex-tts-hook.sh`:

1. Move the `INPUT` capture + `TYPE` parse (currently after the kill-prior block) to run **before** the kill-prior block. Specifically, relocate:

```bash
# Codex notify: JSON payload comes as the last CLI argument
INPUT="${!#}"
if [ -z "$INPUT" ] || [ "$INPUT" = "$0" ]; then INPUT=$(cat); fi
[ -z "$INPUT" ] && exit 0
TYPE=$(echo "$INPUT" | jq -r '.type // empty' 2>/dev/null)
if [ "$TYPE" != "agent-turn-complete" ] && [ -n "$TYPE" ]; then exit 0; fi
```

   to just after the `HOOK_LOCK` acquisition (`if [ "$LOCK_ACQUIRED" = "false" ]; then exit 0; fi`) and **before** the `# Kill any previous TTS playback` block.

2. Immediately after that relocated block, insert the voice-turn gate (before kill-prior):

```bash
# --- Voice-turn gate: only speak dictated turns. Codex has no per-prompt session id,
#     so gate on the app's voice_turn signal (presence + freshness) and clear it. ---
VOICE_TURN="$APP_SUPPORT/voice_turn"
VOICE_FRESHNESS=300
[ -f "$VOICE_TURN" ] || exit 0
VT_TS=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
NOW=$(date +%s)
if [ -n "$VT_TS" ] && [ "$((NOW - VT_TS))" -gt "$VOICE_FRESHNESS" ]; then
  rm -f "$VOICE_TURN"; exit 0
fi
rm -f "$VOICE_TURN"   # claim: this turn is spoken, future typed turns are not
```

3. Replace the `[VOICE: ...]` extraction + fallback block (the `SPEECH=$(echo "$TEXT" | sed -n -E 's/.*\[VOICE: ...` block through its `if [ ${#SPEECH} -gt 600 ] ... fi`) with:

```bash
TEXT=$(echo "$INPUT" | jq -r '.["last-assistant-message"] // .last_assistant_message // empty' 2>/dev/null)
[ -z "$TEXT" ] && exit 0
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/first-paragraph.sh")
[ -z "$SPEECH" ] && exit 0
```

   (Delete the now-duplicate `TEXT=` / `TYPE=` lines that were below the kill-prior block.)

- [ ] **Step 2: Smoke test**

With the TTS server running, set `selected_platform` to Codex, dictate a prompt into a Codex CLI session, and confirm the first paragraph is spoken once and `voice_turn` is cleared:

Run: `ls ~/Library/Application\ Support/OpenWhisperer/voice_turn 2>/dev/null && echo PRESENT || echo CLEARED`
Expected: `CLEARED` after the turn completes. A subsequent typed Codex turn produces no speech.

- [ ] **Step 3: Commit**

```bash
git add hooks/codex-tts-hook.sh
git commit -m "feat(voice): gate codex hook on voice_turn + speak first paragraph"
```

---

### Task 7: Migration helper + `ConfigManager` rewiring

**Files:**
- Create: `app/Sources/OpenWhispererKit/VoiceMigration.swift`
- Create: `app/Tests/OpenWhispererKitTests/VoiceMigrationChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (wire check group)
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift`
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (bundled hook paths)

**Interfaces:**
- Produces: `VoiceMigration.stripVoiceBlock(from: String) -> String` (pure: removes the `## Voice Mode` section, same semantics as the old private `removeVoiceBlock`); `ConfigManager.applyHookToSettings()` now also registers the `UserPromptSubmit` hook; `ConfigManager.migrateRemoveVoiceTags()` strips the old block from `~/.claude/CLAUDE.md` and `~/.codex/instructions.md`; `Paths.voiceContextHook`, `Paths.firstParagraphScript`.
- Consumes: `Paths.claudeSettings`, `Paths.voiceContextHook`.

- [ ] **Step 1: Write the failing migration check**

Create `app/Tests/OpenWhispererKitTests/VoiceMigrationChecks.swift`:

```swift
import OpenWhispererKit

func voiceMigrationFailures() -> [String] {
    var failures: [String] = []

    func expect(_ input: String, _ expected: String, _ name: String) {
        let r = VoiceMigration.stripVoiceBlock(from: input)
        if r != expected {
            failures.append("VoiceMigration.\(name): got \(r.debugDescription); expected \(expected.debugDescription)")
        }
    }

    expect("# Project\n\n## Voice Mode\nALWAYS include a [VOICE: ...] tag.\n\nExample: x",
           "# Project",
           "stripsVoiceSectionToEOF")
    expect("# A\n\n## Voice Mode\nblah\n\n## Keep Me\nkept",
           "# A\n\n## Keep Me\nkept",
           "stopsAtNextHeading")
    expect("# No voice here\njust text",
           "# No voice here\njust text",
           "leavesUnrelatedContentUnchanged")

    return failures
}
```

Wire `failures += voiceMigrationFailures()` into `SubmitTriggerTests.swift` (same `@main` block as Task 1).

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: FAIL to build — `VoiceMigration` not in scope.

- [ ] **Step 3: Implement `VoiceMigration`**

Create `app/Sources/OpenWhispererKit/VoiceMigration.swift` (lift the existing `removeVoiceBlock` logic verbatim into a pure, public helper):

```swift
import Foundation

/// One-shot migration helper: removes the legacy `## Voice Mode` block that the
/// app used to inject into CLAUDE.md / AGENTS.md. Pure so it is unit-tested.
public enum VoiceMigration {

    /// Remove the `## Voice Mode` section (header through the next `## ` or EOF),
    /// then strip trailing blank lines.
    public static func stripVoiceBlock(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var skipping = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("## Voice Mode") {
                skipping = true
                continue
            }
            if skipping && line.trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                skipping = false
            }
            if !skipping { result.append(line) }
        }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: PASS.

- [ ] **Step 5: Add bundled hook paths**

In `app/Sources/OpenWhisperer/Paths.swift`, after the `ttsHook` entry, add:

```swift
    /// Bundled UserPromptSubmit hook (Claude Code voice-turn detection)
    static let voiceContextHook = resources.appendingPathComponent("hooks").appendingPathComponent("voice-context.sh")

    /// Bundled first-paragraph extractor used by the Stop hooks
    static let firstParagraphScript = resources.appendingPathComponent("hooks").appendingPathComponent("first-paragraph.sh")
```

- [ ] **Step 6: Register the UPS hook in `applyHookToSettings`**

In `app/Sources/OpenWhisperer/ConfigManager.swift`, inside `applyHookToSettings()`, after the `Stop` array is rebuilt and before writing back (`hooks["Stop"] = stopArray`), add a sibling `UserPromptSubmit` registration:

```swift
        // Register the UserPromptSubmit voice-turn hook (idempotent: drop our old entries first).
        var upsArray = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
        upsArray.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { (($0["command"] as? String).map(isOurHook) ?? false) }
        }
        let upsHook: [String: Any] = ["type": "command", "command": Paths.voiceContextHook.path]
        upsArray.append(["hooks": [upsHook]])
        hooks["UserPromptSubmit"] = upsArray
```

Add `"voice-context.sh"` to the `hookPatterns` array (so `isOurHook` recognises and de-dupes it):

```swift
    private static let hookPatterns = [
        "tts-hook.sh",
        "voice-context.sh",
        "Open Whisperer",
        "OpenWhisperer",
        "mlx-openai-whisper",
    ]
```

- [ ] **Step 7: Add the migration entry point + remove the injection**

In `ConfigManager.swift`:

1. Add a migration function:

```swift
    /// One-shot cleanup for existing installs: strip the legacy `## Voice Mode`
    /// block from the user's CLAUDE.md and Codex instructions.md.
    static func migrateRemoveVoiceTags() {
        let targets = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/instructions.md"),
        ]
        for url in targets {
            guard let existing = try? String(contentsOf: url, encoding: .utf8),
                  existing.contains("[VOICE:") || existing.contains("## Voice Mode") else { continue }
            let cleaned = VoiceMigration.stripVoiceBlock(from: existing).trimmingCharacters(in: .whitespacesAndNewlines)
            try? (cleaned + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
```

2. Delete the now-dead injection API: `applyClaudeMd`, `applyAgentsMd`, `voiceBlockForDetail`, `removeVoiceBlock` (replaced by `VoiceMigration.stripVoiceBlock`), `showClaudeMdInstructions`, `showCodexAgentsMdInstructions`, `checkClaudeMdConfigured`, `checkCodexAgentsMdConfigured`, `applyVoiceTag(for:)`, `checkVoiceTagConfigured(for:)`, `showVoiceTagInstructions(for:)`. (Their only callers are in `MenuBarView.swift`, handled in Task 8 — do Task 8 in the same branch so the build stays green; if implementing incrementally, comment out the calls in `MenuBarView.swift` first.)

3. Call `migrateRemoveVoiceTags()` once at app launch — add it next to the existing setup/`applyHookToSettings` call sites in `AppDelegate` / `SetupManager` (grep `applyHookToSettings(` to find where hooks are applied and call `migrateRemoveVoiceTags()` alongside).

- [ ] **Step 8: Build + test**

Run: `cd app && swift run OpenWhispererKitTests && swift build`
Expected: checks pass; build is green once Task 8's UI edits land (build `OpenWhispererKitTests` alone passes immediately).

- [ ] **Step 9: Commit**

```bash
git add app/Sources/OpenWhispererKit/VoiceMigration.swift \
        app/Tests/OpenWhispererKitTests/VoiceMigrationChecks.swift \
        app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift \
        app/Sources/OpenWhisperer/ConfigManager.swift \
        app/Sources/OpenWhisperer/Paths.swift
git commit -m "feat(voice): register UPS hook, add CLAUDE.md voice-block migration"
```

---

### Task 8: MenuBar / setup UI cleanup

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift`

**Interfaces:**
- Consumes: `Paths.voiceDetail` (kept — now feeds the nudge), `ConfigManager.checkHookConfigured(for:)`.
- Removes UI dependence on the deleted voice-tag API (`applyVoiceTag`, `showVoiceTagInstructions`, `checkVoiceTagConfigured`).

The grep of `phase1-native-stt` shows these call sites to update:
- `MenuBarView.swift:218` — reads `Paths.voiceDetail` into UI state: **keep** (the control now tunes the nudge).
- `MenuBarView.swift:503` — writes `Paths.voiceDetail` on change: **keep**.
- `MenuBarView.swift:505` — `ConfigManager.applyVoiceTag(for:forceUpdate:true)` after writing detail: **delete** (no file to rewrite — the nudge is read live by the hook).
- `MenuBarView.swift:682` — `onTapGesture { ConfigManager.showVoiceTagInstructions(...) }`: **delete** that row, or repoint to the hook-install status.
- `MenuBarView.swift:686` — `ConfigManager.applyVoiceTag(...)`: **delete** the "apply voice tag" button/action.
- `MenuBarView.swift:933` — `claudeMdApplied = ConfigManager.checkVoiceTagConfigured(...)`: **replace** with the hook-configured check: `voiceHookApplied = ConfigManager.checkHookConfigured(for: selectedPlatform)` (rename the `@State` accordingly), so the "voice" setup card now reflects "voice hook installed" rather than "CLAUDE.md tag present".

- [ ] **Step 1: Read the regions**

Read `app/Sources/OpenWhisperer/MenuBarView.swift` around lines 200–230, 490–520, 670–700, 920–940 to see the exact view code and `@State` names.

- [ ] **Step 2: Apply the edits**

Remove the voice-tag setup row/buttons (the CLAUDE.md/AGENTS.md "Voice Tag" step), keep the `voice_detail` picker (relabel its help text to "Spoken summary length" — it now shapes the nudge), and replace the `claudeMdApplied` state + check with a hook-configured check. The `voice_detail` write at `:503` stays; delete the `applyVoiceTag` call at `:505`.

- [ ] **Step 3: Build**

Run: `cd app && swift build`
Expected: builds cleanly (no remaining references to the deleted `ConfigManager` symbols — verify with `grep -rn 'applyVoiceTag\|showVoiceTagInstructions\|checkVoiceTagConfigured\|voiceBlockForDetail' app/Sources`, which must return nothing).

- [ ] **Step 4: Manual verification**

Launch the app: the voice settings card shows the spoken-length picker and a "voice hook installed" status; there is no "add to CLAUDE.md" step.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/MenuBarView.swift
git commit -m "feat(voice): drop voice-tag setup UI, repurpose detail picker for nudge"
```

---

### Task 9: Bundling + end-to-end verification

**Files:**
- Modify: the DMG/bundle build script (find it: `ls scripts/*build* scripts/*dmg* 2>/dev/null`; the streaming-TTS plan calls it `build-dmg.sh`)

**Interfaces:**
- Consumes: `hooks/voice-context.sh`, `hooks/first-paragraph.sh`.
- Produces: both scripts bundled into the app's `Resources/hooks/`, executable, matching `Paths.voiceContextHook` / `Paths.firstParagraphScript`.

- [ ] **Step 1: Bundle the new hooks**

In the bundle script, alongside where `tts-hook.sh` / `codex-tts-hook.sh` are copied into `Contents/Resources/hooks/`, add `voice-context.sh` and `first-paragraph.sh` (preserve the executable bit, e.g. `chmod +x`).

- [ ] **Step 2: Build the bundle**

Run the bundle script. Confirm:

Run: `ls -l <App>.app/Contents/Resources/hooks/`
Expected: `tts-hook.sh`, `codex-tts-hook.sh`, `voice-context.sh`, `first-paragraph.sh` all present and `+x`.

- [ ] **Step 3: End-to-end manual checklist**

With the TTS server running and the app installed (run `ConfigManager.applyHookToSettings()` via the setup UI so both `Stop` and `UserPromptSubmit` are registered, and `migrateRemoveVoiceTags()` has run):

- [ ] Dictate a request into a Claude Code session → the reply's **first paragraph** is spoken; the transcript shows **no** `[VOICE:]` tag and **no** visible nudge line.
- [ ] **Type** a request in the same session → **nothing** is spoken.
- [ ] Open two Claude Code tabs; dictate into one → only that session speaks.
- [ ] Dictate into session A (long reply), then dictate into session B → both queue; only one voice is audible at a time (newest barges in).
- [ ] Confirm `~/.claude/CLAUDE.md` no longer contains a `## Voice Mode` block.
- [ ] `voice_detail = terse` vs `rich` changes how long the spoken opener is.
- [ ] Edit a dictated prompt before submitting → that turn is **not** spoken (correct).

- [ ] **Step 4: Commit**

```bash
git add <bundle script>
git commit -m "build(voice): bundle voice-context.sh + first-paragraph.sh"
```

---

## Self-Review

**Spec coverage:** handshake (T1/T2/T4), first-paragraph speak (T3/T5), hidden nudge (T4), session routing via `speak_pending` (T4/T5), Codex parity no-nudge (T6), CLAUDE.md removal + migration (T7), `voice_detail` → nudge only (T4/T8), bundling (T9), concurrency gate-before-kill (T5). All spec sections map to a task.

**Open items intentionally deferred to implementation time (not placeholders):** exact `MenuBarView.swift` view code (Task 8 Step 1 reads the regions first — these are UI files not yet read, and the call sites are pinned by line number); the bundle script's exact name (Task 9 locates it). Both are concrete actions, not vague requirements.

**Type/name consistency:** `voice_turn`, `speak_pending/<session_id>`, `VoiceSignal.canonicalHash`, `VoiceSignal.signalContents`, `VoiceMigration.stripVoiceBlock`, `Paths.voiceTurn`, `Paths.speakPendingDir`, `Paths.voiceContextHook`, `Paths.firstParagraphScript`, freshness `300`, the `terse/natural/rich` nudge mapping, and `hookSpecificOutput.additionalContext + suppressOutput:true` are used identically across the app, both hooks, and the tests.
