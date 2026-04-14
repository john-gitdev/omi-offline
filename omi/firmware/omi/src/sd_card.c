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

LOG_MODULE_REGISTER(sd_card, CONFIG_LOG_DEFAULT_LEVEL);

#define DISK_DRIVE_NAME CONFIG_SDMMC_VOLUME_NAME
#define SD_REQ_QUEUE_MSGS 250
#define SD_PRIO_QUEUE_MSGS 10
#define SD_FSYNC_INTERVAL_MS (60 * 1000)
#define WRITE_DRAIN_BURST 16
#define ERROR_THRESHOLD 5

/* SD power-gating: sleep SD between write bursts to reduce active duty cycle.
 * GATE_SLEEP_MS: max time SD stays off (queue holds 21.5s at 5100 B/s — 15s is safe).
 * GATE_WAKE_THRESHOLD: queue depth that triggers early wake (70% of 250 = 175 items ≈ 15s). */
#define GATE_SLEEP_MS       15000
#define GATE_WAKE_THRESHOLD ((SD_REQ_QUEUE_MSGS * 70) / 100)
#define FILE_CACHE_TTL_MS (30 * 1000)

/* LittleFS paths are relative to FS root (no mount-point prefix) */
#define FILE_DATA_DIR  "audio"
#define FILE_INFO_PATH "info.txt"
/* Magic cookie written on every clean LFS format.  If lfs_mount() accidentally
 * succeeds on stale FatFS data (bytes happen to pass LFS superblock CRC), the
 * magic file will be absent or contain wrong bytes — triggering a reformat. */
#define LFS_MAGIC_PATH  ".lfs_magic"
#define LFS_MAGIC_VALUE 0x4C465356u /* 'L','F','S','V' */

/* ------------------------------------------------------------------ */
/* LittleFS state                                                     */
/* ------------------------------------------------------------------ */

/* Raw LFS instance */
static lfs_t lfs_fs;

/* Open file handles */
static lfs_file_t lfs_fil_data;
static lfs_file_t lfs_fil_info;

/* Static buffers for lfs_file_opencfg (avoids heap allocation)
 * Size must match cache_size (LFS_CACHE_SIZE = 8192). */
static uint8_t lfs_fdata_buf[8192];
static uint8_t lfs_finfo_buf[8192];
static struct lfs_file_config lfs_fdata_cfg = {.buffer = lfs_fdata_buf};
static struct lfs_file_config lfs_finfo_cfg = {.buffer = lfs_finfo_buf};


/* LFS I/O buffers — sized to cache_size (8192) for multi-sector I/O */
static uint8_t lfs_read_buf[8192];
static uint8_t lfs_prog_buf[8192];
/* Lookahead buffer sizing:
 * 128 bytes = 1024 blocks = 4 MB window → too small for 512 MB SD (128K blocks).
 * Every time the window is exhausted, LFS triggers a FULL filesystem traversal
 * (lfs_alloc_scan → lfs_fs_traverse_) which reads every block in every file.
 * With 200 MB of data (~50K blocks) this costs 10-50+ seconds per scan over SPI.
 *
 * 2048 bytes = 16384 blocks = 64 MB window → only ~8 scans to cover entire disk.
 * Reduces scan frequency from every ~4 MB written to every ~64 MB written.
 * Cost: 1920 bytes extra static RAM (nRF52840 has 256 KB). */
#define LFS_LOOKAHEAD_SIZE 2048
static uint8_t lfs_lookahead_buf[LFS_LOOKAHEAD_SIZE];

/* Shared temp sector buffer â€” only used from worker thread, safe as static */
static uint8_t _lfs_io_tmp[512];

/* ------------------------------------------------------------------ */
/* Disk sector size (always 512 for SD) */
#define DISK_SECTOR_SIZE 512
/* LFS block size: groups 8 sectors into one LFS block.
 * With 512-byte blocks, a 512 MB SD has 1M blocks and LFS metadata overhead
 * is enormous (CTZ skip-lists, lookahead scans).  4096-byte blocks reduce
 * the block count to ~128K and cut metadata overhead by ~8x. */
#define LFS_BLOCK_SIZE 8192
#define LFS_CACHE_SIZE LFS_BLOCK_SIZE                         /* cache = 1 full block for multi-sector I/O */
#define SECTORS_PER_BLOCK (LFS_BLOCK_SIZE / DISK_SECTOR_SIZE) /* 16 */
/* LittleFS disk_access callbacks                                      */
/* ------------------------------------------------------------------ */

