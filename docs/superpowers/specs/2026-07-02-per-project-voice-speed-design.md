# Per-project voice & speed + drop `text` response mode

**Date:** 2026-07-02
**Status:** Approved (brainstorming) — pending implementation plan

## Goal

Two related changes to the TTS config surface:

1. **Remove the `text` response mode.** The mode has no defensible use case — it
   speaks *only typed* turns and silences *dictated* ones, the exact inverse of
   the natural talk→hear loop. Response mode becomes just `voice` / `always`.
2. **Make voice and speed per-project**, joining `OW_TTS_STYLE` /
   `OW_TTS_RESPONSE`. The driving use case: a repo answering in its own
   recognizable voice, so the user knows by ear which project replied. Works on
   all three platforms (Claude Code, Codex, Pi).

This reverses the "Voice is global-only now" statement in AGENTS.md — that was
true only because nothing bridged a project's env to the synth. The hook (and
Pi's extension) already sees the project env; we route voice/speed through it.

## Decisions (settled during brainstorming)

- **Nudge-only for Claude/Codex.** The hook injects `voice="…" speed=…` into the
  nudge; the model echoes them into the `speak` call. Model-dependent: if the
  model omits an arg, that turn falls back to the global pref. Accepted — matches
  the existing "no fallback" philosophy, and "nudging is good enough."
- **Deterministic for Pi.** Pi's extension *makes* the play call itself, so its
  `openwhisperer_speak` handler reads the prefs and puts voice/speed in the body
  directly — no model dependency. Pi gets the stronger path for free.
- **`speed` added to the `speak` MCP tool schema** (Claude/Codex path).
- **Per-project voice drives the native-tongue flavor** — the first-char language
  map keys off the resolved voice (override → global), so a French-voice project
  also gets French flavor.
- **Inject args only when the project overrides.** Default projects keep today's
  lean nudge and rely on the tool's existing global fallback. Minimal diff, no
  behavior change for the common case.

## Non-goals (YAGNI)

- No per-project *volume*, *language*, or *interaction mode* — only voice/speed
  join the per-project set.
- No native-tongue **flavor for Pi** — Pi's nudge has never carried the flavor
  line; that pre-existing gap stays out of scope. Per-project voice alone
  achieves the recognition goal (the voice *is* the identity signal).
- No new UI. The menubar stays global-only for voice/speed; per-project is an
  env-var affordance, exactly like style/response.
- No version bump.

## Approach

### Part A — drop `text` mode

- **`hooks/voice-context.sh`** — delete the `text)` branch from the mode `case`
  (line 69). A lingering `text` value (env or file) falls through to the `*)`
  default = **voice** behavior, so it self-heals; no hard error.
- **`app/Sources/OpenWhisperer/MenuBarView.swift`** — remove
  `("text", "when Text")` from `responseModes` (line 181) and drop the "when
  Text" clause from the `.help(...)` string (line 661). The `.onAppear` restore
  already guards against unknown saved values (line 305), so a stale `text` file
  silently reverts to the default `voice` in the picker.
- **`pi/openwhisperer.ts`** — delete the `else if (mode === "text")` branch
  (line 139).
- **`app/Sources/OpenWhisperer/ConfigManager.swift`** — add a small launch
  migration mirroring `migrateVoiceDetailToTtsStyle()`: if the global
  `tts_response_mode` file reads `text`, rewrite it to `voice`. Keeps persisted
  state clean rather than relying only on the self-heal.

### Part B — per-project voice/speed, Claude & Codex (nudge)

**`hooks/voice-context.sh`:**

- Resolve voice with the same precedence as style/response:
  `VOICE = OW_TTS_VOICE (env) → tts_voice file → ""`. Use this resolved value at
  the flavor map (line 88) so the flavor language follows the per-project voice.
- Resolve speed: `SPEED = OW_TTS_SPEED (env) → tts_speed file → ""`.
- When the project **overrides** voice/speed (i.e. the `OW_TTS_*` env var is set),
  append an explicit arg directive to the speak instruction in `NUDGE`
  (line 110), e.g. `Call the speak tool with voice="ff_siwis" and speed=1.1.`
  Inject `voice` only when `OW_TTS_VOICE` is set; inject `speed` only when
  `OW_TTS_SPEED` is set **and parses as a number** (junk is dropped — the tool
  falls back). The default (non-overridden) nudge is byte-for-byte unchanged.

Precedence note: the *flavor* reads the resolved voice from env-or-file, but the
*nudge arg* is injected only from the env override — because a globally-selected
voice is already the tool's default, so echoing it would be redundant.

### Part C — `speed` on the `speak` MCP tool + plumbing

