# LittleFS Migration — Bug Fixes

Actionable fix instructions for every issue found in the migration review.
Each section contains the exact code to change, the file and line numbers, and a before/after diff.

---

## CRITICAL FIXES

### C1. Compile Error — Undefined Variable `elapsed`

**File:** `omi/firmware/omi/src/sd_card.c:1045`
**Severity:** Build-breaking
**Root cause:** `elapsed` was never declared; the correct local is `elapsed_ms`.

#### Before
```c
LOG_INF("Rename: %s -> %s (elapsed=%u ms)", current_filename, new_filename, elapsed);
```

#### After
```c
LOG_INF("Rename: %s -> %s (elapsed=%lld ms)", current_filename, new_filename, elapsed_ms);
```

**Why `%lld`:** `elapsed_ms` is `int64_t`. Using `%u` would silently truncate on 64-bit values. Zephyr's `LOG_INF` supports `%lld` via `CONFIG_CBPRINTF_FP_SUPPORT=y` (already enabled in `omi.conf`).

---

### C2. Directory Iteration While Deleting — Undefined Behavior

**File:** `omi/firmware/omi/src/sd_card.c:1376-1390` (inside `REQ_CLEAR_AUDIO_DIR` case)
**Severity:** Data loss (silent incomplete wipe)
**Root cause:** LittleFS forbids `lfs_remove()` during `lfs_dir_read()` — the CTZ skip-list metadata is mutated mid-iteration, causing skipped entries.

#### Before
```c
if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) == 0) {
    while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
        if (info.type != LFS_TYPE_REG)
            continue;
        build_file_path(info.name, fpath, sizeof(fpath));
        int rm = lfs_remove(&lfs_fs, fpath);
        if (rm < 0)
            LOG_ERR("[SD_WORK] rm %s: %d", fpath, rm);
    }
    lfs_dir_close(&lfs_fs, &dir);
}
```

#### After
```c
{
    /* Two-phase delete: LittleFS forbids lfs_remove() during
     * lfs_dir_read() — the directory metadata is a CTZ skip-list
     * and removing an entry mid-iteration causes undefined behavior
     * (skipped files, double-reads, or corruption). */
    char del_names[MAX_AUDIO_FILES][MAX_FILENAME_LEN];
    int del_count = 0;

    /* Phase 1: collect filenames */
    if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) == 0) {
        while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
            if (info.type != LFS_TYPE_REG)
                continue;
            if (del_count < MAX_AUDIO_FILES) {
                strncpy(del_names[del_count], info.name,
                        MAX_FILENAME_LEN - 1);
                del_names[del_count][MAX_FILENAME_LEN - 1] = '\0';
                del_count++;
            }
        }
        lfs_dir_close(&lfs_fs, &dir);
    }

    /* Phase 2: delete after directory handle is closed */
    for (int i = 0; i < del_count; i++) {
        build_file_path(del_names[i], fpath, sizeof(fpath));
        int rm = lfs_remove(&lfs_fs, fpath);
        if (rm < 0)
            LOG_ERR("[SD_WORK] rm %s: %d", fpath, rm);
    }
}
```

**Stack impact:** `MAX_AUDIO_FILES=100` × `MAX_FILENAME_LEN=64` = 6400 bytes on worker stack. Worker stack is 16384 bytes — sufficient. If stack is a concern, use the existing `cached_file_names[]` static array (but invalidate it after).

---

### C3. Remove Dead FATFS Configuration

**File:** `omi/firmware/omi/omi.conf`
**Severity:** Wasted ~20-30 KB flash + RAM
**Root cause:** The FATFS Kconfig symbols were not removed during migration.

#### Lines to delete

| Line | Content | Why remove |
|------|---------|------------|
| 54 | `CONFIG_FILE_SYSTEM_MKFS=y` | Only needed for `fs_mkfs()` VFS API — LittleFS uses `lfs_format()` directly |
| 55 | `CONFIG_FS_FATFS_MKFS=y` | ELM FatFs mkfs support — dead code |
| 324 | `CONFIG_FAT_FILESYSTEM_ELM=y` | Pulls in entire ELM FatFs library |
| 326 | `CONFIG_FS_FATFS_MOUNT_MKFS=y` | Auto-format on failed FAT mount — dead code |

