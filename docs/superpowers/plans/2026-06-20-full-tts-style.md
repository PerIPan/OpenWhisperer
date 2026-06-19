# `full` TTS Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fourth spoken-summary style `full` that makes the model write its entire reply as speakable prose and the Stop hook speak the whole (markdown-stripped) reply, uncapped.

**Architecture:** The style already lives in synchronized places — the menubar picker, the nudge `case` in `voice-context.sh`, and (newly) the Stop hooks. `first-paragraph.sh` is renamed to `speakable-text.sh` and gains a `--full` mode (all paragraphs, no cap); the Stop hooks read the resolved style and pass `--full` when it is `full`; `voice-context.sh` swaps the whole nudge for `full`. The app is unchanged beyond one picker row — it synthesizes whatever text it is POSTed.

**Tech Stack:** Bash hooks (jq, awk, sed), Swift/SwiftUI app, plain-executable `HookTests` runner (no XCTest under Command Line Tools).

## Global Constraints

- macOS 14+, Apple Silicon, pure Swift + bash hooks. No new dependencies.
- No XCTest/swift-testing — `HookTests` is a `@main` executable aggregating `*Failures() -> [String]` groups; it `exit(1)` on any failure. Run: `swift run HookTests` from `app/`.
- The bash `shasum` hashing in `voice-context.sh` must stay byte-parity with `VoiceSignal.canonicalHash` — **this plan does not touch hashing/trimming.**
- Style values must stay synchronized across four sites: `MenuBarView.styleLevels`, `voice-context.sh` nudge `case`, the Stop hooks' style read (`tts-hook.sh`, `codex-tts-hook.sh`), and the `speakable-text.sh` modes.
- Commits: Conventional Commits (`type(scope): subject`, ≤72 incl. prefix), scope commonly `tts`. End every commit message with the trailer `Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U`. No `Co-Authored-By`.
- This is a PR-path change (multiple files, user-visible behavior). Per CLAUDE.md: work in a worktree off `main` (`.claude/worktrees/<slug>`), build + run both test runners, then open a PR.

---

## File Structure

- `hooks/first-paragraph.sh` → **rename** `hooks/speakable-text.sh` — spoken-text extractor, now two modes (default first-paragraph, `--full` whole body). Single home for the markdown-stripping rules.
- `hooks/tts-hook.sh`, `hooks/codex-tts-hook.sh` — Stop hooks: resolve style, call the extractor with/without `--full`.
- `hooks/voice-context.sh` — UserPromptSubmit hook: `full)` nudge branch.
- `app/Sources/OpenWhisperer/MenuBarView.swift` — add the `("full", "Full")` picker row.
- `app/Sources/OpenWhisperer/Paths.swift` — rename the (currently unused) `firstParagraphScript` constant + its path.
- `app/build-dmg.sh` — copy/chmod the renamed script into the bundle.
- `app/Tests/HookTests/FirstParagraphChecks.swift` → **rename** `SpeakableTextChecks.swift` (+ function rename in `main.swift`); add `--full` checks.
- `app/Tests/HookTests/HookHarness.swift` — extend `Hook.run` to pass script args.
- `app/Tests/HookTests/VoiceContextChecks.swift`, `TTSHookGateChecks.swift` — add `full` checks.
- `CLAUDE.md`, `README.md`, `app/Package.swift` — docs / comments.

> **Note — spec correction:** the spec said the rename ripples to "exactly the two Stop hooks and one test reference." It actually also touches `build-dmg.sh`, `Paths.swift` (an unused constant), `README.md`, and a `Package.swift` comment. All are mechanical and handled in Task 1.

---

## Task 1: Rename `first-paragraph.sh` → `speakable-text.sh` (no behavior change)

Pure rename so the suite stays green at this checkpoint. The `--full` behavior comes in Task 2.

**Files:**
- Rename: `hooks/first-paragraph.sh` → `hooks/speakable-text.sh`
- Modify: `hooks/tts-hook.sh:46`, `hooks/codex-tts-hook.sh:43`
- Modify: `app/build-dmg.sh:53,60`
- Modify: `app/Sources/OpenWhisperer/Paths.swift:22-23`
- Modify: `app/Package.swift:37` (comment), `README.md:238` (file-tree line)
- Rename: `app/Tests/HookTests/FirstParagraphChecks.swift` → `SpeakableTextChecks.swift`
- Modify: `app/Tests/HookTests/main.swift:7`

