# Early spoken summary via a general `speak` MCP tool

**Date:** 2026-06-25 (reconciled 2026-06-26 with v1.5.1 / upstream `e717128`)
**Status:** Design — pending final review
**Shape:** A general, ungated `speak` MCP tool hosted in-app (HTTP transport,
in-process playback). The spoken summary is one application, driven entirely by a
positive prompt nudge on the turns the `tts_response_mode` gate selects (dictated
turns by default). No tool-side gate, no Stop hook, no fallback, no markers.

## Problem

On a voice turn, the spoken summary is read aloud by the **Stop hook**
(`hooks/tts-hook.sh`), which can only fire once the reply has **fully finished
streaming**. The model keeps writing on-screen detail after the opening summary
is done, so the user reads the first paragraph seconds before hearing it. While
watching the screen this lag feels unnatural. The bottleneck is **not** synthesis
speed — the whole turn must complete before any audio starts.

### Why we can't just "start earlier" with the current design

- The session transcript JSONL is written at **turn boundaries**, not
  incrementally — nothing to tail before Stop.
- **No interactive hook carries partial assistant text** mid-turn.
- The only token-streaming channel is headless (`claude -p … stream-json …`),
  unavailable in interactive sessions.

So a Stop-hook design cannot start early; we need something that runs *during*
the turn.

## Key insight

A **tool runs mid-turn by definition.** If the model calls a tool as its first
action, the handler executes immediately — long before the turn ends. Nudge the
model to call `speak` first with a one-sentence summary, and audio begins ~a
second in, while the rest of the reply streams on screen.

## Design

`speak(text)` is a **general-purpose** MCP tool — "synthesize and play this
text" — exposed by OpenWhisperer and usable in **any** context: voice-turn
summaries, ad-hoc model use ("read this aloud"), external callers (e.g. a morning
cron that reads an inbox summary), or other skills. It is **not** coupled to the
voice handshake and **does not gate** on any signal — when called, it speaks.

The voice-turn summary is just *one application* layered on top, via a prompt
nudge. Keeping the tool ungated is exactly what enables the other uses.

### Components

1. **`speak(text)` — general in-app MCP tool (new).** Hosted by the app over
   **HTTP transport**; synthesizes + plays **in-process** via the existing
   Kokoro engine — no shim, no localhost hop, plain loopback (no TLS). Ungated.
   Optional `voice` param; voice resolution as today.

2. **Positive nudge (`voice-context.sh`, UserPromptSubmit).** The hook classifies
   the turn (`IS_VOICE` via hash-match against `voice_turn`, **claiming + removing**
   it on a match — exactly as today) and then consults **`tts_response_mode`**
   (`voice` default | `text` | `always`; per-project `OW_TTS_RESPONSE`) to decide
   whether *this* turn speaks — see **Response modes** below. When it should, it
   injects: *"First, call `speak` with a single standalone sentence summarizing
   your answer; then write your full reply."* When it shouldn't, **no nudge** (the
   `voice`-mode fast-path exit on a typed turn is retained). The hook **no longer
   writes `speak_pending`** — there is no Stop hook to signal; the model's own
   `speak` call produces the audio.

3. **`ConfigManager`** — registers the in-app MCP server with each platform that
   supports it; **removes the obsolete Stop hooks** on upgrade.

### Response modes (new since v1.5.1)

v1.5.1 (upstream `e717128`) generalized the old voice-only gate into a
**`tts_response_mode`** pref — `voice` (default) | `text` | `always`, overridable
per-project via `OW_TTS_RESPONSE` — that decides *which* turns are spoken:

| mode     | speaks when             | nudge injected on |
|----------|-------------------------|-------------------|
| `voice`  | turn was voice-dictated | `IS_VOICE == 1`   |
| `text`   | turn was typed          | `IS_VOICE == 0`   |
| `always` | every turn              | every turn        |

This design **subsumes** that gate rather than discarding it: the mode decision
stays exactly where v1.5.1 put it (`voice-context.sh` / `codex-tts-hook.sh`), and
the only change is *what fires on "speak"* — a **nudge to call `speak` first**
instead of writing `speak_pending` for a Stop hook. All three modes keep working;
"typed turns stay quiet" is just the `voice`-mode default, not a hard-coded
assumption. (Consequence: the no-fallback reliability risk now spans **every**
mode, not only voice — see *Removed vs. today* and *Accepted risks*.)

### `voice_turn` lifecycle

Written by the app on dictation → **claimed + removed by `voice-context.sh` at
submit** (single winner) → used **only** to classify the turn (`IS_VOICE`), which
the response mode (above) turns into the nudge decision. The tool never reads it.
Because nothing downstream needs it to survive, it keeps its clean,
immediately-consumed lifecycle — so the multi-terminal race / session-scoping /
markers we previously worried about simply **do not exist** here.

### Data flow (voice turn)

```
dictation → voice_turn written (app)
submit → voice-context.sh: classify IS_VOICE (hash-match → claim+remove voice_turn)
       → response-mode gate (voice/text/always) → inject "call speak() first"
model: speak("<summary>") ─► in-app MCP handler ─► synth + play IN-PROCESS (audio ≈1s in)
model: writes full reply (natural answer) ─► streams to screen
turn ends → nothing to do (no Stop hook)
```

## Behavior choices

- **Spoken-only:** the summary is audio + the tool-call chip; the written reply
  is the model's natural answer, not restated.
