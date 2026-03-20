#!/bin/bash
# 6-stream 720p FPS comparison test
# Streams are Syphon sources named "1" through "6", each 1280x720 @ 60fps.
# Stream 1 → real decoder on dev box (latency + FPS measured).
# Streams 2-6 → SINK_IP (switch-discarded, wire-present).
#
# Purpose: verify per-stream FPS at 1280x720/60 vs prior 1920x1080/60 baseline.
#
# Usage: ./test-6stream-720p.sh [dest_ip] [duration_secs]
#   dest_ip defaults to 192.168.0.14
#
# Authentication:
#   SSH key (preferred):  ensure your key is authorised on the target
#   Password:             set SSH_PASSWORD=<password> in your environment
#                         e.g.  SSH_PASSWORD=NDI ./test-6stream-720p.sh

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

DEST="${1:-192.168.0.14}"
DURATION="${2:-120}"
BITRATE=80    # Mbps per stream — 2x the 1080p@40Mbps rate at 720p (~4x bits/pixel)
PACE=320      # Mbps pacing budget per stream (4x bitrate headroom)
CODEC="${CODEC:-hevc}"  # hevc or h264; default hevc
CODEC_FLAG=""; [[ "$CODEC" = "hevc" ]] && CODEC_FLAG="--hevc"
ENCODER_DIR="$(cd "$(dirname "$0")/../encoder" && pwd)"
ENCODER="$ENCODER_DIR/svi-encoder"

# Baseline for comparison note in summary
BASELINE_RES="1920x1080"
BASELINE_FPS_TARGET=60

# Dummy destination — RFC 5737 TEST-NET-2, static ARP → dead MAC.
# Packets hit the wire but the switch has nowhere to forward them.
SINK_IP="198.51.100.1"
SINK_MAC="02:00:00:00:de:ad"

SSH_OPTS="-q -o StrictHostKeyChecking=no -o LogLevel=ERROR"
if [[ -n "${SSH_PASSWORD:-}" ]]; then
    SSH_OPTS="-o PubkeyAuthentication=no -o PreferredAuthentications=password $SSH_OPTS"
    SSH_CMD="sshpass -p \"$SSH_PASSWORD\" ssh $SSH_OPTS root@$DEST"
    SCP_CMD="sshpass -p \"$SSH_PASSWORD\" scp $SSH_OPTS"
else
    SSH_CMD="ssh $SSH_OPTS root@$DEST"
    SCP_CMD="scp $SSH_OPTS"
fi

# Stream table: syphon_name:port  (clock-sync uses port+1, so step by 2)
# Stream 1 → real decoder, streams 2-6 → sink
STREAMS=(
    "1:5004"
    "2:5006"
    "3:5008"
    "4:5010"
    "5:5012"
    "6:5014"
)

echo "=== SVI 6-Stream 720p FPS Comparison Test ==="
echo "Resolution:  1280x720 @ 60fps (testing vs ${BASELINE_RES} @ ${BASELINE_FPS_TARGET}fps baseline)"
echo "Codec:       ${CODEC}"
echo "Bitrate:     ${BITRATE}Mbps/stream   Pace: ${PACE}Mbps/stream"
echo "Duration:    ${DURATION}s"
echo "Stream 1  →  $DEST:5004 (decoded)"
echo "Streams 2-6 →  $SINK_IP (switch-discarded)"
echo ""

# ── 1. Pre-flight: encoder binary present ──
if [[ ! -x "$ENCODER" ]]; then
    echo "ERROR: svi-encoder not found at $ENCODER" >&2
    echo "       Run: cd encoder && bash build.sh" >&2
    exit 1
fi

# ── 2. Kill existing encoders ──
echo "Stopping any existing encoders..."
pkill -f svi-encoder 2>/dev/null || true
sleep 0.5

# ── 3. Static ARP so sink packets hit the wire ──
echo "Adding static ARP: $SINK_IP → $SINK_MAC"
sudo arp -s "$SINK_IP" "$SINK_MAC" 2>/dev/null || true
echo ""

