#!/bin/bash
# Start both STT and TTS servers for Claude Voice Mode
# Usage: ./start-servers.sh [venv_path]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PATH="${1:-$HOME/mlx-openai-whisper}"

if [ ! -f "$VENV_PATH/bin/activate" ]; then
  echo "Error: Virtual environment not found at $VENV_PATH"
  echo "Usage: $0 [path/to/venv]"
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

echo ""
echo "Both servers running. Press Ctrl+C to stop both."

trap "kill $STT_PID $TTS_PID 2>/dev/null; exit" INT TERM
wait
