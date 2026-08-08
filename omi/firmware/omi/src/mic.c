/*
 * Copyright (c) 2023 Omi Inc.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "lib/core/mic.h"

#include <nrfx_pdm.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "lib/core/settings.h"

LOG_MODULE_REGISTER(mic, CONFIG_LOG_DEFAULT_LEVEL);

#define MAX_SAMPLE_RATE 16000
#define SAMPLE_BIT_WIDTH 16
#define BYTES_PER_SAMPLE sizeof(int16_t)
#define CHANNELS 2

/* Milliseconds to wait for a block to be read. */
#define READ_TIMEOUT 1000

/* Size of a block for 100 ms of audio data. */
#define BLOCK_SIZE(sample_rate, number_of_channels) (BYTES_PER_SAMPLE * (sample_rate / 10) * number_of_channels)

/* Driver will allocate blocks from this slab to receive audio data into them.
 * Application, after getting a given block from the driver and processing its
 * data, needs to free that block.
 */
#define MAX_BLOCK_SIZE BLOCK_SIZE(MAX_SAMPLE_RATE, 2)
#define BLOCK_COUNT 4

K_MEM_SLAB_DEFINE_STATIC(mem_slab, MAX_BLOCK_SIZE, BLOCK_COUNT, 4);

static const struct device *dmic_dev;
static volatile mix_handler callback_func = NULL;
static volatile bool mic_running = false;

/* Serializes every transition of mic_running together with the dmic_trigger() calls
 * that implement it.
 *
 * These are reached from at least three threads: the button work handler
 * (button.c mute_apply / record start-stop), the BT RX thread (transport.c mute
 * write at :930 and VAD-threshold write at :1247), and main() at boot. Without a
 * lock, mic_reset()'s STOP-then-START is a check-then-act a mute can land inside,
 * leaving capture restarted on a device the user just muted. Privacy bug, and the
 * reason this lock exists.
 *
 * It is also what lets mic_reset() key its restart off a plain `was_running`
 * snapshot: read under the lock, that value cannot go stale before it is used, so
 * no separate "capture intended" state is needed to carry it.
 *
 * Zephyr mutexes are recursive for the owning thread, so mic_start() calling
 * mic_set_gain() while holding this is safe. Nothing here is reachable from an ISR
 * (all call sites are work handlers or thread context), so a mutex rather than a
 * spinlock is the right primitive. */
K_MUTEX_DEFINE(mic_state_lock);

/* PDM_EN (board net, P1.4) is the active-high enable for the T5838 mic + TXS0104
 * level-shifter power rail, and this firmware DOES NOT TOUCH IT. The pin is held
 * high by a board pull-up, so leaving it in its reset state (input, disconnected)
 * means the mic simply always has power — which is how it worked from the start
 * until oo-2.6.0, and the mic never froze in that time.
 *
 * Every driver of this pin has been removed on purpose: the ship-mode cut in
 * mic_off(), its restore in mic_on(), and the power cycle in mic_reset(). Driving
 * it is the prime suspect for the freezing that began afterwards, so it is left
 * alone to isolate that variable. See IDEAS.md "Mic rail (PDM_EN) is not driven by
 * firmware" for the evidence, what this costs (~1 mA leak in ship mode), and how to
 * bring it back if DIAG_VAD_LEVEL shows the mic still dropping without it.
 *
 * NB: config.h's PDM_PWR_PIN (P1.10) is a misnamed, unused leftover pointing at a
 * different rail — pdm_en_pin in the board DTS is the real mic-power net. */

#define MAX_FRAMES (MAX_SAMPLE_RATE / 10)
static int16_t mono_buffer[MAX_FRAMES];

