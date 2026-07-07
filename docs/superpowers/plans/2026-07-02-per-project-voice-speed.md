# Per-project voice & speed + drop `text` response mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the useless `text` response mode and let any repo override the TTS voice and speed (joining style/response) via env vars, on Claude Code, Codex, and Pi.

**Architecture:** The `UserPromptSubmit` hook (`voice-context.sh`) and Pi's extension already read a project's env; we route `OW_TTS_VOICE`/`OW_TTS_SPEED` through them. Claude/Codex get it by the hook injecting the values into the speak-first nudge (model echoes them into the `speak` tool call); Pi gets it deterministically because its extension makes the play call itself. `speed` becomes a first-class arg on the `speak` MCP tool and on `/v1/audio/play`.

**Tech Stack:** Swift (SwiftPM, CLT — no XCTest; plain `@main` test runners), bash hook, TypeScript (Pi extension), FluidAudio Kokoro TTS.

## Global Constraints

- **No version bump.** `1.5.0` stays in `build-dmg.sh` and `Info.plist`.
- **Speed range is `[0.7, 1.5]`, default `1.0`** — parsed/clamped only via `TTSSpeed` (`OpenWhispererKit`). Never hardcode the bounds elsewhere.
- **The native-tongue language map lives ONLY in `hooks/voice-context.sh`** — no Swift parity pair. `HookTests` is its guard.
- **Tests:** `cd app && swift run OpenWhispererKitTests` (pure logic) and `swift run HookTests` (bash hook) — each `exit(1)` on failure. There is no per-test filter.
- **Commits:** Conventional Commits (`type(scope): subject`, ≤72 incl. prefix). Every commit message ends with the `Claude-Session:` trailer per the repo's Bash/commit convention.
- **Voice ids** are Kokoro names like `af_heart` (English US), `bf_alice` (English UK), `ff_siwis` (French), `if_sara` (Italian), `jf_alpha` (Japanese). The flavor map keys off the **first character** (`a`/`b`→English→no flavor).

---

### Task 1: Drop the `text` response mode

Response mode becomes `voice` (default) / `always`. A lingering `text` value (env or persisted file) must degrade to `voice` behavior, and the persisted global file gets rewritten on launch.

**Files:**
- Modify: `hooks/voice-context.sh` (the mode `case`, ~line 67-71)
- Modify: `app/Tests/HookTests/VoiceContextChecks.swift` (tests 12 & 13)
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift:181` (picker) and `:661` (help)
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift` (new migration, after line 416)
- Modify: `app/Sources/OpenWhisperer/AppDelegate.swift:15` (call the migration)

**Interfaces:**
- Produces: `ConfigManager.migrateRemoveTextResponseMode()` — static, no args, no return.

- [ ] **Step 1: Rewrite HookTests cases 12 & 13 to expect `text` → `voice` behavior**

In `app/Tests/HookTests/VoiceContextChecks.swift`, replace the two blocks currently labelled `// 12) text + typed turn → speaks.` and `// 13) text + dictated turn → silent, signal still consumed.` (lines 138-151) with:

```swift
    // 12) removed `text` mode + dictated turn → behaves as voice: speaks and claims the signal.
    do {
        let s = newSandbox(); s.writeResponseMode("text"); s.writeVoiceTurn(forPrompt: "spoke this")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "spoke this", session: "s-tv"), sandbox: s)
        if nudge(r.stdout)?.contains("`speak` tool") != true { fail("textIsVoiceDictated: expected nudge, got \(r.stdout.debugDescription)") }
        if s.voiceTurnExists() { fail("textIsVoiceDictated: voice_turn should be claimed") }
    }

    // 13) removed `text` mode + typed turn → behaves as voice: stays silent.
    do {
        let s = newSandbox(); s.writeResponseMode("text")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "typed thing", session: "s-tt"), sandbox: s)
        if !r.stdout.isEmpty { fail("textIsVoiceTyped: expected silence, got \(r.stdout.debugDescription)") }
    }
```

- [ ] **Step 2: Run HookTests — verify it fails**

Run: `cd app && swift run HookTests`
Expected: FAIL — `textIsVoiceDictated` (the current hook silences a dictated turn under `text`) and/or `textIsVoiceTyped` (current hook speaks a typed turn under `text`).

