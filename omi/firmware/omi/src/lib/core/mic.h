#ifndef MIC_H
#define MIC_H

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/kernel.h> /* struct k_mutex — see mic_state_lock below */

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
 * @brief Serializes every mic_running transition with the dmic_trigger() calls
 *        implementing it. Exported so callers that own state which must AGREE with
 *        the mic can make their decision and their mic call one atomic unit.
 *
 * The mic functions take this themselves, so ordinary callers never need it. It is
 * exported for exactly one reason: `is_muted` (button.c) must never disagree with
 * whether capture is running, and a caller that reads is_muted, then calls
 * mic_pause(), has a window in which a concurrent mute transition lands between the
 * two — leaving the mic stopped while unmuted, or running while muted. Take this
 * around the pair to close it.
 *
 * Recursive for the owning thread, so nesting the mic calls inside it is fine. Do
 * NOT hold it across anything that can block for long (marker writes, SD I/O) —
 * every mic transition on every thread queues behind it.
 */
extern struct k_mutex mic_state_lock;

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

/**
 * @brief True once mic_start() has resolved the dmic device.
 *
 * transport_start() runs before mic_start(), with boot_warming_sequence() (up to 90 s
 * on a faulty SD) in between, so a BLE write can reach the mic before it exists.
 * mic_resume()/mic_on() ignore calls made then; callers that would otherwise report
 * that as a failure should ask first.
 */
bool mic_is_ready(void);
void mic_set_gain(uint8_t gain_level);
#endif
