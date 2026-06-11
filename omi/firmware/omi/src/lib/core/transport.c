#include "transport.h"

#include <hal/nrf_power.h>
#include <math.h> // For float conversion in logs
#include <stdint.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/dt-bindings/gpio/nordic-nrf-gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>
#include <zephyr/random/random.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/ring_buffer.h>
#include "speaker.h"

#include "accel.h"
#include "button.h"
#include "config.h"
#include "features.h"
#include "haptic.h"
#include "mic.h"
#include "lib/battery/battery.h"
#ifdef CONFIG_OMI_ENABLE_MONITOR
#include "monitor.h"
#endif
#include "codec.h"
#include "sd_card.h"
#include "settings.h"
#include "storage.h"
#include "rtc.h"

LOG_MODULE_REGISTER(transport, CONFIG_LOG_DEFAULT_LEVEL);

#ifdef CONFIG_OMI_ENABLE_RFSW_CTRL
static const struct gpio_dt_spec rfsw_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(rfsw_en_pin), gpios, {0});
#endif

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
extern struct bt_gatt_service storage_service;
extern bool storage_is_on;
static bool storage_full_warned = false;
#endif

extern bool is_connected;
extern bool is_charging;
static atomic_t pusher_stop_flag;

struct bt_conn *current_connection = NULL;
static K_MUTEX_DEFINE(conn_mutex);
uint16_t current_mtu = 0;
uint16_t current_packet_index = 0;

#ifdef CONFIG_OMI_ENABLE_SPEAKER
static ssize_t audio_data_write_handler(struct bt_conn *conn,
                                        const struct bt_gatt_attr *attr,
                                        const void *buf,
                                        uint16_t len,
                                        uint16_t offset,
                                        uint8_t flags);
#endif

static struct bt_conn_cb _callback_references;
static ssize_t settings_dim_ratio_write_handler(struct bt_conn *conn,
                                                const struct bt_gatt_attr *attr,
                                                const void *buf,
                                                uint16_t len,
                                                uint16_t offset,
                                                uint8_t flags);
static ssize_t settings_dim_ratio_read_handler(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset);
static ssize_t settings_mic_gain_write_handler(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               const void *buf,
                                               uint16_t len,
                                               uint16_t offset,
                                               uint8_t flags);
static ssize_t settings_mic_gain_read_handler(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset);
static ssize_t settings_vad_threshold_write_handler(struct bt_conn *conn,
                                                    const struct bt_gatt_attr *attr,
                                                    const void *buf,
                                                    uint16_t len,
                                                    uint16_t offset,
                                                    uint8_t flags);
static ssize_t settings_vad_threshold_read_handler(struct bt_conn *conn,
                                                   const struct bt_gatt_attr *attr,
                                                   void *buf,
                                                   uint16_t len,
                                                   uint16_t offset);
static ssize_t
features_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset);

// Forward declarations for update functions and callbacks
static void update_phy(struct bt_conn *conn);
static void update_data_length(struct bt_conn *conn);
static void update_mtu(struct bt_conn *conn);
static void exchange_func(struct bt_conn *conn, uint8_t att_err, struct bt_gatt_exchange_params *params);

// --- GATT Exchange MTU Params ---
static struct bt_gatt_exchange_params exchange_params;

// --- Settings Service ---
static struct bt_uuid_128 settings_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10010, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 settings_dim_ratio_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10011, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 settings_mic_gain_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10012, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 settings_vad_threshold_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10013, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static struct bt_gatt_attr settings_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&settings_service_uuid),
    BT_GATT_CHARACTERISTIC(&settings_dim_ratio_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
                           settings_dim_ratio_read_handler,
                           settings_dim_ratio_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&settings_mic_gain_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
                           settings_mic_gain_read_handler,
                           settings_mic_gain_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&settings_vad_threshold_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
                           settings_vad_threshold_read_handler,
                           settings_vad_threshold_write_handler,
                           NULL),
};

static struct bt_gatt_service settings_service = BT_GATT_SERVICE(settings_service_attr);

// --- Features Service ---
static struct bt_uuid_128 features_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10020, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 features_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10021, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 features_codec_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10022, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static ssize_t audio_codec_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset)
{
    uint8_t value[1] = {CODEC_ID};
    LOG_DBG("audio_codec_read_characteristic %d", CODEC_ID);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, sizeof(value));
}

static struct bt_gatt_attr features_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&features_service_uuid),
    BT_GATT_CHARACTERISTIC(&features_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           features_read_handler,
                           NULL,
                           NULL),
    BT_GATT_CHARACTERISTIC(&features_codec_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           audio_codec_read_characteristic,
                           NULL,
                           NULL),
};

static struct bt_gatt_service features_service = BT_GATT_SERVICE(features_service_attr);

// --- Time Sync Service ---
// Service UUID: 19B10030-E8F2-537E-4F6C-D104768A1214
// Characteristics:
//   - Time Write (19B10031): Write 4 bytes (uint32_t epoch_s) to sync time
//   - Time Read  (19B10032): Read 4 bytes (uint32_t epoch_s) current device time
static struct bt_uuid_128 time_sync_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10030, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 time_sync_write_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10031, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 time_sync_read_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10032, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static ssize_t time_sync_write_handler(struct bt_conn *conn,
                                       const struct bt_gatt_attr *attr,
                                       const void *buf,
                                       uint16_t len,
                                       uint16_t offset,
                                       uint8_t flags)
{
    if (len != sizeof(uint32_t)) {
        LOG_WRN("Invalid length for time sync write: %u (expected %u)", len, sizeof(uint32_t));
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint32_t epoch_s;
    memcpy(&epoch_s, buf, sizeof(epoch_s));

    LOG_INF("Time sync received: %u seconds", epoch_s);

    int err = rtc_set_utc_time((uint64_t)epoch_s);
    if (err) {
        LOG_ERR("Failed to set RTC time: %d", err);
        return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
    }

    LOG_INF("Time synchronized successfully");
    return len;
}

static ssize_t time_sync_read_handler(struct bt_conn *conn,
                                      const struct bt_gatt_attr *attr,
                                      void *buf,
                                      uint16_t len,
                                      uint16_t offset)
{
    uint32_t epoch_s = get_utc_time();
    LOG_INF("Time sync read: %u seconds", epoch_s);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &epoch_s, sizeof(epoch_s));
}

static struct bt_gatt_attr time_sync_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&time_sync_service_uuid),
    BT_GATT_CHARACTERISTIC(&time_sync_write_characteristic_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           time_sync_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&time_sync_read_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           time_sync_read_handler,
                           NULL,
                           NULL),
};

static struct bt_gatt_service time_sync_service = BT_GATT_SERVICE(time_sync_service_attr);

// --- Battery Detail Service ---
// Service UUID: 19B10050-E8F2-537E-4F6C-D104768A1214
// Characteristics:
//   - Battery Detail (19B10051): Notify 1 byte [charging]
#ifdef CONFIG_OMI_ENABLE_BATTERY
static void battery_detail_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t battery_detail_read_handler(struct bt_conn *conn,
                                          const struct bt_gatt_attr *attr,
                                          void *buf,
                                          uint16_t len,
                                          uint16_t offset)
{
    uint8_t value = (uint8_t)is_charging;

    return bt_gatt_attr_read(conn, attr, buf, len, offset, &value, sizeof(value));
}

static struct bt_uuid_128 battery_detail_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10050, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 battery_detail_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10051, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static struct bt_gatt_attr battery_detail_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&battery_detail_service_uuid),
    BT_GATT_CHARACTERISTIC(&battery_detail_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           battery_detail_read_handler,
                           NULL,
                           NULL),
    BT_GATT_CCC(battery_detail_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
};

