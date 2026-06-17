# Phase 2b — Native TTS (FluidAudio) Implementation Design

**Date:** 2026-06-17
**Status:** Brainstormed and approved. Ready for an implementation plan.
**Branch / worktree:** `phase2b-native-tts` (`.claude/worktrees/phase2b-native-tts`).
**Parents:** [`2026-06-17-phase2-native-tts-design.md`](2026-06-17-phase2-native-tts-design.md) (phasing + the
FluidAudio/CoreML pivot), [`2026-06-17-phase2a-g2p-parity-spike-design.md`](2026-06-17-phase2a-g2p-parity-spike-design.md)
(spike + engine eval that chose FluidAudio).

## Goal

Replace the out-of-process Python TTS with **native in-process Swift TTS** using **FluidAudio** (CoreML/ANE
Kokoro), and **remove the Python venv entirely** — since Phase 1 already made STT native (WhisperKit), the venv
has no remaining purpose. The bash hook keeps working unchanged.

## Decisions (locked)

- **Engine:** `FluidInference/FluidAudio` `KokoroAneManager` (CoreML/ANE, Kokoro-82M, voice `af_heart`). Chosen
  over MLX (MisakiSwift + kokoro-ios) for maintenance, build simplicity (no metallib / no full-Xcode), ANE
  efficiency, zero external SwiftPM deps. Pin a release tag (not `branch: main`).
- **Delivery:** a tiny **embedded Swift HTTP server** (`Network.framework` `NWListener`, zero deps) on `:8000`
  serving the endpoints the hook needs. The hook is **unchanged**.
