/*
 * sd_card.c â€” LittleFS over disk_access (SD NAND via SPI SD protocol)
 *
 * Architecture:
 *   SD NAND chip â†’ SD SPI stack (disk_access) â†’ LittleFS block callbacks
 *
 * Why LittleFS instead of FATFS:
 *   - Copy-on-write metadata: filesystem is always consistent after power loss
 *   - No "dirty bit" that causes FATFS to refuse writes after ungraceful shutdown
 *   - Journaling: data integrity without complex recovery code
 *   - SD card handles erase internally â†’ erase callback is a no-op
 *   - SD card has internal wear leveling â†’ block_cycles = -1
 */
#include "lib/core/sd_card.h"
#include "lib/core/transport.h"
#include "lib/core/storage.h"
#include "lib/core/settings.h"
#ifdef CONFIG_OMI_AUDIO_RING
#include "lib/core/sd_ring.h"
#endif

#include <ctype.h>
#include <lfs.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/sys/atomic.h>

#include "rtc.h"
#include "imu.h"

LOG_MODULE_REGISTER(sd_card, CONFIG_LOG_DEFAULT_LEVEL);

/* ------------------------------------------------------------------ */
/* Storage backend selector (LittleFS default / raw ring)             */
/* ------------------------------------------------------------------ */
/* Read once at sd_worker boot from the persisted setting. Switching backends
 * requires a reboot (the switch command sets the setting + reboots), so this is
 * stable for the life of a boot. When CONFIG_OMI_AUDIO_RING is off, the ring
 * code is not compiled and ring_active() is a compile-time false so every fork
 * below folds to the LittleFS path. */
static uint8_t g_backend = STORAGE_BACKEND_LITTLEFS;
#ifdef CONFIG_OMI_AUDIO_RING
static uint32_t ring_total_sectors; /* disk sector count, captured at mount for reformat */
static size_t ring_bytes_since_sync;
static uint32_t ring_last_seg_ts;   /* last segment identity ts — bump on same-second collision */
/* An explicit (priority/manual) REQ_CREATE_NEW_FILE rotation whose durability sync
 * failed — the write path completes it before appending, so the requested boundary
 * is never silently dropped and later audio can't land in the previous segment. */
static bool ring_pending_explicit_rotate;
/* The cursor is durably advanced (partial-tail write + CTRL_SYNC + cursor write)
 * on whichever comes first: RING_SYNC_BYTES of appended audio, a ~5 min segment
 * rotation, a critical marker (block_has_critical_marker), or the write-wait-timeout
 * branch once SD_FSYNC_INTERVAL_MS (60 s) has elapsed — the wall-clock backstop,
 * mirroring the LittleFS fsync gate. 256 KiB is NOT arbitrary: at the measured
 * ~5 KB/s ingest it is ~52 s ≈ the 60 s fsync interval, so the byte cap and the
 * time cap target the SAME ~1 min worst-case loss by design; it is also a power-of-2
 * multiple of the 512 B sector and the 4 KB stage batch, keeping the flush
 * page-aligned. The byte cap (not a timer) is what bounds loss during DISCONNECTED
 * continuous speech, where the write-wait timeout never fires (audio blocks arrive
 * ~86 ms apart, faster than the 500 ms disconnected wait), so appended bytes are
 * the only elapsed-audio signal.
 *
 * Only an ungraceful stop loses anything, and for an offline-first device that is
 * realistically just the battery going flat — a <~1 min tail loss there is
 * indistinguishable from "didn't charge enough". At the old 4 KB this synced
 * ~1.25x/s (~75x the LittleFS cadence), burning power on redundant NAND commits
 * (a CTRL_SYNC can trigger a NAND erase — the expensive op). VAD-resume markers
 * (0xFFFFFFFD) also no longer force a sync: they fire on every speech-after-silence
 * wake and carry only a timestamp re-anchor, so they were the dominant per-wake
 * commit in auto mode. */
#define RING_SYNC_BYTES (256 * 1024)
static inline bool ring_active(void)
{
    return g_backend == STORAGE_BACKEND_RING;
}
#else
static inline bool ring_active(void)
{
    return false;
}
#endif

/* ------------------------------------------------------------------ */
/* Power Management Helpers                                           */
/* ------------------------------------------------------------------ */
#ifndef pm_action_is_unsupported
#define pm_action_is_unsupported(ret) ((ret) == -ENOTSUP || (ret) == -ENOSYS)
#endif

#ifndef pm_action_is_ok
#define pm_action_is_ok(ret) ((ret) == 0 || (ret) == -EALREADY || (ret) == -ENOTSUP || (ret) == -ENOSYS)
#endif

#define DISK_DRIVE_NAME CONFIG_SDMMC_VOLUME_NAME
#define SD_REQ_QUEUE_MSGS 120
#define SD_PRIO_QUEUE_MSGS 10
/* Write fairness: the priority (read) queue is normally drained first, but a
 * steady read stream (active sync) must not starve audio writes. Force a write
 * turn after this many consecutive reads, and drain at least this many writes
 * per turn before yielding back to reads. Bounds write latency to
 * MAX_READS_BETWEEN_WRITES read-ops and keeps write throughput above ingest. */
#define MAX_READS_BETWEEN_WRITES 6
#define WRITE_FAIR_MIN 4
#define SD_FSYNC_INTERVAL_MS (60 * 1000)
#define WRITE_BATCH_COUNT 100
#define ERROR_THRESHOLD 5
/* After this many failed 2s recovery cycles, escalate from plain retry to a
 * full power-cycle + remount of the SD card before continuing to drop. */
#define SD_RECOVERY_REMOUNT_THRESHOLD 3

/* SPI3 MOSI hold-low pin — disconnected on SD power-off to prevent back-feed.
   gpio1 pin 11 = P1.11 on the nRF52840 board schematic. */
#define SD_SPI_MOSI_HOLD_PIN 11

#define FILE_CACHE_TTL_MS (30 * 1000)
#define FILE_CONTINUE_THRESHOLD_SEC 60
#define BOOT_MIN_AUDIO_FILE_SIZE 10000

/* LittleFS paths are relative to FS root (no mount-point prefix) */
#define FILE_DATA_DIR  "audio"
#define FILE_INFO_PATH "info.txt"
/* Magic cookie written on every clean LFS format.  If lfs_mount() accidentally
 * succeeds on stale FatFS data (bytes happen to pass LFS superblock CRC), the
 * magic file will be absent or contain wrong bytes — triggering a reformat. */
#define LFS_MAGIC_PATH  ".lfs_magic"
#define LFS_MAGIC_VALUE 0x4C465356u /* 'L','F','S','V' */

/* ------------------------------------------------------------------ */
/* Disk sector size (always 512 for SD) */
#define DISK_SECTOR_SIZE 512
/* LFS block size: groups 8 sectors into one LFS block.
 * With 512-byte blocks, a 512 MB SD has 1M blocks and LFS metadata overhead
 * is enormous (CTZ skip-lists, lookahead scans).  4096-byte blocks reduce
 * the block count to ~128K and cut metadata overhead by ~8x. */
#define LFS_BLOCK_SIZE 4096
#define LFS_CACHE_SIZE LFS_BLOCK_SIZE                         /* cache = 1 full block for multi-sector I/O */
#define SECTORS_PER_BLOCK (LFS_BLOCK_SIZE / DISK_SECTOR_SIZE) /* 8 */

/* ------------------------------------------------------------------ */
/* LittleFS state                                                     */
/* ------------------------------------------------------------------ */

/* Raw LFS instance */
static lfs_t lfs_fs;

/* Open file handles */
static lfs_file_t lfs_fil_data;
static lfs_file_t lfs_fil_info;

/* Static buffers for lfs_file_opencfg (avoids heap allocation)
 * Size must match cache_size (LFS_CACHE_SIZE = 4096). */
static uint8_t lfs_fdata_buf[LFS_CACHE_SIZE];
static uint8_t lfs_finfo_buf[LFS_CACHE_SIZE];
static struct lfs_file_config lfs_fdata_cfg = {.buffer = lfs_fdata_buf};
static struct lfs_file_config lfs_finfo_cfg = {.buffer = lfs_finfo_buf};


/* LFS I/O buffers — sized to cache_size (4096) for multi-sector I/O */
static uint8_t lfs_read_buf[LFS_CACHE_SIZE];
static uint8_t lfs_prog_buf[LFS_CACHE_SIZE];
/* Lookahead buffer sizing:
 * 128 bytes = 1024 blocks = 4 MB window → too small for 512 MB SD (128K blocks).
 * Every time the window is exhausted, LFS triggers a FULL filesystem traversal
 * (lfs_alloc_scan → lfs_fs_traverse_) which reads every block in every file.
 * With 200 MB of data (~50K blocks) this costs 10-50+ seconds per scan over SPI.
 *
 * The traversal runs on the single sd_worker thread and is the dominant source of
 * intermittent sd_msgq saturation (peak-depth spikes toward SD_REQ_QUEUE_MSGS): it
 * fires only when the window drains, and its duration tracks how full the SD is.
 *
 * 4096 bytes = 32768 blocks = 128 MB window → ~4 scans to cover entire disk.
 * Reduces scan frequency to every ~128 MB written (vs ~64 MB at 2048), halving how
 * often the write path eats a full-FS traversal. Does NOT shorten each scan — that
 * cost is O(data on disk), so prompt app-side sync+delete (keeping the FS emptier)
 * remains the biggest lever on stall *duration*.
 * Cost: 2048 bytes extra static RAM vs the prior 2048-byte window. */
#define LFS_LOOKAHEAD_SIZE 4096
static uint8_t lfs_lookahead_buf[LFS_LOOKAHEAD_SIZE];

/* Shared temp sector buffer â€” only used from worker thread, safe as static */
static uint8_t _lfs_io_tmp[512];

/* LittleFS disk_access callbacks                                      */
/* ------------------------------------------------------------------ */

/*
 * Map LFS (block, offset) to disk sector.
 *
 * NOTE: LittleFS is NOT thread-safe by default. In this architecture, all
 * lfs_* functions and these callbacks are strictly serialized on the single
 * sd_worker thread. If LFS is ever called from another thread, it will 
 * cause immediate filesystem corruption.
 *
 *   LFS block N at byte offset K  →  disk sector  N * SECTORS_PER_BLOCK + K/512
 * With cache_size == 4096 (== block_size), LFS typically calls us with
 * size == 4096 and off == 0.  The fast path handles any aligned multi-sector
 * read in a single disk_access call (CMD18 multi-block read).
 */
static int lfs_disk_read_cb(const struct lfs_config *c, lfs_block_t block, lfs_off_t off, void *buffer, lfs_size_t size)
{
    (void) c;
    uint32_t sector = (uint32_t) block * SECTORS_PER_BLOCK + off / DISK_SECTOR_SIZE;
    uint32_t sec_off = off % DISK_SECTOR_SIZE;

    /* Fast path: aligned multi-sector read (the common case with cache_size=4096) */
    if (sec_off == 0 && (size % DISK_SECTOR_SIZE) == 0) {
        uint32_t nsec = size / DISK_SECTOR_SIZE;
        return disk_access_read(DISK_DRIVE_NAME, buffer, sector, nsec) == 0 ? LFS_ERR_OK : LFS_ERR_IO;
    }
    /* Generic path: partial / unaligned */
    uint8_t *dst = (uint8_t *) buffer;
    while (size > 0) {
        if (disk_access_read(DISK_DRIVE_NAME, _lfs_io_tmp, sector, 1) != 0)
            return LFS_ERR_IO;
        lfs_size_t chunk = DISK_SECTOR_SIZE - sec_off;
        if (chunk > size)
            chunk = size;
        memcpy(dst, _lfs_io_tmp + sec_off, chunk);
        dst += chunk;
        size -= chunk;
        sec_off = 0;
        sector++;
    }
    return LFS_ERR_OK;
}

static int
lfs_disk_prog_cb(const struct lfs_config *c, lfs_block_t block, lfs_off_t off, const void *buffer, lfs_size_t size)
{
    (void) c;
    uint32_t sector = (uint32_t) block * SECTORS_PER_BLOCK + off / DISK_SECTOR_SIZE;
    uint32_t sec_off = off % DISK_SECTOR_SIZE;

    /* Fast path: aligned multi-sector write (CMD25 multi-block write) */
    if (sec_off == 0 && (size % DISK_SECTOR_SIZE) == 0) {
        uint32_t nsec = size / DISK_SECTOR_SIZE;
        return disk_access_write(DISK_DRIVE_NAME, buffer, sector, nsec) == 0 ? LFS_ERR_OK : LFS_ERR_IO;
    }
    /* Generic path: read-modify-write per sector */
    const uint8_t *src = (const uint8_t *) buffer;
    while (size > 0) {
        if (disk_access_read(DISK_DRIVE_NAME, _lfs_io_tmp, sector, 1) != 0)
            return LFS_ERR_IO;
        lfs_size_t chunk = DISK_SECTOR_SIZE - sec_off;
        if (chunk > size)
            chunk = size;
        memcpy(_lfs_io_tmp + sec_off, src, chunk);
        if (disk_access_write(DISK_DRIVE_NAME, _lfs_io_tmp, sector, 1) != 0)
            return LFS_ERR_IO;
        src += chunk;
        size -= chunk;
        sec_off = 0;
        sector++;
    }
    return LFS_ERR_OK;
}

static int lfs_disk_erase_cb(const struct lfs_config *c, lfs_block_t block)
{
    /* SD card erases blocks internally on write â€” this is a true no-op. */
    (void) c;
    (void) block;
    return LFS_ERR_OK;
}

static int lfs_disk_sync_cb(const struct lfs_config *c)
{
    (void) c;
    int ret = disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_CTRL_SYNC, NULL);
    if (ret != 0 && ret != -ENOTSUP && ret != -ENOSYS) {
        LOG_WRN("[SD] CTRL_SYNC failed: %d (data may not be durable)", ret);
        return LFS_ERR_IO;
    }
    return LFS_ERR_OK;
}

/* LFS config â€” block_count filled at runtime from DISK_IOCTL_GET_SECTOR_COUNT */
static struct lfs_config lfs_cfg = {
    .read = lfs_disk_read_cb,
    .prog = lfs_disk_prog_cb,
    .erase = lfs_disk_erase_cb,
    .sync = lfs_disk_sync_cb,

    .read_size = DISK_SECTOR_SIZE,
    .prog_size = DISK_SECTOR_SIZE,
    .block_size = LFS_BLOCK_SIZE,
    .block_count = 0,                     /* set at mount time */
    .cache_size = LFS_CACHE_SIZE,         /* 4096: full-block cache → multi-sector I/O */
    .lookahead_size = LFS_LOOKAHEAD_SIZE, /* 4096 bytes = 32768 blocks = 128 MB window */

    .read_buffer = lfs_read_buf,
    .prog_buffer = lfs_prog_buf,
    .lookahead_buffer = lfs_lookahead_buf,

    /* SD card has internal wear leveling â†’ disable LFS wear leveling */
    .block_cycles = -1,

#if LFS_VERSION >= 0x00020009
    /* Disable metadata compaction during lfs_fs_gc() -- we only want
     * the allocator pre-warm (lookahead scan), not expensive compaction.
     * compact_thresh was added in LFS 2.9. */
    .compact_thresh = (lfs_size_t) -1,
#endif
};

/* ------------------------------------------------------------------ */
/* General state                                                      */
/* ------------------------------------------------------------------ */

static uint8_t writing_error_counter = 0;
static uint8_t sd_recovery_cycles = 0;  /* consecutive failed write-block recoveries */
static bool sd_write_blocked = false;
static uint8_t write_batch_buffer[WRITE_BATCH_COUNT * MAX_WRITE_SIZE];
static size_t write_batch_offset = 0;
static int write_batch_counter = 0;
static int64_t last_write_blocked_log_ms = 0;
static int64_t last_write_error_uptime_ms = 0;
static uint32_t write_drop_packets = 0;
static uint32_t write_drop_bytes = 0;

/* SD boot readiness gate: cleared during init, set after pre-warm + file open.
 * write_to_file() silently discards data while this is 0, preventing the message
 * queue from filling up while lfs_fs_gc() is running on the worker thread. */
static atomic_t sd_boot_ready;

/* Counter of audio frames dropped while SD boot was in progress.
 * Incremented in write_to_file(); queryable via sd_get_boot_dropped_frames(). */
static atomic_t boot_dropped_frames;
static atomic_t stat_dropped_frames;

/* Observability for the write path (since boot, reset on reboot):
 *  - sd_msgq_peak_depth: high-water mark of sd_msgq occupancy. Shows headroom
 *    vs SD_REQ_QUEUE_MSGS — how close write fairness keeps us to a drop.
 *  - write_fair_activations: times the worker forced a write turn over pending
 *    reads (fairness engaged). Both queryable via getters for diagnostics. */
static atomic_t sd_msgq_peak_depth;
static atomic_t write_fair_activations;

/* Diagnostics: rotations that closed a bin holding no audio (size <= the inline
 * metadata header, i.e. only the 0xFFFFFFFB header or nothing at all persisted).
 * A Priority Recording whose 0xFFFFFFF8 marker + force-captured frames were lost
 * at the rotate leaves exactly this empty-bin residue, so a nonzero delta across a
 * priority attempt is the on-device fingerprint of that loss. Read via 0x19B10062. */
static atomic_t empty_bin_rotations;

/* Diagnostics: marker-bearing blocks RESCUED at the sd_write_paused gate below —
 * written through the pause instead of dropped. Before oo-2.5.9 this exact block was
 * silently discarded — the one marker-loss path that bumped NO counter at all
 * (marker_write_drops only counts a transport-level block reject; the sd_write_blocked
 * overflow path above still bumps stat_dropped_frames, so it isn't silent, just not
 * marker-specific). The counter tallied those losses; now a nonzero value with
 * recordings finalizing = the rescue firing. Read via 0x19B10062. */
static atomic_t marker_pause_gate_saves;

/* Scan a 440-byte storage block for inline marker headers. Markers are always
 * 4-byte aligned by the transport, so scanning 4-byte-aligned words is exact. The
 * sentinel list lives here ONCE; `include_resume` selects the marker SET so the two
 * wrappers below can't drift out of sync as marker types / alignment change:
 *   - block_has_marker (include_resume = true): EVERY marker type, incl. 0xFFFFFFFD
 *     VAD-resume. Used at the sd_write_paused rescue so NO marker is dropped through
 *     a pause. Before oo-2.5.9 that block was silently discarded.
 *   - block_has_critical_marker (include_resume = false): boundary + user markers
 *     only (priority-start / mute-off / mute-on / session-end / button-tap). Used to
 *     decide the immediate force-sync (an out-of-band CTRL_SYNC + cursor write).
 *     0xFFFFFFFD is excluded there because it fires on EVERY speech-after-silence
 *     wake (many/hr in auto mode) and carries only a timestamp re-anchor, so an
 *     ungraceful cut loses at most one re-anchor, not a boundary — it rides the
 *     RING_SYNC_BYTES periodic sync instead, and was the main reason ring's flush
 *     cadence ran ~10x LittleFS's.
 * Only called on the rare pause-gate / marker paths, never per audio frame, so the
 * scan cost is irrelevant. */
