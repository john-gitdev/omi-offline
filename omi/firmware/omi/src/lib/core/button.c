#include "button.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/poweroff.h>
#include <zephyr/sys/reboot.h>

#include "haptic.h"
#include "imu.h"
#include "led.h"
#include "mic.h"
#include "rtc.h"
#include "speaker.h"
#include "transport.h"
#include "diag_log.h"
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
    /* is_muted and the mic's run state must never disagree, so the write and the
     * mic call are one atomic unit. Without this the pair is a check-then-act for
     * anyone else reading is_muted to decide whether to stop capture (main.c does
     * exactly that at boot): they can observe one value and act after the other has
     * already been applied, leaving the mic running while muted, or stopped while
     * unmuted with nothing to resume it.
     *
     * Scoped tightly on purpose — released before mute_state_notify() and the
     * marker writes below, which can block on a saturated SD queue and would stall
     * every mic transition on every thread. Recursive, so the nested mic calls are
     * fine. */
    k_mutex_lock(&mic_state_lock, K_FOREVER);
    /* Re-check under the lock. The early return above is only a fast path: two
     * threads (button gesture and BLE mute write) can both observe the old value
     * and both fall through, and without this they would both apply the change —
     * two mic transitions and, worse, two mute-on/off markers bracketing the same
     * stretch of audio, which the app's bracket parsing reads as a nested mute. */
    if (on == is_muted) {
        k_mutex_unlock(&mic_state_lock);
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
        /* Unmute was chosen as the safest recovery point for a wedged T5838: no
         * capture is in flight, so a full power-cycle cost nothing but ~40 ms.
         *
         * mic_reset() NO LONGER POWER-CYCLES — nothing drives PDM_EN any more (see
         * IDEAS.md "Mic rail (PDM_EN) is not driven by firmware"), so this pair is
         * now just a dmic re-trigger and a wedged part survives a mute/unmute
         * untouched again. The call is kept, not deleted, so restoring the cycle is
         * one edit here rather than a hunt for the right recovery point. */
        mic_reset();
        mic_resume();
    }
    k_mutex_unlock(&mic_state_lock);
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
    transport_note_priority_record_stop(); /* diagnostics: pairs with the start count (0x19B10062) */
    uint16_t resting = app_settings_get_vad_threshold(); /* persisted auto value */
    aad_set_threshold(resting);
    /* aad_set_threshold's finalize path just parked AAD asleep, where only the
     * hardware wake line can start another recording. Reset on the way in so we
     * enter sleep on a known-good mic: without this a wedge that began during the
     * recording costs up to AAD_WEDGE_RESET_MS of dead auto-capture before the
     * watchdog notices. Free here — the recording has already ended. */
    mic_reset();
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
        /* Same reasoning as the auto-mode priority path below: this opened capture
         * on a freshly powered mic, manual mode being just as exposed to a wedged
         * part — more so, since it has no other recovery path at all. mic_reset() no
         * longer power-cycles, so that protection is currently absent (IDEAS.md "Mic
         * rail (PDM_EN) is not driven by firmware").
         *
         * Only when capture is not already running. in_manual is true for BOTH
         * manual sub-states — 32769 standby and 65535 recording — so a second
         * RECORD_START press while a manual recording is live lands here too, and
         * an unguarded reset would drop that live recording's in-flight samples (a
         * ~40 ms hole while it still power-cycled; the dmic stop/start alone is
         * shorter, but not free). The
         * repeat is entirely reachable: nothing upstream de-duplicates the action,
         * and pressing again is the natural thing to do when you missed the LED
         * flash and aren't sure the recording started. Re-pressing was a harmless
         * no-op before this change and must stay one. (already_recording is
         * otherwise dead in this branch — the else-if below only ever sees it in
         * auto mode.) */
        if (!already_recording) {
            mic_reset();
        }
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
        aad_set_threshold(65535);
        app_settings_save_vad_threshold(65535);
#endif
        return true;
    } else if (already_recording) {
        LOG_INF("Record start ignored (priority recording already active)");
        return false;
    }
    /* Auto-mode Priority Recording. Enter force-capture (runtime 65535 + force-wake)
     * BEFORE the rotate + 0xFFFFFFF8 marker. If the button was tapped just as a
     * silence gap ended, a pause request may still be queued (sd_pause_pending=1)
     * that the AAD handler hasn't applied yet; sd_write_pause(false) only clears the
     * live flag, not that queued request, so the handler would re-pause SD writes a
     * moment later and the still-paused SD worker would silently drop the marker and
     * first audio frames at the sd_write_paused gate (sd_card.c). Setting the
     * force-capture state first lets the AAD handler recognise the queued pause as
     * stale and skip it. Then rotate so the prior auto recording owns the old bin,
     * and write 0xFFFFFFF8 as the first inline frame of the fresh bin. */
    marker_flash_color = MARKER_FLASH_RED;
    marker_flash_count = 2;
    /* This used to start every Priority Recording on a freshly powered mic — the
     * one moment the user has unambiguously asked for audio, so worth ~40 ms to
     * guarantee the part is not wedged.
     *
     * It no longer does: mic_reset() does not touch PDM_EN any more (IDEAS.md "Mic
     * rail (PDM_EN) is not driven by firmware"), so this is a dmic re-trigger that
     * will NOT rescue a wedged part. Worth knowing, because a Priority Recording
     * happening to call this is exactly what recovered the 2026-08-02 outage — that
     * escape hatch is closed while the rail experiment runs.
     *
     * Kept here, still before the force-capture entry and the rotate + 0xFFFFFFF8
     * marker, so restoring the cycle puts the dead samples outside the recording
     * rather than at its head, as before. */
    mic_reset();
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    /* Runtime force-capture only — NOT persisted, so a reboot mid-recording
     * returns to the auto threshold. */
    aad_set_threshold(65535);
    aad_force_wake();
