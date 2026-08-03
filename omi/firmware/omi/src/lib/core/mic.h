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
 * Stop and restart the nRF PDM peripheral, preserving whether capture was running.
 *
 * NO LONGER POWER-CYCLES THE MIC. It used to drop PDM_EN, which is the only thing
 * that clears a wedged T5838 — that was removed because driving PDM_EN at all is
 * the prime suspect for the wedging it was meant to cure (the firmware never
 * touched that pin before oo-2.6.0, and the mic never froze before then). What
 * remains is a dmic re-trigger, which does NOT recover a wedged part.
 *
 * The call sites are kept so the cycle is one small edit away. See IDEAS.md
 * "Mic rail (PDM_EN) is not driven by firmware".
 */
void mic_reset();
bool mic_is_running();
void mic_set_gain(uint8_t gain_level);
#endif
