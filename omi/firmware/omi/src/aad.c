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

#include "lib/core/codec.h"
#include "lib/core/config.h"
#include "lib/core/diag_log.h"
#include "lib/core/sd_card.h"
#include "lib/core/transport.h"
#include "lib/core/settings.h"
#include "rtc.h"
#include "imu.h"

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
static atomic_t sd_pause_pending = ATOMIC_INIT(0); /* 1=pause, 2=resume */
static atomic_t adv_slow_req = ATOMIC_INIT(0);
static atomic_t adv_fast_req = ATOMIC_INIT(0);

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

/* ---- VAD state (mic callback context only) ---- */
static bool vad_is_recording = false;
static bool vad_sleeping = false;
static uint16_t vad_voice_streak = 0;
static int64_t vad_last_voice_ms = 0;
static int64_t vad_next_status_ms = 0;

/* Peak-hold window for DIAG_VAD_LEVEL. Only ever touched from aad_process_audio()
 * on the mic thread, so no atomics needed. next_ms == 0 means "window not started";
 * the first processed frame arms it. */
static int64_t vad_next_diag_level_ms = 0;
static uint16_t vad_diag_level_max = 0;
static uint16_t vad_diag_level_min = UINT16_MAX;

/* ---- Pre-roll ring buffer ---- */
/* 8 frames * 100 ms/frame ~= 0.8 s pre-roll. */
#define VAD_PREROLL_FRAMES 8
/* Replay/backlog depth (also 0.8 s). With paced one-frame callbacks,
 * this avoids dropping transition speech while staying within RAM budget. */
#define VAD_PREROLL_FLUSH_MAX_FRAMES 8
static int16_t vad_preroll_buf[VAD_PREROLL_FRAMES][MIC_BUFFER_SAMPLES];
static uint8_t vad_preroll_wr = 0;
static uint8_t vad_preroll_cnt = 0;
static uint8_t vad_preroll_flush_rd = 0;
static uint8_t vad_preroll_flush_pending = 0;
static int16_t vad_live_backlog_buf[VAD_PREROLL_FLUSH_MAX_FRAMES][MIC_BUFFER_SAMPLES];
static uint8_t vad_live_backlog_rd = 0;
static uint8_t vad_live_backlog_wr = 0;
static uint8_t vad_live_backlog_cnt = 0;

#define VAD_STATUS_LOG_INTERVAL_MS 2000

/* Diagnostic level reporting (DIAG_VAD_LEVEL). Deliberately far slower than the RTT
 * status line above, and a peak-hold rather than a sample.
 *
 * Rate: the ring is 128 records deep and shared with every other event, so emitting
 * at the 2 s status cadence would evict the whole log every ~4 minutes and make the
 * rare events (empty-bin rotation, marker drop, bond state) unreadable. At 5 minutes
 * this costs ~12 records/hour, leaving ~10 h of history.
 *
 * Peak-hold rather than sample: it makes the emit rate irrelevant to the question
 * being asked. A wedged mic (digital-zero PDM output) reports max == 0 for every
 * window no matter when you look; a genuinely quiet room always catches SOMETHING
 * over five minutes — a door, a keystroke, movement — so max climbs well clear of
 * zero even when it never reaches the recording threshold. An instantaneous sample
 * confuses the two whenever it happens to land in a silent gap, which is exactly the
 * ambiguity that left the 2026-08-02 mic outage un-diagnosable from logs. */
#define VAD_DIAG_LEVEL_INTERVAL_MS 300000

/* ---- Helpers ---- */

static void preroll_reset(void)
{
    vad_preroll_wr = 0;
    vad_preroll_cnt = 0;
    vad_preroll_flush_rd = 0;
    vad_preroll_flush_pending = 0;
    vad_live_backlog_rd = 0;
    vad_live_backlog_wr = 0;
    vad_live_backlog_cnt = 0;
}

