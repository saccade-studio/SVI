#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_BIN="$SCRIPT_DIR/.visible_rect_test"

gcc -std=c11 -Wall -Wextra -Werror -pedantic \
  "$SCRIPT_DIR/visible_rect_test.c" \
  -o "$OUT_BIN" -lm

"$OUT_BIN"
rm -f "$OUT_BIN"
