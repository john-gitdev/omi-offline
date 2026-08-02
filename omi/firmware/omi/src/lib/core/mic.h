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
 * @return true only if the full low-then-restore cycle completed.
 *
 * False means the cycle did not complete — NOT that the part kept its supply
 * throughout. Three shapes, and they differ:
 *   - never started: the GPIO was not ready, the pull-down failed, or the dmic STOP
 *     failed and aborted the reset. The call degrades to at most a dmic re-trigger,
 *     which does not clear a wedged T5838.
 *   - partial: the rail went low but could not be driven back up. The pin is then
 *     released to the board pull-up to re-power the part, so it may in fact have
 *     been cycled — the result is simply not something this function can assert.
 *   - stuck: even the release failed, so PDM_EN is low and the mic has no supply.
 *     Capture is deliberately left stopped rather than restarted into a dead rail.
 *
 * A caller recording this in the diagnostic log must report the returned value
 * rather than assume a complete cycle happened; RTT carries which shape it was.
 */
bool mic_reset();
bool mic_is_running();
void mic_set_gain(uint8_t gain_level);
#endif
