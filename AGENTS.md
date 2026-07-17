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
swift run OpenWhisperer --mcp-stdio   # stdio⇄HTTP MCP bridge (Claude Desktop); proxies to :8000/mcp
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
- **`OpenWhisperer`** — the executable (AppKit/SwiftUI menubar app + native STT/TTS). Depends on `FluidAudio` (Parakeet STT + Kokoro TTS) — the single speech library since 2026-07-13.
- **`OpenWhispererKitTests`**, **`HookTests`** — the two executable test runners above.

Entry point `OpenWhispererMain.main()`: `--serve-tts` → headless TTS; otherwise the SwiftUI `MenuBarExtra` app. `AppDelegate` owns the long-lived managers (`ServerManager`, `SetupManager`, `DictationManager`, `HotkeyManager`, `AccessibilityManager`). The app is `LSUIElement` (menubar only, no dock icon).

### STT (dictation) — fully in-process, no server

`HotkeyManager` watches a modifier key (Ctrl/fn/Option/Cmd) → `AppDelegate` captures the frontmost app's PID *before* any focus shift → `DictationManager` orchestrates: `AudioRecorder` (16 kHz mono PCM) → `ParakeetTranscriber` (FluidAudio Parakeet TDT v3, on the ANE) → types the result into the captured app via Accessibility / CGEvent Unicode (the **clipboard is never touched**). Three `InteractionMode`s: `holdToTalk` (default), `pressToTalk`, `handsFree` (`KeywordDetector` uses Apple's Speech framework for "initiate"/"hold on").

