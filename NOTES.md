# Notes

Running log of investigated bugs, deferred decisions, and findings that don't fit TODO or README.

---

## Firmware: LED Behavior

### Boot Sequence
1. **LEDs breathing white** — `boot_led_sequence()` starts `led_start_breathing()` right after `led_start()` (which just asserts PWM ready, doesn't drive any LED itself)
2. **Haptic buzz** (100ms) — fires during breathing while settings + SD init run
3. **Breathing continues** — `boot_warming_sequence()` spin-waits for the SD worker to finish mount + `lfs_fs_gc` + file open (< 5 s with little data, up to ~50 s with 200 MB)
4. **Mic starts** — `mic_start()` runs once SD is ready
5. **Breathing stops, solid white → fade to off** — `boot_ready_fade()` holds solid white (R+G+B at `dim_ratio`) for 1 s, then fades all three channels down to 0 over ~1000 ms (100 × 10 ms steps). Main loop's `set_led_state()` (500 ms cadence) then takes over.

### LED State Machine (`set_led_state()`, runs every 500ms)

Priority order (highest first):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off (`is_off`) | Off |
| 2 | Charging starts (`is_charging && !is_led_enabled`) | Force `is_led_enabled = true`, continue |
| 3 | Double-tap marker (`marker_flash_count > 0`) | White (R+G+B) — overrides stealth |
| 4 | Stealth mode (`!is_led_enabled`) | Off |
| 5 | Muted | Solid Red |
| 6 | Low battery (< 10%) | Solid Purple (R+B) |
| 7 | BLE connected | Solid Blue (wins over recording state) |
| 8 | Manual recording active (AAD threshold == 65535) | Solid Yellow (R+G) |
| 9 | AAD auto-recording (`aad_is_recording()`) | Solid Yellow (R+G) |
| 10 | Idle / disconnected / standby | Off |

### Charging Override
Applied on top of the base state above:
- **Fully charged (≥ 98%):** Solid Green
- **Charging:** Blinks every 500ms between Green and the current base color (e.g. Green ↔ Blue if connected, Green ↔ Yellow if recording)
- Plugging in charger automatically disables Stealth Mode (`is_led_enabled = true`)

### Button Controls
| Action | Effect | Haptic |
|--------|--------|--------|
| Single tap | No action | None |
| Double tap | White flash ~1s (marker recorded via `write_marker_to_storage()`) — ignored if muted. In manual AAD mode: toggles manual recording start/stop instead. | None |
| Double tap + hold (1s on second press) | Toggle Mute — LED goes Red when muted, mic paused. Suppressed in manual AAD mode. | None |
| Triple tap | Toggle Stealth Mode (`is_led_enabled`) | None |
| Triple tap + hold (3s on third press) | Power off (`turnoff_all()`) | 100ms |

### Hardware Error LEDs
**Removed in production.** All `error_*()` functions in `feedback.c` log to UART/RTT only. No visual LED feedback on errors.

### Stealth Mode Notes
- Triple tap toggles `is_led_enabled`
- Stealth suppresses all base state LEDs (priority 4)
- Stealth does **not** suppress double-tap white flash (priority 3 fires first)
- Charging always overrides stealth back on

---

## Firmware: Power / Battery Optimizations

### Button: Interrupt-Driven (implemented)

**Files:** `src/lib/core/button.c`, `src/main.c`, `src/lib/core/transport.c`

Previously `check_button_level` unconditionally rescheduled itself every 40ms (25 Hz) via a Zephyr work queue, preventing the CPU from sleeping between presses.

**Fix:** The GPIO interrupt (`button_gpio_callback`) schedules the work item (`K_NO_WAIT`) only when a press arrives while `fsm_state == STATE_IDLE`. The work item reschedules itself at 40ms while an interaction is in progress and stops when the state machine returns to `STATE_IDLE`. `activate_button_work()` still exists but is no longer called from `main.c` or `transport.c`.

### Battery ADC Poll Interval (implemented)

**File:** `src/lib/core/transport.c`

| State | Before | After |
|-------|--------|-------|
| Connected | 10 s | 60 s |
| Disconnected | 30 s | 5 min |

Battery voltage on the 150 mAh LiPo changes on the order of millivolts per minute. The previous intervals were excessively frequent and prevented the ADC/peripheral from reaching low-power states.

### Deferred Optimizations

- **BT TX power** (`CONFIG_BT_CTLR_TX_PWR_ANTENNA=8` → 0 or 4 dBm): saves power during every radio tx. Requires testing with phone in pocket/bag to confirm no audio dropouts.
- **BLE connection interval** (7.5–15ms → 30ms): large power savings from longer radio sleep. Requires empirical validation that Opus streaming (50 fps, 80 B/frame, MTU 498) doesn't overflow buffers or cause audio gaps at the longer interval. The `update_conn_params()` in `transport.c` hardcodes the interval at runtime and would need updating alongside the Kconfig values.
- **Disable logging in production**: `CONFIG_SERIAL=n`, `CONFIG_LOG=n` in a `release.conf` overlay. RTT logging stays on for development builds. The log processing thread and UART clock domain add baseline power draw.

---

## Firmware: SD Write Queue Configuration

**Location:** `omi/firmware/omi/src/sd_card.c`

**Current values:**
```c
#define SD_REQ_QUEUE_MSGS  100   // main audio write queue depth
#define SD_PRIO_QUEUE_MSGS  10   // priority queue (control requests)
#define WRITE_BATCH_COUNT  100   // frames accumulated per write batch
#define SD_FSYNC_INTERVAL_MS (60 * 1000)  // fsync every 60s
```

Each slot in `sd_msgq` holds one `sd_req_t`. The queue is backed by `K_MSGQ_DEFINE` (static allocation). The worker accumulates up to `WRITE_BATCH_COUNT` (100) frames into a batch buffer before flushing to LittleFS.

`SD_FSYNC_INTERVAL_MS` (60 s) controls durability: data is in the LittleFS write cache until fsync fires. A hard power-off within this window risks losing up to 60 s of audio, but LittleFS's copy-on-write metadata ensures the filesystem itself stays consistent.

The early-flush path (`sd_boot_ready` gate + high-watermark logic) prevents the queue from filling during the boot `lfs_fs_gc` pre-warm and during bursts of rapid audio ingestion.

---

## Debug Tools Audit

This section reviews the functionality of the Debug Tools present in `app/lib/pages/settings/sync_page.dart` to verify if they operate according to their given descriptions.

### 1. Sync Omi Segments
**Description:** "Download any pending raw segments from your Omi."
**Implementation:**
- Checks if processing is currently running (`RecordingsManager.isProcessingAny`), blocking the sync if true.
- Calls `ServiceManager.instance().wal.getSyncs().syncAll()`.
- Updates UI based on the response.
**Conclusion:** Matches description. `syncAll` correctly checks for pending segments and syncs them.

### 2. Force Sync Omi
**Description:** "Seals the current recording on the device and syncs everything, including the current session."
**Implementation:**
- Shows a confirmation dialog warning that it will close the current recording segment.
- Calls `ServiceManager.instance().wal.getSyncs().rotateAndSync()`.
- `rotateAndSync` connects to the device, executes a file rotation (`connection.rotateFile()`), updates the missing wals bypassing the minimum buffer threshold (`ignoreThreshold: true`), and then runs `syncAll()`.
**Conclusion:** Matches description. The `rotateFile` command forces the firmware to close the current file and start a new one, allowing immediate download.

### 3. Force Process Omi
**Description:** "Process raw segments immediately, including the newest (may be incomplete)."
**Implementation:**
- Checks if processing is already running.
- Calls `RecordingsManager.forceProcessAll()`.
- `forceProcessAll` retrieves all batches and filters for `rawSegments.isNotEmpty`. Unlike regular processing which skips the newest segment per session to prevent conflict with ongoing writing, `forceProcessAll` intentionally includes all segments.
**Conclusion:** Matches description. It correctly bypasses the `excludeNewestSegmentPerSession` filter.

### 4. Delete Omi Segments
**Description:** "Permanently deletes raw segments from your Omi. The device immediately starts a new recording file."
**Implementation:**
- Shows a confirmation dialog.
- Cancels any active sync.
- Calls `ServiceManager.instance().wal.getSyncs().deleteAllPendingWals()`.
- Resets shared preferences related to sync and processing progress.
- `deleteAllPendingWals` in `SDCardWalSyncImpl` sends the `CMD_CLEAR_STORAGE` (0x14) to the device. If that fails, it falls back to deleting each file individually.
**Conclusion:** Matches description.

### 5. Delete Phone Segments
**Description:** "Permanently deletes raw segment files stored on this phone."
**Implementation:**
- Blocked if processing is active.
- Shows a confirmation dialog.
- Deletes the `raw_segments` directory (`${directory.path}/raw_segments`) recursively.
- Resets shared preferences related to sync progress.
**Conclusion:** Matches description. The `raw_segments` folder contains all the downloaded `.bin` files and markers.

### 6. Delete Phone Conversations
**Description:** "Permanently deletes finalized recordings and conversations." (Confirmation dialog also warns that any open conversation in progress is included.)
**Implementation:**
- Blocked if processing is active.
- Shows a confirmation dialog.
- Deletes the `recordings` directory (`${directory.path}/recordings`) recursively.
- Deletes the `processing_temp` directory (`${directory.path}/processing_temp`) recursively.
- Resets shared preferences related to sync progress.
- Clears the HeyPocket upload history to allow re-upload if files are re-processed.
**Conclusion:** Matches description. `recordings` stores the `.m4a` files and EDL data, while `processing_temp` holds files currently being worked on.

### 7. Delete Problematic EDLs
**Description:** "Deletes marker EDL files with no matching recording (pending or orphaned)."
**Implementation:**
- Shows a confirmation dialog.
- Calls `RecordingsManager().getMarkerConversations()` and filters for entries where `isPending` is true.
- Deletes the `.edl` file for each problematic entry.
- Notifies listeners via `RecordingsManager.notifyRecordingsChanged()`.
**Conclusion:** Matches description. Cleans up orphaned marker EDL files that have no corresponding finalized recording.

---

## SD Card Power-Gating and Locking Architecture

### App-Side (Client Locking & Triggers)
The Flutter app manages a `_storageMutex` to ensure that no two multi-step storage operations (e.g., `syncAll`, `deleteWal`, `rotateAndSync`) overlap. This prevents deadlocks and ensures the SD card stays awake for the full duration of a task.

1. **`app/lib/services/devices/omi_connection.dart`**:
   - Owns the `_storageMutex`.
   - `acquireStorageLock()`: Includes an active wake probe via `_waitForStorageReady()`, which calls `performGetStorageFileStats()` to wake the SD card if asleep.
   - `releaseStorageLock()`: Implements an idle release. It does not force an explicit BLE sleep command, allowing the firmware's idle timeout to safely handle powering down after operations conclude.

2. **`app/lib/services/wals/sdcard_wal_sync.dart`**:
   - Enforces the `_Locked` pattern.
   - Public methods (e.g., `syncAll`, `getMissingWals`) acquire the mutex and pass the locked connection to their private `_Locked` equivalents.
   - Prevents nested locks and re-entrant calls, ensuring atomic and uninterrupted workflows.

### Firmware-Side (Device Power Management)
The firmware leverages priority queues to intelligently gate SD card power without needing explicit wake/sleep commands from the app.

1. **`omi/firmware/omi/src/sd_card.c`**:
   - Runs the main SD worker thread.
   - **Per-operation power gating (`sd_io_low_power` atomic)**: The SPI3 bus (and SD device) are suspended via `sd_set_io_low_power(true)` immediately after each operation completes, and resumed via `sd_set_io_low_power(false)` before the next one starts. There is no fixed sleep timer — the bus is off whenever no operation is in flight. Write data manages its own gate inline (`spi_woken` flag within `process_write_data_req`); all other request types are wrapped at the worker loop level.
   - **OTA override**: `sd_set_ota_active(true)` keeps the bus awake for the duration of a firmware update.

2. **`omi/firmware/omi/src/lib/core/storage.c`**:
   - Acts as the BLE GATT translation layer.
   - When the app reads the `0x30295782...` characteristic (via `performGetStorageFileStats()`), it calls `get_audio_file_stats()`. This posts a `REQ_GET_FILE_STATS` to the `sd_prio_msgq`, signaling `sd_card.c` to wake up.

3. **`omi/firmware/omi/src/lib/core/sd_card.h`**:
   - Defines the API for interacting with the SD worker, including the `sd_req_type_t` enumeration (e.g., `REQ_GET_FILE_STATS`).
