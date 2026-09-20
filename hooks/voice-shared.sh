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
#   voice  (default) — speak only voice-dictated turns
#   always           — speak every turn
#   needed           — every turn is a candidate, but the model speaks only when the turn
#                      ends on the user (question / blocked / approval / failure). The gate
#                      lives in the nudge because this hook cannot see the turn's outcome.
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
  # Bash re-evaluates variable contents inside $(( )), so an array subscript in this field
  # would run command substitution: a voice_turn holding `x[$(...)]` executes it. The file
  # sits in a 0700 dir and is app-written, so nothing crosses a privilege boundary — but it
  # is the documented cross-process IPC bus, which makes this an easy sink to forget.
  case "$stored_ts" in ''|*[!0-9]*) stored_ts=0 ;; esac
  local now
  now=$(date +%s)
  if [ "$stored_ts" -gt 0 ] && [ "$((now - stored_ts))" -gt "$FRESHNESS" ]; then
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
    terse) echo "one short, plain spoken sentence" ;;
    rich)  echo "a sentence or two of plain spoken summary" ;;
    # `full` used to fold into `rich`; since 2.0.0 it is its own, longest tier. Anyone
    # carrying the legacy value asked for maximum detail, so promoting them is a
    # restoration of that intent rather than a surprise.
    full)  echo "a spoken paragraph of four or five sentences" ;;
    *)     echo "one plain spoken sentence" ;;
  esac
}

# Depth nudge for the longest tier only. The base sentence asks for something that
# "summarizes your answer", which on its own would cap `full` at a longer summary —
# this tells the model to actually explain. Empty for every other tier.
resolve_depth_line() {
  local style="$OW_TTS_STYLE"
  [ -z "$style" ] && style=$(cat "$APP_SUPPORT/tts_style" 2>/dev/null | tr -d '[:space:]')
  [ -z "$style" ] && style=$(cat "$APP_SUPPORT/voice_detail" 2>/dev/null | tr -d '[:space:]')
  if [ "$style" = "full" ]; then
    echo " Use that paragraph to explain your reasoning and any trade-offs, not just the conclusion — but keep it spoken prose, with no lists, headings, code, or file paths."
  else
    echo ""
  fi
}