static bool block_scan_markers(const uint8_t *buf, size_t len, bool include_resume)
{
    for (size_t i = 0; i + 4 <= len; i += 4) {
        uint32_t w = (uint32_t) buf[i] | ((uint32_t) buf[i + 1] << 8) | ((uint32_t) buf[i + 2] << 16) |
                     ((uint32_t) buf[i + 3] << 24);
        if (w == 0xFFFFFFF8u /* priority-start */ || w == 0xFFFFFFF9u /* mute-off */ ||
            w == 0xFFFFFFFAu /* mute-on */ || w == 0xFFFFFFFCu /* session-end */ ||
            w == 0xFFFFFFFEu /* button-tap */ ||
            (include_resume && w == 0xFFFFFFFDu) /* VAD-resume — critical set excludes */) {
            return true;
        }
    }
    return false;
}

/* Any marker (incl. VAD-resume) — pause-gate rescue predicate. */
static inline bool block_has_marker(const uint8_t *buf, size_t len)
{
    return block_scan_markers(buf, len, true);
}

/* Boundary/user markers only (VAD-resume excluded) — force-sync predicate. */
static inline bool block_has_critical_marker(const uint8_t *buf, size_t len)
{
    return block_scan_markers(buf, len, false);
}

/* Protects current_filename / current_file_path across threads.
 * The SD worker updates these during file creation and TMP→hex rename;
 * the storage thread reads them via sd_is_current_recording_file(). */
static K_MUTEX_DEFINE(current_filename_lock);

/* Deferred control requests when prio queue is temporarily saturated */
static atomic_t pending_flush_on_ble_connect;
static atomic_t pending_rotate_on_ble_connect;
static atomic_t pending_time_synced;
static uint32_t pending_timesync_utc; /* Written only from sd_notify_time_synced (single writer), read only on worker thread — no atomic needed. */
static atomic_t deferred_timesync_rename_pending;
static uint32_t deferred_timesync_utc;

/* Set when a TMP→UTC rename is in flight (between sd_notify_time_synced and the
 * sd_worker completing sd_update_filename_after_timesync). The storage thread
 * waits on this before responding to CMD_LIST_FILES so it never returns
 * uptime-stamped entries to the app. */
static atomic_t timesync_rename_pending = ATOMIC_INIT(0);

static bool is_mounted = false;
static bool sd_enabled = false;
static atomic_t sd_write_paused = ATOMIC_INIT(0);
static atomic_t ota_active = ATOMIC_INIT(0);
static atomic_t sd_io_low_power = ATOMIC_INIT(0);
static atomic_t sd_dev_pm_supported = ATOMIC_INIT(1);

/* Idle power saving is SPI-bus suspend only (sd_set_io_low_power): the SD chip
 * stays mounted and powered the whole time the device is running, matching the
 * upstream firmware. The NAND is fully powered off only at shutdown. We do NOT
 * deep-power-gate during operation — a full power-off + remount-on-wake could
 * persistently fail (driver wedge) and latch sd_write_blocked, silently killing
 * recording until a reboot. */

/* Worker thread & task definitions */
/* 12 KB: on-device the sd_worker high-water is ~5.8 KB on the ring path and, after
 * shrinking sd_ring_format()'s zeroing buffer (4 KB→512 B), its peak stays ~6 KB;
 * the LittleFS path's lfs ops (incl. the traverse scan) are iterative/bounded and
 * fit comfortably too. The 4 KB reclaimed vs the old 16 KB is handed to the codec
 * thread, which ran at ~17.5/18.6 KB (94%). Net RAM change: zero. Verify after a
 * backend switch that the LittleFS-path high-water stays well under this. */
#define SD_WORKER_STACK_SIZE 12288
#define SD_WORKER_PRIORITY 7
K_THREAD_STACK_DEFINE(sd_worker_stack, SD_WORKER_STACK_SIZE);
static struct k_thread sd_worker_thread_data;
static k_tid_t sd_worker_tid = NULL;

static bool sd_ready = false;
static bool sd_shutdown_in_progress = false;
static uint32_t current_file_size = 0;
static size_t bytes_since_sync = 0;
static int64_t last_file_sync_uptime_ms = 0;

/* Current writing file info */
static char current_filename[MAX_FILENAME_LEN] = {0};
static char current_file_path[64] = {0};
static int64_t current_file_created_uptime_ms = -1;
static bool current_file_needs_rename = false;
static uint32_t cached_stats_file_count = 0;
static uint64_t cached_stats_total_size = 0;
static uint32_t cached_free_bytes = 0;
static int64_t cached_stats_valid_until_ms = 0;
static bool file_cache_valid = false;
static int cached_file_list_count = 0;
static uint32_t cached_total_file_count = 0;
static uint64_t cached_total_file_size = 0;
static AudioFileMeta_t cached_file_meta[MAX_AUDIO_FILES];
static K_MUTEX_DEFINE(file_cache_mutex);

/* BLE connection tracking for file rotation */
static atomic_t ble_connected;
static int64_t ble_connect_time_ms = 0;

/* Track if active file was deleted while BLE connected */
static atomic_t current_file_deleted;

/* Offset info (oldest file + byte offset) */
static sd_offset_info_t current_offset_info = {0};

/* Hardware device references */
static const struct device *const sd_dev = DEVICE_DT_GET(DT_NODELABEL(sdhc0));
static const struct gpio_dt_spec sd_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(sdcard_en_pin), gpios, {0});

K_MSGQ_DEFINE(sd_msgq, sizeof(sd_req_t), SD_REQ_QUEUE_MSGS, 4);
K_MSGQ_DEFINE(sd_prio_msgq, sizeof(sd_req_t), SD_PRIO_QUEUE_MSGS, 4);

/* Persistent read file handle — kept open between read_audio_data calls
 * so we avoid the expensive LFS open/seek/close on every read.
 * With 512-byte blocks and a 1 MB+ file, an open+seek costs O(sqrt(N/512))
 * block reads (≈50 SPI transactions), making each read 100–300 ms.
 * Keeping the handle open reduces this to a simple sequential read (~5 ms). */
static lfs_file_t lfs_read_handle;
static uint8_t lfs_read_handle_buf[LFS_CACHE_SIZE];
static struct lfs_file_config lfs_read_handle_cfg = {.buffer = lfs_read_handle_buf};
static char read_handle_filename[MAX_FILENAME_LEN] = {0};
static bool read_handle_open = false;
static lfs_soff_t read_handle_pos = 0;

/* Sync generation: incremented every time lfs_fil_data is synced.
 * The read handle records which generation it was opened at;
 * if it doesn't match, the handle is stale (file grew) and must reopen. */
static uint32_t data_sync_gen = 0;
static uint32_t read_handle_gen = 0;


static void parse_filename_to_meta(const char* filename, uint32_t size, AudioFileMeta_t* meta)
{
    memset(meta, 0, sizeof(AudioFileMeta_t));
    meta->file_size = size;

    if (strncmp(filename, "TMP_", 4) == 0) {
        meta->is_tmp = true;
        meta->timestamp = (uint32_t)strtoul(filename + 4, NULL, 16);
        const char *sep = strchr(filename + 4, '_');
        if (sep) meta->uptime_offset = (uint32_t)strtoul(sep + 1, NULL, 16);
    } else {
        char *endptr = NULL;
        uint32_t ts = (uint32_t)strtoul(filename, &endptr, 16);
        if (endptr == filename) {
            /* strtoul consumed zero characters — filename is not a hex-named file (e.g. stats.txt) */
            meta->is_stats = true;
        } else {
            meta->timestamp = ts;
            /* Tokenized format: %08X_%08X.txt — second token is session_id */
            if (endptr && *endptr == '_') {
                meta->uptime_offset = (uint32_t)strtoul(endptr + 1, NULL, 16);
            }
        }
    }
}

void build_filename_from_meta(const AudioFileMeta_t* meta, char* out_buffer, size_t max_len)
{
    if (meta->is_stats) {
        snprintf(out_buffer, max_len, "stats.txt");
    } else if (meta->is_tmp) {
        snprintf(out_buffer, max_len, "TMP_%08X_%08X.txt", meta->timestamp, meta->uptime_offset);
    } else if (meta->uptime_offset != 0) {
        snprintf(out_buffer, max_len, "%08X_%08X.txt", meta->timestamp, meta->uptime_offset);
    } else {
        snprintf(out_buffer, max_len, "%08X.txt", meta->timestamp);
    }
}

static int compare_meta(const AudioFileMeta_t* a, const AudioFileMeta_t* b)
{
    if (a->timestamp != b->timestamp) {
        return (a->timestamp > b->timestamp) ? 1 : -1;
    }
    if (a->uptime_offset != b->uptime_offset) {
        return (a->uptime_offset > b->uptime_offset) ? 1 : -1;
    }
    /* is_tmp is part of the identity — keep consistent with sd_is_current_recording_file_meta */
    if (a->is_tmp != b->is_tmp) {
        return a->is_tmp ? 1 : -1;
    }
    return 0;
}

bool sd_is_current_recording_file_meta(const AudioFileMeta_t *meta)
{
    if (!meta) return false;
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    if (current_filename[0] == '\0') {
        k_mutex_unlock(&current_filename_lock);
        return false;
    }
    AudioFileMeta_t current;
    parse_filename_to_meta(current_filename, 0, &current);
    k_mutex_unlock(&current_filename_lock);
    return (current.timestamp == meta->timestamp &&
            current.uptime_offset == meta->uptime_offset &&
            current.is_tmp == meta->is_tmp);
}

// Thread-safe getter for the BLE thread
int sd_get_cached_file_count(void)
{
    k_mutex_lock(&file_cache_mutex, K_FOREVER);
    int count = cached_file_list_count;
    k_mutex_unlock(&file_cache_mutex);
    return count;
}

// Thread-safe struct copy
int sd_get_cached_file_meta(int index, AudioFileMeta_t *out_meta)
{
    k_mutex_lock(&file_cache_mutex, K_FOREVER);
    if (index < 0 || index >= cached_file_list_count || !out_meta) {
        k_mutex_unlock(&file_cache_mutex);
        return -1;
    }
    // Deep copy the 16-byte struct
    *out_meta = cached_file_meta[index];
    k_mutex_unlock(&file_cache_mutex);
    return 0;
}

uint64_t sd_get_cached_total_size(void)
{
    k_mutex_lock(&file_cache_mutex, K_FOREVER);
    uint64_t size = cached_total_file_size;
    k_mutex_unlock(&file_cache_mutex);
    return size;
}

/* Forward declarations */
void sd_worker_thread(void);
static void process_write_data_req(const sd_req_t *req);
static int flush_batch_buffer_chunked(void);
static int create_audio_file_with_timestamp(void);
static bool should_rotate_file(void);
static void build_file_path(const char *filename, char *path, size_t path_size);
static void invalidate_file_cache(void);
static void invalidate_file_cache_deferrable(void);
static void update_current_file_cache_size(uint32_t delta);
static void sort_cached_file_entries(void);
static void sd_set_io_low_power(bool enable);
static int sd_unmount(void);
static int sd_remount_and_reopen_info(void);

#ifdef CONFIG_OMI_AUDIO_RING
/* Ring-backend variants of the LittleFS operations, dispatched behind
 * ring_active(). Defined together near the end of this file. */
static int ring_create_segment(void);
static void process_write_data_req_ring(const sd_req_t *req);
static int ring_refresh_file_cache(void);
static int ring_find_segment_index(uint32_t timestamp, uint32_t session_id);
static void ring_handle_read_req(const sd_req_t *req);
#endif

static void process_save_offset_req(const sd_req_t *req)
{
    /* The read-resume offset lives in LittleFS info.txt. The ring tracks the read
     * position via the app's WAL + the ring tail, so this is a no-op there. */
    if (ring_active()) {
        return;
    }
    if (sd_write_blocked) {
        if ((k_uptime_get() - last_write_error_uptime_ms) > 2000) {
            sd_write_blocked = false;
            writing_error_counter = 0;
            LOG_INF("[SD_WORK] Attempting recovery from write-blocked state (offset)");
        } else {
            return;
        }
    }

    sd_set_io_low_power(false);
    lfs_file_seek(&lfs_fs, &lfs_fil_info, 0, LFS_SEEK_SET);
    lfs_ssize_t bw = lfs_file_write(&lfs_fs, &lfs_fil_info, &req->u.info.offset_info, sizeof(sd_offset_info_t));
    if (bw == (lfs_ssize_t) sizeof(sd_offset_info_t)) {
        lfs_file_sync(&lfs_fs, &lfs_fil_info);
        memcpy(&current_offset_info, &req->u.info.offset_info, sizeof(sd_offset_info_t));
    } else {
        last_write_error_uptime_ms = k_uptime_get();
        LOG_ERR("[SD_WORK] save offset write err %d", (int) bw);
    }
    sd_set_io_low_power(true);
}

/* SD-worker-thread-local guards: while true, process_write_data_req() must NOT
 * (sd_suppress_auto_rotate) auto-rotate (should_rotate_file()) mid-write, and
 * (sd_draining) must NOT discard a frame on sd_write_paused. Only ever set/read on
 * the SD worker thread inside drain_pending_write_queue_for_shutdown(), so plain
 * bools are sufficient (no cross-thread access). */
static bool sd_suppress_auto_rotate = false;
static bool sd_draining = false;

static void drain_pending_write_queue_for_shutdown(void)
{
    /* Frames drained here belong to the CURRENT file and must land in it. Callers
     * drain immediately before an explicit rotate (REQ_CREATE_NEW_FILE) or an
     * unmount, so any rotation process_write_data_req() would trigger on its own
     * (5-min file age, or a pending BLE-connect rotate) is redundant AND harmful:
     * it would push a queued frame — e.g. the 0xFFFFFFFC session-end marker a
     * priority-record stop just enqueued — into a fresh bin instead of the
     * current one. Suppress it for the duration of the drain.
     *
     * sd_draining also bypasses the sd_write_paused gate below: a stop that ends a
     * recording (aad_set_threshold finalize) enqueues the 0xFFFFFFFC marker and then
     * queues a pause; the higher-priority AAD handler flips sd_write_paused=1 before
     * this drain runs, so without the bypass the drain would discard the marker (and
     * any tail audio) it is meant to persist — the on-device "0 of N stops" loss.
     * These frames were accepted into sd_msgq before the pause and belong to the
     * current file; drain them regardless of the paused flag. */
    sd_suppress_auto_rotate = true;
    sd_draining = true;
    /* Bound the drain to the frames already queued at entry. The audio producer
     * stops when a recording ends / goes silent (aad_process_audio forwards nothing
     * while !vad_is_recording), so in practice nothing new is enqueued here — but
     * snapshotting the depth keeps the pause-gate bypass from ever persisting a frame
     * that arrived after the pause. The SD worker is the only consumer of sd_msgq, so
     * these `queued` items are all present now. */
    uint32_t queued = k_msgq_num_used_get(&sd_msgq);
    while (queued-- > 0) {
        sd_req_t pending_req;
        if (k_msgq_get(&sd_msgq, &pending_req, K_NO_WAIT) != 0) {
            break;
        }

        if (pending_req.type == REQ_WRITE_DATA) {
            process_write_data_req(&pending_req);
        } else if (pending_req.type == REQ_SAVE_OFFSET) {
            process_save_offset_req(&pending_req);
        }
    }
    sd_draining = false;
    sd_suppress_auto_rotate = false;
}

#define FLUSH_CHUNK_SIZE 4096 

static int flush_batch_buffer_chunked(void)
{
    if (write_batch_offset == 0) return 0;
    if (sd_write_blocked) {
        write_batch_offset = 0;
        write_batch_counter = 0;
        return -EIO;
    }

    size_t to_write = write_batch_offset;
    uint8_t *ptr = write_batch_buffer;
    size_t total_written = 0;

    while (to_write > 0) {
        size_t chunk = (to_write > FLUSH_CHUNK_SIZE) ? FLUSH_CHUNK_SIZE : to_write;
        lfs_ssize_t bw = lfs_file_write(&lfs_fs, &lfs_fil_data, ptr, chunk);

        if (bw < 0 || (size_t)bw != chunk) {
            k_msleep(50);
            bw = lfs_file_write(&lfs_fs, &lfs_fil_data, ptr, chunk);
        }

        if (bw < 0 || (size_t)bw != chunk) {
            writing_error_counter++;
            last_write_error_uptime_ms = k_uptime_get();
            if (writing_error_counter > ERROR_THRESHOLD) sd_write_blocked = true;
            write_batch_offset = 0;
            write_batch_counter = 0;
            return -EIO;
        }
        ptr += bw;
        to_write -= bw;
        total_written += bw;
        current_file_size += bw;
        bytes_since_sync += bw;

        /* CRITICAL: Preemption point to let BLE run! */
        if (to_write > 0 && k_msgq_num_used_get(&sd_prio_msgq) > 0) {
            memmove(write_batch_buffer, ptr, to_write);
            write_batch_offset = to_write;
            update_current_file_cache_size(total_written);
            return 0; 
        }
        if (to_write > 0) k_yield(); 
    }

    update_current_file_cache_size(total_written);
    writing_error_counter = 0;
    sd_recovery_cycles = 0;  /* a successful flush means the card is healthy again */
    write_batch_offset = 0;
    write_batch_counter = 0;
    return 0;
}

static void process_write_data_req(const sd_req_t *req)
{
#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) {
        process_write_data_req_ring(req);
        return;
    }
#endif

    bool spi_woken = false;

    if (sd_write_blocked) {
        if ((k_uptime_get() - last_write_error_uptime_ms) > 2000) {
            if (++sd_recovery_cycles >= SD_RECOVERY_REMOUNT_THRESHOLD) {
                /* Plain 2s retries aren't clearing the fault — power-cycle and
                 * remount the card ("unplug/replug") before continuing to drop. */
                LOG_WRN("[SD_WORK] %u failed recoveries — power-cycling + remounting SD",
                        sd_recovery_cycles);
                sd_set_io_low_power(false);
                spi_woken = true;
                sd_unmount();
                int mret = sd_remount_and_reopen_info();
                sd_recovery_cycles = 0;
                if (mret == 0) {
                    sd_write_blocked = false;
                    writing_error_counter = 0;
                    LOG_INF("[SD_WORK] SD remounted — resuming writes");
                } else {
                    /* Remount failed too; stay blocked and retry in 2s. */
                    last_write_error_uptime_ms = k_uptime_get();
                }
            } else {
                sd_write_blocked = false;
                writing_error_counter = 0;
                LOG_INF("[SD_WORK] Attempting recovery from write-blocked state (data, cycle %u)",
                        sd_recovery_cycles);
            }
        }

        if (sd_write_blocked) {
            /* Still blocked: buffer the frame to preserve audio if space allows */
            if (write_batch_offset + req->u.write.len <= sizeof(write_batch_buffer)) {
                memcpy(write_batch_buffer + write_batch_offset,
                       req->u.write.buf, req->u.write.len);
                write_batch_offset += req->u.write.len;
                write_batch_counter++;
            } else {
                /* Batch buffer full — frame is truly unrecoverable */
                atomic_inc(&stat_dropped_frames);
            }
            if (spi_woken) {
                sd_set_io_low_power(true);
            }
            return;
        }
    }

    /* Skip the pause gate while draining: drain_pending_write_queue_for_shutdown()
     * persists frames already accepted into sd_msgq before a concurrent pause (e.g.
     * the 0xFFFFFFFC a priority-record stop just enqueued right before it queued the
     * pause and rotated the bin). Dropping them here is the deterministic stop-marker
     * loss. (Manual-mode stop doesn't rotate, so its marker never reaches this drain
     * — that path is unchanged here.) */
    if (!sd_draining && atomic_get(&sd_write_paused)) {
        /* A pause is a power optimization for silence, NOT a correctness gate. A
         * marker-bearing block MUST still be persisted here, or a priority/manual stop
         * that enqueued 0xFFFFFFFC and then queued a pause loses it: the SD worker can
         * pull that marker off sd_msgq via this normal path BEFORE the
         * REQ_CREATE_NEW_FILE drain runs, so the drain-bypass alone didn't cover it
         * (confirmed on-device — session_end_marker_emits moved while the app saw no
         * stop, and marker_pause_gate_saves logged the drop). Write a marker block
         * through despite the pause; drop only non-marker (audio) blocks. The counter
         * tallies these RESCUES (markers kept through a pause), not losses. */
        if (block_has_marker(req->u.write.buf, req->u.write.len)) {
            atomic_inc(&marker_pause_gate_saves);
            /* fall through to persist the marker despite the pause */
        } else {
            if (spi_woken) {
                sd_set_io_low_power(true);
            }
            return;
        }
    }

    if (current_filename[0] == '\0') {
        if (!spi_woken) { sd_set_io_low_power(false); spi_woken = true; }
        int res = create_audio_file_with_timestamp();
        if (res < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto done;
        }
        atomic_clear(&current_file_deleted);
    }

    if (!sd_suppress_auto_rotate && should_rotate_file()) {
        LOG_INF("[SD_WORK] Rotating file after %d min", (int)(FILE_ROTATION_INTERVAL_MS / 60000));
        if (!spi_woken) { sd_set_io_low_power(false); spi_woken = true; }
        int flush_res = flush_batch_buffer_chunked();
        if (flush_res < 0) {
            LOG_ERR("[SD_WORK] flush failed before rotation: %d", flush_res);
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto done;
        }
        int res = create_audio_file_with_timestamp();
        if (res < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto done;
        }
    }

    /* Overflow guard — flush first if this frame won't fit */
    if (write_batch_offset + req->u.write.len > sizeof(write_batch_buffer)) {
        if (!spi_woken) { sd_set_io_low_power(false); spi_woken = true; }
        flush_batch_buffer_chunked();
        if (write_batch_offset + req->u.write.len > sizeof(write_batch_buffer)) {
            LOG_ERR("[SD_WORK] batch buffer overflow guard len=%u", (unsigned) req->u.write.len);
            goto done;
        }
    }

    memcpy(write_batch_buffer + write_batch_offset, req->u.write.buf, req->u.write.len);
    write_batch_offset += req->u.write.len;
    write_batch_counter++;

