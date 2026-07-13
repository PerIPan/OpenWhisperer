# Minimal Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the floating overlay to waveform + status dot (no text) and move the model-status words + Retry into the menubar dropdown.

**Architecture:** Two surgical edits. `WaveformBar` loses its state label and hotkey hint and gains a danger-red dot override; `OverlayView` drops the model-status block. `SettingsMenuItems` gains a status row reading the overlay's existing `statusText`/`statusIsError` publishers.

**Tech Stack:** Swift/SwiftUI. No new logic; no Kit changes.

**Spec:** `docs/superpowers/specs/2026-07-13-minimal-overlay-design.md`

## Global Constraints

- All Swift commands run from `app/` (the SwiftPM package root).
- Work in a worktree off `main` at `.claude/worktrees/minimal-overlay` (branch `minimal-overlay`) — never branch in place.
- The overlay must end up with **zero text**: no state label, no hotkey hint, no model-status words. Non-text elements stay: status dot, waveform, hands-free silence line, close button, drag-to-move, "Show Overlay" toggle copy unchanged.
- `TranscriptionOverlay.pttKeyLabel` and `.interactionMode` (and their writers in AppDelegate/InputTab/DictationManager) stay in place even though the hint is gone — spec decision.
- Menu status row semantics: rendered only while `overlay.statusText != nil`; a Button titled `"\(status) — Retry"` calling `dm.retrySTT()` when `overlay.statusIsError && dm.sttFailed`, else a disabled Text; followed by its own Divider; placed between the Clear History group and the "Show Overlay" toggle.
- Commits: Conventional Commits, imperative, subject hard cap 72 chars including `type(scope):`. No `Co-Authored-By`. End each commit body with the trailer line `Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5`.

---

### Task 1: Strip the overlay to wave + dot

**Files:**
- Modify: `app/Sources/OpenWhisperer/TranscriptionOverlay.swift` (WaveformBar ~lines 284-416, OverlayView ~lines 244-273; anchor on quoted code, not line numbers)

**Interfaces:**
- Consumes: existing `OWColor.danger` token; `overlay.statusIsError` (`@Published`, already on the class).
- Produces: `WaveformBar(recorder:isTTSPlaying:statusIsError:)` — the `pttKeyLabel:`/`interactionMode:` parameters are removed from the view. Task 2 relies on `TranscriptionOverlay.statusText`/`statusIsError`/`dictationManager` remaining published/accessible exactly as they are today (this task must NOT remove them).

- [ ] **Step 1: Slim the `WaveformBar` declaration**

In `app/Sources/OpenWhisperer/TranscriptionOverlay.swift`, replace:

```swift
struct WaveformBar: View {
    @ObservedObject var recorder: AudioRecorder
    var isTTSPlaying: Bool = false
    var pttKeyLabel: String = "Ctrl"
    var interactionMode: InteractionMode = .pressToTalk
```

with:

```swift
struct WaveformBar: View {
    @ObservedObject var recorder: AudioRecorder
    var isTTSPlaying: Bool = false
    /// Paints the dot danger-red while model status is failed (the words live in the menu).
    var statusIsError: Bool = false
```

- [ ] **Step 2: Remove the label and hint from the body**

In `WaveformBar.body`, replace:

```swift
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.custom("Outfit", size: 10))
                    .foregroundColor(statusColor)
                Spacer()
                if recorder.state == .recording {
                    let hint: String = {
                        switch interactionMode {
                        case .holdToTalk: return "Release \(pttKeyLabel) to stop"
                        case .handsFree: return "silence submits"
                        case .pressToTalk: return "Press \(pttKeyLabel) to stop"
                        }
                    }()
                    Text(hint)
                        .font(.custom("Outfit", size: 9))
                        .foregroundColor(.secondary)
                }
            }
```

with:

```swift
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Spacer()
            }
```

- [ ] **Step 3: Error override on the dot; delete the dead label text**

Replace:

```swift
    private var statusColor: Color {
        if isTTSPlaying && recorder.state == .idle { return OWColor.accent }
```

with:

```swift
    private var statusColor: Color {
        if statusIsError { return OWColor.danger }
        if isTTSPlaying && recorder.state == .idle { return OWColor.accent }
```

Then delete the now-unused computed property in `WaveformBar` (the whole block):

```swift
    private var statusText: String {
        if isTTSPlaying && recorder.state == .idle { return "Speaking..." }
        switch recorder.state {
        case .recording: return "Recording..."
        case .uploading: return "Transcribing..."
        case .listening: return "Listening..."
        case .idle: return "Standby"
        }
    }
```

(Note: `TranscriptionOverlay`'s class-level `statusText` @Published property is a DIFFERENT thing and must stay — only `WaveformBar`'s private computed var goes.)

- [ ] **Step 4: Update the `OverlayView` call site and drop the model-status block**

In `OverlayView.body`, replace:

```swift
            // Live waveform + state word ("Standby" / "Recording…" / "Speaking…").
            WaveformBar(recorder: recorder, isTTSPlaying: overlay.isTTSPlaying, pttKeyLabel: overlay.pttKeyLabel, interactionMode: overlay.interactionMode)
                .frame(height: 32)
```

with:

```swift
            // Live waveform + status dot (no text — the words live in the menubar dropdown).
            WaveformBar(recorder: recorder, isTTSPlaying: overlay.isTTSPlaying, statusIsError: overlay.statusIsError)
                .frame(height: 32)
```

Then delete the whole model-status block:

```swift
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
```

(The `if overlay.interactionMode == .handsFree { SilenceProgressBar(...) }` block above it stays untouched.)

- [ ] **Step 5: Build and run both suites**

Run (from `app/`): `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: `Build complete!`, both suites green.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenWhisperer/TranscriptionOverlay.swift
git commit -m "feat(overlay): strip text to wave and status dot" \
  -m "State label, hotkey hint, and the in-overlay model-status block go;
the dot turns danger-red while model status is failed. Words move to
the menubar dropdown (next commit).

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 2: Model-status row in the menubar dropdown

**Files:**
- Modify: `app/Sources/OpenWhisperer/OpenWhispererApp.swift` (`SettingsMenuItems`, between the Clear History group and the "Show Overlay" toggle)

**Interfaces:**
- Consumes: `TranscriptionOverlay.shared` already observed as `overlay` in `SettingsMenuItems`; its `statusText: String?`, `statusIsError: Bool`, `dictationManager: DictationManager?`; `DictationManager.sttFailed` and `retrySTT()`.
- Produces: nothing later tasks use.

- [ ] **Step 1: Insert the status row**

In `SettingsMenuItems.body`, replace:

```swift
        Divider()

        Toggle("Show Overlay", isOn: Binding(
```

with:

```swift
        Divider()

        // Model/setup status — the overlay shows only a red dot; the words live here.
        if let status = overlay.statusText {
            if overlay.statusIsError, let dm = overlay.dictationManager, dm.sttFailed {
                Button("\(status) — Retry") { dm.retrySTT() }
            } else {
                Text(status)
            }
            Divider()
        }

        Toggle("Show Overlay", isOn: Binding(
```

- [ ] **Step 2: Build and run both suites**

Run (from `app/`): `swift build && swift run OpenWhispererKitTests && swift run HookTests`
Expected: `Build complete!`, both suites green.

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenWhisperer/OpenWhispererApp.swift
git commit -m "feat(menu): add model-status row with inline Retry" \
  -m "Shown only while loading/failed; salvaged from the closed notch
branch (PR #24), re-targeted at the overlay's status publishers.

Claude-Session: 4f5b9596-717f-497e-abfd-1ce5df4587a5"
```

---

### Task 3: Verification, PR, manual smoke handoff

**Files:**
- No source changes. Build artifacts only.

**Interfaces:**
- Consumes: Tasks 1–2 on the `minimal-overlay` branch.
- Produces: an open PR and a signed local build for the user's smoke test.

- [ ] **Step 1: Full test pass**

Run (from `app/`): `swift run OpenWhispererKitTests && swift run HookTests`
Expected: both green, exit 0.

- [ ] **Step 2: Signed local build**

Run (from `app/`): `OW_SIGN_IDENTITY="OpenWhisperer Dev" ./build-dmg.sh`
Expected: `.app` + `.dmg` under `app/.build/`. (The cert exists in the login keychain even though `security find-identity -v` hides it — do not fall back to ad-hoc.)

- [ ] **Step 3: Rebase and open the PR**

```bash
git fetch origin && git rebase origin/main
git push -u origin minimal-overlay
gh pr create --title "feat: strip the overlay to wave and status dot" --body "$(cat <<'EOF'
## Summary
- The floating overlay loses all text: state label and hotkey hint removed; the status dot now also signals model failure (danger red)
- Model-status words + inline Retry move to the menubar dropdown (shown only while loading/failed) — salvaged from the closed notch branch (PR #24)
- Non-text elements unchanged: waveform, hands-free silence line, close button, drag-to-move, "Show Overlay" toggle

Spec: `docs/superpowers/specs/2026-07-13-minimal-overlay-design.md` (successor to the rejected notch indicator)

## Test plan
- [x] `swift run OpenWhispererKitTests`
- [x] `swift run HookTests`
- [ ] Manual smoke (Hakan): idle green dot + calm wave, no words; recording = red dot + live wave; transcribing amber; speaking gold; hands-free silence line fills; during a model load the dropdown shows the status row (and Retry on failure) while the overlay dot goes red; light/dark
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 4: Install and hand off the manual smoke**

```bash
killall OpenWhisperer 2>/dev/null; rm -rf /Applications/OpenWhisperer.app
cp -R .build/OpenWhisperer.app /Applications/
open /Applications/OpenWhisperer.app
```

(If `open` fails with Launch Services error -600, rerun just the `open` command outside the sandbox.) Report the PR link and smoke checklist to the user. Do not merge before the smoke passes.

---

## Self-Review Notes

- **Spec coverage:** zero-text overlay incl. dot error override (Task 1), menu status row semantics + placement (Task 2), pttKeyLabel/interactionMode retention (Task 1 explicitly keeps the class properties; only the view parameters go), non-goals untouched, PR-path workflow (Task 3).
- **Type consistency:** `WaveformBar(recorder:isTTSPlaying:statusIsError:)` matches between Task 1's declaration and call site; Task 2 reads only members Task 1 preserves (`statusText`, `statusIsError`, `dictationManager`).
- No new tests: no new pure logic (UI deletion + menu row); the suites act as regression gates.
