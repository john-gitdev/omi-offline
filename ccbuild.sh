#!/usr/bin/env bash
# Build a flashable pair — firmware DFU zip + dev APK — and drop both in releases/.
#
# The gap this fills: app/build-fw.sh does NOT compile anything. It packages an
# already-built dfu_application.zip and then deletes the build directory. So the
# firmware half has meant either a VS Code / nRF Connect build first, or setting up
# the Zephyr environment by hand. This does the compile too.
#
# Deterministic only, matching app/build.sh: no version bump, no commit, no push.
# Version numbers come from app/pubspec.yaml and CONFIG_BT_DIS_FW_REV_STR as they
# stand right now.
#
#   ./ccbuild.sh                 firmware + APK, skipping whichever is already current
#   ./ccbuild.sh --force         build both regardless
#   ./ccbuild.sh --fw            firmware only
#   ./ccbuild.sh --apk           APK only
#   ./ccbuild.sh --fw --keep-build   firmware, leaving build/ intact for incrementals
#   ./ccbuild.sh --fw --pristine     force a fresh configure, discarding build/
#
# A plain run works out for itself what needs building: a half is skipped when the
# artifact it would write is already in releases/ and no input has been touched
# since, so an app-only change rebuilds just the APK and costs no firmware time.
# It says which file made the call either way. --force overrides, and --pristine
# implies it for the firmware half — discarding build/ to then skip the build
# would be a strange thing to have asked for. --fw/--apk still say which halves
# to consider at all. (--if-changed is accepted and does nothing; it is now the
# default. --no-skip is a synonym for --force.)
#
# Environment overrides (all auto-detected otherwise):
#   NCS_ROOT        default C:/ncs
#   ZEPHYR_BASE     default the newest NCS_ROOT/v*/zephyr
#   NCS_TOOLCHAIN   default the newest NCS_ROOT/toolchains/<hash>

set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
FW_DIR="$ROOT_DIR/omi/firmware/omi"
FW_BUILD_DIR="$FW_DIR/build/omi"
RELEASES_DIR="$ROOT_DIR/releases"

DO_FW=1
DO_APK=1
KEEP_BUILD=0
PRISTINE=0
# Auto-detect by default: the common run is "pick up whatever I just changed", and
# paying five idle minutes on the untouched half is the whole reason this is here.
IF_CHANGED=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fw)         DO_APK=0 ;;
    --apk)        DO_FW=0 ;;
    --keep-build) KEEP_BUILD=1 ;;
    --pristine)   PRISTINE=1 ;;
    --force|--no-skip) IF_CHANGED=0 ;;
    --if-changed) ;;  # the default now; still accepted so old invocations work
    # Prints the whole leading comment block, however long it grows — the old fixed
    # line range silently truncated its own usage text the first time one was added.
    -h|--help)    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            echo "ccbuild: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\033[1mccbuild:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mccbuild: %s\033[0m\n' "$*" >&2; exit 1; }

# cmake wants Windows-style paths (C:/…), bash gives POSIX (/c/…).
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# ── Is a build necessary? (--if-changed) ────────────────────────────────────────
# "Not necessary" means the artifact this run would write is already in releases/
# and nothing feeding it has been touched since. The test is deliberately biased
# toward building: a missing artifact, an unreadable version, or one newer input
# is enough. The two failure directions are not symmetric — an unnecessary build
# costs minutes, while a wrongly skipped one hands you a stale zip or APK that
# looks freshly built and you find out on the device.
#
# mtime rather than a content hash, because a git checkout stamps every restored
# file with the checkout time and so errs toward rebuilding — the safe direction.
#
# Inputs are the repo tree only. An NCS or toolchain update changes the firmware
# image without touching a file here, and this will not notice — run without
# --if-changed after one.

# The naming build-apk.sh and build-fw.sh both use for their output.
short_version() {
  local clean; clean="$(echo "$1" | tr -d '.-')"
  if [[ "$clean" == oo* ]]; then echo "$clean"; else echo "oo$clean"; fi
}

# First input under $2 newer than $1, or nothing. Build outputs are pruned (the
# build writes them itself), as are editor/tool directories. Two app-specific
# exclusions, both generated rather than authored: app/test, since tests are not
# compiled into the APK and a test edit would otherwise cost a ten-minute rebuild,
# and the plugin/local-properties files any `flutter pub get` rewrites — a plain
# `bash app/test.sh` run would otherwise mark the APK stale.
newer_input() {
  local ref="$1" tree="$2"
  find "$tree" \
       -path '*/build' -prune -o \
       -path '*/.dart_tool' -prune -o \
       -path '*/.gradle' -prune -o \
       -path '*/.cxx' -prune -o \
       -path '*/.claude' -prune -o \
       -path '*/.idea' -prune -o \
       -path '*/.vscode' -prune -o \
       -path "$ROOT_DIR/app/test" -prune -o \
       -name .flutter-plugins-dependencies -o \
       -name .flutter-plugins -o \
       -name local.properties -o \
       -type f -newer "$ref" -print -quit 2>/dev/null
}