done:
    if (spi_woken) {
        sd_set_io_low_power(true);
    }
}

static void close_read_handle(void)
{
    if (read_handle_open) {
        lfs_file_close(&lfs_fs, &lfs_read_handle);
        read_handle_open = false;
        read_handle_filename[0] = '\0';
        read_handle_pos = 0;
    }
}

/* ------------------------------------------------------------------ */
/* Power management                                                    */
/* ------------------------------------------------------------------ */

static int sd_enable_power(bool enable)
{
    int ret;
    gpio_pin_configure_dt(&sd_en, GPIO_OUTPUT);
    const struct device *spi_dev = DEVICE_DT_GET(DT_NODELABEL(spi3));
    if (enable) {
        ret = gpio_pin_set_dt(&sd_en, 1);
        if (device_is_ready(spi_dev)) {
            pm_device_action_run(spi_dev, PM_DEVICE_ACTION_RESUME);
            pm_device_action_run(sd_dev, PM_DEVICE_ACTION_RESUME);
        }
        sd_enabled = true;
    } else {
        if (device_is_ready(spi_dev)) {
            pm_device_action_run(sd_dev, PM_DEVICE_ACTION_SUSPEND);
            /* Do NOT suspend spi3 — spi_flash (DFU secondary slot) shares the same
             * bus and must remain accessible during OTA. The SD chip itself is
             * powered off via sd_en, so it draws no current regardless. */
        }
        gpio_pin_configure(DEVICE_DT_GET(DT_NODELABEL(gpio1)),
                           SD_SPI_MOSI_HOLD_PIN, GPIO_DISCONNECTED);
        ret = gpio_pin_set_dt(&sd_en, 0);
        sd_enabled = false;
    }
    return ret;
}

static void sd_set_io_low_power(bool enable)
{
    const struct device *spi_dev = DEVICE_DT_GET(DT_NODELABEL(spi3));

    if (!sd_enabled || !device_is_ready(spi_dev))
        return;

    if (enable) {
        /* Do NOT sleep the bus if an OTA is in progress or about to start */
        if (atomic_get(&ota_active))
            return;

        if (!atomic_cas(&sd_io_low_power, 0, 1))
            return;

        int ret_sd = 0;
        if (atomic_get(&sd_dev_pm_supported)) {
            ret_sd = pm_device_action_run(sd_dev, PM_DEVICE_ACTION_SUSPEND);
            if (pm_action_is_unsupported(ret_sd)) {
                atomic_set(&sd_dev_pm_supported, 0);
                LOG_INF("SD device PM suspend unsupported, SPI-only power management");
            }
        }
        int ret_spi = pm_device_action_run(spi_dev, PM_DEVICE_ACTION_SUSPEND);
        if (!pm_action_is_ok(ret_sd) || !pm_action_is_ok(ret_spi))
            LOG_WRN("SD low-power suspend failed (sd=%d spi=%d)", ret_sd, ret_spi);
    } else {
        if (!atomic_cas(&sd_io_low_power, 1, 0))
            return;

        int ret_spi = pm_device_action_run(spi_dev, PM_DEVICE_ACTION_RESUME);
        int ret_sd = 0;
        if (atomic_get(&sd_dev_pm_supported)) {
            ret_sd = pm_device_action_run(sd_dev, PM_DEVICE_ACTION_RESUME);
            if (pm_action_is_unsupported(ret_sd)) {
                atomic_set(&sd_dev_pm_supported, 0);
                LOG_INF("SD device PM resume unsupported, SPI-only power management");
            }
        }
        if (!pm_action_is_ok(ret_sd) || !pm_action_is_ok(ret_spi))
            LOG_WRN("SD low-power resume failed (sd=%d spi=%d)", ret_sd, ret_spi);
    }
    /* spi3 is safe to suspend — BLE connect always resumes it before OTA can start */
}

void sd_set_ota_active(bool active)
{
    if (active) {
        atomic_set(&ota_active, 1);
        /* Force SPI3 bus to wake up immediately */
        sd_set_io_low_power(false);
        LOG_INF("OTA mode active: SPI3 bus resumed");
    } else {
        atomic_set(&ota_active, 0);
        LOG_INF("OTA mode inactive");
    }
}

bool sd_get_ota_active(void)
{
    return atomic_get(&ota_active) != 0;
}

void sd_write_pause(bool pause)
{
    if (pause) {
        atomic_set(&sd_write_paused, 1);

        if (k_current_get() != sd_worker_tid) {
            if (is_mounted && sd_worker_tid) {
                /* Static storage prevents UAR: if k_sem_take times out and the caller
                 * returns, the sd_worker still has a valid pointer when it later calls
                 * k_sem_give.  The atomic guards against concurrent callers sharing the
                 * same resp/req while a previous pause is still in-flight. */
                static atomic_t pause_in_flight;
                static struct read_resp resp;
                static sd_req_t req;

                if (!atomic_cas(&pause_in_flight, 0, 1)) {
                    LOG_WRN("[SD] sd_write_pause: pause already in-flight, skipping");
                    return;
                }

                /* Reset semaphore inside the guard so a stale give from a previous
                 * timed-out request cannot satisfy this new wait. */
                k_sem_init(&resp.sem, 0, 1);
                resp.res = 0;
                memset(&req, 0, sizeof(req));
                req.type = REQ_PAUSE_IO;
                req.u.create_file.resp = &resp;

                int qret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(500));
                if (qret == 0) {
                    k_sem_take(&resp.sem, K_MSEC(10000));
                }
                atomic_set(&pause_in_flight, 0);
            }
            return;
        }

        /* If we are here, we ARE the worker thread. Caller (handler) already flushed. */
        sd_set_io_low_power(true);
        LOG_INF("[AAD] SD writes paused (SPI3 suspended)");
    } else {
        atomic_set(&sd_write_paused, 0);
        LOG_INF("[AAD] SD writes resumed (lazy)");
    }
}

/* ------------------------------------------------------------------ */
/* LittleFS mount / unmount                                            */
/* ------------------------------------------------------------------ */

static void lfs_close_files(void)
{
    flush_batch_buffer_chunked();
    lfs_file_close(&lfs_fs, &lfs_fil_data);
    lfs_file_close(&lfs_fs, &lfs_fil_info);
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    current_filename[0] = '\0';
    current_file_path[0] = '\0';
    k_mutex_unlock(&current_filename_lock);
    /* Reset batch and sync counters so a post-recovery remount starts clean */
    write_batch_offset  = 0;
    write_batch_counter = 0;
    bytes_since_sync    = 0;
    current_file_size   = 0;
}

/*
 * Mount the filesystem.  LittleFS mounts existing FS or formats on first use.
 *
 * Key difference from FATFS: if there is any corruption LittleFS recovers
 * from its journal automatically â€” no mkfs needed, no power-loss dirty bit.
 */
/**
 * check_magic - verify the LFS format-version cookie on a freshly mounted FS.
 *
 *   0         the magic file exists and holds LFS_MAGIC_VALUE → a clean
 *             omi-offline filesystem this firmware family formatted.
 *   -ENOENT   the magic file is absent. omi-offline writes the cookie immediately
 *             after every format it performs (see write_magic() call sites), so an
 *             absent cookie on a *mountable* volume means the data was laid down by
 *             some other firmware (e.g. stock Omi) — not ours.
 *   -EBADMSG  the magic file exists but holds the wrong value → ghost mount on
 *             stale FatFS bytes that happened to pass the LFS superblock CRC.
 *
 * In every non-zero case the caller must lfs_unmount + lfs_format + lfs_mount +
 * write_magic to guarantee a clean slate. This is what makes the one-time wipe on
 * migration from a different firmware happen exactly once: the boot after the wipe
 * finds a valid cookie and keeps recordings.
 *
 * NOTE: reuses lfs_finfo_cfg because the info file is not open at mount time.
 */
static int check_magic(void)
{
    lfs_file_t f;
    uint32_t   magic = 0;

    int ret = lfs_file_opencfg(&lfs_fs, &f, LFS_MAGIC_PATH, LFS_O_RDONLY, &lfs_finfo_cfg);
    if (ret == LFS_ERR_OK) {
        lfs_ssize_t rd = lfs_file_read(&lfs_fs, &f, &magic, sizeof(magic));
        lfs_file_close(&lfs_fs, &f);
        if (rd == (lfs_ssize_t)sizeof(magic) && magic == LFS_MAGIC_VALUE) {
            return 0; /* clean omi-offline filesystem confirmed */
        }
        LOG_WRN("[SD] LFS magic mismatch (read=0x%08X expected=0x%08X) — ghost mount detected",
                magic, LFS_MAGIC_VALUE);
        return -EBADMSG;
    }

    LOG_WRN("[SD] LFS magic cookie absent — volume not formatted by omi-offline");
    return -ENOENT;
}

/**
 * write_magic - stamp the omi-offline format cookie onto a freshly formatted FS.
 *
 * Call after every lfs_format()+lfs_mount() so this firmware recognises its own
 * filesystem on the next boot. Skipping it anywhere would make that volume look
 * foreign on the next mount and get wiped — so it must follow every format.
 */
static int write_magic(void)
{
    lfs_file_t f;
    int ret = lfs_file_opencfg(&lfs_fs, &f, LFS_MAGIC_PATH, LFS_O_WRONLY | LFS_O_CREAT, &lfs_finfo_cfg);
    if (ret != LFS_ERR_OK) {
        LOG_ERR("[SD] Failed to create LFS magic file: %d", ret);
        return ret;
    }
    uint32_t magic = LFS_MAGIC_VALUE;
    lfs_ssize_t wr = lfs_file_write(&lfs_fs, &f, &magic, sizeof(magic));
    lfs_file_close(&lfs_fs, &f);
    if (wr != (lfs_ssize_t)sizeof(magic)) {
        LOG_ERR("[SD] LFS magic write failed: %d", (int)wr);
        return -EIO;
    }
    LOG_INF("[SD] LFS magic file written (fresh format)");
    return 0;
}

static int sd_mount(void)
{
    if (is_mounted) {
        return 0;
    }

    /* Retry loop: SD NAND needs up to ~200 ms to stabilise after power-on.
     * CTRL_INIT returns EINVAL (-22) or EIO (-5) when the card isn't ready. */
    uint32_t sector_count = 0;
    uint32_t sector_size = 0;
    int ret = -EIO;

    for (int attempt = 1; attempt <= 5; attempt++) {
        ret = sd_enable_power(true);
        if (ret < 0) {
            LOG_ERR("SD power on failed: %d", ret);
            return ret;
        }

        /* Progressive back-off: 50, 100, 150, 200, 250 ms */
        k_msleep(50 * attempt);

        ret = disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_CTRL_INIT, NULL);
        if (ret == 0) {
            break; /* init succeeded */
        }

        LOG_WRN("SD CTRL_INIT attempt %d/5 failed: %d", attempt, ret);
        (void) disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_CTRL_DEINIT, NULL);
        sd_enable_power(false);
        k_msleep(50);
    }

    if (ret != 0) {
        LOG_ERR("Disk CTRL_INIT failed after retries: %d", ret);
        return ret;
    }

    disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_GET_SECTOR_COUNT, &sector_count);
    disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_GET_SECTOR_SIZE, &sector_size);

    /* LittleFS only needs the disk to be 'initialised' from here on;
     * keep driver active (no CTRL_DEINIT) so callbacks work. */
    LOG_INF("SD: %u sectors x %u bytes = %u MB",
            sector_count,
            sector_size,
            (unsigned) ((uint64_t) sector_count * sector_size >> 20));

#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) {
        /* Raw ring backend: the disk is initialised; hand it to sd_ring. No
         * LittleFS mount. Mount an existing ring, or format one on first use
         * (foreign FS / fresh card / backend switch — the one-time SD wipe). */
        ring_total_sectors = sector_count;
        int rr = sd_ring_mount(sector_count);
        if (rr == -ENOENT) {
            LOG_WRN("[SD] no ring on card — formatting as ring (one-time SD wipe)");
            rr = sd_ring_format(sector_count);
        }
        if (rr == 0) {
            is_mounted = true;
            sd_ready = true;
            LOG_INF("[SD] ring backend mounted OK");
            return 0;
        }
        /* Ring couldn't mount OR format (persistent SD init failure that isn't a
         * crash, so the crash-loop auto-revert in main.c won't catch it). Don't
         * strand the device recording-blocked forever: revert the persisted
         * selection to LittleFS, flip g_backend so ring_active() is now false, and
         * fall through to the LittleFS mount below for this boot — a recoverable
         * state instead of a silent brick. */
        LOG_ERR("[SD] ring mount/format failed: %d — reverting to LittleFS", rr);
        (void) app_settings_save_storage_backend(STORAGE_BACKEND_LITTLEFS);
        g_backend = STORAGE_BACKEND_LITTLEFS;
    }
#endif

    /* read/prog stay at sector granularity (512);
     * cache = full block (4096) for multi-sector I/O. */
    uint32_t ss = (sector_size > 0) ? sector_size : DISK_SECTOR_SIZE;
    lfs_cfg.read_size = ss;
    lfs_cfg.prog_size = ss;
    lfs_cfg.cache_size = LFS_CACHE_SIZE;
    lfs_cfg.block_size = LFS_BLOCK_SIZE;
    lfs_cfg.block_count = sector_count / (LFS_BLOCK_SIZE / ss);

    /* Try to mount existing filesystem */
    int64_t mount_start_ms = k_uptime_get();
    ret = lfs_mount(&lfs_fs, &lfs_cfg);
    LOG_INF("[SD_BOOT] lfs_mount took %lld ms (ret=%d)", k_uptime_get() - mount_start_ms, ret);
    if (ret != LFS_ERR_OK) {
        LOG_WRN("LFS mount failed (%d) — existing data on SD will be ERASED by format", ret);
        LOG_WRN("If this device was previously using FATFS, all old recordings are lost.");
        ret = lfs_format(&lfs_fs, &lfs_cfg);
        if (ret != LFS_ERR_OK) {
            LOG_ERR("LFS format failed: %d", ret);
            sd_enable_power(false);
            return -EIO;
        }
        ret = lfs_mount(&lfs_fs, &lfs_cfg);
        if (ret != LFS_ERR_OK) {
            LOG_ERR("LFS mount after format failed: %d", ret);
            sd_enable_power(false);
            return -EIO;
        }
        /* Stamp the cookie on the freshly formatted filesystem (an unmountable card
         * means foreign/blank data — not an omi-offline filesystem). */
        (void)write_magic();
    } else {
        /* Mount succeeded — but only KEEP the data if this is genuinely an
         * omi-offline filesystem. check_magic() is non-zero when the cookie is
         * absent (foreign data, e.g. stock Omi firmware that left a mountable
         * LittleFS) or wrong (ghost mount on stale FatFS bytes). Either way,
         * format once so a migration from non-"oo" firmware starts clean; the
         * next boot finds the cookie and keeps recordings. Released omi-offline
         * builds (>= oo-1.9.3) always carry the cookie, so an upgrade never
         * re-wipes them. */
        int magic_ret = check_magic();
        if (magic_ret != 0) {
            LOG_WRN("[SD] Mounted volume is not an omi-offline filesystem (%d) — formatting once", magic_ret);
            lfs_unmount(&lfs_fs);
            ret = lfs_format(&lfs_fs, &lfs_cfg);
            if (ret != LFS_ERR_OK) {
                LOG_ERR("LFS format (migration wipe) failed: %d", ret);
                sd_enable_power(false);
                return -EIO;
            }
            ret = lfs_mount(&lfs_fs, &lfs_cfg);
            if (ret != LFS_ERR_OK) {
                LOG_ERR("LFS mount after migration wipe failed: %d", ret);
                sd_enable_power(false);
                return -EIO;
            }
            (void)write_magic();
        }
    }

    is_mounted = true;
    sd_ready = true;
    LOG_INF("LittleFS mounted OK (block_size=%u, block_count=%u, lookahead=%u bytes = %u blocks window)",
            (unsigned) lfs_cfg.block_size,
            (unsigned) lfs_cfg.block_count,
            (unsigned) lfs_cfg.lookahead_size,
            (unsigned) lfs_cfg.lookahead_size * 8);
    return 0;
}

static int sd_unmount(void)
{
    sd_ready = false;
#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) {
        /* Flush the partial sector + cursor so the shutdown is a clean durability
         * point, then drop power. No LittleFS handles are open in ring mode. Retry
         * once on failure (transient SD hiccup at a reboot/backend-switch boundary),
         * and surface the result instead of reporting a clean unmount — app_sd_off()
         * uses this path, so the caller can see the final batch wasn't persisted. */
        int sr = sd_ring_sync();
        if (sr != 0) {
            sr = sd_ring_sync();
        }
        is_mounted = false;
        sd_enable_power(false);
        if (sr != 0) {
            LOG_ERR("ring unmount: final sync failed (%d) — up to the last batch may be lost", sr);
        } else {
            LOG_INF("ring unmounted");
        }
        return sr;
    }
#endif
    close_read_handle();
    lfs_close_files();
    if (is_mounted) {
        lfs_unmount(&lfs_fs);
        is_mounted = false;
    }
    sd_enable_power(false);
    LOG_INF("LittleFS unmounted");
    return 0;
}

/* Power on + remount (NO lfs_fs_gc — that runs once at boot) and reopen the info
 * file that a prior unmount closed. The audio file is intentionally NOT reopened:
 * current_filename is empty, so the next write starts a fresh segment. Used by
 * the sd_write_blocked recovery path. Returns 0 on success, negative errno
 * otherwise; the caller decides what to do with the result. */
