#!/usr/bin/env bash
# Build the dev-flavor release APK, rename it after the current pubspec
# version (e.g. 0.14.6 -> oo0146.apk), and drop it in releases/ at the repo root.
#
# Deterministic only: no version bump, no commit, no push. Run those
# steps yourself (or via the /RELEASE flow) before calling this.

set -euo pipefail

APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$APP_DIR/.." && pwd )"
PUBSPEC="$APP_DIR/pubspec.yaml"

VERSION="$(awk '/^version:/ {print $2; exit}' "$PUBSPEC")"
if [[ -z "${VERSION:-}" ]]; then
  echo "build: could not parse version from $PUBSPEC" >&2
  exit 1
fi

SHORT="oo$(echo "$VERSION" | tr -d '.')"
RELEASES_DIR="$ROOT_DIR/releases"
OUT_PATH="$RELEASES_DIR/${SHORT}.apk"

echo "build: version=$VERSION  output=$OUT_PATH"

mkdir -p "$RELEASES_DIR"

cd "$APP_DIR"
flutter clean
flutter build apk --flavor dev

SRC_APK="$APP_DIR/build/app/outputs/flutter-apk/app-dev-release.apk"
if [[ ! -f "$SRC_APK" ]]; then
  echo "build: build succeeded but $SRC_APK not found" >&2
  exit 1
fi

mv "$SRC_APK" "$OUT_PATH"
echo "build: wrote $OUT_PATH"

# --- Firmware DFU handling ---
DFU_ZIP="$ROOT_DIR/omi/firmware/omi/build/omi/dfu_application.zip"
if [[ -f "$DFU_ZIP" ]]; then
  echo "build: found $DFU_ZIP - processing firmware version"
  
  # Extract version.txt from the zip. version.txt contains e.g. "oo-2.0.0"
  FW_VERSION_RAW=$(unzip -p "$DFU_ZIP" version.txt 2>/dev/null || true)
  
  if [[ -n "$FW_VERSION_RAW" ]]; then
    # Format: oo-2.0.0 -> oo200 (remove '-' and '.')
    FW_SHORT=$(echo "$FW_VERSION_RAW" | tr -d '.-')
    FW_OUT_PATH="$RELEASES_DIR/${FW_SHORT}.zip"
    
    cp "$DFU_ZIP" "$FW_OUT_PATH"
    echo "build: wrote $FW_OUT_PATH (firmware version $FW_VERSION_RAW)"
    
    # Cleanup firmware build directory
    FW_BUILD_DIR="$ROOT_DIR/omi/firmware/omi/build"
    echo "build: cleaning up $FW_BUILD_DIR"
    rm -rf "$FW_BUILD_DIR"
  else
    echo "build: warning - could not extract version.txt from $DFU_ZIP"
  fi
fi
