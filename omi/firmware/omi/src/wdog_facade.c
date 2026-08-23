#include <zephyr/drivers/watchdog.h>
#include <zephyr/logging/log.h>
#include <zephyr/kernel.h>

LOG_MODULE_REGISTER(wdog_facade, CONFIG_LOG_DEFAULT_LEVEL);

#define WATCHDOG_TIMEOUT_MS CONFIG_OMI_WATCHDOG_TIMEOUT_MS

static const struct device *wdt_dev;
static int wdt_channel_id;

void watchdog_feed(void)
{
    if (wdt_dev && device_is_ready(wdt_dev)) {
        wdt_feed(wdt_dev, wdt_channel_id);
    }
}

int watchdog_init(void)
{
    int ret;
    struct wdt_timeout_cfg wdt_config;

    // Get watchdog device (nRF5340 has built-in watchdog)
    wdt_dev = DEVICE_DT_GET(DT_NODELABEL(wdt0));
    if (!device_is_ready(wdt_dev)) {
        LOG_ERR("Watchdog device not ready");
        return -ENODEV;
    }

    // Configure watchdog timeout
    wdt_config.flags = WDT_FLAG_RESET_SOC;         // Reset entire SoC on timeout
    wdt_config.window.min = 0U;                    // No minimum window
    wdt_config.window.max = WATCHDOG_TIMEOUT_MS;   // 30 seconds timeout
    wdt_config.callback = NULL;                    // No callback, just reset

    // Install watchdog timeout
    wdt_channel_id = wdt_install_timeout(wdt_dev, &wdt_config);
    if (wdt_channel_id < 0) {
        LOG_ERR("Watchdog install failed: %d", wdt_channel_id);
        return wdt_channel_id;
    }

    // Start watchdog
    ret = wdt_setup(wdt_dev, WDT_OPT_PAUSE_HALTED_BY_DBG);
    if (ret < 0) {
        LOG_ERR("Watchdog setup failed: %d", ret);
        return ret;
    }

    LOG_INF("Watchdog initialized (timeout: %u ms, channel: %d)", WATCHDOG_TIMEOUT_MS, wdt_channel_id);
    return 0;
}

int watchdog_deinit(void)
{
    /* NULL when watchdog_init() failed — main() only logs that, so the device runs
     * on without a watchdog and still reaches here on power-off. wdt_disable(NULL)
     * would fault. */
    if (!wdt_dev) {
        return 0;
    }

    int rc = wdt_disable(wdt_dev);

    /* -EPERM means "this SoC cannot stop its watchdog", which is the nRF5340's
     * permanent answer: Zephyr's nrfx driver returns it unless NRFX_WDT_HAS_STOP,
     * and the STOP task only exists from the nRF54 series onward. Treating that as
     * a failure made turnoff_all() return TURNOFF_BAILED on EVERY power-off — so
     * the 4-tap-hold gesture and "Shutdown Omi" cold-rebooted instead of powering
     * off, and the critical-battery path (which deliberately does not reboot) left
     * the device awake with BLE down and the mic thread aborted, i.e. permanently
     * deaf on a nearly-flat cell.
     *
     * Nothing is lost by accepting it: sys_poweroff() enters System OFF, which
     * stops the watchdog in hardware. The disable is only worth attempting for a
     * part that supports it. */
    if (rc == -EPERM) {
        LOG_INF("Watchdog cannot be stopped on this SoC; System OFF will stop it");
        return 0;
    }
    return rc;
}
