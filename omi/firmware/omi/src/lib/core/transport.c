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
#include <zephyr/random/random.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/ring_buffer.h>

#include "accel.h"
#include "button.h"
#include "config.h"
#include "features.h"
#include "haptic.h"
#include "lib/battery/battery.h"
#include "mic.h"
#include "speaker.h"
#ifdef CONFIG_OMI_ENABLE_MONITOR
#include "monitor.h"
#endif
#include "codec.h"
#include "diag_log.h"
#include "rtc.h"
#include "sd_card.h"
#include "settings.h"
#include "storage.h"

LOG_MODULE_REGISTER(transport, CONFIG_LOG_DEFAULT_LEVEL);

#ifdef CONFIG_OMI_ENABLE_RFSW_CTRL
static const struct gpio_dt_spec rfsw_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(rfsw_en_pin), gpios, {0});
#endif

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
extern struct bt_gatt_service storage_service;
extern bool storage_is_on;
static bool storage_full_warned = false;
#endif

/* Defined in main.c. atomic_t rather than bool because the BT RX thread writes it
 * (_transport_connected / _transport_disconnected) while the system workqueue and
 * the AAD thread read it — the advertising guard's gate checks, main.c's LED state
 * machine, the battery-interval pick. Concurrent access to a plain bool there is a
 * data race in the C memory model even where the load is single-instruction, and
 * holding adv_mutex does not help: the RX thread never takes it, and must not.
 *
 * This buys UB-freedom and a guaranteed re-read, NOT atomicity of the decisions
 * built on it — every reader is still check-then-act with a window afterwards. The
 * guard is correct because it classifies results (adv_schedule_retry ignores a
 * failure that arrives while a link is up), not because it wins that race. */
extern atomic_t is_connected;
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
static ssize_t settings_priority_cap_write_handler(struct bt_conn *conn,
                                                   const struct bt_gatt_attr *attr,
                                                   const void *buf,
                                                   uint16_t len,
                                                   uint16_t offset,
                                                   uint8_t flags);
static ssize_t settings_priority_cap_read_handler(struct bt_conn *conn,
                                                  const struct bt_gatt_attr *attr,
                                                  void *buf,
                                                  uint16_t len,
                                                  uint16_t offset);
// Defined further down (originally under the retired 23BA7926 button-config service).
static ssize_t button_config_write_handler(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           const void *buf,
                                           uint16_t len,
                                           uint16_t offset,
                                           uint8_t flags);
static ssize_t button_config_read_handler(struct bt_conn *conn,
                                          const struct bt_gatt_attr *attr,
                                          void *buf,
                                          uint16_t len,
                                          uint16_t offset);
static ssize_t haptic_config_write_handler(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           const void *buf,
                                           uint16_t len,
                                           uint16_t offset,
                                           uint8_t flags);
static ssize_t haptic_config_read_handler(struct bt_conn *conn,
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
// Priority Recording safety-cap (u16 minutes; 0 = no cap).
static struct bt_uuid_128 settings_priority_cap_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10014, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
// Button + haptic config, consolidated here from the retired 23BA7926 service.
static struct bt_uuid_128 settings_button_config_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10015, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 settings_haptic_config_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10016, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
/* NOTE: do NOT append further characteristics to this service. It is registered
 * FIRST (see transport_start), so every attribute added here shifts the handles
 * of every service registered after it — storage, diagnostics, mute — and a peer
 * holding a cached GATT DB would then address the wrong attributes until it
 * re-pairs. New settings go in a service registered last, as the LED service
 * (0x19B10080) below does. Adding 0015/0016 here already cost one re-pair. */

static struct bt_gatt_attr settings_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&settings_service_uuid),
    BT_GATT_CHARACTERISTIC(&settings_dim_ratio_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           settings_dim_ratio_read_handler,
                           settings_dim_ratio_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&settings_mic_gain_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           settings_mic_gain_read_handler,
                           settings_mic_gain_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&settings_vad_threshold_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           settings_vad_threshold_read_handler,
                           settings_vad_threshold_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&settings_priority_cap_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           settings_priority_cap_read_handler,
                           settings_priority_cap_write_handler,
                           NULL),
    // Button + haptic config consolidated here from the retired 23BA7926 service.
    BT_GATT_CHARACTERISTIC(&settings_button_config_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           button_config_read_handler,
                           button_config_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&settings_haptic_config_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           haptic_config_read_handler,
                           haptic_config_write_handler,
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

    int err = rtc_set_utc_time((uint64_t) epoch_s);
    if (err) {
        LOG_ERR("Failed to set RTC time: %d", err);
        return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
    }

    LOG_INF("Time synchronized successfully");
    return len;
}

static ssize_t
time_sync_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
{
    uint32_t epoch_s = get_utc_time();
    LOG_INF("Time sync read: %u seconds", epoch_s);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &epoch_s, sizeof(epoch_s));
}

