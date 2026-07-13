# Menubar Transcription History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move transcription history from the floating overlay into a clipboard-manager-style section of the menubar dropdown, and slim the overlay to a pure status widget.

**Architecture:** A pure `TranscriptHistoryBuffer` (cap, order, menu-label truncation) lands in `OpenWhispererKit` where it is unit-testable; a thin `TranscriptionHistory` ObservableObject in the app target subscribes to `DictationManager.$lastTranscription` and feeds `SettingsMenuItems`. The overlay loses its transcript rows, resize grip, and `overlay_lines` pref.

**Tech Stack:** Swift/SwiftUI (MenuBarExtra menu-style), Combine, plain-executable test runner (no XCTest — Command Line Tools only).

**Spec:** `docs/superpowers/specs/2026-07-13-menubar-transcription-history-design.md`

## Global Constraints

- All Swift commands run from `app/` (the SwiftPM package root).
- Work in a worktree off `main` at `.claude/worktrees/menubar-history` (branch `menubar-history`) — never branch in place. Create it via the `superpowers:using-git-worktrees` skill (or `git worktree add .claude/worktrees/menubar-history -b menubar-history`).
- No XCTest. Kit checks are functions returning `[String]` failures, registered in `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift`; run with `swift run OpenWhispererKitTests`.
- History is **session-only**: no history data is ever written to disk.
- Buffer keeps **50** entries; the menu shows the **10** newest; menu labels truncate to **50** characters (49 + `…`).
- Commits: Conventional Commits, imperative, subject hard cap 72 chars including `type(scope):`. No `Co-Authored-By`. End each commit body with the trailer line `Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5`.

---

### Task 1: `TranscriptHistoryBuffer` (Kit, TDD)

**Files:**
- Create: `app/Sources/OpenWhispererKit/TranscriptHistoryBuffer.swift`
- Create: `app/Tests/OpenWhispererKitTests/TranscriptHistoryBufferChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` (register the check group)

**Interfaces:**
- Consumes: nothing.
- Produces (Tasks 2 and 3 rely on these exact signatures):
  - `public struct TranscriptHistoryBuffer` with `public static let maxEntries = 50`
  - `public private(set) var items: [String]` — newest first, trimmed, full text
  - `public init()`
  - `public mutating func append(_ text: String)`
  - `public mutating func clear()`
  - `public static func menuLabel(_ text: String, limit: Int = 50) -> String`

- [ ] **Step 1: Write the failing checks**

Create `app/Tests/OpenWhispererKitTests/TranscriptHistoryBufferChecks.swift`:

```swift
import OpenWhispererKit

/// Checks for `TranscriptHistoryBuffer` — the session-only history behind the menubar
/// dropdown's "Recent Transcriptions" section. Cap and order here MUST match what the
/// menu assumes (50 kept, newest first, 50-char labels).
func transcriptHistoryBufferFailures() -> [String] {
    var failures: [String] = []

    func expect(_ condition: Bool, _ name: String, _ detail: String) {
        if !condition { failures.append("TranscriptHistoryBuffer.\(name): \(detail)") }
    }

    // Newest first.
    var buf = TranscriptHistoryBuffer()
    buf.append("first")
    buf.append("second")
    expect(buf.items == ["second", "first"], "newestFirst", "got \(buf.items)")

    // Stored text is trimmed.
    buf = TranscriptHistoryBuffer()
    buf.append("  hello \n")
    expect(buf.items == ["hello"], "trims", "got \(buf.items)")

    // Empty / whitespace-only input is ignored.
    buf = TranscriptHistoryBuffer()
    buf.append("")
    buf.append("   \n\t")
    expect(buf.items.isEmpty, "ignoresEmpty", "got \(buf.items)")

    // Cap: 55 appends keep the 50 newest.
    buf = TranscriptHistoryBuffer()
    for i in 1...55 { buf.append("entry \(i)") }
    expect(buf.items.count == 50, "capCount", "got \(buf.items.count)")
    expect(buf.items.first == "entry 55", "capNewest", "got \(buf.items.first ?? "nil")")
    expect(buf.items.last == "entry 6", "capOldest", "got \(buf.items.last ?? "nil")")

    // Clear empties.
    buf.clear()
    expect(buf.items.isEmpty, "clear", "got \(buf.items)")

    // menuLabel: short and exactly-at-limit strings pass through unchanged.
    let fifty = String(repeating: "a", count: 50)
    expect(TranscriptHistoryBuffer.menuLabel("hi") == "hi", "labelShort",
           "got \(TranscriptHistoryBuffer.menuLabel("hi"))")
    expect(TranscriptHistoryBuffer.menuLabel(fifty) == fifty, "labelAtLimit",
           "got \(TranscriptHistoryBuffer.menuLabel(fifty))")

    // menuLabel: one over the limit → 49 chars + ellipsis (50 total).
    let fiftyOne = String(repeating: "a", count: 51)
    let truncated = TranscriptHistoryBuffer.menuLabel(fiftyOne)
    expect(truncated == String(repeating: "a", count: 49) + "…", "labelTruncates", "got \(truncated)")
    expect(truncated.count == 50, "labelTruncatedCount", "got \(truncated.count)")

    // menuLabel: newlines (incl. CRLF) collapse to single spaces; result is trimmed.
    expect(TranscriptHistoryBuffer.menuLabel("a\nb\r\nc\r") == "a b c", "labelNewlines",
           "got \(TranscriptHistoryBuffer.menuLabel("a\nb\r\nc\r"))")

    // menuLabel: truncation counts grapheme clusters — a multi-scalar emoji never splits.
    let family = String(repeating: "👨‍👩‍👧‍👦", count: 60)
    let emojiLabel = TranscriptHistoryBuffer.menuLabel(family)
    expect(emojiLabel.count == 50, "labelEmojiCount", "got \(emojiLabel.count)")
    expect(emojiLabel == String(repeating: "👨‍👩‍👧‍👦", count: 49) + "…", "labelEmojiBoundary",
           "truncation split a grapheme cluster")

    return failures
}
```

- [ ] **Step 2: Register the check group**

In `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift`, after the line `failures += ttsVoiceRegistryFailures()` add:

```swift
        failures += transcriptHistoryBufferFailures()
```

- [ ] **Step 3: Run to verify it fails**

Run (from `app/`): `swift run OpenWhispererKitTests`
Expected: **build error** — `cannot find 'TranscriptHistoryBuffer' in scope` (with no XCTest, the red step is a compile failure).

- [ ] **Step 4: Write the implementation**

Create `app/Sources/OpenWhispererKit/TranscriptHistoryBuffer.swift`:

```swift
import Foundation

/// Session-only buffer behind the menubar "Recent Transcriptions" section.
/// Pure logic (cap, order, menu-row truncation) so it stays testable under CLT;
/// the app-side `TranscriptionHistory` store owns an instance and feeds SwiftUI.
public struct TranscriptHistoryBuffer {
    /// Entries kept in memory. The menu shows fewer (its choice); the larger cap
    /// matches the old overlay buffer and leaves room for a future "show more".
    public static let maxEntries = 50

    /// Stored transcriptions — newest first, trimmed, full (untruncated) text.
    public private(set) var items: [String] = []

    public init() {}

    /// Prepend a transcription. Whitespace-only input is dropped.
    public mutating func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(trimmed, at: 0)
        if items.count > Self.maxEntries {
            items.removeLast(items.count - Self.maxEntries)
        }
    }

    public mutating func clear() {
        items.removeAll()
    }

    /// Single-line menu-row label: newlines collapse to spaces, the result is trimmed
    /// and tail-truncated to `limit` characters (grapheme clusters, so multi-scalar
    /// emoji never split), the last one an ellipsis.
    public static func menuLabel(_ text: String, limit: Int = 50) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit >= 1, flattened.count > limit else { return flattened }
        return flattened.prefix(limit - 1) + "…"
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run (from `app/`): `swift run OpenWhispererKitTests`
Expected: `✅ OpenWhispererKit: all checks passed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenWhispererKit/TranscriptHistoryBuffer.swift \
        Tests/OpenWhispererKitTests/TranscriptHistoryBufferChecks.swift \
        Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
