#!/usr/bin/env bash
# Build the dev-flavor release APK and rename it after the pubspec version.
set -euo pipefail

APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$APP_DIR/.." && pwd )"
PUBSPEC="$APP_DIR/pubspec.yaml"
RELEASES_DIR="$ROOT_DIR/releases"

VERSION="$(awk '/^version:/ {print $2; exit}' "$PUBSPEC")"
if [[ -z "${VERSION:-}" ]]; then
  echo "build-apk: could not parse version from $PUBSPEC" >&2
  exit 1
fi

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

SHORT=$(format_version_short "$VERSION")
OUT_PATH="$RELEASES_DIR/${SHORT}.apk"

echo "build-apk: version=$VERSION  output=$OUT_PATH"
mkdir -p "$RELEASES_DIR"

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
