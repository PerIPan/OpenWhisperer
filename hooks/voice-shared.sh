#!/bin/bash
# Shared logic for OpenWhisperer's voice-turn hooks: response-mode resolution, voice_turn
# hash-match-and-claim, style/voice/persona resolution, and nudge-sentence construction.
# Sourced by hooks/voice-context.sh (Claude Code + Codex UserPromptSubmit) and
# hooks/agy-previnvocation.sh (Antigravity CLI PreInvocation) — the two hooks differ in
# stdin/stdout shape but share this decision.

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisperer"
VOICE_TURN="$APP_SUPPORT/voice_turn"
# voice_turn time-to-live (seconds) — kept uniform across the hooks.
FRESHNESS=900

# Response mode. Precedence: per-project OW_TTS_RESPONSE env → global file → "voice".
resolve_mode() {
  local mode="$OW_TTS_RESPONSE"
  [ -z "$mode" ] && mode=$(cat "$APP_SUPPORT/tts_response_mode" 2>/dev/null | tr -d '[:space:]')
  [ -z "$mode" ] && mode="voice"
  printf '%s' "$mode"
}

# Determine whether THIS turn was voice-dictated: a fresh voice_turn whose hash matches the
# given prompt text. On a match, atomically claim (consume) the signal so a later typed turn
# isn't also matched. A stale signal is swept. Echoes "1" (matched+claimed) or "0" (no match).
# (Hashing MUST match VoiceSignal.canonicalHash.)
match_and_claim_voice_turn() {
  local prompt="$1"
  [ -f "$VOICE_TURN" ] || { echo 0; return; }
  local stored_hash stored_ts
  stored_hash=$(sed -n '1p' "$VOICE_TURN" 2>/dev/null)
  stored_ts=$(sed -n '2p' "$VOICE_TURN" 2>/dev/null)
  [ -z "$stored_hash" ] && { echo 0; return; }
  local now
  now=$(date +%s)
  if [ -n "$stored_ts" ] && [ "$((now - stored_ts))" -gt "$FRESHNESS" ]; then
    rm -f "$VOICE_TURN"
    echo 0
    return
  fi
  trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
  local trimmed prompt_hash
  trimmed=$(trim "$prompt")
  if command -v shasum >/dev/null 2>&1; then
    prompt_hash=$(printf '%s' "$trimmed" | shasum -a 256 | awk '{print $1}')
  else
    prompt_hash=$(printf '%s' "$trimmed" | openssl dgst -sha256 | awk '{print $NF}')
  fi
  if [ "$prompt_hash" = "$stored_hash" ]; then
    local claim="$APP_SUPPORT/.voice_turn.claimed.$$"
    if mv "$VOICE_TURN" "$claim" 2>/dev/null; then
      rm -f "$claim"
      echo 1
      return
    fi
  fi
  echo 0
}

# Spoken-summary length hint. Precedence: OW_TTS_STYLE env → tts_style file → legacy voice_detail.
resolve_length_phrase() {
  local style="$OW_TTS_STYLE"
  [ -z "$style" ] && style=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
  [ -z "$style" ] && style=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
  case "$style" in
    terse)     echo "one short, plain spoken sentence" ;;
    rich|full) echo "a sentence or two of plain spoken summary" ;;
    *)         echo "one plain spoken sentence" ;;
  esac
}

# Native-tongue flavor: for a personified voice, an ungated persona keyed off the voice id's
# first char: a light national character, set for English (a/b) too. The flavors stay subdued,
# so they don't detract from the message. Personality only, no vocabulary steering; whatever
# code-switching happens is the model's own.
# The map lives ONLY here (unknown/no voice → nothing); HookTests is its guard.
# Resolved voice: per-project OW_TTS_VOICE env → global tts_voice file.
resolve_flavor() {
  local voice="$OW_TTS_VOICE"
  [ -z "$voice" ] && voice=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null)
  voice=$(printf '%s' "$voice" | tr -d '[:space:]')
  local accent="" persona="" desc=""
  case "${voice:0:1}" in
    a) accent="American English";     persona="American";  desc="quietly self-assured, with a light touch of Silicon Valley hype" ;;
    b) accent="British English";      persona="British";   desc="dry and unflappable, with a streak of deadpan wit and gentle irony" ;;
    f) accent="French";               persona="French";    desc="dry and faintly unimpressed, given to the occasional philosophical shrug" ;;
    i) accent="Italian";              persona="Italian";   desc="warm and expressive; things are either wonderful or a small catastrophe, rarely in between" ;;
    e) accent="Spanish";              persona="Spanish";   desc="relaxed and direct; there's always time, and it'll all be fine" ;;
    p) accent="Brazilian Portuguese"; persona="Brazilian"; desc="sunny and easygoing, unbothered, always a friendly way around things" ;;
    h) accent="Hindi";                persona="Hindi";     desc="warm and irrepressibly helpful, the eternal problem-solver, assuring you it's no trouble at all" ;;
    j) accent="Japanese";             persona="Japanese";  desc="courteous and understated, meticulous, softening things, quietly prizing care and subtlety" ;;
    z) accent="Mandarin Chinese";     persona="Chinese";   desc="pragmatic and modest, understated, fond of a proverb, unfussed by small things" ;;
  esac
  if [ -n "$persona" ]; then
    echo " The voice speaking your reply has a ${accent} accent. Adopt a ${persona} persona: ${desc}."
  else
    echo ""
  fi
}

# Speak tool args → tell the model the exact voice/speed to pass to `speak` to prevent guesswork.
# We always explicitly instruct the model to pass the active voice (global or overridden).
resolve_speak_args() {
  local voice="$OW_TTS_VOICE"
  [ -z "$voice" ] && voice=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null)
  voice=$(printf '%s' "$voice" | tr -d '[:space:]')
  [ -z "$voice" ] && voice="af_heart"

  local ovr=" voice=\"$voice\""
  if [ -n "$OW_TTS_SPEED" ] && printf '%s' "$OW_TTS_SPEED" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    ovr="${ovr} speed=$OW_TTS_SPEED"
  fi
  echo " Call it with${ovr}."
}

# Build the full nudge sentence. $1 = IS_VOICE (0/1).
build_nudge() {
  local is_voice="$1"
  local len flavor speak_args prefix
  len=$(resolve_length_phrase)
  flavor=$(resolve_flavor)
  speak_args=$(resolve_speak_args)
  if [ "$is_voice" -eq 1 ]; then
    prefix="This turn was dictated by voice."
  else
    prefix="This reply should be spoken aloud."
  fi
  printf '%s Before writing your on-screen reply, your FIRST action must be to call the `speak` tool exactly once, passing %s that summarizes your answer and stands alone when heard.%s Then write your full reply on screen as usual. Do not skip the speak call, and do not mention the tool in your written reply.%s' \
    "$prefix" "$len" "$speak_args" "$flavor"
}
