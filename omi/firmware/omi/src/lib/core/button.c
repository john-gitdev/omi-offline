#include "button.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/sys/poweroff.h>

#include "haptic.h"
#include "led.h"
#include "mic.h"
#include "rtc.h"
#include "speaker.h"
#include "transport.h"
#include "wdog_facade.h"
#include "imu.h"
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
#include "sd_card.h"
#endif
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
#include "aad.h"
#endif

#include "settings.h"

LOG_MODULE_REGISTER(button, CONFIG_LOG_DEFAULT_LEVEL);

extern bool is_off;
volatile bool is_muted = false;
volatile bool is_led_enabled = false;
volatile uint8_t marker_flash_count = 0;
volatile marker_flash_color_t marker_flash_color = MARKER_FLASH_WHITE;

/* When mute was last engaged, exposed over the BLE mute characteristic so the
 * app can render "Muted since …". utc_s is best-effort (0 pre-time-sync);
 * uptime_ms is monotonic so the app can derive wall time after it time-syncs. */
static volatile uint32_t mute_since_utc_s = 0;
static volatile uint32_t mute_since_uptime_ms = 0;

/* is_led_enabled as it was just before mute engaged. Muting force-enables the
 * LED so the solid-red mute indicator is visible even from stealth; unmute
 * restores this prior preference. The user can still toggle the LED off while
 * muted (BUTTON_ACTION_TOGGLE_LED writes is_led_enabled), which unmute then
 * overrides back to the pre-mute state. */
static volatile bool led_state_before_mute = false;

bool mute_apply(bool on)
{
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    uint16_t thr = aad_get_threshold();
    bool in_manual = (thr == 32769 || thr == 65535);
#else
    bool in_manual = false;
#endif
    if (in_manual) {
        LOG_INF("Mute change ignored (manual mode)");
        return false;
    }
    if (on == is_muted) {
        return false;
    }
    is_muted = on;
    if (on) {
        // Force the LED on so the solid-red mute indicator shows even from
        // stealth; remember the prior preference so unmute can restore it.
        led_state_before_mute = is_led_enabled;
        is_led_enabled = true;
        mute_since_utc_s = get_utc_time();
        mute_since_uptime_ms = (uint32_t)k_uptime_get();
        mic_pause();
    } else {
        is_led_enabled = led_state_before_mute;
        mic_resume();
    }
    LOG_INF("Mute toggled: %s", on ? "ON" : "OFF");
    // Push the live state first (fast, non-blocking) before the marker write,
    // which may briefly block on a saturated SD queue.
    mute_state_notify();
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    // Mute can be toggled while VAD has paused SD writes (e.g. during a silence
    // gap), which would drop the marker. Resume writes first, then write a
    // durable mute-on/off marker bracketing the muted stretch in the stream.
    sd_write_pause(false);
    if (on) {
        write_mute_on_marker_to_storage();
    } else {
        write_mute_off_marker_to_storage();
    }
#endif
    return true;
}

void mute_get_state(uint8_t *muted, uint32_t *since_utc_s, uint32_t *since_uptime_ms)
{
    if (is_muted) {
        *muted = 1;
        *since_utc_s = mute_since_utc_s;
        *since_uptime_ms = mute_since_uptime_ms;
    } else {
        *muted = 0;
        *since_utc_s = 0;
        *since_uptime_ms = 0;
    }
}

static const struct device *const buttons = DEVICE_DT_GET(DT_ALIAS(buttons));
static const struct gpio_dt_spec usr_btn = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(usr_btn), gpios, {0});

/* Written from the GPIO ISR, read from the button_work handler — must be
 * volatile so the handler always re-reads the latest edge state. */
static volatile bool was_pressed = false;

// Polling interval for state machine
#define BUTTON_CHECK_INTERVAL 40 // 0.04 seconds, 25 Hz

void check_button_level(struct k_work *work_item);

K_WORK_DELAYABLE_DEFINE(button_work, check_button_level);

// State machine definitions
typedef enum {
    STATE_IDLE,
    STATE_PRESS,
    STATE_RELEASE,
    STATE_WAIT_FOR_RELEASE
} button_fsm_state_t;

static volatile button_fsm_state_t fsm_state = STATE_IDLE;
static uint32_t state_timer = 0;
static uint8_t tap_count = 0;

#define HOLD_TIME 1000             // 1s hold threshold for customizable actions
#define POWER_OFF_HOLD_TIME 3000   // 3s hold for 4-tap power off
#define UNPAIR_HOLD_TIME 10000     // 10s hold for 5-tap unpair
#define MULTI_TAP_WINDOW 600       // 600ms window for multi-taps


