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
#include <zephyr/dt-bindings/gpio/nordic-nrf-gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/random/random.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/ring_buffer.h>

/* aad.h is needed for the one AAD call in this file — settings_vad_threshold_write_handler's
 * aad_set_threshold(). Without it that call was an implicit declaration: benign on this ABI
 * (uint16_t promotes to int in r0, void return ignored) but formally UB, unchecked against the
 * real prototype, and a hard error under GCC 14 / C23. */
#include "aad.h"
#include "button.h"
#include "config.h"
#include "features.h"
#include "haptic.h"
#include "lib/battery/battery.h"
#include "mic.h"
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

/* Defined in main.c. atomic_t rather than bool: the BT RX thread writes it while the
 * advertising watchdog (system workqueue) and main.c's LED state machine read it, and
 * concurrent access to a plain bool is a data race in the C memory model even where
 * the load is single-instruction. A lock is not an option — the RX thread must never
 * take adv_mutex. */
extern atomic_t is_connected;
extern bool is_charging;
static atomic_t pusher_stop_flag;
/* Set once k_thread_create() has returned for pusher_thread. transport_off() must
 * not k_thread_join() a k_thread that was never created: a zeroed one has an
 * uninitialised join wait queue, so the join dereferences NULL rather than timing
 * out. Reachable whenever transport_start() returns early — a failed bt_enable() or
 * ring-buffer init — after which a 4-tap-hold or the critical-battery path still
 * calls transport_off(). */
static bool pusher_started;

struct bt_conn *current_connection = NULL;
static K_MUTEX_DEFINE(conn_mutex);

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
 * THIRD (see transport_start) — only register_button_service() and
 * register_haptic_service() run ahead of it — so every attribute added here
 * shifts the handles of every service registered after it: features, time sync,
 * battery, storage, diagnostics, mute, led. A peer holding a cached GATT DB
 * would then address the wrong attributes until it re-pairs. New settings go in
 * a service registered last, as the LED service (0x19B10080) below does. Adding
 * 0015/0016 here already cost one re-pair.
 *
 * This note said "registered FIRST" for a long time. That was wrong about the
 * order and right about the rule; button/haptic are unaffected by an addition
 * here, everything listed above is. */

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

/* Diagnostics: encoded frames dropped at write_to_tx_queue() because the tx ring was
 * full. Not on 0x0062 (that payload is full at 100 B) — it rides DIAG_WRITE_BLOCKED's
 * arg1 instead, which is the more useful shape anyway: a stall is diagnosed by when it
 * started and whether the total is still climbing. Codec thread only. */
static atomic_t tx_ring_full_drops;

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
/* Advertising interval currently applied. An atomic enum rather than a `const char *`
 * because the BT RX callbacks read it for the diagnostics below while the advertising
 * watchdog writes it — and the RX thread must never take the watchdog's lock (see
 * adv_mutex). Strings are derived only for logs. */
#define ADV_MODE_FAST 0
#define ADV_MODE_SLOW 1
static atomic_t adv_active_mode = ATOMIC_INIT(ADV_MODE_FAST); /* boot starts fast */

static inline const char *adv_mode_name(int mode)
{
    return (mode == ADV_MODE_SLOW) ? "slow" : "fast";
}

/* 1 if the most recent failure of either kind was during slow advertising. atomic_t
 * because the BT RX callbacks write it while the persistence worker and the 0x0062
 * packer read it — the same cross-context exposure the advertising mode was fixed for. */
static atomic_t last_failed_adv_slow = ATOMIC_INIT(0);

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
                                (uint8_t) atomic_get(&last_failed_adv_slow),
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
// Returns 100 bytes LE (fields appended over time; older apps read a prefix):
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
//   [uint32 last_mic_frame_uptime_ms] k_uptime_get() at the last processed mic frame (offset 84).
//                                  now_ms MINUS this is "how long since the mic delivered" —
//                                  frames land every 100 ms, so seconds means parked and
//                                  minutes means stopped. Sampled BEFORE now_ms on purpose.
//   [uint32 vad_voiced_ms]         total ms the VAD has held a recording open since boot
//                                  (offset 88). Against now_ms this is the capture duty cycle.
//   [uint32 adv_modes]             [active u8][desired u8] advertising interval (offset 92),
//                                  0 = fast (100-150 ms), 1 = slow (~1 s). NOT the same as
//                                  last_failed_adv_slow at offset 24, which is the mode during
//                                  the last FAILED connection. Advertising stops while
//                                  connected, so `active` read here is the interval in force
//                                  when the phone found the device.
//   [uint32 device_session_id]     the per-boot session id every recording of this boot is
//                                  stamped with (offset 96). Paired with current_uptime_ms
//                                  from the SAME read, it is the app's clock anchor.
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

/* Current advertising interval, packed. Defined after adv_desired_mode below. */
static uint32_t adv_modes_packed(void);

/* Lazy per-boot session id. Defined with the marker writers far below; declared here
 * because the diagnostics payload reports it. */
static uint32_t ensure_device_session_id(void);

/* Pack the 100-byte drop-counter payload. Shared by the read handler (0x0062)
 * and the notify path (diagnostics_drops_notify) so the wire layout has exactly
 * one definition. */
static void diagnostics_drops_pack(uint8_t payload[100])
{
    uint32_t block_drops = (uint32_t) atomic_get(&storage_block_drops);
    uint32_t last_drop_ms = (uint32_t) atomic_get(&last_storage_drop_uptime_ms);
    uint32_t sd_stream_drops = sd_get_stream_dropped_frames();
    uint32_t sd_boot_drops = sd_get_boot_dropped_frames();
    /* Mic fields FIRST, now_ms after. Both are k_uptime_get() samples and the app
     * reports (now_ms - last_mic_frame) as an unsigned 32-bit delta, so a frame that
     * lands between the two reads makes last_mic_frame the LARGER value and the delta
     * wraps to ~49.7 days — a healthy mic rendered as catastrophically dead. The
     * window is not theoretical: the reads below include two k_thread_stack_space_get()
     * calls, which scan kilobytes of stack for the sentinel, against frames arriving
     * every 100 ms. Sampling in this order makes now_ms >= last_mic_frame by
     * construction. */
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    uint32_t last_mic_frame = aad_last_frame_uptime_ms();
    uint32_t voiced_ms = aad_voiced_ms();
#else
    uint32_t last_mic_frame = 0;
    uint32_t voiced_ms = 0;
#endif
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

    /* 100 bytes: legacy u32 drops + conn_fail count + last-failure adv mode +
     * codec_drops + sd_msgq peak depth + write-fairness activations + establishment
     * failures + Priority Recording lifecycle (starts / stops / marker drops /
     * empty-bin rotations) + session-end emit attempts + pause-gate marker saves +
     * sd_worker & codec peak stack used + ring_max_io_ms + ring_io_errors +
     * Each field is appended at the end so older
     * app builds (which read only the first
     * 20 / 28 / 32 / 40 / 44 / 60 / 68 / 76 / 84 / 92 / 96 bytes) keep working unchanged.
     *
     * last_mic_frame_uptime_ms (84) + vad_voiced_ms (88): mic liveness and capture
     * duty. The first, against now_ms, answers "is the mic delivering right now"
     * without inferring it from the absence of event-log records -- the inference
     * that is wrong whenever the mic is legitimately parked. The second, against
     * now_ms, is the fraction of the day the VAD holds a recording open, i.e. what
     * the auto threshold actually costs in encode + NAND writes.
     *
     * adv_modes (92): the advertising interval, which was previously reported
     * NOWHERE. The nearest thing, last_failed_adv_slow at offset 24, is the mode
     * during the last FAILED connection and says nothing about the current one -- it
     * was misread as the live mode twice during review, which is the argument for
     * this field existing. Read at connect time it answers "what interval was this
     * device advertising on while it sat idle", which is the only way to confirm the
     * idle-advertising backstop works.
     *
     * empty_bin_rotations (56) is NOT a loss signal, and was read as one for a long
     * time. An empty bin means nothing at all reached the card for that segment, and
     * an accepted marker always does (it force-drains a full 440 B block), so an empty
     * bin is a rotation that landed where nothing was being written — any silent
     * stretch in auto mode. Two Force Syncs over a quiet lunch break move it and mean
     * nothing. marker_write_drops (52) is the loss signal and stands alone — both are
     * boot-cumulative totals that name no segment, so reading them together invents a
     * correlation neither carries. Per-bin cause + timing live in the 0x0063 event
     * log's arg0. */
    pack_u32_le(payload + 0, block_drops);
    pack_u32_le(payload + 4, last_drop_ms);
    pack_u32_le(payload + 8, sd_stream_drops);
    pack_u32_le(payload + 12, sd_boot_drops);
    pack_u32_le(payload + 16, now_ms);
    pack_u32_le(payload + 20, conn_fails);
    pack_u32_le(payload + 24, (uint32_t) atomic_get(&last_failed_adv_slow));
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
    pack_u32_le(payload + 84, last_mic_frame);
    pack_u32_le(payload + 88, voiced_ms);
    pack_u32_le(payload + 92, adv_modes_packed());
    /* device_session_id (96): the id every recording of THIS boot is stamped with.
     *
     * It is here, rather than inferred app-side, so that the phone's clock anchor is
     * atomic: one read hands back the session id and now_ms (offset 16) together, and
     * two fields from the same read cannot disagree about which boot they describe.
     * The app pairs them with its own wall clock to place recordings the Omi could not
     * timestamp (device_clock_anchor.dart). Inferring the live session from synced bin
     * filenames instead does not work — CMD_LIST_FILES omits the bin currently being
     * written, so after a reboot with no rotation yet the newest listed file belongs to
     * the PREVIOUS boot, which is exactly the case the correction exists for.
     *
     * ensure_ rather than a plain atomic_get: the id is allocated lazily on first use,
     * so a boot that has not yet written a marker or a bin would report 0 here and then
     * stamp its recordings with a different, real id moments later — an anchor bound to
     * a session that never existed. Forcing allocation on the first diagnostics read
     * costs one sys_rand32_get() and makes the id the app sees the id it will meet. */
    pack_u32_le(payload + 96, ensure_device_session_id());
}

