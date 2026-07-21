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
#include <zephyr/sys/reboot.h>

#include "button.h"
#include "sd_card.h"
#include "settings.h"
#include "transport.h"
#include "utils.h"

/* Framed packet types (firmware → app) */
#define PACKET_DATA 0x01  /* [0x01][offset:4LE][payload] */
#define PACKET_EOT  0x02  /* [0x02] — end of file */
#define PACKET_ACK  0x03  /* [0x03][result:1] — command response */

LOG_MODULE_REGISTER(storage, CONFIG_LOG_DEFAULT_LEVEL);

/* CMD_READ_FILE / CMD_DELETE_FILE carry the file index in a single byte, so the
 * cache must never hold more files than fit in a uint8_t.  Today MAX_AUDIO_FILES
 * is 150, well under the limit; this guard fails the build loudly if a future
 * change raises it past 255 (which would silently truncate the index — the
 * timestamp fallback mitigates but should not be relied on as the only defense). */
BUILD_ASSERT(MAX_AUDIO_FILES <= 255, "file index is a uint8_t in the BLE storage protocol");

/* Current file being read for transfer */
static char current_read_filename[MAX_FILENAME_LEN] = {0};
static uint32_t current_read_offset = 0;

#define MAX_PACKET_LENGTH 256
#define OPUS_ENTRY_LENGTH 80
#define FRAME_PREFIX_LENGTH 3

/* Control commands */
#define CMD_STOP_SYNC      0x03

/* New multi-file sync commands */
#define CMD_LIST_FILES      0x10   // Get list of audio files
#define CMD_READ_FILE       0x11   // Read specific file: [cmd][file_index][offset:4]
#define CMD_DELETE_FILE     0x12   // Delete specific file: [cmd][file_index]
#define CMD_ROTATE_FILE     0x13   // Close current recording file and open a new one
#define CMD_CLEAR_STORAGE    0x14   // Delete all audio files
#define CMD_UNPAIR           0x15   // Wipe Bluetooth pairing keys
#define CMD_REBOOT           0x16   // Cold-reboot the device (remote restart)
#define CMD_POWER_OFF        0x17   // Power off the device (ship mode; button/charger wake)
#define CMD_ARM_POST_DFU_UNPAIR 0x18 // [0x18, arm]: arm(1)/disarm(0) one-shot bond wipe on next new-image boot
#define CMD_SET_BACKEND      0x1A   // [0x1A, backend]: switch storage backend (0=LittleFS,1=ring), reboots to apply

#define INVALID_COMMAND 6
#define FILE_NOT_FOUND 7
#define FILE_INDEX_OUT_OF_RANGE 8
#define STORAGE_NOT_READY 9

#define MAX_HEARTBEAT_FRAMES 100
#define HEARTBEAT 50

/* Retry storage_notify up to N times on -ENOMEM, yielding between attempts.
 * Caps retries so a permanently-stuck BLE TX queue doesn't spin forever. */
#define NOTIFY_RETRY_MAX 50
#define STORAGE_NOTIFY(conn, buf, len)                                      \
    do {                                                                    \
        int _sn_err; int _sn_r = 0;                                        \
        do {                                                                \
            _sn_err = storage_notify((conn), (buf), (len));                 \
            if (_sn_err == -ENOMEM) k_yield();                              \
        } while (_sn_err == -ENOMEM && ++_sn_r < NOTIFY_RETRY_MAX);        \
        if (_sn_err && _sn_err != -EAGAIN) {                               \
            LOG_ERR("GATT notify error: %d (retries: %d)", _sn_err, _sn_r);\
        }                                                                   \
    } while (0)

/* Multi-file sync state.  Pending-request flags are atomic_t because they are
 * set on the BLE callback thread and consumed on the storage thread.  Companion
 * data fields (delete_file_*, read_request_*) are plain memory written BEFORE
 * the atomic flag is set; atomic_set provides the memory-barrier publication. */
static int current_sync_file_index = -1;
static atomic_t list_files_requested = ATOMIC_INIT(0);
static atomic_t rotate_file_requested = ATOMIC_INIT(0);
static atomic_t clear_storage_requested = ATOMIC_INIT(0);
static atomic_t reboot_requested = ATOMIC_INIT(0);
static atomic_t power_off_requested = ATOMIC_INIT(0);
static atomic_t backend_switch_requested = ATOMIC_INIT(0);
static uint8_t  backend_switch_value = 0;

static atomic_t delete_request_pending = ATOMIC_INIT(0);
static int16_t  delete_file_index = -1;
static bool     delete_file_has_ts = false;
static uint32_t delete_file_expected_ts = 0;

/* CMD_READ_FILE is deferred to the storage thread so setup_file_transfer
 * (which writes current_read_filename/offset/file_index) cannot race against
 * write_to_gatt, which reads the same fields while sending. */
static atomic_t read_request_pending = ATOMIC_INIT(0);
static uint8_t  read_request_file_index = 0;
static uint32_t read_request_offset = 0;
static bool     read_request_has_ts = false;
static uint32_t read_request_expected_ts = 0;

static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags);

static struct bt_uuid_128 storage_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295780, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_write_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295781, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_read_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295782, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static ssize_t storage_read_characteristic(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           void *buf,
                                           uint16_t len,
                                           uint16_t offset);

K_THREAD_STACK_DEFINE(storage_stack, 4096);
static struct k_thread storage_thread;

