# Codebase Bug Review

Comprehensive review of the Omi offline-first wearable codebase. Findings are deduplicated across Flutter app (services, providers, UI) and firmware layers.

---

## CRITICAL

### 1. Opus decoder state corruption between VAD and save passes

**File:** `app/lib/services/offline_audio_processor.dart:202-205, 412-415`

A single `_decoder` instance is used for both the VAD analysis pass (`processSegmentFile`, line 205) and the recording save pass (`_saveRecording`, line 415). Opus decoders are stateful — they maintain internal prediction and packet-loss concealment state. The VAD pass decodes all frames, leaving the decoder in a state that corresponds to the end of the audio stream. When `_saveRecording` then re-decodes the same frames from disk, the decoder state is stale from the VAD pass, producing audible artifacts (clicks, distortion) especially at recording boundaries.

**Fix:** Create a fresh `SimpleOpusDecoder` instance in `_saveRecording`, or reset the decoder state before the second pass.

---

### 2. Storage write offset endianness inconsistency (masked — always zero today)

**File:** `app/lib/services/devices/omi_connection.dart:146-151` and `omi/firmware/omi/src/lib/core/storage.c:221-222`

Both the Flutter app and firmware use **big-endian** for the storage write command offset. However, the rest of the BLE protocol uses little-endian (storage read list at `omi_connection.dart:128-131`, BLE data packets, time sync). While both sides currently agree, this inconsistency is a latent trap: if either side is "fixed" to use little-endian independently, it will break. More importantly, the offset is currently always 0 (the app always re-downloads from the beginning), so any nonzero offset has never been tested through the full stack.

**Fix:** Align both sides to little-endian for consistency with the rest of the protocol, and add integration tests for nonzero resume offsets.

---

### 3. FindDevicesPage bypasses full connection pipeline

**File:** `app/lib/pages/settings/find_devices_page.dart:86-121`

When a user pairs via FindDevicesPage, `_connectToDevice` calls `ensureConnection`, then manually sets `setConnectedDevice(device)` and `setIsConnected(true)`. This bypasses `DeviceProvider._onDeviceConnected()`, which is responsible for: starting health checks, initiating battery/button listeners, setting up WAL sync, triggering background sync, and retrieving storage percentage. The BLE connection callback will eventually fire `_handleDeviceConnected` via debouncer, but it races with the manual state set, potentially causing `_onDeviceConnected` to run with partially stale state or triggering duplicate `ensureConnection` calls.

**Fix:** Remove the manual `setConnectedDevice`/`setIsConnected` calls and let the `onDeviceConnectionStateChanged` callback handle state transitions through the normal pipeline.

---

### 4. C macro precedence errors in firmware codec config

**File:** `omi/firmware/omi/src/lib/core/config.h:25-26`

```c
#define CODEC_PACKAGE_SAMPLES 160 * 2
#define CODEC_OUTPUT_MAX_BYTES CODEC_PACKAGE_SAMPLES / 2
```

These macros lack parentheses. `CODEC_OUTPUT_MAX_BYTES` expands to `160 * 2 / 2 = 160` (correct by accident due to left-to-right evaluation). But `sizeof(arr) / CODEC_PACKAGE_SAMPLES` would expand to `sizeof(arr) / 160 * 2` — completely wrong. Any future use of these macros in compound expressions will silently produce incorrect values.

**Fix:** `#define CODEC_PACKAGE_SAMPLES (160 * 2)` and `#define CODEC_OUTPUT_MAX_BYTES (CODEC_PACKAGE_SAMPLES / 2)`.

---

## MODERATE

### 5. `_isUserTriggered` never reset on error paths

**File:** `app/lib/pages/recordings/recordings_page.dart:286, 304-311, 334`

`_isUserTriggered` is set to `true` at line 286 in `_runPipeline()` and only reset to `false` at line 334 after `_runProcessing()` completes successfully. If `syncAll()` throws (catch block at line 303), the method returns at line 311 without resetting the flag. Once stuck `true`, the polling logic stops tracking background sync state changes, breaking the sync status UI until the page is recreated.

**Fix:** Reset `_isUserTriggered = false` in the catch block before returning.

---

### 6. Brightness/mic-gain slider debounce drops intermediate BLE writes

**File:** `app/lib/pages/settings/device_settings.dart:364-368`

The debounce guard `if (!(_debounce?.isActive ?? false))` only fires the first change, then silently drops all subsequent rapid changes until the 300ms timer fires. A proper debounce should cancel-and-restart the timer on every change. The `onChangeEnd` handler does send the final value, but during a slow drag the device LED visibly lags. Same issue for mic gain slider (lines 473-477).

**Fix:** Replace with `_debounce?.cancel(); _debounce = Timer(...)` on every `onChanged`.

---

### 7. Subscription key collision using `hashCode`

