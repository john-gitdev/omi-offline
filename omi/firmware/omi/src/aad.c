/*
 * AAD + VAD gate for Omi
 *
 * Owns voice-activity detection (VAD) state.  main.c calls
 * aad_process_audio() from the mic callback to decide whether
 * a frame should be forwarded to the codec or discarded.
 *
 * During VAD silence the SD card may be suspended to save power.
 * A dedicated thread manages SD lifecycle and auto-resumes on
 * BLE connect.  The T5838 WAKE pin (P1.2) is monitored via GPIO
 * ISR to reset VAD debounce on acoustic activity.
 */

#include "aad.h"

#include <stdint.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

#include "imu.h"
#include "lib/core/codec.h"
#include "lib/core/config.h"
#include "lib/core/diag_log.h"
#include "lib/core/mic.h"
#include "lib/core/sd_card.h"
#include "lib/core/settings.h"
#include "lib/core/transport.h"
#include "rtc.h"

LOG_MODULE_REGISTER(aad, CONFIG_LOG_DEFAULT_LEVEL);

/* ---- DTS GPIO spec for WAKE pin ---- */
static const struct gpio_dt_spec pin_wake = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(pdm_wake_pin), gpios, {0});
static struct gpio_callback wake_cb_data;

/* ---- Thread plumbing ---- */
#define AAD_THREAD_STACK_SIZE 2048
#define AAD_THREAD_PRIORITY 5

static K_THREAD_STACK_DEFINE(aad_stack, AAD_THREAD_STACK_SIZE);
static struct k_thread aad_thread_data;
static k_tid_t aad_tid;

static K_SEM_DEFINE(aad_sem, 0, 1);

/* ---- Atomic flags (ISR / cross-thread safe) ---- */
static atomic_t wake_pending = ATOMIC_INIT(0);
static atomic_t wake_consumed = ATOMIC_INIT(0);
/* Set by aad_note_capture_gap(), consumed on the mic thread. Same pattern as
 * wake_consumed: the VAD statics below belong to the mic callback, so a caller on
 * another thread posts a request instead of writing them. */
static atomic_t capture_gap_pending = ATOMIC_INIT(0);
/* Same contract, narrower job: drop the pre-roll ring without claiming a capture gap.
 * aad_set_threshold()'s finalize needs the reset (see there) but runs on the button/BLE
 * thread, and preroll_reset() is NOT safe to call from there. It was once far worse —
 * the reset also cleared a paced-replay state whose counts were decremented after a
 * zero test, so a reset landing between the two underflowed a uint8_t to 255 and
 * replayed ~25 s of stale frames. That state is gone; what remains is preroll_store(),
 * whose memcpy / write-index advance / count bump is still a multi-step update, and a
 * reset interleaved with it leaves a ring whose contents do not match its counters —
 * i.e. a garbled frame at the head of the next recording rather than a wedge. Smaller,
 * still real, and the fix costs nothing since the mechanism already exists. The plain
 * assignments the finalize makes alongside (vad_is_recording, vad_sleeping,
 * vad_voice_streak) carry no such hazard: none is a read-modify-write. */
static atomic_t replay_reset_pending = ATOMIC_INIT(0);
/* Button interaction in flight — an input to mic_should_run(). See
 * aad_set_mic_prearm(). */
static atomic_t mic_prearm = ATOMIC_INIT(0);

/* Post-resume capture probe. Set to MIC_VERIFY_FRAMES when the gate starts the mic;
 * the mic thread counts them down and ORs each frame's level into mic_verify_level,
 * so a run that ends at zero means the mic returned digital silence — a START that
 * "succeeded" onto a wedged part. 5 frames = 500 ms, past any PDM settling. */
#define MIC_VERIFY_FRAMES 5
static atomic_t mic_verify_frames = ATOMIC_INIT(0);
static atomic_t mic_verify_level = ATOMIC_INIT(0);

/* Liveness + duty, both read over BLE (0x0062) rather than inferred from the event
 * log. last_frame_uptime_ms answers "is the mic delivering right now" in one
 * subtraction against the payload's nowUptimeMs — the question that took timestamp
 * archaeology across a 12-record log to get wrong. voiced_ms totals the time the VAD
 * held a recording open, which against uptime is the auto-mode capture duty cycle:
 * the number that governs how much of the day is encoded and written, and so the
 * largest remaining battery lever. Written only on the mic thread; a torn 32-bit
 * read from the BLE thread is a harmless stale snapshot. */
static uint32_t mic_last_frame_uptime_ms;
static uint32_t vad_voiced_ms;
static atomic_t sd_pause_pending = ATOMIC_INIT(0); /* 1=pause, 2=resume */
static atomic_t adv_slow_req = ATOMIC_INIT(0);
static atomic_t adv_fast_req = ATOMIC_INIT(0);
/* Posted by the VAD-sleep path instead of doing the work inline. The checkpoint is
 * an unconditional 50 ms rail settle, six I2C round trips and an NVS write — and an
 * NVS write can trigger a page erase (~85 ms of stalled CPU) when the sector fills.
 * That ran on the MIC THREAD, via aad_process_audio(), at every silence transition:
 * up to ~140 ms of stall on the capture path, every 10 s of quiet in auto mode. The
 * dmic driver's four buffers (400 ms) absorbed it, so nothing was lost — but nothing
 * about it belonged there. */
static atomic_t imu_checkpoint_pending = ATOMIC_INIT(0);

/* volatile: written on the button/mic threads (aad_set_threshold) and read on the
 * AAD handler thread — notably the re-read in aad_thread_fn that undoes a pause
 * applied into a racing force-capture. Without volatile the compiler may cache the
 * first read (this static is invisible to sd_write_pause's translation unit, so it
 * can't be assumed to clobber it), making that "re-read" stale. Aligned 16-bit
 * loads/stores are atomic on this Cortex-M33, so a plain volatile is sufficient. */
static volatile uint16_t vad_threshold = 250;

/* ---- Force-wake (button press) ---- */
/* Mirrored app-side as _markerProtectionWindowMs in app/lib/services/
 * vad_audio_processor.dart — the app suppresses splits / forces speech for the
 * same span so a button-tap marker's audio is never split away. Keep equal. */
