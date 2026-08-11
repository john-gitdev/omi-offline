/*
 * sd_card.c — raw circular-log audio storage over disk_access (SD NAND via SPI)
 *
 * Architecture:
 *   SD NAND chip → SD SPI stack (disk_access) → sd_ring append-only log
 *
 * Why a raw ring and not a filesystem:
 *   LittleFS has no persistent free-map, so once its lookahead window drains
 *   lfs_alloc runs a full-FS traversal (O(data on disk), 10-50 s over SPI) on
 *   this file's single sd_worker thread — saturating sd_msgq and dropping audio
 *   exactly in the all-day-offline state this device is built for. The ring
 *   appends in O(1) with no free-map and no scan. It owns raw sectors: segments
 *   are delimited by the inline 0xFFFFFFFB header and presented to BLE as
 *   "files" keyed <timestamp>_<session_id>, so the storage protocol and the
 *   app-side WAL are unchanged from the filesystem era.
 *
 *   See sd_ring.h for the on-card layout and durability contract.
 */
#include "lib/core/sd_card.h"
#include "lib/core/transport.h"
#include "lib/core/storage.h"
#include "lib/core/settings.h"
#include "lib/core/sd_ring.h"
#include "lib/core/diag_log.h"

#include <ctype.h>
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
/* Ring backend state                                                  */
/* ------------------------------------------------------------------ */
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
 * branch once SD_FSYNC_INTERVAL_MS (60 s) has elapsed — the wall-clock backstop.
 * 256 KiB is NOT arbitrary: at the measured
 * ~5 KB/s ingest it is ~52 s ≈ the 60 s fsync interval, so the byte cap and the
 * time cap target the SAME ~1 min worst-case loss by design; it is also a power-of-2
 * multiple of the 512 B sector and of the 4 KB NAND page the stage flushes in, so
 * every write stays page-aligned. The byte cap (not a timer) is what bounds loss
 * during DISCONNECTED
 * continuous speech, where the write-wait timeout never fires (audio blocks arrive
 * ~86 ms apart, faster than the 500 ms disconnected wait), so appended bytes are
 * the only elapsed-audio signal.
 *
 * Only an ungraceful stop loses anything, and for an offline-first device that is
 * realistically just the battery going flat — a <~1 min tail loss there is
 * indistinguishable from "didn't charge enough". At the old 4 KB this synced
 * ~1.25x/s, burning power on redundant NAND commits (a CTRL_SYNC can trigger a
 * NAND erase — the expensive op). VAD-resume markers (0xFFFFFFFD) also no longer
 * force a sync: they fire on every speech-after-silence wake and carry only a
 * timestamp re-anchor, so they were the dominant per-wake commit in auto mode. */
#define RING_SYNC_BYTES (256 * 1024)

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
/* After this many failed 2 s soft recoveries, escalate from plain retry to a full
 * power-cycle + remount of the SD card before continuing to drop. */
#define SD_RECOVERY_REMOUNT_THRESHOLD 3

/* SPI3 MOSI hold-low pin — disconnected on SD power-off to prevent back-feed.
   gpio1 pin 11 = P1.11 on the nRF52840 board schematic. */
#define SD_SPI_MOSI_HOLD_PIN 11

#define FILE_CACHE_TTL_MS (30 * 1000)

/* ------------------------------------------------------------------ */
/* General state                                                      */
/* ------------------------------------------------------------------ */

static bool sd_write_blocked = false;
static uint8_t sd_recovery_cycles = 0; /* consecutive failed soft recoveries */
/* The ring's append stage. Handed to sd_ring via sd_ring_init(); sd_ring.c holds
 * only the pointer. Sized (RING_STAGE_BYTES, 40 KB) so a flush covers whole NAND
 * pages and the SPI bus wakes ~0.125x per second of audio rather than per block —
 * the flush cadence is what sets idle current. Until oo-2.9.0 this was a union
 * with the LittleFS write-batch buffer, since exactly one backend was live per
 * boot; with LittleFS gone it is a plain array. */
static uint8_t ring_stage[RING_STAGE_BYTES] __aligned(4);
static int64_t last_write_blocked_log_ms = 0;
static int64_t last_write_error_uptime_ms = 0;
static uint32_t write_drop_packets = 0;
static uint32_t write_drop_bytes = 0;

