# TODO

## Streaming file list response [UX improvement]

Currently `CMD_LIST_FILES (0x10)` blocks until the firmware completes a full directory walk,
buffers all results, then sends one BLE notification burst. With 100 files this can take 5ΓÇô30 seconds
before the app sees anything. The fix is to stream entries as they are found, matching the pattern
already used by `CMD_READ_FILE` (`0x01` data frames + `0x02` EOT).

**Not urgent** ΓÇö the current approach is reliable after the timeout/retry fixes. Do this
when the wait time becomes a visible UX complaint or file counts grow significantly.

**Protocol change:**
Replace the current single response `[count:1][ts:4LE][sz:4LE]├ùN` with:
- `[PACKET_FILE_ENTRY (0x04)][ts:4LE][sz:4LE]` ΓÇö one notification per file, sent as the walk finds it
- `[0x02 EOT]` ΓÇö signals end of list (same sentinel used by CMD_READ_FILE)

A new command byte is needed ΓÇö **note: `0x14` is already taken by `CMD_CLEAR_STORAGE`**, so use
e.g. `CMD_LIST_FILES_STREAM 0x15` to avoid breaking existing app versions that expect the old framing.

**Firmware tasks (`omi/firmware/omi/src/lib/core/`):**
- [ ] Add `CMD_LIST_FILES_STREAM (0x15)` to `storage.h`
- [ ] Modify the `REQ_GET_FILE_LIST` sd_worker handler (`sd_card.c`) to accept a per-entry callback
  instead of filling a flat array ΓÇö called once per file as the directory walk progresses
- [ ] In `storage.c`: new `send_file_list_streaming()` ΓÇö calls `storage_notify()` per entry, then sends
  `0x02 EOT`; replaces the `storage_buffer` batch-build approach in `send_file_list_response()` (line 288)
- [ ] Keep existing `CMD_LIST_FILES (0x10)` / `send_file_list_response()` unchanged for backward compat

**App tasks:**
- [ ] Add `CMD_LIST_FILES_STREAM` path in `performListFiles()` (`omi_connection.dart:267`)
  - Subscribe to data characteristic, write `0x15`, accumulate `StorageFile` per `PACKET_FILE_ENTRY`,
    complete on `0x02 EOT` (same timeout/generation-guard logic as today)
- [ ] Expose a `Stream<List<StorageFile>>` variant so `_buildWalsFromFiles()` can render progressive UI
- [ ] Fall back to `CMD_LIST_FILES (0x10)` if firmware does not support `0x15` (check via features characteristic)

**Key advantage over pagination:** no cursor/index stability problem ΓÇö firmware pushes a snapshot,
so file deletions between "pages" are not possible. No app-side state machine needed.

**Relevant files:**
- `omi/firmware/omi/src/lib/core/storage.c:288` ΓÇö `send_file_list_response()` to replace
- `omi/firmware/omi/src/lib/core/storage.h` ΓÇö add `CMD_LIST_FILES_STREAM`, `PACKET_FILE_ENTRY`
- `omi/firmware/omi/src/sd_card.c:2336` ΓÇö `get_audio_file_list_with_sizes()` walk to make streamable
- `app/lib/services/devices/omi_connection.dart:267` ΓÇö `performListFiles()` to extend
- `app/lib/services/wals/sdcard_wal_sync.dart:161` ΓÇö `_buildWalsFromFiles()` consumer

## Apple Watch Integration [minor]

The platform layer (watchOS app, iOS AppDelegate, Pigeon-generated Swift/Dart code) is complete and functional. The Dart side is never wired up.

### Issues

- **`WatchRecorderFlutterAPI.setUp()` never called** ΓÇö Pigeon message channel handlers are never registered, so all incoming watch messages (audio segments, recording start/stop, battery updates) are silently dropped. Fix: instantiate `AppleWatchFlutterBridge` and call `WatchRecorderFlutterAPI.setUp(bridge)` in `ServiceManager.init()` or `main.dart`.

- **`AppleWatchFlutterBridge` never instantiated** ΓÇö `app/lib/services/bridges/apple_watch_bridge.dart` exists but is never used anywhere in the app.

- **No consumer for watch audio data** ΓÇö The `onSegment` callback in `AppleWatchFlutterBridge` has no handler. Watch audio frames need to be routed into the same pipeline as BLE audio.

- **No UI for watch status** ΓÇö APIs exist to check pairing, reachability, battery level, and app installation (`WatchRecorderHostAPI`), but no Flutter screen or widget displays any of this.

### Relevant Files

- `app/lib/services/bridges/apple_watch_bridge.dart` ΓÇö bridge class, needs instantiation + `setUp()` call
- `app/lib/gen/flutter_communicator.g.dart:468` ΓÇö `WatchRecorderFlutterAPI.setUp()` defined here
- `app/lib/services/services.dart` ΓÇö `ServiceManager.init()` is the right place to wire this up
- `app/ios/Runner/AppDelegate.swift` ΓÇö WCSession delegate, already functional
- `app/ios/Runner/RecorderHostApiImpl.swift` ΓÇö host API implementation, already functional
- `app/ios/omiWatchApp/` ΓÇö watchOS app, already functional

