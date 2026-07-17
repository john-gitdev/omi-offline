#ifndef BUTTON_H
#define BUTTON_H

#include <zephyr/input/input.h>
#include <zephyr/kernel.h>

extern volatile bool is_muted;
extern volatile bool is_led_enabled;
extern volatile uint8_t marker_flash_count;

typedef enum {
    MARKER_FLASH_WHITE,   // Non-manual marker tap
    MARKER_FLASH_GREEN,   // Manual-mode start of recording
    MARKER_FLASH_RED,     // Manual-mode end of recording
} marker_flash_color_t;

typedef enum {
    BUTTON_ACTION_NONE = 0,
    BUTTON_ACTION_MUTE = 1,
    BUTTON_ACTION_MARKER = 2,
    BUTTON_ACTION_TOGGLE_LED = 3,
    /* Explicit start/stop of a recording, distinct gestures (no toggle).
     * Manual mode: same as today's MARKER start/stop (65535 / 32769, persisted).
     * Auto mode: start/stop a "Priority Recording" — a force-captured stretch
     * (runtime 65535, not persisted) bracketed by a 0xFFFFFFF8 start marker and
     * the existing 0xFFFFFFFC session-end on stop; rendered high-priority (red). */
    BUTTON_ACTION_RECORD_START = 4,
    BUTTON_ACTION_RECORD_STOP = 5,
    /* Single-gesture toggle: stop if a recording is currently active, else start
     * one. "Active" is the runtime threshold == 65535 in either mode (manual
     * recording and auto priority-recording both hold it). Dispatches into the
     * same start/stop paths as RECORD_START / RECORD_STOP. */
    BUTTON_ACTION_RECORD_TOGGLE = 6,
} button_action_t;

extern volatile marker_flash_color_t marker_flash_color;

int button_init();
void activate_button_work();
void register_button_service();

/* turnoff_all() result. It never returns on a successful power-off (ends in
 * sys_poweroff()); these cover the two non-fatal early returns. Values are
 * ordered so a bare truthy check (`if (turnoff_all())`) treats the recoverable
 * failure as the non-benign case: the no-op is 0, the teardown failure is
 * non-zero. */
typedef enum {
    TURNOFF_ALREADY = 0, /* another context is already powering off; this call was a no-op */
    TURNOFF_BAILED = 1,  /* hardware teardown couldn't complete; caller may recover (e.g. reboot) */
} turnoff_result_t;
turnoff_result_t turnoff_all();

/* Apply a mute change from the button FSM or the BLE mute characteristic.
 * No-op while in manual mode (mirrors the physical-button gate). Records the
 * mute-since timestamp on engage and notifies the mute characteristic on any
 * change. Returns true if the state actually changed. */
bool mute_apply(bool on);

/* Snapshot the mute state for the BLE mute characteristic. *since_* are when
 * mute was engaged (0 when not muted): utc_s = RTC epoch seconds (0 if
 * pre-time-sync), uptime_ms = monotonic ms for app-side wall-time derivation. */
void mute_get_state(uint8_t *muted, uint32_t *since_utc_s, uint32_t *since_uptime_ms);

// Input message queue from evt/button.c
extern struct k_msgq input_button;

#endif
