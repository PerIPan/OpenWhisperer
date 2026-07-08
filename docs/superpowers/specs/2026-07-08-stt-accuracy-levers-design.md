# STT Accuracy Levers

**Date:** 2026-07-08
**Status:** Approved (brainstorming) — pending implementation plan

## Goal

Improve dictation accuracy with three independent, low-risk changes to the WhisperKit decode path:

1. **Vocabulary glossary.** A user-editable word list fed to Whisper as `promptTokens`, so jargon and proper nouns ("WhisperKit", "Codex", "Kokoro") transcribe correctly instead of degrading into sound-alikes ("RISC-KIT").
2. **Honest Auto-detect.** Make the existing "Auto-detect" language setting actually detect. Today `DecodingOptions(language: nil)` prefills `<|en|>`: WhisperKit defaults `detectLanguage` to `false` whenever `usePrefillPrompt` is true, then falls back to `Constants.defaultLanguageCode = "en"` (TextDecoder). Auto currently means force-English — right by accident for English, wrong for Turkish.
3. **Decode tweaks.** `withoutTimestamps: true`, `suppressBlank: true`, `chunkingStrategy: .vad` — each a one-line revert if it misbehaves.

### Why this, why now

The June 24 → July 8 accuracy regression (WhisperKit 1.0.0 tokenizer-path bug, fixed in `7fe853a`) prompted a research pass over the decode configuration. It found the app passes stock `DecodingOptions` and uses none of Whisper's context-biasing ability. The glossary attacks the user's actual complaint class (jargon); the other two correct settings that lie or underperform for dictation.

## Decisions

