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
 * @return true only if the PDM_EN rail was actually taken low and restored.
 *
 * False means the part never lost its supply — a not-ready GPIO, a failed
 * `gpio_pin_configure_dt()`, or an aborted reset because the dmic STOP failed. In
 * every one of those cases the call degrades to at most a dmic re-trigger, which
 * does NOT clear a wedged T5838, so a caller recording this in the diagnostic log
 * must report the returned value rather than assume the cycle happened.
 */
bool mic_reset();
bool mic_is_running();
void mic_set_gain(uint8_t gain_level);
#endif
