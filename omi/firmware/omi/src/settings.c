#include "lib/core/settings.h"

#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>

/* Partition Manager's generated layout, for the trailer-overlap BUILD_ASSERT
 * below. Guarded because the assert is skipped entirely without PM. */
#if defined(CONFIG_PARTITION_MANAGER_ENABLED)
#include <pm_config.h>
#endif

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

// In-memory cache for the settings
static uint8_t dim_light_ratio = DEFAULT_DIM_LIGHT_RATIO;
static uint8_t mic_gain = DEFAULT_MIC_GAIN;
static uint16_t vad_threshold = DEFAULT_VAD_THRESHOLD;
static uint16_t priority_record_max_minutes = DEFAULT_PRIORITY_RECORD_MAX_MINUTES;
static uint8_t connected_led_enabled = DEFAULT_CONNECTED_LED;
static uint8_t led_boot_enabled = DEFAULT_LED_BOOT_ENABLED;
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

/* One-shot "wipe BLE bonds on the next boot" marker, set when mcumgr reports a
 * firmware image has finished transferring (MGMT_EVT_OP_IMG_MGMT_DFU_PENDING,
 * main.c) and consumed by transport_start(). A flash rewrites the MCUboot primary
 * slot whether or not the version changed, and any bond it corrupts is
 * unrecoverable from the phone: CONFIG_BT_MAX_PAIRED=1 plus an unset
 * CONFIG_BT_SMP_ALLOW_UNAUTH_OVERWRITE means update_keys_check() refuses a fresh
 * Just Works pairing whenever a key slot is occupied — by a valid key or by a
 * corrupt one, it cannot tell the difference. So the device frees the slot after
 * every flash, and the app clears its own bond on DFU success; both sides
 * re-pair clean.
 *
 * Deliberately keyed on "a DFU landed", NOT on the firmware version changing. A
 * same-version reflash writes the slot just as hard, so a version comparison
 * would skip exactly the recovery flash a user performs *because* pairing is
 * already broken. It also removes the arm/ACK ambiguity of the old
 * CMD_ARM_POST_DFU_UNPAIR design: the device observes the DFU itself and infers
 * nothing from the app.
 *
 * Every divergence lands on "device slot free, phone possibly stale", which the
 * user can fix from the phone (Forget Device). The reverse — device bonded,
 * phone wiped — needs the 5-tap gesture on the device, so it is the one outcome
 * worth engineering against. */
static bool dfu_bond_wipe_pending = false;

/* Set once, on the first boot of any firmware carrying the scheme above.
 *
 * Migration backstop. The flash that first installs this firmware is performed by
 * the PREVIOUS image, which has no DFU_PENDING hook and therefore cannot arm
 * dfu_bond_wipe — while an app new enough to pair with this firmware clears the
 * phone bond on success regardless. That combination is the one unrecoverable
 * outcome (phone unbonded, device still holding its key slot), and without this
 * it would hit every existing device on the very update that introduces the
 * feature. So a boot that has never seen this marker wipes once and records it.
 *
 * Harmless in the other two cases it also catches: a factory device has no bond
 * to wipe, and a device flashed by an older app keeps its phone bond, which is
 * the direction Forget Device can fix. */
static bool dfu_wipe_scheme_seen = false;

/* MCUboot runs OVERWRITE_ONLY_FAST here (CONFIG_BOOT_UPGRADE_ONLY=y expands to
 * both MCUBOOT_OVERWRITE_ONLY and _FAST, mcuboot_config.h:72-75), and its
 * boot_copy_image() erases whole sectors downward from the TOP of the primary
 * slot until they cover boot_trailer_sz() (loader.c:1889-1900). settings_storage
 * sits inside that slot — 0xfc000-0xfe000, versus mcuboot_primary's
 * 0x10000-0x100000 — so it survives only because the erase does not reach down
 * that far. It is not outside the blast radius; it is below it.
 *
 * Verified against NCS v2.9.0 rather than assumed. With N =
 * CONFIG_BOOT_MAX_IMG_SECTORS and min_write_sz = flash_area_align() of the
 * PRIMARY slot = the SoC's internal-flash write-block-size = 4:
 *
 *   trailer_sz = N * BOOT_STATUS_STATE_COUNT * min_write_sz
 *                + (BOOT_MAX_ALIGN * 4 + BOOT_MAGIC_SZ)
 *              = N * 3 * 4 + (8 * 4 + 16)  =  12N + 48
 *
 * and the erase covers ceil(trailer_sz / 4096) sectors down from 0x100000:
 *
 *   N <=  337   1 sector   0xff000-0x100000   settings_storage untouched  <-- N=256 today (3120 B)
 *   N <=  678   2 sectors  0xfe000-0x100000   untouched (it ends exactly at 0xfe000)
 *   N <= 1020   3 sectors  0xfd000-0x100000   ERASES the upper half of settings_storage
 *   N >= 1021   4 sectors  0xfc000-0x100000   erases settings_storage in full
 *
 * READ THIS BEFORE TRUSTING THE ASSERT. It checks the LAYOUT — that
 * settings_storage keeps two sectors of margin below the slot top — which is
 * necessary but NOT sufficient. It cannot check the trailer SIZE, because
 * CONFIG_BOOT_MAX_IMG_SECTORS belongs to the mcuboot image and is not defined in
 * this one (verified: absent from the app's autoconf.h). So raising it to 679 or
 * beyond silently starts erasing settings_storage while this assert still
 * passes. Two sectors is also the most the current layout can assert — the
 * margin is exactly 0x2000 — so the bound cannot simply be widened; buying more
 * headroom means moving the partition down. If you change that Kconfig, re-run
 * the table above by hand. Nothing else will catch it.
 *
 * The layout is chosen dynamically by Partition Manager (boards/omi/pm_static.yml
 * is NOT applied — PM reads pm_static.yml from the application directory), which
 * is exactly why this asserts the property rather than trusting the addresses. */
