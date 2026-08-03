#include "lib/core/settings.h"

#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>

LOG_MODULE_REGISTER(app_settings, CONFIG_LOG_DEFAULT_LEVEL);

// Default values if not found in flash
#define DEFAULT_DIM_LIGHT_RATIO 50
#define DEFAULT_MIC_GAIN 6
#define DEFAULT_VAD_THRESHOLD 32769
#define DEFAULT_PRIORITY_RECORD_MAX_MINUTES 120 // 2 h; 0 = no cap
/* Solid-blue "connected to phone" LED. 1 = show it (previous, unconditional
 * behaviour), 0 = stay dark while connected and let the underlying recording
 * state drive the LED instead. */
#define DEFAULT_CONNECTED_LED 1
/* Boot value for is_led_enabled, the LED master gate. 0 = LEDs start off and
 * only the button gesture lights them for the session (the historical
 * behaviour, since is_led_enabled is volatile and reset every boot); 1 = LEDs
 * come up enabled on every boot. */
#define DEFAULT_LED_BOOT_ENABLED 0

/* Active audio storage backend. Persisted in NVS (on internal flash) — the
 * backend CHOICE is a tiny value; the audio + ring metadata it selects live on
 * the SD NAND. Default 0 = LittleFS (unchanged behaviour); 1 = raw ring buffer.
 * A device with no stored value (factory / pre-ring firmware) reads the default,
 * so shipping the ring code never changes an existing device's backend until the
 * user opts in from the app. */
#define DEFAULT_STORAGE_BACKEND STORAGE_BACKEND_LITTLEFS

// In-memory cache for the settings
static uint8_t dim_light_ratio = DEFAULT_DIM_LIGHT_RATIO;
static uint8_t mic_gain = DEFAULT_MIC_GAIN;
static uint16_t vad_threshold = DEFAULT_VAD_THRESHOLD;
static uint16_t priority_record_max_minutes = DEFAULT_PRIORITY_RECORD_MAX_MINUTES;
static uint8_t connected_led_enabled = DEFAULT_CONNECTED_LED;
static uint8_t led_boot_enabled = DEFAULT_LED_BOOT_ENABLED;
static uint8_t storage_backend = DEFAULT_STORAGE_BACKEND;
/* Consecutive post-crash (watchdog/lockup) boots observed while the ring backend
 * is active. Anti-brick: at RING_BOOT_FAIL_LIMIT the device auto-reverts to the
 * known-good LittleFS backend so a ring bug can't crash-loop it into needing a
 * reflash (BLE/DFU is up before the SD wait, so it's reachable regardless — this
 * also gets recording working again). Cleared once a boot proves healthy. */
static uint8_t ring_boot_fails = 0;
/* Armed by the backend-switch command with the TARGET backend to format; consumed at the
 * next sd_mount() (a plain mount can otherwise pick up stale on-card metadata from the
 * previous backend and mount OK onto overwritten bytes). Holds STORAGE_FORMAT_PENDING_NONE
 * when disarmed — the default, so an existing device that upgrades never force-formats. */
static uint8_t storage_format_pending = STORAGE_FORMAT_PENDING_NONE;
static struct rtc_time rtc_timestamp = {0};
static uint64_t rtc_epoch = 0;

struct lsm6dsl_time_base {
    uint64_t epoch_s;
    uint32_t ts;
    uint32_t reserved;
};

static struct lsm6dsl_time_base lsm6dsl_time_base = {0};

struct last_reset_record {
    uint32_t cause;
    uint32_t _pad;
    uint64_t uptime_ms;
};

static struct last_reset_record last_reset = {0};
static uint64_t crash_session_uptime_ms = 0;

/* BLE connection-establishment failure counter, persisted so it survives the
 * power-cycle the user must perform to reconnect and read it. */
/* v1 was {count, last_adv_slow, _pad[3]} = 8 bytes. v2 appends estab_count.
 * Loader accepts both sizes so an in-field device keeps its history across the
 * firmware update that adds the field (v1 records load with estab_count = 0). */
