# Native Settings Window — Design

**Date:** 2026-07-08
**Status:** Approved (user picked "fully native" + the 5-tab map; goal: ship)

## Problem

The settings UI is one 310-pt-wide branded scroll of custom cards (`MenuBarView.swift`, 84 KB)
shown in a plain `Window` scene. It reads as a popover, not a Mac settings window: custom
pickers/checkboxes, collapsible cards hiding core settings, and an information architecture the
UX backlog already flags (merge Voice Input/Voice Settings, label clarity, overlay toggle
placement). The user wants a standard macOS Settings window — toolbar tabs + native grouped
forms, like Tailscale/CopyClip.

## Decision

Fully native. No in-window branding: system colors, system fonts, native controls. The brand
stays on the website and the overlay.

### Scene mechanics

- Replace `Window("OpenWhisperer Settings", id: "settings")` with a **`Settings` scene**.
- A `TabView` inside a Settings scene renders native **toolbar tabs** (icon + label) for free.
- Each tab is a `Form` with **`.formStyle(.grouped)`** — the modern System Settings look.
- The menubar "Settings…" button becomes a **`SettingsLink`** (macOS 14+). *Deviation
  from the first draft (implementation finding):* a plain `Button` + `openSettings`
  environment action silently fails to present the window for an accessory
  (`LSUIElement`) app — macOS gates Settings-scene presentation on app activation, which
  synthetic/inactive contexts are denied. `SettingsLink` handles presentation and
  activation internally. ⌘, keyboard shortcut unchanged.
- Fixed content width ~500 pt per tab; height varies per tab (standard settings behavior,
  `windowResizability` handled by the scene).

### Tab map

| Tab | Icon (SF Symbol) | Contents |
|---|---|---|
| General | `gearshape` | Launch at login (Toggle) · Permissions rows: Accessibility, Microphone, Speech Recognition (hands-free only) with status + "Open Settings…" · first-run status section (below) · version footer |
| Input | `mic` | Mode picker + description footnote · PTT key picker (hidden in hands-free) · "Auto-submit after N s of silence" (hands-free only) · live state row (Ready/Recording/Transcribing dot) · mic-grant button when permission missing · PTT-restart + error notices · "Show transcription overlay" Toggle · **Language** picker (renamed from "Dictate in") · Vocabulary editor + footnote · **App Focus** section: auto-focus Toggle + app picker + custom-name field, "Press Enter after inserting" (was "auto-submit"), "Return to previous app" (was "with return"), behavior-hint footnote |
| Voice | `speaker.wave.2` | Voice picker (sectioned by language) · Speed slider · Volume slider · **Reply detail** (was "Style": Terse/Normal/Rich/Full) · **Speak replies** (when Voice / Always) |
| Agents | `wand.and.stars` | Platform picker (Claude Code / Codex / Pi / Antigravity) · Auto-Apply hook button with applied state, per-platform help, apply feedback, hook-instructions link |
| Advanced | `wrench.and.screwdriver` | Model status rows (Whisper STT / Kokoro TTS) · Start/Stop server · Port (editable only when stopped) · "Server reachable" row · Delete downloaded models (keeps `NSAlert` confirm) · Server Log / Events Log / Copy Diagnostics |

### First-run signals

The old setup-progress card and model-loading banner become a conditional section at the top
of **General** (progress bar while `SetupManager` is `.inProgress`, error + Retry on `.failed`;
model-loading row while STT/TTS load, error + Retry on STT failure). The menubar hourglass icon
already covers the always-visible signal; Advanced always shows the model status rows.

## Zero behavior change

All persistence carries over verbatim: every `.onChange` flat-file write to the Application
Support bus, the `onAppear` pref loads, the off-main `SMAppService.mainApp.status` check, the
0.5 s debounced vocabulary save **with flush-on-disappear**, `NSAlert` for destructive confirms,
and the slider bounds contracts (`TTSSpeed` 0.7–1.5, `TTSVolume` 0.3–2.0 — **the `Slider`
ranges MUST stay equal to the pure-Kit min/max**). Renamed labels change UI text only, never
file names or values.

Deletions (written-never-read today, GUI-only):
- `Paths.setupCardExpanded`, `Paths.voiceSettingsCardExpanded`, `Paths.serverCardExpanded`
  and the writes to them (the collapsible cards are gone; nothing else reads these files).

## Code structure

- New `app/Sources/OpenWhisperer/Settings/`:
  - `SettingsView.swift` — the `TabView`, shared environment objects.
  - `GeneralTab.swift`, `InputTab.swift`, `VoiceTab.swift`, `AgentsTab.swift`,
    `AdvancedTab.swift` — one file per tab, each owning its `@State` + load-on-appear +
    write-on-change (same pattern as today; no new view-model layer).
  - `SettingsRows.swift` — small shared helpers (permission/status row, port field).
- **Delete `MenuBarView.swift`** and all its custom controls (`OWCard`, `OWCollapsibleCard`,
  `OWMenuPicker`, `OWGroupedMenuPicker`, `OWAppPicker`, `OWCheckbox`, `OWPickerRow`,
  `OWInfoTip`, button styles, `ModernStatusRow`, `ModernDiagnosticRow`, `InlineBadge`,
  `PortField`, …). The searchable app picker is rebuilt natively (Picker with favorites +
  installed apps + custom entry, same `FocusTarget` tagging).
- **Move `OWColor` into `Theme.swift`** — `TranscriptionOverlay` still uses it. `OWFont` and
  `registerBundledFonts` are kept only if the overlay (or anything else) still consumes them;
  otherwise deleted (verify with grep at implementation time).
- `OpenWhispererApp.swift`: `Settings` scene + `SettingsLink`; menubar menu and
  `MenuBarStatusIcon` untouched.

## Out of scope

- The UX-backlog P0 first-run checklist card (this design only relocates existing signals).
- Per-project hooks, menubar icon states, any hook/`OpenWhispererKit` change.
- The transcription overlay (keeps its brand styling).

## Testing

Pure-logic targets are unaffected, but run both suites anyway (`swift run
OpenWhispererKitTests`, `swift run HookTests`). UI is verified by building and launching the
app and eyeballing each tab; behavior parity is verified by checking the flat-file bus
(`~/Library/Application Support/OpenWhisperer`) after toggling representative settings from
each tab.
