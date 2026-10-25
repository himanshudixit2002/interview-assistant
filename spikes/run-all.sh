#!/bin/bash
# Reproduces the Phase 0 measurements. Needs Screen Recording granted to the terminal/host app (it does not prompt).
# Audio tests play fixtures through a muted process tap, so nothing is audible.
set -uo pipefail
cd "$(dirname "$0")"
SPIKE=./.build/release/spike
[ -x "$SPIKE" ] || swift build -c release
./fixtures/make-audio.sh
echo "## capabilities"; $SPIKE capabilities
echo; echo "## transcription set (default)"; $SPIKE transcribe-set fixtures
echo; echo "## transcription set (--fast)"; $SPIKE transcribe-set fixtures --fast
echo; echo "## window OCR (accurate, title bar cropped)"; $SPIKE ocr-window --render fixtures/sample_code.py --code --crop-top 32
echo; echo "## on-device model"; $SPIKE on-device-model --classify --fewshot --draft
echo; echo "## live audio via muted process tap (fast results, 600 ms endpoint)"
afplay fixtures/q07pad.aiff & PID=$!
$SPIKE tap-audio --pid "$PID" --seconds 11 --mute --fast --endpoint-ms 600 | grep -v 'partial audio'
wait $PID 2>/dev/null
if [ -n "${RESUME_PDF:-}" ]; then echo; echo "## evidence retrieval"; $SPIKE evidence "$RESUME_PDF"; fi