- [ ] **Step 3: Remove the `text)` branch from the hook**

In `hooks/voice-context.sh`, the mode `case` (lines 67-71) currently reads:

```bash
case "$MODE" in
  always) SPEAK=1 ;;
  text)   [ "$IS_VOICE" -eq 0 ] && SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;   # voice (default)
esac
```

Delete the `text)` line so it becomes:

```bash
case "$MODE" in
  always) SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;   # voice (default); a stale "text" falls here
esac
```

Also update the mode comment near the top (lines 5-8) to drop the `text` line:

```bash
# Response mode (tts_response_mode, or per-project OW_TTS_RESPONSE):
#   voice  (default) — speak only voice-dictated turns (prompt hash matches voice_turn)
#   always           — speak every turn
```

- [ ] **Step 4: Run HookTests — verify it passes**

Run: `cd app && swift run HookTests`
Expected: `✅ HookTests: all checks passed`

- [ ] **Step 5: Remove `text` from the menubar picker and help**

In `app/Sources/OpenWhisperer/MenuBarView.swift`, delete the `text` entry from `responseModes` (line 181) so it reads:

```swift
    private static let responseModes: [(id: String, label: String)] = [
        ("voice", "when Voice"),
        ("always", "Always"),
    ]
```

Update the `.help(...)` string on line 661:

```swift
                            .help("When replies are spoken: when Voice = only dictated turns, Always = every turn.")
```

(The `.onAppear` restore at line 305 already ignores unknown saved values, so a stale `text` file reverts to the default `voice` in the picker — no change needed there.)

- [ ] **Step 6: Add the launch migration and call it**

In `app/Sources/OpenWhisperer/ConfigManager.swift`, add after `migrateVoiceDetailToTtsStyle()` (after line 416):

```swift
    /// One-shot: the `text` response mode was removed (no sensible use case). Rewrite any
    /// persisted `tts_response_mode` == "text" to the default "voice" so the picker and hook agree.
    static func migrateRemoveTextResponseMode() {
        guard let raw = try? String(contentsOf: Paths.ttsResponseMode, encoding: .utf8),
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == "text" else { return }
        try? "voice".write(to: Paths.ttsResponseMode, atomically: true, encoding: .utf8)
    }
```

In `app/Sources/OpenWhisperer/AppDelegate.swift`, add the call right after line 15 (`ConfigManager.migrateVoiceDetailToTtsStyle()`):

```swift
        // The `text` response mode was removed — coerce any persisted value to the default.
        ConfigManager.migrateRemoveTextResponseMode()
```

- [ ] **Step 7: Build — verify the app target compiles**

Run: `cd app && swift build`
Expected: `Build complete!`

- [ ] **Step 8: Commit**

```bash
git add hooks/voice-context.sh app/Tests/HookTests/VoiceContextChecks.swift \
        app/Sources/OpenWhisperer/MenuBarView.swift \
        app/Sources/OpenWhisperer/ConfigManager.swift \
        app/Sources/OpenWhisperer/AppDelegate.swift
git commit -m "feat(voice): drop the text response mode"
```

---

### Task 2: Add `speed` to the `speak` MCP tool and thread it through playback

`speed` becomes an optional arg on the `speak` tool (Claude/Codex path) and on `/v1/audio/play` (Pi path). The `.speak` outcome carries it; `TTSPlaybackController.play` takes it as a parameter.

**Files:**
- Modify: `app/Tests/OpenWhispererKitTests/MCPServerChecks.swift` (tools/list + tools/call checks)
- Modify: `app/Sources/OpenWhispererKit/MCPServer.swift` (enum, schema, parse)
- Modify: `app/Sources/OpenWhisperer/TTSHTTPServer.swift` (`.speak` case + `/v1/audio/play`)
- Modify: `app/Sources/OpenWhisperer/TTSPlaybackController.swift` (`play` signature)

**Interfaces:**
- Produces: `enum MCPOutcome { case speak(response: Data, text: String, voice: String?, speed: Double?) ... }`
- Produces: `TTSPlaybackController.play(text: String, voice: String, speed: Float)`
- Consumes: `TTSSpeed.clamp(_:) -> Float`, `TTSHTTPServer.userSpeed() -> Float`, `TTSHTTPServer.userVoice() -> String` (all already exist).

