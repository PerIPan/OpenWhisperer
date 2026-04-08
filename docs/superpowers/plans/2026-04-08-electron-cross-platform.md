# Open Whisperer — Electron Cross-Platform Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Open Whisperer on Windows and Linux via Electron, sharing the Python backend with the existing macOS Swift app.

**Architecture:** Two UI shells (Swift for macOS, Electron for Win/Linux) sharing a Python FastAPI server. The server gets PyTorch fallback imports and a `client_managed` mode. Each client handles text insertion and app focusing natively. Formal OpenAPI contract governs the API.

**Tech Stack:** Electron 33+, React 19, TypeScript, electron-vite, PyTorch Whisper, Kokoro PyTorch, FastAPI, ffi-napi (Win), xdotool (Linux), uiohook-napi, electron-builder

**Spec:** `docs/superpowers/specs/2026-04-08-electron-cross-platform-design.md`

---

## Plan Overview (7 phases)

| Phase | Name | Depends On | Deliverable |
|-------|------|------------|-------------|
| 0 | POCs | — | Go/no-go for 5 risk areas |
| 1 | Server cross-platform + API contract | — | Server runs on Win/Linux with PyTorch |
| 2 | Electron scaffold + tray + server lifecycle | Phase 1 | App launches, tray icon, Python server starts |
| 3 | Audio recording + STT pipeline | Phase 2 | Record → transcribe → get text back |
| 4 | Text insertion + auto-submit | Phase 3 | Transcribed text typed into focused app |
| 5 | Settings UI + config + hooks | Phase 4 | Full settings panel, TTS hooks |
| 6 | Overlay + TTS playback | Phase 5 | Transcription overlay, TTS audio |
| 7 | Setup flow + distribution | Phase 6 | First-launch installer, .exe, .AppImage |

---

## Phase 0: Proof of Concepts

> Run these BEFORE any production code. Each is isolated. If any fails, revisit the spec.

### Task 0.1: Transparent Overlay on Linux

**Goal:** Verify frameless transparent BrowserWindow on Ubuntu GNOME Wayland + X11

**Files:**
- Create: `electron/poc/overlay-test/main.js`
- Create: `electron/poc/overlay-test/index.html`
- Create: `electron/poc/overlay-test/package.json`

- [ ] **Step 1: Scaffold minimal Electron app**

```javascript
// main.js
const { app, BrowserWindow } = require('electron');
app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 300, height: 120,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    webPreferences: { nodeIntegration: false, contextIsolation: true }
  });
  win.loadFile('index.html');
});
```

```html
<!-- index.html -->
<body style="background: transparent; font-family: sans-serif; margin: 20px;">
  <div style="background: rgba(30,30,30,0.85); color: white; padding: 16px; border-radius: 12px;">
    <span style="color: #4ade80;">● Recording...</span>
    <p>Overlay transparency test</p>
  </div>
</body>
```

- [ ] **Step 2: Test on target platforms**

Run: `cd electron/poc/overlay-test && npx electron .`

Test on:
- Ubuntu 24.04 GNOME Wayland
- Ubuntu 22.04 GNOME X11
- Windows 11

Expected: transparent background with floating rounded card. If Wayland shows solid black, document and use opaque fallback.

- [ ] **Step 3: Document results**

Write results to `electron/poc/RESULTS.md`

---

### Task 0.2: Modifier-Only Hotkey on Windows

**Goal:** Verify `uiohook-napi` detects Ctrl-only press/release without false triggers

**Files:**
- Create: `electron/poc/hotkey-test/main.js`
- Create: `electron/poc/hotkey-test/package.json`

- [ ] **Step 1: Scaffold hotkey test**

```javascript
// main.js
const { app } = require('electron');
const { uIOhook, UiohookKey } = require('uiohook-napi');

app.whenReady().then(() => {
  let ctrlDown = false;
  let otherKeyPressed = false;

  uIOhook.on('keydown', (e) => {
    if (e.keycode === UiohookKey.Ctrl) { ctrlDown = true; otherKeyPressed = false; }
    else { otherKeyPressed = true; }
  });

  uIOhook.on('keyup', (e) => {
    if (e.keycode === UiohookKey.Ctrl && ctrlDown && !otherKeyPressed) {
      console.log('SOLO CTRL TAP DETECTED');
    }
    if (e.keycode === UiohookKey.Ctrl) ctrlDown = false;
  });

  uIOhook.start();
  console.log('Listening for Ctrl taps... (Ctrl+C to exit)');
});
```

