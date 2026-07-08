# AGENTS.md

This file defines the project-scoped rules, workflows, commands, and architecture details for AI agents working in the OpenWhisperer repository.

## Commands

All Swift commands run from the `app/` directory (it's the SwiftPM package root).

```bash
cd app
swift build                                           # debug build
swift build -c release                                # release build
OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh   # build signed bundle + .dmg for local dev (keeps TCC grants)
./build-dmg.sh                                        # build ad-hoc bundle + .dmg (release) into app/.build/

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
  2. **Build + test** from `app/`: `swift run OpenWhispererKitTests` and `swift run HookTests` (both `exit(1)` on failure). For a packaged `.app`/`.dmg`, use `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh` locally so TCC grants survive the rebuild (see Conventions).
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

### TTS (spoken replies) — in-process synth + playback, `speak` MCP tool

`ServerManager` hosts `KokoroTTS` (FluidAudio) behind `TTSHTTPServer`, a tiny loopback-only HTTP/1.1 server on **:8000** (Network.framework, zero deps). The app also hosts a minimal **MCP server at `POST /mcp`** exposing a `speak` tool (see Voice-turn handshake): the model calls `speak(text, voice?, speed?)` mid-turn (optional `voice`, resolved from the user's `tts_voice` pref, and `speed`, clamped via `TTSSpeed`, both defaulting to the user's global prefs) → the in-process `MCPServer` dispatch (`OpenWhispererKit`, pure JSON-RPC) → `TTSPlaybackController` synthesizes **sentence-by-sentence** (`SentenceSplitter`) and plays gaplessly via `AudioPlaybackEngine` (`AVAudioPlayerNode`) — so the first sentence plays while the rest are still synthesizing. Endpoints: `GET /v1/models`, `POST /v1/audio/speech` (blocking WAV — used by `scripts/speak.sh`), `POST /v1/audio/play` (fire-and-forget; also takes optional `voice` (resolved from `tts_voice`) and `speed` (clamped via `TTSSpeed`); used by the Pi extension's `openwhisperer_speak` tool), `POST /mcp` (MCP Streamable HTTP, protocol `2025-11-25` — the `speak` tool).

**Playback rate.** The global `tts_speed` pref (a Voice Settings slider, 0.7–1.5, default 1.1 — upstream is 1.0) is threaded into `KokoroTTS` synthesis and read where `tts_volume` is read — `TTSPlaybackController` (so the `speak` tool + `/v1/audio/play` pick it up) and the blocking `/v1/audio/speech` (which also honors an optional per-request `speed`). Parsing/clamping lives in pure `TTSSpeed` (`OpenWhispererKit`), unit-tested; its `[min, max]` MUST stay equal to the menubar `Slider`'s `in:` range.

**Barge-in** is in-process: starting a recording (or "hold on") calls `TTSPlaybackController.bargeIn()`, which cancels pending synthesis (freeing the ANE for STT) and stops audio instantly. `DictationManager` gets the controller injected by `AppDelegate`.

### Voice-turn handshake (nudge + `speak` tool — the subtle part)

By default (**Response = `when Voice`**) only **voice-dictated** turns are spoken; typed turns stay silent. The `tts_response_mode` pref (or per-project `OW_TTS_RESPONSE`) changes *when* replies are spoken — `voice` (default) | `always`. There is **no Stop hook and no `speak_pending` marker**: the model's own mid-turn `speak` tool call produces the audio, so it starts ~1 s into the turn instead of after the reply finishes. The mechanism:

1. On each dictation the app writes `voice_turn` = SHA-256 of the dictated text + a unix timestamp (`VoiceSignal.canonicalHash`).
2. The **UserPromptSubmit** hook (`hooks/voice-context.sh`) recomputes `shasum -a 256` of the submitted prompt; on a match it **claims (removes)** `voice_turn`, classifies the turn `IS_VOICE`, applies the response mode, and on a "speak" decision injects a hidden `additionalContext` nudge telling the model to **call the `speak` tool first** with a standalone spoken summary (length shaped by `tts_style`).
3. The model calls `speak(text)` → the app's `POST /mcp` handler synthesizes + plays in-process. Nothing runs at turn end.

**Native-tongue flavor.** For a **personified** voice, `voice-context.sh` reads `tts_voice` and adds one layer to the nudge: an **ungated persona** — a light national character (e.g. French = *dry and faintly unimpressed*; Hindi = *irrepressibly helpful*; American English = *quietly self-assured, light SV hype*; British English = *dry and unflappable*), present on **every** turn for that voice. First-char map: `a`→American English, `b`→British English, `f`→French, `i`→Italian, `e`→Spanish, `p`→Brazilian Portuguese, `h`→Hindi, `j`→Japanese, `z`→Mandarin Chinese; unknown/no-voice gets nothing. The map + personas live **only** in the hook — no Swift parity pair (unlike `VoiceSignal.canonicalHash`); `HookTests` guards them (persona sentinel `voice speaking your reply`). **Why this shape (don't re-litigate):** the personas are a deliberate, *playful* national-stereotype touch kept subdued — personality only, no vocabulary steering. An earlier cut also had a rare-gated "native word" line (`OW_FLAVOR_ROLL`, ~1 in 5 turns) plus tone-not-vocabulary guardrails; both were dropped 2026-07-02 after transcripts showed the model code-switches from the persona alone (the gate never fired, yet every spoken summary carried a foreign word), so the extra wording was dead weight. Whatever code-switching happens now is the model's own. Tune the wording in the hook, and keep it subdued.

**One hook, both platforms.** `voice-context.sh` serves Claude Code *and* Codex — both fire a `UserPromptSubmit` command hook whose stdin carries `prompt`+`session_id` and whose stdout `{hookSpecificOutput:{additionalContext}}` is honored identically. `ConfigManager` registers the MCP server + this hook for each platform (Claude → `~/.claude.json` + `~/.claude/settings.json`; Codex → `~/.codex/config.toml`).

`VoiceSignal.canonicalHash` lives in `OpenWhispererKit` and is unit-tested specifically to guarantee parity with the bash `shasum` reader — **if you touch hashing/trimming on either side, update both and run `HookTests`.**

**Known limitations (by design, document don't "fix" blindly):**
- The hash covers the **dictated text only**. It matches the submitted prompt **only when the input buffer was empty** before dictation. Pre-typed text in the prompt, or dictating twice into one prompt, makes `trim(prompt) != dictated text` → the turn is treated as typed and silently **not spoken**. Editing a dictated prompt before submit (manual-submit mode) likewise un-matches — which is correct (you took over by keyboard).
- **No fallback.** If the model doesn't call `speak` on a turn the mode meant to speak, that turn is simply silent (accepted, KISS). Spiked at 13/13 (Claude) and 5/5 (Codex) speak-first; the untested case is very long interactive agentic turns.
- **Codex requires hook trust.** Codex silently skips *untrusted* hooks, so a first-run user must approve trusting the OpenWhisperer hook once (the setup window says so). Until then, dictated turns are silent on Codex.
- The voice-turn TTL is **900 s**, uniform across `voice-context.sh` and `codex-tts-hook.sh`'s successor (none — Codex now shares `voice-context.sh`).
- **Antigravity (agy) is supported** (2026-07-06, superseding the earlier "unsupported" finding). agy's `PreInvocation` hook — undocumented in the 2026-06-29 spike, present in agy v1.0.16 — fires before every model call, and `invocationNum` resets to `0` at the start of each new user turn (confirmed live), giving early-speak the once-per-turn gate it needs. `hooks/agy-previnvocation.sh` reads the just-submitted prompt from `transcriptPath`'s last `USER_EXPLICIT` entry (no prompt text is given on stdin), classifies it against `voice_turn` via the shared `hooks/voice-shared.sh` (also used by `voice-context.sh`), and on a "speak" decision emits `{"injectSteps":[{"ephemeralMessage": "..."}]}`. The `speak` MCP tool is reached over agy's `serverUrl` (SSE) transport in `~/.gemini/config/mcp_config.json`, pointed at the same `POST /mcp` endpoint Claude/Codex/Pi use — no stdio shim needed, contrary to an earlier design review. The hook is registered in the **global** `~/.gemini/config/hooks.json`, not a per-workspace `.agents/hooks.json` (confirmed live: the global file fires for any workspace). Like Claude/Codex, there is no Stop-hook fallback — a missed `speak` call means a silent turn. See `docs/superpowers/specs/2026-07-06-agy-voice-support-design.md` for the full spike findings.
- **Pi (`@earendil-works/pi-coding-agent`) — supported via a single extension, NOT MCP** (validated 2026-06-29). Pi is deliberately MCP-free (its author, Mario Zechner, argues you often don't need MCP), so one self-contained TS extension (`~/.pi/agent/extensions/openwhisperer.ts`) replaces the MCP-server + bash-hook combo: `pi.registerTool({ name: "openwhisperer_speak" })` plays via the existing `:8000` `/v1/audio/play` endpoint, and a `before_agent_start` handler reads `voice_turn`, hash-matches the prompt (same `VoiceSignal.canonicalHash`), and injects the gated speak-first nudge; a `renderCall` shows a branded "OpenWhisperer" TUI header. Validated end-to-end on **Pi + local ollama `gemma4`** — free, fully offline, no cloud key (gemma4 *is* tool-capable: ollama advertises `tools`). The extension lives at `pi/openwhisperer.ts` (bundled into the `.app`); selecting **Pi** in the Setup card → Auto-Apply copies it into `~/.pi/agent/extensions/` (`ConfigManager.applyToPi`), then `/reload` in Pi loads it. It hits the TTS server's `/v1/audio/play` endpoint — no MCP, no bash hook, no hook-trust: the lightest of the three integrations.

### State & IPC: flat files in Application Support

`~/Library/Application Support/OpenWhisperer` (0700) is the shared bus between the GUI app, the bash hooks, and the embedded server. All prefs and signals are flat files — see `Paths.swift` for the full list. Notable ones: `tts_voice`, `tts_volume`, `tts_speed` (global TTS playback rate, default 1.1, clamped 0.7–1.5 via `TTSSpeed`), `stt_language`, `interaction_mode`, `ptt_hotkey`, `tts_style` (spoken-summary style: `terse`/`normal`/`rich` summary lengths; `full` now folds into the richest tier; was `voice_detail` before the rename — `ConfigManager.migrateVoiceDetailToTtsStyle()` migrates it on launch), `tts_response_mode` (when replies are spoken: `voice`/`always`), `selected_platform`, `auto_submit`, `auto_focus_app`, `voice_turn`, and `tts_playing.lock` (written while speaking; polled to drive the overlay waveform and mute the mic in hands-free mode).

These are global (one menubar setting for all repos), but `tts_style`, `tts_response_mode`, `tts_voice`, and `tts_speed` can be **overridden per-project** via env vars in that repo's `.claude/settings.local.json` `env` block — read by `voice-context.sh` (and Pi's extension), which take precedence over the global files: `OW_TTS_STYLE`, `OW_TTS_RESPONSE`, `OW_TTS_VOICE`, and `OW_TTS_SPEED`. For Claude/Codex, voice/speed overrides are injected into the speak nudge as `speak` tool args (model-echoed); on Pi the extension passes them to `/v1/audio/play` directly (deterministic). For Claude/Codex, the override voice also drives the native-tongue flavor.

### Concurrency

`SpeechTranscriber`, `KokoroTTS`, and `TTSPlaybackController` are **actors** — they serialize work on the single ANE/compute unit and dedup the one-time model load (concurrent callers await the same in-flight `prepare()`).

### Models & offline-first

First run downloads the models; both then prefer their on-disk cache and load **offline** when present:

- WhisperKit → `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<model>` (`SpeechTranscriber` explicitly loads with `download: false` when cached).
- FluidAudio Kokoro → `~/.cache/fluidaudio` (models and voice packs).
  - *Note on Alternative Voices:* The upstream `FluidInference/kokoro-82m-coreml` repository only hosts the default `af_heart.bin` voice file under the `ANE/` subpath. Downloading alternative voices from this repository will fail (404/silent error). The menubar Voice picker offers the full Kokoro-82M v1.0 roster (~54 voices, grouped by language); selecting any non-default voice triggers `KokoroTTS.ensureVoicePack`, which downloads its `<voice>.bin` from the `onnx-community/Kokoro-82M-v1.0-ONNX` repository (`resolve/main/voices/<voice>.bin`) into `~/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE/<voice>.bin` on demand. It re-fetches if the cached file is missing or under 1 KB, and rejects non-200 responses so an error page is never cached as a voice.

This matters because the developer's firewall (Little Snitch) blocks the HuggingFace **Xet CDN**, which breaks fresh downloads — an already-cached model still loads.

## Conventions & gotchas

- **Code signing identity** is set by `OW_SIGN_IDENTITY` (default `-` = ad-hoc). With ad-hoc, the cdhash changes every build, so macOS **drops the Accessibility and Microphone grants** — dictation breaks until you remove and re-add the app in System Settings → Privacy & Security. **To stop the churn locally:** sign with a stable self-signed cert — `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh` — whose designated requirement pins to the cert leaf hash (constant across rebuilds), so TCC grants persist; you re-grant only once. Release builds set `OW_SIGN_IDENTITY="Developer ID Application: …"` plus `OW_NOTARIZE=1` and `OW_NOTARIZE_PROFILE` to add hardened runtime (`Resources/OpenWhisperer.entitlements`) + notarize + staple the DMG (needs a paid Apple Developer account).
- Platform (Claude Code, Codex CLI, Pi, or Antigravity) is selected in the menubar; `ConfigManager` applies the right thing per platform: Claude → hook in `~/.claude/settings.json` + `speak` MCP server in `~/.claude.json`; Codex → both in `~/.codex/config.toml` (needs one-time hook-trust); Pi → copies the `pi/openwhisperer.ts` extension into `~/.pi/agent/extensions/`; Antigravity → global hook and mcp config.
- Version is single-sourced from `app/Resources/Info.plist` — bump `CFBundleVersion` + `CFBundleShortVersionString` together; `build-dmg.sh` derives the DMG name from `CFBundleShortVersionString` via PlistBuddy.
- **Rebuilding & Installing locally:** Since hook files (`hooks/*.sh`) are bundled into the application resource path (`OpenWhisperer.app/Contents/Resources/hooks/`) during build, any hook changes require rebuilding the app (`./build-dmg.sh`). To install it locally, terminate any running app instance (`killall OpenWhisperer`), remove the old app (`rm -rf /Applications/OpenWhisperer.app`), and copy the fresh build (`cp -R app/.build/OpenWhisperer.app /Applications/`).
- `app/Tools/` (G2PParity, STTDiag, FluidTTSSpike) are local-only diagnostic spikes and are **gitignored**.
- Design docs and implementation plans live in `docs/superpowers/{specs,plans}/`, organized by phase (Phase 1 = STT port, Phase 2 = native TTS, Phase 3 = streaming TTS). Consult these for the rationale behind the Swift port.