void broadcast_storage_packet(struct k_work *work_item);

static struct bt_gatt_attr storage_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&storage_service_uuid),
    BT_GATT_CHARACTERISTIC(&storage_write_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE_ENCRYPT,
                           NULL,
                           storage_write_handler,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
    BT_GATT_CHARACTERISTIC(&storage_read_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ_ENCRYPT,
                           storage_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
};

struct bt_gatt_service storage_service = BT_GATT_SERVICE(storage_service_attr);

#define STORAGE_IDLE_POLL_MS_OFFLINE    2000
#define STORAGE_IDLE_POLL_MS_CONNECTED    10

#define STORAGE_WRITE_NOTIFY_ATTR_IDX 2

bool storage_is_on = false;

static bool storage_notify_ready(struct bt_conn *conn)
{
    return conn && bt_gatt_is_subscribed(conn,
                                         &storage_service.attrs[STORAGE_WRITE_NOTIFY_ATTR_IDX],
                                         BT_GATT_CCC_NOTIFY);
}

static int storage_notify(struct bt_conn *conn, const void *data, uint16_t len)
{
    if (!storage_notify_ready(conn)) {
        return -EAGAIN;
    }

    return bt_gatt_notify(conn, &storage_service.attrs[STORAGE_WRITE_NOTIFY_ATTR_IDX], data, len);
}

static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    transport_mark_activity();

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
    /* Phone app expects (little-endian):
     *   [0..3]  total_used_bytes  (uint32)
     *   [4..7]  file_count        (uint32)
     *   [8..11] free_bytes        (uint32)  — optional, newer firmware
     *   [12..15] status_flags     (uint32)  — optional, newer firmware
     */
    uint32_t payload[4] = {0};
    payload[0] = (uint32_t)sd_get_cached_total_size(); /* total used bytes */
    payload[1] = sd_get_cached_file_count();           /* number of audio files */
    payload[2] = sd_get_cached_free_bytes();           /* free bytes remaining on SD */
    payload[3] = app_settings_get_storage_backend();   /* status_flags: low byte = active backend */
    
    LOG_INF("Storage read: used=%u bytes, files=%u, free=%u", payload[0], payload[1], payload[2]);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, payload, sizeof(payload));
}

uint8_t transport_started = 0;
#define SD_BLE_SIZE 440
#define STORAGE_READ_BATCH_SIZE 20
#define STORAGE_BUFFER_SIZE (SD_BLE_SIZE * STORAGE_READ_BATCH_SIZE + 5 * STORAGE_READ_BATCH_SIZE)  /* ~8.9KB */
static uint8_t storage_buffer[STORAGE_BUFFER_SIZE];
static atomic_t stop_started;
static atomic_t remaining_length;

#define SYNC_SPEED_LOG_INTERVAL_MS (30 * 1000)

typedef enum {
    SYNC_SPEED_MODE_NONE = 0,
    SYNC_SPEED_MODE_BLE,
} sync_speed_mode_t;

static sync_speed_mode_t sync_speed_mode = SYNC_SPEED_MODE_NONE;
static int64_t sync_speed_window_start_ms = 0;
static uint64_t sync_speed_window_bytes = 0;

static void sync_speed_reset(sync_speed_mode_t mode)
{
    sync_speed_mode = mode;
    sync_speed_window_start_ms = k_uptime_get();
    sync_speed_window_bytes = 0;
}

static void sync_speed_add_bytes(uint32_t bytes)
{
    if (sync_speed_mode == SYNC_SPEED_MODE_NONE || bytes == 0) {
        return;
    }

    sync_speed_window_bytes += bytes;
    int64_t now = k_uptime_get();
    int64_t elapsed_ms = now - sync_speed_window_start_ms;

    if (elapsed_ms >= SYNC_SPEED_LOG_INTERVAL_MS) {
        uint64_t kbps = (sync_speed_window_bytes * 1000U) / (elapsed_ms * 1024U);
        const char *mode_str = "BLE";
        LOG_INF("Sync speed (%s): %u KB/s", mode_str, (uint32_t)kbps);

        sync_speed_window_start_ms = now;
        sync_speed_window_bytes = 0;
    }
}

static uint16_t get_ble_chunk_size(struct bt_conn *conn, uint8_t include_timestamp)
{
    if (!conn) {
        return SD_BLE_SIZE;
    }

    uint16_t mtu = bt_gatt_get_mtu(conn);
    if (mtu <= 3) {
        return 20;
    }

    uint16_t att_payload = mtu - 3;
    /* Framed protocol: [PACKET_DATA(1)][offset(4)] = 5 bytes overhead */
    uint16_t protocol_overhead = include_timestamp ? 5 : 0;

    if (att_payload <= protocol_overhead + 8) {
        return 20;
    }

    uint16_t chunk = att_payload - protocol_overhead;
    return MIN(chunk, (uint16_t)SD_BLE_SIZE);
}

static uint8_t heartbeat_count = 0;



/**
 * @brief Send file list response
 * Format: [count:1][ts1:4][sz1:4][ts2:4][sz2:4]...
 *


 *
 * The currently-recording file is excluded from the response.  Syncing an
 * open write file causes contention on the sd_worker and results in
 * read_audio_data timeouts → error ACK 7.  The file will appear in the next
 * list once it has been rotated (closed).
 */
