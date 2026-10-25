#!/bin/bash
# Generates synthetic interviewer audio with macOS text-to-speech for the transcription spike.
# Synthetic speech is a smoke test for vocabulary and latency, not a substitute for real accents (plan §15.1).
set -euo pipefail
cd "$(dirname "$0")"
while IFS='|' read -r id voice text; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  if [ ! -f "$id.aiff" ]; then
    say -v "$voice" -o "$id.aiff" "$text"
    echo "generated $id.aiff ($voice)"
  fi
done < questions.txt
