# Richer voices — full roster + native-tongue flavor

**Date:** 2026-07-01
**Status:** Approved (brainstorming) — pending implementation plan

## Goal

Two paired changes that make the spoken output more varied and more fun:

1. **Roster.** Expand the menubar voice picker from the curated 6 to the **full
   Kokoro-82M v1.0 roster** (54 named voices across 9 language/region groups),
   rendered grouped by language so the long list stays navigable. The engine can
   already play any of them — `KokoroTTS.ensureVoicePack` downloads
   `voices/<id>.bin` from `onnx-community/Kokoro-82M-v1.0-ONNX` on first use — so
   this is a UI/data change only.
2. **Flavor.** When a **non-English** voice is selected, append a small,
   always-on addendum to the per-turn nudge in `voice-context.sh` telling the
   model to lightly flavor its spoken summary with the voice's native tongue —
   the way a bilingual speaker occasionally code-switches — *unless the summary is
   already in that language*.

They ship together because flavor only comes alive once there are many
non-English voices to choose from; expanding the roster is what makes it worth
doing.

### Why this, why now

The picker was trimmed to 6 in `1a0153f` when the on-demand downloader landed,
but the downloader is exactly what makes a big roster cheap: unlisted voices cost
nothing until picked. And the voice-turn nudge is already the place we shape
spoken output per turn (length, when-to-speak) — adding a per-voice language
flavor is a natural, low-cost extension of it.

## Decisions (settled during brainstorming)

- **All ~50, grouped by language.** Full roster, not a curated subset. Rendered
  as **nested submenus per language** inside `OWMenuPicker` (top level = the ~9
  language/region groups; each expands to its voices), so 54 entries never become
  one flat scroll.
- **Flavor is always on for non-English voices — no toggle, no pref.** English
  voices (US + UK) get nothing appended (replies are normally English, so there's
  nothing to code-switch *into*).
- **Flavor = native words/phrases + light mannerisms**, kept subtle, never a
  caricature, never at the cost of clarity.
- **Self-gating on reply language.** The addendum says "unless your summary is
  already in \<Language\>…", so the *model* decides whether to flavor based on
  what it's replying in. No language detection in bash.
- **Mapping lives only in `voice-context.sh`.** Unlike `VoiceSignal.canonicalHash`
  there is no Swift counterpart to keep in parity — the app never needs the
  voice→language map.

## Non-goals (YAGNI)

- No flavor toggle, no per-voice/per-language intensity setting, no per-project
  override.
- No language auto-detection — the model self-gates.
- No search box in the picker (nested submenus handle the length instead).
- No voice-quality grading/filtering in the UI (Kokoro grades some voices lower;
  we list them all and let the user judge by ear).
- The bare `af` alias in the repo is **excluded** — it is a default mix, not a
  named voice.

## Approach — Part 1: Roster

### Voice data (verified against the repo, 2026-07-01)

Grouped `[(group, [(id, label)])]`. Labels carry an `(F)`/`(M)` tag since a
group can hold both; the language is the submenu title.

- **English (US):** `af_heart` Heart (F) · `af_bella` Bella (F) · `af_alloy`
  Alloy (F) · `af_aoede` Aoede (F) · `af_jessica` Jessica (F) · `af_kore` Kore
  (F) · `af_nicole` Nicole (F) · `af_nova` Nova (F) · `af_river` River (F) ·
  `af_sarah` Sarah (F) · `af_sky` Sky (F) · `am_adam` Adam (M) · `am_echo` Echo
  (M) · `am_eric` Eric (M) · `am_fenrir` Fenrir (M) · `am_liam` Liam (M) ·
  `am_michael` Michael (M) · `am_onyx` Onyx (M) · `am_puck` Puck (M) · `am_santa`
  Santa (M)
- **English (UK):** `bf_alice` Alice (F) · `bf_emma` Emma (F) · `bf_isabella`
  Isabella (F) · `bf_lily` Lily (F) · `bm_daniel` Daniel (M) · `bm_fable` Fable
  (M) · `bm_george` George (M) · `bm_lewis` Lewis (M)
- **French:** `ff_siwis` Siwis (F)
- **Italian:** `if_sara` Sara (F) · `im_nicola` Nicola (M)
- **Spanish:** `ef_dora` Dora (F) · `em_alex` Alex (M) · `em_santa` Santa (M)
- **Portuguese (BR):** `pf_dora` Dora (F) · `pm_alex` Alex (M) · `pm_santa` Santa
  (M)
- **Hindi:** `hf_alpha` Alpha (F) · `hf_beta` Beta (F) · `hm_omega` Omega (M) ·
  `hm_psi` Psi (M)
- **Japanese:** `jf_alpha` Alpha (F) · `jf_gongitsune` Gongitsune (F) ·
  `jf_nezumi` Nezumi (F) · `jf_tebukuro` Tebukuro (F) · `jm_kumo` Kumo (M)
