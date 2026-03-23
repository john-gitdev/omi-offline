# Notes

Running log of investigated bugs, deferred decisions, and findings that don't fit TODO or README.

---

## Upstream Comparison: `BasedHardware/omi` feat/auto-offline-sync

Reviewed diff at `BasedHardware/omi/compare/main...feat/auto-offline-sync`.

### What upstream adds
- `StorageSyncImpl` — new sync class for a LittleFS multi-file firmware variant (different from ours)
- `onOfflineDataDetected` callback in `DeviceProvider` — auto-triggers sync on connect
- `hasFilesToSync()` — lightweight pre-check before committing to a full sync
- Phase 0 orchestration in `WalSyncs` — runs storage sync before SD card sync

### Status
- **Auto-sync on connect** — already implemented. `_onDeviceConnected` → `_doBackgroundSync()` (`device_provider.dart:519-520`).
- **`hasFilesToSync()`** — implemented (`sdcard_wal_sync.dart`, `wal_interfaces.dart`).
- **Phase 0 / new LittleFS firmware** — upstream targets a *different* firmware variant using big-endian file list encoding. Our firmware uses little-endian and already implements the same CMD_LIST_FILES (0x10) / CMD_READ_FILE (0x11) / CMD_DELETE_FILE (0x12) protocol. No action needed.
- **Wall-clock timeouts** — upstream uses a 10s inactivity + 5min total timeout with a flag-only cancel. We intentionally use graceful cancel + CMD_STOP for data integrity. Not adopting.
- **StorageStatus** — see TODO.md.

### Things NOT adopted and why
| Feature | Reason |
|---------|--------|
| Big-endian file list parsing | Wrong firmware — ours is LE |
| Drop `walOffset` resume | Regression — upstream has no resume on disconnect |
| Drop gap detection / frame validation | Regression |
| Flag-only cancellation | Inferior to CMD_STOP + graceful drain |
| `_registerWithLocalSync` cloud coupling | Breaks offline-first architecture |

---

## Bug Report Review (reported externally, verified against source)

### 🔴 #1 — Command Overwrite Race Condition (`storage.c`) — NOT ACTIONABLE

**Claim:** `delete_file_index` and `list_files_requested` are plain globals; rapid back-to-back BLE writes could overwrite the first command before the storage thread processes it.

**Reality:** Structurally valid, but unreachable in practice. The app protocol is synchronous — every command awaits `PACKET_ACK` before issuing the next (`performDeleteFile()` in `omi_connection.dart` awaits ACK; `performListFiles()` awaits the full response). Only relevant if pipelined/parallel BLE writes are ever introduced.

---

### 🔴 #2 — Mangled Syntax in `storage_write()` — FABRICATED

**Claim:** Dangling `else if (is_recording_file)` blocks and orphaned braces in the `remaining_length == 0` path.

**Reality:** Checked `storage.c:565-668`. Code is syntactically clean. This bug does not exist in the source.

---

### 🟡 #3 — File List Hard Limit Truncation (255 files) — REAL BUT MASKED

**Claim:** CMD_LIST_FILES uses a 1-byte count field, capping the response at 255 files.

**Reality:** True, but `MAX_AUDIO_FILES` in `sd_card.h` is 100. The firmware can never produce more than 100 files regardless, so the 255 protocol limit is never reached. **Annotated in source:**
- `omi/firmware/omi/src/lib/core/sd_card.h:12` — comment on `MAX_AUDIO_FILES`
- `omi/firmware/omi/src/lib/core/storage.c:284` — comment on `reported_count`

**Action needed if:** `MAX_AUDIO_FILES` is ever raised above 255. If that happens, files beyond 255 become invisible to the app and accumulate unsynced on the SD card.

---

### 🟡 #4 — MTU Underflow in `get_ble_chunk_size()` — INVALID

**Claim:** Subtracting 5-byte protocol overhead from small MTU values could underflow or produce 1–2 byte chunks.

**Reality:** Explicitly guarded. `if (mtu <= 3) return 20` and `if (att_payload <= protocol_overhead + 8) return 20` prevent any underflow or pathologically small chunk. Would require MTU < 17 to produce a chunk < 9 bytes, which is below the BLE spec minimum of 23.

---

### 🟢 #5 — Hardcoded Intel Sample UUID — REAL COMMENT, NOT A BUG

**Claim:** `transport.c` has a TODO to replace `19B10000-E8F2-537E-4F6C-D104768A1214` with `814b9b7c-25fd-4acd-8604-d28877beee6d`.

**Reality:** TODO comment confirmed at `transport.c:119-120`. However this UUID is now the published Omi protocol UUID used across all firmware and apps. Changing it is a breaking protocol change requiring coordinated firmware + app releases. Not a bug.

---

### 🟢 #6 — Time Sync Precision Drift — REAL, INCONSEQUENTIAL

**Claim:** Time sync uses u32 epoch seconds with no millisecond component, introducing up to 999ms of timestamp drift.

**Reality:** True. The sync writes `(uint32_t)(DateTime.now().millisecondsSinceEpoch / 1000)` — second-level precision only. For voice recording where sessions last minutes and are segmented by silence detection, sub-second alignment doesn't matter. Only relevant if precise sub-second cross-device alignment becomes a requirement.
