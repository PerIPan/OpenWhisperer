# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Open Whisperer is a macOS **menubar app** (Swift/SwiftUI, Apple Silicon, macOS 14+) that adds full voice mode to **Claude Code** and **Codex CLI**: dictation in (speech→text, typed into the focused app) and spoken replies out (text→speech). Everything runs locally — no cloud APIs.

> **The README describes an obsolete architecture.** `README.md` documents an out-of-process Python server (`unified_server.py`, FastAPI, uvicorn, spaCy, MLX Whisper, a `~/mlx-openai-whisper` venv, `setup.sh`, `servers/start-servers.sh`). **All of that is gone.** The app was ported to **pure Swift** with both models running in-process on the ANE. `setup.sh` and `servers/start-servers.sh` no longer exist; ignore the README's Python/setup sections for anything architectural. The README's `[VOICE:]` tag mechanism is also vestigial (see "Voice-turn handshake" below).

## Commands

All Swift commands run from the `app/` directory (it's the SwiftPM package root).

```bash
cd app
swift build                          # debug build
swift build -c release               # release build
./build-dmg.sh                       # build .app bundle + .dmg (release) into app/.build/

swift run OpenWhispererKitTests      # pure-logic unit tests (exits non-zero on failure)
swift run HookTests                  # bash-hook integration tests (stubbed curl + temp HOME)

swift run OpenWhisperer --serve-tts  # headless TTS server on :8000 (no GUI) for curl/CI; TTS_PORT overrides
```

Manual TTS smoke checks (server must be running, GUI or `--serve-tts`):

```bash
curl http://localhost:8000/v1/models
echo "hello" | scripts/speak.sh
```

### Testing notes

- This machine has **Command Line Tools only, no full Xcode**, so there is **no XCTest/swift-testing**. Both test targets are plain `@main` executables that aggregate `*Failures() -> [String]` check groups and `exit(1)` if any fail. There is **no per-test filter** — to narrow a run, comment out check-group calls in the runner (`Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` or `Tests/HookTests/main.swift`).
- Only **pure logic** (no AppKit/AVFoundation/WhisperKit/FluidAudio) is unit-testable, and it lives in the `OpenWhispererKit` target precisely so it builds fast under CLT. Put new testable logic there.

## Working on changes

The loop this repo already follows. The parent checkout stays on `main`; feature branches live **only** under `.claude/worktrees/` — never branch in place.

Pick the lightest safe path:

- **Local (commit straight to `main`, no PR)** — docs/CLAUDE.md/comment edits, or a small, self-contained, low-risk code fix where a PR adds ceremony without safety. Stay on `main`, make the smallest edit, verify (readback for docs; the test targets for code), commit, push. If it unexpectedly grows beyond small/isolated, switch to the PR path before committing.
- **PR** — multiple files, real logic, a dependency change, or user-visible behavior:
  1. **Worktree off `main`:** `git worktree add .claude/worktrees/<slug> -b <slug>` (or `EnterWorktree` in Claude Code).
  2. **Build + test** from `app/`: `swift run OpenWhispererKitTests` and `swift run HookTests` (both `exit(1)` on failure). For a packaged `.app`/`.dmg`, `./build-dmg.sh` — set `OW_SIGN_IDENTITY` so TCC grants survive the rebuild (see Conventions).
  3. **PR:** rebase onto `origin/main` if it moved, push, `gh pr create`.
  4. **After merge:** sync `main` (`git pull --ff-only`), `git worktree remove .claude/worktrees/<slug>`, delete the branch. Leave no orphaned worktree dir — a stale bundle holding `:8000` is a known foot-gun.

### Commit messages

Conventional Commits, matching the existing history: `type(scope): subject`, where `type` ∈ `feat|fix|refactor|docs|test|build|chore` and `scope` is optional (commonly `tts`/`voice`/`sign`). Imperative mood; lowercase is fine for proper nouns and acronyms. Aim for a ~50-char subject, **hard cap 72 including the `type(scope):` prefix**; add a body only when the change needs a *why*, wrapped at 72. No `Co-Authored-By`/tool attribution in the message (Claude-authored commits carry only a `Claude-Session:` trailer).

## Architecture

### Targets (`app/Package.swift`)

- **`OpenWhispererKit`** — pure, dependency-free, fast-to-test logic: `SentenceSplitter`, `NumberNormalizer`, `SubmitTrigger`, `VoiceSignal`, `VoiceMigration`, `PCMConversion`.
- **`OpenWhisperer`** — the executable (AppKit/SwiftUI menubar app + native STT/TTS). Depends on `WhisperKit` (STT) and `FluidAudio` (TTS).
- **`OpenWhispererKitTests`**, **`HookTests`** — the two executable test runners above.

Entry point `OpenWhispererMain.main()`: `--serve-tts` → headless TTS; otherwise the SwiftUI `MenuBarExtra` app. `AppDelegate` owns the long-lived managers (`ServerManager`, `SetupManager`, `DictationManager`, `HotkeyManager`, `AccessibilityManager`). The app is `LSUIElement` (menubar only, no dock icon).

### STT (dictation) — fully in-process, no server

`HotkeyManager` watches a modifier key (Ctrl/fn/Option/Cmd) → `AppDelegate` captures the frontmost app's PID *before* any focus shift → `DictationManager` orchestrates: `AudioRecorder` (16 kHz mono PCM) → `SpeechTranscriber` (WhisperKit, on the ANE) → types the result into the captured app via Accessibility / CGEvent Unicode (the **clipboard is never touched**). Three `InteractionMode`s: `holdToTalk` (default), `pressToTalk`, `handsFree` (`KeywordDetector` uses Apple's Speech framework for "initiate"/"hold on").

