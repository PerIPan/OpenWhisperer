#!/bin/bash
# Speaks text via the local native TTS server (synchronous CLI utility).
# Usage: echo "text" | ./speak.sh  OR  ./speak.sh "text to speak"
#
# This blocks until playback finishes: it synthesizes the whole clip (POST /v1/audio/speech → WAV)
# then plays it with afplay. The Stop / notify hooks instead POST /v1/audio/play for low-latency,
# sentence-streamed in-app playback; speak.sh stays a simple blocking helper.

TTS_URL="${TTS_URL:-http://localhost:8000/v1/audio/speech}"
VOICE="${TTS_VOICE:-af_heart}"
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
  -d "$(jq -n --arg t "$TEXT" --arg v "$VOICE" '{input: $t, voice: $v}')" \
  --output "$TMPFILE" 2>/dev/null
afplay -v "${TTS_VOLUME:-1}" "$TMPFILE" 2>/dev/null
rm -f "$TMPFILE"
