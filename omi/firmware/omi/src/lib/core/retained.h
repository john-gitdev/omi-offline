#ifndef RETAINED_H
#define RETAINED_H

/*
 * retained.h — the slice of RAM that outlives a reboot, a crash and a power-off.
 *
 * It is the `sram_retained_mem` partition (boards/omi/pm_static.yml) plus the matching
 * `zephyr,retained-ram` node in the board devicetree. The Partition Manager carves it
 * off the top of sram_primary, so nothing the linker places — and not the libc malloc
 * arena either, which is sized from the same PM values — can land in it. On a power-off
 * Zephyr's z_sys_poweroff() turns RAM retention off everywhere and back on for exactly
 * the devicetree regions marked retained, so this one stays powered in System OFF.
 *
 * What it guarantees, and what it does not:
 *   - Survives: sys_reboot(), a watchdog or fatal-error reset, and System OFF (the
 *     4-tap power-off, the app's Shutdown, critical battery). RAM is not cleared by a
 *     reset, and MCUboot uses only the bottom of RAM (measured: it ends at 0x20049D70,
 *     with no heap). That measurement is of THIS repo's MCUboot; a device keeps
 *     whatever bootloader it shipped with, since OTA never replaces it.
 *   - Does not survive: the battery running flat, or the first boot after flashing
 *     firmware whose layout differs. Both are caught by the header check and the
 *     region starts clean — which is exactly the behaviour before it existed, so a
 *     failure here degrades to the old device, never to garbage.
 *   - Flash layout is untouched: only the two RAM entries in pm_static.yml moved, so
 *     OTA to and from stock firmware is unaffected. Stock treats this slice as
 *     ordinary RAM; arriving from stock, the header check rejects whatever it left.
 *
 * Bump RETAINED_VERSION (retained.c) for any change to what a field MEANS or where it
 * sits. A mismatch wipes the region, which is the safe outcome.
 */

#include <stdbool.h>
#include <stdint.h>

#include "diag_log.h"

/* The diagnostic event ring's state. Owned entirely by diag_log.c; lives here so the
 * layout is fixed whether or not CONFIG_OMI_DIAG_LOG is compiled in. */
struct retained_diag {
    uint32_t magic;    /* diag_log.c's own validity marker for the ring */
    uint32_t head;     /* index of the next slot to write */
    uint32_t count;    /* number of valid records (<= DIAG_LOG_RING_DEPTH) */
    uint32_t next_seq; /* monotonic sequence assigned at enqueue; never 0 */
    uint32_t dropped;  /* keep-newest overwrites since the last ack */
    diag_event_t ring[DIAG_LOG_RING_DEPTH];
};

/* Validate the region and reinitialise it if it does not carry this firmware's
 * signature. Call once, first thing in main(), before anything reads or writes it.
 * Returns true if the previous boot's contents were kept. */
bool retained_init(void);

/* Record the current mute state. Called on every mute change and by the boot restore.
 * The write is not atomic: a reset landing mid-write fails the checksum, and the next
 * boot comes up unmuted — the behaviour before this existed. */
void retained_mute_store(bool muted, uint32_t since_utc_s);

/* True if the retained state says the device was muted, with *since_utc_s the time
 * mute was first engaged (0 if it was engaged before a time sync). */
bool retained_mute_get(uint32_t *since_utc_s);

/* The event ring's state. Always the same address; valid to call at any time. */
struct retained_diag *retained_diag(void);

#endif /* RETAINED_H */
