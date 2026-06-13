/**
 * Software-In-The-Loop Mock for Button FSM
 * Compile with: gcc test_button_fsm.c -o test_button_fsm
 * Run with: ./test_button_fsm
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>

// --- Mocks for Zephyr / Project APIs ---
#define MULTI_TAP_WINDOW 600
#define HOLD_TIME 1000
#define POWER_OFF_HOLD_TIME 3000
#define UNPAIR_HOLD_TIME 10000

typedef enum {
    ACTION_NONE = 0,
    ACTION_MUTE = 1,
    ACTION_MARKER = 2,
    ACTION_TOGGLE_LED = 3,
} button_action_t;

typedef enum {
    STATE_IDLE,
    STATE_PRESS,
    STATE_RELEASE,
} button_state_t;

// Mock configuration (matches our defaults)
uint8_t mock_button_config[6] = {
    ACTION_NONE,       // 1 tap
    ACTION_NONE,       // 1 tap hold
    ACTION_MARKER,     // 2 tap
    ACTION_MUTE,       // 2 tap hold
    ACTION_TOGGLE_LED, // 3 tap
    ACTION_NONE        // 3 tap hold
};

// State variables
button_state_t current_state = STATE_IDLE;
uint8_t tap_count = 0;
uint32_t state_timer = 0;
uint32_t current_time_ms = 0;

// Mock callbacks (to verify actions)
int executed_action = -1;
bool power_off_triggered = false;
bool unpair_triggered = false;

void execute_button_action(button_action_t action) {
    executed_action = action;
    printf("[%u ms] Action executed: %d\n", current_time_ms, action);
}

void trigger_power_off() {
    power_off_triggered = true;
    printf("[%u ms] Power Off triggered!\n", current_time_ms);
}

void trigger_unpair() {
    unpair_triggered = true;
    printf("[%u ms] Unpair triggered!\n", current_time_ms);
}

// --- Simplified FSM implementation for the test ---
void fsm_tick(uint32_t delta_ms) {
    current_time_ms += delta_ms;
    
    if (current_state == STATE_PRESS || current_state == STATE_RELEASE) {
        state_timer += delta_ms;
    }

    switch (current_state) {
        case STATE_IDLE:
            break;

        case STATE_PRESS:
            if (tap_count == 5 && state_timer >= UNPAIR_HOLD_TIME) {
                trigger_unpair();
                current_state = STATE_IDLE; // Reset
            } else if (tap_count == 4 && state_timer >= POWER_OFF_HOLD_TIME) {
                trigger_power_off();
                current_state = STATE_IDLE; // Reset
            } else if (tap_count <= 3 && state_timer >= HOLD_TIME) {
                // Determine action from config
                uint8_t action = mock_button_config[(tap_count - 1) * 2 + 1];
                if (action != ACTION_NONE) {
                    execute_button_action((button_action_t)action);
                }
                current_state = STATE_IDLE; // Reset
            }
            break;

        case STATE_RELEASE:
            if (state_timer >= MULTI_TAP_WINDOW) {
                if (tap_count <= 3) {
                    // Resolve tap action
                    uint8_t action = mock_button_config[(tap_count - 1) * 2];
                    if (action != ACTION_NONE) {
                        execute_button_action((button_action_t)action);
                    }
                }
                current_state = STATE_IDLE; // Reset
            }
            break;
    }
}

void simulate_press() {
    if (current_state == STATE_IDLE || current_state == STATE_RELEASE) {
        current_state = STATE_PRESS;
        tap_count++;
        state_timer = 0;
        printf("[%u ms] Button Pressed (Tap Count: %d)\n", current_time_ms, tap_count);
    }
}

void simulate_release() {
    if (current_state == STATE_PRESS) {
        current_state = STATE_RELEASE;
        state_timer = 0;
        printf("[%u ms] Button Released\n", current_time_ms);
    }
}

void reset_test() {
    current_state = STATE_IDLE;
    tap_count = 0;
    state_timer = 0;
    current_time_ms = 0;
    executed_action = -1;
    power_off_triggered = false;
    unpair_triggered = false;
}

// --- Test Cases ---
int main() {
    printf("Starting FSM Simulation Tests...\n\n");

    // Test 1: Double Tap (Should trigger Marker -> Action 2)
    printf("--- Test 1: Double Tap ---\n");
    reset_test();
    simulate_press();
    fsm_tick(50);
    simulate_release();
    fsm_tick(100);
    simulate_press();
    fsm_tick(50);
    simulate_release();
    fsm_tick(MULTI_TAP_WINDOW + 10); // Wait for window to expire
    assert(executed_action == ACTION_MARKER);
    printf("Test 1 Passed!\n\n");

    // Test 2: Double Tap Hold (Should trigger Mute -> Action 1)
    printf("--- Test 2: Double Tap Hold ---\n");
    reset_test();
    simulate_press();
    fsm_tick(50);
    simulate_release();
    fsm_tick(100);
    simulate_press();
    fsm_tick(HOLD_TIME + 10); // Hold for 1 second
    assert(executed_action == ACTION_MUTE);
    printf("Test 2 Passed!\n\n");

    // Test 3: 4 Tap Hold (Should trigger Power Off)
    printf("--- Test 3: 4 Tap Hold (Power Off) ---\n");
    reset_test();
    for (int i = 0; i < 3; i++) {
        simulate_press();
        fsm_tick(50);
        simulate_release();
        fsm_tick(50);
    }
    simulate_press(); // 4th tap
    fsm_tick(POWER_OFF_HOLD_TIME + 10);
    assert(power_off_triggered == true);
    assert(executed_action == -1); // No standard action
    printf("Test 3 Passed!\n\n");

    // Test 4: 5 Tap Hold (Should trigger Unpair)
    printf("--- Test 4: 5 Tap Hold (Unpair) ---\n");
    reset_test();
    for (int i = 0; i < 4; i++) {
        simulate_press();
        fsm_tick(50);
        simulate_release();
        fsm_tick(50);
    }
    simulate_press(); // 5th tap
    fsm_tick(UNPAIR_HOLD_TIME + 10);
    assert(unpair_triggered == true);
    assert(power_off_triggered == false); // Didn't prematurely trigger power off
    printf("Test 4 Passed!\n\n");

    printf("All Tests Passed successfully!\n");
    return 0;
}