/*
 * Map LFS (block, offset) to disk sector.
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
    (void) disk_access_ioctl(DISK_DRIVE_NAME, DISK_IOCTL_CTRL_SYNC, NULL);
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
    .lookahead_size = LFS_LOOKAHEAD_SIZE, /* 2048 bytes = 16384 blocks = 64 MB window */

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
static bool sd_write_blocked = false;
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

/* Protects current_filename / current_file_path across threads.
 * The SD worker updates these during file creation and TMP→hex rename;
 * the storage thread reads them via sd_is_current_recording_file(). */
static K_MUTEX_DEFINE(current_filename_lock);

/* Deferred control requests when prio queue is temporarily saturated */
static atomic_t pending_flush_on_ble_connect;
static atomic_t pending_rotate_on_ble_connect;
static atomic_t pending_time_synced;
static atomic_t pending_time_synced_utc;
static atomic_t proactive_wipe_requested;

static bool is_mounted = false;
static bool sd_enabled = false;
static bool sd_shutdown_in_progress = false;
static uint32_t current_file_size = 0;
static size_t bytes_since_sync = 0;
static int64_t last_file_sync_uptime_ms = 0;

/* Current writing file info */
static char current_filename[MAX_FILENAME_LEN] = {0};
static char current_file_path[64] = {0};
static int64_t current_file_created_uptime_ms = 0;
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
static uint8_t lfs_read_handle_buf[8192];
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
        }
    }
}

