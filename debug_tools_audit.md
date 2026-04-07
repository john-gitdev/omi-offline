# Debug Tools Audit

This document reviews the functionality of the Debug Tools present in `app/lib/pages/settings/sync_page.dart` to verify if they operate according to their given descriptions.

## 1. Sync Omi Segments
**Description:** "Download any pending raw segments from your Omi."
**Implementation:**
- Checks if processing is currently running (`RecordingsManager.isProcessingAny`), blocking the sync if true.
- Calls `ServiceManager.instance().wal.getSyncs().syncAll()`.
- Updates UI based on the response.
**Conclusion:** Matches description. `syncAll` correctly checks for pending segments and syncs them.

## 2. Force Sync Omi
**Description:** "Syncs all pending segments immediately, ignoring the minimum buffer threshold."
**Implementation:**
- Shows a confirmation dialog warning that it will close the current recording segment.
- Calls `ServiceManager.instance().wal.getSyncs().rotateAndSync()`.
- `rotateAndSync` connects to the device, executes a file rotation (`connection.rotateFile()`), updates the missing wals bypassing the minimum buffer threshold (`ignoreThreshold: true`), and then runs `syncAll()`.
**Conclusion:** Matches description. The `rotateFile` command forces the firmware to close the current file and start a new one, allowing immediate download.

## 3. Force Process Omi
**Description:** "Process raw segments immediately, including the newest (may be incomplete)."
**Implementation:**
- Checks if processing is already running.
- Calls `RecordingsManager.forceProcessAll()`.
- `forceProcessAll` retrieves all batches and filters for `rawSegments.isNotEmpty`. Unlike regular processing which skips the newest segment per session to prevent conflict with ongoing writing, `forceProcessAll` intentionally includes all segments.
**Conclusion:** Matches description. It correctly bypasses the `excludeNewestSegmentPerSession` filter.

## 4. Delete Omi Segments
**Description:** "Permanently deletes raw segments from your Omi. The device immediately starts a new recording file."
**Implementation:**
- Shows a confirmation dialog.
- Cancels any active sync.
- Calls `ServiceManager.instance().wal.getSyncs().deleteAllPendingWals()`.
- Resets shared preferences related to sync and processing progress.
- `deleteAllPendingWals` in `SDCardWalSyncImpl` sends the `CMD_CLEAR_STORAGE` (0x14) to the device. If that fails, it falls back to deleting each file individually.
**Conclusion:** Matches description.

## 5. Delete Phone Segments
**Description:** "Permanently deletes raw segment files stored on this phone."
**Implementation:**
- Blocked if processing is active.
- Shows a confirmation dialog.
- Deletes the `raw_segments` directory (`${directory.path}/raw_segments`) recursively.
- Resets shared preferences related to sync progress.
**Conclusion:** Matches description. The `raw_segments` folder contains all the downloaded `.bin` files and markers.

## 6. Delete Phone Conversations
**Description:** "Permanently deletes finalized recordings and conversations, including any open conversation in progress."
**Implementation:**
- Blocked if processing is active.
- Shows a confirmation dialog.
- Deletes the `recordings` directory (`${directory.path}/recordings`) recursively.
- Deletes the `processing_temp` directory (`${directory.path}/processing_temp`) recursively.
- Resets shared preferences related to sync progress.
- Clears the HeyPocket upload history to allow re-upload if files are re-processed.
**Conclusion:** Matches description. `recordings` stores the `.m4a` files and EDL data, while `processing_temp` holds files currently being worked on.