static ssize_t diagnostics_drops_read_handler(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset)
{
    uint8_t payload[100];
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
static ssize_t
diag_log_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
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
    /* ENCRYPT, unlike the two 0x0061/0x0062 characteristics above, and unlike this
     * pair before diag_log_event_forced() existed. The log now holds DIAG_BOND_STATE
     * from every boot whether or not the app ever enables it, so a plain
     * BT_GATT_PERM_READ here would let any peer that can connect learn how many
     * pairing keys the device holds — and "0 bonds" is precisely the signal an
     * attacker wants, per the CONFIG_BT_SMP_ALLOW_UNAUTH_OVERWRITE note in omi.conf.
     * Matches the 11 other encrypted characteristics in this file. Permission-only
     * change: no attribute is added or removed, so no handle moves. */
    BT_GATT_CHARACTERISTIC(&diag_log_read_characteristic_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ_ENCRYPT,
                           diag_log_read_handler,
                           NULL,
                           NULL),
    BT_GATT_CHARACTERISTIC(&diag_log_control_characteristic_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE_ENCRYPT,
                           NULL,
                           diag_log_control_write_handler,
                           NULL),
#endif
};

static struct bt_gatt_service diagnostics_service = BT_GATT_SERVICE(diagnostics_service_attr);

/* Notify the 100-byte drop payload to every subscribed client. The value
 * attribute is index 4: [0]=service, [1]/[2]=0x0061 decl/value,
 * [3]/[4]=0x0062 decl/value, [5]=CCC.
 *
 * A 100-byte notification needs ATT_MTU >= 103; on a link that never negotiated up
 * from the 23-byte default bt_gatt_notify returns -EMSGSIZE and the update is lost.
 * This is a *live* convenience path — the same payload is always available via a
 * plain READ (ATT read-blob is not MTU-bounded), which is the app's fallback — so we
 * don't defer or fragment here, but we no longer drop the error on the floor: log it
 * (rate-limited by the caller's 2 s/15 s cadence) so a chronically small MTU is
 * visible instead of silent. In practice CONFIG_BT_L2CAP_TX_MTU=498 with
 * AUTO_UPDATE_MTU makes this the rare exception, not the rule. */
static void diagnostics_drops_notify(void)
{
    uint8_t payload[100];
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

/* There is deliberately no button-state notify here. The firmware owns the button
 * entirely: the FSM acts on a gesture locally, and the actions that change captured
 * audio each leave their own inline marker for the app to parse at decode time —
 * MARKER writes 0xFFFFFFFE (a bookmark), RECORD_START writes 0xFFFFFFF8 in auto mode
 * (opens a priority recording), RECORD_STOP writes 0xFFFFFFFC, MUTE brackets with
 * 0xFFFFFFFA/0xFFFFFFF9. NONE and TOGGLE_LED deliberately leave no marker: they do
 * not affect the recording, so there is nothing for the app to reconstruct. A BLE
 * tap event would only arrive while the phone happened to be connected, and Omi is
 * built to run disconnected.
 *
 * The service itself stays registered, and is worth keeping: register_button_service()
 * runs first in transport_start(), ahead of haptic, settings, features, time-sync,
 * battery, storage, diagnostics, mute and led — so dropping it would shift the handles
 * of every one of those and cost a re-pair. It is among the most expensive services in the table to remove and free to
 * keep.
 *
 * That also makes it the natural home for a future device→app push channel, which
 * the app otherwise has no way to receive (it learns device-side state at connect
 * or by polling). Reuse rules, in cost order:
 *   - FREE (no handle change, no re-pair): notify a different, longer payload on the
 *     existing 23BA7925 characteristic. The attribute table does not fix the value
 *     length — bt_gatt_notify() may send up to ATT_MTU-3 bytes, so the 1-byte tap
 *     code can become an N-byte struct. button_ccc_changed() already tells you when
 *     the app subscribes.
 *   - COSTS A RE-PAIR: adding a second characteristic to this service, since almost
 *     everything is registered after it. Same trap as adding to Settings (see the
 *     note on settings_service_attr), but worse — put new attributes in the service
 *     registered LAST, as led (0080) does. */

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
// Settings is registered early (third, behind only button and haptic), so growing
// it renumbers every service after it — features, time sync, battery, storage,
// diagnostics, mute, led — and forces bonded peers to re-pair. Registered last
// (after mute), this leaves every existing handle untouched — which is also why
// characteristic B could be added here for free, while adding it to Settings
// could not.
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

static ssize_t
led_boot_read_handler(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf, uint16_t len, uint16_t offset)
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

    /* No mic_reset() on the manual -> automatic switch any more. The concern was
     * right — that direction hands capture back to acoustic detection, which is
     * where a wedged mic goes unnoticed because nothing auto-records and no button
     * press is coming to mask it — but the remedy never worked: since oo-2.8.5 the
     * call is a dmic re-trigger, which does not recover a wedged part (mic.h). It
     * only cost a STOP/START on a mic the gate has just resumed for auto mode.
     *
     * Detection covers it instead: entering auto mode resumes the mic through the
     * gate, which arms the post-resume probe (DIAG_MIC_STATE_RESUMED_SILENT), and
     * from then on the mic runs continuously so DIAG_VAD_LEVEL's zero-peak windows
     * report a wedge that develops later. (The claim this comment used to make —
     * that "the manual paths reset the mic on every record start/stop themselves" —
     * is also no longer true; those call sites are gone for the same reason.) */

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

    /* OMI_FEATURE_SPEAKER / OMI_FEATURE_ACCELEROMETER are never set: this fork
     * builds neither driver (the Consumer hardware has no speaker, and the IMU is
     * used only for its timestamp counter). Their bits stay reserved in features.h
     * because the app's OmiFeatures mirrors the numbering. */
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
    }
}