- **`app/Sources/OpenWhispererKit/MCPServer.swift`** —
  - `tools/list`: add a `speed` property to the `speak` `inputSchema`
    (`type: number`, description noting the 0.7–1.5 range, optional).
  - `tools/call`: parse `let speed = args["speed"] as? Double` alongside `voice`.
  - Extend the action: `case speak(response: Data, text: String, voice: String?,
    speed: Double?)`.
- **`app/Sources/OpenWhisperer/TTSHTTPServer.swift`** — in the `.speak` case
  (line 144–145), thread speed into playback:
  `play(text:, voice: voice ?? userVoice(), speed: resolvedSpeed)` where
  `resolvedSpeed` clamps a finite `speed` via `TTSSpeed.clamp` (same finiteness
  guard as `/v1/audio/speech`, line 115) and otherwise falls back to
  `userSpeed()`.
- **`app/Sources/OpenWhisperer/TTSPlaybackController.swift`** — change
  `play(text:voice:)` to `play(text:voice:speed:)` taking a concrete `Float`
  speed, and drop the internal `readSpeed()` default (the caller now supplies it,
  matching how `voice` is already caller-supplied). `readSpeed()` itself can be
  removed once no caller uses it.

### Part D — Pi parity (deterministic)

- **`app/Sources/OpenWhisperer/TTSHTTPServer.swift`** — `POST /v1/audio/play`
  (line 126–134) accepts an optional numeric `speed` in the JSON body, guarded +
  clamped exactly like `/v1/audio/speech`, and passes it into `play(...)`. It
  already accepts `voice`.
- **`pi/openwhisperer.ts`** — the `openwhisperer_speak` `execute` handler reads
  `readPref("OW_TTS_VOICE", "tts_voice", "")` and
  `readPref("OW_TTS_SPEED", "tts_speed", "")` and includes them in the play body
  when non-empty/valid: `{ input, voice?, speed? }`. Because the extension owns
  the call, this is model-independent.

## Data flow

- **Claude/Codex:** dictation → `voice_turn` written → `UserPromptSubmit` hook
  resolves mode/style/voice/speed from project env → injects speak-first nudge
  (with `voice="…" speed=…` when overridden) → model calls `speak(text, voice,
  speed)` → `POST /mcp` → `MCPServer` → `TTSPlaybackController.play(text:voice:
  speed:)` → gapless streaming playback.
- **Pi:** `before_agent_start` gates + nudges (speak-first) → model calls
  `openwhisperer_speak(text)` → extension reads voice/speed prefs → `POST
  /v1/audio/play {input, voice, speed}` → same playback path.
- **`scripts/speak.sh`:** unchanged — `POST /v1/audio/speech` already honors a
  body `speed`.

## Sync points

- `TTSSpeed.min/max` must still equal the menubar `Slider`'s `in:` range
  (unchanged from the speed-control spec — this only adds new *readers*).
- The native-tongue **language map lives only in `voice-context.sh`**; there is
  no Swift parity pair. `HookTests` remains its guard and must cover the new
  "flavor follows `OW_TTS_VOICE`" behavior.
- `voice_turn` hashing/trimming parity with `VoiceSignal.canonicalHash` is
  untouched.

## Testing

- **`swift run HookTests`** — new checks:
  - `text` mode gone: with `OW_TTS_RESPONSE=text` (or file), a dictated turn
    still speaks and a typed turn stays silent (i.e. behaves as `voice`).
  - `OW_TTS_VOICE` / `OW_TTS_SPEED` precedence (env over file over unset).
  - Nudge includes `voice="…"`/`speed=…` when the override is set, and omits them
    (byte-identical to today's nudge) when not.
  - Flavor follows the override: `OW_TTS_VOICE=ff_siwis` + `OW_FLAVOR_ROLL=0`
    yields the **French** flavor line even if the global `tts_voice` is English;
    non-numeric `OW_TTS_SPEED` is dropped from the nudge.
- **`swift run OpenWhispererKitTests`** — MCP checks: `tools/list` advertises the
  `speed` property; `tools/call` with a `speed` arg returns `.speak` carrying the
  parsed value; missing `speed` → `nil`. Existing `TTSSpeed` clamp tests already
  cover range/garbage.
- **Manual:** set `OW_TTS_VOICE`/`OW_TTS_SPEED` in a repo's
  `.claude/settings.local.json` env block, dictate a turn on Claude, Codex, and
  Pi, and confirm the reply speaks in that voice at that rate; confirm a repo
  with no override still uses the global voice/speed.

## Docs

- **`AGENTS.md`** — reverse "Voice is global-only now": document `OW_TTS_VOICE`
  and `OW_TTS_SPEED` as per-project overrides in the *State & IPC* section; drop
  `text` from the response-mode list in the *Voice-turn handshake* section; note
  `speed` is now a `speak` tool arg.
- **`CLAUDE.md`** — no change (points at AGENTS.md).
- README stays untouched (obsolete).
