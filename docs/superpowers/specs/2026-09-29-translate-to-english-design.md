# Translate to English — design

**Status:** design approved in conversation; spec in progress. Not yet implemented.
**Date:** 2026-09-29
**Target release:** 2.0.7 (owner's call — includes the `ModelStorage` fix already on `main`)

---

## RESUME HERE (state as of 2026-09-29 ~22:20)

If a session ended abruptly, this section is the handoff.

**Done and committed to `main`:**
- `6192d0e` — `fix(models): reclaim the installed app's ANE cache too`. Unrelated pre-existing
  bug found during this work; `ModelStorage.locations` listed only the dev-build cache path.

**Done, uncommitted, in the working tree (a no-op against turbo — see below):**
- `Paths.swift` — added `sttTranslate` flag path
- `SpeechTranscriber.swift` — `transcribe(samples:language:translate:)`, sets `task:`
- `DictationManager.swift` — `readTranslate()`, threaded through both capture points
- `Settings/DictationTab.swift` — checkbox + conditional caption **(must MOVE to AdvancedTab)**
- `AGENTS.md` — `stt_translate` documented in the State & IPC list

**Temporary, must be reverted before any commit:**
- `app/Package.swift` — carries a `TranslateSpike` executable target whose sources live in
  gitignored `app/Tools/`. **This breaks `swift build` on a fresh clone.** `git checkout
  app/Package.swift` and `rm -rf app/Tools/TranslateSpike`.

**Remaining work:** see "Implementation plan" below.

**Owner instruction:** when implementation is complete, have the `swift-expert` agent review it.

---

## The problem

The owner wants to dictate a non-English conversation (the motivating case was a live **Dutch**
conversation) and have **English text** typed into whatever app is focused — e.g. TextEdit. This
is a standalone live-translation use case; it is *not* about the coding agent, which already
reads all 100 languages natively. That distinction matters: an early draft of this analysis
argued the feature was redundant because Claude Code understands Dutch. It is not redundant,
because the value is English text on screen for a human to read.

## The blocking discovery

**The pinned model cannot translate.** `SpeechTranscriber.modelName` is
`openai_whisper-large-v3-v20240930_turbo`. OpenAI's turbo fine-tune deliberately **excluded
translation data**, and the model returns the original language even when `task=translate` is set.

Measured on this machine, real audio, the app's real model:

```
es   + transcribe -> Esta es una grabación de LibriVox. Todas las grabaciones...
es   + TRANSLATE  -> Esta es una grabación de LibriVox. Todas las grabaciones...   ← identical
auto + TRANSLATE  -> Esta es una grabación de LibriVox. Todas las grabaciones...   ← identical
en   + TRANSLATE  -> This is a LibriVox.                                           ← mangled
```

The `task: .translate` wiring is *correct*; it addresses a capability this checkpoint lacks.
Confirmed independently: the model's own `config.json` reports `decoder_layers: 4` (full large-v3
has 32), and `task_to_id` does contain `translate: 50359` — the token exists, the training does not.

