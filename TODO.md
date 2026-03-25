# TODO

## UI/UX

### Unknown Timestamp Handling

Files recorded before the device ever synced time (drained battery before first BLE connection)
will have no valid UTC and appear as `TMP_` on the filesystem. These recordings should surface
in the app with an "Unknown date" state rather than silently failing or being dropped.

**Tasks:**
- [ ] Detect recordings with `timestamp == 0` (TMP_ files that were never renamed) in the WAL/recordings list
- [ ] Show these in a dedicated "Unknown date" section or with a placeholder label in the daily batch UI
- [ ] Allow the user to manually set a date/time for an unknown-timestamp recording
  - Tapping sets `StorageFile.timestamp` (or equivalent metadata) and re-slots the recording into the correct day
  - Persist the user-set timestamp so it survives app restart
- [ ] Consider showing a one-time prompt when unknown recordings are detected ("Some recordings have no date — tap to assign")

## StorageStatus — free space & file count from firmware [pending UI decision]

The firmware already returns a 16-byte LE payload via a BLE read characteristic on connect:
`[total_used_bytes:4][file_count:4][free_bytes:4][status_flags:4]`

The app currently estimates storage usage by calling CMD_LIST_FILES and summing file sizes against a hardcoded 480 MB total. Implementing `getStorageFileStats()` on `OmiDeviceConnection` (reading the characteristic via `transport.readCharacteristic()`) would give accurate free space and file count in a single lightweight read.

**Blocked on:** where to surface this in the UI (e.g. device settings page, sync page, home screen indicator, storage full warning).

**Tasks (once UI location decided):**
- [ ] Add `getStorageFileStats()` / `performGetStorageFileStats()` to `DeviceConnection` + `OmiDeviceConnection`
  - Read `storageDataCharacteristicUuid` on `storageDataStreamServiceUuid`, parse 16 bytes LE
- [ ] Replace `_retrieveStorageFullPercentage()` in `DeviceProvider` with the new method (uses accurate `free_bytes` instead of hardcoded 480 MB total)
- [ ] Expose `freeBytes` and `fileCount` in the UI wherever decided

**Relevant files:**
- `app/lib/services/devices/device_connection.dart` — add abstract methods
- `app/lib/services/devices/omi_connection.dart` — implement BLE read
- `app/lib/providers/device_provider.dart:108` — `_retrieveStorageFullPercentage()` to replace
- `omi/firmware/omi/src/lib/core/storage.c:141` — `storage_read_characteristic()` reference

## Streaming file list response [UX improvement]

Currently `CMD_LIST_FILES (0x10)` blocks until the firmware completes a full FAT directory walk,
buffers all results, then sends one BLE notification burst. With 100 files this can take 5–30 seconds
before the app sees anything. The fix is to stream entries as they are found, matching the pattern
already used by `CMD_READ_FILE` (`PACKET_DATA` frames + `PACKET_EOT`).

**Not urgent** — the current approach is now reliable after the timeout/double-refresh fixes. Do this
when the wait time becomes a visible UX complaint or file counts grow significantly.

**Protocol change:**
Replace the current single response `[count:1][ts:4LE][sz:4LE]×N` with:
- `[PACKET_FILE_ENTRY (0x04)][ts:4LE][sz:4LE]` — one notification per file, sent as the walk finds it
- `[PACKET_EOT (0x02)]` — signals end of list (same sentinel used by CMD_READ_FILE)

A new command byte (e.g. `CMD_LIST_FILES_STREAM 0x14`) avoids breaking existing app versions that
expect the old framing.

**Firmware tasks (`omi/firmware/omi/src/lib/core/`):**
- [ ] Add `CMD_LIST_FILES_STREAM (0x14)` to `storage.h`
- [ ] Modify the `REQ_GET_FILE_LIST` sd_worker handler (`sd_card.c`) to accept a per-entry callback
  instead of filling a flat array — called once per file as the directory walk progresses
