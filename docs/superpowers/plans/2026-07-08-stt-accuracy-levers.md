# STT Accuracy Levers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three dictation-accuracy levers from `docs/superpowers/specs/2026-07-08-stt-accuracy-levers-design.md`: a user-editable vocabulary glossary fed to WhisperKit as `promptTokens`, an Auto-detect language setting that actually detects, and three decode tweaks.

**Architecture:** Pure parsing/budgeting logic (`VocabularyPrompt`) goes in `OpenWhispererKit` (unit-testable under Command Line Tools). File I/O, tokenization, and `DecodingOptions` wiring go in the app target (`SpeechTranscriber`). The UI is a file-backed multi-line text box in `MenuBarView`'s Voice Settings card. The glossary file `stt_vocabulary` on the Application Support flat-file bus is the single source of truth.

**Tech Stack:** Swift 5 / SwiftUI (macOS 14+), WhisperKit 1.0.0, SwiftPM. **No XCTest** — tests are plain executables.

## Global Constraints

- Build/test from `app/` (the SwiftPM root): `swift build`, `swift run OpenWhispererKitTests`, `swift run HookTests`. Both test runners `exit(1)` on failure and print `✅ … all checks passed` on success.
- This machine has Command Line Tools only — never add XCTest/swift-testing imports.
- Work in a worktree branch `stt-accuracy-levers` under `.claude/worktrees/` (create via superpowers:using-git-worktrees at execution start). Never branch in place. First build in a fresh worktree re-resolves SwiftPM packages from GitHub (allowed by the firewall; only the HF Xet CDN is blocked, and no model download is needed to build).
- Commits: Conventional Commits `type(scope): subject`, imperative, **≤72 chars including prefix**, body only for *why* (wrap at 72). Every commit ends with exactly this trailer (blank line before it, no Co-Authored-By):
  `Claude-Session: cb322baa-1c01-4158-aaf6-1cb1f163421e`
- Prompt-token budget is **96** (WhisperKit hard-trims prompts to 111 = `maxTokenContext/2 - 1`, and trims with `.suffix`, i.e. keep-last; our cap is keep-first).
- UI copy verbatim from the spec — label `Vocabulary`, hint `one term per line`, placeholder lines `WhisperKit` / `Codex CLI` / `Kokoro`, caption `Biases dictation toward these spellings — product names, CLI jargon, APIs. Keep it to a dozen or two.`
- Git remote: `origin` = `PerIPan/OpenWhisperer` is the **only** remote and the correct PR target; plain `gh pr create` is right.

---

### Task 1: `VocabularyPrompt` pure logic (TDD)

**Files:**
- Create: `app/Sources/OpenWhispererKit/VocabularyPrompt.swift`
- Create: `app/Tests/OpenWhispererKitTests/VocabularyPromptChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (register the check group)

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces (Task 3 relies on these exact signatures):
  - `VocabularyPrompt.terms(from text: String) -> [String]`
  - `VocabularyPrompt.promptText(_ terms: [String]) -> String?`
  - `VocabularyPrompt.fittingPrefixCount(tokenCounts: [Int], separatorCount: Int, budget: Int) -> Int`

- [ ] **Step 1: Write the failing checks**

Create `app/Tests/OpenWhispererKitTests/VocabularyPromptChecks.swift`:

```swift
import OpenWhispererKit

