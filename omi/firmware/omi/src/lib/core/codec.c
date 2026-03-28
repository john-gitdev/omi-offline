#include "codec.h"

#include <zephyr/logging/log.h>
#include <zephyr/sys/ring_buffer.h>
#include <zephyr/kernel.h>

#include "config.h"
#include "utils.h"
#ifdef CODEC_OPUS
#include "lib/opus-1.2.1/opus.h"
#endif

LOG_MODULE_REGISTER(codec, CONFIG_LOG_DEFAULT_LEVEL);

//
// Output
//

static volatile codec_callback _callback = NULL;

void set_codec_callback(codec_callback callback)
{
    _callback = callback;
}

//
// Input
//

uint8_t codec_ring_buffer_data[AUDIO_BUFFER_SAMPLES * 2]; // 2 bytes per sample
struct ring_buf codec_ring_buf;
static K_MUTEX_DEFINE(codec_ring_mutex);

/* Signaled by codec_receive_pcm() each time a PCM block arrives.
 * codec_entry() blocks here instead of polling every 10 ms. */
K_SEM_DEFINE(codec_data_sem, 0, NETWORK_RING_BUF_SIZE);

int codec_receive_pcm(int16_t *data, size_t len) // this gets called after mic data is finished
{
    // Invariant: Only accept writes where (incoming_bytes % sample_size == 0)
    // Here, each sample is 2 bytes (int16_t). 'len' is the number of samples.
    size_t bytes_to_write = len * 2;

    k_mutex_lock(&codec_ring_mutex, K_FOREVER);
    if (ring_buf_space_get(&codec_ring_buf) < bytes_to_write) {
        k_mutex_unlock(&codec_ring_mutex);
        LOG_WRN("Codec ring buffer full, dropping %u bytes", (unsigned)bytes_to_write);
        return -1;
    }

    int written = ring_buf_put(&codec_ring_buf, (uint8_t *) data, bytes_to_write);
    k_mutex_unlock(&codec_ring_mutex);
    if (written != bytes_to_write) {
        LOG_ERR("Failed to write %u bytes to codec ring buffer (written %d)", (unsigned)bytes_to_write, written);
        return -1;
    }

    k_sem_give(&codec_data_sem);
    return 0;
}

//
// Thread
//

int16_t codec_input_samples[CODEC_PACKAGE_SAMPLES];
uint8_t codec_output_bytes[CODEC_OUTPUT_MAX_BYTES];
K_THREAD_STACK_DEFINE(codec_stack, 19000);
static struct k_thread codec_thread;
uint16_t execute_codec();

#if CODEC_OPUS
#if (CONFIG_OPUS_MODE == CONFIG_OPUS_MODE_CELT)
#define OPUS_ENCODER_SIZE 7180
#elif (CONFIG_OPUS_MODE == CONFIG_OPUS_MODE_HYBRID)
#define OPUS_ENCODER_SIZE 10916
#endif
__ALIGN(4)
static uint8_t m_opus_encoder[OPUS_ENCODER_SIZE];
static OpusEncoder *const m_opus_state = (OpusEncoder *) m_opus_encoder;
#endif

void codec_entry()
{
    uint16_t output_size;
    while (1) {
        /* Block until mic delivers at least one PCM block, then drain
         * the entire ring buffer in one pass before sleeping again.
         * Eliminates the 10 ms polling delay of the old k_sleep loop. */
        k_sem_take(&codec_data_sem, K_FOREVER);
        /* Reset any extra counts accumulated while we were processing the last
         * batch.  Without this, rapid back-to-back sem_give() calls leave a
         * non-zero count that causes the next N iterations of the outer loop
         * to wake immediately and spin on an empty ring buffer. */
        k_sem_reset(&codec_data_sem);

        while (1) {
            k_mutex_lock(&codec_ring_mutex, K_FOREVER);
            bool have_data = ring_buf_size_get(&codec_ring_buf) >= CODEC_PACKAGE_SAMPLES * 2;
            if (have_data) {
                ring_buf_get(&codec_ring_buf, (uint8_t *) codec_input_samples, CODEC_PACKAGE_SAMPLES * 2);
            }
            k_mutex_unlock(&codec_ring_mutex);
            if (!have_data) {
                break;
            }
            output_size = execute_codec();
            if (_callback) {
                _callback(codec_output_bytes, output_size);
            }
        }
    }
}

int codec_start()
{

// OPUS
#if CODEC_OPUS
    ASSERT_TRUE(opus_encoder_get_size(1) == sizeof(m_opus_encoder));
    ASSERT_TRUE(opus_encoder_init(m_opus_state, 16000, 1, CODEC_OPUS_APPLICATION) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_BITRATE(CODEC_OPUS_BITRATE)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_VBR(CODEC_OPUS_VBR)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_VBR_CONSTRAINT(0)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_COMPLEXITY(CODEC_OPUS_COMPLEXITY)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_LSB_DEPTH(16)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_DTX(0)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_INBAND_FEC(0)) == OPUS_OK);
    ASSERT_TRUE(opus_encoder_ctl(m_opus_state, OPUS_SET_PACKET_LOSS_PERC(0)) == OPUS_OK);
#endif

    // Thread
    ring_buf_init(&codec_ring_buf, sizeof(codec_ring_buffer_data), codec_ring_buffer_data);
    k_thread_create(&codec_thread,
                    codec_stack,
                    K_THREAD_STACK_SIZEOF(codec_stack),
                    (k_thread_entry_t) codec_entry,
                    NULL,
                    NULL,
                    NULL,
                    K_PRIO_PREEMPT(7),
                    0,
                    K_NO_WAIT);

    // Success
    return 0;
}

//
// Opus codec
//

#if CODEC_OPUS

uint16_t execute_codec()
{
    opus_int32 size = opus_encode(
        m_opus_state, codec_input_samples, CODEC_PACKAGE_SAMPLES, codec_output_bytes, sizeof(codec_output_bytes));
    if (size < 0) {
        LOG_WRN("Opus encoding failed: %d", size);
        return 0;
    }
    LOG_DBG("Opus encoding success: %i", size);
    return size;
}

#endif
