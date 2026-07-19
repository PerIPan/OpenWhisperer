# Restore the branded popover settings UI (revert the native Settings window)

**Date:** 2026-07-19
**Status:** Approved by user. Reverses the 2026-07-08 native-settings redesign
([`2026-07-08-native-settings-window-design.md`](2026-07-08-native-settings-window-design.md)).

## Why (don't re-litigate this back)

The native tabbed `Settings` window shipped in 1.10.0 is technically cleaner (~940 fewer lines,
native a11y/dark-mode for free) but the user finds it **"super blunt" — it lost the app's identity.**
The pre-1.10 branded popover (warm cream/gold cards, Fraunces, custom controls) *was* the product's
character. Decision: **bring the branded popover back, stay on 1.10**, keep every 1.10 feature
(Parakeet STT, custom vocabulary, the overlay + analyzer styles). This trades the redesign's
maintenance win back for identity — an explicit, eyes-open call.

## Scope

- **Restore** the branded popover as the live settings surface.
- **Keep untouched:** the overlay and its analyzer styles, Parakeet STT, TTS, hooks, all prefs/IPC.
- **Drop:** transcription history from the settings surface (user: drop it). It stays out of the
  popover. (The menu-dropdown history goes away with the dropdown menu.)
- **Defer:** pruning individual old cards the user may not want back — decided later, restore all
  for now.

## Approach

Resurrect from `eb7ae37^` (`211001f`) — the last commit where the branded popover was the *live*
UI (before `eb7ae37 feat(ui): change menu bar extra to dropdown menu…`). It's newer than v1.6.0, so
less manager-API drift.

### Phase 1 — branded shell
- Restore `MenuBarView.swift` (1960 lines) + its branded controls (`OWCard`, `OWCollapsibleCard`,
  `OWMenuPicker`, `OWGroupedMenuPicker`, `OWAppPicker`, `OWCheckbox`, `OWInfoTip`, button styles,
  `ModernStatusRow`, `PortField`, …) from `eb7ae37^`.
- **`OWColor` merge (only real collision):** Theme.swift now owns a *reduced* `OWColor` (12
  members) that the overlay uses. The old view needs 22. Merge the 11 missing members
  (`accentDeep, cardBackground, checkboxBorder, divider, muted, onAccent, pickerBg, pickerBorder,
  pillBackground, success, surface`) into Theme.swift's `OWColor`, **keeping current values for any
  member the overlay reads** so the overlay's appearance does not change. Strip the duplicate
  `OWColor` from the restored file. `OWFont` is currently undefined → restores cleanly.
- Rewire `OpenWhispererApp.swift`: `MenuBarExtra { MenuBarView() }.menuBarExtraStyle(.window)`;
  remove the `Settings { SettingsView() }` scene and the dropdown `openSettings` menu items.
- Restore the deleted `Paths.setupCardExpanded / voiceSettingsCardExpanded / serverCardExpanded`.
- Delete `app/Sources/OpenWhisperer/Settings/` (retire the tabs). Only `OpenWhispererApp.swift`
  references them, so removal is contained.

### Phase 2 — re-wire to current managers
Fix any compile drift between `eb7ae37^` and `main` (manager APIs, pref names). Persistence is the
same Application-Support flat-file bus both UIs already use, so no data migration.

### Phase 3 — port post-1.6 controls into branded cards
The resurrected view predates two settings controls; re-add them as branded cards:
- **Custom vocabulary editor** (from `InputTab`) → a branded card (debounced save + flush-on-close).
- **Overlay analyzer-style picker** → a branded picker (user is keeping the overlay).
Transcription history: **not** ported (dropped per decision).

### Phase 4 — verify
`swift build -c release`, `OpenWhispererKitTests`, `HookTests`, package the `.app`. Visual/interaction
check is **user-run** (CLT-only box, no GUI verification here). PR with this spec.

## Risks
- Large file resurrection → iterative compile-fix expected.
- Micro color drift on shared `OWColor` members (overlay values win); branded *structure* is the
  identity, fine-tune later.
- No automated GUI test — relies on user smoke-test of the popover.

## Success criteria
Clicking the menubar icon opens the warm branded popover again (not a blunt system window); every
1.10 setting is reachable; the overlay and analyzer styles are unchanged.
