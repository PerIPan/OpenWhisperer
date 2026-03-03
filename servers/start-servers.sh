#!/bin/bash
# Start STT + TTS servers and voice input for Claude Voice Mode
# Usage: ./start-servers.sh [venv_path]
#        ./start-servers.sh --no-voice [venv_path]   (servers only)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

NO_VOICE=false
if [ "$1" = "--no-voice" ]; then
  NO_VOICE=true
  shift
fi

VENV_PATH="${1:-$HOME/mlx-openai-whisper}"

if [ ! -f "$VENV_PATH/bin/activate" ]; then
  echo "Error: Virtual environment not found at $VENV_PATH"
  echo "Usage: $0 [--no-voice] [path/to/venv]"
  exit 1
fi

source "$VENV_PATH/bin/activate"

STT_PORT="${STT_PORT:-8000}"
TTS_PORT="${TTS_PORT:-8100}"

echo "Starting Whisper STT on http://localhost:$STT_PORT"
python "$SCRIPT_DIR/whisper_server.py" &
STT_PID=$!

echo "Starting TTS on http://localhost:$TTS_PORT"
mlx_audio.server --host 0.0.0.0 --port "$TTS_PORT" &
TTS_PID=$!

VOICE_PID=""
if [ "$NO_VOICE" = false ]; then
  # Wait for STT server to be ready
  echo "Waiting for Whisper server..."
  for i in $(seq 1 30); do
    curl -s "http://localhost:$STT_PORT/models" > /dev/null 2>&1 && break
    sleep 1
  done

  echo "Starting voice input (Whisper-powered, auto-submit, loop mode)"
  echo "Focus the Claude Code input field — voice input is live."
  python "$REPO_DIR/scripts/voice-input.py" --loop --silence 1.5 &
  VOICE_PID=$!
fi

echo ""
echo "Claude Voice Mode is live. Press Ctrl+C to stop all."

trap "kill $STT_PID $TTS_PID $VOICE_PID 2>/dev/null; exit" INT TERM
wait
