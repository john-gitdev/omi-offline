/*
 * diag_log.c — volatile RAM diagnostic event ring (see diag_log.h / DIAG_LOG_SPEC.md).
 *
 * Everything here is compiled only when CONFIG_OMI_DIAG_LOG is set; the disabled
 * build uses the static-inline no-op stubs in the header and this TU is left out of
 * the build (CMakeLists gates the source file on the same config).
 */

#include "diag_log.h"

#ifdef CONFIG_OMI_DIAG_LOG

#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>

/* ------------------------------------------------------------------ */
/* State                                                              */
/* ------------------------------------------------------------------ */

/* The ring lives in .bss. Its DIAG_LOG_RING_BYTES are reclaimed from the SD worker
 * thread's stack (sd_card.c shrinks SD_WORKER_STACK_SIZE by the same amount when
 * this feature is compiled in), so the total RAM budget is unchanged vs production. */
static diag_event_t ring[DIAG_LOG_RING_DEPTH];

static struct k_spinlock diag_lock;

static uint32_t ring_head;  /* index of the next slot to write */
static uint32_t ring_count; /* number of valid records (<= DIAG_LOG_RING_DEPTH) */
static uint32_t next_seq;   /* monotonic sequence assigned at enqueue */
static uint32_t dropped;    /* keep-newest overwrites since the last ack */

/* Enabled gate: one relaxed atomic read at each event site when disabled. */
static atomic_t diag_enabled = ATOMIC_INIT(0);

/* Drain snapshot — captured on the offset-0 read so a GATT Long Read returns a
 * stable blob even if events keep arriving during the (sub-millisecond) transfer. */
static bool snap_valid;
static uint32_t snap_tail;    /* ring index of the oldest snapshotted record */
static uint32_t snap_count;   /* records in the snapshot */
static uint32_t snap_max_seq; /* highest seq in the snapshot (the ack target) */
static uint32_t snap_dropped; /* dropped_count at snapshot time */

/* ------------------------------------------------------------------ */
/* Lifecycle / gate                                                   */
/* ------------------------------------------------------------------ */

void diag_log_init(void)
{
    k_spinlock_key_t key = k_spin_lock(&diag_lock);
    ring_head = 0;
    ring_count = 0;
    /* Start at 1 so seq 0 is reserved for "none": an ack_seq of 0 (a fresh/rebooted
     * app that has read nothing) then drops no records. */
    next_seq = 1;
    dropped = 0;
    snap_valid = false;
    k_spin_unlock(&diag_lock, key);
    atomic_set(&diag_enabled, 0);
}

void diag_log_set_enabled(bool on)
{
    atomic_set(&diag_enabled, on ? 1 : 0);
}

bool diag_log_is_enabled(void)
{
    return atomic_get(&diag_enabled) != 0;
}

/* ------------------------------------------------------------------ */
/* Enqueue                                                            */
/* ------------------------------------------------------------------ */

void diag_log_event(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1)
{
    /* Disabled = a single predictable branch, no lock, no write. */
    if (!atomic_get(&diag_enabled)) {
        return;
    }

    k_spinlock_key_t key = k_spin_lock(&diag_lock);

    diag_event_t *slot = &ring[ring_head];
    slot->seq = next_seq++;
    slot->uptime_ms = k_uptime_get_32();
    slot->code = code;
    slot->backend = backend;
    slot->arg0 = arg0;
    slot->arg1 = arg1;

    ring_head = (ring_head + 1) % DIAG_LOG_RING_DEPTH;
    if (ring_count < DIAG_LOG_RING_DEPTH) {
        ring_count++;
    } else {
        /* Full: this write overwrote the oldest un-acked record. Keep-newest — the
         * events you're actively debugging are the most recent ones. tail advances
         * implicitly with head (tail == head while full). */
        dropped++;
    }
    /* Deliberately do NOT invalidate the drain snapshot here: a multi-ATT GATT Long
     * Read (iOS) serves offset>0 slices from the snapshot captured at offset 0, and
     * re-snapshotting mid-blob would shift record indices and corrupt the transfer.
     * New events past snap_count are picked up on the app's next offset-0 read.
     *
     * The snapshot freezes the ring BOUNDARY (tail/count/max_seq), not record CONTENT,
     * so in theory an overwrite of an already-snapshotted slot during a sub-ms long
     * read could serve newer bytes at an older slot. In practice this cannot lose data:
     * the ack is seq-based (drops seq <= snap_max_seq), and an overwrite always carries
     * a seq strictly greater than snap_max_seq, so the overwriting record survives the
     * ack and is re-served whole on the next drain. Worst case is a transient
     * mis-ordering inside one blob, which the app tolerates (records key on seq). A
     * content snapshot would double the ring's RAM — the whole point of the design is
     * to reclaim it from the SD-worker stack — so it is not worth it for events this
     * rare (empty-bin rotations, marker drops) against a sub-ms transfer window. */

    k_spin_unlock(&diag_lock, key);
}

/* ------------------------------------------------------------------ */
/* Ack / drain                                                        */
/* ------------------------------------------------------------------ */

