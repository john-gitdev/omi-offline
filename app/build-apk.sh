#!/usr/bin/env bash
# Build the dev-flavor release APK only, into releases/ named after the pubspec
# version (0.36.10 -> oo03610.apk).
#
# A thin wrapper over ../ccbuild.sh --apk.
#
# Deterministic: no version bump, no commit, no push. Extra flags pass through, so
# `./app/build-apk.sh --force` rebuilds even when the APK is already current.
set -euo pipefail
exec bash "$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/ccbuild.sh" --apk "$@"
