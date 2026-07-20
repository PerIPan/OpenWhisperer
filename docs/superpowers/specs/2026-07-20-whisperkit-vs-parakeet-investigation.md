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
   *(2026-07-20 addendum: Nemotron 3.5 is an in-family candidate here (incl. Turkish) —
   but it already lost a 2026-06-20 English feel-test; see below.)*
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
  Read 2026-07-20 (via real browser; Reddit blocks automated fetch). A macOS
  dictation/meeting team's 30-day integration report, plus comments. Takeaways:
  - **Corroborates the trade.** ~10× faster than Whisper (~30 s per hour of audio;
    an Argmax dev cites ~9 s/hour on M3 Max, with a base M1 Air only ~50 % slower),
    "a bit less accurate… matches big Whisper for general discussion". Their verdict
    is literally *both*: Whisper the Swiss-army knife (dictionary, breadth), Parakeet
    the race car.
  - **Jargon was their killer too** ("Parakeet" → "Parakit", acronyms, company names)
    — solved with LLM post-processing, i.e. the same text-layer answer as our
    `VocabularyCorrector`. Argmax confirmed in-thread that Parakeet custom vocabulary
    on their side is a **Pro SDK** feature.
  - **Health warning for our documented escalation path.** A competing dictation-app
    vendor (in-thread comment, ~11k benchmark runs across 4 engines; self-promotional,
    weigh accordingly) reports FluidAudio's CTC vocabulary boosting is a **tuning
    nightmare in practice**, especially multilingual: phonetic false positives
    ("parles"/"parce" → "Parakeet", "si tu" → "SwiftUI" in French) survived threshold
    tuning, confidence gates, and a spell-check revert filter; they ship it as an
    experimental opt-in, useful mainly for English-only jargon-heavy workflows. If our
    jargon trigger fires, budget real tuning time — or stay text-layer.
  - **The 25 languages are uneven.** Dutch was "pretty rough" per the OP; a German
    fixture hit a confident early-stop with a wrong-language fallback. Tempers this
    doc's "Dutch, German are fine on Parakeet" note — coverage ≠ uniform quality.
  - Misc: Parakeet degrades on very fast speech (fine at conversational pace); the
    same vendor's matrix has SpeechAnalyzer winning clean accented English, Parakeet
    winning **disfluent dictation**, WhisperKit winning brand names — "no single
    winner".

## Open questions (for the user, later)

1. Do we need any **non-European language** (Turkish, Arabic, CJK, …)? If yes → strong pull
   back to Whisper (or a dual-engine seam). *(2026-07-20: Nemotron 3.5 covers Turkish
   in-family but already lost an English feel-test — viable only behind a per-language
   seam or after re-validation; see addendum.)*
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

*2026-07-20 revision (corrected same day after review):* if Q1 fires, the realistic options
are WhisperKit back as the multilingual engine (mechanically ≈ reverting PR #21 — see
addendum) or a **per-language seam** using Nemotron 3.5 only for the non-European language.
Nemotron as the sole engine was already feel-tested and rejected on English quality
(2026-06-20); don't re-spike it as a wholesale replacement without re-validating that first.

## 2026-07-20 addendum — findings from a mobile Claude session