- [ ] **Step 2: Test on Windows 11**

Run: `cd electron/poc/hotkey-test && npx electron .`

Test scenarios:
1. Solo Ctrl press → should log "SOLO CTRL TAP DETECTED"
2. Ctrl+C → should NOT log
3. Ctrl+V → should NOT log
4. Rapid Ctrl taps → should log each time

- [ ] **Step 3: Document results in `electron/poc/RESULTS.md`**

If unreliable, fallback plan: use `Ctrl+Space` as default PTT combo.

---

### Task 0.3: Tray Icon on GNOME

**Goal:** Verify Electron tray visibility on GNOME without AppIndicator extension

- [ ] **Step 1: Test Task 0.1's Electron app with a Tray added**

Add to main.js:
```javascript
const { Tray, Menu } = require('electron');
const tray = new Tray('icon.png'); // 16x16 or 22x22 PNG
tray.setContextMenu(Menu.buildFromTemplate([
  { label: 'Open Whisperer', click: () => {} },
  { label: 'Quit', click: () => app.quit() }
]));
```

- [ ] **Step 2: Test on GNOME with and without AppIndicator extension**

Expected without extension: tray icon invisible. Document behavior.

- [ ] **Step 3: Document GNOME fallback strategy in `electron/poc/RESULTS.md`**

---

### Task 0.4: Windows Text Insertion (ffi-napi + SendInput)

**Goal:** Type Unicode text into Notepad on Windows without nut.js

**Files:**
- Create: `electron/poc/sendinput-test/main.js`
- Create: `electron/poc/sendinput-test/package.json`

- [ ] **Step 1: Scaffold SendInput test**

```javascript
const ffi = require('ffi-napi');
const ref = require('ref-napi');
const StructType = require('ref-struct-napi');

const INPUT = StructType({
  type: ref.types.uint32,
  wVk: ref.types.uint16,
  wScan: ref.types.uint16,
  dwFlags: ref.types.uint32,
  time: ref.types.uint32,
  dwExtraInfo: ref.types.ulong,
  padding: ref.types.uint64
});

const user32 = ffi.Library('user32', {
  'SendInput': ['uint32', ['uint32', INPUT, 'int32']]
});

function typeText(text) {
  for (const char of text) {
    const code = char.charCodeAt(0);
    // Key down
    const down = new INPUT();
    down.type = 1; // INPUT_KEYBOARD
    down.wVk = 0;
    down.wScan = code;
    down.dwFlags = 0x0004; // KEYEVENTF_UNICODE
    user32.SendInput(1, down, INPUT.size);
    // Key up
    const up = new INPUT();
    up.type = 1;
    up.wVk = 0;
    up.wScan = code;
    up.dwFlags = 0x0004 | 0x0002; // UNICODE | KEYUP
    user32.SendInput(1, up, INPUT.size);
  }
}

// Test: open Notepad, wait 2 seconds, type text
setTimeout(() => typeText('Hello from Open Whisperer! 🎤'), 2000);
```

- [ ] **Step 2: Run test** — open Notepad, run script, verify text appears

- [ ] **Step 3: Test Unicode (emoji, accented chars, CJK)**

- [ ] **Step 4: Document results in `electron/poc/RESULTS.md`**

---

### Task 0.5: AudioWorklet Recording → Server Transcription

**Goal:** Record audio in Electron renderer, export WAV, POST to server, get transcription

**Files:**
- Create: `electron/poc/audio-test/main.js`
- Create: `electron/poc/audio-test/renderer.html`
- Create: `electron/poc/audio-test/audio-processor.js`

- [ ] **Step 1: Create AudioWorklet processor**

```javascript
// audio-processor.js
class AudioRecorderProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const input = inputs[0][0]; // mono channel
    if (input) this.port.postMessage(input);
    return true;
  }
}
registerProcessor('audio-recorder', AudioRecorderProcessor);
```

- [ ] **Step 2: Create renderer with record button**

Record 5 seconds, export as WAV (16kHz mono 16-bit), POST to `http://localhost:8000/v1/audio/transcriptions`, display result.

- [ ] **Step 3: Test against running Python server**

Run: start unified_server.py, then `npx electron .`
Expected: spoken text appears as transcription result.

- [ ] **Step 4: Document results in `electron/poc/RESULTS.md`**

---

## Phase 1: Server Cross-Platform + API Contract