- **Chinese:** `zf_xiaobei` Xiaobei (F) · `zf_xiaoni` Xiaoni (F) · `zf_xiaoxiao`
  Xiaoxiao (F) · `zf_xiaoyi` Xiaoyi (F) · `zm_yunjian` Yunjian (M) · `zm_yunxi`
  Yunxi (M) · `zm_yunxia` Yunxia (M) · `zm_yunyang` Yunyang (M)

Default stays `af_heart`. (US English's 20 entries make the longest submenu;
acceptable. If it grates in practice we can split it Female/Male, but not up
front.)

### Changes by file

1. **`app/Sources/OpenWhisperer/MenuBarView.swift`.**
   - Replace the flat `static let voices: [(id, label)]` with a grouped
     `static let voiceGroups: [(group: String, options: [(id: String, label:
     String)])]` holding the roster above, plus a computed
     `static var allVoices: [(id, label)]` (flattened) for the collapsed-label
     lookup and the `.onAppear` membership validation (which currently does
     `Self.voices.contains { $0.id == voice }`).
   - Swap the Voice row's `OWMenuPicker` for a grouped variant (below).
2. **`OWMenuPicker` (same file) — add grouped rendering.** It is already a
   SwiftUI `Menu { ForEach … }`; add a second initializer / sibling
   `OWGroupedMenuPicker` that takes `groups: [(group, [(id, label)])]` and renders
   one nested `Menu(group.name)` per group, each containing the group's `Button`
   rows (checkmark on the selected id, same as today). The collapsed label looks
   the selected id up across all groups. No visual-style change — same
   `pickerBg`/border/chevron.

`ensureVoicePack` and the download path are **unchanged** — they already accept
any sanitized id.

## Approach — Part 2: Flavor

### Voice → language map (first character of the id)

`a`, `b` → English (skip) · `f` → French · `i` → Italian · `e` → Spanish · `p` →
Brazilian Portuguese · `h` → Hindi · `j` → Japanese · `z` → Mandarin Chinese.
Unknown/empty → skip (safe default: no addendum).

### Changes by file

3. **`hooks/voice-context.sh`.** After the `LEN` `case` and before emitting
   `NUDGE`:
   - Read the selected voice: `VOICE=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null |
     tr -d '[:space:]')`.
   - Map `${VOICE:0:1}` to a language name via a `case`; English/`a`/`b`/unknown
     leave `FLAVOR` empty.
   - For a non-English match, set `FLAVOR` to a short, self-gating addendum and
     append it to `NUDGE`, e.g.: *"The voice reading this aloud is \<Language\>.
     Unless your spoken sentence is already in \<Language\>, lightly flavor it the
     way a bilingual \<Language\> speaker naturally would — an occasional
     \<Language\> word or expression and a touch of native mannerism — kept
     subtle, never a caricature, and never at the expense of being understood."*
   - `FLAVOR` is appended regardless of `terse`/`normal`/`rich`/`full`, so it
     composes with every length setting.

This is the only speaking path that needs it: the addendum lands in the nudge the
model reads before calling `speak`, so the flavor ends up in the spoken summary
(what's actually voiced), not the on-screen reply.

4. **`AGENTS.md`.** Note in the TTS / voice-turn section that `voice-context.sh`
   now reads `tts_voice` and appends a native-tongue flavor addendum for
   non-English voices (always on, self-gating), and that the voice→language map
   lives only in the hook (no Swift parity pair). Update the picker/roster
   mention if the "6 voices" count appears anywhere.

## Data flow (flavor)

dictation → `voice_turn` hash written → `voice-context.sh` matches → builds the
speak-first nudge, reads `tts_voice`, appends the flavor addendum for a
non-English voice → model calls `speak(text)` with a lightly code-switched
sentence → in-process synth + playback (unchanged). English voice → no addendum,
identical to today.

## Sync points

- The roster's grouping in `MenuBarView.voiceGroups` and the hook's first-char
  language map share the Kokoro id-prefix convention; they are independent code
  but must agree on what each prefix means. Keep both in view when adding a
  language.
- `HookTests` is the guard for the flavor addendum (below).

## Testing

- **`swift run HookTests`** — extend `VoiceContextChecks`:
  - `tts_voice=ff_siwis` (voice turn, speak) → nudge contains the French flavor
    addendum ("French").
  - `tts_voice=af_heart` → **no** flavor addendum present.
  - `tts_voice` absent/unknown → no addendum, nudge otherwise unchanged.
- **`swift run OpenWhispererKitTests`** — unaffected; run as regression.
- **Manual (roster):** open the Voice picker, confirm the language submenus
  populate and a newly picked non-default voice downloads and plays on first use.
- **Manual (flavor):** select Siwis (French), dictate a turn, confirm the spoken
  summary drops in the occasional French touch while staying clear; switch to an
  English voice and confirm plain delivery.