static struct bt_gatt_attr time_sync_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&time_sync_service_uuid),
    BT_GATT_CHARACTERISTIC(&time_sync_write_characteristic_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE_ENCRYPT,
                           NULL,
                           time_sync_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&time_sync_read_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ_ENCRYPT,
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
    uint8_t value = (uint8_t) is_charging;

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

/* Diagnostics: BLE connection failures (NOTES.md: "BLE: advertising but won't
 * connect"). Two distinct counters, because the interesting failure does NOT
 * take the path the first one watches:
 *
 *   failed_conn_count — _transport_connected fired with err set, i.e. the host
 *     was told outright that a connection attempt failed.
 *
 *   estab_fail_count — a link came up normally (connected callback, err = 0) and
 *     then died with HCI 0x3e CONN_FAIL_TO_ESTAB, meaning no data-channel packet
 *     was exchanged in the first 6 connection events. This is what a central sees
 *     during the "visible but unconnectable" outages, and it increments *here*,
 *     not above: on a peripheral the controller reports LE Connection Complete
 *     with success the moment it receives CONNECT_IND, so the host takes the
 *     err = 0 path and only learns of the failure at disconnect.
 *
 * The pair is the discriminator, and only their *movement* discriminates: both are
 * persisted to flash and re-seeded from it in transport_start(), so they accumulate
 * for the life of the device and a nonzero absolute value says nothing about the
 * outage in front of you. Compare a reading taken after the outage against one from
 * before it (the app keeps such a baseline — see sync_page.dart's estab_fail_baseline,
 * which likewise survives reboot).
 *
 * estab_fail_count *rose* across the outage: the Omi did receive the CONNECT_INDs and
 * the link died at establishment (points at the peripheral controller / RF /
 * coexistence). Both counters unchanged: the Omi never heard the CONNECT_INDs at all
 * (deaf RX, or nothing usable reached the air), which puts the fault on the central.
 * Pairing with the advertising mode in effect tells us whether either correlates with
 * slow (1 s) advertising. */
static atomic_t failed_conn_count = ATOMIC_INIT(0);
static atomic_t estab_fail_count = ATOMIC_INIT(0);
static const char *current_adv_mode = "fast"; /* boot + post-disconnect both start fast */
static uint8_t last_failed_adv_slow = 0;      /* 1 if the most recent failure of either kind was during slow adv */

/* Diagnostics: Priority Recording lifecycle, appended to 0x19B10062. These make a
 * lost Priority Recording traceable from the app log alone (no RTT/serial capture):
 *   priority_record_starts — a 0xFFFFFFF8 start marker write was attempted, i.e.
 *     record_start() opened an auto-mode priority recording (counted even if the
 *     write below is then dropped — that pairing is the whole diagnosis).
 *   priority_record_stops  — priority_record_stop() ended one (starts > stops means
 *     a priority recording was left open — the "open-draft banner" case).
 *   marker_write_drops     — an inline marker (0xFFFFFFF8 / 0xFFFFFFFC / 0xFFFFFFFE /
 *     mute) failed to persist to SD (queue full / write reject); the marker is lost.
 * empty_bin_rotations lives in sd_card.c (see sd_get_empty_bin_rotations()). All are
 * monotonic since boot — only movement between two reads is meaningful. */
static atomic_t priority_record_starts = ATOMIC_INIT(0);
static atomic_t priority_record_stops = ATOMIC_INIT(0);
static atomic_t marker_write_drops = ATOMIC_INIT(0);

/* Diagnostics: pins the "lost stop marker" question (0x19B10062, appended).
 *   session_end_marker_emits — write_session_end_marker_to_storage() was actually
 *     reached, i.e. aad_set_threshold()'s finalize path emitted a 0xFFFFFFFC. If a
 *     priority/manual stop leaves NO app-visible marker but this DID move, the marker
 *     was emitted-then-dropped (see marker_pause_gate_saves); if it did NOT move, the
 *     emit path never fired (the finalize guard).
 * marker_pause_gate_saves lives in sd_card.c (sd_get_marker_pause_gate_saves()): a
 * marker-bearing block RESCUED at the sd_write_paused gate (written through the pause
 * instead of dropped). Before oo-2.5.9 that block was silently lost — the one
 * marker-loss path that bumped NO counter (the sd_write_blocked overflow path still
 * bumps stat_dropped_frames / stream drops, so it isn't silent, just not marker-aware). */
static atomic_t session_end_marker_emits = ATOMIC_INIT(0);

/* Diagnostics: the advertising-restart guard (0x19B10062, appended).
 *   adv_restart_failures   — a bt_le_adv_start() returned an error on any path
 *     (post-disconnect restart, AAD slow/fast switch, retry). Before oo-2.8.x every
 *     one of these was discarded, and a single failure left the device permanently
 *     invisible: firmware alive and still recording to SD, radio silent, no way back
 *     except a power cycle. Any movement here is the pathology firing.
 *   adv_watchdog_recoveries — times the periodic watchdog found advertising stopped
 *     while disconnected and restarted it. Non-zero means the device WOULD have gone
 *     dark and the watchdog caught it; this is the counter that proves the fix works.
 * Both monotonic since boot — only movement between two reads is meaningful. */
static atomic_t adv_restart_failures = ATOMIC_INIT(0);
static atomic_t adv_watchdog_recoveries = ATOMIC_INIT(0);

/* Throttled flash persist of both counters (NOTES.md: "BLE: advertising but
 * won't connect"). The failures accrue while disconnected, and the user must
 * power-cycle or toggle phone Bluetooth to reconnect and read them, so the counts
 * are persisted to survive a reboot. k_work_schedule (not reschedule) coalesces a
 * storm into one write ~CONN_FAIL_PERSIST_DELAY after the first failure — bounding
 * flash wear while keeping the persisted counts current to within that window. */
#define CONN_FAIL_PERSIST_DELAY_MS 10000
static void conn_fail_persist_work_handler(struct k_work *work)
{
    app_settings_save_conn_fail((uint32_t) atomic_get(&failed_conn_count),
                                last_failed_adv_slow,
                                (uint32_t) atomic_get(&estab_fail_count));
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
// Returns 92 bytes LE (fields appended over time; older apps read a prefix):
//   [uint32 storage_block_drops]   storage_block_drops since boot (each = ~5 Opus frames lost)
//   [uint32 last_drop_uptime_ms]   k_uptime_get() at the most recent block drop (0 = none)
//   [uint32 sd_stream_drops]       stat_dropped_frames from sd_card.c (queue-full audio frame drops)
//   [uint32 sd_boot_drops]         frames lost during SD mount/boot window
//   [uint32 current_uptime_ms]     k_uptime_get() at the moment of read
//   [uint32 conn_fails]            connect attempts the host reported as failed outright,
//                                  i.e. the connected callback fired with err != 0 (offset 20).
//                                  NOT establishment failures — those are estab_fail_count.
//   [uint32 last_failed_adv_slow]  1 if last conn fail was during slow adv (offset 24)
//   [uint32 codec_drops]           PCM blocks dropped before encode, ring-full (offset 28)
//   [uint32 sd_msgq_peak_depth]    high-water mark of sd_msgq occupancy / SD_REQ_QUEUE_MSGS (offset 32)
//   [uint32 write_fair_activations] times write fairness forced a write over reads (offset 36)
//   [uint32 estab_fail_count]      links that died at establishment, HCI 0x3e (offset 40)
//   [uint32 priority_record_starts] 0xFFFFFFF8 priority-start writes attempted (offset 44)
//   [uint32 priority_record_stops]  priority recordings ended; starts>stops = left open (offset 48)
//   [uint32 marker_write_drops]     inline markers that failed to persist to SD (offset 52)
//   [uint32 empty_bin_rotations]    rotations that closed a bin holding no audio (offset 56)
//   [uint32 session_end_marker_emits] 0xFFFFFFFC emits attempted from the finalize path (offset 60)
//   [uint32 marker_pause_gate_saves]  marker-bearing blocks kept through the sd_write_paused gate (offset 64)
//   [uint32 sd_worker_stack_used]  peak sd_worker stack bytes used since boot (offset 68)
//   [uint32 codec_stack_used]      peak codec/encode thread stack bytes used since boot (offset 72)
//   [uint32 ring_max_io_ms]        ring: slowest SD primitive since boot, packed
//                                  (tag<<24)|ms, tag 1=write 2=read 3=CTRL_SYNC (offset 76)
//   [uint32 ring_io_errors]        ring: write/CTRL_SYNC failures (EIO) since boot (offset 80)
//   [uint32 adv_restart_failures]  bt_le_adv_start() errors on any restart path (offset 84)
//   [uint32 adv_watchdog_recoveries] times the watchdog found advertising stopped
//                                  while disconnected and restarted it (offset 88)
static struct bt_uuid_128 diagnostics_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10060, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 diagnostics_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10061, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 diagnostics_drops_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10062, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
#ifdef CONFIG_OMI_DIAG_LOG
// Characteristic C:  19B10063 — diag-log drain (Long-Read). Snapshot header + packed
//   16-byte records (see diag_log.h DIAG_LOG_HEADER_SIZE layout). Present only when
//   CONFIG_OMI_DIAG_LOG is built (advertised via OMI_FEATURE_DIAG_LOG).
// Characteristic D:  19B10064 — diag-log control (Write). 5 bytes [u8 enable][u32 ack_seq]:
//   enable sets the runtime gate; ack_seq (non-zero) drops records with seq <= ack_seq.
static struct bt_uuid_128 diag_log_read_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10063, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 diag_log_control_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10064, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
#endif

static ssize_t diagnostics_read_handler(struct bt_conn *conn,
                                        const struct bt_gatt_attr *attr,
                                        void *buf,
                                        uint16_t len,
                                        uint16_t offset)
{
    uint32_t cause = app_settings_get_last_reset_cause();
    uint32_t uptime_s = (uint32_t) (app_settings_get_crash_session_uptime() / 1000);
    uint8_t payload[8] = {
        (uint8_t) (cause),
        (uint8_t) (cause >> 8),
        (uint8_t) (cause >> 16),
        (uint8_t) (cause >> 24),
        (uint8_t) (uptime_s),
        (uint8_t) (uptime_s >> 8),
        (uint8_t) (uptime_s >> 16),
        (uint8_t) (uptime_s >> 24),
    };
    return bt_gatt_attr_read(conn, attr, buf, len, offset, payload, sizeof(payload));
}

static inline void pack_u32_le(uint8_t *dst, uint32_t v)
{
    dst[0] = (uint8_t) (v);
    dst[1] = (uint8_t) (v >> 8);
    dst[2] = (uint8_t) (v >> 16);
    dst[3] = (uint8_t) (v >> 24);
}

/* Pack the 92-byte drop-counter payload. Shared by the read handler (0x0062)
 * and the notify path (diagnostics_drops_notify) so the wire layout has exactly
 * one definition. */
static void diagnostics_drops_pack(uint8_t payload[92])
{
    uint32_t block_drops = (uint32_t) atomic_get(&storage_block_drops);
    uint32_t last_drop_ms = (uint32_t) atomic_get(&last_storage_drop_uptime_ms);
    uint32_t sd_stream_drops = sd_get_stream_dropped_frames();
    uint32_t sd_boot_drops = sd_get_boot_dropped_frames();
    uint32_t now_ms = (uint32_t) k_uptime_get();
    uint32_t conn_fails = (uint32_t) atomic_get(&failed_conn_count);
    uint32_t codec_drops = codec_get_dropped_frames();
    uint32_t msgq_peak = sd_get_msgq_peak_depth();
    uint32_t fair_acts = sd_get_write_fair_activations();
    uint32_t estab_fails = (uint32_t) atomic_get(&estab_fail_count);
    uint32_t prio_starts = (uint32_t) atomic_get(&priority_record_starts);
    uint32_t prio_stops = (uint32_t) atomic_get(&priority_record_stops);
    uint32_t mk_drops = (uint32_t) atomic_get(&marker_write_drops);
    uint32_t empty_rots = sd_get_empty_bin_rotations();
    uint32_t se_emits = (uint32_t) atomic_get(&session_end_marker_emits);
    uint32_t mk_pause_saves = sd_get_marker_pause_gate_saves();
    uint32_t sd_stack_used = sd_get_worker_stack_used();
    uint32_t codec_stack_used = codec_get_stack_used();
    uint32_t ring_max_io = sd_get_ring_max_io_ms();
    uint32_t ring_io_errs = sd_get_ring_io_errors();
    uint32_t adv_fails = (uint32_t) atomic_get(&adv_restart_failures);
    uint32_t adv_rescues = (uint32_t) atomic_get(&adv_watchdog_recoveries);

    /* 92 bytes: legacy u32 drops + conn_fail count + last-failure adv mode +
     * codec_drops + sd_msgq peak depth + write-fairness activations + establishment
     * failures + Priority Recording lifecycle (starts / stops / marker drops /
     * empty-bin rotations) + session-end emit attempts + pause-gate marker saves +
     * sd_worker & codec peak stack used + ring_max_io_ms + ring_io_errors. Each field
     * is appended at the end so older app builds (which read only the first
     * 20 / 28 / 32 / 40 / 44 / 60 / 68 / 76 / 84 bytes) keep working unchanged. */
    pack_u32_le(payload + 0, block_drops);
    pack_u32_le(payload + 4, last_drop_ms);
    pack_u32_le(payload + 8, sd_stream_drops);
    pack_u32_le(payload + 12, sd_boot_drops);
    pack_u32_le(payload + 16, now_ms);
    pack_u32_le(payload + 20, conn_fails);
    pack_u32_le(payload + 24, (uint32_t) last_failed_adv_slow);
    pack_u32_le(payload + 28, codec_drops);
    pack_u32_le(payload + 32, msgq_peak);
    pack_u32_le(payload + 36, fair_acts);
    pack_u32_le(payload + 40, estab_fails);
    pack_u32_le(payload + 44, prio_starts);
    pack_u32_le(payload + 48, prio_stops);
    pack_u32_le(payload + 52, mk_drops);
    pack_u32_le(payload + 56, empty_rots);
    pack_u32_le(payload + 60, se_emits);
    pack_u32_le(payload + 64, mk_pause_saves);
    pack_u32_le(payload + 68, sd_stack_used);
    pack_u32_le(payload + 72, codec_stack_used);
    pack_u32_le(payload + 76, ring_max_io);
    pack_u32_le(payload + 80, ring_io_errs);
    pack_u32_le(payload + 84, adv_fails);
    pack_u32_le(payload + 88, adv_rescues);
}

static ssize_t diagnostics_drops_read_handler(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset)
{
    uint8_t payload[92];
    diagnostics_drops_pack(payload);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, payload, sizeof(payload));
}

/* Drop counters are also pushed as a notification (0x0062) so the app's
 * diagnostics view updates live *during* an SD sync — a GATT read would race
 * the storage notify stream and throw Error 133 on Android, so the app can't
 * poll while syncing. Firmware pushes instead: fast cadence during a transfer
 * (when the counters actually move and the live view matters), slow heartbeat
 * otherwise (keeps the live uptime ticking at negligible cost). Emits only
 * while a client is subscribed. */
static void diagnostics_drops_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value);
static atomic_t diag_notify_subscribed = ATOMIC_INIT(0);
#define DIAG_NOTIFY_SYNC_MS 2000
#define DIAG_NOTIFY_IDLE_MS 15000

#ifdef CONFIG_OMI_DIAG_LOG
/* 0x0063 drain read: serve the [offset, offset+len) slice of the snapshot blob
 * directly into the ATT buffer. diag_log_drain snapshots the ring on the offset-0
 * read so a GATT Long Read returns a stable blob; we don't route through
 * bt_gatt_attr_read because the drain already handles offset addressing. */
static ssize_t diag_log_read_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     void *buf,
                                     uint16_t len,
                                     uint16_t offset)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    return (ssize_t) diag_log_drain((uint8_t *) buf, len, offset);
}

/* 0x0064 control write: [u8 enable][u32 ack_seq LE] (5 bytes). enable sets the
 * runtime gate; a non-zero ack_seq drops all records with seq <= ack_seq. A
 * short/malformed write is rejected (fail-closed — this both gates capture and
 * discards records). */
static ssize_t diag_log_control_write_handler(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              const void *buf,
                                              uint16_t len,
                                              uint16_t offset,
                                              uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len != 5) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    const uint8_t *b = (const uint8_t *) buf;
    bool enable = (b[0] != 0);
    uint32_t ack_seq = (uint32_t) b[1] | ((uint32_t) b[2] << 8) | ((uint32_t) b[3] << 16) | ((uint32_t) b[4] << 24);

    diag_log_set_enabled(enable);
    if (ack_seq != 0) {
        diag_log_ack(ack_seq);
    }
    LOG_INF("diag-log control: enable=%d ack_seq=%u (dropped=%u)", (int) enable, ack_seq, diag_log_dropped_count());
    return len;
}
#endif // CONFIG_OMI_DIAG_LOG