static int sd_remount_and_reopen_info(void)
{
    int64_t t0 = k_uptime_get();

    int res = sd_mount();
    if (res != 0) {
        LOG_ERR("[SD] remount failed: %d", res);
        return res;
    }

    res = lfs_file_opencfg(&lfs_fs, &lfs_fil_info, FILE_INFO_PATH,
                           LFS_O_CREAT | LFS_O_RDWR, &lfs_finfo_cfg);
    if (res < 0) {
        LOG_ERR("[SD] reopen info failed: %d", res);
        return res;
    }
    lfs_file_seek(&lfs_fs, &lfs_fil_info, 0, LFS_SEEK_SET);
    lfs_ssize_t rb = lfs_file_read(&lfs_fs, &lfs_fil_info, &current_offset_info,
                                   sizeof(current_offset_info));
    if (rb != (lfs_ssize_t) sizeof(current_offset_info)) {
        LOG_WRN("[SD] info read short (%d) — keeping cached copy", (int) rb);
    }

    LOG_INF("[SD] remount + reopen info in %lld ms", k_uptime_get() - t0);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Path helpers                                                        */
/* ------------------------------------------------------------------ */

static void build_file_path(const char *filename, char *path, size_t path_size)
{
    snprintf(path, path_size, "%s/%s", FILE_DATA_DIR, filename);
}

static bool filename_equals_ignore_case(const char *a, const char *b)
{
    if (!a || !b)
        return false;
    for (size_t i = 0; i < MAX_FILENAME_LEN; i++) {
        if (tolower((unsigned char) a[i]) != tolower((unsigned char) b[i]))
            return false;
        if (a[i] == '\0' && b[i] == '\0')
            return true;
        if (a[i] == '\0' || b[i] == '\0')
            return false;
    }
    return true;
}

/* ------------------------------------------------------------------ */
/* Boot: list existing audio files                                     */
/* ------------------------------------------------------------------ */

static void print_audio_files_at_boot(void)
{
    lfs_dir_t dir;
    struct lfs_info info;
    uint32_t file_count = 0;
    uint64_t total_size = 0;

    if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) < 0) {
        LOG_INF("[SD_BOOT] No audio directory found");
        return;
    }

    /* Clear file cache arrays before populating */
    memset(cached_file_meta, 0, sizeof(cached_file_meta));
    int list_count = 0;

    LOG_INF("========== AUDIO FILES ON SD CARD ==========");
    while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
        if (info.type != LFS_TYPE_REG)
            continue;
        char *dot = strrchr(info.name, '.');
        if (dot && strcasecmp(dot, ".txt") == 0) {
            LOG_INF("  [%u] %s - %u bytes", file_count + 1, info.name, (unsigned) info.size);
            total_size += info.size;
            file_count++;
            /* Also populate the file list cache so that get_file_list
             * can return data immediately during the long gc pre-warm. */
            if (list_count < MAX_AUDIO_FILES) {
                parse_filename_to_meta(info.name, (uint32_t)info.size, &cached_file_meta[list_count]);
                list_count++;
            }
        }
    }
    lfs_dir_close(&lfs_fs, &dir);
    cached_file_list_count = list_count;
    sort_cached_file_entries();
    cached_stats_file_count = file_count;
    cached_stats_total_size = total_size;
    cached_stats_valid_until_ms = k_uptime_get() + FILE_CACHE_TTL_MS;
    cached_total_file_count = file_count;
    cached_total_file_size = total_size;
    file_cache_valid = true;
    LOG_INF("[SD_BOOT] %u files, %u bytes total", file_count, (unsigned) total_size);
    LOG_INF("=============================================");
}

/* ------------------------------------------------------------------ */
/* File creation / continuation at boot                               */
/* ------------------------------------------------------------------ */

/* Helper: open a file and set the common state variables for continuation. */
static int _open_file_for_continuation(const char *filename, bool needs_rename)
{
    strncpy(current_filename, filename, sizeof(current_filename) - 1);
    current_filename[sizeof(current_filename) - 1] = '\0';
    build_file_path(current_filename, current_file_path, sizeof(current_file_path));

    int ret = lfs_file_opencfg(&lfs_fs, &lfs_fil_data, current_file_path, LFS_O_RDWR | LFS_O_APPEND, &lfs_fdata_cfg);
    if (ret < 0) {
        LOG_ERR("[SD_BOOT] open file for continuation failed: %d", ret);
        current_filename[0] = '\0';
        current_file_path[0] = '\0';
        return -1;
    }

    {
        lfs_ssize_t _sz = lfs_file_size(&lfs_fs, &lfs_fil_data);
        current_file_size = (_sz >= 0) ? (uint32_t)_sz : 0;
    }
    bytes_since_sync = 0;
    write_batch_offset = 0;
    write_batch_counter = 0;

    last_file_sync_uptime_ms = k_uptime_get();
    current_file_created_uptime_ms = k_uptime_get();
    current_file_needs_rename = needs_rename;
    return 0;
}

static int try_continue_latest_file(void)
{
    lfs_dir_t dir;
    struct lfs_info info;

    uint32_t current_time = get_utc_time();
    bool rtc_valid = (current_time != 0 && current_time >= 1700000000U);

    if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) < 0) {
        return -1;
    }

    char latest_utc_fn[MAX_FILENAME_LEN] = {0};
    uint32_t latest_utc_ts = 0;
    lfs_size_t latest_utc_sz = 0;

    char latest_tmp_fn[MAX_FILENAME_LEN] = {0};
    uint32_t latest_tmp_uptime = 0;
    lfs_size_t latest_tmp_sz = 0;

    while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
        if (info.type != LFS_TYPE_REG)
            continue;

        if (info.size < BOOT_MIN_AUDIO_FILE_SIZE)
            continue;

        if (strncmp(info.name, "TMP_", 4) == 0) {
            uint32_t uptime = (uint32_t)strtoul(info.name + 4, NULL, 16);
            if (uptime > latest_tmp_uptime) {
                latest_tmp_uptime = uptime;
                latest_tmp_sz = info.size;
                strncpy(latest_tmp_fn, info.name, sizeof(latest_tmp_fn) - 1);
            }
        } else {
            char *dot = strrchr(info.name, '.');
            if (dot && strcasecmp(dot, ".txt") == 0) {
                uint32_t ts = (uint32_t)strtoul(info.name, NULL, 16);
                if (ts > latest_utc_ts) {
                    latest_utc_ts = ts;
                    latest_utc_sz = info.size;
                    strncpy(latest_utc_fn, info.name, sizeof(latest_utc_fn) - 1);
                }
            }
        }
    }
    lfs_dir_close(&lfs_fs, &dir);

    /* 1. Prefer UTC file if valid and within window */
    if (rtc_valid && latest_utc_ts > 0) {
        int32_t diff = (int32_t)(current_time - latest_utc_ts);
        if (diff >= 0 && diff <= FILE_CONTINUE_THRESHOLD_SEC) {
            LOG_INF("[SD_BOOT] Continuing UTC file: %s (diff=%d s, sz=%u)",
                    latest_utc_fn, diff, (unsigned)latest_utc_sz);
            return _open_file_for_continuation(latest_utc_fn, /*needs_rename=*/false);
        }
    }

    /* 2. Fall back to TMP file (always needs rename) */
    if (latest_tmp_uptime > 0) {
        LOG_INF("[SD_BOOT] Continuing TMP file: %s (sz=%u)",
                latest_tmp_fn, (unsigned)latest_tmp_sz);
        return _open_file_for_continuation(latest_tmp_fn, /*needs_rename=*/true);
    }

    return -1;
}

static int create_audio_file_with_timestamp(void)
{
#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) {
        return ring_create_segment();
    }
#endif

    bool rtc_valid = rtc_is_valid();
    uint32_t timestamp = 0;

    if (rtc_valid) {
        timestamp = get_utc_time();
        if (timestamp == 0 || timestamp < 1700000000U)
            rtc_valid = false;
    }

    /* Close current file if open */
    if (current_filename[0] != '\0') {
        /* Flush the pending batch into the OLD file BEFORE measuring it, so audio
         * still buffered in write_batch_buffer at the rotation counts toward the
         * size (flush_batch_buffer_chunked updates current_file_size synchronously
         * via lfs_file_write). Without this a short recording whose audio hadn't been
         * flushed yet would read as an empty bin. */
        flush_batch_buffer_chunked();
        /* Diagnostics: a bin closed with no audio beyond the inline metadata header
         * (0xFFFFFFFB) means the file was opened+rotated but nothing landed in it —
         * the on-device signature of a lost Priority Recording (0xFFFFFFF8 marker +
         * force-captured frames dropped at the rotate). Surface it over BLE
         * (0x19B10062) so it's visible without an RTT capture. */
        if (current_file_size <= sizeof(RecordingHeader_v1_t)) {
            atomic_inc(&empty_bin_rotations);
        }
        lfs_file_close(&lfs_fs, &lfs_fil_data);
        k_mutex_lock(&current_filename_lock, K_FOREVER);
        current_filename[0] = '\0';
        k_mutex_unlock(&current_filename_lock);
    }

    /* Ensure audio directory exists */
    struct lfs_info dir_info;
    if (lfs_stat(&lfs_fs, FILE_DATA_DIR, &dir_info) < 0) {
        int mk = lfs_mkdir(&lfs_fs, FILE_DATA_DIR);
        if (mk < 0 && mk != LFS_ERR_EXIST) {
            LOG_ERR("mkdir %s failed: %d", FILE_DATA_DIR, mk);
            return mk;
        }
    }

    /* Read device_session_id once via atomic_get — it's atomic_t since
     * the lazy-init in transport.c uses atomic_cas (A8/B7). */
    uint32_t sid_snap = (uint32_t)atomic_get(&device_session_id);

    /* Build a COLLISION-PROOF filename. The identity is <seconds>_<session> (or
     * TMP_<uptime_ms>_<session> pre-time-sync), which is second-granular. Two
     * create_new_audio_file() calls in the same UTC second — e.g. a ~5-min
     * natural rotation landing on the same second as a button/priority rotation —
     * would otherwise resolve to the same name; the old LFS_O_CREAT|LFS_O_APPEND
     * open then SILENTLY REOPENED and concatenated two recordings into one file,
     * and left it as the active write target (the source of the unreadable/stuck
     * bin the app kept re-reading). LFS_O_EXCL makes the open fail on an existing
     * name; on collision we bump the identity and retry. The audio timeline is
     * unaffected — the app anchors each recording to the inline 0xFFFFFFFB
     * header's utc_start_ms (written from real time below), not the filename. */
    char fname[MAX_FILENAME_LEN];
    char fpath[64];
    int ret = LFS_ERR_EXIST;
    uint32_t ident = rtc_valid ? timestamp : (uint32_t) k_uptime_get_32();
    for (int attempt = 0; attempt < 16; attempt++) {
        if (rtc_valid) {
            snprintf(fname, sizeof(fname), "%08X_%08X.txt", ident, sid_snap);
        } else {
            snprintf(fname, sizeof(fname), "TMP_%08X_%08X.txt", ident, sid_snap);
        }
        build_file_path(fname, fpath, sizeof(fpath));
        ret = lfs_file_opencfg(&lfs_fs, &lfs_fil_data, fpath, LFS_O_CREAT | LFS_O_EXCL | LFS_O_RDWR,
                               &lfs_fdata_cfg);
        if (ret != LFS_ERR_EXIST) {
            break; /* created, or a real (non-collision) open error */
        }
        LOG_WRN("Audio filename collision on %s — bumping identity and retrying", fname);
        ident++; /* next second (UTC) / next ms (pre-time-sync TMP_) */
    }

    if (ret < 0) {
        LOG_ERR("Failed to create %s: %d", fpath, ret);
        k_mutex_lock(&current_filename_lock, K_FOREVER);
        current_filename[0] = '\0';
        current_file_path[0] = '\0';
        k_mutex_unlock(&current_filename_lock);
        return ret;
    }

    k_mutex_lock(&current_filename_lock, K_FOREVER);
    strncpy(current_filename, fname, sizeof(current_filename) - 1);
    current_filename[sizeof(current_filename) - 1] = '\0';
    strncpy(current_file_path, fpath, sizeof(current_file_path) - 1);
    current_file_path[sizeof(current_file_path) - 1] = '\0';
    current_file_needs_rename = !rtc_valid;
    k_mutex_unlock(&current_filename_lock);

    LOG_INF("Creating audio file: %s", current_file_path);
    if (!rtc_valid)
        LOG_WRN("RTC not synced, temp file: %s", current_filename);

    if (lfs_file_size(&lfs_fs, &lfs_fil_data) == 0) {
        RecordingHeader_v1_t header = {
            .marker = 0xFFFFFFFB,
            .payload_len = 28,
            .utc_start_ms = rtc_get_utc_time_ms(),
            .uptime_start_ms = (uint64_t)k_uptime_get(),
            .session_id = (uint32_t)atomic_get(&device_session_id),
            .version = 1,
        };
        uint32_t imu_ts = 0;
        if (lsm6dsl_timestamp_read(&imu_ts) == 0) {
            header.imu_ticks = imu_ts;
        } else {
            header.imu_ticks = 0;
        }
        lfs_file_write(&lfs_fs, &lfs_fil_data, &header, sizeof(header));
        lfs_file_sync(&lfs_fs, &lfs_fil_data);
    }

    {
        lfs_ssize_t _sz = lfs_file_size(&lfs_fs, &lfs_fil_data);
        current_file_size = (_sz >= 0) ? (uint32_t)_sz : 0;
    }
    bytes_since_sync = 0;
    write_batch_offset = 0;
    write_batch_counter = 0;

    writing_error_counter = 0;
    sd_write_blocked = false;
    last_file_sync_uptime_ms = k_uptime_get();
    current_file_created_uptime_ms = k_uptime_get();

    LOG_INF("Audio file created: %s", current_filename);
    /* Deferrable: a rotation during a sync session must not force a mid-session
     * rebuild (it never changes index 0). The rebuild happens once the session
     * ends so the new file is enumerated then. */
    invalidate_file_cache_deferrable();
    return 0;
}


/* ------------------------------------------------------------------ */
/* File rotation helper                                                */
/* ------------------------------------------------------------------ */

/* Minimum file age before a BLE-connect can trigger early rotation (2 minutes).
 * Avoids creating tiny files when BLE reconnects after a brief disconnect. */
#define BLE_CONNECT_MIN_ROTATE_AGE_MS (2 * 60 * 1000)

static bool should_rotate_file(void)
{
    if (current_file_created_uptime_ms < 0)
        return false;

    int64_t file_age_ms = k_uptime_get() - current_file_created_uptime_ms;

    if (file_age_ms >= FILE_ROTATION_INTERVAL_MS)
        return true;

    /* On BLE connect: rotate early if file is old enough so the app can
     * immediately download the completed recording without waiting up to
     * FILE_ROTATION_INTERVAL_MS for the normal rotation timer. */
    if (atomic_cas(&pending_rotate_on_ble_connect, 1, 0)) {
        if (file_age_ms >= BLE_CONNECT_MIN_ROTATE_AGE_MS) {
            LOG_INF("[SD_WORK] Rotating file on BLE connect (age %lld ms)", file_age_ms);
            return true;
        }
    }

    return false;
}

/* ------------------------------------------------------------------ */
/* Filename sort (hex timestamp, oldest first)                        */
/* ------------------------------------------------------------------ */

/* TMP_ files have no valid hex timestamp — strtoul returns 0, which would
 * incorrectly sort them as "oldest". Return UINT32_MAX so they sort last,
 * after all real timestamped files. TMP files are the currently-recording
 * file (pre-time-sync) and should never be synced before being renamed. */
static void update_cached_free_bytes(void)
{
    if (lfs_cfg.block_count == 0) return;
    uint64_t total_cap = (uint64_t)lfs_cfg.block_count * lfs_cfg.block_size;
    /* Reserve ~2% for LFS metadata (CTZ skip-lists, dir entries, superblock).
       Minimum reservation: 512 KB to avoid false "disk full" near capacity. */
    uint64_t metadata_reserve = total_cap / 50;  /* 2% */
    if (metadata_reserve < (512 * 1024)) metadata_reserve = 512 * 1024;
    uint64_t usable = (total_cap > metadata_reserve)
                      ? (total_cap - metadata_reserve) : 0;
    cached_free_bytes = (cached_total_file_size < usable)
                        ? (uint32_t)(usable - cached_total_file_size)
                        : 0;
}

static void invalidate_file_cache(void)
{
    file_cache_valid = false;
    cached_stats_valid_until_ms = 0;
}

/* Invalidate the cache UNLESS a storage sync session is active — used by the
 * rotation and active-file size paths, which (unlike deletes) never touch index
 * 0, all the fast-path sync reads. Rebuilding mid-session would re-enumerate +
 * re-sort on the single SD worker and stall the in-flight BLE read, so during a
 * session we simply skip the invalidation and leave the frozen indices intact.
 * The dropped rebuild is not lost: the next CMD_LIST_FILES forces a fresh
 * enumeration (sd_invalidate_file_cache_blocking) before handing the app a list,
 * so a file this rotation created is picked up then. Delete keeps the immediate
 * invalidate_file_cache() since it does change index 0. */
static void invalidate_file_cache_deferrable(void)
{
    if (is_storage_sync_active()) {
        return;
    }
    invalidate_file_cache();
}

static void sort_cached_file_entries(void)
{
    if (cached_file_list_count <= 1) {
        return;
    }

    for (int i = 1; i < cached_file_list_count; i++) {
        AudioFileMeta_t tmp_meta = cached_file_meta[i];

        int j = i - 1;
        while (j >= 0 && compare_meta(&cached_file_meta[j], &tmp_meta) > 0) {
            cached_file_meta[j + 1] = cached_file_meta[j];
            j--;
        }

        cached_file_meta[j + 1] = tmp_meta;
    }
}

static void update_current_file_cache_size(uint32_t delta)
{
    if (!file_cache_valid || delta == 0 || current_filename[0] == '\0') {
        return;
    }

    /* Snapshot filename under lock so a concurrent BLE rename cannot
       change it between our cache lookup and the size update. */
    char fname_snap[MAX_FILENAME_LEN];
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    if (current_filename[0] == '\0') {
        k_mutex_unlock(&current_filename_lock);
        return;
    }
    strncpy(fname_snap, current_filename, sizeof(fname_snap) - 1);
    fname_snap[sizeof(fname_snap) - 1] = '\0';
    k_mutex_unlock(&current_filename_lock);

    cached_total_file_size += delta;
    cached_stats_total_size = cached_total_file_size;
    cached_stats_file_count = cached_total_file_count;
    update_cached_free_bytes();
    cached_stats_valid_until_ms = k_uptime_get() + FILE_CACHE_TTL_MS;

    k_mutex_lock(&file_cache_mutex, K_FOREVER);
    AudioFileMeta_t current_meta;
    parse_filename_to_meta(fname_snap, current_file_size, &current_meta);

    for (int i = 0; i < cached_file_list_count; i++) {
        if (compare_meta(&cached_file_meta[i], &current_meta) == 0) {
            cached_file_meta[i].file_size += delta;
            k_mutex_unlock(&file_cache_mutex);
            return;
        }
    }

    /* Cache became stale (e.g. filename not indexed due truncation). This fires
     * for every write to a just-rotated active file that isn't in the frozen
     * cache, so during a sync it must defer rather than force a mid-session
     * rebuild (the active file is excluded from the sync anyway). */
    invalidate_file_cache_deferrable();
    k_mutex_unlock(&file_cache_mutex);
}