- [ ] **Step 1: Update MCPServerChecks for the `speed` property and arg**

In `app/Tests/OpenWhispererKitTests/MCPServerChecks.swift`:

In the `tools/list` block (after line 50, `if props?["voice"] == nil ...`), add:

```swift
        if props?["speed"] == nil { failures.append("tools/list: speak missing speed property") }
```

Replace the `tools/call speak (text + voice)` block (lines 55-66) with a version that also passes and asserts `speed`:

```swift
    // tools/call speak (text + voice + speed) → .speak side effect, all args passed through.
    switch req(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hello there","voice":"af_bella","speed":1.25}}}"#) {
    case let .speak(response, text, voice, speed):
        if text != "hello there" { failures.append("tools/call: text not passed through") }
        if voice != "af_bella" { failures.append("tools/call: voice not passed through") }
        if speed != 1.25 { failures.append("tools/call: speed not passed through") }
        if let r = decode(response)?["result"] as? [String: Any] {
            if (r["isError"] as? Bool) != false { failures.append("tools/call: isError should be false") }
            if ((r["content"] as? [[String: Any]])?.first?["type"] as? String) != "text" { failures.append("tools/call: content[0].type != \"text\"") }
        } else { failures.append("tools/call: response not decodable") }
    default:
        failures.append("tools/call(speak): expected .speak outcome")
    }
```

Replace the `tools/call speak without voice` block (lines 69-75) with one that also asserts `speed` is nil when omitted:

```swift
    // tools/call speak without voice/speed → both nil (handler must not invent them).
    switch req(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hi"}}}"#) {
    case let .speak(_, text, voice, speed):
        if text != "hi" { failures.append("tools/call(no voice): text wrong") }
        if voice != nil { failures.append("tools/call(no voice): voice should be nil") }
        if speed != nil { failures.append("tools/call(no speed): speed should be nil") }
    default:
        failures.append("tools/call(no voice): expected .speak outcome")
    }
```

- [ ] **Step 2: Run OpenWhispererKitTests — verify it fails**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: FAIL to **compile** — the `.speak` pattern now binds four values but the enum still declares three.

- [ ] **Step 3: Extend MCPServer — enum, schema, parse**

In `app/Sources/OpenWhispererKit/MCPServer.swift`:

Change the enum case (line 11):

```swift
    /// Send `response` (200) AND play `text` aloud (optionally in `voice`/`speed`). The one side effect.
    case speak(response: Data, text: String, voice: String?, speed: Double?)
```

In `tools/list`, add a `speed` property to the `speak` `inputSchema` `properties` (after the `voice` line, line 60):

```swift
                        "speed": ["type": "number", "description": "Optional playback speed, 0.7–1.5; defaults to the user's setting."],
```

In `tools/call`, after `let voice = args["voice"] as? String` (line 76), add and pass `speed`:

```swift
            let voice = args["voice"] as? String
            let speed = args["speed"] as? Double
            let response = Self.resultResponse(id: requestID, result: [
                "content": [["type": "text", "text": "Speaking."]],
                "isError": false,
            ])
            return .speak(response: response, text: text, voice: voice, speed: speed)
```

- [ ] **Step 4: Run OpenWhispererKitTests — verify it passes**

Run: `cd app && swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`

- [ ] **Step 5: Thread `speed` through the HTTP layer and the playback controller**

In `app/Sources/OpenWhisperer/TTSPlaybackController.swift`, change `play` to take a `speed` parameter and drop the internal read. Replace lines 22-34 (the signature through the `writeLock()` call) with:

```swift
    /// Speak `text`, superseding any current playback.
    func play(text: String, voice: String, speed: Float) {
        generation += 1
        let gen = generation
        synthDone = false
        playTask?.cancel()
        engine.stop()

        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else { removeLock(); return }
        let volume = Self.readVolume()
        writeLock()
```

Then delete the now-unused `readSpeed()` helper (lines 106-108):

```swift
    private static func readSpeed() -> Float {
        TTSSpeed.parse(try? String(contentsOf: Paths.ttsSpeed, encoding: .utf8))
    }
```

In `app/Sources/OpenWhisperer/TTSHTTPServer.swift`, update the `/v1/audio/play` case (lines 126-134) to honor an optional body `speed`:

```swift
        case ("POST", "/v1/audio/play"):
            // Fire-and-forget: hand the text to the in-app player and return immediately. The
            // player synthesizes sentence-by-sentence and supersedes any current playback.
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
            let input = json?["input"] as? String ?? ""
            let voice = json?["voice"] as? String ?? Self.userVoice()
            let speed = (json?["speed"] as? Double).flatMap { $0.isFinite ? TTSSpeed.clamp(Float($0)) : nil } ?? Self.userSpeed()
            Task { [playback] in await playback.play(text: input, voice: voice, speed: speed) }
            respond(conn, "202 Accepted",
                    Data(#"{"status":"accepted"}"#.utf8), contentType: "application/json")
```

Update the `.speak` case (lines 144-146) to bind and clamp `speed`:

```swift
            case .speak(let response, let text, let voice, let speed):
                let resolvedSpeed = speed.flatMap { $0.isFinite ? TTSSpeed.clamp(Float($0)) : nil } ?? Self.userSpeed()
                Task { [playback] in await playback.play(text: text, voice: voice ?? Self.userVoice(), speed: resolvedSpeed) }
                respond(conn, "200 OK", response, contentType: "application/json")
```

- [ ] **Step 6: Build — verify the app target compiles with the new signatures**

Run: `cd app && swift build`
Expected: `Build complete!` (confirms both `play` call sites and the `.speak` match were updated).

- [ ] **Step 7: Commit**

```bash
git add app/Tests/OpenWhispererKitTests/MCPServerChecks.swift \
        app/Sources/OpenWhispererKit/MCPServer.swift \
        app/Sources/OpenWhisperer/TTSHTTPServer.swift \
        app/Sources/OpenWhisperer/TTSPlaybackController.swift
git commit -m "feat(tts): add speed arg to speak tool + /v1/audio/play"
```

---

### Task 3: Per-project voice/speed in the hook (Claude & Codex)

The hook resolves voice/speed with the same precedence as style/response, uses the resolved voice for the native-tongue flavor, and injects `voice="…" speed=…` into the nudge **only when the project overrides** (env var set).

**Files:**
- Modify: `hooks/voice-context.sh` (flavor voice read ~line 88; new arg block before the nudge ~line 108; nudge string ~line 110)
- Modify: `app/Tests/HookTests/VoiceContextChecks.swift` (new checks 24-28)

**Interfaces:**
- Consumes: env `OW_TTS_VOICE`, `OW_TTS_SPEED`; files `tts_voice`, `tts_speed`.
- Produces: nudge text containing ` Call it with voice="<id>" speed=<n>.` when overridden; byte-identical to today when not.

- [ ] **Step 1: Add the failing HookTests checks**

In `app/Tests/HookTests/VoiceContextChecks.swift`, add these blocks just before `return failures` (after line 244):

```swift
    // --- Per-project voice/speed overrides (env → nudge args; flavor follows the override) ---

    // 24) OW_TTS_VOICE override → nudge instructs speak with that voice arg.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_VOICE": "ff_siwis"])
        if nudge(r.stdout)?.contains("voice=\"ff_siwis\"") != true {
            fail("voiceOverrideArg: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 25) OW_TTS_SPEED (numeric) override → nudge instructs speak with that speed arg.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_SPEED": "1.2"])
        if nudge(r.stdout)?.contains("speed=1.2") != true {
            fail("speedOverrideArg: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 26) no override → nudge carries no voice=/speed= args (default nudge unchanged).
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("voice=") == true || n?.contains("speed=") == true {
            fail("noOverrideNoArgs: unexpected arg injected: \(n?.debugDescription ?? "nil")")
        }
    }

    // 27) non-numeric OW_TTS_SPEED is dropped (garbage never reaches the nudge).
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_SPEED": "fast"])
        if nudge(r.stdout)?.contains("speed=") == true {
            fail("badSpeedDropped: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 28) flavor follows OW_TTS_VOICE, not the global file: French override beats an English global.
    do {
        let s = newSandbox(); s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"),
                         sandbox: s, env: ["OW_TTS_VOICE": "ff_siwis", "OW_FLAVOR_ROLL": "0"])
        if nudge(r.stdout)?.contains("French") != true {
            fail("flavorFollowsOverride: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }
```

- [ ] **Step 2: Run HookTests — verify it fails**

