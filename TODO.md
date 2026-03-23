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