static int refresh_file_cache(void)
{

    if (!is_mounted) {
        return -ENODEV;
    }

#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) {
        if (is_storage_sync_active() && file_cache_valid) {
            return 0; /* keep frozen indices stable during an active sync session */
        }
        return ring_refresh_file_cache();
    }
#endif

    if (is_storage_sync_active() && file_cache_valid) {
        LOG_DBG("refresh_file_cache: session active, skipping refresh to maintain stable indices");
        return 0;
    }

    lfs_dir_t dir;
    struct lfs_info info;
    int list_count = 0;
    uint32_t total_count = 0;
    uint64_t total_size = 0;

    k_mutex_lock(&file_cache_mutex, K_FOREVER);
    memset(cached_file_meta, 0, sizeof(cached_file_meta));

    int dres = lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR);
    if (dres < 0) {
        if (dres == LFS_ERR_NOENT) {
            cached_file_list_count = 0;
            cached_total_file_count = 0;
            cached_total_file_size = 0;
            cached_stats_file_count = 0;
            cached_stats_total_size = 0;
            update_cached_free_bytes();
            cached_stats_valid_until_ms = k_uptime_get() + FILE_CACHE_TTL_MS;
            file_cache_valid = true;
            k_mutex_unlock(&file_cache_mutex);
            return 0;
        }
        k_mutex_unlock(&file_cache_mutex);
        return dres;
    }

    while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
        if (info.type != LFS_TYPE_REG) {
            continue;
        }

        char *dot = strrchr(info.name, '.');
        if (!dot || strcasecmp(dot, ".txt") != 0) {
            continue;
        }

        total_count++;
        total_size += info.size;

        if (list_count < MAX_AUDIO_FILES) {
            parse_filename_to_meta(info.name, (uint32_t)info.size, &cached_file_meta[list_count]);
            list_count++;
        }
    }
    lfs_dir_close(&lfs_fs, &dir);

    cached_file_list_count = list_count;
    sort_cached_file_entries();

    if (current_filename[0] != '\0') {
        AudioFileMeta_t current_meta;
        parse_filename_to_meta(current_filename, current_file_size, &current_meta);
        for (int i = 0; i < cached_file_list_count; i++) {
            if (compare_meta(&cached_file_meta[i], &current_meta) == 0) {
                total_size = total_size - cached_file_meta[i].file_size + current_file_size;
                cached_file_meta[i].file_size = current_file_size;
                break;
            }
        }
    }

    /* Exclude the currently-open recording from the reported count — it is not
     * yet available for sync (send_file_list_response skips it too). */
    uint32_t reportable_count = total_count;
    if (current_filename[0] != '\0' && reportable_count > 0) {
        reportable_count--;
    }
    cached_total_file_count = reportable_count;
    cached_total_file_size = total_size;
    cached_stats_file_count = reportable_count;
    cached_stats_total_size = total_size;
    update_cached_free_bytes();

    /* Do NOT call refresh_free_bytes_if_stale() here. lfs_fs_size() traverses
     * every block in the filesystem and can take 30+ seconds on a full card.
     * It was blocking the file-list response path, causing the 30 s semaphore
     * in get_audio_file_list_with_sizes() to expire (especially after a time-
     * sync, which invalidates both caches together). Free-space is computed
     * lazily the next time it is actually queried. */

    cached_stats_valid_until_ms = k_uptime_get() + FILE_CACHE_TTL_MS;
    file_cache_valid = true;

    /* Reset the block flag if refresh was successful — the card is working now. */
    sd_write_blocked = false;
    writing_error_counter = 0;

    k_mutex_unlock(&file_cache_mutex);
    return 0;
}

static int ensure_file_cache(void)
{
    if (file_cache_valid) {
        return 0;
    }
    return refresh_file_cache();
}

/* ------------------------------------------------------------------ */
/* Filename rename after time-sync                                     */
/* ------------------------------------------------------------------ */

void sd_update_filename_after_timesync(uint32_t synced_utc_time)
{
    if (!is_mounted)
        return;

    /* Ring segments carry their timestamp in the table and are not renamed:
     * pre-time-sync segments keep their uptime-based key (shown "unorganized",
     * like LittleFS TMP files before rename) and the app anchors real timing to
     * each segment's inline 0xFFFFFFFB header. The REQ_TIME_SYNCED handler just
     * rotates to a fresh UTC-keyed segment; there is no directory to walk here. */
    if (ring_active()) {
        return;
    }

    /* Calculate the UTC offset between uptime and real-world time */
    uint32_t rtc_offset = synced_utc_time - (uint32_t)(k_uptime_get() / 1000U);
    LOG_INF("Time sync received: offset is %u s", rtc_offset);

    /* 
     * Retroactively rename all CLOSED temporary files.
     * Use a search-and-repeat loop to avoid renaming while iterating the directory
     * (safe for LittleFS) and to save RAM (no large buffer of filenames).
     */
    bool file_renamed;
    do {
        file_renamed = false;
        lfs_dir_t dir;
        struct lfs_info info;

        if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) < 0) {
            break;
        }

        while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
            /* Only rename finished TMP_ segments. The active one was already
             * rotated out by the worker before calling this function. */
            if (info.type == LFS_TYPE_REG && strncmp(info.name, "TMP_", 4) == 0 &&
                strcmp(info.name, current_filename) != 0) {

                char old_path[64], new_path[64], new_fn[MAX_FILENAME_LEN];
                uint32_t original_uptime_ms = (uint32_t)strtoul(info.name + 4, NULL, 16);
                uint32_t session_id = 0;
                const char *sep = strchr(info.name + 4, '_');
                if (sep) {
                    session_id = (uint32_t)strtoul(sep + 1, NULL, 16);
                }

                // Only rename files that belong to the current session. Files from
                // previous sessions have an uptime that is not relative to the
                // current rtc_offset and would result in incorrect timestamps.
                if (session_id != (uint32_t)atomic_get(&device_session_id)) {
                    continue;
                }

                uint32_t correct_ts = (original_uptime_ms / 1000U) + rtc_offset;
                snprintf(new_fn, MAX_FILENAME_LEN, "%08X_%08X.txt", correct_ts, session_id);
                build_file_path(new_fn, new_path, sizeof(new_path));

                /* Collision-proof the target. correct_ts is second-granular
                 * (uptime_ms / 1000), so two TMP_ files whose uptimes fall in the
                 * same second map to the same UTC name — and lfs_rename would
                 * OVERWRITE (destroy) the first. Bump the target second until it is
                 * free (also dodges a real UTC file created right after time-sync).
                 * lfs_stat is read-only, so probing here is safe while the dir cursor
                 * is still open — only the lfs_rename below mutates this directory and
                 * must be preceded by lfs_dir_close(). Bounded; the <=1s nudge is below
                 * the app's stitch threshold. Rename-time analogue of the LFS_O_EXCL
                 * guard in create_audio_file_with_timestamp(). */
                struct lfs_info existing;
                for (int bump = 0; bump < 16 && lfs_stat(&lfs_fs, new_path, &existing) == 0; bump++) {
                    correct_ts++;
                    snprintf(new_fn, MAX_FILENAME_LEN, "%08X_%08X.txt", correct_ts, session_id);
                    build_file_path(new_fn, new_path, sizeof(new_path));
                }

                if (lfs_stat(&lfs_fs, new_path, &existing) == 0) {
                    /* No free UTC second within the budget — renaming would OVERWRITE
                     * (destroy) an existing recording. Skip ONLY this file (leave it
                     * as TMP_, still syncable with a derived timestamp) and keep
                     * scanning, so one collision can't strand unrelated recordings.
                     * The dir cursor is untouched (no mutation yet), so continue
                     * iterating. Needs 16 consecutive occupied seconds — effectively
                     * unreachable in practice. */
                    LOG_ERR("Retro-rename: no free UTC slot for %s within budget — leaving as TMP_", info.name);
                    continue;
                }

                /* Free slot found. lfs_rename mutates this directory, so close the
                 * iteration cursor first (LittleFS-safe), then restart the scan. */
                build_file_path(info.name, old_path, sizeof(old_path));
                lfs_dir_close(&lfs_fs, &dir);

                if (lfs_rename(&lfs_fs, old_path, new_path) == 0) {
                    LOG_INF("Retroactive rename: %s -> %s", info.name, new_fn);
                } else {
                    LOG_ERR("Failed to rename %s", info.name);
                }

                file_renamed = true;
                break;
            }
        }

        if (!file_renamed) {
            lfs_dir_close(&lfs_fs, &dir);
        }

        /* Yield to allow other prio-msgq requests (like get list) to be processed
         * between renames if there are many files. */
        k_yield();
    } while (file_renamed);
    invalidate_file_cache();
}

/* ------------------------------------------------------------------ */
/* Internal helpers: file list, file stats                            */
/* ------------------------------------------------------------------ */



/* ------------------------------------------------------------------ */
/* SD worker thread                                                    */
/* ------------------------------------------------------------------ */

void sd_worker_thread(void)
{
    sd_req_t req;
    int res;

    /* Select the storage backend for this boot (persisted; a switch reboots). */
    g_backend = app_settings_get_storage_backend();
    LOG_INF("[SD_BOOT] storage backend: %s", ring_active() ? "ring" : "littlefs");

    /* ---- Mount ---- */
    res = sd_mount();
    if (res != 0) {
        LOG_ERR("[SD_WORK] mount failed: %d", res);
        sd_write_blocked = true;
        return;
    }

#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) {
        /* sd_mount() already brought the ring up. None of the LittleFS boot steps
         * (audio dir, allocator pre-warm, info.txt, initial-file continuation)
         * apply — the first audio write lazily opens the first segment. Skip
         * straight to marking the SD ready so BLE bring-up / boot warming proceed. */
        goto sd_boot_done;
    }
#endif

    /* ---- Ensure audio directory exists ---- */
    struct lfs_info dir_info;
    if (lfs_stat(&lfs_fs, FILE_DATA_DIR, &dir_info) < 0) {
        int mk = lfs_mkdir(&lfs_fs, FILE_DATA_DIR);
        if (mk < 0 && mk != LFS_ERR_EXIST) {
            LOG_ERR("[SD_WORK] mkdir audio failed: %d â€” write path blocked", mk);
            sd_write_blocked = true;
        }
    }

    /* ---- Print existing files at boot ---- */
    print_audio_files_at_boot();

    /* ---- Pre-warm LFS block allocator ---- */
    {
        int64_t gc_start_ms = k_uptime_get();
        LOG_INF("[SD_BOOT] Pre-warming LFS allocator (lookahead=%u bytes, %u blocks window)...",
                LFS_LOOKAHEAD_SIZE,
                LFS_LOOKAHEAD_SIZE * 8);
        int gc_res = lfs_fs_gc(&lfs_fs);
        int64_t gc_elapsed_ms = k_uptime_get() - gc_start_ms;
        if (gc_res < 0) {
            LOG_WRN("[SD_BOOT] lfs_fs_gc failed: %d (took %lld ms)", gc_res, gc_elapsed_ms);
            if (gc_res == LFS_ERR_CORRUPT) {
                LOG_ERR("[SD_BOOT] Hard corruption detected (-84) during GC. Forcing format...");
                lfs_unmount(&lfs_fs);
                lfs_format(&lfs_fs, &lfs_cfg);
                lfs_mount(&lfs_fs, &lfs_cfg);
                write_magic();
            }
        } else {
            LOG_INF("[SD_BOOT] LFS allocator pre-warmed OK in %lld ms", gc_elapsed_ms);
        }
    }

    /* ---- Open / create info file ---- */
    {
        struct lfs_info info_lstat;
        bool info_exists = (lfs_stat(&lfs_fs, FILE_INFO_PATH, &info_lstat) == 0);
        bool need_init_off = !info_exists || (info_lstat.size < sizeof(sd_offset_info_t));

        res = lfs_file_opencfg(&lfs_fs, &lfs_fil_info, FILE_INFO_PATH, LFS_O_CREAT | LFS_O_RDWR, &lfs_finfo_cfg);
        if (res < 0) {
            LOG_ERR("[SD_WORK] open info failed: %d", res);
            if (res == LFS_ERR_CORRUPT) {
                LOG_ERR("[SD_BOOT] Hard corruption detected (-84) opening info. Forcing format...");
                lfs_unmount(&lfs_fs);
                lfs_format(&lfs_fs, &lfs_cfg);
                lfs_mount(&lfs_fs, &lfs_cfg);
                write_magic();
                res = lfs_file_opencfg(&lfs_fs, &lfs_fil_info, FILE_INFO_PATH, LFS_O_CREAT | LFS_O_RDWR, &lfs_finfo_cfg);
            }
            if (res < 0) {
                sd_write_blocked = true;
            }
        }
        
        if (res >= 0) {
            if (need_init_off) {
                memset(&current_offset_info, 0, sizeof(current_offset_info));
                lfs_ssize_t bw = lfs_file_write(&lfs_fs, &lfs_fil_info, &current_offset_info, sizeof(current_offset_info));
                if (bw != (lfs_ssize_t) sizeof(current_offset_info)) {
                    LOG_ERR("[SD_WORK] init info write failed: %d", (int) bw);
                } else {
                    lfs_file_sync(&lfs_fs, &lfs_fil_info);
                }
            } else {
                lfs_file_seek(&lfs_fs, &lfs_fil_info, 0, LFS_SEEK_SET);
                lfs_ssize_t rb = lfs_file_read(&lfs_fs, &lfs_fil_info, &current_offset_info, sizeof(current_offset_info));
                if (rb != (lfs_ssize_t) sizeof(current_offset_info)) {
                    LOG_ERR("[SD_WORK] read offset info failed: %d", (int) rb);
                    memset(&current_offset_info, 0, sizeof(current_offset_info));
                } else {
                    LOG_INF("[SD_WORK] Loaded offset: file=%s off=%u",
                            current_offset_info.oldest_filename,
                            current_offset_info.offset_in_file);
                }
            }
        }
    }

    /* ---- Open initial audio file ---- */
    res = try_continue_latest_file();
    if (res < 0) {
        res = create_audio_file_with_timestamp();
        if (res < 0) {
            LOG_ERR("[SD_WORK] initial file create failed: %d â€” write blocked", res);
            if (res == LFS_ERR_CORRUPT && !sd_write_blocked) {
                LOG_ERR("[SD_BOOT] Hard corruption detected (-84) creating file. Forcing format...");
                lfs_unmount(&lfs_fs);
                lfs_format(&lfs_fs, &lfs_cfg);
                lfs_mount(&lfs_fs, &lfs_cfg);
                write_magic();
                res = create_audio_file_with_timestamp();
            }
            if (res < 0) {
                sd_write_blocked = true;
            }
        }
    }

    /* ---- SD boot init complete, allow writes ---- */
