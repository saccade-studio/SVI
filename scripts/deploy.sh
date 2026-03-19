#!/bin/bash
# Deploy SVI-Decoder binary + start script to remote device
# Usage: ./deploy.sh [host] [port] [async|sync]

HOST="${1:-192.168.0.14}"
PORT="${2:-5004}"
FLIP_MODE="${3:-async}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DECODER_DIR="$SCRIPT_DIR/../decoder"

if [[ "$FLIP_MODE" != "async" && "$FLIP_MODE" != "sync" ]]; then
    echo "Invalid flip mode '$FLIP_MODE' (use 'async' or 'sync')" >&2
    exit 1
fi

SSH_OPTS="-o PubkeyAuthentication=no -o PreferredAuthentications=password -o StrictHostKeyChecking=no"
SSH_CMD="sshpass -p "${SSH_PASSWORD}" ssh $SSH_OPTS root@$HOST"
SCP_CMD="sshpass -p "${SSH_PASSWORD}" scp $SSH_OPTS"

echo "=== Deploying SVI-Decoder to $HOST ==="

# Kill existing decoder
echo "Stopping existing decoder..."
$SSH_CMD "kill -9 \$(pgrep -f svi-decoder) 2>/dev/null; true"
sleep 0.5

# Copy source + build script
echo "Copying decoder source..."
$SCP_CMD "$DECODER_DIR/svi-decoder.c" "root@$HOST:/root/svi-decoder.c"
$SCP_CMD "$DECODER_DIR/build.sh" "root@$HOST:/root/build.sh"

# Build on device
echo "Building on device..."
$SSH_CMD "chmod +x /root/build.sh && cd /root && bash build.sh"

# Copy and run start script
echo "Starting decoder on port $PORT ($FLIP_MODE flip)..."
$SCP_CMD "$SCRIPT_DIR/start_decoder.sh" "root@$HOST:/root/start_decoder.sh"
$SSH_CMD "chmod +x /root/start_decoder.sh && /root/start_decoder.sh $PORT $FLIP_MODE"

echo "=== Deploy complete ==="
