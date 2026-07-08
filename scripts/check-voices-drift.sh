#!/bin/bash
# Check if our static voice catalog has drifted from the remote HuggingFace repository
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REGISTRY_FILE="$PROJECT_DIR/app/Sources/OpenWhispererKit/TTSVoiceRegistry.swift"

echo "=== Fetching voices from HuggingFace ONNX repository ==="
HF_JSON=$(curl -s "https://huggingface.co/api/models/onnx-community/Kokoro-82M-v1.0-ONNX/tree/main/voices")

# Extract remote voices (exclude default/fallback 'af' which is not part of the 54 standard Kokoro-82M voices)
REMOTE_VOICES=$(echo "$HF_JSON" | jq -r '.[] | select(.type == "file") | .path | split("/")[-1] | split(".bin")[0]' | grep -v "^af$" | sort)

# Extract local voices from Swift file
LOCAL_VOICES=$(grep -o 'id: "[^"]*"' "$REGISTRY_FILE" | cut -d'"' -f2 | sort)

echo "=== Comparing catalogs ==="
DRIFT=0

# Check for remote voices missing locally
for voice in $REMOTE_VOICES; do
    if ! echo "$LOCAL_VOICES" | grep -q "^$voice$"; then
        echo "⚠️  Missing locally: $voice (available on HuggingFace)"
        DRIFT=1
    fi
done

# Check for local voices missing remotely
for voice in $LOCAL_VOICES; do
    if ! echo "$REMOTE_VOICES" | grep -q "^$voice$"; then
        echo "⚠️  Orphaned locally: $voice (not found on HuggingFace)"
        DRIFT=1
    fi
done

if [ $DRIFT -eq 0 ]; then
    echo "✅ Voice catalogs are in perfect sync!"
    exit 0
else
    echo "❌ Catalog drift detected."
    exit 1
fi