static int send_file_list_response(struct bt_conn *conn)
{
    int sync_file_count = sd_get_cached_file_count();
    if (sync_file_count == 0) {
        uint8_t zero_resp[5] = {PACKET_DATA, 0, 0, 0, 0};
        STORAGE_NOTIFY(conn, zero_resp, 5);

        uint8_t eot = PACKET_EOT;
        STORAGE_NOTIFY(conn, &eot, 1);
        return 0;
    }

    /* 
     * Standardized List Protocol: [PACKET_DATA(0x01)][count:4LE][ts1:4LE][sz1:4LE]...
     * Uses dynamic chunking to stay under MTU. Only first packet contains count.
     */
    uint16_t mtu = bt_gatt_get_mtu(conn);
    uint16_t max_payload = (mtu > 3) ? (mtu - 3) : 20;
    
    /* First packet overhead: 1 (type) + 4 (count) = 5 bytes. Entry: [idx:4][ts:4][sz:4][sid:4] = 16 bytes */
    int first_packet_max = (max_payload - 5) / 16;
    /* Subsequent packets overhead: 1 (type) = 1 byte */
    int later_packet_max = (max_payload - 1) / 16;

    int files_processed = 0;
    uint32_t total_included = 0;

    for (int i = 0; i < sync_file_count; i++) {
        AudioFileMeta_t meta;
        if (sd_get_cached_file_meta(i, &meta) == 0) {
            if (!sd_is_current_recording_file_meta(&meta)) {
                total_included++;
            }
        }
    }

    while (files_processed < sync_file_count) {
        int resp_len = 0;
        storage_buffer[resp_len++] = PACKET_DATA;

        int chunk_limit;
        if (files_processed == 0) {
            /* First packet: include the 4-byte Little-Endian count */
            storage_buffer[resp_len++] = total_included & 0xFF;
            storage_buffer[resp_len++] = (total_included >> 8) & 0xFF;
            storage_buffer[resp_len++] = (total_included >> 16) & 0xFF;
            storage_buffer[resp_len++] = (total_included >> 24) & 0xFF;
            chunk_limit = first_packet_max;
        } else {
            chunk_limit = later_packet_max;
        }

        uint8_t chunk_count = 0;
        for (; files_processed < sync_file_count && chunk_count < chunk_limit; files_processed++) {
            AudioFileMeta_t meta;
            if (sd_get_cached_file_meta(files_processed, &meta) < 0) {
                continue;
            }

            if (sd_is_current_recording_file_meta(&meta)) {
                continue;
            }

            uint32_t timestamp = meta.timestamp;
            uint32_t size = meta.file_size;
            uint32_t index = (uint32_t)files_processed;
            uint32_t session_id = meta.uptime_offset;

            /* Little-Endian for App parser - 16 byte entry: [idx:4][ts:4][sz:4][sid:4] */
            storage_buffer[resp_len++] = index & 0xFF;
            storage_buffer[resp_len++] = (index >> 8) & 0xFF;
            storage_buffer[resp_len++] = (index >> 16) & 0xFF;
            storage_buffer[resp_len++] = (index >> 24) & 0xFF;

            storage_buffer[resp_len++] = timestamp & 0xFF;
            storage_buffer[resp_len++] = (timestamp >> 8) & 0xFF;
            storage_buffer[resp_len++] = (timestamp >> 16) & 0xFF;
            storage_buffer[resp_len++] = (timestamp >> 24) & 0xFF;

            storage_buffer[resp_len++] = size & 0xFF;
            storage_buffer[resp_len++] = (size >> 8) & 0xFF;
            storage_buffer[resp_len++] = (size >> 16) & 0xFF;
            storage_buffer[resp_len++] = (size >> 24) & 0xFF;

            storage_buffer[resp_len++] = session_id & 0xFF;
            storage_buffer[resp_len++] = (session_id >> 8) & 0xFF;
            storage_buffer[resp_len++] = (session_id >> 16) & 0xFF;
            storage_buffer[resp_len++] = (session_id >> 24) & 0xFF;

            chunk_count++;
        }

        if (chunk_count > 0 || (files_processed == sync_file_count && total_included == 0)) {
            STORAGE_NOTIFY(conn, storage_buffer, resp_len);
            k_msleep(15); /* Small gap for BLE stability */
        }
    }

    uint8_t eot = PACKET_EOT;
    STORAGE_NOTIFY(conn, &eot, 1);

    return 0;
}


/**
 * @brief Setup transfer for specific file by index
 */
static int setup_file_transfer(int file_index, uint32_t start_offset, bool has_ts, uint32_t expected_ts)
{
    AudioFileMeta_t meta;
    int actual_idx = file_index;

    /* Clean state for new transfer */
    atomic_clear(&remaining_length);
    atomic_clear(&stop_started);

    if (has_ts) {
        if (sd_get_cached_file_meta(file_index, &meta) == 0 &&
            meta.timestamp == expected_ts) {
            /* Index still valid */
            actual_idx = file_index;
        } else {
            /* Index shifted - scan for timestamp */
            actual_idx = -1;
            int count = sd_get_cached_file_count();
            for (int i = 0; i < count; i++) {
                if (sd_get_cached_file_meta(i, &meta) == 0 &&
                    meta.timestamp == expected_ts) {
                    actual_idx = i;
                    LOG_WRN("Read: index shifted %d -> %d (ts=%u)", file_index, i, expected_ts);
                    break;
                }
            }
        }
    }

    if (actual_idx < 0 || sd_get_cached_file_meta(actual_idx, &meta) < 0) {
        LOG_ERR("File not found for transfer (idx=%d, ts=%u)", file_index, expected_ts);
        return -1;
    }

    // Reconstruct the %08X string just-in-time for LittleFS to open
    build_filename_from_meta(&meta, current_read_filename, sizeof(current_read_filename));

    current_read_offset = start_offset;
    current_sync_file_index = actual_idx;    
    if (current_read_offset < meta.file_size) {
        atomic_set(&remaining_length, meta.file_size - current_read_offset);
    } else {
        atomic_clear(&remaining_length);
    }

    LOG_INF("Setup transfer: file[%d]=%s, offset=%u, remaining=%u",
            file_index, current_read_filename, current_read_offset, (uint32_t)atomic_get(&remaining_length));
    return 0;
}


