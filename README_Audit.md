# README Audit Summary

## README Baseline
- **Commit Hash:** `57341454f3e0a616ef5fb4b0b9b7a75b2006f10a`
- **Commit Date:** Thu Jun 4 22:45:39 2026 -0700
- **What it described:** The repository structure with an offline architecture, using an isolate-based VAD Audio Processor in Dart.
- **Number of Commits Reviewed:** 66 commits between the baseline and HEAD.

## Documentation Gaps
- **Missing Features:**
  - Android Native VAD Batch Runner integration (replaced/augmented Dart isolate-based processor for Android).
  - "Upload on Wifi Only" toggle setting.
  - AAD/VAD designation tags in the recording list and metadata.
  - Forget Device relocation to the Discovery Page.
- **Outdated Sections:**
  - The "Key Components" or Architecture sections missed the `VadBatchRunner.kt` (Android native) and `vad_batch_runner_channel.dart`.
  - The App Settings table lacked "Upload on Wifi Only", the relocated "Short Recordings".
  - Adjustment mode (added in 0.20.0 and removed in 0.20.0) left some lingering confusion in commits but was correctly identified as fully removed by the final commit.
  - The Reprocess Day debug tool was removed.
  - The Repository structure had old directories like `app/integration_test`, `app/e2e`, and `test-data/` which were removed.
- **Missing Setup/Configuration:** None significantly missing that blocks setup, but App Settings and Debug tools configuration have evolved.
- **Missing Architecture Information:** The switch to using a native JNI/MethodChannel-based VAD batch runner in Android (`VadBatchRunner.kt`) for better memory management instead of pure Dart.

## Commit-Derived Improvements

### Major Features
- **Android Native VAD Batch Runner:** Introduced a native implementation for Android to handle VAD batch processing, significantly improving performance.
- **Upload on Wifi Only:** Added a user preference to restrict HeyPocket/Integration uploads to Wi-Fi.

### Developer Experience Improvements
- **Repository Cleanup:** Removed `app/e2e`, `app/integration_test`, `test-data/`, `app/NOTE.md`, and deprecated Android assets.

### UI / Settings Refactors
- **Relocated Forget Device:** Moved from Debug Tools to the "Find Devices" discovery page.
- **App Settings Reorganization:** Combined auto sync, Wifi-only uploads, save format, short recordings, and retention policy into a streamlined view.
- **Processing Designation:** Added AAD/VAD processing tags directly in the recording subtext for better transparency.
- **Adjustment Mode:** Implemented and subsequently removed an 'Adjustment Mode' for safe reprocessing.

### Bug Fixes & Reliability
- **Sync Robustness:** Hardened the pipeline against unexpected Bluetooth disconnections, socket timeouts, and isolate hangs.
- **Ghost Recordings:** Refined the deletion behavior to properly clean up discard rows (ghost recordings) and un-break the "Delete Day" feature.

---

# Proposed README.md

[See the updated README.md file in the root directory for the complete rewritten content.]

---

# Confidence Report

- **Assumptions:** Assuming the integration with Silero VAD remains the core offline processing model, despite the migration to the native Android runner for performance.
- **Verification:** Verified the presence of `VadBatchRunner.kt` and the removal of directories like `app/e2e` and `test-data`. The removal of Adjustment mode and Reprocess Day was verified in commit `05f498074` and UI changes verified in subsequent commits.
