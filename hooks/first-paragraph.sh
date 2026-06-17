#!/bin/bash
# Reads a markdown assistant message on stdin; prints the spoken first paragraph.
export LANG="${LANG:-en_US.UTF-8}"

TEXT=$(cat)

# 1) Take the first prose paragraph: drop fenced code blocks + their content,
#    drop heading and table lines, de-bullet list items, and stop at the first
#    blank line after prose has started.
PARA=$(printf '%s\n' "$TEXT" | awk '
  /^[[:space:]]*```/ { infence = !infence; next }   # toggle + drop fence lines
  infence { next }                                  # drop fenced content
  /^[[:space:]]*#/  { next }                         # drop ATX headings
  /^[[:space:]]*\|/ { next }                          # drop table rows
  {
    line = $0
    sub(/^[[:space:]]*[-*+][[:space:]]+/, "", line)        # de-bullet
    sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", line)     # de-number
    if (line ~ /^[[:space:]]*$/) { if (started) exit; else next }
    started = 1
    print line
  }
')

# 2) Strip inline markdown / links / URLs, join lines, collapse whitespace.
SPEECH=$(printf '%s\n' "$PARA" | \
  sed -E 's/`([^`]*)`/\1/g; s/\*\*//g; s/\*//g' | \
  sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | \
  sed -E 's|https?://[^ ]*||g' | \
  tr '\n' ' ' | \
  sed -E 's/  */ /g; s/^ *//; s/ *$//')

# 3) Cap at ~600 chars on a sentence boundary.
if [ ${#SPEECH} -gt 600 ]; then
  SPEECH="${SPEECH:0:600}"
  SPEECH=$(printf '%s' "$SPEECH" | sed -E 's/([.!?])[^.!?]*$/\1/')
fi

printf '%s' "$SPEECH"
