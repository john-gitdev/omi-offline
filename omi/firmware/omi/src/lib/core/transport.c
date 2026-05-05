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
/* Flush and pause SD writes at this percentage to prevent brownout corruption.
 * The 150mAh cell's internal resistance rises sharply below ~15%, and SD write
 * bursts or LFS alloc scans can dip voltage below the CPU reset threshold. */
#define BATTERY_LOW_SD_FLUSH_THRESHOLD        15    // %
uint8_t battery_percentage = 100;
bool battery_ready = false;
static bool sd_paused_for_low_battery = false;
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

        /* Flush and pause SD writes before the cell voltage collapses.
         * A write burst or LFS alloc scan at low charge can brownout the CPU. */
        if (!is_charging && battery_percentage <= BATTERY_LOW_SD_FLUSH_THRESHOLD &&
            !sd_paused_for_low_battery) {
            LOG_WRN("Battery low (%d%%) — flushing SD and pausing writes to prevent brownout",
                    battery_percentage);
            sd_flush_current_file();
            sd_write_pause(true);
            sd_paused_for_low_battery = true;
        } else if (sd_paused_for_low_battery &&
                   (is_charging || battery_percentage > BATTERY_LOW_SD_FLUSH_THRESHOLD)) {
            LOG_INF("Battery recovered (%d%%) — resuming SD writes", battery_percentage);
            sd_write_pause(false);
            sd_paused_for_low_battery = false;
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
        bt_gatt_notify(NULL, attr - 1, &is_charging_byte, 1);
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

static void update_conn_params(struct bt_conn *conn);

static void _transport_connected(struct bt_conn *conn, uint8_t err)
{
    struct bt_conn_info info = {0};
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = true;
#endif

    err = bt_conn_get_info(conn, &info);
    if (err) {
        LOG_ERR("Failed to get connection info (err %d)", err);
        bt_conn_unref(conn);
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

    LOG_INF("Transport disconnected");

    k_mutex_lock(&conn_mutex, K_FOREVER);
    if (current_connection != NULL) {
        bt_conn_unref(current_connection);
        current_connection = NULL;
    }
    k_mutex_unlock(&conn_mutex);
    current_mtu = 0;
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

/*
static void update_phy(struct bt_conn *conn)
{
    int err;
    // Prefer 2M PHY for higher throughput
    const struct bt_conn_le_phy_param preferred_phy = {
        .options = BT_CONN_LE_PHY_OPT_NONE,
        .pref_rx_phy = BT_GAP_LE_PHY_2M,
        .pref_tx_phy = BT_GAP_LE_PHY_2M,
    };
    LOG_INF("Requesting PHY update...");
    err = bt_conn_le_phy_update(conn, &preferred_phy);
    if (err) {
        LOG_ERR("bt_conn_le_phy_update() failed (err %d)", err);
    }
}
*/

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

bool write_custom_packet_to_storage(uint32_t marker, uint8_t *data, uint32_t data_size)
{
    /* Framed entry: [length:4LE][payload:NB] */
    uint32_t entry_size = data_size + 4;

    k_mutex_lock(&storage_temp_mutex, K_FOREVER);

    if (buffer_offset + entry_size > MAX_WRITE_SIZE) {
        /* Pad remaining block with 0 (NULL entries) */
        memset(storage_temp_data + buffer_offset, 0, MAX_WRITE_SIZE - buffer_offset);
        write_to_file(storage_temp_data, MAX_WRITE_SIZE);
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

    /* Align buffer_offset to 4-byte boundary for the next entry */
    uint16_t alignment_padding = (4 - (buffer_offset % 4)) % 4;
    if (alignment_padding > 0 && buffer_offset + alignment_padding <= MAX_WRITE_SIZE) {
        memset(storage_temp_data + buffer_offset, 0, alignment_padding);
        buffer_offset += alignment_padding;
    }

    if (buffer_offset == MAX_WRITE_SIZE) {
        write_to_file(storage_temp_data, MAX_WRITE_SIZE);
        buffer_offset = 0;
    }

    k_mutex_unlock(&storage_temp_mutex);

#ifdef CONFIG_OMI_ENABLE_MONITOR
    monitor_inc_storage_write();
#endif
    return true;
}

bool write_to_storage(void)
{
    uint8_t *buffer = tx_buffer + 2;
    return write_custom_packet_to_storage(tx_buffer_size, buffer, tx_buffer_size);
}

uint32_t device_session_id = 0;
uint32_t segment_index = 0;

bool write_marker_to_storage(void)
{
    if (device_session_id == 0) {
        // Should not really happen as we should be recording, but safety first
        do {
            device_session_id = sys_rand32_get();
        } while (device_session_id == 0);
    }

    uint8_t temp_buffer[16];
    uint32_t utc_time = get_utc_time();
    uint32_t uptime_ms = (uint32_t)k_uptime_get();

    memcpy(temp_buffer, &utc_time, 4);
    memcpy(temp_buffer + 4, &uptime_ms, 4);
    memcpy(temp_buffer + 8, &device_session_id, 4);
    // Padding for remaining 4 bytes
    memset(temp_buffer + 12, 0, 4);

    LOG_INF("Writing marker to storage (DeviceSession: %u)", device_session_id);
    return write_custom_packet_to_storage(0xFFFFFFFE, temp_buffer, 16);
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

    // First disconnect any active connections
    if (current_connection != NULL) {
        bt_conn_disconnect(current_connection, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
        bt_conn_unref(current_connection);
        current_connection = NULL;
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
    if (!err) {
        LOG_INF("Accelerometer failed to activate\n");
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
    memset(storage_temp_data, 0, OPUS_PADDED_LENGTH * 4);
    bt_gatt_service_register(&storage_service);
#endif
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
