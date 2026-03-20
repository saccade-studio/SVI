#!/bin/bash
# 2-stream panoramic encoder stress test
# Encodes Stream A (1920x3240, 3 panels stacked) and Stream B (1920x3240).
# Stream A goes to the real decoder for latency measurement.
# Stream B is sent to a dummy IP (switch-discarded).
#
# Usage: ./stress-test-6x.sh <dest_ip> [duration_secs]
#
# Authentication (choose one):
#   SSH key (preferred):  ensure your key is authorised on the target device
#   Password:             set SSH_PASSWORD=<password> in your environment

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

DEST="${1:?Usage: stress-test-6x.sh <dest_ip> [duration_secs]}"
DURATION="${2:-120}"
BITRATE=150   # 1920x3240 = 3x pixels vs 1080p; scale bitrate accordingly
PACE=450
ENCODER_DIR="$(cd "$(dirname "$0")/../encoder" && pwd)"
ENCODER="$ENCODER_DIR/svi-encoder"

# Dummy destination for sink streams — RFC 5737 TEST-NET-2 range, won't
# collide with real hosts. Static ARP entry sends frames to a dead MAC
# so packets hit the wire but the switch has nowhere to forward them.
SINK_IP="198.51.100.1"
SINK_MAC="02:00:00:00:de:ad"

SSH_OPTS="-o StrictHostKeyChecking=no"
if [[ -n "${SSH_PASSWORD:-}" ]]; then
    SSH_OPTS="-o PubkeyAuthentication=no -o PreferredAuthentications=password $SSH_OPTS"
    SSH_CMD="sshpass -p \"$SSH_PASSWORD\" ssh $SSH_OPTS root@$DEST"
else
    SSH_CMD="ssh $SSH_OPTS root@$DEST"
fi

# Stream table: syphon_name:port (spaced by 2 for clock-sync on port+1)
# Stream A → real decoder (panel 1 = bottom slice: crop-top 2160 crop-bottom 0)
# Stream B → sink
STREAMS=(
    "Stream A:5004"
    "Stream B:5006"
)

echo "=== SVI 6-Stream Stress Test ==="
echo "Bitrate: ${BITRATE}Mbps  Pace: ${PACE}Mbps  Duration: ${DURATION}s"
echo "Stream 1 → $DEST (decoded)  |  Streams 2-6 → $SINK_IP (switch-discarded)"
echo ""

# ── 1. Kill existing encoders ──
echo "Stopping existing encoders..."
pkill -f svi-encoder 2>/dev/null || true
sleep 1

# ── 2. Add static ARP for sink IP so packets hit the wire ──
echo "Adding static ARP: $SINK_IP → $SINK_MAC"
sudo arp -s "$SINK_IP" "$SINK_MAC" 2>/dev/null || true
echo ""

# ── 3. Launch 6 encoders ──
PIDS=()
for i in "${!STREAMS[@]}"; do
    IFS=: read -r syphon_name port <<< "${STREAMS[$i]}"
    n=$((i + 1))
    log="/tmp/enc${n}.log"

    if [ "$i" -eq 0 ]; then
        target="$DEST"
        label="$DEST:$port (decoded)"
    else
        target="$SINK_IP"
        label="$SINK_IP:$port (sink)"
    fi

    echo "  Starting encoder $n: '$syphon_name' → $label"
    "$ENCODER" "$syphon_name" "$target" "$port" "$BITRATE" "$PACE" > "$log" 2>&1 &
    PIDS+=($!)
done
echo ""

