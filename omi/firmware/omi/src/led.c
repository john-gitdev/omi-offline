#include "lib/core/led.h"

#include <zephyr/drivers/pwm.h>
#include <zephyr/logging/log.h>

#include "lib/core/settings.h"
#include "lib/core/utils.h"

LOG_MODULE_REGISTER(led, CONFIG_LOG_DEFAULT_LEVEL);

// Define LED PWM specs from device tree
static const struct pwm_dt_spec led_red = PWM_DT_SPEC_GET(DT_NODELABEL(led_red));
static const struct pwm_dt_spec led_green = PWM_DT_SPEC_GET(DT_NODELABEL(led_green));
static const struct pwm_dt_spec led_blue = PWM_DT_SPEC_GET(DT_NODELABEL(led_blue));

int led_start()
{
    ASSERT_TRUE(pwm_is_ready_dt(&led_red));
    ASSERT_TRUE(pwm_is_ready_dt(&led_green));
    ASSERT_TRUE(pwm_is_ready_dt(&led_blue));
    /* We don't zero all channels immediately anymore to allow a seamless 
     * transition from the hardware's initial PWM state into breathing. */
    LOG_INF("LEDs (PWM) started — transition to breathing pending");
    return 0;
}

static void set_led_on_off(const struct pwm_dt_spec *led, bool on)
{
    if (!pwm_is_ready_dt(led)) {
        LOG_ERR("LED PWM device not ready");
        return;
    }

    uint32_t pulse_width_ns = 0;
    if (on) {
        uint8_t ratio = app_settings_get_dim_ratio();
        if (ratio > 100) {
            ratio = 100;
        }
        pulse_width_ns = (led->period * ratio) / 100;
    }

    pwm_set_pulse_dt(led, pulse_width_ns);
}

void set_led_red(bool on)
{
    set_led_on_off(&led_red, on);
}

void set_led_green(bool on)
{
    set_led_on_off(&led_green, on);
}

void set_led_blue(bool on)
{
    set_led_on_off(&led_blue, on);
}

void set_led_pwm(led_color_t color, uint8_t level)
{
    const struct pwm_dt_spec *led;

    switch (color) {
    case LED_RED:
        led = &led_red;
        break;
    case LED_GREEN:
        led = &led_green;
        break;
    case LED_BLUE:
        led = &led_blue;
        break;
    default:
        LOG_ERR("Invalid LED color");
        return;
    }

    if (!pwm_is_ready_dt(led)) {
        LOG_ERR("LED PWM device not ready");
        return;
    }

    if (level > 100) {
        level = 100;
    }

    uint32_t pulse_width_ns = (led->period * level) / 100;
    pwm_set_pulse_dt(led, pulse_width_ns);
}

void led_off(void)
{
    pwm_set_pulse_dt(&led_red,   0);
    pwm_set_pulse_dt(&led_green, 0);
    pwm_set_pulse_dt(&led_blue,  0);
}

static struct k_thread breathing_thread_data;
static k_tid_t breathing_thread_id;
static K_THREAD_STACK_DEFINE(breathing_thread_stack, 512);
static volatile bool is_breathing = false;

static void breathing_thread(void *p1, void *p2, void *p3)
{
    int level = 100;
    int step = -2;
    bool first_cycle = true;
    while (is_breathing) {
        uint8_t ratio = first_cycle ? 100 : app_settings_get_dim_ratio();
        uint8_t current_level = (level * ratio) / 100;

        set_led_pwm(LED_RED, current_level);
        set_led_pwm(LED_GREEN, current_level);
        set_led_pwm(LED_BLUE, current_level);

        level += step;
        if (level <= 0) {
            level = 0;
            step = -step;
            first_cycle = false;
        } else if (level >= 100) {
            level = 100;
            step = -step;
        }
        k_msleep(30);
    }
    led_off();
}

void led_start_breathing(void)
{
    if (is_breathing) return;
    is_breathing = true;
    breathing_thread_id = k_thread_create(&breathing_thread_data, breathing_thread_stack,
                                          K_THREAD_STACK_SIZEOF(breathing_thread_stack),
                                          breathing_thread, NULL, NULL, NULL,
                                          K_LOWEST_APPLICATION_THREAD_PRIO, 0, K_NO_WAIT);
}

void led_stop_breathing(void)
{
    if (!is_breathing) return;
    is_breathing = false;
    if (breathing_thread_id) {
        k_thread_join(breathing_thread_id, K_FOREVER);
        breathing_thread_id = NULL;
    }
}