//
// Battery Service Handlers
//

#ifdef CONFIG_OMI_ENABLE_BATTERY
#define BATTERY_REFRESH_INTERVAL_CONNECTED 60000     // 60 seconds while connected
#define BATTERY_REFRESH_INTERVAL_DISCONNECTED 300000 // 5 minutes while offline
/* Not a Kconfig symbol, despite the CONFIG_-prefixed name this used to carry: it is
 * defined here and appears in no Kconfig file, so adding the real option later would
 * have made autoconf.h and this line collide. Named like its neighbours instead. */
#define BATTERY_CRITICAL_MV 3500 // mV
/* Below this percentage the 150mAh cell's internal resistance rises sharply, so
 * a brownout mid-write is more likely. We flush once here so everything captured
 * so far is durable, but recording CONTINUES — a recorder should capture to the
 * critical-voltage shutdown, not stop at 15%. littlefs is power-loss resilient,
 * so a brownout costs at most the last unsynced frames; the clean shutdown still
 * happens at BATTERY_CRITICAL_MV. */
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

        if (battery_millivolt < BATTERY_CRITICAL_MV) {
            LOG_WRN("Battery critical level reached (%d mV). Initiating shutdown.", battery_millivolt);
            /* Deliberately NOT rebooting on TURNOFF_BAILED here, unlike the 4-tap-hold
             * and CMD_POWER_OFF paths.
             *
             * Those two are user-initiated on a device that may have days of charge
             * left, so a bailed teardown stranding the mic is worth a reboot to clear.
             * This one is the opposite: it only fires below BATTERY_CRITICAL_MV,
             * and whatever makes turnoff_all() bail (a GPIO configure or watchdog
             * deinit failure) is deterministic — it will bail again on the next boot,
             * and the one after that. Rebooting would give an unattended device a
             * cold-reboot loop on a nearly-flat cell, never reaching a stable
             * power-off and burning what charge is left on repeated boots, each of
             * which waits on the SD card.
             *
             * Letting it limp instead costs the mic until the cell dies, which is
             * minutes away by definition here — a far smaller loss than the loop, and
             * bounded by the battery itself rather than unbounded. */
            if (turnoff_all() == TURNOFF_BAILED) {
                LOG_ERR("Critical-battery shutdown: turnoff_all() bailed — staying up rather than "
                        "reboot-looping on a flat cell; mic may be stopped until power is lost");
            }
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
 * MUST stay above the app's foreground keep-alive interval (10 s, see
 * device_provider.dart _startForegroundKeepAlive). A timeout at/below that
 * interval makes the heartbeat structurally unable to keep the link up: the
 * device idle-drops before the next keep-alive arrives, producing a permanent
 * connect/disconnect loop (BT_HCI_ERR_REMOTE_USER_TERM_CONN / gatt_status_19).
 * The two are sized together — six beats inside the window, so five may be
 * missed — so neither may be changed without the other.
 *
 * Raised 15 s -> 60 s. Two reasons. The first is that 15 s was tight enough that
 * every legitimate operation which does not touch a storage characteristic needed
 * its own exemption — there are already two below (OTA, transfer) and a third was
 * found missing after a DFU, where the bond is deliberately wiped and the first
 * write cannot complete until a fresh pairing does. Nothing marks activity during
 * that pairing, so the link was dropped at 15 s and the pairing restarted, five
 * times, before one completed. A minute swallows pairing, discovery and MTU
 * negotiation without needing to enumerate them.
 *
 * The second is that the cost of waiting is now much lower: an idle link is
 * negotiated down to 100-200 ms (see CONN_PARAM_IDLE_*) instead of the ~11.25 ms
 * Android drives for transfers, so holding it a further 45 s is a fraction of what
 * it used to be. This remains a backstop against a phone that holds the link and
 * stops talking — the app's own post-sync disconnect is the normal path — and a
 * backstop does not need to be prompt. */
#define IDLE_DISCONNECT_TIMEOUT_MS 60000
#define IDLE_DISCONNECT_POLL_MS 5000
/* How long an UNENCRYPTED link is given before the ordinary idle rule applies to it
 * anyway. Generous because the thing being waited on is a Just Works pairing on the
 * central's schedule, and Android will retry one across several seconds; bounded
 * because an unencrypted link that never pairs is indistinguishable from the stuck
 * central this timer exists to shed. See the use site for why silence on an
 * unencrypted link proves nothing. */
#define PAIRING_GRACE_MS 180000

static atomic_t last_activity_ms;

void transport_mark_activity(void)
{
    atomic_set(&last_activity_ms, (atomic_val_t) k_uptime_get_32());
}

/* Connection parameters are negotiated for one of two jobs, and the right values
 * differ by an order of magnitude.
 *
 * TRANSFER is the historic setting: as fast as the central will go, because a file
 * read is throughput-bound. Android drives it to ~11.25 ms via
 * CONNECTION_PRIORITY_HIGH regardless of what we ask.
 *
 * IDLE is new. The link spends most of its life connected with nothing to carry —
 * waiting out a sync window, or held open while the app is in the foreground — and
 * it was sitting at the transfer setting the whole time, waking the radio ~89 times
 * a second on a 150 mAh cell for no traffic at all.
 *
 * latency is 0 in both AS REQUESTED, but do not read that as a guarantee: Android's
 * CONNECTION_PRIORITY_LOW_POWER, which the app pairs with the idle set, carries a
 * latency of 2 of its own, and the central decides. So the idle link may well end up
 * at ~100-125 ms with 2 skipped events. That is fine — a worst-case ~330 ms before a
 * command is heard is imperceptible for a link whose entire traffic is
 * command/response (list files, read, settings) at human timescales. What is NOT
 * worth doing is asking for a large latency on top of a long interval: the product
 * of the two is the delay, and several seconds of it would be felt on the first
 * command of every sync. The bulk of the saving is the interval, not the latency.
 *
 * The central has the final say — these are requests. The app must agree, or it
 * will simply re-assert its own priority: see OmiBleManager.applyConnectionPriority,
 * which pairs LOW_POWER/HIGH with these two modes.
 *
 * If iOS ever comes back (this fork is Android-only), note that Apple rejects any
 * request with interval_min < 15 ms outright rather than negotiating down, so the
 * TRANSFER set would be refused and the link would silently sit at iOS's ~30 ms
 * default. It needs an Apple-compliant fallback (12-24 units = 15-30 ms) applied
 * when a transfer-mode request is not honored. A one-shot recheck for exactly this
 * used to run 3 s after connect; it was removed here because connects now start in
 * IDLE mode and the mode cannot change until the 5 s poll, which made it
 * unreachable — not because the constraint stopped being true. */
#define CONN_PARAM_IDLE_INTERVAL_MIN 80  /* 100 ms */
#define CONN_PARAM_IDLE_INTERVAL_MAX 160 /* 200 ms */
#define CONN_PARAM_IDLE_LATENCY      0
#define CONN_PARAM_IDLE_TIMEOUT      600 /* 6 s */
#define CONN_PARAM_XFER_INTERVAL_MIN 6   /* 7.5 ms */
#define CONN_PARAM_XFER_INTERVAL_MAX 18  /* 22.5 ms */
#define CONN_PARAM_XFER_LATENCY      0
#define CONN_PARAM_XFER_TIMEOUT      600 /* 6 s */

enum conn_param_mode {
    CONN_PARAM_MODE_UNSET = 0,
    CONN_PARAM_MODE_IDLE,
    CONN_PARAM_MODE_TRANSFER,
};

/* Which set was last requested, so the poll below only sends an update when the
 * mode actually changes rather than re-requesting every 5 s. Reset on disconnect so
 * a new link always gets an explicit request. */
static atomic_t applied_conn_param_mode = ATOMIC_INIT(CONN_PARAM_MODE_UNSET);

static void apply_conn_params(struct bt_conn *conn, enum conn_param_mode mode);

