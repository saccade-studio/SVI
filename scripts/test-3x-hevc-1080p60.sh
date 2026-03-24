#!/bin/bash
# 3-stream 1080p60 HEVC encoder test
#
# Stream routing:
#   1 → 192.168.0.14:5004  (real decoder)
#   2 → 198.51.100.1:5006  (switch-rejected sink)
#   3 → 198.51.100.1:5008  (switch-rejected sink)
#
# Usage: ./test-3x-hevc-1080p60.sh [duration_secs]
#
# Authentication (choose one):
#   SSH key (preferred):  ensure your key is authorised on the target device
#   Password:             set SSH_PASSWORD=<password> in your environment

set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

DEST="192.168.0.14"
DURATION="${1:-120}"
BITRATE=40    # Mbps — reasonable for 1080p60 HEVC
PACE=200      # Mbps — UDP send pacing cap
ENCODER_DIR="$(cd "$(dirname "$0")/../encoder" && pwd)"
ENCODER="$ENCODER_DIR/svi-encoder"

SINK_IP="198.51.100.1"
SINK_MAC="02:00:00:00:de:ad"

if [[ -n "${SSH_PASSWORD:-}" ]]; then
    SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o PreferredAuthentications=password root@"$DEST")
else
    SSH_CMD=(ssh -o StrictHostKeyChecking=no root@"$DEST")
fi

# Stream table: "syphon_name:port:dest_ip"
# Ports spaced by 2 so clock-sync replies land on port+1 without collision.
STREAMS=(
    "1:5004:$DEST"          # live decoder — clock-sync enabled for latency
    "2:5006:$SINK_IP"       # switch-rejected
    "3:5008:$SINK_IP"       # switch-rejected
)

echo "=== SVI 3-Stream 1080p60 HEVC Test ==="
echo "Codec: HEVC  Bitrate: ${BITRATE}Mbps  Pace: ${PACE}Mbps  Duration: ${DURATION}s"
echo ""
echo "  Stream 1  → $DEST:5004  (decoded + latency measured)"
echo "  Stream 2  → $SINK_IP:5006  (switch-rejected)"
echo "  Stream 3  → $SINK_IP:5008  (switch-rejected)"
echo ""

# ── 1. Kill existing encoders ──
echo "Stopping existing encoders..."
pkill -f svi-encoder 2>/dev/null || true
sleep 1

# ── 2. Static ARP so sink packets actually hit the wire ──
echo "Adding static ARP: $SINK_IP → $SINK_MAC"
sudo arp -s "$SINK_IP" "$SINK_MAC" 2>/dev/null || true
echo ""

# ── 3. Launch 3 HEVC encoders ──
PIDS=()
for i in "${!STREAMS[@]}"; do
    IFS=: read -r syphon_name port target <<< "${STREAMS[$i]}"
    n=$((i + 1))
    log="/tmp/enc${n}.log"

    if [ "$target" = "$DEST" ]; then
        label="$DEST:$port (decoded)"
    else
        label="$SINK_IP:$port (sink)"
    fi

    echo "  Starting encoder $n: '$syphon_name' → $label"
    "$ENCODER" "$syphon_name" "$target" "$port" "$BITRATE" "$PACE" --hevc > "$log" 2>&1 &
    PIDS+=($!)
done
echo ""