- [ ] In `storage.c`: new `send_file_list_streaming()` — calls `storage_notify()` per entry, then sends
  `PACKET_EOT`; replaces the `storage_buffer` batch-build approach
- [ ] Keep existing `CMD_LIST_FILES (0x10)` / `send_file_list_response()` unchanged for backward compat

**App tasks:**
- [ ] Add `CMD_LIST_FILES_STREAM` path in `performListFiles()` (`omi_connection.dart`)
  - Subscribe to data characteristic, write `0x14`, accumulate `StorageFile` per `PACKET_FILE_ENTRY`,
    complete on `PACKET_EOT` (same timeout/generation-guard logic as today)
- [ ] Expose a `Stream<List<StorageFile>>` variant so `_buildWalsFromFiles()` can render progressive UI
- [ ] Fall back to `CMD_LIST_FILES (0x10)` if firmware does not support `0x14` (check via features characteristic)

**Key advantage over pagination:** no cursor/index stability problem — firmware pushes a snapshot,
so file deletions between "pages" are not possible. No app-side state machine needed.

**Relevant files:**
- `omi/firmware/omi/src/lib/core/storage.c:281` — `send_file_list_response()` to replace
- `omi/firmware/omi/src/lib/core/storage.h` — add `CMD_LIST_FILES_STREAM`, `PACKET_FILE_ENTRY`
- `omi/firmware/omi/src/sd_card.c:2212` — `get_audio_file_list_with_sizes()` walk to make streamable
- `app/lib/services/devices/omi_connection.dart:330` — `performListFiles()` to extend
- `app/lib/services/wals/sdcard_wal_sync.dart:185` — `_buildWalsFromFiles()` consumer

## User-configurable sync interval [minor]

Currently sync runs on a fixed 30-minute interval. Let the user choose the interval (e.g. 15 min, 30 min, 1 hr, manual only) via a settings screen. Shorter intervals reduce data loss window but increase BLE radio usage and battery drain on both devices; surface this tradeoff in the UI.

## Apple Watch Integration [minor]

The platform layer (watchOS app, iOS AppDelegate, Pigeon-generated Swift/Dart code) is complete and functional. The Dart side is never wired up.

### Issues

- **`WatchRecorderFlutterAPI.setUp()` never called** — Pigeon message channel handlers are never registered, so all incoming watch messages (audio segments, recording start/stop, battery updates) are silently dropped. Fix: instantiate `AppleWatchFlutterBridge` and call `WatchRecorderFlutterAPI.setUp(bridge)` in `ServiceManager.init()` or `main.dart`.

- **`AppleWatchFlutterBridge` never instantiated** — `app/lib/services/bridges/apple_watch_bridge.dart` exists but is never used anywhere in the app.

- **No consumer for watch audio data** — The `onSegment` callback in `AppleWatchFlutterBridge` has no handler. Watch audio frames need to be routed into `RecordingsManager` (or similar) the same way BLE audio is.

- **No UI for watch status** — APIs exist to check pairing, reachability, battery level, and app installation (`WatchRecorderHostAPI`), but no Flutter screen or widget displays any of this.

- **`apple_watch.png` asset referenced but unused** — An image asset for the watch exists but is not displayed anywhere in the UI.

### Relevant Files

- `app/lib/services/bridges/apple_watch_bridge.dart` — bridge class, needs instantiation + `setUp()` call
- `app/lib/gen/flutter_communicator.g.dart` — Pigeon-generated code, `WatchRecorderFlutterAPI.setUp()` defined here
- `app/lib/services/services.dart` — `ServiceManager.init()` is the right place to wire this up
- `app/ios/Runner/AppDelegate.swift` — WCSession delegate, already functional
- `app/ios/Runner/RecorderHostApiImpl.swift` — host API implementation, already functional
- `app/ios/omiWatchApp/` — watchOS app, already functional
