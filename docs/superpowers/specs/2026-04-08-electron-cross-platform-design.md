# Open Whisperer — Electron Cross-Platform App Design

**Date:** 2026-04-08
**Status:** Reviewed (3-agent review complete)
**Scope:** Windows + Linux desktop app via Electron, sharing backend with existing macOS Swift app
**Reviewers:** architect-reviewer, electron-pro, security-engineer

## Goal

Ship Open Whisperer on Windows and Linux with feature parity (minus hands-free mode), while keeping the native Swift macOS app unchanged. Single monorepo, shared Python server backend.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| macOS app | Keep Swift (unchanged) | Native, fast, working |
| Windows/Linux UI | Electron + React + TypeScript | Cross-platform, single codebase |
| STT/TTS backend | PyTorch Whisper + Kokoro PyTorch | Minimal server code changes, CUDA support |
| Installation | Auto-install on first launch | Same pattern as macOS, zero manual setup |
| Repo structure | Monorepo (`electron/` folder) | Shared server code, one release workflow |
| v1 scope | Everything except hands-free | Hands-free requires SFSpeechRecognizer alternative (Phase 2) |
| v1 Linux scope | X11 only | Wayland text insertion is unstable (Phase 2) |

## Architecture

### Two UI shells, one shared backend

```
OpenWhisperer/
├── app/                    # Swift macOS app (existing, unchanged)
├── electron/               # Electron app (Windows + Linux)
│   ├── src/
│   │   ├── main/           # Main process (tray, server spawn, IPC)
│   │   │   ├── tray.ts             # System tray icon + context menu
│   │   │   ├── server-manager.ts   # Spawn/monitor Python server
│   │   │   ├── setup-manager.ts    # First-launch venv + deps install
│   │   │   ├── hotkey-manager.ts   # Global hotkey registration
│   │   │   ├── ipc-handlers.ts     # IPC bridge between main ↔ renderer
│   │   │   ├── config.ts           # File-based config (mirrors Paths.swift)
│   │   │   └── platform/           # Platform abstraction layer
│   │   │       ├── text-inserter.ts          # Interface
│   │   │       ├── text-inserter-win.ts      # Windows: ffi-napi + SendInput
│   │   │       ├── text-inserter-x11.ts      # Linux X11: xdotool
│   │   │       ├── text-inserter-wayland.ts  # Linux Wayland: wtype (Phase 2)
│   │   │       ├── audio-player.ts           # Interface
│   │   │       ├── audio-player-win.ts       # Windows: ffplay
│   │   │       └── audio-player-linux.ts     # Linux: paplay / ffplay
│   │   ├── renderer/       # React UI
│   │   │   ├── App.tsx             # Root component
│   │   │   ├── SettingsPanel.tsx   # Main popover (mirrors MenuBarView.swift)
│   │   │   ├── Overlay.tsx         # Transcription overlay window
│   │   │   ├── WaveformBar.tsx     # Live waveform display
│   │   │   └── components/         # Shared UI components
│   │   └── preload/
│   │       └── index.ts            # Context bridge (typed API, secure IPC)
│   ├── assets/              # Icons, fonts
│   ├── package.json
│   ├── tsconfig.json
│   ├── electron-builder.yml # Build config for .exe, .AppImage, .deb
│   └── electron-vite.config.ts  # electron-vite (handles main + renderer)
├── servers/
│   └── unified_server.py   # Shared — PyTorch fallback + client-managed mode
├── hooks/
│   ├── tts-hook.sh          # macOS + Linux hook
│   └── tts-hook.js          # Cross-platform Node.js hook (Windows)
├── api/
│   └── openapi.yaml         # Formal API contract (both clients code against this)
├── setup.sh                 # macOS + Linux setup
└── setup.ps1                # Windows setup (or Node.js-based, see Security)
```

### Server API Contract

**Both UI shells code against a formal OpenAPI spec** (`api/openapi.yaml`). The server validates against it. Any endpoint change requires updating the spec first.

Endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `POST /v1/audio/transcriptions` | POST | STT: WAV → `{"text": "...", "should_submit": bool}` |
| `POST /v1/audio/speech` | POST | TTS: text → audio/wav stream |
| `GET /v1/models` | GET | List available STT + TTS models |
| `GET /v1/config/:key` | GET | Read config value (future: replace file reads) |

### Python Server Changes

**Key architectural change (from review):** Move `press_enter()`, `focus_target_app()`, and `kill_tts()` OUT of the server. The server returns structured responses; each client handles keystroke simulation and app focusing natively.

```python
import platform

if platform.system() == "Darwin":
    import mlx_whisper
    from mlx_audio.server import ...
    GPU_TYPE = "metal"
else:
    import whisper
    from kokoro import KPipeline  # PyTorch Kokoro
    import torch
    GPU_TYPE = "cuda" if torch.cuda.is_available() else "cpu"
```

When Electron connects, it sends `client_managed=true` in the transcription request. The server skips `press_enter` and `focus_target_app` — Electron handles those natively. Swift continues using server-side submission for backwards compatibility.

The server response becomes:
```json
{
  "text": "transcribed text here",
  "should_submit": true,
  "language": "en"
}
```

Config path is platform-aware:
- macOS: `~/Library/Application Support/OpenWhisperer/`
- Windows: `%APPDATA%/OpenWhisperer/`
- Linux: `~/.config/OpenWhisperer/`

### Component Mapping: Swift → Electron

| Swift Component | Electron Equivalent | Module |
|----------------|---------------------|--------|
| `MenuBarExtra` (system tray) | `Tray` + `BrowserWindow` popover | `tray.ts` |
| `AudioRecorder` (AVFoundation) | Web Audio API (`AudioWorkletNode`) | Renderer process |
| `HotkeyManager` (NSEvent) | `uiohook-napi` for modifier-only keys | `hotkey-manager.ts` |
| `DictationManager` (AX + CGEvent) | Platform-specific modules (see below) | `platform/text-inserter-*.ts` |
| `TranscriptionOverlay` (NSWindow) | Frameless `BrowserWindow` (with opaque fallback) | `Overlay.tsx` |
| `ServerManager` (Process) | `child_process.spawn()` | `server-manager.ts` |
| `SetupManager` (venv creation) | Node.js script: download uv, create venv, install deps | `setup-manager.ts` |
| `AccessibilityManager` | Not needed on Windows; Linux X11 needs no permission | — |
| `ConfigManager` (file-based) | Same pattern, cross-platform paths | `config.ts` |
| `KeywordDetector` (SFSpeechRecognizer) | **Phase 2** — Vosk or small Whisper model | — |

### Text Insertion Strategy

**`nut-tree/nut.js` is NOT used** (commercial license in v3+, incompatible with open source).

| Platform | Method | Library | Privilege |
|----------|--------|---------|-----------|
| Windows | `SendInput` API | `ffi-napi` + `user32.dll` | None needed (except UAC-elevated windows) |
| Linux X11 | `xdotool type --clearmodifiers` | Child process call | None needed |
| Linux Wayland | **Phase 2** — `wtype` or clipboard fallback | — | TBD |

Tiered approach:
1. Try native keyboard simulation (type Unicode characters)
2. Fall back to clipboard paste (Ctrl+V / Ctrl+Shift+V) if typing fails
3. On Windows, detect UAC-elevated focus and warn user (UIPI blocks cross-integrity SendInput)

Platform abstraction layer:
```typescript
// platform/text-inserter.ts (interface)
export interface TextInserter {
  type(text: string): Promise<void>;
  pressEnter(): Promise<void>;
  isAvailable(): Promise<boolean>;
}
```

Each platform gets its own implementation file. Input is sanitized: control characters (0x00-0x1F except \n) are stripped before insertion. Shell metacharacters are never passed through a shell — always use `spawn()` with array args.

### Audio Recording (Renderer Process)

Uses `AudioWorkletNode` (NOT the deprecated `createScriptProcessor`):

