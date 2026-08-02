#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/random/random.h>

#include "lib/core/transport.h"
#include "lib/core/button.h"
#include "lib/core/led.h"
#include "lib/core/mic.h"
#include "lib/core/haptic.h"
#include "lib/core/utils.h"
#include "lib/core/lib/battery/battery.h"
#include "lib/core/sd_card.h"
#include "lib/core/storage.h"
#include "lib/core/settings.h"
#include "lib/core/codec.h"
#include "lib/core/config.h"
#include "lib/core/diag_log.h"
#include "rtc.h"
#include "imu.h"

#include "spi_flash.h"
#include "wdog_facade.h"

#ifdef CONFIG_HWINFO
#include <zephyr/drivers/hwinfo.h>
#endif

#include <zephyr/mgmt/mcumgr/grp/img_mgmt/img_mgmt.h>
#include <zephyr/mgmt/mcumgr/mgmt/callbacks.h>
#include <zephyr/mgmt/mcumgr/grp/img_mgmt/img_mgmt_callbacks.h>

#ifdef CONFIG_OMI_ENABLE_T5838_AAD
#include "aad.h"
#endif

LOG_MODULE_REGISTER(main, CONFIG_LOG_DEFAULT_LEVEL);

#ifdef CONFIG_OMI_ENABLE_BATTERY
#define BATTERY_FULL_THRESHOLD_PERCENT 98 // 98%
extern uint8_t battery_percentage;
#endif

/* Set when the SD card fails to become ready within SD_BOOT_TIMEOUT_MS. The
 * device keeps running (BLE/mic) but cannot record. set_led_state() then
 * blinks the LED red, ignoring stealth/mute/marker/button states, so the user
 * can tell a fault (blinking red) apart from mute (solid red). */
static volatile bool sd_fatal_error = false;
#define SD_BOOT_TIMEOUT_MS 90000

static enum mgmt_cb_return ota_mgmt_callback(uint32_t event, enum mgmt_cb_return prev_status,
                                             int32_t *rc, uint16_t *group, bool *abort_more,
                                             void *data, size_t data_size)
{
    if (event == MGMT_EVT_OP_IMG_MGMT_DFU_STARTED) {
        LOG_INF("OTA Upload Started — Waking SPI3 bus");
        sd_set_ota_active(true);
    } else if (event == MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED) {
        LOG_INF("OTA Upload Stopped/Finished — Releasing SPI3 bus");
        sd_set_ota_active(false);
    }
    return MGMT_CB_OK;
}

static struct mgmt_callback ota_mgmt_cb = {
    .callback = ota_mgmt_callback,
    .event_id = (MGMT_EVT_OP_IMG_MGMT_DFU_STARTED | MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED),
};

atomic_t is_connected = ATOMIC_INIT(0);
bool is_charging = false;
bool is_off = false;

static bool blink_toggle = false;

static void mic_handler(int16_t *buffer)
{
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    if (!aad_process_audio(buffer, MIC_BUFFER_SAMPLES)) {
        return;
    }
#endif

    int err = codec_receive_pcm(buffer, MIC_BUFFER_SAMPLES);
    if (err) {
        LOG_ERR("Failed to process PCM data: %d", err);
    }
}

static void boot_led_sequence(void)
{
    led_start_breathing();
    LOG_INF("[BOOT] LEDs breathing white — waiting for SD + mic");
}