#ifdef CONFIG_OMI_AUDIO_RING
sd_boot_done:
#endif
    atomic_set(&sd_boot_ready, 1);
    {
        long dropped = (long)atomic_get(&boot_dropped_frames);
        LOG_INF("[SD_BOOT] SD card ready for audio writes (boot took %lld ms, "
                "%ld audio frames dropped during boot)", k_uptime_get(), dropped);
        if (dropped > 0) {
            LOG_WRN("[SD_BOOT] %ld audio frames were dropped while SD was booting", dropped);
        }
    }

    /* Suspend SPI now that boot is complete — saves ~0.5 mA idle current
     * during the initial batch accumulation window. OTA is protected: the
     * MGMT_EVT_OP_IMG_MGMT_DFU_STARTED callback calls sd_set_ota_active(true)
     * which resumes SPI before any flash writes occur. */
    sd_set_io_low_power(true);

    /* Write-fairness: consecutive reads served without a write turn. */
    uint32_t reads_since_write = 0;

    /* ---- Main loop ---- */
    while (1) {

        /* Handle deferred control requests first (when queue was saturated). */
        if (atomic_cas(&pending_flush_on_ble_connect, 1, 0)) {
            if (!atomic_get(&current_file_deleted) && current_filename[0] != '\0') {
                sd_set_io_low_power(false);
                int sr;
#ifdef CONFIG_OMI_AUDIO_RING
                if (ring_active()) {
                    /* Ring mode: lfs_fil_data is never opened — flush the cursor via
                     * the ring backend instead of the inactive LittleFS handle. */
                    sr = sd_ring_sync();
                    if (sr == 0) {
                        ring_bytes_since_sync = 0;
                    }
                } else
#endif
                {
                    sr = lfs_file_sync(&lfs_fs, &lfs_fil_data);
                }
                sd_set_io_low_power(true);
                if (sr < 0) {
                    atomic_set(&pending_flush_on_ble_connect, 1);
                } else {
                    data_sync_gen++;
                    bytes_since_sync = 0;
                    last_file_sync_uptime_ms = k_uptime_get();
                    LOG_INF("[SD_WORK] Deferred BLE flush OK (%u bytes)", current_file_size);
                }
            }
        }
        if (atomic_cas(&pending_time_synced, 1, 0)) {
            req.type = REQ_TIME_SYNCED;
            req.u.time_synced.utc_time = pending_timesync_utc;
            goto handle_req;
        }

        /* Priority queue normally checked first (no-wait), but write fairness:
         * once we've served MAX_READS_BETWEEN_WRITES reads back-to-back while
         * audio writes are waiting, skip the read this iteration so a write
         * gets a turn. Prevents a steady read stream (active sync) from
         * starving audio writes and filling sd_msgq. */
        bool force_write = (k_msgq_num_used_get(&sd_msgq) > 0) &&
                           (reads_since_write >= MAX_READS_BETWEEN_WRITES);
        if (force_write) {
            atomic_inc(&write_fair_activations);
        } else if (k_msgq_get(&sd_prio_msgq, &req, K_NO_WAIT) == 0) {
            reads_since_write++;
            goto handle_req;
        }

        /* Block waiting for the next audio write.
         * Short timeout when BLE connected (keeps reads responsive);
         * longer when disconnected (saves CPU/power).
         * On timeout, flush any partially-filled batch buffer. */
        k_timeout_t write_wait = atomic_get(&ble_connected) ? K_MSEC(50) : K_MSEC(500);
        if (k_msgq_get(&sd_msgq, &req, write_wait) == 0) {
            reads_since_write = 0;
            goto handle_req;
        }

#ifdef CONFIG_OMI_AUDIO_RING
        /* Ring: no batch buffer. On the write-wait timeout, commit the cursor for
         * audio appended since the last sync — but rate-gated to SD_FSYNC_INTERVAL_MS
         * exactly like the LittleFS fsync path below, NOT on every timeout. When BLE
         * is connected (the app is connected whenever it is open) write_wait is 50 ms,
         * shorter than the ~86 ms audio-block spacing, so this branch fires in the gap
         * after nearly every block; an ungated commit meant a full partial-sector +
         * CTRL_SYNC + cursor write ~12x/s during active connected audio. The threshold
         * (RING_SYNC_BYTES) and any critical marker still force earlier commits, so a
         * crash in the sub-interval window loses at most the same bytes the byte cap
         * already tolerates. */
        if (ring_active()) {
            /* Commit when the periodic gate elapses OR a prior commit failed and its
             * 2 s soft-recovery has passed: the SD_FSYNC_INTERVAL_MS gate throttles
             * ROUTINE periodic commits, but must NOT delay recovering undurable data —
             * notably a failed session-end marker after audio has stopped, when no
             * further write arrives to retry it via the write path. The retry honors
             * the same 2 s backoff the write path uses so a persistently-failing card
             * isn't hammered every timeout tick. */
            bool ring_sync_due = (k_uptime_get() - last_file_sync_uptime_ms) >= SD_FSYNC_INTERVAL_MS;
            bool ring_retry_due = sd_write_blocked &&
                                  (k_uptime_get() - last_write_error_uptime_ms) > 2000;
            if (ring_bytes_since_sync > 0 && (ring_sync_due || ring_retry_due)) {
                sd_set_io_low_power(false);
                if (sd_ring_sync() == 0) {
                    ring_bytes_since_sync = 0;
                    last_file_sync_uptime_ms = k_uptime_get();
                    sd_write_blocked = false; /* recovered — unblock the write path */
                    writing_error_counter = 0;
                } else {
                    /* Still failing: keep ring_bytes_since_sync pending and stay
                     * blocked so ring_retry_due fires again after the 2 s backoff. */
                    last_write_error_uptime_ms = k_uptime_get();
                    sd_write_blocked = true;
                }
                sd_set_io_low_power(true);
            }
            continue;
        }
#endif

        /* Timeout: flush batch if data is waiting. */
        if (write_batch_offset > 0) {
            sd_set_io_low_power(false);
            flush_batch_buffer_chunked();
            if (bytes_since_sync > 0 &&
                (k_uptime_get() - last_file_sync_uptime_ms) >= SD_FSYNC_INTERVAL_MS) {
                lfs_file_sync(&lfs_fs, &lfs_fil_data);
                data_sync_gen++;
                bytes_since_sync = 0;
                last_file_sync_uptime_ms = k_uptime_get();
            }
            sd_set_io_low_power(true);
        }
        continue;

    handle_req:
        /* Wake SPI for all requests except write data — write data manages
         * its own SPI gating internally via spi_woken in process_write_data_req. */
        if (req.type != REQ_WRITE_DATA) {
            sd_set_io_low_power(false);
        }

        switch (req.type) {

        /* ---- Write data ---- */
        case REQ_WRITE_DATA: {
#ifdef CONFIG_OMI_AUDIO_RING
            /* Ring writes touch the SD every block (append + periodic cursor sync),
             * unlike the LittleFS path which only buffers to RAM here. Wake the bus
             * ONCE for the whole write burst (this req + the drain loop below) and
             * suspend after — never per block. The LittleFS path stays suspended
             * while buffering and wakes only on a flush; the ring must mirror that
             * or the per-block pm_device power-cycle starves sd_msgq. */
            bool ring_spi_woken = false;
            if (ring_active()) {
                sd_set_io_low_power(false);
                ring_spi_woken = true;
            }
#endif
            process_write_data_req(&req);
            reads_since_write = 0;
            /* Drain up to 16 additional write/save_offset messages in one pass
             * to improve SD throughput by batching more work per wake. The
             * first WRITE_FAIR_MIN drain unconditionally so a steady read
             * stream can't starve audio; beyond that, yield to pending reads
             * to keep sync responsive. */
            for (int _d = 0; _d < 16; _d++) {
                if (_d >= WRITE_FAIR_MIN && k_msgq_num_used_get(&sd_prio_msgq) > 0)
                    break;
                sd_req_t _next = {0};
                if (k_msgq_get(&sd_msgq, &_next, K_NO_WAIT) != 0)
                    break;
                if (_next.type == REQ_WRITE_DATA)
                    process_write_data_req(&_next);
                else if (_next.type == REQ_SAVE_OFFSET)
                    process_save_offset_req(&_next);
            }
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_spi_woken) {
                sd_set_io_low_power(true);
            }
#endif
            break;
        }

        /* ---- Read audio data (uses persistent file handle) ---- */
        case REQ_READ_DATA: {
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_active()) {
                ring_handle_read_req(&req);
                break;
            }
#endif
            char read_path[64];
            build_file_path(req.u.read.filename, read_path, sizeof(read_path));

            bool is_active_file = (current_filename[0] != '\0' && strcmp(req.u.read.filename, current_filename) == 0);

            /* Close handle if different file requested */
            if (read_handle_open && strcmp(read_handle_filename, req.u.read.filename) != 0) {
                close_read_handle();
            }

            /* Reopen if handle is stale (file was synced since handle opened) */
            if (read_handle_open && read_handle_gen != data_sync_gen) {
                close_read_handle();
            }

            /* Open file if not already open */
            if (!read_handle_open) {
                res = lfs_file_opencfg(&lfs_fs, &lfs_read_handle, read_path, LFS_O_RDONLY, &lfs_read_handle_cfg);
                if (res < 0) {
                    LOG_ERR("[SD_WORK] open read failed: %s err=%d", read_path, res);
                    if (req.u.read.resp) {
                        req.u.read.resp->res = res;
                        req.u.read.resp->read_bytes = 0;
                        k_sem_give(&req.u.read.resp->sem);
                    }
                    break;
                }
                strncpy(read_handle_filename, req.u.read.filename, MAX_FILENAME_LEN - 1);
                read_handle_open = true;
                read_handle_pos = 0;
                read_handle_gen = data_sync_gen;
            }

            /* Only seek if position doesn't match (sequential reads skip seek) */
            if (read_handle_pos != (lfs_soff_t) req.u.read.offset) {
                lfs_file_seek(&lfs_fs, &lfs_read_handle, (lfs_soff_t) req.u.read.offset, LFS_SEEK_SET);
                read_handle_pos = (lfs_soff_t) req.u.read.offset;
            }

            lfs_ssize_t br = lfs_file_read(&lfs_fs, &lfs_read_handle, req.u.read.out_buf, req.u.read.length);

            /* Lazy sync: if we got 0 bytes (EOF) on the active file and
             * there is uncommitted data, flush+sync now and retry once.
             * This avoids the expensive lfs_file_sync on EVERY read
             * (was ~50-100 ms each) — we only pay the cost when we
             * actually hit the stale-EOF boundary. */
            if (br == 0 && is_active_file && (write_batch_offset > 0 || bytes_since_sync > 0)) {
                if (write_batch_offset > 0)
                    flush_batch_buffer_chunked();
                if (bytes_since_sync > 0) {
                    int sr = lfs_file_sync(&lfs_fs, &lfs_fil_data);
                    if (sr == 0) {
                        data_sync_gen++;
                        bytes_since_sync = 0;
                        last_file_sync_uptime_ms = k_uptime_get();

                        /* Reopen read handle to pick up new file size.
                         * Re-verify the file is still active after the close-reopen
                         * window to guard against concurrent file rotation. */
                        close_read_handle();
                        k_mutex_lock(&current_filename_lock, K_FOREVER);
                        bool still_active = (current_filename[0] != '\0' &&
                                             strcmp(req.u.read.filename, current_filename) == 0);
                        k_mutex_unlock(&current_filename_lock);
                        if (!still_active) {
                            /* File rotated under us — signal completion. */
                            is_active_file = false;
                        }
                        res = lfs_file_opencfg(&lfs_fs, &lfs_read_handle, read_path, LFS_O_RDONLY, &lfs_read_handle_cfg);
                        if (res < 0) {
                            if (req.u.read.resp) {
                                req.u.read.resp->res = res;
                                req.u.read.resp->read_bytes = 0;
                                k_sem_give(&req.u.read.resp->sem);
                            }
                            break;
                        }
                        strncpy(read_handle_filename, req.u.read.filename, MAX_FILENAME_LEN - 1);
                        read_handle_open = true;
                        read_handle_pos = 0;
                        read_handle_gen = data_sync_gen;

                        /* Re-check if the file is still the active file after reopen.
                         * A file rotation could have changed current_filename between
                         * the sync and reopen, making our read_path stale. */
                        k_mutex_lock(&current_filename_lock, K_FOREVER);
                        still_active = (current_filename[0] != '\0' &&
                                        strcmp(req.u.read.filename, current_filename) == 0);
                        k_mutex_unlock(&current_filename_lock);
                        if (!still_active) {
                            if (req.u.read.resp) {
                                req.u.read.resp->res = 0;
                                req.u.read.resp->read_bytes = 0;
                                k_sem_give(&req.u.read.resp->sem);
                            }
                            break;
                        }

                        lfs_file_seek(&lfs_fs, &lfs_read_handle, (lfs_soff_t) req.u.read.offset, LFS_SEEK_SET);
                        read_handle_pos = (lfs_soff_t) req.u.read.offset;

                        br = lfs_file_read(&lfs_fs, &lfs_read_handle, req.u.read.out_buf, req.u.read.length);
                    } else {
                        LOG_ERR("[SD_WORK] lazy sync failed: %d", sr);
                    }
                }
            }

            if (br > 0) {
                read_handle_pos += br;
                    }

            if (req.u.read.resp) {
                req.u.read.resp->res = (br < 0) ? (int) br : 0;
                req.u.read.resp->read_bytes = (br < 0) ? 0 : (int) br;
                k_sem_give(&req.u.read.resp->sem);
            }
            break;
        }

        /* ---- Save offset ---- */
        case REQ_SAVE_OFFSET:
            process_save_offset_req(&req);
            break;

        /* ---- Clear audio directory ---- */
        case REQ_CLEAR_AUDIO_DIR: {
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_active()) {
                /* Reformat the ring (wipes all segments) and reopen a fresh one. */
                int cr = sd_ring_format(ring_total_sectors);
                k_mutex_lock(&current_filename_lock, K_FOREVER);
                current_filename[0] = '\0';
                current_file_path[0] = '\0';
                k_mutex_unlock(&current_filename_lock);
                current_file_size = 0;
                ring_bytes_since_sync = 0;
                invalidate_file_cache();
                if (cr == 0) {
                    cr = create_audio_file_with_timestamp();
                }
                if (req.u.clear_dir.resp) {
                    req.u.clear_dir.resp->res = cr;
                    k_sem_give(&req.u.clear_dir.resp->sem);
                }
                break;
            }
#endif
            flush_batch_buffer_chunked();
            close_read_handle();
            lfs_file_close(&lfs_fs, &lfs_fil_data);
            k_mutex_lock(&current_filename_lock, K_FOREVER);
            current_filename[0] = '\0';
            current_file_path[0] = '\0';
            k_mutex_unlock(&current_filename_lock);

            char fpath[64];
            bool clear_ok = true;

            /* RAM-efficient search-and-delete loop (avoids 9.6KB static buffer).
             * We find one file, close dir, delete it, and repeat until empty. 
             * This $O(N^2)$ approach is safe and saves significant RAM. */
            while (1) {
                lfs_dir_t dir;
                struct lfs_info info;
                char to_delete[MAX_FILENAME_LEN] = {0};

                if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) == 0) {
                    while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
                        if (info.type == LFS_TYPE_REG) {
                            strncpy(to_delete, info.name, MAX_FILENAME_LEN - 1);
                            break;
                        }
                    }
                    lfs_dir_close(&lfs_fs, &dir);
                }

                if (to_delete[0] == '\0') {
                    break; /* Directory is empty */
                }

                build_file_path(to_delete, fpath, sizeof(fpath));
                int rm = lfs_remove(&lfs_fs, fpath);
                if (rm < 0) {
                    LOG_ERR("[SD_WORK] rm %s: %d", fpath, rm);
                    clear_ok = false;
                    break; /* Stop on error to avoid infinite loops */
                }
                k_yield();
            }

            if (clear_ok) {
                /* Reset offset info */
                memset(&current_offset_info, 0, sizeof(current_offset_info));
                lfs_file_seek(&lfs_fs, &lfs_fil_info, 0, LFS_SEEK_SET);
                lfs_file_write(&lfs_fs, &lfs_fil_info, &current_offset_info, sizeof(current_offset_info));
                lfs_file_sync(&lfs_fs, &lfs_fil_info);
                invalidate_file_cache();
                bytes_since_sync = 0;
                write_batch_offset = 0;
                write_batch_counter = 0;

                res = create_audio_file_with_timestamp();
            } else {
                res = -EIO;
            }

            if (req.u.clear_dir.resp) {
                req.u.clear_dir.resp->res = res;
                k_sem_give(&req.u.clear_dir.resp->sem);
            }
            break;
        }

        /* ---- Create new file ---- */
        case REQ_CREATE_NEW_FILE:
            /* Drain any writes still queued in sd_msgq into the OLD file before we
             * rotate. The SD worker services sd_prio_msgq (this request) ahead of
             * sd_msgq, so a write enqueued just before the rotate — most importantly
             * the 0xFFFFFFFC session-end marker written by priority_record_stop()
             * immediately before create_new_audio_file() — would otherwise be
             * processed AFTER the rotate and land in the fresh bin. Draining here
             * keeps each recording's markers/audio in its own bin (priority bins
             * stay self-contained: [0xFFFFFFF8 .. audio .. 0xFFFFFFFC]). Reuses the
             * same helper REQ_UNMOUNT uses; name is historical, behaviour is generic. */
            drain_pending_write_queue_for_shutdown();
            res = 0;
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_active()) {
                /* Head must be durable before create_audio_file_with_timestamp ->
                 * begin_segment publishes the closing segment's length. If the sync
                 * fails, don't rotate: report the error and let the caller/next write
                 * retry, rather than committing an over-claimed close. */
                res = sd_ring_sync();
                if (res == 0) {
                    ring_bytes_since_sync = 0;
                } else {
                    /* Explicit rotation could not be made durable now — mark it
                     * pending so the write path completes it BEFORE accepting more
                     * audio; otherwise this requested boundary is lost and the next
                     * recording's audio lands in the current segment. */
                    ring_pending_explicit_rotate = true;
                }
            } else
#endif
            {
                flush_batch_buffer_chunked();
            }
            if (res == 0) {
                res = create_audio_file_with_timestamp();
            }
            if (req.u.create_file.resp) {
                req.u.create_file.resp->res = res;
                k_sem_give(&req.u.create_file.resp->sem);
            }
            break;

        /* ---- Get file stats ---- */
        case REQ_GET_FILE_STATS: {
            res = ensure_file_cache();

            if (req.u.file_stats.resp) {
                req.u.file_stats.resp->res = res;
                req.u.file_stats.resp->file_count = (res == 0) ? cached_total_file_count : 0;
                req.u.file_stats.resp->total_size = (res == 0) ? cached_total_file_size : 0;
                k_sem_give(&req.u.file_stats.resp->sem);
            }
            break;
        }



        /* ---- Flush current file ---- */
        case REQ_FLUSH_FILE: {
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_active()) {
                int fr = sd_ring_sync();
                if (fr == 0) {
                    ring_bytes_since_sync = 0; /* keep pending on failure so it retries */
                }
                if (req.u.create_file.resp) {
                    req.u.create_file.resp->res = fr;
                    k_sem_give(&req.u.create_file.resp->sem);
                }
                break;
            }
#endif
            int flush_res = 0;
            if (!atomic_get(&current_file_deleted) && current_filename[0] != '\0') {
                flush_res = flush_batch_buffer_chunked();
                if (flush_res == 0) {
                    int sr = lfs_file_sync(&lfs_fs, &lfs_fil_data);
                    if (sr < 0) {
                        LOG_ERR("[SD_WORK] lfs_file_sync failed: %d", sr);
                        flush_res = sr;
                    } else {
                        data_sync_gen++;
                        bytes_since_sync = 0;
                        write_batch_offset = 0;
                        write_batch_counter = 0;
                        last_file_sync_uptime_ms = k_uptime_get();
                        LOG_INF("[SD_WORK] Flushed %s (%u bytes)", current_filename, current_file_size);
                    }
                }
            }
            if (req.u.create_file.resp) {
                req.u.create_file.resp->res = flush_res;
                k_sem_give(&req.u.create_file.resp->sem);
            }
            break;
        }

        /* ---- Unmount SD/LFS (must run on worker thread) ---- */
        case REQ_UNMOUNT: {
            /* Shutdown path: stop accepting new writes and drain queued writes
             * so data already enqueued by mic thread is persisted before unmount. */
            drain_pending_write_queue_for_shutdown();
            int off_res = sd_unmount();
            if (req.u.create_file.resp) {
                req.u.create_file.resp->res = off_res;
                k_sem_give(&req.u.create_file.resp->sem);
            }
            break;
        }

        /* ---- Delete file ---- */
        case REQ_DELETE_FILE: {
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_active()) {
                /* Deletion = ack the segment; the ring advances its tail past
                 * leading acked segments to reclaim space. */
                AudioFileMeta_t m;
                parse_filename_to_meta(req.u.delete_file.filename, 0, &m);
                int idx = ring_find_segment_index(m.timestamp, m.uptime_offset);
                int rc = (idx >= 0) ? sd_ring_ack_segment(idx) : 0; /* absent = already gone */
                invalidate_file_cache();
                if (req.u.delete_file.resp) {
                    req.u.delete_file.resp->res = (rc < 0) ? rc : 0;
                    k_sem_give(&req.u.delete_file.resp->sem);
                }
                break;
            }
#endif
            char del_path[64];
            build_file_path(req.u.delete_file.filename, del_path, sizeof(del_path));

            /* Close read handle if we're about to delete the file being read */
            if (read_handle_open && filename_equals_ignore_case(read_handle_filename, req.u.delete_file.filename)) {
                close_read_handle();
            }

            if (current_filename[0] != '\0' &&
                filename_equals_ignore_case(current_filename, req.u.delete_file.filename)) {
                LOG_INF("[SD_WORK] Deleting active recording file");
                flush_batch_buffer_chunked();
                lfs_file_close(&lfs_fs, &lfs_fil_data);
                k_mutex_lock(&current_filename_lock, K_FOREVER);
                current_filename[0] = '\0';
                current_file_path[0] = '\0';
                k_mutex_unlock(&current_filename_lock);
                current_file_size = 0;
                bytes_since_sync = 0;
                write_batch_offset = 0;
                write_batch_counter = 0;
                last_file_sync_uptime_ms = 0;
                atomic_set(&current_file_deleted, 1);
            }

            int rm = lfs_remove(&lfs_fs, del_path);
            if (rm < 0 && rm != LFS_ERR_NOENT) {
                LOG_ERR("[SD_WORK] remove %s failed: %d", del_path, rm);
            } else {
                invalidate_file_cache();
                    }
            if (req.u.delete_file.resp) {
                req.u.delete_file.resp->res = rm;
                k_sem_give(&req.u.delete_file.resp->sem);
            }
            break;
        }

        /* ---- Pause IO ---- */
        case REQ_PAUSE_IO: {
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_active()) {
                int psr = sd_ring_sync();
                if (psr == 0) {
                    ring_bytes_since_sync = 0;
                } else {
                    /* Durability sync failed at the pause boundary — keep the bytes
                     * pending and enter recovery (the write-wait-timeout retries the
                     * sync) so the final audio/marker isn't silently lost, and report
                     * the error to the caller instead of ack'ing success. */
                    last_write_error_uptime_ms = k_uptime_get();
                    sd_write_blocked = true;
                }
                sd_write_pause(true);
                if (req.u.create_file.resp) {
                    req.u.create_file.resp->res = psr;
                    k_sem_give(&req.u.create_file.resp->sem);
                }
                break;
            }
#endif
            flush_batch_buffer_chunked();
            if (current_filename[0] != '\0') {
                lfs_file_sync(&lfs_fs, &lfs_fil_data);
            }
            sd_write_pause(true);
            if (req.u.create_file.resp) {
                req.u.create_file.resp->res = 0;
                k_sem_give(&req.u.create_file.resp->sem);
            }
            break;
        }

        /* ---- Invalidate file cache (force a fresh enumeration) ---- */
        case REQ_INVALIDATE_CACHE:
            /* Runs on the SD worker, which owns all cache state — no cross-thread
             * race. Posted synchronously from the CMD_LIST_FILES path so the list
             * the app receives always reflects a fresh enumeration, including files
             * a rotation created during the previous session (whose mid-session
             * invalidation was intentionally skipped to keep indices frozen). */
            invalidate_file_cache();
            if (req.u.create_file.resp) {
                req.u.create_file.resp->res = 0;
                k_sem_give(&req.u.create_file.resp->sem);
            }
            break;

        /* ---- Time synced ---- */
        case REQ_TIME_SYNCED:
#ifdef CONFIG_OMI_AUDIO_RING
            if (ring_active()) {
                /* Rotate to a fresh UTC-keyed segment so subsequent audio is
                 * organized. Existing pre-sync segments keep their uptime key
                 * (no directory to rename); the app anchors timing to each
                 * segment's inline header. */
                if (current_filename[0] == '\0' || current_file_needs_rename) {
                    /* If an open (TMP) segment will be closed by this rotation, make
                     * its head durable first: create_audio_file_with_timestamp ->
                     * begin_segment publishes the closing length from head_abs, so an
                     * un-synced head could expose uncommitted bytes past the recovered
                     * cursor after a power cut. On sync failure, defer — a later
                     * rotation retries with a durable head. */
                    if (current_filename[0] != '\0') {
                        if (sd_ring_sync() != 0) {
                            atomic_set(&timesync_rename_pending, 0);
                            break;
                        }
                        ring_bytes_since_sync = 0;
                    }
                    create_audio_file_with_timestamp();
                }
                atomic_set(&timesync_rename_pending, 0);
                break;
            }
#endif
            if (current_filename[0] != '\0' && current_file_needs_rename) {
                /*
                 * Time sync received while recording to a temporary file.
                 * 1. Rotate to a new file (which will now use the correct UTC timestamp).
                 * 2. Retroactively rename all previously closed TMP_ segments.
                 */
                int res = create_audio_file_with_timestamp();
                if (res >= 0) {
                    sd_update_filename_after_timesync(req.u.time_synced.utc_time);
                } else {
                    LOG_ERR("[SD_WORK] Time sync rotation failed: %d", res);
                }
            } else if (current_filename[0] == '\0') {
                /* No file open yet, start a fresh one with UTC name. */
                create_audio_file_with_timestamp();
            } else {
                /* Already recording with UTC name; just catch up any old TMP segments. */
                sd_update_filename_after_timesync(req.u.time_synced.utc_time);
            }
            atomic_set(&timesync_rename_pending, 0);
            break;

        default:
            LOG_ERR("[SD_WORK] unknown request type %d", req.type);
        }

        /* Suspend SPI after non-write requests complete.
         * Write data manages its own SPI state via spi_woken. */
        if (req.type != REQ_WRITE_DATA) {
            sd_set_io_low_power(true);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

bool sd_is_timesync_rename_pending(void)
{
    return atomic_get(&timesync_rename_pending) != 0;
}

bool sd_is_boot_ready(void)
{
    return atomic_get(&sd_boot_ready);
}

uint32_t sd_get_boot_dropped_frames(void)
{
    return (uint32_t)atomic_get(&boot_dropped_frames);
}

uint32_t sd_get_stream_dropped_frames(void)
{
    return (uint32_t)atomic_get(&stat_dropped_frames);
}

uint32_t sd_get_msgq_peak_depth(void)
{
    return (uint32_t)atomic_get(&sd_msgq_peak_depth);
}

uint32_t sd_get_write_fair_activations(void)
{
    return (uint32_t)atomic_get(&write_fair_activations);
}

uint32_t sd_get_empty_bin_rotations(void)
{
    return (uint32_t)atomic_get(&empty_bin_rotations);
}

uint32_t sd_get_marker_pause_gate_saves(void)
{
    return (uint32_t)atomic_get(&marker_pause_gate_saves);
}

uint32_t sd_get_worker_stack_used(void)
{
#if defined(CONFIG_THREAD_STACK_INFO) && defined(CONFIG_INIT_STACKS)
    size_t unused = 0;
    if (sd_worker_tid != NULL && k_thread_stack_space_get(sd_worker_tid, &unused) == 0) {
        return (uint32_t)(K_THREAD_STACK_SIZEOF(sd_worker_stack) - unused);
    }
#endif
    return 0;
}

/* Ring SD-primitive diagnostics: slowest disk op (packed tag+ms) and write/sync
 * error count. 0 when the ring backend is compiled out or not active. */
uint32_t sd_get_ring_max_io_ms(void)
{
#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) return sd_ring_max_io_ms();
#endif
    return 0;
}

uint32_t sd_get_ring_io_errors(void)
{
#ifdef CONFIG_OMI_AUDIO_RING
    if (ring_active()) return sd_ring_io_errors();
#endif
    return 0;
}

uint8_t sd_get_active_backend(void)
{
    /* What is ACTUALLY mounted this boot — authoritative even when a ring
     * mount/format failure reverted to LittleFS but the persisted-selector write
     * didn't land. */
#ifdef CONFIG_OMI_AUDIO_RING
    return ring_active() ? STORAGE_BACKEND_RING : STORAGE_BACKEND_LITTLEFS;
#else
    return STORAGE_BACKEND_LITTLEFS;
#endif
}

#ifdef CONFIG_OMI_AUDIO_RING
/* ================================================================== */
/* Ring backend glue — dispatched behind ring_active().               */
/* All functions run on the sd_worker thread, like their LittleFS      */
/* counterparts.                                                       */
/* ================================================================== */

/* Open a new ring segment and write its inline 0xFFFFFFFB RecordingHeader,
 * mirroring create_audio_file_with_timestamp(). Reuses the shared
 * current_filename / current_file_size / rotation-timer state so
 * should_rotate_file() and the marker plumbing work unchanged. */
static int ring_create_segment(void)
{
    bool rtc_valid = rtc_is_valid();
    uint32_t utc = 0;
    if (rtc_valid) {
        utc = get_utc_time();
        if (utc == 0 || utc < 1700000000U) {
            rtc_valid = false;
        }
    }
    uint32_t sid = (uint32_t) atomic_get(&device_session_id);

    /* Empty-bin diagnostic: previous segment closed holding only its header. */
    if (current_filename[0] != '\0' && current_file_size <= sizeof(RecordingHeader_v1_t)) {
        atomic_inc(&empty_bin_rotations);
    }

    /* Pre-time-sync segments key on uptime seconds (sorts < 946684800 → shown
     * "unorganized", like LittleFS TMP files); unique per segment. */
    uint32_t seg_ts = rtc_valid ? utc : (k_uptime_get_32() / 1000U);
    /* Two rotations in the same second (e.g. a priority-record boundary landing
     * on a natural rotation) would otherwise share a (ts,sid) identity and make
     * the read/delete lookup ambiguous. Force strictly increasing (not just !=):
     * once a bump pushes the key ahead of wall-clock seconds, a plain equality
     * check would let the next same-second rotation reuse an already-issued key. */
    if (seg_ts <= ring_last_seg_ts) {
        seg_ts = ring_last_seg_ts + 1;
    }
    ring_last_seg_ts = seg_ts;

    int rc = sd_ring_begin_segment(seg_ts, sid);
    if (rc < 0) {
        LOG_ERR("[SD_WORK] ring begin_segment failed: %d", rc);
        return rc;
    }

    /* Synthetic filename so the shared list/read/delete/marker plumbing keys on
     * it exactly like the LittleFS path (identity = <ts>_<sid>). */
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    if (rtc_valid) {
        snprintf(current_filename, sizeof(current_filename), "%08X_%08X.txt", seg_ts, sid);
    } else {
        snprintf(current_filename, sizeof(current_filename), "TMP_%08X_%08X.txt", seg_ts, sid);
    }
    current_file_path[0] = '\0';
    current_file_needs_rename = !rtc_valid;
    k_mutex_unlock(&current_filename_lock);

    RecordingHeader_v1_t header = {
        .marker = 0xFFFFFFFB,
        .payload_len = 28,
        .utc_start_ms = rtc_get_utc_time_ms(),
        .uptime_start_ms = (uint64_t) k_uptime_get(),
        .session_id = sid,
        .version = 1,
    };
    uint32_t imu_ts = 0;
    header.imu_ticks = (lsm6dsl_timestamp_read(&imu_ts) == 0) ? imu_ts : 0;

    rc = sd_ring_append((const uint8_t *) &header, sizeof(header));
    if (rc == 0) {
        rc = sd_ring_sync();
    } else {
        (void) sd_ring_sync();
    }
    if (rc < 0) {
        /* The 0xFFFFFFFB segment header did not reach NAND. Discard the segment that
         * begin_segment just opened, else a phantom zero-length entry leaks into the
         * fixed 168-slot table and later closes as a bogus file. Keep
         * ring_bytes_since_sync pending so the worker timeout retries the sync, clear
         * the active file so the next write re-creates a fresh segment, and surface
         * the error so the caller blocks writes instead of treating this as success. */
        LOG_ERR("[SD_WORK] ring segment header not persisted: %d", rc);
        (void) sd_ring_discard_open_segment();
        k_mutex_lock(&current_filename_lock, K_FOREVER);
        current_filename[0] = '\0';
        k_mutex_unlock(&current_filename_lock);
        return rc;
    }
    ring_bytes_since_sync = 0;

    current_file_size = sizeof(RecordingHeader_v1_t);
    bytes_since_sync = 0;
    current_file_created_uptime_ms = k_uptime_get();
    last_file_sync_uptime_ms = k_uptime_get();
    writing_error_counter = 0;
    sd_write_blocked = false;
    invalidate_file_cache_deferrable();
    return 0;
}

/* Ring write path: 2 s soft-recovery + pause-gate marker rescue + lazy segment
 * open + rotation + append + bounded cursor sync. Mirrors the control flow of
 * the LittleFS process_write_data_req() minus the batch buffer and remount. */
static void process_write_data_req_ring(const sd_req_t *req)
{
    if (sd_write_blocked) {
        if ((k_uptime_get() - last_write_error_uptime_ms) > 2000) {
            sd_write_blocked = false;
            writing_error_counter = 0;
        } else {
            return;
        }
    }

    /* Pause gate: a pause is a power optimization, not a correctness gate. Keep
     * marker-bearing blocks (session-end / priority-start / tap / mute / resume)
     * through a pause; drop only plain audio. */
    if (!sd_draining && atomic_get(&sd_write_paused)) {
        if (block_has_marker(req->u.write.buf, req->u.write.len)) {
            atomic_inc(&marker_pause_gate_saves);
        } else {
            return; /* no I/O performed */
        }
    }

    /* Complete a deferred explicit rotation (a priority/manual REQ_CREATE_NEW_FILE
     * whose sync failed) BEFORE appending, so the requested boundary is honored and
     * this block does not land in the previous segment. On failure, stay pending and
     * block rather than append into the wrong segment. */
    if (ring_pending_explicit_rotate) {
        if (sd_ring_sync() != 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto ring_done;
        }
        ring_bytes_since_sync = 0;
        if (ring_create_segment() < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto ring_done;
        }
        ring_pending_explicit_rotate = false;
    }

    /* SPI is already awake here — do NOT power-cycle it per block. The worker loop
     * wakes the bus once around the whole write burst (the REQ_WRITE_DATA case +
     * its drain loop), and the non-write handlers that reach this path via the
     * shutdown drain (REQ_CREATE_NEW_FILE / REQ_UNMOUNT) wake it too. A per-block
     * pm_device RESUME/SUSPEND re-inits the SD card (tens of ms) ~12x/s, which
     * pegged sd_msgq at 120/120 and dropped audio instead of draining it. */
    if (current_filename[0] == '\0') {
        if (ring_create_segment() < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto ring_done;
        }
        atomic_clear(&current_file_deleted);
    }

    if (!sd_suppress_auto_rotate && should_rotate_file()) {
        /* Make the current head durable BEFORE rotating: ring_create_segment ->
         * begin_segment publishes the closing segment's length from head_abs, so if
         * this sync fails and we rotate anyway, a reboot restores an older cursor
         * head and the closed length over-claims un-synced bytes. On failure, don't
         * rotate — block + retry; the rotation happens once the sync succeeds. */
        if (sd_ring_sync() != 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto ring_done;
        }
        ring_bytes_since_sync = 0;
        if (ring_create_segment() < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto ring_done;
        }
    }

    if (sd_ring_append(req->u.write.buf, req->u.write.len) < 0) {
        atomic_inc(&stat_dropped_frames);
        last_write_error_uptime_ms = k_uptime_get();
        goto ring_done;
    }
    current_file_size += req->u.write.len;
    ring_bytes_since_sync += req->u.write.len;

    /* Durability: sync the cursor at least every RING_SYNC_BYTES of audio, and
     * immediately for any CRITICAL marker block (recording boundary / user action)
     * so a stop / priority-start / tap / mute is not lost to a power cut before the
     * next periodic sync. VAD-resume (0xFFFFFFFD) is intentionally excluded — see
     * block_has_critical_marker — so it no longer forces a full CTRL_SYNC + cursor
     * write on every speech-after-silence wake. */
    if (block_has_critical_marker(req->u.write.buf, req->u.write.len) ||
        ring_bytes_since_sync >= RING_SYNC_BYTES) {
        if (sd_ring_sync() == 0) {
            ring_bytes_since_sync = 0;
            /* Feed the shared last-sync clock the write-wait-timeout gate reads, so a
             * threshold/marker commit here defers the next timeout commit a full
             * SD_FSYNC_INTERVAL_MS (no redundant back-to-back sync). */
            last_file_sync_uptime_ms = k_uptime_get();
        } else {
            /* Sync failed — the appended bytes (and any marker) are NOT durable yet.
             * Keep ring_bytes_since_sync non-zero so the write-wait-timeout sync and
             * the next threshold retry it, and block writes so the 2 s recovery runs
             * instead of silently deferring durability by another RING_SYNC_BYTES. */
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
        }
    }

ring_done:
    return; /* SPI is suspended by the caller after the whole write burst. */
}

/* Resolve a segment index from the app's (timestamp, session_id) key. */
static int ring_find_segment_index(uint32_t timestamp, uint32_t session_id)
{
    int n = sd_ring_segment_count();
    for (int i = 0; i < n; i++) {
        ring_segment_t seg;
        if (sd_ring_get_segment(i, &seg) == 0 &&
            seg.timestamp == timestamp && seg.session_id == session_id) {
            return i;
        }
    }
    return -1;
}

/* REQ_READ_DATA handler for the ring: map filename → segment → byte range. */
static void ring_handle_read_req(const sd_req_t *req)
{
    AudioFileMeta_t m;
    parse_filename_to_meta(req->u.read.filename, 0, &m);
    int idx = ring_find_segment_index(m.timestamp, m.uptime_offset);
    int br = (idx >= 0) ? sd_ring_read_segment(idx, req->u.read.offset, req->u.read.out_buf,
                                               req->u.read.length)
                        : -1;
    if (req->u.read.resp) {
        req->u.read.resp->res = (br < 0) ? br : 0;
        req->u.read.resp->read_bytes = (br < 0) ? 0 : br;
        k_sem_give(&req->u.read.resp->sem);
    }
}

/* Build the file-list cache from the ring's CLOSED segments (oldest first). The
 * open segment is excluded by sd_ring_segment_count(), matching the LittleFS
 * "exclude the currently-recording file" behaviour. */
static int ring_refresh_file_cache(void)
{
    k_mutex_lock(&file_cache_mutex, K_FOREVER);
    memset(cached_file_meta, 0, sizeof(cached_file_meta));

    int n = sd_ring_segment_count();
    int list_count = 0;
    uint64_t total_size = 0;
    for (int i = 0; i < n; i++) {
        ring_segment_t seg;
        if (sd_ring_get_segment(i, &seg) < 0) {
            continue;
        }
        /* Count every closed segment toward the storage stats, so used-bytes /
         * file-count stay accurate even past the cache cap... */
        total_size += seg.length;
        /* ...but only the first MAX_AUDIO_FILES fit the BLE-indexed list cache (the
         * app drains + deletes, freeing slots, well before this bound in practice). */
        if (list_count < MAX_AUDIO_FILES) {
            AudioFileMeta_t *meta = &cached_file_meta[list_count++];
            memset(meta, 0, sizeof(*meta));
            meta->timestamp = seg.timestamp;
            meta->uptime_offset = seg.session_id;
            meta->file_size = seg.length;
            meta->is_tmp = (seg.timestamp < 946684800U); /* pre-time-sync key → unorganized */
        }
    }

    cached_file_list_count = list_count;
    cached_total_file_count = (uint32_t) n;
    cached_total_file_size = total_size;
    cached_stats_file_count = (uint32_t) n;
    cached_stats_total_size = total_size;
    {
        uint64_t freeb = sd_ring_free_bytes();
        cached_free_bytes = (freeb > UINT32_MAX) ? UINT32_MAX : (uint32_t) freeb;
    }
    cached_stats_valid_until_ms = k_uptime_get() + FILE_CACHE_TTL_MS;
    file_cache_valid = true;
    /* Do NOT clear sd_write_blocked / writing_error_counter here: listing reads the
     * in-RAM segment table and never touches the write path, so a successful list
     * says nothing about a pending write fault. Let the write path's own timed
     * recovery clear it, or a fault would be masked and retried too early. */

    k_mutex_unlock(&file_cache_mutex);
    return 0;
}
#endif /* CONFIG_OMI_AUDIO_RING */

int app_sd_init(void)
{
    sd_shutdown_in_progress = false;
    if (!sd_worker_tid) {
        sd_worker_tid = k_thread_create(&sd_worker_thread_data,
                                        sd_worker_stack,
                                        SD_WORKER_STACK_SIZE,
                                        (k_thread_entry_t) sd_worker_thread,
                                        NULL,
                                        NULL,
                                        NULL,
                                        SD_WORKER_PRIORITY,
                                        0,
                                        K_NO_WAIT);
        k_thread_name_set(sd_worker_tid, "sd_worker");
    }
    return 0;
}

int app_sd_off(void)
{
    sd_shutdown_in_progress = true;
    bool unmount_completed = false;

    if (is_mounted && sd_worker_tid) {
        static struct read_resp resp;
        k_sem_init(&resp.sem, 0, 1);
        resp.res = 0;

        sd_req_t req = {0};
        req.type = REQ_UNMOUNT;
        req.u.create_file.resp = &resp;

        int qret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(2000));
        if (qret == 0) {
            if (k_sem_take(&resp.sem, K_MSEC(45000)) != 0) {
                LOG_ERR("Timeout waiting for sd_worker unmount; skip force SD power-off");
            } else if (resp.res < 0) {
                LOG_ERR("sd_worker unmount failed: %d", resp.res);
            } else {
                unmount_completed = true;
            }
        } else {
            LOG_ERR("Failed to queue sd unmount request: %d", qret);
        }
    }

    /* Avoid forcing SD power-off while worker may still be writing/syncing,
     * which can trigger SPI transfer timeouts and filesystem corruption. */
    if (unmount_completed || !is_mounted) {
        if (sd_enabled) {
            sd_enable_power(false);
        }
        sd_enabled = false;
    }

    return 0;
}

bool is_sd_on(void)
{
    return sd_enabled;
}

uint32_t get_file_size(void)
{
    return current_file_size;
}

int get_current_filename(char *buf, size_t buf_size)
{
    if (!buf || buf_size < MAX_FILENAME_LEN)
        return -EINVAL;
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    strncpy(buf, current_filename, buf_size - 1);
    buf[buf_size - 1] = '\0';
    k_mutex_unlock(&current_filename_lock);
    return 0;
}

