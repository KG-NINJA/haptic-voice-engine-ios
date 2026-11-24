#!/usr/bin/env bash
# Builds an unsigned device IPA (arm64, Release) for re-signing with iloader / AltStore / Sideloadly.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
OUT=build/ipa
rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild build \
  -project HapticVoiceEngine.xcodeproj -scheme HapticVoiceEngine \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd-device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" >"$OUT/build.log" 2>&1 \
  || { tail -40 "$OUT/build.log"; exit 1; }
APP=build/dd-device/Build/Products/Release-iphoneos/HapticVoiceEngine.app
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qry HapticVoiceEngine-unsigned.ipa Payload)
rm -rf "$OUT/Payload"
shasum -a 256 "$OUT/HapticVoiceEngine-unsigned.ipa"
