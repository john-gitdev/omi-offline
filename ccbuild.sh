#!/usr/bin/env bash
# Build a flashable pair — firmware DFU zip + dev APK — and drop both in releases/.
#
# The single implementation behind all three entry points. app/build.sh,
# app/build-fw.sh and app/build-apk.sh are thin wrappers that call this with no
# flag, --fw and --apk respectively, and pass everything else straight through.
#
# It used to be the other way round: build.sh drove build-apk.sh and build-fw.sh,
# and this script called those same two. That left the version-naming rule in three
# copies, and a build-fw.sh that could not compile anything despite its name — it
# packaged a dfu_application.zip somebody else had already built, so the firmware
# half meant a VS Code / nRF Connect build first or a Zephyr environment set up by
# hand. This does the compile.
#
# Deterministic only: no version bump, no commit, no push. Version numbers come from
# app/pubspec.yaml and CONFIG_BT_DIS_FW_REV_STR as they stand right now.
#
# A missing Zephyr/nRF toolchain is a NOTICE when both halves were asked for (the
# run carries on to the APK; an app-only developer has no SDK and still wants one)
# and an ERROR under --fw, where firmware is what was asked for.
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
# Runs on Linux, macOS and Windows (Git Bash) unchanged. The only thing that
# genuinely differs is where the nRF Connect SDK lives, which is searched for; the
# toolchain layouts underneath it already differ by more than a path separator and
# are both handled below.
#
# Environment overrides (all auto-detected otherwise):
#   NCS_ROOT        first of $HOME/ncs, /opt/nordic/ncs, /opt/ncs, /c/ncs, /d/ncs
#                   that looks like an SDK install
#   ZEPHYR_BASE     default the newest NCS_ROOT/v*/zephyr
#   NCS_TOOLCHAIN   default the newest NCS_ROOT/toolchains/<hash>

set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
FW_DIR="$ROOT_DIR/omi/firmware/omi"
FW_BUILD_DIR="$FW_DIR/build/omi"
RELEASES_DIR="$ROOT_DIR/releases"

# Where to look for the nRF Connect SDK, in order. The old code defaulted to
# /c/ncs — one machine's Windows path — so a Linux or macOS run died pointing at a
# drive letter that cannot exist there. $HOME/ncs is the Toolchain Manager default
# on Linux and macOS, /opt/nordic/ncs the common system-wide one, /c/ncs the
# Windows installer default (and /d/ for a second drive). Listing all of them on
# every platform is harmless: the ones belonging to the other OS simply do not
# exist. NCS_ROOT still wins outright, so an unusual install needs no edit here.
NCS_CANDIDATES=("$HOME/ncs" /opt/nordic/ncs /opt/ncs /c/ncs /d/ncs)

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

say()  { printf '\033[1mccbuild:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mccbuild: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mccbuild: %s\033[0m\n' "$*" >&2; exit 1; }

# Fatal when the firmware was ASKED for, a notice when it was merely implied.
#
# The distinction is the whole reason app/build.sh could be pointed here: an
# app-only developer has no Zephyr toolchain and never will, and a plain run that
# died on that before touching the APK would be useless to them. Asking for
# firmware explicitly (--fw) and not getting it is a different thing, and stays an
# error. Only environment problems go through here — no SDK, no toolchain, no west.
# An actual compile failure is fatal either way: that is a broken tree, not a
# machine without the tools, and quietly shipping an APK beside it would hide it.
fw_missing() {
  if [[ $DO_APK -eq 0 ]]; then die "$*"; fi
  warn "$* — skipping firmware, continuing to the APK"
  return 1
}

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

# ── Where is the SDK? ───────────────────────────────────────────────────────────
# A candidate has to LOOK like an SDK install, not merely exist. An empty ~/ncs
# left behind by an abandoned install would otherwise win over a real one further
# down the list, and the run would then die at the toolchain hunt instead — with a
# message about a missing toolchain rather than the wrong root, which is the
# harder of the two to act on.
looks_like_ncs() {
  [[ -d "$1/toolchains" ]] && return 0
  [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -type d -name 'v*' -print -quit 2>/dev/null)" ]]
}

