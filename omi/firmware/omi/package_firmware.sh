#!/usr/bin/env bash
# Usage: ./package_firmware.sh [output_name] [input_zip]
# Reads version from omi.conf, adds version.txt to the build zip,
# and writes the result as build/omi/<output_name>.zip.
#
# Defaults:
#   input_zip   build/omi/dfu_application.zip
#   output_name dfu_application_release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/omi.conf"

OUTPUT_NAME="${1:-dfu_application_release}"
BUILD_ZIP="${2:-$SCRIPT_DIR/build/omi/dfu_application.zip}"

if [[ ! -f "$BUILD_ZIP" ]]; then
  echo "Error: $BUILD_ZIP not found. Build the firmware first (or pass the zip path as \$2)." >&2
  exit 1
fi

VERSION=$(grep 'CONFIG_BT_DIS_FW_REV_STR' "$CONF" | sed 's/.*="\(.*\)"/\1/')
if [[ -z "$VERSION" ]]; then
  echo "Error: Could not read CONFIG_BT_DIS_FW_REV_STR from $CONF" >&2
  exit 1
fi

OUTPUT_ZIP="$SCRIPT_DIR/build/omi/${OUTPUT_NAME}.zip"

cp "$BUILD_ZIP" "$OUTPUT_ZIP"

python3 -c "
import zipfile, sys
output, version = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(output, 'a') as z:
    z.writestr('version.txt', version)
print(f'Packaged: {output} (version: {version})')
" "$OUTPUT_ZIP" "$VERSION"
