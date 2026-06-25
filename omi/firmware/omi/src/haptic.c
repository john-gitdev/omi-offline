#include "lib/core/haptic.h"

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

LOG_MODULE_REGISTER(haptic, CONFIG_LOG_DEFAULT_LEVEL);

#define MAX_HAPTIC_DURATION 5000

/* Button-feedback pulse-train shape: each pulse is HAPTIC_PULSE_ON_MS on,
 * separated by HAPTIC_PULSE_GAP_MS off. Single = 1 pulse, double = 2,
 * triple = 3. HAPTIC_MAX_PULSES bounds the worst case if a bad value slips in. */
#define HAPTIC_PULSE_ON_MS 100
#define HAPTIC_PULSE_GAP_MS 100
#define HAPTIC_MAX_PULSES 10

static const struct gpio_dt_spec haptic_pin = GPIO_DT_SPEC_GET_OR(DT_NODELABEL(motor_pin), gpios, {0});

/* --- Motor ownership -----------------------------------------------------
 * Every mutation of the motor GPIO and the sequence state below runs on the
 * system workqueue (haptic_work_handler) or from a caller already executing
 * in that workqueue (button actions, power-off, unpair). The system workqueue
 * is single-threaded, so these never race and no lock is needed. Two callers
 * reach the motor from elsewhere and are made safe by construction:
 *   - the boot buzz (main.c) runs once on the main thread, before any button
 *     event is possible and before any haptic_work has been scheduled; and
 *   - the BLE "play now" characteristic (CAB1AB95) arrives on the BT RX thread
 *     and defers onto the workqueue via cab_play_work rather than driving the
 *     motor directly.
 * A single work item drives the whole train, so any new request cleanly
 * cancels and supersedes the one in flight.
 */
static struct k_work_delayable haptic_work;
/* Pulse-train state: ON phases left to emit, per-pulse ON/gap durations, and
 * whether the motor is currently mid-ON-phase. */
static uint8_t seq_pulses_left;
static uint16_t seq_on_ms;
static uint16_t seq_gap_ms;
static bool seq_phase_on;

/* CAB1AB95 "play now" hand-off: the BT RX thread stores the duration and
 * submits cab_play_work so the actual motor drive happens on the workqueue. */
static struct k_work cab_play_work;
static atomic_t cab_play_ms = ATOMIC_INIT(0);

static void haptic_pin_set(bool on)
{
    gpio_pin_set_dt(&haptic_pin, on ? 1 : 0);
}

static void haptic_work_handler(struct k_work *work)
{
    if (seq_pulses_left == 0) {
        haptic_pin_set(false);
        return;
    }

    if (seq_phase_on) {
        /* This pulse's ON time elapsed: drop the motor for the gap. */
        haptic_pin_set(false);
        seq_phase_on = false;
        if (--seq_pulses_left == 0) {
            return; /* train complete; motor stays off */
        }
        if (k_work_reschedule(&haptic_work, K_MSEC(seq_gap_ms)) < 0) {
            seq_pulses_left = 0; /* motor already off; just stop */
        }
    } else {
        /* Gap elapsed: start the next pulse. */
        haptic_pin_set(true);
        seq_phase_on = true;
        if (k_work_reschedule(&haptic_work, K_MSEC(seq_on_ms)) < 0) {
            haptic_off(); /* pin is high with no off scheduled: kill it */
        }
    }
}

static void cab_play_work_handler(struct k_work *work)
{
    play_haptic_milli((uint32_t)atomic_get(&cab_play_ms));
}

/* Start (or restart) a pulse train. The pin is driven high synchronously so
 * the blocking callers (power-off/unpair/boot do pin-on -> k_msleep ->
 * haptic_off) keep working unchanged. */
static void haptic_start(uint8_t pulses, uint16_t on_ms, uint16_t gap_ms)
{
    if (!gpio_is_ready_dt(&haptic_pin)) {
        LOG_ERR("Haptic GPIO device not ready");
        return;
    }

    /* Supersede any train in flight (single source of truth for the motor). */
    k_work_cancel_delayable(&haptic_work);

    if (pulses == 0 || on_ms == 0) {
        seq_pulses_left = 0;
        haptic_pin_set(false);
        return;
    }

    if (on_ms > MAX_HAPTIC_DURATION) {
        on_ms = MAX_HAPTIC_DURATION;
    }

    seq_pulses_left = pulses;
    seq_on_ms = on_ms;
    seq_gap_ms = gap_ms;
    seq_phase_on = true;
    haptic_pin_set(true);
    if (k_work_reschedule(&haptic_work, K_MSEC(on_ms)) < 0) {
        LOG_ERR("Failed to schedule haptic off; stopping motor");
        haptic_off(); /* pin is high with no off scheduled: kill it */
    }
}