#define FORCE_WAKE_HOLD_MS 50000
/* These two are written on one thread and read on another (force_wake_until_ms:
 * button-work thread -> mic thread; last_hw_wake_ms: aad thread -> main loop).
 * A 64-bit read is two 32-bit loads on this core, so a torn read is possible in
 * principle. It is benign here because both hold k_uptime_get() millisecond
 * values whose high 32 bits stay 0 until ~49.7 days of continuous uptime — far
 * beyond this wearable's per-charge runtime — so the high word never changes
 * mid-write and any torn read reassembles to the correct value. */
static int64_t force_wake_until_ms = 0;
static int64_t last_hw_wake_ms = -100000; // Initialize to long ago

extern volatile bool is_muted;

/* ---- VAD state (written on the mic callback thread only) ---- */
/* volatile for the same reason vad_threshold is, and now with a second reader that
 * depends on it: the AAD handler thread re-reads this after its blocking
 * sd_write_pause(true) returns, specifically to notice a resume that landed during the
 * wait. A cached pre-call value would defeat that re-read — sd_write_pause() lives in
 * another translation unit but this static's address is never taken, so the compiler is
 * free to assume the call cannot touch it. (main.c's LED loop and aad_is_recording()
 * read it too.) Aligned byte loads/stores are atomic on this Cortex-M33, so plain
 * volatile is sufficient. */
static volatile bool vad_is_recording = false;
static bool vad_sleeping = false;
static uint16_t vad_voice_streak = 0;
static int64_t vad_last_voice_ms = 0;
static int64_t vad_next_status_ms = 0;

/* Peak-hold window for DIAG_VAD_LEVEL. Only ever touched from aad_process_audio()
 * on the mic thread, so no atomics needed. next_ms == 0 means "window not started";
 * the first processed frame arms it. vad_diag_level_was_silent starts true so the
 * first non-silent window after boot emits — that record is the healthy baseline,
 * and without it a log that opens mid-outage has nothing to compare against. */
static int64_t vad_next_diag_level_ms = 0;
static int64_t vad_diag_level_heartbeat_ms = 0;
static uint16_t vad_diag_level_max = 0;
static uint16_t vad_diag_level_min = UINT16_MAX;
static bool vad_diag_level_was_silent = true;

/* ---- Pre-roll ring buffer ---- */
/* 8 frames * 100 ms/frame ~= 0.8 s pre-roll.
 *
 * DEPTH IS COUPLED TO THE BUTTON FSM — do not shrink it without reading this.
 * button.c dispatches a tap action only after MULTI_TAP_WINDOW (600 ms) of idle
 * following the release, because until then the gesture might still become a
 * double-tap. Add the press itself and the 40 ms poll granularity and record_start()
 * runs ~700 ms after the user's finger goes down. Pre-roll is what puts those 700 ms
 * into the recording, so a button-started recording begins where the press did rather
 * than where the firmware caught up. 8 frames covers it with ~100 ms to spare; 4
 * would silently clip the front of every button-initiated recording.
 *
 * It does NOT cover a record action mapped to a HOLD: those dispatch at HOLD_TIME
 * (1000 ms), so the ring has already rolled ~200 ms past the press. That is not a
 * regression from pre-arm — before it, the mic ran continuously and the ring still
 * held only the most recent 800 ms at dispatch, i.e. the same window. Deepening it now
 * costs ~3.2 KB per added frame rather than the ~6.4 KB it did when a second ring of
 * the same depth shadowed this one, so the RAM argument against it is weaker than it
 * was; the reason it stays is that the default configs put record actions on taps, not
 * holds. */
#define VAD_PREROLL_FRAMES 8
static int16_t vad_preroll_buf[VAD_PREROLL_FRAMES][MIC_BUFFER_SAMPLES];
static uint8_t vad_preroll_wr = 0;
static uint8_t vad_preroll_cnt = 0;
/* Pre-roll frames dropped by preroll_queue_flush()'s trim, i.e. lead-in audio the encoder
 * ring had no room for. Rides DIAG_WRITE_BLOCKED's arg1 rather than 0x0062, whose payload
 * is full at 100 B. Mic thread only. */
static uint32_t vad_preroll_trim_drops;

#define VAD_STATUS_LOG_INTERVAL_MS 2000

/* Diagnostic level reporting (DIAG_VAD_LEVEL): a 5-minute peak-hold, emitted on a
 * signal CHANGE or once an hour, whichever comes first.
 *
 * Peak-hold rather than sample, because it makes the emit rate irrelevant to the
 * question being asked. A wedged mic (digital-zero PDM output) reports max == 0 for
 * every window no matter when you look; a genuinely quiet room always catches
 * SOMETHING over five minutes — a door, a keystroke, movement — so max climbs clear
 * of zero even when it never reaches the recording threshold. An instantaneous
 * sample confuses the two whenever it lands in a silent gap, which is exactly the
 * ambiguity that left the 2026-08-02 mic outage un-diagnosable from logs.
 *
 * Change-driven rather than periodic, because the ring is only 128 records deep and
 * shared with every other event. Emitting every window would cost ~12 records/hour
 * and evict everything rarer within ~10 h — including the boot-time bond records
 * that diag_log_event_forced() exists to preserve. Two instrumentation changes
 * fighting each other is worse than either alone. The transition into (or out of) a
 * silent window is the whole alarm; the hourly heartbeat is what proves the state
 * persisted and gives a healthy baseline to compare against. Steady state is ~1
 * record/hour whether the mic is fine or wedged. */
#define VAD_DIAG_LEVEL_WINDOW_MS 300000
#define VAD_DIAG_LEVEL_HEARTBEAT_MS 3600000

/* ---- Helpers ---- */

static void preroll_reset(void)
{
    vad_preroll_wr = 0;
    vad_preroll_cnt = 0;
}

static void preroll_store(const int16_t *buf)
{
    memcpy(vad_preroll_buf[vad_preroll_wr], buf, sizeof(vad_preroll_buf[0]));
    vad_preroll_wr = (vad_preroll_wr + 1) % VAD_PREROLL_FRAMES;
    if (vad_preroll_cnt < VAD_PREROLL_FRAMES) {
        vad_preroll_cnt++;
    }
}

