#!/usr/bin/env bash
# Build the dev-flavor release APK, rename it after the current pubspec
# version (e.g. 0.14.6 -> oo0146.apk), and drop it in releases/ at the repo root.
# Then build the firmware zip if the Zephyr/nRF toolchain is available.
#
# Deterministic only: no version bump, no commit, no push. Run those
# steps yourself (or via the /RELEASE flow) before calling this.

set -euo pipefail

APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

bash "$APP_DIR/build-apk.sh"

# The firmware build needs the nRF Connect SDK / Zephyr toolchain, which app-only
# developers won't have. Don't let its absence fail the APK build — skip with a notice.
if ! bash "$APP_DIR/build-fw.sh"; then
    echo "build.sh: firmware build skipped or failed (Zephyr/nRF toolchain required) — APK build above is unaffected." >&2
fi
