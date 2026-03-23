# LittleFS Migration Review — Production-Level Audit

**Reviewer:** Claude (automated deep review)
**Date:** 2026-03-23
**Scope:** `sd_card.c`, `storage.c`, `transport.c`, `sdcard_wal_sync.dart`, `storage_file.dart`, Kconfig, NOMENCLATURE.md alignment

---

## CRITICAL ISSUES

### C1. Compile Error — Undefined Variable `elapsed` in `sd_update_filename_after_timesync()`

**File:** `sd_card.c:1045`

```c
LOG_INF("Rename: %s -> %s (elapsed=%u ms)", current_filename, new_filename, elapsed);
```

The variable `elapsed` does not exist. The local variables are `elapsed_ms` (int64_t) and `elapsed_s` (uint32_t). This is a **build-breaking bug** (or a silent format-string UB if the compiler doesn't catch it).

**Fix:**
```c
LOG_INF("Rename: %s -> %s (elapsed=%u ms)", current_filename, new_filename, (unsigned)elapsed_ms);
```

---

### C2. Directory Iteration While Deleting — Undefined Behavior in `clear_audio_directory`

**File:** `sd_card.c:1380-1389`

```c
if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) == 0) {
    while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
        if (info.type != LFS_TYPE_REG)
            continue;
        build_file_path(info.name, fpath, sizeof(fpath));
        int rm = lfs_remove(&lfs_fs, fpath);  // ← modifies directory DURING iteration
    }
    lfs_dir_close(&lfs_fs, &dir);
}
```

**LittleFS explicitly documents** that `lfs_remove()` during `lfs_dir_read()` iteration is **undefined behavior**. Unlike FATFS (which had predictable iteration due to linear directory tables), LittleFS uses a CTZ skip-list for directories. Removing an entry can restructure metadata blocks, causing `lfs_dir_read()` to skip files or re-read already-deleted entries.

**Failure scenario:** Calling "nuke storage" leaves files behind. The user thinks data is cleared, but ghost files persist and confuse the next sync.

**Fix:** Collect filenames into an array first, close the directory, then delete:
```c
char names[MAX_AUDIO_FILES][MAX_FILENAME_LEN];
int count = 0;
// Phase 1: collect
while (lfs_dir_read(...) > 0) {
    if (info.type == LFS_TYPE_REG && count < MAX_AUDIO_FILES) {
        strncpy(names[count++], info.name, MAX_FILENAME_LEN - 1);
    }
}
lfs_dir_close(&lfs_fs, &dir);
// Phase 2: delete
for (int i = 0; i < count; i++) {
    build_file_path(names[i], fpath, sizeof(fpath));
    lfs_remove(&lfs_fs, fpath);
}
```

---

### C3. `CONFIG_FAT_FILESYSTEM_ELM=y` Still Enabled — Wastes ~20-30 KB Flash + RAM

**File:** `omi.conf:324`

```
CONFIG_FAT_FILESYSTEM_ELM=y
```

LittleFS is used directly via `<lfs.h>` (no Zephyr VFS layer). FATFS is no longer referenced anywhere in the code. This pulls in the entire ELM FatFs library (heap allocation, sector buffers, code text) for nothing.

Also still enabled: `CONFIG_FS_FATFS_MOUNT_MKFS=y` (line 326) and `CONFIG_FILE_SYSTEM_MKFS=y` (line 54).

**Fix:** Remove all FATFS-related config lines:
```
# Remove these:
CONFIG_FAT_FILESYSTEM_ELM=y
CONFIG_FS_FATFS_MOUNT_MKFS=y
CONFIG_FILE_SYSTEM_MKFS=y
CONFIG_FS_FATFS_MKFS=y
```

---

## SUBTLE BUGS / EDGE CASES

### S1. Stale File Index After Auto-Delete in `storage.c`

**File:** `storage.c:641-657` (auto-delete after transfer) and `storage.c:308-327` (setup_file_transfer)

After a file transfer completes, the storage thread auto-deletes the synced file and calls `refresh_file_list_cache()` from `delete_file_by_index()`. However, the app still holds the **old file index mapping** from the original `CMD_LIST_FILES` response.

**Failure scenario:**
1. App lists files: `[0]=old.txt, [1]=middle.txt, [2]=newest.txt`
2. App requests file 0 → firmware transfers and auto-deletes `old.txt`
3. Internal `sync_file_list` refreshes to `[0]=middle.txt, [1]=newest.txt`
4. App requests file 1 (meaning `middle.txt`) → firmware serves `newest.txt`
5. App deletes file 1 (meaning `middle.txt`) → firmware deletes `newest.txt`

**Impact:** Data loss — the wrong file gets deleted.

**Fix:** After auto-delete, the firmware should NOT silently refresh the file list. Instead, the app should be required to re-issue `CMD_LIST_FILES` before operating on new indices. Document this as a protocol invariant. Or better: stop auto-deleting, let the app control deletion.

---

### S2. `file_index` Type Mismatch: `uint8_t` vs `int8_t`

**File:** `storage.c:374` vs `storage.c:55`

```c
uint8_t file_index = ((uint8_t *) buf)[1];  // line 374, CMD_READ_FILE
```
vs.
```c
static int8_t delete_file_index = -1;       // line 55, signed
```

When `CMD_DELETE_FILE` sets `delete_file_index = file_index` (line 411), the `uint8_t` value 128-255 gets implicitly converted to a negative `int8_t`, making the `idx >= sync_file_count` check (line 597) always fail for indices ≥128. Since `MAX_AUDIO_FILES=100`, this is technically unreachable, but it's a latent bug if the cap ever increases.

---

### S3. Race Between `sd_notify_time_synced()` and Write Queue

**File:** `sd_card.c:1647-1658`

```c
void sd_notify_time_synced(uint32_t utc_time)
{
    pending_time_synced_utc = utc_time;       // ← non-atomic write
    atomic_set(&pending_time_synced, 1);
```

`pending_time_synced_utc` is a plain `uint32_t` written from the system workqueue thread (via `rtc_persist_work_handler`) while the SD worker thread reads it at line 1229:

```c
req.u.time_synced.utc_time = pending_time_synced_utc;
```

On ARM Cortex-M4, 32-bit aligned writes are atomic, so this is **safe in practice** on nRF52840. But it's fragile — if this code ever runs on a platform with non-atomic 32-bit stores, or if the compiler reorders the two stores, the worker could see a stale `utc_time` with `pending_time_synced=1`.

**Fix:** Use `atomic_t` or a mutex, or document the ARM atomicity assumption.

---

### S4. App Frame Parsing Assumes Single-Byte Length Prefix on SD

**File:** `sdcard_wal_sync.dart:499-526`

```dart
int packageSize = streamBuffer[0];  // single byte!
```

The stream parser reads the **first byte** of `streamBuffer` as the frame length. This means frame sizes are capped at 255 bytes. The NOMENCLATURE.md and CLAUDE.md state Opus frames are 80 bytes (codec 20) or 40 bytes (codec 21), so this works for current codecs.

However, the `_flushToDisk` method writes a **4-byte LE length prefix** per frame (lines 276-279):
```dart
builder.addByte(len & 0xFF);
builder.addByte((len >> 8) & 0xFF);
builder.addByte((len >> 16) & 0xFF);
builder.addByte((len >> 24) & 0xFF);
```

This is a **format mismatch**: the SD card stores raw frames with a 1-byte type/length prefix (firmware writes `[len_byte][opus_data]`), but `_flushToDisk` writes `.bin` files with a 4-byte LE length prefix. If a future codec produces frames >255 bytes, the 1-byte stream parser will silently corrupt data.

**Note:** For marker packets (0xFE = 254), the parser correctly handles this as a special case. But value 255 is treated as a normal frame, which conflicts with the old protocol's 255-byte metadata frame convention noted in CLAUDE.md.

---

### S5. Deferred TMP Rename During BLE Connection Can Delay Sync

**File:** `sd_card.c:1525-1533`

```c
if (ble_connected) {
    deferred_timesync_rename_pending = true;
    deferred_timesync_utc_time = req.u.time_synced.utc_time;
    LOG_INF("[SD_WORK] Deferring TMP rename while BLE connected");
}
```

When the app connects via BLE, time sync fires immediately. But the rename is deferred until BLE **disconnects** (line 1681). This means the file list returned to the app contains `TMP_*.txt` files, which sort last (UINT32_MAX) and have timestamp=0.

**Impact:** The app's `_buildWalsFromFiles` skips files with `timestamp < 946684800` (kMinValidEpoch), but `strtoul("TMP_...", NULL, 16)` returns 0, which is < kMinValidEpoch. So TMP files **are never synced** while BLE is connected — they're invisible until the next connect-disconnect-connect cycle.

**Fix:** Either rename immediately (the close+rename+reopen is safe since only the worker thread touches the file), or have the firmware report TMP files with a computed correct timestamp so the app can sync them.

---

## INTEGRATION RISKS

### I1. Big-Endian Timestamp in File List vs. Little-Endian Everywhere Else

**File:** `storage.c:287-298` (send_file_list_response)

```c
storage_buffer[resp_len++] = (timestamp >> 24) & 0xFF;  // Big-endian!
storage_buffer[resp_len++] = (timestamp >> 16) & 0xFF;
storage_buffer[resp_len++] = (timestamp >> 8) & 0xFF;
storage_buffer[resp_len++] = timestamp & 0xFF;
```

The file list sends timestamps and sizes in **big-endian** format. But every other part of the BLE protocol (PACKET_DATA offsets, CMD_READ_FILE offsets, time sync) uses **little-endian**.

**Risk:** This inconsistency is likely handled correctly in the current app-side parser (`connection.listFiles()`), but any new code or third-party tool that assumes the "standard" LE convention will misparse timestamps. This should be documented in the BLE protocol spec.

---

### I2. File Count Byte Limits List to 255 Files

**File:** `storage.c:284`

```c
storage_buffer[resp_len++] = (uint8_t)sync_file_count;
```

The file count is a single byte, capping the visible list at 255 files. `MAX_AUDIO_FILES=100` keeps this safe today, but if the cap increases or files accumulate (e.g., many short recordings), the count wraps silently.

---

### I3. `_countFramesInFile` Uses 4-Byte LE Prefix — Must Match `_flushToDisk`

**File:** `sdcard_wal_sync.dart:902-917`

The frame counter reads 4-byte LE length prefixes from `.bin` files. This correctly matches `_flushToDisk` (which writes 4-byte LE prefixes). But this format is **different from the raw SD card format** (1-byte prefix). If anyone ever reads `.bin` files expecting raw SD format, they'll get garbage.

**Recommendation:** Document the `.bin` file format explicitly: `[uint32_LE length][payload][uint32_LE length][payload]...`

---

### I4. No Backward Compatibility Path for Existing FATFS Data

The migration auto-formats the SD card on first mount (`lfs_mount` fails → `lfs_format` → `lfs_mount`). Any recordings stored under the old FATFS filesystem are silently destroyed.

**Recommendation:** If devices already deployed in the field have unretrieved FATFS data, document this as a known breaking change. Consider logging a warning or requiring an explicit user action before formatting.

---

## PERFORMANCE CONCERNS

### P1. `lfs_fs_gc()` Pre-Warm Can Take 10-50+ Seconds

**File:** `sd_card.c:1159-1171`

The boot sequence calls `lfs_fs_gc()` to pre-warm the allocator. With 200+ MB of data and SPI SD, this traverses every block and can take **tens of seconds**. During this time, audio frames are silently dropped (`sd_boot_ready=0`).

This is a correct design choice (better than stalling the real-time write path), but the user loses the first 10-50 seconds of audio after every reboot. Consider:
- Persisting the allocator state (lookahead bitmap) to NVS across reboots
- Starting with a smaller lookahead scan and expanding lazily

---

### P2. Insertion Sort for File List — O(n²)

**File:** `sd_card.c:894-908`

The `sort_cached_file_entries()` uses insertion sort, which is O(n²). With MAX_AUDIO_FILES=100, worst case is 10,000 string comparisons × strtoul() each. This runs on the SD worker thread and blocks audio writes.

Not critical at 100 files, but worth noting.

---

### P3. `lfs_fs_size()` Called on Every File Cache Refresh

**File:** `sd_card.c:1004`

```c
lfs_ssize_t used_blocks = lfs_fs_size(&lfs_fs);
```

`lfs_fs_size()` traverses the entire filesystem to count used blocks — it's O(total_files × average_file_blocks). This runs on every `refresh_file_cache()`, which is called on every `CMD_LIST_FILES` and after every delete.

**Recommendation:** Cache the free-space value and only recompute on file create/delete, not on every list request.

---

## NOMENCLATURE ALIGNMENT

### N1. `chunk` Used Extensively in storage.c

**NOMENCLATURE.md §6:** *"chunk" and "bin" are forbidden in code and comments.*

`storage.c` uses `chunk` as a local variable name in multiple places (lines 241, 242, 515, 524, 526, 543, 544, 545, 546) and defines `STORAGE_CHUNK_COUNT` (line 178). Similarly, `sd_card.c` uses `chunk` in the disk I/O callbacks (lines 117-122, 146-153).

**Assessment:** The disk I/O callbacks are low-level infrastructure where `chunk` means "byte range" not "audio segment" — this is arguably acceptable. But `STORAGE_CHUNK_COUNT` in storage.c directly relates to audio transfer batching and should be renamed per nomenclature rules.

**Fix:** Rename `STORAGE_CHUNK_COUNT` → `STORAGE_BATCH_COUNT` or `BLE_BATCH_PACKETS` (the latter already exists at line 461 as a different constant with value 20, creating confusion).

---

### N2. `ble_packet_index` Missing from Code

**NOMENCLATURE.md §7** documents `ble_packet_index` in `storage.c`, but grep finds no such variable. The transport uses `current_package_index` (transport.c:55) and the storage thread doesn't track packet indices at all. The nomenclature table is stale.

---

### N3. `current_package_index` Should Be `current_packet_index`

**File:** `transport.c:55`

```c
uint16_t current_package_index = 0;
```

NOMENCLATURE.md uses "packet" not "package". This variable should be `current_packet_index`.

---

## RECOMMENDED FIXES (Priority Order)

| # | Severity | Fix | File(s) |
|---|----------|-----|---------|
| C1 | **Build-breaking** | Change `elapsed` → `(unsigned)elapsed_ms` | sd_card.c:1045 |
| C2 | **Data loss** | Two-phase collect-then-delete for directory clear | sd_card.c:1380-1389 |
| C3 | **Wasted resources** | Remove `CONFIG_FAT_FILESYSTEM_ELM=y` and related | omi.conf |
| S1 | **Data loss** | Don't auto-delete; or invalidate app's file index cache after delete | storage.c:641-657 |
| S5 | **Sync regression** | Don't defer TMP rename while BLE connected, or expose computed timestamp | sd_card.c:1525 |
| I1 | **Protocol debt** | Document BE timestamps in file list as intentional deviation | storage.c:287-298 |
| I4 | **Field upgrade** | Log explicit warning when formatting over existing FS | sd_card.c:511-524 |
| N1 | **Nomenclature** | Rename `STORAGE_CHUNK_COUNT` | storage.c:178 |
| N3 | **Nomenclature** | Rename `current_package_index` → `current_packet_index` | transport.c:55 |
| P3 | **Performance** | Cache `lfs_fs_size()` separately from file list refresh | sd_card.c:1004 |

---

## SUMMARY

The LittleFS migration is architecturally sound. The copy-on-write metadata and power-loss safety of LittleFS are a significant improvement over FATFS's dirty-bit problem. The batch write buffer, persistent read handle, and priority queue design are well-thought-out optimizations.

**The two most dangerous issues are:**
1. **C2 (delete during iteration)** — will silently leave files behind on "nuke" operations
2. **S1 (stale file index after auto-delete)** — can cause the wrong file to be deleted, losing audio data

Both are LittleFS-specific behaviors that didn't exist under FATFS and represent the most likely production regressions from this migration.
