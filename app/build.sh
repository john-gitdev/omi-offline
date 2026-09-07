#!/usr/bin/env bash
# Build both halves — firmware DFU zip and dev-flavor APK — into releases/.
#
# A thin wrapper over ../ccbuild.sh, which is the single implementation of all
# three entry points. It used to be the other way round (this script drove
# build-apk.sh and build-fw.sh, and ccbuild.sh called those two as well), which
# meant the version-naming rule existed in three copies and build-fw.sh could not
# actually compile anything despite its name.
#
# Firmware is skipped with a notice, not an error, when the Zephyr/nRF toolchain is
# absent — an app-only developer has no SDK and still wants the APK. Ask for
# firmware explicitly (build-fw.sh) and a missing toolchain is an error.
#
# Deterministic: no version bump, no commit, no push. Extra flags pass straight
# through, so `./app/build.sh --force` works.
set -euo pipefail
exec bash "$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/ccbuild.sh" "$@"