### Task 1.1: Create OpenAPI Spec

**Files:**
- Create: `api/openapi.yaml`

- [ ] **Step 1: Write OpenAPI 3.0 spec matching current server endpoints**

```yaml
openapi: 3.0.3
info:
  title: Open Whisperer API
  version: 1.3.3
paths:
  /v1/audio/transcriptions:
    post:
      summary: Transcribe audio
      requestBody:
        content:
          multipart/form-data:
            schema:
              type: object
              properties:
                file:
                  type: string
                  format: binary
                model:
                  type: string
                language:
                  type: string
                client_managed:
                  type: boolean
                  default: false
      responses:
        '200':
          content:
            application/json:
              schema:
                type: object
                properties:
                  text:
                    type: string
                  should_submit:
                    type: boolean
  /v1/audio/speech:
    post:
      summary: Text to speech
      requestBody:
        content:
          application/json:
            schema:
              type: object
              properties:
                input:
                  type: string
                voice:
                  type: string
                model:
                  type: string
      responses:
        '200':
          content:
            audio/wav: {}
  /v1/models:
    get:
      summary: List models
      responses:
        '200':
          content:
            application/json: {}
```

- [ ] **Step 2: Commit**

```bash
git add api/openapi.yaml
git commit -m "feat: add OpenAPI spec for server contract"
```

---

### Task 1.2: Add Platform Detection to Server

**Files:**
- Modify: `servers/unified_server.py:20-26` (imports)
- Modify: `servers/unified_server.py:69` (APP_SUPPORT path)
- Modify: `servers/unified_server.py:100` (GPU lock)

- [ ] **Step 1: Add platform-aware imports**

Replace lines 20-26 with:
```python
import platform

_IS_DARWIN = platform.system() == "Darwin"

if _IS_DARWIN:
    import mlx_whisper
    from mlx_audio.server import app, model_provider, setup_cors, SpeechRequest
else:
    import whisper
    from kokoro import KPipeline
    import torch
    from fastapi import FastAPI
    from fastapi.middleware.cors import CORSMiddleware
    app = FastAPI()
```

- [ ] **Step 2: Make APP_SUPPORT path cross-platform**

Replace line 69:
```python
if _IS_DARWIN:
    _APP_SUPPORT = os.path.expanduser("~/Library/Application Support/OpenWhisperer")
elif platform.system() == "Windows":
    _APP_SUPPORT = os.path.join(os.environ.get("APPDATA", ""), "OpenWhisperer")
else:
    _APP_SUPPORT = os.path.expanduser("~/.config/OpenWhisperer")
```

- [ ] **Step 3: Make GPU lock platform-aware**

```python
if _IS_DARWIN:
    _mlx_gpu_lock = threading.Lock()
else:
    _gpu_lock = threading.Lock()  # Same pattern, different name for clarity
```

- [ ] **Step 4: Test server starts on current platform**

Run: `python servers/unified_server.py`
Expected: Server starts on port 8000, `/v1/models` returns model list

- [ ] **Step 5: Commit**

```bash
git add servers/unified_server.py
git commit -m "feat: add platform detection for cross-platform server"
```

---

### Task 1.3: Add client_managed Mode

**Files:**
- Modify: `servers/unified_server.py:147-229` (press_enter, focus_target_app, kill_tts)
- Modify: `servers/unified_server.py:242-318` (transcription endpoint)

- [ ] **Step 1: Gate macOS-only functions behind platform check**

Wrap `press_enter()`, `focus_target_app()`, `kill_tts()` with `if _IS_DARWIN`:

```python
if _IS_DARWIN:
    def focus_target_app():
        # ... existing code (lines 147-165) ...

    def press_enter():
        # ... existing code (lines 205-229) ...

    def kill_tts():
        # ... existing code (lines 168-202) ...
else:
    def focus_target_app():
        pass  # Client handles this

    def press_enter():
        pass  # Client handles this

    def kill_tts():
        pass  # Client handles this
```

- [ ] **Step 2: Add `client_managed` form param to transcription endpoint**

In the transcription endpoint (line ~260), add:
```python
client_managed = form_data.get("client_managed", "false") == "true"
```

When `client_managed=true`, skip `press_enter()` and `focus_target_app()` calls. Always return `should_submit` in the JSON response so the client can handle it:

```python
return JSONResponse({"text": text.strip(), "should_submit": should_submit})
```

