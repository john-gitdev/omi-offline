#include "imu.h"

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/util.h>

#include "lib/core/diag_log.h"
#include "lib/core/settings.h"
#include "rtc.h"

LOG_MODULE_REGISTER(imu, CONFIG_LOG_DEFAULT_LEVEL);

/* Minimal register access for ST LSM6DS3TR-C/LSM6DSx timestamp.
 *
 * Relevant registers (LSM6DS3TR-C header confirms these addresses):
 * - CTRL10_C = 0x19, timer_en is bit 5 (enables timestamp counter)
 * - WAKE_UP_DUR = 0x5C, timer_hr selects timestamp LSB
 * - TIMESTAMP0 = 0x40, 24-bit little-endian counter (TIMESTAMP0..2)
 */

#define LSM6DS_REG_CTRL10_C         0x19
#define LSM6DS_REG_WAKE_UP_DUR      0x5C
#define LSM6DS_REG_TIMESTAMP0       0x40
#define LSM6DS_REG_TIMESTAMP2       0x42

#define LSM6DS_CTRL10_TIMER_EN      BIT(5)

/* Accel/gyro control registers, read back so the power state can be verified rather
 * than assumed. Nothing in the built firmware consumes motion data — accel.c is the
 * only reader and is not in CMakeLists.txt — so both parts should be idle. */
#define LSM6DS_REG_CTRL1_XL         0x10 /* ODR_XL in bits [7:4]; 0 = accel powered down */
#define LSM6DS_REG_CTRL2_G          0x11 /* ODR_G  in bits [7:4]; 0 = gyro powered down  */
#define LSM6DS_REG_CTRL6_C          0x15 /* bit 4 XL_HM_MODE: 1 = accel low-power mode   */
#define LSM6DS_REG_CTRL7_G          0x16 /* bit 7 G_HM_MODE:  1 = gyro low-power mode    */
#define LSM6DS_WAKE_UP_DUR_TIMER_HR BIT(4)

/* LSM6DS3TR-C timestamp resolution:
 * - TIMER_HR = 0: 1 LSB = 6.4 ms (default)
 * - TIMER_HR = 1: 1 LSB = 25 us
 */
#define LSM6DS_TIMESTAMP_TICK_US_6P4MS 6400ULL

/* Allow sensor time to boot after enabling its power pin. */
#define LSM6DS_POWER_ON_DELAY_MS 50

static int lsm6dsl_power_ensure_on(void);

static const struct i2c_dt_spec lsm6dsl_i2c = I2C_DT_SPEC_GET(DT_ALIAS(lsm6dsl));
static const struct gpio_dt_spec lsm6dsl_en = GPIO_DT_SPEC_GET(DT_NODELABEL(lsm6dsl_en_pin), enable_gpios);
static const struct device *const lsm6dsl_dev = DEVICE_DT_GET(DT_ALIAS(lsm6dsl));

/* Reads back what the part is actually doing and records it, because asking is not
 * knowing: a driver that returns 0 has promised only that it accepted the request,
 * and one that refuses 0 Hz outright was — until this — completely silent, since the
 * return codes were discarded and logging is compiled out (oo-2.10.0).
 *
 * Only the timestamp counter is used from this chip, so ODR_XL and ODR_G should both
 * read 0. A gyro left at the driver's default is on the order of 1 mA off a 150 mAh
 * cell, which would make it the largest single draw on the device. */
