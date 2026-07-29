#ifndef FEATURES_H
#define FEATURES_H

#include <stdint.h>

/**
 * @brief Defines the bitmask for available Omi features.
 */
typedef enum {
    OMI_FEATURE_SPEAKER = (1 << 0),
    OMI_FEATURE_ACCELEROMETER = (1 << 1),
    OMI_FEATURE_BUTTON = (1 << 2),
    OMI_FEATURE_BATTERY = (1 << 3),
    OMI_FEATURE_USB = (1 << 4),
    OMI_FEATURE_HAPTIC = (1 << 5),
    OMI_FEATURE_OFFLINE_STORAGE = (1 << 6),
    OMI_FEATURE_LED_DIMMING = (1 << 7),
    OMI_FEATURE_MIC_GAIN = (1 << 8),
    OMI_FEATURE_VAD_THRESHOLD = (1 << 9),
    OMI_FEATURE_PRIORITY_RECORD_CAP = (1 << 10),
    /* Firmware accepts the RECORD_TOGGLE button action (byte 6). Lets the app
     * hide the "Single recording button" switch / Toggle option on older
     * firmware that would reject byte 6. */
    OMI_FEATURE_RECORD_TOGGLE = (1 << 11),
    /* On-device diagnostic event log is compiled in (CONFIG_OMI_DIAG_LOG): the
     * BLE 0x0063 drain / 0x0064 control chars exist. The app hides the Debug Tools
     * event-log toggle when this bit is absent. */
    OMI_FEATURE_DIAG_LOG = (1 << 12),
    /* The LED service (0x19B10080/0x19B10081) exists, so the connected (solid
     * blue) indicator can be turned off. Lets the app hide the switch on older
     * firmware, which always shows it. */
    OMI_FEATURE_CONNECTED_LED = (1 << 13),
} omi_feature_t;

#endif // FEATURES_H
