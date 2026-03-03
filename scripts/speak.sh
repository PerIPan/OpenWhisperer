#!/bin/bash
# Speaks text via local mlx_audio TTS server
# Usage: echo "text" | ./speak.sh  OR  ./speak.sh "text to speak"

TTS_URL="${TTS_URL:-http://localhost:8100/v1/audio/speech}"
VOICE="${TTS_VOICE:-af_heart}"
MODEL="${TTS_MODEL:-prince-canuma/Kokoro-82M}"
TMPFILE=$(mktemp /tmp/tts_XXXXXX.wav)

if [ -n "$1" ]; then
  TEXT="$*"
else
  TEXT=$(cat)
fi

[ -z "$TEXT" ] && exit 0

# Truncate very long text to avoid timeout
TEXT="${TEXT:0:2000}"

curl -s -X POST "$TTS_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$TEXT" --arg v "$VOICE" --arg m "$MODEL" '{model: $m, input: $t, voice: $v}')" \
  --output "$TMPFILE" 2>/dev/null

afplay "$TMPFILE" 2>/dev/null
rm -f "$TMPFILE"