static void boot_warming_sequence(void)
{
    const int delay_ms = 10;
    int64_t wait_start_ms = k_uptime_get();

    /* Spin while LEDs are breathing until sd_worker finishes mount + lfs_fs_gc + file open.
     * With little data this completes in <5 s; with 200 MB it can take ~50 s.
     * Bounded: if the SD never initializes (card fault / unrecoverable corruption,
     * which returns the sd_worker thread before it sets sd_boot_ready), do NOT
     * spin forever feeding the watchdog — give up, flag fatal, and let the device
     * come up without storage so the red-LED fault indicator can run. */
    while (!sd_is_boot_ready()) {
        watchdog_feed();
        k_msleep(delay_ms);
        if ((k_uptime_get() - wait_start_ms) >= SD_BOOT_TIMEOUT_MS) {
            LOG_ERR("[BOOT] SD not ready after %d ms — starting WITHOUT storage (FATAL)",
                    SD_BOOT_TIMEOUT_MS);
            sd_fatal_error = true;
            return;
        }
    }
    LOG_INF("[BOOT] SD ready after %lld ms — starting mic", k_uptime_get() - wait_start_ms);
}

static void boot_ready_fade(void)
{
    const int steps = 100; // 100 steps * 10 ms = 1000 ms fade
    const int delay_ms = 10;

    /* SD + mic are ready — solid white for 1s, then fade down to off. */
    uint8_t start = app_settings_get_dim_ratio();
    LOG_INF("[BOOT] Solid white for 1s, then fading to off (from dim_ratio=%u)", start);

    set_led_pwm(LED_RED, start);
    set_led_pwm(LED_GREEN, start);
    set_led_pwm(LED_BLUE, start);
    k_msleep(1000);

    for (int i = steps; i >= 0; i--) {
        float t = (float) i / steps;
        uint8_t level = (uint8_t) (t * start);
        set_led_pwm(LED_RED, level);
        set_led_pwm(LED_GREEN, level);
        set_led_pwm(LED_BLUE, level);
        k_msleep(delay_ms);
    }
    led_off();
    LOG_INF("[BOOT] Ready — total boot time %lld ms", k_uptime_get());
}

void set_led_state()
{
    if (is_off) {
        led_off();
        return;
    }

    // Fatal SD fault: blink red. Overrides stealth/mute/marker/charging and is
    // unaffected by any button press, so a fault (blinking red) is distinguishable
    // from mute (solid red). Toggles each ~500ms loop pass (see k_msleep below).
    if (sd_fatal_error) {
        set_led_red(blink_toggle);
        set_led_green(false);
        set_led_blue(false);
        blink_toggle = !blink_toggle;
        return;
    }

    // Priority 1: Marker Flash (Transient, overrides stealth)
    if (marker_flash_count > 0) {
        set_led_red(marker_flash_color == MARKER_FLASH_WHITE || marker_flash_color == MARKER_FLASH_RED);
        set_led_green(marker_flash_color == MARKER_FLASH_WHITE || marker_flash_color == MARKER_FLASH_GREEN);
        set_led_blue(marker_flash_color == MARKER_FLASH_WHITE);
        return;
    }

    // Stealth gate: LEDs off unless the user has enabled them. is_led_enabled is
    // the single source of truth — mute force-enables it (see mute_apply()) so a
    // mute tap gives feedback even from the default-off state, yet the user can
    // still toggle the LED back off mid-mute (BUTTON_ACTION_TOGGLE_LED writes
    // is_led_enabled directly). Charging bypasses this gate at display time so
    // the charge indicator shows in stealth without mutating is_led_enabled —
    // otherwise charging's save/restore would race mute's and could drop the red
    // mute indicator on charge-stop while still muted.
    if (!is_led_enabled && !is_charging) {
        led_off();
        return;
    }

    // Base Color Determination (Priority: Mute > Low Bat > Connect > Active)
    bool r = false, g = false, b = false;

    #ifdef CONFIG_OMI_ENABLE_T5838_AAD
    uint16_t thr = aad_get_threshold();
    bool in_manual = (thr == 32769 || thr == 65535);
    #else
    bool in_manual = false;
    uint16_t thr = 0;
    #endif

    if (is_muted) {
        r = true; // Solid Red
    } else if (battery_ready && battery_percentage < 10) {
        r = true; b = true; // Purple
    } else if (atomic_get(&is_connected) && app_settings_get_connected_led()) {
        b = true; // Solid Blue — connected wins over mode state (unless the user turned it off)
    } else if (in_manual) {
        if (thr == 65535) {
            r = true; g = true; // Yellow — manual recording active (disconnected)
        }
        // manual standby disconnected: all off
    } else if (aad_is_recording()) {
        r = true; g = true; // Yellow — auto recording active (disconnected)
    }
    // idle disconnected: all off

    // Final state based on charging
    if (is_charging) {
        if (battery_percentage >= BATTERY_FULL_THRESHOLD_PERCENT) {
            // Full: Solid Green
            set_led_red(false);
            set_led_green(true);
            set_led_blue(false);
        } else {
            // Charging: Blink between Green and Base Color
            if (blink_toggle) {
                set_led_red(false);
                set_led_green(true);
                set_led_blue(false);
            } else {
                set_led_red(r);
                set_led_green(g);
                set_led_blue(b);
            }
            blink_toggle = !blink_toggle;
        }
    } else {
        // Normal Use: Solid Base Color
        set_led_red(r);
        set_led_green(g);
        set_led_blue(b);
    }
}