#### After cleanup
The filesystem section should read:
```
# file system
CONFIG_FILE_SYSTEM=y

CONFIG_DISK_ACCESS=y
CONFIG_DISK_DRIVER_SDMMC=y
```

**Verification:** After removing, rebuild and confirm no linker errors related to `ff_*` or `fs_*` symbols. The sd_card.c code uses `<lfs.h>` directly and never calls Zephyr VFS functions.

---

## SUBTLE BUG FIXES

### S1. Stale File Index After Auto-Delete — Data Loss Risk

**File:** `omi/firmware/omi/src/lib/core/storage.c:641-657`
**Severity:** Wrong file gets deleted = data loss

#### Root cause
After transferring a file, the firmware auto-deletes it and internally refreshes its file list (`sync_file_list[]`). The indices shift. But the app still holds the old index mapping from the last `CMD_LIST_FILES` response.

#### Option A: Remove auto-delete (recommended)

Delete the entire auto-delete block in `storage_write()` (lines 641-657):

```c
// REMOVE THIS BLOCK:
/* Auto-delete after successful multi-file sync. */
{
    bool is_recording_file = sd_is_current_recording_file(current_read_filename);
    if (!is_recording_file && current_read_filename[0] != '\0') {
        LOG_INF("Auto-delete synced file: %s", current_read_filename);
        int del_ret = delete_audio_file(current_read_filename);
        // ...
    }
}
```

The app already sends `CMD_DELETE_FILE` after successful sync (`deleteWal()` in `sdcard_wal_sync.dart:755`). Let the app own deletion — it knows its own index state.

#### Option B: Invalidate indices after auto-delete

If auto-delete must stay, reset `sync_file_count = 0` after the delete to force the app to re-list:

```c
if (del_ret == 0) {
    sync_file_count = 0;  /* Force app to re-issue CMD_LIST_FILES */
}
```

And document in the protocol spec that indices are invalid after any EOT.

---

### S2. `delete_file_index` Type Mismatch

**File:** `omi/firmware/omi/src/lib/core/storage.c:55`
**Severity:** Latent (currently unreachable due to MAX_AUDIO_FILES=100)

#### Before
```c
static int8_t delete_file_index = -1;
```

#### After
```c
static int16_t delete_file_index = -1;
```

Also update the assignment at line 588:
```c
int16_t idx = delete_file_index;
```

**Why `int16_t`:** Needs to hold -1 (sentinel) plus values 0-255 (uint8_t from BLE). `int8_t` can only hold -128 to 127. `int16_t` covers the full range with room to spare.

---

### S3. Non-Atomic `pending_time_synced_utc` Write

**File:** `omi/firmware/omi/src/sd_card.c:1647-1648`
**Severity:** Fragile (safe on ARM Cortex-M4, unsafe on other platforms)

#### Before
```c
void sd_notify_time_synced(uint32_t utc_time)
{
    pending_time_synced_utc = utc_time;
    atomic_set(&pending_time_synced, 1);
```

#### After
```c
void sd_notify_time_synced(uint32_t utc_time)
{
    /* Store value before flag — the atomic_set provides a release barrier
     * that ensures pending_time_synced_utc is visible to the worker thread
     * when it sees pending_time_synced == 1. */
    pending_time_synced_utc = utc_time;
    compiler_barrier();  /* Prevent compiler from reordering past atomic_set */
    atomic_set(&pending_time_synced, 1);
```

Alternatively, change `pending_time_synced_utc` to `atomic_t`:
```c
static atomic_t pending_time_synced_utc_atomic = ATOMIC_INIT(0);
```

---

### S4. Single-Byte Frame Length Cap in Stream Parser

**File:** `app/lib/services/wals/sdcard_wal_sync.dart:499-500`
**Severity:** Future codec regression (safe for current Opus codecs)

#### Before
```dart
int packageSize = streamBuffer[0];
```

#### After
No code change needed for current codecs (max 80 bytes). But add a defensive assertion and a comment:

```dart
int packageSize = streamBuffer[0];

// INVARIANT: Opus frames are ≤ 80 bytes (codec 20) or ≤ 40 bytes (codec 21).
// The firmware's raw SD format uses a 1-byte length prefix per frame.
// If a future codec produces frames > 253 bytes, this parser MUST be updated
// to use a multi-byte length prefix (and the firmware format must change too).
// Values 254 and 255 are reserved: 254 = marker, 255 = metadata.
assert(packageSize <= 253 || packageSize == 254,
    'Frame length $packageSize exceeds single-byte protocol limit');
```

