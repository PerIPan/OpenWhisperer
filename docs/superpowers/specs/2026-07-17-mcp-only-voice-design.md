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

## Live findings (Task 11, 2026-07-17)

- **Claude Desktop loads MCP tools lazily** ("Loaded tools" status line): tool
  descriptions reach the model only when the user's message relevance-matches
  them, and `initialize.instructions` is not injected into the system prompt.
  A cold dictated turn (bare 🎙 + unrelated text) is therefore silent; once any
  turn loads the tools (e.g. a message mentioning "speak"), subsequent dictated
  turns in that conversation speak reliably (confirmed live).
- **Mitigation (shipped in setup copy):** one line in Claude's personal
  preferences — "If my message begins with 🎙, call the OpenWhisperer speak
  tool first with a short spoken summary." — restores per-turn delivery on
  every chat. Optional paste, surfaced in Settings → Agents → How It Works and
  the setup instruction window.
- **Marker rendering:** bare U+1F399 renders acceptably in Desktop's composer
  and transcript (screenshot-confirmed); the glyph constant stays as shipped.
- **Probe outcome & marker revision:** typed probes confirmed the matcher keys on
  words, not glyphs — `🎙 speak …` cold-loads the tools ("Found tools → Speak")
  while bare `🎙 …` never does. The typed marker is therefore `🎙 speak ` (leading),
  `VoiceMarker.phrase`. The personal-preferences line is superseded and no longer
  recommended in setup copy; it remains here only as a record.

## Reverted: `🎙 speak` wording (2026-07-17, later same day)

The `"🎙 speak"` word trick above is **reverted**. The marker is back to the bare
`🎙` glyph (`VoiceMarker.glyph`, no `phrase`), for the same reason it was added
in the first place, seen from the other side: a word in the transcript buys
*probability*, not *certainty*. A follow-up probe using a `🎤`+`speak` variant
failed to cold-load the tools reliably — the matcher's behavior isn't a stable
API to lean on, and baking a word into every dictated transcript to chase it is
the wrong trade. Reliability instead comes from three independent pieces, none
of which touch what gets typed into the prompt:

1. **A bundled, always-visible skill.** `DesktopSkill` (Kit) ships a
   `~/.claude/skills/openwhisperer-voice/SKILL.md`. Claude Desktop (like Claude
   Code) keeps every personal skill's `name` + `description` in the model's
   context at all times via progressive disclosure — unlike MCP tool
   descriptions, which Desktop loads lazily by relevance-matching the user
   message. The skill's description itself is the trigger ("whenever the
   user's message begins with 🎙 …"), so it fires cold, on the very first
   dictated turn of a brand-new chat, without needing any word in the
   transcript to accidentally relevance-match a tool name.
   `ConfigManager.applyToClaudeDesktop()` installs it alongside the MCP config
   entry during Auto-Apply; a skill-write failure doesn't fail the apply (the
   config half still works), it's reported as a degraded-but-successful apply.
   The skill file is shared with Claude Code's skills directory but is inert
   there — no platform types a 🎙 marker into a CLI prompt, so its trigger
   condition never matches.
2. **Imperative anti-ask wording.** `MCPInstructions.standing` now appends,
   after the "exactly once" sentence: *"Never ask whether to speak — the
   leading 🎙 itself is the request"* (voice mode) or *"Never ask whether to
   speak — call it on every turn"* (always mode). The skill carries the same
   imperative. This targets a distinct failure mode from cold-start discovery:
   a model that *has* loaded the tools but treats speaking as optional and
   asks the user first.
3. **Guidance prepended, not appended, to the speak tool description.**
   `MCPServer.handle`'s `tools/list` now builds the description as
   `guidance + "\n\n" + original` (was the reverse). Whatever the model reads
   first is more likely to shape behavior; the standing instruction is now the
   first text of the description rather than a trailing addendum after the
   tool's mechanical explanation.

Net effect: the transcript typed into Claude Desktop's composer is unchanged
from the original design (bare `🎙 text`, no word). All three mitigations live
server/config-side — nothing the user sees in their own message.