struct conn_fail_record {
    uint32_t count;
    uint8_t last_adv_slow;
    uint8_t _pad[3];
    uint32_t estab_count;
};

#define CONN_FAIL_RECORD_V1_SIZE 8

static struct conn_fail_record conn_fail = {0};

/* 6 bytes: 1 tap, 1 tap hold, 2 tap, 2 tap hold, 3 tap, 3 tap hold.
 * Actions: 0=None, 1=Mute, 2=Marker, 3=Toggle LED, 4=Record Start, 5=Record Stop.
 * Default matches the app's manual-mode default (the device boots in manual
 * standby): single-hold=Marker, double=Start, double-hold=Toggle LED, triple=Stop.
 * The app pushes the per-mode config (manual/auto) on connect, so this only
 * governs a factory device that has never been connected to the app. */
static uint8_t button_config[6] = {0, 2, 4, 3, 5, 0};

/* Per-tap-slot vibration pattern, same slot order as button_config.
 * Patterns: 0=Off, 1=Single, 2=Double, 3=Triple. Default off everywhere. */
static uint8_t haptic_config[6] = {0, 0, 0, 0, 0, 0};

/* One-shot "unpair after firmware update" marker: the firmware version the
 * device was running when the app armed a post-update bond wipe
 * (CMD_ARM_POST_DFU_UNPAIR). Empty = disarmed. On boot, a running version that
 * DIFFERS from this armed value means a real update landed → wipe. Capturing the
 * version at ARM time (a deliberate, pre-flash act) means the wipe decision
 * doesn't depend on any boot-time persistence, and it's fail-closed: if arming
 * never persisted, the value stays empty and no wipe ever fires. Rides through
 * the DFU in NVS. */
static char unpair_armed_fw[24] = {0};