# ── 4. Start decoder FIRST so it's ready before any encoder sends ──
# This prevents the 8MB socket buffer from overflowing with pre-start frames,
# which would cause stale-frame eviction churn and VAAPI warmup on a flood
# of dropped packets instead of silence.
echo "Starting decoder on ${DEST}:5004 (before encoders)..."
RCVBUF_BEFORE=$(eval "$SSH_CMD" << ENDSSH
    pkill -x svi-decoder 2>/dev/null || true
    sleep 0.3
    export LIBVA_DRIVER_NAME=i965
    nohup chrt -f 50 taskset -c 1-3 /root/svi-decoder 5004 --async-flip $CODEC_FLAG \\
        > /tmp/decoder.log 2>&1 &
    disown
    sleep 2
    cat /proc/net/snmp | grep '^Udp:' | tail -1 | awk '{print \$6}'
ENDSSH
)
echo "  RcvbufErrors baseline: ${RCVBUF_BEFORE:-unknown}"
echo ""

# ── 5. Launch 6 encoders (decoder is already listening) ──
echo "Launching encoders..."
PIDS=()
for i in "${!STREAMS[@]}"; do
    IFS=: read -r syphon_name port <<< "${STREAMS[$i]}"
    n=$((i + 1))
    log="/tmp/enc${n}.log"

    if [[ "$i" -eq 0 ]]; then
        target="$DEST"
        label="${DEST}:${port} (decoded)"
    else
        target="$SINK_IP"
        label="${SINK_IP}:${port} (sink)"
    fi

    echo "  Stream $n  '$syphon_name'  →  $label"
    "$ENCODER" "$syphon_name" "$target" "$port" "$BITRATE" "$PACE" $CODEC_FLAG > "$log" 2>&1 &
    PIDS+=($!)
done
echo ""

# ── 6. Wait for stabilisation, verify encoders alive ──
sleep 5
ALIVE=0
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && ALIVE=$((ALIVE + 1))
done
echo "Encoders alive: $ALIVE / ${#STREAMS[@]}"
if [[ "$ALIVE" -lt "${#STREAMS[@]}" ]]; then
    echo "WARNING: not all encoders running — check /tmp/enc*.log"
fi
echo ""

# ── 7. Run test ──
echo "Running for ${DURATION}s..."
sleep "$DURATION"
echo "Done. Collecting results..."
echo ""

# ── 8. Encoder results ──
echo "============================================"
echo "  ENCODER RESULTS (per stream)"
echo "============================================"

TOTAL_MBPS=0
ALL_PASS=1
declare -a STREAM_FPS=()

for i in "${!STREAMS[@]}"; do
    IFS=: read -r syphon_name port <<< "${STREAMS[$i]}"
    n=$((i + 1))
    log="/tmp/enc${n}.log"

    dest_label="$( [[ "$i" -eq 0 ]] && echo "${DEST}:${port}" || echo "${SINK_IP}:${port} (sink)" )"

    stats=$(grep '^\[stats\]' "$log" | tail -1 || echo "NO STATS")
    fence=$(grep '^\[fence-5s\]' "$log" | tail -1 || echo "")

    fps=$(echo "$stats"  | grep -oE '[0-9]+\.[0-9]+fps' | head -1 | tr -d 'fps')
    mbps=$(echo "$stats" | grep -oE '[0-9]+\.[0-9]+Mbps' | head -1 | tr -d 'Mbps')
    qfull=$(echo "$stats" | grep -oE 'qfull=[0-9]+'       | head -1 | cut -d= -f2)

    alive="dead"
    kill -0 "${PIDS[$i]}" 2>/dev/null && alive="alive"

    STREAM_FPS+=("${fps:-0}")

    echo ""
    echo "  Stream $n ('$syphon_name') → $dest_label [$alive]"
    echo "    $stats"
    [[ -n "$fence" ]] && echo "    $fence"

    if [[ -n "$mbps" ]]; then
        TOTAL_MBPS=$(awk "BEGIN {print $TOTAL_MBPS + $mbps}")
    fi
    [[ "$alive" = "dead" ]] && ALL_PASS=0
    if [[ -n "$qfull" && "$qfull" != "0" ]]; then
        echo "    !! qfull=$qfull — sender falling behind"
        ALL_PASS=0
    fi
