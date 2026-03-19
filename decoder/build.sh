#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building svi-decoder..."
gcc -O3 -march=silvermont -msse4.1 -flto -ffast-math -I/usr/include/libdrm \
  -o svi-decoder svi-decoder.c \
  -lEGL -lGLESv2 -lgbm -ldrm -lavcodec -lavutil -lva -lva-drm -lpthread
echo "Built: svi-decoder"