#ifdef CONFIG_HWINFO
static void log_reset_cause(uint32_t cause)
{
    if (cause == 0) {
        LOG_INF("[BOOT] Reset cause: unknown/none (0x00000000)");
        return;
    }
    if (cause & RESET_WATCHDOG) {
        LOG_WRN("[BOOT] Reset cause: WATCHDOG TIMEOUT (0x%08x) — firmware hung for >30 s", cause);
    }
    if (cause & RESET_CPU_LOCKUP) {
        LOG_WRN("[BOOT] Reset cause: CPU LOCKUP / HARDFAULT (0x%08x)", cause);
    }
    if (cause & RESET_SOFTWARE) {
        LOG_INF("[BOOT] Reset cause: software reset (0x%08x)", cause);
    }
    if (cause & RESET_PIN) {
        LOG_INF("[BOOT] Reset cause: pin/button reset (0x%08x)", cause);
    }
    if (cause & RESET_POR) {
        LOG_INF("[BOOT] Reset cause: power-on reset (0x%08x)", cause);
    }
    if (cause & RESET_BROWNOUT) {
        LOG_WRN("[BOOT] Reset cause: brownout / low voltage (0x%08x)", cause);
    }
}
#endif

static int suspend_unused_modules(void)
{
    flash_off();
    return 0;
}

