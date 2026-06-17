# Pure-Swift STT Port — Phase 1 Design

**Date:** 2026-06-17
**Status:** Approved direction (Approach B), pending spec review
**Scope:** Phase 1 of a phased port that eliminates the out-of-process Python MLX server. This phase replaces **speech-to-text only**. TTS, server removal, and notarization are later phases.

## Goal

Run Whisper STT **natively in-process** via WhisperKit, deleting the HTTP transcription path. The Python unified server keeps running **for TTS only** during Phase 1; STT simply stops calling it.

## Decisions (locked)

- **Approach B — clean cut, no fallback.** Replace `uploadToWhisper` with a direct in-process WhisperKit call. Delete the STT HTTP machinery now. No `STTBackend` protocol, no HTTP fallback. A WhisperKit failure surfaces as a user-visible error (the honest signal).
- **Engine:** WhisperKit (`argmaxinc/WhisperKit`, MIT), pinned. Model = the `large-v3-turbo` CoreML build — the **same trained model** as today's MLX `mlx-community/whisper-large-v3-turbo`.
- **Model distribution:** download at first run (WhisperKit's native behavior; matches today's UX). Bundling is deferred to the Phase-4 notarization work.
- **Deployment target:** unchanged at macOS 14 (WhisperKit requires 14+; already satisfied).

## Non-goals (explicitly out of scope for Phase 1)

- TTS / Kokoro / phonemizer port (Phase 2–3).
- Removing or shrinking `ServerManager` / the Python server (Phase 4).
- The embedded localhost server for hooks (Phase 3–4).
- Developer-ID signing + notarization (Phase 4; the venv still ships in Phase 1, so notarization is not yet achievable).
- In-process TTS barge-in via `AVAudioPlayerNode` (Phase 3).

## Current state (what we're replacing)