Run: `cd app && swift run HookTests`
Expected: FAIL — `voiceOverrideArg`, `speedOverrideArg`, and `flavorFollowsOverride` (the hook doesn't yet read the env overrides).

- [ ] **Step 3: Make the flavor read the resolved (override-aware) voice**

In `hooks/voice-context.sh`, replace the voice read (line 88):

```bash
VOICE=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null | tr -d '[:space:]')
```

with an env-then-file resolution (trims either source):

```bash
# Resolved voice: per-project OW_TTS_VOICE env → global tts_voice file. Drives BOTH the
# native-tongue flavor (below) and, when it came from the env override, the speak arg.
VOICE="$OW_TTS_VOICE"
[ -z "$VOICE" ] && VOICE=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null)
VOICE=$(printf '%s' "$VOICE" | tr -d '[:space:]')
```

- [ ] **Step 4: Build the override-arg clause and inject it into the nudge**

In `hooks/voice-context.sh`, immediately after the flavor block (after line 107, the `fi` closing `if [ -n "$FLAVOR_LANG" ]`) and before the `PREFIX=` line (109), insert:

```bash
# Per-project overrides → tell the model to pass them to `speak`. Only an override needs
# injecting; the global voice/speed are already the tool's defaults. Speed must be numeric.
SPEAK_ARGS=""
OVR=""
[ -n "$OW_TTS_VOICE" ] && OVR=" voice=\"$VOICE\""
if [ -n "$OW_TTS_SPEED" ] && printf '%s' "$OW_TTS_SPEED" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
  OVR="${OVR} speed=$OW_TTS_SPEED"
fi
[ -n "$OVR" ] && SPEAK_ARGS=" Call it with${OVR}."
```

Then edit the `NUDGE=` assignment (line 110) to splice `${SPEAK_ARGS}` in after "stands alone when heard.":

```bash
NUDGE="${PREFIX} Before writing your on-screen reply, your FIRST action must be to call the \`speak\` tool exactly once, passing ${LEN} that summarizes your answer and stands alone when heard.${SPEAK_ARGS} Then write your full reply on screen as usual. Do not skip the speak call, and do not mention the tool in your written reply.${FLAVOR}"
```

- [ ] **Step 5: Run HookTests — verify it passes**

Run: `cd app && swift run HookTests`
Expected: `✅ HookTests: all checks passed` (new checks 24-28 pass; existing flavor/style checks 1-23 still pass because none set the `OW_TTS_*` env).

- [ ] **Step 6: Commit**

```bash
git add hooks/voice-context.sh app/Tests/HookTests/VoiceContextChecks.swift
git commit -m "feat(voice): per-project OW_TTS_VOICE/OW_TTS_SPEED via nudge"
```

---

### Task 4: Pi extension — drop `text` + inject per-project voice/speed

Pi's extension makes the play call itself, so it injects voice/speed **deterministically** (no model dependency). It also loses the `text` mode branch. No in-repo test harness for TS — verify by review + build + manual Pi run.

**Files:**
- Modify: `pi/openwhisperer.ts` (`execute` handler ~lines 106-121; `before_agent_start` mode branch ~lines 137-140)

**Interfaces:**
- Consumes: `readPref(env, file, fallback) -> string` (already defined, line 25); `TTS_PLAY_URL` (line 22); `/v1/audio/play` now accepts `speed` (Task 2).

- [ ] **Step 1: Inject voice/speed into the play body**

In `pi/openwhisperer.ts`, replace the `execute` handler body (lines 106-121) with a version that reads the prefs and includes them when valid:

```typescript
    async execute(_toolCallId, params) {
      debug(`speak tool called: ${JSON.stringify(params.text).slice(0, 80)}`);
      // Per-project voice/speed: read here (the extension owns the call, so this is
      // deterministic — no dependency on the model echoing args). Precedence: env → file.
      const voice = readPref("OW_TTS_VOICE", "tts_voice", "");
      const speed = Number.parseFloat(readPref("OW_TTS_SPEED", "tts_speed", ""));
      const body: Record<string, unknown> = { input: params.text };
      if (voice) body.voice = voice;
      if (Number.isFinite(speed)) body.speed = speed;
      try {
        await fetch(TTS_PLAY_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        });
      } catch (e) {
        return {
          content: [{ type: "text", text: `speak failed: ${(e as Error).message}` }],
          isError: true,
        };
      }
      return { content: [{ type: "text", text: "Speaking." }] };
    },
```

- [ ] **Step 2: Drop the `text` mode branch**

In `pi/openwhisperer.ts`, replace the mode decision (lines 137-140):

```typescript
    let speak: boolean;
    if (mode === "always") speak = true;
    else if (mode === "text") speak = !isVoice;
    else speak = isVoice; // "voice" (default)
```

with:

```typescript
    // Response mode: "always" speaks every turn; "voice" (default, and any stale "text")
    // speaks only dictated turns.
    const speak = mode === "always" ? true : isVoice;
```

- [ ] **Step 3: Verify no `text` references remain and the file reads cleanly**

Run: `grep -n "text" pi/openwhisperer.ts`
Expected: no `mode === "text"` line remains (only unrelated matches like `type: "text"` content tags).

Read the changed regions back and confirm the body object is only sent with `voice`/`speed` keys when truthy/finite.

- [ ] **Step 4: Manual validation (documented, not automated)**

In a scratch repo, set in `.claude/settings.local.json`:

```json
{ "env": { "OW_TTS_VOICE": "ff_siwis", "OW_TTS_SPEED": "1.2" } }
```

With the app running and the extension installed (`~/.pi/agent/extensions/openwhisperer.ts`, `/reload` in Pi), dictate a turn and confirm it speaks in the French voice, faster. Remove the overrides and confirm it reverts to the global voice/speed. (This is a manual check — note the result in the commit or PR description.)

- [ ] **Step 5: Commit**

```bash
git add pi/openwhisperer.ts
git commit -m "feat(voice): Pi per-project voice/speed + drop text mode"
```

---

### Task 5: Update AGENTS.md

Reverse the "Voice is global-only now" claim, document the two new env vars, drop `text` from the mode list, and note `speed` is a `speak` arg.

**Files:**
- Modify: `AGENTS.md` (State & IPC section; Voice-turn handshake section; TTS section)

- [ ] **Step 1: Edit the per-project override paragraph (State & IPC)**

Find the paragraph beginning "These are global (one menubar setting for all repos), but `tts_style` and `tts_response_mode` can be **overridden per-project**…" and its follow-on "**Voice is global-only now:**…" sentence. Replace that whole passage so it reads:

> These are global (one menubar setting for all repos), but `tts_style`, `tts_response_mode`, `tts_voice`, and `tts_speed` can be **overridden per-project** via env vars in that repo's `.claude/settings.local.json` `env` block — read by `voice-context.sh` (and Pi's extension), which take precedence over the global files: `OW_TTS_STYLE`, `OW_TTS_RESPONSE`, `OW_TTS_VOICE`, and `OW_TTS_SPEED`. For Claude/Codex, voice/speed overrides are injected into the speak nudge as `speak` tool args (model-echoed); on Pi the extension passes them to `/v1/audio/play` directly (deterministic). The override voice also drives the native-tongue flavor.

- [ ] **Step 2: Drop `text` from the response-mode description (Voice-turn handshake)**

Find every mention of the response mode set `voice (default) | text (only typed turns) | always` and change it to `voice (default) | always`. Update the sentence describing `tts_response_mode` in the State & IPC prefs list the same way.

- [ ] **Step 3: Note `speed` is a `speak` arg (TTS section)**

In the paragraph describing `POST /mcp` / the `speak` tool and the `/v1/audio/play` endpoint, add that both accept an optional `speed` (clamped via `TTSSpeed`), alongside the existing `voice`.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document per-project voice/speed, drop text mode"
```

---

## Notes for the implementer

- **Out of scope (do not add):** per-project volume/language/interaction-mode; native-tongue **flavor for Pi** (Pi's nudge never carried it — leave it); any new menubar UI; a version bump.
- **The `text` self-heal is layered:** the hook coerces at runtime, the picker ignores unknown saved values, and the migration rewrites the file. All three are intended — don't "simplify" by removing one.
- **Speed is never clamped in bash.** The hook passes the raw numeric string; `TTSSpeed.clamp` (Swift) is the single clamp point for the MCP/play paths, and `/v1/audio/speech` already clamps its body `speed`.