- **Static file, not magic.** The glossary is a flat file the user edits. Rejected alternatives: post-hoc autocorrect (fuzzy-replacing transcript words — overcorrects homophones, gives the model no context) and dynamic context harvesting (auto-glossary from the frontmost repo — fragile, privacy-adjacent). Either can layer on later.
- **Read per dictation.** `SpeechTranscriber` reads and tokenizes the glossary on every `transcribe` call. The file is tiny; this makes edits live without an app restart and needs no file watcher.
- **Cap keep-first, drop-last.** WhisperKit trims `promptTokens` with `.suffix(111)` — over budget, the *front* of the list silently vanishes. We cap at **96 tokens ourselves, keeping leading terms**, and log when terms drop. The 15-token slack absorbs BPE boundary drift between per-term and joined encodings.
- **Terms join as one comma-separated line.** Whisper conditions on the prompt as preceding transcript; a plain "WhisperKit, Codex CLI, Kokoro" reads like someone listing the terms. No prefix sentence.
- **In-popover editor, file-backed.** The glossary is edited in a small multi-line text box in the Voice Settings card (user's choice at design review, 2026-07-08 — replaces the earlier "Edit Vocabulary…" external-editor button). The box shows the raw file, one term per line; edits write back debounced. The file stays the source of truth on the flat-file bus, so hand-editing it still works.
- **Hallucination guardrail is a UI caption.** Prompt words can hallucinate into near-silent audio (short clips are zero-padded to 1.5 s). The caption under the box says: nudges dictation toward these spellings — keep it short. No runtime heuristic.
- **Auto-detect fix is one expression.** `detectLanguage: lang == nil`. A pinned language behaves exactly as today; auto pays one extra decoder pass (milliseconds on the ANE).
- **Global only.** STT has no notion of the frontmost project, so no per-project vocabulary (unlike `OW_TTS_*`). Out of scope.

## Non-goals (YAGNI)

- No WER measurement harness (parked in `docs/UX-BACKLOG.md`: extend `app/Tools/STTDiag` into a fixed-corpus WER runner; it would have caught the 1.0.0 regression on day one).
- No model change: `openai_whisper-large-v3-v20240930_turbo` FP16 stays (1.93% WER LibriSpeech per Argmax; full large-v3 is the ceiling but ~2× size and far slower decode).
- No STT engine picker (decided 2026-06-20, PR #6 — don't relitigate).
- No external-editor affordance and no separate vocabulary window — just the in-card text box.

## Approach

### 1. `VocabularyPrompt` (`OpenWhispererKit`, pure, unit-tested)

New file `app/Sources/OpenWhispererKit/VocabularyPrompt.swift`:

```swift
public enum VocabularyPrompt {
    /// Parse glossary file text: one term per line, trimmed;
    /// blank lines and lines starting with # ignored.
    public static func terms(from text: String) -> [String]

    /// "a, b, c" — nil when terms is empty.
    public static func promptText(_ terms: [String]) -> String?

    /// How many leading terms fit the token budget. tokenCounts[i] is the
    /// encoded length of terms[i]; separatorCount is the encoded length of ", ".
    public static func fittingPrefixCount(tokenCounts: [Int], separatorCount: Int, budget: Int) -> Int
}
```

`budget` defaults to 96 at the call site (WhisperKit hard-trims at 111).

### 2. `SpeechTranscriber` integration (app target)

- New path `Paths.sttVocabulary` → `~/Library/Application Support/OpenWhisperer/stt_vocabulary`.
- In `transcribe(samples:language:)`, before building options: read the file (any read error → treat as absent), parse terms, per-term `wk.tokenizer?.encode(text:)` for counts, apply `fittingPrefixCount`, join the kept terms, encode the joined string once → `promptTokens`. Empty/missing file or nil tokenizer → `promptTokens: nil` (today's behavior exactly).
- Options become:

```swift
let options = DecodingOptions(
    language: lang,
    detectLanguage: lang == nil,      // lever 2: Auto-detect detects
    withoutTimestamps: true,          // lever 3: dictation needs no timestamps
    promptTokens: promptTokens,       // lever 1: vocabulary glossary
    suppressBlank: true,              // lever 3: OpenAI reference default
    chunkingStrategy: .vad            // lever 3: better seams on >30 s clips
)
```

- `os_log` when glossary terms are dropped by the cap.

### 3. Vocabulary text box (MenuBarView)

A compact multi-line editor in the Voice Settings card, below the Dictate picker. File-backed: loads `stt_vocabulary` on appear, writes back debounced (~0.5 s) on change and once more on disappear. No template file — a fresh install has no file, the box is empty, behavior is stock.

Copy is aimed at the app's core audience (developers driving Claude Code / Codex / Pi by voice):

- **Label:** `Vocabulary` with the inline hint `one term per line`.
- **Placeholder (empty state):** `WhisperKit` / `Codex CLI` / `Kokoro` — real terms from the product's own world.
- **Caption:** `Biases dictation toward these spellings — product names, CLI jargon, APIs. Keep it to a dozen or two.`

Styling follows the existing card controls (the `PortField` precedent shows text input works in this popover); a fixed ~5-line height with internal scroll keeps the card from growing unbounded.

### Error handling

Dictation must never fail because of the glossary: file-read errors, encode failures, and nil tokenizer all degrade to `promptTokens: nil`. Language detection failure inside WhisperKit falls back to `en` upstream (logged by WhisperKit).

### Testing

- `OpenWhispererKitTests`: new `VocabularyPromptChecks` group — parsing (comments, blanks, whitespace, CRLF), `promptText` joining and empty→nil, `fittingPrefixCount` budget math (keep-first, exact-fit, zero-budget, single-oversized-term).
- Both runners (`swift run OpenWhispererKitTests`, `swift run HookTests`) green.
- Manual feel-test after install: dictate glossary jargon with and without the file; dictate a Turkish sentence on Auto-detect; a normal English dictation for no-regression.

### Rollout

Worktree branch off `main` → single PR (to the fork `origin`, not `upstream`). After merge: `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh`, reinstall, relaunch (dictation blinks out ~10 s).
