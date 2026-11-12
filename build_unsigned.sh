#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/HYperRegedit-original-identity.xcarchive"
IPA="$BUILD_DIR/ATH-External-unsigned.ipa"


rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
command -v xcodebuild >/dev/null || { echo 'xcodebuild is required on macOS' >&2; exit 127; }

xcodebuild \
  -project "$ROOT/ThreeOneOSFive.xcodeproj" \
  -scheme JVZTXNX \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  archive

APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -type d -name "*.app" -print -quit)"
test -n "$APP"
test -d "$APP"
PATCH_DIR="$APP/Patches"
mkdir -p "$PATCH_DIR"
for package in "$APP"/*.3105; do
  [ -e "$package" ] || continue
  mv "$package" "$PATCH_DIR/"
done

EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist" 2>/dev/null || true)"
if [[ -z "$EXECUTABLE" || "$EXECUTABLE" == '$(EXECUTABLE_NAME)' ]]; then EXECUTABLE="$(basename "$APP" .app)"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP/Info.plist" || true
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$IPA" Payload
  rm -rf Payload
)
echo "$IPA"
