#!/usr/bin/env bash
# Build the dev-flavor release APK, rename it after the current pubspec
# version (e.g. 0.14.6 -> oo0146.apk), and drop it at the repo root.
#
# Deterministic only: no version bump, no commit, no push. Run those
# steps yourself (or via the /RELEASE flow) before calling this.

set -euo pipefail

APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$APP_DIR/.." && pwd )"
PUBSPEC="$APP_DIR/pubspec.yaml"

VERSION="$(awk '/^version:/ {print $2; exit}' "$PUBSPEC")"
if [[ -z "${VERSION:-}" ]]; then
  echo "build-apk: could not parse version from $PUBSPEC" >&2
  exit 1
fi

SHORT="oo$(echo "$VERSION" | tr -d '.')"
OUT_PATH="$ROOT_DIR/${SHORT}.apk"

echo "build-apk: version=$VERSION  output=$OUT_PATH"

cd "$APP_DIR"
flutter clean
flutter build apk --flavor dev

SRC_APK="$APP_DIR/build/app/outputs/flutter-apk/app-dev-release.apk"
if [[ ! -f "$SRC_APK" ]]; then
  echo "build-apk: build succeeded but $SRC_APK not found" >&2
  exit 1
fi

mv "$SRC_APK" "$OUT_PATH"
echo "build-apk: wrote $OUT_PATH"
