# Voice support for Antigravity CLI (agy) — the fourth platform

**Date:** 2026-07-06
**Status:** Design — validated live, pending implementation
**Shape:** A fourth `Platform.antigravity` case in `ConfigManager`, reusing the
existing in-app `speak` MCP tool over its existing Streamable HTTP endpoint —
no new server, no new transport, no shim process. The only new pieces are a
`PreInvocation` hook (agy's equivalent of `UserPromptSubmit`) and a small
shared bash library factored out of `voice-context.sh`.

## Background

AGENTS.md previously concluded (spike 2026-06-29) that agy could not support
the early-speak nudge: agy's `speak` MCP tool worked, but nothing could inject
the pre-turn nudge, because agy's CLI exposed no `UserPromptSubmit` or
`SessionStart`-equivalent hook. That finding is superseded by this spec —
agy's binary (v1.0.16) ships a documented `PreInvocation` hook type absent
from the earlier investigation, and it does exactly what's needed.

## Problem

Claude Code and Codex speak early by nudging the model, via a
`UserPromptSubmit` hook, to call the `speak` MCP tool as its first action on a
voice-dictated turn. Pi does the same via a `before_agent_start` extension
hook. Agy has neither hook — its lifecycle hooks are `PreToolUse`,
`PostToolUse`, `PreInvocation`, `PostInvocation`, and `Stop`. None of those
map 1:1 onto "once, before the model sees a fresh user turn" — until
`PreInvocation` is examined closely.

## Key findings (validated live, 2026-07-06)

1. **`PreInvocation` fires before every model call**, and its
   `injectSteps: [{ephemeralMessage: "..."}]` output reaches the model —
   confirmed by round-tripping a sentinel word through a live agy session.
2. **`invocationNum` resets to 0 at the start of every new user turn** and
   increments once per subsequent model call within that turn's tool-call
   loop, while a separate `initialNumSteps` field climbs monotonically across
   the whole conversation and never resets. Observed directly: one session
   produced three turns, each starting a fresh `invocationNum=0`, while
   `initialNumSteps` climbed 1→6→9→12→15→18 across all of them. This makes
   `invocationNum==0` a reliable turn-start gate.
3. **The `PreInvocation` payload carries no prompt text** — only
   `conversationId`, `transcriptPath`, `workspacePaths`, `modelName`,
   `invocationNum`, `initialNumSteps`. The just-submitted user message must be
   read from `transcriptPath` instead.
4. **The transcript is written in time** — the last `USER_EXPLICIT` entry in
   `transcript_full.jsonl` carries the same timestamp as the `PreInvocation`
   firing for that turn, confirmed across two separate turns. Its `content`
   is wrapped as `<USER_REQUEST>\n<text>\n</USER_REQUEST>\n<ADDITIONAL_METADATA>...`.
5. **MCP transport is a non-issue.** A prior design review (2026-06-25)
   concluded agy only supports stdio MCP and recommended building a Swift
   stdio shim. That's now known to be stale: agy's current `mcp_config.json`
   supports a `serverUrl` (SSE) transport, and pointing it directly at the
   existing `POST /mcp` Streamable HTTP endpoint (`http://localhost:8000/mcp`)
   was tested live — agy connected, found the `speak` tool, called it, and
   audio played. No shim needed.
6. **The hook must live in the global `~/.gemini/config/hooks.json`, not a
   per-workspace `.agents/hooks.json`.** Both were tested; the global file
   fires identically. This matters because Claude/Codex/Pi are all global,
   one-time installs — a per-project file would mean re-installing per repo,
   which the other three platforms don't require.

## Design

### Components

1. **`hooks/voice-shared.sh` (new).** The platform-agnostic logic extracted
   from `voice-context.sh`: resolving `MODE` (`tts_response_mode` /
   `OW_TTS_RESPONSE`), hashing-and-claiming `voice_turn` against a given
   prompt string (`IS_VOICE`), resolving `STYLE`/`VOICE`/`FLAVOR`, and
   building the nudge sentence. Sourced by both hook scripts below, so the
   persona map and hash logic have exactly one home — matching this repo's
   existing single-sourcing of the flavor map.

2. **`hooks/voice-context.sh` (refactored).** Unchanged behavior; now sources
   `voice-shared.sh` and keeps only what's specific to Claude/Codex's I/O
   shape: reading `.prompt` from stdin, emitting
   `{hookSpecificOutput:{additionalContext}}`.

3. **`hooks/agy-previnvocation.sh` (new).** Agy's `PreInvocation` hook:
   - Exit immediately with `{}` unless `invocationNum == 0`.
   - Fast-path exit `{}` if `MODE=voice` and no `voice_turn` file exists
     (mirrors the existing fast path).
   - Read `transcriptPath`, extract the last `USER_EXPLICIT` entry's
     `content`, strip the `<USER_REQUEST>...</USER_REQUEST>` wrapper, trim.
   - Source `voice-shared.sh` for the hash-match, mode decision, and nudge
     text.
   - On a "speak" decision, emit `{"injectSteps":[{"ephemeralMessage": <nudge>}]}`.

4. **`ConfigManager.applyToAntigravity()` (new).**
   - Merge `"openwhisperer": {"serverUrl": "http://localhost:8000/mcp"}` into
     `~/.gemini/config/mcp_config.json`'s `mcpServers` (merge, don't clobber
     other entries).
   - Merge the `PreInvocation` hook entry into the global
     `~/.gemini/config/hooks.json`.
   - New `Platform.antigravity` case, wired into the Setup card's platform
     picker alongside `claudeCode`/`codexCLI`/`pi`.