/* Submit the whole pre-roll ring to the encoder in one burst, at the RECORDING
 * transition, and be done with it.
 *
 * The paced version of this — queue the frames, then feed one per 100 ms mic
 * callback while parking each arriving live frame in a second ring — is what this
 * replaces, and the pacing was the bug. The encoder consumes exactly one frame per
 * callback, so a one-in-one-out drain never catches up: the holding ring settled at
 * its full 8 frames and STAYED there for the whole recording, leaving the encoder
 * permanently 0.8 s behind the mic. Every path that ends a recording then reset that
 * ring, so all four of them silently dropped the last 0.8 s — including the deliberate
 * stop in aad_set_threshold(), where the discarded audio is the user still talking as
 * they press the button. Bursting removes the lag instead of trying to drain it later,
 * which is the only way to fix it at the stop: by then the 0xFFFFFFFC has already
 * overtaken any audio still in the pipeline (the marker is written straight into
 * storage_temp_data, audio has to clear the encoder and the tx ring first), SD writes
 * are being paused by the same finalize, and the app drops post-0xFFFFFFFC frames
 * outright (_sessionEndPendingResume). Nothing is left in flight at a stop now, so
 * none of that has to be solved.
 *
 * Bursting is safe HERE specifically, and not in general: this runs only when the VAD
 * was asleep, and a sleeping VAD feeds the encoder nothing (aad_process_audio() returns
 * false before mic_handler() reaches codec_receive_pcm()), so the ring has been draining
 * with no producer for at least the silence hold. It is empty by construction. The
 * space check below is the belt to that braces — a stop-then-restart can re-trigger
 * 300 ms after a finalize, which is ample for the encoder but not a proof.
 *
 * Ordering is unchanged from the paced version: oldest pre-roll frame first, and the
 * live frame this callback is holding goes in behind them via mic_handler()'s own
 * codec_receive_pcm(). Hence the one-frame reservation. */
static void preroll_queue_flush(void)
{
    if (vad_preroll_cnt == 0) {
        return;
    }

    /* preroll_store() caps the count at the ring depth, so this is <= VAD_PREROLL_FRAMES. */
    uint8_t frames_to_flush = vad_preroll_cnt;

    /* Trim to what the encoder ring will actually take, keeping the NEWEST frames:
     * codec_receive_pcm() rejects a block whole, so an overrun would drop the tail of
     * the burst — the frames immediately adjacent to the live audio that follows — and
     * punch a hole in the middle of the recording. Dropping from the head instead just
     * shortens the lead-in, which is what a short pre-roll already looks like.
     *
     * One frame is held back for the live buffer mic_handler() submits when this
     * callback returns true. Racing this read is not possible in the direction that
     * matters: the encoder thread is the ring's only consumer and the mic thread its
     * only producer, so between here and the pushes below the free space can only
     * grow. */
    size_t room_frames = codec_pcm_space_get() / (MIC_BUFFER_SAMPLES * sizeof(int16_t));
    room_frames = (room_frames > 0) ? (room_frames - 1) : 0;
    if (frames_to_flush > room_frames) {
        frames_to_flush = (uint8_t) room_frames;
    }

    uint8_t dropped = vad_preroll_cnt - frames_to_flush;
    uint8_t rd = (uint8_t) ((vad_preroll_wr + VAD_PREROLL_FRAMES - frames_to_flush) % VAD_PREROLL_FRAMES);

    for (uint8_t i = 0; i < frames_to_flush; i++) {
        /* Trimmed to fit above, so this should not fail. If it does, stop rather than
         * skip: the frames after it are the ones adjacent to the live audio, and
         * submitting them around a hole is worse than a shorter lead-in. The rejected
         * frame is counted by codec_receive_pcm() itself (DIAG_CODEC_DROP); the ones
         * abandoned by the break are folded into `dropped` and counted below, so the
         * whole loss is accounted for either way. */
        if (codec_receive_pcm(vad_preroll_buf[rd], MIC_BUFFER_SAMPLES) != 0) {
            LOG_ERR("VAD: pre-roll burst rejected at %u/%u", i, frames_to_flush);
            dropped = (uint8_t) (vad_preroll_cnt - i);
            break;
        }
        rd = (uint8_t) ((rd + 1) % VAD_PREROLL_FRAMES);
    }

    LOG_INF("VAD: burst %u/%u pre-roll frame(s), dropped %u", frames_to_flush, vad_preroll_cnt, dropped);

    if (dropped > 0) {
        /* The trim above discards captured audio, and it does so BEFORE any push — so
         * codec_receive_pcm() is never called for those frames and codec_drops cannot
         * move. Without this record the loss is invisible on a shipped device: CONFIG_LOG
         * is unset, so the LOG_INF right above compiles out entirely. Instrumenting it
         * here is what keeps "the tx ring is the only uncounted audio-discard site" true
         * (see write_to_tx_queue) rather than quietly opening a second one.
         *
         * Rate-limited to 1/s in the same shape as the sites it replaces: this fires at
         * most once per recording start, but a persistently starved encoder would trim
         * every start and evict a 128-slot ring shared with everything else. arg1 carries
         * the running total, so the lost detail is only the timing of repeats. Mic thread
         * only, so the statics need no lock. */
        static int64_t last_trim_log_ms;
        vad_preroll_trim_drops += dropped;
        int64_t now_trim = k_uptime_get();
        if (last_trim_log_ms == 0 || (now_trim - last_trim_log_ms) >= 1000) {
            last_trim_log_ms = now_trim;
            diag_log_event(DIAG_WRITE_BLOCKED, 0, DIAG_WRITE_BLOCKED_PREROLL_TRIMMED, vad_preroll_trim_drops);
        }
    }

    vad_preroll_wr = 0;
    vad_preroll_cnt = 0;
}

static uint32_t avg_abs_amplitude(const int16_t *buf, size_t n)
{
    if (n == 0) {
        return 0;
    }
    uint64_t sum = 0;
    for (size_t i = 0; i < n; i++) {
        int32_t s = buf[i];
        sum += (uint32_t) (s < 0 ? -s : s);
    }
    return (uint32_t) (sum / n);
}

/* ---- Idle advertising backstop ---- */

/* Advertising comes up FAST at boot (transport.c adv_active_mode) and is reset to
 * FAST on every disconnect, but the only paths that ever ask for the 1 s SLOW
 * interval are the VAD-sleep transition and aad_set_threshold()'s finalize — both of
 * which require a recording to have happened first. So a device that boots into a
 * quiet room, or disconnects while parked in manual standby, advertises on the
 * 100-150 ms interval indefinitely: ~300-500 uA for nothing (see adv_param_slow).
 * This is the backstop for both. Not a replacement for the VAD-sleep request, which
 * is faster and covers the ordinary auto-mode case.
 *
 * 60 s rather than the VAD hold: a device that just booted or just dropped its link
 * is the most likely to be about to be discovered, and fast advertising is what makes
 * that quick. A minute of it costs nothing; a day of it is the bug. */
