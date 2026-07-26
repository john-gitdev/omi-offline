#ifndef DIAG_LOG_H
#define DIAG_LOG_H

/*
 * On-device diagnostic event log — a lightweight, volatile RAM event ring.
 *
 * Purpose: the drop counters (0x19B10062) are aggregate-since-boot totals — they
 * say HOW MANY empty-bin rotations / marker drops / pause-gate saves happened, but
 * not WHEN, in what order, or with what context. This ring captures a per-event
 * record (seq + uptime + cause context), ships it to the phone over 0x19B10063,
 * and clears on ack (0x19B10064) — so field diagnosis needs no RTT probe.
 *
 * Design constraints (see DIAG_LOG_SPEC.md):
 *   - Zero filesystem interference (lives entirely in RAM, never touches the SD FS).
 *   - RAM-neutral: the ring's bytes are reclaimed from SD_WORKER_STACK_SIZE (see
 *     DIAG_LOG_RING_BYTES use in sd_card.c), so a dev build costs the same RAM as prod.
 *   - Compiled out entirely in production (CONFIG_OMI_DIAG_LOG) — zero .bss, zero code.
 *   - Runtime-gated by a dev-tools toggle (default OFF, not persisted): a disabled log
 *     costs a single predictable branch per call site.
 *
 * Enqueue (diag_log_event) is O(1), spinlock-guarded (callable from any thread),
 * and NEVER touches NAND — a synchronous write here would inject latency into the
 * audio path and cause the very drops we measure.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* Event codes — APPEND-ONLY, never renumber (same discipline as the drop counters).
 * The app keeps a matching decode table; an unknown code renders generically so a
 * newer device against an older app still shows something. */
typedef enum {
    DIAG_RESERVED = 0,
    DIAG_EMPTY_BIN_ROTATION = 1,     /* arg1 = current_file_size (bytes in the empty bin) */
    DIAG_MARKER_WRITE_DROP = 2,      /* arg0 = marker header low16; arg1 = block_drops snapshot */
    DIAG_MARKER_PAUSE_GATE_SAVE = 3, /* arg0 = marker header low16; arg1 = block len */
    DIAG_PRIORITY_RECORD_START = 4,  /* arg1 = session_id */
    DIAG_PRIORITY_RECORD_STOP = 5,   /* arg1 = session_id */
    DIAG_SESSION_END_MARKER_EMIT = 6,/* arg1 = session_id */
    DIAG_SD_BLOCK_DROP = 7,          /* arg1 = block_drops snapshot (audio block lost) */
    DIAG_CODEC_DROP = 8,             /* arg1 = codec ring-full drop count snapshot */
    DIAG_WRITE_BLOCKED = 9,          /* reserved (not yet instrumented) */
    DIAG_RING_IO_ERROR = 10,         /* reserved (not yet instrumented) */
    DIAG_BACKEND_MOUNT = 11,         /* reserved (not yet instrumented) */
} diag_event_code_t;

/* 16-byte packed record. nRF5340 is little-endian, so the in-RAM layout IS the wire
 * layout — the drain memcpy's raw slot bytes with no per-field repacking. */
typedef struct __packed {
    uint32_t seq;        /* monotonic, assigned at enqueue; the ack/drain key */
    uint32_t uptime_ms;  /* k_uptime_get_32() at the event */
    uint8_t  code;       /* diag_event_code_t */
    uint8_t  backend;    /* 0 = littlefs, 1 = ring (sd_get_active_backend()) */
    uint16_t arg0;       /* event-specific (see table above) */
    uint32_t arg1;       /* event-specific (see table above) */
} diag_event_t;

#define DIAG_LOG_RECORD_SIZE 16
#define DIAG_LOG_RING_DEPTH  128
/* Bytes reclaimed from SD_WORKER_STACK_SIZE when the feature is compiled in. */
#define DIAG_LOG_RING_BYTES  (DIAG_LOG_RING_DEPTH * DIAG_LOG_RECORD_SIZE)

/* 0x19B10063 drain header prepended to the record stream (little-endian):
 *   [u8  record_size = 16][u8 reserved][u16 record_count]
 *   [u32 dropped_count][u32 max_seq]
 * Total blob = DIAG_LOG_HEADER_SIZE + record_count * DIAG_LOG_RECORD_SIZE. */
#define DIAG_LOG_HEADER_SIZE 12

#ifdef CONFIG_OMI_DIAG_LOG

void diag_log_init(void);              /* zero state; enabled = false */
void diag_log_set_enabled(bool on);    /* dev-tools toggle target (0x0064 enable bit) */
bool diag_log_is_enabled(void);
void diag_log_event(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1);

/* Snapshot-based, byte-offset-addressable drain for GATT Long Read. The FIRST read
 * (offset 0) snapshots the ring boundary so records don't shift mid-transfer;
 * subsequent offsets serve the same snapshot. Writes up to `max` bytes of the blob
 * (header + packed records) starting at byte `offset`; returns bytes written. */
size_t   diag_log_drain(uint8_t *out, size_t max, uint16_t offset);
void     diag_log_ack(uint32_t through_seq);   /* drop all records with seq <= through_seq */
uint32_t diag_log_max_seq(void);               /* highest seq in the current snapshot */
uint16_t diag_log_record_count(void);          /* live record count */
uint32_t diag_log_dropped_count(void);         /* keep-newest overwrites since last ack */

#else /* !CONFIG_OMI_DIAG_LOG — no-op stubs so call sites compile with zero cost */

static inline void diag_log_init(void) {}
static inline void diag_log_set_enabled(bool on) { (void) on; }
static inline bool diag_log_is_enabled(void) { return false; }
static inline void diag_log_event(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1)
{
    (void) code;
    (void) backend;
    (void) arg0;
    (void) arg1;
}
static inline size_t diag_log_drain(uint8_t *out, size_t max, uint16_t offset)
{
    (void) out;
    (void) max;
    (void) offset;
    return 0;
}
static inline void diag_log_ack(uint32_t through_seq) { (void) through_seq; }
static inline uint32_t diag_log_max_seq(void) { return 0; }
static inline uint16_t diag_log_record_count(void) { return 0; }
static inline uint32_t diag_log_dropped_count(void) { return 0; }

#endif /* CONFIG_OMI_DIAG_LOG */

#endif // DIAG_LOG_H