### Data flow

```
dictation → app writes voice_turn (hash + timestamp)
          → agy: user submits prompt
          → PreInvocation fires, invocationNum=0
          → agy-previnvocation.sh reads transcriptPath, pulls last USER_EXPLICIT content
          → strips <USER_REQUEST> wrapper, trims, hashes
          → voice-shared.sh: hash matches voice_turn → claims it, IS_VOICE=1
          → decides SPEAK per MODE (voice/always), builds nudge
          → outputs {"injectSteps":[{"ephemeralMessage": nudge}]}
          → model's first action: calls speak MCP tool (serverUrl → POST /mcp)
          → app's /mcp handler synthesizes + plays, same as Claude/Codex/Pi
          → invocationNum=1,2,... (later calls in the same turn) → hook exits early, {}
```

### Decisions

- **No fallback.** Matches Claude/Codex's KISS stance: if the model skips the
  `speak` call, that turn is silently unspoken. No Stop-hook safety net, kept
  behaviorally consistent across all platforms rather than special-casing agy
  as the newest integration.
- **No per-project override mechanism invented for agy.** `voice-shared.sh`
  reads `$OW_TTS_STYLE`/`$OW_TTS_RESPONSE`/`$OW_TTS_VOICE`/`$OW_TTS_SPEED` from
  its own process environment exactly like `voice-context.sh` does today —
  agnostic to how they got there. Claude/Codex can source per-project values
  because their CLIs inject a project-level `env` block; agy has no
  per-workspace settings file with that concept (checked: only
  `.agents/hooks.json` and `.agents/skills.json` exist per-workspace, neither
  with env injection). That's a harness gap, not something this app should
  route around with a bespoke config format. If agy grows that feature later,
  it works automatically with zero changes here.

## Testing

- `HookTests` gains a check group for `agy-previnvocation.sh`: synthetic
  `PreInvocation` stdin (`invocationNum=0` vs `1`), a fixture
  `transcript_full.jsonl` with a `USER_REQUEST`-wrapped entry, asserting the
  `{}` fast-exit and the `ephemeralMessage` shape.
- The existing `voice-context.sh` checks move to exercise `voice-shared.sh`'s
  functions directly (mode resolution, hash-match-and-claim, persona map),
  since that's now where the logic lives.

## Accepted risks

- Silent turns on missed `speak` calls — same accepted risk as Claude/Codex,
  now extended to agy.
- `invocationNum==0` as a turn-start marker rests on the one session observed
  during this spike (three turns, clean resets). No adversarial case (e.g. a
  turn that itself triggers a sub-agent or nested invocation) was tested.

## Open questions for planning

1. Exact `jq`/`sed` extraction for the `<USER_REQUEST>` wrapper — needs a
   small fixture-driven implementation, not just the regex sketched above.
2. Whether `ConfigManager`'s JSON merge for `mcp_config.json` /
   `~/.gemini/config/hooks.json` should use a bundled `jq` (as
   `voice-context.sh` does) or a native Swift JSON merge.
3. Version bump and rollout sequencing alongside the existing three-platform
   `Platform` enum and Setup UI.
