# Custom vocabulary (glossary revival) — design

**Date:** 2026-07-17
**Status:** Approved (Hakan, in-session)
**Context:** Parakeet's accepted trade-offs include jargon/homophone slips (observed live: "test one two three" → "tip"/"six one two three"). The old Whisper `promptTokens`/`stt_vocabulary` glossary was removed 2026-07-13 as Whisper-only. This revives the *idea* at the text layer.

## What

An optional user glossary that corrects dictation transcripts after Parakeet returns them. The user enters words/phrases in Settings → Input ("Custom vocabulary", comma- or newline-separated); every dictation's transcript is fuzzy-corrected against that list before being typed into the target app. Empty/missing glossary = feature inert.

**Approach chosen: fuzzy text post-correction** (pure Swift, no model download, unit-testable, works with the existing batch pipeline). Explicitly *not* chosen for v1 — recorded as the upgrade path if fuzzy proves insufficient: FluidAudio's acoustic boosting (`SlidingWindowAsrManager.configureVocabularyBoosting` + ~110M CTC keyword-spotter download), which is welded to the streaming manager we don't use, and whose model download is at risk on this machine (Little Snitch blocks the HF Xet CDN). Also non-goals: per-project override, phonetic matching.

## Components

### Kit — `VocabularyCorrector` (pure, tested)

- `parseGlossary(_ raw: String?) -> [String]`: split on commas and newlines, trim, drop empties, dedupe case-insensitively (first casing wins), cap at 200 terms.
- `apply(_ text: String, glossary: [String]) -> String`:
  - Tokenize preserving separators (runs of letters/digits/apostrophes = words; everything else passes through untouched).
  - Terms scanned longest-first (word count, then length). Each term matches word n-grams: windows of the term's own word count (exact + fuzzy) and word count + 1 (fuzzy only — absorbs splits like "code x" → "Codex").
  - **Recase tier:** case-insensitive exact match adopts the glossary casing.
  - **Fuzzy tier:** Levenshtein ≤ 1 for terms of 4–5 chars, ≤ 2 for 6–9, ≤ 3 for 10+; terms under 4 chars are recase-only. A candidate that exactly equals a *different* glossary term is never fuzzy-captured.
  - Consumed spans aren't re-matched; punctuation/spacing survive byte-for-byte.

### App

- `Paths.sttVocabulary` → `stt_vocabulary` flat file (the historical name, revived).
- `DictationManager.transcribeSTT`: after `parakeet.transcribe` returns, `VocabularyCorrector.apply(text, glossary: parseGlossary(<file>))` — a per-dictation file read, like other prefs.
- Settings → Input: new "Custom vocabulary" section between Language and App Focus — multi-line `TextEditor`, write-through on change, file deleted when emptied, footer explaining the fuzzy correction.

## Testing

Kit checks: parse (split/trim/dedupe/cap), recase, fuzzy hit ("cocorro"→"Kokoro") and principled miss ("six" ≠ "test" at distance 3), split absorption ("code x"→"Codex"), multi-word terms, short-term protection, cross-term capture guard, punctuation preservation, empty no-op. On-device: dictate jargon with and without the glossary.

## Versioning & docs

1.9.0 → 1.10.0. AGENTS.md's "stt_vocabulary … is gone" note gets amended (revived as text-layer fuzzy correction, not promptTokens).
