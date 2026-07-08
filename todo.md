# OpenWhisperer v1.5 — Checklist

Branch: `v1.5-native` · Plan: `docs/superpowers/plans/2026-06-24-v1.5.md`

## Done (this session, by Opus inline)
- [x] Merge Hakan's native rewrite as the v1.5 base (fast-forward, +67 commits)
- [x] Plan reviewed by architect-reviewer + swift-expert (read-only); decisions recorded in the plan
- [x] Delete stale Python `__pycache__` (scripts/ + servers/); remove empty `servers/`
- [x] Version bump 1.4.0 → 1.5.0 (Info.plist ×2 + build-dmg.sh)
- [x] Fix merged test compile error (PCMConversionChecks Float literal)
- [x] **Menubar reskin** to openwhisperer.com — warm gold/cream palette, Fraunces serif wordmark,
      full light + dark via dynamic tokens, ~15 component sites rethemed, WCAG-safe ink-on-gold
- [x] **Transcription overlay** rethemed to the warm surface
- [x] Foundation fixes: TTS gen-guard + playback-error lock clear, HTTP body cap + bind-failure
      surfaced, KokoroTTS voice-pack logging, AVAudioFormat guard, uniform 900s voice-turn TTL
- [x] **WhisperKit 0.18.0 → 1.0.0** (clean compile, both test suites green); FluidAudio already latest
- [x] README reframed to v1.5; tagless limitations documented in AGENTS.md
- [x] Build + `OpenWhispererKitTests` + `HookTests` green throughout

## Remaining (this session)
- [ ] Entitlements / Hardened-Runtime audit for notarization (NSSpeechRecognition string already present)
- [ ] Local self-signed DMG for the user to smoke-test
- [ ] Final work review (architect + swift, read-only) → Opus fixes real findings

## Needs the user
- [ ] Smoke-test on a Mac w/ mic: 3 dictation modes, streaming reply + barge-in, tagless turn,
      reskinned menu in light **and** dark, **first-run STT under WhisperKit 1.0** (BLOCKING gate —
      automated tests never run a real transcription). Revert if it misbehaves: set the Package.swift
      floor back to `0.18.0` **and** `swift package resolve` (two steps; Package.resolved is pinned).
- [ ] Apple Developer credentials → notarize + staple + cut the public v1.5 release
- [ ] Decide site update timing (after notarized DMG)
- [ ] Switch live hooks to tagless, then the `[VOICE:]` mandate in `~/.claude/CLAUDE.md` can go

## Dependency pins to revisit
- [ ] **Unpin FluidAudio** once a release *later than* `v0.15.4` includes commit `313feb4b`.
      It's currently pinned by `revision:` in `app/Package.swift` to the merge commit of
      [PR #730](https://github.com/FluidInference/FluidAudio/pull/730) (fixes garbled Kokoro on
      M3 — root cause [issue #727](https://github.com/FluidInference/FluidAudio/issues/727)).
      Both are merged/closed (2026-06-23) but **not yet in any tagged release** — latest tag
      `v0.15.4` (2026-06-16) predates the fix by ~12 commits. When a newer tag lands, revert
      `Package.swift` from `revision:` back to `from: "<new version>"` + `swift package resolve`.
      Check: `gh release list --repo FluidInference/FluidAudio --limit 5`.