#endif
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    sd_write_pause(false);
    create_new_audio_file();
    write_priority_recording_marker_to_storage();
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
        /* Manual standby is the same "entering a state only a wake can leave"
         * boundary as priority_record_stop() — reset now that capture has ended. */
        mic_reset();
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
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
            /* Recover a wedged mic here too, but ONLY while idle. Mid-recording a
             * reset drops in-flight samples at exactly the instant the marker is
             * meant to bookmark — the worst possible place. Idle it is free, and it
             * is the case that matters: a marker tapped because "it isn't recording
             * anything" is the user reporting the wedge. In the 2026-07-28 incident
             * this tap was the first write to the card in 14.5 h. */
            if (!aad_is_recording()) {
                mic_reset();
            }
#endif
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
                /* Match CMD_POWER_OFF (storage.c): a bailed teardown has already run
                 * transport_off() and mic_off(), so limping on leaves the device with
                 * BLE down, the mic thread aborted by k_thread_abort() and PDM_EN
                 * driven low — i.e. silently deaf, with mic_on() being the only thing
                 * that could restore the rail and nothing calling it. A cold reboot
                 * restores every one of those, PDM_EN included, because a SoC reset
                 * returns the pin to an input and the board pull-up re-powers it. */
                if (turnoff_all() == TURNOFF_BAILED) {
                    LOG_ERR("4-tap-hold power-off: turnoff_all() bailed — rebooting to recover");
                    k_msleep(100); /* let the error log flush before the cold reboot */
                    sys_reboot(SYS_REBOOT_COLD);
                }
                fsm_state = STATE_WAIT_FOR_RELEASE;
            } else if (tap_count == 5 && duration_ms >= UNPAIR_HOLD_TIME) {
                LOG_WRN("5-tap + hold: clearing all BLE bonds!");
                bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY);
                /* Tag the deliberate wipe so a later "device came up unbonded" can be
                 * attributed to this gesture rather than to an unexplained key loss. */
                diag_log_event(DIAG_BOND_STATE, 0, DIAG_BOND_CAUSE_BUTTON,
                               transport_bond_count());

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

// Returns TURNOFF_ALREADY if another context is already powering off (no-op),
// TURNOFF_BAILED if the hardware teardown couldn't complete (caller may recover,
// e.g. cold-reboot), and never returns on success (ends in sys_poweroff()).
turnoff_result_t turnoff_all()
{
    /* Power-off can be triggered from several contexts — the button work thread
     * (4-tap-hold), the storage thread (CMD_POWER_OFF), and transport. Guard
     * against a concurrent or re-entrant call running the hardware teardown
     * (LED/mic/SD/watchdog/GPIO) twice: the first caller wins, later ones no-op.
     * The winner ends in sys_poweroff() and never returns; a bail-out path below
     * releases the guard so a recovery attempt can retry. */
    static atomic_t poweroff_started = ATOMIC_INIT(0);
    if (!atomic_cas(&poweroff_started, 0, 1)) {
        LOG_WRN("turnoff_all: power-off already in progress, ignoring re-entrant call");
        return TURNOFF_ALREADY;
    }

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
        atomic_clear(&poweroff_started);
        return TURNOFF_BAILED;
    }

    rc = gpio_pin_interrupt_configure_dt(&usr_btn, GPIO_INT_LEVEL_LOW);
    if (rc < 0) {
        LOG_ERR("Could not configure usr_btn GPIO interrupt (%d)", rc);
        atomic_clear(&poweroff_started);
        return TURNOFF_BAILED;
    }
    rc = watchdog_deinit();
    if (rc < 0) {
        LOG_ERR("Failed to deinitialize watchdog (%d)", rc);
        atomic_clear(&poweroff_started);
        return TURNOFF_BAILED;
    }

    /* Persist an IMU timestamp base so we can estimate time across system_off. */
    lsm6dsl_time_prepare_for_system_off();
    k_msleep(1000);
    LOG_INF("Entering system off; press usr_btn to restart");

    // Power off the system using sys_poweroff
    sys_poweroff();
}