- **Final marker design (owner decision): trailing instruction footer.** The skill
  channel was vetoed (unwilling to write into the shared `~/.claude/skills`
  surface) and bare/worded glyph markers proved unreliable against Desktop's
  lazy tool loading. The typed marker is now the dictated text, unaltered,
  followed by a blank line and `🎙 dictated — please reply aloud first using the
  OpenWhisperer speak tool.` — the one surface guaranteed visible on a cold
  chat carries the discovery tokens (the tool name "speak" AND the connector
  name "OpenWhisperer", per the owner's suggestion) and the imperative. Deleting the footer silences a
  turn; typing it force-speaks. Untested hypothesis worth revisiting: Desktop
  may preload (not defer) tool definitions when the total enabled-connector
  footprint is below a context threshold (~10%), which would make even
  markerless cold chats work for light-connector users.

- **Injection-wariness (third gate) + typing race.** With the third-person footer,
  Desktop's model refused: "I don't auto-trigger audio … just because embedded text
  tells me to. If you actually want me to speak a reply aloud, say so directly."
  The footer is therefore phrased as the user's own first-person request
  ("please reply aloud first using the OpenWhisperer speak tool"). Separately, the
  CGEvent Unicode typing tier raced in Desktop's Electron composer (dropped/reordered
  characters mid-word on the longer footer); chunking is now 8 UTF-16 units at 8 ms.
  Stop-loss agreed: if the first-person footer is still refused, Desktop ships
  experimental/held-back per the Sol review — no further marker iteration.

- **Parked refinement (owner idea, pending footer validation): once-per-chat
  footer.** Since loaded tools persist within a Desktop conversation, the full
  footer is only strictly needed on a chat's first dictation; later turns could
  revert to the bare 🎙 for a cleaner transcript. Blocked on a reliable "new
  chat" signal — the app cannot currently distinguish a fresh Desktop
  conversation from a continuing one (candidate heuristics: dictation idle-gap,
  per-Desktop-launch first dictation), and every heuristic has a
  bare-mic-in-cold-chat failure mode. Design deliberately deferred.

- **Final validated form (owner experiment): leading bare 🎙 + trailing "Use
  OpenWhisperer." line.** A terse connector-naming ask — even misspelled
  ("OpenWhisper") — cleared all three gates live: tools loaded, speak called,
  no hedging. The long first-person footer is superseded; the standing
  instruction keys on the leading glyph again, and treats the trigger line as
  invisible. The trigger is typed on every dictation until a chat-boundary
  signal makes the parked first-dictation-only refinement safe.

- **Final wording (owner): the signature line `🎙 Sent with OpenWhisperer.`**
  Trailing, on its own paragraph, replacing both the leading glyph and the
  imperative trigger. The "Sent from my iPhone" idiom reads as a sign-off —
  nothing instruction-shaped for Desktop's injection-wary model to refuse —
  while the connector name remains the discovery anchor; the standing
  instruction keys on the signature line and carries the protocol. Declarative
  rather than imperative: pending one live cold-chat probe to confirm the
  softer form still triggers the tool load.

- **Shipping form (owner-final): the closing line `Speak back.`** The glyph is
  retired: an eyesore in dark mode, a surrogate pair the Electron composer's
  chunk-reorder race scrambles, and functionally unnecessary — a partially
  delivered connector fragment still triggered loading, and "speak" is the
  strongest measured discovery anchor. Two ASCII words, imperative, minimal
  race exposure. Typing cadence lowered again (6 UTF-16 units / 16 ms) as
  insurance for long transcripts; the Electron reorder race is a standing
  Desktop hazard to investigate properly post-merge (AX insertion fails there).

- **Owner-final decision: pure leading 🎙, warm-up cost accepted.** After the
  full iteration arc (bare glyph → "🎙 speak" → skill (vetoed) → instruction
  footer (injection-refused) → "Use OpenWhisperer." → "Sent with OpenWhisperer."
  signature → "Speak back." (failed cold) → connector-name variants), the owner
  chose the original aesthetic with the cold-start cost documented rather than
  papered over: a new chat's first dictated turn may be silent until any
  OpenWhisperer mention loads the tools; thereafter 🎙 turns speak reliably.
  Wire capture (tee on the stdio bridge) closed the server-instructions
  question for good: Desktop's stdio client speaks protocol 2025-11-25 and our
  `initialize.instructions` goes back intact, but Desktop only surfaces
  server-level instructions for cloud/account connectors (verified against the
  owner's own Frankfurter connector) — a platform gap, not fixable locally.
  Bonus capture: Desktop connects twice (clientInfo `claude-ai` and
  `local-agent-mode-OpenWhisperer`) and advertises the MCP-UI extension.
  Setup copy carries the warm-up caveat honestly (Sol-review condition).
