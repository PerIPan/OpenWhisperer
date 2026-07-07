# Richer Voices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the menubar voice picker to the full Kokoro-82M v1.0 roster (54 voices, grouped by language), and give non-English voices an always-on native-tongue "flavor" addendum in the per-turn nudge.

**Architecture:** Part 1 is a UI/data change: a grouped `OWGroupedMenuPicker` (nested `Menu` per language) replaces the flat 6-voice `OWMenuPicker`; the engine already downloads any `voices/<id>.bin` on demand, so no engine change. Part 2 appends a self-gating flavor sentence to the nudge built in `hooks/voice-context.sh`, keyed off the first character of the selected voice id; the mapping lives only in bash and is guarded by `HookTests`.

**Tech Stack:** Swift 5.9 (SwiftPM), SwiftUI/AppKit, bash, FluidAudio (Kokoro TTS). Command Line Tools only.

## Global Constraints

- **Roster verified against `onnx-community/Kokoro-82M-v1.0-ONNX` on 2026-07-01.** Use the exact ids in Task 2 (a wrong id silently 404s the download). The bare `af` alias in the repo is **excluded** (it is a default mix, not a named voice). Default voice stays `af_heart`.
- **Flavor is always-on for non-English voices, no toggle/pref.** Language is the **first character** of the voice id: `a`/`b` → English (no flavor), `f` → French, `i` → Italian, `e` → Spanish, `p` → Brazilian Portuguese, `h` → Hindi, `j` → Japanese, `z` → Mandarin Chinese. Unknown/empty → no flavor. Flavor = occasional native words/expressions + a touch of mannerism, subtle, self-gated to when the spoken summary isn't already in that language.
- **The voice→language map lives ONLY in `hooks/voice-context.sh`.** There is no Swift counterpart to keep in parity (unlike `VoiceSignal`). `HookTests` is the guard.
- **No version bump.** Do not touch `build-dmg.sh` or `Info.plist`.
- **Testing reality (per AGENTS.md):** CLT only, no XCTest. The flavor addendum **is** testable via `HookTests` (bash + stubbed HOME) — do it TDD. The SwiftUI roster/picker is **not** unit-testable; its objective check is `swift build` success + both runners green. All `swift` commands run from `app/`.
- **Commits:** Conventional Commits (`type(scope): subject`, ≤72 incl. prefix). End each commit body with the trailer `Claude-Session: https://claude.ai/code/session_01TXnhiqywjpp3QBKe1gxet9`. No tool/co-author attribution.

---

### Task 1: Grouped picker component

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift`

**Interfaces:**
- Produces: `struct OWGroupedMenuPicker<T: Hashable>` with `@Binding var selection: T` and `let groups: [(group: String, options: [(id: T, label: String)])]`. Consumed by Task 2.

- [ ] **Step 1: Add `OWGroupedMenuPicker`**

In `app/Sources/OpenWhisperer/MenuBarView.swift`, immediately after the existing `OWMenuPicker` struct (it ends with the `currentLabel` computed property and its closing brace, under the `// MARK: - OWMenuPicker` comment), add:

```swift
// MARK: - OWGroupedMenuPicker (OWMenuPicker with one nested submenu per group)

/// Like `OWMenuPicker`, but renders `groups` as nested submenus (a `Menu` per
/// group) so a long option list (e.g. ~50 voices) stays navigable instead of one
/// flat scroll. Same collapsed control/styling as `OWMenuPicker`.
struct OWGroupedMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let groups: [(group: String, options: [(id: T, label: String)])]

    var body: some View {
        Menu {
            ForEach(groups, id: \.group) { group in
                Menu(group.group) {
                    ForEach(group.options, id: \.id) { option in
                        Button {
                            selection = option.id
                        } label: {
                            if option.id == selection {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(OWColor.accent.opacity(0.6))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(OWColor.pickerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(OWColor.checkboxBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var currentLabel: String {
        for g in groups {
            if let m = g.options.first(where: { $0.id == selection }) { return m.label }
        }
        return ""
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd app && swift build`
Expected: build succeeds (the new type is unused so far — that's fine).

- [ ] **Step 3: Commit**

```bash
git add app/Sources/OpenWhisperer/MenuBarView.swift
git commit -m "feat(voice): add grouped menu picker component"
```
(Append the `Claude-Session:` trailer.)

---

### Task 2: Full roster + wire up the grouped picker

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift`

**Interfaces:**
- Consumes: `OWGroupedMenuPicker` (Task 1).
- Produces: `static let voiceGroups`, `static var allVoices` on `MenuBarView`.

- [ ] **Step 1: Replace the flat `voices` list with grouped data**

In `app/Sources/OpenWhisperer/MenuBarView.swift`, replace the entire existing declaration:

```swift
    private static let voices: [(id: String, label: String)] = [
        // English
        ("af_heart", "Heart (English F)"),
        ("af_bella", "Bella (English F)"),
        ("am_michael", "Michael (English M)"),
        // French
        ("ff_siwis", "Siwis (French F)"),
        // Italian
        ("if_sara", "Sara (Italian F)"),
        ("im_nicola", "Nicola (Italian M)"),
    ]
```

with:

```swift
    // Full Kokoro-82M v1.0 roster (verified against onnx-community/Kokoro-82M-v1.0-ONNX
    // on 2026-07-01). Grouped by language for the nested-submenu picker. Non-default
    // voices download on first selection via KokoroTTS.ensureVoicePack. The bare `af`
    // alias is intentionally omitted (it is a default mix, not a named voice).
    private static let voiceGroups: [(group: String, options: [(id: String, label: String)])] = [
        ("English (US)", [
            ("af_heart", "Heart (F)"), ("af_bella", "Bella (F)"), ("af_alloy", "Alloy (F)"),
            ("af_aoede", "Aoede (F)"), ("af_jessica", "Jessica (F)"), ("af_kore", "Kore (F)"),
            ("af_nicole", "Nicole (F)"), ("af_nova", "Nova (F)"), ("af_river", "River (F)"),
            ("af_sarah", "Sarah (F)"), ("af_sky", "Sky (F)"),
            ("am_adam", "Adam (M)"), ("am_echo", "Echo (M)"), ("am_eric", "Eric (M)"),
            ("am_fenrir", "Fenrir (M)"), ("am_liam", "Liam (M)"), ("am_michael", "Michael (M)"),
            ("am_onyx", "Onyx (M)"), ("am_puck", "Puck (M)"), ("am_santa", "Santa (M)"),
        ]),
        ("English (UK)", [
            ("bf_alice", "Alice (F)"), ("bf_emma", "Emma (F)"), ("bf_isabella", "Isabella (F)"),
            ("bf_lily", "Lily (F)"),
            ("bm_daniel", "Daniel (M)"), ("bm_fable", "Fable (M)"), ("bm_george", "George (M)"),
            ("bm_lewis", "Lewis (M)"),
        ]),
        ("French", [("ff_siwis", "Siwis (F)")]),
        ("Italian", [("if_sara", "Sara (F)"), ("im_nicola", "Nicola (M)")]),
        ("Spanish", [("ef_dora", "Dora (F)"), ("em_alex", "Alex (M)"), ("em_santa", "Santa (M)")]),
        ("Portuguese (BR)", [("pf_dora", "Dora (F)"), ("pm_alex", "Alex (M)"), ("pm_santa", "Santa (M)")]),
        ("Hindi", [
            ("hf_alpha", "Alpha (F)"), ("hf_beta", "Beta (F)"),
            ("hm_omega", "Omega (M)"), ("hm_psi", "Psi (M)"),
        ]),
        ("Japanese", [
            ("jf_alpha", "Alpha (F)"), ("jf_gongitsune", "Gongitsune (F)"), ("jf_nezumi", "Nezumi (F)"),
            ("jf_tebukuro", "Tebukuro (F)"), ("jm_kumo", "Kumo (M)"),
        ]),
        ("Chinese", [
            ("zf_xiaobei", "Xiaobei (F)"), ("zf_xiaoni", "Xiaoni (F)"), ("zf_xiaoxiao", "Xiaoxiao (F)"),
            ("zf_xiaoyi", "Xiaoyi (F)"),
            ("zm_yunjian", "Yunjian (M)"), ("zm_yunxi", "Yunxi (M)"),
            ("zm_yunxia", "Yunxia (M)"), ("zm_yunyang", "Yunyang (M)"),
        ]),
    ]

    /// Flattened roster for collapsed-label lookup and load-time validation.
    private static var allVoices: [(id: String, label: String)] {
        voiceGroups.flatMap { $0.options }
    }
```

- [ ] **Step 2: Point load-time validation at `allVoices`**

In the `.onAppear` load block, replace:

```swift
                if Self.voices.contains(where: { $0.id == voice }) {
                    selectedVoice = voice
                }
```

with:

```swift
                if Self.allVoices.contains(where: { $0.id == voice }) {
                    selectedVoice = voice
                }
```

- [ ] **Step 3: Swap the Voice row picker**

In the Voice Settings `expandedContent`, replace:

```swift
                    OWMenuPicker(selection: $selectedVoice, options: Self.voices)
```

with:

```swift
                    OWGroupedMenuPicker(selection: $selectedVoice, groups: Self.voiceGroups)
```

- [ ] **Step 4: Verify it builds**

Run: `cd app && swift build`
Expected: build succeeds. (No remaining reference to `Self.voices` should exist — grep to confirm: `grep -n "Self.voices" app/Sources/OpenWhisperer/MenuBarView.swift` returns nothing.)

- [ ] **Step 5: Commit**

```bash
git add app/Sources/OpenWhisperer/MenuBarView.swift
git commit -m "feat(voice): expand picker to full Kokoro roster, grouped by language"
```
(Append the `Claude-Session:` trailer.)

---

### Task 3: Native-tongue flavor addendum (TDD via HookTests)

**Files:**
- Modify: `app/Tests/HookTests/HookHarness.swift` (add a `writeTtsVoice` sandbox helper)
- Modify: `app/Tests/HookTests/VoiceContextChecks.swift` (new flavor cases)
- Modify: `hooks/voice-context.sh` (emit the addendum)

**Interfaces:**
- Consumes: nothing new.
- Produces: flavor addendum appended to the nudge for non-English voices.

- [ ] **Step 1: Add the `writeTtsVoice` sandbox helper**

In `app/Tests/HookTests/HookHarness.swift`, after the existing `writeTtsStyle` method:

```swift
        func writeTtsStyle(_ style: String) {
            try? style.write(to: appSupport.appendingPathComponent("tts_style"),
                             atomically: true, encoding: .utf8)
        }
```

add:

```swift
        /// The selected TTS voice (`tts_voice`); voice-context.sh maps its first
        /// character to a language for the native-tongue flavor addendum.
        func writeTtsVoice(_ voice: String) {
            try? voice.write(to: appSupport.appendingPathComponent("tts_voice"),
                             atomically: true, encoding: .utf8)
        }
```

- [ ] **Step 2: Add the failing flavor checks**

In `app/Tests/HookTests/VoiceContextChecks.swift`, immediately before `return failures` at the end of `voiceContextFailures()`, add:

```swift
    // --- Native-tongue flavor addendum (keyed off tts_voice first char) ---

    // 16) non-English voice (French) → nudge gains the flavor addendum naming the language.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("ff_siwis")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        let n = nudge(r.stdout)
        if n?.contains("French") != true { fail("frenchFlavor: missing 'French': \(n?.debugDescription ?? "nil")") }
        if n?.contains("bilingual") != true { fail("frenchFlavor: missing addendum: \(n?.debugDescription ?? "nil")") }
        if n?.contains("`speak` tool") != true { fail("frenchFlavor: base nudge lost") }
    }

    // 17) another non-English voice (Japanese) → its language named.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("jf_alpha")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("Japanese") != true {
            fail("japaneseFlavor: \(nudge(r.stdout)?.debugDescription ?? "nil")")
        }
    }

    // 18) English voice (af_heart) → NO flavor addendum.
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go"); s.writeTtsVoice("af_heart")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("bilingual") == true { fail("englishNoFlavor: unexpected addendum") }
    }

    // 19) no voice set → NO flavor addendum (safe default).
    do {
        let s = newSandbox()
        s.writeVoiceTurn(forPrompt: "go")
        let r = Hook.run("voice-context.sh", stdin: input(prompt: "go", session: "s1"), sandbox: s)
        if nudge(r.stdout)?.contains("bilingual") == true { fail("noVoiceNoFlavor: unexpected addendum") }
    }
