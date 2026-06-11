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
 * @brief Initialize the Codec
 *
 * Initializes the codec
 *
 * @return 0 if successful, negative errno code if error
 */
int codec_start();

#endif