static struct bt_gatt_service battery_detail_service = BT_GATT_SERVICE(battery_detail_service_attr);
#endif

/* Diagnostics: count 440-byte storage block flushes the SD queue rejected.
 * Each rejected block contains up to ~5 Opus frames (~100 ms audio).
 * Bumped from write_custom_packet_to_storage(); read via 0x19B10062. */
static atomic_t storage_block_drops = ATOMIC_INIT(0);
static atomic_t last_storage_drop_uptime_ms = ATOMIC_INIT(0);

/* Diagnostics: BLE connection-establishment failures (NOTES.md: "BLE: advertising
 * but won't connect"). _transport_connected fires with err set when a central sent
 * CONNECT_IND but the link failed to establish (HCI 0x3e). Pairing the count with the
 * advertising mode in effect tells us whether the "visible but unconnectable until
 * reboot" failures correlate with slow (1 s) advertising vs a controller/RF wedge.
 * RTT/UART log only — no BLE characteristic. */
static atomic_t failed_conn_count = ATOMIC_INIT(0);
static const char *current_adv_mode = "fast"; /* boot + post-disconnect both start fast */
static uint8_t last_failed_adv_slow = 0;      /* 1 if the most recent failure was during slow adv */

/* Throttled flash persist of failed_conn_count (NOTES.md: "BLE: advertising but
 * won't connect"). The failures accrue while disconnected, and the user must
 * power-cycle to reconnect and read them, so the count is persisted to survive
 * the reboot. k_work_schedule (not reschedule) coalesces a storm into one write
 * ~CONN_FAIL_PERSIST_DELAY after the first failure — bounding flash wear while
 * keeping the persisted count current to within that window. */
#define CONN_FAIL_PERSIST_DELAY_MS 10000
static void conn_fail_persist_work_handler(struct k_work *work)
{
    app_settings_save_conn_fail((uint32_t)atomic_get(&failed_conn_count), last_failed_adv_slow);
}
static K_WORK_DELAYABLE_DEFINE(conn_fail_persist_work, conn_fail_persist_work_handler);

// --- Diagnostics Service ---
// Service UUID:       19B10060-E8F2-537E-4F6C-D104768A1214
// Characteristic A:   19B10061-E8F2-537E-4F6C-D104768A1214
// Returns 8 bytes LE: [uint32 reset_cause] [uint32 uptime_seconds]
//   reset_cause: Zephyr HWINFO bitmask for why the current boot started
//     RESET_PIN=0x01  RESET_SOFTWARE=0x02  RESET_BROWNOUT=0x04  RESET_POR=0x08
//     RESET_WATCHDOG=0x10  RESET_CPU_LOCKUP=0x100
//   uptime_seconds: how long the PREVIOUS session ran before it ended (crash or clean shutdown)
//
// Characteristic B:   19B10062-E8F2-537E-4F6C-D104768A1214
// Returns 40 bytes LE (fields appended over time; older apps read a prefix):
//   [uint32 storage_block_drops]   storage_block_drops since boot (each = ~5 Opus frames lost)
//   [uint32 last_drop_uptime_ms]   k_uptime_get() at the most recent block drop (0 = none)
//   [uint32 sd_stream_drops]       stat_dropped_frames from sd_card.c (queue-full audio frame drops)
//   [uint32 sd_boot_drops]         frames lost during SD mount/boot window
//   [uint32 current_uptime_ms]     k_uptime_get() at the moment of read
//   [uint32 conn_fails]            BLE connection-establishment failures (offset 20)
//   [uint32 last_failed_adv_slow]  1 if last conn fail was during slow adv (offset 24)
//   [uint32 codec_drops]           PCM blocks dropped before encode, ring-full (offset 28)
//   [uint32 sd_msgq_peak_depth]    high-water mark of sd_msgq occupancy / SD_REQ_QUEUE_MSGS (offset 32)
//   [uint32 write_fair_activations] times write fairness forced a write over reads (offset 36)
static struct bt_uuid_128 diagnostics_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10060, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 diagnostics_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10061, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 diagnostics_drops_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10062, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static ssize_t diagnostics_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                        void *buf, uint16_t len, uint16_t offset)
{
    uint32_t cause   = app_settings_get_last_reset_cause();
    uint32_t uptime_s = (uint32_t)(app_settings_get_crash_session_uptime() / 1000);
    uint8_t payload[8] = {
        (uint8_t)(cause),        (uint8_t)(cause >> 8),
        (uint8_t)(cause >> 16),  (uint8_t)(cause >> 24),
        (uint8_t)(uptime_s),     (uint8_t)(uptime_s >> 8),
        (uint8_t)(uptime_s >> 16),(uint8_t)(uptime_s >> 24),
    };
    return bt_gatt_attr_read(conn, attr, buf, len, offset, payload, sizeof(payload));
}

static inline void pack_u32_le(uint8_t *dst, uint32_t v)
{
    dst[0] = (uint8_t)(v);
    dst[1] = (uint8_t)(v >> 8);
    dst[2] = (uint8_t)(v >> 16);
    dst[3] = (uint8_t)(v >> 24);
}

static ssize_t diagnostics_drops_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                              void *buf, uint16_t len, uint16_t offset)
{
    uint32_t block_drops    = (uint32_t)atomic_get(&storage_block_drops);
    uint32_t last_drop_ms   = (uint32_t)atomic_get(&last_storage_drop_uptime_ms);
    uint32_t sd_stream_drops = sd_get_stream_dropped_frames();
    uint32_t sd_boot_drops   = sd_get_boot_dropped_frames();
    uint32_t now_ms         = (uint32_t)k_uptime_get();
    uint32_t conn_fails     = (uint32_t)atomic_get(&failed_conn_count);
    uint32_t codec_drops    = codec_get_dropped_frames();
    uint32_t msgq_peak      = sd_get_msgq_peak_depth();
    uint32_t fair_acts      = sd_get_write_fair_activations();

    /* 40 bytes: legacy u32 drops + conn_fail count + last-failure adv mode +
     * codec_drops + sd_msgq peak depth + write-fairness activations. Each field
     * is appended at the end so older app builds (which read only the first
     * 20 / 28 / 32 bytes) keep working unchanged. */
    uint8_t payload[40];
    pack_u32_le(payload + 0,  block_drops);
    pack_u32_le(payload + 4,  last_drop_ms);
    pack_u32_le(payload + 8,  sd_stream_drops);
    pack_u32_le(payload + 12, sd_boot_drops);
    pack_u32_le(payload + 16, now_ms);
    pack_u32_le(payload + 20, conn_fails);
    pack_u32_le(payload + 24, (uint32_t)last_failed_adv_slow);
    pack_u32_le(payload + 28, codec_drops);
    pack_u32_le(payload + 32, msgq_peak);
    pack_u32_le(payload + 36, fair_acts);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, payload, sizeof(payload));
}

static struct bt_gatt_attr diagnostics_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&diagnostics_service_uuid),
    BT_GATT_CHARACTERISTIC(&diagnostics_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           diagnostics_read_handler,
                           NULL,
                           NULL),
    /* Drops characteristic — appended last so existing diagnostics handles
     * stay stable across firmware revisions. */
    BT_GATT_CHARACTERISTIC(&diagnostics_drops_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           diagnostics_drops_read_handler,
                           NULL,
                           NULL),
};

static struct bt_gatt_service diagnostics_service = BT_GATT_SERVICE(diagnostics_service_attr);

// --- Button Service ---
// Service UUID: 23BA7924-0000-1000-7450-346EAC492E92
// Characteristics:
//   - Button Trigger (23BA7925): Notify 1 byte (0=released, 1=pressed)
static struct bt_uuid_128 button_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7924, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
static struct bt_uuid_128 button_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7925, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));