static int settings_set(const char *name, size_t len, settings_read_cb read_cb, void *cb_arg)
{
    const char *next;
    int rc;

    if (settings_name_steq(name, "dim_ratio", &next) && !next) {
        if (len != sizeof(dim_light_ratio)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &dim_light_ratio, sizeof(dim_light_ratio));
        if (rc >= 0) {
            LOG_INF("Loaded dim_ratio: %u", dim_light_ratio);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "mic_gain", &next) && !next) {
        if (len != sizeof(mic_gain)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &mic_gain, sizeof(mic_gain));
        if (rc >= 0) {
            LOG_INF("Loaded mic_gain: %u", mic_gain);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "vad_threshold", &next) && !next) {
        if (len != sizeof(vad_threshold)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &vad_threshold, sizeof(vad_threshold));
        if (rc >= 0) {
            LOG_INF("Loaded vad_threshold: %u", vad_threshold);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "prio_rec_max", &next) && !next) {
        if (len != sizeof(priority_record_max_minutes)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &priority_record_max_minutes, sizeof(priority_record_max_minutes));
        if (rc >= 0) {
            LOG_INF("Loaded prio_rec_max: %u", priority_record_max_minutes);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "led_conn", &next) && !next) {
        if (len != sizeof(connected_led_enabled)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &connected_led_enabled, sizeof(connected_led_enabled));
        if (rc >= 0) {
            connected_led_enabled = connected_led_enabled ? 1 : 0;
            LOG_INF("Loaded led_conn: %u", connected_led_enabled);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "led_boot", &next) && !next) {
        if (len != sizeof(led_boot_enabled)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &led_boot_enabled, sizeof(led_boot_enabled));
        if (rc >= 0) {
            led_boot_enabled = led_boot_enabled ? 1 : 0;
            LOG_INF("Loaded led_boot: %u", led_boot_enabled);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "storage_backend", &next) && !next) {
        if (len != sizeof(storage_backend)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &storage_backend, sizeof(storage_backend));
        if (rc >= 0) {
            if (storage_backend > STORAGE_BACKEND_RING) {
                storage_backend = DEFAULT_STORAGE_BACKEND; /* reject an out-of-range persisted value */
            }
            LOG_INF("Loaded storage_backend: %u", storage_backend);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "ring_boot_fails", &next) && !next) {
        if (len != sizeof(ring_boot_fails)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &ring_boot_fails, sizeof(ring_boot_fails));
        if (rc >= 0) {
            LOG_INF("Loaded ring_boot_fails: %u", ring_boot_fails);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "storage_format_pending", &next) && !next) {
        if (len != sizeof(storage_format_pending)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &storage_format_pending, sizeof(storage_format_pending));
        if (rc >= 0) {
            LOG_INF("Loaded storage_format_pending: %u", storage_format_pending);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "rtc_timestamp", &next) && !next) {
        if (len != sizeof(rtc_timestamp)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &rtc_timestamp, sizeof(rtc_timestamp));
        if (rc >= 0) {
            LOG_INF("Loaded rtc_timestamp");
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "rtc_epoch", &next) && !next) {
        /* Backward compatibility: older builds may have stored epoch as u32. */
        if (len == sizeof(rtc_epoch)) {
            rc = read_cb(cb_arg, &rtc_epoch, sizeof(rtc_epoch));
            if (rc >= 0) {
                LOG_INF("Loaded rtc_epoch=%llu", rtc_epoch);
                return 0;
            }
            return rc;
        }

        if (len == sizeof(uint32_t)) {
            uint32_t epoch_u32 = 0;
            rc = read_cb(cb_arg, &epoch_u32, sizeof(epoch_u32));
            if (rc >= 0) {
                rtc_epoch = (uint64_t) epoch_u32;
                LOG_INF("Loaded rtc_epoch(u32)=%u -> %llu", epoch_u32, rtc_epoch);
                return 0;
            }
            return rc;
        }

        LOG_WRN("rtc_epoch size mismatch: len=%u expected=%u (or legacy %u)",
                (unsigned) len,
                (unsigned) sizeof(rtc_epoch),
                (unsigned) sizeof(uint32_t));
        return -EINVAL;
    }

    if (settings_name_steq(name, "lsm6dsl_time_base", &next) && !next) {
        if (len == sizeof(lsm6dsl_time_base)) {
            rc = read_cb(cb_arg, &lsm6dsl_time_base, sizeof(lsm6dsl_time_base));
            if (rc >= 0) {
                LOG_INF("Loaded lsm6dsl_time_base: epoch_s=%llu ts=0x%08x",
                        lsm6dsl_time_base.epoch_s,
                        lsm6dsl_time_base.ts);
                return 0;
            }
            return rc;
        }

        /* Backward compatibility: older builds may have stored without reserved (12 bytes). */
        if (len == (sizeof(uint64_t) + sizeof(uint32_t))) {
            struct {
                uint64_t epoch_s;
                uint32_t ts;
            } legacy;

            rc = read_cb(cb_arg, &legacy, sizeof(legacy));
            if (rc >= 0) {
                lsm6dsl_time_base.epoch_s = legacy.epoch_s;
                lsm6dsl_time_base.ts = legacy.ts;
                lsm6dsl_time_base.reserved = 0;
                LOG_INF("Loaded lsm6dsl_time_base(legacy): epoch_s=%llu ts=0x%08x", legacy.epoch_s, legacy.ts);
                return 0;
            }
            return rc;
        }

        LOG_WRN("lsm6dsl_time_base size mismatch: len=%u expected=%u (or legacy %u)",
                (unsigned) len,
                (unsigned) sizeof(lsm6dsl_time_base),
                (unsigned) (sizeof(uint64_t) + sizeof(uint32_t)));
        return -EINVAL;
    }

    if (settings_name_steq(name, "last_reset", &next) && !next) {
        if (len != sizeof(last_reset)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &last_reset, sizeof(last_reset));
        if (rc >= 0) {
            LOG_INF("Loaded last_reset: cause=0x%08x uptime=%llums", last_reset.cause, last_reset.uptime_ms);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "crash_uptime", &next) && !next) {
        if (len != sizeof(crash_session_uptime_ms)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &crash_session_uptime_ms, sizeof(crash_session_uptime_ms));
        if (rc >= 0) {
            LOG_INF("Loaded crash_uptime: %llums", crash_session_uptime_ms);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "conn_fail", &next) && !next) {
        if (len != sizeof(conn_fail) && len != CONN_FAIL_RECORD_V1_SIZE) {
            return -EINVAL;
        }
        /* Zero first so a short (v1) read leaves estab_count at 0 rather than stale. */
        memset(&conn_fail, 0, sizeof(conn_fail));
        rc = read_cb(cb_arg, &conn_fail, len);
        if (rc >= 0) {
            LOG_INF("Loaded conn_fail: count=%u last_adv_slow=%u estab_count=%u",
                    conn_fail.count,
                    conn_fail.last_adv_slow,
                    conn_fail.estab_count);
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "button_config", &next) && !next) {
        if (len != sizeof(button_config)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, button_config, sizeof(button_config));
        if (rc >= 0) {
            LOG_INF("Loaded button_config");
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "haptic_config", &next) && !next) {
        if (len != sizeof(haptic_config)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, haptic_config, sizeof(haptic_config));
        if (rc >= 0) {
            LOG_INF("Loaded haptic_config");
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "unpair_armed_fw", &next) && !next) {
        if (len > sizeof(unpair_armed_fw)) {
            return -EINVAL;
        }
        memset(unpair_armed_fw, 0, sizeof(unpair_armed_fw));
        rc = read_cb(cb_arg, unpair_armed_fw, len);
        if (rc >= 0) {
            unpair_armed_fw[sizeof(unpair_armed_fw) - 1] = '\0';
            LOG_INF("Loaded unpair_armed_fw: '%s'", unpair_armed_fw);
            return 0;
        }
        return rc;
    }


    return -ENOENT;
}