Sources: [openai/whisper#2363](https://github.com/openai/whisper/discussions/2363),
[model card](https://huggingface.co/openai/whisper-large-v3-turbo).

## Model selection

Measured sizes from the live `argmaxinc/whisperkit-coreml` repo:

| Variant | Size | Translates | Decoder layers |
|---|---|---|---|
| `large-v3-v20240930_turbo` (current) | 1.5 GB | **No** | 4 |
| `large-v3_947MB` | 948 MB | Yes | 32 |
| `medium` | 1.53 GB | Yes | 24 |
| `small` | 486 MB | **Unusable — see below** | 12 |
| `large-v3` (uncompressed) | 3.09 GB | Yes | 32 |

**`openai_whisper-large-v3_947MB` is the choice.**

**`small` is a trap and must not be used.** `SpeechTranscriber.loadWhisperKit` hardcodes
`tokenizerFolder: hubBase/models/openai/whisper-large-v3`, and WhisperKit takes the first folder
containing `tokenizer.json`. large-v3's vocabulary added `<|yue|>`=50358, which shifts every
special token after it: `<|translate|>`=50359, `<|transcribe|>`=50360. In a non-v3 vocabulary
**id 50359 *is* `<|transcribe|>`**. Prefill would say translate, the decoder would hear
transcribe, and the output would be byte-identical source-language text — reproducing the exact
bug above from a different cause, silently, with nothing thrown (`download: false` never
consults `tokenizerNameForVariant`). Any future use of a non-large-v3 variant must make
`tokenizerFolder` model-derived first.

## Measured performance (`large-v3_947MB`)

```
TRANSLATE  lang=es   2.04s -> "This is a LibriVox recording. All LibriVox recordings are public domain."
TRANSLATE  lang=auto 2.10s -> "This is a LibriVox recording. All LibriVox recordings are public domain."
```

| | Turbo | large-v3_947MB |
|---|---|---|
| decode (7.7 s clip) | 0.78–0.91 s | **2.0–2.3 s** (~2.4×) |
| cold load + ANE compile | ~101 s | ~126 s (incl. 948 MB download) |
| **warm load (already compiled)** | — | **1.7 s** |
| on-disk | 1.5 GB | 911 MB |

The expensive step is a **one-time ANE compile per model**; afterwards loads are ~1.7 s. A 45 s
first-inference warmup was observed once, immediately after a fresh compile, and did **not**
recur on the next run — it is a post-compile artifact, not a per-launch cost.

Component split (note the shape inverts vs turbo — the 947MB build is quantized throughout):

| Component | Turbo | large-v3_947MB |
|---|---|---|
| AudioEncoder | 1.2 GB | 343 MB |
| TextDecoder | 328 MB | 568 MB |

## Design: swap the one model, do not add a second

**Decision: one model resident at a time.** Ticking the setting swaps the active model to
`large-v3_947MB` (and sets `task: .translate`); unticking swaps back to turbo.

Why swap rather than hold both:

- Every model-status surface in the app is single-valued — `sttStatus` / `sttModelReady` /
  `sttFailed` (`DictationManager.swift:40-44`), consumed by the menubar hourglass
  (`OpenWhispererApp.swift:107`), the overlay headline (`TranscriptionOverlay.swift:385-392`),
  first run (`FirstRunView.swift:145-152`), GeneralTab's banner (`GeneralTab.swift:248-300`),
  AdvancedTab (`:25-29`), `Diagnostics.swift:28-31`, `ServerManager.swift:17`. With one model
  resident these all keep their current meaning untouched. With two they misreport.
- No RAM doubling. The two encoders are the same byte count but different content, so there is
  no dedup — a second resident model re-pays its full encoder.
- A second `SpeechTranscriber` would be a second serialization domain, breaking AGENTS.md's
  documented invariant that these actors exist to serialize the single ANE.
- Precedent: `6808df7` added a second STT engine behind an `stt_engine` pref and handled exactly
  this by picking **one engine per session**.

Cost accepted: while translate mode is on, *all* dictation runs at ~2.0 s instead of ~0.8 s.
That is acceptable because it is a mode the user enters deliberately for a conversation.

### Download consent (owner's design — this is what defuses the watchdog)

Ticking the setting must **not** trigger the download from inside a dictation. Flow:

1. Tick → sheet: "Translation needs a different speech model (948 MB, one-time download)."
2. Approve → download + ANE compile, reusing the existing progress handler (~2 min)
3. Model becomes active; the setting goes live
4. Untick → swap back to turbo (~1.7 s, both already compiled)

This matters because `sttWarm` is a single `Bool` (`DictationManager.swift:83`) set true by
turbo's launch load, so `transcriptionTimeout()` (`:258-259`) returns **35 s**. A cold second-model
load inside a dictation would blow that budget every time, the watchdog at `:636` would cancel the
task, and the audio is already gone (`AudioRecorder.exportPCMFloat()` drains `pcmBuffers`), so the
user would lose the sentence and loop. Moving the load to consent time removes the problem rather
than papering over it.

### Placement (owner's call)

- **Advanced → Models card, after the "TTS engines" row.** Deliberately not prominent. It sits
  directly under the `Whisper STT: <modelName>` row, which makes the model swap visible and
  self-explanatory.
- **General → About card:** mention translation in the closing feature sentence.
- **`engineRow` currently hardcodes "WhisperKit large-v3 turbo"** (`GeneralTab.swift`) — this
  becomes false the moment the model swaps and must read the active model name. There is a
  comment immediately above warning that hardcoded copy in this card has already shipped wrong
  once.

## Implementation plan

1. `SpeechTranscriber.modelName` → dynamic, driven by the `stt_translate` pref; `cachedModelFolder`
   and `isModelCached` follow it automatically. Add a model-swap path that unloads
   (`WhisperKit.unloadModels()`, currently never called anywhere) and reloads.
2. Move the checkbox out of `DictationTab` into `AdvancedTab`'s Models card, with states:
   not-downloaded / downloading(progress) / ready / failed.
3. Consent sheet + download, wired to the existing `setDownloadProgressHandler`.
4. `GeneralTab`: dynamic model name in `engineRow`, translation in the feature sentence.
5. Disk disclosure: `ModelStorage` should account for two possible Whisper models.
6. `AGENTS.md` + `README.md` (Dictation list at :145; the Tip at :257 advises pinning a language,
   which collides with translate mode preferring Auto-detect).
7. Version bump to 2.0.7 + release notes (owner's call, owner-requested).
8. **`swift-expert` agent review before commit** (owner instruction).

## Mixed-language behaviour — measured, and it needs no guard

The obvious real-world failure mode is "translate mode is on, but the user just spoke English".
On turbo that case mangled output (`en + TRANSLATE -> "This is a LibriVox."`). On
`large-v3_947MB` it does **not**: English passes through cleanly and identically to a plain
transcribe.

```
--- en.aiff (spoken: en) ---
transcribe lang=en    2.28s -> I would like to review the pull request before tomorrow morning's meeting, and then we can discuss the release.
TRANSLATE  lang=en    2.26s -> I would like to review the pull request before tomorrow morning's meeting, and then we can discuss the release.
TRANSLATE  lang=auto  2.44s -> I would like to review the pull request before tomorrow morning's meeting, and then we can discuss the release.

--- nl.aiff (spoken: nl) ---
transcribe lang=nl    2.62s -> Goedemorgen allemaal, ik denk dat we de vergadering van volgende week moeten verplaatsen naar donderdag.
TRANSLATE  lang=nl    1.81s -> Good morning everyone, I think we have to move the meeting to Thursday.
TRANSLATE  lang=auto  1.97s -> Good morning everyone, I think we have to move the meeting to Thursday.

--- es.aiff (spoken: es) ---
TRANSLATE  lang=es    2.84s -> Hello, good morning. I would like to know if the dictation system works correctly when I speak Spanish. I hope the automatic translation to English works well.
```

Consequences for the design:

- **No guard is needed.** Translate mode can stay on across a bilingual conversation: Dutch comes
  out English, English stays English. This was the main open risk and it is closed.
- **Auto-detect is viable**, costing ~0.2 s over a pinned source language and producing identical
  text. It is the right setting for a mixed conversation. The app's default is `en`, which is
  wrong for this mode, so the setting's caption should point at Auto-detect. Do **not** silently
  override the user's Language choice — pinning is still slightly faster and more accurate when
  the conversation really is single-language.
- Translation quality is good but not lossless: "de vergadering van volgende week" → "the meeting"
  dropped "next week's". Worth knowing; not a blocker for the use case.

## Cleanup already performed

~12.7 GB reclaimed: a 3.0 GB orphan model that review subagents downloaded into the production
hub, 7.5 GB + 1.3 GB of interrupted ANE compile bundles from spike processes, and a 914 MB scratch
download. Note for future work: an interrupted ANE compile leaves a full-size `.tmp.<pid>` bundle
behind, never resumes it, and does not dedup across processes — kill a compiling model load and it
costs ~1.2 GB of cache each time.
