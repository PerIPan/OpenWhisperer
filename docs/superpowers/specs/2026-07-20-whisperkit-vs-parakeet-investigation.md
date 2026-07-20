# WhisperKit vs Parakeet — STT engine investigation (revisit)

> **Status: open investigation, no decision.** Parked for the user to review later.
> Current shipping engine is **Parakeet TDT v3** (adopted 2026-07-13, WhisperKit removed).
> This doc gathers the evidence for/against switching back so the choice can be re-made
> deliberately rather than from memory.

## TL;DR

| | **Parakeet TDT v3** (current) | **WhisperKit** (removed) |
|---|---|---|
| Speed (on-device, warm) | **48–81 ms** / clip | 506–663 ms / clip (~8–10× slower) |
| Cold model load | **~12 s** | ~96 s |
| Accuracy (quiet, matched A/B) | draw — literal | draw — polished (edits, sometimes wrongly) |
| Noise robustness | weaker ⚠️ | **better** |
| Jargon (no glossary) | **nailed it** (Kokoro/Codex/Sentry/Claude) | needed `promptTokens` + a fork pin |
| Languages | ~25 **European** | ~99 (broad multilingual incl. Turkish, Arabic, CJK) |
| Punctuation / formatting | literal (fillers, repairs, comma spray) | auto-edits/polishes; can hallucinate on silence |
| Library | FluidAudio (also our TTS) | WhisperKit + a fork pin |
| Runtime | CoreML / ANE | CoreML / ANE |

**One-line framing:** Parakeet is dramatically faster and jargon-friendly with a single
shared library (FluidAudio) for both STT and TTS; WhisperKit wins on **language breadth**
and **noise robustness**. The 2026-07-13 migration traded the latter two away for speed +
simplicity, on the user's call.

## Measured on-device (same clips, warm models, production configs)

From the engine-configurability spec's 2026-07-13 addendum
([`2026-06-20-engine-configurability-design.md`](2026-06-20-engine-configurability-design.md)):

- **Speed:** Parakeet 48–81 ms vs Whisper 506–663 ms per 2.6–6 s clip (~8–10×). Cold load
  ~12 s vs ~96 s. The felt sluggishness that triggered the whole re-evaluation was Whisper's
  decode + load cost.
- **Accuracy (quiet):** a draw with *opposite failure styles*. Parakeet won a pair on words
  (Whisper hallucinated "art arising movements" vs Parakeet's correct "art arrives in
  movements"); Whisper won a pair on polish (capitalisation, further/farther, no doubled
  words). Under vacuum-cleaner noise both degraded — **Parakeet worse**.
- **Jargon:** Parakeet transcribed Kokoro/Codex/Sentry/Claude Code correctly with **no
  glossary**; Whisper had needed `promptTokens` (plus an upstream prefill-EOT bug and a fork
  pin) for the same.

## Why this is worth re-opening

The 2026-07-13 decision recorded two explicit **revisit triggers**, both of which are live
questions again:

1. **Language breadth.** Parakeet covers ~25 European languages; WhisperKit covered ~99. The
   *original* rejection of Parakeet (2026-06-20) was driven by a **Turkish** requirement + a
   macOS-14 floor concern. If non-European languages matter, that's the strongest case for
   Whisper. (Note: Dutch, German, etc. are fine on Parakeet — they're European.)
2. **Noise robustness.** The one axis Whisper clearly won. If dictation-in-noise quality is a
   recurring complaint, that's the trigger.

## Alternatives on the table (not just a binary)

- **Apple SpeechAnalyzer** (macOS 26+). A third-party LibriSpeech benchmark (M2 Pro) put it at
  **2.12% WER clean / 4.56% other, ~3× faster than Whisper Small** — strong on the *noise*
  axis where Parakeet is weakest, with **zero model download** and no ANE contention with
  Kokoro. Limits: macOS 26 API floor, ~30 locales, English-only benchmark on read audiobook
  speech (no jargon/filler evidence). Candidate if the noise trigger fires.
- **FluidAudio vocabulary boosting** (CTC keyword spotter + `configureVocabularyBoosting`) —
  the in-family answer if Parakeet jargon ever regresses; needs an extra model download.

## External reference

- **Reddit — "30 days testing Parakeet v3 vs Whisper" (r/LocalLLaMA):**
  <https://www.reddit.com/r/LocalLLaMA/comments/1nf10ye/30_days_testing_parakeet_v3_vs_whisper/>
  *(Automated fetch is blocked by Reddit — read directly. Add its key takeaways here on review.)*

## Open questions (for the user, later)

1. Do we need any **non-European language** (Turkish, Arabic, CJK, …)? If yes → strong pull
   back to Whisper (or a dual-engine seam).
2. Is **dictation-in-noise** a real, recurring problem in daily use, or a lab artifact?
3. Is the **literal transcript** (fillers/repairs kept, comma spray) a feature (fidelity) or a
   nuisance (want auto-polish) for how you actually dictate?
4. Worth reviving the **`stt_engine` seam** (per-dictation A/B switch) that the migration
   deleted, so this can be answered empirically instead of re-litigated? Or spike
   **SpeechAnalyzer** as a third option first?

## Recommendation (tentative, pending the answers above)

**Stay on Parakeet** unless Q1 (non-European language) is a yes. The speed win is large and
felt daily; the losses (noise, polish) are situational. If noise becomes the pain point,
**spike SpeechAnalyzer before** re-adding WhisperKit — it targets exactly that axis without
the ANE contention or the fork-pin maintenance WhisperKit carried.