> **STT is WhisperKit by design.** FluidAudio's Parakeet/Nemotron were evaluated as selectable alternatives (2026-06-20, PR #6) and **rejected** — Nemotron's English is rougher, Parakeet has no Turkish, and Whisper's "clean transcript" behavior (drops filler, handles jargon) is intrinsic to the model. Don't re-add an STT engine picker without revisiting `docs/superpowers/specs/2026-06-20-engine-configurability-design.md` (its Outcome section + the FluidAudio model/cache map).

### TTS (spoken replies) — in-process synth + playback, thin HTTP shim for hooks

`ServerManager` hosts `KokoroTTS` (FluidAudio) behind `TTSHTTPServer`, a tiny loopback-only HTTP/1.1 server on **:8000** (Network.framework, zero deps). After each AI reply, a bash hook POSTs the spoken text to `POST /v1/audio/play`; the server returns `202` immediately and `TTSPlaybackController` synthesizes **sentence-by-sentence** (`SentenceSplitter`) and plays gaplessly via `AudioPlaybackEngine` (`AVAudioPlayerNode`) — so the first sentence plays while the rest are still synthesizing. Endpoints: `GET /v1/models`, `POST /v1/audio/speech` (blocking, returns WAV — used by `scripts/speak.sh`), `POST /v1/audio/play` (fire-and-forget streaming).

**Barge-in** is in-process: starting a recording (or "hold on") calls `TTSPlaybackController.bargeIn()`, which cancels pending synthesis (freeing the ANE for STT) and stops audio instantly. `DictationManager` gets the controller injected by `AppDelegate`.

### Voice-turn handshake (Swift ⇄ bash — the subtle part)

Only **voice-dictated** turns are spoken; typed turns stay silent. The mechanism spans Swift and bash and must stay byte-parity:

1. On each dictation the app writes `voice_turn` = SHA-256 of the dictated text + a unix timestamp (`VoiceSignal.canonicalHash`).
2. The **UserPromptSubmit** hook (`hooks/voice-context.sh`) recomputes `shasum -a 256` of the submitted prompt; on a match it (a) injects a hidden `additionalContext` nudge telling the model to open with a standalone spoken summary, and (b) marks the session via `speak_pending/<session_id>`.
3. The **Stop** hook (`hooks/tts-hook.sh`) speaks only if that marker exists, extracting the reply's spoken text with `hooks/speakable-text.sh` — the markdown-stripped first paragraph (~600 char cap), or the whole reply when `tts_style` is `full` — then POSTs to `/v1/audio/play`.