/// Checks for `VocabularyPrompt` — glossary parsing + prompt-token budgeting
/// for the WhisperKit promptTokens accuracy lever.
/// Returns a list of human-readable failures (empty = all passed).
func vocabularyPromptFailures() -> [String] {
    var failures: [String] = []

    func expectTerms(_ input: String, _ expected: [String], _ name: String) {
        let r = VocabularyPrompt.terms(from: input)
        if r != expected {
            failures.append(
                "VocabularyPrompt.\(name): terms(\(input.debugDescription)) -> \(r); expected \(expected)")
        }
    }

    func expectPrompt(_ terms: [String], _ expected: String?, _ name: String) {
        let r = VocabularyPrompt.promptText(terms)
        if r != expected {
            failures.append(
                "VocabularyPrompt.\(name): promptText(\(terms)) -> "
                + "\(String(describing: r)); expected \(String(describing: expected))")
        }
    }

    func expectCount(_ counts: [Int], _ sep: Int, _ budget: Int, _ expected: Int, _ name: String) {
        let r = VocabularyPrompt.fittingPrefixCount(tokenCounts: counts, separatorCount: sep, budget: budget)
        if r != expected {
            failures.append(
                "VocabularyPrompt.\(name): fittingPrefixCount(\(counts), sep: \(sep), "
                + "budget: \(budget)) -> \(r); expected \(expected)")
        }
    }

    // terms(from:)
    expectTerms("WhisperKit\nCodex CLI\nKokoro", ["WhisperKit", "Codex CLI", "Kokoro"], "basicLines")
    expectTerms("  WhisperKit  \n\tKokoro\t", ["WhisperKit", "Kokoro"], "trimsWhitespace")
    expectTerms("WhisperKit\n\n\nKokoro", ["WhisperKit", "Kokoro"], "skipsBlankLines")
    expectTerms("# comment\nWhisperKit\n  # indented\nKokoro", ["WhisperKit", "Kokoro"], "skipsComments")
    expectTerms("WhisperKit\r\nCodex CLI\r\n", ["WhisperKit", "Codex CLI"], "handlesCRLF")
    expectTerms("", [], "emptyInput")
    expectTerms("# only\n# comments\n   \n", [], "onlyCommentsAndBlanks")
    expectTerms("Codex CLI", ["Codex CLI"], "keepsInnerSpaces")

    // promptText(_:)
    expectPrompt(["WhisperKit", "Codex CLI", "Kokoro"], "WhisperKit, Codex CLI, Kokoro", "joinsWithCommas")
    expectPrompt(["WhisperKit"], "WhisperKit", "singleTerm")
    expectPrompt([], nil, "emptyIsNil")

    // fittingPrefixCount(tokenCounts:separatorCount:budget:)
    expectCount([3, 3, 3], 1, 100, 3, "allFit")
    expectCount([3, 3, 3], 1, 7, 2, "partialFit")       // 3, then 3+1+3=7 fits, then 11 > 7
    expectCount([3, 3, 3], 1, 6, 1, "separatorCounts")  // 3 fits; 3+1+3=7 > 6
    expectCount([3, 3], 1, 0, 0, "zeroBudget")
    expectCount([120], 1, 96, 0, "firstTermOverBudget")
    expectCount([3, 4], 1, 8, 2, "exactFit")            // 3 + 1 + 4 = 8
    expectCount([], 1, 96, 0, "noTerms")

    return failures
}
```

Register the group in `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` — change:

```swift
        failures += ttsVoiceRegistryFailures()
```

to:

```swift
        failures += ttsVoiceRegistryFailures()
        failures += vocabularyPromptFailures()
```

- [ ] **Step 2: Run to verify it fails**

Run (from `app/`): `swift build 2>&1 | tail -5`
Expected: FAIL — `error: cannot find 'VocabularyPrompt' in scope` (no test framework here; the red step is a compile failure).

- [ ] **Step 3: Write the implementation**

Create `app/Sources/OpenWhispererKit/VocabularyPrompt.swift`:

```swift
import Foundation