static bool live_backlog_push(const int16_t *buf)
{
    if (vad_live_backlog_cnt >= VAD_PREROLL_FLUSH_MAX_FRAMES) {
        LOG_ERR("VAD: live backlog overflow (cnt=%u)", vad_live_backlog_cnt);
        return false;
    }

    memcpy(vad_live_backlog_buf[vad_live_backlog_wr], buf, sizeof(vad_live_backlog_buf[0]));
    vad_live_backlog_wr = (vad_live_backlog_wr + 1) % VAD_PREROLL_FLUSH_MAX_FRAMES;
    vad_live_backlog_cnt++;
    return true;
}

static void live_backlog_flush_one(void)
{
    if (vad_live_backlog_cnt == 0) {
        return;
    }

    int err = codec_receive_pcm(vad_live_backlog_buf[vad_live_backlog_rd], MIC_BUFFER_SAMPLES);
    if (err) {
        LOG_ERR("VAD: live backlog flush failed (pending=%u): %d", vad_live_backlog_cnt, err);
        return;
    }

    vad_live_backlog_rd = (vad_live_backlog_rd + 1) % VAD_PREROLL_FLUSH_MAX_FRAMES;
    vad_live_backlog_cnt--;
}

static void preroll_store(const int16_t *buf)
{
    memcpy(vad_preroll_buf[vad_preroll_wr], buf, sizeof(vad_preroll_buf[0]));
    vad_preroll_wr = (vad_preroll_wr + 1) % VAD_PREROLL_FRAMES;
    if (vad_preroll_cnt < VAD_PREROLL_FRAMES) {
        vad_preroll_cnt++;
    }
}

static void preroll_queue_flush(void)
{
    if (vad_preroll_cnt == 0) {
        return;
    }
    uint8_t frames_to_flush = vad_preroll_cnt;
    if (frames_to_flush > VAD_PREROLL_FLUSH_MAX_FRAMES) {
        frames_to_flush = VAD_PREROLL_FLUSH_MAX_FRAMES;
    }

    /* Keep the most recent buffered audio when truncating flush burst. */
    vad_preroll_flush_rd = (vad_preroll_wr + VAD_PREROLL_FRAMES - frames_to_flush) % VAD_PREROLL_FRAMES;
    vad_preroll_flush_pending = frames_to_flush;

    uint8_t dropped = (vad_preroll_cnt > frames_to_flush) ? (vad_preroll_cnt - frames_to_flush) : 0;
    LOG_INF("VAD: queued %u/%u pre-roll frame(s), dropped %u", frames_to_flush, vad_preroll_cnt, dropped);

    /* Reset capture ring state; queued frames remain accessible via
     * vad_preroll_flush_rd + vad_preroll_flush_pending. */
    vad_preroll_wr = 0;
    vad_preroll_cnt = 0;
}