int app_settings_save_rtc_timestamp(struct rtc_time ts)
{
    rtc_timestamp = ts;
    int err = settings_save_one("omi/rtc_timestamp", &rtc_timestamp, sizeof(rtc_timestamp));
    if (err) {
        LOG_ERR("Failed to save rtc_timestamp (err %d)", err);
    } else {
        LOG_INF("Saved rtc_timestamp");
    }
    return err;
}

struct rtc_time app_settings_get_rtc_timestamp(void)
{
    return rtc_timestamp;
}

int app_settings_save_rtc_epoch(uint64_t epoch_s)
{
    rtc_epoch = epoch_s;
    int err = settings_save_one("omi/rtc_epoch", &rtc_epoch, sizeof(rtc_epoch));
    if (err) {
        LOG_ERR("Failed to save rtc_epoch (err %d)", err);
    } else {
        LOG_INF("Saved rtc_epoch");
    }
    return err;
}

uint64_t app_settings_get_rtc_epoch(void)
{
    return rtc_epoch;
}

int app_settings_save_lsm6dsl_time_base(uint64_t epoch_s, uint32_t imu_timestamp)
{
    lsm6dsl_time_base.epoch_s = epoch_s;
    lsm6dsl_time_base.ts = imu_timestamp;
    lsm6dsl_time_base.reserved = 0;

    int err = settings_save_one("omi/lsm6dsl_time_base", &lsm6dsl_time_base, sizeof(lsm6dsl_time_base));
    if (err) {
        LOG_ERR("Failed to save lsm6dsl_time_base (err %d)", err);
    } else {
        LOG_INF("Saved lsm6dsl_time_base");
    }
    return err;
}

int app_settings_get_lsm6dsl_time_base(uint64_t *epoch_s, uint32_t *imu_timestamp)
{
    if (epoch_s == NULL || imu_timestamp == NULL) {
        return -EINVAL;
    }
    *epoch_s = lsm6dsl_time_base.epoch_s;
    *imu_timestamp = lsm6dsl_time_base.ts;
    return 0;
}