# ── 4. Restart decoder on port 5004 (stream 1) ──
echo "Restarting decoder on $DEST:5004..."
RCVBUF_BEFORE=$($SSH_CMD "
    pkill -x svi-decoder 2>/dev/null || true
    sleep 0.3
    export LIBVA_DRIVER_NAME=i965
    nohup chrt -f 50 taskset -c 1-3 /root/svi-decoder 5004 --async-flip --crop-top 2160 --crop-bottom 0 > /tmp/decoder.log 2>&1 &
    disown
    sleep 3
    cat /proc/net/snmp | grep '^Udp:' | tail -1 | awk '{print \$6}'
")
echo "  RcvbufErrors baseline: $RCVBUF_BEFORE"
echo ""

# ── 5. Wait for encoders to stabilise, then verify all alive ──
sleep 5
ALIVE=0
for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && ALIVE=$((ALIVE + 1))
done
echo "Encoders alive: $ALIVE / ${#STREAMS[@]}"
if [ "$ALIVE" -lt "${#STREAMS[@]}" ]; then
    echo "WARNING: not all encoders started. Check /tmp/enc*.log"
fi
echo ""

# ── 6. Run test ──
echo "Running for ${DURATION}s..."
sleep "$DURATION"
echo "Test complete. Collecting results..."
echo ""

# ── 7. Collect encoder results ──
echo "============================================"
echo "  ENCODER RESULTS (per stream)"
echo "============================================"

TOTAL_MBPS=0
ALL_PASS=1

for i in "${!STREAMS[@]}"; do
    IFS=: read -r syphon_name port <<< "${STREAMS[$i]}"
    n=$((i + 1))
    log="/tmp/enc${n}.log"

    if [ "$i" -eq 0 ]; then
        dest_label="$DEST:$port"
    else
        dest_label="$SINK_IP:$port (sink)"
    fi

    # Get last stats line
    stats=$(grep '^\[stats\]' "$log" | tail -1 || echo "NO STATS")
    fence=$(grep '^\[fence-5s\]' "$log" | tail -1 || echo "NO FENCE")

    # Extract values
    fps=$(echo "$stats" | grep -oE '[0-9]+\.[0-9]+fps' | head -1 | tr -d 'fps')
    mbps=$(echo "$stats" | grep -oE '[0-9]+\.[0-9]+Mbps' | head -1 | tr -d 'Mbps')
    qfull=$(echo "$stats" | grep -oE 'qfull=[0-9]+' | head -1 | cut -d= -f2)

    # Check alive
    alive="dead"
    kill -0 "${PIDS[$i]}" 2>/dev/null && alive="alive"

    echo ""
    echo "  Stream $n ($syphon_name) → $dest_label [$alive]"
    echo "    $stats"
    echo "    $fence"

    if [ -n "$mbps" ]; then
        TOTAL_MBPS=$(awk "BEGIN {print $TOTAL_MBPS + $mbps}")
    fi

    if [ "$alive" = "dead" ]; then ALL_PASS=0; fi
    if [ -n "$qfull" ] && [ "$qfull" != "0" ]; then
        echo "    !! qfull=$qfull"
        ALL_PASS=0
    fi
done

echo ""
echo "============================================"
echo "  DECODER RESULTS (stream 1)"
echo "============================================"
echo ""

DECODER_OUT=$($SSH_CMD "
    tail -5 /tmp/decoder.log
    echo '---'
    cat /proc/net/snmp | grep '^Udp:' | tail -1 | awk '{print \$6}'
")
echo "$DECODER_OUT"

RCVBUF_AFTER=$(echo "$DECODER_OUT" | tail -1)
RCVBUF_DELTA=$((RCVBUF_AFTER - RCVBUF_BEFORE))

echo ""
echo "============================================"
echo "  MAC CPU USAGE"
echo "============================================"
echo ""
ps -p "$(echo "${PIDS[@]}" | tr ' ' ',')" -o pid,%cpu,rss,command 2>/dev/null | head -8 || echo "  (processes exited)"

echo ""
echo "============================================"
echo "  SUMMARY"
echo "============================================"
echo ""
echo "  Aggregate bandwidth:  ${TOTAL_MBPS} Mbps"
echo "  RcvbufErrors delta:   $RCVBUF_DELTA"
echo "  Encoders alive:       $ALIVE / ${#STREAMS[@]}"

if [ "$RCVBUF_DELTA" -gt 0 ]; then
    echo "  !! FAIL: $RCVBUF_DELTA new RcvbufErrors"
    ALL_PASS=0
fi

if [ "$ALL_PASS" -eq 1 ]; then
    echo ""
    echo "  PASS"
else
    echo ""
    echo "  ISSUES DETECTED — review per-stream details above"
fi

echo ""

# ── 8. Cleanup ──
echo "Stopping encoders..."
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true

echo "Removing static ARP entry..."
sudo arp -d "$SINK_IP" 2>/dev/null || true

echo "Done."
