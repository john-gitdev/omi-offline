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
#include "lib/core/utils.h"
#include "lib/core/sd_card.h"
#include "lib/core/settings.h"
#include "rtc.h"
#include "imu.h"

#include "spi_flash.h"
#include "wdog_facade.h"
#include "wifi.h"

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
    // Simplified boot blink
    set_led_blue(true);
    k_msleep(500);
    led_off();
}

static void boot_ready_sequence(void)
{
    const int steps = 50;
    const int delay_ms = 10;

    // Smooth green fade in/out 2 times = "Ready!"
    for (int cycle = 0; cycle < 2; cycle++) {
        for (int i = 0; i <= steps; i++) {
            float t = (float) i / steps;
            float eased = t < 0.5f ? 2.0f * t * t : 1.0f - 2.0f * (1.0f - t) * (1.0f - t);
            uint8_t level = (uint8_t) (eased * 50.0f);
            set_led_pwm(LED_GREEN, level);
            k_msleep(delay_ms);
        }
        for (int i = 0; i <= steps; i++) {
            float t = (float) i / steps;
            float eased = t < 0.5f ? 2.0f * t * t : 1.0f - 2.0f * (1.0f - t) * (1.0f - t);
            uint8_t level = (uint8_t) ((1.0f - eased) * 70.0f);
            set_led_pwm(LED_GREEN, level);
            k_msleep(delay_ms);
        }
    }
    led_off();
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

    // Priority 1: Star Flash (Transient, overrides stealth)
    if (star_flash_count > 0) {
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

    init_rtc();

    suspend_unused_modules();

    ret = watchdog_init();
    if (ret) LOG_ERR("WD failed %d", ret);

    ret = button_init();
    if (ret) LOG_ERR("BTN failed %d", ret);
    activate_button_work();

    ret = transport_start();
    if (ret) LOG_ERR("BLE failed %d", ret);

    ret = mic_start();
    if (ret) {
        LOG_ERR("Mic failed %d", ret);
        return ret;
    }

#ifdef CONFIG_OMI_ENABLE_WIFI
    wifi_init();
#endif

    boot_ready_sequence();
    LOG_INF("Ready\n");

    while (1) {
        watchdog_feed();
#ifdef CONFIG_OMI_ENABLE_MONITOR
        monitor_log_metrics();
#endif

        set_led_state();
        
        // Transient effect handling
        if (star_flash_count > 0) {
            star_flash_count--;
        }

        k_msleep(500); // More responsive loop for blinking
    }

    return 0;
}