# Native-tongue flavor: for a personified voice, an ungated persona keyed off the voice id's
# first char: a light national character, set for English (a/b) too. The flavors stay subdued,
# so they don't detract from the message. Personality only, no vocabulary steering; whatever
# code-switching happens is the model's own.
# This map is the source of truth for what the model is told (unknown/no voice → nothing).
# `VoicePersona` in OpenWhispererKit mirrors it for display only, so Settings can disclose the
# persona a voice carries; reword here first. HookTests' voicePersonaParityFailures() parses
# these arms and fails if the two drift.
# Resolved voice: per-project OW_TTS_VOICE env → global tts_voice file.
resolve_flavor() {
  local voice="$OW_TTS_VOICE"
  [ -z "$voice" ] && voice=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null)
  voice=$(printf '%s' "$voice" | tr -d '[:space:]')

  # Explicit persona wins over the voice's own. Per-project OW_TTS_PERSONA env → global
  # tts_persona file → "auto" (follow the voice), which is also what an absent file means.
  local override="$OW_TTS_PERSONA"
  [ -z "$override" ] && override=$(cat "$APP_SUPPORT/tts_persona" 2>/dev/null)
  override=$(printf '%s' "$override" | tr -d '[:space:]' | tr 'A-Z' 'a-z')

  # One case, two kinds of key: the Kokoro voice-id first character for the automatic path,
  # and the persona id for an override. Single chars and words cannot collide, so they share
  # arms. This is the shape issue #39 proposes for keying Supertonic voices by language code.
  # Try the override first, then the voice's own prefix. One `case`, walked at most twice,
  # so an unrecognized override degrades to the voice instead of stripping the persona —
  # and there is no second copy of the map to drift out of sync with this one.
  local primary="${voice:0:1}" chose_override=0
  [ -n "$override" ] && [ "$override" != "auto" ] && primary="$override" && chose_override=1

  local accent="" persona="" desc="" key
  for key in "$primary" "${voice:0:1}"; do
  case "$key" in
    a|american)  accent="American English";     persona="American";  desc="quietly self-assured, with a light touch of Silicon Valley hype" ;;
    b|british)   accent="British English";      persona="British";   desc="dry and unflappable, with a streak of deadpan wit and gentle irony" ;;
    f|french)    accent="French";               persona="French";    desc="dry and faintly unimpressed, given to the occasional philosophical shrug" ;;
    i|italian)   accent="Italian";              persona="Italian";   desc="warm and expressive; things are either wonderful or a small catastrophe, rarely in between" ;;
    e|spanish)   accent="Spanish";              persona="Spanish";   desc="relaxed and direct; there's always time, and it'll all be fine" ;;
    p|brazilian) accent="Brazilian Portuguese"; persona="Brazilian"; desc="sunny and easygoing, unbothered, always a friendly way around things" ;;
    h|hindi)     accent="Hindi";                persona="Hindi";     desc="warm and irrepressibly helpful, the eternal problem-solver, assuring you it's no trouble at all" ;;
    j|japanese)  accent="Japanese";             persona="Japanese";  desc="courteous and understated, meticulous, softening things, quietly prizing care and subtlety" ;;
    z|chinese)   accent="Mandarin Chinese";     persona="Chinese";   desc="pragmatic and modest, understated, fond of a proverb, unfussed by small things" ;;
    dutch)       accent="Dutch";                persona="Dutch";     desc="direct to the point of bluntness and considers that a courtesy; says the plain thing and trusts you can take it" ;;
    german)      accent="German";               persona="German";    desc="precise and thorough, quietly certain there is a correct way; jokes arrive deadpan and structurally sound" ;;
    polish)      accent="Polish";               persona="Polish";    desc="warm underneath a matter-of-fact surface; expects the worst, copes admirably, mentions neither" ;;
    russian)     accent="Russian";              persona="Russian";   desc="sombre and unhurried, fond of a bleak aphorism, unimpressed by enthusiasm" ;;
    turkish)     accent="Turkish";              persona="Turkish";   desc="hospitable and generous with reassurance; takes personal responsibility for your comfort" ;;
    finnish)     accent="Finnish";              persona="Finnish";   desc="sparing with words, comfortable with silence; says the necessary thing and stops" ;;
    korean)      accent="Korean";               persona="Korean";    desc="brisk and thorough, quietly competitive about doing it properly" ;;
    greek)       accent="Greek";                persona="Greek";     desc="expansive and quick to debate, always warmly; takes the long view, having watched empires come and go" ;;
  esac
    # Matched on the first pass? Then the override (if any) stuck. Matched only on the
    # second? The override was unrecognized, so this is really the automatic path.
    if [ -n "$persona" ]; then break; fi
    chose_override=0
  done

  if [ -z "$persona" ]; then
    echo ""
  elif [ "$chose_override" -eq 1 ]; then
    # Overridden: say nothing about the accent. It comes from the voice, not this persona,
    # and naming the persona's own accent here would describe a voice that isn't speaking.
    # Keeps the "voice speaking your reply" sentinel HookTests keys on.
    echo " Adopt $(article "$persona") ${persona} persona for the voice speaking your reply: ${desc}."
  else
    echo " The voice speaking your reply has $(article "$accent") ${accent} accent. Adopt $(article "$persona") ${persona} persona: ${desc}."
  fi
}

# "a" or "an" for the word that follows: "an American English accent", "a British persona".
# Initial letter only — none of the names above start with a silent h or a "you" sound.
article() {
  case "$1" in
    [AEIOUaeiou]*) echo "an" ;;
    *) echo "a" ;;
  esac
}