bool sd_is_current_recording_file(const char *filename)
{
    if (!filename || filename[0] == '\0')
        return false;
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    bool match = (current_filename[0] != '\0' && strcmp(filename, current_filename) == 0);
    k_mutex_unlock(&current_filename_lock);
    return match;
}

uint32_t sd_get_cached_free_bytes(void)
{
    return cached_free_bytes;
}

void sd_notify_time_synced(uint32_t utc_time)
{
    /* Mark rename in-flight before queuing so CMD_LIST_FILES can't race past it. */
    atomic_set(&timesync_rename_pending, 1);
    /* Store value before flag — atomic_set provides ordering. */
    pending_timesync_utc = utc_time;
    atomic_set(&pending_time_synced, 1);

    sd_req_t req = {0};
    req.type = REQ_TIME_SYNCED;
    req.u.time_synced.utc_time = utc_time;
    int ret = k_msgq_put(&sd_prio_msgq, &req, K_NO_WAIT);
    if (ret == 0) {
        atomic_set(&pending_time_synced, 0);
    }
}

void sd_notify_ble_state(bool connected)
{
    if (connected && !atomic_get(&ble_connected)) {
        ble_connect_time_ms = k_uptime_get();
        LOG_INF("BLE connected");
        /* Signal the SD worker to rotate the active file on the next write so
         * the app can immediately download a completed recording.  The worker
         * checks the file age (>= 2 min) before actually rotating. */
        atomic_set(&pending_rotate_on_ble_connect, 1);
        /* Fire-and-forget flush via prio queue.
         * Do NOT block here — this runs on the BLE callback thread;
         * a blocking call would freeze the BLE stack and cause
         * ATT Timeout → disconnect.  The storage auto-sync will
         * flush before reading anyway. */
        sd_req_t req = {0};
        req.type = REQ_FLUSH_FILE;
        req.u.create_file.resp = NULL; /* no response needed */
        int ret = k_msgq_put(&sd_prio_msgq, &req, K_NO_WAIT);
        if (ret) {
            atomic_set(&pending_flush_on_ble_connect, 1);
            LOG_WRN("Flush on BLE connect deferred (%d)", ret);
        }
    } else if (!connected && atomic_get(&ble_connected)) {
        LOG_INF("BLE disconnected");
        atomic_set(&pending_rotate_on_ble_connect, 0);

        if (atomic_cas(&deferred_timesync_rename_pending, 1, 0)) {
            LOG_INF("[SD] Executing deferred time-sync rename after BLE disconnect");
            sd_req_t req = {0};
            req.type = REQ_TIME_SYNCED;
            req.u.time_synced.utc_time = deferred_timesync_utc;
            k_msgq_put(&sd_prio_msgq, &req, K_NO_WAIT);
        }

        if (atomic_get(&current_file_deleted)) {
            int cr = create_new_audio_file();
            if (cr < 0)
                LOG_ERR("create file on BLE disconnect failed: %d", cr);
            else
                atomic_clear(&current_file_deleted);
        }
    }
    atomic_set(&ble_connected, connected ? 1 : 0);
}

void sd_invalidate_file_cache_blocking(void)
{
    /* Force the file cache to be re-enumerated on the SD worker before the next
     * CMD_LIST_FILES response is built. Rotations during a sync session skip their
     * invalidation to keep the frozen indices stable (invalidate_file_cache_
     * deferrable), so the cache can be stale by the next session; this makes the
     * list authoritative again. Marshalled to the SD worker — which owns all cache
     * state — so there is no cross-thread mutation of file_cache_valid. Called from
     * the storage thread (the CMD_LIST_FILES handler), which may block, so we wait
     * for completion: that also guarantees cached_stats_valid_until_ms is cleared
     * before get_audio_file_stats() runs next, defeating its 30 s TTL fast-path.
     *
     * The response object is STATIC (not stack) with an in-flight guard, matching
     * create_new_audio_file()/get_audio_file_stats(): on a wait timeout the queued
     * REQ still references &resp, so a stack object would dangle when the SD worker
     * completes late. The next call reclaims the static once that late completion
     * signals the sem. Only the single storage thread calls this, so the guard is
     * just protecting against that late-completion reuse, not true concurrency. */
    static struct read_resp resp;
    static atomic_t invalidate_in_flight;

    if (!atomic_cas(&invalidate_in_flight, 0, 1)) {
        if (k_sem_take(&resp.sem, K_NO_WAIT) == 0) {
            atomic_set(&invalidate_in_flight, 0); /* late completion drained */
        } else {
            LOG_WRN("Force cache invalidate: previous request still in-flight");
            return;
        }
        if (!atomic_cas(&invalidate_in_flight, 0, 1)) {
            return;
        }
    }
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_INVALIDATE_CACHE;
    req.u.create_file.resp = &resp;

    if (k_msgq_put(&sd_prio_msgq, &req, K_MSEC(2000)) != 0) {
        LOG_WRN("Force cache invalidate not queued; list may serve a stale enumeration");
        atomic_set(&invalidate_in_flight, 0);
        return;
    }
    if (k_sem_take(&resp.sem, K_MSEC(2000)) != 0) {
        /* Leave invalidate_in_flight set — the REQ still owns &resp; the next call
         * reclaims after the late k_sem_give. get_audio_file_stats() then still
         * repairs the cache via its own REQ_GET_FILE_STATS round-trip. */
        LOG_WRN("Force cache invalidate timed out; list may serve a stale enumeration");
        return;
    }
    atomic_set(&invalidate_in_flight, 0);
}

/* Shared write path. retry_to is the bounded blocking timeout used on the
 * second enqueue attempt after an initial K_NO_WAIT put fails. Audio uses a
 * short adaptive timeout (drop-friendly); marker-bearing blocks use a long
 * timeout via write_to_file_blocking() so they survive transient saturation. */
static uint32_t write_to_file_impl(uint8_t *data, uint32_t length, k_timeout_t retry_to)
{
    static int64_t last_write_err_log_ms;
    static int64_t last_shutdown_drop_log_ms;

    /* Discard data while SD boot init is still running
     * (mount + lfs_fs_gc pre-warm + file open).  Rate-limited logging
     * so the drop is observable; counter is queryable after boot. */
    if (!atomic_get(&sd_boot_ready)) {
        static int64_t last_not_ready_log_ms;
        atomic_inc(&boot_dropped_frames);
        int64_t now = k_uptime_get();
        if (now - last_not_ready_log_ms > 5000) {
            LOG_WRN("write_to_file dropped: SD not ready (boot in progress), "
                     "total dropped frames: %ld",
                     (long)atomic_get(&boot_dropped_frames));
            last_not_ready_log_ms = now;
        }
        return 0;
    }

    if (sd_shutdown_in_progress) {
        int64_t now = k_uptime_get();
        if (now - last_shutdown_drop_log_ms > 1000) {
            LOG_WRN("write_to_file dropped: SD shutdown in progress");
            last_shutdown_drop_log_ms = now;
        }
        return 0;
    }

    if (sd_write_blocked) {
        /* Recovery is handled strictly on the sd_worker thread to avoid data races. */
        int64_t now = k_uptime_get();
        if (now - last_write_blocked_log_ms > 1000) {
            LOG_ERR("write_to_file blocked (permanent SD failure?)");
            last_write_blocked_log_ms = now;
        }
        return 0;
    }
    if (length > MAX_WRITE_SIZE) {
        LOG_ERR("write_to_file: length %u exceeds MAX_WRITE_SIZE %d", (unsigned)length, MAX_WRITE_SIZE);
        return 0;
    }

    sd_req_t req = {0};
    req.type = REQ_WRITE_DATA;
    memcpy(req.u.write.buf, data, length);
    req.u.write.len = length;

    /* Try non-blocking put first to check if we need to track a block attempt */
    int ret = k_msgq_put(&sd_msgq, &req, K_NO_WAIT);
    if (ret != 0) {
        ret = k_msgq_put(&sd_msgq, &req, retry_to);
    }

    if (ret != 0) {
        atomic_inc(&stat_dropped_frames);
        write_drop_packets++;
        write_drop_bytes += length;
        int64_t now = k_uptime_get();
        if (now - last_write_err_log_ms > 2000) {
            uint32_t depth = k_msgq_num_used_get(&sd_msgq);
            uint32_t dropped = (uint32_t)atomic_get(&stat_dropped_frames);
            LOG_ERR("SD queue blocked >500ms (depth=%u/%d), dropped=%u",
                    depth, SD_REQ_QUEUE_MSGS, dropped);
            last_write_err_log_ms = now;
        }
        return 0;
    }

    /* Track the high-water mark right after enqueue (queue at its fullest from
     * the producer's view) so diagnostics can show headroom vs the drop edge. */
    {
        uint32_t depth = k_msgq_num_used_get(&sd_msgq);
        if (depth > (uint32_t)atomic_get(&sd_msgq_peak_depth)) {
            atomic_set(&sd_msgq_peak_depth, (atomic_val_t)depth);
        }
    }
    return length;
}

uint32_t write_to_file(uint8_t *data, uint32_t length)
{
    /* Bounded blocking on the producer (codec) thread: wait briefly for queue
     * space before dropping. This is NOT the worker and does not slow reads —
     * it only governs how patient the audio thread is when the queue is full.
     * 25 ms rides out transient stalls (flush-on-connect, read bursts) without
     * dropping; it's ~4% of the 1.0 s codec ring, so the ring recovers easily
     * between stalls. Same value connected or not — the old 1 ms connected
     * timeout dropped audio the instant the worker got busy, for no benefit. */
    k_timeout_t retry_to = K_MSEC(25);
    return write_to_file_impl(data, length, retry_to);
}

uint32_t write_to_file_blocking(uint8_t *data, uint32_t length)
{
    /* Marker-bearing blocks: tolerate a full SD maintenance stall (≤500ms) so
     * button-tap / session-end / VAD-resume markers are not lost to a transient
     * sd_msgq saturation. Markers are rare, so the bounded stall is acceptable. */
    return write_to_file_impl(data, length, K_MSEC(500));
}

int read_audio_data(const char *filename, uint8_t *buf, int amount, int offset)
{

    /* Static resp so worker never writes to freed stack memory on timeout */
    static struct read_resp resp;
    static atomic_t read_in_flight;

    if (!atomic_cas(&read_in_flight, 0, 1)) {
        /* Check if late worker response arrived */
        if (k_sem_take(&resp.sem, K_NO_WAIT) == 0) {
            atomic_set(&read_in_flight, 0); /* Worker caught up */
        } else {
            LOG_WRN("read_audio_data: previous request still in-flight");
            return -EBUSY;
        }
        if (!atomic_cas(&read_in_flight, 0, 1)) {
            return -EBUSY;
        }
    }
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_READ_DATA;
    strncpy(req.u.read.filename, filename, MAX_FILENAME_LEN - 1);
    req.u.read.out_buf = buf;
    req.u.read.length = amount;
    req.u.read.offset = offset;
    req.u.read.resp = &resp;

    int ret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(500));
    if (ret) {
        LOG_ERR("Failed to queue read: %d", ret);
        atomic_set(&read_in_flight, 0);
        return ret;
    }

    if (k_sem_take(&resp.sem, K_MSEC(15000)) != 0) {
        LOG_ERR("Timeout waiting for read");
        /* Worker may still write to static resp later — that's safe.
         * Next call will check if worker caught up via sem. */
        return -ETIMEDOUT;
    }
    atomic_set(&read_in_flight, 0);
    if (resp.res) {
        LOG_ERR("read_audio_data failed: %d", resp.res);
        return -1;
    }
    return resp.read_bytes;
}

int sd_flush_current_file(void)
{
    static struct read_resp resp;
    static atomic_t flush_in_flight;

    if (!atomic_cas(&flush_in_flight, 0, 1)) {
        if (k_sem_take(&resp.sem, K_NO_WAIT) == 0) {
            atomic_set(&flush_in_flight, 0);
        } else {
            LOG_WRN("sd_flush: previous flush still in-flight");
            return -EBUSY;
        }
        if (!atomic_cas(&flush_in_flight, 0, 1)) {
            return -EBUSY;
        }
    }
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_FLUSH_FILE;
    req.u.create_file.resp = &resp;

    int ret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(500));
    if (ret) {
        LOG_ERR("Failed to queue flush: %d", ret);
        atomic_set(&flush_in_flight, 0);
        return ret;
    }

    if (k_sem_take(&resp.sem, K_MSEC(30000)) != 0) {
        LOG_ERR("Timeout waiting for flush");
        return -ETIMEDOUT;
    }
    atomic_set(&flush_in_flight, 0);
    return resp.res;
}

int delete_audio_file(const char *filename)
{

    if (!filename)
        return -EINVAL;

    static struct read_resp resp;
    static atomic_t delete_in_flight;

    if (!atomic_cas(&delete_in_flight, 0, 1)) {
        if (k_sem_take(&resp.sem, K_NO_WAIT) == 0) {
            atomic_set(&delete_in_flight, 0);
        } else {
            LOG_WRN("delete_audio_file: previous delete still in-flight");
            return -EBUSY;
        }
        if (!atomic_cas(&delete_in_flight, 0, 1)) {
            return -EBUSY;
        }
    }
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_DELETE_FILE;
    strncpy(req.u.delete_file.filename, filename, MAX_FILENAME_LEN - 1);
    req.u.delete_file.resp = &resp;

    int ret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(500));
    if (ret) {
        LOG_ERR("Failed to queue delete: %d", ret);
        atomic_set(&delete_in_flight, 0);
        return ret;
    }

    if (k_sem_take(&resp.sem, K_MSEC(30000)) != 0) {
        LOG_ERR("Timeout waiting for delete");
        return -ETIMEDOUT;
    }
    atomic_set(&delete_in_flight, 0);
    if (resp.res < 0 && resp.res != -ENOENT) {
        LOG_ERR("delete_audio_file %s failed: %d", filename, resp.res);
        return resp.res;
    }
    return 0;
}

int clear_audio_directory(void)
{

    static struct read_resp resp;
    static atomic_t clear_in_flight;

    if (!atomic_cas(&clear_in_flight, 0, 1)) {
        if (k_sem_take(&resp.sem, K_NO_WAIT) == 0) {
            atomic_set(&clear_in_flight, 0);
        } else {
            LOG_WRN("clear_audio_directory: previous clear still in-flight");
            return -EBUSY;
        }
        if (!atomic_cas(&clear_in_flight, 0, 1)) {
            return -EBUSY;
        }
    }
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_CLEAR_AUDIO_DIR;
    req.u.clear_dir.resp = &resp;

    int ret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(500));
    if (ret) {
        LOG_ERR("Failed to queue clear_dir: %d", ret);
        atomic_set(&clear_in_flight, 0);
        return -1;
    }

    if (k_sem_take(&resp.sem, K_MSEC(60000)) != 0) {
        LOG_ERR("Timeout waiting for clear_dir");
        return -1;
    }
    atomic_set(&clear_in_flight, 0);
    if (resp.res) {
        LOG_ERR("clear_audio_directory failed: %d", resp.res);
        return -1;
    }
    return 0;
}

int save_offset(const char *filename, uint32_t offset)
{

    sd_req_t req = {0};
    req.type = REQ_SAVE_OFFSET;
    strncpy(req.u.info.offset_info.oldest_filename, filename, MAX_FILENAME_LEN - 1);
    req.u.info.offset_info.offset_in_file = offset;

    int ret = k_msgq_put(&sd_msgq, &req, K_MSEC(20));
    if (ret) {
        LOG_ERR("Failed to queue save_offset: %d", ret);
        return -1;
    }
    return 0;
}

int create_new_audio_file(void)
{

    static struct read_resp resp;
    static atomic_t create_in_flight;

    if (!atomic_cas(&create_in_flight, 0, 1)) {
        if (k_sem_take(&resp.sem, K_NO_WAIT) == 0) {
            atomic_set(&create_in_flight, 0);
        } else {
            LOG_WRN("create_new_audio_file: previous request still in-flight");
            return -EBUSY;
        }
        if (!atomic_cas(&create_in_flight, 0, 1)) {
            return -EBUSY;
        }
    }
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_CREATE_NEW_FILE;
    req.u.create_file.resp = &resp;

    int ret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(2000));
    if (ret) {
        LOG_ERR("Failed to queue create_new_audio_file: %d", ret);
        atomic_set(&create_in_flight, 0);
        return -1;
    }

    if (k_sem_take(&resp.sem, K_MSEC(25000)) != 0) {
        LOG_ERR("Timeout waiting for create_new_audio_file");
        return -1;
    }
    atomic_set(&create_in_flight, 0);
    if (resp.res) {
        LOG_ERR("create_new_audio_file failed: %d", resp.res);
        return -1;
    }

    if (atomic_get(&ble_connected))
        ble_connect_time_ms = k_uptime_get();
    return 0;
}

int get_audio_file_stats(uint32_t *file_count, uint64_t *total_size)
{

    if (!file_count || !total_size)
        return -EINVAL;

    if (sd_shutdown_in_progress) {
        if (cached_stats_valid_until_ms > 0) {
            *file_count = cached_stats_file_count;
            *total_size = cached_stats_total_size;
            return 0;
        }
        return -ECANCELED;
    }

    static struct file_stats_resp resp;
    static atomic_t stats_in_flight;
    int64_t now = k_uptime_get();
    k_timeout_t wait_timeout = atomic_get(&ble_connected) ? K_MSEC(1000) : K_MSEC(30000);

    if (now < cached_stats_valid_until_ms) {
        *file_count = cached_stats_file_count;
        *total_size = cached_stats_total_size;
        return 0;
    }

    if (!atomic_cas(&stats_in_flight, 0, 1)) {
        if (k_sem_take(&resp.sem, K_NO_WAIT) == 0) {
            atomic_set(&stats_in_flight, 0);
        } else {
            LOG_WRN("get_audio_file_stats: previous request still in-flight");
            if (cached_stats_valid_until_ms > 0) {
                *file_count = cached_stats_file_count;
                *total_size = cached_stats_total_size;
                return 0;
            }
            return -EBUSY;
        }
        if (!atomic_cas(&stats_in_flight, 0, 1)) {
            return -EBUSY;
        }
    }
    k_sem_init(&resp.sem, 0, 1);

    sd_req_t req = {0};
    req.type = REQ_GET_FILE_STATS;
    req.u.file_stats.resp = &resp;

    int ret = k_msgq_put(&sd_prio_msgq, &req, K_MSEC(2000));
    if (ret) {
        LOG_ERR("Failed to queue get_file_stats: %d", ret);
        atomic_set(&stats_in_flight, 0);
        if (cached_stats_valid_until_ms > 0) {
            *file_count = cached_stats_file_count;
            *total_size = cached_stats_total_size;
            return 0;
        }
        return -1;
    }

    if (k_sem_take(&resp.sem, wait_timeout) != 0) {
        LOG_ERR("Timeout waiting for get_file_stats");
        atomic_set(&stats_in_flight, 0);
        if (cached_stats_valid_until_ms > 0) {
            *file_count = cached_stats_file_count;
            *total_size = cached_stats_total_size;
            return 0;
        }
        return -ETIMEDOUT;
    }
    atomic_set(&stats_in_flight, 0);
    if (resp.res) {
        LOG_ERR("get_audio_file_stats failed: %d", resp.res);
        return -1;
    }

    cached_stats_file_count = resp.file_count;
    cached_stats_total_size = resp.total_size;
    cached_stats_valid_until_ms = k_uptime_get() + FILE_CACHE_TTL_MS;

    *file_count = resp.file_count;
    *total_size = resp.total_size;
    return 0;
}