static void lsm6dsl_report_power_state(int accel_rc, int gyro_rc)
{
	/* CTRL1_XL/CTRL2_G and CTRL6_C/CTRL7_G are adjacent pairs — two bursts, not four
	 * single-byte reads, so this costs the I2C bus almost nothing. */
	uint8_t regs[4] = {0};
	if (i2c_burst_read_dt(&lsm6dsl_i2c, LSM6DS_REG_CTRL1_XL, &regs[0], 2) != 0 ||
	    i2c_burst_read_dt(&lsm6dsl_i2c, LSM6DS_REG_CTRL6_C, &regs[2], 2) != 0) {
		/* 0xFFFF marks arg1 as meaningless rather than as "everything powered down",
		 * which is what a zeroed payload would otherwise read as. */
		diag_log_event_forced(DIAG_IMU_POWER_STATE, 0, 0xFFFFu, 0);
		return;
	}

	uint32_t packed = ((uint32_t)regs[0] << 24) | ((uint32_t)regs[1] << 16) |
			  ((uint32_t)regs[2] << 8) | (uint32_t)regs[3];
	uint16_t rcs = (uint16_t)(((accel_rc & 0xFF) << 8) | (gyro_rc & 0xFF));

	/* This runs on every time sync, i.e. every connect. Report only a change (and the
	 * first call after boot) so a steady state does not evict the 128-slot ring. */
	static bool reported;
	static uint32_t last_packed;
	static uint16_t last_rcs;
	if (reported && packed == last_packed && rcs == last_rcs) {
		return;
	}
	reported = true;
	last_packed = packed;
	last_rcs = rcs;

	/* Forced past the runtime gate for the same reason DIAG_BOND_STATE is: the first
	 * emit rides the time sync that lands with the connect, seconds before the app has
	 * opened the gate, so a gated emit would be dropped exactly when it is wanted. */
	diag_log_event_forced(DIAG_IMU_POWER_STATE, 0, rcs, packed);
}

static void lsm6dsl_force_minimal_run_mode(void)
{
	if (lsm6dsl_dev == NULL || !device_is_ready(lsm6dsl_dev)) {
		LOG_DBG("lsm6dsl_dev not ready; skip minimal run mode");
		return;
	}

	/* 12.5 Hz = 12 + 0.5 (in micro). */
	struct sensor_value odr = { .val1 = 12, .val2 = 500000 };
	int accel_rc = sensor_attr_set(lsm6dsl_dev, SENSOR_CHAN_ACCEL_XYZ, SENSOR_ATTR_SAMPLING_FREQUENCY, &odr);

	/* Best-effort attempt to stop gyro to save power. Not all drivers accept 0 Hz. */
	struct sensor_value gyro_odr = { .val1 = 0, .val2 = 0 };
	int gyro_rc = sensor_attr_set(lsm6dsl_dev, SENSOR_CHAN_GYRO_XYZ, SENSOR_ATTR_SAMPLING_FREQUENCY, &gyro_odr);

	lsm6dsl_report_power_state(accel_rc, gyro_rc);
}

static int lsm6dsl_power_ensure_on(void)
{
	if (!device_is_ready(lsm6dsl_en.port)) {
		LOG_DBG("lsm6dsl_en gpio not ready; assume always-on");
		return 0;
	}

	/* ensure enable pin is configured and driven high. */
	int err = gpio_pin_configure_dt(&lsm6dsl_en, GPIO_OUTPUT);
	if (err < 0) {
		LOG_WRN("Failed to configure lsm6dsl_en gpio (err %d)", err);
		return err;
	}

	err = gpio_pin_set_dt(&lsm6dsl_en, 1);
	if (err < 0) {
		LOG_WRN("Failed to set lsm6dsl_en gpio high (err %d)", err);
		return err;
	}

	/* Give IMU time to be ready for I2C transactions. */
	k_msleep(LSM6DS_POWER_ON_DELAY_MS);
	LOG_INF("lsm6dsl_en asserted");

	return 0;
}

static int lsm6dsl_timestamp_enable(void)
{
	if (!device_is_ready(lsm6dsl_i2c.bus)) {
		LOG_WRN("lsm6dso i2c bus not ready");
		return -ENODEV;
	}

	uint8_t ctrl10;
	int err = i2c_reg_read_byte_dt(&lsm6dsl_i2c, LSM6DS_REG_CTRL10_C, &ctrl10);
	if (err) {
		LOG_WRN("Failed to read CTRL10_C (err %d)", err);
		return err;
	}

	ctrl10 |= LSM6DS_CTRL10_TIMER_EN;
	err = i2c_reg_write_byte_dt(&lsm6dsl_i2c, LSM6DS_REG_CTRL10_C, ctrl10);
	if (err) {
		LOG_WRN("Failed to write CTRL10_C timer_en=1 (err %d)", err);
		return err;
	}

	LOG_DBG("Timestamp enabled (CTRL10_C=0x%02x)", ctrl10);
	return 0;
}

