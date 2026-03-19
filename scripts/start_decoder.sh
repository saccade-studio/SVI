#!/bin/bash
pkill -f svi-decoder 2>/dev/null
sleep 0.3
export LIBVA_DRIVER_NAME=i965
nohup chrt -f 50 taskset -c 1-3 /root/svi-decoder 5004 > /tmp/decoder.log 2>&1 &
disown
sleep 2
cat /tmp/decoder.log