/* SD boot readiness gate: cleared during init, set once the ring is mounted.
 * write_to_file() silently discards data while this is 0, so the message queue
 * can't fill during the card's power-on + mount window on the worker thread. */
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
 * priority attempt is the on-device fingerprint of that loss. Read via 0x19B10062.
 *
 * NOT a loss signal by itself. An empty bin means NOTHING reached the card for that
 * segment — not one audio block, not one marker. An ACCEPTED marker cannot be the
 * missing part: write_marker_header_to_storage() force-drains its partial 440 B block
 * immediately, so a marker the SD queue takes lands as a full block and puts the bin
 * well past header-only. What is left is a rotation that landed where nothing was
 * being written — in auto mode, any silent stretch. (The narrow exception: if that
 * force-drain is REJECTED the block stays in transport.c's assembly buffer, which no
 * rotation drains — sd_msgq holds formed blocks, not that buffer — so the marker is
 * not lost but lands in the NEXT bin, leaving this one empty. That needs the SD queue
 * full at the marker write, and bumps no counter of its own.)
 * Independent of marker_write_drops:
 * both are boot-cumulative totals naming no segment, so reading them together invents
 * a correlation neither carries. The event log timestamps each one. */
static atomic_t empty_bin_rotations;

/* Why the rotation currently being performed was requested (rotate_reason_t). Read
 * only by ring_create_segment(), and only when the rotation closes an empty bin.
 * SD-worker-thread-local: every ring_create_segment() call site runs on this thread,
 * and cross-thread requests carry their reason in sd_req_t.u.create_file.reason,
 * which the REQ_CREATE_NEW_FILE handler copies here — so a plain byte is sufficient.
 * Each call site sets it immediately before rotating; ring_create_segment() clears it
 * back to UNKNOWN afterwards so a site that forgets records "unattributed" rather
 * than inheriting the previous rotation's reason. */
static uint8_t ring_rotate_reason = ROTATE_REASON_UNKNOWN;
/* Reason of an explicit rotation deferred by a failed durability sync, so the write
 * path can complete it later without losing what asked for it. */
static uint8_t ring_pending_explicit_rotate_reason = ROTATE_REASON_UNKNOWN;

/* Diagnostics: marker-bearing blocks RESCUED at the sd_write_paused gate below —
 * written through the pause instead of dropped. Before oo-2.5.9 this exact block was
 * silently discarded — the one marker-loss path that bumped NO counter at all
 * (marker_write_drops only counts a transport-level block reject; the sd_write_blocked
 * overflow path above still bumps stat_dropped_frames, so it isn't silent, just not
 * marker-specific). The counter tallied those losses; now a nonzero value with
 * recordings finalizing = the rescue firing. Read via 0x19B10062. */
static atomic_t marker_pause_gate_saves;

/* Scan a 440-byte storage block for inline marker headers and return the FIRST
 * matching marker word (0 if none — every real marker header is 0xFFFFFFFx, so 0 is
 * an unambiguous "no marker"). Markers are always 4-byte aligned by the transport, so
 * scanning 4-byte-aligned words is exact. The sentinel list lives here ONCE;
 * `include_resume` selects the marker SET so the call sites can't drift out of sync
 * as marker types / alignment change:
 *   - include_resume = true: EVERY marker type, incl. 0xFFFFFFFD VAD-resume. The
 *     sd_write_paused rescue passes true so NO marker is dropped through a pause
 *     (before oo-2.5.9 that block was silently discarded).
 *   - include_resume = false (block_has_critical_marker): boundary + user markers
 *     only (priority-start / mute-off / mute-on / session-end / button-tap). Used to
 *     decide the immediate force-sync (an out-of-band CTRL_SYNC + cursor write).
 *     0xFFFFFFFD is excluded there because it fires on EVERY speech-after-silence
 *     wake (many/hr in auto mode) and carries only a timestamp re-anchor, so an
 *     ungraceful cut loses at most one re-anchor, not a boundary — it rides the
 *     RING_SYNC_BYTES periodic sync instead, and was the main reason ring's flush
 *     cadence ran ~10x LittleFS's.
 * Returning the word (not a bool) lets the pause-gate rescue tag its diag-log event
 * with which marker (low16) it kept, without a second scan or a duplicate sentinel
 * list. Only called on the rare pause-gate / marker paths, never per audio frame, so
 * the scan cost is irrelevant. */
static uint32_t block_scan_markers(const uint8_t *buf, size_t len, bool include_resume)
{
    for (size_t i = 0; i + 4 <= len; i += 4) {
        uint32_t w = (uint32_t) buf[i] | ((uint32_t) buf[i + 1] << 8) | ((uint32_t) buf[i + 2] << 16) |
                     ((uint32_t) buf[i + 3] << 24);
        if (w == 0xFFFFFFF8u /* priority-start */ || w == 0xFFFFFFF9u /* mute-off */ ||
            w == 0xFFFFFFFAu /* mute-on */ || w == 0xFFFFFFFCu /* session-end */ ||
            w == 0xFFFFFFFEu /* button-tap */ ||
            (include_resume && w == 0xFFFFFFFDu) /* VAD-resume — critical set excludes */) {
            return w;
        }
    }
    return 0;
}