# True when $1 exists and nothing under $2 is newer; sets SKIP_REASON either way.
SKIP_REASON=""
up_to_date() {
  local artifact="$1" tree="$2"
  if [[ ! -f "$artifact" ]]; then
    SKIP_REASON="$(basename "$artifact") is not in releases/"
    return 1
  fi
  local newer; newer="$(newer_input "$artifact" "$tree")"
  if [[ -n "$newer" ]]; then
    SKIP_REASON="${newer#"$ROOT_DIR/"} is newer than $(basename "$artifact")"
    return 1
  fi
  SKIP_REASON="nothing under ${tree#"$ROOT_DIR/"} is newer than $(basename "$artifact")"
  return 0
}

# ── Firmware ────────────────────────────────────────────────────────────────────
build_firmware() {
  local fw_ver
  fw_ver="$(awk -F'"' '/^CONFIG_BT_DIS_FW_REV_STR=/ {print $2; exit}' "$FW_DIR/omi.conf")"
  [[ -n "$fw_ver" ]] || die "could not read CONFIG_BT_DIS_FW_REV_STR from $FW_DIR/omi.conf"

  # Ahead of the toolchain hunt on purpose: an up-to-date firmware then skips
  # cleanly on a machine with no NCS install, instead of dying looking for one.
  if [[ $IF_CHANGED -eq 1 && $PRISTINE -eq 0 ]] &&
     up_to_date "$RELEASES_DIR/$(short_version "$fw_ver").zip" "$ROOT_DIR/omi/firmware"; then
    say "firmware $fw_ver — nothing to do ($SKIP_REASON)"
    return 0
  fi
  BUILT=1

  local ncs="${NCS_ROOT:-/c/ncs}"
  [[ -d "$ncs" ]] || die "NCS not found at $ncs — set NCS_ROOT to your nRF Connect SDK install."

  # Newest toolchain hash, unless pinned. The hash changes with an SDK update, which
  # is exactly why this is not hardcoded.
  local tc="${NCS_TOOLCHAIN:-}"
  if [[ -z "$tc" ]]; then
    tc="$(find "$ncs/toolchains" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
  fi
  [[ -n "$tc" && -d "$tc" ]] || die "no toolchain under $ncs/toolchains — set NCS_TOOLCHAIN."

  local zbase="${ZEPHYR_BASE:-}"
  if [[ -z "$zbase" ]]; then
    zbase="$(find "$ncs" -mindepth 2 -maxdepth 2 -type d -name zephyr 2>/dev/null | sort | tail -1)"
  fi
  [[ -n "$zbase" && -d "$zbase" ]] || die "no Zephyr tree under $ncs — set ZEPHYR_BASE."

  # Both toolchain layouts, because they differ by more than a path separator. The
  # Windows bundle puts west under opt/bin and runs the system Python; the Linux one
  # ships a whole sysroot — west lives in usr/local/bin and is a python3.12 script
  # that will not start until LD_LIBRARY_PATH/PYTHONHOME point back inside the
  # toolchain. Listing dirs that do not exist is harmless, so both go on PATH
  # unconditionally; the Linux-only variables are set only when its libdir is really
  # there, so a Windows run is left exactly as it was.
  export PATH="$tc/opt/bin:$tc/opt/bin/Scripts:$tc/opt/nanopb/generator-bin:$tc/opt/zephyr-sdk/arm-zephyr-eabi/bin:$tc/opt/zephyr-sdk/riscv64-zephyr-elf/bin:$tc/mingw64/bin:$tc/bin:$tc/usr/bin:$tc/usr/local/bin:$PATH"
  if [[ -d "$tc/usr/local/lib" ]]; then
    export LD_LIBRARY_PATH="$tc/lib:$tc/lib/x86_64-linux-gnu:$tc/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export PYTHONHOME="$tc/usr/local"
    export PYTHONPATH="$tc/usr/local/lib/python3.12:$tc/usr/local/lib/python3.12/site-packages"
  fi
  export ZEPHYR_BASE="$zbase"
  export ZEPHYR_SDK_INSTALL_DIR="$tc/opt/zephyr-sdk"
  export ZEPHYR_TOOLCHAIN_VARIANT=zephyr

  command -v west >/dev/null 2>&1 || die "west not on PATH even after toolchain setup ($tc)."

  say "firmware $fw_ver  (toolchain $(basename "$tc"), $(basename "$(dirname "$zbase")"))"

  # BOARD_ROOT is required: the board lives one level above the app dir, and without
  # it cmake cannot find omi/nrf5340/cpuapp and dumps the entire upstream board list.
  local board_root; board_root="$(winpath "$ROOT_DIR/omi/firmware")"
  local conf;       conf="$(winpath "$FW_DIR/omi.conf")"

  # Kept rather than a temp file: /tmp is not writable in every shell here, and a
  # build log you can go back to is worth more than one that deletes itself. build/
  # is gitignored, so it never shows up as a change.
  # An incremental build reuses whatever CMakeCache is already there — including
  # Kconfig overrides injected on the command line by someone else. The nRF Connect
  # VS Code extension builds into this very directory with CMAKE_BUILD_TYPE=Debug and
  # CONFIG_DEBUG_THREAD_INFO=y, so without this check ccbuild would quietly produce a
  # debug image and label it a clean build. That exact confusion cost a round of
  # binary-diffing to untangle, so it fails loudly instead of silently.
  if [[ $PRISTINE -eq 0 && -f "$FW_BUILD_DIR/CMakeCache.txt" ]]; then
    local foreign
    foreign="$(grep -E '^(CMAKE_BUILD_TYPE:[A-Z]*=Debug|CONFIG_[A-Z0-9_]+:UNINITIALIZED=)'                  "$FW_BUILD_DIR/CMakeCache.txt" || true)"
    if [[ -n "$foreign" ]]; then
      say "existing build/ was configured elsewhere (IDE?) with overrides:"
      printf '    %s
' $foreign
      say "reconfiguring from scratch so the output matches omi.conf alone"
      PRISTINE=1
    fi
  fi
  if [[ $PRISTINE -eq 1 && -d "$FW_DIR/build" ]]; then
    rm -rf "$FW_DIR/build"
  fi

  mkdir -p "$FW_DIR/build"
  local log="$FW_DIR/build/ccbuild-last.log"
  cd "$FW_DIR"
  if [[ -d "$FW_BUILD_DIR" ]]; then
    say "incremental build (build/omi exists)"
    west build -d build/omi 2>&1 | tee "$log"
  else
    say "full configure + build"
    west build -b omi/nrf5340/cpuapp -d build/omi --sysbuild -- \
      -DBOARD_ROOT="$board_root" -DCACHED_CONF_FILE="$conf" -DCONF_FILE="$conf" 2>&1 | tee "$log"
  fi
  local rc=${PIPESTATUS[0]}
  [[ $rc -eq 0 ]] || die "west build failed (exit $rc) — full log: $log"


  # A clean build emits ~14 Kconfig warnings from upstream Zephyr/NCS that are not
  # actionable. Anything naming a path inside this repo is ours, and new.
  local ours
  ours="$(grep -E "omi-offline.*(warning|error)" "$log" || true)"
  if [[ -n "$ours" ]]; then
    printf '\033[1;33mccbuild: warnings from repo sources — these are yours:\033[0m\n%s\n' "$ours"
  fi

  local zip="$FW_BUILD_DIR/dfu_application.zip"
  [[ -f "$zip" ]] || die "build reported success but $zip is missing."

  if [[ $KEEP_BUILD -eq 1 ]]; then
    # Same naming as build-fw.sh, but without its rm -rf: an incremental rebuild is
    # ~1 min against ~5 for a fresh configure, which matters while iterating.
    local raw short
    raw="$(unzip -p "$zip" version.txt 2>/dev/null || true)"
    [[ -n "$raw" ]] || die "could not read version.txt from $zip"
    short="$(echo "$raw" | tr -d '.-')"; [[ "$short" == oo* ]] || short="oo$short"
    mkdir -p "$RELEASES_DIR"
    cp "$zip" "$RELEASES_DIR/$short.zip"
    say "wrote $RELEASES_DIR/$short.zip (build dir kept)"
  else
    bash "$ROOT_DIR/app/build-fw.sh"
  fi
}

