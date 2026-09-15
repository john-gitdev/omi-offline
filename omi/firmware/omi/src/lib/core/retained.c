/*
 * retained.c — RAM that outlives a reboot, a crash and a power-off. See retained.h.
 */

#include "retained.h"

#include <stddef.h>
#include <string.h>
#include <zephyr/devicetree.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/crc.h>

LOG_MODULE_REGISTER(retained, CONFIG_LOG_DEFAULT_LEVEL);

/* The zephyr,retained-ram node's PARENT carries the address range, the same way
 * retained_mem_nrf_ram_ctrl.c reads it to decide what stays powered in System OFF. */
#define RETAINED_REGION DT_PARENT(DT_NODELABEL(omi_retained))
#define RETAINED_ADDR DT_REG_ADDR(RETAINED_REGION)
#define RETAINED_SIZE DT_REG_SIZE(RETAINED_REGION)

#define RETAINED_MAGIC 0x4F4D4952u /* "RIMO" in memory — arbitrary, just unlikely */
#define RETAINED_VERSION 1

struct retained_mute {
    uint8_t muted; /* 1 = muted; anything else reads as not muted */
    uint8_t reserved[3];
    uint32_t since_utc_s; /* when mute was first engaged; 0 if before a time sync */
    uint32_t crc;         /* crc32 over the fields above */
};

struct omi_retained {
    uint32_t magic;
    uint16_t version;
    uint16_t size; /* sizeof(struct omi_retained), so a layout change is caught too */
    struct retained_mute mute;
    struct retained_diag diag;
};

BUILD_ASSERT(sizeof(struct omi_retained) <= RETAINED_SIZE,
             "retained layout outgrew the sram_retained_mem partition (boards/omi/pm_static.yml)");

static struct omi_retained *const retained = (struct omi_retained *) RETAINED_ADDR;

bool retained_init(void)
{
    const bool intact = retained->magic == RETAINED_MAGIC && retained->version == RETAINED_VERSION &&
                        retained->size == sizeof(struct omi_retained);
    if (!intact) {
        /* First boot after a flash of firmware with a different layout (or of stock
         * firmware, which used this slice as ordinary RAM), or the battery ran flat.
         * Whatever is here is not ours to interpret. */
        memset(retained, 0, sizeof(*retained));
        retained->magic = RETAINED_MAGIC;
        retained->version = RETAINED_VERSION;
        retained->size = sizeof(struct omi_retained);
        LOG_INF("Retained RAM: no valid contents — starting clean");
    } else {
        LOG_INF("Retained RAM: kept from the previous boot");
    }
    return intact;
}

static uint32_t mute_crc(const struct retained_mute *m)
{
    return crc32_ieee((const uint8_t *) m, offsetof(struct retained_mute, crc));
}

void retained_mute_store(bool muted, uint32_t since_utc_s)
{
    struct retained_mute m = {0};
    m.muted = muted ? 1 : 0;
    m.since_utc_s = muted ? since_utc_s : 0;
    m.crc = mute_crc(&m);
    retained->mute = m;
}

bool retained_mute_get(uint32_t *since_utc_s)
{
    const struct retained_mute m = retained->mute;
    if (m.crc != mute_crc(&m) || m.muted != 1) {
        return false;
    }
    if (since_utc_s != NULL) {
        *since_utc_s = m.since_utc_s;
    }
    return true;
}

struct retained_diag *retained_diag(void)
{
    return &retained->diag;
}
