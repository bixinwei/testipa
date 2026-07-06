#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/InjectedDylib/AppControlDylib.m"
OUTPUT_DIR="$ROOT_DIR/build-output"
OUT="$OUTPUT_DIR/AppControlDylib.dylib"

mkdir -p "$OUTPUT_DIR"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

xcrun clang \
  -dynamiclib \
  -arch arm64 \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc \
  -framework Foundation \
  -framework UIKit \
  -framework WebKit \
  -framework CoreGraphics \
  -framework Network \
  -install_name "@rpath/AppControlDylib.dylib" \
  "$SRC" \
  -o "$OUT"

echo "Built dylib at: $OUT"
