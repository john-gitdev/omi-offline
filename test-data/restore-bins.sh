#!/usr/bin/env bash
# Restore raw .bin segments to the dev app for live processing tests.
# Usage: bash test-data/restore-bins.sh [tarball]
# Default tarball: live_bins_20260603.tar
set -e

PKG="com.omi.offline.dev"
TARBALL="${1:-live_bins_20260603.tar}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAR_PATH="$SCRIPT_DIR/$TARBALL"

if [ ! -f "$TAR_PATH" ]; then
  echo "Error: $TAR_PATH not found"
  exit 1
fi

echo "Pushing $TARBALL to device..."
MSYS_NO_PATHCONV=1 adb push "$TAR_PATH" /data/local/tmp/restore_bins.tar

echo "Extracting..."
MSYS_NO_PATHCONV=1 adb shell "run-as $PKG tar xf /data/local/tmp/restore_bins.tar -C /"
MSYS_NO_PATHCONV=1 adb shell "rm /data/local/tmp/restore_bins.tar"

echo "Done — open the app to start processing."