- [ ] **Step 3: Test — macOS still works as before**

Run server, use Swift app. Verify STT + auto-submit still work.

- [ ] **Step 4: Test — client_managed mode returns structured response**

```bash
curl -X POST http://localhost:8000/v1/audio/transcriptions \
  -F "file=@test.wav" \
  -F "model=mlx-community/whisper-large-v3-turbo" \
  -F "client_managed=true"
```

Expected: `{"text": "...", "should_submit": true}` (no Enter key pressed)

- [ ] **Step 5: Commit**

```bash
git add servers/unified_server.py
git commit -m "feat: add client_managed mode, move UI actions to client"
```

---

### Task 1.4: Add API Token Authentication

**Files:**
- Modify: `servers/unified_server.py` (add auth middleware)

- [ ] **Step 1: Generate token on startup, save to config**

```python
import secrets

_API_TOKEN_PATH = os.path.join(_APP_SUPPORT, "api_token")

def _get_or_create_token():
    if os.path.exists(_API_TOKEN_PATH):
        with open(_API_TOKEN_PATH) as f:
            return f.read().strip()
    token = secrets.token_urlsafe(32)
    os.makedirs(_APP_SUPPORT, exist_ok=True)
    with open(_API_TOKEN_PATH, "w") as f:
        f.write(token)
    return token

_API_TOKEN = _get_or_create_token()
```

- [ ] **Step 2: Add optional auth middleware**

```python
from fastapi import Request, HTTPException

@app.middleware("http")
async def check_auth(request: Request, call_next):
    # Allow unauthenticated for backwards compat with Swift app
    auth = request.headers.get("Authorization", "")
    if auth and not auth == f"Bearer {_API_TOKEN}":
        raise HTTPException(status_code=401, detail="Invalid token")
    return await call_next(request)
```

- [ ] **Step 3: Test — requests without token still work (backwards compat)**
- [ ] **Step 4: Test — requests with wrong token get 401**
- [ ] **Step 5: Commit**

```bash
git add servers/unified_server.py
git commit -m "feat: add optional API token auth for local server"
```

---

### Task 1.5: Add PyTorch STT/TTS Fallback

**Files:**
- Modify: `servers/unified_server.py:119-128` (transcribe function)
- Modify: `servers/unified_server.py:328-383` (TTS functions + endpoint)

- [ ] **Step 1: Add PyTorch transcription path**

```python
def _serialize_transcribe(audio_path, language=None):
    if _IS_DARWIN:
        with _mlx_gpu_lock:
            result = mlx_whisper.transcribe(audio_path, path_or_hf_repo=WHISPER_MODEL, language=language)
    else:
        with _gpu_lock:
            model = whisper.load_model("large-v3-turbo")
            result = model.transcribe(audio_path, language=language)
    return result.get("text", "").strip()
```

- [ ] **Step 2: Add PyTorch TTS path**

```python
if not _IS_DARWIN:
    _kokoro_pipeline = None

    def _get_kokoro():
        global _kokoro_pipeline
        if _kokoro_pipeline is None:
            _kokoro_pipeline = KPipeline(lang_code='a')
        return _kokoro_pipeline

    @app.post("/v1/audio/speech")
    async def speech(request: Request):
        body = await request.json()
        text = body.get("input", "")
        voice = body.get("voice", "af_heart")
        with _gpu_lock:
            pipeline = _get_kokoro()
            audio, sr = pipeline(text, voice=voice)
        # Return as WAV
        buf = io.BytesIO()
        import soundfile as sf
        sf.write(buf, audio, sr, format='WAV')
        buf.seek(0)
        return StreamingResponse(buf, media_type="audio/wav")
```

- [ ] **Step 3: Test on macOS — MLX path still works**
- [ ] **Step 4: Test on Linux/Windows — PyTorch path works**

```bash
# STT test
curl -X POST http://localhost:8000/v1/audio/transcriptions -F "file=@test.wav" -F "model=whisper"

# TTS test
curl -X POST http://localhost:8000/v1/audio/speech -H "Content-Type: application/json" -d '{"input":"Hello world","voice":"af_heart","model":"kokoro"}' -o test_output.wav
```

- [ ] **Step 5: Commit**

```bash
git add servers/unified_server.py
git commit -m "feat: add PyTorch Whisper + Kokoro fallback for Win/Linux"
```

---

### Task 1.6: Cross-Platform TTS Hook