**File:** `app/lib/services/devices.dart:98` and `app/lib/services/wals/wal_service.dart:19`

Both `DeviceService.subscribe` and `WalService.subscribe` use `context.hashCode` as the map key. Dart's `hashCode` is not guaranteed to be unique across objects. A collision silently overwrites the existing subscription, causing lost event notifications with no error.

**Fix:** Use `identityHashCode(context)` or use the `context` object directly as the key.

---

### 8. No timeout on BLE adapter state and connection state waits

**File:** `app/lib/services/devices/transports/ble_transport.dart:63, 67`

`connect()` waits indefinitely for the Bluetooth adapter to reach the `on` state (line 63) and then for the device to reach `connected` state (line 67). If Bluetooth is disabled or the device is unreachable, these futures never complete and the app hangs.

**Fix:** Add `timeout(const Duration(seconds: 15))` to both stream waits.

---

### 9. `setDevice` is `async void` — exceptions silently swallowed

**File:** `app/lib/services/wals/sdcard_wal_sync.dart:127`

```dart
void setDevice(BtDevice? device) async {
```

An `async` method returning `void` means the caller cannot await it and exceptions from `getMissingWals()` are silently lost. The interface declares it as `void`, hiding the async nature from callers.

**Fix:** Return `Future<void>` from both the interface and implementation.

---

### 10. `TcpTransport` recursive disconnect from socket error handler

**File:** `app/lib/services/devices/transports/tcp_transport.dart:88-96`

The socket's `onError` handler calls `disconnect()`, which calls `_cleanup()`, which cancels `_clientSubscription`. Cancelling a subscription from within its own listener can cause undefined behavior. Also `disconnect()` is async but not awaited.

**Fix:** Schedule the disconnect on the next microtask: `Future.microtask(() => disconnect())`.

---

### 11. `DeviceConnection.disconnect()` does not cancel stream subscriptions

**File:** `app/lib/services/devices/device_connection.dart:107-113`

`disconnect()` calls `transport.disconnect()` but does not cancel `_internalStateSubscription` or `_externalStateSubscription`. These remain live after disconnect and can fire stale callbacks. They are only cancelled on the next `connect()` call.

**Fix:** Cancel both subscriptions in `disconnect()`.

---

### 12. `ManualRecordingExtractor` destroys decoder between segments

**File:** `app/lib/services/manual_recording_extractor.dart:293-296, 357-359`

In `_runVadPass`, a new `SimpleOpusDecoder` is created per segment and destroyed in the `finally` block. Since each segment is a continuation of the same audio stream, the decoder's internal state is lost at segment boundaries, producing slightly different PCM for the first few frames of each segment.

**Fix:** Create one decoder at the start of the outer loop and destroy it at the end.

---

### 13. `_handleDeviceConnected` is fire-and-forget via debouncer

**File:** `app/lib/providers/device_provider.dart:537, 512-518`

`_connectDebouncer.run()` invokes `_handleDeviceConnected` which is `async`. The `Debouncer.run()` takes a `VoidCallback`, so the returned Future is fire-and-forget. If `_handleDeviceConnected` throws, the exception is swallowed, leaving the provider in a partially-connected state.

**Fix:** Wrap the body in try-catch that logs errors and resets state (e.g., `isConnecting = false`).

---

### 14. `k_uptime_get_32()` wraps after ~49 days

**File:** `omi/firmware/omi/src/lib/core/transport.c:861`

`write_timestamp_to_storage` uses `k_uptime_get_32()` which returns a 32-bit uptime in milliseconds. This wraps around after ~49.7 days. Stored uptime is used for timestamp anchoring — after wraparound, delta calculations produce incorrect timestamps.

**Fix:** Use `k_uptime_get()` (64-bit) or document the 49-day limitation.

---

### 15. `storageValue.length / 4` uses floating-point division

**File:** `app/lib/services/devices/omi_connection.dart:126`

`storageValue.length / 4` produces a `double`. If `storageValue.length` is not a multiple of 4 (malformed BLE data), the loop iterates into a partial 4-byte group and `storageValue[baseIndex + 3]` throws `RangeError`.

**Fix:** Use integer division: `storageValue.length ~/ 4`.

---

### 16. `ConnectivityService.dispose()` leaves `_isInitialized = true`

**File:** `app/lib/services/connectivity_service.dart:56-59`

After `dispose()`, `_isInitialized` remains `true` so `init()` is a no-op. But `_connectionChangeController` has been closed, so any future `add()` throws `StateError`. The singleton pattern means the same instance persists.

**Fix:** Reset `_isInitialized = false` in `dispose()`.

---

## MINOR

### 17. `_completeCancelIfPending` can double-complete Completer

**File:** `app/lib/services/wals/sdcard_wal_sync.dart:668-671`

