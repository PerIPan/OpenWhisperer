# Minimal Overlay — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorm with Hakan, 2026-07-13)
**Successor to the rejected notch indicator** (`2026-07-13-notch-status-indicator-design.md`,
PR #24 closed unmerged). The floating overlay stays; it loses all text.

## Problem

After the notch experiment, the floating overlay is confirmed as the right status surface —
but it still carries words: the state label ("Standby" / "Recording…"), the hotkey hint, and
the model-status text with Retry. Hakan wants it reduced to signal only: **waveform + status
dot, no text**.

## Decisions

| Question | Decision |
|---|---|
| Overlay content | **Waveform + status dot only.** State label and hotkey hint removed. |
| Model status (loading / failure + Retry) | **Menubar dropdown row** — the pattern built for the notch branch (closed PR #24, commit `d6951d7`), re-targeted at the overlay's existing `statusText`/`statusIsError`: shown only while non-nil; a Button `"<status> — Retry"` when failed, else a disabled Text; followed by a Divider. |
| Error signal on the overlay | The status dot turns **danger red** while `statusIsError` (words live in the menu). |
| Non-text elements | **Keep:** hands-free silence line, close button, drag-to-move, bottom-right default position, warm surface, `overlay_hidden` flag + menu toggle (unchanged copy: "Show Overlay"). |

## Changes

- `TranscriptionOverlay.swift`:
  - `WaveformBar` loses the `Text(statusText)` label and the recording-hint `Text`; keeps the
    dot + mirrored waveform. The dot gains the `statusIsError → OWColor.danger` override.
    `pttKeyLabel`/`interactionMode` stay published on the overlay (the hint may return
    someday; the properties are cheap and still feed `SilenceProgressBar` gating).
  - `OverlayView` drops the model-status `Label`/Retry block; height shrinks accordingly
    (window stays 240pt wide; content height falls out of the remaining rows).
- `OpenWhispererApp.swift` (`SettingsMenuItems`): add the status row between "Clear History"'s
  Divider and the "Show Overlay" toggle — same structure the notch branch used, reading
  `overlay.statusText` / `overlay.statusIsError` / `overlay.dictationManager?.sttFailed` /
  `retrySTT()`.

## Error handling

Nothing new. The Retry path is the existing `DictationManager.retrySTT()`.

## Testing

- No new Kit logic (pure UI deletion + menu row) — no new check group; both suites must stay
  green.
- Manual smoke: idle dot (green) + calm waveform; recording turns the dot red and animates;
  transcribing amber; speaking gold; hands-free silence line still fills; model-load row +
  Retry appear in the dropdown during a load/failure and vanish when ready; overlay shows a
  red dot while failed; no text anywhere on the overlay; light/dark.

## Non-goals

- Any change to overlay position, dragging, sizing behavior, or the visibility toggle.
- Notch/menu-bar-band UI (rejected — see the predecessor spec).
- Removing `pttKeyLabel`/`interactionMode` plumbing.

## Workflow

Two files, user-visible → PR path: worktree off `main`, suites green, `gh pr create`, merge
gated on the manual smoke.