static inline void
interleaved_stereo_to_mono(const int16_t *restrict interleaved, size_t frames, int16_t *restrict mono_out)
{
    /* Mix L and R channels directly from interleaved format: L0, R0, L1, R1, ... */
    for (size_t i = 0, j = 0; i < frames; ++i, j += 2) {
        int32_t left = (int32_t) interleaved[j + 0];
        int32_t right = (int32_t) interleaved[j + 1];
        int32_t sum = left + right;
        sum >>= 1; /* divide by 2 to avoid clipping */
        if (sum > 32767)
            sum = 32767;
        if (sum < -32768)
            sum = -32768;
        mono_out[i] = (int16_t) sum;
    }
}

static void process_audio_buffer(void *buffer, uint32_t size)
{
    /* size is total interleaved stereo size: frames * 2ch * 2bytes */
    __ASSERT_NO_MSG((size % (BYTES_PER_SAMPLE * CHANNELS)) == 0);
    size_t frames = size / (BYTES_PER_SAMPLE * CHANNELS);
    int16_t *inter = (int16_t *) buffer;

    /* Verify we don't exceed static buffer size */
    if (frames > MAX_FRAMES) {
        LOG_ERR("Frame count %zu exceeds MAX_FRAMES %d", frames, MAX_FRAMES);
        k_mem_slab_free(&mem_slab, buffer);
        return;
    }

    interleaved_stereo_to_mono(inter, frames, mono_buffer);

    if (callback_func) {
        callback_func(mono_buffer);
    }

    k_mem_slab_free(&mem_slab, buffer);
}

static void mic_thread_function(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    while (true) {
        if (mic_running) {
            void *buffer;
            uint32_t size;

            int ret = dmic_read(dmic_dev, 0, &buffer, &size, READ_TIMEOUT);
            if (ret < 0) {
                LOG_ERR("Read failed: %d", ret);
                continue;
            }

            LOG_DBG("Got buffer %p of %u bytes", buffer, size);
            process_audio_buffer(buffer, size);
        } else {
            k_sleep(K_MSEC(100));
        }
    }
}

#define MIC_THREAD_STACK_SIZE 2048
#define MIC_THREAD_PRIORITY 5
K_THREAD_DEFINE(mic_thread_id,
                MIC_THREAD_STACK_SIZE,
                mic_thread_function,
                NULL,
                NULL,
                NULL,
                MIC_THREAD_PRIORITY,
                0,
                -1);

int mic_start()
{
    int ret;

    dmic_dev = DEVICE_DT_GET(DT_ALIAS(dmic0));
    if (!device_is_ready(dmic_dev)) {
        LOG_ERR("%s is not ready", dmic_dev->name);
        return -ENODEV;
    }

    struct pcm_stream_cfg stream = {
        .pcm_width = SAMPLE_BIT_WIDTH,
        .mem_slab = &mem_slab,
        .pcm_rate = MAX_SAMPLE_RATE,
        .block_size = BLOCK_SIZE(MAX_SAMPLE_RATE, CHANNELS),
    };

    struct dmic_cfg cfg = {
        .io =
            {
                .min_pdm_clk_freq = 512000,
                .max_pdm_clk_freq = 3500000,
                .min_pdm_clk_dc = 48,
                .max_pdm_clk_dc = 52,
            },
        .streams = &stream,
        .channel =
            {
                .req_num_streams = 1,
                .req_num_chan = CHANNELS,
                .req_chan_map_lo =
                    dmic_build_channel_map(0, 0, PDM_CHAN_LEFT) | dmic_build_channel_map(1, 0, PDM_CHAN_RIGHT),
            },

    };

    LOG_INF("PCM output rate: %u, channels: %u", cfg.streams[0].pcm_rate, cfg.channel.req_num_chan);

    /* Locked from here: the configure/gain/START sequence and the flag writes must
     * be one atomic unit. transport_start() runs BEFORE mic_start() in main(), so a
     * BLE mute write can already arrive and STOP the dmic between the trigger below
     * and mic_running = true, leaving capture running with the flags saying muted. */
    k_mutex_lock(&mic_state_lock, K_FOREVER);

    ret = dmic_configure(dmic_dev, &cfg);
    if (ret < 0) {
        LOG_ERR("Failed to configure the driver: %d", ret);
        k_mutex_unlock(&mic_state_lock);
        return ret;
    }

    // Apply saved mic gain setting
    uint8_t saved_gain = app_settings_get_mic_gain();
    mic_set_gain(saved_gain);

    ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
    if (ret < 0) {
        LOG_ERR("START trigger failed: %d", ret);
        k_mutex_unlock(&mic_state_lock);
        return ret;
    }

    mic_running = true;
    /* Inside the lock, like mic_on()'s. mic_off() holds this lock while it calls
     * k_thread_abort(mic_thread_id), so unlocking first opens a window where a
     * power-off aborts the thread between here and the start below — and
     * k_thread_start() on an aborted thread does nothing, so the mic thread would
     * never run again and no reset or resume could bring capture back. Reachable
     * because transport_start() and button_init() both run BEFORE mic_start() in
     * main(), so both power-off routes are already armed; the harm lands when
     * turnoff_all() bails without the reboot recovery storage.c does. */
    k_thread_start(mic_thread_id);
    k_mutex_unlock(&mic_state_lock);

    LOG_INF("Microphone started");
    return 0;
}

