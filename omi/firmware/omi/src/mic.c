/*
 * Copyright (c) 2023 Omi Inc.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "lib/core/mic.h"

#include <nrfx_pdm.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/drivers/gpio.h>
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

/* PDM_EN (board net, P1.4): active-high enable for the T5838 mic + TXS0104
 * level-shifter power rail (schematic: PDM_EN gates the shifter's VCCA/VCCB).
 * It is hardware-default-enabled via a pull-up, so the mic runs without the
 * firmware ever touching it. We drive it low in mic_off() — whose sole caller
 * is turnoff_all() — so the mic + shifter fully power down at ship-mode instead
 * of leaking ~1 mA of the 150 mAh cell through System OFF (GPIO output levels
 * are retained in System OFF). NB: config.h's PDM_PWR_PIN (P1.10) is a misnamed,
 * unused leftover pointing at a different rail — this pdm_en_pin node is the
 * real mic-power net. */
static const struct gpio_dt_spec pdm_en = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(pdm_en_pin), gpios, {0});

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

    ret = dmic_configure(dmic_dev, &cfg);
    if (ret < 0) {
        LOG_ERR("Failed to configure the driver: %d", ret);
        return ret;
    }

    // Apply saved mic gain setting
    uint8_t saved_gain = app_settings_get_mic_gain();
    mic_set_gain(saved_gain);

    ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
    if (ret < 0) {
        LOG_ERR("START trigger failed: %d", ret);
        return ret;
    }

    mic_running = true;
    k_thread_start(mic_thread_id);

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
    if (mic_running) {
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
        if (ret < 0) {
            LOG_ERR("STOP trigger failed: %d", ret);
            return;
        }
        mic_running = false;
    }
}

void mic_resume()
{
    LOG_INF("Resuming microphone");
    if (!mic_running) {
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
        if (ret < 0) {
            LOG_ERR("START trigger failed: %d", ret);
            return;
        }
        mic_running = true;
    }
}