SETTINGS_STATIC_HANDLER_DEFINE(app_settings, "omi", NULL, settings_set, NULL, NULL);

int app_settings_init(void)
{
    int err = settings_subsys_init();
    if (err) {
        LOG_ERR("Failed to initialize settings subsystem (err %d)", err);
        return err;
    }

    /* Load only app-owned settings here.
     * BT settings must be loaded after bt_enable(). */
    err = settings_load_subtree("omi");
    if (err && err != -ENOENT) {
        LOG_ERR("Failed to load app settings (err %d)", err);
    }

    LOG_INF("Settings initialized. dim_ratio=%u mic_gain=%u vad_threshold=%u rtc_epoch=%llu lsm6_base_epoch=%llu "
            "lsm6_base_ts=0x%08x",
            dim_light_ratio,
            mic_gain,
            vad_threshold,
            rtc_epoch,
            lsm6dsl_time_base.epoch_s,
            lsm6dsl_time_base.ts);
    return (err == -ENOENT) ? 0 : err;
}

int app_settings_save_dim_ratio(uint8_t new_ratio)
{
    dim_light_ratio = new_ratio;
    int err = settings_save_one("omi/dim_ratio", &dim_light_ratio, sizeof(dim_light_ratio));
    if (err) {
        LOG_ERR("Failed to save dim_ratio (err %d)", err);
    } else {
        LOG_INF("Saved dim_ratio: %u", dim_light_ratio);
    }
    return err;
}

uint8_t app_settings_get_dim_ratio(void)
{
    return dim_light_ratio;
}

int app_settings_save_mic_gain(uint8_t new_gain)
{
    mic_gain = new_gain;
    int err = settings_save_one("omi/mic_gain", &mic_gain, sizeof(mic_gain));
    if (err) {
        LOG_ERR("Failed to save mic_gain (err %d)", err);
    } else {
        LOG_INF("Saved mic_gain: %u", mic_gain);
    }
    return err;
}

uint8_t app_settings_get_mic_gain(void)
{
    return mic_gain;
}

int app_settings_save_vad_threshold(uint16_t new_threshold)
{
    vad_threshold = new_threshold;
    int err = settings_save_one("omi/vad_threshold", &vad_threshold, sizeof(vad_threshold));
    if (err) {
        LOG_ERR("Failed to save vad_threshold (err %d)", err);
    } else {
        LOG_INF("Saved vad_threshold: %u", vad_threshold);
    }
    return err;
}

uint16_t app_settings_get_vad_threshold(void)
{
    return vad_threshold;
}

int app_settings_save_connected_led(bool enabled)
{
    uint8_t value = enabled ? 1 : 0;
    int err = settings_save_one("omi/led_conn", &value, sizeof(value));
    if (err) {
        LOG_ERR("Failed to save led_conn (err %d)", err);
        return err;
    }
    connected_led_enabled = value;
    LOG_INF("Saved led_conn: %u", connected_led_enabled);
    return 0;
}

bool app_settings_get_connected_led(void)
{
    return connected_led_enabled != 0;
}

int app_settings_save_led_boot_enabled(bool enabled)
{
    uint8_t value = enabled ? 1 : 0;
    int err = settings_save_one("omi/led_boot", &value, sizeof(value));
    if (err) {
        LOG_ERR("Failed to save led_boot (err %d)", err);
        return err;
    }
    led_boot_enabled = value;
    LOG_INF("Saved led_boot: %u", led_boot_enabled);
    return 0;
}

bool app_settings_get_led_boot_enabled(void)
{
    return led_boot_enabled != 0;
}

int app_settings_save_storage_backend(uint8_t backend)
{
    if (backend > STORAGE_BACKEND_RING) {
        return -EINVAL;
    }
    /* Only update the in-memory selector after the NVS write succeeds, so a failed
     * save leaves the cache consistent with the persisted value and the mounted
     * backend (a nonzero ACK then honestly reports "unchanged"). */
    int err = settings_save_one("omi/storage_backend", &backend, sizeof(backend));
    if (err) {
        LOG_ERR("Failed to save storage_backend (err %d)", err);
        return err;
    }
    storage_backend = backend;
    LOG_INF("Saved storage_backend: %u", storage_backend);
    return 0;
}

