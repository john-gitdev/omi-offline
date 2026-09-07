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
  
  # Extract version.txt from the zip. `unzip` is NOT part of a default Git for
  # Windows install, and a missing one was indistinguishable from a zip with no
  # version.txt: both warned, skipped the copy, and then deleted the build directory
  # anyway — throwing away a five-minute firmware build with nothing saved.
  FW_VERSION_RAW=$(unzip -p "$DFU_ZIP" version.txt 2>/dev/null || true)

  # Fall back to the file the zip's own version.txt is generated from, so the copy
  # still happens with no unzip on the box. Same value by construction (both read
  # CONFIG_BT_DIS_FW_REV_STR), so this is a second route to one answer, not a guess.
  if [[ -z "$FW_VERSION_RAW" ]]; then
    FW_VERSION_RAW=$(awk -F'"' '/^CONFIG_BT_DIS_FW_REV_STR=/ {print $2; exit}'       "$ROOT_DIR/omi/firmware/omi/omi.conf" 2>/dev/null || true)
    if [[ -n "$FW_VERSION_RAW" ]]; then
      echo "build-fw: could not read version.txt (no unzip?) - using omi.conf: $FW_VERSION_RAW"
    fi
  fi

  if [[ -n "$FW_VERSION_RAW" ]]; then
    FW_SHORT=$(format_version_short "$FW_VERSION_RAW")
    FW_OUT_PATH="$RELEASES_DIR/${FW_SHORT}.zip"

    cp "$DFU_ZIP" "$FW_OUT_PATH"
    echo "build-fw: wrote $FW_OUT_PATH (firmware version $FW_VERSION_RAW)"
  else
    echo "build-fw: warning - could not determine the firmware version from $DFU_ZIP or omi.conf" >&2
    KEEP_BUILD_DIR=1
  fi
fi

# Cleanup the firmware build directory. The one case it is kept is a zip that was
# built but could not be named: deleting then would destroy the only copy of a
# build nothing has saved, and the rebuild is minutes. A build directory with no
# zip in it is deleted as before — there is no artifact to lose, and a clean slate
# is what a failed or absent build wants.
FW_BUILD_DIR="$ROOT_DIR/omi/firmware/omi/build"
if [[ -d "$FW_BUILD_DIR" ]]; then
  if [[ "${KEEP_BUILD_DIR:-0}" -eq 1 ]]; then
    echo "build-fw: keeping $FW_BUILD_DIR - nothing reached releases/, so the zip in it is the only copy" >&2
  else
    echo "build-fw: cleaning up $FW_BUILD_DIR"
    rm -rf "$FW_BUILD_DIR"
  fi
fi