static void execute_button_action(uint8_t taps, bool is_hold)
{
    if (taps < 1 || taps > 3) return;

    uint8_t config[6];
    app_settings_get_button_config(config);

    uint8_t index = (taps - 1) * 2 + (is_hold ? 1 : 0);
    button_action_t action = (button_action_t)config[index];

    LOG_INF("Action triggered: taps=%d, hold=%d -> action=%d", taps, is_hold, action);

    switch (action) {
    case BUTTON_ACTION_MUTE:
        mute_apply(!is_muted);
        break;
    case BUTTON_ACTION_MARKER:
        if (!is_muted) {
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
            uint16_t thr = aad_get_threshold();
            bool in_manual = (thr == 32769 || thr == 65535);
#else
            bool in_manual = false;
            uint16_t thr = 0;
#endif
            if (in_manual) {
                if (thr == 32769) {
                    LOG_INF("Manual mode start recording");
                    marker_flash_color = MARKER_FLASH_GREEN;
                    marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
                    aad_set_threshold(65535);
#endif
                } else {
                    LOG_INF("Manual mode stop recording");
                    marker_flash_color = MARKER_FLASH_RED;
                    marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
                    aad_set_threshold(32769);
#endif
                }
            } else {
                LOG_INF("Marker detected");
                marker_flash_color = MARKER_FLASH_WHITE;
                marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
                // AAD may have paused SD writes during a silence gap. A marker
                // written while paused is enqueued, reported as written, then
                // silently dropped by the SD worker (sd_card.c process_write_data_req
                // returns early on sd_write_paused). aad_force_wake() below only
                // resumes writes ~debounce frames later — far too late. Resume
                // first so the marker is durable, mirroring the mute path above.
                sd_write_pause(false);
                write_marker_to_storage();
#endif
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
                aad_force_wake();
#endif
            }
        } else {
            LOG_INF("Marker ignored (muted)");
        }
        break;
    case BUTTON_ACTION_TOGGLE_LED:
        is_led_enabled = !is_led_enabled;
        LOG_INF("LED toggled %s", is_led_enabled ? "ON" : "OFF");
        break;
    case BUTTON_ACTION_NONE:
    default:
        break;
    }
}

void check_button_level(struct k_work *work_item)
{
    bool pressed = was_pressed;
    state_timer++;

    switch (fsm_state) {
    case STATE_IDLE:
        if (pressed) {
            fsm_state = STATE_PRESS;
            tap_count = 1;
            state_timer = 0;
        }
        break;

    case STATE_PRESS:
        if (!pressed) {
            fsm_state = STATE_RELEASE;
            state_timer = 0;
        } else {
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;

            if (tap_count == 4 && duration_ms >= POWER_OFF_HOLD_TIME) {
                LOG_INF("Power off triggered via 4-tap-hold");
                turnoff_all();
                fsm_state = STATE_WAIT_FOR_RELEASE;
            } else if (tap_count == 5 && duration_ms >= UNPAIR_HOLD_TIME) {
                LOG_WRN("5-tap + hold: clearing all BLE bonds!");
                bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY);

                led_off();
                for (int i = 0; i < 3; i++) {
                    set_led_red(true);
                    k_msleep(150);
                    led_off();
                    k_msleep(150);
                }
#ifdef CONFIG_OMI_ENABLE_HAPTIC
                play_haptic_milli(1000);
                k_msleep(1000);
                haptic_off();
#endif
                fsm_state = STATE_WAIT_FOR_RELEASE;
            } else if (tap_count <= 3 && duration_ms >= HOLD_TIME) {
                execute_button_action(tap_count, true);
                fsm_state = STATE_WAIT_FOR_RELEASE;
            }
            // No terminal branch for tap_count > 5: the count keeps climbing and stays
            // above every gesture threshold, so an over-tap is harmlessly ignored on
            // release. Do NOT route it to WAIT_FOR_RELEASE — that resets the count and
            // lets continued tapping wrap around into a fresh gesture (e.g. 10 taps + hold
            // would re-derive a 4-tap-hold power off).
        }
        break;

    case STATE_RELEASE:
        if (pressed) {
            tap_count++;
            fsm_state = STATE_PRESS;
            state_timer = 0;
        } else {
            uint32_t idle_duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (idle_duration_ms > MULTI_TAP_WINDOW) {
                if (tap_count <= 3) {
                    execute_button_action(tap_count, false);
                } else {
                    LOG_INF("%d tap(s) ignored (no single action)", tap_count);
                }
                fsm_state = STATE_IDLE;
                tap_count = 0;
            }
        }
        break;

    case STATE_WAIT_FOR_RELEASE:
        if (!pressed) {
            fsm_state = STATE_IDLE;
            tap_count = 0;
        }
        break;
    }

    // Keep polling only while an interaction is in progress.
    // Returning to STATE_IDLE lets the work item die; the GPIO interrupt
    // will restart it on the next button press.
    if (fsm_state != STATE_IDLE) {
        k_work_reschedule(&button_work, K_MSEC(BUTTON_CHECK_INTERVAL));
    }
    return;
}