/**
 * @brief Delete specific file by index
 */
static int delete_file_by_index(int file_index)
{
    AudioFileMeta_t meta;

    if (sd_get_cached_file_meta(file_index, &meta) < 0) {
        return -1;
    }

    /* Copy target filename so we are robust to list refreshes */
    char target_name[MAX_FILENAME_LEN] = {0};
    build_filename_from_meta(&meta, target_name, sizeof(target_name));

    /* Delegate deletion to SD worker so it can safely handle
     * the case where this is the currently-recording file. */
    int ret = delete_audio_file(target_name);
    if (ret < 0) {
        LOG_ERR("Failed to delete file[%d]: %s (err=%d)", file_index, target_name, ret);
        return ret;
    }

    LOG_INF("Deleted file[%d]: %s", file_index, target_name);
    
    /* We don't modify the cache here, SD worker handles invalidating the cache. */
    
    return 0;
}


static volatile bool storage_sync_session_active = false;

void storage_start_sync_session(void) {
    storage_sync_session_active = true;
    LOG_INF("Storage Sync Session: STARTED (indices frozen)");
}

void storage_stop_sync_session(void) {
    storage_sync_session_active = false;
    LOG_INF("Storage Sync Session: ENDED (indices unfrozen)");
}

bool is_storage_sync_active(void) {
    return storage_sync_session_active;
}

static uint8_t parse_storage_command(void *buf, uint16_t len, struct bt_conn *conn)
{
    if (len < 1) {
        return INVALID_COMMAND;
    }

    const uint8_t command = ((uint8_t *) buf)[0];
    LOG_INF("Storage command: 0x%02X, len=%d", command, len);

    /* ===== NEW MULTI-FILE COMMANDS ===== */

    if (command == CMD_LIST_FILES) {
        storage_start_sync_session();
        atomic_set(&list_files_requested, 1);
        return 0xFF;  /* Storage thread will send its own response */
    }

    if (command == CMD_STOP_SYNC) {
        storage_stop_sync_session();
        storage_stop_transfer();
        return 0;
    }

    if (command == CMD_READ_FILE) {
        if (len < 2) return INVALID_COMMAND;

        uint8_t file_index = ((uint8_t *) buf)[1];
        uint32_t request_offset = 0;
        uint32_t expected_ts = 0;
        bool has_ts = (len >= 10);

        if (len >= 6) {
            /* Little-endian offset to match the rest of the BLE protocol */
            request_offset = ((uint8_t *) buf)[2]
                           | ((uint8_t *) buf)[3] << 8
                           | ((uint8_t *) buf)[4] << 16
                           | (uint32_t)((uint8_t *) buf)[5] << 24;
        }

        if (has_ts) {
            expected_ts = ((uint8_t *) buf)[6]
                        | ((uint8_t *) buf)[7] << 8
                        | ((uint8_t *) buf)[8] << 16
                        | (uint32_t)((uint8_t *) buf)[9] << 24;
        }

        /* Stage params, then publish via atomic flag.  Running setup_file_transfer
         * on the storage thread means it cannot race write_to_gatt's reads of
         * current_read_filename/offset/file_index. */
        read_request_file_index = file_index;
        read_request_offset = request_offset;
        read_request_has_ts = has_ts;
        read_request_expected_ts = expected_ts;
        atomic_set(&read_request_pending, 1);
        return 0xFF;  /* Storage thread will ACK after setup completes */
    }

    if (command == CMD_DELETE_FILE) {
        if (len < 2) return INVALID_COMMAND;

        uint8_t file_index = ((uint8_t *) buf)[1];

        /* Extended form: [0x12][index][ts:4LE] — app supplies the timestamp it
         * received in CMD_LIST_FILES so the storage thread can verify the index
         * still points to the same file after a cache refresh. */
        bool has_ts = (len >= 6);
        uint32_t expected_ts = 0;
        if (has_ts) {
            const uint8_t *b = (const uint8_t *) buf;
            expected_ts = (uint32_t)b[2]
                        | (uint32_t)b[3] << 8
                        | (uint32_t)b[4] << 16
                        | (uint32_t)b[5] << 24;
        }

        /* Stage params, then publish via atomic flag. */
        delete_file_index = file_index;
        delete_file_has_ts = has_ts;
        delete_file_expected_ts = expected_ts;
        atomic_set(&delete_request_pending, 1);
        return 0xFF;
    }

    if (command == CMD_ROTATE_FILE) {
        /* Defer to storage thread so create_new_audio_file() runs on the SD worker context. */
        atomic_set(&rotate_file_requested, 1);
        return 0xFF;  /* ACK sent by storage thread after rotation completes */
    }

    if (command == CMD_UNPAIR) {
        LOG_INF("CMD_UNPAIR: received unpair command, wiping all OS bonds");
        bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY);
        return 0;
    }

    if (command == CMD_REBOOT) {
        /* Defer to the storage thread so we can ACK before the link drops on the
         * cold reboot; sys_reboot() never returns. */
        LOG_INF("CMD_REBOOT: received reboot command");
        atomic_set(&reboot_requested, 1);
        return 0xFF;  /* ACK + reboot handled by storage thread */
    }

    if (command == CMD_POWER_OFF) {
        /* Defer to the storage thread so we can ACK before turnoff_all() tears
         * down BLE; it ends in sys_poweroff() and never returns. */
        LOG_INF("CMD_POWER_OFF: received power-off command");
        atomic_set(&power_off_requested, 1);
        return 0xFF;  /* ACK + power-off handled by storage thread */
    }

    if (command == CMD_ARM_POST_DFU_UNPAIR) {
        /* [0x18][arm]: arm(1)/disarm(0) the one-shot post-update bond wipe.
         * Require the explicit arm byte — fail closed on a short/malformed write
         * rather than silently arming a destructive wipe (the app always sends 2
         * bytes). Arming records the current firmware version; the wipe fires on
         * the first boot of a DIFFERENT version (see transport_start). NVS write
         * ACK'd inline like the other config writes. */
        if (len < 2) {
            return INVALID_COMMAND;
        }
        uint8_t arm = ((uint8_t *) buf)[1] ? 1 : 0;
        int err = app_settings_arm_post_dfu_unpair(arm, CONFIG_BT_DIS_FW_REV_STR);
        LOG_INF("CMD_ARM_POST_DFU_UNPAIR: %s", arm ? "armed" : "disarmed");
        return err ? 1 : 0;  /* non-zero ACK signals a persist failure to the client */
    }

    if (command == CMD_SET_BACKEND) {
        /* [0x1A][backend]: persist the storage backend and reboot to apply it.
         * The reboot re-runs boot, which mounts the selected backend or formats
         * the SD to it on first use (the one-time wipe). Fail-closed on a short
         * write. The app should sync everything first — switching reformats. */
        if (len < 2) {
            return INVALID_COMMAND;
        }
        backend_switch_value = ((uint8_t *) buf)[1];
        atomic_set(&backend_switch_requested, 1);
        return 0xFF; /* storage thread saves + reboots */
    }

    if (command == CMD_CLEAR_STORAGE) {
        /* CMD_CLEAR_STORAGE (0x14) - defer wipe to storage thread to prevent GATT 133 */
        atomic_set(&clear_storage_requested, 1);
        return 0xFF;
    }

    if (command == HEARTBEAT) {
        heartbeat_count = 0;
        return 0;
    }

    /* Accept only multi-file protocol commands above. */
    return INVALID_COMMAND;
}

