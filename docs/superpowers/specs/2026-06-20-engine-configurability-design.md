# Configurable STT/TTS engines (FluidAudio + WhisperKit)

**Date:** 2026-06-20
**Status:** Approved (brainstorming) — pending implementation plan

## Goal

Let the user choose, from the menubar, which engine drives each side of voice
mode, so we can install the app and feel-test FluidAudio's ASR (notably for
Turkish) against the shipped WhisperKit path without losing the latter.

- **STT picker:** WhisperKit `large-v3-turbo`, FluidAudio Parakeet v3, FluidAudio
  Nemotron-multilingual.
- **TTS picker:** FluidAudio Kokoro (today's engine), FluidAudio Supertonic3.
- **Defaults on first launch:** STT = Nemotron-multilingual, TTS = Kokoro.
- WhisperKit is **retained** as a selectable engine, not removed.

### Why this, why now

The trigger was the question "would consolidating onto FluidAudio lose Turkish
dictation?" The answer turned out to be no: FluidAudio ships a
Nemotron-multilingual ASR model that lists Turkish (`tr-TR`, ~11% WER), and a
Supertonic3 TTS engine whose locale list includes `tr`. Rather than commit to a
blind swap, we make both engines selectable and let real use decide. Keeping
WhisperKit (Whisper's ~99-language breadth, already proven) as the safe fallback
makes the change reversible.

## Non-goals (YAGNI)

- No removal of WhisperKit.
- No per-engine voice catalog for Supertonic3 in v1 — it uses a single default
  voice. (Kokoro keeps its existing voice picker.)
- No SenseVoice or older Parakeet (v2 / CTC) engines in the menu.
- No change to the `:8000` HTTP shim, the voice-turn handshake, barge-in, or
  sentence-by-sentence streaming playback.

## Approach

A small **protocol seam per side**, mirroring the app's existing
one-actor-per-engine isolation. Chosen over an enum-with-internal-`switch`
(tangles two libraries into one type) and over a closure/factory (weaker test
boundary).

- Today's `SpeechTranscriber` → `WhisperKitTranscriber` (behavior unchanged),
  conforming to a new `Transcriber` protocol.
- Today's `KokoroTTS` → `KokoroSynthesizer`, conforming to a new
  `SpeechSynthesizer` protocol.
- New conformers: `FluidAudioTranscriber`, `Supertonic3Synthesizer`.
- `DictationManager` / `ServerManager` hold the **active** conformer, selected
  from a pref, rebuilt lazily on change (no app restart).

## Components

### 1. Engine model — pure, testable (`OpenWhispererKit`)

Two enums with stable raw strings (the pref value), display labels, and the
FluidAudio model id where applicable:

- `STTEngine { whisperLargeV3Turbo, parakeetV3, nemotronMultilingual }`
- `TTSEngine { kokoro, supertonic3 }`

Plus `parse(_:) -> Engine` with default-fallback. This is the genuinely
unit-testable unit (string ↔ enum, default selection, label mapping) and lives
in the Kit target with tests in `OpenWhispererKitTests`. The model **wrappers**
stay in the `OpenWhisperer` app target (they touch WhisperKit/FluidAudio and
aren't CLT-unit-testable).

### 2. Prefs & migration

Two new flat files in `Paths.swift`: `stt_engine`, `tts_engine`, read/written
like `tts_voice` / `stt_language`. `VoiceMigration` seeds first-run defaults
(`stt_engine = nemotron-multilingual`, `tts_engine = kokoro`). Existing prefs
unchanged.

### 3. STT seam

```
protocol Transcriber {
    func prepare() async throws
    func transcribe(_ pcm: [Float]) async throws -> String
}
```

- `WhisperKitTranscriber` — today's `SpeechTranscriber`, verbatim behavior.
- `FluidAudioTranscriber(engine:)` — offline-first from `~/.cache/fluidaudio`
  (same pattern as Kokoro), parameterized by the chosen FluidAudio model.

`DictationManager` builds the active transcriber from `stt_engine`; changing the
pref rebuilds it lazily on the next dictation. The `stt_language` pref is passed
as a hint to engines that accept one (Whisper; Nemotron language-id
conditioning) and ignored by auto-detect engines (Parakeet).

**Known integration wrinkle (grounded in the FluidAudio source):**
- Parakeet v3 has a clean batch surface: `AsrModels.downloadAndLoad()` →
  `UnifiedAsrManager.transcribe(_ samples: [Float]) async throws -> String`.
- Nemotron-multilingual is exposed via `StreamingNemotronMultilingualAsrManager`
  (a streaming manager), not a one-shot call. For a finite dictation clip,
  `FluidAudioTranscriber` must feed the recorded PCM through a streaming session
  and finalize to a single string. This is more integration than Parakeet and is
  the main implementation risk for the default engine — to be detailed in the
  plan.

### 4. TTS seam

`SpeechSynthesizer` protocol over what `KokoroTTS` already exposes.
`Supertonic3Synthesizer` wraps FluidAudio's `Supertonic3Manager.synthesize(...)`
(confirmed public; its own `Supertonic3VoiceStyle` + offline-first model store).
`ServerManager` / `TTSPlaybackController` pick from `tts_engine`. The existing
Kokoro voice picker is shown only when Kokoro is selected; Supertonic3 uses its
default voice (v1). Sentence-by-sentence streaming, barge-in, and `:8000` are
untouched.

### 5. UI (`MenuBarView`)

Two new `OWMenuPicker`s — STT engine (3 options) and TTS engine (2 options) —
beside the existing language/voice pickers. The voice picker becomes conditional
on Kokoro. Selecting an engine writes its pref; first use after a switch shows
the existing "Loading speech model…" overlay state while the model loads.

### 6. Download UX & the firewall

New models download on first selection. Given the developer's Little Snitch /
HF-Xet block, a first switch to an uncached model can fail offline. The overlay
must surface a clear "model failed to download" state (reusing the existing
`sttStatus` / `loadFailed` plumbing) rather than silently falling back.

## Testing

- Unit tests (`OpenWhispererKitTests`): enum raw-string round-trip, `parse`
  default-fallback, label mapping.
- Transcription / synthesis paths are integration-only under CLT — verified by
  the hands-on feel-test.
- `swift run OpenWhispererKitTests` and `swift run HookTests` must stay green.

## Outcome / Decision (2026-06-20)

**Built, feel-tested, and NOT adopted.** The configurable engines were implemented
end-to-end (PR #6) and tried on-device. Conclusion: the existing defaults —
**WhisperKit for STT, Kokoro for TTS** — are the right choice, and the
configurability isn't worth its complexity here. PR #6 was closed unmerged; only its
one independent improvement (a clearer voice nudge: "only the first paragraph is
read aloud") was kept and cherry-picked to `main`.

What the feel-test showed:
- **Nemotron** transcribes English noticeably worse than Whisper (rougher, mangles
  acronyms / programming jargon). Whisper's clean output (drops "uh/um", handles
  jargon) is intrinsic to the model — not post-processing we could bolt onto the others.
- **Parakeet v3** has **no Turkish** (25 European languages only), so it can't be a
  general default for this user.
- **Whisper large-v3-turbo** is the all-rounder: best English *and* ~99 languages
  incl. Turkish (confirmed live). It stays the sole STT engine.
- The FluidAudio ASR models also cost ~1.1 GB on disk (Parakeet 461 MB + Nemotron
  635 MB) for no benefit over Whisper.

Lessons worth keeping:
- **FluidAudio model/language map:** Parakeet = European (no Turkish); Nemotron =
  ~40 langs incl. Turkish but weaker English; SenseVoice = 5 langs. TTS: Kokoro =
  en/zh/ja only; Supertonic3 supports Turkish. Whisper comes from **WhisperKit, a
  separate library — FluidAudio has no Whisper** — which is why the app pulls in both.
- **FluidAudio ASR models cache to `~/Library/Application Support/FluidAudio/Models`**
  (not `~/.cache/fluidaudio`, which holds the Kokoro TTS chain).
- **Kokoro voice packs download on demand**; a non-default voice (e.g. `am_michael`)
  needs a fetch the dev's Little Snitch blocks, and a missing pack makes TTS silently
  fall through. Stick to the cached `af_heart`, or allow the fetch once.

The protocol-seam implementation (`Transcriber` / `SpeechSynthesizer`,
`FluidAudioTranscriber` with Parakeet-batch + Nemotron-streaming) lives on the
abandoned `worktree-engine-config` branch / PR #6 if ever revisited.

### Addendum (2026-07-13) — constraints changed, Parakeet re-opened

The user explicitly waived two constraints this Outcome rested on: **Turkish
support no longer matters**, and **the macOS 14 deployment floor no longer
matters**. Consequences for the record:

- The case against **Parakeet v3** was almost entirely the Turkish constraint.
  The feel-test's "rougher English / mangled jargon" evidence came from
  **Nemotron** (the test build's default); Parakeet's English was never put
  through the feel-test. With Turkish waived, Parakeet is un-rejected —
  status: **worth a proper English evaluation** (own-corpus WER harness, incl.
  the jargon/glossary cases), not adopted. Note `stt_vocabulary` /
  `promptTokens` is Whisper-specific and has no Parakeet equivalent.
- **TTSKit (Qwen3-TTS, in the already-pinned argmax-oss-swift SDK)** was
  disqualified in the 2026-07-12 research pass on the macOS 15+ API floor +
  no Turkish; both grounds are now waived. Status: eligible for a spike;
  no quality-vs-Kokoro comparison exists anywhere yet.
- Nothing is decided beyond re-opening evaluation. Whisper large-v3-turbo +
  Kokoro remain the shipped engines until a harness says otherwise.

## Success criteria (the feel-test)

1. App launches defaulting to Nemotron STT + Kokoro TTS; dictation works.
2. Dictating the earlier Turkish phrase via Nemotron produces correct Turkish
   text (compare against the WhisperKit transcription already observed).
3. Switching STT engine in the menu takes effect on the next dictation with no
   restart; the overlay reports load/download status correctly.
4. Switching TTS to Supertonic3 produces audible spoken output; switching back
   to Kokoro restores the voice picker.
5. WhisperKit remains selectable and behaves exactly as before.

## Rollout

PR-path work (multiple files, new dependency surface, user-visible): a
`.claude/worktrees/<slug>` branch off `main`, built with `OW_SIGN_IDENTITY` so
TCC grants survive the rebuild. Version bump (`build-dmg.sh` + `Info.plist`)
on merge.
