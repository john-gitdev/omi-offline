#ifndef STORAGE_H
#define STORAGE_H

#ifdef CONFIG_OMI_ENABLE_OFFLINE_STORAGE

#include <stdbool.h>

/**
 * @brief Initializes the Storage Transport thread
 *
 * Initializes the Storage Transport thread
 *
 * @return 0 if successful, negative errno code if error
 */
int storage_init();

/**
 * @brief Stops the current storage transfer
 *
 * Stops the current storage transfer
 */
void storage_stop_transfer();

/**
 * @brief Returns true while a file sync transfer is in progress.
 *
 * Used by other modules (e.g. battery broadcast) to defer non-critical
 * BLE notifications and avoid saturating the TX buffer during sync.
 */
bool storage_transfer_active(void);

#endif // CONFIG_OMI_ENABLE_OFFLINE_STORAGE

#endif // STORAGE_H
