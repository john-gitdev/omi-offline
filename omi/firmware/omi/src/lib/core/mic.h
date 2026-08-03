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
 * @return true only if the PDM_EN rail was actually taken low and restored, which
 *         is the only outcome that clears a wedged T5838. False means the cycle did
 *         not complete — an unready GPIO, a failed gpio_pin_configure_dt(), or an
 *         aborted reset because the dmic STOP failed.
 *
 * Reported rather than acted on. Capture is restarted whenever it was running,
 * regardless: gating it on the rail state was tried and removed, because the state
 * machine it required was larger than the problem. A rail that genuinely fails to
 * come back produces silent capture, and DIAG_VAD_LEVEL reports that within one
 * window — so the detector already covers the case the gating was trying to
 * prevent, and there is nothing the firmware could usefully do about it anyway.
 */
bool mic_reset();
bool mic_is_running();
void mic_set_gain(uint8_t gain_level);
#endif