Source: a same-day conversation walking the Argmax/FluidAudio ecosystem and engine
trade-offs (<https://claude.ai/share/e6e923ca-5894-4572-a685-e0c507ab23d7>). New evidence
only; the on-device measurements above are unchanged.

### Nemotron 3.5 complicates the binary (revises Q1 — with a known strike against it)

FluidAudio ships NVIDIA **Nemotron 3.5 ASR** on-device
(`Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, encoder int8 on the ANE): ~40
locales in one 600M checkpoint via language-ID prompt conditioning — **including Turkish
(tr-TR, ~11 % WER)**, the language whose absence drove the original 2026-06-20 Parakeet
rejection. So the language-breadth trigger has an in-family candidate.

**But it was already evaluated — and quality, not language, was the blocker** (correction
from review; the first cut of this addendum missed it). The 2026-06-20
engine-configurability spike made Nemotron-multilingual the *default* engine precisely for
Turkish, and a same-day live feel-test killed it: English noticeably rougher than Whisper,
mangled acronyms and programming jargon ("direct test" → "director") — the exact axis agent
dictation lives on. The default was flipped back to Whisper the same day; no formal
benchmark, but the gap was immediate and decisive. There's also an integration wrinkle:
Nemotron is exposed as a streaming manager, so batch dictation clips need a
feed-and-finalize wrapper (more work than Parakeet's one-shot API).

Net: if Q1 fires, Nemotron is realistic only behind a **per-language seam** (non-European
language → Nemotron, everything else → Parakeet), or after a fresh feel-test shows its
English has materially improved. As a wholesale engine it already lost once.

### Code-switching: nobody wins

Mid-utterance switching (Dutch↔English in one breath) is weak across the board. Whisper
decodes with exactly **one language token**, so its ~99 languages don't buy switching —
rapid alternation degrades it despite the breadth. Parakeet's auto-detect likewise locks
onto one language per segment. Nemotron's prompt conditioning is architecturally better
suited but has no published code-switch benchmark. The TL;DR table's Languages row
overstates Whisper's practical advantage for a bilingual speaker; loanwords survive fine
on any engine, clause-level switching is rough on all of them.

### Agent dictation is turn-based — reinforces the recommendation

Dictating to a coding agent is push-to-talk over a finished utterance: the agent's own
thinking time dwarfs any STT latency gap, so what matters is **final-transcript accuracy on
the exact string the agent will act on**. Whisper's known habit of inventing text during
mid-sentence pauses is a real liability here (a hallucinated word becomes a wrong command);
Parakeet barely hallucinates on silence. Streaming engines buy nothing in this loop —
another reason batch Parakeet fits the product's primary use case.

### External corroboration of the on-device numbers

Open ASR Leaderboard: Parakeet TDT v3 ~6.32 % avg English WER vs Whisper large-v3 ~7.44 %
(~15 % relative reduction from a model under half the size); throughput ~3,300× real-time
vs ~69×. FLEURS across the shared 25 languages: Whisper slightly ahead on most individual
languages. English-only Parakeet v2 (~6.05 %) is a hair better than v3 — the usual
multilingual tax. Consistent with our matched A/B: speed decisively Parakeet, quiet
accuracy roughly a draw, non-English leaning Whisper.

### "Switching back": mostly a revert, but into a commercially gated ecosystem

Correction from review: the first cut here claimed re-adoption would be "a fresh
integration, not a revert" — wrong. **The app already rode the v1.0.0 transition** before
the removal: v1.5 raised the floor 0.9 → 1.0.0, hit a v1.0.0 quality regression (reverted
to 0.18.0, then restored 1.0.0 with a tokenizer-path fix), and ended pinned to a fork =
v1.0.0 + the prefill-EOT fix (synced to upstream main as of 2026-07-08). Re-adding
WhisperKit is therefore mechanically ≈ reverting PR #21 and restoring that pin (or plain
upstream, if the EOT abort is fixed by now — check before pinning).

What the May 2026 Argmax restructuring (`argmax-oss-swift`) changes is the ceiling, not
the floor: the capabilities that would *justify* a switch — real-time streaming, the
~9×-faster model variants, audio-based custom vocabulary — are **Pro-gated** behind
per-device licensing (`ax_` key). The OSS tier we'd return to is the same ~100-token
`promptTokens` biasing we already carried a fork for. FluidAudio ships custom vocabulary
in the open library. So: cheap to go back, but going back buys the same WhisperKit we
left, not the faster Pro one.

### Footnotes

- **Licensing:** Parakeet is CC-BY-4.0 — NVIDIA attribution is owed in the About
  screen/docs today, engine debates aside. Whisper is MIT.
- **Distribution (orthogonal):** the session independently reconfirmed the MAS blocker —
  since Feb 2026 App Review rejects Accessibility-based text injection (guideline 2.4.5,
  no-exceptions precedent) — consistent with the existing distribution notes.
