# Omi Offline — BLE Issues & Fix Ideas

Findings from analysing the device logs of 2026-06-27 and a full code review of
[OmiBleManager.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt) and
[OmiBleForegroundService.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt).

---

## 1. Notifications stuck on "Connecting…"

### Problem

The foreground-service notification shows **"Connecting…"** and never transitions
back to idle. This happens when the Dart engine is frozen by Doze (or killed) while
a background sync connect attempt is in progress. The native
`setSyncStatus` in
[OmiBleForegroundService.kt:954-968](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt)
pushes the "Connecting…" text and arms a `CONNECT_SETTLE_MS` (160 s) exact alarm
via `SyncAlarmReceiver.scheduleSettle`. If Dart never resolves the connect (success
or failure), the notification stays stuck until either:

- The 160 s alarm fires and `settleStaleConnectingToIdle()` reverts it.
- Under deep Doze the alarm can be deferred to the OS's ~9 min throttle window,
  leaving the notification visibly stuck for minutes.

### Relevant files

| File | Lines | What it does |
|------|-------|-------------|
| `OmiBleForegroundService.kt` | 53 | `DEFAULT_NOTIF_TEXT = "Connecting..."` |
| `OmiBleForegroundService.kt` | 54-58 | `CONNECT_SETTLE_MS = 160_000L` — the watchdog timeout |
| `OmiBleForegroundService.kt` | 954-968 | `setSyncStatus` — arms the settle alarm when text starts with "Connecting" |
| `OmiBleForegroundService.kt` | 976-992 | `settleStaleConnectingToIdle` — reverts the notification |
| `SyncAlarmReceiver.kt` | — | Fires the exact alarm and calls `settleStaleConnectingToIdle` |

### Fix ideas

1. **Reduce `CONNECT_SETTLE_MS`** to something closer to the Dart connect-settle
   watchdog (currently 150 s on the Dart side) — e.g. 90–120 s — so the native
   fallback kicks in sooner.
2. **Use `AlarmManager.setExactAndAllowWhileIdle`** (it already may, but verify)
   so Doze doesn't batch it into the 9-min window.
3. **Push a native-side `onConnectionStateChange → STATE_DISCONNECTED`
   notification update** immediately when the GATT callback fires, instead of
   relying on Dart to update the notification text. This would catch the case
   where Dart is frozen but native callbacks still fire.

---

## 2. Partial sync completions

### Problem

