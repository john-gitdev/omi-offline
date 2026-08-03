#ifndef SETTINGS_H
#define SETTINGS_H

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/drivers/rtc.h>

/* Audio storage backend selector (persisted; see app_settings_get_storage_backend). */
#define STORAGE_BACKEND_LITTLEFS 0 /* default — file-per-segment over LittleFS */
#define STORAGE_BACKEND_RING     1 /* raw append-only circular log (sd_ring.c) */
/* "No format armed" sentinel for storage_format_pending. Any other value is the
 * STORAGE_BACKEND_* the next mount should format fresh; 0xFF never aliases a real
 * backend, so an unset/never-armed device (default) never force-formats. */
#define STORAGE_FORMAT_PENDING_NONE 0xFF

/* Consecutive post-crash boots with the ring backend active before it
 * auto-reverts to LittleFS (anti-brick self-heal). */
#define RING_BOOT_FAIL_LIMIT     3

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
 * @brief Persist the active audio storage backend.
 *
 * @param backend STORAGE_BACKEND_LITTLEFS (0, default) or STORAGE_BACKEND_RING (1).
 * @return 0 on success, -EINVAL for an unknown backend, or a persist error.
 *
 * NOTE: switching backends requires the SD to be (re)formatted to the target
 * layout. The backend-switch command (storage.c) arms app_settings_save_storage_
 * format_pending(<the selected backend>) alongside this so the next boot wipes to a
 * fresh layout — a plain mount of the previous backend's card can leave stale
 * metadata (e.g. a still-valid ring header under freshly-written LittleFS data) that
 * mounts OK but points at overwritten bytes, so nothing is readable. Pass the TARGET
 * backend, not a bare flag: the mount only force-formats when the armed value equals
 * the backend it mounts. The value itself lives in internal NVS; the audio + ring
 * metadata it selects live on the SD NAND.
 */
int app_settings_save_storage_backend(uint8_t backend);

/**
 * @brief Get the active audio storage backend (STORAGE_BACKEND_*; default
 *        STORAGE_BACKEND_LITTLEFS when nothing is persisted).
 */
uint8_t app_settings_get_storage_backend(void);

/**
 * @brief Persist the "format this target backend fresh on next boot" record.
 *
 * @param target the STORAGE_BACKEND_* to format on the next mount, or
 *        STORAGE_FORMAT_PENDING_NONE to disarm.
 *
 * Armed by the backend-switch command with the TARGET backend (not a bare flag), then the
 * backend itself is persisted. The boot mount force-formats only when this target equals the
 * backend it actually mounts — so an interruption between the two writes (target armed, backend
 * not yet saved) leaves target != mounted-backend and never wipes the current storage. The
 * record stays ARMED across the wipe and is cleared (back to NONE) only AFTER the target both
 * formats and mounts (sd_card.c consume_format_pending), so a reset mid-format re-formats next
 * boot instead of mounting stale metadata; a persistent clear failure fails the mount rather
 * than accepting writes a re-wipe would destroy. Only the boot mount consumes it — runtime
 * remounts never force-format. NONE is the default and steady state.
 */
int app_settings_save_storage_format_pending(uint8_t target);

/** @brief Get the armed format target (a STORAGE_BACKEND_*, or STORAGE_FORMAT_PENDING_NONE). */
uint8_t app_settings_get_storage_format_pending(void);

/**
 * @brief Persist the consecutive ring-backend post-crash boot counter.
 *
 * Bumped at boot when the ring backend is active and the reset cause was a
 * watchdog/lockup; reset once a boot proves healthy. Drives the anti-brick
 * auto-revert to LittleFS at RING_BOOT_FAIL_LIMIT.
 */
int app_settings_save_ring_boot_fails(uint8_t fails);

/** @brief Get the consecutive ring-backend post-crash boot counter. */
uint8_t app_settings_get_ring_boot_fails(void);

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
 * @brief Arm/disarm the one-shot "unpair after firmware update" marker.
 *
 * Arming records [current_fw] (the version running now, before the flash);
 * disarming clears it. Consumed once, on the first boot whose running version
 * DIFFERS from the armed one (see @ref app_settings_consume_post_dfu_unpair /
 * transport_start). Because the version is captured at ARM time, a failed/
 * aborted flash (same version afterward) never triggers the wipe, and it's
 * fail-closed: if arming didn't persist, no version is stored and no wipe fires.
 * The app arms this before a flash when the user opted in, and disarms otherwise.
 *
 * @param arm true to arm, false to disarm.
 * @param current_fw Compile-time firmware version string (e.g. CONFIG_BT_DIS_FW_REV_STR).
 * @return 0 on success, negative error code otherwise.
 */
int app_settings_arm_post_dfu_unpair(bool arm, const char *current_fw);

/**
 * @brief Consume the one-shot post-update unpair marker for this boot.
 *
 * Clears the armed marker (one-shot) and returns whether a bond wipe is due:
 * true iff it was armed AND [current_fw] differs from the armed version (a real
 * update landed). Returns false when not armed or the version is unchanged.
 *
 * @param current_fw Compile-time firmware version string (e.g. CONFIG_BT_DIS_FW_REV_STR).
 * @return true if the caller should wipe BLE bonds, false otherwise.
 */
bool app_settings_consume_post_dfu_unpair(const char *current_fw);


#endif // SETTINGS_H