/* Boundary/user markers only (VAD-resume excluded) — force-sync predicate. */
static inline bool block_has_critical_marker(const uint8_t *buf, size_t len)
{
    return block_scan_markers(buf, len, false) != 0;
}

/* Protects current_filename across threads. The SD worker updates it when it
 * opens a segment; the storage thread reads it via sd_is_current_recording_file(). */
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
/* 12 KB: on-device the sd_worker high-water is ~2.7-3.0 KB (0x0062 offset 68) and,
 * after shrinking sd_ring_format()'s zeroing buffer (4 KB→512 B), its peak stays
 * ~6 KB even through a format. The 4 KB reclaimed vs the old 16 KB was handed to
 * the codec thread, which ran at ~17.5/18.6 KB (94%). */
#if defined(CONFIG_OMI_DIAG_LOG)
/* The diagnostic event ring's RAM (DIAG_LOG_RING_BYTES = 2 KB) is carved out of this
 * stack when the feature is compiled in, keeping total RAM identical to production
 * (10240 stack + 2048 ring == the 12288 stack prod uses). The sd_worker high-water is
 * ~3 KB, so 10 KB leaves comfortable headroom. */
#define SD_WORKER_STACK_SIZE (12288 - DIAG_LOG_RING_BYTES)
#else
#define SD_WORKER_STACK_SIZE 12288
#endif
#define SD_WORKER_PRIORITY 7
K_THREAD_STACK_DEFINE(sd_worker_stack, SD_WORKER_STACK_SIZE);
static struct k_thread sd_worker_thread_data;
static k_tid_t sd_worker_tid = NULL;

static bool sd_ready = false;
static bool sd_shutdown_in_progress = false;
static uint32_t current_file_size = 0;
static int64_t last_file_sync_uptime_ms = 0;

/* Current writing file info */
static char current_filename[MAX_FILENAME_LEN] = {0};
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

/* Hardware device references */
static const struct device *const sd_dev = DEVICE_DT_GET(DT_NODELABEL(sdhc0));
static const struct gpio_dt_spec sd_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(sdcard_en_pin), gpios, {0});

K_MSGQ_DEFINE(sd_msgq, sizeof(sd_req_t), SD_REQ_QUEUE_MSGS, 4);
K_MSGQ_DEFINE(sd_prio_msgq, sizeof(sd_req_t), SD_PRIO_QUEUE_MSGS, 4);

/* The ring needs no persistent read handle: a segment read resolves to a byte
 * range in the log and goes straight to disk_access, with none of the open /
 * seek / close cost a filesystem charged per read. */

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
static bool should_rotate_file(void);
static void invalidate_file_cache(void);
static void invalidate_file_cache_deferrable(void);
static void sd_set_io_low_power(bool enable);
static int sd_unmount(void);
/* Defined together near the end of this file. */
static int ring_create_segment(void);
static int ring_find_segment_index(uint32_t timestamp, uint32_t session_id);
static void ring_handle_read_req(const sd_req_t *req);

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
        }
    }
    sd_draining = false;
    sd_suppress_auto_rotate = false;
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

/* --- Ring I/O hooks (see sd_ring_host_t) --- */

/* Resume the bus on the ring's first real disk access. sd_set_io_low_power()
 * short-circuits on an atomic CAS when already awake, so paying this per disk op
 * is far cheaper than what it replaces: waking unconditionally per audio block,
 * when all but roughly one block in RING_STAGE_BYTES/MAX_WRITE_SIZE (~93) only
 * memcpy into the stage and never reach the NAND. */
static void ring_io_wake_cb(void)
{
    sd_set_io_low_power(false);
}

/* A BLE read is queued — a multi-chunk flush should hand the worker back, so a
 * sync's 40 KB flush can't hold the worker for its whole duration. */
static bool ring_io_busy_cb(void)
{
    return k_msgq_num_used_get(&sd_prio_msgq) > 0;
}

