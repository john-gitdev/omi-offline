#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/drivers/watchdog.h>

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
#include "rtc.h"
#include "imu.h"

#include "spi_flash.h"
#include "wdog_facade.h"

LOG_MODULE_REGISTER(main, CONFIG_LOG_DEFAULT_LEVEL);

#ifdef CONFIG_OMI_ENABLE_BATTERY
#define BATTERY_FULL_THRESHOLD_PERCENT 98 // 98%
extern uint8_t battery_percentage;
#endif

bool is_connected = false;
bool is_charging = false;
bool is_off = false;

static bool blink_toggle = false;

static void boot_led_sequence(void)
{
}

static void boot_warming_sequence(void)
{
    const int steps = 30;
    const int delay_ms = 10;

    // Wait with LEDs off while SD pre-warm (lfs_fs_gc) is running
    while (!sd_is_boot_ready()) {
        k_msleep(delay_ms);
    }

    // Fade up to dim_ratio brightness so main loop set_led_state() takes over
    // at the same level — no brightness jump
    uint8_t target = app_settings_get_dim_ratio();
    for (int i = 0; i <= steps; i++) {
        float t = (float) i / steps;
        uint8_t level = (uint8_t) (t * target);
        set_led_pwm(LED_RED, level);
        set_led_pwm(LED_GREEN, level);
        k_msleep(delay_ms);
    }
}

void set_led_state()
{
    if (is_off) {
        led_off();
        return;
    }

    // Force LEDs ON if charging starts
    if (is_charging && !is_led_enabled) {
        is_led_enabled = true;
    }

    // Priority 1: Marker Flash (Transient, overrides stealth)
    if (marker_flash_count > 0) {
        set_led_red(true);
        set_led_green(true);
        set_led_blue(true);
        return;
    }

    // Stealth Mode: All LEDs off
    if (!is_led_enabled) {
        led_off();
        return;
    }

    // Base Color Determination (Priority: Mute > Low Bat > Connect > Active)
    bool r = false, g = false, b = false;

    if (is_muted) {
        r = true; // Solid Red
    } else if (battery_percentage < 10) {
        r = true; b = true; // Purple
    } else if (is_connected) {
        b = true; // Solid Blue
    } else {
        r = true; g = true; // Solid Yellow
    }

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

static int suspend_unused_modules(void)
{
    flash_off();
    return 0;
}

int main(void)
{
    int ret;
    printk("Starting omi ...\n");

    ret = led_start();
    if (ret) printk("LED failed %d\n", ret);
    boot_led_sequence();

    app_settings_init();

    init_rtc();
    lsm6dsl_time_boot_adjust_rtc();

    haptic_init();
    play_haptic_milli(200);

    flash_init();

    app_sd_init();

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
    activate_button_work();

    ret = transport_start();
    if (ret) LOG_ERR("BLE failed %d", ret);

    boot_warming_sequence();

    ret = mic_start();
    if (ret) {
        LOG_ERR("Mic failed %d", ret);
        return ret;
    }

    LOG_INF("Ready\n");

    while (1) {
        watchdog_feed();
#ifdef CONFIG_OMI_ENABLE_MONITOR
        monitor_log_metrics();
#endif

        set_led_state();
        
        // Transient effect handling
        if (marker_flash_count > 0) {
            marker_flash_count--;
        }

        k_msleep(500); // More responsive loop for blinking
    }

    return 0;
}