#define ADV_IDLE_SLOW_DELAY_MS (60 * 1000)

static void adv_idle_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    /* An active recording wants to stay findable so the phone can sync it — the same
     * reason the VAD resume path asks for FAST. */
    if (vad_is_recording || vad_threshold == 65535) {
        return;
    }
    atomic_set(&adv_slow_req, 1);
    k_sem_give(&aad_sem);
}
K_WORK_DELAYABLE_DEFINE(adv_idle_work, adv_idle_work_handler);

void aad_note_link_idle(void)
{
    /* Called from the BT RX thread on disconnect — schedule only, no locks, no radio
     * calls (see the adv_mutex note in transport.c). */
    k_work_reschedule(&adv_idle_work, K_MSEC(ADV_IDLE_SLOW_DELAY_MS));
}

/* ---- Mic gate ---- */

/* Manual standby (threshold 32769) is the one state where the mic's output is
 * provably unused: has_voice can only become true via the 65535 always-record
 * sentinel or a button force-wake, and avg|PCM| can never reach 32769 (the largest
 * possible mean of |int16| is 32768). So the PDM peripheral, the HFXO it holds up
 * and both mics are pure load there, all day, in a mode that is the app default.
 *
 * The gate is DERIVED, never commanded. Every producer of "should we be recording"
 * lands on aad_set_threshold() — the button, a BLE write from the app, the boot
 * restore in aad_start(), the priority safety cap — so reconciling here covers all
 * of them at once. A caller that flipped the mic itself would fix its own path and
 * leave the other four wrong, two of them in the direction that records silence.
 *
 * THIS IS NOT THE PDM_EN RAIL. It is dmic STOP/START, the same mechanism mute has
 * used on every toggle for the life of the project (button.c mute_apply). Nothing
 * here touches P1.4 — see mic.c's pdm_en comment and IDEAS.md "Mic rail (PDM_EN) is
 * not driven by firmware" for why that pin stays undriven, and do not "improve" this
 * by power-cycling the rail.
 *
 * Taken under mic_state_lock because is_muted and mic_running must agree: without
 * it, a mute landing between the read and the resume leaves capture running on a
 * muted device (mic.h documents this exact hazard). Never called while holding a
 * marker write — the lock must not queue behind SD I/O. */

/* The whole gate, in one expression. Every input is here so no call site has to
 * remember a special case:
 *   - muted                        -> never capture, whatever else is true
 *   - threshold != 32769           -> auto mode, or manual actively recording
 *   - force-wake window open       -> a marker tap force-captures for 50 s without
 *                                     ever changing the threshold
 *   - pre-arm                      -> a button interaction is in flight and we do
 *                                     not yet know whether it will start a
 *                                     recording; see aad_set_mic_prearm() */
static bool mic_should_run(void)
{
    if (is_muted) {
        return false;
    }
    if (vad_threshold != 32769) {
        return true;
    }
    if (k_uptime_get() < force_wake_until_ms) {
        return true;
    }
    return atomic_get(&mic_prearm) != 0;
}

void aad_apply_mic_gate(void)
{
    /* Before mic_start() there is no device to gate, and the resume branch below
     * would report the no-op as DIAG_MIC_STATE_RESUME_FAILED — a fault record for a
     * mic that simply does not exist yet. Reachable: transport_start() precedes
     * mic_start(), so a BLE threshold write can land here first. aad_start() runs
     * after mic_start() and re-applies the gate, so nothing is lost by skipping. */
    if (!mic_is_ready()) {
        return;
    }

    k_mutex_lock(&mic_state_lock, K_FOREVER);
    const bool want = mic_should_run();
    const bool running = mic_is_running();

    if (!want && running) {
        mic_pause();
        /* Parking leaves the same unbounded hole in the audio that a mute does, so
         * the resumption has to re-anchor the app's timeline and drop the stale
         * pre-roll the same way. It also stops the DIAG_VAD_LEVEL window advancing,
         * which would otherwise close on the first frame back and report a stale
         * zero peak — a parked mic reading as a wedged one. */
        aad_note_capture_gap();
        diag_log_event(DIAG_MIC_STATE, 0, DIAG_MIC_STATE_PARKED, vad_threshold);
        /* Nothing will produce a mic frame until the gate reopens, so the VAD-sleep
         * transition that normally drops advertising to the 1 s interval can never
         * fire from here on. Ask for it now or the radio stays on the 100-150 ms
         * fast interval for the whole standby — ~300-500 uA (see adv_param_slow). */
        atomic_set(&adv_slow_req, 1);
        k_sem_give(&aad_sem);
    } else if (want && !running) {
        mic_resume();
        /* A failed dmic START would otherwise leave manual mode recording nothing,
         * and silently: mic_resume() reports only through LOG_ERR, and CONFIG_LOG is
         * compiled out. One retry covers a transient failure. */
        if (!mic_is_running()) {
            mic_resume();
        }
        if (mic_is_running()) {
            diag_log_event(DIAG_MIC_STATE, 0, DIAG_MIC_STATE_RESUMED, vad_threshold);
            /* Arm the "did audio actually come back" probe. A START that returns 0
             * but yields digital silence (wedged T5838) is invisible otherwise, and
             * the cost of missing it is a whole recording of nothing. */
            /* Level first, count second: the mic thread gates on the count, so arming
             * it last means no frame can be sampled against a level that is about to
             * be cleared. (The reverse order could only lose one frame's OR, and a
             * false RESUMED_SILENT would still need the next four frames to be
             * digital zero -- i.e. a genuinely wedged part -- but the ordering costs
             * nothing and removes the argument.) */
            atomic_set(&mic_verify_level, 0);
            atomic_set(&mic_verify_frames, MIC_VERIFY_FRAMES);
        } else {
            diag_log_event(DIAG_MIC_STATE, 0, DIAG_MIC_STATE_RESUME_FAILED, vad_threshold);
        }
    }
    k_mutex_unlock(&mic_state_lock);
}

/* A button interaction has started (or ended). The FSM cannot know for ~700 ms
 * whether a press is a record-start — it has to wait out MULTI_TAP_WINDOW to rule
 * out a second tap — and with the mic parked those 700 ms would be missing from the
 * front of the recording. Waking on the press edge means pre-roll has already
 * collected them by the time record_start() runs, so a manual recording still begins
 * where the user's finger did. The matching false at the FSM's return to idle parks
 * again if nothing asked for capture. */