git commit -m "feat(history): add TranscriptHistoryBuffer to Kit" \
  -m "Pure cap/order/truncation logic for the menubar history section,
unit-tested under CLT per the Kit convention.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 2: `TranscriptionHistory` store + AppDelegate wiring

**Files:**
- Create: `app/Sources/OpenWhisperer/TranscriptionHistory.swift`
- Modify: `app/Sources/OpenWhisperer/AppDelegate.swift:17` (property) and `:118` (wiring)

**Interfaces:**
- Consumes: `TranscriptHistoryBuffer` (Task 1), `DictationManager.$lastTranscription` (`@Published var lastTranscription: String`, exists at `DictationManager.swift:21`).
- Produces (Task 3 relies on): `final class TranscriptionHistory: ObservableObject` with `@Published private(set) var items: [String]`, `func wire(to dictation: DictationManager)`, `func clear()`; `AppDelegate.transcriptionHistory` instance property.

Note: the spec sketched `@MainActor` on this class. Dropped: `AppDelegate.setupDictation()` is nonisolated, and the repo pattern (`TranscriptionOverlay`) is a plain ObservableObject with `.receive(on: DispatchQueue.main)`. Behavior is identical — all mutations land on the main queue.

- [ ] **Step 1: Create the store**

Create `app/Sources/OpenWhisperer/TranscriptionHistory.swift`:

```swift
import Foundation
import Combine
import OpenWhispererKit

/// Session-only transcription history feeding the menubar dropdown. Wraps the pure
/// `TranscriptHistoryBuffer`; nothing is written to disk. All mutations land on the
/// main queue (the sink receives on main; `clear()` is called from the menu).
final class TranscriptionHistory: ObservableObject {
    @Published private(set) var items: [String] = []

    private var buffer = TranscriptHistoryBuffer()
    private var cancellable: AnyCancellable?

    /// Subscribe to the dictation pipeline's transcription feed — the same
    /// `$lastTranscription` publisher the overlay's status wiring consumes.
    func wire(to dictation: DictationManager) {
        cancellable = dictation.$lastTranscription
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.buffer.append(text)
                self.items = self.buffer.items
            }
    }

    func clear() {
        buffer.clear()
        items = []
    }
}
```

- [ ] **Step 2: Own and wire it in AppDelegate**

In `app/Sources/OpenWhisperer/AppDelegate.swift`, after line 17 (`let accessibilityManager = AccessibilityManager()`) add:

```swift
    let transcriptionHistory = TranscriptionHistory()
```

In `setupDictation()`, directly after `TranscriptionOverlay.shared.setupManager = setupManager` (line 118), add:

```swift
        transcriptionHistory.wire(to: dictationManager)
```

- [ ] **Step 3: Build**

Run (from `app/`): `swift build`
Expected: `Build complete!` (no test coverage possible — app target is AppKit-bound; logic was tested in Task 1).

- [ ] **Step 4: Commit**

