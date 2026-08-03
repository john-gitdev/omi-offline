#ifndef MIC_H
#define MIC_H

#include <stdbool.h>
#include <stdint.h>

typedef void (*mix_handler)(int16_t *);

/**
 * @brief Initialize the Microphone
 *
 * Initializes the Microphone
 *
 * @return 0 if successful, negative errno code if error
 */
int mic_start();
void set_mic_callback(mix_handler _callback);

void mic_off();
void mic_on();
void mic_pause();
void mic_resume();

/**
 * @brief Hard-reset the T5838 by power-cycling its supply rail.
 *
 * mic_pause()/mic_resume() only stop and start the nRF PDM peripheral — they
 * never touch PDM_EN — so a wedged mic (PDM data stuck at digital zero, hw AAD
 * never asserting WAKE) survives a mute/unmute cycle untouched. This is the only
 * path short of a reboot that re-powers the part.
 *
 * Blocks ~40 ms for the rail to settle. Restores whatever run state it found, so
 * it is safe to call whether or not capture is currently running — but prefer
 * calling it while paused, since the cycle discards in-flight samples.
 */
/**
 * Outcome of @ref mic_reset. These are materially different states, not degrees of
 * success, which is why this is an enum rather than a bool: only CYCLED clears a
 * wedged T5838, and only RAIL_OFF means capture must not be started. Values are
 * persisted as DIAG_MIC_POWER_CYCLE arg0 — APPEND-ONLY, never renumber.
 */
typedef enum {
    /** Rail never dropped — GPIO not ready, pull-down failed, or the dmic STOP
     *  aborted the reset. Still powered, but nothing was cleared. */
    MIC_RESET_NOT_CYCLED = 0,
    /** Full low-then-restore completed. The only outcome that clears a wedge. */
    MIC_RESET_CYCLED = 1,
    /** Rail dropped but could not be driven back up; the pin was released to the
     *  board pull-up, which should re-power it. Probably cycled — not assertable,
     *  and treated as unconfirmed: capture is NOT auto-restarted, because a weak
     *  pull-up's rise time is nothing like a driven output's and we cannot tell
     *  whether the rail actually came back. */
    MIC_RESET_PARTIAL = 2,
    /** PDM_EN is stuck low and the release failed too: the mic has NO supply.
     *  Callers must not start capture, or they will report a running mic over a
     *  dead part and produce silence that looks healthy from every layer above. */
    MIC_RESET_RAIL_OFF = 3,
} mic_reset_result_t;

/**
 * @return which of @ref mic_reset_result_t occurred. RTT carries the same shape,
 *         but this is what callers gate on and what reaches the drained log.
 */
mic_reset_result_t mic_reset();
bool mic_is_running();
void mic_set_gain(uint8_t gain_level);
#endif
