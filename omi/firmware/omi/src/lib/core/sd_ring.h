/*
 * sd_ring.h — raw circular-log audio backend for the SD NAND.
 *
 * WHY THIS EXISTS
 *   LittleFS has no persistent free-map: when its lookahead window drains, the
 *   block allocator runs lfs_fs_traverse_ (a full-FS scan reading every block of
 *   every file, 10-50 s on a near-full card) on the single sd_worker thread,
 *   during which audio writes queue in sd_msgq and drop. That cost is inherent
 *   to LittleFS and unavoidable once the card is full — which is exactly the
 *   all-day-offline state we care about.
 *
 *   The ring replaces the allocator with a monotonic byte cursor: appending is
 *   O(1) (advance head, write the sector), there is no free-map, and no scan
 *   ever runs. Old audio is append-only and immutable, so a crash can only
 *   damage the single in-flight block — everything committed before the last
 *   cursor sync is safe. This is both faster AND more crash-safe than LittleFS
 *   for a continuous-append workload.
 *
 * WHERE IT LIVES
 *   Entirely on the SD NAND (a separate 512 MB chip). DFU never addresses the
 *   SD NAND — not the primary app slot, not the QSPI secondary — so the cursor
 *   and segment table are immune to firmware updates by construction, unlike
 *   the internal-flash NVS that holds BT bonds.
 *
 * ON-SD LAYOUT (512-byte sectors; a "reserved" 256-sector / 128 KB metadata
 * region precedes the audio ring):
 *
 *   sector 0          format header   (ring_format_header_t; written once at format)
 *   sectors 1..64     cursor log      (64 × ring_cursor_t, one per sector; circular)
 *   sectors 65..72    segment table A (ring_segment_table_t, 8 sectors)
 *   sectors 73..80    segment table B (ring_segment_table_t, 8 sectors)
 *   sectors 81..255   reserved
 *   sectors 256..END  audio ring      (append-only circular byte log)
 *
 * DURABILITY INVARIANT (never claim un-synced audio):
 *   sd_ring_append() stages bytes in RAM and flushes complete sectors once the
 *   stage fills. sd_ring_sync() writes everything still staged, CTRL_SYNCs, and
 *   ONLY THEN writes a fresh cursor record (advanced head_abs) to the next
 *   cursor-log slot. If power dies before the cursor write, the cursor still
 *   points at the old head, so those bytes simply aren't claimed — the safe
 *   direction. A torn cursor write fails CRC on boot and we fall back to the
 *   previous valid slot.
 *
 * THREADING: like the LittleFS path, ALL sd_ring_* calls are serialized on the
 * single sd_worker thread. Not thread-safe; do not call from other threads.
 */
#ifndef SD_RING_H
#define SD_RING_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* On-SD format constants                                             */
/* ------------------------------------------------------------------ */
#define RING_SECTOR_SIZE      512u
#define RING_FMT_MAGIC        0x474E524Fu /* "ORNG" */
#define RING_CUR_MAGIC        0x55435247u /* "GRCU" */
#define RING_SEG_MAGIC        0x47535247u /* "GRSG" */
#define RING_FORMAT_VERSION   1u

#define RING_HDR_SECTOR       0u
#define RING_CURLOG_START     1u
#define RING_CURLOG_SLOTS     64u  /* wear + torn-write headroom for the ~1 Hz cursor write */
#define RING_SEGTAB_SECTORS   8u   /* 4096 B per table copy */
#define RING_SEGTAB_A_START   (RING_CURLOG_START + RING_CURLOG_SLOTS)      /* 65 */
#define RING_SEGTAB_B_START   (RING_SEGTAB_A_START + RING_SEGTAB_SECTORS)  /* 73 */
#define RING_DATA_START_SECTOR 256u /* 128 KB metadata reserve; audio ring begins here */

/* Max concurrently-tracked segments. At 10-min rotation this is ~28 h of
 * un-synced audio; in normal use the phone drains + acks so far fewer are live.
 * Sized so ring_segment_table_t is exactly RING_SEGTAB_SECTORS sectors. */
