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