static struct bt_gatt_attr diagnostics_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&diagnostics_service_uuid),
    BT_GATT_CHARACTERISTIC(&diagnostics_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           diagnostics_read_handler,
                           NULL,
                           NULL),
    /* Drops characteristic — appended last so existing diagnostics handles
     * stay stable across firmware revisions. READ (poll) + NOTIFY (live during
     * sync); the CCC that follows is the last attribute in the service. */
    BT_GATT_CHARACTERISTIC(&diagnostics_drops_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           diagnostics_drops_read_handler,
                           NULL,
                           NULL),
    BT_GATT_CCC(diagnostics_drops_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
#ifdef CONFIG_OMI_DIAG_LOG
    /* Diag-log drain + control — appended AFTER the 0x0062 CCC so the notify value
     * attribute stays at index 4 (diagnostics_drops_notify) regardless of this build
     * option. */
    BT_GATT_CHARACTERISTIC(&diag_log_read_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           diag_log_read_handler,
                           NULL,
                           NULL),
    BT_GATT_CHARACTERISTIC(&diag_log_control_characteristic_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           diag_log_control_write_handler,
                           NULL),
#endif
};

static struct bt_gatt_service diagnostics_service = BT_GATT_SERVICE(diagnostics_service_attr);

/* Notify the 92-byte drop payload to every subscribed client. The value
 * attribute is index 4: [0]=service, [1]/[2]=0x0061 decl/value,
 * [3]/[4]=0x0062 decl/value, [5]=CCC.
 *
 * A 92-byte notification needs ATT_MTU >= 95; on a link that never negotiated up
 * from the 23-byte default bt_gatt_notify returns -EMSGSIZE and the update is lost.
 *
 * Growth headroom, since this payload is append-only and keeps growing: a notify is
 * a single ATT PDU (no read-blob continuation), so the ceiling is ATT_MTU - 3 = 495
 * with CONFIG_BT_L2CAP_TX_MTU=498 — about 100 more u32 counters. The READ path is
 * bounded instead by the 512-byte ATT attribute-value maximum. Past ~495 the notify
 * path would start failing on healthy links, not just tiny-MTU ones, and the app
 * would silently fall back to polling READs.
 * This is a *live* convenience path — the same payload is always available via a
 * plain READ (ATT read-blob is not MTU-bounded), which is the app's fallback — so we
 * don't defer or fragment here, but we no longer drop the error on the floor: log it
 * (rate-limited by the caller's 2 s/15 s cadence) so a chronically small MTU is
 * visible instead of silent. In practice CONFIG_BT_L2CAP_TX_MTU=498 with
 * AUTO_UPDATE_MTU makes this the rare exception, not the rule. */
static void diagnostics_drops_notify(void)
{
    uint8_t payload[92];
    diagnostics_drops_pack(payload);
    int err = bt_gatt_notify(NULL, &diagnostics_service_attr[4], payload, sizeof(payload));
    if (err && err != -ENOTCONN) {
        LOG_DBG("diagnostics notify skipped (err %d) — client can still READ 0x0062", err);
    }
}

static void diagnostics_notify_work_handler(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(diagnostics_notify_work, diagnostics_notify_work_handler);

static void diagnostics_notify_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    /* Stop the chain if the client unsubscribed or the link dropped; a fresh
     * subscribe re-arms it from diagnostics_drops_ccc_changed. */
    if (!atomic_get(&diag_notify_subscribed) || !atomic_get(&is_connected)) {
        return;
    }
    diagnostics_drops_notify();
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    uint32_t next = storage_transfer_active() ? DIAG_NOTIFY_SYNC_MS : DIAG_NOTIFY_IDLE_MS;
#else
    uint32_t next = DIAG_NOTIFY_IDLE_MS;
#endif
    k_work_reschedule(&diagnostics_notify_work, K_MSEC(next));
}

static void diagnostics_drops_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ARG_UNUSED(attr);
    if (value == BT_GATT_CCC_NOTIFY) {
        atomic_set(&diag_notify_subscribed, 1);
        /* Push immediately on subscribe, then the handler self-reschedules. */
        k_work_reschedule(&diagnostics_notify_work, K_NO_WAIT);
    } else {
        atomic_set(&diag_notify_subscribed, 0);
        k_work_cancel_delayable(&diagnostics_notify_work);
    }
}

/* Re-arm the diagnostics notify cadence immediately. Called from the storage thread
 * when a transfer becomes active: the notify handler only re-evaluates idle (15 s) vs
 * sync (2 s) cadence when it next fires, so a sync starting mid-idle-interval would
 * otherwise coast up to 15 s on the stale slow cadence before the live 2 s updates
 * kick in. Firing it now switches to the 2 s cadence at once (~0 s lag). No-op when
 * nothing is subscribed. */
void transport_diagnostics_kick(void)
{
    if (atomic_get(&diag_notify_subscribed)) {
        k_work_reschedule(&diagnostics_notify_work, K_NO_WAIT);
    }
}

// --- Button Service ---
// Service UUID: 23BA7924-0000-1000-7450-346EAC492E92
// Characteristics:
//   - Button Trigger (23BA7925): Notify 1 byte (0=released, 1=pressed)
static struct bt_uuid_128 button_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7924, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
static struct bt_uuid_128 button_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7925, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
// Button + haptic config UUIDs moved to the Settings service (0x19B10015 / 0x19B10016);
// the 23BA7926 service was retired during the config-characteristic consolidation.

static ssize_t button_config_read_handler(struct bt_conn *conn,
                                          const struct bt_gatt_attr *attr,
                                          void *buf,
                                          uint16_t len,
                                          uint16_t offset)
{
    uint8_t config[6];
    app_settings_get_button_config(config);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, config, sizeof(config));
}

static ssize_t button_config_write_handler(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           const void *buf,
                                           uint16_t len,
                                           uint16_t offset,
                                           uint8_t flags)
{
    if (len != 6) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    // Reject out-of-range actions so we never persist a config the FSM can't map.
    const uint8_t *cfg = (const uint8_t *) buf;
    for (int i = 0; i < 6; i++) {
        if (cfg[i] > BUTTON_ACTION_RECORD_TOGGLE) {
            return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
        }
    }
    app_settings_save_button_config(cfg);
    return len;
}

static ssize_t haptic_config_read_handler(struct bt_conn *conn,
                                          const struct bt_gatt_attr *attr,
                                          void *buf,
                                          uint16_t len,
                                          uint16_t offset)
{
    uint8_t config[6];
    app_settings_get_haptic_config(config);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, config, sizeof(config));
}

static ssize_t haptic_config_write_handler(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           const void *buf,
                                           uint16_t len,
                                           uint16_t offset,
                                           uint8_t flags)
{
    if (len != 6) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    // Reject out-of-range patterns (0=Off, 1=Single, 2=Double, 3=Triple).
    const uint8_t *cfg = (const uint8_t *) buf;
    for (int i = 0; i < 6; i++) {
        if (cfg[i] > 3) {
            return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
        }
    }
    app_settings_save_haptic_config(cfg);
    return len;
}

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
    BT_GATT_CHARACTERISTIC(&button_characteristic_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE, NULL, NULL, NULL),
    BT_GATT_CCC(button_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
};

struct bt_gatt_service button_service = BT_GATT_SERVICE(button_service_attr);

/* The button-config + haptic-config characteristics now live in the Settings
 * service (0x19B10015 / 0x19B10016); the standalone 23BA7926 service was retired.
 * Their handlers (button_config_*_handler / haptic_config_*_handler, above) are
 * unchanged and are referenced from settings_service_attr. */

void transport_notify_button_state(uint8_t state)
{
    bt_gatt_notify(NULL, &button_service_attr[2], &state, sizeof(state));
}

// --- Mute Service ---
// Service UUID:    19B10070-E8F2-537E-4F6C-D104768A1214
// Characteristic:  19B10071-E8F2-537E-4F6C-D104768A1214 (Read / Write / Notify)
//   Read/Notify 9 bytes LE: [uint8 muted][uint32 since_utc_s][uint32 since_uptime_ms]
//     muted: 1 while the mic is muted (double-tap-hold or BLE write), else 0.
//     since_utc_s: RTC epoch seconds when mute was engaged (0 when not muted or
//       pre-time-sync). since_uptime_ms: monotonic ms at engage, so the app can
//       derive wall time after it time-syncs even if the RTC was unset.
//   Write 1 byte: 0 = unmute, non-zero = mute. Honored only in auto mode (a
//     no-op in manual mode, mirroring the physical-button gate).
// Notify is intentionally ungated during file sync: mute changes are rare,
// user-driven events (one packet), unlike the periodic battery-detail notify.
static struct bt_uuid_128 mute_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10070, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 mute_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10071, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static void mute_pack_payload(uint8_t *payload)
{
    uint8_t muted = 0;
    uint32_t since_utc_s = 0;
    uint32_t since_uptime_ms = 0;
    mute_get_state(&muted, &since_utc_s, &since_uptime_ms);
    payload[0] = muted;
    pack_u32_le(payload + 1, since_utc_s);
    pack_u32_le(payload + 5, since_uptime_ms);
}

static ssize_t
mute_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
{
    uint8_t payload[9];
    mute_pack_payload(payload);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, payload, sizeof(payload));
}

static ssize_t mute_write_handler(struct bt_conn *conn,
                                  const struct bt_gatt_attr *attr,
                                  const void *buf,
                                  uint16_t len,
                                  uint16_t offset,
                                  uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len < 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    mute_apply(((const uint8_t *) buf)[0] != 0);
    return len;
}

static void mute_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ARG_UNUSED(attr);
    // Push the current state on subscribe so the app doesn't wait for a change.
    if (value == BT_GATT_CCC_NOTIFY) {
        mute_state_notify();
    }
}

static struct bt_gatt_attr mute_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&mute_service_uuid),
    BT_GATT_CHARACTERISTIC(&mute_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           mute_read_handler,
                           mute_write_handler,
                           NULL),
    BT_GATT_CCC(mute_ccc_changed, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
};

static struct bt_gatt_service mute_service = BT_GATT_SERVICE(mute_service_attr);

// --- LED Service ---
// Service UUID:    19B10080-E8F2-537E-4F6C-D104768A1214
// Characteristic A: 19B10081-E8F2-537E-4F6C-D104768A1214 (Read / Write)
//   1 byte: 0 = the connected (solid blue) indicator is off, non-zero = on.
//   Default on, so an updated device behaves exactly as it did before.
// Characteristic B: 19B10082-E8F2-537E-4F6C-D104768A1214 (Read / Write)
//   1 byte: the boot value of is_led_enabled, the LED master gate. 0 (default)
//   = LEDs start off every boot, the historical behaviour; non-zero = they come
//   up on. A write applies to the live state as well, so the app's switch does
//   something visible immediately rather than only after the next restart.
//   Read returns the persisted default, NOT the live gate: the button gesture
//   still toggles the session's state without changing what the device returns
//   to on reboot, and a read that tracked the gesture would make the app's
//   write-then-verify disagree with what it just stored.
// Deliberately its OWN service rather than more Settings characteristics:
// Settings is registered first, so growing it renumbers every service after it
// and forces bonded peers to re-pair. Registered last (after mute), this leaves
// every existing handle untouched — which is also why characteristic B could be
// added here for free, while adding it to Settings could not.
static struct bt_uuid_128 led_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10080, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 led_connected_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10081, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 led_boot_characteristic_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10082, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static ssize_t led_connected_write_handler(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           const void *buf,
                                           uint16_t len,
                                           uint16_t offset,
                                           uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len != 1) {
        LOG_WRN("Invalid length for connected-LED write: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    bool enabled = ((const uint8_t *) buf)[0] != 0;
    LOG_INF("Received connected-LED setting: %u", (unsigned int) enabled);
    int err = app_settings_save_connected_led(enabled);
    if (err) {
        /* The save is the whole operation here — it leaves the in-memory value
         * untouched on failure, so nothing changed. ACKing success would report
         * a setting the device neither applied nor stored. */
        LOG_ERR("Failed to save connected-LED setting: %d", err);
        return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
    }

    /* No explicit refresh needed — the main loop re-evaluates set_led_state()
     * every ~500 ms, so the change lands within one pass. */
    return len;
}

static ssize_t led_connected_read_handler(struct bt_conn *conn,
                                          const struct bt_gatt_attr *attr,
                                          void *buf,
                                          uint16_t len,
                                          uint16_t offset)
{
    uint8_t enabled = app_settings_get_connected_led() ? 1 : 0;
    LOG_INF("Reading connected-LED setting: %u", (unsigned int) enabled);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &enabled, sizeof(enabled));
}