/// Parses the user's dictation vocabulary (`stt_vocabulary`) and sizes it to a
/// prompt-token budget. Pure logic — file I/O and tokenization stay in the app
/// target (`SpeechTranscriber`), so this builds and tests fast under CLT.
public enum VocabularyPrompt {
    /// One term per line; lines are trimmed, blank lines and #-comments skipped.
    public static func terms(from text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// "a, b, c" — Whisper reads the prompt as preceding transcript, so a plain
    /// comma list biases decoding toward these spellings. Nil when empty.
    public static func promptText(_ terms: [String]) -> String? {
        terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    /// How many leading terms fit `budget` tokens, where `tokenCounts[i]` is the
    /// encoded length of term i and `separatorCount` the encoded length of ", ".
    /// Keep-first by design: WhisperKit trims prompt tokens with `.suffix`, which
    /// would silently drop the FRONT of the list instead.
    public static func fittingPrefixCount(tokenCounts: [Int], separatorCount: Int, budget: Int) -> Int {
        var total = 0
        for (i, count) in tokenCounts.enumerated() {
            total += count + (i > 0 ? separatorCount : 0)
            if total > budget { return i }
        }
        return tokenCounts.count
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run (from `app/`): `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhispererKit/VocabularyPrompt.swift Tests/OpenWhispererKitTests/VocabularyPromptChecks.swift Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(stt): add VocabularyPrompt parsing and token-cap logic

Claude-Session: cb322baa-1c01-4158-aaf6-1cb1f163421e"
```

---

### Task 2: Honest Auto-detect + decode tweaks

**Files:**
- Modify: `app/Sources/OpenWhisperer/SpeechTranscriber.swift:134-135` (the `DecodingOptions` construction in `transcribe(samples:language:)`)

**Interfaces:**
- Consumes: nothing new.
- Produces: the multi-line `DecodingOptions` construction that Task 3 extends with a `promptTokens:` argument.

- [ ] **Step 1: Replace the options construction**

In `app/Sources/OpenWhisperer/SpeechTranscriber.swift`, change:

```swift
        let lang = (language?.isEmpty == false && language != "auto") ? language : nil
        let options = DecodingOptions(language: lang)
```

to:

```swift
        let lang = (language?.isEmpty == false && language != "auto") ? language : nil
        // detectLanguage: WhisperKit's default (false while usePrefillPrompt is on)
        // prefills <|en|> for a nil language — "Auto-detect" would force English.
        // withoutTimestamps: dictation needs no timestamps. suppressBlank: matches
        // the OpenAI reference decoder (WhisperKit defaults it off). .vad: better
        // window seams on >30 s dictations; no effect on short clips.
        let options = DecodingOptions(
            language: lang,
            detectLanguage: lang == nil,
            withoutTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: .vad
        )
```

(Argument order matches the `DecodingOptions` initializer declaration order — Swift requires it.)

- [ ] **Step 2: Build and run both test runners**

Run (from `app/`): `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: build succeeds; `✅ OpenWhispererKit: all checks passed`; HookTests prints its all-passed line and exits 0. (No unit test can cover this file — it imports WhisperKit; the compile + green suites are the gate.)

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenWhisperer/SpeechTranscriber.swift
git commit -m "feat(stt): honest auto-detect and dictation decode tweaks

With stock options a nil language prefills <|en|> (detectLanguage
defaults to false while usePrefillPrompt is on), so the menubar
Auto-detect setting silently forced English. Pass detectLanguage
when no language is pinned, and adopt dictation-appropriate decode
settings: withoutTimestamps, suppressBlank (OpenAI reference
default), and VAD chunking for >30 s clips.
See docs/superpowers/specs/2026-07-08-stt-accuracy-levers-design.md.

Claude-Session: cb322baa-1c01-4158-aaf6-1cb1f163421e"
```

---

### Task 3: Glossary → `promptTokens` in SpeechTranscriber

**Files:**
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (add `sttVocabulary` after `sttLanguage`)
- Modify: `app/Sources/OpenWhisperer/SpeechTranscriber.swift` (import, budget constant, helper, `promptTokens:` argument)

**Interfaces:**
- Consumes: `VocabularyPrompt.terms(from:)`, `.promptText(_:)`, `.fittingPrefixCount(tokenCounts:separatorCount:budget:)` from Task 1; the `DecodingOptions` construction from Task 2; WhisperKit's `WhisperTokenizer.encode(text:) -> [Int]` (`wk.tokenizer` is `WhisperTokenizer?`).
- Produces: `Paths.sttVocabulary` (Task 4 reads/writes this URL).

- [ ] **Step 1: Add the path**

In `app/Sources/OpenWhisperer/Paths.swift`, change:

```swift
    /// STT language file (default language for in-process WhisperKit STT)
    static let sttLanguage = appSupport.appendingPathComponent("stt_language")
```

to:

```swift
    /// STT language file (default language for in-process WhisperKit STT)
    static let sttLanguage = appSupport.appendingPathComponent("stt_language")

    /// Dictation vocabulary (glossary) — one term per line, #-comments allowed.
    /// Fed to WhisperKit as promptTokens to bias transcription toward these
    /// spellings. Edited by the Voice Settings vocabulary box; absent = no bias.
    static let sttVocabulary = appSupport.appendingPathComponent("stt_vocabulary")
```

- [ ] **Step 2: Wire the glossary into SpeechTranscriber**

In `app/Sources/OpenWhisperer/SpeechTranscriber.swift`, change:

```swift
import Foundation
import WhisperKit
```

to:

```swift
import Foundation
import OpenWhispererKit
import WhisperKit
```

Then add, directly below `static let modelName …` (after line 23):

```swift
    /// Prompt-token budget for the vocabulary glossary. WhisperKit hard-trims
    /// prompts to 111 tokens (maxTokenContext/2 - 1) with keep-LAST semantics;
    /// capping at 96 keep-FIRST ourselves leaves slack for BPE boundary drift
    /// between per-term and joined encodings.
    private static let promptTokenBudget = 96

    /// Encode the user's vocabulary glossary (Paths.sttVocabulary) as prompt
    /// tokens, keeping leading terms within the budget. Every failure path
    /// (missing file, no tokenizer, empty list) degrades to nil — dictation
    /// must never break on account of its own glossary.
    private static func glossaryPromptTokens(tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer,
              let text = try? String(contentsOf: Paths.sttVocabulary, encoding: .utf8) else { return nil }
        let terms = VocabularyPrompt.terms(from: text)
        guard !terms.isEmpty else { return nil }
        let counts = terms.map { tokenizer.encode(text: $0).count }
        let separatorCount = tokenizer.encode(text: ", ").count
        let kept = VocabularyPrompt.fittingPrefixCount(
            tokenCounts: counts, separatorCount: separatorCount, budget: promptTokenBudget)
        guard kept > 0 else { return nil }
        if kept < terms.count {
            NSLog("SpeechTranscriber: vocabulary trimmed to first \(kept) of \(terms.count) terms")
        }
        guard let prompt = VocabularyPrompt.promptText(Array(terms.prefix(kept))) else { return nil }
        return tokenizer.encode(text: prompt)
    }
```

Then extend the Task 2 options construction — change:

```swift
        let options = DecodingOptions(
            language: lang,
            detectLanguage: lang == nil,
            withoutTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: .vad
        )
```

to:

```swift
        let options = DecodingOptions(
            language: lang,
            detectLanguage: lang == nil,
            withoutTimestamps: true,
            promptTokens: Self.glossaryPromptTokens(tokenizer: wk.tokenizer),
            suppressBlank: true,
            chunkingStrategy: .vad
        )
```

(`promptTokens` sits between `withoutTimestamps` and `suppressBlank` in the initializer's declaration order. WhisperKit wraps the tokens with `<|startofprev|>` and filters special tokens itself.)

- [ ] **Step 3: Build and run both test runners**

Run (from `app/`): `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: build succeeds; both runners green.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenWhisperer/Paths.swift Sources/OpenWhisperer/SpeechTranscriber.swift
git commit -m "feat(stt): feed vocabulary glossary as promptTokens

Reads stt_vocabulary on each transcribe (tiny file; edits apply
without restart), encodes a comma-joined term list, and passes it
as promptTokens so Whisper biases toward the user's jargon. Capped
keep-first at 96 tokens because WhisperKit's own 111-token trim is
keep-last and would drop the front of the list.

Claude-Session: cb322baa-1c01-4158-aaf6-1cb1f163421e"
```

---

### Task 4: Vocabulary text box in Voice Settings

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift` — four edits: state vars (~line 73), `.onAppear` load (after the `savedLang` block, ~line 263), the card UI (between the "Dictate in" row's `.onChange` and the divider before the "Voice" row, ~line 597), and a private save helper.

**Interfaces:**
- Consumes: `Paths.sttVocabulary` from Task 3; existing theme tokens `OWColor.ink/.inkSoft/.inkFaint/.pickerBg/.pickerBorder`, `OWFont.body/.caption/.mono`, `OWInternalDivider`.
- Produces: nothing downstream.

- [ ] **Step 1: Add state vars**

After the line `@State private var autoSubmit = false`, add:

```swift
    @State private var vocabularyText = ""
    /// Debounced save of the vocabulary editor (0.5 s after the last keystroke).
    @State private var vocabularySaveWork: DispatchWorkItem?
```

- [ ] **Step 2: Load the file on appear**

Directly after the `savedLang` block in `.onAppear` (the `if let savedLang = try? String(contentsOf: Paths.sttLanguage…` block's closing brace), add:

```swift
            vocabularyText = (try? String(contentsOf: Paths.sttVocabulary, encoding: .utf8)) ?? ""
```

- [ ] **Step 3: Insert the editor into the Voice Settings card**

In `voiceSettingsCard`, directly after the `.onChange(of: selectedLanguage) { … }` block (and before the existing `OWInternalDivider()` that precedes the "Voice" row), insert:

```swift

                OWInternalDivider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Vocabulary")
                            .font(OWFont.body(11))
                            .foregroundColor(OWColor.ink)
                        Spacer()
                        Text("one term per line")
                            .font(OWFont.caption(10))
                            .foregroundColor(OWColor.inkSoft)
                    }
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $vocabularyText)
                            .font(OWFont.mono(11))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .frame(height: 72)
                            .background(OWColor.pickerBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(OWColor.pickerBorder, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        if vocabularyText.isEmpty {
                            Text("WhisperKit\nCodex CLI\nKokoro")
                                .font(OWFont.mono(11))
                                .foregroundColor(OWColor.inkFaint)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: vocabularyText) { _, newValue in
                        vocabularySaveWork?.cancel()
                        let work = DispatchWorkItem { saveVocabulary(newValue) }
                        vocabularySaveWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                    }
                    .onDisappear {
                        // Flush a pending debounce so a quick popover close can't lose edits.
                        if let work = vocabularySaveWork, !work.isCancelled {
                            work.cancel()
                            saveVocabulary(vocabularyText)
                        }
                    }
                    Text("Biases dictation toward these spellings — product names, CLI jargon, APIs. Keep it to a dozen or two.")
                        .font(OWFont.caption(10))
                        .foregroundColor(OWColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

Also update the card's `help:` string (in the `OWCollapsibleCard(title: "Voice Settings", …)` call) — change:

```swift
            help: "Dictation language, the voice that reads replies aloud, how fast it's read, and Response — how much of a reply is spoken, and when.",
```

to:

```swift
            help: "Dictation language and vocabulary, the voice that reads replies aloud, how fast it's read, and Response — how much of a reply is spoken, and when.",
```

- [ ] **Step 4: Add the save helper**

Near the other private helpers of `MenuBarView` (e.g. below `multiplierLabel`), add:

```swift
    /// Persist the vocabulary editor's contents to the flat-file bus.
    /// Whitespace-only → remove the file (stock behavior, no glossary).
    private func saveVocabulary(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: Paths.sttVocabulary)
        } else {
            try? text.write(to: Paths.sttVocabulary, atomically: true, encoding: .utf8)
        }
    }
```

- [ ] **Step 5: Build and run both test runners**

Run (from `app/`): `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: build succeeds; both runners green.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenWhisperer/MenuBarView.swift
git commit -m "feat(ui): vocabulary editor in Voice Settings card

Claude-Session: cb322baa-1c01-4158-aaf6-1cb1f163421e"
```

---

### Task 5: Final verification, push, PR

**Files:** none new.

- [ ] **Step 1: Full clean pass**

Run (from `app/`): `swift build 2>&1 | tail -3 && swift run OpenWhispererKitTests && swift run HookTests`
Expected: `Build complete!`; `✅ OpenWhispererKit: all checks passed`; HookTests all-passed, exit 0.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin stt-accuracy-levers
```

(If `origin/main` moved since the worktree was created, rebase onto it first per AGENTS.md.)

- [ ] **Step 3: Open the PR**

```bash
gh pr create \
  --title "feat(stt): accuracy levers — glossary, auto-detect, decode tweaks" \
  --body "Implements docs/superpowers/specs/2026-07-08-stt-accuracy-levers-design.md.

- Vocabulary glossary: stt_vocabulary (one term per line, #-comments) → WhisperKit promptTokens, capped keep-first at 96 tokens; edited via a file-backed text box in the Voice Settings card
- Honest Auto-detect: detectLanguage when no language is pinned (stock options prefill <|en|> — Auto-detect silently forced English)
- Decode tweaks: withoutTimestamps, suppressBlank, VAD chunking

Tests: OpenWhispererKitTests (new VocabularyPromptChecks group) + HookTests, both green.

Post-merge feel-test (per spec): dictate glossary jargon with and without the file; a Turkish sentence on Auto-detect; a plain English dictation for no-regression. Requires signed rebuild + reinstall (OW_SIGN_IDENTITY=\"OpenWhisperer Dev\" ./build-dmg.sh)."
```

Expected: PR URL printed, targeting `PerIPan/OpenWhisperer` `main`.

- [ ] **Step 4: Report**

Return the PR URL and the final test output. Post-merge install (build-dmg + reinstall + relaunch) is deliberately outside this plan — it restarts the app the user may be dictating with.
