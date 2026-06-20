#!/bin/bash
# UserPromptSubmit hook (Claude Code) — voice-turn detection via content-correlation.
# If the submitted prompt matches the hash the app recorded for the last dictation,
# THIS session is the voice turn: nudge the model (hidden from the transcript) and
# mark the session so the Stop hook speaks the reply's first paragraph.
export LANG="${LANG:-en_US.UTF-8}"

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VOICE_TURN="$APP_SUPPORT/voice_turn"
PENDING_DIR="$APP_SUPPORT/speak_pending"
FRESHNESS=300

# Fast path for typed turns: no pending dictation → nothing to do.
[ -f "$VOICE_TURN" ] || exit 0

# Find jq (system, then bundled next to the hooks dir).
if ! command -v jq >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then export PATH="$(dirname "$BUNDLED_JQ"):$PATH"; else exit 0; fi
fi

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -z "$PROMPT" ] && exit 0
[ -z "$SESSION_ID" ] && exit 0

STORED_HASH=$(sed -n '1p' "$VOICE_TURN" 2>/dev/null)
STORED_TS=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
[ -z "$STORED_HASH" ] && exit 0

# Freshness: drop a stale signal and bail.
NOW=$(date +%s)
if [ -n "$STORED_TS" ] && [ "$((NOW - STORED_TS))" -gt "$FRESHNESS" ]; then
  rm -f "$VOICE_TURN"
  exit 0
fi

# Hash the trimmed prompt — must match VoiceSignal.canonicalHash.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
TRIMMED=$(trim "$PROMPT")
if command -v shasum >/dev/null 2>&1; then
  PROMPT_HASH=$(printf '%s' "$TRIMMED" | shasum -a 256 | awk '{print $1}')
else
  PROMPT_HASH=$(printf '%s' "$TRIMMED" | openssl dgst -sha256 | awk '{print $NF}')
fi
[ "$PROMPT_HASH" = "$STORED_HASH" ] || exit 0   # not the voice turn

# Atomic claim: only one session wins even if two submit identical text.
CLAIM="$APP_SUPPORT/.voice_turn.claimed.$$"
mv "$VOICE_TURN" "$CLAIM" 2>/dev/null || exit 0
rm -f "$CLAIM"

# Mark this session for the Stop hook.
mkdir -p "$PENDING_DIR"
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_.-' '_')
: > "$PENDING_DIR/$SAFE_ID"

# Spoken-summary style. Precedence: per-project OW_TTS_STYLE env → global
# tts_style file → legacy voice_detail. Shapes the nudge wording here; the Stop
# hooks read the same style to choose first-paragraph vs. whole-reply extraction.
STYLE="$OW_TTS_STYLE"
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
case "$STYLE" in
  full)
    NUDGE="This turn was dictated by voice and your entire reply will be read aloud. Write the whole reply as natural spoken prose: short sentences, expand acronyms, avoid AI-isms and filler, and keep code, file paths, and tables out of the spoken flow — describe them in words instead. Do not write a separate summary."
    ;;
  terse) LEN="one short, plain spoken sentence" ;;
  rich)  LEN="a sentence or two of plain spoken summary" ;;
  *)     LEN="one plain spoken sentence" ;;
esac
# terse/normal/rich build the summary nudge from LEN; full sets NUDGE directly above.
[ -z "$NUDGE" ] && NUDGE="This turn was dictated by voice and your reply will be read aloud. Open with ${LEN} that stands alone as a summary; details can follow."

# additionalContext is visible to the model; suppressOutput keeps it out of the transcript.
jq -n --arg ctx "$NUDGE" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}'
exit 0