- `DictationManager.uploadToWhisper(wavData:language:port:handsFree:completion:)` (`DictationManager.swift:567–643`) — multipart POST to `http://localhost:<port>/v1/audio/transcriptions`, returns `{text}` via a `Result<String, Error>` completion.
- Two call sites: hands-free (`:334`) and push-to-talk (`:493`).
- `Data.appendField` (`:960`) — multipart helper, used **only** by `uploadToWhisper`.
- `DictationManager.port` / `updatePort` / `currentPort` (`:32, :124, :301, :453`) — used **only** to build the STT URL. (The TTS server's port lives separately in `ServerManager`.)
- Server-side post-processing in `unified_server.py` that must move to Swift:
  - `check_submit_trigger(text)` (`:134–147`) — strips a trailing trigger phrase and reports whether one was found. Triggers: `["submit", "send it", "go ahead", "send", "enter"]` (`:79`), matched longest-first, tolerant of trailing punctuation, via precompiled regex (`:85–92`).
  - Submit semantics (`:304–319`):
    - **Hands-free:** server strips the trigger word; **Swift already presses Enter** (`insertText(..., forceSubmit: true)` at `:349`).
    - **Push-to-talk + auto-submit flag** (`Paths.autoSubmitFlag`): server runs `check_submit_trigger`, and if a trigger was found *or* the flag is set, it presses Enter itself (`_delayed_enter`, ~1s) and calls `kill_tts`. Swift's PTT path currently does **not** force-submit (`:509`).

## Target design

### New components

1. **`SpeechTranscriber` (actor, new file `SpeechTranscriber.swift`)**
   - Owns a lazily-loaded `WhisperKit` instance, pinned to the `large-v3-turbo` model.
   - `func transcribe(samples: [Float], language: String?) async throws -> String` — `nil`/`"auto"` language ⇒ autodetect; otherwise pass through to WhisperKit decode options.
   - **Warm-up:** `prepare()` loads + warms the model (first ANE compile is slow). Called at app launch or first record. Model-download/compile progress surfaced via the existing `SetupManager`-style progress UI.
   - Serializes inference (actor) so concurrent calls can't race the ANE/GPU.

2. **`SubmitTrigger` (new file `SubmitTrigger.swift`)** — faithful Swift port of `SUBMIT_TRIGGERS` + `check_submit_trigger`.
   - `static func process(_ text: String) -> (cleaned: String, didMatch: Bool)`.
   - Same trigger list, longest-first ordering, trailing-punctuation tolerance, and regex semantics as the Python original (including the codex VOICE-regex parity behavior).
   - Unit-tested against golden cases.

3. **`AudioRecorder.exportPCMFloat() -> [Float]?` (addition to `AudioRecorder.swift`)**
   - Returns 16 kHz mono **Float32** samples (normalized) — feeds WhisperKit directly, skipping the WAV encode→POST→decode round-trip. The recorder already produces 16 kHz Int16 mono internally.

### Changes to `DictationManager`

- Replace both `uploadToWhisper` call sites with `SpeechTranscriber.transcribe(samples:language:)` driven from the recorder's `exportPCMFloat()`.
- **Hands-free path (`:334`):** transcribe → `SubmitTrigger.process` to strip the trigger word → `insertText(cleaned, forceSubmit: true)` (unchanged submit behavior).
- **Push-to-talk path (`:493`):** transcribe → if `Paths.autoSubmitFlag` exists, run `SubmitTrigger.process`; `forceSubmit = didMatch || flagPresent` (replicating the server's `should_submit`, including "flag set always submits"). When submitting, call `killTTS()` first (replacing the server's `kill_tts`), then `insertText(cleaned, forceSubmit: true)`. Otherwise `insertText(cleaned)` with no submit.
- Keep the watchdog as an **inference-hang timeout** (no longer a network timeout). Preserve current durations (35 s hands-free, 30 s PTT) initially; revisit once warmed latency is measured.
- Adjust the "too short" guard: it currently checks WAV byte count (`< 9700`, `:311`); switch to a sample-count threshold on the `[Float]` buffer (equivalent minimum duration).

### Deletions

- `uploadToWhisper` (`:567–643`), `Data.appendField` (`:960`), `DictationManager.port` / `updatePort` / `currentPort` and the now-dead caller of `updatePort`.
- The STT-specific multipart/network error branches.

### Untouched in Phase 1

- `ServerManager` (still launches Python for TTS; `/v1/models` health check + server `port` stay). Its now-unused `/v1/audio/transcriptions` route remains harmlessly until Phase 4.
- `AudioRecorder` capture pipeline, `KeywordDetector`, `HotkeyManager`, `AccessibilityManager`, `ConfigManager`, `MenuBarView` (except a label tweak if the Server card mentions STT), `AppDelegate` orchestration.

## Data flow (after)

```
record → AudioRecorder.exportPCMFloat() → [Float]
       → SpeechTranscriber.transcribe(samples:language:) → transcript
       → SubmitTrigger.process → (cleaned, didMatch)
       → insertText(cleaned, forceSubmit: <per-mode rule>) → AX insert / Enter
```

Same `Result`-style outcome into the existing insert/overlay code; the recording state machine and AX insertion are unchanged.

## Error handling

- WhisperKit init/download/compile failure or inference error ⇒ surface via the existing `self.error` → `TranscriptionOverlay` path. No fallback (Approach B).
- Inference hang ⇒ watchdog cancels, resets state, sets `error`, resumes listening (hands-free) — mirrors current watchdog behavior.
- Empty/whitespace transcript ⇒ existing no-op guards (`:344`, `:504`) preserved.

## Testing

- **Unit:** `SubmitTrigger` golden cases (each trigger, trailing punctuation, no-match, mid-text non-match); `exportPCMFloat` conversion (Int16→Float32 scaling, sample rate, mono).
- **Integration:** transcribe a committed WAV fixture, assert expected text (allow minor tolerance); a one-off A/B note comparing WhisperKit vs the old server output on the same fixture during rollout.
- **Manual:** build, run, dictate via push-to-talk and hands-free; verify auto-submit (flag on/off) and trigger-word stripping in both modes.

## Risks & mitigations

- **First-run model download (~1 GB) + ANE compile latency.** Mitigate with explicit `prepare()` warm-up and progress UI; cache persists across launches.
- **Language autodetect parity** vs the MLX model. Same trained weights; validate on the fixture and a few non-English samples.
- **Submit-trigger fidelity.** The behavioral subtlety (server-side Enter in PTT auto-submit) is the main correctness risk; covered by golden tests + manual auto-submit checks.
- **WhisperKit API specifics** (exact model identifier string, init/transcribe signatures, progress callback) — verified against the library before implementation; see verification step.

## Rollout / definition of done (Phase 1)

- App builds release; dictation works in push-to-talk and hands-free with no Python STT call (verified: server STT route receives zero requests during a session).
- Auto-submit and trigger-word stripping behave identically to today in both modes.
- Unit + integration tests pass.
- `uploadToWhisper` and STT port plumbing are gone; `ServerManager` still serves TTS.

## Phase roadmap (context only — not this phase)

- **Phase 2:** TTS engine (`kokoro-ios` + `MisakiSwift`) + **g2p parity spike** (the gating quality risk).
- **Phase 3:** `AVAudioPlayerNode` streaming player; hook-IPC decision; in-process barge-in.
- **Phase 4:** delete venv/uv/jq; tiny embedded localhost server for the agent hooks; Developer-ID sign + Hardened Runtime + notarize.

---

## As-Built Notes & Verifier Corrections (applied)

An adversarial verification pass (WhisperKit API + codebase claims + spec gaps) corrected the
design before implementation. What actually shipped in Phase 1:

**Engine / API (corrections to the original draft):**
- **Model id** is `"openai_whisper-large-v3-v20240930_turbo"` (there is no literal `large-v3-turbo`;
  it's a family). A `_632MB` 4-bit variant is noted in `SpeechTranscriber` as a smaller-download swap.
- **WhisperKit pinned at 0.18.0** via `from: "0.9.0"` (repo `argmaxinc/WhisperKit`, MIT). It pulls
  swift-transformers, yyjson, swift-argument-parser, swift-jinja, swift-collections, swift-crypto, swift-asn1.
- Real API: `transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws -> [TranscriptionResult]`;
  language via `DecodingOptions(language:)` (`nil` = autodetect); `SpeechTranscriber.transcribe` joins
  `results.map(\.text)` into the `String` the call sites expect.

**The async↔GCD bridge (the heart of the port):** each transcribe runs in a `Task`; the result hops to
`MainActor.run` for all UI/state/`insertText`. `activeUploadTask: URLSessionDataTask?` became
`activeTranscribeTask: Task<Void, Never>?`, cancelled at all four sites (mode-change, deactivate-HF, two
watchdogs). A `if Task.isCancelled { return }` **generation guard** before the main-thread handler preserves
the T1.2/T1.4 "don't type into the wrong app" invariant — cancelling does **not** interrupt WhisperKit
mid-inference, so the guard (not the cancel) is what matters. Watchdogs kept at 35 s.

**Submit reconciliation (avoids double-Enter):** `insertText` already presses Enter whenever
`Paths.autoSubmitFlag` exists (independent of `forceSubmit`). So once the server STT path is gone, the
server's `_delayed_enter` simply stops firing and `insertText` becomes the sole Enter. Hands-free strips the
trigger phrase and passes `forceSubmit: true` (always submits, unchanged). Push-to-talk strips the trigger
phrase **only when the flag is set** (matching the server) and relies on `insertText`'s existing flag-check
for Enter — no `forceSubmit`, no double-submit.

**Deletions:** `uploadToWhisper`, the multipart `appendField` helper, `DictationManager.port`/`updatePort`,
and the three `updatePort` callers (`OpenWhispererApp.swift:15` + the `.onChange` block, `MenuBarView.swift:232`).
The now-dead WAV cluster in `AudioRecorder` (`exportWAV`, `flushAndContinue`, `mergeToWAV`, WAV-header `Data`
extension) was removed; `exportPCMFloat()` / `flushAndContinueFloat()` / `mergeToFloat()` replace them, reusing
the unit-tested `PCMConversion`. `MenuBarView` STT row relabeled "Whisper STT (on-device)" driven by
`DictationManager.sttModelReady` (was the stale Python `serverManager.sttModel`).

**Submit-trigger phantom requirement removed:** there is no "VOICE regex" in `check_submit_trigger`; the port
mirrors `_SUBMIT_PATTERNS` + the `rfind` fallback exactly (`SubmitTrigger`, 14 parity checks).

**Packaging (S9):** WhisperKit's deps ship two SwiftPM resource bundles
(`swift-transformers_Hub.bundle`, `swift-crypto_Crypto.bundle`) loaded via `Bundle.module` at runtime.
`build-dmg.sh` now copies all `.build/release/*.bundle` into `Contents/Resources/` — without this the
packaged `.app` crashes on first model load. The binary links no non-system dylibs (Swift statically linked).
Ad-hoc `codesign --deep` still verifies. (Notarization remains a Phase-4 item — the venv still ships.)

**Testing under Command-Line-Tools-only:** this machine has no `XCTest`/`Testing` module, so unit tests run
as a plain executable harness (`swift run OpenWhispererKitTests`, exits non-zero on failure):
`SubmitTrigger` (14 parity checks) + `PCMConversion` (7 checks). Swap for an XCTest target once full Xcode is installed.

**Verified vs. not:** debug + release builds pass; unit harness green; `.app` packaged, bundles present,
signature valid. **Not** verified here (needs a Mac with GUI + mic + ~1.5 GB model download): first-run model
download UX, actual transcription quality/latency, push-to-talk + hands-free + auto-submit end-to-end.
