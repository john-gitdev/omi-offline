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
 * @brief Stop and restart the nRF PDM peripheral, preserving whether capture was
 *        running.
 *
 * DESPITE THE NAME, THIS DOES NOT POWER-CYCLE THE MIC. It used to drop PDM_EN,
 * which is the only thing that clears a wedged T5838 (PDM data stuck at digital
 * zero, hw AAD never asserting WAKE). That was removed because driving PDM_EN at
 * all is the prime suspect for the wedging it was meant to cure: the firmware
 * never touched that pin before oo-2.6.0, and the mic never froze before then.
 *
 * What remains is a dmic re-trigger — the same thing mic_pause()/mic_resume() do —
 * so it does NOT recover a wedged part, and no path short of a full power-cycle
 * currently does. Returns quickly; the ~40 ms rail settle is gone with the cycle.
 *
 * Safe to call whether or not capture is running. The call sites are kept so the
 * cycle is one small edit away. See IDEAS.md "Mic rail (PDM_EN) is not driven by
 * firmware" for the evidence and the restore order.
 */
void mic_reset();
bool mic_is_running();
void mic_set_gain(uint8_t gain_level);
#endif
