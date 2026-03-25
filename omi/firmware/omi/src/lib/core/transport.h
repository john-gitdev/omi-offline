#ifndef TRANSPORT_H
#define TRANSPORT_H

#include <zephyr/drivers/sensor.h>
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

extern uint32_t device_session_id;
extern uint32_t segment_index;

bool write_custom_packet_to_storage(uint8_t marker, uint8_t *data, uint8_t data_size);

#endif // TRANSPORT_H
