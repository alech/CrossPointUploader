#!/bin/bash
set -euo pipefail

# Build CrossPointUploader.app from the single Swift source file (no Xcode project needed).
cd "$(dirname "$0")"

APP="CrossPointUploader.app"
BIN="CrossPointUploader"

echo "Compiling…"
rm -rf "$APP" "$BIN"
xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -O \
    -o "$BIN" \
    CrossPointUploader.swift

echo "Assembling bundle…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"
cp Info.plist "$APP/Contents/Info.plist"

echo "Ad-hoc code signing (needed for the Local Network permission prompt)…"
codesign --force --sign - --timestamp=none "$APP"

echo "Done → $(pwd)/$APP"
