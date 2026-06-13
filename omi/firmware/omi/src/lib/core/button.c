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
        mute_since_utc_s = get_utc_time();
        mute_since_uptime_ms = (uint32_t)k_uptime_get();
        mic_pause();
    } else {
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
    STATE_FIRST_PRESS,
    STATE_FIRST_RELEASE,
    STATE_SECOND_PRESS,
    STATE_SECOND_RELEASE,  // waiting to see if a third tap follows
    STATE_THIRD_PRESS,     // third tap in progress
    STATE_THIRD_RELEASE,   // waiting to see if a fourth tap follows
    STATE_FOURTH_PRESS,    // fourth tap in progress
    STATE_FOURTH_RELEASE,  // waiting to see if a fifth tap follows
    STATE_FIFTH_PRESS,     // fifth tap in progress (hold for unpair)
    STATE_WAIT_FOR_RELEASE
} button_fsm_state_t;

/* Read from the GPIO ISR (to decide whether to (re)start button_work) as well
 * as the handler, so mark volatile to avoid a stale cached read in the ISR. */
static volatile button_fsm_state_t fsm_state = STATE_IDLE;
static uint32_t state_timer = 0;

#define HOLD_TIME 1000             // 1s hold threshold (single/double tap)
#define TRIPLE_HOLD_TIME 3000      // 3s hold for triple-tap power off
#define UNPAIR_HOLD_TIME 10000     // 10s hold for 5-tap unpair
#define DOUBLE_TAP_WINDOW 600      // 600ms window for second tap
#define TRIPLE_TAP_WINDOW 600      // 600ms window for third tap
#define MULTI_TAP_WINDOW 600       // 600ms window for 4th/5th taps


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
                // mute_apply() honors the manual-mode gate, records the
                // mute-since timestamp, and notifies the BLE mute characteristic.
                mute_apply(!is_muted);
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
                        if (thr == 32769) {
                            LOG_INF("Double tap — manual mode, start recording");
                            marker_flash_color = MARKER_FLASH_GREEN;
                            marker_flash_count = 2;
                            #ifdef CONFIG_OMI_ENABLE_T5838_AAD
                            aad_set_threshold(65535);
                            #endif
                        } else {
                            LOG_INF("Double tap — manual mode, stop recording");
                            marker_flash_color = MARKER_FLASH_RED;
                            marker_flash_count = 2;
                            /* aad_set_threshold emits the session-end marker
                             * itself on the 65535→other transition, so both
                             * button-stop and BLE-driven mode switches finalize
                             * cleanly through one path. */
                            #ifdef CONFIG_OMI_ENABLE_T5838_AAD
                            aad_set_threshold(32769);
                            #endif
                        }
                    } else {
                        LOG_INF("Double tap (Marker) detected");
                        marker_flash_color = MARKER_FLASH_WHITE;
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
            // Released — wait to see if a fourth tap follows.
            fsm_state = STATE_THIRD_RELEASE;
            state_timer = 0;
        } else {
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= TRIPLE_HOLD_TIME) {
                // Triple tap + hold → power off.
                LOG_INF("Power off triggered via triple-tap-hold");
                turnoff_all();
                fsm_state = STATE_IDLE;
            }
        }
        break;

    case STATE_THIRD_RELEASE:
        if (pressed) {
            // Fourth tap started.
            fsm_state = STATE_FOURTH_PRESS;
            state_timer = 0;
        } else {
            uint32_t idle_duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (idle_duration_ms > MULTI_TAP_WINDOW) {
                // Timeout — it was a triple tap → toggle LED.
                is_led_enabled = !is_led_enabled;
                LOG_INF("Triple tap: LED toggled %s", is_led_enabled ? "ON" : "OFF");
                fsm_state = STATE_IDLE;
            }
        }
        break;

    case STATE_FOURTH_PRESS:
        if (!pressed) {
            // Released — wait for fifth tap.
            fsm_state = STATE_FOURTH_RELEASE;
            state_timer = 0;
        } else {
            // Absorb hold — no action on 4-tap hold.
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= HOLD_TIME) {
                fsm_state = STATE_WAIT_FOR_RELEASE;
            }
        }
        break;

    case STATE_FOURTH_RELEASE:
        if (pressed) {
            // Fifth tap started!
            fsm_state = STATE_FIFTH_PRESS;
            state_timer = 0;
        } else {
            uint32_t idle_duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (idle_duration_ms > MULTI_TAP_WINDOW) {
                // Timeout — 4-tap, no action.
                LOG_INF("Quadruple tap (no action)");
                fsm_state = STATE_IDLE;
            }
        }
        break;

    case STATE_FIFTH_PRESS:
        if (!pressed) {
            // Released before hold threshold — 5-tap, no action.
            LOG_INF("Quintuple tap (no action)");
            fsm_state = STATE_IDLE;
        } else {
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= UNPAIR_HOLD_TIME) {
                // 5-tap + 10s hold → clear all BLE bonds.
                LOG_WRN("5-tap + hold: clearing all BLE bonds!");
                bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY);

                // Feedback: blink red 3 times, vibrate 1s.
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