```typescript
// Register worklet
await context.audioWorklet.addModule('audio-processor.js');
const workletNode = new AudioWorkletNode(context, 'audio-recorder');
workletNode.port.onmessage = (e) => { /* buffer PCM frames */ };
source.connect(workletNode);
```

The renderer POSTs directly to `http://localhost:8000/v1/audio/transcriptions` via `fetch()` (avoids unnecessary IPC hop through main process). The server's CORS config already allows localhost origins.

WAV export implements proper header generation matching the Swift `AudioRecorder` (RIFF header, frame clamping, UInt32 overflow protection).

Permission handling: if microphone is denied, show a clear error in the settings panel with instructions per OS.

### Audio Playback

| Platform | TTS Playback | Method |
|----------|-------------|--------|
| Windows | Bundled `ffplay` | Child process |
| Linux | `paplay` with `ffplay` fallback | Child process |
| macOS | `afplay` (Swift app, unchanged) | — |

**Windows hooks:** Since bash doesn't run natively on Windows, TTS hooks are implemented as a Node.js script (`hooks/tts-hook.js`) that the Electron app registers. Same logic as `tts-hook.sh` but cross-platform.

### Transcription Overlay

Frameless `BrowserWindow` with `transparent: true` and `alwaysOnTop: true`.

**Linux Wayland fallback (from review):** Transparent windows frequently fail on GNOME 44+ Wayland (renders as solid black). The overlay detects this at startup and falls back to a semi-opaque background (`rgba(30, 30, 30, 0.92)`) instead of full transparency. POC required before shipping.

### System Tray

**GNOME issue (from review):** GNOME 40+ removed system tray support. The tray icon is invisible without the `AppIndicator` extension.

Mitigation strategy:
1. On first launch, detect GNOME without AppIndicator
2. Show a one-time notification explaining how to install the extension
3. Fall back to a persistent small window (mini-panel) if tray is unavailable
4. Document the GNOME extension requirement in installation instructions

### Config & State

Cross-platform config directory:
- Windows: `%APPDATA%/OpenWhisperer/`
- Linux: `~/.config/OpenWhisperer/`
- macOS: `~/Library/Application Support/OpenWhisperer/` (existing)

**File-based IPC contract** (formalized from review):

| File | Format | Encoding | Locking | Purpose |
|------|--------|----------|---------|---------|
| `ptt_hotkey` | Plain text, single value | UTF-8, no BOM | Write: atomic (temp+rename) | PTT key preference |
| `interaction_mode` | Plain text: `pressToTalk` or `holdToTalk` | UTF-8 | Atomic write | Interaction mode |
| `stt_language` | ISO 639-1 code or `auto` | ASCII | Atomic write | STT language |
| `tts_voice` | Voice ID (e.g. `af_heart`) | ASCII | Atomic write | TTS voice |
| `tts_volume` | Decimal string (e.g. `1`, `0.3`, `4`) | ASCII | Atomic write | Volume level |
| `voice_detail` | `brief`, `natural`, or `detailed` | ASCII | Atomic write | VOICE tag verbosity |
| `auto_focus_app` | App name from allow-list only | UTF-8 | Atomic write | Auto-focus target |
| `auto_submit` | Marker file (empty, existence = enabled) | — | Create/delete | Auto-submit flag |
| `selected_platform` | `claudeCode` or `codexCLI` | ASCII | Atomic write | Platform |
| `server.pid` | Integer PID | ASCII | Atomic write | Server process |
| `server.log` | Append-only log | UTF-8 | Append | Server output |
| `tts_playing.lock` | Marker file | — | Create/delete | TTS playback state |
| `tts_hook.pid` | Integer PID | ASCII | Atomic write | TTS process |

All writes use temp-file-then-rename for atomicity. Electron uses `fs.watch()` on lock files instead of polling.

### Setup Flow (First Launch)

