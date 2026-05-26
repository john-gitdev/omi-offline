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

bool write_custom_packet_to_storage(uint32_t marker, uint8_t *data, uint32_t data_size);

void transport_notify_button_state(uint8_t state);

int transport_set_adv_slow(void);
int transport_set_adv_fast(void);

#endif // TRANSPORT_H
