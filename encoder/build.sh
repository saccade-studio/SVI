#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building svi-encoder..."
clang -O2 -fobjc-arc -o svi-encoder svi-encoder.m \
  -F"/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
  -rpath "/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
  -framework Syphon -framework Cocoa -framework OpenGL \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -framework CoreFoundation -framework IOSurface -lpthread
echo "Built: svi-encoder"

echo "Building svi-list..."
clang -O2 -fobjc-arc -o svi-list svi-list.m \
  -F"/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
  -rpath "/Applications/Resolume Arena/Arena.app/Contents/Frameworks" \
  -framework Syphon -framework Cocoa
echo "Built: svi-list"