void aad_set_mic_prearm(bool on)
{
    atomic_set(&mic_prearm, on ? 1 : 0);
    aad_apply_mic_gate();
}

void aad_note_capture_gap(void)
{
    atomic_set(&capture_gap_pending, 1);
}

/* ---- WAKE pin ISR ---- */

static void wake_pin_isr(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    ARG_UNUSED(dev);
    ARG_UNUSED(cb);
    ARG_UNUSED(pins);

    atomic_set(&wake_pending, 1);
    k_sem_give(&aad_sem);
}

/* ---- Handler thread (SD suspend / resume) ---- */

static void aad_thread_fn(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    LOG_INF("AAD handler thread running");

    while (1) {
        /* K_FOREVER, not a poll. Every producer of the four flags read below signals
         * this semaphore in the same breath as its atomic_set — the WAKE ISR, both
         * advertising-mode requests, and all three SD pause/resume posts — so a
         * timeout could only ever wake this thread to find nothing to do. The
         * limit-1 semaphore cannot drop an event either: a single pass services all
         * four flags, so gives that coalesce still leave every flag handled.
         * Anything added here later MUST signal the same way or it will never run.
         *
         * This costs no latency: the ISR's k_sem_give is what released this thread
         * before, not the timeout. And it is nowhere near the audio path — capture
         * and the pre-roll ring belong to the mic thread (mic.c
         * process_audio_buffer -> aad_process_audio), never to this one. */
        k_sem_take(&aad_sem, K_FOREVER);

        /* WAKE event from ISR */
        if (atomic_cas(&wake_pending, 1, 0)) {
            atomic_set(&wake_consumed, 1);
            last_hw_wake_ms = k_uptime_get();
            LOG_INF("AAD: WAKE detected");
        }

        int pause_cmd = atomic_cas(&sd_pause_pending, 1, 0) ? 1 : atomic_cas(&sd_pause_pending, 2, 0) ? 2 : 0;
        if (pause_cmd == 1) {
            /* Honor a queued pause only when NOT force-capturing. A RECORD_START that
             * raced a just-queued silence pause (sd_pause_pending=1, not yet applied
             * by this handler) has since set vad_threshold=65535; applying that stale
             * pause now would re-pause SD writes and the still-paused SD worker would
             * silently drop the 0xFFFFFFF8 priority marker and first audio frames at
             * the sd_write_paused gate (sd_card.c). We never want to pause mid
             * force-capture anyway, so skip it; the next real silence re-queues a pause
             * once force-capture ends and vad_threshold drops back below 65535. */
            if (vad_threshold != 65535) {
                sd_write_pause(true);
                /* The check above and this apply are not atomic with record_start()
                 * on the button thread: it may have entered force-capture
                 * (vad_threshold=65535) in between, so the pause we just applied would
                 * land after record_start()'s own sd_write_pause(false) and strand the
                 * 0xFFFFFFF8 marker. Re-read and undo if so. Between this re-check and
                 * record_start()'s sd_write_pause(false), one of the two clears the
                 * flag in every interleaving, so writes are always enabled once
                 * force-capture is on.
                 *
                 * vad_is_recording covers the SAME hazard from the MIC thread, and the
                 * window is far wider than the button one: sd_write_pause(true) sets the
                 * flag before it queues REQ_PAUSE_IO and then waits on the worker for up
                 * to 10.5 s, and any silence→speech transition in that span runs its own
                 * inline sd_write_pause(false) BEFORE ours — so ours wins and buries a
                 * live recording behind a closed gate. Testing the threshold alone missed
                 * it entirely: a priority stop restores an AUTO threshold (250), so the
                 * 65535 test is false in exactly the case that matters. Pausing while the
                 * VAD holds a recording open is never right regardless of how it arose,
                 * which is why the condition is the recording state and not a list of
                 * racing callers. */
                if (vad_threshold == 65535 || vad_is_recording) {
                    sd_write_pause(false);
                }
            } else {
                LOG_INF("AAD: pause skipped (force-capture active)");
            }
        } else if (pause_cmd == 2) {
            sd_write_pause(false);
        }

        if (atomic_cas(&adv_slow_req, 1, 0))
            transport_set_adv_slow();
        if (atomic_cas(&adv_fast_req, 1, 0))
            transport_set_adv_fast();

#ifdef CONFIG_LSM6DSL
        /* LAST in the pass, deliberately: this is slower than everything above it by
         * orders of magnitude, so a pause/resume or advertising change posted in the
         * same breath is serviced before it rather than behind it.
         *
         * It cannot delay a resume either. The resume path clears the SD pause INLINE
         * (see the 0xFFFFFFFD write above) precisely because the async one is too slow
         * to be trusted with it; what is posted here is the idempotent backstop. */
        if (atomic_cas(&imu_checkpoint_pending, 1, 0)) {
            lsm6dsl_time_prepare_for_system_off();
        }
#endif
    }
}

/* ================================================================
 * Public API
 * ================================================================ */