1. Electron detects no `.setup-complete` marker
2. Shows setup progress UI in the settings panel
3. **Check disk space** (need ~8GB: download + installed)
4. **Detect GPU**: run `nvidia-smi` to check CUDA availability
5. Downloads `uv` (or uses bundled copy)
6. Creates venv: `uv venv ~/.openwhisperer/venv --python 3.13 --clear`
7. Installs with correct PyTorch index:
   - CUDA detected: `uv pip install torch --index-url https://download.pytorch.org/whl/cu124`
   - No CUDA: `uv pip install torch` (CPU-only, ~500MB smaller)
8. Installs: `uv pip install openai-whisper kokoro soundfile fastapi uvicorn`
9. Installs spaCy model (required by Kokoro)
10. Writes `.setup-complete` marker
11. Starts Python server

**Windows:** Setup runs via Node.js (not PowerShell) to avoid execution policy issues.
**Progress:** `uv` progress is piped to the setup UI for download feedback.

### Distribution & Code Signing

| Platform | Format | Tool | Signing |
|----------|--------|------|---------|
| Windows | `.exe` (NSIS, perUser) | electron-builder | **EV Authenticode certificate** (required for SmartScreen) |
| Linux | `.AppImage` + `.deb` | electron-builder | GPG-signed releases |
| macOS | Keep `.dmg` (Swift app) | Existing `build-dmg.sh` | Ad-hoc (existing) |

**Windows SmartScreen (from review):** Without an EV code signing certificate ($300-600/yr), Windows blocks the installer. This is a shipping requirement, not optional. Submit signed binary to Microsoft for reputation pre-seeding.

**Auto-update:**
- `electron-updater` pointing to GitHub Releases over HTTPS
- Windows: works with NSIS `perUser` install (no UAC for updates)
- Linux AppImage: works if launched from writable location (`$HOME/Applications/`)
- Linux .deb: notify-only (user re-downloads; document this)
- ASAR integrity checking enabled for production builds

### IPC Flow

```
Renderer (React)                Main Process (Node.js)           Python Server
     │                                │                               │
     │                                ├── hotkey-manager detects PTT  │
     │                                ├── signals renderer            │
     ├── starts AudioWorklet capture  │                               │
     │   ...recording...              │                               │
     ├── fetch() POST /v1/audio/transcriptions ──────────────────────►│
     │                                │                               ├── transcribe
     │◄───────── {"text":"...", "should_submit": true} ───────────────┤
     │                                │                               │
     ├── ipc: 'transcription-result'  │                               │
     │                                ├── text-inserter.type(text)    │
     │                                ├── if should_submit: pressEnter│
     │                                │                               │
     ├── update overlay UI            │                               │
     │                                │                               │
     │   --- Config changes ---       │                               │
     ├── ipc: 'set-config'           │                               │
     │                                ├── atomic write to config file │
     │                                │   (server picks up on next req│
     │                                │                               │
     │   --- Server lifecycle ---     │                               │
     │                                ├── spawn Python on app.ready   │
     ├── ipc: 'server-status'        │   (never from renderer)       │
     │   └── update tray + panel     │                               │
     │                                │                               │
     │   --- TTS state ---           │                               │
     │                                ├── fs.watch('tts_playing.lock')│
     ├── ipc: 'tts-state'           │                               │
     │   └── update overlay          │                               │
```

## Security

### Electron Security Configuration (mandatory)

```typescript
const win = new BrowserWindow({
  webPreferences: {
    nodeIntegration: false,
    contextIsolation: true,
    sandbox: true,
    webSecurity: true,
    allowRunningInsecureContent: false,
    preload: path.join(__dirname, 'preload.js')
  }
});
```

The preload script exposes a minimal typed API via `contextBridge.exposeInMainWorld()`. Raw `ipcRenderer` is never exposed to the renderer.

### Local API Authentication

The Python server generates a random token at startup and writes it to `api_token` in the config directory. Both the Electron app and hooks read this token and pass it as `Authorization: Bearer <token>`. This prevents other local processes from abusing the API.

### Input Sanitization

- Transcribed text is stripped of control characters (0x00-0x1F except \n) before insertion
- Text insertion always uses `spawn()` with array args (never shell strings)
- File extensions on uploads are validated against allow-list (.wav, .mp3, .m4a, .ogg, .flac)
- `auto_focus_app` restricted to allow-list only (regex fallback removed)

