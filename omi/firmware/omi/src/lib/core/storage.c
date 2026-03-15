#include "storage.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

#include "sd_card.h"
#include "transport.h"
#include "utils.h"
#include "mic.h"
#ifdef CONFIG_OMI_ENABLE_WIFI
#include "wifi.h"
#endif

LOG_MODULE_REGISTER(storage, CONFIG_LOG_DEFAULT_LEVEL);

#define MAX_PACKET_LENGTH 256
#define OPUS_ENTRY_LENGTH 80
#define FRAME_PREFIX_LENGTH 3

#define READ_COMMAND 0
#define DELETE_COMMAND 1
#define NUKE 2
#define STOP_COMMAND 3

#define INVALID_FILE_SIZE 3
#define ZERO_FILE_SIZE 4
#define INVALID_COMMAND 6

#define MAX_HEARTBEAT_FRAMES 100
#define HEARTBEAT 50

// End-of-Transfer marker sent as a single notification once all audio data has been sent.
// Chosen as 0xFD to extend the existing reserved-byte hierarchy:
//   0xFF = metadata packet (16-byte payload follows)
//   0xFE = star marker    (16-byte payload follows)
//   0xFD = end of transfer (no payload — this byte alone signals completion)
// Values 0x01–0xFC are audio frame length prefixes; 0xFD will never appear as a
// legitimate Opus frame size (OPUS_ENTRY_LENGTH = 80). This is purely a storage
// protocol marker and has no interaction with MCUboot or the SMP OTA service.
#define EOT_MARKER 0xFD
static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags);
#ifdef CONFIG_OMI_ENABLE_WIFI
static ssize_t storage_wifi_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags);
static void wifi_start_work_handler(struct k_work *work)
{
    mic_pause();
    wifi_turn_on();
}
#endif

static struct bt_uuid_128 storage_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295780, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_write_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295781, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_read_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295782, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_wifi_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295783, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static ssize_t storage_read_characteristic(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           void *buf,
                                           uint16_t len,
                                           uint16_t offset);
static struct k_work wifi_start_work;

K_THREAD_STACK_DEFINE(storage_stack, 4096);
static struct k_thread storage_thread;

void broadcast_storage_packet(struct k_work *work_item);

// GATT attribute index map — update these comments whenever the table changes.
// attrs[0] = primary service declaration
// attrs[1] = write characteristic declaration   (BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY)
// attrs[2] = write characteristic value
// attrs[3] = write CCC descriptor
// attrs[4] = read characteristic declaration    (BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY)
// attrs[5] = read characteristic value
// attrs[6] = read CCC descriptor
// [CONFIG_OMI_ENABLE_WIFI only:]
// attrs[7] = wifi characteristic declaration    (BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY)
// attrs[8] = wifi characteristic value
// attrs[9] = wifi CCC descriptor
//
// bt_gatt_notify() for the write/data path always uses attrs[1].
// bt_gatt_notify() for the wifi path uses attrs[7] (only valid when WiFi is enabled).
#define STORAGE_ATTR_WRITE_CHAR 1
#define STORAGE_ATTR_WIFI_CHAR  7

static struct bt_gatt_attr storage_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&storage_service_uuid),                           /* attrs[0] */
    BT_GATT_CHARACTERISTIC(&storage_write_uuid.uuid,                         /* attrs[1] */
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           storage_write_handler,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE), /* attrs[3] */
    BT_GATT_CHARACTERISTIC(&storage_read_uuid.uuid,                          /* attrs[4] */
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           storage_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE), /* attrs[6] */
#ifdef CONFIG_OMI_ENABLE_WIFI
    BT_GATT_CHARACTERISTIC(&storage_wifi_uuid.uuid,                          /* attrs[7] */
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           storage_wifi_handler,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE), /* attrs[9] */
#endif
};

struct bt_gatt_service storage_service = BT_GATT_SERVICE(storage_service_attr);

bool storage_is_on = false;

static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{

    storage_is_on = true;
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_ERR("Invalid CCC value: %u", value);
    }
}

static ssize_t storage_read_characteristic(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           void *buf,
                                           uint16_t len,
                                           uint16_t offset)
{
    k_msleep(10);
    uint32_t amount[2] = {0};
    amount[0] = get_file_size();
    amount[1] = get_offset();
    LOG_INF("Storage read requested: file size %u, offset %u", amount[0], amount[1]);
    ssize_t result = bt_gatt_attr_read(conn, attr, buf, len, offset, amount, 2 * sizeof(uint32_t));
    return result;
}