static int lsm6dsl_timestamp_reset(void)
{
	/* LSM6DS3TR-C datasheet: to reset the timestamp timer, store 0xAA in TIMESTAMP2 (0x42). */
	if (!device_is_ready(lsm6dsl_i2c.bus)) {
		LOG_WRN("lsm6dso i2c bus not ready");
		return -ENODEV;
	}

	int err = i2c_reg_write_byte_dt(&lsm6dsl_i2c, LSM6DS_REG_TIMESTAMP2, 0xAA);
	if (err) {
		LOG_WRN("Failed to write TIMESTAMP2=0xAA (reset) (err %d)", err);
		return err;
	}

	/* Give the IMU a moment to apply the reset. */
	k_msleep(2);
	LOG_DBG("Timestamp reset requested (TIMESTAMP2=0xAA)");
	return 0;
}

static int lsm6dsl_timestamp_set_resolution_6p4ms(void)
{
	if (!device_is_ready(lsm6dsl_i2c.bus)) {
		LOG_WRN("lsm6dso i2c bus not ready");
		return -ENODEV;
	}

	uint8_t wake_up_dur;
	int err = i2c_reg_read_byte_dt(&lsm6dsl_i2c, LSM6DS_REG_WAKE_UP_DUR, &wake_up_dur);
	if (err) {
		LOG_WRN("Failed to read WAKE_UP_DUR (err %d)", err);
		return err;
	}

	/* TIMER_HR=0 => 6.4ms LSB */
	wake_up_dur &= (uint8_t)~LSM6DS_WAKE_UP_DUR_TIMER_HR;
	err = i2c_reg_write_byte_dt(&lsm6dsl_i2c, LSM6DS_REG_WAKE_UP_DUR, wake_up_dur);
	if (err) {
		LOG_WRN("Failed to write WAKE_UP_DUR timer_hr=0 (err %d)", err);
		return err;
	}

	LOG_DBG("Timestamp resolution forced to 6.4ms (WAKE_UP_DUR=0x%02x)", wake_up_dur);
	return 0;
}

int lsm6dsl_timestamp_read(uint32_t *ts)
{
    if (ts == NULL) {
        return -EINVAL;
    }
	if (!device_is_ready(lsm6dsl_i2c.bus)) {
		LOG_WRN("lsm6dso i2c bus not ready");
		return -ENODEV;
	}

	/* LSM6DS3TR-C exposes a 24-bit timestamp counter (TIMESTAMP0..2). */
	uint8_t buf[3];
	int err = i2c_burst_read_dt(&lsm6dsl_i2c, LSM6DS_REG_TIMESTAMP0, buf, sizeof(buf));
	if (err) {
		LOG_WRN("Failed to read TIMESTAMP0..2 (err %d)", err);
		return err;
	}

	*ts = ((uint32_t)buf[0]) | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16);
	return 0;
}

void lsm6dsl_time_prepare_for_system_off(void)
{
	/* Requires a valid UTC epoch to be meaningful. */
	if (!rtc_is_valid()) {
		LOG_INF("system_off prep: skip (RTC not valid)");
		return;
	}

	LOG_INF("system_off prep: begin");

	int err = lsm6dsl_power_ensure_on();
	if (err) {
		LOG_WRN("system_off prep: IMU power ensure failed (err %d)", err);
	}
	lsm6dsl_force_minimal_run_mode();
	err = lsm6dsl_timestamp_set_resolution_6p4ms();
	if (err) {
		LOG_WRN("system_off prep: set timestamp res failed (err %d)", err);
	}
	err = lsm6dsl_timestamp_enable();
	if (err) {
		LOG_WRN("system_off prep: timestamp enable failed (err %d)", err);
	}

	/* Reset timestamp so it starts near 0 */
	err = lsm6dsl_timestamp_reset();
	if (err) {
		LOG_WRN("system_off prep: timestamp reset failed (err %d)", err);
	}

	uint32_t ts;
	err = lsm6dsl_timestamp_read(&ts);
	if (err != 0) {
		LOG_WRN("system_off prep: timestamp read failed (err %d)", err);
		return;
	}
	LOG_INF("system_off prep: imu ts=0x%06x", ts & 0x00FFFFFFu);

	uint64_t epoch_s = (uint64_t)get_utc_time();
	if (epoch_s == 0) {
		LOG_WRN("system_off prep: get_utc_time() returned 0 despite rtc_is_valid");
		return;
	}
	LOG_INF("system_off prep: epoch_s=%llu", epoch_s);

	err = app_settings_save_lsm6dsl_time_base(epoch_s, ts);
	if (err) {
		LOG_WRN("system_off prep: failed to save base (err %d)", err);
	} else {
		LOG_INF("system_off prep: saved base OK");
	}
}