## Re-disable uploads during Adjustment Mode

Uploads to external APIs (HeyPocket, Omi Sync) were temporarily enabled during Adjustment Mode for testing. These need to be disabled again so users do not accidentally upload debugging audio.

**App tasks:**
- [x] Uncomment the `if (_prefs.adjustmentMode) return;` check in `tryAutoUploadNext()` in `app/lib/pages/recordings/recordings_controller.dart`.
- [x] Uncomment the `if (_prefs.adjustmentMode) return;` check in `tryAutoSyncNext()` in `app/lib/pages/recordings/recordings_controller.dart`.
- [x] Uncomment the `if (_prefs.adjustmentMode) throw Exception(...)` block in `uploadConversation()` in `app/lib/pages/recordings/recordings_controller.dart`.
- [x] Uncomment the `if (_prefs.adjustmentMode)` check in `_handleUploadTap` in `app/lib/pages/recordings/recordings_page.dart`.
- [x] Uncomment the `if (_prefs.adjustmentMode)` check in `_handleUpload` in `app/lib/pages/recordings/recording_player_page.dart`.
- [x] Uncomment the `if (adjustmentMode)` check in `UploadIconButton.build` in `app/lib/pages/recordings/batch_card.dart`.

## AAD Threshold Refactor & Noise Profiling

Refactor the hardware-acoustic Wake-on-Voice (AAD) system to be user-adjustable and self-tuning.

### Phase 1: Manual Adjustability [Complete]
Successfully implemented manual threshold control from the app.
- **Firmware:** Added `vad_threshold` to settings NVS, dynamic `aad_set_threshold()` API, and BLE Characteristic `0x19B10013`.
- **App:** Added AAD Sensitivity slider (0–32768) in Device Settings with presets and "Always On" (0) / "Manual Only" (32768) support.

### Phase 2: Learning & Auto-Tune [In Progress]
Implement a hybrid statistical/distribution profiling system to allow the device to "Auto-Tune" to its environment.

**Architectural Separation:**
1. **Runtime Autotune Engine (Welford's Algorithm):** 
   - Lightweight, production-safe running stats (Mean, Variance/StdDev).
   - Used for "Auto-Tune" button calculation: `Threshold = Mean + 3*StdDev`.
2. **Developer Diagnostics (Logarithmic Histogram):**
   - 8-bucket distribution visualization for debugging and environmental insight.
   - Buckets: 0-31, 32-63, 64-127, 128-255, 256-511, 512-1023, 1024-2047, 2048+.

**Firmware Tasks:**
- [ ] Implement `vad_profile_t` in `aad.c` using Welford's Online Algorithm.
- [ ] Add 8-bucket logarithmic histogram tracking in `aad.c`.
- [ ] Add BLE Characteristic `0x19B10062` (Read Profile Data: N, Mean, M2, Buckets, Peak, Recording Frames).
- [ ] Add BLE Characteristic `0x19B10063` (Write: Reset Stats).
- [ ] Add periodic persistence for Mean/M2 in `settings.c`.

**App Tasks:**
- [ ] Add **Developer: Noise Diagnostics** dashboard in Device Settings.
- [ ] Implement Bar Chart visualization for logarithmic histogram.
- [ ] Implement **Threshold Overlay** (white line) on top of histogram.
- [ ] Implement **Safe Zone Overlay** (green shaded area for `Mean +/- 3*StdDev`).
- [ ] Implement **Auto-Tune** button: calculates and writes new threshold based on profile.
- [ ] Add "Learning Progress" indicator (Total Frames / Duration).

**Relevant Files:**
- `omi/firmware/omi/src/aad.c` - VAD logic and statistical engine.
- `omi/firmware/omi/src/lib/core/transport.c` - BLE characteristic handlers.
- `app/lib/pages/settings/device_settings.dart` - UI Dashboard and Auto-Tune logic.
- `app/lib/services/devices/omi_connection.dart` - BLE communication.

## Auto-Tune Mic Gain
- [ ] Incorporate automatic tuning of Mic Gain based on hardware amplitude detection.
  - **Concept:** Use the peak amplitude tracking from the Noise Profiler to dynamically adjust the hardware microphone gain.
  - **Anti-Clipping:** If the peak amplitude consistently hits the ceiling (e.g., > 30,000), automatically step down the `mic_gain` to prevent distorted, blown-out audio.
  - **Auto-Boost:** If the peak amplitude of recorded speech is consistently very low, incrementally step up the `mic_gain` to improve signal-to-noise ratio.
  - **Implementation Idea:** The firmware could run a slow PID loop or hysteresis check on the `peak` value over a multi-minute window, adjusting the gain setting directly and notifying the app of the change.