mic_reset_result_t mic_reset()
{
    const bool was_running = mic_running;
    mic_reset_result_t result = MIC_RESET_NOT_CYCLED;

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
            return MIC_RESET_NOT_CYCLED;
        }
        mic_running = false;
    }

    /* Drop the T5838 + TXS0104 rail long enough for the part to fully de-power,
     * then bring it back and let it settle before capture resumes. This is the
     * whole point of the call — a wedged T5838 (digital-zero PDM output, WAKE
     * never asserting) is only cleared by removing its supply, which neither
     * mic_pause()/mic_resume() nor a dmic re-trigger does. INACTIVE = physical
     * low = disabled (pdm_en_pin is GPIO_ACTIVE_HIGH).
     *
     * Both configure calls are checked. A ready GPIO controller does not mean the
     * pin was actually driven, and callers that record this in the diagnostic log
     * must never claim a power cycle that did not happen — a discarded error here
     * would leave the rail up while the record says otherwise, which is exactly the
     * confusion the record exists to prevent. If the pull-down fails there is no
     * cycle at all; if only the restore fails the rail is left LOW, which is worse
     * than not trying, so say so loudly. */
    if (gpio_is_ready_dt(&pdm_en)) {
        int lo = gpio_pin_configure_dt(&pdm_en, GPIO_OUTPUT_INACTIVE);
        if (lo < 0) {
            LOG_ERR("mic_reset: PDM_EN pull-down failed: %d — rail NOT cycled", lo);
        } else {
            k_msleep(20);
            int hi = gpio_pin_configure_dt(&pdm_en, GPIO_OUTPUT_ACTIVE);
            if (hi < 0) {
                /* The rail is LOW and we cannot drive it back up — the one outcome
                 * worse than never having tried, because the part now has no supply
                 * at all. Release the pin to an input so the board pull-up re-powers
                 * it: that pull-up is what holds PDM_EN high whenever the firmware
                 * doesn't touch the pin, so handing control back to it is the best
                 * recovery available here. */
                int rel = gpio_pin_configure_dt(&pdm_en, GPIO_INPUT);
                if (rel < 0) {
                    LOG_ERR("mic_reset: PDM_EN stuck LOW (restore %d, release %d) — mic has NO supply",
                            hi,
                            rel);
                    result = MIC_RESET_RAIL_OFF;
                } else {
                    LOG_WRN("mic_reset: PDM_EN restore failed (%d) — released to the board pull-up", hi);
                    k_msleep(20);
                    result = MIC_RESET_PARTIAL;
                }
            } else {
                k_msleep(20);
                result = MIC_RESET_CYCLED;
                LOG_INF("mic_reset: PDM_EN power-cycled");
            }
        }
    } else {
        LOG_WRN("mic_reset: PDM_EN gpio not ready — rail NOT cycled");
    }

    /* Never restart capture unless the rail is CONFIRMED up. Doing so would report
     * mic_running = true over a part that may have no supply, i.e. silent capture
     * that every layer above believes is healthy — the exact failure this whole
     * change set exists to make visible.
     *
     * PARTIAL counts as unconfirmed, not as good enough. The pin was released to the
     * board pull-up, which should re-power the part, but "should" is the problem: a
     * pull-up is deliberately weak, so its rise time through the mic's decoupling is
     * nothing like a driven output and the 20 ms settle above was sized for the
     * latter. If the pull-up is absent or damaged the rail simply stays low. We
     * cannot tell, and starting capture is a claim we would have no basis for.
     *
     * Leaving mic_running false is the honest state and lets a later
     * mic_start()/mic_reset() retry once the rail has had time to recover. */
    /* Positive form on purpose: an enum value appended later defaults to "not
     * confirmed", i.e. to leaving capture stopped, which is the safe side. */
    const bool rail_confirmed_up = (result == MIC_RESET_CYCLED || result == MIC_RESET_NOT_CYCLED);
    if (was_running && !rail_confirmed_up) {
        LOG_ERR("mic_reset: not restarting capture — rail unconfirmed (result=%d), mic left stopped", (int) result);
    } else if (was_running) {
        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
        if (ret < 0) {
            LOG_ERR("mic_reset: START trigger failed: %d", ret);
            return result;
        }
        mic_running = true;
    }

    LOG_INF("Microphone reset (running=%d, result=%d)", mic_running, (int) result);
    return result;
}

bool mic_is_running()
{
    return mic_running;
}

void mic_off()
{
    if (mic_running) {
        mic_running = false;
        k_thread_abort(mic_thread_id);

        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_STOP);
        if (ret < 0) {
            LOG_ERR("STOP trigger failed: %d", ret);
        }

        LOG_INF("Microphone stopped");
    }

    /* Cut the mic + TXS0104 shifter power rail. mic_off() runs only on the
     * power-down path (turnoff_all), so forcing PDM_EN low here overrides its
     * default-enable pull-up and stops the ~1 mA system-off leak. INACTIVE =
     * physical low = disabled (pdm_en_pin is GPIO_ACTIVE_HIGH). */
    if (gpio_is_ready_dt(&pdm_en)) {
        gpio_pin_configure_dt(&pdm_en, GPIO_OUTPUT_INACTIVE);
        LOG_INF("PDM_EN low — mic + shifter powered down");
    }
}

void mic_on()
{
    if (!mic_running) {
        /* Restore the mic + TXS0104 rail in case a prior mic_off() drove PDM_EN
         * low. Normally PDM_EN is already high (default-enable pull-up), so this
         * is a no-op; it only matters if mic_off() ran without a full power-off
         * (e.g. a bailed turnoff_all). Re-assert active and let the rail settle
         * before capture so the first frames aren't garbage. */
        if (gpio_is_ready_dt(&pdm_en)) {
            gpio_pin_configure_dt(&pdm_en, GPIO_OUTPUT_ACTIVE);
            k_msleep(5);
        }

        int ret = dmic_trigger(dmic_dev, DMIC_TRIGGER_START);
        if (ret < 0) {
            LOG_ERR("START trigger failed: %d", ret);
            return;
        }

        mic_running = true;
        k_thread_start(mic_thread_id);

        LOG_INF("Microphone restarted");
    }
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
