#ifndef TRANSPORT_H
#define TRANSPORT_H

#include <zephyr/drivers/sensor.h>
#include <zephyr/sys/atomic.h>
#ifdef CONFIG_OMI_ENABLE_BATTERY
extern uint8_t battery_percentage;
// Set to true after the first successful ADC reading so callers can
// distinguish "no reading yet" from "battery is genuinely at 100%".
extern bool battery_ready;
// Schedule an immediate battery notify (e.g. after charging state changes).
// Safe to call from ISR/interrupt context.
void transport_notify_battery_soon(void);
#endif
extern uint16_t current_mtu;

/**
 * @brief Initialize the BLE transport logic
 *
 * Initializes the BLE Logic
 *
 * @return 0 if successful, negative errno code if error
 */
int transport_start();

/**
 * @brief Turn off the BLE transport
 *
 * @return 0 if successful, negative errno code if error
 */
int transport_off();

/**
 * @brief Write a marker packet to storage
 *
 * @return true if successful
 */
bool write_marker_to_storage(void);

/**
 * @brief Write a session-end marker packet (header 0xFFFFFFFC) to storage.
 *
 * Emitted on manual-mode stop double-tap so the app can finalize the
 * recording at the user-chosen boundary instead of holding it as a draft.
 *
 * @return true if successful
 */
bool write_session_end_marker_to_storage(void);

/**
 * @brief Write mute-on (0xFFFFFFFA) / mute-off (0xFFFFFFF9) markers to storage.
 *
 * Bracket a muted stretch in the audio stream so the app can render it as a
 * "Muted" gap in the recordings timeline. Force-drained like other markers so
 * they're durable even though no audio flows while muted.
 *
 * @return true if successful
 */
bool write_mute_on_marker_to_storage(void);
bool write_mute_off_marker_to_storage(void);

/**
 * @brief Write a Priority Recording start marker (header 0xFFFFFFF8) to storage.
 *
 * Emitted on an auto-mode RECORD_START. Written as the first inline frame of a
 * freshly rotated bin so the recording boundary coincides with a bin boundary.
 * The app finalizes the current auto recording at this point and opens a new
 * high-priority (force-captured) recording anchored here. Same 16-byte payload
 * as the button-tap marker (utc_ms u64 + uptime_ms u32 + device_session_id u32).
 *
 * @return true if successful
 */
bool write_priority_recording_marker_to_storage(void);

/**
 * @brief Note that a Priority Recording just stopped (diagnostics counter).
 *
 * Called from button.c priority_record_stop() once a force-capture actually ends,
 * so the priority_record_starts / _stops pair (read via 0x19B10062) balances.
 * starts > stops means a priority recording was left open.
 */
void transport_note_priority_record_stop(void);

/**
 * @brief Broadcast audio packets over BLE
 *
 * @param buffer Buffer containing audio data
 * @param size Size of the audio data
 * @return 0 if successful, negative errno code if error
 */
int broadcast_audio_packets(uint8_t *buffer, size_t size);

/**
 * @brief Get the current BLE connection
 *
 * @return Pointer to current connection, or NULL if not connected
 */
struct bt_conn *get_current_connection();

/**
 * @brief Release a connection reference obtained from get_current_connection()
 *
 * @param conn Connection to release (safe to call with NULL)
 */
void put_current_connection(struct bt_conn *conn);

typedef struct __attribute__((packed)) {
    uint32_t marker;            // 0xFFFFFFFB
    uint32_t payload_len;       // 28
    uint64_t utc_start_ms;      // Wall clock at file creation (ms precision)
    uint64_t uptime_start_ms;   // Monotonic time at file creation (ms precision)
    uint32_t imu_ticks;         // Raw 24-bit LSM6DSL ticks
    uint32_t session_id;        // Unique boot ID
    uint32_t version;           // Struct version (v1 = 1)
} RecordingHeader_v1_t;

/* Unique per-boot session ID. Declared atomic_t so concurrent lazy-init
 * from the audio path, button-tap marker, and main() race safely and so
 * cross-thread readers (sd_card.c) observe a consistent value. Use
 * `(uint32_t)atomic_get(&device_session_id)` to read. */
extern atomic_t device_session_id;

/* important=true marks the frame as a marker (button-tap / session-end /
 * VAD-resume): the 440-byte block it lands in is flushed with the durable
 * (blocking) SD enqueue so it isn't dropped on transient queue saturation.
 * Audio frames pass important=false. */
bool write_custom_packet_to_storage(uint32_t marker, uint8_t *data, uint32_t data_size, bool important);

void transport_notify_button_state(uint8_t state);

/* Push a notification on the BLE mute characteristic (19B10071) with the
 * current mute state. Called from the button FSM / BLE write path whenever
 * mute toggles. */
void mute_state_notify(void);

int transport_set_adv_slow(void);
int transport_set_adv_fast(void);

/**
 * @brief Mark inbound/outbound GATT activity on a power-relevant characteristic.
 *
 * Resets the idle-disconnect timer.  Call from storage command writes,
 * outbound storage notifications, and CCC subscribe events.  Do NOT call
 * from periodic battery autopushes or sporadic button events — those would
 * prevent the idle window from ever closing.
 */
void transport_mark_activity(void);

#endif // TRANSPORT_H
