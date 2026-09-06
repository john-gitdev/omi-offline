#!/usr/bin/env bash
# Build a DEBUGGABLE dev APK and drop it in releases/ as oo<version>-debug.apk.
#
# Why this exists, and why it is NOT the default:
#
# The app keeps everything that matters — raw_segments/, discarded_segments/,
# recordings/, wals.json, the .meta sidecars — under getApplicationDocumentsDirectory(),
# which on Android is /data/data/<pkg>/app_flutter. That is app-private. On an
# unrooted phone the ONLY way to read it is `adb shell run-as <pkg>`, and run-as
# refuses a package whose manifest is not debuggable. ccbuild.sh produces a release
# APK, so a question like "is this bin still on disk or did something delete it?"
# cannot be answered from the artifact you are running. That is a real gap: on
# 2026-09-06 a 227 KB bin was downloaded, deleted from the card, and never decoded,
# and the difference between "still on disk, wrongly filtered" and "the write never
# landed" could not be settled without this.
#
# It is deliberately NOT the default build, because `flutter build apk --debug` is a
# JIT build. Dart runs interpreted, asserts are on, and there is no AOT snapshot — so
# the Silero decode pass, the processing isolate, background service timing and
# battery draw all behave differently from what ships. Hunting a timing- or
# throughput-sensitive bug in this build tells you about this build. Reach for it when
# you need the filesystem, then go back to ccbuild.sh.
#
# Data is preserved across the swap in BOTH directions. android/app/build.gradle sets
#   productFlavors.dev.signingConfig signingConfigs.debug
# and signingConfigs.debug loads android/key.properties when it exists, so devDebug and
# devRelease carry the same signature and install over each other as updates. That
# matters more than convenience here: the app-private data IS the evidence, and an
# uninstall/reinstall would destroy it. If key.properties is missing, the debug build
# falls back to the default debug keystore, the signature will not match, and the
# install is refused — cleanly, without touching the data. Checked up front for --install,
# and warned about loudly otherwise: a build-only run is still useful to someone with no
# release APK installed, where there is no signature to match and nothing to preserve.
#
#   ./ccbuilddev.sh              build only
#   ./ccbuilddev.sh --install    build, then install over whatever is on the device
#
# After you are done, put the real build back:  adb install -r releases/oo<version>.apk
set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_DIR="$ROOT_DIR/app"
PUBSPEC="$APP_DIR/pubspec.yaml"
RELEASES_DIR="$ROOT_DIR/releases"
PKG="com.omi.offline.dev"

DO_INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) DO_INSTALL=1 ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "ccbuilddev: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\033[1mccbuilddev:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mccbuilddev: %s\033[0m\n' "$*" >&2; exit 1; }

# The ONLY path Gradle reads. android/app/build.gradle does
# `rootProject.file('key.properties')`, and inside a Flutter Android project rootProject is
# app/android — so app/android/key.properties is the single file deciding whether
# signingConfigs.debug uses the release keystore. Do NOT also accept
# <repo>/android/key.properties: no such directory exists, Gradle would never load it, and
# a stray file there would let this check pass while the build was signed with the default
# debug keystore — the exact outcome the check exists to prevent.
KEY_PROPS="$APP_DIR/android/key.properties"

# Everything that can reject this run, checked BEFORE the build rather than after it. A
# ten-minute build ending in "no device attached" is a bad trade for three lines.
if [[ $DO_INSTALL -eq 1 ]]; then
  command -v adb >/dev/null 2>&1 || die "--install given but adb is not on PATH"
  adb get-state >/dev/null 2>&1 || die "--install given but no device is attached (adb devices)"
  # Fatal only for --install, where the package manager would refuse us at the end anyway.
  # A build-only run is still useful to someone with no release APK installed: there is no
  # signature to match and nothing to preserve.
  [[ -f "$KEY_PROPS" ]] || die "app/android/key.properties missing — a debug build is then signed with the
  default debug keystore, will NOT match an installed release APK, and could only be
  installed by uninstalling first, which destroys the app-private data this build exists
  to read. Refusing rather than doing that."
fi

VERSION="$(awk '/^version:/ {print $2; exit}' "$PUBSPEC")"
[[ -n "${VERSION:-}" ]] || die "could not parse version from $PUBSPEC"

short_version() { local c; c=$(echo "$1" | tr -d '.-'); [[ "$c" == oo* ]] && echo "$c" || echo "oo$c"; }
OUT_PATH="$RELEASES_DIR/$(short_version "$VERSION")-debug.apk"

say "version=$VERSION  output=$OUT_PATH"
if [[ ! -f "$KEY_PROPS" ]]; then
  # Not fatal here, but never silent: this artifact cannot be installed over an existing
  # release build, and discovering that by uninstalling is how the data gets destroyed.
  printf '\033[1;33mccbuilddev: WARNING\033[0m %s\n' \
    "app/android/key.properties is missing, so this APK is signed with the default debug
  keystore. It will NOT install over an existing release build — 'adb install -r' is
  refused. Do NOT uninstall to work around that: the app-private data is usually the whole
  reason for building this." >&2
fi
mkdir -p "$RELEASES_DIR"

# No `flutter clean` here, unlike build-apk.sh. That costs ten minutes and buys
# nothing for a throwaway diagnostic build; the release artifact is produced by
# ccbuild.sh, which still cleans.
cd "$APP_DIR"
flutter build apk --debug --flavor dev

SRC_APK="$APP_DIR/build/app/outputs/flutter-apk/app-dev-debug.apk"
[[ -f "$SRC_APK" ]] || die "build succeeded but $SRC_APK not found"

# -debug in the name, in releases/ alongside the real artifacts: nothing here may be
# mistakable for a shippable build, and `oo0368.apk` vs `oo0368-debug.apk` is the only
# thing standing between you and flashing a JIT build to a test user.
mv "$SRC_APK" "$OUT_PATH"
say "wrote $OUT_PATH"

if [[ $DO_INSTALL -eq 1 ]]; then
  say "installing as an update (app data preserved)…"
  adb install -r "$OUT_PATH"
  say "installed. run-as is now available, e.g."
  say "  adb shell run-as $PKG ls -l app_flutter/raw_segments/"
  say "restore the real build with: adb install -r $RELEASES_DIR/$(short_version "$VERSION").apk"
fi