# Sets NCS_DIR, or dies. Deliberately not a `$(...)` helper: `die` exits, and from
# inside a command substitution that only ends the subshell — the caller would carry
# on with an empty string and report a second, vaguer error over the real one.
NCS_DIR=""
resolve_ncs() {
  # An explicit NCS_ROOT wins even when it does not look like an install: saying
  # "you pointed me at this and it is not there" beats quietly searching elsewhere
  # and building against a different SDK than the one that was asked for.
  if [[ -n "${NCS_ROOT:-}" ]]; then
    [[ -d "$NCS_ROOT" ]] || die "NCS_ROOT is set to '$NCS_ROOT', which is not a directory."
    NCS_DIR="$NCS_ROOT"
    return 0
  fi
  local c
  for c in "${NCS_CANDIDATES[@]}"; do
    if [[ -d "$c" ]] && looks_like_ncs "$c"; then
      NCS_DIR="$c"
      return 0
    fi
  done
  fw_missing "no nRF Connect SDK found (looked in: ${NCS_CANDIDATES[*]}; set NCS_ROOT)"
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

  resolve_ncs || return 1
  local ncs="$NCS_DIR"

  # Most recently installed toolchain, unless pinned. The hash changes with an SDK
  # update, which is exactly why this is not hardcoded.
  #
  # `|| true` on both searches, and it is not defensive noise. Under `set -o
  # pipefail` a failing `find` (a missing directory, an unreadable one) makes the
  # whole pipeline non-zero, an assignment takes its command substitution's status,
  # and `set -e` then kills the script THERE — silently, exit 1, no output at all,
  # never reaching the `die` on the next line that says what is actually wrong.
  # Reachable for real: a `west init` install has v2.9.0 and no bundled toolchains/
  # at all, which is an ordinary Linux setup, and those users got the silent exit.
  local tc="${NCS_TOOLCHAIN:-}"
  if [[ -z "$tc" && -d "$ncs/toolchains" ]]; then
    # `ls -t` (mtime, newest first), not `sort` on the name. These directories are
    # opaque hashes, so sorting them lexicographically picks an arbitrary one — which
    # is not what the comment above says, and not what anyone wants the moment an SDK
    # update installs a second alongside the first. Identical with one installed,
    # which is why it went unnoticed. `ls -t` is POSIX; `find -printf '%T@'` would be
    # the obvious alternative and is GNU-only, so it would work here and on Git Bash
    # and break on macOS. The trailing slash restricts the glob to directories, which
    # is what -type d was doing (toolchains/ also holds a toolchains.json).
    tc="$(ls -td "$ncs/toolchains"/*/ 2>/dev/null | head -1)" || true
    tc="${tc%/}"
  fi
  [[ -n "$tc" && -d "$tc" ]] || fw_missing "no toolchain under $ncs/toolchains (set NCS_TOOLCHAIN)" || return 1

  local zbase="${ZEPHYR_BASE:-}"
  if [[ -z "$zbase" ]]; then
    zbase="$(find "$ncs" -mindepth 2 -maxdepth 2 -type d -name zephyr 2>/dev/null | sort | tail -1)" || true
  fi
  [[ -n "$zbase" && -d "$zbase" ]] || fw_missing "no Zephyr tree under $ncs (set ZEPHYR_BASE)" || return 1

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

  command -v west >/dev/null 2>&1 || fw_missing "west not on PATH even after toolchain setup ($tc)" || return 1

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
  # Same class of problem, different trigger: editing a Kconfig value in omi.conf does
  # NOT reliably re-run the Zephyr configure step in an existing build dir. Bumping
  # CONFIG_BT_DIS_FW_REV_STR and rebuilding with --keep-build produced an image still
  # carrying the OLD version — silently, and in the worst possible place: the zip is
  # named from omi.conf (so it looks right on disk) while the DIS characteristic inside
  # reports the stale one. The app fingerprints the GATT cache on exactly that string,
  # so a wrong DIS version means a missed cache refresh after a flash.
  #
  # Compare what the build dir was configured with against what omi.conf says now, and
  # reconfigure from scratch if they differ. Only reachable with --keep-build or an IDE
  # build; a plain run deletes build/ on the way out and starts clean anyway.
  if [[ $PRISTINE -eq 0 && -f "$FW_BUILD_DIR/omi/zephyr/.config" ]]; then
    local built_ver
    built_ver="$(awk -F'"' '/^CONFIG_BT_DIS_FW_REV_STR=/ {print $2; exit}' "$FW_BUILD_DIR/omi/zephyr/.config")"
    if [[ -n "$built_ver" && "$built_ver" != "$fw_ver" ]]; then
      say "build/ is configured for $built_ver but omi.conf now says $fw_ver"
      say "reconfiguring from scratch so the image reports the version it is named after"
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

  package_firmware_zip "$zip" "$fw_ver"
}