bool aad_process_audio(int16_t *buffer, size_t sample_count)
{
    /* WAKE pin event -> reset VAD debounce.
     * Force-wake (button press) sets force_wake_until_ms; hardware acoustic
     * WAKE does not.  Don't stop an active recording on a button press — only
     * the hardware T5838 WAKE (silence → acoustic activity) needs a full reset. */
    /* Capture stopped for an unknown wall-clock span (mute) and has just resumed.
     * Park the VAD so the next speech takes the normal RECORDING path and emits a
     * 0xFFFFFFFD resume packet — that packet is what re-anchors the app's frame
     * timeline. Without it the app keeps counting 20 ms per frame straight across
     * the gap, so everything after an unmute is stamped early by the whole mute
     * duration (up to the next bin, whose timerStart re-anchors it anyway).
     * preroll_reset() matters as much: the ring still holds frames from before the
     * mute, and a re-trigger would replay that stale audio into the new recording. */
    if (atomic_cas(&capture_gap_pending, 1, 0)) {
        vad_is_recording = false;
        vad_sleeping = true;
        vad_voice_streak = 0;
        preroll_reset();
        /* Re-arm the diagnostic level window rather than closing a window that has
         * been open across the gap: its peak stopped accumulating when the frames
         * did, so a stale zero would emit as DIAG_VAD_LEVEL "silent" and read as a
         * wedged mic. Zero means "not started"; the next frame arms it. */
        vad_next_diag_level_ms = 0;
        vad_diag_level_max = 0;
        vad_diag_level_min = UINT16_MAX;
    }

    /* Deferred pre-roll reset from a recording ended on another thread. Consumed here,
     * ahead of every reader and writer of the ring in this function — including the
     * preroll_queue_flush() below, which must not burst frames belonging to the
     * recording that just ended into the one about to start. A capture gap above has
     * already done this, so the two coalesce harmlessly. */
    if (atomic_cas(&replay_reset_pending, 1, 0)) {
        preroll_reset();
    }

    if (atomic_cas(&wake_consumed, 1, 0)) {
        int64_t now_wake = k_uptime_get();
        vad_voice_streak = 0;
        vad_last_voice_ms = now_wake;
        if (now_wake >= force_wake_until_ms) {
            vad_is_recording = false;
            /* Every site that ends a recording clears the pre-roll with it, so the
             * next recording's burst carries only audio from its own lead-in. The ring
             * stops collecting while vad_is_recording is set, so without this it would
             * still hold frames from before the recording that just ended — 1m48s old
             * in the 2026-09-05 reproduction. The VAD-sleep and capture-gap paths
             * already did; this one and aad_set_threshold()'s finalize did not. */
            preroll_reset();
        }
        LOG_INF("AAD: WAKE, VAD reset (force=%s)", now_wake < force_wake_until_ms ? "y" : "n");
    }

    uint32_t avg = avg_abs_amplitude(buffer, sample_count);
    int64_t now = k_uptime_get();

    /* Liveness: stamped every frame, so "mic delivering?" is nowUptimeMs minus this,
     * with no reference to the event log at all. */
    mic_last_frame_uptime_ms = (uint32_t) now;

    /* Post-resume probe: OR the level across the first frames after a START. A
     * wedged T5838 returns digital zero, which a quiet room never does. */
    if (atomic_get(&mic_verify_frames) > 0) {
        atomic_or(&mic_verify_level, (atomic_val_t) avg);
        if (atomic_dec(&mic_verify_frames) == 1 && atomic_get(&mic_verify_level) == 0) {
            /* Every sample of MIC_VERIFY_FRAMES frames was zero. */
            diag_log_event(DIAG_MIC_STATE, 0, DIAG_MIC_STATE_RESUMED_SILENT, vad_threshold);
        }
    }
    /* 65535 = active manual recording (always-voice); 32769 = manual standby.
     * button.c reads the threshold back to distinguish manual vs. marker taps. */
    bool has_voice = vad_threshold == 65535 || avg >= vad_threshold || now < force_wake_until_ms;

    if (has_voice) {
        vad_last_voice_ms = now;
        if (!vad_is_recording) {
            vad_voice_streak++;
            if (vad_voice_streak >= CONFIG_OMI_VAD_DEBOUNCE_FRAMES) {
                vad_is_recording = true;
                vad_sleeping = false;

                /* Write VAD-resume timestamp into the audio stream so the app
                 * can recalibrate frame times after a silence gap. */
                uint8_t vad_ts_buf[16] = {0};
                uint32_t utc = get_utc_time();
                uint64_t up = (uint64_t) k_uptime_get();
                memcpy(vad_ts_buf, &utc, 4);
                memcpy(vad_ts_buf + 4, &up, 4);
                /* SD writes are still paused from the silence gap. The resume
                 * request below (sd_pause_pending=2) is handled asynchronously by
                 * the AAD thread, so without this the marker would be enqueued and
                 * then dropped by the still-paused SD worker (same hazard the
                 * button-tap marker hit). Clear the pause flag inline first — on the
                 * resume side sd_write_pause() is just a non-blocking atomic set —
                 * so this resume packet is durable. The async resume below is left
                 * as a harmless idempotent backstop. */
                sd_write_pause(false);
                write_custom_packet_to_storage(0xFFFFFFFD, vad_ts_buf, 16, true);

                /* AFTER the two lines above, both of which it now depends on, and this
                 * is the whole reason the burst is placed here rather than at the top of
                 * the branch where the queueing version sat.
                 *
                 * After sd_write_pause(false): the queueing version put no audio into the
                 * encoder at all — the first frame went in at the BOTTOM of this same
                 * callback, by which point the pause was already cleared. A burst placed
                 * where that queue call was would hand the encoder 0.8 s of audio while
                 * sd_write_paused is still set, and the pause gate (sd_card.c) discards
                 * any block that carries no marker — silently, since a rescue only fires
                 * for marker-bearing blocks. The whole pre-roll would go in the bin.
                 *
                 * After the 0xFFFFFFFD write: that marker goes straight into
                 * storage_temp_data while audio has to clear the encoder and the tx ring,
                 * so the marker reaches the file first either way. Ordering it explicitly
                 * keeps the bin layout identical to the paced version ([0xFFFFFFFD]
                 * [pre-roll][live]) rather than resting on the mic thread outrunning the
                 * encoder — which it does, at priority 5 against the encoder's 7, but that
                 * is a scheduling accident and not something to encode a file format in.
                 *
                 * A stop landing around here still beats the burst to the card, and no
                 * ordering available on this thread fixes it. The system workqueue runs at
                 * -1 (cooperative), so a BUTTON stop preempts this thread outright, between
                 * any two instructions; an APP stop arrives on BT RX at 8 and cannot preempt
                 * us, but lands just as well while these blocks are still crossing the
                 * encoder and the tx ring, because the 0xFFFFFFFC goes straight into
                 * storage_temp_data and skips both. Either way the app discards the burst
                 * (_sessionEndPendingResume). It costs the same 8 frames the paced version
                 * lost to the same race — there the finalize's reset cleared the pending
                 * replay instead — so this is not a regression. See NOTES.md, "A stop that
                 * lands around the burst"; the three reasons it cannot be closed here are
                 * written up there. */
                preroll_queue_flush();

                atomic_set(&sd_pause_pending, 2);
                atomic_set(&adv_fast_req, 1);
                k_sem_give(&aad_sem);
                LOG_INF("VAD: RECORDING (avg=%u, utc=%u)", avg, utc);
            }
        }
    } else {
        vad_voice_streak = 0;
        if (vad_is_recording) {
            int64_t silent_ms = now - vad_last_voice_ms;
            if (silent_ms >= CONFIG_OMI_VAD_HOLD_MS) {
                vad_is_recording = false;
                vad_sleeping = true;

#ifdef CONFIG_LSM6DSL
                /* Checkpoint the RTC vs IMU timestamp so a reboot during silence can
                 * recover the lost wall-clock. Posted, not called: see
                 * imu_checkpoint_pending. The k_sem_give below is the one that carries
                 * it, so this must stay above it. Deferring cannot skew the result —
                 * the checkpoint stores a (UTC, IMU counter) PAIR sampled together, so
                 * a pair taken a few ms later is equally valid. */
                atomic_set(&imu_checkpoint_pending, 1);
#endif

                atomic_set(&sd_pause_pending, 1);
                atomic_set(&adv_slow_req, 1);
                k_sem_give(&aad_sem);
                LOG_INF("VAD: SLEEP (silent %lld ms)", silent_ms);
                preroll_reset();
                /* Re-arm the gate. In manual standby this is what stops the mic
                 * again after a marker tap's force-wake window expires — the
                 * threshold never changed, so aad_set_threshold() will not run.
                 * A no-op in auto mode (mic_resume on a running mic). */
                aad_apply_mic_gate();
            }
        }
    }

    /* Periodic status log */
    if (now >= vad_next_status_ms) {
        LOG_INF("VAD: %s (avg=%u thr=%u deb=%u hold=%d)",
                vad_is_recording ? "REC" : "SLEEP",
                avg,
                vad_threshold,
                CONFIG_OMI_VAD_DEBOUNCE_FRAMES,
                CONFIG_OMI_VAD_HOLD_MS);
        vad_next_status_ms = now + VAD_STATUS_LOG_INTERVAL_MS;
    }

    /* Capture duty: the time the VAD holds a recording open, against uptime, is what
     * the auto-mode threshold actually costs. sample_count/16 = ms at the fixed 16 kHz
     * rate.
     *
     * It is NOT a measure of audio reaching the card, and must never be read as one.
     * It is stamped on vad_is_recording alone, upstream of every place a frame can still
     * die — codec_receive_pcm() rejecting a block, the tx ring being full, the SD pause
     * gate. 100 % duty over a bin holding no audio at all is exactly what the 2026-09-05
     * wedge produced, and reading duty as capture is what sent that investigation
     * downstream of the real fault. The wedge itself is gone (the holding ring it lived
     * in no longer exists), but the gap between this number and bytes on the card is
     * structural, not a property of that bug. */
    if (vad_is_recording) {
        vad_voiced_ms += (uint32_t) (sample_count / 16);
    }

    /* Peak-hold the input level between diagnostic emissions (see
     * VAD_DIAG_LEVEL_WINDOW_MS). Saturate at UINT16_MAX so a full-scale frame
     * can't wrap arg0 and read as silence — the one value we must never fake. */
    uint16_t avg_u16 = (avg > UINT16_MAX) ? UINT16_MAX : (uint16_t) avg;
    if (avg_u16 > vad_diag_level_max) {
        vad_diag_level_max = avg_u16;
    }
    if (avg_u16 < vad_diag_level_min) {
        vad_diag_level_min = avg_u16;
    }
    if (vad_next_diag_level_ms == 0) {
        /* First frame after boot: start the window here rather than closing one on a
         * single sample. */
        vad_next_diag_level_ms = now + VAD_DIAG_LEVEL_WINDOW_MS;
        vad_diag_level_heartbeat_ms = now + VAD_DIAG_LEVEL_HEARTBEAT_MS;
    } else if (now >= vad_next_diag_level_ms) {
        /* A window whose PEAK is zero means the mic produced literal digital silence
         * for five minutes — not a quiet room, which always peaks above zero. */
        bool silent = (vad_diag_level_max == 0);
        if (silent != vad_diag_level_was_silent || now >= vad_diag_level_heartbeat_ms) {
            /* arg1 packs the window minimum above the threshold in force, so a reader
             * can tell "quiet room under a high threshold" from "no signal at all"
             * without cross-referencing a second event. */
            diag_log_event(DIAG_VAD_LEVEL,
                           0,
                           vad_diag_level_max,
                           ((uint32_t) vad_diag_level_min << 16) | (uint32_t) vad_threshold);
            vad_diag_level_heartbeat_ms = now + VAD_DIAG_LEVEL_HEARTBEAT_MS;
        }
        vad_diag_level_was_silent = silent;
        vad_diag_level_max = 0;
        vad_diag_level_min = UINT16_MAX;
        vad_next_diag_level_ms = now + VAD_DIAG_LEVEL_WINDOW_MS;
    }

    if (!vad_is_recording) {
        preroll_store(buffer);
        return false;
    }

    /* Straight through to the encoder. The pre-roll was already submitted in full at
     * the RECORDING transition (preroll_queue_flush), so there is no replay state to
     * interleave with and no holding ring for this frame to wait in — the two branches
     * that used to stand here, and the 2026-09-05 wedge that lived in the first of
     * them, are gone rather than guarded. See NOTES.md. */
    return true;
}