### Temp File Security

- Temp directories created with `mkdir -p -m 700`
- PID files written atomically (temp + rename)
- `mktemp` with error guard (cleanup lockfile on failure)

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Desktop framework | Electron 33+ |
| Build tool | electron-vite |
| Renderer | React 19 + TypeScript |
| UI styling | Tailwind CSS |
| Main process | TypeScript (Node.js) |
| Keyboard sim (Win) | `ffi-napi` + `user32.dll` SendInput |
| Keyboard sim (Linux) | `xdotool` (X11), `wtype` (Wayland, Phase 2) |
| Global hotkeys | `uiohook-napi` |
| Audio recording | Web Audio API (`AudioWorkletNode`) |
| STT | OpenAI Whisper (PyTorch) |
| TTS | Kokoro (PyTorch) |
| Server | FastAPI + Uvicorn (shared with macOS) |
| Build/Package | electron-builder |
| Auto-update | electron-updater |
| Code signing (Win) | EV Authenticode certificate |

## What Changes in Existing Code

1. **`servers/unified_server.py`** — PyTorch import fallback + `client_managed` flag to skip press_enter/focus_target_app
2. **`hooks/tts-hook.sh`** — platform fork for audio playback; fix greedy regex in codex-tts-hook.sh
3. **New:** `hooks/tts-hook.js` — Node.js cross-platform hook for Windows
4. **New:** `api/openapi.yaml` — formal API contract
5. **Modified:** `setup.sh` — detect OS, install PyTorch instead of MLX on Linux

## What Stays Unchanged

- `app/` — entire Swift macOS app (untouched)
- Server API endpoint paths and response shapes
- File-based IPC pattern (now formalized)
- `CLAUDE.md`, README voice tag instructions

## v1 Feature Scope

### Included
- System tray with settings popover (all current settings)
- Python server auto-setup + lifecycle management (with GPU detection)
- Press-to-Talk mode
- Hold-to-Talk mode
- STT via PyTorch Whisper (CUDA/CPU)
- TTS via Kokoro PyTorch (CUDA/CPU)
- Text insertion into focused app (Windows + Linux X11)
- Auto-focus + auto-submit (client-side, not server)
- Language picker (17 languages)
- Voice picker (11 Kokoro voices)
- Voice detail level + volume control
- Transcription overlay (with opaque fallback for Wayland)
- Cross-platform TTS hooks (bash + Node.js)
- Platform selector (Claude Code / Codex CLI)
- Auto-apply hooks + voice tags
- Code-signed `.exe` (Windows) and `.AppImage` + `.deb` (Linux)
- Auto-update via GitHub Releases

### Excluded (Phase 2)
- Hands-free mode (Vosk or small Whisper keyword detection)
- Linux Wayland text insertion (`wtype`)
- Linux Wayland transparent overlay (needs compositor-specific work)
- Waveform animation in overlay

## Proof-of-Concept Priority (before implementation)

| # | POC | Risk | Time |
|---|-----|------|------|
| 1 | Transparent overlay on Ubuntu GNOME Wayland | Go/no-go for overlay UX | 2 hrs |
| 2 | `uiohook-napi` modifier-only hotkey on Windows 11 | Validates PTT interaction model | 2 hrs |
| 3 | Tray icon on GNOME without AppIndicator extension | Determines fallback strategy | 1 hr |
| 4 | `ffi-napi` + `SendInput` text insertion on Windows | Validates nut.js replacement | 2 hrs |
| 5 | `AudioWorkletNode` → WAV → server → transcription | Validates audio pipeline e2e | 3 hrs |

## Open Questions (reduced from review)

- Windows EV certificate: which provider? (DigiCert, Sectigo, Azure Trusted Signing)
- CUDA runtime: require user-installed NVIDIA drivers or bundle? (Recommend: require user drivers, detect at setup)
- Modifier-only hotkey fallback: if `uiohook-napi` is unreliable on Windows, use Ctrl+Space as default PTT?