static ssize_t led_boot_write_handler(struct bt_conn *conn,
                                      const struct bt_gatt_attr *attr,
                                      const void *buf,
                                      uint16_t len,
                                      uint16_t offset,
                                      uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len != 1) {
        LOG_WRN("Invalid length for LED-boot write: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    bool enabled = ((const uint8_t *) buf)[0] != 0;
    LOG_INF("Received LED-boot setting: %u", (unsigned int) enabled);
    int err = app_settings_save_led_boot_enabled(enabled);

    /* Apply to the live gate regardless, so the change is visible without a
     * restart — the user asked for this state now, and that much still works
     * even if the flash write failed. */
    is_led_enabled = enabled;

    if (err) {
        /* But do NOT ACK success: this characteristic's contract is the *boot
         * default*, and that is exactly the half that didn't survive. A silent
         * ACK would show a default that reverts on the next reboot. */
        LOG_ERR("Failed to save LED-boot setting: %d", err);
        return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
    }
    return len;
}

static ssize_t led_boot_read_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     void *buf,
                                     uint16_t len,
                                     uint16_t offset)
{
    uint8_t enabled = app_settings_get_led_boot_enabled() ? 1 : 0;
    LOG_INF("Reading LED-boot setting: %u", (unsigned int) enabled);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &enabled, sizeof(enabled));
}

static struct bt_gatt_attr led_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&led_service_uuid),
    BT_GATT_CHARACTERISTIC(&led_connected_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           led_connected_read_handler,
                           led_connected_write_handler,
                           NULL),
    BT_GATT_CHARACTERISTIC(&led_boot_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT,
                           led_boot_read_handler,
                           led_boot_write_handler,
                           NULL),
};

static struct bt_gatt_service led_service = BT_GATT_SERVICE(led_service_attr);

void mute_state_notify(void)
{
    uint8_t payload[9];
    mute_pack_payload(payload);
    bt_gatt_notify(NULL, &mute_service_attr[2], payload, sizeof(payload));
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

    /* Capture the outgoing mode before the save overwrites it. Manual is 32769
     * (standby) or 65535 (recording); anything lower is an auto sensitivity. */
    const uint16_t prev_threshold = app_settings_get_vad_threshold();

    int err = app_settings_save_vad_threshold(new_threshold);
    if (err) {
        LOG_ERR("Failed to save VAD threshold setting: %d", err);
    }

    // Apply the threshold immediately
    aad_set_threshold(new_threshold);

    /* Switching manual -> automatic hands capture back to the hardware wake line,
     * which is exactly where a wedged mic goes unnoticed (nothing auto-records and
     * no button press is coming to mask it). Start that mode on a freshly powered
     * part. Only this direction needs it: the manual paths reset the mic on every
     * record start/stop themselves, and an auto -> auto sensitivity tweak never
     * changes who is driving capture. */
    if (prev_threshold >= 32769 && new_threshold < 32769) {
        LOG_INF("VAD threshold: manual -> automatic, resetting mic");
        mic_reset();
    }

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

static ssize_t settings_priority_cap_write_handler(struct bt_conn *conn,
                                                   const struct bt_gatt_attr *attr,
                                                   const void *buf,
                                                   uint16_t len,
                                                   uint16_t offset,
                                                   uint8_t flags)
{
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len != 2) {
        LOG_WRN("Invalid length for priority-record cap write: %u", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint16_t minutes;
    memcpy(&minutes, buf, 2);

    LOG_INF("Received new priority-record cap: %u minutes", minutes);
    int err = app_settings_save_priority_record_max_minutes(minutes);
    if (err) {
        LOG_ERR("Failed to save priority-record cap setting: %d", err);
    }
    // Takes effect on the next auto-mode Priority Recording start; an already-armed
    // cap on an in-progress recording keeps the value it was armed with.

    return len;
}

static ssize_t settings_priority_cap_read_handler(struct bt_conn *conn,
                                                  const struct bt_gatt_attr *attr,
                                                  void *buf,
                                                  uint16_t len,
                                                  uint16_t offset)
{
    uint16_t minutes = app_settings_get_priority_record_max_minutes();
    LOG_INF("Reading priority-record cap: %u minutes", minutes);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &minutes, sizeof(minutes));
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
    // The LED service (0x19B10080 / 0x19B10081) is always registered.
    features |= OMI_FEATURE_LED_SERVICE;
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    // Priority Recording (and thus its configurable safety cap) exists only on AAD builds.
    features |= OMI_FEATURE_PRIORITY_RECORD_CAP;
    // The RECORD_TOGGLE action toggles a manual recording / auto priority
    // recording — both require AAD, so advertise it only on AAD builds.
    features |= OMI_FEATURE_RECORD_TOGGLE;
#endif
#ifdef CONFIG_OMI_DIAG_LOG
    // On-device diagnostic event log compiled in — 0x0063/0x0064 chars present.
    features |= OMI_FEATURE_DIAG_LOG;
#endif

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
#define BATTERY_REFRESH_INTERVAL_CONNECTED 60000     // 60 seconds while connected
#define BATTERY_REFRESH_INTERVAL_DISCONNECTED 300000 // 5 minutes while offline
#define CONFIG_OMI_BATTERY_CRITICAL_MV 3500          // mV
/* Below this percentage the 150mAh cell's internal resistance rises sharply, so
 * a brownout mid-write is more likely. We flush once here so everything captured
 * so far is durable, but recording CONTINUES — a recorder should capture to the
 * critical-voltage shutdown, not stop at 15%. littlefs is power-loss resilient,
 * so a brownout costs at most the last unsynced frames; the clean shutdown still
 * happens at CONFIG_OMI_BATTERY_CRITICAL_MV. */
#define BATTERY_LOW_SD_FLUSH_THRESHOLD 15 // %
uint8_t battery_percentage = 100;
bool battery_ready = false;
static bool sd_flushed_for_low_battery = false;
void broadcast_battery_level(struct k_work *work_item);

K_WORK_DELAYABLE_DEFINE(battery_work, broadcast_battery_level);

/* Non-blocking retry for the 1-byte charging-state notify. broadcast_battery_level runs
 * on the system workqueue, so we must NOT sleep-retry there — blocking it would stall
 * unrelated work during the exact sync-pressure window this targets. On -ENOMEM (TX
 * buffers momentarily full mid-sync) we stash the byte and reschedule this delayable
 * work a couple of times; if it still can't send, the next battery cycle (~60 s)
 * re-sends. Both this and battery_work run on the system workqueue, so the retry-count
 * accesses are serialized (no lock needed). */
static uint8_t pending_charging_byte;
static atomic_t charging_retry_left;
static void charging_notify_try(uint8_t byte);

static void charging_notify_retry_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    charging_notify_try(pending_charging_byte);
}
static K_WORK_DELAYABLE_DEFINE(charging_notify_retry_work, charging_notify_retry_handler);

static void charging_notify_try(uint8_t byte)
{
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        int nerr = bt_gatt_notify(NULL, &battery_detail_service_attr[2], &byte, 1);
        if (nerr == -ENOMEM && atomic_get(&charging_retry_left) > 0) {
            atomic_dec(&charging_retry_left);
            pending_charging_byte = byte;
            k_work_reschedule(&charging_notify_retry_work, K_MSEC(50));
        } else if (nerr && nerr != -ENOTCONN) {
            LOG_DBG("charging notify failed: %d (next battery cycle re-sends)", nerr);
        }
    }
    put_current_connection(conn);
}

