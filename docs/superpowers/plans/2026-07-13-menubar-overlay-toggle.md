# Menubar "Show Overlay" Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the overlay show/hide control from Settings → Input into the menubar dropdown as a checkmark item, and persist visibility across launches.

**Architecture:** The floating status window is `TranscriptionOverlay.shared` (an `ObservableObject` singleton with `@Published isVisible`). A SwiftUI `Toggle` in the `.menu`-style `MenuBarExtra` renders as a native checkmark menu item and binds to the same `show()`/`hide()` methods the Settings toggle uses today. Persistence follows the app's flag-file convention: an `overlay_hidden` file in Application Support (exists = stay hidden; absent = show on launch, the default), written/removed inside `hide()`/`show()` so every deliberate visibility change — menu toggle or the overlay's X button — persists through one code path.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, SwiftPM (build from `app/`), no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-13-menubar-overlay-toggle-design.md`

## Global Constraints

- macOS 14+, Apple Silicon; Command Line Tools only — **no XCTest**. Test runners are plain executables: `swift run OpenWhispererKitTests` and `swift run HookTests` (both `exit(1)` on failure), run from `app/`.
- **No new unit tests in this plan.** All changed code is AppKit/SwiftUI UI wiring plus two one-line `FileManager` calls; per AGENTS.md only pure logic in `OpenWhispererKit` is unit-testable, and none of this qualifies. Verification is build + existing suites + a scripted manual pass (Task 3).
- User-facing name is **"Show Overlay"** (the window is "the overlay" in copy).
- Flag-file convention (matches `auto_submit`): file contains `"on"`, existence is the signal, removal disables.
- Commits: Conventional Commits, imperative, subject ≤72 chars including `type(scope):` prefix. No Co-Authored-By/tool attribution.
- Workflow: PR path. Execute from a worktree created via `git worktree add .claude/worktrees/menubar-overlay-toggle -b menubar-overlay-toggle` (or the superpowers:using-git-worktrees skill). All `swift` commands run from `<worktree>/app/`.

---

### Task 1: Persist overlay visibility (`overlay_hidden` flag)

**Files:**
- Modify: `app/Sources/OpenWhisperer/Paths.swift` (after the `overlayLines` declaration, ~line 89)
- Modify: `app/Sources/OpenWhisperer/TranscriptionOverlay.swift:98` (`show()`) and `:166` (`hide()`)
- Modify: `app/Sources/OpenWhisperer/AppDelegate.swift:120-121`

**Interfaces:**
- Consumes: `Paths.appSupport` (existing), `TranscriptionOverlay.shared.show()/hide()` (existing).
- Produces: `Paths.overlayHidden: URL` — the flag file. `show()` removes it, `hide()` writes it. Task 2's menu toggle gets persistence for free by calling these methods.

- [ ] **Step 1: Add the flag path to `Paths.swift`**

Insert directly below the existing `overlayLines` declaration:

```swift
    /// Overlay visibility flag — present when the user hid the floating overlay
    /// (menu toggle off, or the overlay's X button). Absent = show on launch.
    static let overlayHidden = appSupport.appendingPathComponent("overlay_hidden")
```

- [ ] **Step 2: Persist in `TranscriptionOverlay.show()` and `hide()`**

At the very top of `func show()` (before the `if let w = window` early-return branch, so both the re-front and first-construction paths persist):

```swift
        try? FileManager.default.removeItem(at: Paths.overlayHidden)
```

At the very top of `func hide()`:

```swift
        try? "on".write(to: Paths.overlayHidden, atomically: true, encoding: .utf8)
```

Do **not** touch `windowWillClose(_:)` — it also fires during app teardown, and persisting there could record "hidden" on quit. Only the two deliberate methods persist.

- [ ] **Step 3: Gate the launch-time show in `AppDelegate`**

Replace:

```swift
        // Show transcription overlay by default on launch
        TranscriptionOverlay.shared.show()
```

with:

```swift
        // Show the overlay on launch unless the user hid it last session
        // (overlay_hidden flag — maintained by TranscriptionOverlay.show()/hide()).
        if !FileManager.default.fileExists(atPath: Paths.overlayHidden.path) {
            TranscriptionOverlay.shared.show()
        }
```

- [ ] **Step 4: Build and run the suites**

Run from `app/`:

```bash
swift build && swift run OpenWhispererKitTests && swift run HookTests
```

Expected: build succeeds; both runners print their pass summaries and exit 0.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/Paths.swift app/Sources/OpenWhisperer/TranscriptionOverlay.swift app/Sources/OpenWhisperer/AppDelegate.swift
git commit -m "feat(overlay): persist visibility across launches"
```

