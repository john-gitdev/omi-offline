#ifndef CODEC_H
#define CODEC_H
#include <zephyr/kernel.h>

// Callback
typedef void (*codec_callback)(uint8_t *data, size_t len);
void set_codec_callback(codec_callback callback);

// Integration

int codec_receive_pcm(int16_t *data, size_t len);

/**
 * @brief Number of PCM blocks dropped before encode due to a full codec ring
 *        buffer (encoder starved). Each drop ~= one mic chunk (~100 ms). Safe
 *        to call from any thread.
 */
uint32_t codec_get_dropped_frames(void);

/**
 * @brief Peak stack usage (bytes) of the codec/encode thread since boot.
 *        High-water mark via k_thread_stack_space_get; 0 if unavailable. Compare
 *        against the codec stack size to gauge reclaimable stack. Any thread.
 */
uint32_t codec_get_stack_used(void);

/**
 * @brief Initialize the Codec
 *
 * Initializes the codec
 *
 * @return 0 if successful, negative errno code if error
 */
int codec_start();

#endif