# Name the built zip after the firmware version and put it in releases/, then clear
# the build directory unless asked to keep it.
#
# Was app/build-fw.sh, called from here as a separate process. Folded in so that the
# thing which builds the firmware is also the thing which files it — the split meant
# two copies of the version-naming rule, and a build-fw.sh that could not compile
# anything, which is the confusion this script was written to end.
package_firmware_zip() {
  local zip="$1" conf_ver="$2"
  local raw short

  # `unzip` is NOT part of a default Git for Windows install, so falling back to the
  # file version.txt is generated from is what makes this work there at all: one
  # answer reached two ways, not a guess. (Verified equal on the current build.)
  raw="$(unzip -p "$zip" version.txt 2>/dev/null || true)"
  if [[ -z "$raw" && -n "$conf_ver" ]]; then
    raw="$conf_ver"
    say "could not read version.txt (no unzip?) — using omi.conf: $raw"
  fi
  [[ -n "$raw" ]] || die "could not name $zip: no version.txt in it and no version in omi.conf."

  short="$(short_version "$raw")"
  mkdir -p "$RELEASES_DIR"
  cp "$zip" "$RELEASES_DIR/$short.zip"
  say "wrote $RELEASES_DIR/$short.zip (firmware version $raw)"

  # Only ever deleted once the zip is safely in releases/. Deleting a build whose
  # artifact was never filed destroys the only copy of it, and the rebuild is minutes.
  # An incremental rebuild is ~1 min against ~5 for a fresh configure, which is what
  # --keep-build is for.
  if [[ $KEEP_BUILD -eq 1 ]]; then
    say "keeping $FW_DIR/build for incremental rebuilds (--keep-build)"
  elif [[ -d "$FW_DIR/build" ]]; then
    say "cleaning up $FW_DIR/build"
    rm -rf "$FW_DIR/build"
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

  # Was app/build-apk.sh. Same reason as the firmware half: one implementation, and
  # the version-naming rule stated once.
  local out="$RELEASES_DIR/$(short_version "$app_ver").apk"
  mkdir -p "$RELEASES_DIR"
  # In a subshell so the `cd` cannot leak. build-apk.sh got this for free by being a
  # separate process; folded in, a bare `cd` would leave the rest of the run standing
  # somewhere it did not choose.
  ( cd "$ROOT_DIR/app" && flutter clean && flutter build apk --flavor dev ) || die "flutter build failed"

  local src="$ROOT_DIR/app/build/app/outputs/flutter-apk/app-dev-release.apk"
  [[ -f "$src" ]] || die "flutter reported success but $src is missing."
  mv "$src" "$out"
  say "wrote $out"
}

# ── Run ─────────────────────────────────────────────────────────────────────────
# Firmware first: it is the half that fails fast, and the APK is the slow one. No
# point spending ten minutes on an APK to then find the firmware would not compile.
BUILT=0
FW_SKIPPED=0
# `|| FW_SKIPPED=1` rather than a bare call: build_firmware returns non-zero when
# fw_missing let it through, and under `set -e` an unguarded non-zero here would end
# the run before the APK — the exact failure this arrangement exists to avoid.
if [[ $DO_FW -eq 1 ]]; then
  build_firmware || FW_SKIPPED=1
fi
[[ $DO_APK -eq 1 ]] && build_apk

# Skipping is the default, so a run that built nothing has to say so outright —
# otherwise it reads as a build that finished suspiciously fast.
if [[ $BUILT -eq 0 ]]; then
  say "everything already current — nothing rebuilt (--force builds anyway)"
fi
# Said again at the end because the notice above scrolls past a ten-minute APK
# build, and "done" over a run that silently built half of what was asked is how a
# stale firmware zip gets flashed.
if [[ $FW_SKIPPED -eq 1 ]]; then
  warn "firmware was NOT built (see above) — any .zip below is from an earlier run"
fi
say "done — artifacts in releases/"
ls -lh "$RELEASES_DIR" 2>/dev/null | tail -n +2 | awk '{printf "  %s  %s\n", $5, $9}'
