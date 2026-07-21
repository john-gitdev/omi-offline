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

/* Audio staged in RAM and flushed to the NAND in large, page-aligned batches
 * instead of one 512 B sector at a time. A sub-page (512 B) write forces the NAND
 * FTL to read-modify-write the whole page — on-device this showed ~300 ms write
 * stalls and a write path with no throughput headroom, so audio dropped the
 * moment anything else loaded the card (e.g. a backlog sync). Batching to
 * RING_STAGE_BYTES (page-aligned) removes the amplification.
 *   Invariant: the bytes [head_abs - stage_fill, head_abs) live in
 *   stage[0 .. stage_fill) and are NOT yet on disk; everything before that IS.
 *   The on-disk "written head" (head_abs - stage_fill) only ever advances by
 *   whole sectors, so it stays sector-aligned — which write_run() and
 *   flush_full_sectors() depend on. */
#define RING_STAGE_SECTORS 8u                                    /* 4 KB batch */
#define RING_STAGE_BYTES   (RING_STAGE_SECTORS * RING_SECTOR_SIZE)
static uint8_t  stage[RING_STAGE_BYTES] __aligned(4);
static uint32_t stage_fill;          /* unwritten staged bytes, [0, RING_STAGE_BYTES) */

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
    int64_t t0 = k_uptime_get();
    int rc = disk_access_read(RING_DISK, buf, sector, n) == 0 ? 0 : -EIO;
    note_io(2, t0, 0); /* reads don't count toward io_errors (BLE-read path, non-fatal) */
    return rc;
}

static inline int write_sectors(uint32_t sector, const void *buf, uint32_t n)
{
    int64_t t0 = k_uptime_get();
    int rc = disk_access_write(RING_DISK, buf, sector, n) == 0 ? 0 : -EIO;
    note_io(1, t0, rc);
    return rc;
}

static inline int sync_disk(void)
{
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

/* Flush every COMPLETE sector currently staged, in one page-aligned run, keeping
 * the trailing sub-sector remainder in the stage. Advances the on-disk written
 * head (head_abs - stage_fill) by whole sectors, preserving its alignment. */
static int flush_full_sectors(void)
{
    uint32_t nfull = stage_fill / RING_SECTOR_SIZE;
    if (nfull == 0) {
        return 0;
    }
    uint64_t start_abs = head_abs - stage_fill; /* sector-aligned written head */
    if (write_run(start_abs, stage, nfull)) {
        return -EIO;
    }
    uint32_t flushed = nfull * RING_SECTOR_SIZE;
    uint32_t partial = stage_fill - flushed;
    if (partial > 0) {
        memmove(stage, stage + flushed, partial);
    }
    stage_fill = partial;
    return 0;
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
 * into segtab.entries[]. Closed = not currently open. Returns -1 if out of range. */
static int closed_global_index(int closed_index)
{
    if (closed_index < 0) {
        return -1;
    }
    int seen = 0;
    for (uint32_t i = 0; i < segtab.count; i++) {
        if (segtab.entries[i].flags & RING_SEG_FLAG_OPEN) {
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

int sd_ring_mount(uint32_t total_sectors)
{
    if (total_sectors <= RING_DATA_START_SECTOR + 16) {
        return -EINVAL;
    }

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

    /* Restore the partial head sector so appends continue into it. */
    stage_fill = (uint32_t) (head_abs % RING_SECTOR_SIZE);
    memset(stage, 0, sizeof(stage));
    if (stage_fill != 0) {
        uint32_t sec = abs_to_sector(head_abs - stage_fill);
        if (read_sectors(sec, stage, 1) != 0) {
            /* Partial tail sector is unreadable. Do NOT fail the mount (the caller
             * would fall back to LittleFS and lfs_format() the volume, wiping every
             * synced-but-undrained recording) and do NOT overwrite the bad sector in
             * this traversal. Close/truncate the last segment at the last good sector
             * boundary — so no closed recording claims unreadable bytes and the open
             * one cannot span a gap — then resume recording just PAST the bad sector,
             * leaving it as dead space owned by no segment.
             * LIMITATION: the raw log has no bad-block remapping, so a full ring wrap
             * (only reachable if the phone never drains for ~26 h of continuous
             * recording) would eventually re-address this physical sector; a
             * persistently-bad sector then surfaces as an ordinary write drop /
             * sd_write_blocked, not corruption. LittleFS (the FTL-backed default) is
             * the answer for a genuinely failing card. */
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
    memset(stage, 0, sizeof(stage));

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

    /* Once a full batch has accumulated, flush it as one page-aligned write.
     * Non-fatal on error: the bytes remain staged and become durable on the next
     * successful sync, so head_abs is not rolled back here. */
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
         * plus the partial tail sector (padded — only its valid prefix is ever
         * read, since reads are bounded by segment length). Keep the partial tail
         * staged so appends keep filling it; drop the flushed full sectors. */
        uint32_t nsec = (stage_fill + RING_SECTOR_SIZE - 1) / RING_SECTOR_SIZE;
        uint64_t start_abs = head_abs - stage_fill; /* sector-aligned written head */
        if (write_run(start_abs, stage, nsec)) {
            return -EIO;
        }
        uint32_t nfull = stage_fill / RING_SECTOR_SIZE;
        uint32_t partial = stage_fill - nfull * RING_SECTOR_SIZE;
        if (nfull > 0 && partial > 0) {
            memmove(stage, stage + nfull * RING_SECTOR_SIZE, partial);
        }
        stage_fill = partial;
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
    return write_cursor();
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

int sd_ring_segment_count(void)
{
    if (!ring_mounted) {
        return 0;
    }
    int n = 0;
    for (uint32_t i = 0; i < segtab.count; i++) {
        if (!(segtab.entries[i].flags & RING_SEG_FLAG_OPEN)) {
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
    return write_cursor(); /* persist the advanced tail */
}

/* ------------------------------------------------------------------ */
/* Stats                                                               */
/* ------------------------------------------------------------------ */
uint64_t sd_ring_used_bytes(void)
{
    return ring_mounted ? (head_abs - tail_abs) : 0;
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