static struct gpio_callback button_cb_data;

static void button_gpio_callback(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    was_pressed = (gpio_pin_get_dt(&usr_btn) == 1);

    // Start the state machine work item on the first press from idle.
    // The work item reschedules itself while active and stops when it returns
    // to STATE_IDLE, so no continuous polling occurs between interactions.
    if (was_pressed && fsm_state == STATE_IDLE) {
        k_work_reschedule(&button_work, K_NO_WAIT);
    }
}

int button_regist_callback()
{
    int ret;

    // Configure GPIO as input with pull-up
    ret = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (ret < 0) {
        LOG_ERR("Failed to configure button GPIO (%d)", ret);
        return ret;
    }

    // Setup interrupt on both edges
    ret = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_EDGE_BOTH);
    if (ret < 0) {
        LOG_ERR("Failed to configure button interrupt (%d)", ret);
        return ret;
    }

    // Register callback
    gpio_init_callback(&button_cb_data, button_gpio_callback, BIT(usr_btn.pin));
    gpio_add_callback(usr_btn.port, &button_cb_data);

    LOG_INF("Button initialized with GPIO interrupt");

    return 0;
}

int button_init()
{
    int ret;

    // Initialize the buttons device from evt
    if (!device_is_ready(buttons)) {
        LOG_ERR("Buttons device not ready");
        return -ENODEV;
    }

    // Enable runtime power management for the buttons device
    ret = pm_device_runtime_get(buttons);
    if (ret < 0) {
        LOG_ERR("Failed to enable buttons device (%d)", ret);
        return ret;
    }

    // Regist callback
    ret = button_regist_callback();
    if (ret < 0) {
        LOG_ERR("Failed to regist buttons callback (%d)", ret);
        return ret;
    }

    return 0;
}

void activate_button_work()
{
    k_work_schedule(&button_work, K_MSEC(BUTTON_CHECK_INTERVAL));
}

extern struct bt_gatt_service button_service;
void register_button_service()
{
    bt_gatt_service_register(&button_service);
}

void turnoff_all()
{
    int rc;

    // Immediate feedback: LED off and haptic
    led_off();
    // Set is_off immediately so set_led_state() keeps LEDs off
    is_off = true;

#ifdef CONFIG_OMI_ENABLE_HAPTIC
    play_haptic_milli(100);
    k_msleep(300);
    haptic_off();
#endif

    // Delays for stability
    k_msleep(1000);

    // // Enter the low power mode
    transport_off();
    k_msleep(300);

    // Always turn off microphone
    mic_off();
    k_msleep(100);

    // Turn off speaker if enabled
#ifdef CONFIG_OMI_ENABLE_SPEAKER
    speaker_off();
    k_msleep(100);
#endif

    // Turn off accelerometer if enabled
#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER
    accel_off();
    k_msleep(100);
#endif

    if (is_sd_on() && sd_is_boot_ready()) {
        app_sd_off();
    }
    k_msleep(300);

    // Put the buttons device to sleep if button is enabled
#ifdef CONFIG_OMI_ENABLE_BUTTON
    pm_device_runtime_put(buttons);
    k_msleep(100);
#endif

    // Disable USB if enabled
#ifdef CONFIG_OMI_ENABLE_USB
    NRF_USBD->INTENCLR = 0xFFFFFFFF;
#endif

    // Log system power off
    LOG_INF("System powering off");

    // Configure usr_btn as input with interrupt to allow wake-up
    rc = gpio_pin_configure_dt(&usr_btn, GPIO_INPUT);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO (%d)", rc);
        return;
    }

    rc = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_LEVEL_LOW);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO interrupt (%d)", rc);
        return;
    }
    rc = watchdog_deinit();
    if (rc < 0) {
        LOG_ERR("Failed to deinitialize watchdog (%d)", rc);
        return;
    }

    /* Persist an IMU timestamp base so we can estimate time across system_off. */
    lsm6dsl_time_prepare_for_system_off();
    k_msleep(1000);
    LOG_INF("Entering system off; press usr_btn to restart");

    // Power off the system using sys_poweroff
    sys_poweroff();
}
