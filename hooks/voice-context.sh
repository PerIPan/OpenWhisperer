#!/bin/bash
# UserPromptSubmit hook (Claude Code + Codex) — decides whether THIS turn's reply is spoken and,
# if so, nudges the model to call the `speak` MCP tool FIRST with a standalone spoken summary.
#
# Response mode (tts_response_mode, or per-project OW_TTS_RESPONSE):
#   voice  (default) — speak only voice-dictated turns (prompt hash matches voice_turn)
#   text             — speak only typed turns (no fresh voice_turn match)
#   always           — speak every turn
# There is no Stop hook and no speak_pending marker: the model's own `speak` call is the audio.
# Both platforms pass {prompt, session_id, hook_event_name:"UserPromptSubmit"} and accept the
# {hookSpecificOutput:{additionalContext}} output, so one script serves both.
export LANG="${LANG:-en_US.UTF-8}"

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VOICE_TURN="$APP_SUPPORT/voice_turn"
# voice_turn time-to-live (seconds) — kept uniform across the hooks.
FRESHNESS=900

# Response mode. Precedence: per-project OW_TTS_RESPONSE env → global file → "voice".
MODE="$OW_TTS_RESPONSE"
[ -z "$MODE" ] && MODE=$(cat "$APP_SUPPORT/tts_response_mode" 2>/dev/null | tr -d '[:space:]')
[ -z "$MODE" ] && MODE="voice"

# Fast path: default "voice" mode with no pending dictation has nothing to do.
[ "$MODE" = "voice" ] && [ ! -f "$VOICE_TURN" ] && exit 0

# Find jq (system, then bundled next to the hooks dir).
if ! command -v jq >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else exit 0; fi
fi

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
[ -z "$PROMPT" ] && exit 0

# Determine whether THIS turn was voice-dictated: a fresh voice_turn whose hash matches the
# submitted prompt. On a match, atomically claim (consume) the signal so a later typed turn isn't
# also matched. A stale signal is swept. (Hashing MUST match VoiceSignal.canonicalHash.)
IS_VOICE=0
if [ -f "$VOICE_TURN" ]; then
  STORED_HASH=$(sed -n '1p' "$VOICE_TURN" 2>/dev/null)
  STORED_TS=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
  if [ -n "$STORED_HASH" ]; then
    NOW=$(date +%s)
    if [ -n "$STORED_TS" ] && [ "$((NOW - STORED_TS))" -gt "$FRESHNESS" ]; then
      rm -f "$VOICE_TURN"
    else
      trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
      TRIMMED=$(trim "$PROMPT")
      if command -v shasum >/dev/null 2>&1; then
        PROMPT_HASH=$(printf '%s' "$TRIMMED" | shasum -a 256 | awk '{print $1}')
      else
        PROMPT_HASH=$(printf '%s' "$TRIMMED" | openssl dgst -sha256 | awk '{print $NF}')
      fi
      if [ "$PROMPT_HASH" = "$STORED_HASH" ]; then
        CLAIM="$APP_SUPPORT/.voice_turn.claimed.$$"
        if mv "$VOICE_TURN" "$CLAIM" 2>/dev/null; then rm -f "$CLAIM"; IS_VOICE=1; fi
      fi
    fi
  fi
fi

# Decide whether to speak this turn, per Response mode.
SPEAK=0
case "$MODE" in
  always) SPEAK=1 ;;
  text)   [ "$IS_VOICE" -eq 0 ] && SPEAK=1 ;;
  *)      [ "$IS_VOICE" -eq 1 ] && SPEAK=1 ;;   # voice (default)
esac
[ "$SPEAK" -eq 1 ] || exit 0

# Spoken-summary length hint. Precedence: OW_TTS_STYLE env → tts_style file → legacy voice_detail.
STYLE="$OW_TTS_STYLE"
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
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
  # Occasional, NOT every turn: only ~1 in 5 voice turns carry the flavor line, so spoken
  # replies stay mostly plain and it never becomes a tic. OW_FLAVOR_ROLL pins the dice for tests.
  ROLL="${OW_FLAVOR_ROLL:-$((RANDOM % 5))}"
  if [ "$ROLL" -eq 0 ]; then
    FLAVOR=" The voice reading this aloud is ${FLAVOR_LANG}. If it feels natural, you may let a ${FLAVOR_LANG} word or expression slip into your spoken sentence the way a bilingual ${FLAVOR_LANG} speaker might — subtle, never forced, never a caricature, never at the expense of being understood. If nothing fits naturally, plain English is perfectly fine."
  fi
fi

if [ "$IS_VOICE" -eq 1 ]; then PREFIX="This turn was dictated by voice."; else PREFIX="This reply should be spoken aloud."; fi
NUDGE="${PREFIX} Before writing your on-screen reply, your FIRST action must be to call the \`speak\` tool exactly once, passing ${LEN} that summarizes your answer and stands alone when heard. Then write your full reply on screen as usual. Do not skip the speak call, and do not mention the tool in your written reply.${FLAVOR}"

jq -n --arg ctx "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}'
exit 0