uint8_t transport_started = 0;
#define SD_BLE_SIZE 440
static uint8_t storage_write_buffer[SD_BLE_SIZE * 10];

static uint32_t offset = 0;
static uint8_t stop_started = 0;
static uint8_t delete_started = 0;
uint32_t remaining_length = 0;
static uint32_t ble_chunk_index = 0;

static int setup_storage_tx()
{
    transport_started = (uint8_t) 0;
    LOG_INF("about to transmit storage\n");
    // Give the central time to subscribe to notifications before data starts flowing.
    // This delay was split across setup_storage_tx (100ms) and the GATT write handler
    // (500ms). The write handler sleep has been removed because it blocked the BT thread,
    // so the full delay now lives here in the storage thread where it is safe.
    k_msleep(600);

    uint32_t file_size = get_file_size();

    // Validate offset against file size
    if (offset >= file_size) {
        LOG_ERR("Offset %d exceeds file size %d", offset, file_size);
        offset = 0; // Reset to start
    }

    remaining_length = file_size - offset;
    ble_chunk_index = 0;

    LOG_INF("remaining length: %d", remaining_length);
    LOG_INF("offset: %d", offset);
    LOG_INF("file size: %d", file_size);

    return 0;
}
uint8_t delete_num = 0;
uint8_t nuke_started = 0;
static uint8_t heartbeat_count = 0;
static uint8_t parse_storage_command(const void *buf, uint16_t len)
{

    if (len != 6 && len != 2) {
        LOG_INF("invalid command");
        return INVALID_COMMAND;
    }
    const uint8_t command = ((uint8_t *) buf)[0];
    const uint8_t file_num = ((uint8_t *) buf)[1];
    uint32_t request_offset = 0;
    if (len == 6) {
        request_offset =
            ((uint8_t *) buf)[2] << 24 | ((uint8_t *) buf)[3] << 16 | ((uint8_t *) buf)[4] << 8 | ((uint8_t *) buf)[5];
    }
    LOG_INF("command successful: command: %d file: %d offset: %d \n", command, file_num, request_offset);

    // only support file 1 for now
    if (file_num != 1) {
        LOG_INF("invalid file count 0");
        return INVALID_FILE_SIZE;
    }

    if (command == READ_COMMAND) // read
    {
        uint32_t file_size = get_file_size();
        if (request_offset >= file_size) {
            LOG_WRN("requested offset is too large");
            return INVALID_FILE_SIZE;
        } else if (file_size == 0) {
            LOG_WRN("file size is 0");
            return ZERO_FILE_SIZE;
        } else {
            offset = request_offset - (request_offset % SD_BLE_SIZE);
            transport_started = 1;
        }
    } else if (command == DELETE_COMMAND) {
        delete_num = file_num;
        delete_started = 1;
    } else if (command == NUKE) {
        nuke_started = 1;
    } else if (command == STOP_COMMAND) // should be no explicit stop command, send heartbeats to keep connection alive
    {
        storage_stop_transfer();
    } else if (command == HEARTBEAT) {
        heartbeat_count = 0;
    } else {
        LOG_INF("invalid command \n");
        return 6;
    }
    return 0;
}

static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags)
{
    LOG_INF("about to schedule the storage");
    LOG_INF("was sent %d  ", ((uint8_t *) buf)[0]);

    uint8_t result_buffer[1] = {0};
    uint8_t result = parse_storage_command(buf, len);
    result_buffer[0] = result;
    LOG_INF("length of storage write: %d", len);
    LOG_INF("result: %d ", result);
    bt_gatt_notify(conn, &storage_service.attrs[STORAGE_ATTR_WRITE_CHAR], &result_buffer, 1);
    // NOTE: do NOT sleep here. This handler runs in the Bluetooth host stack's cooperative
    // thread. Sleeping would block ALL BLE operations (connection events, supervision
    // timeouts, etc.). The storage thread handles its own startup delay in setup_storage_tx().
    return len;
}