#define RING_MAX_SEGMENTS     168u

/* segment.flags bits */
#define RING_SEG_FLAG_ACKED   (1u << 0) /* phone synced + deleted; tail may advance past it */
#define RING_SEG_FLAG_OPEN    (1u << 1) /* currently-recording segment; excluded from the sync list */

/* ------------------------------------------------------------------ */
/* Host-provided RAM and wiring (see sd_ring_init)                    */
/* ------------------------------------------------------------------ */
/* Audio is staged in RAM and flushed to the NAND in large, page-aligned batches
 * instead of one 512 B sector at a time. A sub-page (512 B) write forces the NAND
 * FTL to read-modify-write the whole page — on-device that showed ~300 ms write
 * stalls and no throughput headroom, so audio dropped the moment anything else
 * loaded the card. Batching to a page multiple removes the amplification.
 *
 * SIZE (80 sectors = 40 KB ≈ 8 s of audio at the measured ~5 KB/s ingest) is set
 * to match the LittleFS path's 44,000 B write_batch_buffer (~8.6 s), and that is
 * the whole point: the flush cadence sets how often the SPI bus and NAND are
 * powered up, which was the dominant idle-current difference between the two
 * backends. At the previous 4 KB the ring woke the bus ~10x more often than
 * LittleFS for the same audio. The stage is NOT owned here — sd_card.c passes in
 * scratch it shares with the LittleFS batch buffer (exactly one backend is live
 * per boot), so matching LittleFS's power profile costs zero additional RAM.
 *
 * Growing the stage does NOT widen the crash-loss window: that is bounded by
 * RING_SYNC_BYTES (256 KB) and the 60 s fsync backstop in sd_card.c, both far
 * larger, and sd_ring_sync() flushes the stage before committing the cursor.
 *
 *   Invariant: the bytes [head_abs - stage_fill, head_abs) live in
 *   stage[0 .. stage_fill), and the on-disk "written head" (head_abs - stage_fill)
 *   only ever advances by whole sectors, so it stays sector-aligned — which
 *   write_run() and flush_full_sectors() depend on.
 *
 *   Staged does NOT imply un-durable: sd_ring_sync() writes the padded partial tail
 *   sector and deliberately keeps it staged so appends keep filling it, so a
 *   non-empty stage can be entirely on disk. Ask stage_dirty (sd_ring.c), never
 *   stage_fill, whether anything is still un-written — sd_ring_begin_segment()
 *   depends on that distinction to decide if it must sync before publishing a
 *   segment's closed length. */
#define RING_STAGE_SECTORS 80u
#define RING_STAGE_BYTES   (RING_STAGE_SECTORS * RING_SECTOR_SIZE)

/* One NAND page per disk op. A full-stage flush is issued as a run of these
 * rather than one 40 KB write, so the sd_worker never sits inside a single long
 * disk op — mirroring flush_batch_buffer_chunked() on the LittleFS path, which
 * chunks at 4 KB for exactly this reason. */
#define RING_FLUSH_CHUNK_SECTORS 8u

/* Wiring supplied by sd_card.c before the first mount/format. Fields are copied,
 * so the struct itself may be a temporary. */
typedef struct {
    /* Scratch for the append stage; at least RING_STAGE_BYTES, 4-byte aligned. */
    uint8_t *stage;
    size_t   stage_bytes;
    /* Called immediately before any disk access, so the caller can leave the SPI
     * bus suspended until the ring genuinely touches the NAND (most appends only
     * memcpy into the stage). MUST be cheap and idempotent — it runs per disk op.
     * Optional; NULL means the caller keeps the bus awake itself. */
    void (*io_wake)(void);
    /* True when a higher-priority request (a BLE read) is waiting. A multi-chunk
     * flush checks this between chunks and returns early, leaving the remainder
     * staged — which is the ring's normal not-yet-durable state, so it costs
     * nothing. Optional; NULL means never yield. */
    bool (*io_busy)(void);
} sd_ring_host_t;

