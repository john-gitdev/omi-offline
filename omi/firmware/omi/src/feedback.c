#include "lib/core/feedback.h"

#include <zephyr/logging/log.h>
#include "lib/core/led.h"

LOG_MODULE_REGISTER(feedback, CONFIG_LOG_DEFAULT_LEVEL);

/**
 * Error reporting for production builds.
 *
 * LED blink patterns were removed for production (callers are currently
 * unwired). Errors are reported via UART/RTT only. If you need to re-enable
 * visual feedback, see git history for the original show_error() LED patterns.
 */
static void log_error_event(const char *component)
{
    LOG_ERR("Hardware Error Detected: %s", component);
}

void error_settings(void)
{
    log_error_event("Settings");
}

void error_led_driver(void)
{
    log_error_event("LED Driver");
}

void error_battery_init(void)
{
    log_error_event("Battery Init");
}

void error_battery_charge(void)
{
    log_error_event("Battery Charge");
}

void error_button(void)
{
    log_error_event("Button");
}

void error_haptic(void)
{
    log_error_event("Haptic");
}

void error_sd_card(void)
{
    log_error_event("SD Card");
}

void error_storage(void)
{
    log_error_event("Storage");
}

void error_transport(void)
{
    log_error_event("BLE Transport");
}

void error_codec(void)
{
    log_error_event("Codec");
}

void error_microphone(void)
{
    log_error_event("Microphone");
}