> **STT is Parakeet TDT v3 since 2026-07-13** (WhisperKit removed), after the user waived the Turkish + macOS-14 constraints that drove the earlier rejection (2026-06-20, PR #6). Measured on-device: ~8–10x faster decode (50–80 ms vs 500–900 ms per clip), comparable quiet-room accuracy, and it handled the old glossary's jargon (Kokoro/Codex/Sentry) with **no glossary at all** — `stt_vocabulary`/`promptTokens` was Whisper-only and is gone (`stt_vocabulary` was revived 2026-07-17 as a text-layer fuzzy-correction glossary — `VocabularyCorrector` in Kit, applied post-transcription; not acoustic promptTokens). Known trade-offs, accepted: literal transcripts (fillers/repairs kept, occasional comma spray, farther/further-class homophone slips) and weaker noise robustness than Whisper. If jargon accuracy ever regresses, FluidAudio has a vocabulary-boosting path (CTC keyword spotter + `configureVocabularyBoosting`) that needs an extra model download. Full rationale + measurements: `docs/superpowers/specs/2026-06-20-engine-configurability-design.md` (2026-07-13 addenda). The transcription watchdog is 35 s warm / 180 s cold — a cold first dictation loads the model inside the watchdogged task, and recording-start pre-warms it.

### TTS (spoken replies) — in-process synth + playback, `speak` MCP tool

`ServerManager` hosts `KokoroTTS` (FluidAudio) behind `TTSHTTPServer`, a tiny loopback-only HTTP/1.1 server on **:8000** (Network.framework, zero deps). The app also hosts a minimal **MCP server at `POST /mcp`** exposing a `speak` tool (see Voice-turn handshake): the model calls `speak(text, voice?, speed?)` mid-turn (optional `voice`, resolved from the user's `tts_voice` pref, and `speed`, clamped via `TTSSpeed`, both defaulting to the user's global prefs) → the in-process `MCPServer` dispatch (`OpenWhispererKit`, pure JSON-RPC) → `TTSPlaybackController` synthesizes **sentence-by-sentence** (`SentenceSplitter`) and plays gaplessly via `AudioPlaybackEngine` (`AVAudioPlayerNode`) — so the first sentence plays while the rest are still synthesizing. Endpoints: `GET /v1/models`, `POST /v1/audio/speech` (blocking WAV — used by `scripts/speak.sh`), `POST /v1/audio/play` (fire-and-forget; also takes optional `voice` (resolved from `tts_voice`) and `speed` (clamped via `TTSSpeed`); used by the Pi extension's `openwhisperer_speak` tool), `POST /mcp` (MCP Streamable HTTP, protocol `2025-11-25` — the `speak` tool).

**Playback rate.** The global `tts_speed` pref (a Settings → Voice slider, 0.7–1.5, default 1.1 — upstream is 1.0) is threaded into `KokoroTTS` synthesis and read where `tts_volume` is read — `TTSPlaybackController` (so the `speak` tool + `/v1/audio/play` pick it up) and the blocking `/v1/audio/speech` (which also honors an optional per-request `speed`). Parsing/clamping lives in pure `TTSSpeed` (`OpenWhispererKit`), unit-tested; its `[min, max]` MUST stay equal to the Settings → Voice `Slider`'s `in:` range.

**Barge-in** is in-process: starting a recording (or "hold on") calls `TTSPlaybackController.bargeIn()`, which cancels pending synthesis (freeing the ANE for STT) and stops audio instantly. `DictationManager` gets the controller injected by `AppDelegate`.

### Voice-turn handshake (nudge + `speak` tool — the subtle part)

By default (**Response = `when Voice`**) only **voice-dictated** turns are spoken; typed turns stay silent. The `tts_response_mode` pref (or per-project `OW_TTS_RESPONSE`) changes *when* replies are spoken — `voice` (default) | `always`. There is **no Stop hook and no `speak_pending` marker**: the model's own mid-turn `speak` tool call produces the audio, so it starts ~1 s into the turn instead of after the reply finishes. The mechanism:

1. On each dictation the app writes `voice_turn` = SHA-256 of the dictated text + a unix timestamp (`VoiceSignal.canonicalHash`).
2. The **UserPromptSubmit** hook (`hooks/voice-context.sh`) recomputes `shasum -a 256` of the submitted prompt; on a match it **claims (removes)** `voice_turn`, classifies the turn `IS_VOICE`, applies the response mode, and on a "speak" decision injects a hidden `additionalContext` nudge telling the model to **call the `speak` tool first** with a standalone spoken summary (length shaped by `tts_style`).
3. The model calls `speak(text)` → the app's `POST /mcp` handler synthesizes + plays in-process. Nothing runs at turn end.

**Native-tongue flavor.** For a **personified** voice, `voice-context.sh` reads `tts_voice` and adds one layer to the nudge: an **ungated persona** — a light national character (e.g. French = *dry and faintly unimpressed*; Hindi = *irrepressibly helpful*; American English = *quietly self-assured, light SV hype*; British English = *dry and unflappable*), present on **every** turn for that voice. First-char map: `a`→American English, `b`→British English, `f`→French, `i`→Italian, `e`→Spanish, `p`→Brazilian Portuguese, `h`→Hindi, `j`→Japanese, `z`→Mandarin Chinese; unknown/no-voice gets nothing. The map + personas live in the hook, with one 2026-07-17 exception: `MCPInstructions.flavor` in Kit now carries a copy for the MCP tier (Claude Desktop has no hook to read it from) — tune both together; `HookTests` guards the bash side (persona sentinel `voice speaking your reply`), `MCPInstructionsChecks` the Swift side. **Why this shape (don't re-litigate):** the personas are a deliberate, *playful* national-stereotype touch kept subdued — personality only, no vocabulary steering. An earlier cut also had a rare-gated "native word" line (`OW_FLAVOR_ROLL`, ~1 in 5 turns) plus tone-not-vocabulary guardrails; both were dropped 2026-07-02 after transcripts showed the model code-switches from the persona alone (the gate never fired, yet every spoken summary carried a foreign word), so the extra wording was dead weight. Whatever code-switching happens now is the model's own. Tune the wording in the hook, and keep it subdued.

**One hook, both platforms.** `voice-context.sh` serves Claude Code *and* Codex — both fire a `UserPromptSubmit` command hook whose stdin carries `prompt`+`session_id` and whose stdout `{hookSpecificOutput:{additionalContext}}` is honored identically. `ConfigManager` registers the MCP server + this hook for each platform (Claude → `~/.claude.json` + `~/.claude/settings.json`; Codex → `~/.codex/config.toml`).

`VoiceSignal.canonicalHash` lives in `OpenWhispererKit` and is unit-tested specifically to guarantee parity with the bash `shasum` reader — **if you touch hashing/trimming on either side, update both and run `HookTests`.**

**Known limitations (by design, document don't "fix" blindly):**
- The hash covers the **dictated text only**. It matches the submitted prompt **only when the input buffer was empty** before dictation. Pre-typed text in the prompt, or dictating twice into one prompt, makes `trim(prompt) != dictated text` → the turn is treated as typed and silently **not spoken**. Editing a dictated prompt before submit (manual-submit mode) likewise un-matches — which is correct (you took over by keyboard).
- **No fallback.** If the model doesn't call `speak` on a turn the mode meant to speak, that turn is simply silent (accepted, KISS). Spiked at 13/13 (Claude) and 5/5 (Codex) speak-first; the untested case is very long interactive agentic turns.
- **Codex requires hook trust.** Codex silently skips *untrusted* hooks, so a first-run user must approve trusting the OpenWhisperer hook once (the setup window says so). Until then, dictated turns are silent on Codex.
- The voice-turn TTL is **900 s**, uniform across `voice-context.sh` and `codex-tts-hook.sh`'s successor (none — Codex now shares `voice-context.sh`).
- **Antigravity (agy) is supported** (2026-07-06, superseding the earlier "unsupported" finding). agy's `PreInvocation` hook — undocumented in the 2026-06-29 spike, present in agy v1.0.16 — fires before every model call, and `invocationNum` resets to `0` at the start of each new user turn (confirmed live), giving early-speak the once-per-turn gate it needs. `hooks/agy-previnvocation.sh` reads the just-submitted prompt from `transcriptPath`'s last `USER_EXPLICIT` entry (no prompt text is given on stdin), classifies it against `voice_turn` via the shared `hooks/voice-shared.sh` (also used by `voice-context.sh`), and on a "speak" decision emits `{"injectSteps":[{"ephemeralMessage": "..."}]}`. The `speak` MCP tool is reached over agy's `serverUrl` (SSE) transport in `~/.gemini/config/mcp_config.json`, pointed at the same `POST /mcp` endpoint Claude/Codex/Pi use — no stdio shim needed, contrary to an earlier design review. The hook is registered in the **global** `~/.gemini/config/hooks.json`, not a per-workspace `.agents/hooks.json` (confirmed live: the global file fires for any workspace). Like Claude/Codex, there is no Stop-hook fallback — a missed `speak` call means a silent turn. See `docs/superpowers/specs/2026-07-06-agy-voice-support-design.md` for the full spike findings.
- **Pi (`@earendil-works/pi-coding-agent`) — supported via a single extension, NOT MCP** (validated 2026-06-29). Pi is deliberately MCP-free (its author, Mario Zechner, argues you often don't need MCP), so one self-contained TS extension (`~/.pi/agent/extensions/openwhisperer.ts`) replaces the MCP-server + bash-hook combo: `pi.registerTool({ name: "openwhisperer_speak" })` plays via the existing `:8000` `/v1/audio/play` endpoint, and a `before_agent_start` handler reads `voice_turn`, hash-matches the prompt (same `VoiceSignal.canonicalHash`), and injects the gated speak-first nudge; a `renderCall` shows a branded "OpenWhisperer" TUI header. Validated end-to-end on **Pi + local ollama `gemma4`** — free, fully offline, no cloud key (gemma4 *is* tool-capable: ollama advertises `tools`). The extension lives at `pi/openwhisperer.ts` (bundled into the `.app`); selecting **Pi** in Settings → Agents → Auto-Apply copies it into `~/.pi/agent/extensions/` (`ConfigManager.applyToPi`), then `/reload` in Pi loads it. It hits the TTS server's `/v1/audio/play` endpoint — no MCP, no bash hook, no hook-trust: the lightest of the three integrations.

**MCP-only tier (Claude Desktop, 2026-07-17).** Claude Desktop has no hooks, so it gets a different mechanism entirely. Dictations targeting it get a leading bare `🎙` (`VoiceMarker.glyph` in Kit, applied only for allowlisted bundle IDs — `com.anthropic.claudefordesktop`); the MCP server ships a standing instruction (`MCPInstructions` in Kit) via `initialize.instructions` + the speak tool description (guidance now *prepended*, not appended — it's the first thing the model reads), regenerated from prefs on every request. Deleting the `🎙` silences a turn, typing it force-speaks. The instruction is marker-gated and therefore inert on hook platforms (no `clientInfo` scoping — the transport is stateless). Claude Desktop launches the `--mcp-stdio` bridge from `claude_desktop_config.json`, which proxies to the running app's `:8000/mcp`. Hooks remain the gold path on Claude Code/Codex/agy pending the compliance data in the spec; the marker deliberately does NOT extend to terminal-hosted CLIs (frontmost app ≠ agent focus). Cold-start tool discovery — Desktop loads MCP tool descriptions lazily by relevance-matching the user message, so a bare glyph alone never triggers the load — is handled not by marker wording (a `🎙 speak` word-trick was tried and reverted 2026-07-17: it bought probability, not certainty) but by a bundled, always-visible personal skill, `openwhisperer-voice` (`DesktopSkill` in Kit): skill name+description sit in the model's context on every turn via progressive disclosure, independent of tool loading. `ConfigManager.applyToClaudeDesktop()` installs `SKILL.md` into `~/.claude/skills/openwhisperer-voice/` alongside the MCP config entry during Auto-Apply (a skill-write failure doesn't fail the apply); `checkHookConfigured` for this platform requires both the config entry and the skill file. The skill is shared with Claude Code's skills dir but inert there (no CLI platform types a marker). Both the standing instruction and the skill also carry explicit "never ask whether to speak" wording, guarding against a model that loaded the tool but treats speaking as optional.

### State & IPC: flat files in Application Support

`~/Library/Application Support/OpenWhisperer` (0700) is the shared bus between the GUI app, the bash hooks, and the embedded server. All prefs and signals are flat files — see `Paths.swift` for the full list. Notable ones: `tts_voice`, `tts_volume`, `tts_speed` (global TTS playback rate, default 1.1, clamped 0.7–1.5 via `TTSSpeed`), `stt_language`, `interaction_mode`, `ptt_hotkey`, `tts_style` (spoken-summary style: `terse`/`normal`/`rich` summary lengths; `full` now folds into the richest tier; was `voice_detail` before the rename — `ConfigManager.migrateVoiceDetailToTtsStyle()` migrates it on launch), `tts_response_mode` (when replies are spoken: `voice`/`always`), `selected_platform`, `auto_submit`, `auto_focus_app`, `voice_turn`, and `tts_playing.lock` (written while speaking; polled to drive the overlay waveform and mute the mic in hands-free mode).

These are global (one menubar setting for all repos), but `tts_style`, `tts_response_mode`, `tts_voice`, and `tts_speed` can be **overridden per-project** via env vars in that repo's `.claude/settings.local.json` `env` block — read by `voice-context.sh` (and Pi's extension), which take precedence over the global files: `OW_TTS_STYLE`, `OW_TTS_RESPONSE`, `OW_TTS_VOICE`, and `OW_TTS_SPEED`. For Claude/Codex, voice/speed overrides are injected into the speak nudge as `speak` tool args (model-echoed); on Pi the extension passes them to `/v1/audio/play` directly (deterministic). For Claude/Codex, the override voice also drives the native-tongue flavor.

### Concurrency

`ParakeetTranscriber`, `KokoroTTS`, and `TTSPlaybackController` are **actors** — they serialize work on the single ANE/compute unit and dedup the one-time model load (concurrent callers await the same in-flight `prepare()`).

### Models & offline-first

First run downloads the models; both then prefer their on-disk cache and load **offline** when present:

- FluidAudio Parakeet (STT) → `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` (~600 MB; `AsrModels.downloadAndLoad(version: .v3)` prefers the cache). The removed WhisperKit engine's ~1.5 GB hub (`~/Library/Application Support/OpenWhisperer/models/huggingface`, or legacy `~/Documents/huggingface`) is orphaned — `ModelStorage.locations` lists both so Settings → Advanced → "Delete models" reclaims them.
- FluidAudio Kokoro → `~/.cache/fluidaudio` (models and voice packs). **Not** relocated with Whisper: `KokoroAneManager` takes a custom `directory:`, but FluidAudio pins the shared G2P/English-lexicon assets to `~/.cache/fluidaudio` regardless (a `G2PModel.shared` singleton, `directory: nil` upstream), so moving only the model store would split the cache and risk breaking TTS. It's a hidden cache outside iCloud/Documents, so it stays put.
  - *Note on Alternative Voices:* The upstream `FluidInference/kokoro-82m-coreml` repository only hosts the default `af_heart.bin` voice file under the `ANE/` subpath. Downloading alternative voices from this repository will fail (404/silent error). The Settings → Voice picker offers the full Kokoro-82M v1.0 roster (~54 voices, grouped by language); selecting any non-default voice triggers `KokoroTTS.ensureVoicePack`, which downloads its `<voice>.bin` from the `onnx-community/Kokoro-82M-v1.0-ONNX` repository (`resolve/main/voices/<voice>.bin`) into `~/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE/<voice>.bin` on demand. It re-fetches if the cached file is missing or under 1 KB, and rejects non-200 responses so an error page is never cached as a voice.

This matters because the developer's firewall (Little Snitch) blocks the HuggingFace **Xet CDN**, which breaks fresh downloads — an already-cached model still loads.

## Conventions & gotchas

- **Code signing identity** is set by `OW_SIGN_IDENTITY` (default `-` = ad-hoc). With ad-hoc, the cdhash changes every build, so macOS **drops the Accessibility and Microphone grants** — dictation breaks until you remove and re-add the app in System Settings → Privacy & Security. **To stop the churn locally:** sign with a stable self-signed cert — `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh` — whose designated requirement pins to the cert leaf hash (constant across rebuilds), so TCC grants persist; you re-grant only once. Release builds set `OW_SIGN_IDENTITY="Developer ID Application: …"` plus `OW_NOTARIZE=1` and `OW_NOTARIZE_PROFILE` to add hardened runtime (`Resources/OpenWhisperer.entitlements`) + notarize + staple the DMG (needs a paid Apple Developer account).
- Platform (Claude Code, Codex CLI, Pi, Antigravity, or Claude Desktop) is selected in Settings → Agents; `ConfigManager` applies the right thing per platform: Claude → hook in `~/.claude/settings.json` + `speak` MCP server in `~/.claude.json`; Codex → both in `~/.codex/config.toml` (needs one-time hook-trust); Pi → copies the `pi/openwhisperer.ts` extension into `~/.pi/agent/extensions/`; Antigravity → global hook and mcp config; Claude Desktop → MCP entry in `~/Library/Application Support/Claude/claude_desktop_config.json` (stdio bridge, no hook, no trust step).
- Version is single-sourced from `app/Resources/Info.plist` — bump `CFBundleVersion` + `CFBundleShortVersionString` together; `build-dmg.sh` derives the DMG name from `CFBundleShortVersionString` via PlistBuddy.
- **Rebuilding & Installing locally:** Since hook files (`hooks/*.sh`) are bundled into the application resource path (`OpenWhisperer.app/Contents/Resources/hooks/`) during build, any hook changes require rebuilding the app (`./build-dmg.sh`). To install it locally, terminate any running app instance (`killall OpenWhisperer`), remove the old app (`rm -rf /Applications/OpenWhisperer.app`), and copy the fresh build (`cp -R app/.build/OpenWhisperer.app /Applications/`).
- `app/Tools/` (G2PParity, STTDiag, FluidTTSSpike) are local-only diagnostic spikes and are **gitignored**.
- Design docs and implementation plans live in `docs/superpowers/{specs,plans}/`, organized by phase (Phase 1 = STT port, Phase 2 = native TTS, Phase 3 = streaming TTS). Consult these for the rationale behind the Swift port.
