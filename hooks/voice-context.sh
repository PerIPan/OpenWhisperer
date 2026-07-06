#!/bin/bash
# UserPromptSubmit hook (Claude Code + Codex) — decides whether THIS turn's reply is spoken and,
# if so, nudges the model to call the `speak` MCP tool FIRST with a standalone spoken summary.
#
# Response mode (tts_response_mode, or per-project OW_TTS_RESPONSE):
#   voice  (default) — speak only voice-dictated turns (prompt hash matches voice_turn)
#   always           — speak every turn
# There is no Stop hook and no speak_pending marker: the model's own `speak` call is the audio.
# Both platforms pass {prompt, session_id, hook_event_name:"UserPromptSubmit"} and accept the
# {hookSpecificOutput:{additionalContext}} output, so one script serves both.
#
# The mode/hash/style/voice/flavor logic lives in voice-shared.sh, shared with
# agy-previnvocation.sh (Antigravity CLI), which has a different stdin/stdout shape but the same
# underlying decision.
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/voice-shared.sh"

MODE=$(resolve_mode)

# Fast path: default "voice" mode with no pending dictation has nothing to do.
[ "$MODE" = "voice" ] && [ ! -f "$VOICE_TURN" ] && exit 0

# Find jq (system, then bundled next to the hooks dir).
if ! command -v jq >/dev/null 2>&1; then
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else exit 0; fi
fi

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
[ -z "$PROMPT" ] && exit 0

IS_VOICE=$(match_and_claim_voice_turn "$PROMPT")

# Decide whether to speak this turn, per Response mode.
SPEAK=0
case "$MODE" in
  always) SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;   # voice (default); a stale "text" falls here
esac
[ "$SPEAK" -eq 1 ] || exit 0

NUDGE=$(build_nudge "$IS_VOICE")

jq -n --arg ctx "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}'
exit 0