/* Re-request parameters if the transfer state has changed since the last request.
 * Driven from the idle-disconnect poll rather than a hook in storage.c:
 * storage_transfer_active() is derived state with no transition callback, and this
 * work item is already running every 5 s for the whole life of a connection. The
 * cost is that a transfer can spend up to one poll at idle parameters; at 200 ms
 * that is a slower start, not a stall, and the first file read is preceded by
 * several seconds of command/response anyway. */
static void refresh_conn_param_mode(void)
{
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    /* An OTA counts as transfer, and must: storage_transfer_active() tracks the
     * storage file read only (remaining_length / transport_started), so on its own
     * it reads false throughout a flash — which would have this request the 100-200
     * ms idle set in the middle of a firmware update, an order of magnitude slower
     * than the ~11.25 ms the DFU library negotiates for itself. The two would then
     * fight for the length of the flash, re-requesting parameters over the link
     * carrying the image. */
    const bool busy = storage_transfer_active() || sd_get_ota_active();
#else
    const bool busy = false;
#endif
    enum conn_param_mode want = busy ? CONN_PARAM_MODE_TRANSFER : CONN_PARAM_MODE_IDLE;
    if ((enum conn_param_mode) atomic_get(&applied_conn_param_mode) == want) {
        return;
    }
    struct bt_conn *conn = get_current_connection();
    if (!conn) {
        return;
    }
    apply_conn_params(conn, want);
    put_current_connection(conn);
}

