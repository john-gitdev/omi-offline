#include "button.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/sys/poweroff.h>

#include "haptic.h"
#include "imu.h"
#include "led.h"
#include "mic.h"
#include "rtc.h"
#include "speaker.h"
#include "transport.h"
#include "wdog_facade.h"
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
        mute_since_uptime_ms = (uint32_t) k_uptime_get();
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
typedef enum { STATE_IDLE, STATE_PRESS, STATE_RELEASE, STATE_WAIT_FOR_RELEASE } button_fsm_state_t;

static volatile button_fsm_state_t fsm_state = STATE_IDLE;
static uint32_t state_timer = 0;
static uint8_t tap_count = 0;

#define HOLD_TIME 1000           // 1s hold threshold for customizable actions
#define POWER_OFF_HOLD_TIME 3000 // 3s hold for 4-tap power off
#define UNPAIR_HOLD_TIME 10000   // 10s hold for 5-tap unpair
#define MULTI_TAP_WINDOW 600     // 600ms window for multi-taps

/* ================================================================
 * Priority Recording (auto-mode force-capture)
 * ================================================================
 * An auto-mode RECORD_START forces continuous capture (runtime threshold
 * 65535, deliberately NOT persisted so a reboot returns to auto) bracketed by
 * a 0xFFFFFFF8 start marker and the existing 0xFFFFFFFC session-end on stop.
 * A safety cap auto-stops a recording the user forgets to end so a runaway
 * capture can't drain the 150 mAh cell or fill the SD card. */

/* AAD without offline storage is an invalid build: RECORD_START's force-capture
 * (aad_set_threshold(65535)) runs under AAD alone, but its only sink and the
 * RECORD_STOP threshold-restore both live behind offline storage — so the mic
 * would be pinned awake with no way to stop it. This offline-first firmware
 * always ships SD storage, so forbid the combination at build time rather than
 * carry a dead, asymmetric code path. */
#if defined(CONFIG_OMI_ENABLE_T5838_AAD) && !defined(CONFIG_OMI_ENABLE_OFFLINE_STORAGE)
#error "CONFIG_OMI_ENABLE_T5838_AAD requires CONFIG_OMI_ENABLE_OFFLINE_STORAGE"
#endif

#if defined(CONFIG_OMI_ENABLE_T5838_AAD) && defined(CONFIG_OMI_ENABLE_OFFLINE_STORAGE)
/* Safety-cap duration is user-configurable over BLE (Settings char 0x19B10014),
 * persisted as priority_record_max_minutes; 0 disables the cap so battery / SD
 * capacity become the only limit. Default 120 minutes (see settings.c). */

static void priority_record_stop(void);

static void priority_cap_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    LOG_INF("Priority recording safety cap reached — auto-stopping");
    priority_record_stop();
}
K_WORK_DELAYABLE_DEFINE(priority_cap_work, priority_cap_work_handler);

static void priority_record_arm_cap(void)
{
    uint16_t minutes = app_settings_get_priority_record_max_minutes();
    if (minutes == 0) {
        /* 0 = no safety cap: let battery / SD capacity be the only limit. */
        k_work_cancel_delayable(&priority_cap_work);
        return;
    }
    /* minutes <= 65535 -> <= 3.93e9 ms, within uint32 unsigned range. */
    k_work_reschedule(&priority_cap_work, K_MSEC((uint32_t) minutes * 60U * 1000U));
}

static void priority_record_cancel_cap(void)
{
    k_work_cancel_delayable(&priority_cap_work);
}

/* Stop an auto-mode Priority Recording. Restoring the persisted auto VAD
 * threshold takes aad_set_threshold's finalize path (prev == 65535) which emits
 * the 0xFFFFFFFC session-end marker and ends the recording immediately; the bin
 * rotate then gives the resumed auto recording a fresh bin so the priority
 * recording owns whole bins (no shared-bin re-VAD). No-op if not force-capturing. */
static void priority_record_stop(void)
{
    if (aad_get_threshold() != 65535) {
        return;
    }
    uint16_t resting = app_settings_get_vad_threshold(); /* persisted auto value */
    aad_set_threshold(resting);
    create_new_audio_file();
    priority_record_cancel_cap();
}
#else
static inline void priority_record_arm_cap(void) {}
static inline void priority_record_stop(void) {}
#endif

/* Start a recording from the button. Manual mode: force capture and persist the
 * threshold (65535) so the offline start survives a reboot. Auto mode: open a
 * force-captured Priority Recording (runtime 65535, NOT persisted) bracketed by
 * a 0xFFFFFFF8 start marker, after rotating the bin so the prior auto recording
 * owns the old bin. Caller must have already checked !is_muted. Returns true if
 * it acted (false = auto priority recording already running). */