int main(void)
{
    int ret;
    printk("Starting omi ...\n");

    /* Initialize unique session ID for this boot session. Race-safe vs.
     * the button-tap marker path which may also lazy-init on boot (B18). */
    if (atomic_get(&device_session_id) == 0) {
        uint32_t sid;
        do {
            sid = sys_rand32_get();
        } while (sid == 0);
        /* atomic_cas returns false if another path beat us; their ID wins. */
        (void)atomic_cas(&device_session_id, 0, (atomic_val_t)sid);
    }

    ret = led_start();
    if (ret) printk("LED failed %d\n", ret);
    boot_led_sequence();

    haptic_init();
    play_haptic_milli(100);

    app_settings_init();

    /* Seed the LED master gate from its persisted default. is_led_enabled is
     * volatile RAM (a button gesture toggles it for the session only), so
     * without this it is off after every reboot. Safe to write here: the button
     * thread — the only other writer — is not started until button_init() far
     * below. */
    is_led_enabled = app_settings_get_led_boot_enabled();

    /* Zero the diagnostic event ring before any thread could enqueue (no-op when
     * CONFIG_OMI_DIAG_LOG is off). Starts disabled — the app enables it at runtime. */
    diag_log_init();

#ifdef CONFIG_HWINFO
    {
        uint32_t this_cause = 0;
        hwinfo_get_reset_cause(&this_cause);
        hwinfo_clear_reset_cause();

        /* this_cause = why THIS boot started = how the PREVIOUS session ended.
         * prev_cause = NVS value = why the PREVIOUS boot started = how boot-before-that ended.
         * Log both for full history, but only warn on this_cause for the current-session crash. */
        uint32_t prev_cause = app_settings_get_last_reset_cause();
        uint64_t prev_uptime = app_settings_get_last_reset_uptime_ms();

        if (this_cause & (RESET_WATCHDOG | RESET_CPU_LOCKUP)) {
            LOG_WRN("[BOOT] *** PREVIOUS SESSION CRASHED (cause: 0x%08x, ran ~%llu ms) ***",
                    this_cause, prev_uptime);
            log_reset_cause(this_cause);
        } else {
            LOG_INF("[BOOT] This boot cause: 0x%08x (prev session ran ~%llu ms)", this_cause, prev_uptime);
            log_reset_cause(this_cause);
        }

        if (prev_cause != 0) {
            LOG_INF("[BOOT] Boot-before-last cause: 0x%08x", prev_cause);
        }

        /* Snapshot previous session's final uptime before overwriting the main record.
         * This is the value the BLE diagnostics char returns so the app can show
         * "crashed after Xh Ym" rather than current-session uptime (which starts at 0). */
        app_settings_save_crash_session_uptime(prev_uptime);

        /* Overwrite NVS with this boot's cause; uptime starts at 0 and is updated in the main loop */
        app_settings_save_last_reset(this_cause, 0);

#ifdef CONFIG_OMI_AUDIO_RING
        /* Anti-brick self-heal: if the ring backend is active and the device has
         * been crash-looping (watchdog/lockup) across boots, revert to the
         * known-good LittleFS backend so a ring bug can't wedge it into needing a
         * reflash. BLE/DFU comes up before the bounded SD wait, so the device
         * stays DFU-reachable regardless — this just also gets it recording again.
         * The counter is cleared once a boot proves healthy (see main loop). */
        if (app_settings_get_storage_backend() == STORAGE_BACKEND_RING &&
            (this_cause & (RESET_WATCHDOG | RESET_CPU_LOCKUP))) {
            uint8_t fails = app_settings_get_ring_boot_fails() + 1;
            if (fails >= RING_BOOT_FAIL_LIMIT) {
                LOG_ERR("[BOOT] ring backend crash-looped (%u boots) — reverting to LittleFS", fails);
                app_settings_save_storage_backend(STORAGE_BACKEND_LITTLEFS);
                app_settings_save_ring_boot_fails(0);
            } else {
                LOG_WRN("[BOOT] post-crash boot %u/%u with ring backend active", fails, RING_BOOT_FAIL_LIMIT);
                app_settings_save_ring_boot_fails(fails);
            }
        }
#endif
    }
#endif

    app_sd_init();
    init_rtc();

#ifdef CONFIG_LSM6DSL
    /* Recover UTC time using IMU timestamp delta if we just rebooted. */
    lsm6dsl_time_boot_adjust_rtc();
#endif

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    storage_init();
#endif

    // Initialize battery
#ifdef CONFIG_OMI_ENABLE_BATTERY
    ret = battery_init();
    if (ret) {
        LOG_ERR("Battery init failed (err %d)", ret);
        return ret;
    }
    LOG_INF("Battery initialized");
#endif

    suspend_unused_modules();

    ret = watchdog_init();
    if (ret) LOG_ERR("WD failed %d", ret);

    ret = button_init();
    if (ret) LOG_ERR("BTN failed %d", ret);
    // Button work is now interrupt-driven; no startup polling needed.

    ret = transport_start();
    if (ret) LOG_ERR("BLE failed %d", ret);

    mgmt_callback_register(&ota_mgmt_cb);

    boot_warming_sequence();

    set_mic_callback(mic_handler);

    /* First boot of a new image: power-cycle the mic rail before starting capture.
     *
     * A firmware update is a WARM reset. PDM_EN is held high by a board pull-up and
     * the firmware only ever drives it in mic_reset()/mic_off(), so the T5838 keeps
     * its supply — and therefore its internal state — straight through MCUboot and
     * into the new image. The PDM clock, meanwhile, stops dead mid-stream at the
     * reset and restarts when the new image configures the peripheral. A part that
     * comes out of that inconsistent is invisible: it emits digital zero, the
     * hardware AAD never asserts WAKE, nothing auto-records, and no reboot can clear
     * it because no reboot removes the supply. Exactly one such outage is on record
     * (2026-08-02, ~2 h of lost audio ending only when a Priority Recording happened
     * to call mic_reset()).
     *
     * Cycling here costs ~40 ms once per update and starts every new image from a
     * known-good part. This is NOT a periodic wedge watchdog — it fixes the one
     * transition we can point at. DIAG_VAD_LEVEL is what will tell us whether the
     * mic also wedges spontaneously mid-session; if it does, that gets diagnosed on
     * its own evidence rather than papered over here.
     *
     * Runs before mic_start(), so mic_running is false and mic_reset() does only the
     * rail cycle — no dmic trigger against an unconfigured device. */
    if (app_settings_firmware_version_changed(CONFIG_BT_DIS_FW_REV_STR)) {
        LOG_INF("First boot of %s — power-cycling the mic rail", CONFIG_BT_DIS_FW_REV_STR);
        mic_reset();
        diag_log_event_forced(DIAG_MIC_POWER_CYCLE, 0, mic_pdm_rail_is_ready() ? 1 : 0, 0);
    }

    ret = mic_start();
    if (ret) {
        LOG_ERR("Mic failed %d", ret);
        return ret;
    }

#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    ret = aad_start();
    if (ret) {
        LOG_ERR("AAD start failed (%d)", ret);
    }
#endif

    led_stop_breathing();

    /* On fatal SD fault, skip the green-ish ready fade and let the main loop
     * drive the solid-red fault indicator instead. */
    if (!sd_fatal_error) {
        boot_ready_fade();
    }

    LOG_INF("Ready\n");

    /* Save uptime every 10 minutes so the next boot can report session length on crash.
     * Re-reads the cause we saved at boot (hwinfo was already cleared by then). */
#ifdef CONFIG_HWINFO
    static uint32_t uptime_save_ticks = 0;
    static const uint32_t UPTIME_SAVE_INTERVAL_MS = 10 * 60 * 1000;
    uint32_t this_boot_cause = app_settings_get_last_reset_cause();
#endif

    while (1) {
        watchdog_feed();

#ifdef CONFIG_OMI_AUDIO_RING
        /* Once this boot has run long enough to be definitely healthy (past any
         * boot-time fault window), clear the ring crash-loop counter so only
         * CONSECUTIVE bad boots accumulate toward the auto-revert. */
        static bool ring_fails_cleared = false;
        if (!ring_fails_cleared && k_uptime_get() > 120000) {
            /* Clear regardless of the CURRENT backend: a healthy LittleFS boot must
             * also reset the count, otherwise stale failures from an earlier Ring
             * trial would make the next Ring trial auto-revert on its first crash
             * instead of after RING_BOOT_FAIL_LIMIT consecutive ones. */
            if (app_settings_get_ring_boot_fails() != 0) {
                app_settings_save_ring_boot_fails(0);
            }
            ring_fails_cleared = true;
        }
#endif

#ifdef CONFIG_OMI_ENABLE_MONITOR
        monitor_log_metrics();
#endif

        set_led_state();

        // Transient effect handling
        if (marker_flash_count > 0) {
            marker_flash_count--;
        }

#ifdef CONFIG_HWINFO
        {
            uint32_t now_ms = (uint32_t)k_uptime_get();
            if ((now_ms - uptime_save_ticks) >= UPTIME_SAVE_INTERVAL_MS) {
                uptime_save_ticks = now_ms;
                app_settings_save_last_reset(this_boot_cause, (uint64_t)now_ms);
            }
        }
#endif

        k_msleep(500); // More responsive loop for blinking
    }

    return 0;
}
