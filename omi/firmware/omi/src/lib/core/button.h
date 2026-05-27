#ifndef BUTTON_H
#define BUTTON_H

#include <zephyr/input/input.h>
#include <zephyr/kernel.h>

extern volatile bool is_muted;
extern volatile bool is_led_enabled;
extern volatile uint8_t marker_flash_count;

typedef enum {
    MARKER_FLASH_WHITE,   // Non-manual marker tap
    MARKER_FLASH_GREEN,   // Manual-mode start of recording
    MARKER_FLASH_RED,     // Manual-mode end of recording
} marker_flash_color_t;

extern volatile marker_flash_color_t marker_flash_color;

int button_init();
void activate_button_work();
void register_button_service();
void turnoff_all();

// Input message queue from evt/button.c
extern struct k_msgq input_button;

#endif
