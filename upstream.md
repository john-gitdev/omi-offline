# Upstream Tracking

Tracks changes from [BasedHardware/omi](https://github.com/BasedHardware/omi) that have been assessed and applied to this project.

---

## Applied

### BasedHardware/omi#6067 — Android BLE connect race condition (status=5)
**Date applied:** 2026-03-28
**Upstream PR:** https://github.com/BasedHardware/omi/pull/6067

**Problem:** Three callers (Dart `ensureConnection`, `OmiBleForegroundService` startup, `BleCompanionService.deviceAppeared`) raced to call `connectPeripheral` within milliseconds of each other. Each call closed the previous in-flight GATT connection, corrupting the encryption handshake and producing `status=5` (GATT_INSUFFICIENT_AUTHENTICATION). The code treated status=5 as non-retryable, so the connection was permanently abandoned.

**Changes applied:**

| File | Change |
|------|--------|
| `OmiBleManager.kt` | Added `connectingAddresses` set — 2nd/3rd concurrent callers are skipped while a connect is already in-flight |
| `OmiBleManager.kt` | Added `cancelPendingReconnect()` at start of `connectPeripheral` — cancels any delayed reconnect runnable before opening a new connection |
| `OmiBleManager.kt` | `connectingAddresses.remove()` in both `STATE_CONNECTED` and `STATE_DISCONNECTED` branches of `onConnectionStateChange` |
| `OmiBleManager.kt` | Status=5 handling — detects stale bond, calls `removeBond()` via reflection, retries after `RECONNECT_DELAY_MS` |
| `OmiBleManager.kt` | `removeBond()` helper wrapping the hidden API call |
| `OmiBleManager.kt` | RSSI keepalive deferred from `STATE_CONNECTED` to after `onServicesDiscovered` — reduces BLE traffic during security handshake |
| `OmiBleManager.kt` | `caller: String` parameter on `connectPeripheral` for log traceability |
| `OmiBleForegroundService.kt` | `connectToDevice` forwards `caller` to `connectPeripheral` |
| `BleHostApiImpl.kt` | Tags Dart-side calls with `caller = "Dart"` |

**Already present (no changes needed):**
- Caller tags in `BleCompanionService.kt`
- Caller tag in `MainActivity.onActivityResult`
- `caller` param in `OmiBleForegroundService.startService()`
