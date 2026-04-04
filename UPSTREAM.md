# Upstream Integrations

Tracks features, fixes, and commits reviewed from `BasedHardware/omi` and ported into `omi-offline`.

## Integrated Changes

### 1. BLE Connection Pipeline & Stability Refactor
**Source:** [PR #6085](https://github.com/BasedHardware/omi/pull/6085) ("feat: native-owned BLE connection pipeline") — [Commit `7645da3`](https://github.com/BasedHardware/omi/commit/7645da34a3f6f56cc8cec594187cf41a9e8745e0)

**Integrated:**
- **Native-Owned Service Discovery:** Moved service discovery from Dart into native Android (`OmiBleManager.kt`) and iOS (`OmiBleManager.swift`) layers, triggering immediately on connection.
- **On-Demand Bonding (`requestBond`):** Replaced forced bonding with an explicit `requestBond` method across Pigeon interfaces and native layers; bonding only initiates when required.
- **iOS Connection Keep-Alive:** RSSI polling timer (1s intervals) prevents the OS from dropping idle BLE connections due to supervision timeouts.
- **Android Retry Resilience:** Expanded `RETRYABLE_STATUS_CODES` (adding `22` and `147`) for aggressive auto-reconnect on transient GATT errors.

**Excluded:** None.

---

### 2. Firmware SD Card & BLE Sync Speed Optimizations
**Source:** [TuEmb's `sd_card_improvement` branch (23 commits)](https://github.com/TuEmb/omi/tree/TuEmb/sd_card_improvement)

**Integrated:**
- **LittleFS Migration:** Transitioned SD card from FAT32 to multi-file LittleFS (local partial implementation served as foundation).
- **Priority Message Queue (`sd_prio_msgq`):** High-priority queue for API requests (read, list, delete, flush) bypasses the audio write queue, improving BLE sync responsiveness.
- **Queue & Batch Expansion:** `SD_REQ_QUEUE_MSGS` → 100, `WRITE_BATCH_COUNT` → 200 to absorb larger audio bursts without dropping frames.
- **RAM Optimization:** `AUDIO_BUFFER_SAMPLES` reduced from 16000 to 12800 in `config.h`, freeing ~6.4 KB to accommodate the larger queues.
- **File Continuation Tuning:** `FILE_CONTINUE_THRESHOLD_SEC` reduced from 30 min to 2 min; dropped the blind `TMP_` continuation fallback.

**Excluded:**
- **Wi-Fi Removal:** Already removed locally; no action needed.
- **Deferred TMP Renaming & Red LED:** Local immediate `TMP_` renaming on `syncDeviceTime` is cleaner and avoids lost audio at boot.

---

### 3. App-Side Sync Rewrite (LittleFS Protocol)
**Source:** [PR #5905](https://github.com/BasedHardware/omi/pull/5905/commits) — Commits [`1c25b1ca`](https://github.com/BasedHardware/omi/commit/1c25b1caebab76d801504a82076a64ed0517495b), [`b4ca794a`](https://github.com/BasedHardware/omi/commit/b4ca794a31520bbbdd4f1d8d58bd41dbbd109c47)

**Integrated:**
- **`syncDeviceTime()` Implementation:** Extracted `performSyncDeviceTime()` and its UUIDs (`timeSyncServiceUuid`, `timeSyncWriteCharacteristicUuid`) into `device_connection.dart` and `omi_connection.dart`, so the app pushes UTC epoch on connection to anchor firmware timestamps.
- **LittleFS Commands:** Validated that `sdcard_wal_sync.dart` already used the new firmware commands (`listFiles` 0x10, `readFile` 0x11, `deleteFile` 0x12) and expects the 4-byte timestamp prefix in data packets.

**Excluded:**
- **Legacy Wi-Fi Sync Artifacts:** Already expunged locally; cleaner local state preserved.
- **FlutterBluePlus Logic:** `omi-offline` uses native Pigeon bridges (`NativeBleTransport`) in place of the standard Flutter plugin calls.

---

### 4. Auto Offline Sync on Device Connect — Reliability Fixes
**Source:** [PR #5916](https://github.com/BasedHardware/omi/pull/5916)

**Integrated:**
- **Partial Transfer Flush Guard (`sdcard_wal_sync.dart`):** `eotReceived` flag ensures `flushBuffer()` is only called when `PACKET_EOT (0x02)` is received. If BLE drops mid-transfer, buffered Opus frames are discarded instead of flushed — preventing corrupted, truncated `.m4a` files.
- **Rapid Reconnect Sync Fix (`device_provider.dart`):** `_doBackgroundSync()` now awaits `cancelFuture` when `isSyncing` and cancellation is in progress, fixing a window where rapid reconnect left the device permanently unsynced because the new sync returned while the old one was still winding down.

**Excluded:**
- **Firmware Version Gating (≥ 3.0.17) & `StorageSyncImpl` Architecture Split:** Not ported — single firmware version, no legacy fallback needed; `SDCardWalSyncImpl` is sufficient.
- **Upload Progress Callbacks:** Not applicable — `omi-offline` uses HeyPocket presigned-URL streaming uploads, not the upstream `/v1/sync-local-files` pipeline.
- **`auto_sync_page.dart` & Localization Strings:** Not ported — no Omi backend in use.

---

### 5. Android BLE Connect Race Condition Fix (status=5)
**Source:** [PR #6067](https://github.com/BasedHardware/omi/pull/6067)

**Integrated:**
- **`connectingAddresses` Race Guard (`OmiBleManager.kt`):** `ConcurrentHashMap`-backed set tracks in-flight `connectGatt` calls. Three callers (Dart `ensureConnection`, `OmiBleForegroundService`, `BleCompanionService`) can race to call `connectPeripheral` within milliseconds — each was closing the previous GATT connection and corrupting the encryption handshake, producing `status=5` (GATT_INSUFFICIENT_AUTHENTICATION). Later callers now return immediately. Set cleared on both `STATE_CONNECTED` and `STATE_DISCONNECTED`.
- **`cancelPendingReconnect()` in `connectPeripheral`:** Cancels any delayed reconnect runnable before a fresh connection attempt begins.
- **Status=5 Bond Removal + Retry:** Dedicated `STATE_DISCONNECTED` path for `status == 5` when bonded: removes stale bond via `removeBond()` (reflection on hidden Android API) and schedules a fresh `connectGatt` after `RECONNECT_DELAY_MS`. Previously status=5 was not in `RETRYABLE_STATUS_CODES`, permanently abandoning the connection.
- **RSSI Keepalive Deferred:** Moved `startRssiKeepAlive()` from `STATE_CONNECTED` to after `requestConnectionPriority()` in `onServicesDiscovered`, reducing BLE traffic during critical service discovery and MTU negotiation.
- **Caller Tagging:** `caller: String` parameter added to `connectPeripheral`; all connect-attempt log lines now identify their origin.

**Excluded:** Caller tags in `BleCompanionService.kt` and `MainActivity.kt` were already present locally.

---

### 6. Android BLE Cold-Start Crash & Reconnect Race Fixes
**Source:** [PR #6086](https://github.com/BasedHardware/omi/pull/6086) ("BLE Reliability Fixes")

**Integrated:**
- **`isInitialized` guard (`BleCompanionService.kt`):** Added `OmiBleManager.isInitialized` check in `handleDeviceAppeared` and `onCreate` before accessing `OmiBleManager.instance`. Android can start `BleCompanionService` as a system service before `MainActivity` initializes `OmiBleManager`, causing `IllegalStateException`.
- **`isInitialized` companion property (`OmiBleManager.kt`):** `val isInitialized: Boolean get() = _instance != null` to support the guard without catching exceptions.
- **Reconnect guard in `connectPeripheral` (`OmiBleManager.kt`):** Skips if `pendingReconnectRunnable != null`, preventing Dart from fighting the OS-managed `autoConnect=true` reconnect in progress.
- **`ensureConnection` refactor (`devices.dart`):** Returns `null` without disposing the transport if a `_connection` already exists for the same device ID (even if disconnected), preventing `force=true` calls from killing a native reconnect.
- **`_bleDisconnectDevice` simplification (`device_provider.dart`):** Calls `DeviceService.disconnectDevice()` directly instead of routing through `ensureConnection()`, which would leave `_connection` pointing to a stale object after DFU.
- **Characteristic existence guards (`native_ble_transport.dart`):** `_hasCharacteristic()` helper checks discovered `_services`; subscribe silently skips, read returns `[]`, write throws immediately with a clear message for absent optional characteristics.

**Excluded:** None.

---

### 7. BLE Single-Owner Connection Model (Architecture Refactor)
**Source:** [PR #6200](https://github.com/BasedHardware/omi/pull/6200) ("REFACTOR(ANDROID): BLE SINGLE-OWNER CONNECTION MODEL")

**Integrated:**
- **1:1 Structural Alignment:** Full code replacement of core BLE management files from the `pr-6200` branch, resolving all prior integration mismatches.
- **Intent-Based Management (`manageDevice`):** Replaced the multi-step `connect → discover → MTU` sequence with a single "management" intent; the native layer owns the entire pipeline and signals `onDeviceReady` only when fully stable.
- **Android "Connection Owner" (`OmiBleForegroundService.kt`):** `ManagedDevice` state tracking, auto-retry with stability timers, specialized Bluetooth state handling.
- **Android "Pure GATT Wrapper" (`OmiBleManager.kt`):** Serialized GATT command queue (`enqueueCommand`/`completeCommand`) prevents concurrent GATT requests.
- **API 34+ Reconnect Fix:** `getRemoteLeDevice(addr, ADDRESS_TYPE_RANDOM)` for reliable reconnect after Bluetooth toggles on modern Android.
- **iOS Ready Signal (`OmiBleManager.swift`):** `onDeviceReady` fires only after full service and characteristic discovery.
- **Dart Transport (`NativeBleTransport.dart`):** Long-lived transport model; auto-resubscribes to characteristic streams on each `onDeviceReady` signal, ensuring zero data loss across native-initiated reconnections.
- **Connection Logic (`DeviceService.dart`):** Simplified to match the intent-based model.
- **Lifecycle Guard (`MainActivity.kt`):** `OmiBleManager.isFlutterAlive` guard synchronizes native background tasks with the UI lifecycle.
- **Connecting State:** `DeviceConnectionState.connecting` handled in `DeviceProvider` for accurate UI feedback.
- **Standardized Unpairing (`device_settings.dart`):** `forgetDevice()` + native `unmanageDevice()`.

**Excluded:** None.

---

### Minor Individual Commits

Smaller fixes integrated independently; superseded by the PR #6200 full-file replacement.

| Commit | File | Description | Status |
|--------|------|-------------|--------|
| [`bae9dbea3`](https://github.com/BasedHardware/omi/commit/bae9dbea3) | `OmiBleManager.kt` | BLE API compat for Android < 13: `SDK_INT >= 33` branches with deprecated `setValue` fallbacks for `writeCharacteristic` / `writeDescriptor` | Already present |
| [`b0560a0ec`](https://github.com/BasedHardware/omi/commit/b0560a0ec) | `OmiBleForegroundService.kt` | Guard `OmiBleManager` init in `onCreate`: `if (!OmiBleManager.isInitialized) initialize(application)` prevents `IllegalStateException` on re-delivered pending intents after process death | Integrated |
| [`20f323a36`](https://github.com/BasedHardware/omi/commit/20f323a36) | `OmiBleForegroundService.kt` | Remove DFU service MTU skip in `requestMtuThenNotifyReady`: removed `hasDfuService` guard and unused `DFU_SERVICE_UUID` constant so MTU negotiation proceeds unconditionally | Integrated |
| [`a43cd2be0`](https://github.com/BasedHardware/omi/commit/a43cd2be0) | `OmiBleManager.kt` | Log `writeCharacteristic` errors on API 33+ path; extract `writeDescriptorCompat()` helper that calls `completeCommand()` on failure, preventing permanent BLE queue stalls | Integrated |