int lsm6dsl_time_boot_adjust_rtc(void)
{
	uint64_t base_epoch_s;
	uint32_t base_ts;
	int err = app_settings_get_lsm6dsl_time_base(&base_epoch_s, &base_ts);
	if (err) {
		LOG_WRN("boot adjust: failed to read saved base (err %d)", err);
		return err;
	}
	if (base_epoch_s == 0) {
		LOG_DBG("boot adjust: no saved base");
		return 0;
	}
	LOG_INF("boot adjust: base_epoch_s=%llu base_ts=0x%06x", base_epoch_s, base_ts & 0x00FFFFFFu);

	err = lsm6dsl_power_ensure_on();
	if (err) {
		LOG_WRN("boot adjust: IMU power ensure failed (err %d)", err);
	}
	err = lsm6dsl_timestamp_set_resolution_6p4ms();
	if (err) {
		LOG_WRN("boot adjust: set timestamp res failed (err %d)", err);
	}
	err = lsm6dsl_timestamp_enable();
	if (err) {
		LOG_WRN("boot adjust: timestamp enable failed (err %d)", err);
	}

	uint32_t ts_now;
	err = lsm6dsl_timestamp_read(&ts_now);
	if (err) {
		LOG_WRN("boot adjust: timestamp read failed (err %d)", err);
		return err;
	}
	LOG_INF("boot adjust: ts_now=0x%06x", ts_now & 0x00FFFFFFu);

	/* The IMU timestamp is a 24-bit counter at 6.4 ms/tick, so it rolls over
	 * every 2^24 * 6.4 ms ~= 29.8 h.  The mask below corrects a SINGLE rollover.
	 * Multiple rollovers (device powered off > ~29.8 h) cannot be detected — the
	 * CPU is off during system_off, so nothing counts wraps — and the recovered
	 * time will undercount by N * 29.8 h.  This is acceptable because the IMU
	 * bridge only needs to span short crash/reboot gaps; any longer gap is
	 * corrected by the next BLE time-sync once the phone reconnects. */
	uint32_t delta_ticks = (ts_now - base_ts) & 0x00FFFFFFu;
	uint64_t delta_us = (uint64_t)delta_ticks * LSM6DS_TIMESTAMP_TICK_US_6P4MS;
	uint64_t delta_ms = delta_us / 1000ULL;
	LOG_INF("boot adjust: delta_ticks=%u delta_ms=%llu", delta_ticks, delta_ms);

	uint64_t new_epoch_ms = (base_epoch_s * 1000ULL) + delta_ms;
	if (new_epoch_ms == 0) {
		return 0;
	}

	err = rtc_set_utc_time_ms(new_epoch_ms);
	if (err) {
		LOG_WRN("boot adjust: rtc_set_utc_time_ms failed (err %d)", err);
		return err;
	}

	/* Clear the base so we don't reapply on every reboot. */
	err = app_settings_save_lsm6dsl_time_base(0, 0);
	if (err) {
		LOG_WRN("boot adjust: failed to clear base (err %d)", err);
	}

	LOG_INF("Applied IMU timestamp delta: +%llu ms", delta_ms);
	return 1;
}
