/*
 * sd_ring.c — raw circular-log audio backend (see sd_ring.h for the design).
 *
 * All functions run on the single sd_worker thread and are NOT thread-safe.
 */
#include "lib/core/sd_ring.h"

#include <errno.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/sys/crc.h>

LOG_MODULE_REGISTER(sd_ring, CONFIG_LOG_DEFAULT_LEVEL);

#define RING_DISK CONFIG_SDMMC_VOLUME_NAME

/* The segment table must be exactly its sector span, and the single-sector
 * records must fit in a sector — the on-flash layout depends on it. */
BUILD_ASSERT(sizeof(ring_segment_table_t) == RING_SEGTAB_SECTORS * RING_SECTOR_SIZE,
             "ring_segment_table_t must be an exact multiple of the sector size");
BUILD_ASSERT(sizeof(ring_cursor_t) <= RING_SECTOR_SIZE, "cursor record exceeds one sector");
BUILD_ASSERT(sizeof(ring_format_header_t) <= RING_SECTOR_SIZE, "format header exceeds one sector");

/* ------------------------------------------------------------------ */
/* State (sd_worker-thread-local)                                      */
/* ------------------------------------------------------------------ */
static bool     ring_mounted;
static uint64_t ring_bytes;          /* audio-ring capacity */
static uint32_t data_start_sector;   /* first audio sector (RING_DATA_START_SECTOR) */
static uint32_t ring_end_sector;     /* one past the last audio sector */

static uint64_t head_abs;            /* total bytes appended (monotonic) */
static uint64_t tail_abs;            /* bytes reclaimed — start of live data */

static uint32_t cursor_seq = 1;      /* next cursor seq to write */
static uint32_t cursor_slot;         /* next cursor-log slot [0, RING_CURLOG_SLOTS) */

/* In-RAM working copy of the segment table (~4 KB), doubles as the write source. */
static ring_segment_table_t segtab __aligned(4);
static uint32_t segtab_seq = 1;      /* next table seq */
static uint8_t  segtab_next_ab;      /* 0 -> write copy A next, 1 -> copy B */
static bool     segtab_dirty;        /* wrap dropped entries; flush on next sync */

/* Append stage — sizing and ownership are documented in sd_ring.h. The buffer is
 * supplied by sd_card.c via sd_ring_init() (it was shared RAM with the LittleFS batch
 * buffer), so this is a pointer, not an array: never sizeof() it. */
static uint8_t *stage;
static uint32_t stage_fill;          /* unwritten staged bytes, [0, RING_STAGE_BYTES) */
/* True when bytes have been appended that are not yet on the NAND. NOT the same
 * as stage_fill != 0: sd_ring_sync() writes the padded partial tail sector to disk
 * but deliberately KEEPS it staged so appends keep filling it, so a non-empty stage
 * can be fully durable. Set on append, cleared only by a fully successful sync —
 * conservative in the one case a flush happens to empty the stage exactly. Read by
 * sd_ring_begin_segment() to skip a redundant sync when the caller already did one. */
static bool stage_dirty;

/* Host hooks (see sd_ring_host_t). Both optional. */
static void (*host_io_wake)(void);
static bool (*host_io_busy)(void);

/* Called before every disk access so the host can keep the SPI bus suspended
 * until the ring actually reaches the NAND. Idempotent by contract. */
static inline void io_wake(void)
{
    if (host_io_wake) {
        host_io_wake();
    }
}

/* True when a higher-priority request is waiting and a multi-chunk flush should
 * hand the worker back rather than finish. */
static inline bool io_busy(void)
{
    return host_io_busy && host_io_busy();
}

/* ------------------------------------------------------------------ */
/* Diagnostics: pinpoint a worker stall to a single SD primitive.       */
/*   ring_max_io_ms — packed (tag<<24)|ms of the slowest disk op since   */
/*     boot; tag 1=write_sectors, 2=read_sectors, 3=CTRL_SYNC. A ~queue- */
/*     full drop burst with, say, tag=3 & ms=20000 says the FTL flush    */
/*     stalled; tag=1 says a page-program/erase; small ms says the stall */
/*     was NOT one long op (look at ring_io_errors instead).             */
/*   ring_io_errors — write_sectors / sync_disk failures (EIO). Nonzero  */
/*     with a small max-io means the NAND was rejecting writes, not slow. */
/* Worker-thread-only writers; a torn 32-bit read from the BLE thread is */
/* a harmless stale snapshot, so no atomics needed on Cortex-M.          */
static uint32_t ring_max_io_ms;
static uint32_t ring_io_errors;