# ── 4. Restart HEVC decoder on test box ──
echo "Restarting HEVC decoder on $DEST:5004..."
RCVBUF_BEFORE=$("${SSH_CMD[@]}" "
    pkill -x svi-decoder 2>/dev/null || true
    sleep 0.3
    export LIBVA_DRIVER_NAME=i965
    nohup chrt -f 50 taskset -c 1-3 /root/svi-decoder 5004 --async-flip --hevc > /tmp/decoder.log 2>&1 &
    disown
    sleep 3
    cat /proc/net/snmp | grep '^Udp:' | tail -1 | awk '{print \$6}'
")
echo "  RcvbufErrors baseline: $RCVBUF_BEFORE"
echo ""

# ── 5. Verify all encoders alive after settling ──
sleep 5
ALIVE=0
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && ALIVE=$((ALIVE + 1))
done
echo "Encoders alive: $ALIVE / ${#STREAMS[@]}"
if [ "$ALIVE" -lt "${#STREAMS[@]}" ]; then
    echo "WARNING: not all encoders started — check /tmp/enc*.log"
fi
echo ""

# ── 6. Live metrics loop (every 10s for the test duration) ──
echo "=== Live metrics (every 10s) ==="
TICK=0
END_TIME=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$END_TIME" ]; do
    sleep 10
    TICK=$((TICK + 1))
    ELAPSED=$((TICK * 10))
    echo ""
    printf "── T+%ds " "$ELAPSED"
    printf '─%.0s' {1..40}
    echo ""
    for i in "${!STREAMS[@]}"; do
        IFS=: read -r syphon_name port target <<< "${STREAMS[$i]}"
        n=$((i + 1))
        log="/tmp/enc${n}.log"
        last=$(grep '^\[stats\]' "$log" 2>/dev/null | tail -1 || echo "(no stats yet)")
        echo "  Enc$n ($syphon_name): $last"
    done
    DEC_LINE=$("${SSH_CMD[@]}" "tail -1 /tmp/decoder.log 2>/dev/null || echo '(no decoder log)'" 2>/dev/null || echo "(ssh unavailable)")
    echo "  Decoder:          $DEC_LINE"
done

echo ""
echo "Test complete. Collecting final results..."
echo ""

# ── 7. Encoder results ──
echo "============================================"
echo "  ENCODER RESULTS (per stream)"
echo "============================================"

TOTAL_MBPS=0
ALL_PASS=1

for i in "${!STREAMS[@]}"; do
    IFS=: read -r syphon_name port target <<< "${STREAMS[$i]}"
    n=$((i + 1))
    log="/tmp/enc${n}.log"

    stats=$(grep '^\[stats\]' "$log"  | tail -1 || echo "NO STATS")
    fence=$(grep '^\[fence-5s\]' "$log" | tail -1 || echo "")

    fps=$(echo "$stats"   | grep -oE '[0-9]+\.[0-9]+fps'  | head -1 | tr -d 'fps')
    mbps=$(echo "$stats"  | grep -oE '[0-9]+\.[0-9]+Mbps' | head -1 | tr -d 'Mbps')
    qfull=$(echo "$stats" | grep -oE 'qfull=[0-9]+'       | head -1 | cut -d= -f2)

    alive="dead"
    kill -0 "${PIDS[$i]}" 2>/dev/null && alive="alive"

    echo ""
    echo "  Stream $n ($syphon_name) → $target:$port [$alive]"
    echo "    $stats"
    [ -n "$fence" ] && echo "    $fence"

    if [ -n "$mbps" ]; then
        TOTAL_MBPS=$(awk "BEGIN {print $TOTAL_MBPS + $mbps}")
    fi
    if [ "$alive" = "dead" ]; then ALL_PASS=0; fi
    if [ -n "$qfull" ] && [ "$qfull" != "0" ]; then
        echo "    !! qfull=$qfull — send queue overflowed"
        ALL_PASS=0
    fi
done

# ── 8. Decoder results ──
echo ""
echo "============================================"
echo "  DECODER RESULTS (192.168.0.14)"
echo "============================================"
echo ""

DECODER_OUT=$("${SSH_CMD[@]}" "
    tail -10 /tmp/decoder.log
    echo '---'
    cat /proc/net/snmp | grep '^Udp:' | tail -1 | awk '{print \$6}'
")
echo "$DECODER_OUT"

RCVBUF_AFTER=$(echo "$DECODER_OUT" | tail -1)
RCVBUF_DELTA=$((RCVBUF_AFTER - RCVBUF_BEFORE))

# ── 9. Mac CPU ──
echo ""
echo "============================================"
echo "  MAC CPU USAGE"
echo "============================================"
echo ""
ps -p "$(echo "${PIDS[@]}" | tr ' ' ',')" -o pid,%cpu,rss,command 2>/dev/null | head -8 \
    || echo "  (processes exited)"

# ── 10. Summary ──
echo ""
echo "============================================"
echo "  SUMMARY"
echo "============================================"
echo ""
echo "  Codec:               HEVC (H.265)"
echo "  Resolution:          1080p60"
echo "  Streams:             3 (1 live → $DEST, 2+3 switch-rejected)"
echo "  Bitrate per stream:  ${BITRATE} Mbps"
echo "  Aggregate bandwidth: ${TOTAL_MBPS} Mbps"
echo "  RcvbufErrors delta:  $RCVBUF_DELTA"
echo "  Encoders alive:      $ALIVE / ${#STREAMS[@]}"

if [ "$RCVBUF_DELTA" -gt 0 ]; then
    echo "  !! FAIL: $RCVBUF_DELTA new RcvbufErrors on decoder"
    ALL_PASS=0
fi

echo ""
if [ "$ALL_PASS" -eq 1 ]; then
    echo "  PASS"
else
    echo "  ISSUES DETECTED — review per-stream details above"
fi
echo ""

# ── 11. Cleanup ──
echo "Stopping encoders..."
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true

echo "Removing static ARP entry..."
sudo arp -d "$SINK_IP" 2>/dev/null || true

echo "Done."
