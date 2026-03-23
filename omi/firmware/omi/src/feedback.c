#include "lib/core/feedback.h"

#include "feedback.h"

#include <zephyr/logging/log.h>
#include "lib/core/led.h"

LOG_MODULE_REGISTER(feedback, CONFIG_LOG_DEFAULT_LEVEL);

/**
 * @brief Log error and optionally set a universal generic error LED state.
 *
 * @param component The name of the failing component.
 */
static void log_error_event(const char *component)
{
    LOG_ERR("Hardware Error Detected: %s", component);

    // Optional UX: If you want a universal "Something is wrong" red flash, 
    // we can do a brief pulse. For now, we will just log it.
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
