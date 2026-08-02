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
void mic_reset();
bool mic_is_running();

/**
 * @brief Whether the PDM_EN rail GPIO is usable, i.e. whether mic_reset() can
 *        actually power-cycle the part.
 *
 * A not-ready GPIO makes mic_reset() a no-op that only re-triggers the nRF PDM
 * peripheral — it logs a warning to RTT and otherwise looks identical to a real
 * reset. Callers that record a reset in the diagnostic log use this so the record
 * says which of the two happened.
 */
bool mic_pdm_rail_is_ready();
void mic_set_gain(uint8_t gain_level);
#endif
