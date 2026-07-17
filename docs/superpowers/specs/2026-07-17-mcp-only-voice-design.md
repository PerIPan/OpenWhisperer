# MCP-only voice tier — marker + standing instruction (Claude Desktop and beyond)

**Date:** 2026-07-17
**Status:** Approved design; spike pending before implementation
**Origin:** Brainstorm on supporting Claude Desktop, which has MCP but no hook
system — generalized into a hook-free integration tier for any MCP client.

## Problem

Every supported platform today needs bespoke hook infrastructure: Claude
Code/Codex `UserPromptSubmit` hooks, agy `PreInvocation`, Pi's
`before_agent_start` handler. That per-agent surface is the scaling and
fragility bottleneck: each new agent is a spike against an undocumented hook
API, hooks break when agents change, and setup carries friction (Codex
hook-trust). Claude Desktop — the motivating case — has **no hook system at
all**, so the current architecture cannot reach it.

Goal: an integration tier where setup is *"add the OpenWhisperer MCP server —
done."*

## Decision

Add an **additive** MCP-only voice tier. The existing hooks stay the gold path
on their platforms **until the new tier measurably matches or beats them**
(promotion gate below). Nothing is deleted in v1.

The tier inverts the hook's trick. Hooks inject a *conditional, per-turn*
nudge; the MCP tier ships a *standing* instruction and puts the per-turn
signal in the prompt itself:

1. **Marker.** When a dictation targets an MCP-tier app, the transcript is
   typed with a leading `🎙` (U+1F399 STUDIO MICROPHONE, bare — no U+FE0F
   variation selector, so it renders as a subdued monochrome glyph where
   text-presentation is honored) followed by a space, then the transcript.
2. **Standing instruction.** The server's `initialize` response `instructions`
   field *and* the `speak` tool description carry the rule. Tool descriptions
   are the guaranteed channel — every MCP client must show the model its
   tools — so `instructions` is reinforcement, not a dependency. One line per
   response mode:
   - `voice` (default): *"If the user's latest message begins with 🎙, it was
     dictated — before writing your reply, call `speak` once with a short
     standalone spoken summary. Treat the 🎙 as invisible; never mention it."*
   - `always`: *"On every user turn, call `speak` first with a short
     standalone spoken summary."*
