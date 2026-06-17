# Phase 2b — Native TTS (FluidAudio) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python TTS with in-process FluidAudio (CoreML Kokoro) behind a tiny embedded localhost server, and remove the Python venv entirely — the bash hook keeps working unchanged.

**Architecture:** `NumberNormalizer` (pure) + a `KokoroTTS` actor (FluidAudio `KokoroAneManager`, offline-first load, mirrors `SpeechTranscriber`) behind an `NWListener` HTTP server on `:8000` serving `GET /v1/models` + `POST /v1/audio/speech` (WAV). `ServerManager` owns the listener+actor instead of spawning Python. Then the whole Python bootstrap is deleted.

**Tech Stack:** Swift (SwiftPM, macOS 14, tools 5.9), `FluidInference/FluidAudio` (CoreML/ANE), `Network.framework`. Tests are plain executables (`swift run OpenWhispererKitTests`) — no XCTest (Command Line Tools only).

**Spec:** [`docs/superpowers/specs/2026-06-17-phase2b-native-tts-design.md`](../specs/2026-06-17-phase2b-native-tts-design.md)

## Global Constraints

- macOS 14+, SwiftPM tools 5.9 for the app package (FluidAudio's own manifest is 6.0 — a 5.9 consumer of a 6.0 dependency is fine).
- FluidAudio pinned to a release tag (not `branch: main`). Product `FluidAudio`, type `KokoroAneManager(variant: .english)`, voice `af_heart`, output WAV 24 kHz mono.
- Tests are plain-executable assertions under `Tests/OpenWhispererKitTests` (run `swift run OpenWhispererKitTests`, non-zero exit on failure). No XCTest.
- Embedded server on port `8000` serving `GET /v1/models` + `POST /v1/audio/speech` returning **WAV/RIFF** (the hook's afplay fallback checks for the `RIFF` magic header).
- Offline-first model load (mirror `SpeechTranscriber.loadWhisperKit`): try cache first, fall back to download; surface failures in the standby overlay.
- Frequent commits. Build after each task: `swift build` from `app/`.

---

## Group A — Engine

### Task A1: `NumberNormalizer` (pure)

**Files:**
- Create: `app/Sources/OpenWhispererKit/NumberNormalizer.swift`
- Test: `app/Tests/OpenWhispererKitTests/NumberNormalizerTests.swift` (+ register in the test `main`)

**Interfaces:**
- Produces: `public enum NumberNormalizer { public static func normalize(_ text: String) -> String }` — expands money/percent/decimals/plain integers to spoken words; leaves other text untouched.

- [ ] **Step 1: Write failing tests** in `NumberNormalizerTests.swift`:

```swift
import OpenWhispererKit

func testNumberNormalizer() {
    assertEqual(NumberNormalizer.normalize("It costs $5.99 today."),
                "It costs five dollars and ninety nine cents today.", "money")
    assertEqual(NumberNormalizer.normalize("15% off"), "fifteen percent off", "percent")
    assertEqual(NumberNormalizer.normalize("pi is 3.14"), "pi is three point one four", "decimal")
    assertEqual(NumberNormalizer.normalize("room 101"), "room one hundred one", "integer")
    assertEqual(NumberNormalizer.normalize("no numbers here"), "no numbers here", "passthrough")
}
```

(Use the repo's existing `assertEqual` test helper; if none, add a tiny one in the test `main` that prints PASS/FAIL and tracks a failure count for the non-zero exit.)

- [ ] **Step 2: Wire the test into the harness** — call `testNumberNormalizer()` from `Tests/OpenWhispererKitTests/main.swift` (follow the existing pattern there for `SubmitTrigger`/`PCMConversion`).

- [ ] **Step 3: Run, verify it fails** — `cd app && swift run OpenWhispererKitTests` → FAILs (no `NumberNormalizer`).

- [ ] **Step 4: Implement `NumberNormalizer.swift`** — a focused number→words expander:
  - Regex pass for `\$\d+(\.\d{2})?` → "<dollars> dollars[ and <cents> cents]".
  - `\d+%` → "<n> percent".
  - decimals `\d+\.\d+` → "<int> point <digit-by-digit>".
  - standalone integers `\d+` → cardinal words (0–999,999 enough for summaries).
  - A small `cardinal(_ n: Int) -> String` helper (ones/tens/hundreds/thousands).
  - Apply money → percent → decimal → integer in that order so each consumes its tokens.

- [ ] **Step 5: Run, verify pass** — `swift run OpenWhispererKitTests` → all PASS.

- [ ] **Step 6: Commit** — `git add app/Sources/OpenWhispererKit/NumberNormalizer.swift app/Tests/OpenWhispererKitTests/ && git commit -m "feat(tts): add NumberNormalizer for spoken-form numbers"`

### Task A2: Add FluidAudio dependency + `KokoroTTS` actor

**Files:**
- Modify: `app/Package.swift` (add the FluidAudio package + product to the `OpenWhisperer` target)
- Create: `app/Sources/OpenWhisperer/KokoroTTS.swift`

**Interfaces:**
- Consumes: `NumberNormalizer.normalize`, FluidAudio `KokoroAneManager(variant:)`, `.initialize()`, `.synthesize(text:voice:speed:) -> Data`.
- Produces: `actor KokoroTTS { func prepare() async throws; var isReady: Bool { get } async; func synthesize(_ text: String, voice: String) async throws -> Data /* WAV */ }`

- [ ] **Step 1: Add the dependency** to `app/Package.swift`:

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "<latest-tag>"),
```
and add `.product(name: "FluidAudio", package: "FluidAudio")` to the `OpenWhisperer` target's dependencies. (Resolve the latest release tag with `git ls-remote --tags https://github.com/FluidInference/FluidAudio.git | tail`.)

- [ ] **Step 2: Resolve + build** — `cd app && swift package resolve && swift build` → builds (no metallib/Xcode needed). Expected: clean.

- [ ] **Step 3: Implement `KokoroTTS.swift`** mirroring `SpeechTranscriber`: an `actor` holding `KokoroAneManager`, a `loadTask` dedup, `isReady`, `prepare()` (calls `initialize()`), and `synthesize(text, voice)` that does `NumberNormalizer.normalize(text)` then `manager.synthesize(text: voice: speed:)`. Offline-first: `initialize()` reads cache then downloads; wrap errors in a `KokoroTTSError.loadFailed`.

- [ ] **Step 4: Verify via `TTSDiag`** (see A3) — defer assertion to A3; here just confirm `swift build` passes.

- [ ] **Step 5: Commit** — `git commit -am "feat(tts): add KokoroTTS actor over FluidAudio"`

### Task A3: `TTSDiag` standalone tool (offline synth check)

**Files:**
- Create: `app/Tools/TTSDiag/Package.swift`, `app/Tools/TTSDiag/Sources/main.swift` (gitignored under `app/Tools/`, like `STTDiag`)

- [ ] **Step 1:** Package depending on FluidAudio (copy `STTDiag/Package.swift` shape; product FluidAudio).
- [ ] **Step 2:** `main.swift`: `KokoroAneManager(variant: .english)`; `initialize()`; `synthesize(text: "Testing one two three.", voice: "af_heart")`; write `out.wav`; print byte count.
- [ ] **Step 3: Run** — `cd app/Tools/TTSDiag && swift run TTSDiag` → writes a RIFF wav (downloads model on first run; **expect a Little Snitch prompt** — approve it). `file out.wav` → "RIFF ... WAVE". `afplay out.wav` → hear it.
- [ ] **Step 4:** No commit (gitignored). Record the result in the worktree notes.

---

## Group B — Delivery (embedded server + ServerManager)

### Task B1: `TTSHTTPServer` (NWListener)

**Files:**
- Create: `app/Sources/OpenWhisperer/TTSHTTPServer.swift`

**Interfaces:**
- Consumes: `KokoroTTS.synthesize`.
- Produces: `final class TTSHTTPServer { init(port: UInt16, tts: KokoroTTS); func start() throws; func stop() }` — serves `GET /v1/models` (200 + minimal models JSON) and `POST /v1/audio/speech` (parse `{model,input,voice}`, return `200` WAV with `Content-Type: audio/wav`, else `500`).

- [ ] **Step 1:** Implement a minimal HTTP/1.1 handler over `NWListener` (TCP, `.parameters(.tcp)` on `127.0.0.1:8000`): read the request line + headers + body (Content-Length), route the two endpoints, write a raw HTTP response. Keep it tiny — only what the hook + health checks need.
- [ ] **Step 2: Manual test** — start it from a temporary `@main`/test harness or via B2's ServerManager; `curl -s -o /tmp/o.wav -w "%{http_code}" -X POST localhost:8000/v1/audio/speech -d '{"model":"k","input":"hello there","voice":"af_heart"}'` → `200`; `file /tmp/o.wav` → RIFF WAVE; `curl localhost:8000/v1/models` → 200 JSON.
- [ ] **Step 3: Commit** — `git commit -am "feat(tts): embedded NWListener server for /v1/audio/speech"`

### Task B2: `ServerManager` rework

**Files:**
- Modify: `app/Sources/OpenWhisperer/ServerManager.swift`

- [ ] **Step 1:** Replace the `Process`/Python-spawn logic with: construct `KokoroTTS` + `TTSHTTPServer`, `start()` on launch, `stop()` on quit; health = listener bound + `await tts.isReady`. Keep the published status + standby-overlay surfacing; on model-load failure set `.error` with the message (Retry re-runs `prepare()`).
- [ ] **Step 2: Build + run the app** — `swift build`; launch; trigger a `[VOICE:]` response → the hook hits the native server → you hear it. Confirm via `paste`-style check + `server.log`/console.
- [ ] **Step 3: Commit** — `git commit -am "feat(tts): ServerManager hosts native TTS instead of Python"`

---

## Group C — Python teardown

### Task C1: Remove Python servers + scripts

- [ ] **Step 1:** `git rm` `servers/unified_server.py servers/tts_stream.py servers/whisper_server.py servers/start-servers.sh scripts/tts_stream_player.py`; trim `scripts/speak.sh` to the curl+afplay path (or remove if unused).
- [ ] **Step 2:** Build + smoke the app still runs (TTS native). Commit `chore(tts): remove Python TTS servers + streaming player`.

### Task C2: Strip the venv bootstrap

**Files:** `setup.sh`, `app/Sources/OpenWhisperer/SetupManager.swift`, `app/Sources/OpenWhisperer/Paths.swift`

- [ ] **Step 1:** Remove from `setup.sh` the `uv`/venv creation + all `uv pip install` (mlx-audio, mlx-whisper, spaCy, misaki, setuptools) + the spaCy model download; leave only what (if anything) remains needed.
- [ ] **Step 2:** In `SetupManager.swift` remove Steps 1–6 (venv/pip/spaCy/smoke); first-launch becomes "ensure CoreML models / mark complete" (offline-first). Remove `Paths.venv`, `Paths.python`, `Paths.uvBinary` and their uses.
- [ ] **Step 3:** Build; run first-launch path (delete `.setup-complete`) → no Python touched. Commit `chore(tts): remove uv/venv bootstrap from setup`.

### Task C3: Simplify the hooks

**Files:** `hooks/tts-hook.sh`, `hooks/codex-tts-hook.sh`

- [ ] **Step 1:** Drop the venv-Python streaming-player branch + the `.tts_stream_ok`/`.tts_stream_unavailable` capability probe; keep the `curl → /v1/audio/speech → afplay -v <volume>` path, the `tts_playing.lock` "Speaking…" state, the prior-afplay kill, and the `[VOICE:]` extraction.
- [ ] **Step 2:** Restart a session (or re-fire the hook) → hear native TTS via the simplified hook. Commit `chore(tts): simplify hooks to native /v1/audio/speech + afplay`.

---

## Self-Review

- **Spec coverage:** NumberNormalizer (A1), KokoroTTS actor + FluidAudio dep + offline load (A2), TTSDiag (A3), embedded server `/v1/models`+`/v1/audio/speech` WAV (B1), ServerManager rework (B2), Python teardown across servers/scripts/setup/SetupManager/Paths/hooks (C1–C3). All spec sections mapped.
- **Placeholders:** `<latest-tag>` in A2 is a deliberate resolve-at-implementation step (command given). NWListener HTTP details in B1 are structural (the exact byte-handling is written during implementation against a running curl) — flagged as a live-iteration task, not a silent TODO.
- **Type consistency:** `KokoroTTS.synthesize(_:voice:) -> Data` used identically in B1/B2; `NumberNormalizer.normalize(_:) -> String` in A1/A2; voice `af_heart` throughout.