static int ring_install_host(void)
{
    const sd_ring_host_t host = {
        .stage = ring_stage,
        .stage_bytes = sizeof(ring_stage),
        .io_wake = ring_io_wake_cb,
        .io_busy = ring_io_busy_cb,
    };
    return sd_ring_init(&host);
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
/* Ring mount / unmount                                                */
/* ------------------------------------------------------------------ */

/*
 * Bring the SD NAND up and hand its raw sectors to sd_ring.
 *
 * allow_format gates the ONLY on-card wipe there is — formatting a card that has
 * no ring on it (fresh, or written by other firmware), i.e. the one-time wipe on
 * migration. The boot mount passes true. The write path's recovery remount
 * (sd_recover_remount) passes FALSE, because a transient read failure that makes
 * the header look absent must never be answered by erasing recordings the app has
 * not synced yet — there, a mount failure is surfaced and writes stay blocked.
 *
 * A persistent failure here leaves recording blocked but the device fully
 * reachable — main.c starts BLE/DFU before it waits on the SD card — so a card
 * or ring fault is recoverable with a firmware update, never a reflash.
 */
static int sd_mount(bool allow_format)
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

    /* The ring needs the disk only 'initialised' from here on; keep the driver
     * active (no CTRL_DEINIT) so sd_ring's sector I/O works. */
    LOG_INF("SD: %u sectors x %u bytes = %u MB",
            sector_count,
            sector_size,
            (unsigned) ((uint64_t) sector_count * sector_size >> 20));

    ring_total_sectors = sector_count;

    /* Hand the ring its stage buffer + I/O hooks before any mount/format, so the
     * stage always starts empty against the cursor we are about to load. */
    ret = ring_install_host();
    if (ret != 0) {
        LOG_ERR("[SD] ring host install failed: %d", ret);
        sd_enable_power(false);
        return ret;
    }

    ret = sd_ring_mount(sector_count);
    if (ret == -ENOENT && allow_format) {
        LOG_WRN("[SD] no ring on card — formatting (one-time SD wipe)");
        ret = sd_ring_format(sector_count);
    }
    if (ret != 0) {
        LOG_ERR("[SD] ring mount/format failed: %d", ret);
        sd_enable_power(false);
        return ret;
    }

    is_mounted = true;
    sd_ready = true;
    LOG_INF("[SD] ring mounted OK");
    return 0;
}