void set_mic_callback(mix_handler callback)
{
    callback_func = callback;
}

void mic_pause()
{
    LOG_INF("Pausing microphone");
    k_mutex_lock(&mic_state_lock, K_FOREVER);
    if (mic_running) {
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
        if (ret < 0) {
            LOG_ERR("STOP trigger failed: %d", ret);
            k_mutex_unlock(&mic_state_lock);
            return;
        }
        mic_running = false;
    }
    k_mutex_unlock(&mic_state_lock);
}

/* True once mic_start() has resolved the dmic device. Everything that STOPs is
 * already safe before then (it is gated on mic_running, which cannot be set yet),
 * but the two entry points that START are not: they would hand a NULL device to
 * dmic_trigger().
 *
 * The window is real and not short. transport_start() runs BEFORE mic_start() in
 * main(), and boot_warming_sequence() sits between them waiting for the SD card —
 * up to SD_BOOT_TIMEOUT_MS (90 s) on a faulty card. Any BLE write that reaches the
 * mic in that window lands here: a VAD-threshold write via aad_apply_mic_gate(), or
 * the unmute half of a mute toggle. */
static inline bool mic_hw_ready(void)
{
    return dmic_dev != NULL;
}

bool mic_is_ready(void)
{
    return mic_hw_ready();
}

void mic_resume()
{
    LOG_INF("Resuming microphone");
    if (!mic_hw_ready()) {
        LOG_WRN("mic_resume before mic_start — ignoring");
        return;
    }
    k_mutex_lock(&mic_state_lock, K_FOREVER);
    if (!mic_running) {
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
        if (ret < 0) {
            LOG_ERR("START trigger failed: %d", ret);
            k_mutex_unlock(&mic_state_lock);
            return;
        }
        mic_running = true;
    }
    k_mutex_unlock(&mic_state_lock);
}