---

### Task 2: Menubar "Show Overlay" toggle; remove the Settings toggle

**Files:**
- Modify: `app/Sources/OpenWhisperer/OpenWhispererApp.swift:76-94` (`SettingsMenuItems`)
- Modify: `app/Sources/OpenWhisperer/Settings/InputTab.swift:6` and `:90-93`

**Interfaces:**
- Consumes: `TranscriptionOverlay.shared` (`@Published isVisible`, `show()`, `hide()` — persistence from Task 1 rides along automatically).
- Produces: user-visible menu item only; nothing downstream consumes it.

- [ ] **Step 1: Add the toggle to `SettingsMenuItems`**

Replace the whole struct with:

```swift
/// Menubar menu content.
private struct SettingsMenuItems: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    var body: some View {
        Toggle("Show Overlay", isOn: Binding(
            get: { overlay.isVisible },
            set: { $0 ? overlay.show() : overlay.hide() }
        ))

        Divider()

        Button("Settings...") {
            // Activate the app to bring the Settings window to the front
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit OpenWhisperer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
```

(In a `.menu`-style `MenuBarExtra`, `Toggle` renders as a checkmark menu item; menus re-evaluate on each open, so the checkmark tracks closes made via the overlay's X button.)

- [ ] **Step 2: Remove the Settings toggle from `InputTab.swift`**

Delete the property on line 6:

```swift
    @ObservedObject private var overlay = TranscriptionOverlay.shared
```

Delete the toggle block (lines 90–93) and its preceding blank line:

```swift
            Toggle("Show transcription overlay", isOn: Binding(
                get: { overlay.isVisible },
                set: { $0 ? overlay.show() : overlay.hide() }
            ))
```

Confirm no references to the removed property remain: `rg -n '\boverlay\.' app/Sources/OpenWhisperer/Settings/InputTab.swift` → no matches. (Unrelated `TranscriptionOverlay.shared.pttKeyLabel` writes remain in the file.)

- [ ] **Step 3: Build and run the suites**

Run from `app/`:

```bash
swift build && swift run OpenWhispererKitTests && swift run HookTests
```

Expected: build succeeds; both runners exit 0.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/OpenWhisperer/OpenWhispererApp.swift app/Sources/OpenWhisperer/Settings/InputTab.swift
git commit -m "feat(overlay): move show toggle into menubar menu"
```

---

### Task 3: Packaged manual verification + PR

**Files:**
- None created/modified — packaging, verification, PR.

**Interfaces:**
- Consumes: Tasks 1–2 committed on the `menubar-overlay-toggle` branch.
- Produces: an open PR against `main`.

- [ ] **Step 1: Build and install the signed bundle**

Run from the worktree's `app/` (stable dev cert so TCC grants survive):

```bash
OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh
killall OpenWhisperer || true
rm -rf /Applications/OpenWhisperer.app
cp -R .build/OpenWhisperer.app /Applications/
open /Applications/OpenWhisperer.app
```

- [ ] **Step 2: Manual pass (user at the keyboard — pause and ask)**

1. Menubar dropdown shows **Show Overlay** with a checkmark; clicking it hides the overlay, clicking again re-shows it.
2. Close the overlay via its X → reopen the dropdown → the checkmark is gone.
3. With the overlay hidden, quit and relaunch → overlay stays hidden (`~/Library/Application Support/OpenWhisperer/overlay_hidden` exists). Toggle on, quit, relaunch → overlay shows and the flag file is gone.
4. Settings → Input no longer offers an overlay toggle.

- [ ] **Step 3: Push and open the PR**

```bash
git fetch origin && git rebase origin/main
git push -u origin menubar-overlay-toggle
gh pr create --title "feat(overlay): menubar Show Overlay toggle with persistence" --body "$(cat <<'EOF'
## Summary
- Add a native checkmark "Show Overlay" item to the menubar dropdown
- Remove the Settings → Input overlay toggle (single home in the menu)
- Persist visibility across launches via an `overlay_hidden` flag file (X button and menu toggle share the `show()`/`hide()` path)

Spec: docs/superpowers/specs/2026-07-13-menubar-overlay-toggle-design.md

## Test plan
- [x] `swift run OpenWhispererKitTests` / `swift run HookTests`
- [x] Manual: toggle both ways, X-button sync, persistence across relaunch, Settings toggle gone
EOF
)"
```

- [ ] **Step 4: After merge — cleanup**

```bash
git -C /Users/hakanensari/code/OpenWhisperer pull --ff-only
git worktree remove .claude/worktrees/menubar-overlay-toggle
git branch -d menubar-overlay-toggle
```
