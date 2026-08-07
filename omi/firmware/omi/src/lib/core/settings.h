#ifndef SETTINGS_H
#define SETTINGS_H

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/drivers/rtc.h>

/* Storage-backend wire values. The runtime selector was removed in oo-2.9.0 when
 * LittleFS was retired — the ring is the only backend — but these values are still
 * reported over BLE (0x0062 status_flags, and the diag event log's `backend` field),
 * so they must not be renumbered. */
#define STORAGE_BACKEND_LITTLEFS 0 /* retired: file-per-segment over LittleFS */
#define STORAGE_BACKEND_RING     1 /* raw append-only circular log (sd_ring.c) */

/**
 * @brief Initialize the settings subsystem.
 *
 * This loads any persisted settings from flash into memory.
 *
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_init(void);

/**
 * @brief Save the dim light ratio setting.
 *
 * @param new_ratio The new ratio value (e.g., 0-100).
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_dim_ratio(uint8_t new_ratio);

/**
 * @brief Get the current dim light ratio.
 *
 * @return The current ratio value.
 */
uint8_t app_settings_get_dim_ratio(void);

/**
 * @brief Save the microphone gain setting.
 *
 * @param new_gain The new gain level (0-8).
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_mic_gain(uint8_t new_gain);

/**
 * @brief Get the current microphone gain.
 *
 * @return The current gain level (0-8).
 */
uint8_t app_settings_get_mic_gain(void);

/**
 * @brief Save the AAD threshold setting.
 *
 * @param new_threshold The new threshold value.
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_vad_threshold(uint16_t new_threshold);

/**
 * @brief Get the current AAD threshold.
 *
 * @return The current threshold value.
 */
uint16_t app_settings_get_vad_threshold(void);

/**
 * @brief Save the auto-mode Priority Recording safety-cap duration.
 *
 * @param minutes Max minutes a force-capture runs before auto-stop; 0 = no cap
 *                (battery / SD capacity become the only limit).
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_priority_record_max_minutes(uint16_t minutes);

/**
 * @brief Get the Priority Recording safety-cap duration in minutes (0 = no cap).
 */
uint16_t app_settings_get_priority_record_max_minutes(void);

/**
 * @brief Persist whether the solid-blue "connected to phone" LED is shown.
 *
 * @param enabled true (default) = solid blue while a phone is connected, which
 *        overrides the recording-state colour; false = the connection no longer
 *        drives the LED at all, so the underlying mute / low-battery / recording
 *        state shows through and an idle connected device stays dark.
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_connected_led(bool enabled);

/** @brief Whether the connected (solid blue) LED indicator is enabled. */
bool app_settings_get_connected_led(void);

/**
 * @brief Persist the boot value of the LED master gate (@ref is_led_enabled).
 *
 * @param enabled false (default) = LEDs start off each boot and only the
 *        BUTTON_ACTION_TOGGLE_LED gesture lights them for that session, which
 *        is the historical behaviour (is_led_enabled is volatile RAM); true =
 *        LEDs come up enabled on every boot. The button gesture still toggles
 *        the live state either way — it is a session override, not a new
 *        default, so this value is what the device returns to after a restart.
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_led_boot_enabled(bool enabled);

/** @brief The persisted boot value of the LED master gate. */
bool app_settings_get_led_boot_enabled(void);

/**
 * @brief Save the RTC timestamp setting.
 *
 * @param ts The new RTC timestamp.
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_rtc_timestamp(struct rtc_time ts);

/**
 * @brief Get the current RTC timestamp.
 *
 * @return The current RTC timestamp.
 */
struct rtc_time app_settings_get_rtc_timestamp(void);

/**
 * @brief Save the UTC epoch time base (seconds).
 *
 * This is used by the application timekeeping layer to provide a stable
 * increasing UTC time while the device is running.
 *
 * @param epoch_s UTC time in seconds since 1970-01-01.
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_rtc_epoch(uint64_t epoch_s);

/**
 * @brief Get the persisted UTC epoch time base (seconds).
 *
 * @return UTC seconds since 1970-01-01, or 0 if not set.
 */
uint64_t app_settings_get_rtc_epoch(void);

/**
 * @brief Save an LSM6DSL timestamp base for timekeeping across system_off.
 *
 * When epoch_s is non-zero, the base becomes valid; when epoch_s is zero, the
 * stored base is cleared.
 */
int app_settings_save_lsm6dsl_time_base(uint64_t epoch_s, uint32_t imu_timestamp);

/**
 * @brief Get the saved LSM6DSL timestamp base.
 *
 * @param epoch_s Output epoch seconds (0 if not set).
 * @param imu_timestamp Output IMU timestamp counter.
 */
int app_settings_get_lsm6dsl_time_base(uint64_t *epoch_s, uint32_t *imu_timestamp);