static void button_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Button notifications enabled");
    } else {
        LOG_INF("Button notifications disabled");
    }
}

static struct bt_gatt_attr button_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&button_service_uuid),
    BT_GATT_CHARACTERISTIC(&button_characteristic_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_NONE,
                           NULL,
                           NULL,
                           NULL),
    BT_GATT_CCC(button_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
};

struct bt_gatt_service button_service = BT_GATT_SERVICE(button_service_attr);

void transport_notify_button_state(uint8_t state)
{
    bt_gatt_notify(NULL, &button_service_attr[2], &state, sizeof(state));
}

// Advertisement data
static const struct bt_data bt_ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA(BT_DATA_UUID128_ALL, settings_service_uuid.val, sizeof(settings_service_uuid.val)),
    BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

// Scan response data
static const struct bt_data bt_sd[] = {
    BT_DATA_BYTES(BT_DATA_UUID16_ALL, BT_UUID_16_ENCODE(BT_UUID_DIS_VAL)),
};

//
// State and Characteristics
//

#ifdef CONFIG_OMI_ENABLE_SPEAKER
static ssize_t audio_data_write_handler(struct bt_conn *conn,
                                        const struct bt_gatt_attr *attr,
                                        const void *buf,
                                        uint16_t len,
                                        uint16_t offset,
                                        uint8_t flags)
{
    uint16_t amount = 400;
    int16_t *int16_buf = (int16_t *) buf;
    uint8_t *data = (uint8_t *) buf;
    bt_gatt_notify(conn, attr, &amount, sizeof(amount));
    amount = speak(len, buf);
    return len;
}
#endif