```

- [ ] **Step 3: Run to verify it fails (RED)**

Run: `cd app && swift run HookTests`
Expected: FAIL — `❌ voice-context.frenchFlavor: missing 'French'…` and `❌ voice-context.japaneseFlavor…` (cases 18/19 already pass since no addendum exists yet).

- [ ] **Step 4: Implement the flavor logic in the hook**

In `hooks/voice-context.sh`, find the end of the style `case` block and the `NUDGE=` assignment:

```bash
case "$STYLE" in
  terse)     LEN="one short, plain spoken sentence" ;;
  rich|full) LEN="a sentence or two of plain spoken summary" ;;
  *)         LEN="one plain spoken sentence" ;;
esac

if [ "$IS_VOICE" -eq 1 ]; then PREFIX="This turn was dictated by voice."; else PREFIX="This reply should be spoken aloud."; fi
NUDGE="${PREFIX} Before writing your on-screen reply, your FIRST action must be to call the \`speak\` tool exactly once, passing ${LEN} that summarizes your answer and stands alone when heard. Then write your full reply on screen as usual. Do not skip the speak call, and do not mention the tool in your written reply."
```

Insert the flavor block between the `esac` and the `if [ "$IS_VOICE" ... ]` line, and append `${FLAVOR}` to the `NUDGE` assignment, so the section becomes:

```bash
case "$STYLE" in
  terse)     LEN="one short, plain spoken sentence" ;;
  rich|full) LEN="a sentence or two of plain spoken summary" ;;
  *)         LEN="one plain spoken sentence" ;;
