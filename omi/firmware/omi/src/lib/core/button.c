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

#include "diag_log.h"
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

/* Serializes a whole mute transition — the state change, the BLE notify and the
 * inline stream marker — so two callers cannot emit out of order.
 *
 * Be precise about what this does and does not guard, because the obvious reading
 * is wrong. There are exactly two callers: the button FSM (button.c) and the BLE
 * mute write (transport.c). Two BUTTON mutes cannot race — the FSM polls at 25 Hz
 * on one work handler behind a 600 ms multi-tap window, so they are both far apart
 * and on the same thread. Button-mashing is not the hazard.
 *
 * The reachable case is button thread vs BT RX thread, where the button timing
 * constrains nothing. It needs a BLE mute write to land inside the window between
 * the button thread releasing mic_state_lock and writing its marker, so in practice
 * it means the app's mute control and the device button being used at the same
 * instant: possible, not probable.
 *
 * It is guarded anyway because mute_apply() mutates shared state and emits ORDERED
 * stream markers, and is genuinely called from two threads — making it non-reentrant
 * is ordinary practice, and the failure mode is silent: 0xFFFFFFF9 landing before
 * 0xFFFFFFFA gives the app's bracket parser a close before its open, with nothing
 * in any log to explain the corrupted mute bracket months later.
 *
 * mic_state_lock cannot do this job: it is deliberately released before the notify
 * and the marker write, since those can block on a saturated SD queue and every mic
 * transition on every thread queues behind that mutex. So the ordering guarantee
 * gets its own lock, held across the whole body, while mic_state_lock keeps its
 * narrow scope for the is_muted/mic agreement. Lock order is always
 * mute_apply_lock → mic_state_lock and never the reverse: nothing in mic.c calls
 * mute_apply(), and this is the only user of this mutex. */
