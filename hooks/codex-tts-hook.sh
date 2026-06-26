#!/bin/bash
# Codex CLI notify hook — speaks the last response via the in-app native TTS player.
# Codex passes the JSON payload as the last CLI argument with "last-assistant-message". A dictated
# turn is marked by the app's voice_turn signal; this hook extracts the first paragraph and POSTs it
# to the app, which synthesizes sentence-by-sentence and plays in-process (no PID/afplay).

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"

# Find jq: system PATH first, then bundled in app
if ! command -v jq &>/dev/null; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  BUNDLED_JQ="$(dirname "$SCRIPT_DIR")/jq"
  if [ -x "$BUNDLED_JQ" ]; then
    export PATH="$(dirname "$BUNDLED_JQ"):$PATH"
  else
    exit 0  # no jq available, skip TTS
  fi
fi

# Codex notify: JSON payload comes as the last CLI argument
INPUT="${!#}"
if [ -z "$INPUT" ] || [ "$INPUT" = "$0" ]; then INPUT=$(cat); fi
[ -z "$INPUT" ] && exit 0
TYPE=$(echo "$INPUT" | jq -r '.type // empty' 2>/dev/null)
if [ "$TYPE" != "agent-turn-complete" ] && [ -n "$TYPE" ]; then exit 0; fi

# --- Voice-turn gate: Codex has no per-prompt session id, so gate on the app's voice_turn signal
#     (presence + freshness) and clear it so future typed turns are not spoken. ---
# Response mode: per-project OW_TTS_RESPONSE env → global tts_response_mode → "voice".
MODE="$OW_TTS_RESPONSE"
[ -z "$MODE" ] && MODE=$(cat "$APP_SUPPORT/tts_response_mode" 2>/dev/null | tr -d '[:space:]')
[ -z "$MODE" ] && MODE="voice"
VOICE_TURN="$APP_SUPPORT/voice_turn"
# voice_turn TTL (s) — kept uniform with voice-context.sh + the 15-min speak_pending sweep.
VOICE_FRESHNESS=900
# Is this a fresh dictated turn? Claim (consume) the signal so future turns aren't it.
IS_VOICE=0
if [ -f "$VOICE_TURN" ]; then
  VT_TS=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
  NOW=$(date +%s)
  if [ -n "$VT_TS" ] && [ "$((NOW - VT_TS))" -gt "$VOICE_FRESHNESS" ]; then
    rm -f "$VOICE_TURN"            # stale → treat as typed
  else
    IS_VOICE=1
    rm -f "$VOICE_TURN"           # claim
  fi
fi
case "$MODE" in
  always) ;;                                   # speak every turn
  text)   [ "$IS_VOICE" -eq 1 ] && exit 0 ;;   # text mode: dictated turns stay silent
  *)      [ "$IS_VOICE" -eq 1 ] || exit 0 ;;   # voice (default): typed turns stay silent
esac

# Codex uses "last-assistant-message" (hyphenated key)
TEXT=$(echo "$INPUT" | jq -r '.["last-assistant-message"] // .last_assistant_message // empty' 2>/dev/null)
[ -z "$TEXT" ] && exit 0
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# Spoken-text style. Precedence: per-project OW_TTS_STYLE env → global tts_style file →
# legacy voice_detail. 'full' speaks the whole reply; everything else, the first paragraph.
STYLE="$OW_TTS_STYLE"
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
[ -z "$STYLE" ] && STYLE=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
if [ "$STYLE" = "full" ]; then
  SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh" --full)
else
  SPEECH=$(printf '%s' "$TEXT" | "$HOOK_DIR/speakable-text.sh")
fi
[ -z "$SPEECH" ] && exit 0

# Resolve voice (volume is applied app-side now).
VOICE_FILE="$APP_SUPPORT/tts_voice"
if [ -f "$VOICE_FILE" ] && [ ! -L "$VOICE_FILE" ]; then
  VOICE="$(cat "$VOICE_FILE" 2>/dev/null | tr -d '[:space:]')"; VOICE="${VOICE:-${TTS_VOICE:-af_heart}}"
else
  VOICE="${TTS_VOICE:-af_heart}"
fi

# POST to the in-app player (loopback only). Fire-and-forget: the app returns 202 immediately,
# then synthesizes + plays in-process and owns tts_playing.lock.
PLAY_URL="${TTS_PLAY_URL:-http://localhost:8000/v1/audio/play}"
case "$PLAY_URL" in
  http://localhost:*|http://127.0.0.1:*) ;;
  *) PLAY_URL="http://localhost:8000/v1/audio/play" ;;
esac

PAYLOAD="$(jq -n --arg t "$SPEECH" --arg v "$VOICE" '{input: $t, voice: $v}')"
curl -s -X POST "$PLAY_URL" -H "Content-Type: application/json" -d "$PAYLOAD" --max-time 5 >/dev/null 2>&1 &

exit 0
