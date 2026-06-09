#include "lib/core/settings.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>

LOG_MODULE_REGISTER(app_settings, CONFIG_LOG_DEFAULT_LEVEL);

// Default values if not found in flash
#define DEFAULT_DIM_LIGHT_RATIO 50
#define DEFAULT_MIC_GAIN 6
#define DEFAULT_VAD_THRESHOLD 32769

// In-memory cache for the settings
static uint8_t dim_light_ratio = DEFAULT_DIM_LIGHT_RATIO;
static uint8_t mic_gain = DEFAULT_MIC_GAIN;
static uint16_t vad_threshold = DEFAULT_VAD_THRESHOLD;
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
struct conn_fail_record {
    uint32_t count;
    uint8_t last_adv_slow;
    uint8_t _pad[3];
};

static struct conn_fail_record conn_fail = {0};

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
                rtc_epoch = (uint64_t)epoch_u32;
                LOG_INF("Loaded rtc_epoch(u32)=%u -> %llu", epoch_u32, rtc_epoch);
                return 0;
            }
            return rc;
        }

        LOG_WRN("rtc_epoch size mismatch: len=%u expected=%u (or legacy %u)",
            (unsigned)len, (unsigned)sizeof(rtc_epoch), (unsigned)sizeof(uint32_t));
        return -EINVAL;
    }

    if (settings_name_steq(name, "lsm6dsl_time_base", &next) && !next) {
        if (len == sizeof(lsm6dsl_time_base)) {
            rc = read_cb(cb_arg, &lsm6dsl_time_base, sizeof(lsm6dsl_time_base));
            if (rc >= 0) {
                LOG_INF("Loaded lsm6dsl_time_base: epoch_s=%llu ts=0x%08x", lsm6dsl_time_base.epoch_s, lsm6dsl_time_base.ts);
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
            (unsigned)len, (unsigned)sizeof(lsm6dsl_time_base), (unsigned)(sizeof(uint64_t) + sizeof(uint32_t)));
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
        if (len != sizeof(conn_fail)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &conn_fail, sizeof(conn_fail));
        if (rc >= 0) {
            LOG_INF("Loaded conn_fail: count=%u last_adv_slow=%u", conn_fail.count, conn_fail.last_adv_slow);
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

    LOG_INF("Settings initialized. dim_ratio=%u mic_gain=%u vad_threshold=%u rtc_epoch=%llu lsm6_base_epoch=%llu lsm6_base_ts=0x%08x",
		dim_light_ratio, mic_gain, vad_threshold, rtc_epoch, lsm6dsl_time_base.epoch_s, lsm6dsl_time_base.ts);
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

int app_settings_save_conn_fail(uint32_t count, uint8_t last_adv_slow)
{
    conn_fail.count = count;
    conn_fail.last_adv_slow = last_adv_slow;
    int err = settings_save_one("omi/conn_fail", &conn_fail, sizeof(conn_fail));
    if (err) {
        LOG_ERR("Failed to save conn_fail (err %d)", err);
    }
    return err;
}

void app_settings_get_conn_fail(uint32_t *count, uint8_t *last_adv_slow)
{
    if (count) {
        *count = conn_fail.count;
    }
    if (last_adv_slow) {
        *last_adv_slow = conn_fail.last_adv_slow;
    }
}