/* ------------------------------------------------------------------ */
/* On-SD structures (packed; byte layout is the on-flash contract)     */
/* ------------------------------------------------------------------ */

/* sector 0 — written once at format, read at mount to learn geometry. */
typedef struct __packed {
    uint32_t magic;             /* RING_FMT_MAGIC */
    uint32_t version;           /* RING_FORMAT_VERSION */
    uint32_t sector_size;       /* RING_SECTOR_SIZE */
    uint32_t data_start_sector; /* RING_DATA_START_SECTOR */
    uint64_t ring_bytes;        /* audio-ring capacity in bytes (multiple of sector size) */
    uint32_t reserved[2];
    uint32_t crc32;             /* crc32_ieee over all preceding bytes */
} ring_format_header_t;

/* One cursor-log slot (1 sector). Highest valid seq wins on mount. */
typedef struct __packed {
    uint32_t magic;    /* RING_CUR_MAGIC */
    uint32_t seq;      /* monotonic */
    uint64_t head_abs; /* total bytes ever appended (monotonic; head_off = head_abs % ring_bytes) */
    uint64_t tail_abs; /* bytes reclaimed — start of live data */
    uint32_t reserved[4];
    uint32_t crc32;    /* crc32_ieee over all preceding bytes */
} ring_cursor_t;

/* One tracked segment ("file" in the BLE protocol). A segment begins at the
 * 0xFFFFFFFB RecordingHeader written into the ring by sd_ring_begin_segment(). */
typedef struct __packed {
    uint64_t start_abs;   /* absolute byte offset of this segment's first byte */
    uint32_t timestamp;   /* UTC seconds from the RecordingHeader — the app's "file" key */
    uint32_t session_id;  /* device_session_id */
    uint32_t length;      /* segment size in bytes; 0 while it is the open/current segment */
    uint32_t flags;       /* RING_SEG_FLAG_* */
} ring_segment_t;         /* 24 bytes */

/* Double-buffered segment table (copies A/B). Exactly RING_SEGTAB_SECTORS. */
typedef struct __packed {
    uint32_t magic;   /* RING_SEG_MAGIC */
    uint32_t seq;     /* monotonic; higher of A/B wins */
    uint32_t count;   /* number of valid entries in `entries` */
    uint32_t reserved;
    ring_segment_t entries[RING_MAX_SEGMENTS];
    uint8_t  pad[RING_SEGTAB_SECTORS * RING_SECTOR_SIZE
                 - 16 - RING_MAX_SEGMENTS * sizeof(ring_segment_t) - 4];
    uint32_t crc32;   /* crc32_ieee over all preceding bytes */
} ring_segment_table_t;

/* ------------------------------------------------------------------ */
/* API — all calls run on the sd_worker thread only                    */
/* ------------------------------------------------------------------ */

/**
 * @brief Install the host's scratch buffer and I/O hooks.
 *
 * Must succeed before sd_ring_mount() / sd_ring_format(); both fail with
 * -EINVAL until it has. Safe to call again (a re-mount re-installs).
 *
 * @return 0 on success, -EINVAL if @p host or its stage is missing/too small.
 */
int sd_ring_init(const sd_ring_host_t *host);

/**
 * @brief Detect an existing ring on the mounted disk and load its state.
 *
 * Reads the format header, replays the cursor log (highest valid seq), and
 * loads the newest valid segment table. On success the ring is ready to append.
 *
 * @param total_sectors Disk sector count (from DISK_IOCTL_GET_SECTOR_COUNT).
 * @return 0 if a valid ring was mounted; -ENOENT if the disk holds no ring
 *         (caller should sd_ring_format()); other negative errno on I/O error.
 */
int sd_ring_mount(uint32_t total_sectors);

/**
 * @brief Wipe the metadata region and lay down a fresh, empty ring.
 *
 * Destroys any existing content (LittleFS or an older ring) — the one-time SD
 * migration cost. Leaves the ring mounted and ready to append.
 *
 * @param total_sectors Disk sector count.
 * @return 0 on success, negative errno otherwise.
 */
int sd_ring_format(uint32_t total_sectors);

