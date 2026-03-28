# Upstream Pull Requests

This document tracks upstream pull requests and details why they have or have not been merged into this local repository.

## Unmerged PRs

### [PR #5994: Fix sync endpoint silent failure causing permanent audio loss](https://github.com/BasedHardware/omi/pull/5994)
- **Status:** Unmerged
- **Reason:** This PR addresses silent failures in the network/API synchronization layer and audio data preservation. It does not contain any Bluetooth Low Energy (BLE) hardware connection reliability fixes between the phone and the Omi device, which is what we are looking for.