---

### S5. TMP Files Invisible During BLE Sync

**File:** `omi/firmware/omi/src/sd_card.c:1522-1533`
**Severity:** Sync regression (data not synced until reconnect cycle)

#### Fix: Rename immediately instead of deferring

Replace the `if (ble_connected)` branch:

```c
/* ---- Time synced ---- */
case REQ_TIME_SYNCED:
    if (current_file_needs_rename && current_filename[0] != '\0') {
        /* Rename immediately — the worker thread is the only writer to
         * lfs_fil_data, so close+rename+reopen is safe regardless of
         * BLE connection state. The old deferral was overly cautious
         * and caused TMP files to be invisible to the app's sync. */
        sd_update_filename_after_timesync(req.u.time_synced.utc_time);
        invalidate_file_cache();
        deferred_timesync_rename_pending = false;
    } else if (current_filename[0] == '\0') {
        res = create_audio_file_with_timestamp();
        if (res < 0)
            LOG_ERR("[SD_WORK] create after time sync failed: %d", res);
    }
    break;
```

Then remove the deferred rename logic from `sd_notify_ble_state()` (lines 1681-1693):
```c
// REMOVE:
if (deferred_timesync_rename_pending) {
    sd_req_t req = {0};
    req.type = REQ_TIME_SYNCED;
    req.u.time_synced.utc_time = deferred_timesync_utc_time;
    // ...
}
```

And remove the now-unused variables:
```c
// REMOVE:
static bool deferred_timesync_rename_pending = false;
static uint32_t deferred_timesync_utc_time = 0;
```

**Why this is safe:** The concern was that renaming while the storage thread is reading the file could cause conflicts. But `sd_update_filename_after_timesync()` already runs on the SD worker thread (via the message queue), and the read handle is a separate `lfs_file_t`. The rename closes `lfs_fil_data`, renames the path, and reopens — no concurrent access.

---

## INTEGRATION FIXES

### I1. Document Big-Endian Timestamps in File List Protocol

**File:** `CLAUDE.md` (BLE Protocol section)

Add to the Storage protocol documentation:

```markdown
**CMD_LIST_FILES (0x10) response format:**
`[count:1][ts1:4BE][sz1:4BE][ts2:4BE][sz2:4BE]...`

Note: timestamps and sizes are big-endian (network byte order) in the file list
response. This differs from all other protocol fields which use little-endian.
This is intentional and must be preserved for backward compatibility.
```

#### Alternative fix: Switch to little-endian

In `storage.c:287-298`, replace the big-endian encoding:

```c
/* Before (big-endian): */
storage_buffer[resp_len++] = (timestamp >> 24) & 0xFF;
storage_buffer[resp_len++] = (timestamp >> 16) & 0xFF;
storage_buffer[resp_len++] = (timestamp >> 8) & 0xFF;
storage_buffer[resp_len++] = timestamp & 0xFF;

/* After (little-endian, consistent with rest of protocol): */
storage_buffer[resp_len++] = timestamp & 0xFF;
storage_buffer[resp_len++] = (timestamp >> 8) & 0xFF;
storage_buffer[resp_len++] = (timestamp >> 16) & 0xFF;
storage_buffer[resp_len++] = (timestamp >> 24) & 0xFF;
```

**WARNING:** This is a breaking protocol change. The app-side parser in `connection.listFiles()` must be updated simultaneously. Only do this if no deployed firmware uses the current BE format.

---

### I2. File Count Overflow Guard

**File:** `omi/firmware/omi/src/lib/core/storage.c:284`

#### Before
```c
storage_buffer[resp_len++] = (uint8_t)sync_file_count;
```

#### After
```c
uint8_t reported_count = (sync_file_count > 255) ? 255 : (uint8_t)sync_file_count;
storage_buffer[resp_len++] = reported_count;
if (sync_file_count > 255) {
    LOG_WRN("File count %d exceeds protocol limit (255), reporting 255", sync_file_count);
}
```

---

### I4. Log Warning Before Formatting Over Existing Data

**File:** `omi/firmware/omi/src/sd_card.c:511-524`

