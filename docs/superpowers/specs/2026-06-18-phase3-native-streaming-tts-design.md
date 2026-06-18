# Phase 3 — Native Streaming TTS + In-Process Barge-in — Design Spec

- **Date:** 2026-06-18
- **Branch:** `phase3-streaming-tts`
- **Status:** Approved (brainstorming) — pending implementation plan
- **Topic:** Move TTS playback into the app; sentence-pipelined synthesis; in-process barge-in.
- **Predecessors:** Phase 1 (native STT), Phase 2b (native TTS via FluidAudio, PR #1). Supersedes the
  Python-era `docs/superpowers/specs/2026-06-14-tts-streaming-design.md`.

## 1. Problem

Phase 2b made TTS native (`KokoroTTS` actor + `TTSHTTPServer` on :8000) but kept the **playback model
from the Python era**:

- The bash hook (`hooks/tts-hook.sh`) still tries a **dead** streaming path — it probes for
  `venv/bin/python` + `sounddevice` to run `scripts/tts_stream_player.py`. Python and the venv were
  removed in Phase 2b, so that probe always fails and every reply falls through to
  `curl → WAV → afplay`: time-to-first-audio (TTFA) = synthesize the **whole** first paragraph, then
  play.
- Barge-in ("hold on") and superseding a reply are a **cross-process kill**: `DictationManager.killTTS()`
  reads `tts_hook.pid` and runs `pkill`/`kill`. Clunky, racy, and it cannot cancel in-flight synthesis,
  so the ANE stays busy while STT wants it.

FluidAudio's `KokoroAneManager` is **whole-clip per call** (`synthesizeDetailed(text:) →
KokoroAneSynthesisResult.samples: [Float]`, raw 24 kHz mono fp32). It has no per-segment streaming API
(only the heavier PocketTTS model does). So low-latency playback must come from **chunking text into
sentences and pipelining synthesis into playback** ourselves.

## 2. Goals / Non-goals

**Goals**
- Cut TTFA on multi-sentence replies: start audio after sentence 1 while later sentences synthesize.
- **Gapless** playback across sentences via a single queued `AVAudioPlayerNode`.
- **In-process barge-in:** stop playback **and** cancel pending synthesis instantly (frees the ANE for
  STT), with no `pkill`/PID files.
- Move playback into the menu-bar app (it already owns `KokoroTTS`, `TTSHTTPServer`, and the
  `tts_playing.lock` it polls). The hook becomes a thin "speak this text" signal.
- Delete the dead Python streaming machinery (`tts_stream_player.py`, the `sounddevice` capability
  probe, the PID-kill block).
- Preserve every existing behavior: the `tts_playing.lock` "Speaking…" state (overlay waveform +
  hands-free mic-muting + keyword barge-in), `tts_volume`, voice selection, the voice-turn gate.

**Non-goals**
- No change to STT, auto-submit, auto-focus, the voice-turn gate logic, or overlay rendering.
- Keep `POST /v1/audio/speech` (WAV) unchanged — `speak.sh`, manual `curl`, and any external caller
  still use it.
- No PocketTTS / voice cloning. No notarization (Phase 4).
- No word/sub-sentence streaming (sentence granularity is enough; finer is future work).

## 3. Success criteria

1. On a 3–4 sentence reply, audible speech starts after roughly the first sentence (not the whole
   paragraph).
2. Playback is continuous across sentence boundaries (no audible gap) in the normal case.
3. "Hold on" (barge-in) or a new reply stops playback within ~100 ms **and** cancels remaining
   synthesis, so the ANE is free for STT — no wasted synthesis.
4. `tts_volume` changes loudness; voice selection still works.
5. `speak.sh` (and any `/v1/audio/speech` caller) is unaffected.
6. The hands-free "Speaking…" state, mic-muting, and overlay waveform behave exactly as before.

## 4. Approach (chosen)

**In-app player.** The hook POSTs the spoken text to a new endpoint; the app synthesizes
sentence-by-sentence and plays in-process. Barge-in/supersede are direct in-process calls. (Chosen over
porting the Python producer/queue/HTTP-stream design literally: that needs a second Swift player binary
to bundle/sign and still kills a process for barge-in — more moving parts, no upside now that Python is
gone.)

## 5. Components

### 5.1 `SentenceSplitter` — `OpenWhispererKit` (new, pure, unit-tested)
- `static func split(_ text: String) -> [String]`.
- Breaks the markdown-stripped first paragraph on sentence-final punctuation (`. ! ?`) followed by
  whitespace/end, plus hard newlines. Merges fragments shorter than a small threshold into the previous
  chunk so short replies aren't over-fragmented (e.g. "Done." stays one chunk; "v1.4 is out." doesn't
  split at the version dot — guard against splitting when the char before the period is a digit or the
  "sentence" is too short).
- Pure and deterministic — lives in the Kit beside `SubmitTrigger` / `NumberNormalizer`, fully unit
  tested. No `NaturalLanguage` dependency (keeps it testable + dependency-free).

### 5.2 `KokoroTTS.synthesizeSamples` — `app` (extend existing actor)
- Add `func synthesizeSamples(_ text: String, voice: String) async throws -> (samples: [Float], sampleRate: Int)`
  backed by `manager.synthesizeDetailed(...)` — raw PCM, no WAV wrapper. Reuses the existing
  `NumberNormalizer.normalize` pre-pass.
- Keep `synthesize(_:voice:) -> Data` (WAV) for `/v1/audio/speech`.

### 5.3 `AudioPlaybackEngine` — `app` (new)
- Wraps one `AVAudioEngine` + `AVAudioPlayerNode`. macOS plays to the default output device; no
  `AVAudioSession` needed.
- `schedule(samples: [Float], sampleRate: Double, volume: Float)`: builds a mono `AVAudioPCMBuffer`
  (applying volume gain with a soft clamp), `scheduleBuffer`s it (queued → gapless), starts the engine
  + node on the first buffer.
- `stop()`: `playerNode.stop()` + `engine.stop()` — immediate halt for barge-in.
- Completion: uses `scheduleBuffer(completionCallbackType: .dataPlayedBack)` to count buffers played; a
  callback notifies the controller when the queue drains.

### 5.4 `TTSPlaybackController` — `app` (new, actor)
- Owns one `AudioPlaybackEngine` and a reference to the `KokoroTTS` actor.
- `play(text:voice:)`:
  1. Cancel any prior playback (supersede).
  2. Write `tts_playing.lock`.
  3. `SentenceSplitter.split(text)`; for each sentence (in a cancellable `Task`): check
     `Task.isCancelled` → `synthesizeSamples` → `AudioPlaybackEngine.schedule(...)`. Sentence 1 starts
     audio while 2+ synthesize.
  4. When the queue drains (and synth loop is done), remove the lock + stop the engine.
- `bargeIn()` / `stop()`: cancel the synth `Task` (no further ANE work) + `AudioPlaybackEngine.stop()` +
  remove the lock. Safe to call from any thread (HTTP callback queue, `killTTS` background queue) via an
  actor hop.
- Reads `tts_volume` (file in App Support) per playback.

### 5.5 `TTSHTTPServer` — add `POST /v1/audio/play`
- Body `{input, voice}` (same shape as `/v1/audio/speech`).
- Hands text to `TTSPlaybackController.play(...)` and returns **202 Accepted immediately**
  (fire-and-forget — the hook does not block on playback duration).
- `/v1/audio/speech` (WAV) and `/v1/models` unchanged. `TTSHTTPServer.init` gains a
  `playback: TTSPlaybackController` parameter.

### 5.6 Wiring
- `ServerManager`: create + own `TTSPlaybackController(tts:)`, pass it to `TTSHTTPServer`, expose it as
  `var playback`.
- `ServeTTSMode` (headless `--serve-tts`): construct the controller too so `/v1/audio/play` works in
  CI/diagnostics (plays on the local default device).
- `AppDelegate`: after construction, set `dictationManager.ttsController = serverManager.playback`.
- `DictationManager`: add `weak var ttsController: TTSPlaybackController?`. `killTTS()` becomes
  `Task { await ttsController?.bargeIn() }` (drop the PID read + `pkill`). The lock-file poll +
  `handleTTSStateChange` are unchanged — the controller removes the lock, the existing poll reacts.

### 5.7 Hooks (`tts-hook.sh`, `codex-tts-hook.sh`)
- Remove: the `sounddevice`/`venv` capability probe (`CAP_OK`/`CAP_BAD`), the streaming-player branch,
  the `afplay` fallback block, and the PID prior-kill block (supersede is now in-app).
- Keep: the voice-turn gate, first-paragraph extraction, the localhost URL guard, the hook-serialization
  lock.
- New body: resolve voice → `curl -s -X POST $TTS_URL/v1/audio/play -d '{input,voice}'` fire-and-forget,
  then exit. Volume is read app-side now (drop `-v`). The app owns `tts_playing.lock`, so the hook no
  longer touches lock/PID files.
- Delete the orphaned `scripts/tts_stream_player.py`.

## 6. Data flow

**Happy path:** UPS hook marks a voice turn → Stop hook extracts the first paragraph → `POST
/v1/audio/play` → server returns 202; controller writes the lock, splits into sentences, synthesizes
sentence 1 → schedules it → audio begins **while** sentence 2 synthesizes → … → queue drains →
controller removes the lock + stops the engine. `DictationManager` sees the lock appear/disappear and
mutes/un-mutes STT as today.

**Barge-in / supersede:** "hold on" detected (or a new reply POSTs `/v1/audio/play`) → `killTTS()` /
`play()` calls `bargeIn()` → synth `Task` cancelled (stops before the next sentence → ANE freed),
`AudioPlaybackEngine.stop()` halts audio, lock removed → STT resumes.

## 7. Error handling & edge cases

- **App/server down:** the hook's `curl` fails → nothing plays (same as today when the server is down).
  No fallback path needed; if the server is up, in-app playback works.
- **Synthesis throws mid-paragraph:** stop the loop, play what's queued, remove the lock, log. Don't
  crash the server.
- **Empty / single-sentence text:** `split` returns one chunk; plays normally.
- **Two replies in quick succession:** the second `play()` supersedes the first (in-app cancel) — no
  cross-process race.
- **Volume:** read `tts_volume`; apply as buffer gain with a soft clamp.
- **Device sample rate ≠ 24 kHz:** the player schedules 24 kHz buffers; `AVAudioEngine`'s mixer
  resamples to the device.
- **Headless `--serve-tts`:** controller present; plays on the local default output (acceptable for
  diagnostics/CI).

## 8. Testing strategy

- **Unit (`OpenWhispererKitTests`, existing pattern):** `SentenceSplitter` — sentence boundaries,
  abbreviations / decimals / version numbers (no false split), tiny-fragment merge, empty / single /
  trailing-punctuation / multi-newline inputs.
- **Component:** `AudioPlaybackEngine` buffer construction (`[Float]` → `AVAudioPCMBuffer`: frame count,
  rate, channel count, volume gain) — assert on the buffer without a device. `TTSPlaybackController`
  cancellation: inject a fake synthesizer (protocol) and assert no sentences are requested after
  `bargeIn()`.
- **Manual checklist:** multi-sentence reply → audio after sentence 1; gapless; "hold on" stops <100 ms
  and STT resumes; new reply supersedes; `tts_volume` honored; `speak.sh` still works via
  `/v1/audio/speech`.

## 9. Files affected

**New**
- `app/Sources/OpenWhispererKit/SentenceSplitter.swift` (+ `app/Tests/OpenWhispererKitTests/SentenceSplitterChecks.swift`)
- `app/Sources/OpenWhisperer/AudioPlaybackEngine.swift`
- `app/Sources/OpenWhisperer/TTSPlaybackController.swift`

**Modified**
- `app/Sources/OpenWhisperer/KokoroTTS.swift` — add `synthesizeSamples`
- `app/Sources/OpenWhisperer/TTSHTTPServer.swift` — `POST /v1/audio/play`, `playback` init arg
- `app/Sources/OpenWhisperer/ServerManager.swift` — own + expose the controller
- `app/Sources/OpenWhisperer/ServeTTSMode.swift` — construct the controller
- `app/Sources/OpenWhisperer/AppDelegate.swift` — wire `dictationManager.ttsController`
- `app/Sources/OpenWhisperer/DictationManager.swift` — `killTTS()` → `bargeIn()`; add `ttsController`
- `hooks/tts-hook.sh`, `hooks/codex-tts-hook.sh` — simplify to `POST /v1/audio/play`

**Removed**
- `scripts/tts_stream_player.py` (orphaned Python player)

## 10. Out of scope / future

- Word-level streaming; STT/TTS model warmup tuning; cross-platform player; Phase 4 sign + notarize.
