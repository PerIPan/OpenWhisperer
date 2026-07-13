# Menubar Transcription History — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorm with Hakan, 2026-07-13)
**Phase 1 of the overlay split.** Phase 2 — a notch-side status indicator replacing the
floating overlay — is parked in `docs/UX-BACKLOG.md` (P2, "Notch status indicator").

## Problem

The transcription overlay does two jobs: it shows live status (waveform, state word,
silence countdown, model progress) and it holds past transcriptions behind a resize grip
that reveals 0–3 click-to-copy rows. The second job fits the menubar dropdown better —
the dropdown today holds only three items, and a clipboard-manager-style list (the Flycut
idiom) is more discoverable and holds more than 3 rows. This spec moves history into the
menu and slims the overlay to a pure status widget.

## Decisions

| Question | Decision |
|---|---|
| Persistence | **Session-only.** In-memory, gone on restart. No transcript ever touches disk. |
| Menu layout | **Inline section** at the top of the dropdown, newest first. |
| Overlay transcript rows | **Removed**, along with the resize grip. |
| State owner | **New dedicated store** (not `DictationManager`, not the overlay). |
| Click action | **Copy full text to the clipboard** — parity with today's overlay rows. Typed insertion still never touches the clipboard; this is an explicit user action. |

## Menu structure

```
Recent Transcriptions          (disabled header)
fix the race in the tts serv…  (up to 10 rows, newest first, click = copy)
add a menubar toggle for the…
— or, when empty —
No transcriptions yet          (disabled)
────────────────────────────
Clear History                  (disabled when empty)
────────────────────────────
✓ Show Overlay                 (existing items, unchanged)
Settings…                  ⌘,
────────────────────────────
Quit OpenWhisperer         ⌘Q
```

- Rows show a single-line label: newlines collapsed to spaces, trimmed, tail-truncated
  to 50 characters (49 + `…`). Clicking copies the **full untruncated** text to
  `NSPasteboard.general`.
- The store keeps 50 entries; the menu shows the 10 newest. The larger cap matches
  today's overlay buffer, costs nothing, and leaves room for a future "show more".
- No ⌘0–⌘9 shortcuts. Flycut needs them because a hotkey summons it; our menu is
  mouse-opened. Add them only if asked.

## Architecture

Two units, one wire:

1. **`TranscriptHistoryBuffer`** (struct, `OpenWhispererKit`) — pure, testable logic:
   - `mutating func append(_ text: String)` — trims; ignores empty/whitespace-only
     input; prepends; evicts beyond `maxEntries = 50`.
   - `var items: [String]` — newest first, full text.
   - `static func menuLabel(_ text: String, limit: Int = 50) -> String` — collapse
     newlines, trim, truncate on `Character` (grapheme) boundaries with a trailing `…`.
2. **`TranscriptionHistory`** (`@MainActor final class …: ObservableObject`, app target)
   — ~20 lines: wraps the buffer, `@Published private(set) var items`, exposes
   `clear()`. `AppDelegate` owns it and subscribes it to
   `DictationManager.$lastTranscription` — the same feed `TranscriptionOverlay.wireStatus()`
   consumes today.

`SettingsMenuItems` (in `OpenWhispererApp.swift`) receives the store through its
initializer — the pattern `MenuBarStatusIcon(dictation:server:)` already uses — and
renders the section.

**Why not `DictationManager`:** history is a presentation policy (keep 50, show 10,
truncate) and nothing in the dictation pipeline reads it. `DictationManager` lives in the
app target, so logic there is untestable under CLT. The dedicated store keeps the logic
in Kit and leaves nothing to untangle when phase 2 replaces the overlay.

## Overlay slimming

Remove from `TranscriptionOverlay.swift`:

- the transcript rows (`OverlayLineRow`) and the `lines` storage + its
  `$lastTranscription` subscription,
- the resize grip and `maxTranscriptLines`,
- the `Paths.overlayLines` read/write.

Keep: waveform + status word, hands-free silence bar, model-loading/failure text, close
button. The window becomes fixed-size (240×64). `ConfigManager` deletes the orphaned
`overlay_lines` file on launch, next to `migrateVoiceDetailToTtsStyle()`.

## Error handling

Nothing new: no disk, no network. Clipboard writes use `NSPasteboard` as today.

## Testing

- **`OpenWhispererKitTests`** — new check group `transcriptHistoryBufferFailures()`
  registered in the runner: cap eviction at 50; newest-first order; empty and
  whitespace-only input ignored; label truncation (short unchanged, exactly-50 unchanged,
  51 chars → 49 + `…`, newline collapsing, emoji/grapheme not split).
- **Manual smoke** (signed build via `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh`):
  dictate → row appears; click → clipboard holds full text; Clear empties and disables;
  overlay shows status only, no grip; menu renders in light and dark.

## Non-goals

- Persistence across restarts (decided against — privacy posture stays "nothing on disk").
- Search, pinning, or per-row delete.
- The notch status indicator (phase 2, backlogged).
- Any change to dictation, typing, or TTS behavior.

## Workflow

Multi-file, user-visible → PR path: worktree off `main`, both test targets green,
`gh pr create`.