#### Before
```c
if (ret != LFS_ERR_OK) {
    LOG_WRN("LFS mount failed (%d), formatting…", ret);
    ret = lfs_format(&lfs_fs, &lfs_cfg);
```

#### After
```c
if (ret != LFS_ERR_OK) {
    LOG_WRN("LFS mount failed (%d) — existing data on SD will be ERASED by format", ret);
    LOG_WRN("If this device was previously using FATFS, all old recordings are lost.");
    ret = lfs_format(&lfs_fs, &lfs_cfg);
```

---

## PERFORMANCE FIXES

### P1. Reduce Boot Audio Loss from GC Pre-Warm

**File:** `omi/firmware/omi/src/sd_card.c:1159-1171`

No immediate code fix — this is an architectural trade-off. Document the expected boot delay:

```c
/* NOTE: Boot audio loss is expected here.
 * With 200 MB data on SPI SD, this takes ~10-50 seconds.
 * Audio frames arriving during this window are silently dropped
 * (sd_boot_ready == 0). This is preferable to a 50-second stall
 * in the real-time write path on the first lfs_alloc().
 *
 * Future improvement: persist the lookahead bitmap to NVS between
 * reboots to skip the scan entirely on warm boots. */
```

---

### P3. Cache `lfs_fs_size()` Separately from File List Refresh

**File:** `omi/firmware/omi/src/sd_card.c:1003-1011`

#### Before
```c
/* Inside refresh_file_cache(): */
lfs_ssize_t used_blocks = lfs_fs_size(&lfs_fs);
```

#### After
Extract free-space computation into its own function with independent caching:

```c
/* Add new static state: */
static int64_t free_bytes_valid_until_ms = 0;

static void refresh_free_bytes_if_stale(void)
{
    int64_t now = k_uptime_get();
    if (now < free_bytes_valid_until_ms) return;

    lfs_ssize_t used_blocks = lfs_fs_size(&lfs_fs);
    if (used_blocks >= 0 && lfs_cfg.block_count > 0) {
        uint64_t total_cap = (uint64_t)lfs_cfg.block_count * lfs_cfg.block_size;
        uint64_t used_cap  = (uint64_t)used_blocks * lfs_cfg.block_size;
        cached_free_bytes  = (used_cap < total_cap) ? (uint32_t)(total_cap - used_cap) : 0;
    } else {
        cached_free_bytes = 0;
    }
    free_bytes_valid_until_ms = now + (60 * 1000);  /* Recompute at most once per minute */
}
```

Call `refresh_free_bytes_if_stale()` from `refresh_file_cache()` instead of inline `lfs_fs_size()`. Also call it after file create/delete to immediately invalidate:
```c
static void invalidate_free_bytes_cache(void)
{
    free_bytes_valid_until_ms = 0;
}
```

---

## NOMENCLATURE FIXES

### N1. Rename `STORAGE_CHUNK_COUNT`

**File:** `omi/firmware/omi/src/lib/core/storage.c:178`

#### Before
```c
#define STORAGE_CHUNK_COUNT 20
#define STORAGE_BUFFER_SIZE (SD_BLE_SIZE * STORAGE_CHUNK_COUNT + 5 * STORAGE_CHUNK_COUNT)
```

#### After
```c
#define STORAGE_READ_BATCH_SIZE 20
#define STORAGE_BUFFER_SIZE (SD_BLE_SIZE * STORAGE_READ_BATCH_SIZE + 5 * STORAGE_READ_BATCH_SIZE)
```

Note: `BLE_BATCH_PACKETS` (line 461) already exists with value 20 and serves a similar purpose. Consider consolidating into a single constant.

---

### N2. Remove Stale `ble_packet_index` from NOMENCLATURE.md

**File:** `NOMENCLATURE.md` (Section 7, row 3)

The `ble_packet_index` variable does not exist in the codebase. Either:
- Remove the row entirely, or
- Update it to reference `current_package_index` in `transport.c` (see N3)

---

### N3. Rename `current_package_index` → `current_packet_index`

**File:** `omi/firmware/omi/src/lib/core/transport.c:55`

#### Before
```c
uint16_t current_package_index = 0;
```

#### After
```c
uint16_t current_packet_index = 0;
```

Then find-and-replace all references to `current_package_index` across the file. Search for usage:
```bash
grep -rn 'current_package_index' omi/firmware/
```

Update NOMENCLATURE.md Section 7 to match.