**Interfaces:**
- Produces: a hook script invoked as `speakable-text.sh` (stdin → stdout), unchanged default behavior; test group function `speakableTextFailures() -> [String]`.

- [ ] **Step 1: Rename the script (preserve history + mode)**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git mv hooks/first-paragraph.sh hooks/speakable-text.sh
```

- [ ] **Step 2: Update the two Stop hooks to call the new name**

In `hooks/tts-hook.sh`, change line 46:

```bash
SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh")
```

In `hooks/codex-tts-hook.sh`, change line 43:

```bash
SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh")
```

- [ ] **Step 3: Update the bundle copy in `app/build-dmg.sh`**

Line 53:

```bash
cp "$PROJECT_DIR/hooks/speakable-text.sh" "$APP_BUNDLE/Contents/Resources/hooks/"
```

Line 60:

```bash
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/speakable-text.sh"
```

- [ ] **Step 4: Rename the unused path constant in `app/Sources/OpenWhisperer/Paths.swift`**

Replace lines 22-23:

```swift
    /// Bundled spoken-text extractor used by the Stop hooks
    static let speakableTextScript = resources.appendingPathComponent("hooks").appendingPathComponent("speakable-text.sh")
```

(`firstParagraphScript` has no references in `app/Sources` — verified — so this is a safe rename.)

- [ ] **Step 5: Update the `Package.swift` comment and the README file-tree line**

`app/Package.swift:37`:

```swift
        // Integration tests for the bash hooks (Stop + UserPromptSubmit + speakable-text).