esac

# Native-tongue flavor: for a non-English voice, nudge the model to lightly code-switch
# into the voice's language — self-gated to when the spoken summary isn't already in it.
# Language = first character of the selected voice id (a/b = English → no flavor).
# This map lives ONLY here; HookTests is its guard.
VOICE=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null | tr -d '[:space:]')
case "${VOICE:0:1}" in
  f) FLAVOR_LANG="French" ;;
  i) FLAVOR_LANG="Italian" ;;
  e) FLAVOR_LANG="Spanish" ;;
  p) FLAVOR_LANG="Brazilian Portuguese" ;;
  h) FLAVOR_LANG="Hindi" ;;
  j) FLAVOR_LANG="Japanese" ;;
  z) FLAVOR_LANG="Mandarin Chinese" ;;
  *) FLAVOR_LANG="" ;;
esac
FLAVOR=""
if [ -n "$FLAVOR_LANG" ]; then
  FLAVOR=" The voice reading this aloud is ${FLAVOR_LANG}. Unless your spoken sentence is already in ${FLAVOR_LANG}, lightly flavor it the way a bilingual ${FLAVOR_LANG} speaker naturally would — an occasional ${FLAVOR_LANG} word or expression and a touch of native mannerism — kept subtle, never a caricature, and never at the expense of being understood."
fi

