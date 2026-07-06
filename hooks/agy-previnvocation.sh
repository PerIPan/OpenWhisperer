#!/bin/bash
# PreInvocation hook (Antigravity CLI / agy) — fires before every model call in the agent loop.
# invocationNum resets to 0 at the start of each new user turn (confirmed live 2026-07-06: one
# session produced three turns, each starting invocationNum=0, while a separate initialNumSteps
# field climbed monotonically across all of them), so we gate on that to behave like a
# once-per-turn hook. No prompt text is given on stdin; it's read from transcriptPath's last
# USER_EXPLICIT entry instead. See voice-shared.sh for the shared mode/hash/style/voice/flavor
# logic also used by voice-context.sh (Claude Code + Codex).
export LANG="${LANG:-en_US.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/voice-shared.sh"

if ! command -v jq >/dev/null 2>&1; then
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else echo '{}'; exit 0; fi
fi

INPUT=$(cat)
INVOCATION_NUM=$(printf '%s' "$INPUT" | jq -r '.invocationNum // empty')
[ "$INVOCATION_NUM" = "0" ] || { echo '{}'; exit 0; }

MODE=$(resolve_mode)
[ "$MODE" = "voice" ] && [ ! -f "$VOICE_TURN" ] && { echo '{}'; exit 0; }

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcriptPath // empty')
PROMPT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  LAST=$(jq -c 'select(.source=="USER_EXPLICIT")' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
  if [ -n "$LAST" ]; then
    CONTENT=$(printf '%s' "$LAST" | jq -r '.content // empty')
    PROMPT=$(printf '%s' "$CONTENT" | sed -n '/<USER_REQUEST>/,/<\/USER_REQUEST>/p' | sed '1d;$d')
  fi
fi
[ -z "$PROMPT" ] && { echo '{}'; exit 0; }

IS_VOICE=$(match_and_claim_voice_turn "$PROMPT")

SPEAK=0
case "$MODE" in
  always) SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;
esac
[ "$SPEAK" -eq 1 ] || { echo '{}'; exit 0; }

NUDGE=$(build_nudge "$IS_VOICE")

jq -n --arg msg "$NUDGE" '{injectSteps: [{ephemeralMessage: $msg}]}'
exit 0