static int sd_unmount(void)
{
    sd_ready = false;
    /* Flush the partial sector + cursor so the shutdown is a clean durability
     * point, then drop power. Retry once on failure (transient SD hiccup at a
     * reboot boundary), and surface the result instead of reporting a clean
     * unmount — app_sd_off() uses this path, so the caller can see that the
     * final batch wasn't persisted. */
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

/*
 * Power-cycle the card and re-mount the ring after repeated write failures.
 *
 * Recovers a class of fault plain retries cannot: the SD controller latching busy,
 * or the SPI slave state machine desyncing. Only re-running the card's init
 * sequence clears those, so without this the device records nothing until someone
 * notices and reboots it. This is the escalation the filesystem backend had at the
 * same threshold; the ring never had one.
 *
 * Deliberately does NOT sync on the way down — the card is failing, and sd_unmount's
 * two sync attempts would just be two more failed writes. Whatever was staged in RAM
 * is therefore lost: sd_ring_init() re-runs inside sd_mount() and starts the stage
 * empty against the cursor it reloads, so recording resumes from the last durable
 * cursor. That is the same bound a power cut already carries (RING_SYNC_BYTES, or
 * the 60 s backstop), and far better than staying deaf indefinitely.
 *
 * The open segment is abandoned rather than resumed — current_filename is cleared so
 * the next write opens a fresh one, matching what the filesystem path did after its
 * remount (it deliberately did not reopen the audio file either). Never formats.
 */
static int sd_recover_remount(void)
{
    LOG_WRN("[SD_WORK] %d failed recoveries — power-cycling + remounting SD",
            SD_RECOVERY_REMOUNT_THRESHOLD);
    sd_set_io_low_power(false);
    is_mounted = false;
    sd_ready = false;
    sd_enable_power(false);
    k_msleep(50);

    /* Abandon the open segment BEFORE attempting the mount, not after it succeeds.
     * The power-cycle has already invalidated it either way, and if the mount fails
     * this is what stops the write path's backoff buffering from staging audio into
     * a card that is powered off — that guard keys on current_filename. */
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    current_filename[0] = '\0';
    k_mutex_unlock(&current_filename_lock);
    current_file_size = 0;
    ring_bytes_since_sync = 0;
    ring_pending_explicit_rotate = false;
    invalidate_file_cache();

    int rc = sd_mount(false); /* recovery: never format — may hold un-synced audio */
    if (rc != 0) {
        LOG_ERR("[SD_WORK] SD remount failed: %d — staying blocked", rc);
        return rc;
    }

    LOG_INF("[SD_WORK] SD remounted — resuming writes in a fresh segment");
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

    /* Publish which trigger fired, for the empty-bin attribution in
     * ring_create_segment(). Only this function can tell them apart, and only a
     * `true` return leads to a rotation, so setting it here cannot mislabel one. */
    if (file_age_ms >= FILE_ROTATION_INTERVAL_MS) {
        ring_rotate_reason = ROTATE_REASON_AGE;
        return true;
    }

    /* On BLE connect: rotate early if file is old enough so the app can
     * immediately download the completed recording without waiting up to
     * FILE_ROTATION_INTERVAL_MS for the normal rotation timer. */
    if (atomic_cas(&pending_rotate_on_ble_connect, 1, 0)) {
        if (file_age_ms >= BLE_CONNECT_MIN_ROTATE_AGE_MS) {
            LOG_INF("[SD_WORK] Rotating file on BLE connect (age %lld ms)", file_age_ms);
            ring_rotate_reason = ROTATE_REASON_BLE_CONNECT;
            return true;
        }
    }

    return false;
}

/* ------------------------------------------------------------------ */
/* File list cache                                                     */
/* ------------------------------------------------------------------ */

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

/* Build the file-list cache from the ring's CLOSED segments (oldest first — the
 * ring's segment table is in append order, so no sort is needed). The open
 * segment is excluded by sd_ring_segment_count(): the app never syncs the
 * recording still being written. */
static int refresh_file_cache(void)
{
    if (!is_mounted) {
        return -ENODEV;
    }

    if (is_storage_sync_active() && file_cache_valid) {
        return 0; /* keep frozen indices stable during an active sync session */
    }

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
    /* Do NOT clear sd_write_blocked here: listing reads the in-RAM segment table
     * and never touches the write path, so a successful list says nothing about a
     * pending write fault. Let the write path's own timed recovery clear it, or a
     * fault would be masked and retried too early. */

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
/* SD worker thread                                                    */
/* ------------------------------------------------------------------ */

void sd_worker_thread(void)
{
    sd_req_t req;
    int res;

    /* ---- Mount ---- */
    res = sd_mount(true); /* boot mount: may format a card that has no ring */
    if (res != 0) {
        LOG_ERR("[SD_WORK] mount failed: %d", res);
        sd_write_blocked = true;
        return;
    }

    /* sd_mount() brought the ring up; the first audio write lazily opens the
     * first segment. There is no boot-time filesystem work to do — mark the SD
     * ready so BLE bring-up / boot warming proceed. */

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
                int sr = sd_ring_sync();
                sd_set_io_low_power(true);
                if (sr < 0) {
                    atomic_set(&pending_flush_on_ble_connect, 1);
                } else {
                    ring_bytes_since_sync = 0;
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
         * On timeout, commit the cursor if a sync is due. */
        k_timeout_t write_wait = atomic_get(&ble_connected) ? K_MSEC(50) : K_MSEC(500);
        if (k_msgq_get(&sd_msgq, &req, write_wait) == 0) {
            reads_since_write = 0;
            goto handle_req;
        }

        /* On the write-wait timeout, commit the cursor for audio appended since the
         * last sync — but rate-gated to SD_FSYNC_INTERVAL_MS, NOT on every timeout.
         * When BLE is connected (the app is connected whenever it is open) write_wait
         * is 50 ms, shorter than the ~86 ms audio-block spacing, so this branch fires
         * in the gap after nearly every block; an ungated commit meant a full
         * partial-sector + CTRL_SYNC + cursor write ~12x/s during active connected
         * audio. The threshold (RING_SYNC_BYTES) and any critical marker still force
         * earlier commits, so a crash in the sub-interval window loses at most the
         * same bytes the byte cap already tolerates.
         *
         * Commit when the periodic gate elapses OR a prior commit failed and its
         * 2 s soft-recovery has passed: the SD_FSYNC_INTERVAL_MS gate throttles
         * ROUTINE periodic commits, but must NOT delay recovering undurable data —
         * notably a failed session-end marker after audio has stopped, when no
         * further write arrives to retry it via the write path. The retry honors
         * the same 2 s backoff the write path uses so a persistently-failing card
         * isn't hammered every timeout tick. */
        {
            bool ring_sync_due = (k_uptime_get() - last_file_sync_uptime_ms) >= SD_FSYNC_INTERVAL_MS;
            bool ring_retry_due = sd_write_blocked &&
                                  (k_uptime_get() - last_write_error_uptime_ms) > 2000;
            if (ring_bytes_since_sync > 0 && (ring_sync_due || ring_retry_due)) {
                sd_set_io_low_power(false);
                if (sd_ring_sync() == 0) {
                    ring_bytes_since_sync = 0;
                    last_file_sync_uptime_ms = k_uptime_get();
                    sd_write_blocked = false; /* recovered — unblock the write path */
                    sd_recovery_cycles = 0;   /* card is healthy; re-arm the escalation */
                } else {
                    /* Still failing: keep ring_bytes_since_sync pending and stay
                     * blocked so ring_retry_due fires again after the 2 s backoff. */
                    last_write_error_uptime_ms = k_uptime_get();
                    sd_write_blocked = true;
                }
                sd_set_io_low_power(true);
            }
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
            process_write_data_req(&req);
            reads_since_write = 0;
            /* Drain up to 16 additional write messages in one pass to improve SD
             * throughput by batching more work per wake. The first WRITE_FAIR_MIN
             * drain unconditionally so a steady read stream can't starve audio;
             * beyond that, yield to pending reads to keep sync responsive. */
            for (int _d = 0; _d < 16; _d++) {
                if (_d >= WRITE_FAIR_MIN && k_msgq_num_used_get(&sd_prio_msgq) > 0)
                    break;
                sd_req_t _next = {0};
                if (k_msgq_get(&sd_msgq, &_next, K_NO_WAIT) != 0)
                    break;
                if (_next.type == REQ_WRITE_DATA)
                    process_write_data_req(&_next);
            }
            /* The bus is woken lazily by sd_ring's io_wake hook, on the first disk op
             * of this burst — and most bursts never have one, because an append that
             * fits in the stage is a memcpy. Suspend unconditionally here:
             * sd_set_io_low_power() no-ops when the bus was never resumed, so this
             * costs one atomic CAS on the (common) memcpy-only burst.
             *
             * Do NOT reinstate an eager wake at the top of this case. It ran ~11.6x
             * per second of audio (one block per loop pass, since blocks arrive every
             * ~86 ms and write_wait is 50 ms while connected) against ~1.2 real
             * flushes, and a pm_device RESUME/SUSPEND pair re-inits the SD card —
             * which is what made the ring's idle current worse than the filesystem's
             * before the lazy hook landed. */
            sd_set_io_low_power(true);
            break;
        }

        /* ---- Read audio data ---- */
        case REQ_READ_DATA:
            ring_handle_read_req(&req);
            break;

        /* ---- Clear all recordings ---- */
        case REQ_CLEAR_AUDIO_DIR: {
            /* Reformat the ring (wipes all segments) and open a fresh one. */
            int cr = sd_ring_format(ring_total_sectors);
            k_mutex_lock(&current_filename_lock, K_FOREVER);
            current_filename[0] = '\0';
            k_mutex_unlock(&current_filename_lock);
            current_file_size = 0;
            ring_bytes_since_sync = 0;
            invalidate_file_cache();
            if (cr == 0) {
                /* current_filename was just cleared above, so this closes nothing and
                 * cannot count as an empty bin — attributed for consistency only. */
                ring_rotate_reason = ROTATE_REASON_CLEAR;
                cr = ring_create_segment();
            }
            if (req.u.clear_dir.resp) {
                req.u.clear_dir.resp->res = cr;
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
            /* Head must be durable before ring_create_segment -> begin_segment
             * publishes the closing segment's length. If the sync fails, don't
             * rotate: report the error and let the caller/next write retry, rather
             * than committing an over-claimed close. */
            res = sd_ring_sync();
            if (res == 0) {
                ring_bytes_since_sync = 0;
                ring_rotate_reason = req.u.create_file.reason;
                res = ring_create_segment();
            } else {
                /* Explicit rotation could not be made durable now — mark it
                 * pending so the write path completes it BEFORE accepting more
                 * audio; otherwise this requested boundary is lost and the next
                 * recording's audio lands in the current segment. Carry the reason
                 * with it: the deferred rotation is still this caller's boundary,
                 * and a priority stop completed later is exactly the case whose
                 * attribution matters most. */
                ring_pending_explicit_rotate = true;
                ring_pending_explicit_rotate_reason = req.u.create_file.reason;
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



        /* ---- Flush (commit the ring cursor) ---- */
        case REQ_FLUSH_FILE: {
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

        /* ---- Unmount (must run on worker thread) ---- */
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

        /* ---- Delete file (ack the segment) ---- */
        case REQ_DELETE_FILE: {
            /* Deletion = ack the segment; the ring advances its tail past leading
             * acked segments to reclaim space. */
            AudioFileMeta_t m;
            parse_filename_to_meta(req.u.delete_file.filename, 0, &m);
            int idx = ring_find_segment_index(m.timestamp, m.uptime_offset);
            int rc = (idx >= 0) ? sd_ring_ack_segment(idx) : 0; /* absent = already gone */
            if (rc != 0) {
                /* The ack STANDS in RAM (see sd_ring_ack_segment's contract) but its
                 * table write failed, so the segment has already left the file list
                 * while the on-disk table still lists it un-acked. That is the one
                 * window where a reboot resurrects it and the phone downloads and
                 * decodes the recording a second time.
                 *
                 * Retry the durability HERE, synchronously, because this is the last
                 * moment it can be retried on demand: the segment is now absent from
                 * the cache refresh_file_cache() builds (it mirrors the same closed +
                 * un-acked list), so storage.c resolves any later CMD_DELETE_FILE for
                 * it to FILE_NOT_FOUND and never queues another REQ_DELETE_FILE. A
                 * retry keyed on the app re-sending the delete cannot reach this code
                 * at all — which is exactly what an earlier version of this fix got
                 * wrong. sd_ring_sync() rewrites the table while segtab_dirty.
                 *
                 * If it still fails, segtab_dirty keeps the next ordinary sync (a
                 * rotation, a flush) retrying it; that is the residual bound, and it
                 * is why the failure is logged rather than swallowed. */
                int sync_rc = sd_ring_sync();
                if (sync_rc == 0) {
                    LOG_WRN("[SD_WORK] delete: segment table was not durable, retried OK");
                    rc = 0;
                } else {
                    LOG_ERR("[SD_WORK] delete: segment acked but table NOT durable (ack=%d sync=%d) — "
                            "a reboot before the next sync will resurrect it",
                            rc, sync_rc);
                }
            }
            invalidate_file_cache();
            if (req.u.delete_file.resp) {
                req.u.delete_file.resp->res = (rc < 0) ? rc : 0;
                k_sem_give(&req.u.delete_file.resp->sem);
            }
            break;
        }

        /* ---- Pause IO ---- */
        case REQ_PAUSE_IO: {
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
            /* Rotate to a fresh UTC-keyed segment so subsequent audio is organized.
             * Existing pre-sync segments keep their uptime key — there is no
             * directory to rename, and the app anchors real timing to each segment's
             * inline 0xFFFFFFFB header, so they simply show as "unorganized". */
            if (current_filename[0] == '\0' || current_file_needs_rename) {
                /* If an open (TMP) segment will be closed by this rotation, make its
                 * head durable first: ring_create_segment -> begin_segment publishes
                 * the closing length from head_abs, so an un-synced head could expose
                 * uncommitted bytes past the recovered cursor after a power cut. On
                 * sync failure, defer — a later rotation retries with a durable head. */
                if (current_filename[0] != '\0') {
                    if (sd_ring_sync() != 0) {
                        atomic_set(&timesync_rename_pending, 0);
                        break;
                    }
                    ring_bytes_since_sync = 0;
                }
                ring_rotate_reason = ROTATE_REASON_TIME_SYNC;
                ring_create_segment();
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
 * error count. */
uint32_t sd_get_ring_max_io_ms(void)
{
    return sd_ring_max_io_ms();
}

uint32_t sd_get_ring_io_errors(void)
{
    return sd_ring_io_errors();
}

uint8_t sd_get_active_backend(void)
{
    /* Kept on the wire (0x0062 status_flags) after the LittleFS backend was
     * removed in oo-2.9.0: the app's Diagnostics panel reads it to name the
     * backend, and an older app still expects the field. */
    return STORAGE_BACKEND_RING;
}

/* ================================================================== */
/* Ring segment plumbing                                               */
/* All functions run on the sd_worker thread.                          */
/* ================================================================== */

/* Open a new ring segment and write its inline 0xFFFFFFFB RecordingHeader.
 * Drives the shared current_filename / current_file_size / rotation-timer state
 * so should_rotate_file() and the marker plumbing work off one set of fields. */
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

    /* Empty-bin diagnostic: previous segment closed holding only its header.
     *
     * Attribute it, because the count alone never says which rotation left the bin
     * empty and they are not equally interesting: "you Force Synced twice over a quiet
     * lunch" and "a recording boundary landed on a mic that was delivering nothing"
     * both land here. The reason is the only thing that separates them, and it costs
     * a byte of an event record that was already being written. */
    if (current_filename[0] != '\0' && current_file_size <= sizeof(RecordingHeader_v1_t)) {
        atomic_inc(&empty_bin_rotations);
        diag_log_event(DIAG_EMPTY_BIN_ROTATION, STORAGE_BACKEND_RING, ring_rotate_reason, current_file_size);
    }
    /* Consume the reason: a site that fails to set one records an empty bin as
     * unattributed rather than inheriting the previous rotation's cause. */
    ring_rotate_reason = ROTATE_REASON_UNKNOWN;

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

    /* Synthetic filename: segments are presented to BLE as files, so the list /
     * read / delete / marker plumbing all key on this identity (<ts>_<sid>). The
     * ".txt" suffix and TMP_ prefix are the storage protocol's, not a filesystem's. */
    k_mutex_lock(&current_filename_lock, K_FOREVER);
    if (rtc_valid) {
        snprintf(current_filename, sizeof(current_filename), "%08X_%08X.txt", seg_ts, sid);
    } else {
        snprintf(current_filename, sizeof(current_filename), "TMP_%08X_%08X.txt", seg_ts, sid);
    }
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
    current_file_created_uptime_ms = k_uptime_get();
    last_file_sync_uptime_ms = k_uptime_get();
    sd_write_blocked = false;
    sd_recovery_cycles = 0; /* header reached the card — re-arm the escalation */
    invalidate_file_cache_deferrable();
    return 0;
}

/* The write path: 2 s soft-recovery + pause-gate marker rescue + lazy segment
 * open + rotation + append + bounded cursor sync. */
static void process_write_data_req(const sd_req_t *req)
{
    if (sd_write_blocked) {
        if ((k_uptime_get() - last_write_error_uptime_ms) > 2000) {
            if (++sd_recovery_cycles >= SD_RECOVERY_REMOUNT_THRESHOLD) {
                /* Soft retries aren't clearing the fault — escalate to a power-cycle.
                 * Reset the counter either way so a failed remount costs another full
                 * threshold of soft retries before we power-cycle again, rather than
                 * cycling the card every 2 s on a permanently dead one. */
                sd_recovery_cycles = 0;
                if (sd_recover_remount() == 0) {
                    sd_write_blocked = false;
                } else {
                    last_write_error_uptime_ms = k_uptime_get();
                }
            } else {
                sd_write_blocked = false;
            }
        }

        if (sd_write_blocked) {
            /* Backing off after a write/sync failure. Keep the audio instead of
             * discarding it: sd_ring_append() is a pure memcpy while the stage has
             * room, so a fault that clears within ~8 s (RING_STAGE_BYTES at the
             * ~5 KB/s ingest) costs nothing — the same protection the filesystem
             * backend got from buffering into its 44 KB batch buffer while blocked.
             *
             * Gated on stage headroom, which BOUNDS the disk I/O here rather than
             * removing it: a block landing on exactly the free space fills the stage
             * and trips sd_ring_append()'s trailing flush, so this path can issue at
             * most one flush per stage-fill (~8 s of audio) — never the per-block
             * (~11.6x/s) flush-to-make-room the backoff exists to stop. Refusing
             * that block instead, to guarantee zero I/O, would throw away the very
             * audio this path exists to keep, so the flush is the better trade.
             * Requires an open segment — bytes appended with none would belong to
             * no segment and never be listed.
             *
             * Anything we genuinely cannot keep is counted. Before this, every block
             * arriving inside a backoff window was dropped silently, so a card
             * fault under-reported its own audio loss in the 0x0062 counters. */
            if (current_filename[0] != '\0' &&
                req->u.write.len <= sd_ring_stage_headroom() &&
                sd_ring_append(req->u.write.buf, req->u.write.len) == 0) {
                current_file_size += req->u.write.len;
                ring_bytes_since_sync += req->u.write.len;
            } else {
                atomic_inc(&stat_dropped_frames);
            }
            return;
        }
    }

    /* Pause gate: a pause is a power optimization, not a correctness gate. Keep
     * marker-bearing blocks (session-end / priority-start / tap / mute / resume)
     * through a pause; drop only plain audio. */
    if (!sd_draining && atomic_get(&sd_write_paused)) {
        uint32_t pause_marker = block_scan_markers(req->u.write.buf, req->u.write.len, true);
        if (pause_marker != 0) {
            atomic_inc(&marker_pause_gate_saves);
            /* arg0 = which marker was rescued (low16); arg1 = block length. */
            diag_log_event(DIAG_MARKER_PAUSE_GATE_SAVE, STORAGE_BACKEND_RING, (uint16_t) (pause_marker & 0xFFFF),
                           req->u.write.len);
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
        ring_rotate_reason = ring_pending_explicit_rotate_reason;
        if (ring_create_segment() < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto ring_done;
        }
        ring_pending_explicit_rotate = false;
        ring_pending_explicit_rotate_reason = ROTATE_REASON_UNKNOWN;
    }

    /* Do NOT wake the bus here, and do NOT power-cycle it per block. sd_ring's
     * io_wake hook resumes it on the first real disk access, so a block that only
     * lands in the stage (all but ~1 in 93) never touches SPI at all; the worker
     * suspends once after the whole burst. A per-block pm_device RESUME/SUSPEND
     * re-inits the SD card (tens of ms) ~12x/s, which pegged sd_msgq at 120/120 and
     * dropped audio instead of draining it. */
    if (current_filename[0] == '\0') {
        /* Nothing open, so this rotation closes nothing and can never count as an
         * empty bin; the reason is set only to keep the attribution honest. */
        ring_rotate_reason = ROTATE_REASON_MOUNT;
        if (ring_create_segment() < 0) {
            last_write_error_uptime_ms = k_uptime_get();
            sd_write_blocked = true;
            goto ring_done;
        }
        atomic_clear(&current_file_deleted);
    }

    /* should_rotate_file() sets ring_rotate_reason itself — it is the only site that
     * knows which of its two triggers (age vs BLE-connect) fired. */
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
            int cr = create_new_audio_file(ROTATE_REASON_ACTIVE_DELETED);
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

    /* Discard data while SD boot init is still running (card power-on + ring
     * mount).  Rate-limited logging
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

int create_new_audio_file(uint8_t reason)
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
    req.u.create_file.reason = reason;

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