static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags)
{
    transport_mark_activity();

    if (len < 1) {
        uint8_t ack[2] = {PACKET_ACK, INVALID_COMMAND};
        LOG_WRN("storage write with empty payload");
        storage_notify(conn, ack, sizeof(ack));
        return len;
    }

    LOG_INF("storage cmd: 0x%02X len=%d", ((uint8_t *) buf)[0], len);

    uint8_t result = parse_storage_command((void *)buf, len, conn);

    /* 0xFF means the storage thread will send its own response (list/delete) */
    if (result != 0xFF) {
        uint8_t ack[2] = {PACKET_ACK, result};
        STORAGE_NOTIFY(conn, ack, sizeof(ack));
    }

    return len;
}

/*
 * Batch-read buffer for BLE sync: reuse storage_buffer (4450 bytes).
 * Only need a small separate buffer for building BLE notifications.
 */
#define BLE_BATCH_PACKETS 20
/* [PACKET_DATA(1)][offset:4LE] + payload */
static uint8_t ble_notify_buf[5 + SD_BLE_SIZE];

static void write_to_gatt(struct bt_conn *conn)
{
    transport_mark_activity();

    int err;
    if (sync_speed_mode != SYNC_SPEED_MODE_BLE) {
        sync_speed_reset(SYNC_SPEED_MODE_BLE);
    }
    uint16_t ble_chunk = get_ble_chunk_size(conn, current_sync_file_index >= 0);
    
    if (current_sync_file_index < 0) {
        LOG_ERR("write_to_gatt called without active multi-file transfer");
        atomic_clear(&remaining_length);
        return;
    }

    /*
     * Framed protocol: [PACKET_DATA(1)][offset:4LE][payload]
     *
     * Multi-batch send loop: keep reading+sending until BLE TX buffers
     * saturate or we run out of data. Keeps BLE running at full
     * connection-event throughput instead of one batch per main-loop tick.
     */
    while (atomic_get(&remaining_length) > 0) {
        if (atomic_get(&stop_started)) {
            atomic_clear(&remaining_length);
            return;
        }

        uint32_t rem = (uint32_t)atomic_get(&remaining_length);
        uint32_t batch_audio_size = MIN(rem, (uint32_t)(ble_chunk * BLE_BATCH_PACKETS));
        if (batch_audio_size > STORAGE_BUFFER_SIZE) {
            batch_audio_size = STORAGE_BUFFER_SIZE;
        }

        int r = read_audio_data(current_read_filename, storage_buffer, batch_audio_size, current_read_offset);
        if (r <= 0) {
            LOG_ERR("Failed to read audio data: %d", r);
            atomic_clear(&remaining_length);
            /* Notify app so it aborts immediately instead of waiting for timeout. */
            uint8_t err_ack[2] = {PACKET_ACK, FILE_NOT_FOUND};
            STORAGE_NOTIFY(conn, err_ack, sizeof(err_ack));
            return;
        }
        uint32_t bytes_read = (uint32_t)r;
        uint32_t bytes_sent = 0;

        while (bytes_sent < bytes_read && atomic_get(&remaining_length) > 0) {
            /* Verify connection is still alive before every batch */
            struct bt_conn *valid_conn = get_current_connection();
            if (!valid_conn) {
                LOG_ERR("BLE disconnected during GATT write loop");
                atomic_clear(&remaining_length);
                return;
            }
            if (valid_conn != conn) {
                put_current_connection(valid_conn);
                LOG_ERR("BLE connection changed during GATT write loop");
                atomic_clear(&remaining_length);
                return;
            }

            if (atomic_get(&stop_started)) {
                put_current_connection(valid_conn);
                atomic_clear(&remaining_length);
                return;
            }

            uint32_t chunk = MIN(bytes_read - bytes_sent, ble_chunk);

            /* Build framed header: [PACKET_DATA][offset:4LE] */
            uint32_t pkt_offset = current_read_offset;
            ble_notify_buf[0] = PACKET_DATA;
            ble_notify_buf[1] =  pkt_offset        & 0xFF;
            ble_notify_buf[2] = (pkt_offset >>  8) & 0xFF;
            ble_notify_buf[3] = (pkt_offset >> 16) & 0xFF;
            ble_notify_buf[4] = (pkt_offset >> 24) & 0xFF;
            memcpy(ble_notify_buf + 5, storage_buffer + bytes_sent, chunk);

            err = storage_notify(valid_conn, ble_notify_buf, 5 + chunk);
            put_current_connection(valid_conn);

            if (err == -ENOMEM) {
                /* TX buffers full — yield and wait for next connection event */
                k_yield();
                continue;
            }
            if (err == -EAGAIN) {
                return;
            }
            if (err && err != -ENOMEM) {
                LOG_ERR("GATT notify error: %d", err);
                return;
            }

            bytes_sent += chunk;
            sync_speed_add_bytes(chunk);
            current_read_offset += chunk;
            atomic_sub(&remaining_length, chunk);
        }
    }
}