// BLE Service definitions
static ssize_t haptic_write_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags);

// Define a unique UUID for the Haptic Service
static struct bt_uuid_128 haptic_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0xCAB1AB95, 0x2EA5, 0x4F4D, 0xBB56, 0x874B72CFC984));
static struct bt_uuid_128 haptic_char_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0xCAB1AB96, 0x2EA5, 0x4F4D, 0xBB56, 0x874B72CFC984));

// Define the Haptic GATT Service structure
static struct bt_gatt_attr haptic_attrs[] = {
    BT_GATT_PRIMARY_SERVICE(&haptic_service_uuid),
    BT_GATT_CHARACTERISTIC(&haptic_char_uuid.uuid,
                           BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE_ENCRYPT,
                           NULL,
                           haptic_write_handler,
                           NULL),
};

static struct bt_gatt_service haptic_service = BT_GATT_SERVICE(haptic_attrs);

// Haptic Write Handler
static ssize_t haptic_write_handler(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf,
                                    uint16_t len,
                                    uint16_t offset,
                                    uint8_t flags)
{
    if (len < 1) {
        LOG_WRN("Haptic write: Invalid length %d", len);
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t value = ((uint8_t *) buf)[0];
    LOG_INF("Haptic write received: value %d", value);

    // Map received value to haptic duration (1 -> 100ms, 2 -> 300ms, 3 -> 500ms).
    // This handler runs on the BT RX thread; defer the actual motor drive onto
    // the system workqueue so all motor ownership stays single-threaded.
    uint32_t ms;
    switch (value) {
    case 1:
        ms = 100;
        break;
    case 2:
        ms = 300;
        break;
    case 3:
        ms = 500;
        break;
    default:
        LOG_WRN("Haptic write: Invalid value %d", value);
        return len;
    }

    atomic_set(&cab_play_ms, (atomic_val_t)ms);
    k_work_submit(&cab_play_work);

    return len;
}

// Public Functions

int haptic_init(void)
{
    if (!gpio_is_ready_dt(&haptic_pin)) {
        LOG_ERR("Haptic GPIO device %s is not ready", haptic_pin.port->name);
        return -ENODEV;
    }

    int err = gpio_pin_configure_dt(&haptic_pin, GPIO_OUTPUT_INACTIVE);
    if (err) {
        LOG_ERR("Failed to configure haptic pin (err %d)", err);
        return err;
    }

    // Initialize the pulse-train work item and the CAB1AB95 hand-off work.
    k_work_init_delayable(&haptic_work, haptic_work_handler);
    k_work_init(&cab_play_work, cab_play_work_handler);

    LOG_INF("Haptic system initialized");
    return 0;
}

void play_haptic_milli(uint32_t duration)
{
    // A single pulse is just a one-pulse train with no gap.
    uint16_t ms = (duration > MAX_HAPTIC_DURATION) ? MAX_HAPTIC_DURATION : (uint16_t)duration;
    haptic_start(1, ms, 0);
}

void play_haptic_pattern(uint8_t pulses)
{
    if (pulses > HAPTIC_MAX_PULSES) {
        pulses = HAPTIC_MAX_PULSES;
    }
    // pulses == 0 falls through to haptic_start's "stop" branch (off slots).
    haptic_start(pulses, HAPTIC_PULSE_ON_MS, HAPTIC_PULSE_GAP_MS);
}

void register_haptic_service(void)
{
    int err = bt_gatt_service_register(&haptic_service);
    if (err) {
        LOG_ERR("Failed to register Haptic GATT service (err %d)", err);
    } else {
        LOG_INF("Haptic GATT service registered");
    }
}

void haptic_off()
{
    // Cancel any in-flight train so a pending phase can't drive the motor back
    // on, then drop the pin.
    k_work_cancel_delayable(&haptic_work);
    seq_pulses_left = 0;
    seq_phase_on = false;
    gpio_pin_set_dt(&haptic_pin, 0);
}