void mic_reset()
{
    /* Held for the whole sequence so the was_running snapshot below cannot go stale
     * between the STOP and the START: under the lock, what was running when we
     * entered is still what should be running when we leave. See mic_state_lock. */
    k_mutex_lock(&mic_state_lock, K_FOREVER);

    const bool was_running = mic_running;

    if (mic_running) {
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
        if (ret < 0) {
            /* Bail rather than press on, matching mic_pause(). Treating a failed
             * STOP as stopped would cut PDM_EN out from under a still-active
             * peripheral and then START an un-stopped driver, whose error return
             * leaves mic_running false while capture is really running — a state
             * desync worse than the wedge this is trying to clear. The caller
             * simply doesn't get a reset this time. */
            LOG_ERR("mic_reset: STOP trigger failed: %d — leaving mic untouched", ret);
            k_mutex_unlock(&mic_state_lock);
            return;
        }
        mic_running = false;
    }

    /* NO PDM_EN CYCLE HERE — deliberately. See IDEAS.md "Mic rail (PDM_EN) is not
     * driven by firmware". This used to drop and restore the T5838's supply, which
     * is the only thing that clears a wedged part, and it is gone because driving
     * that rail at all is the prime suspect for the wedging: the firmware never
     * touched PDM_EN until oo-2.6.0 (2026-07-17), and the mic had never frozen
     * before that. Removing it isolates that variable.
     *
     * What is left is a dmic re-trigger, which does NOT recover a wedged T5838. The
     * call sites are kept so the cycle is one small edit away if DIAG_VAD_LEVEL
     * shows the mic still dropping without it. */

    if (was_running) {
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
        if (ret < 0) {
            LOG_ERR("mic_reset: START trigger failed: %d", ret);
            k_mutex_unlock(&mic_state_lock);
            return;
        }
        mic_running = true;
    }

    LOG_INF("Microphone reset (running=%d)", mic_running);
    k_mutex_unlock(&mic_state_lock);
}

bool mic_is_running()
{
    return mic_running;
}

void mic_off()
{
    /* Locked like the rest so an in-flight mic_reset() cannot restart capture after
     * this stopped it. Irrelevant delay on the power-down path. */
    k_mutex_lock(&mic_state_lock, K_FOREVER);
    if (mic_running) {
        mic_running = false;
        k_thread_abort(mic_thread_id);

        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
        if (ret < 0) {
            LOG_ERR("STOP trigger failed: %d", ret);
        }

        LOG_INF("Microphone stopped");
    }

    /* The PDM_EN cut that used to be here is gone — see the pdm_en comment at the
     * top of this file. It saved ~1 mA in ship mode and cost the mic being latched
     * off whenever turnoff_all() bailed after this point, which is the failure the
     * firmware never had before oo-2.6.0. The leak is the deliberate price of
     * isolating that. */
    k_mutex_unlock(&mic_state_lock);
}

void mic_on()
{
    /* Same pre-mic_start() hazard as mic_resume(), plus this one would also
     * k_thread_start() the mic thread into dmic_read(NULL). */
    if (!mic_hw_ready()) {
        LOG_WRN("mic_on before mic_start — ignoring");
        return;
    }
    k_mutex_lock(&mic_state_lock, K_FOREVER);
    if (!mic_running) {
        /* No PDM_EN restore needed: nothing drives that pin any more, so the rail is
         * never down to begin with. See the pdm_en comment at the top of this file. */
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
        if (ret < 0) {
            LOG_ERR("START trigger failed: %d", ret);
            k_mutex_unlock(&mic_state_lock);
            return;
        }

        mic_running = true;
        k_thread_start(mic_thread_id);

        LOG_INF("Microphone restarted");
    }
    k_mutex_unlock(&mic_state_lock);
}

void mic_set_gain(uint8_t gain_level)
{
    // Map gain level (0-8) to hardware values
    static const uint8_t gain_map[9] = {
        0x00, // Level 0: mute
        0x14, // Level 1: -20dB
        0x1E, // Level 2: -10dB
        0x28, // Level 3: +0dB
        0x2E, // Level 4: +6dB
        0x32, // Level 5: +10dB
        0x3C, // Level 6: +20dB (default)
        0x46, // Level 7: +30dB
        0x50  // Level 8: +40dB
    };

    // Clamp to valid level range
    if (gain_level > 8) {
        gain_level = 8;
    }

    uint8_t hw_gain = gain_map[gain_level];

    LOG_INF("Setting mic gain to level %u (0x%02x)", gain_level, hw_gain);

#ifdef NRF_PDM0_S
    nrf_pdm_gain_set(NRF_PDM0_S, hw_gain, hw_gain);
#else
    nrf_pdm_gain_set(NRF_PDM0_NS, hw_gain, hw_gain);
#endif
}
