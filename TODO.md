# TODO

## UI/UX

### Unknown Timestamp Handling

Files recorded before the device ever synced time will have no valid UTC
anchor. Currently the app silently back-fills a derived timestamp (current
time minus estimated audio duration) rather than surfacing the ambiguity to
the user.

**Tasks:**
- [ ] Detect recordings whose timestamp was derived rather than firmware-provided (no reliable UTC anchor) in the WAL/recordings list
- [ ] Show these in a dedicated "Unknown date" section or with a placeholder label in the daily batch UI
- [ ] Allow the user to manually set a date/time for an unknown-timestamp recording
  - Tapping sets `StorageFile.timestamp` (or equivalent metadata) and re-slots the recording into the correct day
  - Persist the user-set timestamp so it survives app restart
- [ ] Consider showing a one-time prompt when unknown recordings are detected ("Some recordings have no date — tap to assign")

## Streaming file list response [UX improvement]

Currently `CMD_LIST_FILES (0x10)` blocks until the firmware completes a full directory walk,
buffers all results, then sends one BLE notification burst. With 100 files this can take 5–30 seconds
before the app sees anything. The fix is to stream entries as they are found, matching the pattern
already used by `CMD_READ_FILE` (`0x01` data frames + `0x02` EOT).

**Not urgent** — the current approach is reliable after the timeout/retry fixes. Do this
when the wait time becomes a visible UX complaint or file counts grow significantly.

**Protocol change:**
Replace the current single response `[count:1][ts:4LE][sz:4LE]×N` with:
- `[PACKET_FILE_ENTRY (0x04)][ts:4LE][sz:4LE]` — one notification per file, sent as the walk finds it
- `[0x02 EOT]` — signals end of list (same sentinel used by CMD_READ_FILE)

A new command byte is needed — **note: `0x14` is already taken by `CMD_CLEAR_STORAGE`**, so use
e.g. `CMD_LIST_FILES_STREAM 0x15` to avoid breaking existing app versions that expect the old framing.

**Firmware tasks (`omi/firmware/omi/src/lib/core/`):**
- [ ] Add `CMD_LIST_FILES_STREAM (0x15)` to `storage.h`
- [ ] Modify the `REQ_GET_FILE_LIST` sd_worker handler (`sd_card.c`) to accept a per-entry callback
  instead of filling a flat array — called once per file as the directory walk progresses
- [ ] In `storage.c`: new `send_file_list_streaming()` — calls `storage_notify()` per entry, then sends
  `0x02 EOT`; replaces the `storage_buffer` batch-build approach in `send_file_list_response()` (line 288)
- [ ] Keep existing `CMD_LIST_FILES (0x10)` / `send_file_list_response()` unchanged for backward compat

**App tasks:**
- [ ] Add `CMD_LIST_FILES_STREAM` path in `performListFiles()` (`omi_connection.dart:267`)
  - Subscribe to data characteristic, write `0x15`, accumulate `StorageFile` per `PACKET_FILE_ENTRY`,
    complete on `0x02 EOT` (same timeout/generation-guard logic as today)
- [ ] Expose a `Stream<List<StorageFile>>` variant so `_buildWalsFromFiles()` can render progressive UI
- [ ] Fall back to `CMD_LIST_FILES (0x10)` if firmware does not support `0x15` (check via features characteristic)

**Key advantage over pagination:** no cursor/index stability problem — firmware pushes a snapshot,
so file deletions between "pages" are not possible. No app-side state machine needed.

**Relevant files:**
- `omi/firmware/omi/src/lib/core/storage.c:288` — `send_file_list_response()` to replace
- `omi/firmware/omi/src/lib/core/storage.h` — add `CMD_LIST_FILES_STREAM`, `PACKET_FILE_ENTRY`
- `omi/firmware/omi/src/sd_card.c:2336` — `get_audio_file_list_with_sizes()` walk to make streamable
- `app/lib/services/devices/omi_connection.dart:267` — `performListFiles()` to extend
- `app/lib/services/wals/sdcard_wal_sync.dart:161` — `_buildWalsFromFiles()` consumer

## Apple Watch Integration [minor]

The platform layer (watchOS app, iOS AppDelegate, Pigeon-generated Swift/Dart code) is complete and functional. The Dart side is never wired up.

### Issues

- **`WatchRecorderFlutterAPI.setUp()` never called** — Pigeon message channel handlers are never registered, so all incoming watch messages (audio segments, recording start/stop, battery updates) are silently dropped. Fix: instantiate `AppleWatchFlutterBridge` and call `WatchRecorderFlutterAPI.setUp(bridge)` in `ServiceManager.init()` or `main.dart`.

- **`AppleWatchFlutterBridge` never instantiated** — `app/lib/services/bridges/apple_watch_bridge.dart` exists but is never used anywhere in the app.

- **No consumer for watch audio data** — The `onSegment` callback in `AppleWatchFlutterBridge` has no handler. Watch audio frames need to be routed into the same pipeline as BLE audio.

- **No UI for watch status** — APIs exist to check pairing, reachability, battery level, and app installation (`WatchRecorderHostAPI`), but no Flutter screen or widget displays any of this.

### Relevant Files

- `app/lib/services/bridges/apple_watch_bridge.dart` — bridge class, needs instantiation + `setUp()` call
- `app/lib/gen/flutter_communicator.g.dart:468` — `WatchRecorderFlutterAPI.setUp()` defined here
- `app/lib/services/services.dart` — `ServiceManager.init()` is the right place to wire this up
- `app/ios/Runner/AppDelegate.swift` — WCSession delegate, already functional
- `app/ios/Runner/RecorderHostApiImpl.swift` — host API implementation, already functional
- `app/ios/omiWatchApp/` — watchOS app, already functional
