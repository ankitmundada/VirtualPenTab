#!/bin/bash
# Records raw stylus tilt from the tablet's digitizer, so the sign convention
# can be established from hardware rather than assumed.
#
# Usage:  ./tools/capture-tilt.sh [seconds]
#
# Draw four short strokes, lifting the pen fully between each:
#   1. upright   2. leaning right   3. leaning left   4. leaning away
#
# Strokes are segmented by BTN_TOUCH, not by timing, so take as long as
# you like between them.
set -e
SECONDS_TO_RUN="${1:-60}"
OUT="${TMPDIR:-/tmp}/tilt-capture.log"

DEVICE=$(adb shell getevent -pl 2>/dev/null \
    | awk '/^add device/{dev=$NF} /name:.*Pen/{print dev; exit}')
if [ -z "$DEVICE" ]; then
    echo "No pen digitizer found. Is the tablet connected?" >&2
    exit 1
fi

echo "Recording $DEVICE for ${SECONDS_TO_RUN}s — draw your four strokes now."
# timeout must run on the device: macOS has no such command.
adb shell "timeout $SECONDS_TO_RUN getevent -l $DEVICE" > "$OUT" 2>&1 || true
echo "Captured $(wc -l < "$OUT" | tr -d ' ') events to $OUT"

if [ ! -s "$OUT" ]; then
    echo "Nothing recorded — the pen must actually touch the screen during the window." >&2
    exit 1
fi

echo
echo "Per-stroke tilt (degrees, as reported by the digitizer):"
awk '
  /BTN_TOUCH/ && /DOWN/ { stroke++; tx=""; ty=""; next }
  /BTN_TOUCH/ && /UP/ {
      if (stroke > 0) printf "  stroke %d:  ABS_TILT_X %-6s  ABS_TILT_Y %-6s\n", stroke, tx, ty
      next
  }
  /ABS_TILT_X/ { tx = strtonum("0x" $NF); if (tx > 2147483647) tx -= 4294967296 }
  /ABS_TILT_Y/ { ty = strtonum("0x" $NF); if (ty > 2147483647) ty -= 4294967296 }
' "$OUT"