# ── APK ─────────────────────────────────────────────────────────────────────────
build_apk() {
  local app_ver
  app_ver="$(awk '/^version:/ {print $2; exit}' "$ROOT_DIR/app/pubspec.yaml")"
  [[ -n "$app_ver" ]] || die "could not read version from app/pubspec.yaml"

  if [[ $IF_CHANGED -eq 1 ]] && up_to_date "$RELEASES_DIR/$(short_version "$app_ver").apk" "$ROOT_DIR/app"; then
    say "app $app_ver — nothing to do ($SKIP_REASON)"
    return 0
  fi
  BUILT=1
  say "app $app_ver  (flutter clean + build apk --flavor dev — several minutes)"
  bash "$ROOT_DIR/app/build-apk.sh"
}

# ── Run ─────────────────────────────────────────────────────────────────────────
# Firmware first: it is the half that fails fast, and the APK is the slow one. No
# point spending ten minutes on an APK to then find the firmware would not compile.
BUILT=0
[[ $DO_FW  -eq 1 ]] && build_firmware
[[ $DO_APK -eq 1 ]] && build_apk

# Skipping is the default, so a run that built nothing has to say so outright —
# otherwise it reads as a build that finished suspiciously fast.
if [[ $BUILT -eq 0 ]]; then
  say "everything already current — nothing rebuilt (--force builds anyway)"
fi
say "done — artifacts in releases/"
ls -lh "$RELEASES_DIR" 2>/dev/null | tail -n +2 | awk '{printf "  %s  %s\n", $5, $9}'