uint8_t app_settings_get_storage_backend(void)
{
    return storage_backend;
}

int app_settings_save_ring_boot_fails(uint8_t fails)
{
    ring_boot_fails = fails;
    int err = settings_save_one("omi/ring_boot_fails", &ring_boot_fails, sizeof(ring_boot_fails));
    if (err) {
        LOG_ERR("Failed to save ring_boot_fails (err %d)", err);
    }
    return err;
}

uint8_t app_settings_get_ring_boot_fails(void)
{
    return ring_boot_fails;
}

int app_settings_save_storage_format_pending(uint8_t target)
{
    /* target is a STORAGE_BACKEND_* to format, or STORAGE_FORMAT_PENDING_NONE to disarm.
     * Stored verbatim — the mount validates it against the backend it actually mounts. */
    int err = settings_save_one("omi/storage_format_pending", &target, sizeof(target));
    if (err) {
        LOG_ERR("Failed to save storage_format_pending (err %d)", err);
        return err;
    }
    storage_format_pending = target;
    LOG_INF("Saved storage_format_pending: %u", storage_format_pending);
    return 0;
}

uint8_t app_settings_get_storage_format_pending(void)
{
    return storage_format_pending;
}

int app_settings_save_priority_record_max_minutes(uint16_t minutes)
{
    priority_record_max_minutes = minutes;
    int err = settings_save_one("omi/prio_rec_max", &priority_record_max_minutes, sizeof(priority_record_max_minutes));
    if (err) {
        LOG_ERR("Failed to save prio_rec_max (err %d)", err);
    } else {
        LOG_INF("Saved prio_rec_max: %u", priority_record_max_minutes);
    }
    return err;
}

uint16_t app_settings_get_priority_record_max_minutes(void)
{
    return priority_record_max_minutes;
}

int app_settings_save_last_reset(uint32_t cause, uint64_t uptime_ms)
{
    last_reset.cause = cause;
    last_reset.uptime_ms = uptime_ms;
    int err = settings_save_one("omi/last_reset", &last_reset, sizeof(last_reset));
    if (err) {
        LOG_ERR("Failed to save last_reset (err %d)", err);
    }
    return err;
}

uint32_t app_settings_get_last_reset_cause(void)
{
    return last_reset.cause;
}

uint64_t app_settings_get_last_reset_uptime_ms(void)
{
    return last_reset.uptime_ms;
}

int app_settings_save_crash_session_uptime(uint64_t uptime_ms)
{
    crash_session_uptime_ms = uptime_ms;
    int err = settings_save_one("omi/crash_uptime", &crash_session_uptime_ms, sizeof(crash_session_uptime_ms));
    if (err) {
        LOG_ERR("Failed to save crash_uptime (err %d)", err);
    }
    return err;
}

uint64_t app_settings_get_crash_session_uptime(void)
{
    return crash_session_uptime_ms;
}

int app_settings_save_conn_fail(uint32_t count, uint8_t last_adv_slow, uint32_t estab_count)
{
    conn_fail.count = count;
    conn_fail.last_adv_slow = last_adv_slow;
    conn_fail.estab_count = estab_count;
    int err = settings_save_one("omi/conn_fail", &conn_fail, sizeof(conn_fail));
    if (err) {
        LOG_ERR("Failed to save conn_fail (err %d)", err);
    }
    return err;
}

void app_settings_get_conn_fail(uint32_t *count, uint8_t *last_adv_slow, uint32_t *estab_count)
{
    if (count) {
        *count = conn_fail.count;
    }
    if (last_adv_slow) {
        *last_adv_slow = conn_fail.last_adv_slow;
    }
    if (estab_count) {
        *estab_count = conn_fail.estab_count;
    }
}