#if defined(PM_SETTINGS_STORAGE_END_ADDRESS) && defined(PM_MCUBOOT_PRIMARY_END_ADDRESS)
BUILD_ASSERT(PM_SETTINGS_STORAGE_END_ADDRESS <= PM_MCUBOOT_PRIMARY_END_ADDRESS - 0x2000,
             "settings_storage is within two sectors of the top of the MCUboot primary slot, "
             "where the OVERWRITE_ONLY_FAST trailer erase lands: an OTA could erase BLE bonds "
             "and settings. Move the partition; do not widen this bound.");
#endif


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

    if (settings_name_steq(name, "dfu_bond_wipe", &next) && !next) {
        uint8_t stored;
        if (len != sizeof(stored)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &stored, sizeof(stored));
        if (rc >= 0) {
            dfu_bond_wipe_pending = (stored != 0);
            LOG_INF("Loaded dfu_bond_wipe: %s", dfu_bond_wipe_pending ? "pending" : "clear");
            return 0;
        }
        return rc;
    }

    if (settings_name_steq(name, "dfu_wipe_seen", &next) && !next) {
        uint8_t stored;
        if (len != sizeof(stored)) {
            return -EINVAL;
        }
        rc = read_cb(cb_arg, &stored, sizeof(stored));
        if (rc >= 0) {
            dfu_wipe_scheme_seen = (stored != 0);
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

int app_settings_arm_dfu_bond_wipe(void)
{
    /* Idempotent: mcumgr can notify DFU_PENDING more than once for a single
     * update (a client that marks the image pending and then confirms it), and
     * this NVS instance also holds the BLE bond keys. Re-writing the same value
     * moments before the flash reboot is a needless erase cycle next to them. */
    if (dfu_bond_wipe_pending) {
        LOG_INF("DFU bond wipe: already pending, skipping redundant flash write");
        return 0;
    }
    uint8_t val = 1;
    int err = settings_save_one("omi/dfu_bond_wipe", &val, sizeof(val));
    if (err) {
        /* Best-effort. A miss here means the device keeps its bond across the
         * flash while the app clears its own on success — the phone can restore
         * that from Forget Device, unlike the reverse. */
        LOG_ERR("Failed to save dfu_bond_wipe (err %d)", err);
        return err;
    }
    dfu_bond_wipe_pending = true;
    LOG_INF("DFU bond wipe armed — bonds will be cleared on the next boot");
    return 0;
}




bool app_settings_consume_dfu_bond_wipe(void)
{
    /* Two independent reasons to wipe: a DFU landed (dfu_bond_wipe_pending), or
     * this is the first boot of any firmware carrying the scheme — see
     * dfu_wipe_scheme_seen for why that flash can never have armed its own
     * marker.
     *
     * Both markers are retired here, BEFORE the caller's bt_unpair() runs, and
     * that ordering is deliberate rather than an oversight. A review flagged it
     * as "a failed unpair is never retried", but bt_unpair(BT_ID_DEFAULT,
     * BT_ADDR_LE_ANY) cannot fail: its only error returns are id >=
     * CONFIG_BT_ID_MAX (we pass 0) and a NULL addr under !CONFIG_BT_SMP (we pass
     * BT_ADDR_LE_ANY, and SMP is on) — every other path falls through to
     * return 0. Splitting this into query + explicit-clear to guard that branch
     * was tried and reverted: it bought nothing and made the caller responsible
     * for a second call which, if ever forgotten, wipes bonds on every boot. */
    bool due = dfu_bond_wipe_pending || !dfu_wipe_scheme_seen;
    if (!due) {
        return false;
    }

    if (dfu_bond_wipe_pending) {
        uint8_t val = 0;
        int err = settings_save_one("omi/dfu_bond_wipe", &val, sizeof(val));
        if (err) {
            /* Left set: the next boot wipes again. Idempotent and harmless — the
             * bonds are already gone — which is the right way to fail for a
             * marker whose only job is to guarantee a free key slot. */
            LOG_ERR("Failed to clear dfu_bond_wipe (err %d)", err);
        } else {
            dfu_bond_wipe_pending = false;
        }
    }

    if (!dfu_wipe_scheme_seen) {
        LOG_INF("DFU bond wipe: first boot with this scheme — wiping once to match the app");
        uint8_t seen = 1;
        int err = settings_save_one("omi/dfu_wipe_seen", &seen, sizeof(seen));
        if (err) {
            LOG_ERR("Failed to save dfu_wipe_seen (err %d)", err);
        } else {
            dfu_wipe_scheme_seen = true;
        }
    }

    return true;
}