3. **Playback.** A `speak` call that arrives simply plays. No server-side
   gating, no `voice_turn`, no hash, no echoed-prefix argument — the marker
   *is* the handshake. Voice and speed resolve server-side at playback from
   current prefs (better than the hook's model-echoed args).
4. **Persona + style.** The persona flavor and `tts_style` length phrase are
   baked into the instruction text, regenerated **fresh on every
   `tools/list`** from the same pref files the hooks read. Staleness after a
   settings change lasts until the client's next connect/session; if that
   annoys in practice, v2 adds `tools/list_changed` (requires SSE notification
   plumbing in `TTSHTTPServer`).
5. **Client scoping.** The server reads `clientInfo` at `initialize`:
   hook platforms (Claude Code, Codex) keep today's minimal server behavior;
   Desktop-class/unknown clients get the standing-instruction personality.
   One server, two greetings.
6. **Marker guard (non-negotiable).** The marker is typed **only when the
   frontmost app captured at dictation start is an allowlisted MCP-tier
   bundle** (v1: Claude Desktop's bundle ID). All other dictation targets get
   today's clean transcript — no mic glyphs in Slack, shells, or editors.

### Semantics changes vs the hash handshake (accepted)

- **Edit behavior becomes visible control.** Today any edit to a dictated
  prompt un-matches the hash and silences the turn. With the marker, the turn
  speaks unless the user deletes the `🎙`. Control moves from implicit to
  visible — and typing `🎙` by hand **force-speaks** a typed turn, an override
  the hash could never offer.
- **Multi-dictation into one prompt** produces a mid-prompt marker from the
  second chunk (`🎙 first 🎙 second`). Rare, cosmetic, accepted. The leading
  marker still matches the instruction.
- **Per-project `OW_TTS_*` env overrides do not reach this tier** (the server
  cannot see a project's env). Hook platforms keep them; the MCP tier can
  later regain per-project voice via project-instruction lines (e.g. CLAUDE.md
  "call `speak` with voice=…"). Out of scope for v1.

### Rejected alternatives

- **Arbitrary text tag** (`[VOICE:]` revival): visual pollution; vetoed.
- **Invisible marker** (zero-width chars): stripped by some clients,
  unreliable model salience, and generally creepy in prompts.
- **Always-attempt + server-side gating** (model calls `speak` every turn;
  server decides audibility via `voice_turn`): no prompt pollution, but a
  wasted no-op tool call on every typed turn and standing-habit compliance
  risk. Rejected for v1; **retained as the phase-2 candidate for CLI hook
  retirement** (below).
- **Dynamic tool description as the per-turn signal** (`tools/list_changed`
  per dictation): closest hook mimicry, but depends on every client
  re-fetching schemas mid-conversation — exactly the per-client fragility
  this design escapes.

## Phase 2 (parked, not committed): CLI hook retirement

The marker **cannot** safely extend to terminal-hosted CLIs: at dictation time
the frontmost app is a terminal, and the app cannot tell whether an agent
prompt, a shell, or vim has focus — a marker would contaminate plain terminal
dictation (`ls -la 🎙`). The hash handshake is precisely what makes
mis-targeted dictation harmless today.

If hooks are ever to go, CLIs would use the rejected-for-v1 *always-attempt +
server-gated* scheme instead (no marker needed). That trade re-buys the no-op
calls and compliance risk, in exchange for deleting: `voice-context.sh`,
`voice-shared.sh`, `agy-previnvocation.sh`, the bundled `jq`, Codex hook-trust
friction, most of `HookTests`, and the bash/Swift `canonicalHash` parity
constraint. Decide only after the v1 tier produces real-world compliance data.
Pi stays extension-based regardless (deliberately MCP-free) — already the
lightest integration.

## Reach

Any MCP-capable agent can join the tier: connectivity (HTTP `/mcp`, or a
bundled `--mcp-stdio` bridge if a client is stdio-only) plus, for GUI apps, a
bundle-ID allowlist entry for the marker. Supporting a new agent stops being a
hook-API spike and becomes configuration.

## Spike (before any implementation)

1. **Connectivity:** does Claude Desktop accept a plain
   `http://localhost:8000/mcp` custom connector? If not, add a `--mcp-stdio`
   bridge mode to the OpenWhisperer binary and register it in
   `claude_desktop_config.json`.
2. **Rendering:** how bare U+1F399 renders in Desktop's composer/transcript
   (vs `🎙️` with U+FE0F); pick the constant accordingly.
3. **Compliance:** batches of dictated + typed turns on Claude Desktop, and on
   Claude Code with its hook disabled and `clientInfo` scoping bypassed,
   counting speak-first hits and false positives against the hook baseline
   (13/13 Claude, 5/5 Codex).

**Promotion gate:** hooks are only ever retired if the tier is "reasonably
sure the same experience or better" (user's bar), per the compliance spike.

## Components touched (v1)

- **`MCPServer` (Kit):** `instructions` in `initialize`, `clientInfo`-scoped
  behavior, instruction/description text built per `tools/list` from prefs —
  pure logic, unit-tested in `OpenWhispererKitTests` (persona/style text
  generation moves toward Swift parity with `voice-shared.sh` wording).
- **`DictationManager`/`AppDelegate`:** marker append behind the
  frontmost-bundle allowlist check (bundle already captured pre-focus-shift).
- **`ConfigManager` + Settings → Agents:** a "Claude Desktop" platform entry
  (register connector or `claude_desktop_config.json` bridge, per spike).
- **Hooks, `HookTests`, Pi extension:** untouched.

## Testing

Pure logic lands in `OpenWhispererKit`: marker-append decision, instruction
text builder (mode lines, persona, style), `clientInfo` scoping. Existing
`HookTests` remain the guard for the unchanged hook path. End-to-end: manual
spike protocol above, mirroring the 13/13 methodology.

## Addendum (implementation, 2026-07-17)

- **`clientInfo` scoping dropped.** The MCP transport is stateless (no session
  header; a fresh `MCPServer` per request), so correlating `initialize` with
  later `tools/list` calls would need new session plumbing. Unnecessary: the
  standing instruction is marker-gated, and markers are only ever typed into
  allowlisted apps, so identical instructions are inert on hook platforms. In
  `always` mode the instruction and the hook nudge agree rather than conflict.
  Side effect kept: any MCP-connected platform gains type-🎙-to-force-speak.
- **Regeneration is per-request, not per-`tools/list`** — strictly fresher
  than specced; settings changes apply without reconnect wherever the client
  re-reads tool schemas.
- **Connectivity spike resolved by inspection:** `claude_desktop_config.json`
  is stdio-only (`command`/`args`), so the `--mcp-stdio` bridge is the route;
  the HTTP-connector question is moot for v1. Bundle ID confirmed:
  `com.anthropic.claudefordesktop`.
