# Ideas

## Table of Contents

### ACTIVE
- [1. BLE stability: stuck notifications, partial syncs, Bluetooth wedge [large] [Active]](#1-ble-stability-stuck-notifications-partial-syncs-bluetooth-wedge-large-active)
### PENDING
- [2. Hybrid "Isolated Recording" Architecture (Start/Stop) [large] [Pending]](#2-hybrid-isolated-recording-architecture-startstop-large-pending)
- [3. High-Priority Marker Mode — "New Recording" Button Action [large] [Pending]](#3-high-priority-marker-mode-new-recording-button-action-large-pending)
- [4. Clean session-end marker when entering Manual Mode [medium] [Pending]](#4-clean-session-end-marker-when-entering-manual-mode-medium-pending)
- [5. Split manual recording Start/Stop from the Marker action [medium] [Pending]](#5-split-manual-recording-startstop-from-the-marker-action-medium-pending)
- [6. Device-side toggle for Manual/Auto Mode [medium] [Pending]](#6-device-side-toggle-for-manualauto-mode-medium-pending)
- [7. Device-driven BLE wake (firmware + iOS) [large] [Pending]](#7-device-driven-ble-wake-firmware-ios-large-pending)
### DEFERRED
- [8. iOS code signing & non-jailbroken distribution [medium] [Deferred]](#8-ios-code-signing-non-jailbroken-distribution-medium-deferred)

---


## ACTIVE

### 1. BLE stability: stuck notifications, partial syncs, Bluetooth wedge [large] [Active]

Findings from analysing the device logs of 2026-06-27 and a full code review of
[OmiBleManager.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt) and
[OmiBleForegroundService.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt).

#### 1. Notifications stuck on "Connecting…"

**Problem:** The foreground-service notification shows "Connecting…" and never transitions back to idle. This happens when the Dart engine is frozen by Doze (or killed) while a background sync connect attempt is in progress. The native `setSyncStatus` in [OmiBleForegroundService.kt:954-968](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt) pushes the "Connecting…" text and arms a `CONNECT_SETTLE_MS` (160 s) exact alarm via `SyncAlarmReceiver.scheduleSettle`. If Dart never resolves the connect (success or failure), the notification stays stuck until either:

- The 160 s alarm fires and `settleStaleConnectingToIdle()` reverts it.
- Under deep Doze the alarm can be deferred to the OS's ~9 min throttle window, leaving the notification visibly stuck for minutes.

**Relevant files:**

| File | Lines | What it does |
|------|-------|-------------|
| `OmiBleForegroundService.kt` | 53 | `DEFAULT_NOTIF_TEXT = "Connecting..."` |
| `OmiBleForegroundService.kt` | 54-58 | `CONNECT_SETTLE_MS = 160_000L` — the watchdog timeout |
| `OmiBleForegroundService.kt` | 954-968 | `setSyncStatus` — arms the settle alarm when text starts with "Connecting" |
| `OmiBleForegroundService.kt` | 976-992 | `settleStaleConnectingToIdle` — reverts the notification |
| `SyncAlarmReceiver.kt` | — | Fires the exact alarm and calls `settleStaleConnectingToIdle` |

**Fix ideas:**

1. **Reduce `CONNECT_SETTLE_MS`** to something closer to the Dart connect-settle watchdog (currently 150 s on the Dart side) — e.g. 90–120 s — so the native fallback kicks in sooner.
2. **Use `AlarmManager.setExactAndAllowWhileIdle`** (it already may, but verify) so Doze doesn't batch it into the 9-min window.
3. **Push a native-side `onConnectionStateChange → STATE_DISCONNECTED` notification update** immediately when the GATT callback fires, instead of relying on Dart to update the notification text. This would catch the case where Dart is frozen but native callbacks still fire.

#### 3. Partial sync completions

**Problem:** Background syncs identify multiple WAL files to transfer (e.g. "getMissingWals returned 4 WALs") but abort partway through because the Bluetooth connection drops mid-transfer. The logs show this pattern repeatedly:

```
SDCardWalSync: deleting synced WAL from SD card: index=0 ts=1782589703  ← WAL 1 OK
SDCardWalSync: deleting synced WAL from SD card: index=0 ts=1782590304  ← WAL 2 OK
SDCardWalSync: deleting synced WAL from SD card: index=0 ts=1782590906  ← WAL 3 OK
[NativeBleTransport] C3:94:71:EA:A8:D5: disconnected (error=gatt_status_8 ...)  ← DROP
SDCardWalSync: Connection lost after failure, aborting syncAll  ← ABORT
```

The underlying cause is `gatt_status_8` (`GATT_CONN_TIMEOUT`) — the LE link supervision timer expired, meaning the peripheral stopped sending LL keepalive PDUs (or the radio channel was too degraded for them to be received).

A secondary cause visible in the logs is `Stream closed without EOT` ([OmiBleManager.kt:540](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt)), which fires when `cleanupPeripheral` is called during an active `StorageDownloadSession`. This is the symptom, not the cause — the transfer was interrupted by the connection drop.

**Relevant files:**

| File | Lines | What it does |
|------|-------|-------------|
| `OmiBleManager.kt` | 522-541 | `cleanupPeripheral` — cancels active downloads with "Stream closed without EOT" |
| `OmiBleManager.kt` | 688-786 | `StorageDownloadSession` — the file transfer session |
| `OmiBleManager.kt` | 447-465 | Storage keepalive (0x32 every 15 s) — resets firmware's 30 s idle timer |
| `OmiBleForegroundService.kt` | 536-601 | `handleDisconnection` — cleanup on drop |

**Fix ideas:**

1. **Increase firmware LE supervision timeout.** The repeated `gatt_status_8` suggests the Zephyr LE connection supervision timeout may be too short (possibly 100–400 ms). Increasing it to 4–6 seconds (`CONFIG_BT_PERIPHERAL_PREF_TIMEOUT` or via a connection parameter update request) would tolerate brief RF interference without dropping the link. This is the single highest-impact fix.
2. **Request robust connection parameters from Android.** After connecting, the code calls `gatt.requestConnectionPriority(CONNECTION_PRIORITY_HIGH)` ([OmiBleManager.kt:589](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt)). `CONNECTION_PRIORITY_HIGH` requests a short interval (11.25–15 ms) which is great for throughput but increases sensitivity to RF interference. Consider switching to `CONNECTION_PRIORITY_BALANCED` during the transfer (30 ms interval, longer supervision timeout) — slower throughput but fewer drops.
3. **Resume-from-offset after reconnect.** The `StorageDownloadSession` already supports a `startOffset` parameter. If a transfer is interrupted, persist the last successfully written offset and resume from there on the next connection instead of re-downloading the entire file. The WAL sync loop already deletes successfully synced WALs, so partially transferred WALs are re-fetched — but they restart from offset 0.
4. **Reduce keepalive interval.** The storage keepalive is 15 s, but the firmware idle-disconnect timer is 30 s. If a keepalive write silently fails (e.g. Android flow control backs off), the firmware may time out. Consider reducing to 10 s for more margin.

#### 4. Phone stops connecting to Omi (requires Bluetooth toggle)

**Problem:** The logs show a connection attempt failing after the full 30 s timeout with `gatt_status_8`, followed by repeated failed retries until the user toggled Bluetooth:

```
23:28:24  manageDevice sent, waiting for device-ready (30s timeout)
23:28:29  not ready in 5s — starting BLE scan in parallel
23:28:39  ignoring transient GATT error during connect: gatt_status_-1
23:28:48  connect failed after 24410ms: gatt_status_8
```

This is the Android BLE stack getting into a **wedged state** where it believes it has an active connection to the device (or has corrupted internal state for that address) but cannot actually communicate over the air.

**Root causes (from code review):**

##### A. Ghost-purge dummy GATT approach worsens the wedge

[OmiBleManager.kt:133-153](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt) (`purgeGhostGatts`) and
[OmiBleManager.kt:164-181](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt) (`purgeGhostGattForAddress`):

```kotlin
val dummyGatt = device.connectGatt(application, false,
    object : BluetoothGattCallback() {}, BluetoothDevice.TRANSPORT_LE)
dummyGatt?.disconnect()
dummyGatt?.close()
```

This creates a **second** GATT client for the same device, immediately disconnects it, and closes it — all in the same main-looper pass. The intent is to flush a stale OS-held link, but on many Android stacks (Samsung/Qualcomm especially) this actually makes things worse:

- `connectGatt` tells the Bluetooth daemon to establish (or reuse) a connection.
- The immediate `disconnect()`/`close()` tears down the *app's client handle* but the daemon's internal connection-tracking may not decrement correctly when a client connects and disconnects within the same looper pass.
- The result is a daemon that holds the connection slot open with no app-side client to receive callbacks, creating exactly the ghost state we were trying to fix.

This is called both at startup (`purgeGhostGatts`, line 134) and during retry logic (`purgeGhostGattForAddress`, called from [OmiBleForegroundService.kt:706](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt)).

##### B. No `disconnect()` before `close()` in `connectGatt` pre-cleanup

[OmiBleManager.kt:263-268](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt):

```kotlin
connectedGatts[addr]?.let {
    Log.i(TAG, "Closing existing GATT for $addr before reconnecting")
    it.close()          // ← no disconnect() first
    connectedGatts.remove(addr)
}
```

If this GATT object represents a connection the OS still considers active (a stale link), calling `close()` without `disconnect()` releases the app's client interface but doesn't tell the daemon to tear down the radio-level link. The daemon keeps the connection alive with no client listening. This is a minor defensive gap — it only matters when a ghost link exists, and the code has the `purgeGhostGattForAddress` mechanism to handle that case. But adding `it.disconnect()` before `it.close()` is a free safety improvement.

The same pattern appears at [OmiBleForegroundService.kt:477](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):
```kotlin
if (bleManager.connectedGatts.containsKey(addr)) bleManager.closeGatt(addr)
```
This calls `closeGatt` (which does `refresh()` then `close()`) but not `disconnectGatt` first. The guard on line 475 (`!bleManager.isPeripheralConnected(addr)`) should mean the device is already disconnected, but `isPeripheralConnected` queries `BluetoothManager.getConnectionState` which can lag behind reality on some stacks.

##### C. Rapid retry cycling with no exponential backoff

[OmiBleForegroundService.kt:40](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):
```kotlin
private const val RECONNECT_DELAY_MS = 1_500L
```

After every failed connection, the code waits only **1.5 seconds** before retrying. There is no exponential backoff. This means after a `gatt_status_8` timeout (which itself took 15–30 s), the code immediately:

1. Calls `disconnectGatt` + `closeGatt` (cleanup)
2. Waits 1.5 s
3. Optionally creates a dummy GATT for ghost purge, waits 500 ms
4. Calls `connectGatt` again

This rapid churn of GATT client registrations/teardowns is the **single most common trigger** for the Android Bluetooth daemon's internal state machine to get wedged on Samsung, Qualcomm, and MediaTek stacks. Each cycle allocates and frees a GATT client interface in the daemon; when done repeatedly in quick succession, the daemon's `ClientMap` can leak entries or corrupt its connection refcount.

##### D. `STATE_TURNING_OFF` and `STATE_OFF` both call `closeGatt` without `disconnectGatt`

[OmiBleForegroundService.kt:786-806](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):

In `STATE_TURNING_OFF`:
```kotlin
bleManager.closeGatt(addr)  // line 792 — no disconnectGatt first
```

In `STATE_OFF`:
```kotlin
bleManager.closeGatt(addr)  // line 803 — no disconnectGatt first
```

When Bluetooth is turning off, the OS is tearing down all links anyway, so this is less impactful. But it means the code is not consistently calling `disconnect()` before `close()` across all paths.

#### Relevant files (full list)

| File | Lines | What it does |
|------|-------|-------------|
| `OmiBleManager.kt` | 133-153 | `purgeGhostGatts` — startup ghost purge via dummy connect-close |
| `OmiBleManager.kt` | 164-181 | `purgeGhostGattForAddress` — per-address ghost purge via dummy connect-close |
| `OmiBleManager.kt` | 254-283 | `connectGatt` — GATT client creation, pre-cleanup of existing GATT |
| `OmiBleManager.kt` | 285-287 | `disconnectGatt` — calls `gatt.disconnect()` |
| `OmiBleManager.kt` | 289-307 | `closeGatt` — calls `gatt.refresh()` then `gatt.close()` |
| `OmiBleManager.kt` | 522-541 | `cleanupPeripheral` — resets queues, stops keepalives, fails active downloads |
| `OmiBleManager.kt` | 543-573 | `createGattCallback` — `onConnectionStateChange` handler |
| `OmiBleForegroundService.kt` | 40 | `RECONNECT_DELAY_MS = 1_500L` |
| `OmiBleForegroundService.kt` | 46-47 | `GHOST_PURGE_MIN_INTERVAL_MS` and `GHOST_PURGE_SETTLE_MS` |
| `OmiBleForegroundService.kt` | 430-467 | `unmanageDevice` — intentional disconnect path |
| `OmiBleForegroundService.kt` | 471-519 | `connectToDevice` — connection with timeout |
| `OmiBleForegroundService.kt` | 536-601 | `handleDisconnection` — cleanup + retry dispatch |
| `OmiBleForegroundService.kt` | 683-726 | `handleRetryLogic` — retry scheduling with ghost purge |
| `OmiBleForegroundService.kt` | 780-806 | Bluetooth state receiver — `STATE_TURNING_OFF`/`STATE_OFF` cleanup |
| `OmiBleForegroundService.kt` | 892-920 | `onDestroy` — service teardown |
| `OmiBleForegroundService.kt` | 954-968 | `setSyncStatus` — notification + settle alarm |
| `OmiBleForegroundService.kt` | 976-992 | `settleStaleConnectingToIdle` — revert stranded notification |
| `SyncAlarmReceiver.kt` | — | Doze-exempt alarm for stranded "Connecting…" notification |

#### Fix ideas

1. **Replace the dummy-GATT ghost purge with a safer approach.** Instead of creating a new `connectGatt` and immediately tearing it down:
   - First try `BluetoothGatt.disconnect()` on the stale system link if you can obtain a handle to it.
   - If that doesn't work, the only reliable programmatic reset is `adapter.disable()` / `adapter.enable()` (requires `BLUETOOTH_CONNECT` permission on Android 12+). This is disruptive but is what "toggle Bluetooth" does manually.
   - If neither is acceptable, at minimum insert a delay (e.g. 500 ms) between `connectGatt` and `disconnect()`/`close()` on the dummy GATT to let the daemon's state machine settle.

2. **Add `disconnect()` before `close()` in all cleanup paths.**
   - [OmiBleManager.kt:266](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt): add `it.disconnect()` before `it.close()`.
   - [OmiBleForegroundService.kt:477](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt): add `bleManager.disconnectGatt(addr)` before `bleManager.closeGatt(addr)`.
   - [OmiBleForegroundService.kt:792, 803](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt): add `bleManager.disconnectGatt(addr)` before `bleManager.closeGatt(addr)` in both `STATE_TURNING_OFF` and `STATE_OFF` branches.

3. **Add exponential backoff to retry logic.** Replace the fixed 1.5 s delay with exponential backoff:
   ```kotlin
   val delay = min(RECONNECT_DELAY_MS * (1L shl min(managed.retryCount, 5)), 30_000L)
   ```
   This gives: 1.5 s → 3 s → 6 s → 12 s → 24 s → 30 s (capped). Dramatically reduces GATT client churn that triggers daemon wedges.

4. **Increase firmware LE supervision timeout.** If the Zephyr config uses the default or a low supervision timeout, increase it to 4–6 s (`CONFIG_BT_PERIPHERAL_PREF_TIMEOUT` in `prj.conf`, value in units of 10 ms, so 400–600). This is the highest-impact fix for the `gatt_status_8` disconnects that cascade into all three problems.

---

#### Summary of impact

| Fix | Addresses | Impact |
|-----|-----------|--------|
| Firmware supervision timeout increase | Partial syncs, BT wedge | **Highest** — prevents the disconnects that cause everything else |
| Exponential backoff on retries | BT wedge | **High** — stops the GATT client churn that wedges the daemon |
| Replace dummy-GATT ghost purge | BT wedge | **High** — removes a mechanism that actively worsens the wedge |
| Add `disconnect()` before `close()` everywhere | BT wedge | **Low-Medium** — defensive improvement, narrow edge case |
| Reduce / improve settle alarm for notification | Stuck notifications | **Medium** — UX improvement |
| Connection parameter tuning during transfer | Partial syncs | **Medium** — trades throughput for reliability |

---

## PENDING

### 2. Hybrid "Isolated Recording" Architecture (Start/Stop) [large] [Pending]

This architecture perfectly combines the eyes-free UX safety of distinct actions (Idea #5, previously Idea #4) with the file-system safety of bin rotations (Idea #3, previously Idea #2) and state-backup (Idea #6, previously Idea #5).

#### Implementation details
1. **Firmware (`settings.c`, `settings.h`)**:
   - Implement the `auto_vad_threshold` backup variable (as detailed in Idea #6). This ensures the device remembers the user's preferred Auto sensitivity (e.g., `250`).
2. **Firmware (`button.c`, `button.h`)**:
   - Add two new distinct actions: `BUTTON_ACTION_RECORD_START` and `BUTTON_ACTION_RECORD_STOP`.
   - **On Start Press**:
     - Block and call `create_new_audio_file()` (Rotate Bin).
     - Immediately write the `0xFFFFFFF8` marker (High-Priority Start Marker).
     - Set `vad_threshold = 65535` (Force continuous capture to ensure no audio is dropped).
   - **On Stop Press**:
     - Block and call `create_new_audio_file()` (Rotate Bin).
     - Immediately write the `0xFFFFFFF7` marker (High-Priority Stop Marker).
     - Set `vad_threshold = auto_vad_threshold` (Safely restore the background VAD using the backup variable).
3. **App (`vad_audio_processor.dart`)**:
   - **On reading `0xFFFFFFF8`**: Finalize the current active auto-recording. Start a brand new, isolated recording anchored at this byte offset and set a high-priority flag (e.g., render it red in the UI).
   - **On reading `0xFFFFFFF7`**: Finalize the isolated recording. Immediately start a new standard auto-recording to capture the ambient background audio moving forward.
4. **App UI (`button_config_page.dart`)**:
   - Add "Start Isolated Recording" and "Stop Isolated Recording" to the configuration list so users can map them to separate distinct gestures (e.g., Double Tap to Start, Triple Tap to Stop). This avoids "state confusion" and allows true eyes-free usage.

### 3. High-Priority Marker Mode — "New Recording" Button Action [large] [Pending]

Implementation spec. **Self-contained** — every file/line/symbol below was verified against the
codebase during research. A fresh agent can implement straight from this doc.

> Magic byte: `0xFFFFFFF8` (next in sequence below mute-off `0xFFFFFFF9`).
> Verified unused anywhere in `app/lib/` or firmware source.
> Payload: 20 bytes total = 4-byte header + 16-byte payload `utc_time_ms` (u64) + `uptime_ms` (u32)
> + `device_session_id` (u32) — identical to the button-tap marker `0xFFFFFFFE`.

---

#### 1. What it is (design, settled)

A **fifth button action, "New Recording"**, available **only in auto (VAD) mode** — not manual mode,
which is already press-to-start / press-to-stop. On tap (auto mode, not muted) the device:
1. **rotates the SD bin file** (closes the current bin, opens a new one), then
2. writes a `0xFFFFFFF8` marker as the first inline frame of the new bin,
3. flashes the LED **red**, and wakes AAD.

The app, when processing audio, treats `0xFFFFFFF8` as a **split**: it finalizes the current
recording at that boundary and starts a fresh one anchored at the marker. The new recording carries
a **high-priority** marker rendered **red** (vs. the normal amber bookmark). A settings toggle
(`showHighPriorityMarker`) controls whether these red markers are shown in the timeline.

It reuses the existing **marker** infrastructure end-to-end. The only behavioural deltas vs. the
normal `0xFFFFFFFE` marker: (a) it forces a recording split (close prior, start new), (b) red instead
of amber, (c) auto-mode-only, (d) firmware rotates the bin.

##### Why the flag lives on `MarkerConversation`, not on the recording
"red flag instead of yellow flag" — the only amber/yellow element in the UI is the **marker bookmark
icon** (`batch_card` `MarkerSubEntry`, `Colors.amber`). There is no yellow on recordings. So "red"
means recoloring the marker. "A separate recording starting at the high-priority marker" is satisfied
because the marker is added *after* the flush, so it associates with the **next** saved recording
(the new split) at `offsetAtMarkerMs: 0` → its `segment` = the new recording, marker sits at its start.

---

#### 3. CRITICAL: why the firmware MUST rotate the bin (do not skip this)

The app's bin model is **whole-bin**: a recording's `.meta` stores the *set* of bins it touched
(no byte-offset granularity), and the stateless reader re-reads each bin **from offset 0** every run.

If the bin is **not** rotated, one physical bin holds `[prior audio][0xFFFFFFF8 marker][new audio]`.
That shared bin is **retained** across runs (the in-progress new recording flushes as a `_draft`, and
`pruneConsumedBins` keeps any bin a draft references). On the next run the retained bin is re-read
from offset 0, and its **pre-marker audio is re-VAD'd into a DUPLICATE of the already-finalized prior
recording**. `coveredBinPaths` only skips *fully*-covered bins, and the prior recording's interval
ends mid-bin, so the shared bin is not skipped. This is the system's own documented failure mode
("near-duplicate .wav with a slightly different VAD cut", `recordings_manager.dart:2650`).

App-only would require adding **sub-bin consumed-offset tracking** to both the deletion path and the
reader — a much larger, riskier change. **Rotating the bin makes the recording boundary coincide with
a bin boundary**, which the whole-bin model handles cleanly:
- prior bin → fully consumed by the finalized prior recording, referenced by no draft → deleted cleanly;
- new bin → owned only by the draft → retained, re-read with no pre-marker audio to duplicate.

The existing `0xFFFFFFFC` (session-end) / `0xFFFFFFFA` (mute-on) handlers dodge this only because they
**drop** all post-marker audio (`_sessionEndPendingResume` / `_muted`). `0xFFFFFFF8` is the FIRST case
that finalizes mid-stream **and keeps consuming into a new recording**, which is exactly why it needs
the rotate.

##### Known caveats (accepted)
- `create_new_audio_file()` **blocks the button thread up to ~25 s** worst case (SD contention);
  normally milliseconds. Acceptable for a button action. The async-flag alternative
  (`rotate_file_requested`) avoids the block but races the marker into the *old* bin → marker lost, so
  the **blocking call is the correct choice**.
- The marker is not *guaranteed* the literal first frame — a few audio frames queued at rotation time
  can land in the new bin ahead of it. Worst case that is a sub-second fragment that VAD almost always
  drops; the app handler only finalizes when `_currentRefs` is non-empty, so it tolerates this.

---

#### 4. Firmware changes (`omi/firmware/omi/src/`)

##### 3a. `lib/core/button.h`
Enum at lines 17-22 is `NONE=0, MUTE=1, MARKER=2, TOGGLE_LED=3`. Add:
```c
typedef enum {
    BUTTON_ACTION_NONE = 0,
    BUTTON_ACTION_MUTE = 1,
    BUTTON_ACTION_MARKER = 2,
    BUTTON_ACTION_TOGGLE_LED = 3,
    BUTTON_ACTION_NEW_RECORDING = 4,   // ADD
} button_action_t;
```
(`marker_flash_color_t` at button.h:11-15 already defines `MARKER_FLASH_WHITE/GREEN/RED`.)

##### 3b. `lib/core/transport.h`
Marker declarations are at lines 33-60, **return `bool`** (not `int`). Add after line 60:
```c
bool write_new_recording_marker_to_storage(void);
```

##### 3c. `lib/core/transport.c`
- Helper `static bool write_marker_header_to_storage(uint32_t header, const char *label)` at **line
  1572**; `label` is logging-only (no length constraint). All marker fns live inside
  `#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE` (opened **1455**, closed **1641**). Add the new fn before
  line 1641, alongside the others:
  ```c
  bool write_new_recording_marker_to_storage(void)
  {
      return write_marker_header_to_storage(0xFFFFFFF8, "new-record");
  }
  ```
- **Bounds-check fix (mandatory — else the app can never assign action 4).** In
  `button_config_write_handler` (lines 453-472), the loop at 463-469 rejects anything `> 3`:
  ```c
  for (int i = 0; i < 6; i++) {
      if (cfg[i] > BUTTON_ACTION_TOGGLE_LED) {      // CHANGE → BUTTON_ACTION_NEW_RECORDING
          return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
      }
  }
  ```

##### 3d. `lib/core/button.c` — `execute_button_action()` (lines 134-233)
Mirror the **non-manual** `BUTTON_ACTION_MARKER` branch (lines 191-207), but red, and **only in
auto mode**. The existing MARKER case branches on manual mode at line ~166; **find the exact variable
the MARKER case uses to detect manual mode** (it is the same one) and guard on it. `acted` (line 150,
`bool __maybe_unused acted`) gates haptic at line 227; set it so haptic fires. `is_muted` is
`volatile bool` (button.c:31).

```c
case BUTTON_ACTION_NEW_RECORDING:
    // Auto-mode only: manual mode is already press-to-start/stop.
    if (<IN_MANUAL>) {                 // same check the MARKER case uses (~line 166)
        LOG_INF("New Recording ignored (manual mode)");
    } else if (is_muted) {
        LOG_INF("New Recording ignored (muted)");
    } else {
        acted = true;
        marker_flash_color = MARKER_FLASH_RED;   // red, vs MARKER_FLASH_WHITE for normal marker
        marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
        sd_write_pause(false);
        create_new_audio_file();                  // ROTATE: close prior bin, open fresh one (blocks)
        write_new_recording_marker_to_storage();  // 0xFFFFFFF8 as first inline frame of new bin
#endif
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
        aad_force_wake();
#endif
    }
    break;
```
- `create_new_audio_file()` is at `sd_card.c:2769` (thread-safe blocking wrapper; posts
  `REQ_CREATE_NEW_FILE` to `sd_prio_msgq`, SD worker does the close/open via
  `create_audio_file_with_timestamp`, new file gets a fresh `timerStart` from `get_utc_time()`,
  header `0xFFFFFFFB` written first). Include `sd_card.h` — already included in button.c under the
  offline-storage guard.
- Default button config `settings.c:50` `{0,0,2,1,3,0}` needs no change; out-of-range stored values
  fall through `default: break` harmlessly.

---

#### 5. App changes (`app/lib/`)

##### 4a. `backend/preferences.dart`
Mirror the `manualMode` idiom at lines 39-40. Add:
```dart
bool get showHighPriorityMarker => getBool('showHighPriorityMarker', defaultValue: true);
set showHighPriorityMarker(bool v) => saveBool('showHighPriorityMarker', v);
```
This is a **UI-visibility** pref only, read in the main isolate. **It is NOT read by the VAD
processor** (the processor runs in a background isolate that has no `SharedPreferencesUtil`; do not try
to read it there). The processor always emits the marker with `isHighPriority: true`; the UI decides
whether to show it.

##### 4b. `pages/settings/button_config_page.dart`
`_actions` getter at lines 38-43. Add "New Recording" **only in auto mode** (index 4):
```dart
List<String> get _actions => [
      'None',
      _manualMode ? 'Mute - Disabled' : 'Mute',
      _manualMode ? 'Start/Stop Recording' : 'Marker',
      'Toggle LED',
      if (!_manualMode) 'New Recording',   // ADD
    ];
```
Dropdowns are auto-generated from `_actions.length` (`List.generate`, line 183) with a clamp at line
156, so the new entry just works. Add a `SwitchListTile` (no existing one in this file — use the
standard Material widget) wired to `SharedPreferencesUtil().showHighPriorityMarker`. Config is sent via
`_updateConfig(index, action)` → `setButtonConfig(_config)` (lines 92-121).

##### 4c. `services/vad_audio_processor.dart`  (the core change)

**Record type** — `_pendingMarkers` at **line 154**:
```dart
final List<({int markerMs, int offsetAtMarkerMs, bool isHighPriority})> _pendingMarkers = [];
```
This record is touched at **4 existing sites** beyond the declaration — update all:
- **Serialize, line 352:** `... {'ms': m.markerMs, 'o': m.offsetAtMarkerMs}` → add `'hp': m.isHighPriority`.
- **Deserialize, line 398:** `_pendingMarkers.add((markerMs: m['ms'] as int, offsetAtMarkerMs: m['o'] as int))`
  → add `isHighPriority: (m['hp'] as bool?) ?? false` (backward-compat default — old persisted state lacks it).
- **0xFFFFFFFE add-site, line 794:** add `isHighPriority: false`.
- EDL emit sites (below).

**EDL emit — add `'isHighPriority': m.isHighPriority` to the map at both:**
- `_saveRecording`, loop at lines 1791-1798 (`_pendingEdlData.add({...})`).
- `_emitOrphanMarkers`, map at lines 1602-1607.

**New `0xFFFFFFF8` handler.** It is `[session-end flush MINUS the resume latch]` + `[button-tap
fresh-start]` + `[high-priority tag]`. Insert near the other frame handlers (after the `0xFFFFFFFC`
block at lines 839-871). **Do NOT set `_sessionEndPendingResume`** — that would drop the new
recording's audio. Symbols verified: `_useBatchRunner` (300), `_batchDeferredFrames` (55),
`_flushVadBatch` (1492, `Future<int>`, named args `savedFiles`/`segmentSpeechFrames`),
`flushRemaining` (1257, `Future<String?> {bool isDraft=false}`), `_currentRefs` (77),
`_forcedByMarker` (133), `_markerProtectedUntilMs` (136), `_markerProtectionWindowMs` (188, =50000),
`_pcmBufferLen` (44), `_cachedStateValue` (29), `_vadContext` (38), `_vadContextSamples` (176, =64),
`_batchResetPending` (58). The fresh-start fields come verbatim from the `0xFFFFFFFE` handler lines
797-804 (`_recordingStartTime`, `_speechFrameCount`, `_currentChunkDurationMs`,
`_currentFrameUptimeMs`, `_isDerivedTimestamp`).

```dart
// New-recording marker (0xFFFFFFF8, 20 bytes). Auto-mode "New Recording" button.
// Finalize the current recording at this boundary and start a fresh one.
// Firmware rotates the bin here, so this marker normally arrives near the start of a fresh
// bin (_currentRefs typically empty). CRITICAL: do NOT set _sessionEndPendingResume — audio
// must flow straight into the new recording (no 0xFFFFFFFD resume marker follows).
if (frameLength == 0xFFFFFFF8) {
  if (offset + 20 <= fileLength) {
    // 1) Flush any deferred VAD batch first (two-pass runner) — capture the returned count.
    if (_useBatchRunner && _batchDeferredFrames.isNotEmpty) {
      segmentSpeechFrames =
          await _flushVadBatch(savedFiles: savedFiles, segmentSpeechFrames: segmentSpeechFrames);
    }
    // 2) Parse marker timestamp (same layout as 0xFFFFFFFE).
    final markerUtcMs = byteData.getUint64(offset + 4, Endian.little);
    final markerUptimeMs = byteData.getUint32(offset + 12, Endian.little);
    final markerFrameTime = markerUtcMs > 946684800000
        ? DateTime.fromMillisecondsSinceEpoch(markerUtcMs, isUtc: true)
        : lastFrameWallTime;
    final markerMs = markerFrameTime.millisecondsSinceEpoch;
    // 3) Finalize the current recording (if any) at this boundary.
    if (_currentRefs.isNotEmpty) {
      _forcedByMarker = true;
      final filePath = await flushRemaining(isDraft: false);
      if (filePath != null) savedFiles.add(filePath);
    } else {
      _emitOrphanMarkers();
    }
    // 4) Start the fresh recording timeline at the marker (refs are now empty). Fields per 797-804.
    lastFrameWallTime = markerFrameTime;
    _recordingStartTime = markerFrameTime;
    _speechFrameCount = 0;
    _currentChunkDurationMs = 0;
    _currentFrameUptimeMs = markerUptimeMs;
    _isDerivedTimestamp = false;
    // 5) Queue the high-priority marker at offset 0 of the new recording.
    if (markerMs > 946684800000) {
      _pendingMarkers.add((markerMs: markerMs, offsetAtMarkerMs: 0, isHighPriority: true));
      _markerProtectedUntilMs = markerMs + _markerProtectionWindowMs;
    }
    // 6) Teardown for a clean VAD boundary (= session-end 863-867, minus the resume latch).
    _pcmBufferLen = 0;
    _cachedStateValue?.dispose();
    _cachedStateValue = null;
    _vadContext.fillRange(0, _vadContextSamples, 0.0);
    _batchResetPending = true;
  }
  offset += 20;
  continue;
}
```
> Verify the exact fresh-start field names against lines 797-804 before committing (they were quoted
> verbatim from research but confirm in-file). The `0xFFFFFFFE` handler has extra drift-correction
> logic around lines 753-820; for `0xFFFFFFF8` the simplified timestamp parse above is sufficient
> because the marker sits at a fresh bin start.

##### 4d. `services/recordings_manager.dart`
- **Frame-skip guard, line 1194** (inside `_stitchGhostAudio`, loop 1181-1206). Change the threshold —
  this also fixes the **pre-existing** latent bug where mute markers `0xFFFFFFF9/FA` break the scan early:
  ```dart
  if (frameLen >= 0xFFFFFFF8) {                      // was >= 0xFFFFFFFB
    offset += (frameLen == 0xFFFFFFFB ? 36 : 20);    // ternary already correct for F8..FE
    continue;
  }
  ```
- **`getMarkerConversations()` constructor, lines 1935-1943.** Add:
  ```dart
  isHighPriority: json['isHighPriority'] as bool? ?? false,
  ```
- **EDL creation payload, lines 1771-1778** (the `payload` map written to the `.edl`). Add
  `'isHighPriority': ...`. The **upstream `edl` source dict** built in the VAD isolate (where the
  marker is parsed) must also carry the flag, or it never reaches disk.
- `pruneConsumedBins` (2680-2743) and `consumeSafeToDeletePaths`
  (`vad_audio_processor.dart:1301-1309`) are the bin-deletion paths — **no change needed**; they are
  the reason the firmware rotate is required (see §2). Context only.

##### 4e. `pages/recordings/marker_conversation_player_page.dart` — lines 142-152 (`_saveEdl()`)
**Bug to fix:** `_saveEdl()` rebuilds the EDL map from scratch and drops unknown keys, so cropping a
red marker would silently revert it to amber. Add:
```dart
'isHighPriority': widget.markerConversation.isHighPriority,
```

##### 4f. `services/omi_api_client.dart` — `_readOpusFrameChunks` (lines 326-369)
Currently skips `FB(+36)`, `FE(+20)`, `FD(+16)`, and a catch-all `>0xFFFF00(+4)` at line 348. Insert
**before line 348** (each marker is 20 bytes; this also fixes existing mute markers wrongly hitting the
+4 catch-all):
```dart
if (frameLength == 0xFFFFFFF8 || frameLength == 0xFFFFFFF9 || frameLength == 0xFFFFFFFA) {
  offset += 20;
  skippedMarkers++;
  continue;
}
```
Update the stale doc comment at line 314 (it lists only "0xFFFFFFFE/FD/FB").

##### 4g. `models/recordings/recordings_models.dart` — `MarkerConversation` (lines 508-536)
`const` constructor, no `copyWith`/`fromJson`/`toJson`. Add a defaulted field — safe, the only
construction site is `recordings_manager.dart:1935`:
```dart
final bool isHighPriority;
// ...in the const constructor:
this.isHighPriority = false,
```

##### 4h. UI — render red at BOTH sites
- `pages/recordings/batch_card.dart` — `MarkerSubEntry` (94-137), render at 110-126:
  icon `FontAwesomeIcons.solidBookmark` color `Colors.amber`, label `'Marker at ${mc.markerTimeLabel}'`.
  When `mc.isHighPriority`: red color + label `'New Recording at ${mc.markerTimeLabel}'`. Gate
  visibility on `SharedPreferencesUtil().showHighPriorityMarker` (main isolate — fine here).
- `pages/recordings/marker_day_card.dart:98` — `MarkerTile` is a **second render site**; apply the
  same red branch for consistency. Confirm which view is live; style both.

---

#### 6. Edge cases accounted for

| Case | Handling |
|---|---|
| Manual mode | Action hidden in app (`if (!_manualMode)`) **and** ignored by firmware (the `<IN_MANUAL>` guard) — covers assign-in-auto-then-switch-to-manual. |
| Muted | Firmware no-ops the tap, same as the marker. |
| Pre-time-sync (no RTC) | Timestamp falls back to `lastFrameWallTime`; no 1970 timestamps. |
| Old persisted data | `isHighPriority` defaults `false` everywhere (`as bool? ?? false`); no crash on old `.edl` / serialized state. |
| Crop-save | `_saveEdl()` explicitly preserves the flag (§4e). |
| App restart mid-run | Flag survives the `_pendingMarkers` serialize/deserialize round-trip (§4c). |
| Latent mute-marker bugs | The frame-skip fixes (§4d, §4f) also repair `0xFFFFFFF9/FA` handling. |
| Two timeline views | Both `batch_card` and `marker_day_card` get the red branch. |
| Pref-in-isolate | Avoided: processor always emits the flag; UI (main isolate) gates display. |
| Shared-bin duplication | Avoided by the firmware rotate making recording boundary = bin boundary (§2). |
| Rotation leftover-audio race | Negligible (sub-second, VAD-dropped); handler only finalizes when `_currentRefs` non-empty. |
| ~25 s worst-case button-thread block | Accepted; blocking is required for correct marker ordering. |

---

#### 7. Files touched (checklist)

**Firmware**
- [ ] `lib/core/button.h` — `BUTTON_ACTION_NEW_RECORDING = 4`
- [ ] `lib/core/transport.h` — declare `bool write_new_recording_marker_to_storage(void)`
- [ ] `lib/core/transport.c` — impl inside offline-storage guard; **bounds check 466 → `> BUTTON_ACTION_NEW_RECORDING`**
- [ ] `lib/core/button.c` — new case: auto-mode-only, red flash, rotate→marker→wake (verify `<IN_MANUAL>` var)

**App**
- [ ] `backend/preferences.dart` — `showHighPriorityMarker` (default true)
- [ ] `pages/settings/button_config_page.dart` — `_actions` entry (auto-only) + `SwitchListTile`
- [ ] `services/vad_audio_processor.dart` — `_pendingMarkers` field + 4 serde/add sites; `0xFFFFFFF8` handler; 2 EDL emits
- [ ] `services/recordings_manager.dart` — frame-skip `>= 0xFFFFFFF8` (1194); `getMarkerConversations` flag (1935); EDL creation payload (1771) + isolate source dict
- [ ] `pages/recordings/marker_conversation_player_page.dart:142` — preserve flag in `_saveEdl`
- [ ] `services/omi_api_client.dart:348` — skip F8/F9/FA; fix doc comment 314
- [ ] `models/recordings/recordings_models.dart` — `isHighPriority` on `MarkerConversation`
- [ ] `pages/recordings/batch_card.dart` + `pages/recordings/marker_day_card.dart:98` — red render at both sites

**After implementing:** format (`dart format --line-length 120 <files>`, `clang-format -i <firmware>`),
add a `CHANGELOG.md` entry, and bump fw rev when shipping firmware.

---

#### 8. Open items to confirm during implementation
1. The exact firmware variable the `BUTTON_ACTION_MARKER` case uses to detect manual mode (button.c ~166) — reuse it for the `<IN_MANUAL>` guard.
2. The VAD fresh-start field names at `vad_audio_processor.dart:797-804` (quoted from research; confirm in-file).
3. The upstream isolate `edl` source dict that feeds `writeMarkerEdl` (so `isHighPriority` reaches disk, not just the on-read path).


### 4. Clean session-end marker when entering Manual Mode [medium] [Pending]

When the user toggles Manual Mode *on* in the app settings, the device transitions its VAD threshold to `32769` (manual standby). Currently, because the previous threshold wasn't `65535` (manual recording), the firmware doesn't instantly inject a `session-end` marker. Instead, it relies on the VAD's natural 10-second silence timeout (`CONFIG_OMI_VAD_HOLD_MS`) to put the recording to sleep. 

#### Why this should change
Switching modes is a hard context boundary. Any ongoing auto-mode conversation should be cleanly finalized with a `session-end` marker the moment the user switches to Manual Mode, rather than letting it bleed out over a 10-second silence timeout. 

#### Implementation details
- **Firmware (`aad.c`):** Update `aad_set_threshold()` so that injecting a `session-end` marker (`0xFFFFFFFC`) isn't strictly gated by `leaving_manual_record` (`prev == 65535 && threshold != 65535`). If the threshold is dropping to `32769` (entering manual mode) from an active auto-recording state (e.g., `prev == 250` and `vad_is_recording == true`), it should also trigger `write_session_end_marker_to_storage()` and instantly put the VAD to sleep.


### 5. Split manual recording Start/Stop from the Marker action [medium] [Pending]

Back when the device had limited button gestures, the `MARKER` action (`BUTTON_ACTION_MARKER`) was overloaded to act as a Start/Stop toggle when `in_manual == true`. Now that the device has a customizable multi-gesture button configuration (`_config` array supporting single/double/triple taps), this overload is actively harmful.

#### Why this should change
1. **Regain Marker utility:** Because `MARKER` is overloaded, a user cannot drop a timestamp marker *during* an active manual recording. By splitting them, `MARKER` can go back to just dropping the `0xFFFFFFFE` marker packet and flashing white, regardless of what mode the device is in.
2. **Eliminate state confusion:** Toggles create "state confusion" (e.g., "Did I just start or stop it?"). With explicit Start/Stop actions, a user can map Double-Tap to Start and Triple-Tap to Stop. The gesture guarantees the intent, no LED checking required.
3. **Cleaner codebase:** The `if (in_manual)` branching inside the `MARKER` switch case in `button.c` can be removed, and the ternary UI label hack in `button_config_page.dart` can be deleted.

#### Implementation details
1. **Firmware (`button.h`):** Expand `button_action_t` to include `BUTTON_ACTION_RECORD_TOGGLE = 4`, `BUTTON_ACTION_RECORD_START = 5`, `BUTTON_ACTION_RECORD_STOP = 6`.
2. **Firmware (`button.c`):** Remove the `in_manual` threshold logic from `BUTTON_ACTION_MARKER`. Add new `switch` cases for the new actions that call `aad_set_threshold(65535)` for start and `aad_set_threshold(32769)` for stop (and toggle between them based on current `aad_get_threshold()`).
3. **App (`button_config_page.dart`):** Expand the `_actions` list to include `'Toggle Recording'`, `'Start Recording'`, and `'Stop Recording'`. Remove the `_manualMode ? ... : ...` ternary logic for the Marker label.

### 6. Device-side toggle for Manual/Auto Mode [medium] [Pending]

Add a new button action that allows users to toggle between Auto Recording and Manual Recording directly from the device, without needing to use the app.

#### Why this is needed
Users may want to quickly switch between continuous auto-recording and on-demand manual capture while on the go. Currently, this requires opening the app. 

A key architectural strength already exists for this: the app prevents offline mode editing and treats the device's `vad_threshold` as the ultimate source of truth upon connection. Therefore, if the device toggles the mode locally, no "timestamp conflict resolution" is needed. The app will simply read the new state upon its next connection and update the UI accordingly.

#### The Firmware Catch
Currently, the firmware only has one persisted threshold variable (`vad_threshold`). When the app switches the device into Manual Mode, it overwrites this variable with `32769`, effectively erasing the user's preferred Auto Mode threshold (e.g., `250`). If a device-side button tries to toggle *back* to Auto Mode, it doesn't know what threshold to fall back to.

#### Implementation details
1. **Firmware (`settings.c`, `settings.h`):** Add a new persisted setting called `auto_vad_threshold` (e.g., defaulting to `250`). This ensures the device always remembers the user's preferred auto-sensitivity even while in manual standby.
2. **App BLE Communication:** Update the "Auto VAD Threshold" slider in the app so that it writes the value not just to the active threshold (if in auto mode), but also explicitly saves it to the firmware's new `auto_vad_threshold` backup slot.
3. **Firmware (`button.h`, `button.c`):** 
   - Add `BUTTON_ACTION_MODE_TOGGLE = 7` to the action enum.
   - When pressed: if `vad_threshold >= 32769` (currently in manual mode), switch the active threshold to the saved `auto_vad_threshold`. If `vad_threshold < 32769` (currently in auto mode), switch the active threshold to `32769`.
4. **App (`button_config_page.dart`):** Add `'Toggle Auto/Manual Mode'` to the `_actions` list so users can assign it to a tap gesture.

### 7. Device-driven BLE wake (firmware + iOS) [large] [Pending]

Shift background-sync triggering from the *phone* (opportunistic iOS `BGTaskScheduler` / Android alarms) to the *device*: the Omi opens a connectable advertising **window** on its own RTC-driven schedule, and the phone ΓÇö holding a standing pending-connect ΓÇö is woken by the OS the moment that window opens. This is the model commercial BLE wearables (e.g. CGMs) use for reliable background sync on iOS.

#### The honest framing (why)
The primary win is **iOS wake *reliability* + device-controlled (punctual) timing**, **not** device battery. The firmware already advertises *slow* (~1 s, `adv_param_slow` in `transport.c`) when idle, which is already cheap; going fully "dark" saves only a bit more. The real reason: a standing pending-connect lets iOS wake the app on the *device's* schedule, replacing the opportunistic `BGTaskScheduler` path (which iOS fires unpredictably and never punctually). The same mechanism *forces* the firmware change ΓÇö a standing pending-connect pointed at a device that advertises connectably **continuously** (today's behavior) would reconnect ΓåÆ idle-drop ΓåÆ reconnect forever (churn). So the device must advertise connectably only in **windows it controls**. **Net: mostly an iOS project.** Android already wakes reliably (FGS + exact alarm + WorkManager) and needs little/no change.

#### Second motivation: privacy / smaller attack surface (going dark)
For an *audio recorder*, the stealth of DARK is arguably as compelling as the iOS-wake win. Today the device advertises connectably 24/7 as "Omi" + service UUIDs, so it is:
- **Visible to any BLE scanner** ΓÇö and continuously broadcasting *"someone here is wearing a recording device."*
- **Trackable** ΓÇö a constant advertiser is a beacon a passive scanner can log and correlate across locations (AirTag-stalking vector).
- **Reachable** ΓÇö any device can occupy its single connection slot (lock-out / DoS) or probe its GATT table.

DARK shrinks exposure from "always visible + reachable" to "brief periodic windows + button press." Precise scope of what this protects: **reachability/visibility, not data confidentiality** ΓÇö the audio and encrypted characteristics are *already* bond/encryption-gated today, so DARK isn't adding data secrecy; it's removing the ability to *find, track, or connect to* the device, which is the basis of passive tracking and most targeted attacks.

**Inseparable coupling (same as the UX cost):** "others can't find/connect it while dark" is literally identical to "your own phone can't either, until a window or button." Your phone copes via the standing pending-connect catching scheduled windows (auto, no tap) + button for immediate connect; attackers only ever get the brief windows. You cannot have the stealth without the not-instantly-connectable.

**Cheap hardening that pairs with DARK:**
- **Resolvable Private Address (RPA).** If the firmware advertises a static/public BLE address, the device is still trackable *during* windows. A rotating RPA (bonded phone resolves it via the IRK; strangers can't) closes the window-time tracking gap. *Verify the current address type in firmware.*
- **Reject non-bonded connections fast** ΓÇö *low value, likely skip.* The payoff is marginal: every meaningful characteristic is already `*_ENCRYPT`-gated (`storage.c`, `transport.c`, button-config, mute, accel), so a non-bonded peer can read *nothing* ΓÇö confidentiality is already solved. The only real gain is connection-slot DoS, which is *already half-covered* by the 15 s idle-disconnect (`idle_disconnect_work_handler` drops an idle hogger in 15 s). Against that thin benefit it needs solid RPA resolution or it risks **false-rejecting your own iPhone** (rotating address). Net negative ΓÇö the encryption perms do the security work. (If maximum window-time stealth is ever wanted, *directed* advertising aimed only at the bonded central is the cleaner lever than connection-level rejection.)

So DARK now carries two stacked upsides ΓÇö **low-power + reliable iOS background wake**, *and* **a much smaller privacy/tracking/attack surface** ΓÇö against the one cost (not instantly connectable on app open).

#### Current state
- **Firmware (`transport.c`, `aad.c`):** idle-disconnects after 15 s of no storage GATT activity (`idle_disconnect_work_handler`, `IDLE_DISCONNECT_TIMEOUT_MS`), then reverts to advertising. Two **always-connectable** modes: fast (`BT_LE_ADV_CONN`) and slow (`adv_param_slow`), via `transport_set_adv_fast/slow()`. **AAD currently owns advertising cadence** (recording ΓåÆ fast `aad.c:310`, silence ΓåÆ slow `aad.c:330`). Conn params 7.5ΓÇô22.5 ms, **latency 0** (`update_conn_params`); iOS recheck falls back to 15ΓÇô30 ms. Audio records to SD **independent of BLE** ΓÇö nothing lost while dark/disconnected.
- **iOS (`OmiBleManager.swift`, `device_provider.dart`):** state restoration *is* wired (`CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState` ΓåÆ `onStateRestored`), **but the aggressive disconnect neutralizes it**: `disconnectDevice(isManual:true)` (`device_provider.dart:884`, `:996`) ΓåÆ `disconnectPeripheral` adds to `manuallyDisconnected` + cancels the link, and `didDisconnectPeripheral` re-arms `connect()` *only if not manual*. Steady state = no pending connect = nothing for iOS to wake on.
- **Android (`OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`):** FGS (`FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`) + WorkManager periodic + `setExactAndAllowWhileIdle`; already uses `connectGatt(autoConnect=true)` as a pending-connect fallback. Reliable today.

#### Target architecture
A device-side **sync-window state machine** replaces AAD's ownership of advertising:

```
        ΓöîΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ DARK ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ        no phone connects
        Γöé non-connectable / adv stopped ΓöéΓùäΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ within window ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ
        Γöé radio mostly off; SD recording Γöé                            Γöé
        ΓööΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö¼ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÿ                            Γöé
   cooldown elapsed AND Γöé (cooldown = sync interval, pushed by app)   Γöé
   has-unsynced data    Γû╝                                            Γöé
        ΓöîΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ SYNC WINDOW ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ    phone connects   ΓöîΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö┤ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ
        Γöé fast CONNECTABLE adv, Γëñ W sec ΓöéΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓû║  Γöé   CONNECTED     Γöé
        ΓööΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÿ                    Γöé sync; existing  Γöé
                                                             Γöé 15 s idle-drop  Γöé
                                                             ΓööΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö¼ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÿ
                                                                      Γöé disconnect ΓåÆ DARK (restart cooldown)
```

Phone side: a **standing pending-connect is always armed** (iOS `connect()` + restoration; Android `autoConnect=true`). The device's cooldown = the sync cadence, punctual because the device's RTC drives it. **In `enabled=1` mode the app's own autosync timer goes dormant on *both* platforms** ΓÇö there's exactly one schedule, owned by the device, so there's nothing for an app timer and a device timer to drift out of. The app's job shrinks to: hold the standing connect, re-push config on each connect, and sync on any device-initiated wake.

#### Firmware changes (the enabling work)
1. **Dark state** ΓÇö `transport_set_adv_dark()`: prefer **non-connectable** advertising (`BT_LE_ADV_NCONN`) so the device stays visible for diagnostics/UI but rejects CONNECT_IND (or fully `bt_le_adv_stop()` for lowest power). Track in `current_adv_mode`.
2. **Sync-window scheduler** (new `sync_window.c` or folded into `transport.c`, a `k_work_delayable`, driven by the **monotonic clock** so it's immune to time-sync state): DARK for `cooldown_ms` ΓåÆ open SYNC WINDOW (`transport_set_adv_fast()`). The window is a **connectability *ceiling*, not a broadcast duration** ΓÇö fast-advertise up to `window_ms` (**45ΓÇô60 s**; iOS background scan is duty-cycled and slow to notice adverts), but **stop advertising the moment a phone connects** (you only needed to be findable long enough to latch). Once connected, the existing `idle_disconnect_work` owns teardown, so a sync runs as long as data flows ΓÇö far past `window_ms`. On `_transport_disconnected`, **schedule the next window as `now + cooldown` on the monotonic clock**: because it resets off the *last disconnect*, a manual button-sync automatically pushes the next scheduled window out by a full interval ΓÇö the "manual sync moves the timer" behavior, free, no special handling. Window expiry with no connect ΓåÆ DARK, restart cooldown.
3. **Hand advertising ownership from AAD to the scheduler** ΓÇö keep AAD's VAD/SD-pause logic; remove/gate its `adv_*_req` writes (`aad.c:310,330,464`, applied in the AAD loop `aad.c:247-250`). Most invasive *refactor*; regression-test VAD recording, SD pause/resume, marker durability.
4. **Gate windows on "has unsynced data"** ΓÇö use "SD has stored files" as the proxy (app deletes via `CMD_DELETE_FILE`); SD empty ΓåÆ stay DARK until new audio is recorded.
5. **Config characteristic + user-facing "Dark Mode" toggle (default OFF)** ΓÇö new char under Settings service (`0010`, e.g. `0014`): `interval_minutes(u16) + window_seconds(u8) + enabled(u8)` (+ optional `next_override_seconds(u16)` for app-side policy nudges), persisted via `settings.c`, range-validated, with a **compiled-in default** (`config.h`) as the floor for a never-configured device. Surfaces in the app as a single **Dark Mode** switch (writes `enabled=1`). **Cadence reuses the existing "Auto Sync Interval" dropdown** (`app_settings_page.dart`: 15/30/60 min / Manual Only) ΓÇö no new cadence setting; the user's existing `backgroundSyncIntervalMinutes` drives the *device's* cooldown. **"Manual Only" (`-1`) maps to button-only wake** ΓÇö firmware opens *no* scheduled windows, only the button window. The app **re-pushes config on every connect** (belt-and-suspenders: the device never holds stale config; the dropdown is the source of truth). Firmware default is `enabled=0` = today's always-connectable behavior (old apps and Android untouched). `enabled=1` activates DARK/window cycling. See "Cross-platform: why this is opt-in" below.
6. **Capability bit** ΓÇö add `deviceDrivenSync` to the Features bitfield (`0021`, `OmiFeatures`) for mixed-version safety (new app + old fw ΓåÆ old timer path; old app + new fw ΓåÆ covered by #7).
7. **On-demand connectability + recovery floors (critical UX safeguard, see "Button-to-wake" below)** ΓÇö button/motion triggers open a window immediately. Plus two recovery behaviors so the device can't strand itself:
   - **Boot:** on reboot, **advertise connectably (like `enabled=0`) until the phone connects and writes config at least once, then resume the persisted dark schedule** ΓÇö re-anchoring `last_disconnect` to that fresh contact so there's no post-reboot blackout (the phone's standing pending-connect latches the moment the device advertises). **Cap the stay-open at ~15 min:** if the phone never shows (rebooted away from the phone), fall back to the persisted last-known config and resume dark scheduling so continuous advertising doesn't drain the 150 mAh cell.
   - **Liveness floor:** no successful sync for `> N` intervals ΓåÆ fall back to continuous connectable advertising so the device can't become permanently unreachable.
8. **(Alternative model) Held low-power connection** ΓÇö instead of windowing, set **slave latency > 0** in `update_conn_params` + a "data ready" notify characteristic (the CGM model). Lower wake latency, simpler app logic, but the radio stays in-connection (more device power than DARK). Default to windowed for the 150 mAh budget; keep this in reserve.

#### Button-to-wake (user-selectable, integrates with existing button mapping)
The on-demand trigger (#7) is a natural fit for the **already-shipped customizable button-mapping system** (`button_config_service` in firmware, `button_config_page.dart` in app ΓÇö maps None/Mute/Marker/Toggle-LED to single/double/triple tap and their holds, synced over the encrypted value-validated button-config characteristic). Add a **new "Wake for Sync" action** to that action set:
- Firmware: on the mapped gesture, `button.c` kicks the sync-window scheduler straight to SYNC WINDOW (open a connectable window now), regardless of cooldown.
- App: expose "Wake for Sync" as a selectable action in `button_config_page.dart`; **default to single tap**, but user-customizable exactly like every other mapping (open to making it single tap out of the box or fully user-selectable ΓÇö both are supported by the existing infra).
- Firmware must range-accept the new action value (the config char already rejects out-of-range actions ΓÇö bump the accepted enum).
- UX: foreground "Sync now" prompts "tap your Omi to sync now" when the device is DARK between windows.

#### Decoupling wake from sync (a connection is not a sync)
A device wake ΓÇö scheduled window *or* button combo ΓÇö only establishes a **connection**; the **app** then decides whether to pull data. Two clean concerns:
- **Device** = *make a connection possible*: open a window on its RTC cadence (config-char interval) + immediately on the button combo.
- **App** = *policy*: on each device-initiated connection, decide whether to sync.

The building block already exists: `_onStateRestored` runs `final due = _shouldSyncNow(); if (!due) return;` (`device_provider.dart:232`) ΓÇö "connection arrived, skip if not due." Generalize into a setting:
- **"Sync on every device wake"** ΓåÆ always pull whenever the device wakes/connects.
- **"Only when due"** ΓåÆ gate on the autosync interval (`_shouldSyncNow()`); an early wake connects, finds nothing due, and disconnects without transferring.

**Recommended semantics:** a *scheduled* window honors the setting (default "only when due"); a *button combo* is explicit user intent ΓåÆ **force-sync** (always pull), since the user tapped precisely to sync now. Make force the button's natural behavior; optionally expose the choice.

**Telling the two apart on connect.** The app can't receive the button event *before* it connects (the tap is what wakes it), so the reason can't arrive over Button char `0041` in time. Add a **"last wake reason" byte the app reads on connect** (scheduled / button / motion) ΓÇö a small new read char or folded into diagnostics `0061`; on `onDeviceReady` the app maps button ΓçÆ force-sync, scheduled ΓçÆ if-due. In `enabled=0`/always-connectable mode this is unneeded ΓÇö the device never goes dark, so a button tap arrives live over `0041` while connected and force-syncs directly.

**Battery note:** align the device's window cadence with the app's autosync interval (push via the config char) so early "connect-then-skip" cycles are rare; the if-due check mainly backstops button taps and edge timing ΓÇö a connect/disconnect with no transfer still costs a little device radio energy.

#### iOS app changes (the real payoff)
1. **Standing pending-connect** ΓÇö after routine sync/disconnect, **re-arm `centralManager.connect(peripheral, options:nil)`** instead of leaving it cancelled, so iOS holds it pending and wakes the app at the device's next window. Add a `standingConnect: Set<String>` alongside `manuallyDisconnected`; distinguish "Forget Device" (truly cancel) from "routine post-sync disconnect" (cancel link, re-arm pending connect). **Also re-arm on app launch** ΓÇö a user force-quit drops the OS-held pending connect, so re-issuing `connect()` at startup (iOS: `retrievePeripherals(withIdentifiers:)` with the saved device ID; Android: `connectGatt(autoConnect=true)` with the saved address) restores the wait that force-quit destroyed. Note this only re-arms the wait ΓÇö it can't connect a *dark* device until its next window or a button tap; for an immediate post-relaunch sync the user taps the button (or the staleness banner, #5).
2. **Routine disconnect Γëá terminal in Dart** ΓÇö post-sync (`device_provider.dart:884`) and pause-grace (`:996`) map to a new "disconnect-but-stay-armed" path (`disconnectKeepingPendingConnect`), not `unmanageDevice`. Only true unpair calls full `unmanageDevice`/`disconnectPeripheral`.
3. **Wake ΓåÆ sync** ΓÇö mostly there: the wake arrives as `didConnect` ΓåÆ `onDeviceReady` ΓåÆ `_handleDeviceConnected`; ensure the background drop-guard lets a device-initiated wake through (set pending-sync flag, as `_onBackgroundSyncRequested` does). `_onStateRestored` (`device_provider.dart:232`) already sanctions a due sync.
4. **Demote BGTaskScheduler to backstop** ΓÇö keep the `BGProcessing`/`BGAppRefresh` tasks (shipped 0.25.4) as the fallback for when pending-connect misses (notably after **user force-quit** ΓÇö iOS won't relaunch for BLE then).
5. **Foreground UX + staleness banner** ΓÇö surface the button-to-wake affordance since the device may be DARK on app open. Add a **"haven't synced in a while ΓÇö tap your Omi to sync" banner** that triggers after **N missed windows** (`now ΓêÆ lastSuccessfulSync ΓëÑ N ├ù interval`, with a floor so short intervals don't nag; suppressed in Manual-Only mode). It's the safety net for the irreducible cases ΓÇö force-quit dropped the standing connect, or the device was out of range ΓÇö proactively pointing the user at the button to realign instead of silently accumulating stale data. Tapping it re-arms the standing connect and prompts the physical tap. Generally useful even on `enabled=0`.

#### Cross-platform: why windowing is opt-in (and Android keeps the status quo)
It's **one device** ΓÇö the firmware can't be DARK for iOS yet always-connectable for Android at the same time; whichever phone is nearby sees the same advertising behavior. The two platforms want opposite things:
- **iOS** *gains* from DARK/window cycling (reliable background wake it otherwise lacks), and loses little on-demand connect (iOS has no good instant on-demand today anyway).
- **Android** *loses* from it: today the device is always connectable, so opening the app connects **instantly**, anytime. DARK between windows breaks that instant on-demand connect (you'd wait for the next window or tap Wake-for-Sync). Android is the platform with the *good* on-demand experience, so it has the most to lose ΓÇö and it doesn't need device-driven wake (FGS + exact alarm already wake it reliably).

Resolution: **windowing is the per-device `enabled` flag (#5 above), default OFF.** `enabled=0` = today's always-connectable behavior (instant on-demand connect, no tap, alarm-driven) ΓÇö **Android stays here ΓåÆ zero regression**. `enabled=1` = device-driven windows ΓÇö iOS opts in. Note: **scheduled** sync needs no tap on either mode (windows auto-connect via the pending-connect); only **immediate/on-demand** connect regresses under `enabled=1`, which is exactly what the Wake-for-Sync tap mitigates.

#### Android changes (none required ΓÇö stays on `enabled=0`)
Android keeps today's path entirely: always-connectable firmware, FGS + WorkManager + exact alarm wake, instant on-demand connect, no tap. The firmware windowing is inert for Android because the app never sets `enabled=1`. (If an Android user *wanted* device-driven cycling, `autoConnect=true` (`OmiBleForegroundService.kt:470`) would catch the windows the same way iOS does ΓÇö but there's no reason to, so leave it off.) **Do not** re-introduce `CompanionDeviceManager` presence observation ΓÇö this fork removed it due to OnePlus/Oppo/Realme connection wedges (0.24 changelog). Keep the alarm as the safety net.

#### Hard tradeoffs & risks
1. **On-demand connect regresses (only when `enabled=1`)** ΓÇö DARK between windows means no instant connect on app open; fully dependent on button/motion triggers + safety floor. Biggest UX risk ΓÇö but scoped to opted-in (iOS) devices; Android and opt-out users on `enabled=0` keep instant on-demand connect.
2. **iOS user force-quit kills background BLE wake** until next manual launch (iOS platform rule). BGTask backstop partially covers it; **re-arm-on-launch** restores the standing connect the moment the app reopens, and the **staleness banner** points the user at the button if data has piled up.
3. **iOS background-scan latency** ΓÇö window must be long + fast-advertising (ΓëÑ45ΓÇô60 s); too short ΓåÆ iOS misses it, too long ΓåÆ device power. Needs tuning + measurement.
4. **Mixed firmware/app versions** ΓÇö gate on the capability bit + safety floor so no combination bricks reachability.
5. **AAD refactor** touches a working, subtle thread ΓÇö regression-test VAD recording, SD pause/resume, marker durability.
6. **Must measure** ΓÇö put it on a Nordic PPK2: today's continuous-slow-adv vs DARK+window current draw, plus real-world iOS wake hit-rate (worn all day, app backgrounded). Don't ship on theory.

#### Phasing
- **Phase 1 ΓÇö Firmware:** dark state + window scheduler + config char + capability bit + button/motion triggers (incl. the "Wake for Sync" button action) + safety floor. Validate on PPK2 + manual nRF connect. Ship behind the capability bit.
- **Phase 2 ΓÇö iOS:** standing pending-connect (1ΓÇô3), routine-disconnect-keeps-armed, wakeΓåÆsync, BGTask demoted to backstop. Measure background wake hit-rate vs. the BGTask-only baseline.
- **Phase 3 ΓÇö Android (optional):** only if measurement shows a worthwhile phone-battery saving from relaxing the alarm cadence.

Highest-leverage cheap validation: **Phase 1 window scheduler + Phase 2 standing pending-connect**, measured against current BGTask reliability ΓÇö tells you whether device-driven wake is worth the full build-out before committing.

#### Relevant files
- `omi/firmware/omi/src/lib/core/transport.c` ΓÇö `idle_disconnect_work_handler` (15 s), `transport_set_adv_fast/slow` + `adv_param_slow`, `_transport_disconnected` (adv restart), `update_conn_params` (latency 0); add dark state + window scheduler.
- `omi/firmware/omi/src/aad.c` ΓÇö `adv_slow_req`/`adv_fast_req` writes (`:310,:330,:464`) and the apply loop (`:247-250`) to hand advertising ownership to the scheduler.
- `omi/firmware/omi/src/lib/core/settings.c` / `settings.h` ΓÇö persist the window config (mirror `app_settings_save_conn_fail`).
- `omi/firmware/omi/src/button.c` + button-config service (registered `transport.c:1810`) ΓÇö add the "Wake for Sync" action; kick the scheduler on the mapped gesture.
- `app/ios/Runner/OmiBleManager.swift` ΓÇö `manuallyDisconnected`/`disconnectPeripheral`/`didDisconnectPeripheral`/`willRestoreState`; add `standingConnect` + pending-connect re-arm.
- `app/ios/Runner/AppDelegate.swift` ΓÇö keep `BGProcessing`/`BGAppRefresh` as backstop.
- `app/lib/providers/device_provider.dart` ΓÇö `disconnectDevice(isManual:true)` sites (`:884`,`:996`), `_onStateRestored` (`:232`, already does the "skip if not due" gate to generalize), `_shouldSyncNow()`, `_onBackgroundSyncRequested` (`:208`); apply the wakeΓåÆpolicy decision (force vs if-due) on device-initiated connect.
- `app/lib/backend/preferences.dart` ΓÇö add the "sync on every device wake" vs "only when due" setting (alongside `backgroundSyncIntervalMinutes`).
- Firmware "last wake reason" ΓÇö expose a 1-byte read (scheduled/button/motion) via a new char or folded into diagnostics `0061` (`transport.c`), read by the app on `onDeviceReady` to pick force-sync vs if-due.
- `app/lib/services/devices/transports/native_ble_transport.dart` ΓÇö add `disconnectKeepingPendingConnect`; `app/lib/pigeon_interfaces.dart` for the new host API + the window-config write.
- `app/lib/pages/settings/button_config_page.dart` ΓÇö expose "Wake for Sync" as a selectable button action (default single tap).
- `app/lib/pages/settings/app_settings_page.dart` ΓÇö add the **Dark Mode** toggle (writes `enabled`); the existing "Auto Sync Interval" dropdown (15/30/60 / Manual Only, ~`:248`) already supplies the cadence ΓÇö Manual Only = button-only. The staleness banner lives wherever sync status surfaces (home/recordings).
- Android (phase 3, optional): `OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`.

---

## DEFERRED

### 8. iOS code signing & non-jailbroken distribution [medium] [Deferred]

The iOS build works end-to-end via CI (`.github/workflows/ios-build.yml`) and produces an **unsigned** dev IPA that installs on a **jailbroken** device (AppSync Unified / TrollStore ΓÇö current path for the iPhone 6s Plus). To run on a **stock** (non-jailbroken) iPhone, the IPA must be code-signed, which needs an Apple Developer account plus signing material wired into CI.

#### What it takes
- **Apple Developer Program ($99/yr)** ΓÇö required for a real signing certificate + provisioning profile. (A free Apple ID only does 7-day Xcode sideloading on a Mac, which headless CI can't drive.)
- **Signing secrets in GitHub Actions** ΓÇö distribution certificate (`.p12` + password) and a provisioning profile stored as encrypted repo secrets, imported into a temporary keychain on the runner (e.g. `apple-actions/import-codesign-certs`).
- **Build a signed IPA** ΓÇö replace the workflow's `flutter build ios --no-codesign` with `flutter build ipa` + an `ExportOptions.plist`: method `app-store` for TestFlight, or `ad-hoc` / `development` for direct install with the target device UDID registered in the profile.
- **Distribution**
  - **TestFlight** (cleanest ΓÇö no per-device UDID): upload via `xcrun altool`/`notarytool` or `apple-actions/upload-testflight-build`; install via the TestFlight app. No Mac needed locally.
  - **Ad-hoc**: register target device UDIDs in the profile; install the signed IPA directly (Apple Configurator / `ideviceinstaller`).

#### Why deferred
The jailbroken-device path (unsigned IPA, already working) covers the current 6s Plus for free. Signing only matters when targeting a non-jailbroken iPhone, and it carries an annual fee + secret management. Revisit if/when a stock-iOS device becomes a target.

#### Relevant files
- `.github/workflows/ios-build.yml` ΓÇö today: `flutter build ios --flavor dev --no-codesign` ΓåÆ zips `Payload/Runner.app` into an unsigned IPA. Signing adds a cert-import step, switches to `flutter build ipa`, and adds an upload/export step.
- Flavors (`app/flavorizr.yaml`): `dev` = `com.omi.offline.development`, `prod` = `com.omi.offline` ΓÇö the provisioning profile must be issued for whichever bundle id is shipped.