static ssize_t settings_dim_ratio_write_handler(struct bt_conn *conn,
                                                const struct bt_gatt_attr *attr,
                                                const void *buf,
                                                uint16_t len,
                                                uint16_t offset,
                                                uint8_t flags)
{
    if (len != 1) {
        LOG_WRN("Invalid length for dim ratio write: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t new_ratio = ((uint8_t *) buf)[0];
    if (new_ratio > 100) {
        new_ratio = 100; // Cap the value at 100
    }

    LOG_INF("Received new dim ratio: %u", new_ratio);
    int err = app_settings_save_dim_ratio(new_ratio);
    if (err) {
        LOG_ERR("Failed to save dim ratio setting: %d", err);
    }

    return len;
}

static ssize_t settings_dim_ratio_read_handler(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset)
{
    uint8_t current_ratio = app_settings_get_dim_ratio();
    LOG_INF("Reading dim ratio: %u", current_ratio);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &current_ratio, sizeof(current_ratio));
}

static ssize_t settings_mic_gain_write_handler(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               const void *buf,
                                               uint16_t len,
                                               uint16_t offset,
                                               uint8_t flags)
{
    if (len != 1) {
        LOG_WRN("Invalid length for mic gain write: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t new_gain = ((uint8_t *) buf)[0];
    if (new_gain > 8) {
        new_gain = 8; // Cap the value at level 8
    }

    LOG_INF("Received new mic gain level: %u", new_gain);
    int err = app_settings_save_mic_gain(new_gain);
    if (err) {
        LOG_ERR("Failed to save mic gain setting: %d", err);
    }

    // Apply the gain immediately
    mic_set_gain(new_gain);

    return len;
}

static ssize_t settings_mic_gain_read_handler(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset)
{
    uint8_t current_gain = app_settings_get_mic_gain();
    LOG_INF("Reading mic gain: %u", current_gain);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &current_gain, sizeof(current_gain));
}

static ssize_t settings_vad_threshold_write_handler(struct bt_conn *conn,
                                                    const struct bt_gatt_attr *attr,
                                                    const void *buf,
                                                    uint16_t len,
                                                    uint16_t offset,
                                                    uint8_t flags)
{
    if (len != 2) {
        LOG_WRN("Invalid length for VAD threshold write: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint16_t new_threshold;
    memcpy(&new_threshold, buf, 2);

    LOG_INF("Received new VAD threshold: %u", new_threshold);
    int err = app_settings_save_vad_threshold(new_threshold);
    if (err) {
        LOG_ERR("Failed to save VAD threshold setting: %d", err);
    }

    // Apply the threshold immediately
    aad_set_threshold(new_threshold);

    return len;
}

static ssize_t settings_vad_threshold_read_handler(struct bt_conn *conn,
                                                   const struct bt_gatt_attr *attr,
                                                   void *buf,
                                                   uint16_t len,
                                                   uint16_t offset)
{
    uint16_t current_threshold = app_settings_get_vad_threshold();
    LOG_INF("Reading VAD threshold: %u", current_threshold);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &current_threshold, sizeof(current_threshold));
}

static ssize_t
features_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
{
    uint32_t features = 0;

#ifdef CONFIG_OMI_ENABLE_SPEAKER
    features |= OMI_FEATURE_SPEAKER;
#endif
#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    features |= OMI_FEATURE_ACCELEROMETER;
#endif
#ifdef CONFIG_OMI_ENABLE_BUTTON
    features |= OMI_FEATURE_BUTTON;
#endif
#ifdef CONFIG_OMI_ENABLE_BATTERY
    features |= OMI_FEATURE_BATTERY;
#endif
#ifdef CONFIG_OMI_ENABLE_USB
    features |= OMI_FEATURE_USB;
#endif
#ifdef CONFIG_OMI_ENABLE_HAPTIC
    features |= OMI_FEATURE_HAPTIC;
#endif
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    features |= OMI_FEATURE_OFFLINE_STORAGE;
#endif
    // LED dimming is always enabled now with PWM.
    features |= OMI_FEATURE_LED_DIMMING;
    // Mic gain control is always enabled.
    features |= OMI_FEATURE_MIC_GAIN;
    // VAD threshold control is always enabled.
    features |= OMI_FEATURE_VAD_THRESHOLD;

    return bt_gatt_attr_read(conn, attr, buf, len, offset, &features, sizeof(features));
}

// --- MTU Update Callback ---
static void exchange_func(struct bt_conn *conn, uint8_t att_err, struct bt_gatt_exchange_params *params)
{
    if (att_err) {
        LOG_ERR("MTU exchange failed (err %u)", att_err);
    } else {
        uint16_t mtu = bt_gatt_get_mtu(conn);
        LOG_INF("MTU exchange successful. New MTU: %u (Payload: %u)", mtu, mtu - 3);
        // Update current_mtu based on the negotiated value, considering header
        // Note: bt_gatt_get_mtu includes the ATT header (3 bytes)
        current_mtu = mtu; // Store the full MTU size
    }
}

//
// Battery Service Handlers
//

#ifdef CONFIG_OMI_ENABLE_BATTERY
#define BATTERY_REFRESH_INTERVAL_CONNECTED    60000  // 60 seconds while connected
#define BATTERY_REFRESH_INTERVAL_DISCONNECTED 300000 // 5 minutes while offline
#define CONFIG_OMI_BATTERY_CRITICAL_MV        3500  // mV
/* Below this percentage the 150mAh cell's internal resistance rises sharply, so
 * a brownout mid-write is more likely. We flush once here so everything captured
 * so far is durable, but recording CONTINUES — a recorder should capture to the
 * critical-voltage shutdown, not stop at 15%. littlefs is power-loss resilient,
 * so a brownout costs at most the last unsynced frames; the clean shutdown still
 * happens at CONFIG_OMI_BATTERY_CRITICAL_MV. */
#define BATTERY_LOW_SD_FLUSH_THRESHOLD        15    // %
uint8_t battery_percentage = 100;
bool battery_ready = false;
static bool sd_flushed_for_low_battery = false;
void broadcast_battery_level(struct k_work *work_item);

K_WORK_DELAYABLE_DEFINE(battery_work, broadcast_battery_level);

void broadcast_battery_level(struct k_work *work_item)
{
    uint16_t battery_millivolt;

    if (battery_get_millivolt(&battery_millivolt) == 0 &&
        battery_get_percentage(&battery_percentage, battery_millivolt) == 0) {

        battery_ready = true;
        LOG_PRINTK("Battery at %d mV (capacity %d%%)\n", battery_millivolt, battery_percentage);

        int err = bt_bas_set_battery_level(battery_percentage);        if (err) {
            LOG_ERR("Error updating battery level: %d", err);
        }

        /* Skip detail notify during active file sync to avoid consuming
         * the TX slots reserved for audio — storage_transfer_active()
         * returns true while a BLE file transfer is in progress. */
        struct bt_conn *conn = get_current_connection();
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
        bool syncing = storage_transfer_active();
#else
        bool syncing = false;
#endif
        if (conn != NULL && !syncing) {
            uint8_t is_charging_byte = (uint8_t)is_charging;
            bt_gatt_notify(NULL, &battery_detail_service_attr[2], &is_charging_byte, 1);
        }
        put_current_connection(conn);

        /* Flush once when we first drop into the low-battery zone so everything
         * captured so far is durable before the high-internal-resistance region.
         * Recording is NOT paused — it continues until the critical-voltage clean
         * shutdown below. Re-arms if the battery recovers above the threshold. */
        if (!is_charging && battery_percentage <= BATTERY_LOW_SD_FLUSH_THRESHOLD &&
            !sd_flushed_for_low_battery) {
            LOG_WRN("Battery low (%d%%) — flushing SD; recording continues to critical shutdown",
                    battery_percentage);
            sd_flush_current_file();
            sd_flushed_for_low_battery = true;
        } else if (sd_flushed_for_low_battery &&
                   (is_charging || battery_percentage > BATTERY_LOW_SD_FLUSH_THRESHOLD)) {
            sd_flushed_for_low_battery = false;
        }

        if (battery_millivolt < CONFIG_OMI_BATTERY_CRITICAL_MV) {
            LOG_WRN("Battery critical level reached (%d mV). Initiating shutdown.", battery_millivolt);
            turnoff_all();
        }
    } else {
        LOG_ERR("Failed to read battery level");
    }

    uint32_t interval = is_connected ? BATTERY_REFRESH_INTERVAL_CONNECTED
                                     : BATTERY_REFRESH_INTERVAL_DISCONNECTED;
    k_work_reschedule(&battery_work, K_MSEC(interval));
}

/* Called when the phone enables or disables notifications on the battery detail
 * characteristic.  On subscribe we immediately push the last cached reading so
 * the app doesn't have to wait up to 10 s for the periodic work to fire. */
static void battery_detail_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value != BT_GATT_CCC_NOTIFY) {
        return;
    }
    if (battery_ready) {
        uint8_t is_charging_byte = (uint8_t)is_charging;
        /* Notify on the characteristic value attribute (index 2), matching the
         * periodic-notify path above; avoids fragile attr-relative arithmetic. */
        bt_gatt_notify(NULL, &battery_detail_service_attr[2], &is_charging_byte, 1);
    }
    /* Also kick a fresh ADC read soon so the cached value is confirmed/updated. */
    k_work_reschedule(&battery_work, K_MSEC(20));
}

/* Schedule an immediate battery notify — safe to call from ISR/interrupt context. */
void transport_notify_battery_soon(void)
{
    k_work_reschedule(&battery_work, K_MSEC(50));
}
#endif

//
// Connection Callbacks
//

/* Forward declarations for helpers used in connection callbacks */
#define MTU_RECHECK_DELAY_MS     800
#define MTU_RECHECK_MAX_ATTEMPTS 6
static uint8_t mtu_recheck_attempts = 0;
static void mtu_recheck_work_handler(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(mtu_recheck_work, mtu_recheck_work_handler);

static void post_pairing_work_handler(struct k_work *work)
{
    if (!is_connected || !current_connection) {
        return;
    }

    // After the pairing delay, initiate PHY, Data Length, and MTU updates
    update_phy(current_connection);
    update_data_length(current_connection);
    update_mtu(current_connection);

    mtu_recheck_attempts = 0;
    k_work_schedule(&mtu_recheck_work, K_MSEC(MTU_RECHECK_DELAY_MS));
}
K_WORK_DELAYABLE_DEFINE(post_pairing_work, post_pairing_work_handler);

static void post_connect_work_handler(struct k_work *work)
{
    if (!is_connected || !current_connection) {
        return;
    }

    // Delay PHY/data-length/MTU updates to give the Central time to complete bonding first.
    // Without this gap, connection-parameter negotiations can race with the SMP exchange.
    k_work_schedule(&post_pairing_work, K_MSEC(1500));
}
K_WORK_DELAYABLE_DEFINE(post_connect_work, post_connect_work_handler);

/* Idle disconnect: drop the BLE link after IDLE_DISCONNECT_TIMEOUT_MS of no
 * GATT activity on storage characteristics.  Saves Omi battery — when
 * disconnected the radio reverts to advertising, which is ~10x lower power
 * than maintaining a connection.  The Android system Bluetooth service does
 * not auto-reconnect bonded LE peers unless an app explicitly requests it
 * (verified 2026-05-27 by toggling BT off/on and observing no auto-reconnect
 * for 30+ s), so the link stays down until the app's next periodic sync
 * scans and connects.
 *
 * MUST stay above the app's foreground keep-alive interval (10 s, see
 * device_provider.dart _startForegroundKeepAlive). A timeout at/below that
 * interval makes the heartbeat structurally unable to keep the link up: the
 * device idle-drops before the next keep-alive arrives, producing a permanent
 * connect/disconnect loop (BT_HCI_ERR_REMOTE_USER_TERM_CONN / gatt_status_19).
 * 15 s gives the 10 s keep-alive a 5 s margin. */
#define IDLE_DISCONNECT_TIMEOUT_MS 15000
#define IDLE_DISCONNECT_POLL_MS    5000

static atomic_t last_activity_ms;

void transport_mark_activity(void)
{
    atomic_set(&last_activity_ms, (atomic_val_t)k_uptime_get_32());
}

static void idle_disconnect_work_handler(struct k_work *work)
{
    if (!is_connected) {
        return;
    }

    uint32_t now = k_uptime_get_32();
    uint32_t last = (uint32_t)atomic_get(&last_activity_ms);
    uint32_t idle_ms = now - last;

    if (idle_ms < IDLE_DISCONNECT_TIMEOUT_MS) {
        k_work_schedule(k_work_delayable_from_work(work), K_MSEC(IDLE_DISCONNECT_POLL_MS));
        return;
    }

    /* Snapshot+null+unref under conn_mutex — same pattern as transport_off
     * (see line ~1265) so a concurrent _transport_disconnected sees NULL and
     * skips its unref of a connection we already released. */
    struct bt_conn *conn_to_release = NULL;
    k_mutex_lock(&conn_mutex, K_FOREVER);
    /* Re-check idle under the lock: a disconnect+reconnect between the
     * timestamp read above and acquiring the mutex would otherwise let us
     * disconnect a freshly-connected link.  Cheap two-line guard. */
    uint32_t idle_ms_locked = k_uptime_get_32() - (uint32_t)atomic_get(&last_activity_ms);
    if (idle_ms_locked >= IDLE_DISCONNECT_TIMEOUT_MS) {
        conn_to_release = current_connection;
        current_connection = NULL;
    }
    k_mutex_unlock(&conn_mutex);

    if (conn_to_release == NULL) {
        /* Lost the race or already disconnected; reschedule and try again. */
        k_work_schedule(k_work_delayable_from_work(work), K_MSEC(IDLE_DISCONNECT_POLL_MS));
        return;
    }

    LOG_INF("Idle for %u ms, disconnecting to save power", idle_ms);
    bt_conn_disconnect(conn_to_release, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
    bt_conn_unref(conn_to_release);
    /* _transport_disconnected fires next; it restarts advertising and the
     * work item stays cancelled until the next connect. */
}
K_WORK_DELAYABLE_DEFINE(idle_disconnect_work, idle_disconnect_work_handler);

static void update_conn_params(struct bt_conn *conn);

static void _transport_connected(struct bt_conn *conn, uint8_t err)
{
    /* HCI connection failure: conn is borrowed and being torn down by the stack.
     * Do not ref/store/unref it — peripheral-role connected callbacks just observe. */
    if (err) {
        /* atomic_inc returns the pre-increment value. See NOTES.md "BLE: advertising
         * but won't connect" — if this fires during the failures, the peripheral *is*
         * receiving CONNECT_IND but the link dies at establishment (points at a
         * controller/RF wedge); if nothing logs while a phone is retrying, the
         * CONNECT_IND is never reaching the device. adv_mode reveals slow-interval
         * correlation. */
        uint32_t fails = (uint32_t)atomic_inc(&failed_conn_count) + 1;
        last_failed_adv_slow = (current_adv_mode[0] == 's') ? 1 : 0; /* "slow" vs "fast" */
        LOG_ERR("Connection failed (err 0x%02x) adv_mode=%s failed_conn_count=%u uptime=%lld ms",
                err, current_adv_mode, fails, (long long)k_uptime_get());
        /* Coalesced flash persist so the count survives the power-cycle needed to read it. */
        k_work_schedule(&conn_fail_persist_work, K_MSEC(CONN_FAIL_PERSIST_DELAY_MS));
        return;
    }

    struct bt_conn_info info = {0};
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = true;
#endif

    int info_err = bt_conn_get_info(conn, &info);
    if (info_err) {
        LOG_ERR("Failed to get connection info (err %d)", info_err);
        return;
    }

    LOG_INF("bluetooth activated");
    k_mutex_lock(&conn_mutex, K_FOREVER);
    current_connection = bt_conn_ref(conn);
    k_mutex_unlock(&conn_mutex);
    uint16_t mtu = bt_gatt_get_mtu(conn);
    current_mtu = MAX(mtu, CONFIG_BT_L2CAP_TX_MTU);

    LOG_INF("Transport connected");

    // Log initial connection parameters
    double connection_interval = info.le.interval * 1.25; // in ms
    uint16_t supervision_timeout = info.le.timeout * 10;  // in ms
    LOG_INF("Initial conn params: interval %.2f ms, latency %d intervals, timeout %d ms",
            connection_interval,
            info.le.latency,
            supervision_timeout);
    LOG_INF("Initial MTU: %u", mtu);

    // Request aggressive connection params for higher BLE sync throughput.
    update_conn_params(current_connection);

    k_work_schedule(&post_connect_work, K_MSEC(500));

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    sd_notify_ble_state(true);
#endif

    is_connected = true;
    transport_mark_activity();
    k_work_schedule(&idle_disconnect_work, K_MSEC(IDLE_DISCONNECT_POLL_MS));
}

static void _transport_disconnected(struct bt_conn *conn, uint8_t err)
{
    is_connected = false;
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = false;
    storage_stop_sync_session();
    sd_notify_ble_state(false);
#endif

    k_work_cancel_delayable(&mtu_recheck_work);
    k_work_cancel_delayable(&idle_disconnect_work);

    LOG_INF("Transport disconnected");

    k_mutex_lock(&conn_mutex, K_FOREVER);
    if (current_connection != NULL) {
        bt_conn_unref(current_connection);
        current_connection = NULL;
    }
    k_mutex_unlock(&conn_mutex);
    current_mtu = 0;

    /* Restart advertising so the device is rediscoverable after any disconnect.
     * Without this, slow-adv mode (BT_LE_ADV_OPT_ONE_TIME) leaves the device
     * invisible after a connect/disconnect cycle — Zephyr does not auto-restart
     * advertising when ONE_TIME is set. Start with fast params; AAD will switch
     * back to slow once VAD returns to sleep. */
    current_adv_mode = "fast";
    bt_le_adv_start(BT_LE_ADV_CONN, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
}

static bool _le_param_req(struct bt_conn *conn, struct bt_le_conn_param *param)
{
    LOG_INF("Transport connection parameters update request received.");
    LOG_DBG("Minimum interval: %d, Maximum interval: %d", param->interval_min, param->interval_max);
    LOG_DBG("Latency: %d, Timeout: %d", param->latency, param->timeout);

    return true;
}

static void _le_param_updated(struct bt_conn *conn, uint16_t interval, uint16_t latency, uint16_t timeout)
{
    double connection_interval = interval * 1.25; // in ms
    uint16_t supervision_timeout = timeout * 10;  // in ms
    LOG_INF("Connection parameters updated: interval %.2f ms, latency %d intervals, timeout %d ms",
            connection_interval,
            latency,
            supervision_timeout);
}

static void _le_phy_updated(struct bt_conn *conn, struct bt_conn_le_phy_info *param)
{
    LOG_INF("PHY updated: TX PHY %u, RX PHY %u", param->tx_phy, param->rx_phy);
    // Detailed logging based on PHY type
    if (param->tx_phy == BT_CONN_LE_TX_POWER_PHY_1M) {
        LOG_INF("PHY updated. New PHY: 1M");
    } else if (param->tx_phy == BT_CONN_LE_TX_POWER_PHY_2M) {
        LOG_INF("PHY updated. New PHY: 2M");
    } else if (param->tx_phy == BT_CONN_LE_TX_POWER_PHY_CODED_S8) {
        LOG_INF("PHY updated. New PHY: Coded S8 (Long Range)");
    } else if (param->tx_phy == BT_CONN_LE_TX_POWER_PHY_CODED_S2) {
        LOG_INF("PHY updated. New PHY: Coded S2 (Long Range)");
    } else {
        LOG_INF("PHY updated. New PHY: Unknown (%u)", param->tx_phy);
    }
}

static void _le_data_length_updated(struct bt_conn *conn, struct bt_conn_le_data_len_info *info)
{
    LOG_INF("Data length updated: TX %u bytes/%u us, RX %u bytes/%u us",
            info->tx_max_len,
            info->tx_max_time,
            info->rx_max_len,
            info->rx_max_time);
    // Note: current_mtu is updated in exchange_func after MTU negotiation
}

static struct bt_conn_cb _callback_references = {
    .connected = _transport_connected,
    .disconnected = _transport_disconnected,
    .le_param_req = _le_param_req,
    .le_param_updated = _le_param_updated,
    .le_phy_updated = _le_phy_updated,
    .le_data_len_updated = _le_data_length_updated,
};

// --- Update Request Functions ---

static void update_data_length(struct bt_conn *conn)
{
    int err;
    // Request maximum data length
    struct bt_conn_le_data_len_param data_len_param = {
        .tx_max_len = BT_GAP_DATA_LEN_MAX,
        .tx_max_time = BT_GAP_DATA_TIME_MAX,
    };
    LOG_INF("Requesting data length update...");
    err = bt_conn_le_data_len_update(conn, &data_len_param);
    if (err) {
        LOG_ERR("bt_conn_le_data_len_update() failed (err %d)", err);
    }
}

static void update_mtu(struct bt_conn *conn)
{
    int err;
    exchange_params.func = exchange_func; // Set the callback function

    LOG_INF("Requesting MTU exchange...");
    err = bt_gatt_exchange_mtu(conn, &exchange_params);
    if (err && err != -EALREADY) {
        LOG_ERR("bt_gatt_exchange_mtu() failed (err %d)", err);
    }
}

/* MTU recheck: if MTU is still at the BLE minimum after connection, the peer
 * may not have responded to our exchange yet.  Retry up to 6 times at 800 ms
 * intervals so iOS / Android apps that negotiate MTU late still get a fast path. */
static void mtu_recheck_work_handler(struct k_work *work)
{
    if (!is_connected || !current_connection) {
        return;
    }
    uint16_t mtu = bt_gatt_get_mtu(current_connection);
    if (mtu <= 23 && mtu_recheck_attempts < MTU_RECHECK_MAX_ATTEMPTS) {
        mtu_recheck_attempts++;
        LOG_INF("MTU still at minimum (%u), recheck attempt %u/%u", mtu, mtu_recheck_attempts, MTU_RECHECK_MAX_ATTEMPTS);
        update_mtu(current_connection);
        k_work_reschedule((struct k_work_delayable *)work, K_MSEC(MTU_RECHECK_DELAY_MS));
    } else {
        LOG_INF("MTU recheck done: MTU=%u after %u attempts", mtu, mtu_recheck_attempts);
    }
}

static void update_phy(struct bt_conn *conn)
{
    int err;
    const struct bt_conn_le_phy_param preferred_phy = {
        .options = BT_CONN_LE_PHY_OPT_NONE,
        .pref_rx_phy = BT_GAP_LE_PHY_2M,
        .pref_tx_phy = BT_GAP_LE_PHY_2M,
    };
    err = bt_conn_le_phy_update(conn, &preferred_phy);
    if (err) {
        LOG_WRN("PHY update request failed (err %d). Device will use default (1M).", err);
    } else {
        LOG_INF("PHY update requested (2M preferred)");
    }
}

/* Request aggressive connection parameters for higher audio throughput.
 * 7.5–15 ms interval gives ~67–133 packets/s vs ~33 at the 30 ms default. */
#define CONN_PARAM_UPDATE_RETRIES 3
static void update_conn_params(struct bt_conn *conn)
{
    struct bt_le_conn_param params = {
        .interval_min = 6,
        .interval_max = 18,
        .latency      = 0,
        .timeout      = 600,
    };
    for (int i = 0; i < CONN_PARAM_UPDATE_RETRIES; i++) {
        int err = bt_conn_le_param_update(conn, &params);
        if (!err || err == -EALREADY) {
            return;
        }
        LOG_WRN("conn param update attempt %d failed (err %d)", i + 1, err);
        k_sleep(K_MSEC(200));
    }
    LOG_ERR("Failed to update connection parameters after %d attempts", CONN_PARAM_UPDATE_RETRIES);
}

//
// Ring Buffer
//

#define NET_BUFFER_HEADER_SIZE 3
#define RING_BUFFER_HEADER_SIZE 2
static uint8_t tx_queue[NETWORK_RING_BUF_SIZE * (CODEC_OUTPUT_MAX_BYTES + RING_BUFFER_HEADER_SIZE)];
static uint8_t tx_buffer[CODEC_OUTPUT_MAX_BYTES + RING_BUFFER_HEADER_SIZE];
static uint32_t tx_buffer_size = 0;
static struct ring_buf ring_buf;

/* Wakes pusher() when a frame is queued — replaces 10 ms sleep polling. */
K_SEM_DEFINE(tx_queue_sem, 0, NETWORK_RING_BUF_SIZE);


static bool write_to_tx_queue(uint8_t *data, size_t size)
{
#ifdef CONFIG_OMI_ENABLE_MONITOR
    // Increment the counter
    monitor_inc_tx_queue_write();
#endif

    if (size > CODEC_OUTPUT_MAX_BYTES) {
        return false;
    }

    uint8_t *allocated_data;
    uint32_t required_size = CODEC_OUTPUT_MAX_BYTES + RING_BUFFER_HEADER_SIZE;

    // Allocate space in the ring buffer directly
    uint32_t allocated_size = ring_buf_put_claim(&ring_buf, &allocated_data, required_size);

    if (allocated_size < required_size) {
        ring_buf_put_finish(&ring_buf, 0); // Release claimed space
        return false;
    }

    // Write directly to the ring buffer
    allocated_data[0] = size & 0xFF;
    allocated_data[1] = (size >> 8) & 0xFF;
    memcpy(allocated_data + RING_BUFFER_HEADER_SIZE, data, size);

    // Finalize the write
    ring_buf_put_finish(&ring_buf, required_size); // It always fits completely or not at all

    k_sem_give(&tx_queue_sem);
    return true;
}

static bool read_from_tx_queue()
{

    // Read from ring buffer
    // memset(tx_buffer, 0, sizeof(tx_buffer));
    uint32_t package_size = CODEC_OUTPUT_MAX_BYTES + RING_BUFFER_HEADER_SIZE;
    tx_buffer_size = ring_buf_get(&ring_buf, tx_buffer, package_size); // It always fits completely or not at all
    if (tx_buffer_size != package_size) {
        // LOG_ERR("Failed to read from ring buffer. not enough data %d", tx_buffer_size);
        return false;
    }

    // Adjust size
    tx_buffer_size = tx_buffer[0] + (tx_buffer[1] << 8);

    return true;
}

//
// Pusher
//

// Thread
K_THREAD_STACK_DEFINE(pusher_stack, 4096);
static struct k_thread pusher_thread;

#define OPUS_PREFIX_LENGTH 1
#define OPUS_PADDED_LENGTH 80
#define MAX_WRITE_SIZE 440
static uint16_t buffer_offset = 0;
static K_MUTEX_DEFINE(storage_temp_mutex);
/* True when the block currently accumulating in storage_temp_data contains a
 * marker frame (button-tap / session-end / VAD-resume). Such a block is flushed
 * via write_to_file_blocking() so the marker survives transient SD saturation.
 * Guarded by storage_temp_mutex (set/read/cleared only while it is held). */
static bool storage_block_has_marker = false;

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
static uint8_t storage_temp_data[MAX_WRITE_SIZE];

/* mic delivers 100ms mono blocks (1600 samples at 16kHz); forward to codec ring buffer */
#define MIC_BLOCK_SAMPLES (16000 / 10)
static void on_mic_audio(int16_t *pcm)
{
    codec_receive_pcm(pcm, MIC_BLOCK_SAMPLES);
}

static void on_codec_output(uint8_t *data, size_t len)
{
    broadcast_audio_packets(data, len);
}

bool write_custom_packet_to_storage(uint32_t marker, uint8_t *data, uint32_t data_size, bool important)
{
    /* Framed entry: [length:4LE][payload:NB] */
    uint32_t entry_size = data_size + 4;
    bool ok = true;

    k_mutex_lock(&storage_temp_mutex, K_FOREVER);

    if (buffer_offset + entry_size > MAX_WRITE_SIZE) {
        /* Pad remaining block with 0 (NULL entries) */
        memset(storage_temp_data + buffer_offset, 0, MAX_WRITE_SIZE - buffer_offset);
        /* If the block being flushed carries a marker, use the blocking enqueue
         * so it isn't dropped on transient saturation. */
        uint32_t wrote = storage_block_has_marker
                             ? write_to_file_blocking(storage_temp_data, MAX_WRITE_SIZE)
                             : write_to_file(storage_temp_data, MAX_WRITE_SIZE);
        storage_block_has_marker = false;
        if (wrote != MAX_WRITE_SIZE) {
            /* SD queue rejected the block — the buffered bytes (up to one
             * full block of audio frames or markers) are lost. We still
             * have to reset buffer_offset to make room for the entry the
             * caller is trying to write; otherwise the writer is stuck
             * forever and loses every subsequent frame too. Signal the
             * loss via the return value. */
            LOG_WRN("Storage rollover flush dropped block (wrote=%u/%u)", wrote, (uint32_t)MAX_WRITE_SIZE);
            atomic_inc(&storage_block_drops);
            atomic_set(&last_storage_drop_uptime_ms, (atomic_val_t)k_uptime_get());
            ok = false;
        }
        buffer_offset = 0;
    }

    /* Write 4-byte Little-Endian length prefix */
    storage_temp_data[buffer_offset + 0] = (uint8_t)(marker & 0xFF);
    storage_temp_data[buffer_offset + 1] = (uint8_t)((marker >> 8) & 0xFF);
    storage_temp_data[buffer_offset + 2] = (uint8_t)((marker >> 16) & 0xFF);
    storage_temp_data[buffer_offset + 3] = (uint8_t)((marker >> 24) & 0xFF);

    /* Write payload */
    memcpy(storage_temp_data + buffer_offset + 4, data, data_size);
    buffer_offset += entry_size;

    /* This block now carries a marker; mark it so every flush path (here, the
     * rollover above, and the marker force-drain) uses the durable enqueue. */
    if (important) {
        storage_block_has_marker = true;
    }

    /* Align buffer_offset to 4-byte boundary for the next entry */
    uint16_t alignment_padding = (4 - (buffer_offset % 4)) % 4;
    if (alignment_padding > 0 && buffer_offset + alignment_padding <= MAX_WRITE_SIZE) {
        memset(storage_temp_data + buffer_offset, 0, alignment_padding);
        buffer_offset += alignment_padding;
    }

    if (buffer_offset == MAX_WRITE_SIZE) {
        uint32_t wrote = storage_block_has_marker
                             ? write_to_file_blocking(storage_temp_data, MAX_WRITE_SIZE)
                             : write_to_file(storage_temp_data, MAX_WRITE_SIZE);
        storage_block_has_marker = false;
        if (wrote != MAX_WRITE_SIZE) {
            /* Full-buffer flush rejected. Same trade-off as above: reset
             * so subsequent writes can proceed, but report the loss. */
            LOG_WRN("Storage full-block flush dropped (wrote=%u/%u)", wrote, (uint32_t)MAX_WRITE_SIZE);
            atomic_inc(&storage_block_drops);
            atomic_set(&last_storage_drop_uptime_ms, (atomic_val_t)k_uptime_get());
            ok = false;
        }
        buffer_offset = 0;
    }

    k_mutex_unlock(&storage_temp_mutex);

#ifdef CONFIG_OMI_ENABLE_MONITOR
    monitor_inc_storage_write();
#endif
    return ok;
}

bool write_to_storage(void)
{
    uint8_t *buffer = tx_buffer + 2;
    return write_custom_packet_to_storage(tx_buffer_size, buffer, tx_buffer_size, false);
}

atomic_t device_session_id = ATOMIC_INIT(0);

/* Atomic lazy-init of device_session_id. Race-safe against parallel calls
 * from the audio path and the button-tap marker path during boot (B18). */
static uint32_t ensure_device_session_id(void)
{
    uint32_t sid = (uint32_t)atomic_get(&device_session_id);
    if (sid != 0) return sid;
    do {
        sid = sys_rand32_get();
    } while (sid == 0);
    /* If another thread already published an ID, keep theirs. */
    if (!atomic_cas(&device_session_id, 0, (atomic_val_t)sid)) {
        sid = (uint32_t)atomic_get(&device_session_id);
    }
    return sid;
}

static bool write_marker_header_to_storage(uint32_t header, const char *label)
{
    uint32_t sid = ensure_device_session_id();

    uint8_t temp_buffer[16];
    uint64_t utc_time_ms = rtc_get_utc_time_ms();
    uint32_t uptime_ms = (uint32_t)k_uptime_get();

    memcpy(temp_buffer, &utc_time_ms, 8);
    memcpy(temp_buffer + 8, &uptime_ms, 4);
    memcpy(temp_buffer + 12, &sid, 4);

    LOG_INF("Writing %s marker to storage (DeviceSession: %u)", label, sid);
    bool ok = write_custom_packet_to_storage(header, temp_buffer, 16, true);

    /* Force-drain any partial block in storage_temp_data so the marker is
     * durable to SD even when no audio is flowing (e.g. mic muted) (B2).
     * Without this, a 20-byte marker can sit in RAM until the 440-byte
     * block fills — and never reach the card if the device powers off
     * before the next audio frame.
     *
     * IMPORTANT: only reset buffer_offset when write_to_file actually
     * accepted the block. If the SD queue is full it returns 0; resetting
     * the buffer in that case throws away both the marker AND whatever
     * audio frames the audio thread interleaved between the mutex
     * release in write_custom_packet_to_storage and this re-acquire
     * (NEW9). Leaving buffer_offset intact lets the next audio write
     * retry the block. */
    k_mutex_lock(&storage_temp_mutex, K_FOREVER);
    if (buffer_offset > 0) {
        uint16_t saved_offset = buffer_offset;
        memset(storage_temp_data + buffer_offset, 0, MAX_WRITE_SIZE - buffer_offset);
        /* This drain carries the marker just appended — use the durable enqueue. */
        uint32_t wrote = write_to_file_blocking(storage_temp_data, MAX_WRITE_SIZE);
        if (wrote == MAX_WRITE_SIZE) {
            buffer_offset = 0;
            storage_block_has_marker = false;
        } else {
            /* Queue rejected; keep the original payload bytes in place
             * (the memset only touched the padding region). */
            buffer_offset = saved_offset;
            ok = false;
            LOG_WRN("Marker flush dropped: SD queue full, retaining buffer (offset=%u)", saved_offset);
        }
    }
    k_mutex_unlock(&storage_temp_mutex);

    return ok;
}

bool write_marker_to_storage(void)
{
    return write_marker_header_to_storage(0xFFFFFFFE, "button-tap");
}

bool write_session_end_marker_to_storage(void)
{
    return write_marker_header_to_storage(0xFFFFFFFC, "session-end");
}
#endif

void pusher(void)
{
    k_msleep(500);
    while (!atomic_get(&pusher_stop_flag)) {
        /* Block until a frame is enqueued or stop is requested. */
        k_sem_take(&tx_queue_sem, K_FOREVER);

        if (atomic_get(&pusher_stop_flag)) {
            break;
        }

        if (!read_from_tx_queue()) {
            continue;
        }

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
        // Always write to storage for offline-only recording
        if (!is_muted && sd_get_cached_total_size() < MAX_STORAGE_BYTES && is_sd_on()) {
            storage_full_warned = false;
            
            write_to_storage();
        } else {
            if (is_muted) {
                // If muted, we just drop the buffer (which was already read_from_tx_queue)
            } else if (!storage_full_warned) {
                LOG_WRN("Storage full, stopping offline storage");
                storage_full_warned = true;
            }
        }
#else
        // Discard if offline storage is somehow disabled
#endif
    }
}

int transport_off()
{
    // Stop pusher thread when transport is turned off
    atomic_set(&pusher_stop_flag, 1);
    k_sem_give(&tx_queue_sem); // unblock pusher if waiting
    int ret = k_thread_join(&pusher_thread, K_MSEC(500));
    if (ret != 0) {
        LOG_WRN("Pusher thread did not terminate in time (err %d)", ret);
    }

    /* Snapshot+null under the mutex so a concurrent _transport_disconnected
     * sees NULL and skips its unref. We then disconnect+unref our snapshot,
     * which still holds the ref taken in _transport_connected. */
    struct bt_conn *conn_to_release = NULL;
    k_mutex_lock(&conn_mutex, K_FOREVER);
    conn_to_release = current_connection;
    current_connection = NULL;
    k_mutex_unlock(&conn_mutex);

    if (conn_to_release != NULL) {
        bt_conn_disconnect(conn_to_release, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
        bt_conn_unref(conn_to_release);
    }

    // Stop advertising
    int err = bt_le_adv_stop();
    if (err) {
        LOG_ERR("Failed to stop Bluetooth advertising %d", err);
    }

    // Disable Bluetooth
    err = bt_disable();
    if (err) {
        LOG_ERR("Failed to disable Bluetooth %d", err);
    }

    // Pull the rfsw control low
#ifdef CONFIG_OMI_ENABLE_RFSW_CTRL
    err = gpio_pin_set_dt(&rfsw_en, 0);
    if (err) {
        LOG_ERR("Failed to pull the rfsw control low %d", err);
    }
#endif

    // Ensure all Bluetooth resources are cleaned up
    is_connected = false;
    current_mtu = 0;

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = false;
#endif

    return 0;
}

/* Slow advertising parameters for low-power mode (~1 s interval).
 * BT_LE_ADV_CONN uses 100-150ms by default; 1000-1200ms saves ~300-500 µA.
 * Advertising interval unit = 0.625 ms → 1000 ms = 1600, 1200 ms = 1920. */
static const struct bt_le_adv_param adv_param_slow = BT_LE_ADV_PARAM_INIT(
    BT_LE_ADV_OPT_CONNECTABLE | BT_LE_ADV_OPT_ONE_TIME,
    1600,
    1920,
    NULL);

int transport_set_adv_slow(void)
{
    if (is_connected) {
        return 0;
    }
    int err = bt_le_adv_stop();
    if (err && err != -EALREADY) {
        LOG_ERR("adv_slow: stop failed (%d)", err);
        return err;
    }
    err = bt_le_adv_start(&adv_param_slow, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    if (err) {
        LOG_ERR("adv_slow: start failed (%d)", err);
    } else {
        current_adv_mode = "slow";
        LOG_INF("BLE advertising switched to slow interval");
    }
    return err;
}

int transport_set_adv_fast(void)
{
    if (is_connected) {
        return 0;
    }
    int err = bt_le_adv_stop();
    if (err && err != -EALREADY) {
        LOG_ERR("adv_fast: stop failed (%d)", err);
        return err;
    }
    err = bt_le_adv_start(BT_LE_ADV_CONN, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    if (err) {
        LOG_ERR("adv_fast: start failed (%d)", err);
    } else {
        current_adv_mode = "fast";
        LOG_INF("BLE advertising switched to fast interval");
    }
    return err;
}

// periodic advertising
int transport_start()
{
    int err = 0;

    // Pull the nfsw control high
#ifdef CONFIG_OMI_ENABLE_RFSW_CTRL
    err = gpio_pin_configure_dt(&rfsw_en, (GPIO_OUTPUT | NRF_GPIO_DRIVE_S0H1));
    if (err) {
        LOG_ERR("Failed to get the rfsw pin config (err %d)", err);
    } else {
        err = gpio_pin_set_dt(&rfsw_en, 1);
        if (err) {
            LOG_ERR("Failed to pull the rfsw pin control high (err %d)", err);
        }
    }
#endif

    // Configure callbacks
    bt_conn_cb_register(&_callback_references);

    /* Seed the connection-failure counter from flash (app_settings_init ran in
     * main before transport_start) so it stays cumulative across reboots — the
     * count is only readable after the user power-cycles to reconnect. */
    {
        uint32_t persisted = 0;
        app_settings_get_conn_fail(&persisted, &last_failed_adv_slow);
        atomic_set(&failed_conn_count, (atomic_val_t)persisted);
    }

    // Enable Bluetooth
    err = bt_enable(NULL);
    if (err) {
        LOG_ERR("Transport bluetooth init failed (err %d)", err);
        return err;
    }

#if defined(CONFIG_BT_SETTINGS)
    err = settings_load_subtree("bt");
    if (err == -ENOENT) {
        LOG_INF("No persisted BT bond keys yet");
    } else if (err) {
        LOG_WRN("Failed to load BT settings (err %d)", err);
    }
#endif

    LOG_INF("Transport bluetooth initialized");

    //  Enable accelerometer
#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    err = accel_start();
    if (err) {
        LOG_ERR("Accelerometer failed to activate (err %d)", err);
    } else {
        LOG_INF("Accelerometer initialized");
        register_accel_service(current_connection);
    }
#endif
    //  Enable button
#ifdef CONFIG_OMI_ENABLE_BUTTON
    button_init();
    register_button_service();
    // Button work is now interrupt-driven; no startup polling needed.
#endif

// Initialize and register Haptic service if enabled
#ifdef CONFIG_OMI_ENABLE_HAPTIC
    // Note: haptic_init() is called in main.c
    register_haptic_service();
    LOG_INF("Haptic service registered via transport");
#endif

#ifdef CONFIG_OMI_ENABLE_SPEAKER
    err = speaker_init();
    if (err) {
        LOG_ERR("Speaker failed to start");
        return 0;
    }
    LOG_INF("Speaker initialized");
    register_speaker_service();

#endif

    // Start advertising
    bt_gatt_service_register(&settings_service);
    bt_gatt_service_register(&features_service);
    bt_gatt_service_register(&time_sync_service);
#ifdef CONFIG_OMI_ENABLE_BATTERY
    bt_gatt_service_register(&battery_detail_service);
#endif
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    // Register storage service for offline audio
    memset(storage_temp_data, 0, sizeof(storage_temp_data));
    bt_gatt_service_register(&storage_service);
#endif
    // Diagnostics registered last so existing storage handles stay stable across firmware updates
    bt_gatt_service_register(&diagnostics_service);
    err = bt_le_adv_start(BT_LE_ADV_CONN, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    if (err) {
        LOG_ERR("Transport advertising failed to start (err %d)", err);
        return err;
    } else {
        LOG_INF("Advertising successfully started");
    }

#ifdef CONFIG_OMI_ENABLE_BATTERY
    k_work_schedule(&battery_work, K_MSEC(3000));
#endif

    // Start pusher
    ring_buf_init(&ring_buf, sizeof(tx_queue), tx_queue);
    if (ring_buf_is_empty(&ring_buf)) {
        LOG_INF("Ring buffer successfully initialized");
    } else {
        LOG_ERR("Ring buffer initialization failed");
        return -1;
    }

    struct k_thread *thread = k_thread_create(&pusher_thread,
                                              pusher_stack,
                                              K_THREAD_STACK_SIZEOF(pusher_stack),
                                              (k_thread_entry_t) pusher,
                                              NULL,
                                              NULL,
                                              NULL,
                                              K_PRIO_PREEMPT(7),
                                              0,
                                              K_NO_WAIT);
    if (thread == NULL) {
        LOG_ERR("Failed to create pusher thread");
        return -1;
    }

    LOG_INF("Pusher successfully started");

    // Wire the audio pipeline: mic PCM → codec → pusher ring buffer
    set_codec_callback(on_codec_output);
    codec_start();
    set_mic_callback(on_mic_audio);
    LOG_INF("Audio pipeline wired: mic → codec → pusher");

    return 0;
}

struct bt_conn *get_current_connection()
{
    k_mutex_lock(&conn_mutex, K_FOREVER);
    struct bt_conn *conn = current_connection;
    if (conn) {
        bt_conn_ref(conn);
    }
    k_mutex_unlock(&conn_mutex);
    return conn;
}

void put_current_connection(struct bt_conn *conn)
{
    if (conn) {
        bt_conn_unref(conn);
    }
}

int broadcast_audio_packets(uint8_t *buffer, size_t size)
{
    if (!write_to_tx_queue(buffer, size)) {
        return -1;
    }
    return 0;
}
