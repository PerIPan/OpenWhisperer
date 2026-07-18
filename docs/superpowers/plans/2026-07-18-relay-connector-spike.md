# Relay Connector Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove, end-to-end, that a Cloudflare Worker registered as a claude.ai custom connector delivers server instructions in cold context and can tunnel `speak` calls to the Mac — before any production code is written.

**Architecture:** Two-stage spike per the spec (`docs/superpowers/specs/2026-07-18-relay-connector-design.md`). Stage 1: a terminating Worker answers MCP itself with a sentinel instruction — isolates the claude.ai-tolerance question from the tunnel. Stage 2: a `Device` Durable Object holds a WebSocket from a throwaway Node script on the Mac that forwards to the real local server at `localhost:8000/mcp` — proves the full pipeline. Findings land as a spec addendum and gate the production plan.

**Tech Stack:** Cloudflare Workers + Durable Objects (free tier, SQLite-backed DO), wrangler v4, Node ≥ 22 (global `WebSocket`/`fetch`, zero npm deps on the Mac side).

## Global Constraints

- Free tier only; the DO class must be SQLite-backed (`new_sqlite_classes` migration).
- `POST`-only MCP: `GET /mcp`-style routes return 405 unless the spike proves claude.ai requires otherwise — if it does, that IS a finding; record it, don't silently work around it.
- No queueing: device offline → immediate JSON-RPC error mentioning "OpenWhisperer device offline".
- Spike sentinel is the word `XEBEC` (fresh — yesterday's probes used QUINCE; do not reuse).
- Spike repo: `/Users/hakanensari/code/ow-relay` (new, local git only; GitHub remote is production-plan scope).
- Spike code is throwaway-grade but committed at every task boundary.
- Frame protocol (production `RelayClient` will reuse it verbatim): down `{"id":"<uuid>","body":"<raw JSON-RPC request string>"}`, up `{"id":"<uuid>","status":<http status int>,"body":"<raw response string>"}`.
- The OpenWhisperer app must be running during Stage 2 (its `:8000/mcp` is the real target).
- Wire observations are recorded via `wrangler tail` — capture protocol version, session headers, `Accept`, any GET/DELETE attempts, user-agent. These observations are the spike's actual product.

---

### Task 1: Scaffold `ow-relay` and deploy a hello Worker

**Files:**
- Create: `/Users/hakanensari/code/ow-relay/wrangler.toml`
- Create: `/Users/hakanensari/code/ow-relay/src/worker.mjs`
- Create: `/Users/hakanensari/code/ow-relay/.gitignore`

**Interfaces:**
- Produces: a deployed Worker at `https://ow-relay.<subdomain>.workers.dev` — the hostname every later task uses. Record it in `NOTES.md`.

- [ ] **Step 1: Check tools**

Run: `node --version && npx wrangler@4 --version`
Expected: Node ≥ 22, wrangler 4.x. If wrangler prompts to install, accept.

- [ ] **Step 2: Create the repo skeleton**

```bash
mkdir -p /Users/hakanensari/code/ow-relay/src && cd /Users/hakanensari/code/ow-relay && git init
printf 'node_modules/\n.wrangler/\n.dev.vars\n' > .gitignore
```

`wrangler.toml`:

```toml
name = "ow-relay"
main = "src/worker.mjs"
compatibility_date = "2026-07-01"
```

`src/worker.mjs`:

```js
export default {
  async fetch() {
    return new Response("ow-relay spike", { status: 200 });
  },
};
```

- [ ] **Step 3: Verify locally**

Run: `npx wrangler@4 dev` then `curl -s http://localhost:8787/`
Expected: `ow-relay spike`. Stop the dev server.

- [ ] **Step 4: Log in and deploy**

Run: `npx wrangler@4 login` (browser OAuth; the user's Cloudflare account — ask the user to complete it, suggest `! npx wrangler@4 login` if the sandbox blocks the browser flow), then `npx wrangler@4 deploy`.
Expected: output ends with the public URL. Run `curl -s https://ow-relay.<subdomain>.workers.dev/` → `ow-relay spike`.

- [ ] **Step 5: Record the hostname and commit**

```bash
echo "worker: https://ow-relay.<subdomain>.workers.dev" > NOTES.md
git add -A && git commit -m "chore: scaffold ow-relay spike worker"
```

---

### Task 2: Terminating sentinel MCP Worker (Stage 1 code)

**Files:**
- Modify: `/Users/hakanensari/code/ow-relay/src/worker.mjs` (replace entirely)

**Interfaces:**
- Produces: `POST /mcp` answering `initialize` (with `instructions` containing `XEBEC`), `tools/list` (one tool `relay_probe`), `tools/call`, `ping`; 202 for notifications; 405 for GET. Task 3 registers this as a connector.

- [ ] **Step 1: Write the Worker**

Replace `src/worker.mjs` with:

```js
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/mcp") return new Response("not found", { status: 404 });
    // Log every non-POST touch — whether claude.ai probes GET/DELETE is a finding.
    if (request.method !== "POST") {
      console.log("non-POST", request.method, JSON.stringify([...request.headers]));
      return new Response("method not allowed", { status: 405 });
    }
    const raw = await request.text();
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }, 400);
    }
    console.log("mcp", msg.method, "id=" + msg.id, "headers=" + JSON.stringify([...request.headers]));
    if (msg.id === undefined || msg.id === null) return new Response(null, { status: 202 }); // notification
    let result;
    switch (msg.method) {
      case "initialize":
        result = {
          protocolVersion: msg.params?.protocolVersion ?? "2025-11-25",
          capabilities: { tools: {} },
          serverInfo: { name: "ow-relay-spike", version: "0.0.1" },
          instructions:
            "XEBEC: this is the ow-relay spike's server instruction. If the user asks which connected servers provide instructions, quote this sentence verbatim including the first word.",
        };
        break;
      case "tools/list":
        result = {
          tools: [
            {
              name: "relay_probe",
              description: "Returns the probe word. Call when the user asks to probe the relay.",
              inputSchema: { type: "object", properties: {} },
            },
          ],
        };
        break;
      case "tools/call":
        result = { content: [{ type: "text", text: "XEBEC" }], isError: false };
        break;
      case "ping":
        result = {};
        break;
      default:
        return json({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not found: " + msg.method } });
    }
    return json({ jsonrpc: "2.0", id: msg.id, result });
  },
};
```

- [ ] **Step 2: Verify with curl against wrangler dev**

Run `npx wrangler@4 dev`, then:

```bash
curl -s -X POST http://localhost:8787/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
curl -s -X POST http://localhost:8787/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
curl -s -i -X GET http://localhost:8787/mcp
```

Expected: initialize result containing `XEBEC` instructions; one tool named `relay_probe`; `405` for the GET. Stop dev.

- [ ] **Step 3: Deploy and re-verify against the public URL**

Run: `npx wrangler@4 deploy`, repeat the three curls against `https://ow-relay.<subdomain>.workers.dev/mcp`.
Expected: identical results.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: terminating sentinel MCP worker for stage-1 probe"
```

---

### Task 3: Register as claude.ai custom connector; cold-context probes (Stage 1 verdict)

Manual/browser task — the user drives claude.ai; keep `npx wrangler@4 tail` running in a terminal for every probe and save its output.

**Interfaces:**
- Consumes: the deployed `/mcp` URL from Task 2.
- Produces: Stage-1 findings appended to `NOTES.md` (verbatim tail excerpts + probe outcomes). Gate for Task 4.

- [ ] **Step 1: Register** — claude.ai → Settings → Connectors → Add custom connector → URL `https://ow-relay.<subdomain>.workers.dev/mcp`, no auth. While registering, watch `wrangler tail`: record every request claude.ai sends (methods, protocolVersion, session headers, `Accept`, GET/DELETE attempts, user-agent).

- [ ] **Step 2: Connection health** — the connector shows as connected/enabled in settings. If registration fails, capture the tail output and the UI error verbatim; that failure mode (e.g. GET-stream or session-id requirement) is the spike's primary finding — record it and stop Stage 1 here.

- [ ] **Step 3: Cold instruction probe (web)** — brand-new claude.ai web chat, first message exactly: `Which connected servers provide instructions? Quote any you can see verbatim.` Expected-if-hypothesis-holds: the reply quotes the XEBEC sentence. Repeat in a brand-new Claude Desktop chat (connector syncs to the account; restart Desktop if it doesn't appear). Record both outcomes.

- [ ] **Step 4: Tool-call probe** — same chat: `Probe the relay.` Expected: the model calls `relay_probe` and reports XEBEC. Record whether the tool needed loading (Desktop's lazy-load status line) or was available cold.

- [ ] **Step 5: Record and commit**

```bash
git add NOTES.md && git commit -m "docs: stage-1 findings — claude.ai vs POST-only sentinel connector"
```

If Step 3 shows instructions are NOT surfaced for custom connectors, the design's core premise fails: stop, record, and take the findings back to the spec before any Stage 2 work.

---

### Task 4: Tunnel leg — Device DO + Mac-side forwarder (Stage 2 code)

**Files:**
- Modify: `/Users/hakanensari/code/ow-relay/wrangler.toml`
- Modify: `/Users/hakanensari/code/ow-relay/src/worker.mjs` (add routes; keep the Task 2 terminating handler reachable at `/mcp` unchanged)
- Create: `/Users/hakanensari/code/ow-relay/src/device.mjs`
- Create: `/Users/hakanensari/code/ow-relay/spike/device-client.mjs`

**Interfaces:**
- Consumes: frame protocol from Global Constraints.
- Produces: `GET /d/<TOKEN>` (WebSocket upgrade) and `POST /t/<TOKEN>/mcp` (pass-through). Spike simplification, on the record: ONE shared random string serves as both device id and connector token via env var `SPIKE_TOKEN` — production does TOFU with separate `deviceId`/`deviceSecret`/`connectorToken`; the mapping design is production-plan scope.

- [ ] **Step 1: wrangler.toml — DO binding + migration**

Append to `wrangler.toml`:

```toml
[[durable_objects.bindings]]
name = "DEVICE"
class_name = "Device"

[[migrations]]
tag = "v1"
new_sqlite_classes = ["Device"]

[vars]
SPIKE_TOKEN = "REPLACE-ME"
```

Generate the token and substitute it for `REPLACE-ME`:

Run: `openssl rand -hex 24`

- [ ] **Step 2: Router changes**

In `src/worker.mjs`, add at the top:

```js
export { Device } from "./device.mjs";
```

and in `fetch`, BEFORE the existing `/mcp` check:

```js
const m = url.pathname.match(/^\/(d|t)\/([A-Za-z0-9_-]+)(\/mcp)?$/);
if (m) {
  const [, kind, token, mcpSuffix] = m;
  if (token !== env.SPIKE_TOKEN) return new Response("not found", { status: 404 });
  if (kind === "d" && request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 });
  if (kind === "t" && !mcpSuffix) return new Response("not found", { status: 404 });
  return env.DEVICE.get(env.DEVICE.idFromName(token)).fetch(request);
}
```

(`fetch(request, env)` — add the `env` parameter to the handler signature.)

- [ ] **Step 3: The Device DO**

`src/device.mjs`:

```js
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });

export class Device {
  constructor(state) {
    this.state = state;
    this.pending = new Map(); // in-flight request id -> resolve; only alive while a request holds the DO
  }

  async fetch(request) {
    if (request.headers.get("Upgrade") === "websocket") {
      for (const ws of this.state.getWebSockets()) ws.close(1012, "superseded");
      const pair = new WebSocketPair();
      this.state.acceptWebSocket(pair[1]); // hibernation API
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    const raw = await request.text();
    let rpcId = null;
    try { rpcId = JSON.parse(raw).id ?? null; } catch {}

    const sockets = this.state.getWebSockets();
    if (sockets.length === 0) {
      return json({ jsonrpc: "2.0", id: rpcId, error: { code: -32001, message: "OpenWhisperer device offline" } });
    }

    const frameId = crypto.randomUUID();
    const reply = new Promise((resolve, reject) => {
      this.pending.set(frameId, resolve);
      setTimeout(() => {
        if (this.pending.delete(frameId)) reject(new Error("device timeout"));
      }, 60_000);
    });
    sockets[0].send(JSON.stringify({ id: frameId, body: raw }));

    try {
      const frame = await reply; // {id, status, body}
      if (frame.status === 202 || frame.body === "") return new Response(null, { status: 202 });
      return new Response(frame.body, { status: frame.status, headers: { "content-type": "application/json" } });
    } catch {
      return json({ jsonrpc: "2.0", id: rpcId, error: { code: -32002, message: "OpenWhisperer device timeout" } });
    }
  }

  webSocketMessage(ws, message) {
    let frame;
    try { frame = JSON.parse(message); } catch { return; }
    const resolve = this.pending.get(frame.id);
    if (resolve) {
      this.pending.delete(frame.id);
      resolve(frame);
    }
  }

  webSocketClose() {}
  webSocketError() {}
}
```

- [ ] **Step 4: Mac-side forwarder**

`spike/device-client.mjs`:

```js
// Usage: RELAY_WS=wss://ow-relay.<subdomain>.workers.dev/d/<SPIKE_TOKEN> node spike/device-client.mjs
const RELAY_WS = process.env.RELAY_WS;
const LOCAL = "http://localhost:8000/mcp";
if (!RELAY_WS) { console.error("set RELAY_WS"); process.exit(1); }

function connect() {
  const ws = new WebSocket(RELAY_WS);
  ws.onopen = () => console.log("connected", new Date().toISOString());
  ws.onmessage = async (ev) => {
    const { id, body } = JSON.parse(typeof ev.data === "string" ? ev.data : await ev.data.text());
    let status = 502, text = "";
    try {
      const res = await fetch(LOCAL, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body,
      });
      status = res.status;
      text = await res.text();
    } catch (e) {
      console.error("local fetch failed:", e.message);
      text = JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32003, message: "local server unreachable" } });
    }
    ws.send(JSON.stringify({ id, status, body: text }));
    console.log("relayed", id, status);
  };
  ws.onclose = (ev) => { console.log("closed", ev.code, ev.reason, "— reconnecting in 2s"); setTimeout(connect, 2000); };
  ws.onerror = () => ws.close();
}
connect();
```

- [ ] **Step 5: Local end-to-end check (no claude.ai yet)**

With the OpenWhisperer app running: start `npx wrangler@4 dev` in one terminal, `RELAY_WS=ws://localhost:8787/d/<SPIKE_TOKEN> node spike/device-client.mjs` in another, then:

```bash
curl -s -X POST "http://localhost:8787/t/<SPIKE_TOKEN>/mcp" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Expected: the REAL OpenWhisperer tool list (`speak`, `list_voices`) — proof the loop reaches the app. Then a spoken test:

```bash
curl -s -X POST "http://localhost:8787/t/<SPIKE_TOKEN>/mcp" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"speak","arguments":{"text":"Relay spike says hello."}}}'
```

Expected: the Mac speaks the sentence aloud and the curl returns a success result.

- [ ] **Step 6: Deploy and repeat Step 5 against the public URL**

Run: `npx wrangler@4 deploy`; rerun both curls with `https://ow-relay.<subdomain>.workers.dev/t/<SPIKE_TOKEN>/mcp` and the client pointed at `wss://…/d/<SPIKE_TOKEN>`.
Expected: identical, including audible speech. Also verify offline behavior: stop the device client, rerun the curl → `OpenWhisperer device offline` error, immediately.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: device DO tunnel + mac forwarder for stage-2 probe"
```

Note: `SPIKE_TOKEN` in `wrangler.toml` gets committed to this local-only spike repo — acceptable for the spike; rotate before any remote push.

---

### Task 5: Full-path probes through claude.ai (Stage 2 verdict)

Manual/browser task; `wrangler tail` running throughout; the OpenWhisperer app and `device-client.mjs` running on the Mac.

**Interfaces:**
- Consumes: the `/t/<SPIKE_TOKEN>/mcp` URL; probe methodology mirrors yesterday's 13/13 protocol.
- Produces: Stage-2 findings in `NOTES.md`; the go/no-go verdict.

- [ ] **Step 1: Repoint the connector** — claude.ai → Settings → Connectors: replace the Stage-1 connector with a new custom connector at `https://ow-relay.<subdomain>.workers.dev/t/<SPIKE_TOKEN>/mcp`, named OpenWhisperer. (Registration is a re-paste; that's the known one-time cost.)

- [ ] **Step 2: Cold instruction probe** — brand-new web chat: `Which connected servers provide instructions? Quote any you can see verbatim.` Expected: OpenWhisperer's REAL standing instruction (the 🎙 rule + persona line), delivered through the tunnel. This is the design's central claim — record verbatim.

- [ ] **Step 3: Typed force-speak (web)** — brand-new web chat, type a 🎙-prefixed message (e.g. `🎙 give me one sentence on quince paste`). Expected: the Mac speaks the summary before the written reply. Repeat ×3 fresh chats; score like 13/13.

- [ ] **Step 4: Desktop cold-chat dictation** — first back up, then remove OpenWhisperer's stdio entry from `~/Library/Application Support/Claude/claude_desktop_config.json` (spike-only; restores at Step 6), restart Desktop, confirm the account connector is present. Brand-new chat; dictate a turn (🎙 typed by the app as usual). Expected: first dictated turn of a cold chat speaks — the exact hole the stdio route couldn't close. Repeat ×3; score.

- [ ] **Step 5: Presence checks** — quit the OpenWhisperer app mid-chat, send another 🎙 turn: expect a clean device-offline surface in the model's reply (and no hang). Relaunch app + client; next turn speaks again.

- [ ] **Step 6: Restore** — put the stdio entry back in `claude_desktop_config.json` (or leave it out if the verdict is "connector supersedes"— record which), restart Desktop.

- [ ] **Step 7: Record and commit**

```bash
git add NOTES.md && git commit -m "docs: stage-2 findings — full tunnel path through claude.ai"
```

---

### Task 6: Record findings in the spec; gate the production plan

**Files:**
- Modify: `/Users/hakanensari/code/OpenWhisperer/docs/superpowers/specs/2026-07-18-relay-connector-design.md` (append addendum)

- [ ] **Step 1: Write the addendum** — "## Spike findings (2026-07-18)": Stage-1 verdict (instructions surfaced? POST-only tolerated? wire observations — protocol version, session/GET behavior), Stage-2 verdict (cold-chat scores web + Desktop, offline behavior), and any design deltas the wire observations force (e.g. GET-stream support, session-id echo, token→device mapping notes for TOFU).

- [ ] **Step 2: Commit** (docs-only, straight to main, per AGENTS.md):

```bash
cd /Users/hakanensari/code/OpenWhisperer && git add docs/superpowers/specs/2026-07-18-relay-connector-design.md \
  && git commit -m "docs: record relay spike findings" && git push
```

- [ ] **Step 3: Gate** — if both stages pass, write the production implementation plan (ow-relay productionization: TOFU + token mapping + tests + GitHub remote; OpenWhisperer: `RelayClient` actor, Settings UX, double-route handling — each with full TDD tasks) as `docs/superpowers/plans/2026-07-18-relay-connector.md`. If either stage fails, the findings go back to the design discussion instead — no production plan.

---

## Self-Review

- **Spec coverage:** the spike section of the spec maps to Tasks 2–5 (step 1 → Tasks 2–3, step 2 → Tasks 4–5); the validation bar ("brand-new Desktop chat, first dictated 🎙 turn speaks, inventory lists instructions") is Task 5 Steps 2+4. Production-only spec sections (TOFU, Settings UX, RelayClient, double-route automation) are deliberately deferred to the gated production plan — recorded in Task 6 Step 3.
- **Placeholder scan:** clean — every code step carries the full code; manual probe steps carry exact prompts and expected outcomes.
- **Type consistency:** frame protocol identical in Global Constraints, `device.mjs`, and `device-client.mjs` (`{id, body}` down / `{id, status, body}` up); `SPIKE_TOKEN` naming consistent across wrangler.toml, router, and client env.