- **Number handling:** a `NumberNormalizer` shim expands numbers/money/percent → words **before** g2p (fixes
  FluidAudio's weak number handling found in the spike).
- **Python teardown:** full — remove the Python servers, the `uv`/venv/`jq` bootstrap, and the Python TTS deps.
- **Streaming:** **staged to Phase 3** (not in 2b). 2b is non-streaming (whole-clip synth → `afplay` via the
  hook's existing fallback). See the Phase-3 streaming-foundation note in the parent doc.

## Non-goals (Phase 2b) → Phase 3

- The `AVAudioPlayerNode` streaming player, the sentence-by-sentence producer, and **in-process barge-in**.
- The full hook-IPC redesign (we keep the localhost-POST contract for now).
- Developer-ID notarization (Phase 4).

## Architecture

```
bash hook (unchanged) ──curl POST :8000/v1/audio/speech──▶ Swift app
                                                            ├─ Embedded HTTP server (NWListener, 0 deps)
                                                            └─▶ KokoroTTS actor
                                                                  ├─ NumberNormalizer (text → spoken words)
                                                                  └─ FluidAudio KokoroAneManager (CoreML/ANE)
hook ◀──────────────────── WAV (RIFF) ──────────────────────────┘   └─▶ afplay -v <volume>
```

## Components (each small, single-purpose, independently testable)

### 1. `NumberNormalizer` (pure logic, in `OpenWhispererKit`)
- **Does:** text in → text out with numerics expanded to spoken words (`$5.99` → "five dollars and ninety nine
  cents", `15%` → "fifteen percent", `2.5` → "two point five", years/times/phone where practical).
- **Why:** the spike showed FluidAudio's g2p mangles numbers; expanding first sidesteps it.
- **Tested:** unit tests over the spike's number cases. Pure function, no deps.

### 2. `KokoroTTS` actor (in the app)
- **Does:** wraps FluidAudio `KokoroAneManager(variant: .english)`. `synthesize(text:voice:) async throws ->
  Data` applies `NumberNormalizer`, then `KokoroAneManager.synthesize(text:voice:)` → WAV `Data` (24 kHz mono).
- **Model load:** offline-first, mirroring `SpeechTranscriber` — `initialize()` downloads the Kokoro CoreML
  models from HF on first run, then loads from cache; failures surface in the standby overlay with Retry.
- **Escape hatch:** keep `synthesizeFromPhonemes(_:)` reachable for future g2p experiments.

### 3. Embedded HTTP server (`NWListener`, in the app)
- **Serves on `:8000`:**
  - `GET /v1/models` → `200` + a models JSON (health checks, the hook's `TTS_URL` validation, `ConfigManager.testTTS`).
  - `POST /v1/audio/speech` → reads `{model, input, voice}`, calls `KokoroTTS`, returns **WAV/RIFF** bytes.
- **Why WAV/RIFF:** the hook's afplay fallback checks for a `RIFF` magic header; FluidAudio's `synthesize`
  returns WAV, so the hook plays it unmodified.
- **Out of scope (Phase 3):** `POST /v1/audio/stream`.

### 4. `ServerManager` rework
- Stop spawning the Python `unified_server.py` process. Instead own the `NWListener` + `KokoroTTS` actor
  lifecycle (start on launch, stop on quit). Health = listener up **and** actor ready. Keep the existing
  status/standby-overlay surfacing.

### 5. Python teardown
- **Remove:** `servers/unified_server.py`, `servers/tts_stream.py`, `servers/whisper_server.py`,
  `servers/start-servers.sh`, `scripts/tts_stream_player.py`, `scripts/speak.sh` (Python parts).
- **`setup.sh` + `SetupManager.swift`:** drop the `uv`/venv creation, `mlx-audio`/`mlx-whisper`/`spaCy`/`misaki`
  installs, the smoke test, and the venv `Paths` (`venv`, `python`, `uvBinary`). First-launch becomes
  "ensure CoreML models present (offline-first)" — no Python.
- **Hooks:** simplify `tts-hook.sh` + `codex-tts-hook.sh` to the `curl → /v1/audio/speech → afplay -v` path
  (drop the venv-Python streaming-player branch + the `.tts_stream_ok` capability probe, which can't run
  without the venv). Preserve the `tts_playing.lock` "Speaking…" state, volume, and the prior-afplay kill.

## Data flow

Hook fires on a `[VOICE:]` response → `curl POST :8000/v1/audio/speech {model, input: <VOICE text>, voice}` →
embedded server → `KokoroTTS.synthesize` (`NumberNormalizer` → FluidAudio CoreML) → WAV → hook `afplay -v
<volume>`. Barge-in: a new hook invocation kills the prior `afplay` (coarse; Phase 3 adds in-process
`playerNode.stop()`).

## Error handling
- **Model not present + offline (Little Snitch/Xet):** surface in the standby overlay with Retry, as STT does.
  No pip anymore, so the failure surface is just the CoreML model fetch.
- **Synthesis failure:** server returns `5xx`; the hook's afplay fallback simply plays nothing (no crash).
- **Port in use:** if `:8000` is taken (e.g., a stale Python server), `ServerManager` reports it in the overlay.

## Known impacts to flag
- **Voquill / external `/v1/audio/transcriptions`:** removing the Python server drops that endpoint. In-app STT
  is unaffected (it's native via `DictationManager`/`SpeechTranscriber`). If external Voquill support matters,
  the embedded server can later grow a native `/v1/audio/transcriptions` backed by WhisperKit — **deferred**,
  not in 2b.
- **Streaming + ~100 ms GPU-releasing barge-in:** temporarily lost (Phase 3 restores — see parent doc).

## Testing
- `NumberNormalizer` unit tests (spike's number cases).
- A `TTSDiag` standalone tool (like `STTDiag`) to synth offline and verify WAV output.
- End-to-end: `curl POST :8000/v1/audio/speech` returns RIFF and `afplay` plays it; fresh-launch path loads the
  model offline.

## Decomposition (for the plan)
Three task groups, buildable/testable in order:
- **A. Engine:** `NumberNormalizer` + `KokoroTTS` actor + `TTSDiag`.
- **B. Delivery:** embedded `NWListener` server (`/v1/models`, `/v1/audio/speech`) + `ServerManager` rework; hook still works.
- **C. Teardown:** remove Python servers/venv bootstrap; simplify `setup.sh`/`SetupManager`/`Paths`/hooks; first-launch no longer touches Python.