static inline void note_io(uint32_t tag, int64_t t0, int rc)
{
    uint32_t dt = (uint32_t) (k_uptime_get() - t0);
    if (dt > (ring_max_io_ms & 0x00FFFFFFu)) {
        ring_max_io_ms = (tag << 24) | (dt & 0x00FFFFFFu);
    }
    if (rc != 0) {
        ring_io_errors++;
    }
}

uint32_t sd_ring_max_io_ms(void)  { return ring_max_io_ms; }
uint32_t sd_ring_io_errors(void)  { return ring_io_errors; }

/* ------------------------------------------------------------------ */
/* Low-level disk helpers                                              */
/* ------------------------------------------------------------------ */
static inline int read_sectors(uint32_t sector, void *buf, uint32_t n)
{
    io_wake();
    int64_t t0 = k_uptime_get();
    int rc = disk_access_read(RING_DISK, buf, sector, n) == 0 ? 0 : -EIO;
    note_io(2, t0, 0); /* reads don't count toward io_errors (BLE-read path, non-fatal) */
    return rc;
}

static inline int write_sectors(uint32_t sector, const void *buf, uint32_t n)
{
    io_wake();
    int64_t t0 = k_uptime_get();
    int rc = disk_access_write(RING_DISK, buf, sector, n) == 0 ? 0 : -EIO;
    note_io(1, t0, rc);
    return rc;
}

static inline int sync_disk(void)
{
    io_wake();
    int64_t t0 = k_uptime_get();
    int raw = disk_access_ioctl(RING_DISK, DISK_IOCTL_CTRL_SYNC, NULL);
    int rc = (raw == 0 || raw == -ENOTSUP || raw == -ENOSYS) ? 0 : -EIO;
    note_io(3, t0, rc);
    return rc;
}

/* Map an absolute byte offset to its physical ring sector. ring_bytes is a
 * multiple of the sector size and appends never straddle the wrap mid-sector,
 * so this is exact. */
static inline uint32_t abs_to_sector(uint64_t abs)
{
    uint64_t off = abs % ring_bytes;
    return data_start_sector + (uint32_t) (off / RING_SECTOR_SIZE);
}

/* Write `nsec` sectors of `buf` starting at the sector for the sector-aligned
 * absolute offset `start_abs`, splitting the run at the physical wrap boundary
 * (a batch can straddle the ring end once per full traversal, ~every 26 h). */
static int write_run(uint64_t start_abs, const uint8_t *buf, uint32_t nsec)
{
    if (nsec == 0) {
        return 0;
    }
    uint32_t first = abs_to_sector(start_abs);
    uint32_t until_wrap = ring_end_sector - first;
    if (nsec <= until_wrap) {
        return write_sectors(first, buf, nsec);
    }
    if (write_sectors(first, buf, until_wrap)) {
        return -EIO;
    }
    return write_sectors(data_start_sector,
                         buf + (size_t) until_wrap * RING_SECTOR_SIZE,
                         nsec - until_wrap);
}

/* Flush every COMPLETE sector currently staged, keeping the trailing sub-sector
 * remainder in the stage. Advances the on-disk written head (head_abs -
 * stage_fill) by whole sectors, preserving its alignment.
 *
 * The run is issued as RING_FLUSH_CHUNK_SECTORS-sized writes rather than one
 * 40 KB op: same bytes, same number of NAND pages, but the worker is never
 * inside a single long disk op, so a BLE read waiting on sd_prio_msgq isn't held
 * off for the length of the whole flush. With @p allow_yield, the flush stops at
 * a chunk boundary as soon as one is waiting and leaves the rest staged — the
 * ring's ordinary not-yet-durable state, which the next flush or sync completes.
 * Always makes progress when it returns 0: at least one chunk is written before
 * the first yield check, so callers flushing to free room always get a chunk.
 *
 * Callers that must leave nothing staged (sd_ring_sync, before the cursor
 * commits) pass allow_yield = false. */
static int flush_full_sectors_ex(bool allow_yield)
{
    uint32_t nfull = stage_fill / RING_SECTOR_SIZE;
    if (nfull == 0) {
        return 0;
    }

    uint64_t start_abs = head_abs - stage_fill; /* sector-aligned written head */
    uint32_t done = 0;
    int rc = 0;

    while (done < nfull) {
        uint32_t n = MIN(RING_FLUSH_CHUNK_SECTORS, nfull - done);
        rc = write_run(start_abs + (uint64_t) done * RING_SECTOR_SIZE,
                       stage + (size_t) done * RING_SECTOR_SIZE, n);
        if (rc) {
            break;
        }
        done += n;
        if (allow_yield && done < nfull && io_busy()) {
            break;
        }
    }

    /* Commit whatever landed, even on a later chunk's error: those sectors ARE on
     * disk, and leaving them staged would re-write them and (worse) hold the
     * written head behind bytes that are already durable. */
    if (done > 0) {
        uint32_t flushed = done * RING_SECTOR_SIZE;
        stage_fill -= flushed;
        memmove(stage, stage + flushed, stage_fill);
    }
    return rc;
}