#ifdef CONFIG_OMI_ENABLE_WIFI
static ssize_t storage_wifi_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags)
{
    uint8_t result_buffer[1] = {0};
    LOG_INF("wifi config write handler called");

    if (len < 1) {
        result_buffer[0] = 1; // error: invalid length
        bt_gatt_notify(conn, &storage_service.attrs[STORAGE_ATTR_WIFI_CHAR], &result_buffer, 1);
        return len;
    }

    if (wifi_is_hw_available() == false) {
        LOG_ERR("Wi-Fi hardware not available");
        result_buffer[0] = 0xFE; // error: hardware not available
        bt_gatt_notify(conn, &storage_service.attrs[STORAGE_ATTR_WIFI_CHAR], &result_buffer, 1);
        return len;
    }

    const uint8_t cmd = ((const uint8_t *) buf)[0];

    switch (cmd) {
        case 0x01: // WIFI_SETUP
            LOG_INF("WIFI_SETUP: len=%d", len);
            if (len < 2) {
                LOG_WRN("WIFI_SETUP: invalid setup length: len=%d", len);
                result_buffer[0] = 2; // error: invalid setup length
                break;
            }
            // Parse SSID
            // Format: [cmd][ssid_len][ssid][password_len][password]
            uint8_t idx = 1;
            uint8_t ssid_len = ((const uint8_t *)buf)[idx++];
            LOG_INF("WIFI_SETUP: ssid_len=%d, len=%d", ssid_len, len);

            if (ssid_len == 0 || ssid_len > WIFI_MAX_SSID_LEN || idx + ssid_len > len) {
                LOG_WRN("SSID length invalid: ssid_len=%d, len=%d", ssid_len, len);
                result_buffer[0] = 3; break;
            }
            char ssid[WIFI_MAX_SSID_LEN + 1] = {0};
            memcpy(ssid, &((const uint8_t *)buf)[idx], ssid_len);
            idx += ssid_len;
            LOG_INF("WIFI_SETUP: ssid='%s'", ssid);

            uint8_t pwd_len = ((const uint8_t *)buf)[idx++];
            if (pwd_len < WIFI_MIN_PASSWORD_LEN || pwd_len > WIFI_MAX_PASSWORD_LEN || idx + pwd_len > len) {
                LOG_WRN("PWD length invalid: pwd_len=%d, len=%d", pwd_len, len);
                result_buffer[0] = 4; break;
            }
            char pwd[WIFI_MAX_PASSWORD_LEN + 1] = {0};
            if (pwd_len > 0) memcpy(pwd, &((const uint8_t *)buf)[idx], pwd_len);
            LOG_INF("WIFI_SETUP: pwd='%s' pwd_len=%d, len=%d", pwd, pwd_len, len);

            setup_wifi_credentials(ssid, pwd);
            result_buffer[0] = 0; // success
            break;

        case 0x02: // WIFI_START
            LOG_INF("WIFI_START command received");
            if (is_wifi_on()) {
                LOG_INF("Wi-Fi already on - wait for next session");
                result_buffer[0] = 5; // wait for next session
                break;
            }
            k_work_submit(&wifi_start_work);
            result_buffer[0] = 0;
            break;

        case 0x03: // WIFI_SHUTDOWN
            LOG_INF("WIFI_SHUTDOWN command received");
            storage_stop_transfer();
            wifi_turn_off();
            mic_resume();
            result_buffer[0] = 0;
            break;

        default:
            LOG_WRN("Unknown WIFI command: %d", cmd);
            result_buffer[0] = 0xFF; // unknown command
            break;
    }

    bt_gatt_notify(conn, &storage_service.attrs[STORAGE_ATTR_WIFI_CHAR], &result_buffer, 1);
    return len;
}
#endif

static void write_to_gatt(struct bt_conn *conn)
{
    // Use the negotiated MTU minus 3 bytes for GATT overhead
    uint32_t max_payload = (current_mtu > 3) ? (current_mtu - 3) : 20;

    // Cap the payload at SD_BLE_SIZE to ensure we don't exceed our buffer
    uint32_t effective_packet_size = MIN(max_payload, SD_BLE_SIZE);
    uint32_t packet_size = MIN(remaining_length, effective_packet_size);

    if (packet_size == 0) return;

    LOG_INF("[BLE_TX] chunk=%u offset=%u remaining=%u", (unsigned)ble_chunk_index, (unsigned)offset, (unsigned)remaining_length);

    int r = read_audio_data(storage_write_buffer, packet_size, offset);
    if (r < 0) {
        LOG_ERR("[BLE_TX] read_audio_data failed at chunk=%u offset=%u: %d", (unsigned)ble_chunk_index, (unsigned)offset, r);
        remaining_length = 0; // Stop transfer on error
        return;
    }

    ble_chunk_index++;

    int err = bt_gatt_notify(conn, &storage_service.attrs[STORAGE_ATTR_WRITE_CHAR], &storage_write_buffer, packet_size);
    if (err) {
        if (err == -ENOMEM || err == -EAGAIN) {
            // Buffer full, try again in next loop without advancing offset
            k_yield();
        } else {
            LOG_WRN("error writing to gatt: %d, packet_size: %u, MTU: %u", err, packet_size, current_mtu);
            // For other errors, maybe try to advance slightly or just yield
            k_msleep(10);
        }
    } else {
        offset = offset + packet_size;
        remaining_length = remaining_length - packet_size;
    }
}