static void preroll_push_one(void)
{
    if (vad_preroll_flush_pending == 0) {
        return;
    }

    uint8_t idx = vad_preroll_flush_rd;
    int err = codec_receive_pcm(vad_preroll_buf[idx], MIC_BUFFER_SAMPLES);
    if (err) {
        LOG_ERR("Preroll push failed (pending=%u): %d", vad_preroll_flush_pending, err);
        vad_preroll_flush_pending = 0;
        return;
    }

    vad_preroll_flush_rd = (vad_preroll_flush_rd + 1) % VAD_PREROLL_FRAMES;
    vad_preroll_flush_pending--;

    if (vad_preroll_flush_pending == 0) {
        LOG_INF("VAD: pre-roll flush complete");
    }
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
        k_sem_take(&aad_sem, K_MSEC(100));

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
                 * force-capture is on. */
                if (vad_threshold == 65535) {
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
    if (atomic_cas(&wake_consumed, 1, 0)) {
        int64_t now_wake = k_uptime_get();
        vad_voice_streak = 0;
        vad_last_voice_ms = now_wake;
        if (now_wake >= force_wake_until_ms) {
            vad_is_recording = false;
        }
        LOG_INF("AAD: WAKE, VAD reset (force=%s)", now_wake < force_wake_until_ms ? "y" : "n");
    }

    uint32_t avg = avg_abs_amplitude(buffer, sample_count);
    int64_t now = k_uptime_get();
    /* 65535 = active manual recording (always-voice); 32769 = manual standby.
     * button.c reads the threshold back to distinguish manual vs. marker taps. */
    bool has_voice = vad_threshold == 65535
                  || avg >= vad_threshold
                  || now < force_wake_until_ms;

    if (has_voice) {
        vad_last_voice_ms = now;
        if (!vad_is_recording) {
            vad_voice_streak++;
            if (vad_voice_streak >= CONFIG_OMI_VAD_DEBOUNCE_FRAMES) {
                preroll_queue_flush();
                vad_is_recording = true;
                vad_sleeping = false;

                /* Write VAD-resume timestamp into the audio stream so the app
                 * can recalibrate frame times after a silence gap. */
                uint8_t vad_ts_buf[16] = {0};
                uint32_t utc = get_utc_time();
                uint64_t up = (uint64_t)k_uptime_get();
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
                /* Checkpoint the RTC vs IMU timestamp before we stop processing.
                 * This allows us to recover lost time if we reboot during silence. */
                lsm6dsl_time_prepare_for_system_off();
#endif

                atomic_set(&sd_pause_pending, 1);
                atomic_set(&adv_slow_req, 1);
                k_sem_give(&aad_sem);
                LOG_INF("VAD: SLEEP (silent %lld ms)", silent_ms);
                preroll_reset();
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

    /* Peak-hold the input level between diagnostic emissions (see
     * VAD_DIAG_LEVEL_INTERVAL_MS). Saturate at UINT16_MAX so a full-scale frame
     * can't wrap arg0 and read as silence — the one value we must never fake. */
    uint16_t avg_u16 = (avg > UINT16_MAX) ? UINT16_MAX : (uint16_t) avg;
    if (avg_u16 > vad_diag_level_max) {
        vad_diag_level_max = avg_u16;
    }
    if (avg_u16 < vad_diag_level_min) {
        vad_diag_level_min = avg_u16;
    }
    if (vad_next_diag_level_ms == 0) {
        /* First frame after boot: start the window here rather than firing
         * immediately on a single sample. */
        vad_next_diag_level_ms = now + VAD_DIAG_LEVEL_INTERVAL_MS;
    } else if (now >= vad_next_diag_level_ms) {
        /* arg1 packs the window minimum above the threshold that was in force, so a
         * reader can tell "quiet room under a high threshold" from "no signal at all"
         * without needing a second event to cross-reference. */
        diag_log_event(DIAG_VAD_LEVEL,
                       0,
                       vad_diag_level_max,
                       ((uint32_t) vad_diag_level_min << 16) | (uint32_t) vad_threshold);
        vad_diag_level_max = 0;
        vad_diag_level_min = UINT16_MAX;
        vad_next_diag_level_ms = now + VAD_DIAG_LEVEL_INTERVAL_MS;
    }

    if (!vad_is_recording) {
        preroll_store(buffer);
        return false;
    }

    /* While replaying pre-roll, output only queued pre-roll frames
     * at the same one-frame-per-callback cadence as normal recording.
     * This avoids interleaving historical frames with current live frames
     * (which corrupts temporal ordering). */
    if (vad_preroll_flush_pending > 0) {
        /* Preserve current live frame while we replay pre-roll. */
        if (!live_backlog_push(buffer)) {
            return false;
        }
        preroll_push_one();
        return false;
    }

    /* Once pre-roll replay has started, keep a single-frame cadence:
     * flush one queued live frame, then queue current frame.
     * This preserves FIFO ordering and avoids two-frame bursts into codec. */
    if (vad_live_backlog_cnt > 0) {
        live_backlog_flush_one();
        if (!live_backlog_push(buffer)) {
            return false;
        }
        return false;
    }

    return true;
}

void aad_force_wake(void)
{
    force_wake_until_ms = k_uptime_get() + FORCE_WAKE_HOLD_MS;
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
        atomic_set(&sd_pause_pending, 1);
        atomic_set(&adv_slow_req, 1);
        k_sem_give(&aad_sem);
        LOG_INF("AAD: recording finalized immediately (prev=%u thr=%u)", prev, threshold);
    }

    LOG_INF("AAD: threshold updated to %u", vad_threshold);
}

uint16_t aad_get_threshold(void)
{
    return vad_threshold;
}

bool aad_is_recording(void)
{
    return vad_is_recording;
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