- **Quiet-by-default is now mode-scoped.** In the default `voice` mode a typed
  turn gets no nudge, so the model has no reason to speak — but `text` and
  `always` deliberately *do* nudge typed turns. There is **no hard guarantee**
  either way (the tool is general and always available), so the model *could*
  speak on a turn its mode meant to keep silent. **Ship the simple version
  first** and see if that happens. **Escalation remedy (not built initially):** a
  *negative nudge* on the silent side of whichever mode is active —
  `voice-context.sh` injects "don't read this turn aloud." (Minor caveat: it
  could fight an explicit "read this aloud" request; the model would usually
  honor the direct ask.)
- **No fallback for missed calls:** if the model doesn't call `speak` on a voice
  turn → silence. Accepted (KISS).
- **`tts_style`:** a length hint folded into the nudge; legacy `full` (verbatim
  whole reply) dropped/redefined as the richest summary tier.

## Transport — locked: in-app HTTP MCP (Option B)

The TTS engine must live in **one long-running, warm process**: the Kokoro model
loads onto the ANE once and stays warm, the ANE is shared with STT via in-process
actors, barge-in is an in-process call, and playback outlives the tool call. That
process already exists — the menubar app. So the agent talks to it **directly**:
the app hosts the MCP server over HTTP and plays in-process — **no shim, no
spawned process, no hop.**

stdio was the reviewers' pick (universal across agents), but stdio *by definition*
spawns a per-session subprocess that can't hold the warm engine — so it would
force exactly the "run something separate + forward" indirection B avoids. Reach:
Claude Code supports HTTP/SSE MCP, and **so does Antigravity** (remote servers via
a `serverUrl` field in `mcp_config.json`) — correcting the earlier "agy has no
HTTP MCP" note, which was a bad design-phase check. The one unverified case is
whether agy accepts a **plain-loopback `http://localhost:8000`** `serverUrl` (its
documented examples are all remote `https://` with auth headers); Codex HTTP-MCP
support is still unconfirmed. So B is **Claude-Code-first but not Claude-only** —
the spike should confirm agy's loopback case. The earlier race argument for stdio
is moot (the tool no longer touches `voice_turn`).

### Port

- **One fixed port, shared.** Host the MCP endpoint on the **same** server as the
  existing TTS API (`:8000`) — one port, one collision surface. Don't add a
  second port.
- **Fixed, not dynamic.** The agent's MCP config needs a stable URL, so the port
  can't be an OS-assigned ephemeral one.
- **Collision risk is real but usually small.** The port is loopback-only (only
  local processes can collide), but `:8000` is popular, and the most likely clash
  is a **stale OpenWhisperer instance** still holding it (a known foot-gun). v1.5
  logs the bind failure; **elevate it to a visible menubar status** so a collision
  is diagnosable, not a silent dead endpoint.
- **Open sub-decision:** keep `:8000` (continuity with the hooks, `scripts/`, and
  smoke-test docs that hardcode it) vs. move the default to a less-trafficked
  fixed port (fewer collisions, but touches those defaults). Lean: keep `:8000` +
  add the visible failure; revisit only if collisions actually show up.

## Removed vs. today

- `hooks/tts-hook.sh`, `hooks/codex-tts-hook.sh` (Stop-hook speech) — deleted.
- `speak_pending` / `spoke_early` markers — gone.
- Tool-side `voice_turn` gate, session-scoping, multi-terminal race handling —
  never needed (the tool is ungated).
- **Note:** in v1.5.1 those Stop hooks + `speak_pending` deliver speech for **all
  three** response modes, not just `voice`. Deleting them means the `speak`-tool
  nudge must now cover `text` and `always` too — it does (the mode gate just
  decides whether to inject the nudge), but the **no-fallback reliability risk
  below now spans every mode**, not only voice turns.

## Docs impact

Rewrite the "Voice-turn handshake" sections in `CLAUDE.md` / `AGENTS.md`: now one
part (response-mode gate + positive nudge + general `speak` tool), no Stop hook.
Fold the v1.5.1 **`tts_response_mode`** description into the new handshake text —
the gate survives; only its *delivery* (model-called `speak` tool vs. Stop hook)
changes.

## Testing

- **HookTests** — extend the existing v1.5.1 mode-gate checks (`VoiceContextChecks`,
  `CodexTtsHookChecks`) to assert the new **nudge content** (`speak`-first) for each
  `tts_response_mode`, and that **no `speak_pending`** is written.
- **Manual smoke** — `speak` tool → in-process audio; voice turn → early audio;
  typed turn → quiet in `voice` mode but spoken in `text`/`always`; verify on
  Claude Code.
- **Compatibility spike (recommended, do first)** — confirm Claude Code
  HTTP-MCP registration works and that the model reliably calls `speak` *first*
  in real interactive sessions.

## Rollout

- Version bump `1.5.1 → 1.6.0` (`build-dmg.sh` + `Resources/Info.plist`).
- `ConfigManager` must remove the obsolete Stop hooks on upgrade (else
  double-speak with a stale `tts-hook.sh`).

## Accepted risks

- Model doesn't call `speak` first → silent turn. No fallback, by choice. **Now
  applies to all three response modes** (the Stop hook that used to guarantee
  speech in `text`/`always` is gone).
- HTTP-MCP support keeps reach Claude-Code-first; Antigravity likely works (remote
  HTTP confirmed, loopback plain-HTTP unverified), Codex unconfirmed.

## Open questions for planning

1. Keep `voice-context.sh` as bash vs. fold the nudge into the app binary.
2. Compatibility-spike outcome: Claude Code HTTP MCP + first-call adherence, and
   whether Antigravity accepts a loopback plain-HTTP `serverUrl`.
3. Port default: keep `:8000` vs. move to a less-trafficked fixed port (see
   Transport › Port).