# Reply language for the multilingual (Supertonic) voices. A Dutch voice reading English text is
# pointless, so when one of those voices is active we tell the model to write the spoken summary
# in that language. The language rides inside the voice id (`supertonic:<lang>:<style>`), so this
# is a plain code→name lookup rather than the first-char scheme resolve_flavor uses for Kokoro.
#
# Like the persona map, this lives ONLY here — no Swift parity pair — and HookTests is its guard.
# Kokoro voices are unaffected (their language is implied by the voice and the model already
# replies in the user's language); `en` gets no line since English is the default.
resolve_language_line() {
  # The reply language has two layers. A *pin* — per-project OW_TTS_LANGUAGE, else the global
  # tts_language file — names the language every spoken reply is written in, whatever the
  # conversation is in. Without a pin, a Supertonic voice's own language is only the *default*:
  # the model may switch when asked or when the conversation is in another language, because
  # the engine follows the language of the text it is handed (TTSLanguageFollow in the app),
  # not the language fused into the voice id. Kokoro voices get no line at all; an English
  # Supertonic voice gets none either (English is already the default).
  local pin="$OW_TTS_LANGUAGE"
  [ -z "$pin" ] && pin=$(cat "$APP_SUPPORT/tts_language" 2>/dev/null)
  # Normalize the pin: whitespace, case, and a BCP-47 region/script subtag (`pt-BR`, `pt_BR`
  # → `pt`). `english` stays accepted — the first cut of OW_TTS_LANGUAGE took it, and a
  # hand-written tts_language file may still say so. Codes are the contract otherwise.
  pin=$(printf '%s' "$pin" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | cut -d- -f1 | cut -d_ -f1)
  [ "$pin" = "english" ] && pin="en"

  local voice="$OW_TTS_VOICE"
  [ -z "$voice" ] && voice=$(cat "$APP_SUPPORT/tts_voice" 2>/dev/null)
  voice=$(printf '%s' "$voice" | tr -d '[:space:]')
  local vcode=""
  case "$voice" in
    supertonic:*|SUPERTONIC:*) vcode=$(printf '%s' "$voice" | cut -d: -f2 | tr '[:upper:]' '[:lower:]') ;;
  esac

  # One code → name map, consulted for the pin first and the voice second. Keep the arms in
  # their current shape (code, close-paren, language=name): HookTests parses them for parity
  # with TTSVoiceRegistry's group names and the Pi extension's LANGUAGES map.
  local kind code language
  for kind in pin voice; do
    if [ "$kind" = "pin" ]; then code="$pin"; else code="$vcode"; fi
    [ -z "$code" ] && continue
    language=""
    case "$code" in
      en) language="English" ;;
      nl) language="Dutch" ;;      de) language="German" ;;      pl) language="Polish" ;;
      ru) language="Russian" ;;    uk) language="Ukrainian" ;;   fr) language="French" ;;
      it) language="Italian" ;;    es) language="Spanish" ;;     pt) language="Portuguese" ;;
      hi) language="Hindi" ;;      ja) language="Japanese" ;;    ko) language="Korean" ;;
      ar) language="Arabic" ;;     bg) language="Bulgarian" ;;   cs) language="Czech" ;;
      da) language="Danish" ;;     el) language="Greek" ;;       et) language="Estonian" ;;
      fi) language="Finnish" ;;    hr) language="Croatian" ;;    hu) language="Hungarian" ;;
      id) language="Indonesian" ;; lt) language="Lithuanian" ;;  lv) language="Latvian" ;;
      ro) language="Romanian" ;;   sk) language="Slovak" ;;      sl) language="Slovenian" ;;
      sv) language="Swedish" ;;    tr) language="Turkish" ;;     vi) language="Vietnamese" ;;
    esac
    [ -z "$language" ] && continue
    # Sentinel phrase "Write the text you pass to `speak` in" is kept distinct from
    # resolve_flavor's "voice speaking your reply" so the two layers stay independently
    # assertable in HookTests.
    if [ "$kind" = "pin" ]; then
      echo " Write the text you pass to \`speak\` in ${language}, whatever language the conversation is in. Your on-screen reply stays in the language of the conversation."
      return
    fi
    [ "$code" = "en" ] && { echo ""; return; }
    echo " Write the text you pass to \`speak\` in ${language} by default — that is the selected voice's language — but switch to whatever language I ask for or the conversation is in; the voice follows the language you write. Your on-screen reply stays in the language of the conversation."
    return
  done
  echo ""
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
  # Conditional wording in "needed" mode: an unconditional "Call it with…" directly after
  # "do NOT call the tool at all" reads as a contradictory imperative.
  if [ "$(resolve_mode)" = "needed" ]; then
    echo " If you do speak, call it with${ovr}."
  else
    echo " Call it with${ovr}."
  fi
}

# Build the full nudge sentence. $1 = IS_VOICE (0/1).
build_nudge() {
  local is_voice="$1"
  local mode len flavor speak_args lang_line depth_line prefix core
  mode=$(resolve_mode)
  len=$(resolve_length_phrase)
  flavor=$(resolve_flavor)
  speak_args=$(resolve_speak_args)
  lang_line=$(resolve_language_line)
  depth_line=$(resolve_depth_line)

  if [ "$mode" = "needed" ]; then
    # "Only when I'm needed" cannot be decided here: this hook runs at prompt-submit,
    # before the turn exists, and there is deliberately no Stop hook. So the gate is
    # delegated to the model, which knows while composing whether the turn ends on the
    # user. Same accepted trade as the rest of the handshake — no fallback either way.
    prefix="Speak this reply ONLY if it needs something from me."
    core=$(printf 'First decide whether this turn ends on me: you are asking a question, you are blocked, you need my approval for something risky or destructive, or something failed and I have to choose what happens next. If so, your FIRST action must be to call the `speak` tool exactly once, passing %s that says plainly what you need from me and stands alone when heard.%s If instead the work simply succeeded and needs nothing from me, do NOT call the tool at all — staying silent is the correct outcome, and a spoken "all done" is exactly what this mode exists to avoid.' \
      "$len" "$depth_line")
  else
    if [ "$is_voice" -eq 1 ]; then
      prefix="This turn was dictated by voice."
    else
      prefix="This reply should be spoken aloud."
    fi
    core=$(printf 'Before writing your on-screen reply, your FIRST action must be to call the `speak` tool exactly once, passing %s that summarizes your answer and stands alone when heard.%s Do not skip the speak call.' \
      "$len" "$depth_line")
  fi

  printf '%s %s%s Then write your full reply on screen as usual. Do not mention the tool in your written reply.%s%s' \
    "$prefix" "$core" "$speak_args" "$flavor" "$lang_line"
}