Background syncs identify multiple WAL files to transfer (e.g. "getMissingWals
returned 4 WALs") but abort partway through because the Bluetooth connection
drops mid-transfer. The logs show this pattern repeatedly:

```
SDCardWalSync: deleting synced WAL from SD card: index=0 ts=1782589703  ← WAL 1 OK
SDCardWalSync: deleting synced WAL from SD card: index=0 ts=1782590304  ← WAL 2 OK
SDCardWalSync: deleting synced WAL from SD card: index=0 ts=1782590906  ← WAL 3 OK
[NativeBleTransport] C3:94:71:EA:A8:D5: disconnected (error=gatt_status_8 ...)  ← DROP
SDCardWalSync: Connection lost after failure, aborting syncAll  ← ABORT
```

The underlying cause is `gatt_status_8` (`GATT_CONN_TIMEOUT`) — the LE link
supervision timer expired, meaning the peripheral stopped sending LL keepalive
PDUs (or the radio channel was too degraded for them to be received).

A secondary cause visible in the logs is `Stream closed without EOT`
([OmiBleManager.kt:540](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt)),
which fires when `cleanupPeripheral` is called during an active
`StorageDownloadSession`. This is the symptom, not the cause — the transfer was
interrupted by the connection drop.

### Relevant files

| File | Lines | What it does |
|------|-------|-------------|
| `OmiBleManager.kt` | 522-541 | `cleanupPeripheral` — cancels active downloads with "Stream closed without EOT" |
| `OmiBleManager.kt` | 688-786 | `StorageDownloadSession` — the file transfer session |
| `OmiBleManager.kt` | 447-465 | Storage keepalive (0x32 every 15 s) — resets firmware's 30 s idle timer |
| `OmiBleForegroundService.kt` | 536-601 | `handleDisconnection` — cleanup on drop |

### Fix ideas

1. **Increase firmware LE supervision timeout.** The repeated `gatt_status_8`
   suggests the Zephyr LE connection supervision timeout may be too short
   (possibly 100–400 ms). Increasing it to 4–6 seconds
   (`CONFIG_BT_PERIPHERAL_PREF_TIMEOUT` or via a connection parameter update
   request) would tolerate brief RF interference without dropping the link.
   This is the single highest-impact fix.
2. **Request robust connection parameters from Android.** After connecting, the
   code calls `gatt.requestConnectionPriority(CONNECTION_PRIORITY_HIGH)`
   ([OmiBleManager.kt:589](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt)).
   `CONNECTION_PRIORITY_HIGH` requests a short interval (11.25–15 ms) which is
   great for throughput but increases sensitivity to RF interference.
   Consider switching to `CONNECTION_PRIORITY_BALANCED` during the transfer
   (30 ms interval, longer supervision timeout) — slower throughput but fewer
   drops.
3. **Resume-from-offset after reconnect.** The `StorageDownloadSession` already
   supports a `startOffset` parameter. If a transfer is interrupted, persist the
   last successfully written offset and resume from there on the next connection
   instead of re-downloading the entire file. The WAL sync loop already deletes
   successfully synced WALs, so partially transferred WALs are re-fetched — but
   they restart from offset 0.
4. **Reduce keepalive interval.** The storage keepalive is 15 s, but the firmware
   idle-disconnect timer is 30 s. If a keepalive write silently fails (e.g.
   Android flow control backs off), the firmware may time out. Consider reducing
   to 10 s for more margin.

---

## 3. Phone stops connecting to Omi (requires Bluetooth toggle)

### Problem

The logs show a connection attempt failing after the full 30 s timeout with
`gatt_status_8`, followed by repeated failed retries until the user toggled
Bluetooth:

```
23:28:24  manageDevice sent, waiting for device-ready (30s timeout)
23:28:29  not ready in 5s — starting BLE scan in parallel
23:28:39  ignoring transient GATT error during connect: gatt_status_-1
23:28:48  connect failed after 24410ms: gatt_status_8
```

This is the Android BLE stack getting into a **wedged state** where it believes
it has an active connection to the device (or has corrupted internal state for
that address) but cannot actually communicate over the air.

### Root causes (from code review)

#### A. Ghost-purge dummy GATT approach worsens the wedge

[OmiBleManager.kt:133-153](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt) (`purgeGhostGatts`) and
[OmiBleManager.kt:164-181](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt) (`purgeGhostGattForAddress`):

```kotlin
val dummyGatt = device.connectGatt(application, false,
    object : BluetoothGattCallback() {}, BluetoothDevice.TRANSPORT_LE)
dummyGatt?.disconnect()
dummyGatt?.close()
```

This creates a **second** GATT client for the same device, immediately disconnects
it, and closes it — all in the same main-looper pass. The intent is to flush a
stale OS-held link, but on many Android stacks (Samsung/Qualcomm especially) this
actually makes things worse:

- `connectGatt` tells the Bluetooth daemon to establish (or reuse) a connection.
- The immediate `disconnect()`/`close()` tears down the *app's client handle* but
  the daemon's internal connection-tracking may not decrement correctly when a
  client connects and disconnects within the same looper pass.
- The result is a daemon that holds the connection slot open with no app-side
  client to receive callbacks, creating exactly the ghost state we were trying
  to fix.

This is called both at startup (`purgeGhostGatts`, line 134) and during retry
logic (`purgeGhostGattForAddress`, called from
[OmiBleForegroundService.kt:706](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt)).

#### B. No `disconnect()` before `close()` in `connectGatt` pre-cleanup

[OmiBleManager.kt:263-268](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt):

```kotlin
connectedGatts[addr]?.let {
    Log.i(TAG, "Closing existing GATT for $addr before reconnecting")
    it.close()          // ← no disconnect() first
    connectedGatts.remove(addr)
}
```

If this GATT object represents a connection the OS still considers active (a stale
link), calling `close()` without `disconnect()` releases the app's client interface
but doesn't tell the daemon to tear down the radio-level link. The daemon keeps the
connection alive with no client listening. This is a minor defensive gap — it only
matters when a ghost link exists, and the code has the `purgeGhostGattForAddress`
mechanism to handle that case. But adding `it.disconnect()` before `it.close()`
is a free safety improvement.

The same pattern appears at [OmiBleForegroundService.kt:477](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):
```kotlin
if (bleManager.connectedGatts.containsKey(addr)) bleManager.closeGatt(addr)
```
This calls `closeGatt` (which does `refresh()` then `close()`) but not
`disconnectGatt` first. The guard on line 475 (`!bleManager.isPeripheralConnected(addr)`)
should mean the device is already disconnected, but `isPeripheralConnected` queries
`BluetoothManager.getConnectionState` which can lag behind reality on some stacks.

#### C. Rapid retry cycling with no exponential backoff

[OmiBleForegroundService.kt:40](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):
```kotlin
private const val RECONNECT_DELAY_MS = 1_500L
```

After every failed connection, the code waits only **1.5 seconds** before retrying.
There is no exponential backoff. This means after a `gatt_status_8` timeout
(which itself took 15–30 s), the code immediately:

1. Calls `disconnectGatt` + `closeGatt` (cleanup)
2. Waits 1.5 s
3. Optionally creates a dummy GATT for ghost purge, waits 500 ms
4. Calls `connectGatt` again

This rapid churn of GATT client registrations/teardowns is the **single most common
trigger** for the Android Bluetooth daemon's internal state machine to get wedged
on Samsung, Qualcomm, and MediaTek stacks. Each cycle allocates and frees a GATT
client interface in the daemon; when done repeatedly in quick succession, the
daemon's `ClientMap` can leak entries or corrupt its connection refcount.

#### D. `STATE_TURNING_OFF` and `STATE_OFF` both call `closeGatt` without `disconnectGatt`

[OmiBleForegroundService.kt:786-806](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):

In `STATE_TURNING_OFF`:
```kotlin
bleManager.closeGatt(addr)  // line 792 — no disconnectGatt first
```

In `STATE_OFF`:
```kotlin
bleManager.closeGatt(addr)  // line 803 — no disconnectGatt first
```

When Bluetooth is turning off, the OS is tearing down all links anyway, so this
is less impactful. But it means the code is not consistently calling
`disconnect()` before `close()` across all paths.

### Relevant files (full list)

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

### Fix ideas

1. **Replace the dummy-GATT ghost purge with a safer approach.**
   Instead of creating a new `connectGatt` and immediately tearing it down:
   - First try `BluetoothGatt.disconnect()` on the stale system link if you
     can obtain a handle to it.
   - If that doesn't work, the only reliable programmatic reset is
     `adapter.disable()` / `adapter.enable()` (requires `BLUETOOTH_CONNECT`
     permission on Android 12+). This is disruptive but is what "toggle
     Bluetooth" does manually.
   - If neither is acceptable, at minimum insert a delay (e.g. 500 ms)
     between `connectGatt` and `disconnect()`/`close()` on the dummy GATT
     to let the daemon's state machine settle.

2. **Add `disconnect()` before `close()` in all cleanup paths.**
   - [OmiBleManager.kt:266](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt):
     add `it.disconnect()` before `it.close()`.
   - [OmiBleForegroundService.kt:477](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):
     add `bleManager.disconnectGatt(addr)` before `bleManager.closeGatt(addr)`.
   - [OmiBleForegroundService.kt:792, 803](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt):
     add `bleManager.disconnectGatt(addr)` before `bleManager.closeGatt(addr)` in
     both `STATE_TURNING_OFF` and `STATE_OFF` branches.

3. **Add exponential backoff to retry logic.**
   Replace the fixed 1.5 s delay with exponential backoff:
   ```kotlin
   val delay = min(RECONNECT_DELAY_MS * (1L shl min(managed.retryCount, 5)), 30_000L)
   ```
   This gives: 1.5 s → 3 s → 6 s → 12 s → 24 s → 30 s (capped).
   Dramatically reduces GATT client churn that triggers daemon wedges.

4. **Increase firmware LE supervision timeout.** If the Zephyr config uses
   the default or a low supervision timeout, increase it to 4–6 s
   (`CONFIG_BT_PERIPHERAL_PREF_TIMEOUT` in `prj.conf`, value in units of
   10 ms, so 400–600). This is the highest-impact fix for the
   `gatt_status_8` disconnects that cascade into all three problems.

---

## Summary of impact

| Fix | Addresses | Impact |
|-----|-----------|--------|
| Firmware supervision timeout increase | Partial syncs, BT wedge | **Highest** — prevents the disconnects that cause everything else |
| Exponential backoff on retries | BT wedge | **High** — stops the GATT client churn that wedges the daemon |
| Replace dummy-GATT ghost purge | BT wedge | **High** — removes a mechanism that actively worsens the wedge |
| Add `disconnect()` before `close()` everywhere | BT wedge | **Low-Medium** — defensive improvement, narrow edge case |
| Reduce / improve settle alarm for notification | Stuck notifications | **Medium** — UX improvement |
| Connection parameter tuning during transfer | Partial syncs | **Medium** — trades throughput for reliability |
