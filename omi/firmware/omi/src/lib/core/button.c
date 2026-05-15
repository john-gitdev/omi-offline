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

LOG_MODULE_REGISTER(button, CONFIG_LOG_DEFAULT_LEVEL);

extern bool is_off;
volatile bool is_muted = false;
volatile bool is_led_enabled = true;
volatile uint8_t marker_flash_count = 0;

static const struct device *const buttons = DEVICE_DT_GET(DT_ALIAS(buttons));
static const struct gpio_dt_spec usr_btn = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(usr_btn), gpios, {0});

static bool was_pressed = false;

// Polling interval for state machine
#define BUTTON_CHECK_INTERVAL 40 // 0.04 seconds, 25 Hz

void check_button_level(struct k_work *work_item);

K_WORK_DELAYABLE_DEFINE(button_work, check_button_level);

static FSM_STATE_T current_button_state = IDLE;

// State machine definitions
typedef enum {
    STATE_IDLE,
    STATE_FIRST_PRESS,
    STATE_FIRST_RELEASE,
    STATE_SECOND_PRESS,
    STATE_SECOND_RELEASE,  // waiting to see if a third tap follows
    STATE_THIRD_PRESS,     // third tap in progress
    STATE_WAIT_FOR_RELEASE
} button_fsm_state_t;

static button_fsm_state_t fsm_state = STATE_IDLE;
static uint32_t state_timer = 0;

#define HOLD_TIME 1000             // 1s hold threshold (single/double tap)
#define TRIPLE_HOLD_TIME 3000      // 3s hold for triple-tap power off
#define DOUBLE_TAP_WINDOW 600      // 600ms window for second tap
#define TRIPLE_TAP_WINDOW 600      // 600ms window for third tap


void check_button_level(struct k_work *work_item)
{
    bool pressed = was_pressed;
    state_timer++;

    switch (fsm_state) {
    case STATE_IDLE:
        if (pressed) {
            fsm_state = STATE_FIRST_PRESS;
            state_timer = 0;
        }
        break;

    case STATE_FIRST_PRESS:
        if (!pressed) {
            // Short press — wait for second tap window.
            fsm_state = STATE_FIRST_RELEASE;
            state_timer = 0;
        } else {
            // Still pressed. Absorb the hold with no action.
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= HOLD_TIME) {
                fsm_state = STATE_WAIT_FOR_RELEASE;
            }
        }
        break;

    case STATE_FIRST_RELEASE:
        if (pressed) {
            fsm_state = STATE_SECOND_PRESS;
            state_timer = 0;
        } else {
            uint32_t idle_duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (idle_duration_ms > DOUBLE_TAP_WINDOW) {
                // Single tap — no action.
                LOG_INF("Single tap");
                fsm_state = STATE_IDLE;
            }
        }
        break;

    case STATE_SECOND_PRESS:
        if (!pressed) {
            // Released — wait to see if a third press arrives.
            fsm_state = STATE_SECOND_RELEASE;
            state_timer = 0;
        } else {
            // Still pressed. Check if held long enough for mute toggle.
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= HOLD_TIME) {
                #ifdef CONFIG_OMI_ENABLE_T5838_AAD
                uint16_t thr2 = aad_get_threshold();
                bool in_manual2 = (thr2 == 32769 || thr2 == 65535);
                #else
                bool in_manual2 = false;
                #endif
                if (!in_manual2) {
                    is_muted = !is_muted;
                    LOG_INF("Mute toggled: %s", is_muted ? "ON" : "OFF");
                    if (is_muted) {
                        mic_pause();
                    } else {
                        mic_resume();
                    }
                }
                fsm_state = STATE_WAIT_FOR_RELEASE;
            }
        }
        break;

    case STATE_SECOND_RELEASE:
        if (pressed) {
            // Third tap started — could be triple-tap or triple-tap-hold.
            fsm_state = STATE_THIRD_PRESS;
            state_timer = 0;
        } else {
            uint32_t idle_duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (idle_duration_ms > TRIPLE_TAP_WINDOW) {
                // Timeout — it was a double tap.
                if (!is_muted) {
                    #ifdef CONFIG_OMI_ENABLE_T5838_AAD
                    uint16_t thr = aad_get_threshold();
                    bool in_manual = (thr == 32769 || thr == 65535);
                    #else
                    bool in_manual = false;
                    uint16_t thr = 0;
                    #endif
                    if (in_manual) {
                        marker_flash_count = 2;
                        if (thr == 32769) {
                            LOG_INF("Double tap — manual mode, start recording");
                            #ifdef CONFIG_OMI_ENABLE_T5838_AAD
                            aad_set_threshold(65535);
                            #endif
                        } else {
                            LOG_INF("Double tap — manual mode, stop recording");
                            #ifdef CONFIG_OMI_ENABLE_T5838_AAD
                            aad_set_threshold(32769);
                            #endif
                        }
                    } else {
                        LOG_INF("Double tap (Marker) detected");
                        marker_flash_count = 2;
                        #ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
                        write_marker_to_storage();
                        #endif
                        #ifdef CONFIG_OMI_ENABLE_T5838_AAD
                        aad_force_wake();
                        #endif
                    }
                } else {
                    LOG_INF("Double tap ignored (muted)");
                }
                fsm_state = STATE_IDLE;
            }
        }
        break;

    case STATE_THIRD_PRESS:
        if (!pressed) {
            // Released — triple tap -> toggle LED.
            is_led_enabled = !is_led_enabled;
            LOG_INF("Triple tap: LED toggled %s", is_led_enabled ? "ON" : "OFF");
            fsm_state = STATE_IDLE;
        } else {
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= TRIPLE_HOLD_TIME) {
                // Triple tap + hold -> power off.
                LOG_INF("Power off triggered via triple-tap-hold");
                play_haptic_milli(1000);
                turnoff_all();
                fsm_state = STATE_IDLE;
            }
        }
        break;

    case STATE_WAIT_FOR_RELEASE:
        if (!pressed) {
            fsm_state = STATE_IDLE;
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

FSM_STATE_T get_current_button_state()
{
    return current_button_state;
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

void force_button_state(FSM_STATE_T state)
{
    current_button_state = state;
}
