#ifndef __BATTERY_H__
#define __BATTERY_H__

#include <stdint.h>

int battery_set_fast_charge(void);
int battery_set_slow_charge(void);
int battery_charge_start(void);
int battery_charge_stop(void);
int battery_get_millivolt(uint16_t *battery_millivolt);
int battery_get_percentage(uint8_t *battery_percentage, uint16_t battery_millivolt);
int battery_init(void);

#endif
