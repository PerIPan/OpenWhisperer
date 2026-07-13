# Menubar "Show Overlay" toggle — design

**Date:** 2026-07-13
**Status:** Approved (pending spec review)

## Problem

The floating status window (`TranscriptionOverlay` — waveform, standby/recording state,
transcript lines) opens on launch and has an X close button, but the only way to reopen
it is buried in Settings → Input. The user wants a quick toggle in the menubar dropdown,
like Tailscale's connect switch. Additionally, closing the overlay does not persist: the
app re-shows it on every launch, so a user who prefers it hidden must close it each time.

## Decisions

- **UI name:** the window is called the **overlay** in user-facing copy ("Show Overlay").
  Shorter than "transcription overlay", unambiguous (the app has exactly one floating
  window), and still findable against the `TranscriptionOverlay` code name.
- **Style: native checkmark menu item**, not a Tailscale-style sliding switch. The
  dropdown is a `.menu`-style `MenuBarExtra`; a SwiftUI `Toggle` there renders as a
  checkmark item. A real switch would require `.menuBarExtraStyle(.window)` and a fully
  custom panel (hand-rolled Settings/Quit rows, hover/dismiss behavior) — rejected as
  disproportionate to the feature.
- **Single home: the menu item replaces the Settings toggle.** The "Show transcription
  overlay" toggle in Settings → Input is removed, not renamed — one control, one place.
- **Visibility persists across launches** (user amendment). With the toggle now the only
  control, re-showing the overlay on every launch would fight the user's choice.

## Changes

1. **`OpenWhispererApp.swift` — `SettingsMenuItems`:** add
   `Toggle("Show Overlay", isOn:)` as the first menu item, then a divider, then the
   existing Settings…/Quit items. Binding observes `TranscriptionOverlay.shared`
   (`@Published isVisible`): on → `show()`, off → `hide()` — the same binding the
   removed Settings toggle used.
2. **`Settings/InputTab.swift`:** delete the "Show transcription overlay" `Toggle`
   (lines 90–93) and the now-unused `@ObservedObject overlay` property (line 6). No
   other references exist in the file.
3. **Persistence — `overlay_hidden` flag file** in Application Support, following the
   existing flag-file convention (`auto_submit`: exists = on, absent = off; inverted
   here because the default is *shown*):
   - `Paths.swift`: add `static let overlayHidden = appSupport.appendingPathComponent("overlay_hidden")`.
   - `TranscriptionOverlay.hide()` writes the flag (`"on"`); `show()` removes it. Both
     the menu toggle and the overlay's X button funnel through these two methods, so
     every deliberate visibility change persists.
   - `AppDelegate` launch: show the overlay only when the flag is absent (replaces the
     unconditional `TranscriptionOverlay.shared.show()`).

## Non-goals

- No keyboard shortcut, no menu icon.
- No change to what the overlay displays or how it resizes.
- `windowWillClose` bookkeeping stays as is — persistence hooks only into the
  deliberate `show()`/`hide()` calls, so an app-quit teardown can never accidentally
  persist "hidden".

## Verification

Pure AppKit/SwiftUI — nothing lands in the unit-testable `OpenWhispererKit` target.
Manual pass after `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh` + install:

1. Menu toggle hides and re-shows the overlay; checkmark tracks state.
2. Closing via the overlay's X unchecks the menu item.
3. Toggle off → relaunch app → overlay stays hidden; toggle on → relaunch → shown.
4. Settings → Input no longer offers the toggle.

## Workflow

Small, self-contained UI change (3 files, no deps, no logic in Kit) — per AGENTS.md
this could go either way; with launch-behavior change and multiple files it takes the
**PR path** from a `.claude/worktrees/` worktree.