`VoiceSignal.canonicalHash` lives in `OpenWhispererKit` and is unit-tested specifically to guarantee parity with the bash `shasum` reader — **if you touch hashing/trimming on either side, update both and run `HookTests`.** Codex has no per-prompt session id, so `hooks/codex-tts-hook.sh` gates on `voice_turn` presence+freshness directly instead of a per-session marker.

### State & IPC: flat files in Application Support

`~/Library/Application Support/OpenWhisperer` (0700) is the shared bus between the GUI app, the bash hooks, and the embedded server. All prefs and signals are flat files — see `Paths.swift` for the full list. Notable ones: `tts_voice`, `tts_volume`, `stt_language`, `interaction_mode`, `ptt_hotkey`, `tts_style` (spoken-summary style: `terse`/`normal`/`rich` summary lengths, or `full` = speak the whole reply as prose; was `voice_detail` before the rename — `ConfigManager.migrateVoiceDetailToTtsStyle()` migrates it on launch), `selected_platform`, `auto_submit`, `auto_focus_app`, `voice_turn`, `speak_pending/`, and `tts_playing.lock` (written while speaking; polled to drive the overlay waveform and mute the mic in hands-free mode).

These two are global (one menubar setting for all repos), but can be **overridden per-project** via env vars in that repo's `.claude/settings.local.json` `env` block — read by the hooks, which take precedence over the global file: `OW_TTS_STYLE` (overrides `tts_style`, read by `voice-context.sh` for the nudge and by the Stop hooks to choose first-paragraph vs. whole-reply extraction) and `OW_TTS_VOICE` (overrides `tts_voice`, read by `tts-hook.sh`). The voice rides per-request in the `/v1/audio/play` POST, so no app change is needed to honor a per-project voice.

### Concurrency

`SpeechTranscriber`, `KokoroTTS`, and `TTSPlaybackController` are **actors** — they serialize work on the single ANE/compute unit and dedup the one-time model load (concurrent callers await the same in-flight `prepare()`).

### Models & offline-first

First run downloads the models; both then prefer their on-disk cache and load **offline** when present:

- WhisperKit → `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model>` (`SpeechTranscriber` explicitly loads with `download: false` when cached).
- FluidAudio Kokoro → `~/.cache/fluidaudio`.

This matters because the developer's firewall (Little Snitch) blocks the HuggingFace **Xet CDN**, which breaks fresh downloads — an already-cached model still loads.

## Conventions & gotchas

- **Code signing identity** is set by `OW_SIGN_IDENTITY` (default `-` = ad-hoc). With ad-hoc, the cdhash changes every build, so macOS **drops the Accessibility and Microphone grants** — dictation breaks until you remove and re-add the app in System Settings → Privacy & Security. **To stop the churn locally:** sign with a stable self-signed cert — `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh` — whose designated requirement pins to the cert leaf hash (constant across rebuilds), so TCC grants persist; you re-grant only once. Release builds set `OW_SIGN_IDENTITY="Developer ID Application: …"` plus `OW_NOTARIZE=1` and `OW_NOTARIZE_PROFILE` to add hardened runtime (`Resources/OpenWhisperer.entitlements`) + notarize + staple the DMG (needs a paid Apple Developer account).
- Platform (Claude Code vs Codex CLI) is selected in the menubar; `ConfigManager` writes the right hooks/config for each (`~/.claude/settings.json` or `~/.codex/config.toml`).
- Version is hardcoded as `1.4.0` in both `build-dmg.sh` and `Resources/Info.plist` — bump both together.
- `app/Tools/` (G2PParity, STTDiag, FluidTTSSpike) are local-only diagnostic spikes and are **gitignored**.
- Design docs and implementation plans live in `docs/superpowers/{specs,plans}/`, organized by phase (Phase 1 = STT port, Phase 2 = native TTS, Phase 3 = streaming TTS). Consult these for the rationale behind the Swift port.
