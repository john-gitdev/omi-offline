/*
 * AAD + VAD gate for Omi
 *
 * Monitors WAKE pin (P1.2) via GPIO ISR, runs VAD state machine,
 * and manages SD card suspend/resume in a background thread.
 */

#ifndef AAD_H
#define AAD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/**
 * @brief Start AAD handler: configure WAKE pin ISR and spawn thread.
 *
 * Call once after mic_start().
 *
 * @return 0 on success, negative errno on failure
 */
int aad_start(void);

/**
 * @brief Process a mic buffer through the VAD gate.
 *
 * Called from the mic callback.  Handles debounce, pre-roll
 * buffering, and SD suspend/resume.
 *
 * @param buffer       Raw PCM samples from the microphone
 * @param sample_count Number of samples in @p buffer
 * @return true  if the frame contains voice — caller should forward to codec
 * @return false if in VAD sleep — frame stored in pre-roll, skip codec
 */
bool aad_process_audio(int16_t *buffer, size_t sample_count);

/**
 * @brief Check if VAD is in sleep mode (low-power).
 *
 * @return true  if VAD is sleeping (mic paused, T5838 hw AAD active)
 * @return false if VAD is active / recording
 */
bool aad_is_sleeping(void);

/**
 * @brief Force VAD out of sleep immediately (e.g. button press).
 *
 * Bypasses acoustic threshold for FORCE_WAKE_HOLD_MS (50s), then resumes
 * normal VAD. Guarantees at least 60s of recording after a button tap.
 *
 * AUTO MODE ONLY. The guarantee is the whole point of a marker there -- the user
 * cannot know whether the VAD rates the moment as speech, so the tap asserts that it
 * does -- but it is wrong in manual mode both ways. In manual STANDBY it would
 * capture ~60 s in the one mode whose promise is that it records only when told to;
 * during a manual RECORDING it adds nothing (the 65535 threshold already forces
 * every frame) and actively harms, because the window outlives a Stop and would
 * resume capture in standby for its remainder. button.c therefore skips this in both
 * manual states.
 *
 * Within auto mode do NOT re-gate it on "was it already recording": a tap during
 * speech that then stops would end the recording 10 s later with the marker at its
 * tail, which is the loss the window exists to prevent.
 */
void aad_force_wake(void);

/**
 * @brief Set the acoustic VAD threshold.
 *
 * @param threshold New threshold value (0-65535).
 */
void aad_set_threshold(uint16_t threshold);

/** @brief Return the current VAD threshold. */
uint16_t aad_get_threshold(void);

/** @brief Return true if VAD is actively recording. */
bool aad_is_recording(void);

/**
 * @brief Reconcile the microphone against the current VAD threshold and mute state.
 *
 * Manual standby (threshold 32769) parks capture — nothing acoustic can start a
 * recording there, so the PDM peripheral and both mics are pure load. Any other
 * threshold resumes it, unless muted.
 *
 * Callers do not decide the mic state, they call this after changing an input to it.
 * aad_set_threshold() / aad_start() already do; mute must, because it owns the other
 * input. Takes mic_state_lock, so never call it holding a lock or mid-marker-write.
 */
void aad_apply_mic_gate(void);

/**
 * @brief Tell the VAD that capture stopped for an unknown wall-clock span.
 *
 * Parks the VAD (applied on the next mic frame) so the resumption takes the normal
 * detect path and emits a 0xFFFFFFFD resume packet, which is what re-anchors the
 * app's frame timeline across the gap; also drops the now-stale pre-roll. Call on
 * mute, whose duration is unbounded and invisible to the frame clock.
 */
void aad_note_capture_gap(void);

/**
 * @brief Mark a button interaction as in flight (or finished).
 *
 * An input to the mic gate. The button FSM cannot classify a press until
 * MULTI_TAP_WINDOW has elapsed, so with the mic parked the first ~700 ms of a
 * button-started recording would be missing. Setting this on the FSM's idle->active
 * edge wakes the mic immediately so pre-roll has collected that span by the time the
 * action dispatches; clearing it on the return to idle parks again unless something
 * (a record start, a marker's force-wake) asked for capture in the meantime.
 */
void aad_set_mic_prearm(bool on);

/**
 * @brief Arm the idle-advertising backstop (boot, and every disconnect).
 *
 * Advertising is FAST after boot and after every disconnect, and only the VAD-sleep
 * path asks for SLOW — which needs a recording to have happened. Without this a quiet
 * device advertises fast indefinitely. Schedule-only; safe from the BT RX thread.
 */
void aad_note_link_idle(void);

/** @brief Device uptime (ms) at the last processed mic frame. 0 if none yet. */
uint32_t aad_last_frame_uptime_ms(void);

/** @brief Total ms the VAD has held a recording open since boot (capture duty). */
uint32_t aad_voiced_ms(void);

#endif /* AAD_H */