static K_MUTEX_DEFINE(mute_apply_lock);

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
        return false; /* fast path — re-checked under the lock below */
    }

    k_mutex_lock(&mute_apply_lock, K_FOREVER);
    /* Re-check under the lock. The check above is only a fast path: two threads
     * (button gesture and BLE mute write) can both observe the old value and both
     * fall through, and without this they would both apply the change — two mic
     * transitions and two mute markers bracketing the same stretch of audio, which
     * the app's bracket parsing reads as a nested mute. */
    if (on == is_muted) {
        k_mutex_unlock(&mute_apply_lock);
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
    is_muted = on;
    if (on) {
        // Force the LED on so the solid-red mute indicator shows even from
        // stealth; remember the prior preference so unmute can restore it.
        led_state_before_mute = is_led_enabled;
        is_led_enabled = true;
        mute_since_utc_s = get_utc_time();
        mute_since_uptime_ms = (uint32_t) k_uptime_get();
        /* Through the gate rather than a direct mic_pause(), so mute is derived like
         * every other input (mic_should_run() returns false whenever is_muted) and
         * capture stops in exactly one place. It also makes the diagnostics
         * symmetric: unmute already resumed via the gate and emitted a
         * DIAG_MIC_STATE record, so a direct pause here logged resumes with no
         * matching parks — a log that reads like the mic restarting on its own.
         *
         * The gate posts the capture-gap notice itself, which is what makes the next
         * speech after unmute emit a 0xFFFFFFFD and re-anchor the app's timeline
         * instead of stamping everything early by the mute duration, and drops the
         * now-stale pre-mute pre-roll. */
        aad_apply_mic_gate();
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
        /* Not a bare mic_resume(): unmuting in manual standby must leave capture
         * parked, so the mic state stays derived from (threshold, is_muted) in one
         * place. Recursive lock, so nesting is fine. */
        aad_apply_mic_gate();
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
    k_mutex_unlock(&mute_apply_lock);
    return true;
}

void mute_get_state(uint8_t *muted, uint32_t *since_utc_s, uint32_t *since_uptime_ms)
{
    /* Read all three under the same lock mute_apply() writes them under. It sets
     * is_muted BEFORE the timestamps, so an unsynchronized reader landing between
     * the two returns muted=1 with the previous session's since_* — or zeros on the
     * very first mute — and the app renders "Muted since" against a time that never
     * happened. Both writes are inside mic_state_lock's critical section, so taking
     * it here makes the trio one atomic snapshot.
     *
     * Lock order holds: the only callers are the GATT read handler and
     * mute_state_notify(), and mute_apply() calls the latter only AFTER releasing
     * mic_state_lock — so this never runs with that mutex already held, and the
     * mute_apply_lock → mic_state_lock order is never inverted. */
    k_mutex_lock(&mic_state_lock, K_FOREVER);
    if (is_muted) {
        *muted = 1;
        *since_utc_s = mute_since_utc_s;
        *since_uptime_ms = mute_since_uptime_ms;
    } else {
        *muted = 0;
        *since_utc_s = 0;
        *since_uptime_ms = 0;
    }
    k_mutex_unlock(&mic_state_lock);
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
    transport_note_priority_record_stop();               /* diagnostics: pairs with the start count (0x19B10062) */
    uint16_t resting = app_settings_get_vad_threshold(); /* persisted auto value */
    aad_set_threshold(resting);
    /* NO mic_reset() HERE — removed. Its rationale ("enter sleep on a known-good
     * mic ... before the watchdog notices") referenced AAD_WEDGE_RESET_MS and a
     * watchdog that do not exist anywhere in this tree, and it could not have
     * delivered it anyway: since oo-2.8.5 the call is a dmic re-trigger, which
     * mic.h states does not recover a wedged part. What it did do was STOP/START a
     * running mic (this path restores an AUTO threshold, so the gate keeps capture
     * on) the instant VAD parks asleep, putting a discontinuity into the pre-roll
     * that the next auto recording flushes at its head.
     *
     * A wedge here is caught by DIAG_VAD_LEVEL instead: auto mode keeps the mic
     * running, so its windows keep closing and a zero peak is the signature. */

    /* Fire-and-forget, like the manual stop in record_stop(). Both reach here on the
     * system workqueue (this one also via priority_cap_work), and neither consumes
     * the durability the blocking form waits for — a drain plus a CTRL_SYNC that can
     * force a NAND erase. Nothing after this call depends on the rotation having
     * completed: priority_record_cancel_cap() only cancels a work item.
     *
     * Safe here specifically because a STOP wants its marker in the OLD bin, and
     * REQ_CREATE_NEW_FILE drains sd_msgq before rotating — so the 0xFFFFFFFC that
     * aad_set_threshold() just enqueued lands in the priority bin either way, keeping
     * it self-contained ([0xFFFFFFF8 .. audio .. 0xFFFFFFFC]). record_start()'s
     * rotation is the mirror image and must NOT be converted; see the note there. */
    if (sd_request_rotate_async(ROTATE_REASON_PRIORITY_STOP) != 0) {
        LOG_ERR("Priority stop: bin rotation not queued — the priority bin stays open "
                "and unlistable until the idle-connect rotate or a Force Sync");
    }
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
    /* Mode is read from the PERSISTED threshold, not the runtime one: an
     * auto-mode priority recording sets runtime 65535 without persisting it, so
     * the persisted value still reflects the real mode (32769/65535 manual,
     * < 32769 auto). */
    uint16_t resting = app_settings_get_vad_threshold();
    bool in_manual = (resting == 32769 || resting == 65535);
    bool already_recording = (aad_get_threshold() == 65535);
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
        /* NO mic_reset() HERE either — removed for the same reason as the auto branch
         * below, and pre-arm makes it worse rather than better. The mic is now already
         * running by this point (the FSM woke it on the press edge so pre-roll could
         * collect the ~700 ms this handler spends deciding what the press was), so the
         * reset is no longer the no-op it would be on a parked mic: it would STOP and
         * START a running mic and discard the in-flight block at exactly the head of
         * the recording — throwing away part of the audio pre-arm exists to keep.
         *
         * THIS IS THE PLACE to restore the PDM_EN power cycle if the rail experiment
         * ends (IDEAS.md "Mic rail (PDM_EN) is not driven by firmware", restore step
         * 1): a manual start is the one moment the user has unambiguously asked for
         * audio. It would need to run BEFORE the pre-arm resume, not here, so the dead
         * samples land outside the recording. */
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
    /* NO mic_reset() HERE — removed deliberately. It used to start every Priority
     * Recording on a freshly power-cycled mic, which was worth ~40 ms at the one
     * moment the user has unambiguously asked for audio. Since oo-2.8.5 it does not
     * touch PDM_EN (IDEAS.md "Mic rail (PDM_EN) is not driven by firmware"), so all
     * that remained was a dmic STOP/START on an already-running mic: it cannot rescue
     * a wedged part — mic.h says so — and it discards the samples in flight at exactly
     * the head of the recording. Pure cost.
     *
     * The wedge protection now comes from the gate's post-resume probe instead
     * (DIAG_MIC_STATE_RESUMED_SILENT), which detects the failure the reset was
     * supposed to prevent rather than blindly re-triggering against it.
     *
     * mute_apply()'s unmute branch is now the SOLE remaining mic_reset() caller, and
     * is the one place to restore the power cycle from if the rail experiment ends
     * (IDEAS.md "Mic rail (PDM_EN) is not driven by firmware", restore step 1). It
     * is the right one: capture is already stopped there, so the cycle costs nothing
     * and cannot punch a hole in anything. Every other call site had the mic running
     * and could only damage the audio it was supposed to protect. */
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    /* Runtime force-capture only — NOT persisted, so a reboot mid-recording
     * returns to the auto threshold. */
    aad_set_threshold(65535);
    aad_force_wake();
#endif
#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE
    sd_write_pause(false);
    /* MUST stay blocking — do not "match" the async rotate the two stop paths use.
     * A START needs its 0xFFFFFFF8 in the NEW bin, and the marker below is enqueued
     * on sd_msgq, which REQ_CREATE_NEW_FILE DRAINS INTO THE OLD BIN before rotating.
     * Waiting here is what guarantees the rotation is already done before the marker
     * exists, so it cannot be swept backwards. The stops want the opposite (their
     * marker belongs to the bin being closed), which is why async is right for them
     * and wrong here. */
    create_new_audio_file(ROTATE_REASON_PRIORITY_START);
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
        if (force_recording) {
            /* Seal the bin, exactly as priority_record_stop() does below. Without
             * this the recording's last bin — the one holding its own 0xFFFFFFFC —
             * stays the ACTIVE file, which the firmware omits from CMD_LIST_FILES,
             * so the app cannot fetch it. Nothing reopens it either: the age and
             * BLE-connect rotations are both evaluated inside the write path
             * (should_rotate_file(), called only from process_write_data_req), and
             * the stop just parked the mic — there is no next write. The tail then
             * sits on the card until the user records again or force-syncs, and the
             * app holds the recording open as a draft for exactly that long. Seen
             * on-device 2026-08-16: stop at 03:47, five background syncs told "0
             * files", released 2h33m later only by a manual Force Sync.
             *
             * Gated on force_recording so a Stop tapped in standby (in_manual is
             * true for 32769 too) doesn't rotate an empty bin every press — that
             * would move sd_get_empty_bin_rotations() for no reason and make the
             * counter's one real signal harder to read.
             *
             * Fire-and-forget, matching priority_record_stop() below. The blocking
             * create_new_audio_file() waits up to 2 s queueing plus 25 s on the
             * worker's semaphore, and this runs on the system workqueue — the same
             * one carrying priority_cap_work and the FSM's own 25 Hz poll. The wait
             * buys durability nothing here consumes; what it costs is a drain plus a
             * CTRL_SYNC that can force a NAND erase, on the everyday path. Ordering
             * is unaffected: REQ_CREATE_NEW_FILE drains sd_msgq into the OLD bin
             * before rotating, so the 0xFFFFFFFC aad_set_threshold() just enqueued
             * still lands in the bin it closes. (record_start()'s rotation is the
             * mirror image and stays blocking — see the note there.)
             *
             * Deliberately NOT done inside aad_set_threshold(): the app's own
             * threshold writes land there on the BLE callback thread, and even a
             * fire-and-forget rotate would be wrong to attach to a path whose other
             * callers are boot restore and the priority cap. The app-driven stop is
             * covered by the idle-connect rotate instead.
             *
             * Logged on failure because this call IS the fix: without it the bin is
             * unreachable until the next recording or a Force Sync, and the only
             * remaining symptom is a recording that stays "in progress" for hours. */
            if (sd_request_rotate_async(ROTATE_REASON_SESSION_END) != 0) {
                LOG_ERR("Manual stop: bin rotation not queued — this recording stays "
                        "unlistable until the idle-connect rotate or a Force Sync");
            }
        }
#endif
        /* NO mic_reset() HERE — removed, and pre-arm is why it is worse than dead.
         * The FSM has not returned to idle yet, so mic_prearm is still set and the
         * gate above deliberately kept capture running; the reset would therefore
         * STOP/START a mic that the gate parks a few hundred ms later regardless.
         * Churn on the way out of a recording, in exchange for nothing a dmic
         * re-trigger can provide. */
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
    case BUTTON_ACTION_MARKER: {
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
        /* Manual STANDBY: the tap does nothing at all. Not a bookmark, not an orphan
         * EDL, nothing — it is swallowed here and no byte reaches the card. There is
         * no recording to bookmark, and the alternative was worse than useless: it
         * force-captured ~60 s of audio (aad_force_wake feeds has_voice, which no
         * mode check gated) in the one mode whose promise is that it records only
         * when told to.
         *
         * Manual RECORDING is different and still works — bookmarking a moment
         * inside a long manual recording is exactly what a marker is for.
         *
         * The PERSISTED threshold decides, not the runtime one: 32769 is manual
         * standby, 65535 manual recording, anything lower auto. An auto-mode Priority
         * Recording holds runtime 65535 without persisting it, so reading the runtime
         * value would misclassify a marker tapped during one as manual. */
        const uint16_t resting_thr = app_settings_get_vad_threshold();
        const bool marker_in_manual = (resting_thr == 32769 || resting_thr == 65535);
        if (resting_thr == 32769) {
            LOG_INF("Marker ignored (manual standby — nothing is recording)");
            break;
        }
#else
        const bool marker_in_manual = false;
#endif
        if (!is_muted) {
            // A plain white bookmark, and in auto mode it also guarantees the audio
            // around itself: aad_force_wake() below bypasses BOTH the firmware's
            // amplitude threshold and (via the app's matching 50 s window) Silero,
            // for ~60 s from the tap. That is the point of the action — the user
            // cannot know whether the VAD considers the moment worth recording, so a
            // marker asserts that it is. The guarantee is unconditional, NOT "only if
            // it was not already recording": a tap during speech that then stops
            // would otherwise end the recording 10 s later with the marker at its
            // tail, which is the exact loss the window exists to prevent.
            acted = true;
            LOG_INF("Marker detected");
            marker_flash_color = MARKER_FLASH_WHITE;
            marker_flash_count = 2;
#ifdef CONFIG_OMI_ENABLE_T5838_AAD
            /* NO mic_reset() HERE — removed, and replaced by something that actually
             * works. The case this guarded is real and worth keeping in mind: a
             * marker tapped because "it isn't recording anything" is the user
             * reporting a wedge, and in the 2026-07-28 incident that tap was the
             * first write to the card in 14.5 h. But a dmic re-trigger cannot clear
             * a wedged T5838 (mic.h), so all it delivered was a hole in the audio
             * immediately before the window the marker exists to bookmark.
             *
             * What replaces it is detection rather than a blind retry. In manual
             * standby the mic is parked, so this tap resumes it through the gate,
             * which arms the post-resume probe — a part returning digital silence
             * now reports DIAG_MIC_STATE_RESUMED_SILENT at the exact moment the user
             * complained. In auto mode the mic never stopped, so DIAG_VAD_LEVEL's
             * zero-peak windows are the signature instead. Both modes covered. */
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
            /* Auto mode only. In a manual recording the 65535 threshold already
             * forces every frame, so the window would add nothing — except a bug:
             * force_wake_until_ms outlives a stop, so a marker tapped within 50 s of
             * pressing Stop would hold has_voice true past the stop and resume
             * capturing in standby, for the remainder of the window. */
            if (!marker_in_manual) {
                aad_force_wake();
            }
#endif
        } else {
            LOG_INF("Marker ignored (muted)");
        }
        break;
    }
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
    const button_fsm_state_t entry_state = fsm_state;
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
                diag_log_event(DIAG_BOND_STATE, 0, DIAG_BOND_CAUSE_BUTTON, transport_bond_count());

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

#ifdef CONFIG_OMI_ENABLE_T5838_AAD
    /* Pre-arm the mic for the whole interaction. In manual standby the mic is parked,
     * and this handler cannot know for ~700 ms whether a press is a record-start —
     * MULTI_TAP_WINDOW has to expire first to rule out a second tap. Waking on the
     * press edge means pre-roll has already collected that span by the time
     * execute_button_action() runs, so a manual recording still starts where the
     * user's finger did instead of where the FSM caught up.
     *
     * The clear runs AFTER the action has dispatched (execute_button_action is called
     * from the branches above, before the state lands on IDLE), so by then the gate
     * sees the threshold the action set: a record-start holds the mic on, anything
     * else parks it again. A press that starts nothing costs a few hundred ms of mic.
     *
     * No-op in auto mode, where the gate keeps the mic running regardless. */
    if (entry_state == STATE_IDLE && fsm_state != STATE_IDLE) {
        aad_set_mic_prearm(true);
    } else if (entry_state != STATE_IDLE && fsm_state == STATE_IDLE) {
        aad_set_mic_prearm(false);
    }
#else
    ARG_UNUSED(entry_state);
#endif

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