void aad_force_wake(void)
{
    force_wake_until_ms = k_uptime_get() + FORCE_WAKE_HOLD_MS;
    /* The window is an input to mic_should_run(), so this reopens the gate in manual
     * standby (where the threshold does not change and the mic would otherwise stay
     * parked through the whole marker window). The VAD-sleep path re-applies the gate
     * once the window expires; muted stays muted, because the gate says so. */
    aad_apply_mic_gate();
    atomic_set(&wake_pending, 1);
    k_sem_give(&aad_sem);
    LOG_INF("AAD: force wake (hold %d ms)", FORCE_WAKE_HOLD_MS);
}

int aad_start(void)
{
    int ret;

    if (!gpio_is_ready_dt(&pin_wake)) {
        LOG_ERR("AAD: WAKE gpio not ready");
        return -ENODEV;
    }

    ret = gpio_pin_configure_dt(&pin_wake, GPIO_INPUT | GPIO_PULL_DOWN);
    if (ret) {
        LOG_ERR("AAD: WAKE pin config failed (%d)", ret);
        return ret;
    }

    gpio_init_callback(&wake_cb_data, wake_pin_isr, BIT(pin_wake.pin));
    ret = gpio_add_callback(pin_wake.port, &wake_cb_data);
    if (ret) {
        LOG_ERR("AAD: WAKE callback failed (%d)", ret);
        return ret;
    }

    ret = gpio_pin_interrupt_configure_dt(&pin_wake, GPIO_INT_EDGE_RISING);
    if (ret) {
        LOG_ERR("AAD: WAKE IRQ config failed (%d)", ret);
        return ret;
    }

    vad_threshold = app_settings_get_vad_threshold();
    /* Boot restore: the threshold is persisted, so a device that was left in manual
     * standby comes up in it and must come up with the mic parked. main() has
     * already run mic_start() and reconciled is_muted by this point. */
    aad_apply_mic_gate();
    /* And arm the idle-advertising backstop for the boot case. */
    aad_note_link_idle();

    aad_tid = k_thread_create(&aad_thread_data,
                              aad_stack,
                              K_THREAD_STACK_SIZEOF(aad_stack),
                              aad_thread_fn,
                              NULL,
                              NULL,
                              NULL,
                              AAD_THREAD_PRIORITY,
                              0,
                              K_NO_WAIT);
    k_thread_name_set(aad_tid, "aad");

    LOG_INF("AAD: started (WAKE=P1.%d, thr=%d deb=%d hold=%d)",
            pin_wake.pin,
            vad_threshold,
            CONFIG_OMI_VAD_DEBOUNCE_FRAMES,
            CONFIG_OMI_VAD_HOLD_MS);
    return 0;
}