static bool record_start(void)
{
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    /* Mode is read from the PERSISTED threshold, not the runtime one: an
     * auto-mode priority recording sets runtime 65535 without persisting it, so
     * the persisted value still reflects the real mode (32769/65535 manual,
     * < 32769 auto). */
    uint16_t resting = app_settings_get_vad_threshold();
    bool in_manual = (resting == 32769 || resting == 65535);
    bool already_recording = (aad_get_threshold() == 65535);
#else
    bool in_manual = false;
    bool already_recording = false;
#endif
    if (in_manual) {
        /* Explicit manual-mode start, persisted so it survives a reboot. */
        marker_flash_color = MARKER_FLASH_GREEN;
        marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
        aad_set_threshold(65535);
        app_settings_save_vad_threshold(65535);
#endif
        return true;
    } else if (already_recording) {
        LOG_INF("Record start ignored (priority recording already active)");
        return false;
    }
    /* Auto-mode Priority Recording: rotate first so the prior auto recording owns
     * the old bin, then write 0xFFFFFFF8 as the first inline frame of the fresh
     * bin and force continuous capture. */
    marker_flash_color = MARKER_FLASH_RED;
    marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    sd_write_pause(false);
    create_new_audio_file();
    write_priority_recording_marker_to_storage();
#endif
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    /* Runtime force-capture only — NOT persisted, so a reboot mid-recording
     * returns to the auto threshold. */
    aad_set_threshold(65535);
    aad_force_wake();
#endif
    priority_record_arm_cap();
    return true;
}

/* Stop a recording from the button. Manual mode: persist the standby threshold
 * (32769) so the offline stop survives a reboot. Auto mode: stop the active
 * Priority Recording (emits the 0xFFFFFFFC session-end marker via the threshold
 * restore). Caller must have already checked !is_muted. Returns true if it acted
 * (false = nothing was recording). */
static bool record_stop(void)
{
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    uint16_t resting = app_settings_get_vad_threshold(); /* persisted → real mode */
    bool in_manual = (resting == 32769 || resting == 65535);
    bool force_recording = (aad_get_threshold() == 65535);
#else
    bool in_manual = false;
    bool force_recording = false;
#endif
    if (in_manual) {
        /* Explicit manual-mode stop, persisted so the offline stop survives a
         * reboot. */
        marker_flash_color = MARKER_FLASH_RED;
        marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
        aad_set_threshold(32769);
        app_settings_save_vad_threshold(32769);
#endif
        return true;
    } else if (force_recording) {
        /* Auto-mode Priority Recording stop. */
        marker_flash_color = MARKER_FLASH_RED;
        marker_flash_count = 2;
        priority_record_stop();
        return true;
    }
    LOG_INF("Record stop ignored (no priority recording active)");
    return false;
}

static void execute_button_action(uint8_t taps, bool is_hold)
{
    if (taps < 1 || taps > 3)
        return;

    uint8_t config[6];
    app_settings_get_button_config(config);

    uint8_t index = (taps - 1) * 2 + (is_hold ? 1 : 0);
    button_action_t action = (button_action_t) config[index];

    LOG_INF("Action triggered: taps=%d, hold=%d -> action=%d", taps, is_hold, action);

    // Tracks whether the action actually took effect, so haptic feedback fires
    // only when something happened (e.g. a mute tap is a no-op in manual mode).
    // __maybe_unused: only read under CONFIG_OMI_ENABLE_HAPTIC below.
    bool __maybe_unused acted = false;

    switch (action) {
    case BUTTON_ACTION_MUTE:
        acted = mute_apply(!is_muted);
        break;
    case BUTTON_ACTION_MARKER:
        if (!is_muted) {
            // Always a plain white bookmark now, in any mode. The manual-mode
            // start/stop overload was removed — explicit RECORD_START /
            // RECORD_STOP handle recording control in both modes, which also lets
            // a marker be dropped *during* a manual recording.
            acted = true;
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
        } else {
            LOG_INF("Marker ignored (muted)");
        }
        break;
    case BUTTON_ACTION_TOGGLE_LED:
        is_led_enabled = !is_led_enabled;
        LOG_INF("LED toggled %s", is_led_enabled ? "ON" : "OFF");
        acted = true;
        break;
    case BUTTON_ACTION_RECORD_START:
        if (is_muted) {
            LOG_INF("Record start ignored (muted)");
            break;
        }
        acted = record_start();
        break;
    case BUTTON_ACTION_RECORD_STOP:
        if (is_muted) {
            LOG_INF("Record stop ignored (muted)");
            break;
        }
        acted = record_stop();
        break;
    case BUTTON_ACTION_RECORD_TOGGLE:
        if (is_muted) {
            LOG_INF("Record toggle ignored (muted)");
            break;
        }
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
        /* Runtime 65535 = actively recording in either mode (manual recording
         * and auto priority-recording both hold it); anything else = idle. So
         * one check picks the right direction without knowing the mode. */
        acted = (aad_get_threshold() == 65535) ? record_stop() : record_start();
#else
        /* No AAD → no recording-state to read; a toggle can only start. */
        acted = record_start();
#endif
        break;
    case BUTTON_ACTION_NONE:
    default:
        break;
    }

#ifdef CONFIG_OMI_ENABLE_HAPTIC
    // Buzz the configured vibration pattern for this slot, but only when the
    // action actually did something. play_haptic_pattern(0) is a no-op, so
    // off-slots stay silent regardless.
    if (acted) {
        uint8_t haptic_cfg[6];
        app_settings_get_haptic_config(haptic_cfg);
        play_haptic_pattern(haptic_cfg[index]);
    }
#endif
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
