#ifndef HAPTIC_H_
#define HAPTIC_H_

#include <stdint.h>
#include <zephyr/bluetooth/conn.h>

/**
 * @brief Initialize the haptic driver.
 *
 * Configures the GPIO pin for the haptic motor.
 *
 * @return 0 on success, negative error code otherwise.
 */
int haptic_init(void);

/**
 * @brief Play a haptic effect for a specified duration.
 *
 * Activates the haptic motor for the given duration in milliseconds.
 * The duration is capped by MAX_HAPTIC_DURATION.
 *
 * @param duration Duration in milliseconds.
 */
void play_haptic_milli(uint32_t duration);

/**
 * @brief Play a button-feedback vibration pattern.
 *
 * Emits @p pulses short buzzes (100 ms on, 100 ms gap). 0 = silent, 1 = single,
 * 2 = double, 3 = triple. Non-blocking; supersedes any pattern already playing.
 *
 * @param pulses Number of buzzes (clamped to HAPTIC_MAX_PULSES).
 */
void play_haptic_pattern(uint8_t pulses);

/**
 * @brief Register the Haptic BLE service.
 *
 * Registers the GATT service for controlling the haptic motor over Bluetooth.
 */
void register_haptic_service(void);

void haptic_off();

#endif // HAPTIC_H_