void aad_set_threshold(uint16_t threshold)
{
    uint16_t prev = vad_threshold;

    /* Cleanly finalize the active recording the moment a deliberate threshold
     * change ends it: emit a session-end marker so the app finalizes the
     * recording at this boundary, then end the recording immediately. Without
     * the immediate state flip the normal VAD-hold tail (CONFIG_OMI_VAD_HOLD_MS)
     * would leak ~10 s of post-stop audio into the bin and produce a spurious
     * short recording. Marker first, then state flip, so the marker lands inside
     * the active recording region while AAD frames are still flowing.
     *
     * Two finalize cases (an auto→auto sensitivity tweak, e.g. 250→300, matches
     * neither, so it never interrupts an active recording):
     *   - prev == 65535  → leaving manual/priority always-record (button stop,
     *                      BLE push, or manual→auto switch). Emitted UNCONDITIONALLY
     *                      (see below) — a stop must always leave a marker.
     *   - threshold == 32769 while recording → entering manual standby mid
     *                      auto-recording (the app's "switch to Manual Mode"
     *                      toggle); finalize the in-progress auto recording at the
     *                      mode boundary rather than letting it bleed out over the
     *                      VAD-hold tail. */
    /* Leaving always-record (a manual or priority-recording button/BLE stop, or
     * a manual->auto switch) MUST emit the session-end marker unconditionally —
     * NOT gated on vad_is_recording. A WAKE event handled by aad_process_audio the
     * instant the stop lands can clear vad_is_recording (see the WAKE-consumed path
     * above); with the old gate the counter still incremented (button.c bumps it
     * before this call) but the 0xFFFFFFFC was never even enqueued, so the app never
     * closed its priority latch and force-captured every following auto recording
     * into one runaway span. marker_write_drops stayed 0 because nothing was queued
     * to drop. prev == 65535 means force-capture WAS active, so a marker here is
     * always correct; the healthy path already had vad_is_recording true, so this
     * never double-emits. */
    bool leaving_always_record = (prev == 65535 && threshold != 65535);
    /* Auto -> manual-standby switch mid-recording: finalize the in-progress auto
     * recording at the mode boundary. Only meaningful if something was recording
     * (an idle auto->standby toggle has nothing to finalize). */
    bool entering_manual_standby = (vad_is_recording && threshold == 32769 && prev != 65535);
    bool finalize_now = leaving_always_record || entering_manual_standby;

    if (finalize_now) {
        write_session_end_marker_to_storage();
    }

    vad_threshold = threshold;

    if (finalize_now) {
        vad_is_recording = false;
        vad_sleeping = true;
        vad_voice_streak = 0;
        /* Drop the pre-roll: preroll_store() only runs while !vad_is_recording, so the
         * ring has been frozen since this recording STARTED and holds frames from before
         * it — 1m48s old in the 2026-09-05 reproduction. Bursting those into the next
         * recording would prepend nearly two minutes of unrelated audio to it.
         *
         * The mic keeps running in auto mode, so the aad_apply_mic_gate() below does
         * NOT park it and therefore does NOT raise a capture gap — which is the only
         * reason manual standby and mute were immune. This path has to reset for itself.
         *
         * This reset was MISSING on 2026-09-05, and back then the omission did more than
         * prepend stale audio: the paced replay it also cleared left a holding ring
         * pinned full, a re-trigger inside the 3-frame debounce wedged
         * aad_process_audio(), and every frame was discarded until the room fell quiet
         * (44 min and 21 min of audio, reproduced 2/2 on demand). That failure mode is
         * gone with the holding ring — the burst has no state to be wedged in — so what
         * this line now prevents is the stale-audio half alone.
         *
         * POSTED, not called: this runs on the button/BLE thread and the pre-roll ring
         * belongs to the mic thread (see replay_reset_pending). The mic thread consumes
         * it at the top of aad_process_audio(), so it always lands before the next
         * preroll_queue_flush(), which is the only ordering that matters. */
        atomic_set(&replay_reset_pending, 1);
        atomic_set(&sd_pause_pending, 1);
        atomic_set(&adv_slow_req, 1);
        k_sem_give(&aad_sem);
        LOG_INF("AAD: recording finalized immediately (prev=%u thr=%u)", prev, threshold);
    }

    LOG_INF("AAD: threshold updated to %u", vad_threshold);

    /* Last, after every marker write above: the gate takes mic_state_lock, which
     * must never be held across SD I/O. */
    aad_apply_mic_gate();
}

uint16_t aad_get_threshold(void)
{
    return vad_threshold;
}

bool aad_is_recording(void)
{
    return vad_is_recording;
}

uint32_t aad_last_frame_uptime_ms(void)
{
    return mic_last_frame_uptime_ms;
}

uint32_t aad_voiced_ms(void)
{
    return vad_voiced_ms;
}

bool aad_is_sleeping(void)
{
    if (is_muted) {
        /* While muted, software VAD is disabled. We consider the device "awake"
         * (for LED status) if hardware acoustic activity was detected recently. */
        return (k_uptime_get() - last_hw_wake_ms) > CONFIG_OMI_VAD_HOLD_MS;
    }
    return vad_sleeping;
}
