#!/bin/bash
set -euo pipefail

PORT="${1:-5004}"
FLIP_MODE="${2:-async}" # async (default) or sync

pkill -x svi-decoder 2>/dev/null || true
sleep 0.3

export LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-i965}"

DECODER_ARGS=("$PORT")
case "$FLIP_MODE" in
    async) DECODER_ARGS+=("--async-flip") ;;
    sync) ;;
    *)
        echo "Invalid flip mode '$FLIP_MODE' (use 'async' or 'sync')" >&2
        exit 1
        ;;
esac

nohup chrt -f 50 taskset -c 1-3 /root/svi-decoder "${DECODER_ARGS[@]}" > /tmp/decoder.log 2>&1 &
disown
sleep 2
cat /tmp/decoder.log
