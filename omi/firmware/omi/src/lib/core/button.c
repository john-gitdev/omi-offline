#include "button.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/input/input.h>
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
#ifdef CONFIG_OMI_ENABLE_WIFI
#include "wifi.h"
#endif

#include "imu.h"
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
#include "sd_card.h"
#endif

LOG_MODULE_REGISTER(button, CONFIG_LOG_DEFAULT_LEVEL);

extern bool is_off;
volatile bool is_muted = false;

static void button_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t button_data_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset);

static struct bt_uuid_128 button_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7924, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
static struct bt_uuid_128 button_characteristic_data_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7925, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));

static struct bt_gatt_attr button_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&button_uuid),
    BT_GATT_CHARACTERISTIC(&button_characteristic_data_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           button_data_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(button_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
};

static struct bt_gatt_service button_service = BT_GATT_SERVICE(button_service_attr);

static void button_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_ERR("Invalid CCC value: %u", value);
    }
}
static const struct device *const buttons = DEVICE_DT_GET(DT_ALIAS(buttons));
static const struct gpio_dt_spec usr_btn = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(usr_btn), gpios, {0});

static bool was_pressed = false;

// Polling interval for state machine
#define BUTTON_CHECK_INTERVAL 40 // 0.04 seconds, 25 Hz

void check_button_level(struct k_work *work_item);

K_WORK_DELAYABLE_DEFINE(button_work, check_button_level);

#define SINGLE_TAP 1
#define DOUBLE_TAP 2
#define LONG_TAP 3
#define BUTTON_PRESS 4
#define BUTTON_RELEASE 5

static FSM_STATE_T current_button_state = IDLE;
static int final_button_state[2] = {0, 0};

// State machine definitions
typedef enum {
    STATE_IDLE,
    STATE_FIRST_PRESS,
    STATE_FIRST_RELEASE,
    STATE_SECOND_PRESS
} button_fsm_state_t;

static button_fsm_state_t fsm_state = STATE_IDLE;
static uint32_t state_timer = 0;

#define MUTE_HOLD_TIME 1000      // 1s hold for mute
#define DOUBLE_TAP_WINDOW 600    // 600ms window for second tap
#define POWER_OFF_HOLD_TIME 3000 // 3s hold for power off (on second tap)

static inline void notify_app(int event_type)
{
    final_button_state[0] = event_type;
    struct bt_conn *conn = get_current_connection();
    if (conn != NULL) {
        bt_gatt_notify(conn, &button_service.attrs[1], &final_button_state, sizeof(final_button_state));
    }
}

void check_button_level(struct k_work *work_item)
{
    bool pressed = was_pressed;
    state_timer++;

    switch (fsm_state) {
    case STATE_IDLE:
        if (pressed) {
            fsm_state = STATE_FIRST_PRESS;
            state_timer = 0;
            notify_app(BUTTON_PRESS);
        }
        break;

    case STATE_FIRST_PRESS:
        if (!pressed) {
            // Released. Check duration.
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= MUTE_HOLD_TIME) {
                // Long press 1s -> Mute toggle
                is_muted = !is_muted;
                LOG_INF("Mute toggled: %s", is_muted ? "ON" : "OFF");
                play_haptic_milli(500);
                
                if (is_muted) {
                    set_led_red(true);
                    set_led_green(false);
                } else {
                    set_led_red(false);
                    set_led_green(true);
                }
                
                notify_app(LONG_TAP);
                fsm_state = STATE_IDLE;
            } else {
                // Short press. Wait for second tap.
                fsm_state = STATE_FIRST_RELEASE;
                state_timer = 0;
                notify_app(BUTTON_RELEASE);
            }
        }
        break;

    case STATE_FIRST_RELEASE:
        if (pressed) {
            fsm_state = STATE_SECOND_PRESS;
            state_timer = 0;
            notify_app(BUTTON_PRESS);
        } else {
            uint32_t idle_duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (idle_duration_ms > DOUBLE_TAP_WINDOW) {
                // Timeout. It was just a single tap. Do nothing.
                LOG_INF("Single tap detected (ignored)");
                fsm_state = STATE_IDLE;
            }
        }
        break;

    case STATE_SECOND_PRESS:
        if (!pressed) {
            // Released.
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms < POWER_OFF_HOLD_TIME) {
                // Double tap (release happened before 3s) -> Star
                LOG_INF("Double tap (Star) detected");
                play_haptic_milli(300);
                notify_app(DOUBLE_TAP);
            }
            fsm_state = STATE_IDLE;
            notify_app(BUTTON_RELEASE);
        } else {
            // Still pressed. Check if we hit 3s.
            uint32_t duration_ms = state_timer * BUTTON_CHECK_INTERVAL;
            if (duration_ms >= POWER_OFF_HOLD_TIME) {
                // Double tap + Long hold 3s -> Power Off
                LOG_INF("Power off triggered via Double-Tap-Hold");
                play_haptic_milli(1000);
                turnoff_all(); // This shuts down the device.
                fsm_state = STATE_IDLE;
            }
        }
        break;
    }

    k_work_reschedule(&button_work, K_MSEC(BUTTON_CHECK_INTERVAL));
    return;
}

static ssize_t button_data_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset)
{
    LOG_INF("button_data_read_characteristic");
    LOG_PRINTK("was_pressed: %d\n", final_button_state[0]);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &final_button_state, sizeof(final_button_state));
}

static struct gpio_callback button_cb_data;

static void button_gpio_callback(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    was_pressed = (gpio_pin_get_dt(&usr_btn) == 1);
    // LOG_INF("Button %s (GPIO callback)", was_pressed ? "pressed" : "released");
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

    if (is_sd_on()) {
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
#ifdef CONFIG_OMI_ENABLE_WIFI
    wifi_turn_off();
#endif
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