void storage_stop_transfer()
{
    atomic_clear(&remaining_length);
    atomic_set(&stop_started, 1);
}

bool storage_transfer_active(void)
{
    return (atomic_get(&remaining_length) > 0) || (transport_started != 0);
}

void storage_write(void)
{
    while (1) {
        struct bt_conn *conn = get_current_connection();

        /* CMD_READ_FILE: deferred setup_file_transfer runs here on the storage
         * thread, so it cannot race write_to_gatt's reads of the same state. */
        if (atomic_cas(&read_request_pending, 1, 0)) {
            uint8_t  file_index   = read_request_file_index;
            uint32_t request_off  = read_request_offset;
            bool     has_ts       = read_request_has_ts;
            uint32_t expected_ts  = read_request_expected_ts;

            int res = setup_file_transfer(file_index, request_off, has_ts, expected_ts);
            uint8_t result = (res < 0) ? FILE_NOT_FOUND : 0;
            if (conn) {
                uint8_t ack[2] = {PACKET_ACK, result};
                STORAGE_NOTIFY(conn, ack, sizeof(ack));
            }
            if (res >= 0) {
                transport_started = 1;
                /* Transfer is now active (remaining_length > 0): switch the diagnostics
                 * notify cadence to 2 s at once instead of waiting out the 15 s idle
                 * interval, so live counters update promptly during the sync. */
                transport_diagnostics_kick();
            }
        }

        if (transport_started) {

            LOG_INF("transport started in side : %d", transport_started);
            sync_speed_mode = SYNC_SPEED_MODE_NONE;
            sync_speed_window_bytes = 0;
            sync_speed_window_start_ms = 0;
            if (current_sync_file_index < 0) {
                LOG_ERR("Transfer start requested without CMD_READ_FILE setup");
                atomic_clear(&remaining_length);
            }
            transport_started = 0;  /* Clear flag after setup */

            /* Offset was already at or past EOF — send EOT now so the host can
             * proceed to the DELETE command (deletion-retry path). */
            if (atomic_get(&remaining_length) == 0 && current_sync_file_index >= 0 && conn != NULL) {
                uint8_t eot[1] = {PACKET_EOT};
                STORAGE_NOTIFY(conn, eot, sizeof(eot));
                k_msleep(250);
            }
        }
        if (atomic_cas(&list_files_requested, 1, 0)) {


            /* Handshake: Wait for SD card boot init to finish (mount + pre-warm).
             * This ensures the app always gets a definitive list and prevents ACK 7. */
            int wait_retries = 100; // 10 seconds total (App timeout is usually 10s)
            while (!sd_is_boot_ready() && wait_retries > 0) {
                k_msleep(100);
                wait_retries--;
            }

            if (!sd_is_boot_ready()) {
                LOG_WRN("CMD_LIST_FILES: SD card still busy after 10s, aborting");
                if (conn) {
                    uint8_t ack[2] = {PACKET_ACK, STORAGE_NOT_READY};
                    STORAGE_NOTIFY(conn, ack, sizeof(ack));
                }
                continue;
            }

            /* Wait for any in-flight TMP→UTC rename to complete so the list
             * never returns uptime-stamped entries to the app. */
            int rename_wait = 20; /* 2 s max (20 × 100 ms) */
            while (sd_is_timesync_rename_pending() && rename_wait-- > 0) {
                k_msleep(100);
            }
            if (sd_is_timesync_rename_pending()) {
                LOG_WRN("CMD_LIST_FILES: timesync rename still pending after 2s, listing anyway");
            }

            if (conn) {
                /* Force a fresh enumeration before building the response. Rotations
                 * during the previous session skip their invalidation to keep frozen
                 * indices stable, so the cache (and get_audio_file_stats()'s 30 s TTL)
                 * can be stale; this blocking SD-worker invalidate makes the list
                 * authoritative. get_audio_file_stats() then dispatches
                 * REQ_GET_FILE_STATS -> ensure_file_cache() to rebuild. */
                sd_invalidate_file_cache_blocking();
                uint32_t dummy_count;
                uint64_t dummy_size;
                get_audio_file_stats(&dummy_count, &dummy_size);
                send_file_list_response(conn);
            }
        }
        if (atomic_cas(&delete_request_pending, 1, 0)) {

            int16_t idx = delete_file_index;
            bool has_ts = delete_file_has_ts;
            uint32_t expected_ts = delete_file_expected_ts;
            delete_file_index = -1;
            delete_file_has_ts = false;

            /* Refresh the file cache before checking bounds or resolving the filename.
             * A rotation or time-sync rename between CMD_LIST_FILES and CMD_DELETE_FILE
             * can call invalidate_file_cache(), leaving the cache stale. */
            uint32_t dummy_count;
            uint64_t dummy_size;
            get_audio_file_stats(&dummy_count, &dummy_size);

            /* Resolve the target index using the timestamp supplied by the app.
             * If the app sent a timestamp and the cached entry at idx no longer
             * matches, scan the full cache for the right file — the index may have
             * shifted due to a rotation or earlier deletion. */
            int delete_idx = idx;
            if (has_ts) {
                AudioFileMeta_t meta;
                if (sd_get_cached_file_meta(idx, &meta) == 0 &&
                    meta.timestamp == expected_ts) {
                    /* Fast path: index still valid. */
                    delete_idx = idx;
                } else {
                    /* Index shifted — scan for matching timestamp. */
                    delete_idx = -1;
                    int count = sd_get_cached_file_count();
                    for (int i = 0; i < count; i++) {
                        if (sd_get_cached_file_meta(i, &meta) == 0 &&
                            meta.timestamp == expected_ts) {
                            delete_idx = i;
                            LOG_WRN("Delete: index shifted %d -> %d (ts=%u)", idx, i, expected_ts);
                            break;
                        }
                    }
                }
            }

            uint8_t result = 0;
            if (delete_idx < 0) {
                LOG_ERR("Delete: file with ts=%u not found in cache", expected_ts);
                result = FILE_NOT_FOUND;
            } else if (delete_idx >= sd_get_cached_file_count()) {
                result = FILE_INDEX_OUT_OF_RANGE;
            } else if (delete_file_by_index(delete_idx) < 0) {
                result = FILE_NOT_FOUND;
            }

            if (conn) {
                uint8_t ack[2] = {PACKET_ACK, result};
                STORAGE_NOTIFY(conn, ack, sizeof(ack));
            }
            LOG_INF("Delete file[%d] (ts=%u) result: %d", idx, expected_ts, result);
        }
        if (atomic_cas(&clear_storage_requested, 1, 0)) {

            int ret = clear_audio_directory();
            if (conn) {
                uint8_t result = (ret >= 0) ? 0 : 1;
                uint8_t ack[2] = {PACKET_ACK, result};
                STORAGE_NOTIFY(conn, ack, sizeof(ack));
            }
            LOG_INF("CMD_CLEAR_STORAGE: SD card wiped, ret=%d", ret);
        }
        if (atomic_cas(&rotate_file_requested, 1, 0)) {

            /* create_new_audio_file() closes the current file and opens a new one.
             * It blocks until the SD worker has completed the rotation, so the ACK
             * is only sent after the old file is fully sealed and the new one is open.
             * The app can safely call CMD_LIST_FILES immediately after the ACK. */
            int ret = create_new_audio_file();
            if (conn) {
                uint8_t result = (ret >= 0) ? 0 : 1;
                uint8_t ack[2] = {PACKET_ACK, result};
                STORAGE_NOTIFY(conn, ack, sizeof(ack));
                LOG_INF("CMD_ROTATE_FILE: new file created, ret=%d", ret);
            }
        }
        if (atomic_cas(&reboot_requested, 1, 0)) {
            /* ACK before the reboot drops the link. Gracefully close the SD card
             * first (app_sd_off() flushes + unmounts via the SD worker) so a
             * reboot landing mid-write doesn't tear an in-progress block; then let
             * the ACK notify flush before the cold reboot, which never returns.
             * Gate only on is_sd_on(): app_sd_off() internally guards on the mount
             * + worker state, so boot-readiness is the wrong gate here — it would
             * skip the flush in the on-but-not-yet-boot-ready window. */
            if (conn) {
                uint8_t ack[2] = {PACKET_ACK, 0};
                STORAGE_NOTIFY(conn, ack, sizeof(ack));
            }
            LOG_INF("CMD_REBOOT: rebooting now");
            if (is_sd_on()) {
                app_sd_off();
            }
            k_msleep(500);
            sys_reboot(SYS_REBOOT_COLD);
        }
        if (atomic_cas(&power_off_requested, 1, 0)) {
            /* ACK before turnoff_all() shuts down BLE and the SoC. It does a
             * graceful teardown (LED/haptic/mic/SD/accel off) and then
             * sys_poweroff(); the device only wakes on a button press or charger.
             * turnoff_all() has its own settle delays, so beyond letting the ACK
             * flush there's no extra sleep needed. */
            if (conn) {
                uint8_t ack[2] = {PACKET_ACK, 0};
                STORAGE_NOTIFY(conn, ack, sizeof(ack));
            }
            LOG_INF("CMD_POWER_OFF: powering off now");
            k_msleep(500);
            /* Normally never returns. TURNOFF_ALREADY = another context (e.g. a
             * physical 4-tap-hold) is already powering off, so just fall through
             * and let it finish. TURNOFF_BAILED = the hardware teardown couldn't
             * complete (after transport_off()/mic_off() ran), leaving the device
             * unreachable over BLE — cold-reboot to recover rather than limp on. */
            if (turnoff_all() == TURNOFF_BAILED) {
                LOG_ERR("CMD_POWER_OFF: turnoff_all() bailed — rebooting to recover");
                k_msleep(100);  /* let the error log flush before the cold reboot */
                sys_reboot(SYS_REBOOT_COLD);
            }
        }
        if (atomic_cas(&backend_switch_requested, 1, 0)) {
            /* Persist the new backend and cold-reboot so boot mounts (or formats
             * to) the selected backend. ACK before the link drops. */
            uint8_t val = backend_switch_value;
            int serr = app_settings_save_storage_backend(val);
            if (conn) {
                uint8_t ack[2] = {PACKET_ACK, serr ? 1 : 0};
                STORAGE_NOTIFY(conn, ack, sizeof(ack));
            }
            LOG_INF("CMD_SET_BACKEND: backend=%u saved=%d — rebooting to apply", val, serr);
            if (serr == 0) {
                if (is_sd_on()) {
                    app_sd_off(); /* flush + unmount cleanly first */
                }
                k_msleep(500);
                sys_reboot(SYS_REBOOT_COLD);
            }
        }
        if (atomic_get(&stop_started)) {
            atomic_clear(&remaining_length);
            atomic_clear(&stop_started);
            save_offset(current_read_filename, current_read_offset);
        }
        if (heartbeat_count == MAX_HEARTBEAT_FRAMES) {
            LOG_INF("no heartbeat sent");
            save_offset(current_read_filename, current_read_offset);
            // ensure heartbeat count resets
            heartbeat_count = 0;
        }

        if (atomic_get(&remaining_length) > 0) {
            if (conn == NULL) {
                LOG_ERR("invalid connection");
                atomic_clear(&remaining_length);
                save_offset(current_read_filename, current_read_offset);
                // save offset to flash
                put_current_connection(conn);
                continue;
                // k_yield();
            }

            write_to_gatt(conn);
            heartbeat_count = (heartbeat_count + 1) % (MAX_HEARTBEAT_FRAMES + 1);

            if (atomic_get(&remaining_length) == 0) {
                if (atomic_get(&stop_started)) {
                    atomic_clear(&stop_started);
                } else {
                    save_offset(current_read_filename, current_read_offset);
                    LOG_INF("File done: %s", current_read_filename);

                    /* Clear saved offset since file sync is complete */
                    save_offset("", 0);

                    /* Notify app: file transfer complete (PACKET_EOT) */
                    LOG_INF("File sync complete, sending EOT: %s", current_read_filename);
                    uint8_t eot[1] = {PACKET_EOT};
                    struct bt_conn *eot_conn = get_current_connection();
                    if (eot_conn) {
                        STORAGE_NOTIFY(eot_conn, eot, sizeof(eot));
                    }
                    put_current_connection(eot_conn);
                    k_msleep(250);
                }
            }
        }

        put_current_connection(conn);

        /* Sleep when there is genuinely no work pending */
        if (atomic_get(&remaining_length) == 0 && !atomic_get(&stop_started) &&
            !atomic_get(&list_files_requested) && !atomic_get(&delete_request_pending) &&
            !atomic_get(&rotate_file_requested) && !atomic_get(&clear_storage_requested) &&
            !atomic_get(&reboot_requested) && !atomic_get(&power_off_requested) &&
            !atomic_get(&backend_switch_requested) &&
            !atomic_get(&read_request_pending)) {
            struct bt_conn *idle_conn = get_current_connection();
            uint32_t idle_sleep_ms = idle_conn
                ? STORAGE_IDLE_POLL_MS_CONNECTED
                : STORAGE_IDLE_POLL_MS_OFFLINE;
            put_current_connection(idle_conn);
            k_msleep(idle_sleep_ms);
        } else {
            k_yield();
        }
    }
}

int storage_init()
{
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
