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