**Files:**
- Create: `hooks/tts-hook.js`
- Modify: `hooks/tts-hook.sh` (fix codex-tts-hook.sh greedy regex)

- [ ] **Step 1: Create Node.js cross-platform hook**

```javascript
#!/usr/bin/env node
// hooks/tts-hook.js — Cross-platform TTS hook for Claude Code
const https = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync, spawn } = require('child_process');

// Read stdin (Claude Code Stop hook payload)
let input = '';
process.stdin.on('data', (d) => input += d);
process.stdin.on('end', () => {
  const payload = JSON.parse(input);
  const message = payload.last_assistant_message || '';

  // Extract [VOICE: ...] tag
  const match = message.match(/\[VOICE:\s*([^\]]*)\]/);
  const text = match ? match[1].trim() : message.slice(0, 600);
  if (!text) process.exit(0);

  // Read config
  const configDir = process.platform === 'win32'
    ? path.join(process.env.APPDATA, 'OpenWhisperer')
    : path.join(os.homedir(), '.config', 'OpenWhisperer');
  const voice = fs.existsSync(path.join(configDir, 'tts_voice'))
    ? fs.readFileSync(path.join(configDir, 'tts_voice'), 'utf8').trim()
    : 'af_heart';
  const volume = fs.existsSync(path.join(configDir, 'tts_volume'))
    ? fs.readFileSync(path.join(configDir, 'tts_volume'), 'utf8').trim()
    : '1';

  // Call TTS server
  const postData = JSON.stringify({ input: text, voice, model: 'kokoro' });
  const tmpFile = path.join(os.tmpdir(), `tts_${Date.now()}.wav`);

  const req = https.request({
    hostname: '127.0.0.1', port: 8000,
    path: '/v1/audio/speech', method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': postData.length }
  }, (res) => {
    const stream = fs.createWriteStream(tmpFile);
    res.pipe(stream);
    stream.on('finish', () => {
      // Play audio
      if (process.platform === 'win32') {
        spawn('ffplay', ['-nodisp', '-autoexit', '-v', 'quiet', '-af', `volume=${volume}`, tmpFile]);
      } else {
        spawn('paplay', [tmpFile], { stdio: 'ignore' });
      }
    });
  });
  req.write(postData);
  req.end();
});
```

- [ ] **Step 2: Fix greedy regex in codex-tts-hook.sh line 81**

Change `(.*)` to `([^]]*)` to match tts-hook.sh pattern.

- [ ] **Step 3: Commit**

```bash
git add hooks/tts-hook.js hooks/codex-tts-hook.sh
git commit -m "feat: add cross-platform Node.js TTS hook, fix codex regex"
```

---

## Phase 2: Electron Scaffold + Tray + Server Lifecycle

### Task 2.1: Scaffold Electron Project

**Files:**
- Create: `electron/package.json`
- Create: `electron/electron-vite.config.ts`
- Create: `electron/tsconfig.json`
- Create: `electron/src/main/index.ts`
- Create: `electron/src/preload/index.ts`
- Create: `electron/src/renderer/index.html`
- Create: `electron/src/renderer/App.tsx`

- [ ] **Step 1: Init project with electron-vite**

```bash
cd electron
npm init -y
npm install electron electron-vite react react-dom
npm install -D typescript @types/react @types/react-dom tailwindcss
```

- [ ] **Step 2: Create main process entry**

```typescript
// src/main/index.ts
import { app, BrowserWindow } from 'electron';
import path from 'path';

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 400, height: 600,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      preload: path.join(__dirname, '../preload/index.js')
    }
  });
  win.loadFile(path.join(__dirname, '../renderer/index.html'));
});
```

- [ ] **Step 3: Create secure preload**

```typescript
// src/preload/index.ts
import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('openWhisperer', {
  getServerStatus: () => ipcRenderer.invoke('get-server-status'),
  onServerStatus: (cb: (status: string) => void) =>
    ipcRenderer.on('server-status', (_, status) => cb(status)),
});
```

- [ ] **Step 4: Create minimal React renderer**

```tsx
// src/renderer/App.tsx
export default function App() {
  return <div className="p-4">
    <h1 className="text-lg font-bold">Open Whisperer</h1>
    <p className="text-gray-500">Loading...</p>
  </div>;
}
```

- [ ] **Step 5: Verify it builds and launches**

Run: `cd electron && npx electron-vite dev`
Expected: Electron window opens with "Open Whisperer" text.