/**
 * @brief Persist reset cause + session uptime for the current boot.
 *
 * Call once at boot with the HWINFO reset cause. Call again periodically
 * (e.g. every 10 min) with cause=0 and updated uptime_ms so the next boot
 * can report how long the session ran before the reset.
 *
 * @param cause   HWINFO reset-cause bitmask (RESET_WATCHDOG, RESET_POR, etc.).
 * @param uptime_ms  k_uptime_get() at time of call.
 */
int app_settings_save_last_reset(uint32_t cause, uint64_t uptime_ms);

/** @brief Return the reset-cause bitmask saved by the previous boot. */
uint32_t app_settings_get_last_reset_cause(void);

/** @brief Return the uptime_ms saved by the previous boot (approximate session length). */
uint64_t app_settings_get_last_reset_uptime_ms(void);

/**
 * @brief Persist the previous session's final uptime before overwriting the last_reset record.
 *
 * Call this once at boot with prev_uptime (read from NVS before clearing it).
 * The BLE diagnostics characteristic returns this value so the app can show
 * how long the crashed session ran, not how long the current session has run.
 */
int app_settings_save_crash_session_uptime(uint64_t uptime_ms);

/** @brief Return the previous session's final uptime checkpoint (ms). */
uint64_t app_settings_get_crash_session_uptime(void);

/**
 * @brief Persist the cumulative BLE connection-failure counters.
 *
 * Survives a power-cycle so the counts are still readable after the user reboots
 * the Omi to reconnect. See NOTES.md "BLE: advertising but won't connect".
 * @param count          cumulative HCI connect-callback failures (across boots).
 *                       Only counts the peripheral host being told a connection
 *                       attempt failed outright — see estab_count for the case
 *                       this misses.
 * @param last_adv_slow  1 if the most recent failure occurred during slow (1 s)
 *                       advertising, 0 if during fast advertising
 * @param estab_count    cumulative links that came up and then died at
 *                       establishment (disconnect reason HCI 0x3e)
 */
int app_settings_save_conn_fail(uint32_t count, uint8_t last_adv_slow, uint32_t estab_count);

/** @brief Load the persisted connection-failure counts + last-failure adv mode. */
void app_settings_get_conn_fail(uint32_t *count, uint8_t *last_adv_slow, uint32_t *estab_count);

/**
 * @brief Save the button configuration.
 *
 * @param config Array of 6 bytes representing button tap actions.
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_button_config(const uint8_t config[6]);

/**
 * @brief Get the button configuration.
 *
 * @param config Array of 6 bytes to store the configuration.
 */
void app_settings_get_button_config(uint8_t config[6]);

/**
 * @brief Save the haptic (vibration pattern) configuration.
 *
 * @param config Array of 6 bytes, one vibration pattern per tap slot
 *               (0=Off, 1=Single, 2=Double, 3=Triple).
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_save_haptic_config(const uint8_t config[6]);

/**
 * @brief Get the haptic (vibration pattern) configuration.
 *
 * @param config Array of 6 bytes to store the configuration.
 */
void app_settings_get_haptic_config(uint8_t config[6]);

/**
 * @brief Arm the one-shot "wipe BLE bonds on the next boot" marker.
 *
 * Called from the mcumgr DFU hook when an image has finished transferring
 * (MGMT_EVT_OP_IMG_MGMT_DFU_PENDING), i.e. a flash is going to happen on the
 * next boot. Consumed once by @ref app_settings_consume_dfu_bond_wipe from
 * transport_start().
 *
 * Keyed on "a DFU landed", NOT on the firmware version changing: a same-version
 * reflash rewrites the slot just as hard, and is exactly what a user does when
 * pairing is already broken. Idempotent — a second call while already pending
 * skips the flash write.
 *
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_arm_dfu_bond_wipe(void);

/**
 * @brief Consume the one-shot DFU bond-wipe marker for this boot.
 *
 * Clears the markers and returns whether the caller should wipe BLE bonds. The
 * clear happens before the caller's bt_unpair(), which is safe because
 * bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY) cannot fail — see the note in
 * settings.c before "fixing" it. A failed clear leaves the marker set, so the
 * next boot wipes again: idempotent, and the right way to fail for a marker
 * whose only job is to guarantee a free key slot.
 *
 * Also returns true on the FIRST boot of any firmware carrying this scheme, even
 * with no marker set: the flash that installed it was performed by the previous
 * image, which had no DFU_PENDING hook and so could not arm one. On Android the
 * app clears the phone bond on DFU success, so without this the migration update
 * would strand the device in exactly that state. (On iOS there is no
 * programmatic bond removal, so the phone keeps its bond and the migration wipe
 * only frees the device side — harmless, and the direction the user can fix.)
 *
 * @return true if the caller should wipe BLE bonds, false otherwise.
 */
bool app_settings_consume_dfu_bond_wipe(void);


#endif // SETTINGS_H
