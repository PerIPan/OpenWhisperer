#!/bin/bash
# UserPromptSubmit hook (Claude Code) — decides whether THIS turn's reply is spoken
# and nudges the model accordingly.
#
# Response mode (tts_response_mode, or per-project OW_TTS_RESPONSE):
#   voice  (default) — speak only voice-dictated turns (prompt hash matches voice_turn)
#   text             — speak only typed turns (no fresh voice_turn match)
#   always           — speak every turn
# On "speak", mark the session (speak_pending/<id>) so the Stop hook reads the reply,
# and inject a hidden nudge so the reply opens with a standalone spoken summary.
export LANG="${LANG:-en_US.UTF-8}"

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VOICE_TURN="$APP_SUPPORT/voice_turn"
PENDING_DIR="$APP_SUPPORT/speak_pending"
# voice_turn time-to-live (seconds). Matched to the speak_pending sweep (15 min) in
# tts-hook.sh so a dictate → review → submit pause in manual-submit mode still speaks.
FRESHNESS=900

# Response mode. Precedence: per-project OW_TTS_RESPONSE env → global tts_response_mode
# file → default "voice".
MODE="$OW_TTS_RESPONSE"
[ -z "$MODE" ] && MODE=$(cat "$APP_SUPPORT/tts_response_mode" 2>/dev/null | tr -d '[:space:]')
[ -z "$MODE" ] && MODE="voice"

# Fast path: in the default "voice" mode, a typed turn with no pending dictation has
# nothing to do — skip jq/hashing entirely (preserves prior behavior + cost).
[ "$MODE" = "voice" ] && [ ! -f "$VOICE_TURN" ] && exit 0

# Find jq (system, then bundled next to the hooks dir).
if ! command -v jq >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else exit 0; fi
fi

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .conversationId // empty')
[ -z "$PROMPT" ] && exit 0
[ -z "$SESSION_ID" ] && exit 0

# Determine whether THIS turn was voice-dictated: a fresh voice_turn whose hash matches
# the submitted prompt. On a match, atomically claim (consume) the signal so a later
# typed turn isn't also matched. A stale signal is swept.
IS_VOICE=0
if [ -f "$VOICE_TURN" ]; then
  STORED_HASH=$(sed -n '1p' "$VOICE_TURN" 2>/dev/null)
  STORED_TS=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
  if [ -n "$STORED_HASH" ]; then
    NOW=$(date +%s)
    if [ -n "$STORED_TS" ] && [ "$((NOW - STORED_TS))" -gt "$FRESHNESS" ]; then
      rm -f "$VOICE_TURN"
    else
      # Hash the trimmed prompt — must match VoiceSignal.canonicalHash.
      trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
      TRIMMED=$(trim "$PROMPT")
      if command -v shasum >/dev/null 2>&1; then
        PROMPT_HASH=$(printf '%s' "$TRIMMED" | shasum -a 256 | awk '{print $1}')
      else
        PROMPT_HASH=$(printf '%s' "$TRIMMED" | openssl dgst -sha256 | awk '{print $NF}')
      fi
      if [ "$PROMPT_HASH" = "$STORED_HASH" ]; then
        CLAIM="$APP_SUPPORT/.voice_turn.claimed.$$"
        if mv "$VOICE_TURN" "$CLAIM" 2>/dev/null; then
          rm -f "$CLAIM"
          IS_VOICE=1
        fi
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

# Mark this session for the Stop hook.
mkdir -p "$PENDING_DIR"
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_.-' '_')
: > "$PENDING_DIR/$SAFE_ID"

# Spoken-summary style. Precedence: per-project OW_TTS_STYLE env → global tts_style file
# → legacy voice_detail. Shapes the nudge wording here; the Stop hooks read the same style
# to choose first-paragraph vs. whole-reply extraction.
STYLE="$OW_TTS_STYLE"
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')

# Lead clause reflects how the turn was entered (dictated turns say so; typed turns don't).
if [ "$IS_VOICE" -eq 1 ]; then LEAD="This turn was dictated by voice and"; else LEAD="Your reply will be read aloud:"; fi

if [ "$STYLE" = "full" ]; then
  NUDGE="${LEAD} your entire reply will be read aloud. Write the whole reply as natural spoken prose: short sentences, expand acronyms, avoid AI-isms and filler, and keep code, file paths, and tables out of the spoken flow — describe them in words instead. Do not write a separate summary."
else
  case "$STYLE" in
    terse) LEN="one short, plain spoken sentence" ;;
    rich)  LEN="a sentence or two of plain spoken summary" ;;
    *)     LEN="one plain spoken sentence" ;;
  esac
  NUDGE="${LEAD} ONLY your first paragraph is read aloud. Open with ${LEN} that stands alone as the spoken summary, then a blank line before any further detail (everything after the blank line stays on screen, unspoken)."
fi

# additionalContext is visible to the model; suppressOutput keeps it out of the transcript.
jq -n --arg ctx "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}'
exit 0