- [ ] **Step 6: Commit**

```bash
git add electron/
git commit -m "feat: scaffold Electron app with electron-vite + React"
```

---

### Task 2.2: System Tray

**Files:**
- Create: `electron/src/main/tray.ts`
- Modify: `electron/src/main/index.ts`

- [ ] **Step 1: Create tray manager**

```typescript
// src/main/tray.ts
import { Tray, Menu, BrowserWindow, nativeImage } from 'electron';
import path from 'path';

export function createTray(settingsWindow: BrowserWindow): Tray {
  const icon = nativeImage.createFromPath(
    path.join(__dirname, '../../assets/tray-icon.png')
  );
  const tray = new Tray(icon.resize({ width: 16, height: 16 }));

  tray.setToolTip('Open Whisperer');
  tray.on('click', () => {
    settingsWindow.isVisible() ? settingsWindow.hide() : settingsWindow.show();
  });

  return tray;
}
```

- [ ] **Step 2: Integrate tray into main process**
- [ ] **Step 3: Test — tray icon appears, click toggles settings window**
- [ ] **Step 4: Commit**

---

### Task 2.3: Server Manager

**Files:**
- Create: `electron/src/main/server-manager.ts`

- [ ] **Step 1: Create server lifecycle manager**

Spawns Python server via `child_process.spawn()`, monitors health via `GET /v1/models`, handles graceful shutdown.

- [ ] **Step 2: Wire into main process — server starts on `app.ready`**
- [ ] **Step 3: Test — server starts, health check passes, app quit kills server**
- [ ] **Step 4: Commit**

---

## Phase 3: Audio Recording + STT Pipeline

### Task 3.1: AudioWorklet Recorder
### Task 3.2: WAV Export
### Task 3.3: Transcription Flow (renderer → server → main → overlay)

---

## Phase 4: Text Insertion + Auto-Submit

### Task 4.1: Platform Text Inserter Interface
### Task 4.2: Windows SendInput Implementation (ffi-napi)
### Task 4.3: Linux X11 Implementation (xdotool)
### Task 4.4: Auto-Submit (press Enter after typing)
### Task 4.5: Auto-Focus (activate target app before typing)

---

## Phase 5: Settings UI + Config + Hooks

### Task 5.1: Config Manager (file-based, cross-platform paths)
### Task 5.2: Settings Panel (React, mirrors MenuBarView.swift)
### Task 5.3: Hook Auto-Apply (register TTS hooks for Claude Code / Codex)

---

## Phase 6: Overlay + TTS Playback

### Task 6.1: Transcription Overlay Window (frameless, with opaque fallback)
### Task 6.2: Waveform Display
### Task 6.3: TTS Audio Playback (platform-specific)
### Task 6.4: Barge-In (kill TTS when recording starts)

---

## Phase 7: Setup Flow + Distribution

### Task 7.1: First-Launch Setup Manager (GPU detection, venv, deps)
### Task 7.2: electron-builder Configuration
### Task 7.3: Windows NSIS Installer + EV Code Signing
### Task 7.4: Linux AppImage + .deb
### Task 7.5: Auto-Update via electron-updater + GitHub Releases
### Task 7.6: GNOME Tray Fallback

---

## Installer Decision

### Windows Code Signing Options

| Option | Cost | SmartScreen | Notes |
|--------|------|-------------|-------|
| **EV Authenticode cert** (DigiCert/Sectigo) | $300-600/yr | Immediate trust | Required hardware token |
| **Azure Trusted Signing** | ~$10/mo | Immediate trust | Azure subscription needed |
| **Standard OV cert** | $100-200/yr | Builds reputation over time | Users see warnings initially |
| **No signing** | Free | Blocked by default | Users must bypass manually (like macOS Gatekeeper) |
| **Self-signed** | Free | Blocked | Same as no signing |

**Recommendation:** Start with **no signing** (same approach as macOS — document the bypass). Add Azure Trusted Signing ($10/mo) when download volume justifies it. Skip the $600/yr EV cert for now.

Windows bypass equivalent of `xattr -cr`:
```
# In PowerShell (right-click → Run as Administrator)
Unblock-File -Path "$env:LOCALAPPDATA\Programs\OpenWhisperer\OpenWhisperer.exe"
```

Or simpler: right-click the downloaded .exe → Properties → Unblock checkbox.

### Linux Installation

No signing issues. AppImage just runs. `.deb` installs with `dpkg -i`.