`_cancelCompleter?.complete()` is called without checking `isCompleted`. If `cancelSync()` already completed it with an error (line 102), this throws `StateError`.

**Fix:** Add `if (c != null && !c.isCompleted) c.complete()`.

---

### 18. `connectionStateStream` returns a single-value stream

**File:** `app/lib/services/devices.dart:193-195`

`Stream.value(connectionState)` emits the current state once and completes. Subscribers expecting ongoing state change notifications will miss all updates.

**Fix:** Back with a `StreamController<DeviceConnectionState>.broadcast()`.

---

### 19. Old transport not disposed on reconnect

**File:** `app/lib/services/devices.dart:171-176`

When `_performConnect` disconnects the old connection, it never calls `dispose()` on the old transport, leaking `_bleConnectionSubscription` and `_connectionStateController`.

**Fix:** Add `await existingConnection.transport.dispose()` after disconnect.

---

### 20. `stop()` does not await stream cancellation

**File:** `app/lib/services/wals/sdcard_wal_sync.dart:123`

`_storageStream?.cancel()` returns a `Future` but is not awaited. The stream listener may fire after `stop()` returns.

**Fix:** `await _storageStream?.cancel()`.

---

### 21. Double-close of `RandomAccessFile` in error path

**File:** `app/lib/services/offline_audio_processor.dart:461-469`

In the `catch` block, `currentRaf?.close()` is called, then the `finally` block also calls `currentRaf?.close()`.

**Fix:** Remove the close in the `catch` block since `finally` handles it.

---

### 22. WAV duration formula applied to M4A files

**File:** `app/lib/services/recordings_manager.dart:77-83`

When no `.meta` sidecar exists, duration is computed as `pcmBytes / 32000.0 * 1000` — a WAV assumption. For `.m4a` files this produces a wildly incorrect duration.

**Fix:** Return 0 or unknown for `.m4a` files without metadata.

---

### 23. `_noiseFloorInitFrames` never resets between recordings

**File:** `app/lib/services/offline_audio_processor.dart:36`

The fast-convergence initialization (50 frames) only runs for the very first segment processed. After a silence-based split, new recordings start with a slow-adapting noise floor. If the noise environment changed, the threshold may be stale.

**Fix:** Reset `_noiseFloorInitFrames = 50` after a silence split.

---

### 24. `showDialog` callbacks use outer `context` instead of dialog's `BuildContext`

**File:** `app/lib/pages/recordings/recordings_page.dart:422-432`

Dialog builders use `Navigator.of(context).pop()` with the page's context instead of the dialog's builder context `c`. Can pop the wrong route or crash if the widget was deactivated.

**Fix:** Use the builder context `c` for `Navigator.of()` inside dialog builders.

---

### 25. `RefreshIndicator.onRefresh` resolves instantly

**File:** `app/lib/pages/recordings/recordings_page.dart:1040`

`_startPipeline()` returns `void` and the sync runs via `unawaited()`. The refresh indicator dismisses immediately with no feedback.

**Fix:** Return a meaningful `Future` from `_startPipeline` or show a snackbar when sync is already in progress.

---

### 26. Unreachable retry code in firmware `push_to_gatt`

**File:** `omi/firmware/omi/src/lib/core/transport.c:764-776`

The second `if (err == -EAGAIN || err == -ENOMEM)` block is dead code because the first `if (err)` already handles all nonzero error values with `continue`.

**Fix:** Check EAGAIN/ENOMEM first, then treat other errors as fatal.

---

### 27. `processDay` sorts segments by string comparison, not numeric

**File:** `app/lib/services/recordings_manager.dart:221`

Filenames like `100_10.bin` sort before `100_2.bin` in string order. Segments within a session could be processed out of order.

**Fix:** Use numeric parsing for the sort comparator, matching the approach in `processAll`.

---

### 28. `ServiceManager.deinit()` is `async void`

**File:** `app/lib/services/services.dart:76`

Declared as `void` but uses `await`. Exceptions from `_wal.stop()` are silently lost and callers cannot wait for cleanup.

**Fix:** Change to `Future<void> deinit() async`.

---

### 29. Stream subscriptions in recording player page never cancelled

**File:** `app/lib/pages/recordings/recording_player_page.dart:46-58`

Three `.listen()` calls on `_player` streams create subscriptions that are never stored or cancelled in `dispose()`. Relies on `_player.dispose()` to kill the streams.

**Fix:** Store subscriptions and cancel in `dispose()`.

---

### 30. `storageFullPercentage` never reset on disconnect

**File:** `app/lib/providers/device_provider.dart:444-466`

When the device disconnects, `storageFullPercentage` retains its stale value. The UI continues showing a storage warning for a disconnected device.

**Fix:** Add `storageFullPercentage = -1` in `onDeviceDisconnected()`.