void broadcast_battery_level(struct k_work *work_item)
{
    uint16_t battery_millivolt;

    if (battery_get_millivolt(&battery_millivolt) == 0 &&
        battery_get_percentage(&battery_percentage, battery_millivolt) == 0) {

        battery_ready = true;
        LOG_PRINTK("Battery at %d mV (capacity %d%%)\n", battery_millivolt, battery_percentage);

        int err = bt_bas_set_battery_level(battery_percentage);
        if (err) {
            LOG_ERR("Error updating battery level: %d", err);
        }

        /* Notify charging state even during an active file sync (the old
         * storage_transfer_active() skip froze the app's charging state for the whole,
         * often long, duration of a sync). It's a 1-byte notify on the battery-refresh
         * cadence, so it can't starve the transfer. A transient -ENOMEM mid-sync is
         * retried off-thread (charging_notify_try) so the state stays live without
         * blocking this workqueue handler. Cancel any retry still pending from a prior
         * cycle first, so a stale byte can't land after this newer state. */
        k_work_cancel_delayable(&charging_notify_retry_work);
        atomic_set(&charging_retry_left, 2);
        charging_notify_try((uint8_t) is_charging);

        /* Flush once when we first drop into the low-battery zone so everything
         * captured so far is durable before the high-internal-resistance region.
         * Recording is NOT paused — it continues until the critical-voltage clean
         * shutdown below. Re-arms if the battery recovers above the threshold. */
        if (!is_charging && battery_percentage <= BATTERY_LOW_SD_FLUSH_THRESHOLD && !sd_flushed_for_low_battery) {
            LOG_WRN("Battery low (%d%%) — flushing SD; recording continues to critical shutdown", battery_percentage);
            sd_flush_current_file();
            sd_flushed_for_low_battery = true;
        } else if (sd_flushed_for_low_battery && (is_charging || battery_percentage > BATTERY_LOW_SD_FLUSH_THRESHOLD)) {
            sd_flushed_for_low_battery = false;
        }

        if (battery_millivolt < CONFIG_OMI_BATTERY_CRITICAL_MV) {
            LOG_WRN("Battery critical level reached (%d mV). Initiating shutdown.", battery_millivolt);
            turnoff_all();
        }
    } else {
        LOG_ERR("Failed to read battery level");
    }

    uint32_t interval =
        atomic_get(&is_connected) ? BATTERY_REFRESH_INTERVAL_CONNECTED : BATTERY_REFRESH_INTERVAL_DISCONNECTED;
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
        uint8_t is_charging_byte = (uint8_t) is_charging;
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
#define MTU_RECHECK_DELAY_MS 800
#define MTU_RECHECK_MAX_ATTEMPTS 6
static uint8_t mtu_recheck_attempts = 0;
static void mtu_recheck_work_handler(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(mtu_recheck_work, mtu_recheck_work_handler);

static void post_pairing_work_handler(struct k_work *work)
{
    if (!atomic_get(&is_connected) || !current_connection) {
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
    if (!atomic_get(&is_connected) || !current_connection) {
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
 * MUST stay above the app's foreground keep-alive interval (5 s, see
 * device_provider.dart _startForegroundKeepAlive). A timeout at/below that
 * interval makes the heartbeat structurally unable to keep the link up: the
 * device idle-drops before the next keep-alive arrives, producing a permanent
 * connect/disconnect loop (BT_HCI_ERR_REMOTE_USER_TERM_CONN / gatt_status_19).
 * 15 s gives the 5 s keep-alive a 10 s margin (survives two missed beats). */
#define IDLE_DISCONNECT_TIMEOUT_MS 15000
#define IDLE_DISCONNECT_POLL_MS 5000

static atomic_t last_activity_ms;

void transport_mark_activity(void)
{
    atomic_set(&last_activity_ms, (atomic_val_t) k_uptime_get_32());
}

static void idle_disconnect_work_handler(struct k_work *work)
{
    if (!atomic_get(&is_connected)) {
        return;
    }

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    /* An in-progress storage transfer is liveness on its own. A slow consumer —
     * notably iOS, where the file read runs packet-by-packet in Dart rather than
     * natively as on Android — can back-pressure the firmware TX so that no
     * notification (hence no transport_mark_activity() from write_to_gatt) happens
     * for >15 s, even though the link is healthy and actively draining a file. The
     * app's foreground keep-alive is also deliberately skipped during a transfer
     * (it would race the read stream). Without this guard the link idle-drops
     * mid-transfer (REMOTE_USER_TERM_CONN) and the resumed transfer drops again,
     * looping. Defer the idle check while a transfer is active; the BLE supervision
     * timeout still backstops a genuinely dead link. */
    if (storage_transfer_active()) {
        k_work_schedule(k_work_delayable_from_work(work), K_MSEC(IDLE_DISCONNECT_POLL_MS));
        return;
    }

    /* Same liveness exemption for a DFU image upload. DFU traffic rides the SMP
     * characteristic, which never calls transport_mark_activity(), so a multi-
     * minute flash would otherwise blow past the 15 s idle window and drop the
     * link mid-update (the app's keep-alive is only a best-effort backstop and is
     * easily starved under SMP saturation). ota_active is bracketed by the DFU
     * STARTED/STOPPED mgmt callbacks and cleared on disconnect, so it cannot get
     * stuck and permanently defeat idle-disconnect. */
    if (sd_get_ota_active()) {
        k_work_schedule(k_work_delayable_from_work(work), K_MSEC(IDLE_DISCONNECT_POLL_MS));
        return;
    }
#endif

    uint32_t now = k_uptime_get_32();
    uint32_t last = (uint32_t) atomic_get(&last_activity_ms);
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
    uint32_t idle_ms_locked = k_uptime_get_32() - (uint32_t) atomic_get(&last_activity_ms);
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

/* iOS-compatible connection-parameter fallback. update_conn_params() requests an
 * aggressive 7.5 ms interval; Apple rejects any request with interval_min < 15 ms
 * outright, so on iOS the link silently stays at iOS's slow default (~30 ms).
 * Android is unaffected — its central drives the interval to ~11.25 ms via
 * CONNECTION_PRIORITY_HIGH regardless of what we ask for. A few seconds after
 * connect we recheck the *actual* negotiated interval and, only if it's still
 * slow (request not honored — i.e. an iOS-like central), send one Apple-compliant
 * request. On Android the interval is already fast by then, so this no-ops and
 * Android keeps ~11.25 ms. One-shot: never rescheduled, so a compliant request
 * landing iOS at 30 ms can't loop. */
#define CONN_PARAM_RECHECK_DELAY_MS 3000
/* Negotiated interval (1.25 ms units) above which the aggressive request is
 * treated as not honored. Our aggressive request maxes at 18 (22.5 ms). */
#define CONN_PARAM_FAST_MAX_INTERVAL 18
static void conn_param_recheck_work_handler(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(conn_param_recheck_work, conn_param_recheck_work_handler);

/* Advertising restart guard — the work items are declared up here so
 * _transport_connected can cancel them; the handlers, parameters and helpers all
 * live just below _transport_disconnected, next to the restart path they serve. */
static void adv_restart_work_handler(struct k_work *work);
static void adv_watchdog_work_handler(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(adv_restart_work, adv_restart_work_handler);
K_WORK_DELAYABLE_DEFINE(adv_watchdog_work, adv_watchdog_work_handler);

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
        uint32_t fails = (uint32_t) atomic_inc(&failed_conn_count) + 1;
        last_failed_adv_slow = (current_adv_mode[0] == 's') ? 1 : 0; /* "slow" vs "fast" */
        LOG_ERR("Connection failed (err 0x%02x) adv_mode=%s failed_conn_count=%u uptime=%lld ms",
                err,
                current_adv_mode,
                fails,
                (long long) k_uptime_get());
        /* Coalesced flash persist so the count survives the power-cycle needed to read it. */
        k_work_schedule(&conn_fail_persist_work, K_MSEC(CONN_FAIL_PERSIST_DELAY_MS));
        return;
    }

    /* Claim the link and silence the advertising guard FIRST, before the lengthy
     * setup below. Until both happen the guard still believes we are disconnected,
     * so a restart/watchdog tick landing mid-setup calls bt_le_adv_start() against a
     * live link — which fails -ENOMEM under CONFIG_BT_MAX_CONN=1 and is then counted
     * as adv_restart_failures and retried. That is fabricated telemetry in the one
     * counter this whole guard exists to make trustworthy. Any later failure path in
     * this callback ends in a disconnect, whose callback re-arms both. */
    atomic_set(&is_connected, 1);
    k_work_cancel_delayable(&adv_restart_work);
    k_work_cancel_delayable(&adv_watchdog_work);

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

    // Recheck the negotiated interval shortly after; if the aggressive request
    // above was rejected (iOS), retry with Apple-compliant params. See above.
    k_work_schedule(&conn_param_recheck_work, K_MSEC(CONN_PARAM_RECHECK_DELAY_MS));

    k_work_schedule(&post_connect_work, K_MSEC(500));

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    sd_notify_ble_state(true);
#endif

    /* is_connected and the guard cancels were hoisted to the top of this callback —
     * see the comment there. */
    transport_mark_activity();
    k_work_schedule(&idle_disconnect_work, K_MSEC(IDLE_DISCONNECT_POLL_MS));
}

/* ── Advertising restart guard ──────────────────────────────────────────────
 *
 * Every path that (re)starts advertising can fail, and until oo-2.8.x every one of
 * them discarded the result. One failed bt_le_adv_start() left the device
 * permanently invisible — firmware running, SD still recording, radio silent —
 * with no route back except a power cycle.
 *
 * Confirmed on 2026-07-31 (BLE_Research.md, Wedge 5): a 2 h outage in which an
 * independent scanner heard nothing, ten in-app 8 s probes heard nothing, a 2.5 min
 * phone Bluetooth toggle changed nothing, and the device — uptime 33 h 40 m, no
 * reset, still holding 8 unsynced WALs — reconnected instantly on a power cycle.
 *
 * Two layers, because the failure is intermittent and silent:
 *   1. adv_restart_work  — retries a failed start with backoff, indefinitely.
 *   2. adv_watchdog_work — while disconnected, re-asserts advertising every
 *      ADV_WATCHDOG_INTERVAL_MS whatever the reason it stopped. This is the layer
 *      that bounds the damage: worst case the device is unreachable for one
 *      watchdog period instead of until someone notices and reboots it.
 *
 * The post-disconnect start is also *deferred* rather than made inline. With
 * CONFIG_BT_MAX_CONN=1 the stack still holds the disconnecting conn object while
 * the disconnected callback runs, so a connectable bt_le_adv_start() there can
 * fail -ENOMEM — the most likely trigger for the observed outage.
 */
#define ADV_RESTART_DEFER_MS 50
#define ADV_RESTART_RETRY_MS 500
#define ADV_RESTART_RETRY_MAX_MS 8000
#define ADV_WATCHDOG_INTERVAL_MS 60000

/* Slow advertising parameters for low-power mode (~1 s interval).
 * BT_LE_ADV_CONN uses 100-150ms by default; 1000-1200ms saves ~300-500 µA.
 * Advertising interval unit = 0.625 ms → 1000 ms = 1600, 1200 ms = 1920. */
static const struct bt_le_adv_param adv_param_slow =
    BT_LE_ADV_PARAM_INIT(BT_LE_ADV_OPT_CONNECTABLE | BT_LE_ADV_OPT_ONE_TIME, 1600, 1920, NULL);

/* atomic_t, not a plain u32: this is touched from the workqueue handlers, the AAD
 * thread (via adv_schedule_retry) and the BT RX thread, and concurrent access to a
 * non-atomic object is a data race in the C memory model regardless of whether the
 * underlying store happens to be single-instruction on this core. A lock is not an
 * option — guarding it would mean taking adv_mutex on the RX thread, the one thing
 * that must never happen (see adv_mutex).
 *
 * The escalation in adv_schedule_retry() is still a non-atomic read-modify-write, so
 * two racing failures can lose one doubling. That is deliberate and harmless: every
 * individual access is atomic (no UB), and the worst outcome is one retry firing at
 * half the intended delay, which the next success resets anyway. */
static atomic_t adv_retry_delay_ms = ATOMIC_INIT(ADV_RESTART_RETRY_MS);

/* Gate for the whole guard. 0 until transport_start() succeeds, and cleared again
 * at the very top of transport_off() — *before* it disconnects, which is the point:
 * bt_conn_disconnect() fires _transport_disconnected asynchronously on the BT RX
 * thread, so cancelling the work items alone would race that callback re-arming
 * them. Without this, every power-off queues a restart 50 ms out, turnoff_all()
 * then sleeps ~1 s before sys_poweroff(), and the handler runs bt_le_adv_start()
 * against a stack bt_disable() has already torn down. That is not merely noisy: it
 * returns -EAGAIN, drives the unbounded retry loop, and inflates
 * adv_restart_failures — poisoning the exact counter this guard exists to make
 * trustworthy. It also matters on the turnoff_all() TURNOFF_BAILED path, where the
 * device keeps running with BLE down instead of powering off. */
static atomic_t adv_guard_active = ATOMIC_INIT(0);

/* Serializes every advertising stop/start/mode change. Two distinct races need it:
 *
 * 1. AAD mode switches vs. the guard. transport_set_adv_slow() is stop → set mode →
 *    start; a retry/watchdog tick landing inside that window starts the *previous*
 *    interval, and the mode setter's own start then returns -EALREADY, which we
 *    treat as success. Net effect: we log "switched to slow" while the radio keeps
 *    advertising at the 100-150 ms fast interval — a silent battery regression that
 *    -EALREADY actively hides. Holding this across the whole sequence makes it
 *    atomic, so -EALREADY can no longer mask a stale-interval start.
 *
 * 2. Shutdown vs. an in-flight handler. k_work_cancel_delayable() does NOT wait for
 *    a handler that is already running, so a handler past its gate check could call
 *    bt_le_adv_start() after bt_disable(). Handlers hold this mutex across their
 *    start, so transport_off() can drain them by taking it.
 *
 *    A mutex, specifically — NOT k_work_cancel_delayable_sync(). turnoff_all() is
 *    reachable from broadcast_battery_level() (the critical-battery shutdown), which
 *    is itself a system-workqueue handler — the same queue adv_restart_work and
 *    adv_watchdog_work run on. A _sync() cancel there would block the workqueue
 *    thread waiting for work only that thread can run: a hard deadlock on the
 *    battery-critical path. The mutex is safe from all three shutdown contexts
 *    (button thread, storage thread, system workqueue), and on the workqueue path it
 *    is uncontended by construction, since a queue runs its items serially. */
 *
 *    One thread must NEVER take this mutex: the BT RX thread, i.e. the
 *    _transport_connected / _transport_disconnected callbacks. bt_le_adv_start() is
 *    an HCI command whose completion the RX thread itself processes, so a callback
 *    blocking on a mutex held by a thread inside bt_le_adv_start() would deadlock
 *    the stack. That constraint is what adv_pending_mode exists to satisfy. */
static K_MUTEX_DEFINE(adv_mutex);

/* Pending "come back up in fast mode" request from _transport_disconnected.
 *
 * The callback used to assign current_adv_mode = "fast" directly, which is the same
 * unsynchronized-mode-write race cubic found in the AAD setters, just at the write
 * site nobody was looking at: AAD holds adv_mutex, sets "slow", and the RX thread
 * overwrites it with "fast" before AAD's own adv_start_raw() reads it — so we start
 * the fast interval while logging "switched to slow". The obvious fix (lock the
 * callback) is exactly the deadlock forbidden above, so instead the callback only
 * raises a request and whoever next holds the lock applies it.
 *
 * That request is parked in adv_pending_mode (below) — the same slot an AAD switch
 * uses — so the post-disconnect reset runs as a real stop → set mode → start.
 * An earlier revision instead flipped current_adv_mode to "fast" inside
 * adv_start_raw() *before* the start returned, which was broken: a start that
 * answers -EALREADY has changed nothing, so if an advertiser was already running on
 * the slow interval we recorded "fast" while the radio stayed slow, with the request
 * already consumed and nothing left to correct it. The watchdog would then re-assert
 * "fast", get -EALREADY again, and call it healthy — permanently wrong, and wrong in
 * the direction that makes the device slower to rediscover, which is the entire
 * failure this PR exists to prevent. Only a stop actually changes the interval.
 *
 * Bonus correctness: current_adv_mode keeps its pre-disconnect value until the
 * restart actually runs, so the 0x3e diagnostic a few lines above — which records
 * the advertising mode in effect at the failure — reads the true mode rather than a
 * value already clobbered to "fast". */

/* Start advertising in whatever mode current_adv_mode selects. Returns the raw
 * bt_le_adv_start() result: 0 = we were NOT advertising and now are, -EALREADY =
 * already on the air (a healthy no-op), anything else = failure. Callers must keep
 * 0 and -EALREADY distinct — the watchdog uses exactly that difference to tell a
 * rescue from a no-op. Caller holds adv_mutex. */
static int adv_start_raw(void)
{
    if (current_adv_mode[0] == 's') {
        return bt_le_adv_start(&adv_param_slow, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    }
    return bt_le_adv_start(BT_LE_ADV_CONN, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
}

/* The one place an advertising-mode request waits to be applied. 0 = nothing
 * pending, otherwise ADV_MODE_FAST / ADV_MODE_SLOW. Two producers:
 *
 *   - an AAD switch whose stop or start failed, parked so it is retried rather than
 *     lost. Without this a transient bt_le_adv_stop() failure dropped the request
 *     outright: the setters return the error, but both aad.c callers discard the
 *     return value AND have already consumed their own request flag, so nothing ever
 *     retried and the device sat on the wrong interval — ~300-500 µA of avoidable
 *     drain on a 150 mAh cell — until the next VAD transition happened to ask again.
 *   - _transport_disconnected asking to come back up fast, which cannot touch
 *     current_adv_mode itself (it runs on the BT RX thread, which must never take
 *     adv_mutex).
 *
 * Last writer wins, which is the semantics we want: an explicit AAD request placed
 * after a disconnect supersedes the fast default, and a disconnect after a parked
 * switch supersedes it in turn (post-disconnect fast is correct, and AAD re-requests
 * slow at the next VAD sleep). */
#define ADV_MODE_FAST 1
#define ADV_MODE_SLOW 2
static atomic_t adv_pending_mode = ATOMIC_INIT(0);

static inline bool adv_pending_mode_pending(void)
{
    return atomic_get(&adv_pending_mode) != 0;
}

/* Apply stop → set mode → start as one unit. Caller holds adv_mutex.
 * Returns 0 / -EALREADY on success, else the failing errno with the request left
 * parked so the retry path picks it up again. */
static int adv_apply_mode_locked(int mode)
{
    int err = bt_le_adv_stop();
    if (err && err != -EALREADY) {
        atomic_set(&adv_pending_mode, (atomic_val_t) mode); /* park it, don't lose it */
        return err;
    }
    /* Only now, after a stop that actually took effect — this assignment must never
     * happen ahead of a start that could answer -EALREADY and change nothing. */
    current_adv_mode = (mode == ADV_MODE_SLOW) ? "slow" : "fast";
    err = adv_start_raw();
    if (err && err != -EALREADY) {
        atomic_set(&adv_pending_mode, (atomic_val_t) mode);
        return err;
    }
    atomic_set(&adv_pending_mode, 0);
    return 0;
}

/* Retry a parked mode switch. Caller holds adv_mutex. */
static int adv_apply_pending_mode_locked(void)
{
    int mode = (int) atomic_get(&adv_pending_mode);
    if (mode == 0) {
        return adv_start_raw();
    }
    return adv_apply_mode_locked(mode);
}

/* Record a failed start and queue another attempt. Never gives up: being
 * unreachable is a total loss of function, so an unbounded retry at an 8 s ceiling
 * is strictly better than any finite budget. */
static void adv_schedule_retry(int err, const char *who)
{
    if (!atomic_get(&adv_guard_active)) {
        return; /* shutting down — not a real failure, and must not be counted */
    }
    if (atomic_get(&is_connected)) {
        /* A link came up between a handler's gate check and its bt_le_adv_start().
         * The cancel in _transport_connected only drops *pending* work, and the RX
         * thread cannot drain a running handler via adv_mutex (that is the forbidden
         * lock), so this window cannot be closed on the producer side — and re-checking
         * just before the start call would only narrow it, never remove it.
         *
         * Close it here instead, where it actually matters: the failure is fully
         * explained by the live link (-ENOMEM under CONFIG_BT_MAX_CONN=1), so it is
         * not evidence of the fault this guard hunts. Don't count it and don't retry;
         * _transport_disconnected re-arms both works when the link goes away. */
        LOG_DBG("adv: %s start failed (%d) but a link is up — not a fault, ignoring", who, err);
        return;
    }
    uint32_t delay = (uint32_t) atomic_get(&adv_retry_delay_ms);
    atomic_inc(&adv_restart_failures);
    LOG_ERR("adv: %s start failed (%d) mode=%s — retry in %u ms", who, err, current_adv_mode, delay);
    k_work_schedule(&adv_restart_work, K_MSEC(delay));
    atomic_set(&adv_retry_delay_ms, (atomic_val_t) MIN(delay * 2, ADV_RESTART_RETRY_MAX_MS));
}

/* A recovered radio must restart its backoff from the fast baseline: leaving it at
 * the 8 s ceiling would make the *next* single failure wait 8 s before its first
 * retry, blunting exactly the self-healing this guard exists to provide. */
static inline void adv_reset_backoff(void)
{
    atomic_set(&adv_retry_delay_ms, (atomic_val_t) ADV_RESTART_RETRY_MS);
}

static void adv_restart_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    /* Gate re-checked *inside* the lock: transport_off() clears it before taking the
     * mutex, so anything that acquires after shutdown began sees it closed. */
    k_mutex_lock(&adv_mutex, K_FOREVER);
    if (!atomic_get(&adv_guard_active) || atomic_get(&is_connected)) {
        k_mutex_unlock(&adv_mutex);
        return; /* shutting down, or a link came up; the disconnect path re-arms us */
    }
    /* A mode switch whose stop failed left its request here rather than losing it. */
    int err = adv_pending_mode_pending() ? adv_apply_pending_mode_locked() : adv_start_raw();
    k_mutex_unlock(&adv_mutex);
    if (err == 0 || err == -EALREADY) {
        adv_reset_backoff();
        LOG_INF("adv: advertising active (mode=%s)", current_adv_mode);
        return;
    }
    adv_schedule_retry(err, "retry");
}

static void adv_watchdog_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    k_mutex_lock(&adv_mutex, K_FOREVER);
    if (!atomic_get(&adv_guard_active) || atomic_get(&is_connected)) {
        /* Deliberately does NOT reschedule: shutdown must not leave a 60 s timer
         * spinning forever, and a live link is re-armed by the next disconnect. */
        k_mutex_unlock(&adv_mutex);
        return;
    }
    /* We cannot portably ask "am I advertising?", so re-asserting IS the test:
     * -EALREADY means healthy, 0 means we had gone silent and just rescued it.
     * Under the lock this reading is trustworthy: without it, a 0 here could just
     * mean we won a race against a mode switch's stop, not that anything was wrong. */
    /* Whether this tick was a plain re-assert or a deferred mode switch decides how
     * to read its result, so capture it before the call clears the request. Applying
     * a parked mode switch necessarily returns 0 (it stops first), and counting that
     * as a rescue would be a fabricated adv_watchdog_recoveries bump — the one
     * counter that must stay trustworthy, since it is the sole evidence this guard
     * does anything. */
    bool had_pending = adv_pending_mode_pending();
    int err = had_pending ? adv_apply_pending_mode_locked() : adv_start_raw();
    /* Re-armed while STILL HOLDING the lock. transport_off() uses this same mutex as
     * its drain barrier, so re-arming after the unlock leaves a window in which
     * shutdown's k_work_cancel_delayable() runs first and this schedule then
     * resurrects a timer shutdown had already cancelled. Under the lock, shutdown's
     * cancel is guaranteed to come after this schedule and therefore to stick. */
    k_work_schedule(&adv_watchdog_work, K_MSEC(ADV_WATCHDOG_INTERVAL_MS));
    k_mutex_unlock(&adv_mutex);

    if (err && err != -EALREADY) {
        adv_schedule_retry(err, "watchdog");
        return;
    }
    adv_reset_backoff(); /* radio is healthy — next failure starts from the baseline */
    if (had_pending) {
        LOG_INF("adv: watchdog applied a deferred mode switch (mode=%s)", current_adv_mode);
        return;
    }
    if (err == 0) {
        uint32_t n = (uint32_t) atomic_inc(&adv_watchdog_recoveries) + 1;
        LOG_WRN("adv: watchdog found advertising stopped — restarted (mode=%s, recoveries=%u)", current_adv_mode, n);
    }
}

static void _transport_disconnected(struct bt_conn *conn, uint8_t err)
{
    atomic_set(&is_connected, 0);

    /* Stop diagnostics notifications; the CCC state is per-bond and the next
     * client will re-subscribe. The work handler already bails on !is_connected,
     * but clear the flag + cancel so a stale timer can't fire post-disconnect. */
    atomic_set(&diag_notify_subscribed, 0);
    k_work_cancel_delayable(&diagnostics_notify_work);

    /* A link that comes up and immediately dies with 0x3e never exchanged a
     * data-channel packet. Count it separately from failed_conn_count (see the
     * counter declarations) and record the advertising mode that was in effect —
     * this must happen before current_adv_mode is reset to "fast" below. */
    if (err == BT_HCI_ERR_CONN_FAIL_TO_ESTAB) {
        uint32_t estab_fails = (uint32_t) atomic_inc(&estab_fail_count) + 1;
        last_failed_adv_slow = (current_adv_mode[0] == 's') ? 1 : 0;
        LOG_ERR("Link died at establishment (0x3e) adv_mode=%s estab_fail_count=%u", current_adv_mode, estab_fails);
        k_work_schedule(&conn_fail_persist_work, K_MSEC(CONN_FAIL_PERSIST_DELAY_MS));
    }

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = false;
    storage_stop_sync_session();
    sd_notify_ble_state(false);
    /* A DFU can only run over a live link; if it dropped, the upload is dead.
     * The img_mgmt DFU_STOPPED callback does NOT fire on a bare disconnect (the
     * upload state is kept for resume), so clear ota_active here ourselves —
     * otherwise it stays latched and would defer idle-disconnect forever on the
     * next, non-DFU connection. A from-scratch retry re-fires DFU_STARTED. Gated
     * so routine idle-disconnects don't spam the "OTA mode inactive" log. */
    if (sd_get_ota_active()) {
        sd_set_ota_active(false);
    }
#endif

    k_work_cancel_delayable(&mtu_recheck_work);
    k_work_cancel_delayable(&conn_param_recheck_work);
    k_work_cancel_delayable(&idle_disconnect_work);

    /* Reason was previously discarded. 0x13 = our own idle-disconnect (REMOTE_USER_TERM),
     * 0x08 = supervision timeout, 0x3e = died at establishment (counted above). */
    LOG_INF("Transport disconnected (reason 0x%02x)", err);

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
     * back to slow once VAD returns to sleep.
     *
     * Deferred to a work item rather than called inline: the stack still holds the
     * disconnecting conn object while this callback runs, so with
     * CONFIG_BT_MAX_CONN=1 a connectable bt_le_adv_start() here can fail -ENOMEM.
     * Letting the conn be released first removes that race, and routing every
     * attempt through adv_restart_work means a failure retries instead of
     * silently stranding the device off the air (see the guard block above). */
    /* Park the request rather than performing it: this is the BT RX thread, which
     * must not take adv_mutex, and an unlocked write to current_adv_mode here races
     * the AAD mode setters. The restart handler applies it under the lock as a real
     * stop → start, which is the only thing that can actually change the interval if
     * an advertiser is somehow still running. */
    atomic_set(&adv_pending_mode, ADV_MODE_FAST);
    /* Skip entirely when transport_off() has already cleared the gate: this
     * callback is what its bt_conn_disconnect() triggers, and re-arming here would
     * schedule advertising work that runs after bt_disable(). */
    if (atomic_get(&adv_guard_active)) {
        adv_reset_backoff();
        k_work_schedule(&adv_restart_work, K_MSEC(ADV_RESTART_DEFER_MS));
        k_work_schedule(&adv_watchdog_work, K_MSEC(ADV_WATCHDOG_INTERVAL_MS));
    }
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
    if (!atomic_get(&is_connected) || !current_connection) {
        return;
    }
    uint16_t mtu = bt_gatt_get_mtu(current_connection);
    if (mtu <= 23 && mtu_recheck_attempts < MTU_RECHECK_MAX_ATTEMPTS) {
        mtu_recheck_attempts++;
        LOG_INF(
            "MTU still at minimum (%u), recheck attempt %u/%u", mtu, mtu_recheck_attempts, MTU_RECHECK_MAX_ATTEMPTS);
        update_mtu(current_connection);
        k_work_reschedule((struct k_work_delayable *) work, K_MSEC(MTU_RECHECK_DELAY_MS));
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
        .latency = 0,
        .timeout = 600,
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

/* See the comment by K_WORK_DELAYABLE_DEFINE(conn_param_recheck_work) above. */
static void conn_param_recheck_work_handler(struct k_work *work)
{
    struct bt_conn *conn = get_current_connection();
    if (!conn) {
        return;
    }

    struct bt_conn_info info = {0};
    if (bt_conn_get_info(conn, &info) == 0 && info.type == BT_CONN_TYPE_LE &&
        info.le.interval > CONN_PARAM_FAST_MAX_INTERVAL) {
        // Aggressive request was not honored (likely an iOS central, which rejects
        // interval_min < 15 ms). Retry once with Apple-compliant params.
        struct bt_le_conn_param params = {
            .interval_min = 12, // 15 ms — Apple's minimum
            .interval_max = 24, // 30 ms
            .latency = 0,
            .timeout = 600, // 6 s
        };
        LOG_INF("Conn interval still %.2f ms after connect — requesting Apple-compliant 15-30 ms",
                info.le.interval * 1.25);
        int err = bt_conn_le_param_update(conn, &params);
        if (err && err != -EALREADY) {
            LOG_WRN("Apple-compliant conn param update failed (err %d)", err);
        }
    }

    put_current_connection(conn);
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
/* Low 16 bits of the last marker header appended to the current block (e.g. 0xFFFC
 * session-end, 0xFFFE button-tap, 0xFFF8 priority-start). Captured so a diag-log
 * marker-drop event can name WHICH marker was lost instead of reporting 0. Same
 * lifetime/guard as storage_block_has_marker. */
static uint16_t storage_block_marker_low16 = 0;

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
        bool had_marker = storage_block_has_marker;
        uint16_t marker_low16 = storage_block_marker_low16;
        uint32_t wrote = had_marker ? write_to_file_blocking(storage_temp_data, MAX_WRITE_SIZE)
                                    : write_to_file(storage_temp_data, MAX_WRITE_SIZE);
        storage_block_has_marker = false;
        storage_block_marker_low16 = 0;
        if (wrote != MAX_WRITE_SIZE) {
            /* SD queue rejected the block — the buffered bytes (up to one
             * full block of audio frames or markers) are lost. We still
             * have to reset buffer_offset to make room for the entry the
             * caller is trying to write; otherwise the writer is stuck
             * forever and loses every subsequent frame too. Signal the
             * loss via the return value. */
            LOG_WRN("Storage rollover flush dropped block (wrote=%u/%u)", wrote, (uint32_t) MAX_WRITE_SIZE);
            atomic_inc(&storage_block_drops);
            /* Diagnostics (0x19B10062): the dropped block carried an inline marker,
             * so this is a genuine lost marker (e.g. a 0xFFFFFFF8/FFFFFFFC that would
             * make a priority recording revert to plain auto VAD). arg0 = the lost
             * marker's low16 so the app can tell priority/session-end/tap apart. */
            if (had_marker) {
                atomic_inc(&marker_write_drops);
                diag_log_event(DIAG_MARKER_WRITE_DROP, sd_get_active_backend(), marker_low16,
                               (uint32_t) atomic_get(&storage_block_drops));
            } else {
                diag_log_event(DIAG_SD_BLOCK_DROP, sd_get_active_backend(), 0,
                               (uint32_t) atomic_get(&storage_block_drops));
            }
            atomic_set(&last_storage_drop_uptime_ms, (atomic_val_t) k_uptime_get());
            ok = false;
        }
        buffer_offset = 0;
    }

    /* Write 4-byte Little-Endian length prefix */
    storage_temp_data[buffer_offset + 0] = (uint8_t) (marker & 0xFF);
    storage_temp_data[buffer_offset + 1] = (uint8_t) ((marker >> 8) & 0xFF);
    storage_temp_data[buffer_offset + 2] = (uint8_t) ((marker >> 16) & 0xFF);
    storage_temp_data[buffer_offset + 3] = (uint8_t) ((marker >> 24) & 0xFF);

    /* Write payload */
    memcpy(storage_temp_data + buffer_offset + 4, data, data_size);
    buffer_offset += entry_size;

    /* This block now carries a marker; mark it so every flush path (here, the
     * rollover above, and the marker force-drain) uses the durable enqueue, and
     * record its low16 so a drop can name the marker type. `marker` here is the
     * 4-byte header of the frame just written (0xFFFFFFFx for a real marker). */
    if (important) {
        storage_block_has_marker = true;
        storage_block_marker_low16 = (uint16_t) (marker & 0xFFFF);
    }

    /* Align buffer_offset to 4-byte boundary for the next entry */
    uint16_t alignment_padding = (4 - (buffer_offset % 4)) % 4;
    if (alignment_padding > 0 && buffer_offset + alignment_padding <= MAX_WRITE_SIZE) {
        memset(storage_temp_data + buffer_offset, 0, alignment_padding);
        buffer_offset += alignment_padding;
    }

    if (buffer_offset == MAX_WRITE_SIZE) {
        bool had_marker = storage_block_has_marker;
        uint16_t marker_low16 = storage_block_marker_low16;
        uint32_t wrote = had_marker ? write_to_file_blocking(storage_temp_data, MAX_WRITE_SIZE)
                                    : write_to_file(storage_temp_data, MAX_WRITE_SIZE);
        storage_block_has_marker = false;
        storage_block_marker_low16 = 0;
        if (wrote != MAX_WRITE_SIZE) {
            /* Full-buffer flush rejected. Same trade-off as above: reset
             * so subsequent writes can proceed, but report the loss. */
            LOG_WRN("Storage full-block flush dropped (wrote=%u/%u)", wrote, (uint32_t) MAX_WRITE_SIZE);
            atomic_inc(&storage_block_drops);
            /* Diagnostics (0x19B10062): a dropped marker-bearing block = lost marker.
             * arg0 = the lost marker's low16 (which marker type was in the block). */
            if (had_marker) {
                atomic_inc(&marker_write_drops);
                diag_log_event(DIAG_MARKER_WRITE_DROP, sd_get_active_backend(), marker_low16,
                               (uint32_t) atomic_get(&storage_block_drops));
            } else {
                diag_log_event(DIAG_SD_BLOCK_DROP, sd_get_active_backend(), 0,
                               (uint32_t) atomic_get(&storage_block_drops));
            }
            atomic_set(&last_storage_drop_uptime_ms, (atomic_val_t) k_uptime_get());
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
    uint32_t sid = (uint32_t) atomic_get(&device_session_id);
    if (sid != 0)
        return sid;
    do {
        sid = sys_rand32_get();
    } while (sid == 0);
    /* If another thread already published an ID, keep theirs. */
    if (!atomic_cas(&device_session_id, 0, (atomic_val_t) sid)) {
        sid = (uint32_t) atomic_get(&device_session_id);
    }
    return sid;
}

static bool write_marker_header_to_storage(uint32_t header, const char *label)
{
    uint32_t sid = ensure_device_session_id();

    uint8_t temp_buffer[16];
    uint64_t utc_time_ms = rtc_get_utc_time_ms();
    uint32_t uptime_ms = (uint32_t) k_uptime_get();

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
            storage_block_marker_low16 = 0;
        } else {
            /* Queue rejected; keep the original payload bytes in place
             * (the memset only touched the padding region). */
            buffer_offset = saved_offset;
            ok = false;
            LOG_WRN("Marker flush dropped: SD queue full, retaining buffer (offset=%u)", saved_offset);
        }
    }
    k_mutex_unlock(&storage_temp_mutex);

    /* NOTE: marker_write_drops is NOT counted here. This flush-drop path RETAINS the
     * buffer (marker kept for the next write to retry), and `ok` also folds in a
     * prior-block rollover that may have carried only audio. A marker is only truly
     * lost when a block that CONTAINS it is rejected and reset — counted at the two
     * flush sites in write_custom_packet_to_storage() (gated on storage_block_has_marker). */
    return ok;
}

bool write_marker_to_storage(void)
{
    return write_marker_header_to_storage(0xFFFFFFFE, "button-tap");
}

bool write_session_end_marker_to_storage(void)
{
    /* Count the emit attempt (diagnostics 0x19B10062): reaching here means the
     * finalize path fired and a 0xFFFFFFFC was handed to storage. Counted even if
     * the write below is dropped downstream — that pairing is the diagnosis. */
    atomic_inc(&session_end_marker_emits);
    bool ok = write_marker_header_to_storage(0xFFFFFFFC, "session-end");
    /* Logged after the inner write so device_session_id is guaranteed populated. */
    diag_log_event(DIAG_SESSION_END_MARKER_EMIT, sd_get_active_backend(), 0,
                   (uint32_t) atomic_get(&device_session_id));
    return ok;
}

bool write_mute_on_marker_to_storage(void)
{
    return write_marker_header_to_storage(0xFFFFFFFA, "mute-on");
}

bool write_mute_off_marker_to_storage(void)
{
    return write_marker_header_to_storage(0xFFFFFFF9, "mute-off");
}

bool write_priority_recording_marker_to_storage(void)
{
    /* Count the start attempt here (not in button.c) so it's tallied exactly once
     * per real priority start — record_start() reaches this only after its
     * already-recording guard. Counted even if the write is dropped below, so a
     * (starts=1, marker_write_drops=1) reading pins a lost priority marker. */
    atomic_inc(&priority_record_starts);
    bool ok = write_marker_header_to_storage(0xFFFFFFF8, "priority-record");
    /* Logged after the inner write so device_session_id is guaranteed populated. */
    diag_log_event(DIAG_PRIORITY_RECORD_START, sd_get_active_backend(), 0,
                   (uint32_t) atomic_get(&device_session_id));
    return ok;
}

/* Called from button.c priority_record_stop() once a force-capture actually ends
 * (after its threshold guard), so priority_record_starts vs _stops pair up. */
void transport_note_priority_record_stop(void)
{
    atomic_inc(&priority_record_stops);
    diag_log_event(DIAG_PRIORITY_RECORD_STOP, sd_get_active_backend(), 0,
                   (uint32_t) atomic_get(&device_session_id));
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
    /* Close the advertising guard FIRST — before the bt_conn_disconnect() below,
     * whose _transport_disconnected callback would otherwise re-arm the work items
     * we are about to cancel, and they would then run bt_le_adv_start() after
     * bt_disable(). Clearing the gate ahead of the disconnect is what makes the
     * cancel stick; cancelling alone races the callback. */
    atomic_set(&adv_guard_active, 0);
    /* Drain a handler that is already running: k_work_cancel_delayable() does not
     * wait for one, so a handler past its gate check could otherwise reach
     * bt_le_adv_start() after the bt_disable() below. Handlers hold adv_mutex across
     * their start, so taking it here waits them out; the gate is already closed
     * above, so nothing new can get in behind us. (Deliberately not
     * k_work_cancel_delayable_sync() — that deadlocks when turnoff_all() is reached
     * from the battery-critical path, which runs on the same workqueue. See
     * adv_mutex.) */
    k_mutex_lock(&adv_mutex, K_FOREVER);
    k_mutex_unlock(&adv_mutex);
    k_work_cancel_delayable(&adv_restart_work);
    k_work_cancel_delayable(&adv_watchdog_work);

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
    atomic_set(&is_connected, 0);
    current_mtu = 0;

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = false;
#endif

    return 0;
}

/* Mode switches stop advertising and then start it again. The stop nearly always
 * succeeds, so a failing start leaves the device provably off the air — which makes
 * these the most dangerous of the three restart paths, not the least. Both callers
 * in aad.c discard the return value AND clear their request flag with an atomic_cas
 * before calling, so nothing upstream would ever retry. Hence: set current_adv_mode
 * *before* attempting, so the retry/watchdog pair inherits the intended mode and
 * owns recovery from here. */
static int transport_set_adv_mode(int mode, const char *label)
{
    if (atomic_get(&is_connected)) {
        return 0;
    }
    /* stop → set mode → start must be atomic against the retry/watchdog handlers;
     * see adv_mutex. adv_schedule_retry() is called after unlocking — it only
     * touches atomics and a work item, and holding the lock across it buys
     * nothing. */
    k_mutex_lock(&adv_mutex, K_FOREVER);
    /* Re-check under the lock: the is_connected test above and the gate can both
     * flip between there and here, and stopping advertising while connected — or
     * touching the radio mid-shutdown — is exactly what this guard exists to
     * prevent. */
    if (!atomic_get(&adv_guard_active) || atomic_get(&is_connected)) {
        k_mutex_unlock(&adv_mutex);
        return 0;
    }
    int err = adv_apply_mode_locked(mode);
    k_mutex_unlock(&adv_mutex);
    if (err) {
        /* adv_apply_mode_locked has parked the request in adv_pending_mode, so the
         * retry re-runs the whole stop/set/start rather than only the start —
         * without which a failed stop silently stranded us on the wrong interval,
         * since both aad.c callers discard this return value. */
        adv_schedule_retry(err, label);
        return err;
    }
    LOG_INF("BLE advertising switched to %s interval", label);
    return 0;
}

int transport_set_adv_slow(void)
{
    return transport_set_adv_mode(ADV_MODE_SLOW, "slow");
}

int transport_set_adv_fast(void)
{
    return transport_set_adv_mode(ADV_MODE_FAST, "fast");
}

static void count_bond_cb(const struct bt_bond_info *info, void *user_data)
{
    (void) info;
    (*(uint32_t *) user_data)++;
}

/* Number of bonds currently held for the default identity. CONFIG_BT_MAX_PAIRED=1,
 * so in practice this is 0 or 1 — and which of the two it is at boot is the whole
 * question when a phone reports itself unpaired. Exported so the button unpair path
 * can report the real post-wipe count rather than assuming it succeeded. */
uint32_t transport_bond_count(void)
{
    uint32_t n = 0;
    bt_foreach_bond(BT_ID_DEFAULT, count_bond_cb, &n);
    return n;
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

    /* Seed the connection-failure counters from flash (app_settings_init ran in
     * main before transport_start) so they stay cumulative across reboots — the
     * counts are only readable once the device is reachable again. */
    {
        uint32_t persisted = 0;
        uint32_t persisted_estab = 0;
        app_settings_get_conn_fail(&persisted, &last_failed_adv_slow, &persisted_estab);
        atomic_set(&failed_conn_count, (atomic_val_t) persisted);
        atomic_set(&estab_fail_count, (atomic_val_t) persisted_estab);
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

    /* Record how many bonds actually came back. A device that boots with ZERO keys
     * when the phone still thinks it is paired is the origin of the "silently
     * unpaired, reconnects forever" outage (BLE_Research.md §9), and nothing else
     * surfaces it: the LOG_INF above goes nowhere without an RTT probe
     * (CONFIG_CONSOLE=n / CONFIG_UART_CONSOLE=n), and the phone can only observe the
     * downstream symptom. Logged unconditionally — the ring is runtime-gated and this
     * is one event per boot. */
    diag_log_event(DIAG_BOND_STATE, 0, DIAG_BOND_CAUSE_BOOT_LOAD,
                   transport_bond_count());

    /* One-shot post-update bond wipe: if the app armed it before a flash (via
     * CMD_ARM_POST_DFU_UNPAIR, which records the version at arm time), a boot on
     * a DIFFERENT version means a real update landed — wipe every bond (now that
     * they've been loaded above) so the device advertises unbonded and the phone
     * (which clears its side on success) re-pairs cleanly. A failed/aborted flash
     * leaves the SAME version, so consume returns false and nothing is wiped —
     * an ordinary reboot or the Reboot Omi command of an armed device can't wipe.
     * Consume is one-shot and clears the marker regardless. */
    if (app_settings_consume_post_dfu_unpair(CONFIG_BT_DIS_FW_REV_STR)) {
        int uerr = bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY);
        if (uerr) {
            /* Rare. The local wipe is best-effort — the actual pairing reset is
             * the app clearing the PHONE bond on success, which forces a fresh
             * pair that re-keys the device anyway. Just surface it. */
            LOG_ERR("post-DFU unpair: bt_unpair failed (err %d); phone re-pair will re-key", uerr);
        } else {
            LOG_INF("post-DFU unpair: firmware changed — wiped BLE bonds");
        }
        /* Distinguishes an intentional post-update wipe from an unexplained loss:
         * without this, both look identical from the phone's side. */
        diag_log_event(DIAG_BOND_STATE, 0, DIAG_BOND_CAUSE_POST_DFU,
                       transport_bond_count());
    }

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
    // Mute service appended after diagnostics so all prior handles stay stable.
    bt_gatt_service_register(&mute_service);
    // LED service appended last, same reason — see the note on settings_service_attr.
    bt_gatt_service_register(&led_service);
    // Button + haptic config now live under the Settings service — no separate service to register.
    err = bt_le_adv_start(BT_LE_ADV_CONN, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    /* Open the gate only once bring-up has got this far, so nothing can queue
     * advertising work against a stack that never came up. Set before the failure
     * branch below, which needs it open for adv_schedule_retry() to arm anything. */
    atomic_set(&adv_guard_active, 1);
    if (err) {
        /* Do NOT fail transport_start here: returning an error aborts BLE bring-up
         * and leaves the device with no radio at all and nothing retrying. Hand the
         * failure to the retry/watchdog pair instead — the same machinery that
         * covers every later restart — so a transient boot-time -ENOMEM/-EAGAIN
         * self-heals within seconds rather than bricking the link until reboot. */
        LOG_ERR("Transport advertising failed to start (err %d) — handing to adv retry", err);
        adv_reset_backoff();
        adv_schedule_retry(err, "boot");
    } else {
        LOG_INF("Advertising successfully started");
    }
    /* Arm the watchdog for the pre-first-connection window too: without this, a
     * device that goes silent before it is ever connected has nothing watching it. */
    k_work_schedule(&adv_watchdog_work, K_MSEC(ADV_WATCHDOG_INTERVAL_MS));

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
