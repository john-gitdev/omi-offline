#!/usr/bin/env bash
# Rename the latest firmware build and cleanup the build folder.
set -euo pipefail

APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$APP_DIR/.." && pwd )"
RELEASES_DIR="$ROOT_DIR/releases"

# Format version: remove dots and dashes, ensure 'oo' prefix
format_version_short() {
  local v="$1"
  local clean=$(echo "$v" | tr -d '.-')
  if [[ "$clean" != oo* ]]; then
    echo "oo$clean"
  else
    echo "$clean"
  fi
}

mkdir -p "$RELEASES_DIR"

# --- Firmware DFU handling ---
DFU_ZIP="$ROOT_DIR/omi/firmware/omi/build/omi/dfu_application.zip"
if [[ -f "$DFU_ZIP" ]]; then
  echo "build-fw: found $DFU_ZIP - processing firmware version"
  
  # Extract version.txt from the zip.
  FW_VERSION_RAW=$(unzip -p "$DFU_ZIP" version.txt 2>/dev/null || true)
  
  if [[ -n "$FW_VERSION_RAW" ]]; then
    FW_SHORT=$(format_version_short "$FW_VERSION_RAW")
    FW_OUT_PATH="$RELEASES_DIR/${FW_SHORT}.zip"
    
    cp "$DFU_ZIP" "$FW_OUT_PATH"
    echo "build-fw: wrote $FW_OUT_PATH (firmware version $FW_VERSION_RAW)"
  else
    echo "build-fw: warning - could not extract version.txt from $DFU_ZIP"
  fi
fi

# Cleanup firmware build directory regardless of whether DFU_ZIP was found
FW_BUILD_DIR="$ROOT_DIR/omi/firmware/omi/build"
if [[ -d "$FW_BUILD_DIR" ]]; then
  echo "build-fw: cleaning up $FW_BUILD_DIR"
  rm -rf "$FW_BUILD_DIR"
fi