if [ "$IS_VOICE" -eq 1 ]; then PREFIX="This turn was dictated by voice."; else PREFIX="This reply should be spoken aloud."; fi
NUDGE="${PREFIX} Before writing your on-screen reply, your FIRST action must be to call the \`speak\` tool exactly once, passing ${LEN} that summarizes your answer and stands alone when heard. Then write your full reply on screen as usual. Do not skip the speak call, and do not mention the tool in your written reply.${FLAVOR}"
```

- [ ] **Step 5: Run to verify it passes (GREEN)**

Run: `cd app && swift run HookTests`
Expected: PASS — `✅` (all voice-context checks, including 16–19, pass).

- [ ] **Step 6: Commit**

```bash
git add hooks/voice-context.sh app/Tests/HookTests/HookHarness.swift app/Tests/HookTests/VoiceContextChecks.swift
git commit -m "feat(voice): add native-tongue flavor nudge for non-English voices"
```
(Append the `Claude-Session:` trailer.)

---

### Task 4: Documentation

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update the TTS / voice-turn section**

In `AGENTS.md`, in the *Voice-turn handshake* section (where the nudge shaping is described), add a sentence: `voice-context.sh` also reads `tts_voice` and, for a **non-English** voice (first-char language map: `f`/`i`/`e`/`p`/`h`/`j`/`z`), appends an always-on, self-gating native-tongue "flavor" addendum to the nudge (occasional native words + light mannerism; English `a`/`b` get nothing). Note the map lives only in the hook — no Swift parity pair.

- [ ] **Step 2: Update the roster mention**

In the STT/TTS or conventions area, if a "6 voices" or curated-voice count is stated, update it: the picker now offers the full Kokoro-82M v1.0 roster (~54 voices) grouped by language, all downloaded on demand via `ensureVoicePack`. README stays untouched (obsolete).

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document full voice roster + native-tongue flavor"
```
(Append the `Claude-Session:` trailer.)

---

### Task 5: Final regression + manual smoke

- [ ] **Step 1: Run both test runners**

Run: `cd app && swift run OpenWhispererKitTests && swift run HookTests`
Expected: both PASS. `HookTests` now includes flavor cases 16–19.

- [ ] **Step 2: Manual smoke (roster)**

Build/run the GUI (`cd app && swift build` then launch, or your usual `./build-dmg.sh` flow). Open the menubar → Voice Settings → the Voice control: confirm the language submenus (English (US)/(UK), French, Italian, Spanish, Portuguese (BR), Hindi, Japanese, Chinese) populate and the checkmark tracks the current voice. Pick a non-default voice (e.g. **English (UK) → George**) and dictate a turn; confirm the `.bin` downloads on first use and the reply is spoken in that voice.

- [ ] **Step 3: Manual smoke (flavor)**

Select **French → Siwis**, dictate a turn, and confirm the spoken summary drops in the occasional French touch while staying clear. Switch to **English (US) → Heart** and confirm plain, un-flavored delivery.

---

## Self-Review

**Spec coverage:**
- Full 54-voice roster, grouped, verified ids, `af` excluded, default `af_heart` → Task 2. ✓
- Nested-submenu picker without a flat scroll → Task 1 (`OWGroupedMenuPicker`). ✓
- Load-time validation against the full roster → Task 2 Step 2. ✓
- `ensureVoicePack` unchanged (on-demand download) → no task needed; noted in Task 2 comment. ✓
- Flavor addendum, always-on for non-English, first-char map, self-gating, words + mannerism → Task 3. ✓
- Map lives only in bash; HookTests is the guard → Task 3 (cases 16–19) + Global Constraints. ✓
- AGENTS.md updates; README untouched; no version bump → Task 4 + Global Constraints. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code (Swift, bash, test); commands have expected output. ✓

**Type consistency:** `OWGroupedMenuPicker(selection:groups:)` defined in Task 1, used with `groups: Self.voiceGroups` in Task 2 — `voiceGroups` element shape `(group: String, options: [(id: String, label: String)])` matches the picker's `groups` parameter exactly. `allVoices` (flattened) used in validation. `writeTtsVoice` defined in Task 3 Step 1, used in Steps 2. Flavor test marker word `bilingual` appears in both the bash addendum and the assertions. ✓