void build_filename_from_meta(const AudioFileMeta_t* meta, char* out_buffer, size_t max_len)
{
    if (meta->is_stats) {
        snprintf(out_buffer, max_len, "stats.txt");
    } else if (meta->is_tmp) {
        snprintf(out_buffer, max_len, "TMP_%08X_%08X.txt", meta->timestamp, meta->uptime_offset);
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

/* Forward declarations */
void sd_worker_thread(void);
static void process_write_data_req(const sd_req_t *req);
static int create_audio_file_with_timestamp(void);
static bool should_rotate_file(void);
static void build_file_path(const char *filename, char *path, size_t path_size);
static void invalidate_file_cache(void);
static void update_current_file_cache_size(uint32_t delta);
static void sort_cached_file_entries(void);

static void process_save_offset_req(const sd_req_t *req)
{
    if (sd_write_blocked) {
        if ((k_uptime_get() - last_write_error_uptime_ms) > 2000) {
            sd_write_blocked = false;
            writing_error_counter = 0;
            LOG_INF("[SD_WORK] Attempting recovery from write-blocked state (offset)");
        } else {
            return;
        }
    }

    lfs_file_seek(&lfs_fs, &lfs_fil_info, 0, LFS_SEEK_SET);
    lfs_ssize_t bw = lfs_file_write(&lfs_fs, &lfs_fil_info, &req->u.info.offset_info, sizeof(sd_offset_info_t));
    if (bw == (lfs_ssize_t) sizeof(sd_offset_info_t)) {
        lfs_file_sync(&lfs_fs, &lfs_fil_info);
        memcpy(&current_offset_info, &req->u.info.offset_info, sizeof(sd_offset_info_t));
    } else {
        last_write_error_uptime_ms = k_uptime_get();
        LOG_ERR("[SD_WORK] save offset write err %d", (int) bw);
    }
}

static void drain_pending_write_queue_for_shutdown(void)
{
    while (1) {
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
}

static void process_write_data_req(const sd_req_t *req)
{
    if (sd_write_blocked) {
        if ((k_uptime_get() - last_write_error_uptime_ms) > 2000) {
            sd_write_blocked = false;
            writing_error_counter = 0;
            LOG_INF("[SD_WORK] Attempting recovery from write-blocked state (data)");
        } else {
            return;
        }
    }

    if (current_filename[0] == '\0') {
        int res = create_audio_file_with_timestamp();
        if (res < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            return;
        }
        atomic_clear(&current_file_deleted);
    }

    if (should_rotate_file()) {
        LOG_INF("[SD_WORK] Rotating file after %d min", (int)(FILE_ROTATION_INTERVAL_MS / 60000));
        int res = create_audio_file_with_timestamp();
        if (res < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            return;
        }
    }

    lfs_ssize_t bw = lfs_file_write(&lfs_fs, &lfs_fil_data, req->u.write.buf, req->u.write.len);
    if (bw < 0 || (size_t)bw != req->u.write.len) {
        last_write_error_uptime_ms = k_uptime_get();
        writing_error_counter++;
        LOG_ERR("write error bw=%d wanted=%u", (int)bw, (unsigned)req->u.write.len);

        if (writing_error_counter > ERROR_THRESHOLD) {
            sd_write_blocked = true;
            LOG_ERR("Too many write errors, blocking write queue");
        }
        return;
    }

    writing_error_counter = 0;
    current_file_size += (uint32_t)bw;
    bytes_since_sync += (size_t)bw;
    update_current_file_cache_size((uint32_t)bw);

    bool sync_due_to_interval =
        (bytes_since_sync > 0) && ((k_uptime_get() - last_file_sync_uptime_ms) >= SD_FSYNC_INTERVAL_MS);

    if (sync_due_to_interval) {
        int err = lfs_file_sync(&lfs_fs, &lfs_fil_data);
        if (err < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            LOG_ERR("sync error err=%d", err);
            sd_write_blocked = true;
            return;
        }
        data_sync_gen++;
        bytes_since_sync = 0;
        last_file_sync_uptime_ms = k_uptime_get();
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
            pm_device_action_run(spi_dev, PM_DEVICE_ACTION_SUSPEND);
        }
        gpio_pin_configure(DEVICE_DT_GET(DT_NODELABEL(gpio1)), 11, GPIO_DISCONNECTED);
        ret = gpio_pin_set_dt(&sd_en, 0);
        sd_enabled = false;
    }
    return ret;
}

/* ------------------------------------------------------------------ */
/* LittleFS mount / unmount                                            */
/* ------------------------------------------------------------------ */

static void lfs_close_files(void)
{
    lfs_file_close(&lfs_fs, &lfs_fil_data);
    lfs_file_close(&lfs_fs, &lfs_fil_info);
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    current_filename[0] = '\0';
    current_file_path[0] = '\0';
    k_mutex_unlock(&current_filename_lock);
}

/*
 * Mount the filesystem.  LittleFS mounts existing FS or formats on first use.
 *
 * Key difference from FATFS: if there is any corruption LittleFS recovers
 * from its journal automatically â€” no mkfs needed, no power-loss dirty bit.
 */
/**
 * check_or_write_magic - verify or create the LFS format-version cookie.
 *
 * After a successful lfs_mount() call this function:
 *   - Returns 0 if the magic file exists and contains LFS_MAGIC_VALUE → healthy FS.
 *   - Returns 0 and writes the magic file if it is absent → fresh format, first boot.
 *   - Returns -EBADMSG if the file exists but the value is wrong → ghost mount on
 *     old FatFS data; caller must lfs_unmount + lfs_format + lfs_mount.
 *
 * NOTE: reuses lfs_finfo_buf/cfg because the info file is not open at mount time.
 */
static int check_or_write_magic(void)
{
    lfs_file_t f;
    uint32_t   magic = 0;

    int ret = lfs_file_opencfg(&lfs_fs, &f, LFS_MAGIC_PATH, LFS_O_RDONLY, &lfs_finfo_cfg);
    if (ret == LFS_ERR_OK) {
        lfs_ssize_t rd = lfs_file_read(&lfs_fs, &f, &magic, sizeof(magic));
        lfs_file_close(&lfs_fs, &f);
        if (rd == (lfs_ssize_t)sizeof(magic) && magic == LFS_MAGIC_VALUE) {
            return 0; /* clean LFS filesystem confirmed */
        }
        LOG_WRN("[SD] LFS magic mismatch (read=0x%08X expected=0x%08X) — ghost mount detected",
                magic, LFS_MAGIC_VALUE);
        return -EBADMSG;
    }

    /* File absent: this is a freshly formatted filesystem — write the cookie. */
    ret = lfs_file_opencfg(&lfs_fs, &f, LFS_MAGIC_PATH, LFS_O_WRONLY | LFS_O_CREAT, &lfs_finfo_cfg);
    if (ret != LFS_ERR_OK) {
        LOG_ERR("[SD] Failed to create LFS magic file: %d", ret);
        return ret;
    }
    magic = LFS_MAGIC_VALUE;
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
        /* Write the magic cookie on the freshly formatted filesystem. */
        (void)check_or_write_magic();
    } else {
        /* Mount succeeded — verify the magic cookie to detect ghost mounts
         * (lfs_mount accidentally succeeding on stale FatFS data). */
        int magic_ret = check_or_write_magic();
        if (magic_ret == -EBADMSG) {
            LOG_WRN("[SD] Ghost mount on FatFS data detected — forcing clean format");
            lfs_unmount(&lfs_fs);
            ret = lfs_format(&lfs_fs, &lfs_cfg);
            if (ret != LFS_ERR_OK) {
                LOG_ERR("LFS format (ghost mount recovery) failed: %d", ret);
                sd_enable_power(false);
                return -EIO;
            }
            ret = lfs_mount(&lfs_fs, &lfs_cfg);
            if (ret != LFS_ERR_OK) {
                LOG_ERR("LFS mount after ghost-mount recovery failed: %d", ret);
                sd_enable_power(false);
                return -EIO;
            }
            (void)check_or_write_magic();
        }
    }

    is_mounted = true;
    LOG_INF("LittleFS mounted OK (block_size=%u, block_count=%u, lookahead=%u bytes = %u blocks window)",
            (unsigned) lfs_cfg.block_size,
            (unsigned) lfs_cfg.block_count,
            (unsigned) lfs_cfg.lookahead_size,
            (unsigned) lfs_cfg.lookahead_size * 8);
    return 0;
}

static int sd_unmount(void)
{
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

/* ------------------------------------------------------------------ */
/* SD power-gating (sleep/wake between write bursts)                  */
/* ------------------------------------------------------------------ */

/* Sync and close open file handles, unmount, power off the SD.
 * Deliberately does NOT clear current_filename/current_file_path so
 * sd_gate_wake() can reopen the same file and continue appending. */
static void sd_gate_sleep(void)
{
    close_read_handle();
    if (current_filename[0] != '\0') {
        lfs_file_sync(&lfs_fs, &lfs_fil_data);
        data_sync_gen++;
        bytes_since_sync = 0;
        last_file_sync_uptime_ms = k_uptime_get();
        lfs_file_close(&lfs_fs, &lfs_fil_data);
    }
    lfs_file_close(&lfs_fs, &lfs_fil_info);
    if (is_mounted) {
        lfs_unmount(&lfs_fs);
        is_mounted = false;
    }
    sd_enable_power(false);
    LOG_INF("[SD_GATE] Powered off");
}

/* Power on SD, remount LFS, reopen the info file and the current
 * audio file in append mode.  No lfs_fs_gc — GC is boot-only. */
static int sd_gate_wake(void)
{
    int ret = sd_mount();
    if (ret != 0) {
        LOG_ERR("[SD_GATE] Remount failed: %d", ret);
        return ret;
    }

    ret = lfs_file_opencfg(&lfs_fs, &lfs_fil_info, FILE_INFO_PATH,
                           LFS_O_CREAT | LFS_O_RDWR, &lfs_finfo_cfg);
    if (ret < 0) {
        LOG_ERR("[SD_GATE] Reopen info failed: %d", ret);
        sd_write_blocked = true;
        return ret;
    }

    if (current_filename[0] != '\0') {
        ret = lfs_file_opencfg(&lfs_fs, &lfs_fil_data, current_file_path,
                               LFS_O_WRONLY | LFS_O_CREAT | LFS_O_APPEND, &lfs_fdata_cfg);
        if (ret < 0) {
            /* File missing or corrupt — process_write_data_req will create a new one */
            LOG_WRN("[SD_GATE] Reopen '%s' failed (%d) — new file on next write",
                    current_file_path, ret);
            k_mutex_lock(&current_filename_lock, K_FOREVER);
            current_filename[0] = '\0';
            current_file_path[0] = '\0';
            k_mutex_unlock(&current_filename_lock);
        }
    }

    LOG_INF("[SD_GATE] Powered on, remounted");
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
        if (a[i] == '\0' || b[i] == '\0')
            break;
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

#define FILE_CONTINUE_THRESHOLD_SEC (2 * 60)

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

    current_file_size = (uint32_t) lfs_file_size(&lfs_fs, &lfs_fil_data);
    bytes_since_sync = 0;

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

    if (!rtc_valid) {
        return -1;
    }

    /* RTC valid: find the most recent timestamped file within the continuation window. */
    if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) < 0) {
        return -1;
    }

    char latest_filename[MAX_FILENAME_LEN] = {0};
    uint32_t latest_timestamp = 0;

    while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
        if (info.type != LFS_TYPE_REG)
            continue;
        char *dot = strrchr(info.name, '.');
        if (dot && strcasecmp(dot, ".txt") == 0) {
            uint32_t ts = (uint32_t) strtoul(info.name, NULL, 16);
            if (ts > latest_timestamp) {
                latest_timestamp = ts;
                strncpy(latest_filename, info.name, sizeof(latest_filename) - 1);
            }
        }
    }
    lfs_dir_close(&lfs_fs, &dir);

    if (latest_filename[0] == '\0')
        return -1;

    int32_t diff = (int32_t) (current_time - latest_timestamp);
    LOG_INF("[SD_BOOT] Latest file: %s diff=%d s", latest_filename, diff);

    if (diff < 0 || diff > FILE_CONTINUE_THRESHOLD_SEC)
        return -1;

    LOG_INF("[SD_BOOT] Continuing file: %s", latest_filename);
    return _open_file_for_continuation(latest_filename, /*needs_rename=*/false);
}