```bash
git add Sources/OpenWhisperer/TranscriptionHistory.swift Sources/OpenWhisperer/AppDelegate.swift
git commit -m "feat(history): add session store wired to dictation" \
  -m "Thin ObservableObject over TranscriptHistoryBuffer, subscribed to
DictationManager.\$lastTranscription. In-memory only.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 3: History section in the menubar dropdown

**Files:**
- Modify: `app/Sources/OpenWhisperer/OpenWhispererApp.swift` (import at line 1, `MenuBarExtra` content at lines 57-59, `SettingsMenuItems` at lines 75-102)

**Interfaces:**
- Consumes: `TranscriptionHistory` (`items`, `clear()`) and `AppDelegate.transcriptionHistory` from Task 2; `TranscriptHistoryBuffer.menuLabel(_:)` from Task 1.
- Produces: nothing later tasks use.

- [ ] **Step 1: Add the Kit import**

At the top of `app/Sources/OpenWhisperer/OpenWhispererApp.swift`, line 1 currently reads `import SwiftUI`. Make it:

```swift
import SwiftUI
import OpenWhispererKit
```

- [ ] **Step 2: Pass the store into the menu**

In `OpenWhispererApp.body` (line 57), change:

```swift
        MenuBarExtra {
            SettingsMenuItems()
        } label: {
```

to:

```swift
        MenuBarExtra {
            SettingsMenuItems(history: appDelegate.transcriptionHistory)
        } label: {
```

- [ ] **Step 3: Render the section**

Replace the whole `SettingsMenuItems` struct (lines 75-102) with:

```swift
/// Menubar menu content.
private struct SettingsMenuItems: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var history: TranscriptionHistory
    @ObservedObject private var overlay = TranscriptionOverlay.shared

    /// Rows the dropdown shows; the buffer keeps `TranscriptHistoryBuffer.maxEntries`.
    private static let visibleRows = 10

    var body: some View {
        // A plain Text renders as a disabled menu item — the section header.
        Text("Recent Transcriptions")

        if history.items.isEmpty {
            Text("No transcriptions yet")
        } else {
            // Newest first. The label is truncated; clicking copies the full text.
            ForEach(Array(history.items.prefix(Self.visibleRows).enumerated()), id: \.offset) { _, text in
                Button(TranscriptHistoryBuffer.menuLabel(text)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }

        Divider()

        Button("Clear History") { history.clear() }
            .disabled(history.items.isEmpty)

        Divider()

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

- [ ] **Step 4: Build**

Run (from `app/`): `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhisperer/OpenWhispererApp.swift
git commit -m "feat(menu): list recent transcriptions in dropdown" \
  -m "Flycut-style inline section: header, 10 newest rows (click = copy
full text), Clear History disabled when empty.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 4: Slim the overlay to a pure status widget

**Files:**
- Modify: `app/Sources/OpenWhisperer/TranscriptionOverlay.swift` (remove transcript machinery)
- Modify: `app/Sources/OpenWhisperer/Paths.swift:89` (rename to legacy)
- Modify: `app/Sources/OpenWhisperer/ConfigManager.swift` (add cleanup after `migrateVoiceDetailToTtsStyle`, line ~520)
- Modify: `app/Sources/OpenWhisperer/AppDelegate.swift:22-26` (call cleanup)

**Interfaces:**
- Consumes: nothing from earlier tasks (independent cleanup; Task 3 already ships the replacement UI).
- Produces: `ConfigManager.removeLegacyOverlayLines()`, `Paths.legacyOverlayLines`.

- [ ] **Step 1: Remove transcript state from `TranscriptionOverlay` (the class)**

In `app/Sources/OpenWhisperer/TranscriptionOverlay.swift`:

a. Delete the `Line` struct, the `lines` and `nextLineId` properties, and the whole resize-grip block — `transcriptLines` (with its doc comment), `maxTranscriptLines`, `clampLines`, `loadTranscriptLines()`, `persistTranscriptLines()` (lines 20-49). Keep `isVisible`, `isTTSPlaying`, `ttsTimer`.

b. Delete the `setWindowMovable(_:)` method and its doc comment (lines 175-181) — it existed only for the grip.

c. In `show()`, change the window style mask (line 130) from `[.borderless, .resizable]` to `[.borderless]` — the window no longer resizes.

d. In `wireStatus()`, delete the `$lastTranscription` subscription and its comment (lines 222-237), i.e. this block:

```swift
            // Transcript history straight from the in-process pipeline. (The overlay
            // used to tail server.log for "Transcribed:" lines — a format only the
            // deleted Python server wrote, so the pane had been empty since the port.)
            dm.$lastTranscription
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] text in
                    guard let self, !text.isEmpty else { return }
                    self.nextLineId += 1
                    self.lines.append(Line(id: self.nextLineId, text: text))
                    // Scrollable history, memory-bounded.
                    if self.lines.count > 50 {
                        self.lines = Array(self.lines.suffix(50))
                    }
                }
                .store(in: &statusCancellables)
```

- [ ] **Step 2: Remove the transcript UI (the views)**

Still in `TranscriptionOverlay.swift`:

a. Delete the entire `OverlayLineRow` struct including its `// MARK: - Overlay Line Row` header (lines 269-329).

b. Replace the entire `OverlayView` struct (lines 333-485) with:

```swift
struct OverlayView: View {
    /// FIX: Observe the overlay as the single source of truth. The overlay's
    /// @Published currentRecorder is how we get the live recorder reference.
    /// We do NOT take recorder as a direct init parameter anymore — doing so
    /// would freeze the reference at the moment NSHostingView was constructed.
    @ObservedObject var overlay: TranscriptionOverlay

    var body: some View {
        // Derive the live recorder from overlay.currentRecorder each time body evaluates,
        // so WaveformBar always observes the instance that is actually recording.
        let recorder = overlay.currentRecorder

        VStack(alignment: .leading, spacing: 4) {
            // Slim close affordance (this is a persistent standby overlay).
            HStack {
                Spacer()
                Button(action: { overlay.hide() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(OWColor.inkFaint)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 12)

            // Live waveform + state word ("Standby" / "Recording…" / "Speaking…").
            WaveformBar(recorder: recorder, isTTSPlaying: overlay.isTTSPlaying, pttKeyLabel: overlay.pttKeyLabel, interactionMode: overlay.interactionMode)
                .frame(height: 32)

            // Silence countdown — hands-free only.
            if overlay.interactionMode == .handsFree {
                SilenceProgressBar(recorder: recorder)
                    .frame(height: 1.5)
                    .padding(.top, 2)
            }

            // Model-loading / failure status. (Transcription history lives in the
            // menubar dropdown; the overlay is a pure status widget.)
            if let status = overlay.statusText {
                HStack(spacing: 6) {
                    Label(status, systemImage: overlay.statusIsError ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                        .font(.custom("Outfit", size: 10))
                        .foregroundColor(overlay.statusIsError ? OWColor.danger : OWColor.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if overlay.statusIsError, let dm = overlay.dictationManager, dm.sttFailed {
                        Spacer(minLength: 0)
                        Button("Retry") { dm.retrySTT() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 9)
        .frame(width: 240, alignment: .leading)
    }
}
```

(This drops `copiedLineId`, `overlayHovered`, `dragStartLines`, `lineStep`, the transcript block, the grip, `gripDrag`, and the outer `.onHover`. `WaveformBar` and `SilenceProgressBar` below it stay untouched.)

- [ ] **Step 3: Retire the pref file**

In `app/Sources/OpenWhisperer/Paths.swift`, replace line 89:

```swift
    static let overlayLines = appSupport.appendingPathComponent("overlay_lines")
```

with:

```swift
    /// Legacy (pre menubar-history): the overlay resize grip's persisted line count.
    /// Kept only so `ConfigManager.removeLegacyOverlayLines()` can delete stale files.
    static let legacyOverlayLines = appSupport.appendingPathComponent("overlay_lines")
```

In `app/Sources/OpenWhisperer/ConfigManager.swift`, directly after the closing brace of `migrateVoiceDetailToTtsStyle()` (line ~520), add:

```swift
    /// One-shot cleanup: transcription history moved to the menubar dropdown (2026-07-13)
    /// and the overlay's resize grip went with it — delete the grip's orphaned pref file.
    static func removeLegacyOverlayLines() {
        try? FileManager.default.removeItem(at: Paths.legacyOverlayLines)
    }
```

In `app/Sources/OpenWhisperer/AppDelegate.swift`, in `applicationDidFinishLaunching`, after the `ConfigManager.migrateRemoveClaudeStopHook()` line (line 26), add:

```swift
        // Delete the orphaned overlay_lines pref (grip removed with menubar history).
        ConfigManager.removeLegacyOverlayLines()
```

- [ ] **Step 4: Build and run both suites**

Run (from `app/`):

```bash
swift build && swift run OpenWhispererKitTests && swift run HookTests
```

Expected: `Build complete!`, `✅ OpenWhispererKit: all checks passed`, and HookTests green (exit 0). A leftover reference to any deleted symbol fails the build — the Task-4 grep guarantee is that `Paths.overlayLines` was the only external reference.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenWhisperer/TranscriptionOverlay.swift Sources/OpenWhisperer/Paths.swift \
        Sources/OpenWhisperer/ConfigManager.swift Sources/OpenWhisperer/AppDelegate.swift
git commit -m "refactor(overlay): drop transcript rows and grip" \
  -m "The overlay is now a pure status widget (waveform, silence bar,
model status); history lives in the menubar dropdown. The orphaned
overlay_lines pref is deleted on launch.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 5: Verification, PR, manual smoke handoff

**Files:**
- No source changes. Build artifacts only.

**Interfaces:**
- Consumes: all prior tasks merged into the `menubar-history` branch.
- Produces: an open PR and a signed local build for the user's smoke test.

- [ ] **Step 1: Full test pass**

Run (from `app/`):

```bash
swift run OpenWhispererKitTests && swift run HookTests
```

Expected: both green, exit 0.

- [ ] **Step 2: Signed local build**

Run (from `app/`):

```bash
OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh
```

Expected: `.app` + `.dmg` under `app/.build/`. (The stable self-signed cert keeps TCC grants across rebuilds. The cert exists in the login keychain even though `security find-identity -v` hides it — do not fall back to ad-hoc.)

- [ ] **Step 3: Rebase and open the PR**

```bash
git fetch origin && git rebase origin/main
git push -u origin menubar-history
gh pr create --title "feat: move transcription history into the menubar dropdown" --body "$(cat <<'EOF'
## Summary
- New "Recent Transcriptions" section in the menubar dropdown (Flycut idiom): 10 newest rows, click copies the full text, Clear History, session-only (nothing on disk)
- Pure `TranscriptHistoryBuffer` in OpenWhispererKit (cap 50, newest first, 50-char grapheme-safe labels) + thin `TranscriptionHistory` store wired to `DictationManager.$lastTranscription`
- Overlay slimmed to a pure status widget: transcript rows, resize grip, and the `overlay_lines` pref removed (orphan deleted on launch)

Spec: `docs/superpowers/specs/2026-07-13-menubar-transcription-history-design.md`
Phase 2 (notch status indicator) stays parked in `docs/UX-BACKLOG.md`.

## Test plan
- [x] `swift run OpenWhispererKitTests` (new `transcriptHistoryBufferFailures` group)
- [x] `swift run HookTests`
- [ ] Manual smoke (Hakan): dictate → row appears; click → clipboard holds full text; Clear empties and disables; overlay shows status only, no grip; menu in light and dark
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 4: Hand off the manual smoke**

Install the fresh build locally so the user can smoke-test (per AGENTS.md):

```bash
killall OpenWhisperer 2>/dev/null; rm -rf /Applications/OpenWhisperer.app
cp -R .build/OpenWhisperer.app /Applications/
open /Applications/OpenWhisperer.app
```

Then report to the user: the PR link and the smoke checklist from the PR body (dictation requires a mic — only the user can run it). Do not merge before the smoke passes.

---

## Self-Review Notes

- **Spec coverage:** menu structure incl. separators around Clear History (Task 3), session-only + cap 50/show 10/labels 50 (Tasks 1-3), click copies full text (Task 3), overlay slimming + fixed size + `overlay_lines` cleanup (Task 4), Kit tests (Task 1), manual smoke + PR path (Task 5). One deliberate deviation from the spec, recorded in Task 2: the store is a plain ObservableObject, not `@MainActor` (nonisolated caller; repo pattern; identical behavior).
- **Type consistency:** `TranscriptHistoryBuffer.maxEntries/items/append/clear/menuLabel` and `TranscriptionHistory.items/wire(to:)/clear()` are used with identical spellings across Tasks 1-4.
