#!/bin/bash
# Reads a markdown assistant message on stdin; prints the spoken text.
#   (default)  the first prose paragraph, capped at ~600 chars on a sentence boundary
#   --full     ALL prose paragraphs, uncapped; paragraph breaks kept as newlines so the
#              app's SentenceSplitter (which flushes on '\n') keeps them as separate chunks
# Both modes drop fenced code, headings, and tables, de-bullet/de-number, and strip inline
# markdown, links, and URLs — a code block or table can't be spoken sensibly even in --full.
export LANG="${LANG:-en_US.UTF-8}"

MODE="first"
[ "$1" = "--full" ] && MODE="full"

TEXT=$(cat)

# 1) Extract prose lines. first mode stops at the first blank line after prose starts;
#    full mode keeps every paragraph (blank lines pass through as separators).
PARA=$(printf '%s\n' "$TEXT" | awk -v mode="$MODE" '
  /^[[:space:]]*```/ { infence = !infence; next }   # toggle + drop fence lines
  infence { next }                                  # drop fenced content
  /^[[:space:]]*#/  { next }                          # drop ATX headings
  /^[[:space:]]*\|/ { next }                           # drop table rows
  {
    line = $0
    sub(/^[[:space:]]*[-*+][[:space:]]+/, "", line)        # de-bullet
    sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", line)     # de-number
    if (line ~ /^[[:space:]]*$/) {
      if (!started) next
      if (mode == "full") { print ""; next }   # keep the paragraph break
      exit                                     # first mode: stop after one paragraph
    }
    started = 1
    print line
  }
')

# 2) Strip inline markdown / links / URLs (both modes).
STRIPPED=$(printf '%s\n' "$PARA" | \
  sed -E 's/`([^`]*)`/\1/g; s/\*\*//g; s/\*//g' | \
  sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | \
  sed -E 's|https?://[^ ]*||g')

if [ "$MODE" = "full" ]; then
  # Join lines within each paragraph to single spaces; keep one newline between paragraphs.
  # No length cap — the whole reply is spoken.
  SPEECH=$(printf '%s\n' "$STRIPPED" | awk '
    BEGIN { RS = ""; ORS = "\n" }
    {
      gsub(/[ \t]*\n[ \t]*/, " ")   # intra-paragraph newlines -> spaces
      gsub(/  +/, " ")
      sub(/^ +/, ""); sub(/ +$/, "")
      print
    }')
else
  # Join everything, collapse whitespace, then cap at ~600 chars on a sentence boundary.
  SPEECH=$(printf '%s\n' "$STRIPPED" | tr '\n' ' ' | sed -E 's/  */ /g; s/^ *//; s/ *$//')
  if [ ${#SPEECH} -gt 600 ]; then
    SPEECH="${SPEECH:0:600}"
    SPEECH=$(printf '%s' "$SPEECH" | sed -E 's/([.!?])[^.!?]*$/\1/')
  fi
fi

printf '%s' "$SPEECH"