done

# ── 9. Decoder results ──
echo ""
echo "============================================"
echo "  DECODER RESULTS (stream 1)"
echo "============================================"
echo ""

DECODER_OUT=$(eval "$SSH_CMD" << 'ENDSSH'
    tail -6 /tmp/decoder.log
    echo '---'
    cat /proc/net/snmp | grep '^Udp:' | tail -1 | awk '{print $6}'
ENDSSH
)
echo "$DECODER_OUT"

RCVBUF_AFTER=$(echo "$DECODER_OUT" | grep -oE '[0-9]+$' | tail -1)
RCVBUF_BEFORE_N=$(echo "$RCVBUF_BEFORE" | grep -oE '[0-9]+$' | tail -1)
RCVBUF_DELTA=$(( ${RCVBUF_AFTER:-0} - ${RCVBUF_BEFORE_N:-0} ))

# ── 10. Mac CPU ──
echo ""
echo "============================================"
echo "  MAC CPU USAGE"
echo "============================================"
echo ""
ps -p "$(echo "${PIDS[@]}" | tr ' ' ',')" -o pid,%cpu,rss,command 2>/dev/null \
    | head -9 || echo "  (processes exited)"

# ── 11. FPS comparison ──
echo ""
echo "============================================"
echo "  FPS vs ${BASELINE_RES} BASELINE"
echo "============================================"
echo ""
echo "  Target: ${BASELINE_FPS_TARGET}.0 fps  |  Resolution under test: 1280x720"
echo ""
FPS_PASS=1
for i in "${!STREAM_FPS[@]}"; do
    n=$((i + 1))
    fps="${STREAM_FPS[$i]}"
    delta=$(awk "BEGIN { printf \"%.1f\", $fps - $BASELINE_FPS_TARGET }" 2>/dev/null || echo "?")
    sign=""; [[ "${delta:0:1}" != "-" ]] && sign="+"
    marker=""
    fps_int=$(printf "%.0f" "$fps" 2>/dev/null || echo 0)
    if [[ "$fps_int" -ge 58 ]]; then marker="OK"; else marker="LOW"; ALL_PASS=0; FPS_PASS=0; fi
    printf "  Stream %d:  %6s fps  (%s%s vs baseline)  [%s]\n" \
        "$n" "${fps:-N/A}" "$sign" "$delta" "$marker"
done

if [[ "$FPS_PASS" -eq 1 ]]; then
    echo ""
    echo "  All streams at or near ${BASELINE_FPS_TARGET}fps — 720p load is within budget."
else
    echo ""
    echo "  One or more streams below 58fps — check encoder logs."
fi

# ── 12. Summary ──
echo ""
echo "============================================"
echo "  SUMMARY"
echo "============================================"
echo ""
echo "  Aggregate bandwidth:  ${TOTAL_MBPS} Mbps"
echo "  RcvbufErrors delta:   ${RCVBUF_DELTA}"
echo "  Encoders alive:       ${ALIVE} / ${#STREAMS[@]}"

[[ "$RCVBUF_DELTA" -gt 0 ]] && { echo "  !! FAIL: $RCVBUF_DELTA new RcvbufErrors at decoder"; ALL_PASS=0; }

echo ""
if [[ "$ALL_PASS" -eq 1 ]]; then
    echo "  PASS — 720p 6-stream run clean"
else
    echo "  ISSUES DETECTED — review per-stream details above"
fi
echo ""

# ── 13. Cleanup ──
echo "Stopping encoders..."
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true

echo "Removing static ARP entry..."
sudo arp -d "$SINK_IP" 2>/dev/null || true

echo "Done."