void diag_log_ack(uint32_t through_seq)
{
    k_spinlock_key_t key = k_spin_lock(&diag_lock);
    /* Records run in strictly increasing seq order from tail to head, so acking
     * seq <= through_seq drops a contiguous prefix. */
    while (ring_count > 0) {
        uint32_t tail = (ring_head - ring_count + DIAG_LOG_RING_DEPTH) % DIAG_LOG_RING_DEPTH;
        if (ring[tail].seq <= through_seq) {
            ring_count--;
        } else {
            break;
        }
    }
    /* dropped_count is "overwrites since the last ack" (see the 0x0063 header). The
     * app saw exactly snap_dropped of them in the header it just drained, so clear
     * only THAT many — overwrites that raced in after the offset-0 snapshot were never
     * reported and must survive to the next drain rather than be silently erased.
     * (Without a valid snapshot the ack has no reference point, so leave the count
     * intact rather than zero out unreported drops.) */
    if (snap_valid) {
        dropped = (dropped >= snap_dropped) ? (dropped - snap_dropped) : 0;
    }
    snap_valid = false;
    k_spin_unlock(&diag_lock, key);
}

static void build_header(uint8_t hdr[DIAG_LOG_HEADER_SIZE], uint32_t rec_count, uint32_t drop, uint32_t max_seq)
{
    hdr[0] = DIAG_LOG_RECORD_SIZE;
    hdr[1] = 0; /* reserved */
    hdr[2] = (uint8_t) (rec_count & 0xFF);
    hdr[3] = (uint8_t) ((rec_count >> 8) & 0xFF);
    hdr[4] = (uint8_t) (drop);
    hdr[5] = (uint8_t) (drop >> 8);
    hdr[6] = (uint8_t) (drop >> 16);
    hdr[7] = (uint8_t) (drop >> 24);
    hdr[8] = (uint8_t) (max_seq);
    hdr[9] = (uint8_t) (max_seq >> 8);
    hdr[10] = (uint8_t) (max_seq >> 16);
    hdr[11] = (uint8_t) (max_seq >> 24);
}

size_t diag_log_drain(uint8_t *out, size_t max, uint16_t offset)
{
    if (out == NULL || max == 0) {
        return 0;
    }

    k_spinlock_key_t key = k_spin_lock(&diag_lock);

    /* Snapshot discipline: offset 0 (a fresh logical read) always re-captures the
     * ring boundary; offset>0 (a GATT Long-Read continuation) serves the SAME
     * snapshot so the blob stays stable across ATT reads. A blob read with no prior
     * snapshot (should not happen in normal GATT) serves nothing rather than
     * snapshot mid-stream. */
    if (offset == 0) {
        snap_tail = (ring_head - ring_count + DIAG_LOG_RING_DEPTH) % DIAG_LOG_RING_DEPTH;
        snap_count = ring_count;
        snap_dropped = dropped;
        if (ring_count > 0) {
            uint32_t last = (ring_head - 1 + DIAG_LOG_RING_DEPTH) % DIAG_LOG_RING_DEPTH;
            snap_max_seq = ring[last].seq;
        } else {
            snap_max_seq = 0;
        }
        snap_valid = true;
    } else if (!snap_valid) {
        k_spin_unlock(&diag_lock, key);
        return 0;
    }

    uint8_t hdr[DIAG_LOG_HEADER_SIZE];
    build_header(hdr, snap_count, snap_dropped, snap_max_seq);

    const uint32_t total = DIAG_LOG_HEADER_SIZE + snap_count * DIAG_LOG_RECORD_SIZE;
    size_t written = 0;
    uint32_t p = offset;
    while (p < total && written < max) {
        if (p < DIAG_LOG_HEADER_SIZE) {
            out[written] = hdr[p];
        } else {
            uint32_t rec_off = p - DIAG_LOG_HEADER_SIZE;
            uint32_t rec_i = rec_off / DIAG_LOG_RECORD_SIZE;
            uint32_t byte_i = rec_off % DIAG_LOG_RECORD_SIZE;
            uint32_t idx = (snap_tail + rec_i) % DIAG_LOG_RING_DEPTH;
            const uint8_t *rec = (const uint8_t *) &ring[idx];
            out[written] = rec[byte_i];
        }
        p++;
        written++;
    }

    k_spin_unlock(&diag_lock, key);
    return written;
}

/* ------------------------------------------------------------------ */
/* Getters                                                            */
/* ------------------------------------------------------------------ */

uint32_t diag_log_max_seq(void)
{
    k_spinlock_key_t key = k_spin_lock(&diag_lock);
    uint32_t v = snap_valid ? snap_max_seq
                            : (ring_count > 0 ? ring[(ring_head - 1 + DIAG_LOG_RING_DEPTH) % DIAG_LOG_RING_DEPTH].seq : 0);
    k_spin_unlock(&diag_lock, key);
    return v;
}

uint16_t diag_log_record_count(void)
{
    k_spinlock_key_t key = k_spin_lock(&diag_lock);
    uint16_t v = (uint16_t) ring_count;
    k_spin_unlock(&diag_lock, key);
    return v;
}

uint32_t diag_log_dropped_count(void)
{
    /* Take the lock (like the other getters) so the value is consistent with a
     * concurrent enqueue/ack rather than a torn read-vs-update on another core/ISR. */
    k_spinlock_key_t key = k_spin_lock(&diag_lock);
    uint32_t v = dropped;
    k_spin_unlock(&diag_lock, key);
    return v;
}

#endif /* CONFIG_OMI_DIAG_LOG */
