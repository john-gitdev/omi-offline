#!/usr/bin/env bash
# Build the firmware DFU zip only, into releases/.
#
# A thin wrapper over ../ccbuild.sh --fw. Note this now COMPILES the firmware; the
# old build-fw.sh only packaged a zip somebody else had already built, which is the
# gap ccbuild.sh was written to fill.
#
# A missing Zephyr/nRF toolchain is an error here, unlike build.sh: firmware is
# what was asked for.
#
# Extra flags pass through — `./app/build-fw.sh --keep-build` leaves the build
# directory intact for incremental rebuilds, `--pristine` forces a fresh configure.
set -euo pipefail
exec bash "$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/ccbuild.sh" --fw "$@"