int app_settings_save_button_config(const uint8_t config[6])
{
    memcpy(button_config, config, sizeof(button_config));
    int err = settings_save_one("omi/button_config", button_config, sizeof(button_config));
    if (err) {
        LOG_ERR("Failed to save button_config (err %d)", err);
    } else {
        LOG_INF("Saved button_config");
    }
    return err;
}

void app_settings_get_button_config(uint8_t config[6])
{
    memcpy(config, button_config, sizeof(button_config));
}

int app_settings_save_haptic_config(const uint8_t config[6])
{
    memcpy(haptic_config, config, sizeof(haptic_config));
    int err = settings_save_one("omi/haptic_config", haptic_config, sizeof(haptic_config));
    if (err) {
        LOG_ERR("Failed to save haptic_config (err %d)", err);
    } else {
        LOG_INF("Saved haptic_config");
    }
    return err;
}

void app_settings_get_haptic_config(uint8_t config[6])
{
    memcpy(config, haptic_config, sizeof(haptic_config));
}

int app_settings_arm_post_dfu_unpair(bool arm, const char *current_fw)
{
    if (arm && (current_fw == NULL || current_fw[0] == '\0')) {
        /* The empty string is the disarmed sentinel, so arming with no version
         * to key on would silently no-op while reporting success. Refuse loudly
         * rather than persist a marker that can never fire. */
        LOG_ERR("post-DFU unpair: refusing to arm with an empty firmware version");
        return -EINVAL;
    }
    char buf[sizeof(unpair_armed_fw)];
    memset(buf, 0, sizeof(buf));
    if (arm) {
        /* current_fw is guaranteed non-empty here. */
        strncpy(buf, current_fw, sizeof(buf) - 1);
    }
    /* buf is the empty string when disarming. */
    /* Skip the flash write when the value isn't actually changing. The app
     * arms/disarms this on EVERY DFU — including a disarm on every update where
     * the "reset pairing after update" option is off — and this NVS instance is
     * the same one that holds the BLE bond keys. Rewriting the marker to the
     * value it already has, then rebooting for the flash moments later, is a
     * needless write next to the bonds right before a power event (a suspected
     * cause of bonds not surviving an update). A genuine arm/disarm — including
     * clearing a real stale arm from an earlier failed flash — still writes. */
    if (memcmp(buf, unpair_armed_fw, sizeof(buf)) == 0) {
        LOG_INF("post-DFU unpair: already %s, skipping redundant flash write", arm ? "armed" : "disarmed");
        return 0;
    }
    int err = settings_save_one("omi/unpair_armed_fw", buf, sizeof(buf));
    if (err) {
        LOG_ERR("Failed to save unpair_armed_fw (err %d)", err);
        return err;
    }
    memcpy(unpair_armed_fw, buf, sizeof(buf));
    if (arm) {
        LOG_INF("post-DFU unpair armed @ '%s'", current_fw);
    } else {
        LOG_INF("post-DFU unpair disarmed");
    }
    return 0;
}




bool app_settings_consume_post_dfu_unpair(const char *current_fw)
{
    if (unpair_armed_fw[0] == '\0') {
        return false; /* not armed */
    }
    bool changed = (current_fw != NULL) && strncmp(unpair_armed_fw, current_fw, sizeof(unpair_armed_fw)) != 0;

    /* One-shot: clear the armed marker. If the clear fails it stays set and a
     * later boot re-evaluates — harmless: a same-version boot returns false (no
     * wipe), and a changed boot would at worst do a redundant idempotent wipe. */
    char empty[sizeof(unpair_armed_fw)];
    memset(empty, 0, sizeof(empty));
    int err = settings_save_one("omi/unpair_armed_fw", empty, sizeof(empty));
    if (err) {
        LOG_ERR("Failed to clear unpair_armed_fw (err %d)", err);
    } else {
        memset(unpair_armed_fw, 0, sizeof(unpair_armed_fw));
    }
    return changed;
}