```

`README.md:238`:

```
│   └── speakable-text.sh     # Shared spoken-text extractor
```

- [ ] **Step 6: Rename the test file + function, update the script name it runs**

```bash
git mv app/Tests/HookTests/FirstParagraphChecks.swift app/Tests/HookTests/SpeakableTextChecks.swift
```

In `app/Tests/HookTests/SpeakableTextChecks.swift`, change the function name and the `Hook.run` script name (header comment too). The function becomes:

```swift
/// `speakable-text.sh` reads a markdown assistant message on stdin and prints spoken text:
/// the first prose paragraph by default (markdown stripped, ~600-char cap). Returns failures.
func speakableTextFailures() -> [String] {
    var failures: [String] = []
    let sandbox = Hook.Sandbox()
    defer { sandbox.cleanup() }

    func firstPara(_ input: String) -> String {
        Hook.run("speakable-text.sh", stdin: input, sandbox: sandbox).stdout
    }
    func expect(_ input: String, _ expected: String, _ name: String) {
        let r = firstPara(input)
        if r != expected {
            failures.append("speakable-text.\(name): got \(r.debugDescription), expected \(expected.debugDescription)")
        }
    }
```

Leave the existing `expect(...)` cases and the long-paragraph cap check as-is (update only the two failure-label prefixes `first-paragraph.capsLongParagraph` → `speakable-text.capsLongParagraph`).

- [ ] **Step 7: Update the runner in `app/Tests/HookTests/main.swift:7`**

```swift
failures += speakableTextFailures()
```

- [ ] **Step 8: Verify no stale references remain (outside docs prose handled later)**

Run:

```bash
cd /Users/hakanensari/code/OpenWhisperer
grep -rn "first-paragraph\|firstParagraph" --include="*.sh" --include="*.swift" hooks app/Sources app/Tests app/build-dmg.sh app/Package.swift README.md
```

Expected: **no output**. (Remaining `first-paragraph` lives only in `CLAUDE.md` prose, updated in Task 6.)

- [ ] **Step 9: Run the hook tests — behavior unchanged, all green**

Run:

```bash
cd app && swift run HookTests
```

Expected: `✅ HookTests: all checks passed`

- [ ] **Step 10: Commit**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git add -A
git commit -m "$(cat <<'EOF'
refactor(tts): rename first-paragraph.sh to speakable-text.sh

The extractor will gain a whole-reply mode, so the name "first paragraph"
no longer fits. Pure rename across hooks, build, paths, and tests.

Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U
EOF
)"
```

---

## Task 2: Add `--full` mode to `speakable-text.sh`

The extractor learns a second mode: all prose paragraphs, no cap, paragraph breaks kept as newlines (the app's `SentenceSplitter` flushes on `\n`). Code/headings/tables are still dropped — a code block can't be spoken even in `full`.

**Files:**
- Modify: `app/Tests/HookTests/HookHarness.swift` (extend `Hook.run` with script args)
- Test: `app/Tests/HookTests/SpeakableTextChecks.swift`
- Modify: `hooks/speakable-text.sh`

**Interfaces:**
- Consumes: `speakable-text.sh` from Task 1.
- Produces: `speakable-text.sh --full` → all prose paragraphs joined intra-paragraph by spaces, separated by single `\n`, uncapped. `Hook.run(name, args:, stdin:, sandbox:, env:)`.

- [ ] **Step 1: Extend the harness to pass script arguments**

In `app/Tests/HookTests/HookHarness.swift`, change the `run` signature and the arguments line:

```swift
    static func run(_ name: String, args: [String] = [], stdin: String, sandbox: Sandbox, env extra: [String: String] = [:]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [hooksDir.appendingPathComponent(name).path] + args
```

(Existing callers use `Hook.run("x.sh", stdin:..., sandbox:...)`; `args` defaults to `[]`, so they keep compiling.)

- [ ] **Step 2: Write the failing `--full` checks**

Append inside `speakableTextFailures()` in `SpeakableTextChecks.swift`, before `return failures`:

```swift
    // --- Full mode: all prose paragraphs, uncapped, paragraph breaks kept as newlines. ---
    func fullText(_ input: String) -> String {
        Hook.run("speakable-text.sh", args: ["--full"], stdin: input, sandbox: sandbox).stdout
    }
    func expectFull(_ input: String, _ expected: String, _ name: String) {
        let r = fullText(input)
        if r != expected {
            failures.append("speakable-text.full.\(name): got \(r.debugDescription), expected \(expected.debugDescription)")
        }
    }

    expectFull("First paragraph here.\n\nSecond paragraph here.\n",
               "First paragraph here.\nSecond paragraph here.", "keepsAllParagraphs")
    expectFull("Intro line.\n\n```swift\nlet x = 1\n```\n\n| a | b |\n\nClosing line.\n",
               "Intro line.\nClosing line.", "dropsCodeAndTablesInFull")
    expectFull("Line one\ncontinues here.\n\nNext para.\n",
               "Line one continues here.\nNext para.", "joinsIntraParagraphLines")

    // No 600-char cap in full mode.
    let longFull = String(repeating: "Sentence one is here. ", count: 60)
        .trimmingCharacters(in: .whitespaces) + "\n"
    let fullCapped = fullText(longFull)
    if fullCapped.count <= 600 {
        failures.append("speakable-text.full.noCap: length \(fullCapped.count) <= 600, expected uncapped")
    }
```

- [ ] **Step 3: Run to verify it fails**

Run:

```bash
cd app && swift run HookTests
```

Expected: FAIL — `speakable-text.full.keepsAllParagraphs` etc. (the script ignores `--full` and returns only the first paragraph).

- [ ] **Step 4: Rewrite `hooks/speakable-text.sh` with the mode switch**

Replace the entire file with:

```bash
#!/bin/bash
# Reads a markdown assistant message on stdin; prints the spoken text.
#   (default)  the first prose paragraph, capped at ~600 chars on a sentence boundary
#   --full     ALL prose paragraphs, uncapped; paragraph breaks kept as newlines so the
#              app's SentenceSplitter (which flushes on '\n') keeps them as separate chunks
# Both modes drop fenced code, headings, and tables, de-bullet/de-number, and strip inline
# markdown, links, and URLs — a code block or table can't be spoken sensibly even in --full.
export LANG="${LANG:-en_US.UTF-8}"

MODE="first"
[ "$1" = "--full" ] && MODE="full"

TEXT=$(cat)

# 1) Extract prose lines. first mode stops at the first blank line after prose starts;
#    full mode keeps every paragraph (blank lines pass through as separators).
PARA=$(printf '%s\n' "$TEXT" | awk -v mode="$MODE" '
  /^[[:space:]]*```/ { infence = !infence; next }   # toggle + drop fence lines
  infence { next }                                  # drop fenced content
  /^[[:space:]]*#/  { next }                          # drop ATX headings
  /^[[:space:]]*\|/ { next }                           # drop table rows
  {
    line = $0
    sub(/^[[:space:]]*[-*+][[:space:]]+/, "", line)        # de-bullet
    sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", line)     # de-number
    if (line ~ /^[[:space:]]*$/) {
      if (!started) next
      if (mode == "full") { print ""; next }   # keep the paragraph break
      exit                                     # first mode: stop after one paragraph
    }
    started = 1
    print line
  }
')

# 2) Strip inline markdown / links / URLs (both modes).
STRIPPED=$(printf '%s\n' "$PARA" | \
  sed -E 's/`([^`]*)`/\1/g; s/\*\*//g; s/\*//g' | \
  sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | \
  sed -E 's|https?://[^ ]*||g')

if [ "$MODE" = "full" ]; then
  # Join lines within each paragraph to single spaces; keep one newline between paragraphs.
  # No length cap — the whole reply is spoken.
  SPEECH=$(printf '%s\n' "$STRIPPED" | awk '
    BEGIN { RS = ""; ORS = "\n" }
    {
      gsub(/[ \t]*\n[ \t]*/, " ")   # intra-paragraph newlines -> spaces
      gsub(/  +/, " ")
      sub(/^ +/, ""); sub(/ +$/, "")
      print
    }')
else
  # Join everything, collapse whitespace, then cap at ~600 chars on a sentence boundary.
  SPEECH=$(printf '%s\n' "$STRIPPED" | tr '\n' ' ' | sed -E 's/  */ /g; s/^ *//; s/ *$//')
  if [ ${#SPEECH} -gt 600 ]; then
    SPEECH="${SPEECH:0:600}"
    SPEECH=$(printf '%s' "$SPEECH" | sed -E 's/([.!?])[^.!?]*$/\1/')
  fi
fi

printf '%s' "$SPEECH"
```

- [ ] **Step 5: Run to verify all checks pass (default + full)**

Run:

```bash
cd app && swift run HookTests
```

Expected: `✅ HookTests: all checks passed`

- [ ] **Step 6: Commit**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git add -A
git commit -m "$(cat <<'EOF'
feat(tts): add --full mode to speakable-text extractor

--full emits every prose paragraph, uncapped, paragraph breaks kept as
newlines so SentenceSplitter keeps them as separate chunks. Code blocks
and tables are still dropped.

Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U
EOF
)"
```

---

## Task 3: Stop hooks speak the whole reply when style is `full`

Both Stop hooks resolve the style (same precedence as `voice-context.sh`) and pass `--full` to the extractor when it is `full`.

**Files:**
- Test: `app/Tests/HookTests/TTSHookGateChecks.swift`
- Modify: `hooks/tts-hook.sh` (after line 45), `hooks/codex-tts-hook.sh` (after line 42)

**Interfaces:**
- Consumes: `speakable-text.sh --full` (Task 2); `Hook.Sandbox.writeTtsStyle(_:)` (existing harness helper).
- Produces: Stop hooks that POST the whole reply when `tts_style`/`OW_TTS_STYLE` is `full`.

- [ ] **Step 1: Write the failing gate check for `full`**

Append inside `ttsHookGateFailures()` in `app/Tests/HookTests/TTSHookGateChecks.swift`, before `return failures`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run:

```bash
cd app && swift run HookTests
```

Expected: FAIL — `tts-hook.fullStyle: only first paragraph spoken` (the hook always uses default mode today, so "Second spoken part" is absent).

- [ ] **Step 3: Resolve style + branch in `hooks/tts-hook.sh`**

Replace lines 45-47 (the `HOOK_DIR` + `SPEECH` extraction):

```bash
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# Spoken-text style. Precedence: per-project OW_TTS_STYLE env → global tts_style file →
# legacy voice_detail. 'full' speaks the whole reply; everything else, the first paragraph.
STYLE="$OW_TTS_STYLE"
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
if [ "$STYLE" = "full" ]; then
  SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh" --full)
else
  SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh")
fi
[ -z "$SPEECH" ] && exit 0
```

- [ ] **Step 4: Mirror the change in `hooks/codex-tts-hook.sh`**

Replace lines 42-44 (the `HOOK_DIR` + `SPEECH` extraction):

```bash
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# Spoken-text style. Precedence: per-project OW_TTS_STYLE env → global tts_style file →
# legacy voice_detail. 'full' speaks the whole reply; everything else, the first paragraph.
STYLE="$OW_TTS_STYLE"
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
if [ "$STYLE" = "full" ]; then
  SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh" --full)
else
  SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh")
fi
[ -z "$SPEECH" ] && exit 0
```

(No `HookTests` group exercises `codex-tts-hook.sh`; parity here is by inspection — it mirrors `tts-hook.sh`.)

- [ ] **Step 5: Run to verify all checks pass**

Run:

```bash
cd app && swift run HookTests
```

Expected: `✅ HookTests: all checks passed`

- [ ] **Step 6: Commit**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git add -A
git commit -m "$(cat <<'EOF'
feat(tts): Stop hooks speak whole reply in full style

Both Stop hooks resolve the style (OW_TTS_STYLE env → tts_style file →
legacy voice_detail) and pass --full to the extractor when it is 'full'.

Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U
EOF
)"
```

---

## Task 4: `full` nudge in `voice-context.sh`

`full` replaces the whole nudge (not just the length phrase): write the entire reply as speakable prose, no separate summary.

**Files:**
- Test: `app/Tests/HookTests/VoiceContextChecks.swift`
- Modify: `hooks/voice-context.sh:66-71`

**Interfaces:**
- Consumes: existing `voice-context.sh` style resolution + `nudge(_:)` test helper.
- Produces: a `full` nudge containing "entire reply" and "read aloud", without the "Open with … summary" opener.

- [ ] **Step 1: Write the failing nudge check**

Append inside `voiceContextFailures()` in `app/Tests/HookTests/VoiceContextChecks.swift`, before `return failures`:

```swift
    // 10) full style → "speak the whole reply" nudge, not a summary opener.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsStyle("full")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("entire reply") != true {
            fail("fullStyle: nudge missing 'entire reply': \(n?.debugDescription ?? "nil")")
        }
        if n?.contains("read aloud") != true {
            fail("fullStyle: nudge missing 'read aloud': \(n?.debugDescription ?? "nil")")
        }
        if n?.contains("Open with") == true {
            fail("fullStyle: nudge should not ask for a summary opener: \(n?.debugDescription ?? "nil")")
        }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run:

```bash
cd app && swift run HookTests
```

Expected: FAIL — `voice-context.fullStyle: nudge missing 'entire reply'` (today `full` falls through to the default summary nudge).

- [ ] **Step 3: Add the `full)` branch in `hooks/voice-context.sh`**

Replace lines 66-71 (the `case` + `NUDGE` assignment):

```bash
case "$STYLE" in
  full)
    NUDGE="This turn was dictated by voice and your entire reply will be read aloud. Write the whole reply as natural spoken prose: short sentences, expand acronyms, avoid AI-isms and filler, and keep code, file paths, and tables out of the spoken flow — describe them in words instead. Do not write a separate summary."
    ;;
  terse) LEN="one short, plain spoken sentence" ;;
  rich)  LEN="a sentence or two of plain spoken summary" ;;
  *)     LEN="one plain spoken sentence" ;;
esac
# terse/normal/rich build the summary nudge from LEN; full set NUDGE directly above.
[ -z "$NUDGE" ] && NUDGE="This turn was dictated by voice and your reply will be read aloud. Open with ${LEN} that stands alone as a summary; details can follow."
```

- [ ] **Step 4: Run to verify all checks pass**

Run:

```bash
cd app && swift run HookTests
```

Expected: `✅ HookTests: all checks passed`

- [ ] **Step 5: Commit**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git add -A
git commit -m "$(cat <<'EOF'
feat(tts): full-style nudge asks model to speak entire reply

For the full style the UserPromptSubmit hook swaps the whole nudge: write
the entire reply as speakable prose, no separate summary opener.

Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U
EOF
)"
```

---

## Task 5: Add `Full` to the menubar style picker

One line enables the value in the UI and lets it pass load-time validation.

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift:115-119`

**Interfaces:**
- Consumes: nothing new.
- Produces: a selectable `full` style written to `Paths.ttsStyle`.

- [ ] **Step 1: Add the picker row**

In `app/Sources/OpenWhisperer/MenuBarView.swift`, change `styleLevels`:

```swift
    private static let styleLevels: [(id: String, label: String)] = [
        ("terse", "Terse"),
        ("normal", "Normal"),
        ("rich", "Rich"),
        ("full", "Full"),
    ]
```

- [ ] **Step 2: Build to verify it compiles**

Run:

```bash
cd app && swift build
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git add app/Sources/OpenWhisperer/MenuBarView.swift
git commit -m "$(cat <<'EOF'
feat(tts): add Full to the menubar style picker

Selecting Full writes tts_style=full; the existing membership check now
accepts it on load.

Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U
EOF
)"
```

---

## Task 6: Documentation

Update CLAUDE.md (the authoritative project doc) so the `tts_style` description and the "speaks the first paragraph" sentences reflect the new mode.

**Files:**
- Modify: `CLAUDE.md` (TTS section ~line 75, voice-turn handshake ~line 82, state list `tts_style` entry, per-project override paragraph)

- [ ] **Step 1: Update the `tts_style` enumerations and "first paragraph" wording**

In `CLAUDE.md`:
- In the state/IPC list, change the `tts_style` description from `terse`/`normal`/`rich` to:

```
`tts_style` (spoken-summary style: `terse`/`normal`/`rich` summary lengths, or `full` = speak the whole reply as prose; was `voice_detail` before the rename)
```

- In the Voice-turn handshake section (step 3), change the Stop-hook sentence to note mode-dependence:

```
3. The **Stop** hook (`hooks/tts-hook.sh`) speaks only if that marker exists, extracting the reply's spoken text with `hooks/speakable-text.sh` — the markdown-stripped first paragraph (~600 char cap), or the whole reply when `tts_style` is `full` — then POSTs to `/v1/audio/play`.
```

(This handshake line is the only `first-paragraph.sh` mention in CLAUDE.md.)

- In the per-project override paragraph, note that `OW_TTS_STYLE` accepts `full` and is now also read by the Stop hooks (not only `voice-context.sh`):

```
`OW_TTS_STYLE` (overrides `tts_style`, read by `voice-context.sh` for the nudge and by the Stop hooks to choose first-paragraph vs. whole-reply extraction)
```

- [ ] **Step 2: Read back the edited sections to confirm accuracy**

Run:

```bash
cd /Users/hakanensari/code/OpenWhisperer
grep -n "tts_style\|speakable-text\|first paragraph\|OW_TTS_STYLE" CLAUDE.md
```

Expected: no remaining `first-paragraph.sh` reference; `tts_style` lists `full`; Stop-hook line mentions whole-reply.

- [ ] **Step 3: Commit**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: document the full TTS style

Update CLAUDE.md for the speakable-text.sh rename and the full style
(whole-reply extraction; OW_TTS_STYLE now read by the Stop hooks too).

Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U
EOF
)"
```

---

## Task 7 (optional): Version bump

User-visible features usually bump the app version. CLAUDE.md: version is hardcoded as `1.4.0` in both `app/build-dmg.sh` and `app/Resources/Info.plist` — **bump both together**. Skip this task if not cutting a release.

**Files:**
- Modify: `app/build-dmg.sh`, `app/Resources/Info.plist`

- [ ] **Step 1: Bump the version in both files** (e.g. `1.4.0` → `1.5.0`)
- [ ] **Step 2: Commit**

```bash
cd /Users/hakanensari/code/OpenWhisperer
git add app/build-dmg.sh app/Resources/Info.plist
git commit -m "$(cat <<'EOF'
build: bump version to 1.5.0

Claude-Session: https://claude.ai/code/session_017EXTWL792Beet83obaeG9U
EOF
)"
```

---

## Final verification (before PR)

- [ ] `cd app && swift run HookTests` → all checks pass
- [ ] `cd app && swift run OpenWhispererKitTests` → all checks pass (regression; this plan does not touch the Kit)
- [ ] `cd app && swift build` → Build complete
- [ ] `grep -rn "first-paragraph" hooks app/Sources app/Tests app/build-dmg.sh app/Package.swift README.md CLAUDE.md` → no output
- [ ] Manual smoke (optional, needs a packaged build): select **Full** in the menubar, dictate a turn that elicits a multi-paragraph reply containing a code block, confirm the whole prose (minus the code) is read aloud, and that starting a new recording barges in cleanly.
- [ ] Open the PR per the CLAUDE.md PR path (rebase onto `origin/main`, push, `gh pr create`).
