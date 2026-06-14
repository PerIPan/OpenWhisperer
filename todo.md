# TTS Streaming (v1.4.0) — todo

Plan: `docs/superpowers/plans/2026-06-14-tts-streaming.md`
Spec: `docs/superpowers/specs/2026-06-14-tts-streaming-design.md`

## Phase 0 — Test scaffolding
- [ ] Task 0: install pytest into venv; add `tests/conftest.py` + `tests/__init__.py`

## Phase 1 — Server streaming core
- [ ] Task 1: `servers/tts_stream.py` — `pcm_bytes()` + `produce()` (TDD, 5 tests)

## Phase 2 — Server endpoint
- [ ] Task 2: `/v1/audio/stream` in `unified_server.py` (wire producer+queue+drain; manual curl smoke test)

## Phase 3 — Client player
- [ ] Task 3: `scripts/tts_stream_player.py` — `iter_frames()` + playback/signals/lifecycle (TDD pure, 3 tests)
- [ ] Task 4: player lifecycle subprocess tests (SIGTERM-fast, connect-fail fallback; 2 tests)

## Phase 4 — Barge-in / kill
- [ ] Task 5: extend `kill_tts()` to target the player (comm allow `python` + `pkill -f tts_stream_player`)

## Phase 5 — Hook + speak.sh integration
- [ ] Task 6: `tts-hook.sh` — capability gate + streaming branch + afplay fallback + prior-kill update
- [ ] Task 7: `codex-tts-hook.sh` — same integration
- [ ] Task 8: `speak.sh` — streaming when available, else afplay

## Phase 6 — Bundling
- [ ] Task 9: `build-dmg.sh` bundle `tts_stream.py` + `tts_stream_player.py`; reset capability markers on reinstall

## Phase 7 — Verification
- [ ] Task 10: full pytest suite + manual checklist (TTFA, gapless, barge-in <100ms, volume, fallback, all 3 entry points)