static inline int flush_full_sectors(void)
{
    return flush_full_sectors_ex(true);
}

/* ------------------------------------------------------------------ */
/* Cursor log                                                          */
/* ------------------------------------------------------------------ */
static int write_cursor(void)
{
    uint8_t buf[RING_SECTOR_SIZE] __aligned(4);
    memset(buf, 0, sizeof(buf));
    ring_cursor_t *c = (ring_cursor_t *) buf;
    c->magic = RING_CUR_MAGIC;
    c->seq = cursor_seq;
    c->head_abs = head_abs;
    c->tail_abs = tail_abs;
    c->crc32 = crc32_ieee(buf, offsetof(ring_cursor_t, crc32));

    int rc = write_sectors(RING_CURLOG_START + cursor_slot, buf, 1);
    if (rc) {
        LOG_ERR("cursor write failed at slot %u: %d", cursor_slot, rc);
        return rc;
    }
    cursor_slot = (cursor_slot + 1) % RING_CURLOG_SLOTS;
    cursor_seq++;
    return 0;
}

/* Replay the cursor log: pick the highest-seq record with a valid CRC. */
static int load_cursor(void)
{
    uint8_t buf[RING_SECTOR_SIZE] __aligned(4);
    bool found = false;
    uint32_t best_seq = 0, best_slot = 0;
    uint64_t best_head = 0, best_tail = 0;

    for (uint32_t i = 0; i < RING_CURLOG_SLOTS; i++) {
        if (read_sectors(RING_CURLOG_START + i, buf, 1)) {
            continue;
        }
        ring_cursor_t *c = (ring_cursor_t *) buf;
        if (c->magic != RING_CUR_MAGIC) {
            continue;
        }
        if (crc32_ieee(buf, offsetof(ring_cursor_t, crc32)) != c->crc32) {
            continue;
        }
        if (!found || c->seq > best_seq) {
            found = true;
            best_seq = c->seq;
            best_slot = i;
            best_head = c->head_abs;
            best_tail = c->tail_abs;
        }
    }

    if (!found) {
        return -ENOENT;
    }
    head_abs = best_head;
    tail_abs = best_tail;
    cursor_seq = best_seq + 1;
    cursor_slot = (best_slot + 1) % RING_CURLOG_SLOTS;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Segment table (double-buffered A/B)                                 */
/* ------------------------------------------------------------------ */
static int write_segtable(void)
{
    segtab.magic = RING_SEG_MAGIC;
    segtab.seq = segtab_seq;
    segtab.crc32 = crc32_ieee((const uint8_t *) &segtab, offsetof(ring_segment_table_t, crc32));

    uint32_t start = (segtab_next_ab == 0) ? RING_SEGTAB_A_START : RING_SEGTAB_B_START;
    int rc = write_sectors(start, &segtab, RING_SEGTAB_SECTORS);
    if (rc) {
        LOG_ERR("segtable write failed (copy %c): %d", segtab_next_ab ? 'B' : 'A', rc);
        return rc;
    }
    segtab_next_ab ^= 1;
    segtab_seq++;
    segtab_dirty = false;
    return 0;
}

/* Load the newer valid segment-table copy into `segtab`; empty table if neither
 * is valid. Uses `segtab` itself as the read buffer to avoid a second 4 KB
 * buffer, re-reading A when A wins (one extra read at mount — negligible). */
static void load_segtable(void)
{
    bool valid_a = false, valid_b = false;
    uint32_t seq_a = 0, seq_b = 0;

    if (read_sectors(RING_SEGTAB_A_START, &segtab, RING_SEGTAB_SECTORS) == 0 &&
        segtab.magic == RING_SEG_MAGIC &&
        crc32_ieee((const uint8_t *) &segtab, offsetof(ring_segment_table_t, crc32)) == segtab.crc32) {
        valid_a = true;
        seq_a = segtab.seq;
    }

    if (read_sectors(RING_SEGTAB_B_START, &segtab, RING_SEGTAB_SECTORS) == 0 &&
        segtab.magic == RING_SEG_MAGIC &&
        crc32_ieee((const uint8_t *) &segtab, offsetof(ring_segment_table_t, crc32)) == segtab.crc32) {
        valid_b = true;
        seq_b = segtab.seq;
    }

    if (valid_b && (!valid_a || seq_b >= seq_a)) {
        /* `segtab` already holds copy B. */
        segtab_next_ab = 0; /* A is now the older copy — overwrite it next */
        segtab_seq = seq_b + 1;
    } else if (valid_a) {
        (void) read_sectors(RING_SEGTAB_A_START, &segtab, RING_SEGTAB_SECTORS);
        segtab_next_ab = 1;
        segtab_seq = seq_a + 1;
    } else {
        memset(&segtab, 0, sizeof(segtab));
        segtab.count = 0;
        segtab_next_ab = 0;
        segtab_seq = 1;
    }
    if (segtab.count > RING_MAX_SEGMENTS) {
        segtab.count = RING_MAX_SEGMENTS; /* defend against a corrupt count that passed CRC */
    }
}

/* Map a caller-facing closed-segment index (0-based, oldest first) to an index
 * into segtab.entries[]. Closed = not open AND not already acked (a non-oldest
 * acked segment lingers in the table until tail reclamation removes it — excluding
 * it here keeps it out of the BLE file list so it can't be re-downloaded/deleted).
 * Returns -1 if out of range. */
static int closed_global_index(int closed_index)
{
    if (closed_index < 0) {
        return -1;
    }
    int seen = 0;
    for (uint32_t i = 0; i < segtab.count; i++) {
        if (segtab.entries[i].flags & (RING_SEG_FLAG_OPEN | RING_SEG_FLAG_ACKED)) {
            continue;
        }
        if (seen == closed_index) {
            return (int) i;
        }
        seen++;
    }
    return -1;
}

/* Drop leading segments whose start has been reclaimed (start_abs < tail_abs).
 * Called after tail advances (ack or keep-newest wrap). */
static void drop_reclaimed_segments(void)
{
    while (segtab.count > 0 && segtab.entries[0].start_abs < tail_abs) {
        memmove(&segtab.entries[0], &segtab.entries[1],
                (segtab.count - 1) * sizeof(ring_segment_t));
        segtab.count--;
    }
}

/* Keep-newest: force the tail forward so `need` more bytes fit, dropping the
 * oldest data. Only fires when the card is full of un-reclaimed audio (the
 * phone hasn't drained) — in normal use it never runs. */
static void enforce_keep_newest(size_t need)
{
    if ((head_abs - tail_abs) + need <= ring_bytes) {
        return;
    }
    uint64_t new_tail = (head_abs + need) - ring_bytes;
    if (new_tail > tail_abs) {
        tail_abs = new_tail;
        drop_reclaimed_segments();
        segtab_dirty = true; /* persist the pruned table on the next sync */
        LOG_WRN("ring full — keep-newest advanced tail to %llu", (unsigned long long) tail_abs);
    }
}

/* ------------------------------------------------------------------ */
/* Mount / format                                                      */
/* ------------------------------------------------------------------ */
static void set_geometry(uint32_t total_sectors, uint32_t data_start, uint64_t rbytes)
{
    data_start_sector = data_start;
    ring_bytes = rbytes;
    ring_end_sector = data_start_sector + (uint32_t) (ring_bytes / RING_SECTOR_SIZE);
    (void) total_sectors;
}

int sd_ring_init(const sd_ring_host_t *host)
{
    if (!host || !host->stage || host->stage_bytes < RING_STAGE_BYTES) {
        LOG_ERR("ring init: stage missing or < %u bytes", (unsigned) RING_STAGE_BYTES);
        return -EINVAL;
    }
    stage = host->stage;
    stage_fill = 0;
    stage_dirty = false;
    host_io_wake = host->io_wake;
    host_io_busy = host->io_busy;
    return 0;
}

int sd_ring_mount(uint32_t total_sectors)
{
    if (!stage) {
        return -EINVAL; /* sd_ring_init() not called */
    }
    if (total_sectors <= RING_DATA_START_SECTOR + 16) {
        return -EINVAL;
    }
    /* Drop the mounted flag up front, as sd_ring_format() does, so EVERY failure
     * path below leaves it false. This matters on a RE-mount (the write path's
     * recovery remount): leaving a stale true would let sd_ring_stage_headroom()
     * report room and sd_ring_append() keep accepting audio into a stage whose
     * card is powered off and unmounted — silently buffering bytes that can never
     * be written, and counting them as kept rather than dropped. */
    ring_mounted = false;

    uint8_t buf[RING_SECTOR_SIZE] __aligned(4);
    if (read_sectors(RING_HDR_SECTOR, buf, 1)) {
        return -EIO;
    }
    ring_format_header_t *h = (ring_format_header_t *) buf;
    if (h->magic != RING_FMT_MAGIC ||
        crc32_ieee(buf, offsetof(ring_format_header_t, crc32)) != h->crc32 ||
        h->version != RING_FORMAT_VERSION) {
        return -ENOENT; /* no (or foreign) ring here — caller should format */
    }

    uint32_t data_start = h->data_start_sector;
    uint64_t rbytes = h->ring_bytes;
    if (data_start >= total_sectors) {
        return -ENOENT;
    }
    uint64_t avail = (uint64_t) (total_sectors - data_start) * RING_SECTOR_SIZE;
    if (rbytes == 0 || rbytes > avail) {
        rbytes = avail; /* card shrank/grew or stale header — clamp to what's really there */
    }
    set_geometry(total_sectors, data_start, rbytes);

    if (load_cursor() != 0) {
        LOG_WRN("ring header present but no valid cursor — treating as unformatted");
        return -ENOENT;
    }
    load_segtable();

    /* Restore the partial head sector so appends continue into it. Read back from
     * disk, so the stage starts clean: nothing here is un-written. */
    stage_fill = (uint32_t) (head_abs % RING_SECTOR_SIZE);
    stage_dirty = false;
    memset(stage, 0, RING_STAGE_BYTES);
    if (stage_fill != 0) {
        uint32_t sec = abs_to_sector(head_abs - stage_fill);
        if (read_sectors(sec, stage, 1) != 0) {
            /* Partial tail sector is unreadable. Do NOT fail the mount — that blocks
             * recording for the whole boot over one bad sector — and do NOT overwrite
             * the bad sector in this traversal. Close/truncate the last segment at the
             * last good sector boundary — so no closed recording claims unreadable
             * bytes and the open one cannot span a gap — then resume recording just
             * PAST the bad sector, leaving it as dead space owned by no segment. Every
             * synced-but-undrained recording is preserved.
             * LIMITATION: the raw log has no bad-block remapping, so a full ring wrap
             * (only reachable if the phone never drains for ~26 h of continuous
             * recording) would eventually re-address this physical sector; a
             * persistently-bad sector then surfaces as an ordinary write drop /
             * sd_write_blocked, not corruption. A genuinely failing card needs
             * replacing — there is no FTL here to route around it. */
            uint64_t bnd = head_abs - stage_fill; /* last good sector boundary */
            LOG_WRN("ring mount: partial tail unreadable — closing at %llu, skipping bad sector",
                    (unsigned long long) bnd);
            bool changed = false;
            while (segtab.count > 0) {
                ring_segment_t *last = &segtab.entries[segtab.count - 1];
                if (last->start_abs >= bnd) {
                    segtab.count--; /* wholly inside the bad region — drop */
                    changed = true;
                    continue;
                }
                uint32_t keep = (uint32_t) (bnd - last->start_abs);
                if ((last->flags & RING_SEG_FLAG_OPEN) || last->length > keep) {
                    last->length = keep; /* close / truncate at the good boundary */
                    last->flags &= ~RING_SEG_FLAG_OPEN;
                    changed = true;
                }
                break; /* earlier segments end before the boundary — untouched */
            }
            head_abs = bnd + RING_SECTOR_SIZE; /* resume past the dead bad sector */
            stage_fill = 0;
            if (changed) {
                /* The reconciled table MUST be durable before the cursor advances to
                 * the skipped head: otherwise a reboot pairs the skipped cursor with
                 * the STALE on-disk table, whose last segment still spans the bad
                 * sector. If the table write/sync fails, leave the cursor at the old
                 * head (reboot re-runs this recovery) and mark the table dirty so the
                 * first normal sync retries it before committing any cursor. */
                if (write_segtable() == 0 && sync_disk() == 0) {
                    (void) write_cursor();
                } else {
                    segtab_dirty = true;
                }
            }
        }
    }

    ring_mounted = true;
    LOG_INF("ring mounted: cap=%llu MB head=%llu tail=%llu segs=%u",
            (unsigned long long) (ring_bytes >> 20), (unsigned long long) head_abs,
            (unsigned long long) tail_abs, segtab.count);
    return 0;
}

int sd_ring_format(uint32_t total_sectors)
{
    if (!stage) {
        return -EINVAL; /* sd_ring_init() not called */
    }
    if (total_sectors <= RING_DATA_START_SECTOR + 16) {
        return -EINVAL;
    }
    ring_mounted = false;

    uint32_t data_start = RING_DATA_START_SECTOR;
    uint64_t rbytes = (uint64_t) (total_sectors - data_start) * RING_SECTOR_SIZE;
    set_geometry(total_sectors, data_start, rbytes);

    /* Zero the whole metadata region so no stale, higher-seq cursor/segtable
     * from a previous format is picked up on the next mount. Audio data sectors
     * are left as-is (overwritten as head advances; reads are bounded by tail). */
    /* Zero one sector at a time from a 512 B buffer, NOT an 8-sector (4 KB) stack
     * frame. format() runs on the sd_worker stack, and that 4 KB buffer was the
     * single largest sd_worker stack consumer — it set the floor on how far
     * SD_WORKER_STACK_SIZE could be trimmed. 256 one-sector writes is fine for a
     * one-time (mount-on-fresh-card / CLEAR_STORAGE) format off the audio path. */
    uint8_t zero[RING_SECTOR_SIZE] __aligned(4);
    memset(zero, 0, sizeof(zero));
    for (uint32_t s = 0; s < RING_DATA_START_SECTOR; s++) {
        if (write_sectors(s, zero, 1)) {
            LOG_ERR("format: zeroing metadata sector %u failed", s);
            return -EIO;
        }
    }

    /* Fresh header. */
    uint8_t buf[RING_SECTOR_SIZE] __aligned(4);
    memset(buf, 0, sizeof(buf));
    ring_format_header_t *h = (ring_format_header_t *) buf;
    h->magic = RING_FMT_MAGIC;
    h->version = RING_FORMAT_VERSION;
    h->sector_size = RING_SECTOR_SIZE;
    h->data_start_sector = data_start;
    h->ring_bytes = rbytes;
    h->crc32 = crc32_ieee(buf, offsetof(ring_format_header_t, crc32));
    if (write_sectors(RING_HDR_SECTOR, buf, 1)) {
        return -EIO;
    }

    /* Fresh cursor + empty segment table. */
    head_abs = 0;
    tail_abs = 0;
    cursor_seq = 1;
    cursor_slot = 0;
    stage_fill = 0;
    stage_dirty = false;
    memset(stage, 0, RING_STAGE_BYTES);

    memset(&segtab, 0, sizeof(segtab));
    segtab.count = 0;
    segtab_seq = 1;
    segtab_next_ab = 0;
    segtab_dirty = false;

    int rc = write_cursor();
    if (rc) {
        return rc;
    }
    rc = write_segtable();
    if (rc) {
        return rc;
    }
    rc = sync_disk();
    if (rc) {
        return rc;
    }

    ring_mounted = true;
    LOG_INF("ring formatted: cap=%llu MB (data sectors %u..%u)",
            (unsigned long long) (ring_bytes >> 20), data_start, ring_end_sector);
    return 0;
}

bool sd_ring_is_mounted(void)
{
    return ring_mounted;
}

/* ------------------------------------------------------------------ */
/* Append / sync                                                       */
/* ------------------------------------------------------------------ */
int sd_ring_append(const uint8_t *data, size_t len)
{
    if (!ring_mounted) {
        return -ENODEV;
    }
    if (len == 0) {
        return 0;
    }

    /* Make room by flushing completed sectors. On a write error the staged bytes
     * stay put (a later sync retries) and head_abs is NOT advanced for bytes we
     * couldn't stage, so the cursor never claims un-written data; we only fail the
     * call — dropping this block — if the stage still can't hold it. (len is one
     * audio/marker block, always << RING_STAGE_BYTES, so a good flush always frees
     * enough room.) */
    if (stage_fill + len > RING_STAGE_BYTES) {
        (void) flush_full_sectors();
        if (stage_fill + len > RING_STAGE_BYTES) {
            return -EIO;
        }
    }

    enforce_keep_newest(len);

    memcpy(stage + stage_fill, data, len);
    stage_fill += (uint32_t) len;
    head_abs += len;
    stage_dirty = true;

    /* Once a full batch has accumulated, flush it (page-aligned, chunked). This is
     * the ONLY routine reason the write path touches the NAND, so the stage size
     * sets both the NAND write cadence and — via the io_wake hook — how often the
     * SPI bus is powered up. Non-fatal on error: the bytes remain staged and become
     * durable on the next successful sync, so head_abs is not rolled back here. */
    if (stage_fill >= RING_STAGE_BYTES) {
        (void) flush_full_sectors();
    }
    return 0;
}

int sd_ring_sync(void)
{
    if (!ring_mounted) {
        return -ENODEV;
    }
    if (stage_fill > 0) {
        /* Persist ALL staged bytes so head_abs is recoverable: the full sectors
         * first (chunked, never yielding — a sync must leave nothing on the wrong
         * side of the cursor it is about to commit), then the partial tail sector
         * (padded — only its valid prefix is ever read, since reads are bounded by
         * segment length). The tail stays staged so appends keep filling it. */
        if (flush_full_sectors_ex(false) != 0) {
            return -EIO;
        }
        if (stage_fill > 0) {
            uint64_t start_abs = head_abs - stage_fill; /* sector-aligned written head */
            if (write_run(start_abs, stage, 1)) {
                return -EIO;
            }
        }
    }
    if (segtab_dirty) {
        /* The pruned table (keep-newest dropped segments + advanced tail) MUST reach
         * NAND before the cursor commits that advanced tail — otherwise a reboot
         * loads the stale table whose leading segments now sit below tail_abs and
         * fail reads. On failure keep segtab_dirty and do NOT advance the durable
         * cursor; the next sync retries the table first. */
        if (write_segtable() != 0) {
            return -EIO;
        }
    }
    int rc = sync_disk();
    if (rc) {
        return rc;
    }
    rc = write_cursor();
    if (rc == 0) {
        /* Everything appended is now on the NAND and claimed by a durable cursor. */
        stage_dirty = false;
    }
    return rc;
}

/* ------------------------------------------------------------------ */
/* Segments                                                            */
/* ------------------------------------------------------------------ */
int sd_ring_begin_segment(uint32_t timestamp, uint32_t session_id)
{
    if (!ring_mounted) {
        return -ENODEV;
    }

    /* Close the currently-open segment (if any). */
    if (segtab.count > 0) {
        ring_segment_t *last = &segtab.entries[segtab.count - 1];
        if (last->flags & RING_SEG_FLAG_OPEN) {
            /* Sync BEFORE publishing the close. The length below is derived from
             * head_abs, which counts bytes still staged in RAM, and write_segtable()
             * at the end of this function makes that length DURABLE. Without the sync,
             * a power cut between here and the caller's next sync leaves an on-disk
             * table whose closed length runs past the durable cursor — and
             * sd_ring_read_segment() bounds reads by seg.length and tail_abs, never by
             * head_abs, so it would serve stale ring content off the end of that
             * recording. The exposure is one stage (RING_STAGE_BYTES) of audio.
             *
             * Every current caller already syncs immediately before calling, except the
             * "no current segment" path in sd_card.c's write handler — which is only
             * reachable at boot, after a format, or after a failed segment-header write,
             * i.e. exactly the states where an SD error has already occurred. Rather
             * than depend on that argument holding for every future caller, make the
             * invariant structural: a segment boundary is minutes apart, so the
             * occasional redundant sync costs nothing measurable.
             *
             * On failure do NOT close: a published length we cannot back with durable
             * bytes is the very thing this prevents. The caller blocks writes and
             * retries, matching the rotation path's existing sync-failure handling.
             *
             * Gated on stage_dirty so the callers that DO sync first don't pay a second
             * CTRL_SYNC per segment boundary — that is the expensive NAND op (it can
             * force an erase), and doubling it at every rotation would claw back part
             * of the idle-current win this backend was tuned for. */
            if (stage_dirty) {
                int rc = sd_ring_sync();
                if (rc != 0) {
                    return rc;
                }
            }
            last->length = (uint32_t) (head_abs - last->start_abs);
            last->flags &= ~RING_SEG_FLAG_OPEN;
        }
    }

    /* Make room if the table is full: drop the oldest entry. (Its data may still
     * be live, but keep-newest will overwrite it; the app re-derives timing from
     * the inline 0xFFFFFFFB headers regardless.) */
    if (segtab.count >= RING_MAX_SEGMENTS) {
        memmove(&segtab.entries[0], &segtab.entries[1],
                (RING_MAX_SEGMENTS - 1) * sizeof(ring_segment_t));
        segtab.count--;
        if (segtab.entries[0].start_abs > tail_abs) {
            tail_abs = segtab.entries[0].start_abs; /* keep tail consistent with the table */
        }
    }

    ring_segment_t *e = &segtab.entries[segtab.count++];
    e->start_abs = head_abs; /* the caller appends the 0xFFFFFFFB header next */
    e->timestamp = timestamp;
    e->session_id = session_id;
    e->length = 0;
    e->flags = RING_SEG_FLAG_OPEN;

    return write_segtable();
}

int sd_ring_discard_open_segment(void)
{
    if (!ring_mounted) {
        return -ENODEV;
    }
    /* Remove the currently-open segment (the one begin_segment appended) if its
     * inline header never became durable — prevents a phantom zero-length entry from
     * leaking into the fixed-size table on a header-write failure. */
    if (segtab.count > 0 && (segtab.entries[segtab.count - 1].flags & RING_SEG_FLAG_OPEN)) {
        segtab.count--;
        int rc = write_segtable();
        if (rc != 0) {
            /* In-RAM table now diverges from disk — mark dirty so the next sync
             * retries it (matching every other table-mutating site). */
            segtab_dirty = true;
        }
        return rc;
    }
    return 0;
}

int sd_ring_segment_count(void)
{
    if (!ring_mounted) {
        return 0;
    }
    int n = 0;
    for (uint32_t i = 0; i < segtab.count; i++) {
        /* Count only closed, un-acked segments — mirrors closed_global_index so the
         * count and the enumerated list agree (acked-but-not-reclaimed excluded). */
        if (!(segtab.entries[i].flags & (RING_SEG_FLAG_OPEN | RING_SEG_FLAG_ACKED))) {
            n++;
        }
    }
    return n;
}

int sd_ring_get_segment(int index, ring_segment_t *out)
{
    if (!ring_mounted || !out) {
        return -1;
    }
    int gi = closed_global_index(index);
    if (gi < 0) {
        return -1;
    }
    *out = segtab.entries[gi];
    return 0;
}

int sd_ring_read_segment(int index, uint32_t offset, uint8_t *buf, size_t len)
{
    if (!ring_mounted) {
        return -ENODEV;
    }
    int gi = closed_global_index(index);
    if (gi < 0) {
        return -1;
    }
    ring_segment_t seg = segtab.entries[gi];

    /* Guard against the app requesting data the ring has since overwritten. */
    if (seg.start_abs < tail_abs) {
        return -1;
    }
    if (offset >= seg.length) {
        return 0;
    }
    uint32_t avail = seg.length - offset;
    if (len > avail) {
        len = avail;
    }

    uint64_t abs = seg.start_abs + offset;
    size_t done = 0;
    uint8_t tmp[RING_SECTOR_SIZE] __aligned(4);

    while (done < len) {
        uint32_t sec = abs_to_sector(abs);
        uint32_t soff = (uint32_t) (abs % RING_SECTOR_SIZE);

        if (soff == 0) {
            /* Fast path: read as many whole sectors as fit before the requested
             * end AND before the ring wrap, straight into the caller's buffer. */
            uint32_t by_len = (uint32_t) ((len - done) / RING_SECTOR_SIZE);
            uint32_t by_wrap = ring_end_sector - sec;
            uint32_t nsec = MIN(by_len, by_wrap);
            if (nsec > 0) {
                if (read_sectors(sec, buf + done, nsec)) {
                    return -EIO;
                }
                uint32_t got = nsec * RING_SECTOR_SIZE;
                done += got;
                abs += got;
                continue;
            }
        }

        /* Fragment: unaligned head or the final partial tail sector. */
        if (read_sectors(sec, tmp, 1)) {
            return -EIO;
        }
        uint32_t chunk = RING_SECTOR_SIZE - soff;
        if (chunk > (len - done)) {
            chunk = (uint32_t) (len - done);
        }
        memcpy(buf + done, tmp + soff, chunk);
        done += chunk;
        abs += chunk;
    }
    return (int) done;
}

int sd_ring_ack_segment(int index)
{
    if (!ring_mounted) {
        return -ENODEV;
    }
    int gi = closed_global_index(index);
    if (gi < 0) {
        return -1;
    }
    segtab.entries[gi].flags |= RING_SEG_FLAG_ACKED;

    /* Advance the tail over all leading, closed, acked segments. */
    while (segtab.count > 0) {
        ring_segment_t *e0 = &segtab.entries[0];
        if (e0->flags & RING_SEG_FLAG_OPEN) {
            break;
        }
        if (!(e0->flags & RING_SEG_FLAG_ACKED)) {
            break;
        }
        tail_abs = e0->start_abs + e0->length;
        memmove(&segtab.entries[0], &segtab.entries[1],
                (segtab.count - 1) * sizeof(ring_segment_t));
        segtab.count--;
    }

    /* The table (segment dropped + tail advanced) must be durable before the cursor
     * persists the advanced tail. On a table-write failure mark it dirty and bail
     * WITHOUT the cursor, so the next sd_ring_sync() retries the table before any
     * cursor commit — otherwise a later cursor could advance the tail past segments
     * a stale on-disk table still lists. */
    if (write_segtable() != 0) {
        segtab_dirty = true;
        return -EIO;
    }
    /* Flush the table to NAND before the cursor commits the advanced tail — like
     * sd_ring_sync() does. Otherwise a power loss with the cursor sector durable but
     * the table not yet flushed mounts the newer tail against the stale table,
     * leaving segments now below tail listed-but-unreadable. */
    if (sync_disk() != 0) {
        segtab_dirty = true;
        return -EIO;
    }
    return write_cursor(); /* persist the advanced tail */
}

/* ------------------------------------------------------------------ */
/* Stats                                                               */
/* ------------------------------------------------------------------ */
uint64_t sd_ring_used_bytes(void)
{
    return ring_mounted ? (head_abs - tail_abs) : 0;
}

size_t sd_ring_stage_headroom(void)
{
    if (!ring_mounted || stage_fill >= RING_STAGE_BYTES) {
        return 0;
    }
    return (size_t) (RING_STAGE_BYTES - stage_fill);
}

uint64_t sd_ring_free_bytes(void)
{
    if (!ring_mounted) {
        return 0;
    }
    uint64_t used = head_abs - tail_abs;
    return (ring_bytes > used) ? (ring_bytes - used) : 0;
}

uint64_t sd_ring_capacity_bytes(void)
{
    return ring_mounted ? ring_bytes : 0;
}