/** @brief True once sd_ring_mount()/sd_ring_format() has succeeded. */
bool sd_ring_is_mounted(void);

/**
 * @brief Append audio bytes at the head. O(1); sector-buffered internally.
 *
 * Advances head_abs by @p len. Full sectors are written as they fill; the
 * partial tail sector is held in RAM until sd_ring_sync() (or the next fill).
 * Enforces keep-newest: if the head would overrun un-reclaimed data, the tail
 * is force-advanced (oldest segments dropped) so recording never blocks.
 *
 * @return 0 on success, negative errno on write error.
 */
int sd_ring_append(const uint8_t *data, size_t len);

/**
 * @brief Flush the partial tail sector, sync the disk, and persist the cursor.
 *
 * Establishes the durability point: after this returns, everything appended so
 * far is recoverable across a power loss. Call on a bounded cadence (~1 Hz)
 * while audio flows, and on shutdown / low-battery.
 *
 * @return 0 on success, negative errno otherwise.
 */
int sd_ring_sync(void);

/**
 * @brief Open a new segment at the current head (call before writing the
 *        0xFFFFFFFB RecordingHeader bytes for the new segment).
 *
 * Finalizes the previously-open segment (sets its length) and appends a new
 * entry to the segment table keyed by @p timestamp / @p session_id. Persists
 * the table (double-buffered) so the new segment survives a crash.
 *
 * Closing a segment implies a sd_ring_sync(): the published length covers staged
 * bytes, and the table write that records it is durable, so those bytes must
 * reach the NAND first. Callers therefore do NOT need their own sync beforehand,
 * and a sync failure fails this call with nothing closed.
 *
 * @return 0 on success, negative errno otherwise.
 */
int sd_ring_begin_segment(uint32_t timestamp, uint32_t session_id);

/**
 * @brief Discard the currently-open segment (roll back sd_ring_begin_segment) when
 *        its inline header could not be persisted, so a header-write failure doesn't
 *        leak a phantom zero-length entry into the fixed segment table.
 * @return 0 on success (or nothing open), negative errno on a table-write error.
 */
int sd_ring_discard_open_segment(void);

/**
 * @brief Number of CLOSED segments available to sync (excludes the open one).
 */
int sd_ring_segment_count(void);

/**
 * @brief Copy out the metadata of the @p index-th closed segment (0-based,
 *        oldest first). @return 0 on success, -1 if out of range.
 */
int sd_ring_get_segment(int index, ring_segment_t *out);

/**
 * @brief Read @p len bytes from closed segment @p index at byte @p offset.
 *
 * Reads are clamped to the segment length. Maps the absolute offset to a ring
 * sector (handling wrap) and reads via disk_access.
 *
 * @return bytes read (>0), 0 at/after segment end, or negative errno.
 */
int sd_ring_read_segment(int index, uint32_t offset, uint8_t *buf, size_t len);

/**
 * @brief Mark closed segment @p index as acked (phone synced+deleted) and
 *        advance the tail past all leading acked segments to reclaim space.
 *
 * @return 0 on success, negative errno / -1 on error.
 */
int sd_ring_ack_segment(int index);

/** @brief Live (un-reclaimed) bytes currently held in the ring. */
uint64_t sd_ring_used_bytes(void);

/** @brief Free bytes remaining before keep-newest overwrite begins. */
uint64_t sd_ring_free_bytes(void);

/** @brief Total audio-ring capacity in bytes. */
uint64_t sd_ring_capacity_bytes(void);

/**
 * @brief Diagnostics: slowest single SD primitive since boot, packed as
 *        (tag << 24) | duration_ms, tag 1=write 2=read 3=CTRL_SYNC. Pinpoints a
 *        worker stall (queue-full drop burst) to the exact disk op.
 */
uint32_t sd_ring_max_io_ms(void);

/** @brief Diagnostics: count of write_sectors / CTRL_SYNC failures (EIO) — a
 *         NAND rejecting writes, as opposed to merely being slow. */
uint32_t sd_ring_io_errors(void);

#endif /* SD_RING_H */
