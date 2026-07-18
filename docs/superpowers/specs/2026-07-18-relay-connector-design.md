# Relay connector — first-party cloud bridge for the MCP voice tier

**Date:** 2026-07-18
**Status:** Approved design; spike pending before implementation
**Origin:** Brainstorm following the 2026-07-18 finding that Claude Desktop's
`remote-devices` aggregation drops server-level `initialize.instructions` for
local stdio MCP servers (recorded in
`2026-07-17-mcp-only-voice-design.md`, addenda).

## Problem

The MCP-only voice tier depends on a standing instruction reaching the model.
Desktop delivers server instructions only for cloud/account connectors
(verified against the owner's Frankfurter connector); its `remote-devices`
bridge for local stdio servers drops them, leaving the tier with a documented
cold-chat warm-up hole. Harnesses whose connectors are fetched from the cloud
(ChatGPT and kin) cannot reach `localhost:8000` at all.

Goal: make the local MCP server appear as a first-class cloud connector —
instructions intact — with no per-session manual work and no standing public
surface when the app is not running.

## Decisions

- **Audience:** personal deployment first, shaped so multi-tenant is an
  extension, not a rewrite.
- **V1 target:** the owner's Claude account. One custom-connector
  registration covers Desktop, claude.ai web, and mobile. ChatGPT is a fast
  follow, out of scope for v1.
- **Hosting:** Cloudflare Workers + Durable Objects, free tier. Durable
  Objects joined the free plan in 2025; WebSocket hibernation makes idle
  devices cost nothing, and MCP traffic is a handful of small JSON requests
  per turn.
- **Relay shape:** transparent pass-through. The relay never parses MCP.

### Supersession record

The 2026-07-18 addendum "Tunnel-to-direct-connector path: assessed, rejected
as product path" is **superseded** by this design. Its objections dissolve
under a first-party relay: no third-party account or daemon (the Worker is
ours; the app itself dials out), no public inbound port on the Mac (the
connection is outbound WebSocket; the local server stays loopback-only), and
registration happens once ever, not per session. One objection survives and
is accepted as irreducible: neither Claude nor ChatGPT offers an API to
register a connector, so a **once-ever** "add custom connector → paste URL"
step remains. It has the same shape as Codex hook-trust and the parked
account-skill upload: one manual step, then invisible.

The validated-and-parked account-skill channel remains parked, not replaced.
It solves Desktop's cold chat alone and cheaply; the relay's distinct value
is instructions-intact delivery, reach into cloud-fetched-connector
harnesses, and driving the Mac from devices that are not the Mac.

## Architecture

Two components:

- **`ow-relay`** (new repository; TypeScript; Cloudflare Worker + one
  `Device` Durable Object class). The DO holds the Mac's hibernating
  WebSocket. Routes:
  - `GET /d/<deviceId>` — WebSocket upgrade from the Mac, authenticated by a
    bearer `deviceSecret`.
  - `POST /t/<connectorToken>/mcp` — the endpoint claude.ai calls. The body
    is wrapped as `{id, body}`, sent down the device socket, and the matching
    `{id, response}` frame becomes the HTTP response body.
  - `GET /t/<connectorToken>/mcp` — 405. The MCP spec permits a server that
    never opens a push stream; the spike confirms claude.ai tolerates this.
- **`RelayClient`** (Swift actor in the OpenWhisperer app). Dials out
  `wss://…/d/<deviceId>` while enabled, reconnects with capped backoff, and
  hands each incoming `body` to the same in-process `MCPServer` dispatch that
  `TTSHTTPServer` serves on `:8000/mcp`. Relay traffic and local traffic run
  identical code, so instructions and tool descriptions regenerate from pref
  files on every request through the connector too.

Data flow for a dictated Desktop turn: the 🎙 marker is typed locally exactly
as today → Claude's cloud POSTs `tools/call speak` to the connector URL →
Worker → DO → WebSocket → `MCPServer.handle` → `TTSPlaybackController`
plays on the Mac → the JSON-RPC response rides back up and closes the HTTP
request. `initialize` passes through the same way, so the standing
instruction reaches the account-connector layer — the path verified to
surface instructions in cold context. This closes the cold-chat warm-up hole
with no marker change.

## Identity, auth, ephemerality

On first enable the app generates three values into the Application Support
bus (0700, `Paths.swift` convention):

- `deviceId` — UUID naming the Durable Object.
- `deviceSecret` — bearer credential for the WebSocket upgrade.
- `connectorToken` — ≥128-bit random path segment. The connector URL is the
  credential, the intended model for no-auth custom connectors.

Registration is trust-on-first-use: the first socket claiming an unguessable
`deviceId` binds its secret hash in DO storage. No per-device deploy step,
and already the multi-tenant shape.

The DO stores presence only — no messages, no MCP state, no queue. App quits
→ socket drops → connector calls fail fast with a "device offline" JSON-RPC
error. Disabling remote access disconnects and offers to rotate
`connectorToken`, killing the old URL. Cloudflare sees model-generated reply
text that already transited Anthropic; nothing dictated, nothing local-only.

## Mac-side UX

Settings → Agents gains a "Claude account (remote)" entry: an Enable toggle,
a status dot (connected / offline / disabled), and the connector URL with a
Copy button and one line of copy — *"Add this as a custom connector at
claude.ai/settings/connectors — once."* That paste is the entire manual
surface.

**Desktop double-route.** With the connector enabled, Desktop would see two
`speak` tools (the `remote-devices` stdio route and the connector). Enabling
the relay removes the `claude_desktop_config.json` entry Auto-Apply
previously wrote (only ours; fail closed on unreadable config, as the
existing code does); disabling the relay offers to restore it. One route at
a time, explicitly.

**Reach beyond Desktop, stated honestly.** The marker guard is
bundle-allowlist-based and no browser bundle can be allowlisted (the app
cannot see which tab has focus), so claude.ai web and mobile turns do not
auto-speak in v1. The tools are live there, the standing instruction is
present, and a hand-typed 🎙 force-speaks from any device — including a phone
making the Mac talk. Browser-tab detection is parked, not scope.

## Error handling

- Device offline → immediate JSON-RPC error naming OpenWhisperer as offline.
- Worker-to-device timeout ~60 s per request (`speak` returns after enqueue,
  so real calls are fast).
- One active socket per device: a new connection supersedes the old, making
  app restarts self-healing.
- Reconnect backoff caps at ~60 s so a woken laptop comes back promptly.

## Testing

- Pure logic — frame codec, reconnect state machine, token generation — lands
  in `OpenWhispererKit` under the existing test runner.
- The Worker gets vitest/miniflare tests in its own repository.
- End-to-end: the spike protocol below, then the 13/13 methodology on a cold
  Desktop chat.

## Spike (before any implementation)

1. Deploy a minimal Worker serving a sentinel instruction; register it as a
   custom connector; confirm claude.ai's client tolerates POST-only
   Streamable HTTP (no GET stream, no session headers) and surfaces the
   sentinel in cold context. This is the only real unknown.
2. Crude WebSocket loop to a script on the Mac proving an end-to-end
   `speak`. Only then productionize.

**Validation bar:** a brand-new Desktop chat, first dictated 🎙 turn speaks,
and the model's server inventory lists OpenWhisperer with its instructions.

## Rejected alternatives

- **Terminating relay** (MCP implemented at the edge, cached `tools/list`):
  caches exactly what must stay fresh — the instructions — and splits MCP
  logic across two repositories. Rejected.
- **Hybrid with offline grace** (pass-through plus edge-cached discovery):
  real complexity for a grace period nobody asked for. A sleeping Mac should
  say so. Rejected.
- **Third-party tunnels** (Tailscale Funnel / ngrok / cloudflared): the
  objections recorded 2026-07-18 stand for third-party variants; only the
  first-party relay dissolves them.

## Out of scope (v1)

Multi-tenant provisioning and signup, ChatGPT registration, browser-tab
detection for web auto-speak, offline grace, connector-side push (SSE).

**Parked, on the record (2026-07-18):** a generic relay for *any* local MCP
server. The pass-through Worker is already MCP-agnostic; generalizing is a
device-side CLI client plus a prior-art sweep (Cloudflare's own remote-MCP
hosting and adjacent tools exist). Pursuing it is a deliberate pivot to
record then, not scope now.

**Additional devices need zero relay-side work.** TOFU means any app
instance claims its own DO and mints its own connector URL — a second
user's Mac joins by flipping the toggle and pasting their URL into their
own Claude account. Their spoken-summary JSON transits the operator's
Worker (disclose it); they share the free-tier request pool; and TOFU
accepts anyone with the app, which is the feature at friend-scale and the
forcing function for the accounts work if builds ever circulate widely.

## Repositories

`ow-relay` is a new repository. The Swift side (`RelayClient`, Settings,
`ConfigManager` changes) is a normal PR in this repository.