static void idle_disconnect_work_handler(struct k_work *work)
{
    if (!atomic_get(&is_connected)) {
        return;
    }

    /* Before the exemptions below, which return early: a transfer starting is
     * exactly when the parameters must go aggressive, and that is also the branch
     * that stops this handler from running to the bottom. */
    refresh_conn_param_mode();

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

    /* Third exemption, the same shape as the two above: a link where the absence of
     * storage activity is not evidence of a phone that stopped talking.
     *
     * Until the link is encrypted the app physically CANNOT send the keep-alive —
     * the storage characteristic is BT_GATT_PERM_WRITE_ENCRYPT (storage.c), so the
     * write blocks behind pairing and nothing ever reaches transport_mark_activity().
     * Silence here means pairing has not finished, not that the central is idle.
     *
     * This is what produced a post-DFU reconnect loop: the update deliberately wipes
     * the bond on both sides, the phone reconnects unencrypted, its first write waits
     * on a fresh Just Works pairing, and the link was dropped out from under that
     * pairing — five times before one completed.
     *
     * Bounded, unlike the other two. A central that never pairs would otherwise hold
     * the link open indefinitely, which is exactly the "phone holds it and goes
     * silent" case this whole timer exists for. Past PAIRING_GRACE_MS the ordinary
     * rule resumes and an unencrypted link is dropped like any other. The window is
     * measured from last_activity_ms, which _transport_connected stamps at connect,
     * so it is time-since-connect for a link that has never carried traffic. */
    if (idle_ms < PAIRING_GRACE_MS) {
        struct bt_conn *sec_conn = get_current_connection();
        bool unencrypted = false;
        if (sec_conn) {
            unencrypted = (bt_conn_get_security(sec_conn) < BT_SECURITY_L2);
            put_current_connection(sec_conn);
        }
        if (unencrypted) {
            LOG_INF("Idle %u ms but link not yet encrypted — deferring disconnect for pairing", idle_ms);
            k_work_schedule(k_work_delayable_from_work(work), K_MSEC(IDLE_DISCONNECT_POLL_MS));
            return;
        }
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


/* ── Advertising watchdog ────────────────────────────────────────────────────
 *
 * Until oo-2.8.3 every path that restarted advertising discarded the result of
 * bt_le_adv_start(). One failure left the device permanently invisible — firmware
 * running, SD still recording, radio silent — recoverable only by a power cycle.
 *
 * Confirmed 2026-07-31 (BLE_Research.md, Wedge 5): a 2 h outage in which an
 * independent scanner heard nothing, ten in-app probes heard nothing, a 2.5 min
 * phone Bluetooth toggle changed nothing, and the device — uptime 33 h 40 m, no
 * reset, 8 unsynced WALs waiting — reconnected instantly on a power cycle.
 *
 * DESIGN: one periodic work item is the entire mechanism. It re-asserts advertising
 * on a timer, so *every* way the radio can end up off the air — a failed start, a
 * dropped mode switch, something we have not thought of — self-heals within one
 * tick. There is no separate retry path and no backoff state machine: the tick
 * interval IS the retry interval.
 *
 * The invariant that keeps this simple: **while the guard is armed, this handler is
 * the only code that touches the radio.** The AAD mode setters merely record an
 * intent and return; transport_start() and transport_off() are bookends that run
 * with the gate closed. A single writer means the whole class of "two things
 * reconfiguring the advertiser at once" cannot occur — which is what an earlier,
 * far more elaborate version of this guard kept failing to defend against.
 *
 * The BT RX callbacks (_transport_connected / _transport_disconnected) must NEVER
 * take adv_mutex: bt_le_adv_start() is an HCI command whose completion the RX thread
 * itself processes, so an RX callback blocking on a lock held by a thread inside
 * bt_le_adv_start() would deadlock the stack. They only set atomics and (re)schedule.
 */
#define ADV_TICK_MS 30000          /* healthy re-assert cadence */
#define ADV_TICK_RETRY_MS 5000     /* after a failed attempt */
#define ADV_TICK_DISCONNECT_MS 200 /* let the stack release the conn object first */
#define ADV_TICK_MODE_MS 50        /* apply a mode request promptly */

/* Serializes the handler against transport_off()'s teardown. transport_off() closes
 * the gate, then takes this lock, which waits out a handler already inside
 * bt_le_adv_start() — k_work_cancel_delayable() does NOT wait for a running handler,
 * and k_work_cancel_delayable_sync() would deadlock, because turnoff_all() is
 * reachable from broadcast_battery_level(), itself a system-workqueue handler on the
 * same queue this work runs on. */
static K_MUTEX_DEFINE(adv_mutex);

/* 0 until transport_start() has the stack up; cleared at the top of transport_off()
 * BEFORE it disconnects, so the disconnect callback cannot re-arm the work we are
 * about to cancel. Without it, power-off queued a restart that ran after
 * bt_disable(). */
static atomic_t adv_guard_active = ATOMIC_INIT(0);

/* What the interval *should* be. Written by the AAD setters and by the disconnect
 * callback; read only by the handler. Last writer wins, which is the behaviour we
 * want: a disconnect resets to fast, and AAD re-requests slow at the next VAD sleep. */
static atomic_t adv_desired_mode = ATOMIC_INIT(ADV_MODE_FAST);

/* [active u8][desired u8] for 0x0062 offset 92. Both, not just active: they diverge
 * exactly when a mode switch was requested and the watchdog has not applied it, which
 * is the failure the idle backstop would show. Note the app can only ever read this
 * over a live connection, and advertising stops while connected -- so `active` is the
 * interval in force when the phone found the device, which is precisely the question,
 * and `desired` is what it will use on the next disconnect. */
static uint32_t adv_modes_packed(void)
{
    const uint32_t active = (uint32_t) atomic_get(&adv_active_mode) & 0xFFu;
    const uint32_t desired = (uint32_t) atomic_get(&adv_desired_mode) & 0xFFu;
    return active | (desired << 8);
}

/* Set when a *start* fails, cleared when one succeeds or a link comes up. Decides
 * whether a later success is reported as a rescue (DIAG_ADV_WATCHDOG_RESCUE).
 *
 * This began life feeding a 0x0062 counter and that was a mistake: across five review
 * passes, seven separate edge cases were found in which it counted something that was
 * not an outage — a failed stop, a routine post-disconnect restart, an -ENOMEM from a
 * link coming up mid-tick. Each fix spawned the next. A counter has to be exactly
 * right or it lies, and this one never was; an event log only has to be informative,
 * and "advertising restarted, we thought it was down" is useful even when the
 * inference is occasionally generous. Cleared on connect because a successful link
 * proves the radio was up, which kills a whole family of those false positives at
 * once — a truly off-air device cannot accept a connection. */
static atomic_t adv_believed_down = ATOMIC_INIT(0);

/* Set by the disconnect callback, consumed by the next tick. Exists purely to keep
 * the recovery counter honest across a behaviour of the stack we cannot verify here.
 *
 * A connection stops the advertiser. Whether it comes back on its own depends on the
 * parameters: slow sets BT_LE_ADV_OPT_ONE_TIME and definitely does not auto-restart,
 * while BT_LE_ADV_CONN (fast) does not set it and — depending on the Zephyr version —
 * may. So the post-disconnect tick's start can legitimately return either -EALREADY
 * (it came back by itself) or 0 (it did not, and we just restarted it), for the same
 * healthy sequence. Counting that 0 as a rescue would add one per disconnect — with a
 * 30-minute sync cadence, ~48 phantom rescues a day, drowning the signal the counter
 * exists to carry.
 *
 * With this flag the routine post-disconnect restart is never counted, while a radio
 * that stops spontaneously mid-idle still is. Consumed at the top of the tick, so a
 * disconnect landing mid-tick suppresses the *next* one too: the bias is toward
 * under-counting, which is the right direction for evidence. */
static atomic_t adv_disconnect_since_tick = ATOMIC_INIT(0);

static void adv_watchdog_work_handler(struct k_work *work);
K_WORK_DELAYABLE_DEFINE(adv_watchdog_work, adv_watchdog_work_handler);

/* Slow advertising parameters for low-power mode (~1 s interval).
 * BT_LE_ADV_CONN uses 100-150ms by default; 1000-1200ms saves ~300-500 µA.
 * Advertising interval unit = 0.625 ms → 1000 ms = 1600, 1200 ms = 1920.
 * ONE_TIME because Zephyr must not auto-restart it behind the watchdog's back. */
static const struct bt_le_adv_param adv_param_slow =
    BT_LE_ADV_PARAM_INIT(BT_LE_ADV_OPT_CONNECTABLE | BT_LE_ADV_OPT_ONE_TIME, 1600, 1920, NULL);

/* Caller holds adv_mutex. Starts the advertiser for `mode`, returning the raw
 * bt_le_adv_start() result — 0 and -EALREADY must stay distinct, since the handler
 * uses the difference to tell "we were off the air" from "already advertising". */
static int adv_start_mode(int mode)
{
    if (mode == ADV_MODE_SLOW) {
        return bt_le_adv_start(&adv_param_slow, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    }
    return bt_le_adv_start(BT_LE_ADV_CONN, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
}

static void adv_watchdog_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    k_mutex_lock(&adv_mutex, K_FOREVER);
    /* Re-checked under the lock: transport_off() clears the gate before acquiring it,
     * so anything getting in after teardown began sees it closed. Deliberately does
     * NOT reschedule — shutdown must not leave a timer running, and a live link is
     * re-armed by the next disconnect. */
    if (!atomic_get(&adv_guard_active) || atomic_get(&is_connected)) {
        k_mutex_unlock(&adv_mutex);
        return;
    }

    /* Consumed here, before the radio work, so a disconnect arriving mid-tick is left
     * for the next one rather than being swallowed by this one. */
    const bool after_disconnect = atomic_cas(&adv_disconnect_since_tick, 1, 0);
    const int desired = (int) atomic_get(&adv_desired_mode);
    const int active = (int) atomic_get(&adv_active_mode);
    /* Only a stop actually changes the interval: bt_le_adv_start() against a running
     * advertiser answers -EALREADY and reconfigures nothing. So a mode change must
     * stop first, and a plain re-assert must not. */
    const bool mode_change = (desired != active);
    int stop_err = 0;
    if (mode_change) {
        stop_err = bt_le_adv_stop();
        if (stop_err == -EALREADY) {
            stop_err = 0;
        }
    }

    int err = stop_err ? stop_err : adv_start_mode(desired);
    const bool ok = (err == 0 || err == -EALREADY);
    /* A link that came up while we were inside those HCI calls explains any result we
     * got, so nothing here is evidence of anything. The cancel in _transport_connected
     * only drops *pending* work — it cannot preempt this handler, and the RX thread
     * cannot wait on adv_mutex (that is the forbidden lock), so the window is
     * unclosable on the producer side; re-checking just before the radio calls would
     * only narrow it. Classify instead: a failure with a live link is a -ENOMEM from
     * the full conn slot, not a silent radio, and must not set believed_down or emit a
     * fault event. The next tick after the disconnect re-establishes the truth. */
    const bool raced_connect = atomic_get(&is_connected) != 0;
    bool rescued = false;
    if (raced_connect) {
        LOG_DBG("adv: tick raced an incoming link (err %d) — not evidence, ignoring", err);
    } else if (ok) {
        atomic_set(&adv_active_mode, desired);
        /* Two independent signals that the radio had gone quiet, and either counts:
         *   - a previous start failed and we have not succeeded since. Unambiguous,
         *     and this is the one that catches the Wedge 5 fault; or
         *   - a plain re-assert (we believed we were already advertising) returned 0,
         *     meaning it wasn't — a radio that stopped with no failure we ever saw.
         * The second needs both guards to mean anything: a mode change stops first, so
         * its 0 is expected, and so is the 0 after a disconnect if the stack did not
         * auto-restart (see adv_disconnect_since_tick). */
        /* `after_disconnect` covers a disconnect that preceded this tick; the live read
         * covers one that landed *during* the HCI calls, which the top-of-tick consume
         * cannot see. Both mean the same thing — a routine post-disconnect restart, not
         * a rescue — and without the second, an ordinary connect/disconnect racing the
         * tick reports the reconnect path as a recovery. The failure branch below
         * already applies the same test. */
        rescued = atomic_cas(&adv_believed_down, 1, 0) ||
                  (!mode_change && !after_disconnect && !atomic_get(&adv_disconnect_since_tick) && err == 0);
    } else if (!stop_err && !after_disconnect && !atomic_get(&adv_disconnect_since_tick)) {
        /* Only a failed *start* means the radio is off the air: a failed stop leaves
         * the old advertiser running.
         *
         * Both disconnect tests are needed, and for different windows. The live read
         * catches a link that came up and went away inside our HCI calls.
         * `after_disconnect` catches the settle tick 200 ms after an ordinary
         * disconnect — where a start can still fail because the stack has not released
         * the conn object yet. Without it that routine retry marked the radio down and
         * the next success reported a rescue. A genuinely stuck radio is still caught:
         * the *following* tick has neither flag set, so a second consecutive failure
         * marks it down and the eventual recovery is reported. */
        atomic_set(&adv_believed_down, 1);
    }
    k_mutex_unlock(&adv_mutex);

    /* Re-arm from ONE place, here, after the radio work — so the flags it reads
     * already reflect anything that arrived while we were inside the HCI calls.
     *
     *  - raced a connect → do not re-arm at all. _transport_connected cancelled us
     *    deliberately, and re-arming would resurrect the timer it just cancelled;
     *    _transport_disconnected arms us again when the link goes away.
     *  - a disconnect landed → the longer settle, so the stack can release the conn
     *    object before we try a connectable start.
     *  - a mode request landed → apply it promptly; giving it the disconnect delay
     *    would make every AAD interval change four times slower than advertised.
     *  - failed → short retry; otherwise the healthy cadence.
     *
     * Gate re-checked because transport_off() closes it and then drains on this mutex:
     * whichever of us acquires first, its cancel stays definitive rather than us
     * queueing work that outlives bt_disable().
     *
     * Residual, stated rather than papered over: the producers cannot take this lock
     * (the RX thread must not), so one landing between our reads and our reschedule
     * still loses its deadline to ours. That is bounded and self-correcting — its flag
     * stays set, so the next tick honours it — and the cost is one late tick, never a
     * permanently dark radio. Two overlapping re-arm blocks were tried to narrow it
     * further and merely made the ownership harder to reason about. */
    if (!raced_connect) {
        k_mutex_lock(&adv_mutex, K_FOREVER);
        if (atomic_get(&adv_guard_active)) {
            const bool late_disconnect = atomic_get(&adv_disconnect_since_tick) != 0;
            const bool late_mode_req = ((int) atomic_get(&adv_desired_mode) != desired);
            uint32_t next_ms;
            if (!ok) {
                next_ms = ADV_TICK_RETRY_MS;
            } else if (late_disconnect) {
                next_ms = ADV_TICK_DISCONNECT_MS;
            } else if (late_mode_req) {
                next_ms = ADV_TICK_MODE_MS;
            } else {
                next_ms = ADV_TICK_MS;
            }
            k_work_reschedule(&adv_watchdog_work, K_MSEC(next_ms));
        }
        k_mutex_unlock(&adv_mutex);
    }

    /* Logged outside the lock from locals — never by re-reading shared state. */
    if (raced_connect) {
        return;
    }
    if (!ok) {
        LOG_ERR("adv: %s failed (%d) mode=%s — retrying in %d ms",
                stop_err ? "stop" : "start",
                err,
                adv_mode_name(desired),
                ADV_TICK_RETRY_MS);
        diag_log_event(stop_err ? DIAG_ADV_STOP_FAIL : DIAG_ADV_START_FAIL, 0, (uint16_t) desired, (uint32_t) -err);
    } else if (rescued) {
        LOG_WRN("adv: watchdog found advertising stopped — restarted (mode=%s)", adv_mode_name(desired));
        diag_log_event(DIAG_ADV_WATCHDOG_RESCUE, 0, (uint16_t) desired, 0);
    } else if (mode_change) {
        LOG_INF("adv: interval switched to %s", adv_mode_name(desired));
    }
}

/* Ask for an interval. Records intent only — the handler owns the radio. Callers in
 * aad.c discard the return value, which is now honest: there is nothing to fail. */
static int adv_request_mode(int mode)
{
    atomic_set(&adv_desired_mode, mode);
    if (atomic_get(&adv_guard_active) && !atomic_get(&is_connected)) {
        /* reschedule, not schedule: the tick may be up to ADV_TICK_MS away and
         * k_work_schedule() would leave it there.
         *
         * Never pull the tick inside a pending disconnect settle. A mode request
         * arriving just after a disconnect would otherwise fire at 50 ms, before the
         * stack has released the conn object, and the connectable start would fail
         * -ENOMEM for no reason — wasting the attempt and pushing the real one out to
         * the retry cadence. */
        const bool settling = atomic_get(&adv_disconnect_since_tick) != 0;
        k_work_reschedule(&adv_watchdog_work, K_MSEC(settling ? ADV_TICK_DISCONNECT_MS : ADV_TICK_MODE_MS));
    }
    return 0;
}

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
        atomic_set(&last_failed_adv_slow, (atomic_get(&adv_active_mode) == ADV_MODE_SLOW) ? 1 : 0);
        LOG_ERR("Connection failed (err 0x%02x) adv_mode=%s failed_conn_count=%u uptime=%lld ms",
                err,
                adv_mode_name((int) atomic_get(&adv_active_mode)),
                fails,
                (long long) k_uptime_get());
        /* Coalesced flash persist so the count survives the power-cycle needed to read it. */
        k_work_schedule(&conn_fail_persist_work, K_MSEC(CONN_FAIL_PERSIST_DELAY_MS));
        return;
    }

    struct bt_conn_info info = {0};

    /* Claim the link and silence the watchdog FIRST, ahead of the setup below. Until
     * both happen the guard still believes we are disconnected, so a tick landing
     * mid-setup would call bt_le_adv_start() against a live link and fail -ENOMEM
     * under CONFIG_BT_MAX_CONN=1 — which the handler would then read as "the radio was
     * down", fabricating a recovery. Any later failure here ends in a disconnect,
     * whose callback re-arms the watchdog.
     *
     * Deliberately OUTSIDE the offline-storage #ifdef below: the connection state and
     * the advertising guard have nothing to do with the SD card, and
     * CONFIG_OMI_ENABLE_OFFLINE_STORAGE defaults to n — gating them on it would leave
     * such a build never entering the connected state at all. */
    atomic_set(&is_connected, 1);
    k_work_cancel_delayable(&adv_watchdog_work);
    /* A link proves the radio is up, whatever a tick may have concluded while it was
     * coming up. Clearing here kills a family of false rescues at once: a start that
     * failed -ENOMEM because the slot was already taken would otherwise leave this set
     * across the whole connection and be reported as a rescue after the next
     * disconnect. A device that is genuinely off the air cannot accept a link. */
    atomic_set(&adv_believed_down, 0);

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = true;
#endif

    int info_err = bt_conn_get_info(conn, &info);
    if (info_err) {
        LOG_ERR("Failed to get connection info (err %d)", info_err);
        /* Undo the claim made above before bailing. Hoisting is_connected and the
         * watchdog cancel to the top of this callback (so a tick could not race the
         * setup below) put them *ahead* of this early return, which previously ran
         * with the link still unclaimed. Left as-is we would return with the guard
         * believing in a link we never finished configuring: the tick gate bails on
         * is_connected forever, nothing is rescheduled, current_connection is NULL and
         * even the idle-disconnect timer below is never armed. Restore the disconnected
         * state and re-arm, flagging it as a disconnect so the first advertising
         * attempt is not counted as a fault. */
        atomic_set(&is_connected, 0);
        atomic_set(&adv_desired_mode, ADV_MODE_FAST);
        atomic_set(&adv_disconnect_since_tick, 1);
        if (atomic_get(&adv_guard_active)) {
            k_work_reschedule(&adv_watchdog_work, K_MSEC(ADV_TICK_DISCONNECT_MS));
        }
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
        /* Same backstop as the disconnect path below. This branch abandons a
         * half-configured link without going through _transport_disconnected, so
         * without it a setup failure is a way to end up advertising FAST forever. */
        aad_note_link_idle();
#endif
        return;
    }

    LOG_INF("bluetooth activated");
    k_mutex_lock(&conn_mutex, K_FOREVER);
    current_connection = bt_conn_ref(conn);
    k_mutex_unlock(&conn_mutex);
    uint16_t mtu = bt_gatt_get_mtu(conn);

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

    /* is_connected and the watchdog cancel were hoisted to the top of this callback. */
    transport_mark_activity();
    k_work_schedule(&idle_disconnect_work, K_MSEC(IDLE_DISCONNECT_POLL_MS));
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
     * this must happen before the watchdog applies the post-disconnect reset below. */
    if (err == BT_HCI_ERR_CONN_FAIL_TO_ESTAB) {
        uint32_t estab_fails = (uint32_t) atomic_inc(&estab_fail_count) + 1;
        atomic_set(&last_failed_adv_slow, (atomic_get(&adv_active_mode) == ADV_MODE_SLOW) ? 1 : 0);
        LOG_ERR("Link died at establishment (0x3e) adv_mode=%s estab_fail_count=%u",
                adv_mode_name((int) atomic_get(&adv_active_mode)),
                estab_fails);
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
    k_work_cancel_delayable(&idle_disconnect_work);

    /* Parameters do not survive the link, so neither may the record of them. Left
     * latched, the next connection would match its mode against the previous one and
     * skip the request entirely, leaving a fresh link on whatever the central chose. */
    atomic_set(&applied_conn_param_mode, (atomic_val_t) CONN_PARAM_MODE_UNSET);

    /* Reason was previously discarded. 0x13 = our own idle-disconnect (REMOTE_USER_TERM),
     * 0x08 = supervision timeout, 0x3e = died at establishment (counted above). */
    LOG_INF("Transport disconnected (reason 0x%02x)", err);

    k_mutex_lock(&conn_mutex, K_FOREVER);
    if (current_connection != NULL) {
        bt_conn_unref(current_connection);
        current_connection = NULL;
    }
    k_mutex_unlock(&conn_mutex);

    /* Advertising must come back, or the device is invisible until someone reboots it:
     * slow mode sets BT_LE_ADV_OPT_ONE_TIME, and Zephyr does not auto-restart that.
     *
     * This is the root cause of Wedge 5, and BOTH halves of the old one-liner were
     * wrong. It called bt_le_adv_start() *inline*, where the stack still holds the
     * disconnecting conn object — so under CONFIG_BT_MAX_CONN=1 a connectable start
     * here can fail -ENOMEM. And it discarded the result, so that failure was
     * permanent. Hand it to the watchdog instead: a short delay lets the conn be
     * released, and if the start still fails the next tick retries it forever.
     *
     * Only atomics and a reschedule here — this is the BT RX thread (see adv_mutex). */
    atomic_set(&adv_desired_mode, ADV_MODE_FAST);
    atomic_set(&adv_disconnect_since_tick, 1);
    if (atomic_get(&adv_guard_active)) {
        k_work_reschedule(&adv_watchdog_work, K_MSEC(ADV_TICK_DISCONNECT_MS));
    }
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    /* FAST above is right for the seconds after a drop — the phone is most likely to
     * be reconnecting — but nothing brings it back down unless a recording happens to
     * start and stop, and in manual standby the mic is parked so that never occurs.
     * Arm the backstop. Schedule-only, as required on this thread. */
    aad_note_link_idle();
#endif
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

/* Request [mode]'s parameters and record what was asked for.
 *
 * ONE attempt, never a retry loop, and never a sleep. This used to try three times
 * with a 200 ms sleep between attempts, which was wrong in both of its callers:
 *
 *  - from _transport_connected it slept in the BT RX thread, which the comment by
 *    the advertising watchdog spells out must "only set atomics and (re)schedule".
 *    It was also self-defeating — bt_conn_le_param_update sends a request whose
 *    response that same RX thread processes, so sleeping there blocks the only
 *    thread that could deliver the answer being waited for.
 *  - from refresh_conn_param_mode it slept on the system workqueue, holding a
 *    shared queue for a request the central is free to decline anyway.
 *
 * Nothing needs the retry. The app drives the central's own priority in step
 * (OmiBleManager.applyConnectionPriority) and the central has the final say
 * regardless, so a declined request costs the difference between two power states
 * on one connection, not correctness.
 *
 * The mode is latched before the request rather than after success, so a declined
 * request is not re-sent on every 5 s poll — refresh_conn_param_mode() asks again
 * the next time the transfer state actually changes, which is the natural retry. */
static void apply_conn_params(struct bt_conn *conn, enum conn_param_mode mode)
{
    const bool transfer = (mode == CONN_PARAM_MODE_TRANSFER);
    struct bt_le_conn_param params = {
        .interval_min = transfer ? CONN_PARAM_XFER_INTERVAL_MIN : CONN_PARAM_IDLE_INTERVAL_MIN,
        .interval_max = transfer ? CONN_PARAM_XFER_INTERVAL_MAX : CONN_PARAM_IDLE_INTERVAL_MAX,
        .latency = transfer ? CONN_PARAM_XFER_LATENCY : CONN_PARAM_IDLE_LATENCY,
        .timeout = transfer ? CONN_PARAM_XFER_TIMEOUT : CONN_PARAM_IDLE_TIMEOUT,
    };
    atomic_set(&applied_conn_param_mode, (atomic_val_t) mode);
    int err = bt_conn_le_param_update(conn, &params);
    if (err && err != -EALREADY) {
        LOG_WRN("conn param update (%s) failed (err %d)", transfer ? "transfer" : "idle", err);
        return;
    }
    LOG_INF("Requested %s connection parameters (%u-%u units)",
            transfer ? "transfer" : "idle",
            params.interval_min,
            params.interval_max);
}

static void update_conn_params(struct bt_conn *conn)
{
    /* On connect nothing is being transferred yet — the app has service discovery,
     * capability reads and a file listing to get through first, all of which are
     * comfortable at 200 ms. refresh_conn_param_mode() promotes to transfer
     * parameters within one poll of a read actually starting. */
    apply_conn_params(conn, CONN_PARAM_MODE_IDLE);
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
        /* An encoded frame just died between the codec and storage, and nothing else
         * records it: our false becomes broadcast_audio_packets()'s -1, which the codec
         * callback discards. That silence is what made the 2026-09-05 outage
         * undiagnosable — 46 minutes captured and encoded, marker_pause_gate_saves and
         * sd_msgq_peak_depth both unmoved (so nothing reached the SD worker), and every
         * 0x0062 counter reading zero.
         *
         * The ring only stays full if pusher() has stopped draining it, and the failure
         * is self-sustaining: bailing here also skips the k_sem_give below, so a pusher
         * waiting on tx_queue_sem is never woken again. Hence a diag record rather than a
         * counter — the 0x0062 payload is full at 100 B, and WHEN the stall began is the
         * diagnosis anyway. Rate-limited to 1/s; arg1 carries the running total so the
         * lost detail is only the timing of repeats, which the first record already
         * establishes. Statics are fine unlocked: this runs solely on the codec thread. */
        static int64_t last_tx_full_log_ms;
        atomic_val_t total = atomic_inc(&tx_ring_full_drops) + 1; /* atomic_inc returns the OLD value */
        int64_t now = k_uptime_get();
        if (last_tx_full_log_ms == 0 || (now - last_tx_full_log_ms) >= 1000) {
            last_tx_full_log_ms = now;
            diag_log_event(DIAG_WRITE_BLOCKED, sd_get_active_backend(), DIAG_WRITE_BLOCKED_TX_RING_FULL,
                           (uint32_t) total);
        }
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
                diag_log_event(DIAG_MARKER_WRITE_DROP,
                               sd_get_active_backend(),
                               marker_low16,
                               (uint32_t) atomic_get(&storage_block_drops));
            } else {
                diag_log_event(
                    DIAG_SD_BLOCK_DROP, sd_get_active_backend(), 0, (uint32_t) atomic_get(&storage_block_drops));
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
                diag_log_event(DIAG_MARKER_WRITE_DROP,
                               sd_get_active_backend(),
                               marker_low16,
                               (uint32_t) atomic_get(&storage_block_drops));
            } else {
                diag_log_event(
                    DIAG_SD_BLOCK_DROP, sd_get_active_backend(), 0, (uint32_t) atomic_get(&storage_block_drops));
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
    diag_log_event(DIAG_SESSION_END_MARKER_EMIT, sd_get_active_backend(), 0, (uint32_t) atomic_get(&device_session_id));
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
    diag_log_event(DIAG_PRIORITY_RECORD_START, sd_get_active_backend(), 0, (uint32_t) atomic_get(&device_session_id));
    return ok;
}

/* Called from button.c priority_record_stop() once a force-capture actually ends
 * (after its threshold guard), so priority_record_starts vs _stops pair up. */
void transport_note_priority_record_stop(void)
{
    atomic_inc(&priority_record_stops);
    diag_log_event(DIAG_PRIORITY_RECORD_STOP, sd_get_active_backend(), 0, (uint32_t) atomic_get(&device_session_id));
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
    /* Disarm the advertising watchdog FIRST — before the bt_conn_disconnect() below,
     * whose callback would otherwise re-arm the very work we are about to cancel, and
     * it would then run bt_le_adv_start() after bt_disable(). Clearing the gate ahead
     * of the disconnect is what makes the cancel stick.
     *
     * Then take adv_mutex: k_work_cancel_delayable() does not wait for a handler that
     * is already running, and the handler holds this lock across its radio calls, so
     * acquiring it here waits that out. Deliberately not
     * k_work_cancel_delayable_sync(), which would deadlock when turnoff_all() is
     * reached from broadcast_battery_level() — itself a handler on the same
     * workqueue. */
    atomic_set(&adv_guard_active, 0);
    k_mutex_lock(&adv_mutex, K_FOREVER);
    k_mutex_unlock(&adv_mutex);
    k_work_cancel_delayable(&adv_watchdog_work);

    // Stop pusher thread when transport is turned off
    atomic_set(&pusher_stop_flag, 1);
    k_sem_give(&tx_queue_sem); // unblock pusher if waiting
    if (pusher_started) {
        int ret = k_thread_join(&pusher_thread, K_MSEC(500));
        if (ret != 0) {
            LOG_WRN("Pusher thread did not terminate in time (err %d)", ret);
        }
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

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_is_on = false;
#endif

    return 0;
}

/* Both setters only record intent; the watchdog owns the radio (see its comment).
 * They can no longer fail, and always return 0 — which is honest, since both callers
 * in aad.c discard the return value. The previous versions did stop → start inline
 * from the AAD thread, racing the guard: a tick landing between their stop and their
 * start began the *old* interval, their own start then answered -EALREADY, and they
 * logged "switched to slow" while the radio stayed fast. */
int transport_set_adv_slow(void)
{
    return adv_request_mode(ADV_MODE_SLOW);
}

int transport_set_adv_fast(void)
{
    return adv_request_mode(ADV_MODE_FAST);
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

    /* Allocate the per-boot session id NOW, before anything can write a bin.
     *
     * It used to be allocated lazily by whoever needed it first, and the only callers
     * were the marker writers — button tap, session end, mute, priority. sd_card.c does
     * a plain atomic_get() when it names and stamps a bin, so on a boot with no button
     * press and no phone connection yet, every bin was written with session_id = 0: in
     * its filename (<ts>_00000000.bin) and in its header. That is the ordinary auto-mode
     * boot, and those are exactly the recordings the phone's clock correction exists for
     * — made before a phone arrived, when the device's own clock may be wrong. With a
     * zero id they carry no session to match an anchor against and were skipped.
     *
     * Here rather than deeper in the SD path because main() runs transport_start()
     * before mic_start(), so this precedes the first audio-bearing bin. The one thing
     * that can open a bin earlier is app_sd_init()'s mount-time rotation, which by
     * definition holds no audio.
     *
     * Also removes the question of an entropy read inside a GATT handler:
     * diagnostics_drops_pack() still calls ensure_ for safety, but by then the id is
     * always already allocated, so sys_rand32_get() no longer runs on the BT RX thread. */
    (void) ensure_device_session_id();

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
        /* Via a local: the settings API takes a uint8_t*, and last_failed_adv_slow is
         * now an atomic_t so it cannot be written through a raw pointer. */
        uint8_t persisted_adv_slow = 0;
        app_settings_get_conn_fail(&persisted, &persisted_adv_slow, &persisted_estab);
        atomic_set(&failed_conn_count, (atomic_val_t) persisted);
        atomic_set(&estab_fail_count, (atomic_val_t) persisted_estab);
        atomic_set(&last_failed_adv_slow, (atomic_val_t) persisted_adv_slow);
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
     * downstream symptom. Forced past the runtime gate: this fires seconds before the
     * app connects and opens the gate, so the plain diag_log_event() this used to be
     * was discarded on every single boot — the reboot that produces the record also
     * closes the gate that would keep it. One event per boot into an already-allocated
     * ring. */
    diag_log_event_forced(DIAG_BOND_STATE, 0, DIAG_BOND_CAUSE_BOOT_LOAD, transport_bond_count());

    /* One-shot post-flash bond wipe: mcumgr told us an image finished
     * transferring before the last reboot (main.c, MGMT_EVT_OP_IMG_MGMT_DFU_
     * PENDING), so wipe every bond — now that they've been loaded above — and
     * advertise unbonded. The app clears its own bond on DFU success, so both
     * sides re-pair clean.
     *
     * Unconditional on the version: a flash can corrupt a bond whether or not
     * the version changed, and an occupied key slot refuses a fresh Just Works
     * pairing regardless of whether the key in it is still valid
     * (update_keys_check() with CONFIG_BT_SMP_ALLOW_UNAUTH_OVERWRITE unset). An
     * ordinary reboot or the Reboot Omi command never sets the marker, so
     * neither can wipe. Consume is one-shot. */
    if (app_settings_consume_dfu_bond_wipe()) {
        /* Return deliberately unchecked: bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY)
         * cannot fail — its only error returns are id >= CONFIG_BT_ID_MAX (0 here)
         * and a NULL addr under !CONFIG_BT_SMP (BT_ADDR_LE_ANY here, SMP on), and
         * every other path returns 0.
         *
         * It does swallow one thing, and the DIAG_BOND_STATE record below does NOT
         * catch it: bt_keys_clear() discards the result of bt_settings_delete_keys()
         * (keys.c), so a failed *flash* delete goes unreported, and the count below
         * comes from bt_foreach_bond() over the RAM key pool — which the same
         * function memsets unconditionally, so it reads 0 either way.
         *
         * Left unguarded anyway. That unconditional memset is also why the state is
         * self-correcting: the running device holds no keys, so it advertises
         * unbonded and accepts a fresh pairing at once, and the app reconnects
         * within seconds of the flash and re-keys — overwriting whatever stale
         * record survived. Stranding the device would need an NVS that fails
         * deletes while still serving the writes that pairing performs, plus no
         * re-pair before the next boot. Verifying the delete means reading settings
         * storage back on every boot: new surface for a case with no demonstrable
         * trigger. */
        (void) bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY);
        LOG_INF("post-DFU unpair: DFU landed — wiped BLE bonds");
        /* Distinguishes an intentional post-update wipe from an unexplained loss:
         * without this, both look identical from the phone's side. Forced for the
         * same reason as the boot-load record above — and this is the one that
         * matters most, since it is the only proof the wipe was ours. */
        diag_log_event_forced(DIAG_BOND_STATE, 0, DIAG_BOND_CAUSE_POST_DFU, transport_bond_count());
    }

    LOG_INF("Transport bluetooth initialized");

    /* button_init() is NOT called here — main() already called it before this
     * function. Calling it twice took a second pm_device_runtime_get() reference on
     * the buttons device that turnoff_all()'s single put never balanced, so the
     * device never actually suspended on power-off. Only the service registration
     * belongs to transport. */
#ifdef CONFIG_OMI_ENABLE_BUTTON
    register_button_service();
#endif

// Initialize and register Haptic service if enabled
#ifdef CONFIG_OMI_ENABLE_HAPTIC
    // Note: haptic_init() is called in main.c
    register_haptic_service();
    LOG_INF("Haptic service registered via transport");
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
    /* Started here rather than deferred to the first tick, so the device is
     * discoverable the instant BLE is up rather than one workqueue hop later. Safe as
     * a direct call because the gate is still closed — no tick can be in flight. */
    err = bt_le_adv_start(BT_LE_ADV_CONN, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    if (err) {
        /* Do NOT return an error: that aborts BLE bring-up and leaves the device with
         * no radio and nothing retrying — the very failure mode this guard exists to
         * end. Mark the radio down and let the watchdog take it from here. */
        LOG_ERR("Transport advertising failed to start (err %d) — watchdog will retry", err);
        atomic_set(&adv_believed_down, 1);
        /* Same event the watchdog emits, so a boot-time failure the retry later fixes
         * still leaves evidence — otherwise the only trace would be a rescue count
         * with nothing explaining what it rescued. */
        diag_log_event(DIAG_ADV_START_FAIL, 0, (uint16_t) ADV_MODE_FAST, (uint32_t) -err);
    } else {
        LOG_INF("Advertising successfully started");
    }
    atomic_set(&adv_active_mode, ADV_MODE_FAST);
    atomic_set(&adv_desired_mode, ADV_MODE_FAST);
    /* Arm the guard only once the stack is up, so nothing can queue radio work
     * against a stack that never came up. */
    atomic_set(&adv_guard_active, 1);
    k_work_reschedule(&adv_watchdog_work, K_MSEC(err ? ADV_TICK_RETRY_MS : ADV_TICK_MS));

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
    pusher_started = true;

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