#ifdef CONFIG_OMI_ENABLE_WIFI
static void write_to_tcp()
{
    
    uint32_t to_read = MIN(remaining_length, SD_BLE_SIZE * 10);
    int ret = read_audio_data(storage_write_buffer, to_read, offset);
    if (ret > 0) {
        offset += to_read;
        remaining_length -= to_read;
        size_t sent = 0;
        while ((sent < to_read) && is_wifi_on()) {
            int n = wifi_send_data(storage_write_buffer + sent, to_read - sent);
            if (n <= 0) {
                // wait and retry
                k_msleep(10);
            } else {
                sent += n;
                k_yield();
            }
        }
    } else {
        LOG_ERR("Failed to read audio data: %d", ret);
        remaining_length = 0; // Stop transfer on error
    }
}
#endif


void storage_stop_transfer()
{
    remaining_length = 0;
    stop_started = 1;
}

void storage_write(void)
{
    while (1) {
        struct bt_conn *conn = get_current_connection();

        if (transport_started) {
            LOG_INF("transport started in side : %d", transport_started);
            setup_storage_tx();
        }
        // probably prefer to implement using work orders for delete,nuke,etc...
        if (delete_started) {
            LOG_INF("delete:%d\n", delete_started);
            int err = clear_audio_directory();

            if (err) {
                LOG_PRINTK("error clearing\n");
            } else {
                offset = 0;
                uint8_t result_buffer[1] = {200};
                if (conn) {
                    bt_gatt_notify(get_current_connection(), &storage_service.attrs[STORAGE_ATTR_WRITE_CHAR], &result_buffer, 1);
                }
            }
            delete_started = 0;
            k_msleep(10);
        }
        if (nuke_started) {
            clear_audio_directory();
            offset = 0;
            nuke_started = 0;
        }
        if (stop_started) {
            remaining_length = 0;
            stop_started = 0;
            save_offset(offset);
        }
        if (heartbeat_count == MAX_HEARTBEAT_FRAMES) {
            LOG_INF("no heartbeat sent\n");
            save_offset(offset);
            // ensure heartbeat count resets
            heartbeat_count = 0;
        }

        if (remaining_length > 0) {
            if (conn == NULL
#ifdef CONFIG_OMI_ENABLE_WIFI
                && !is_wifi_on()
#endif
            ) {
                LOG_ERR("invalid connection");
                remaining_length = 0;
                save_offset(offset);
                // save offset to flash
                continue;
                // k_yield();
            }

#ifdef CONFIG_OMI_ENABLE_WIFI
            // Send data over TCP if WiFi is ready, otherwise over GATT
            if (is_wifi_on()) {
                if (is_wifi_transport_ready()) {
                    write_to_tcp();
                    heartbeat_count = (heartbeat_count + 1) % (MAX_HEARTBEAT_FRAMES + 1);
                }
            } else
#endif
            {
                write_to_gatt(conn);
                heartbeat_count = (heartbeat_count + 1) % (MAX_HEARTBEAT_FRAMES + 1);
            }

            transport_started = 0;
            if (remaining_length == 0) {
                if (stop_started) {
                    stop_started = 0;
                } else {
                    save_offset(offset);
                    LOG_INF("Storage transfer done. Sending EOT marker (0xFD).");
                    uint8_t stop_result[1] = {EOT_MARKER};

                    int err = bt_gatt_notify(get_current_connection(), &storage_service.attrs[STORAGE_ATTR_WRITE_CHAR], &stop_result, 1);
                    if (err) {
                        LOG_ERR("Failed to send completion marker: %d", err);
                    }
                    k_msleep(10);
                }
            }
        }

        // Sleep when there's no work
        if (remaining_length == 0 && !delete_started && !nuke_started && !stop_started) {
            k_msleep(10);
        } else {
            k_yield();
        }
    }
}

int storage_init()
{
#ifdef CONFIG_OMI_ENABLE_WIFI
    k_work_init(&wifi_start_work, wifi_start_work_handler);
#endif
    k_thread_create(&storage_thread,
                    storage_stack,
                    K_THREAD_STACK_SIZEOF(storage_stack),
                    (k_thread_entry_t) storage_write,
                    NULL,
                    NULL,
                    NULL,
                    K_PRIO_PREEMPT(7),
                    0,
                    K_NO_WAIT);
    return 0;
}
