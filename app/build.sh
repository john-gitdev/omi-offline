#!/usr/bin/env bash
# Build the dev-flavor release APK, rename it after the current pubspec
# version (e.g. 0.14.6 -> oo0146.apk), and drop it in releases/ at the repo root.
#
# Deterministic only: no version bump, no commit, no push. Run those
# steps yourself (or via the /RELEASE flow) before calling this.

set -euo pipefail

APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

bash "$APP_DIR/build-apk.sh"
bash "$APP_DIR/build-fw.sh"
