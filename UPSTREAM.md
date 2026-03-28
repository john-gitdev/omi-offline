# Upstream Integrations

This document tracks features, optimizations, and bug fixes that have been reviewed and integrated from the upstream `BasedHardware/omi` repository and its forks into `omi-offline`.

## Unmerged PRs

### [PR #6085: feat: native-owned BLE connection pipeline](https://github.com/BasedHardware/omi/pull/6085)
- **Status:** Already integrated — all changes present in `omi-offline`
- **Merged upstream:** March 27, 2026 (author: mdmohsin7)
- **Assessment:** Every change in this PR was already present in `omi-offline` prior to review. The work had been sourced directly from commit `7645da3` (see Integrated Feature #1 below). No action required.
- **Files changed upstream (11):**
  - `app/android/.../BleHostApiImpl.kt` — `discoverServices` → `requestBond`
  - `app/android/.../OmiBleManager.kt` — always discover on connect (no bond-gating), `requestBond()` impl, GATT codes 22+147 added to retry set
  - `app/android/.../PigeonCommunicator.g.kt` — `discoverServices` → `requestBond`
  - `app/ios/Runner/BleHostApiImpl.swift` — `discoverServices` → `requestBond` (iOS auto-bonds at OS level, returns `true`)
  - `app/ios/Runner/OmiBleManager.swift` — removed Dart-driven `discoverServices`, added RSSI keep-alive timer
  - `app/ios/Runner/PigeonCommunicator.g.swift` — `discoverServices` → `requestBond`
  - `app/lib/pigeon_interfaces.dart` — `discoverServices` → `@async requestBond`
  - `app/lib/gen/pigeon_communicator.g.dart` — `discoverServices` → `requestBond` returning `bool`
  - `app/lib/services/devices/transports/device_transport.dart` — abstract `requestBond()` with default no-op
  - `app/lib/services/devices/transports/native_ble_transport.dart` — `requestBond()` impl, removed Dart-side `discoverServices` call
  - `app/lib/services/devices/limitless_connection.dart` — calls `requestBond()` before subscribing to encrypted characteristics (N/A — file does not exist in `omi-offline`)

---

### [PR #5994: Fix sync endpoint silent failure causing permanent audio loss](https://github.com/BasedHardware/omi/pull/5994)
- **Status:** Unmerged
- **Reason:** This PR addresses silent failures in the network/API synchronization layer and audio data preservation. It does not contain any Bluetooth Low Energy (BLE) hardware connection reliability fixes between the phone and the Omi device, which is what we are looking for.

---

## Integrated Features & Fixes

### 1. BLE Connection Pipeline & Stability Refactor
**Source:** [PR #6085](https://github.com/BasedHardware/omi/pull/6085) ("feat: native-owned BLE connection pipeline", mdmohsin7) — [Commit `7645da3`](https://github.com/BasedHardware/omi/commit/7645da34a3f6f56cc8cec594187cf41a9e8745e0)

**Integrated:**
*   **Native-Owned Service Discovery:** Moved service discovery logic from Dart into the native Android (`OmiBleManager.kt`) and iOS (`OmiBleManager.swift`) layers, triggering immediately upon connection.
*   **On-Demand Bonding (`requestBond`):** Replaced forced bonding with an explicit `requestBond` method across the Pigeon interfaces and native layers, initiating bonding only when required (e.g., for Limitless connections).
*   **iOS Connection Keep-Alive:** Implemented an RSSI polling timer (1-second intervals) on iOS to act as a heartbeat, preventing the OS from dropping idle BLE connections due to supervision timeouts.
*   **Android Retry Resilience:** Expanded `RETRYABLE_STATUS_CODES` (adding `22` and `147`) to make the Android background service aggressively auto-reconnect on transient GATT errors.

**Excluded:**
*   None. The entire architectural improvement was ported to align `omi-offline` with upstream BLE stability.

---

### 2. Firmware SD Card & BLE Sync Speed Optimizations
**Source:** [TuEmb's `sd_card_improvement` branch (23 commits)](https://github.com/TuEmb/omi/tree/TuEmb/sd_card_improvement)

**Integrated:**
*   **LittleFS Migration:** Transitioned the SD card file system from `FAT32` to a multi-file `LittleFS` architecture (this was already partially implemented locally and served as the foundation).
*   **Priority Message Queue (`sd_prio_msgq`):** Added a secondary, high-priority queue for API requests (read, list, delete, flush) to bypass the audio writing queue (`sd_msgq`), massively improving BLE sync responsiveness.
*   **Queue & Batch Expansion:** Increased `SD_REQ_QUEUE_MSGS` to 100 and `WRITE_BATCH_COUNT` to 200, allowing the firmware to absorb larger audio bursts without dropping frames.
*   **RAM Optimization:** Ported commit `e99030c2d` to reduce `AUDIO_BUFFER_SAMPLES` from `16000` (1s) to `12800` (0.8s) in `config.h`, freeing up ~6.4KB of RAM to safely accommodate the larger SD card queues.
*   **File Continuation Tuning:** Reduced the window for appending to an existing file on boot from 30 minutes to 2 minutes (`FILE_CONTINUE_THRESHOLD_SEC`), and dropped the blind `TMP_` continuation fallback.

**Excluded:**
*   **Wi-Fi Removal:** TuEmb's branch completely deleted `wifi.c` and `wifi.h` from the firmware. These files had *already* been removed from the `omi-offline` local repository in previous cleanups, so no further action was needed.
*   **Deferred Renaming:** Did not port TuEmb's deferred TMP renaming logic or Red LED blinking for missing RTC, because the local implementation using immediate `TMP_` renaming upon receiving a `syncDeviceTime` packet was cleaner and didn't result in lost audio at the beginning of a boot sequence.

---

### 3. Auto Offline Sync on Device Connect — Reliability Fixes
**Source:** [PR #5916](https://github.com/BasedHardware/omi/pull/5916)

**Integrated:**
*   **Partial Transfer Flush Guard (`sdcard_wal_sync.dart`):** Added an `eotReceived` flag to `_readStorageBytesToFile`. The flag is set only when a `PACKET_EOT (0x02)` is received from the firmware. The `onError` and `onDone` BLE stream handlers now check this flag before calling `flushBuffer()`. If the stream closes without a proper EOT (e.g. BLE drops mid-transfer), buffered Opus frames are discarded instead of flushed — preventing corrupted, truncated `.m4a` files from being written to disk.
*   **Rapid Reconnect Sync Fix (`device_provider.dart`):** Changed the early-return guard in `_doBackgroundSync()` from a hard bail on `walSync.isSyncing` to a conditional await. If `isSyncing` is true but `cancelFuture` is non-null (meaning the disconnect handler already requested cancellation), the method now awaits that future and then proceeds with the sync. This fixes a window where rapid reconnect — disconnect fires `cancelSync()` before reconnect fires `_doBackgroundSync()` — would leave the device perpetually unsynced because the new sync silently returned while the old one was still winding down.

**Excluded:**
*   **Firmware Version Gating (≥ 3.0.17):** The PR gates the new LittleFS sync path on a firmware version check and adds a `deviceSupportsMultiFileSync` SharedPreferences flag. Not ported — the local project runs a single firmware version and does not need a legacy SD card fallback path.
*   **`StorageSyncImpl` Architecture Split:** The PR introduces a separate `StorageSyncImpl` class for LittleFS alongside the existing `SDCardWalSyncImpl` for legacy firmware. Not ported — redundant given the single-firmware constraint above; the existing `SDCardWalSyncImpl` (which already uses LittleFS commands 0x10–0x13) is sufficient.
*   **Upload Progress Callbacks (`UploadProgressCallback`):** The PR enhances `makeMultipartApiCall()` with byte-level progress tracking for the upstream's `/v1/sync-local-files` backend. Not applicable — `omi-offline` uses HeyPocket presigned-URL streaming uploads, a completely separate pipeline.
*   **`auto_sync_page.dart` and Localization Strings:** New three-tier progress UI page and 20 localization keys tied to the cloud upload pipeline. Not ported — the local project does not use the Omi backend.

---

### 4. App-Side Sync Rewrite (LittleFS Protocol)
**Source:** [PR #5905 Commits](https://github.com/BasedHardware/omi/pull/5905/commits)
*   [Commit `1c25b1ca`](https://github.com/BasedHardware/omi/commit/1c25b1caebab76d801504a82076a64ed0517495b)
*   [Commit `b4ca794a`](https://github.com/BasedHardware/omi/commit/b4ca794a31520bbbdd4f1d8d58bd41dbbd109c47)

**Integrated:**
*   **`syncDeviceTime()` Implementation:** Extracted the missing `performSyncDeviceTime()` method and its associated UUIDs (`timeSyncServiceUuid`, `timeSyncWriteCharacteristicUuid`) and added them to `device_connection.dart` and `omi_connection.dart`. This ensures the app pushes its UTC epoch to the device on connection, allowing the new firmware to accurately rename `TMP_` files to proper timestamped files.
*   **LittleFS Commands:** Validated that the local `sdcard_wal_sync.dart` was already fully rewritten to use the new firmware commands (`listFiles` 0x10, `readFile` 0x11, `deleteFile` 0x12) and expects the 4-byte timestamp prefix in data packets.

**Excluded:**
*   **Legacy Wi-Fi Sync Artifacts:** The upstream commits still contained some interfaces and models from the legacy Wi-Fi sync (`WifiSyncSetupResult`, `setupWifiSync`, etc.). These had already been entirely expunged from the local `omi-offline` app architecture, so the cleaner local state was preserved.
*   **FlutterBluePlus Logic:** Upstream still uses standard Flutter plugins in places where `omi-offline` now uses the newly created native `Pigeon` bridges (`NativeBleTransport`).

---

### 5. Android BLE Connect Race Condition Fix (status=5)
**Source:** [PR #6067](https://github.com/BasedHardware/omi/pull/6067)

**Integrated:**
*   **`connectingAddresses` Race Guard (`OmiBleManager.kt`):** Added a `ConcurrentHashMap`-backed set that tracks addresses with an in-flight `connectGatt` call. Three callers (Dart `ensureConnection`, `OmiBleForegroundService` startup, `BleCompanionService.deviceAppeared`) can race to call `connectPeripheral` within milliseconds — each call was closing the previous in-flight GATT connection and corrupting the encryption handshake, producing `status=5` (GATT_INSUFFICIENT_AUTHENTICATION). The 2nd and 3rd callers now check the set and return immediately. The set is cleared in both `STATE_CONNECTED` and `STATE_DISCONNECTED` branches of `onConnectionStateChange`.
*   **`cancelPendingReconnect()` in `connectPeripheral` (`OmiBleManager.kt`):** Added the call at the top of `connectPeripheral` so any delayed reconnect runnable scheduled from a prior disconnect is cancelled before a fresh connection attempt begins. The upstream codebase already had this; the local copy was behind.
*   **Status=5 Bond Removal + Retry (`OmiBleManager.kt`):** Added a dedicated path in `STATE_DISCONNECTED` for `status == 5` when the device is bonded. Removes the stale bond via `removeBond()` (reflection on the hidden Android API) and schedules a fresh non-autoConnect `connectGatt` after `RECONNECT_DELAY_MS`. Previously status=5 was not in `RETRYABLE_STATUS_CODES` so the connection was permanently abandoned.
*   **`removeBond()` Helper (`OmiBleManager.kt`):** Small private method wrapping the reflection call with a try/catch since `removeBond` is a hidden Android API.
*   **RSSI Keepalive Deferred (`OmiBleManager.kt`):** Moved `startRssiKeepAlive()` from `STATE_CONNECTED` to after `requestConnectionPriority()` in `onServicesDiscovered`. Prevents RSSI polling from adding BLE traffic during the critical service discovery and MTU negotiation window.
*   **Caller Tagging (`OmiBleManager.kt`, `OmiBleForegroundService.kt`, `BleHostApiImpl.kt`):** Added a `caller: String` parameter to `connectPeripheral` and propagated it through `OmiBleForegroundService.connectToDevice`. `BleHostApiImpl` now passes `caller = "Dart"`. All connect-attempt log lines now identify their origin.

**Excluded:**
*   Nothing. All substantive changes were applicable. Caller tags in `BleCompanionService.kt` and `MainActivity.kt` were already present in the local codebase prior to this PR.
