#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/DiskDeduper/DiskDeduper.xcodeproj"
BUILD_DIR="$ROOT_DIR/build-disk-deduper"
OUTPUT_DIR="$ROOT_DIR/build-output-disk-deduper"

rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR/Payload"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme DiskDeduper \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  BUILD_DIR="$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

APP_PATH="$(find "$BUILD_DIR" -type d -name 'DiskDeduper.app' | head -n 1)"
test -n "$APP_PATH"
cp -R "$APP_PATH" "$OUTPUT_DIR/Payload/DiskDeduper.app"
(cd "$OUTPUT_DIR" && zip -qry DiskDeduper.ipa Payload)
