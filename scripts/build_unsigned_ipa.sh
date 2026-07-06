#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/HelloIPA.xcodeproj"
BUILD_DIR="$ROOT_DIR/build"
OUTPUT_DIR="$ROOT_DIR/build-output"
APP_NAME="HelloIPA.app"
IPA_NAME="HelloIPA.ipa"

rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR/Payload"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme HelloIPA \
  -target HelloIPA \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  BUILD_DIR="$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

APP_PATH="$(find "$BUILD_DIR" -type d -name "$APP_NAME" | head -n 1)"

if [ -z "$APP_PATH" ]; then
  echo "Could not find built app bundle."
  exit 1
fi

cp -R "$APP_PATH" "$OUTPUT_DIR/Payload/$APP_NAME"

pushd "$OUTPUT_DIR" > /dev/null
zip -qry "$IPA_NAME" Payload
popd > /dev/null

echo "Built unsigned IPA at: $OUTPUT_DIR/$IPA_NAME"