static int create_audio_file_with_timestamp(void)
{
    bool rtc_valid = rtc_is_valid();
    uint32_t timestamp = 0;

    if (rtc_valid) {
        timestamp = get_utc_time();
        if (timestamp == 0 || timestamp < 1700000000U)
            rtc_valid = false;
    }

    /* Close current file if open */
    if (current_filename[0] != '\0') {
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

    k_mutex_lock(&current_filename_lock, K_FOREVER);
    if (rtc_valid) {
        snprintf(current_filename, sizeof(current_filename), "%08X.txt", timestamp);
        current_file_needs_rename = false;
    } else {
        uint32_t boot_uptime = (uint32_t) k_uptime_get_32();
        snprintf(current_filename, sizeof(current_filename), "TMP_%08X_%08X.txt", boot_uptime, device_session_id);
        current_file_needs_rename = true;
    }
    build_file_path(current_filename, current_file_path, sizeof(current_file_path));
    k_mutex_unlock(&current_filename_lock);

    LOG_INF("Creating audio file: %s", current_file_path);
    if (!rtc_valid)
        LOG_WRN("RTC not synced, temp file: %s", current_filename);

    int ret = lfs_file_opencfg(
        &lfs_fs, &lfs_fil_data, current_file_path, LFS_O_CREAT | LFS_O_RDWR | LFS_O_APPEND, &lfs_fdata_cfg);
    if (ret < 0) {
        LOG_ERR("Failed to create %s: %d", current_file_path, ret);
        k_mutex_lock(&current_filename_lock, K_FOREVER);
        current_filename[0] = '\0';
        current_file_path[0] = '\0';
        k_mutex_unlock(&current_filename_lock);
        return ret;
    }

    current_file_size = 0;
    bytes_since_sync = 0;

    writing_error_counter = 0;
    sd_write_blocked = false;
    last_file_sync_uptime_ms = k_uptime_get();
    current_file_created_uptime_ms = k_uptime_get();

    LOG_INF("Audio file created: %s", current_filename);
    invalidate_file_cache();
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
    if (current_file_created_uptime_ms == 0)
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
static uint32_t filename_sort_ts(const char *name)
{
    if (strncmp(name, "TMP_", 4) == 0) {
        return UINT32_MAX;
    }
    return (uint32_t) strtoul(name, NULL, 16);
}

static int compare_filenames(const void *a, const void *b)
{
    uint32_t ta = filename_sort_ts((const char *) a);
    uint32_t tb = filename_sort_ts((const char *) b);
    return (ta < tb) ? -1 : (ta > tb) ? 1 : 0;
}

static void update_cached_free_bytes(void)
{
    if (lfs_cfg.block_count > 0) {
        uint64_t total_cap = (uint64_t)lfs_cfg.block_count * lfs_cfg.block_size;
        cached_free_bytes = (cached_total_file_size < total_cap)
                            ? (uint32_t)(total_cap - cached_total_file_size) : 0;
    }
}

static void invalidate_file_cache(void)
{
    file_cache_valid = false;
    cached_stats_valid_until_ms = 0;
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

    cached_total_file_size += delta;
    cached_stats_total_size = cached_total_file_size;
    cached_stats_file_count = cached_total_file_count;
    update_cached_free_bytes();
    cached_stats_valid_until_ms = k_uptime_get() + FILE_CACHE_TTL_MS;

    k_mutex_lock(&file_cache_mutex, K_FOREVER);
    AudioFileMeta_t current_meta;
    parse_filename_to_meta(current_filename, current_file_size, &current_meta);

    for (int i = 0; i < cached_file_list_count; i++) {
        if (compare_meta(&cached_file_meta[i], &current_meta) == 0) {
            cached_file_meta[i].file_size += delta;
            k_mutex_unlock(&file_cache_mutex);
            return;
        }
    }

    /* Cache became stale (e.g. filename not indexed due truncation). */
    invalidate_file_cache();
    k_mutex_unlock(&file_cache_mutex);
}

static int refresh_file_cache(void)
{
    if (!is_mounted) {
        return -ENODEV;
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

    cached_total_file_count = total_count;
    cached_total_file_size = total_size;
    cached_stats_file_count = total_count;
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

    /* Calculate the UTC offset between uptime and real-world time */
    uint32_t rtc_offset = synced_utc_time - (uint32_t)(k_uptime_get() / 1000U);
    LOG_INF("Time sync received: offset is %u s", rtc_offset);

    /* Retroactively rename all CLOSED temporary files */
    lfs_dir_t dir;
    struct lfs_info info;
    if (lfs_dir_open(&lfs_fs, &dir, FILE_DATA_DIR) == 0) {
        char old_path[128], new_path[128], new_fn[MAX_FILENAME_LEN];
        while (lfs_dir_read(&lfs_fs, &dir, &info) > 0) {
            /* Only rename finished TMP_ segments (don't touch the active one) */
            if (info.type == LFS_TYPE_REG && strncmp(info.name, "TMP_", 4) == 0 &&
                strcmp(info.name, current_filename) != 0) {
                
                uint32_t original_uptime_ms = (uint32_t)strtoul(info.name + 4, NULL, 16);
                uint32_t correct_ts = (original_uptime_ms / 1000U) + rtc_offset;
                
                snprintf(new_fn, MAX_FILENAME_LEN, "%08X.txt", correct_ts);
                build_file_path(info.name, old_path, 128);
                build_file_path(new_fn, new_path, 128);
                
                if (lfs_rename(&lfs_fs, old_path, new_path) == 0) {
                    LOG_INF("Retroactive rename: %s -> %s", info.name, new_fn);
                }
                /* Yield to allow other prio-msgq requests (like get list) to be processed
                 * between renames if the loop is long. */
                k_yield();
            }
        }
        lfs_dir_close(&lfs_fs, &dir);
    }
    invalidate_file_cache();
}

/* ------------------------------------------------------------------ */
/* Worker thread & task definitions                                    */
/* ------------------------------------------------------------------ */

#define SD_WORKER_STACK_SIZE 16384
#define SD_WORKER_PRIORITY 7
K_THREAD_STACK_DEFINE(sd_worker_stack, SD_WORKER_STACK_SIZE);
static struct k_thread sd_worker_thread_data;
static k_tid_t sd_worker_tid = NULL;

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

    /* ---- Mount ---- */
    res = sd_mount();
    if (res != 0) {
        LOG_ERR("[SD_WORK] mount failed: %d", res);
        sd_write_blocked = true;
        return;
    }

    /* ---- Handle proactive wipe request (e.g. firmware update) ---- */
    if (atomic_cas(&proactive_wipe_requested, 1, 0)) {
        LOG_INF("[SD_WORK] Executing early reformat requested by main...");
        lfs_unmount(&lfs_fs);
        lfs_format(&lfs_fs, &lfs_cfg);
        lfs_mount(&lfs_fs, &lfs_cfg);
        check_or_write_magic();
        LOG_INF("[SD_WORK] Early reformat complete.");
    }

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
                check_or_write_magic();
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
                check_or_write_magic();
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
                check_or_write_magic();
                res = create_audio_file_with_timestamp();
            }
            if (res < 0) {
                sd_write_blocked = true;
            }
        }
    }

    /* ---- SD boot init complete, allow writes ---- */
    atomic_set(&sd_boot_ready, 1);
    {
        long dropped = (long)atomic_get(&boot_dropped_frames);
        LOG_INF("[SD_BOOT] SD card ready for audio writes (boot took %lld ms, "
                "%ld audio frames dropped during boot)", k_uptime_get(), dropped);
        if (dropped > 0) {
            LOG_WRN("[SD_BOOT] %ld audio frames were dropped while SD was booting", dropped);
        }
    }

    /* ---- Main loop ---- */
    int consec_writes = 0;
    bool in_high_watermark = false;
    bool sd_gated = false;
    int64_t gate_start_ms = 0;

    struct k_poll_event gate_events[2] = {
        K_POLL_EVENT_INITIALIZER(K_POLL_TYPE_MSGQ_DATA_AVAILABLE,
                                 K_POLL_MODE_NOTIFY_ONLY, &sd_prio_msgq),
        K_POLL_EVENT_INITIALIZER(K_POLL_TYPE_MSGQ_DATA_AVAILABLE,
                                 K_POLL_MODE_NOTIFY_ONLY, &sd_msgq),
    };

    while (1) {
        /* ---- Gate sleep loop: SD is powered off ---- */
        if (sd_gated) {
            gate_events[0].state = K_POLL_STATE_NOT_READY;
            gate_events[1].state = K_POLL_STATE_NOT_READY;
            k_poll(gate_events, 2, K_MSEC(500));

            uint32_t wq = k_msgq_num_used_get(&sd_msgq);
            uint32_t pq = k_msgq_num_used_get(&sd_prio_msgq);
            bool timed_out = (k_uptime_get() - gate_start_ms) >= GATE_SLEEP_MS;
            bool deferred  = atomic_get(&pending_flush_on_ble_connect) ||
                             atomic_get(&pending_time_synced);

            if (pq > 0 || wq >= GATE_WAKE_THRESHOLD || timed_out || deferred) {
                /* Errors set sd_write_blocked; un-gate either way so the
                 * write_blocked fallback path handles recovery. */
                sd_gate_wake();
                sd_gated = false;
            }
            continue;
        }


        /* Handle deferred control requests first (when queue was saturated). */
        if (atomic_cas(&pending_flush_on_ble_connect, 1, 0)) {
            /* Attempt flush inline; if it fails, re-set the flag so the
             * next loop iteration retries instead of silently losing it. */
            if (!atomic_get(&current_file_deleted) && current_filename[0] != '\0') {
                int sr = lfs_file_sync(&lfs_fs, &lfs_fil_data);
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
            req.u.time_synced.utc_time = (uint32_t)atomic_get(&pending_time_synced_utc);
            goto handle_req;
        }

        uint32_t write_usage = k_msgq_num_used_get(&sd_msgq);
        uint32_t prio_usage = k_msgq_num_used_get(&sd_prio_msgq);
        
        /* Hysteresis: Enter panic mode at 70%, Exit at 50% */
        if (!in_high_watermark && write_usage >= (SD_REQ_QUEUE_MSGS * 70) / 100) {
            in_high_watermark = true;
            LOG_INF("[SD_WORK] High watermark reached (%u/%d), entering priority drain",
                    write_usage, SD_REQ_QUEUE_MSGS);
        } else if (in_high_watermark && write_usage <= (SD_REQ_QUEUE_MSGS * 50) / 100) {
            in_high_watermark = false;
            LOG_INF("[SD_WORK] Queue depth safe (%u/%d), resuming normal schedule", 
                    write_usage, SD_REQ_QUEUE_MSGS);
        }

        /* 
         * Scheduling Policy:
         * 1. If in high watermark, aggressively drain writes.
         * 2. If we have pending writes and haven't exceeded our burst limit (16), process writes.
         * 3. If there are no priority requests, keep processing writes.
         */
        if (write_usage > 0 && (in_high_watermark || consec_writes < 16 || prio_usage == 0)) {
            if (k_msgq_get(&sd_msgq, &req, K_NO_WAIT) == 0) {
                consec_writes++;
                goto handle_req;
            }
        }

        /* 4. Process priority queue (BLE reads/control) if we yielded from writes or writes are empty */
        if (prio_usage > 0) {
            if (k_msgq_get(&sd_prio_msgq, &req, K_NO_WAIT) == 0) {
                consec_writes = 0; /* Reset counter to allow next write burst */
                goto handle_req;
            }
        }

        /* 5. Both queues empty — gate SD off between write bursts */
        if (!sd_write_blocked) {
            sd_gate_sleep();
            sd_gated = true;
            gate_start_ms = k_uptime_get();
            continue;
        }

        /* Write-blocked fallback: keep polling so recovery check in
         * process_write_data_req can fire once the 2s backoff expires. */
        k_timeout_t idle_wait = atomic_get(&ble_connected) ? K_MSEC(10) : K_MSEC(2000);
        if (k_msgq_get(&sd_msgq, &req, idle_wait) == 0) {
            consec_writes++;
            goto handle_req;
        }

        continue;

    handle_req:
        switch (req.type) {

        /* ---- Write data ---- */
        case REQ_WRITE_DATA:
            process_write_data_req(&req);
            break;

        /* ---- Read audio data (uses persistent file handle) ---- */
        case REQ_READ_DATA: {
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
            if (br == 0 && is_active_file && (bytes_since_sync > 0)) {
                if (bytes_since_sync > 0) {
                    lfs_file_sync(&lfs_fs, &lfs_fil_data);
                    data_sync_gen++;
                    bytes_since_sync = 0;
                    last_file_sync_uptime_ms = k_uptime_get();
                }
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
            close_read_handle();
            lfs_file_close(&lfs_fs, &lfs_fil_data);
            k_mutex_lock(&current_filename_lock, K_FOREVER);
            current_filename[0] = '\0';
            k_mutex_unlock(&current_filename_lock);

            lfs_dir_t dir;
            struct lfs_info info;
            char fpath[64];

            {
                /* Two-phase delete: LittleFS forbids lfs_remove() during
                 * lfs_dir_read() — the directory metadata is a CTZ skip-list
                 * and removing an entry mid-iteration causes undefined behavior
                 * (skipped files, double-reads, or corruption). */
                static char del_names[MAX_AUDIO_FILES][MAX_FILENAME_LEN];
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

            /* Reset offset info */
            memset(&current_offset_info, 0, sizeof(current_offset_info));
            lfs_file_seek(&lfs_fs, &lfs_fil_info, 0, LFS_SEEK_SET);
            lfs_file_write(&lfs_fs, &lfs_fil_info, &current_offset_info, sizeof(current_offset_info));
            lfs_file_sync(&lfs_fs, &lfs_fil_info);
            invalidate_file_cache();

            res = create_audio_file_with_timestamp();

            if (req.u.clear_dir.resp) {
                req.u.clear_dir.resp->res = res;
                k_sem_give(&req.u.clear_dir.resp->sem);
            }
            break;
        }

        /* ---- Create new file ---- */
        case REQ_CREATE_NEW_FILE:
            res = create_audio_file_with_timestamp();
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
            int flush_res = 0;
            if (!atomic_get(&current_file_deleted) && current_filename[0] != '\0') {
                int sr = lfs_file_sync(&lfs_fs, &lfs_fil_data);
                if (sr < 0) {
                    LOG_ERR("[SD_WORK] lfs_file_sync failed: %d", sr);
                    flush_res = sr;
                } else {
                    data_sync_gen++;
                    bytes_since_sync = 0;
                    last_file_sync_uptime_ms = k_uptime_get();
                    LOG_INF("[SD_WORK] Flushed %s (%u bytes)", current_filename, current_file_size);
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
            char del_path[64];
            build_file_path(req.u.delete_file.filename, del_path, sizeof(del_path));

            /* Close read handle if we're about to delete the file being read */
            if (read_handle_open && filename_equals_ignore_case(read_handle_filename, req.u.delete_file.filename)) {
                close_read_handle();
            }

            if (current_filename[0] != '\0' &&
                filename_equals_ignore_case(current_filename, req.u.delete_file.filename)) {
                LOG_INF("[SD_WORK] Deleting active recording file");
                lfs_file_close(&lfs_fs, &lfs_fil_data);
                k_mutex_lock(&current_filename_lock, K_FOREVER);
                current_filename[0] = '\0';
                current_file_path[0] = '\0';
                k_mutex_unlock(&current_filename_lock);
                current_file_size = 0;
                bytes_since_sync = 0;
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

        /* ---- Time synced ---- */
        case REQ_TIME_SYNCED:
            if (current_file_needs_rename && current_filename[0] != '\0') {
                /* Rename immediately — the worker thread is the only writer to
                 * lfs_fil_data, so close+rename+reopen is safe regardless of
                 * BLE connection state. The old deferral was overly cautious
                 * and caused TMP files to be invisible to the app's sync. */
                sd_update_filename_after_timesync(req.u.time_synced.utc_time);
                invalidate_file_cache();
            } else if (current_filename[0] == '\0') {
                res = create_audio_file_with_timestamp();
                if (res < 0)
                    LOG_ERR("[SD_WORK] create after time sync failed: %d", res);
            }
            break;

        default:
            LOG_ERR("[SD_WORK] unknown request type %d", req.type);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

bool sd_is_boot_ready(void)
{
    return atomic_get(&sd_boot_ready);
}

uint32_t sd_get_boot_dropped_frames(void)
{
    return (uint32_t)atomic_get(&boot_dropped_frames);
}

void sd_request_wipe(void)
{
    atomic_set(&proactive_wipe_requested, 1);
    LOG_INF("[SD] Proactive wipe flag set for next boot");
}

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
    /* Store value before flag — atomic_set provides ordering. */
    atomic_set(&pending_time_synced_utc, (atomic_val_t)utc_time);
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

uint32_t write_to_file(uint8_t *data, uint32_t length)
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
        int64_t now = k_uptime_get();
        if ((now - last_write_error_uptime_ms) > 2000) {
            sd_write_blocked = false;
            writing_error_counter = 0;
            LOG_INF("Attempting recovery from write-blocked state");
        } else {
            if (now - last_write_blocked_log_ms > 1000) {
                LOG_ERR("write_to_file blocked (permanent SD failure?)");
                last_write_blocked_log_ms = now;
            }
            return 0;
        }
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
        /* Bounded blocking: wait up to 500ms for space in the ordered queue.
         * SD cards frequently stall for 100-400ms during internal maintenance. */
        ret = k_msgq_put(&sd_msgq, &req, K_MSEC(500));
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
    return length;
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

    if (k_sem_take(&resp.sem, K_MSEC(25000)) != 0) {
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

int get_offset(char *filename, uint32_t *offset)
{
    if (!filename || !offset)
        return -EINVAL;
    strncpy(filename, current_offset_info.oldest_filename, MAX_FILENAME_LEN - 1);
    filename[MAX_FILENAME_LEN - 1] = '\0';
    *offset = current_offset_info.offset_in_file;
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




