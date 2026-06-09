# Changelog

## App

### 0.21.4

- **New: "Ready to Upload" / "Last Upload Failed at" upload states.**
    - The Integrations section now reads "Ready to Upload" instead of "Pending", and a failed upload shows "Last Upload Failed at: <time>" (formatted per your 12/24-hour setting) instead of a bare "Failed". The day-list cloud badge now counts only the integrations that still need attention rather than the total.
- **New: Upload failures show the actual reason.**
    - When an Omi Cloud upload fails, the snackbar now surfaces the server's error (e.g. a transcription timeout) instead of a generic "failed".
- **Fix: Upload state survives the full lifecycle.**
    - A recording stays "Uploading…" through the upload and the immediate auto-retry window instead of flickering to failed between attempts. A manual upload that fails — or is interrupted by the app being killed mid-upload — now shows "Last Upload Failed" rather than reverting to "Ready to Upload".
- **Fix: Omi Cloud uploads are limited to one at a time.**
    - Starting a second Omi upload while one is in progress is now blocked with a clear message, across both manual upload paths and the background sweep. Firing parallel sync jobs was causing the server to return 503 errors.

### 0.21.3

- **Fix: Force Sync bolt now lands on the last recording when a discard trails it.**
    - When you Force Process and the chronologically-last item was a discard (ghost), the final real recording either got no force-synced bolt or was left unfinalized as a draft. The bolt now correctly marks the last actual recording — trailing discards/ghosts after it no longer count as "later audio."

### 0.21.2

- **New: Per-integration upload status.**
    - The day-list cloud icon is now an at-a-glance indicator — colored by the worst state needing attention, with a small badge counting how many integrations apply (2+). It has no tap action of its own; tapping the recording opens the player, which now shows an **Integrations** section: a row per integration with its own state (Uploaded / Pending / Failed / Uploading / Not available, with a plain-language reason when a recording can't be uploaded) and a per-integration Upload / Retry / Re-upload action, plus "Upload all pending". You can now retry just the one integration that failed instead of re-uploading to all of them.
- **Fix: Manual upload now works on recordings made before auto-upload was enabled.**
    - Tapping the cloud icon on such a recording previously failed with "No integrations enabled for upload." The auto-upload time cutoff was wrongly gating explicit manual uploads; it now only governs the background auto-upload sweep. Eligibility is per-integration: HeyPocket can upload any recording whose audio still exists, while Omi can only upload recordings that have a processing-time `.bin` (created only while Omi sync is enabled).
- **Fix: Auto-upload no longer sweeps up recordings older than the toggle.**
    - When no "auto-upload enabled" time was recorded (a legacy/zero timestamp), the cutoff check was skipped entirely and every recording — including ones made before you turned the toggle on — became eligible for auto-upload. It now fails closed: with no recorded enable-time nothing is auto-uploaded (you can still upload manually). Relatedly, the cutoff is now stamped only when you toggle Auto-Upload on — not when you save/validate an integration key.
- **Fix: Delivered recordings no longer show a red cloud icon.**
    - The upload icon was keyed off auto-upload eligibility (the time cutoff) instead of actual delivery state, so an already-uploaded recording could flip back to red after the cutoff moved forward. The icon now reflects real per-integration delivery, and recordings that no integration can upload (e.g. Omi-only with no `.bin`) show a greyed-out "can't upload" icon instead of a red one that errors on tap.
- **Fix: Clearer Omi error for un-uploadable recordings.**
    - When Omi has no upload file for a recording (its `.bin` is only created when Omi sync is enabled at processing time), the error now says it was processed before Omi sync was enabled, instead of incorrectly blaming passthrough cleanup.
- **New: Auto-upload cutoff shown on the Integrations page.**
    - Each integration with Auto-Upload on now shows the date/time from which recordings are auto-uploaded, with a reminder that earlier recordings must be uploaded manually via the cloud icon. Respects the 12/24-hour time preference.
- **Improved: Consistent player controls.**
    - Removed the 1×/1.5×/2× playback-speed toggles from the marker recording player so it matches the normal recording player's transport controls.
- **Removed: OGG (Opus) save format.**
    - The recording save-format setting now offers only WAV and M4A. OGG (which was Android-only) has been removed, along with its in-app Ogg encoder/stitcher. Anyone who had OGG selected is moved to WAV automatically; no existing recordings are touched.

### 0.21.1

- **Fix: Android pairing "channel-error".**
    - Added the required `android.software.companion_device_setup` manifest feature so the Companion Device pairing dialog actually opens instead of failing with a `PlatformException(channel-error)`. The native association call is now wrapped so any failure surfaces the real error instead of an opaque channel error.
- **New: BLE connection-failure diagnostics.**
    - The firmware now counts failed BLE connection establishments (and whether they happened during slow vs fast advertising), persists the count across reboots, and exposes it over the diagnostics characteristic. Surfaced in Debug Tools and written to "Save Diagnostic Logs to File" on connect — so a connect-failure that needs a device restart to recover can still be diagnosed after rebooting. Helps investigate the intermittent "Omi is advertising but won't connect" case.
    - The "SD Write Drops" panel is renamed **Diagnostics** (it now also shows BLE connect failures), with separate "Reset drops" and "Reset BLE" baselines — the BLE baseline survives a device reboot, the drops baseline resets with the device.
- **Improved: Adjustment Mode controls (Debug Tools).**
    - Turning on Adjustment Mode while a recording is in progress now asks you to confirm finalizing the current draft first.
    - The Adjustment Mode card now shows when it was enabled and how many bins are held in the isolated adjustment folder (refreshed each time you open Debug Tools), and matches the styling of the SD Write Drops card.
- **Firmware:** bumped to `oo-1.9.4`.

### 0.21.0

- **Fix: False-positive "Connected" snackbar.**
    - Fixed a bug where a Bluetooth connection timeout (e.g., during "Reset Connection") would erroneously show a success snackbar instead of an error message.
- **Improved: Notification readability.**
    - Expanded 'Bat' to 'Battery' in the 'Next Sync' idle notification subtext for better clarity.
- **Improved: Device Scanning Feedback.**
    - The "Scan Again" button now explicitly notifies the user if a background scan is already in progress instead of appearing to fail instantly. This notice only appears on an explicit Scan/Refresh tap — automatic scans (opening the page, rescanning after forgetting a device) silently defer to the running scan.
    - Added a persistent circular progress indicator on the "Find Omi Devices" page that reflects background scans (e.g., from "Reset Connection"), ensuring the user has continuous visual feedback.
- **Improved: Android Connectability.**
    - Integrated Android Companion Device Manager to establish a formal OS-level association when pairing. This significantly improves connection reliability and ensures the app can always find and wake the device, even in the background.
- **Fix: Bluetooth connection deadlock.**
    - Fixed a deadlock in `DeviceService` where a background discovery attempt with a "desirable device" would block on the same mutex as the primary connection attempt, leading to the app getting stuck in a "Scanning" state indefinitely.
    - Improved `DeviceService.discover()` resilience to ensure the scanning status is always cleared even if a connection attempt blocks or fails.
- **Fix: Recording timestamps after auto-reconnect.**
    - The firmware clock is now re-synced on every reconnect, not just manual connects. Previously a native auto-reconnect (e.g. after a device reboot) could leave the device with a reset clock, mis-stamping subsequent recordings.
    - The scanning progress indicator on "Find Omi Devices" now updates reactively when a background scan starts or finishes.
    - "Find Omi Devices" now also lists devices found by background scans, instead of showing "No devices found" right after one completes.

### 0.20.4

- **Fix: SD Card Sync robustness.**
    - The BLE manager now correctly pads dropped packets (protocol gaps) with zeros instead of failing and aborting the transfer, preventing the sync queue from getting permanently stuck on a corrupted file.
    - Bounded the zero-padding to 8 MB so an absurd offset from a corrupt header fails the single transfer cleanly instead of attempting a huge allocation.
- **Improved: Retain trailing silence in recordings.**
    - The VAD processor no longer trims the trailing silence (the "silence to split" duration) from the end of finalized recordings. The entire buffered audio block that triggered the split is now saved within the audio file.
    - As a result, the `silence_trimmed` discard records are no longer generated.
- **Improved: Device Troubleshooting UI.**
    - Added a permanent, full-width "Reset Connection" button to the "Find Omi Devices" page to improve visibility and ease of access during troubleshooting.
    - Optimized the device list layout to ensure the troubleshooting button remains accessible at the bottom of the screen.
- **Improved: Sync Notifications.**
    - Added granular tracking for "Partial" vs "Complete" syncs.
    - Refined the background notification format to "Last Sync: [Status] • [Time] • [Battery]% Bat" for better clarity and conciseness.
    - Fixed a partial background sync stamping the previous successful sync's time — the notification now shows "Partial" alongside the time the partial sync actually ran.
- **Fix: Passthrough uploads no longer drop recordings from the list.**
    - After a successful passthrough upload, the metadata flag is now written in place rather than appended past the end of the sidecar. Previously the flag was never actually recorded, so once the local audio was freed the recording could not be reconstructed and silently disappeared.
- **Fix: "Reset Connection" button visibility.**
    - The button now appears whenever a device pairing is stored — including on a fresh launch when the saved device refuses to connect, the exact case it exists for. Previously it only showed after a successful connection or a mid-session disconnect.
- **Improved: VAD processing resilience.**
    - A transient failure in the native VAD batch runner now falls back to per-window voice detection for just the affected batch, keeping the model active for the rest of the run instead of treating all remaining audio as speech.
- **Improved: Auto-upload concurrency.**
    - Background auto-upload no longer throttles multi-slot integrations (e.g. HeyPocket) down to a single concurrent transfer; the per-integration concurrency limit is now respected.
    - The Wi-Fi-only connectivity check now fails closed if it errors, so uploads are skipped rather than proceeding on cellular.
- **Improved: Adjustment Mode safety.**
    - Turning off Adjustment Mode now asks for confirmation before deleting the isolated copy of raw bins (only when an archive exists).

### 0.20.3

- **Improved: Device Discovery and Connectivity.**
    - Relocated "Forget Device" functionality from Debug Tools to the "Find Omi Devices" page for better accessibility when resolving connection issues.
    - Added "Forget Device" button under "Scan Again" when no devices are found during discovery.

### 0.20.2

- **Improved: Debug Tools and App Settings UI.**
    - Reorganized 'App Settings' page with a more logical flow: Auto Sync Interval, Upload on Wifi Only, Save File Format, Short Recordings, Retention, and Time Format.
    - Updated Debug Tools toggles to match the visual style of App Settings (containers, typography, and accent colors).
    - Fixed an inconsistent spacing gap in the Debug Tools menu.
- **Improved: Short Recording Cleanup.**
    - Enhanced 'Clean up Short Recordings' to delete "ghost" discard records (VAD-rejected audio) in addition to finalized recordings.
    - Optimized cleanup performance by batching deletions and reducing UI reloads.

### 0.20.1

- **Fixed: Delete Day with ghost recordings.**
    - Fixed an issue where the 'Delete Day' button was inactive or non-functional if a day only contained ghost recordings (discards).
    - Refined 'Delete Day' to handle full day deletion (including raw audio bins) when filters are disabled or 'All' view is selected.

### 0.20.0

- **Added: Adjustment Mode.**
    - Added a new 'Adjustment Mode' toggle in Sync Settings to safely copy all incoming raw segments to an isolated folder for reprocessing.
    - The recordings list now synchronously displays an `| ADJ` tag when all underlying bins are successfully backed up.
    - Added a button to manually copy isolated bins back into the processing pipeline.
- **Removed: Adjustment Mode and Reprocess Day.**
    - Completely removed the 'Adjustment Mode' toggle and the 'Reprocess Day' pipeline.
    - Simplified the underlying sync storage model. Unprocessed raw bins are now strictly and unconditionally pruned by the 48-hour recovery sweep, freeing up disk space more aggressively and reliably.
    - Removed 'Surgical Delete' restrictions from day-wipes, leading to a more robust, full-delete standard behavior.
    - Discarded complex state management and UI wrappers built to gate processing/uploads during Adjustment Mode.
- **Fix: Prevent empty day cards from rendering.**
    - Fixed a bug introduced during the Adjustment Mode removal that caused empty UI cards to render for days that only contained unprocessed raw audio segments.
- **Improved: Application Crash and Sync Resilience.**
    - Added extensive unit tests covering synchronization robustness against process deaths, unexpected hardware disconnections, and partial downloads.
    - Hardened the `processAll` audio pipeline to gracefully reset internal states (`processingProgress` and `minutesRemaining`) back to idle instead of locking the UI when isolates die or throw unhandled exceptions.
    - Standardized test coverage for `TimeoutException` and `SocketException` paths across cloud integration clients (Omi and HeyPocket), verifying they present user-friendly fallback behavior.

### 0.19

- **Added: AAD/VAD designation in recording list.**
    - Added a processing mode indicator (AAD or VAD) next to the recording size in the recordings list and player pages, making it easy to see which recordings were processed with Silero VAD.
    - Updated the metadata format to persist the processing mode in `.meta` files.
- **Moved: 'Short Recordings' setting to App Settings.**
    - Relocated the 'Short Recordings' filter from 'Recording Settings' to 'App Settings' to centralize application-wide filters.
    - Enabled 'Short Recordings' filtering for 'Manual Mode'. Previously, manual recordings were always shown regardless of length.
    - Added a 'Clean Up Short Recordings' button to the App Settings page, allowing users to batch-delete recordings that match the current filter.
- **Fix: Resolved back-to-back recording splits on marker tap.**
    - Fixed a race condition where the VAD-resume signal (waking the device after silence) would ignore the marker protection window and trigger an immediate split.
    - Improved Marker protection robustness by anchoring the 50s window to the raw hardware RTC (Real-Time Clock) instead of the drifted audio timeline.
    - Added a wall-clock fallback for marker protection on devices that haven't yet performed their first time-sync.
- **Improved: Ghost-aware Stitching Timeline.**
    - Upgraded the recordings stitcher to include `DiscardRecord`s (ghosts) in its chronological timeline. The app now correctly identifies when a conversation has ended by tracking cumulative non-speech duration (silence gaps + ghost records) against the user's "Silence to Split" threshold.
    - Fixed a bug where conversations would stay stuck "In Progress" indefinitely because the stitcher was "blind" to subsequent noise-only events.
- **Improved: Full-Fidelity Audio Preservation.**
    - Intermediate ghost recordings that fall within the split threshold are now automatically "healed" into the main recording. The app re-decodes the raw audio from these discarded segments and preserves them in the conversation file, ensuring that contextual background noise (like a cough or door slam) is not lost.
- **Improved: Stitching Robustness.**
    - Optimized `_mergeMeta` to safely handle stitching gaps and ghost segments, ensuring accurate duration and peak data preservation even when no subsequent speech file is present.
    - Fixed a "Finalization Race" that could lead to back-to-back recordings being permanently split into separate files.
- **Improved: Ghost Notification Visibility.**
    - Systems-discarded "ghost" audio segments are now always visible in the recordings list, even when short-recording filters are disabled.
    - Unified the short-recording behavior to always "Hide" rather than "Delete", ensuring that all captured audio remains recoverable through the ghost row interface.
    - Ghost recordings now follow the same duration-based tab filtering (Main / Hidden / All) as valid recordings.
- **Simplified: Recording Settings.**
    - Removed the "Action for Short Recordings" setting. The app now defaults to hiding short recordings from the main list while keeping them on the device for recovery.
    - Filter tabs (Main / Hidden / All) now only appear when a duration filter is active (`Short Recordings > 0`), keeping the UI clean for users who prefer no filtering.
- **Refactored: Simplified Backend.**
    - Completely removed the `discardShortRecordings` preference and simplified the VAD processing pipeline. Audio is never permanently deleted based on duration.
- **Fix: Repaired corrupted `recordings_controller.dart`.** Removed syntax-breaking duplicate code and fragment garbage at the end of the file that prevented compilation.
- **Fix: Resolved background notification persistence.**
    - **Hand-off to Idle Notification**: Fixed a bug where background syncs would stop the foreground service after the "Conversations ready" message, causing the notification to disappear. The notification now seamlessly transitions to the "Next sync" countdown, ensuring the service remains active.
    - **Lifecycle Awareness**: The foreground service is no longer prematurely stopped when a success or processing pass completes while the app is in the background.
- **Fix: Resolved syncing notification regressions.**
    - **Harmonized segment counts**: Foreground and background syncs now both use `estimatedTotalSegments`, ensuring consistent progress reporting (e.g., "1 of 5") instead of using the total device history.
    - **Instant notifications**: Moved the foreground service start to the very beginning of the pipeline. The notification now appears instantly (showing "Preparing...") instead of being delayed by heavy disk operations.
    - **Synchronized processing estimates**: The notification now immediately reflects the same filtered "minutes to process" estimate as the app banner, preventing confusing mismatches during the first few seconds of processing.
- **Improved Observability: Live BLE connection status.** Removed the guard that suppressed connection updates during sync intervals. The native BLE notification (ID 2001) now reflects the live "Connected" or "Connecting..." status in real-time.
- **Fix: "Recover to Recording" now correctly bypasses discard filters.** Previously, trying to recover a ghost recording would fail because the system filtered out bins already marked as discards. The pipeline now respects settings overrides to ensure targeted recovery of raw audio.
- **Fix: Resolved "sticky" processing banner.** Synchronized the UI's "Audio to Process" calculation with the actual pipeline filtering. The banner now correctly accounts for "covered" bins (audio already in recordings), preventing it from getting stuck on lingering raw data.
- **Improved Robustness: Automatic bin pruning after manual processing.** Added a mandatory cleanup step after manual processing runs to delete raw bins that have been successfully finalized or covered.
- **Improved Robustness: Hardened processing isolate.** The processing pipeline now requires a explicit completion handshake, ensuring that isolate crashes or watchdog kills do not lead to premature deletion of raw source audio.
- **Documentation: Updated project memory and comments to reflect WAV as the default audio format.**
- **Fix: Manual upload now shows a snackbar error when WiFi is required.** Previously, clicking the upload button while on cellular data with "Upload on Wifi Only" enabled would fail silently. The UI now catches the exception and displays the specific "WiFi required" message to the user.
- **Improved Observability: Manual upload failures are now recorded in Debug Tools.** Errors during the manual upload flow (including WiFi restrictions and integration failures) are now passed to the `Logger.error` system so they appear in the in-app log viewer and persistent log files.
- **Performance: Android Native VAD Batch Runner.** Processing large backlogs is now significantly faster and more power efficient on Android. The app now keeps the ORT session, the recurrent LSTM state, and the context window entirely within a background native Kotlin thread, and evaluates VAD across a batch of acoustic frames in a single platform-channel invocation rather than incurring thousands of synchronous FFI crossings per minute of audio. iOS and non-Android platforms fall back seamlessly to the standard per-window evaluation while preserving bit-identical VAD decisions.
- **Added "Upload on Wifi Only" toggle.** New setting in App Settings allows restricting cloud uploads (Omi, HeyPocket, etc.) to WiFi connections only, preserving mobile data. The toggle is automatically disabled if no integrations are configured.
- **Refactored Generic Integration Architecture.** Centralized all cloud integration logic into a extensible strategy pattern. This allows adding new integrations by updating a single file while automatically inheriting WiFi controls, status tracking, and background sync logic.
- **Improved Observability.** Moved high-level upload logging into service-specific clients for clearer, non-redundant debugging information.
- **Simplified background sync pipeline.** Removed the redundant second "finalizing" sync that occurred after processing. The sync completion timestamp is now updated immediately after the primary data retrieval, ensuring the auto-sync timer is refreshed even during long processing runs. This prevents confusing behavior where audio recorded during processing was downloaded but left unprocessed until the next manual or scheduled sync.
- **Fix: "Audio to Process" banner no longer gets stuck after a background sync that downloads a continuation bin.** If a new bin arrived on the device while the previous processing run was finishing its draft flush, the next pipeline would mark that bin as already "covered" by the open draft's coverage interval (draft end + 120 s VAD-split slack), skip processing, call it done, and leave the bin sitting on disk — so the banner reappeared on every reload. Draft files are now excluded from coverage-interval computation; only finalized recordings gate the idempotency filter.
- **Fix: background sync now fires on time even when Android freezes the Dart isolate.** Previously, if the OS suspended the Flutter runtime (despite the foreground service being alive), the scheduled sync timer and heartbeat both stopped firing — the notification would show a stale "Next sync at X:XX" with no sync occurring until the user opened the app. A native `AlarmManager` exact alarm (`setExactAndAllowWhileIdle`) is now armed whenever Dart sets the next sync time. When the alarm fires, it delivers the sync request natively, bypassing the frozen Dart layer. The alarm re-arms itself from shared prefs so it survives repeated Dart freezes without requiring Dart to reschedule.
- **Overhauled notification layout.** The sync notification now uses title + subtext consistently: idle shows "Next sync at X:XX PM" / "Last sync completed at X:XX PM · 85%"; active phases show "Syncing recordings" / "45% complete" and "Processing recordings" / "67% complete". Progress updates every 5 seconds in both foreground and background. The native BLE notification (always-on) shows connection state only (Connected / Connecting / Disconnected).


### 0.18

- **Fix: sync-timer notification no longer shows a stale countdown.** Previously the "Next sync in ~N min" text was recomputed and pushed from Dart every ~60 s via the `flutter_foreground_task` heartbeat. When Android's battery optimizer suspended the main isolate, the text would freeze — showing "27 minutes ago" in the notification timestamp while still reading "~29 min". The persistent `flutter_foreground_task` notification (ID 2002, `START_STICKY`) now shows the absolute scheduled time ("Next sync at 3:45 PM") and cycles to sync/processing progress during active runs, then back to the new scheduled time after. Text is never stale by more than one sync interval.
- **New: BLE service notification (ID 2001) shows device battery level and last-connected time.** The always-on `OmiBleForegroundService` notification now shows "78% · 3:45 PM" — the last known battery level and the time it was read (which coincides with the last device connection and sync). Updated on every battery reading via a new `setDeviceBattery` Pigeon call. Useful at a glance when the device is disconnected between syncs.
- **Voice Activity Detection defaults to off in Automatic Recording Mode.** Auto-mode VAD must now be enabled by the user (with a one-time confirmation warning). Enabling it shows that Silero VAD uses more battery and takes longer to process than the default AAD mode, with a "Don't show again" option.
- **Fix: Reprocess Day now correctly identifies sessions from folder names.** The identification logic previously looked at bin filenames (timestamps), causing a mismatch with the session IDs stored in recordings. The system now extracts IDs from the parent session folder, ensuring that recordings with backing audio are correctly identified for surgical deletion.
- **Hardened Reprocess Logic with Precision Bin-Mapping.** Recordings now store the exact list of raw bins used (`relativeBins`) in their `.meta` sidecar. The "Reprocess Day" flow uses this metadata to verify that 100% of the required audio is present on disk before allowing a deletion or UI clear, protecting against audio loss while maintaining backward compatibility for older recordings.
- **Fix: Reprocess Day UI now reliably shows a blank slate before processing starts.** The previously implemented `endOfFrame` yield was occasionally too fast for the Android rendering engine to paint the empty list before heavy disk I/O blocked the main thread. A 50ms delay has been added to ensure the "optimistic delete" is always visible to the user. Reprocess Day now also fully refreshes all three filter tabs (Main / Hidden / All) before processing starts.
- **Fix: Reprocess Day no longer deletes bins shared between a ghost record and a valid conversation.** Firmware writes ~5-minute bin files that routinely span multiple conversation chunks. A noise chunk discarded by SileroVAD would list the whole bin in its ghost record's `relativeBins` (without the `excludeBins` guard that `silence_trimmed` applies), so the same bin was referenced by both the valid recording and the ghost. `deleteDay(onlyReprocessable: true)` was calling `removeDiscardRecord(..., deleteBins: true)` unconditionally, deleting those shared bins and making subsequent Reprocess Day runs progressively lose more audio until all bins were gone and only "Delete Day" remained. Fixed by passing `deleteBins: !onlyReprocessable` — ghost record jsonl entries are still cleared (so grey ghost rows disappear) but their bin files are preserved for the next `processAll` run to re-evaluate with current VAD settings.
- **Fix: Reprocess Day now clears the conversation list immediately on confirmation.** Previously the old recordings stayed visible until the async delete and disk reload completed. The controller now optimistically zeros out the day's conversations in the displayed batch list the moment the user confirms, so the card shows a blank slate before any I/O begins.
- **Adjustment Mode improvements.** Added a persistent orange banner at the bottom of the Conversations screen while Adjustment Mode is on, indicating that all recordings are shown (not just processed ones). Tap the banner to turn off Adjustment Mode and process all remaining raw audio with current settings in one step. Auto-upload settings (HeyPocket and Omi) are now automatically saved and disabled when entering Adjustment Mode, and restored upon exit. The subtitle on the banner clarifies that minutes-to-process counts all bins including those already processed.
- **Improved Auto-Upload Protection via Toggle-Restore & Time-Gating.** Enabling an auto-upload toggle now refreshes a "Start Time" gate (added for Omi to match HeyPocket), ensuring the app only syncs recordings created after the toggle was flipped. Reprocessed recordings (which have older timestamps) are thus automatically skipped by the auto-upload loop, allowing the app to safely clear old integration flags during `reprocessDay` for a clean UI without risking duplicate uploads.
- **Fix: Adjustment Mode cleanup now reprocesses all bins, not just unprocessed days.** Previously "Turn Off & Reprocess" only ran processing on days with no existing recordings, skipping days that had already been processed. Now every batch with a backing bin is deleted and reprocessed. Recordings without a bin backup are preserved in all cases.
- **Fix: Android 14+ foreground notification returns if swiped away.** Android 14 allows users to dismiss ongoing foreground notifications. The app now handles the dismissal intent by immediately re-posting the notification, ensuring the sync/processing service remains protected from OS termination. Both the BLE connection notification and the sync/process notification now return after being swiped away—the BLE notification attaches a `deleteIntent` broadcast, and the sync/process notification always stops and restarts the foreground task at the beginning of each pipeline run, guaranteeing a fresh notification post.
- **Fix: Foreground service no longer risks dropping during background sync.** The sync/processing notification now updates in place instead of stopping and restarting the foreground service. Restarting could hit the Android 12+ "start foreground service from background" restriction and leave the app with no foreground service mid-sync; updating in place still re-posts the notification if it was swiped away on Android 14+.
- **Fix: Real-time WAL sync speed updates.** The sync speed calculation was moved from the "segment boundary" callback to the packet-level progress callback. KB/s values in the UI now update smoothly at ~50Hz instead of jumping in large bursts at the end of each multi-megabyte file.
- **Fix: Reprocessed days stay visible in the list while processing.** The `visibleBatches` filter and `BatchCard` rendering now account for days that are empty but contain raw audio to be processed. The day card remains in the list as a "blank slate" with a progress bar, rather than vanishing until the first recording is finished.
- **New: Real-time "ghost row" updates during processing.** The UI now triggers a refresh whenever a "discard" (noise/silence) segment is identified. Ghost rows pop into the list immediately as they are finished, providing continuous visual feedback during long processing runs.
- **Fix: sync/process foreground notification now updates every 10 minutes instead of every 1–2 seconds.** The Android status-bar notification during sync and processing was being reposted on every UI tick (1–2 s throttle), causing unnecessary CPU wake-ups and battery drain in the background. Progress ticks are now throttled to a 10-minute interval; state transitions (starting a sync, switching from sync to processing, etc.) still post immediately so the notification always reflects the current phase.
- **Fix: waveform display now uses percentile normalization instead of fixed log scaling.** Consistently-loud recordings mapped nearly every bar to near-maximum height, making the waveform look like a solid block. The waveform is now normalized per-recording using the 5th–95th percentile of its own amplitude data, so relative variation is always visible regardless of absolute recording level. A guard prevents flat or silence-only recordings from being amplified into fake variation. This replaces the log-scale (dBFS with −40 dB floor) approach from 0.16, which was an intermediate solution.
- **New: Recording Settings shows a warning when battery optimization is active.** A red card appears at the top of Recording Settings when Android has not exempted the app from battery optimization. Tapping Fix opens the system prompt ("Don't optimize") so background processing is no longer killed by the OS when the screen turns off. The card disappears automatically once the exemption is granted.
- **Fix: Android no longer throttles the VAD processing isolate when the screen goes off.** Added a `PARTIAL_WAKE_LOCK` around the background sync+process cycle. Without it, Android's CPU governor downclocks the Dart isolate's thread scheduling when the screen turns off, spiking the per-inference platform-channel latency from ~1 ms to ~10 ms and slowing processing 3–5×. The WakeLock is acquired at the start of `_doBackgroundSync` and released unconditionally in `finally`, holding for the full BLE sync + VAD processing run.

### 0.17

- **Fix: foreground service type now includes `dataSync` alongside `connectedDevice`.** `connectedDevice` alone loses its justification once the BLE device disconnects mid-processing, giving Samsung/Xiaomi/OPPO battery managers a reason to kill the service. Adding `dataSync` declares a legitimate long-running data task that stays valid regardless of BLE state.
- **Fix: notification channel upgraded from LOW to DEFAULT importance.** OEM battery optimisers specifically target foreground services whose notification channel is LOW-importance as kill candidates. DEFAULT places the channel in a protected tier. `onlyAlertOnce: true` is preserved so only the first appearance makes a sound.
- **Fix: processing stall watchdog no longer stops the foreground service on a false trigger.** Android can suspend background isolate threads while the main UI thread stays alive, causing the heartbeat to stop even mid-active-segment. The watchdog was then calling `stopForegroundTask()`, removing the OS protection that keeps the process alive, after which Android killed the now-unprotected process. The foreground service is now preserved on processing stalls so the process survives and restarts cleanly. The service is only stopped on sync stalls, where there is nothing to protect.
- **Fix: processing stall timeout extended from 3 minutes to 10 minutes.** Thermal throttling after a long initial run can slow per-segment processing 5×, pushing individual segments beyond the old 3-minute window even when the isolate is healthy. 10 minutes gives ample headroom while still bounding a genuine native deadlock.
- **Fix: checkpoint resumes correctly after a process kill followed by new syncs.** After Android kills the app mid-processing, the checkpoint was always discarded on restart because new segments had been downloaded and old ones deleted, shifting every index. The checkpoint now uses the last completed segment's timestamp as the boundary: the first current segment with a later timestamp becomes the resume point.
- **Android: background sync now fires reliably even when the foreground service is killed by OEM battery managers.** A WorkManager `PeriodicWorkRequest` is registered whenever the sync interval is set and re-armed on every app start. When it fires, if the Flutter engine is alive it delivers `onBackgroundSyncRequested` to Dart so the normal connect-and-sync pipeline runs. If the process was killed entirely, sync is deferred silently to the next app open.
- **Android: sync and processing now survive swiping the app away.** The foreground service that keeps the Dart isolate alive during sync and VAD processing no longer carries `stopWithTask`, so dismissing the app from the task switcher mid-run no longer kills it. The service still self-cleans when processing finishes.
- **Android: battery optimization exemption is now requested at first device connect.** On OEM devices with aggressive battery managers (MIUI, ColorOS, OnePlus), the system exemption dialog now appears the first time a device pairs.
- **iOS: BGProcessingTask registered for background sync.** A `BGProcessingTask` (`com.omi.offline.sync`) is registered on launch and scheduled whenever the app backgrounds. When iOS fires it, it calls the same sync path as the Dart timer tick — allowing periodic syncs to run even after the app has been in the background for an extended period.
- **Fix: build failure from missing `disconnectPeripheral` in Pigeon spec.** The method was implemented in both native layers and called from Dart, but was never declared in `pigeon_interfaces.dart`. A Pigeon regeneration silently dropped it from the generated Dart file, causing an Android build failure.
- **BLE storage transfers on Android now run entirely in native code.** SD card file downloads previously routed each BLE packet through the main handler → platform channel → Dart callback at ~50 Hz, which Android throttles heavily when the app is backgrounded. The new path (`downloadStorageFile` via Pigeon) receives BLE notifications directly on the binder thread in Kotlin, writes bytes to the output file natively, and signals Dart only on completion. Dart polls the output file size at 1 Hz for WAL progress tracking. iOS is unchanged.
- **Adjustment Mode sync now skips bins already covered by an existing recording.** Previously, every sync in Adjustment Mode would re-decode and re-run the VAD on all preserved raw bins — including bins that already produced a recording — wasting significant compute and time. The sync paths now compute which bins are fully covered by existing recordings and skip them. Bins remain on disk for Reprocess Day; only the VAD input is filtered.
- **Only Reprocess Day and the debug Force Process reprocess bins that already have a recording.** Reprocess Day deletes the day's recordings first so all bins re-run with current VAD settings. The debug Force Process bypasses the coverage filter entirely.
- **Faster connection when device is in range but BLE stack is slow.** A 5 s timeout was firing before the full GATT + service-discovery + MTU pipeline could finish (6–12 s on some phones), causing the app to fall back to a 10 s BLE scan it didn't need. The app now uses the GATT physical-connect event as the decision point: if the device physically connects within 5 s, the app waits for the full pipeline without scanning; if not, it starts a BLE scan in parallel while native keeps retrying.
- **More diagnostic logging throughout the connection path.** Logs now show GATT physical connect timing, device-ready timing, when the background drop-guard fires, and when `ensureConnection` returns unexpectedly null.
- **Fix: "Processing recordings" notification now clears reliably when done.** The BLE foreground service and the sync/processing foreground service were sharing Android notification ID 2001. When the sync service stopped, Android would re-post the BLE service's notification using stale cached text. The two services now use separate notification IDs and channels (`omi_ble_channel` / `omi_sync_channel`), so each owns its notification independently.
- **Added "Forget Device" to Debug Tools.** Clears the stored Bluetooth pairing so the app can rediscover the device fresh — without needing to uninstall. Useful if the device is visible but refuses to connect after a firmware update wiped bonding keys.
- **Firmware OTA no longer wipes BLE bonding keys or app settings.** The MCUmgr DFU was configured with `eraseAppSettings=true`, which wiped the NVS settings partition before every update. This deleted BLE bonds (requiring a re-pair on iOS after every flash) and deleted the stored firmware version string — causing the firmware's own version-change SD wipe to fire on every boot post-OTA, even when reflashing the same version. Setting `eraseAppSettings=false` restores correct behaviour.
- **Firmware OTA update no longer disconnects mid-transfer.** The app was cancelling its keep-alive timer when starting a DFU, but the MCUmgr SMP protocol uses a different GATT service than the Omi storage characteristic — so the firmware's 30 s idle-disconnect timer was never being reset during the transfer. The keep-alive now continues running throughout DFU.

### 0.16

- **Waveform bars now reflect subtle level changes instead of appearing as a solid rectangle.** Loud or steady recordings previously rendered as a flat block because amplitudes were mapped linearly. Waveform values are now converted to dBFS with a −40 dB floor so quiet passages and level variations are perceptually visible in both the recording player and the marker player.
- **Audio that VAD already discarded as noise is no longer re-decoded on every sync.** A date-key mismatch (raw-segment batches are keyed by epoch seconds misread as milliseconds, landing them in a 1970 bucket, while discard records are filed under the real date) left the reprocess-skip filter empty — so previously-discarded audio re-ran the full VAD pass each cycle. The skip filter now reads the complete persisted discard set, and the banner estimate matches what will actually be processed.
- **Raw audio segments now group under their real date instead of January 1970.** The bin-filename timestamp (epoch seconds) was being read as milliseconds, so every segment was bucketed into 1970 and split from the same day's recordings in the batch list. Fixed at the source, so a day's raw segments, recordings, and discards share one batch.
- **Silero VAD now runs with tuned ONNX Runtime session options.** Both session-creation paths (foreground and the background processing isolate) now apply tuned threading and request the XNNPACK CPU execution provider when available, with automatic CPU fallback. Silero is a tiny recurrent model invoked ~112k times per recorded hour, so removing thread-pool overhead and using faster ARM CPU kernels speeds the decode/VAD pass with no change to VAD decisions.
- **Added opt-in VAD timing diagnostics.** With "Save Diagnostic Logs to File" enabled, the processor logs average per-inference timing every ~64 s of audio, plus a one-time line recording which ONNX execution provider and thread config the session actually used.
- **Recording save is faster across all formats (WAV, M4A, OGG).** The WAV path no longer writes PCM to a temporary `.raw` file and copies it back to add the header — it counts samples up front, writes the header first, and streams PCM straight to the final file, eliminating ~2× the file size in disk I/O on long recordings. Silence-gap waveform computation is now O(buckets) instead of O(samples).
- **Fixed a WAV corruption case when audio frames are dropped.** When a recording contains unreadable or undecodable frames, the single-pass WAV header is now patched with the true byte count after writing, so the `data`/RIFF sizes always match the file.
- **Foreground notification is now fully silent.** Two fixes ensure the notification never makes sound or vibration: (1) the notification channel priority is set to LOW with `onlyAlertOnce: true` to prevent sound on status updates, and (2) channel-level silencing (`setSound(null, null)` and `enableVibration(false)`) plus notification-level silencing (`.setSilent(true)` and `.setOnlyAlertOnce(true)`) to cover cached configurations from prior installs.
- **SD Write Drops panel now shows "Waiting for sync to complete…" when a file transfer is in progress.** The drop-counter poll is intentionally skipped during active storage operations to avoid GATT conflicts, but the UI previously showed the generic loading text regardless.
- **File transfers no longer time out with "Stream closed without EOT" on large files.** The Dart-layer keep-alive was skipped whenever a storage operation was in flight (`isStorageBusy`) — so any file read longer than 30 s would hit the firmware's idle timer mid-transfer. The fix moves the keep-alive to the native Android service: `OmiBleManager.startStorageKeepAlive()` sends `0x32` with `WRITE_TYPE_NO_RESPONSE` every 15 s, bypassing the GATT command queue entirely so it never stalls an in-flight read.
- **Opening Debug Tools no longer triggers a Bluetooth pairing dialog or disconnects the device.** The `ensureConnection` default was `requiresBond: true`, so every routine GATT call would mark the managed device as needing a bond. On the next reconnect `requestBond()` fired, Android showed a system pairing UI, the firmware rejected it, and the connection dropped. Default changed to `requiresBond: false`.
- **SD Write Drops polling no longer disconnects the device during file transfer.** The 2-second drop-counter poll was issuing a GATT characteristic read concurrently with the notification stream from an active file download, causing GATT Error 133 and a connection drop mid-sync. The poll now skips when the storage lock is held.
- **The foreground notification now updates immediately when the device connects.** The native service now flips to "Connected" when `fireDeviceReady` is called and back to "Connecting…" when a reconnect attempt begins — both gated on Dart not having claimed the notification.
- **WAL save log spam removed.** "Successfully saved X WALs to file" was emitted on every throttled persist tick (~once per second during sync), flooding the log.
- **Ghost bin sheet no longer shows a raw "Reason" debug line.** The `Reason: … (voice_prob max …)` subtext has been removed.
- **"Recover (listen to decide)" renamed to "Recover to Recording"** for clarity.
- **"Reset to zero" button in the SD Write Drops panel now spans the full width** and its style matches the other action buttons in Debug Tools.
- **"Silenced by VAD" no longer appears when hardware AAD is in use.** The speech-minimum check (`tooShortSpeech`) was not gated on the Silero session being active, so recordings could be marked as noise even when the app had no speech detector running. The check is now skipped when `_session == null`.
- **Speech frame count is now accurate in AAD mode.** When Silero is disabled, every Opus frame is speech by definition — but the processor was only setting `isSpeech = true` on frames that happened to complete a 512-sample VAD window (~12.5% of frames), severely undercounting `speechMs`. The frame loop now initialises `isSpeech = true` in AAD mode and skips the PCM buffer accumulation entirely.
- **Trailing-silence ghost entries are no longer shown.** `silence_trimmed` records appeared as separate ghost entries even though the speech portion was already kept. They are now filtered at load time; the records remain on disk for bin-recovery tracking.
- **Ghost entry labels are clearer.** "Silenced by VAD" → **"below minimum speech"**; "too short" is now split into **"no speech detected"** (entire buffer was silence) and **"below minimum length"** (recording shorter than the Short Recordings filter).

### 0.15

- **The sync banner no longer shows a stale segment count at startup.** The count was read from WALs persisted on disk from the previous session before the device was queried. The count is now left at zero until `getMissingWals` completes — the banner shows "Scanning device…" in the interim.
- **File transfers are no longer stalled by keep-alive timeouts.** The foreground keep-alive writes `0x32` to the same BLE characteristic used for storage streaming. During an active transfer the firmware is busy sending data and cannot service the write, causing a 10-second `TimeoutException` per keep-alive tick. The keep-alive is now skipped whenever a storage operation holds the lock.
- **The marker pipeline now has a CI-enforced test harness.** Twenty-one tests cover the fifteen interacting fixes that were previously verified only by reading the code. Six tests exercise `VadAudioProcessor` directly against synthetic `.bin` payloads; fifteen tests exercise `RecordingsManager` via new `@visibleForTesting` wrappers covering `_writeMarkerEdl`, `_reanchorMarkerEdls`, and `getMarkerConversations` dedup.
- **`getMarkerConversations` now resolves filenames correctly on Windows.** The scanner used `e.path.split('/')` to extract the last path component, which silently returned the full path on Windows. Both usages replaced with `e.uri.pathSegments.last`.
- **A decoded audio frame larger than the VAD window can no longer overrun the sample buffer.** The fixed-size PCM buffer was filled with a whole decoded frame before any 512-sample windows were drained, so a frame bigger than the buffer's headroom would have thrown a range error mid-decode. Windows are now drained the instant one is complete.
- **Processing checkpoints are written far less often on long sessions.** The checkpoint serializes the entire in-flight conversation, so writing it after every ~5-minute segment could rival the decode time itself. Writes are now throttled to once every few seconds — except a write is always forced right before any source file is deleted, so a resumed run can never reference a file already removed from disk.
- **The background processing-progress notification can no longer fire its update twice per tick.** A duplicate listener registration is now prevented.
- **The "Stopping…" subtext is now driven by the controller's own state** rather than a live snapshot read during widget build.
- **The in-app sync card no longer flashes "< 1 min" for a large backlog.** It now shows "Calculating…" until the audio total is measured.
- **The accumulated-audio banner no longer hides bins that are still waiting to be decoded.** It excluded every bin sharing a session id with any already-finalized recording — but a single firmware session routinely finalizes one recording while a later conversation is still an open draft. The banner now counts exactly what processing will decode (all bins except VAD-discarded ones).
- **The notification no longer flickers between percentage and time-remaining formats during processing.** When a background sync ran while the app was open, both `DeviceProvider` and `RecordingsController` were writing to the same notification on every progress tick. `DeviceProvider` now stays silent while the app is in the foreground and `RecordingsController` owns the notification.
- **The notification no longer briefly shows "< 1 min" before snapping to the true duration.** Now shows "Calculating…" until the byte-count is known.
- **The notification stays live if you background the app during a foreground-triggered processing run.** `DeviceProvider` now registers its processing-progress listener in `onAppPaused` and unregisters it in `onAppResumed` to cover this gap.
- **The segment count in the notification now updates upward if the device reports more files than the initial estimate.** The backfill guard (`_totalCount <= 0`) prevented the count from updating once any estimate was set. The guard now updates whenever the service reports a higher count.
- **Cancelling a sync now shows accurate subtext.** Now shows "Transferring current file…" while the transfer is draining and flips to "Finishing current step" once it's done.
- **Interrupted processing now picks up from the last completed segment instead of re-decoding everything from scratch.** After each segment finishes, the app writes a small checkpoint file (`vad_checkpoint.json`) containing the full VAD processor state — Silero LSTM weights, context buffer, PCM tail, conversation frame list, and all counters. When processing resumes, the isolate restores this snapshot and skips all segments already processed.
- **Processing a backlog is now significantly faster.** The Silero VAD model's 256-float LSTM state used to make a full round-trip through Dart memory on every inference cycle (~31 cycles per second of audio): native → Dart list → native again. The state is now kept as a live native tensor and swapped in-place between calls. The per-call allocations dropped from ~6 objects to ~1, and the sample accumulation buffer was replaced with a fixed typed-data ring buffer.
- **The last 1–2 frames of each conversation are now correctly VAD-scored before the boundary is committed.** At any split or flush point, 0–511 samples were stranded in the accumulator and never evaluated. Those tail frames are now zero-padded to 512 and passed through Silero before the boundary fires.
- **A new conversation no longer inherits the previous conversation's Silero LSTM state.** The recurrent state and context buffer are now cleared at every conversation boundary — including the two inline-reset paths (`0xFFFFFFFD` gap-split and max-cap cut) that were previously skipping the reset entirely.
- **With auto-sync off (Manual Only), the app no longer triggers a sync when you resume to a still-live connection.** If the app came to the foreground while the Omi was still connected with pending segments, it would silently trigger a background sync regardless of the sync-interval setting. Every other auto-sync path already checked the setting; this "drain the pending connection" shortcut was the one gap.
- **A sync interrupted by a mid-transfer BLE drop now resumes as soon as the device reconnects, instead of waiting for the next scheduled tick.** The app was immediately dropping those reconnections because the "sanctioned background sync" flag is only set by the periodic timer path.
- **A button-tap marker made just before midnight no longer leaves a stale orphan file on disk.** The stale orphan is now deleted as soon as the paired entry is written in the next day's folder.
- **Pressing Cancel during the processing phase used to occasionally take the whole app down with it.** Cancel is now polled from inside the per-frame decode loop, so it takes effect within milliseconds even mid-segment; the watchdog's force-kill path is no longer reached on a normal cancel, and the rare last-resort kill now waits for in-flight native calls to finish first.
- **A large recording backlog now drains in one pass instead of re-processing the same segments over and over.** Root cause: the foreground service was being torn down while a background decode was still running, which let Android suspend the process mid-decode; on wake, the processing-stall watchdog misread the elapsed time as a wedge and force-killed a perfectly healthy run, restarting the whole backlog. The foreground service is now held for the full duration of a processing run, the watchdog re-anchors across a suspension/wake gap instead of killing, and the decode/save loops now emit a liveness signal so a slow-but-progressing run is no longer mistaken for a hang.
- **The persistent notification stays on the live sync/processing text instead of briefly reverting to "Connecting…".** Dart now mirrors its current notification title/text to shared storage, and the native service reuses that on startup (falling back to "Connecting…" only when no sync/processing is active).
- **A stalled sync now recovers into processing instead of getting stuck.** Every native BLE read/write is now time-bounded (10 s), so a dead peer surfaces as a normal error: the sync unwinds, the segments already downloaded are decoded, and the notification advances to the processing details.
- **A wedged command no longer poisons the next connection (Android).** The native GATT command queue is now cleared on disconnect.
- **Faster reconnect when the device is asleep.** The fast-path direct connect-by-MAC attempt now times out after 5 s instead of 10 s.
- **Pressing Back on the recordings screen now minimizes the app instead of closing it.** Previously Back finished the activity, tearing down the BLE foreground service. Back now pushes the app to the background (like Home).
- **With auto-sync off (Manual Only), the notification now shows the connection state** — "Omi is Connected", "Connecting...", or "Omi is Disconnected" — instead of the generic "Running in the background".
- **The background heartbeat now ticks every minute instead of every five.** A due background sync is picked up sooner and the notification's countdown / connection-state text stays fresher.

### 0.14

- **If the Omi disconnects mid-sync, the app now automatically decodes the raw segments that already reached the phone** instead of erroring out and leaving them on disk until the next sync. This also covers a disconnect before/between transfers, which previously just surfaced an error and skipped processing.
- **Cancelling a sync now asks what you want to do** — *Process downloaded* (decode the segments already pulled to the phone) or *Stop everything* (leave them for the next sync). Previously Cancel always dropped straight back to idle.
- **In every interruption case, processing runs in draft mode**, so the trailing segment is flushed as a draft and its source bin is kept for resume rather than being prematurely finalized and its bin deleted.
- **The processing banner no longer spins forever if decoding wedges.** A processing-stall watchdog now recovers the UI to idle when no progress is seen for 3 minutes. Recovery force-kills the stuck decode worker so it actually stops.
- **The Debug Tools log window no longer shows "No logs yet." on a non-empty log.** A single malformed UTF-8 byte made the strict reader throw on the whole file, so the in-app window went blank even though the log had content. The reader now decodes leniently (bad bytes become `U+FFFD`) and tail-reads the file so the 2 s refresh stays cheap as the log grows.
- **Diagnostic logging is now a single file with a clear on/off lifecycle.** Instead of rolling a new file per day, there's one `omi_debug_*.log` named for the day logging started. Turning the toggle **on** cleans up any old log files and opens a fresh one; turning it **off** deletes the file. On overflow (20 MB) the most recent half is kept.
- **Discarded "ghost" recordings no longer stack on top of each other with identical timestamps.** After an in-stream silence split, the next conversation was re-anchored to the start of the bin file instead of the current frame's wall clock. Each new conversation is now anchored to its first frame's actual time.
- **Consecutive discards now group into a single entry.** The recordings list now coalesces discards whose gaps are within 30 s into one entry spanning the whole period, with the union of their bins.
- **The "Audio to process" banner now reads "~X minutes to process · Y bins"**, showing both the estimated decode time and the raw `.bin` file count.
- **The pending-audio banner now titles itself "Audio to process"** when showing the minutes-to-process figure, and keeps **"Conversation in progress"** only when falling back to an open draft's accumulated duration.
- **The banner now leads with how much audio is actually waiting to be decoded** — "~N minutes to process", counting only raw `.bin` audio that's pending. Falls back to the open draft's "Xm Ys accumulated" only when there's no raw audio left to process.
- **Auto-mode recordings now split on the app's own VAD detecting silence, not only on the firmware's gap signal.** In a continuous-audio environment the firmware rarely produces a gap anywhere near the ~110 s threshold, so the entire synced backlog stitched into one unbounded conversation that never finalized. The processor now independently cuts when Silero VAD has seen `vadSplitSeconds` of continuous non-speech.
- **The sync/processing banner can no longer wedge with no way out.** A watchdog now force-recovers to idle when a sync makes no progress for 60 s, or when a cancel doesn't take effect within 12 s.
- **New "Keep Screen On" toggle in Debug Tools.** Holds a wakelock while the app is open. Survives backgrounding (re-asserted on resume) and is not cleared when a sync/processing pass finishes.
- **VAD/processing logs reach the debug log file.** The audio-processing pass runs in a background isolate where `SharedPreferences` isn't initialized, so `DebugLogManager` read its `false` default and silently dropped every line. The real preference is now forwarded across the isolate boundary.
- **Per-run processing timings.** The processing isolate now logs run start (segment count + background flag), per-segment wall-clock time, and a run-end summary.
- **"Connected to Omi Device" no longer overrides sync/processing progress in the notification.** The native Android BLE service was still posting connection-state strings on every connection change. The native service now uses a single fixed baseline and never writes connection state.
- **Notification shows live processing progress with the app open.** When a sync finished and processing began while you were watching the app, the notification froze at "Processing recordings — preparing…" instead of advancing.
- **One background behaviour; "Maximize Battery" toggle removed.** The stay-connected default never actually held the link — the firmware idle-dropped the connection every ~30 s and the app immediately reconnected, churning Bluetooth for no benefit. The app now always disconnects Bluetooth while backgrounded and reconnects only when a sync is due.
- **Grace period before the backgrounded disconnect.** The app now waits ~30 s after being backgrounded before dropping the link, keeping the firmware keep-alive running so the connection survives quick app-switches.
- **Background notification no longer flickers.** Now shows only the next-sync countdown — stable regardless of connection state.
- **Large recordings now finish syncing in the background.** During a background sync the app now sends the firmware keep-alive (`0x32`) every 20 s, so the device no longer trips its 30-second idle-disconnect mid-transfer.
- **Unprocessed-bin count in the banner.** The "Conversation in progress" banner now surfaces how many synced raw `.bin` files are still waiting to be decoded, alongside the accumulated duration (e.g. "2m 30s accumulated · 4 bins pending").
- **Sync on app open.** Opening the app now triggers a sync whenever one is due — once the auto-sync interval has elapsed since the last sync. Previously the sync-on-open path was gated to non-battery-saver mode.
- **Countdown re-anchors to the last sync.** The auto-sync countdown now resets to the moment the most recent sync *finished*. Applies uniformly to manual syncs and background syncs.
- **Sync-timer notification.** The persistent background notification is now titled **"Omi Offline Sync Timer"** and counts down to the next scheduled sync ("Next sync in ~N min").
- **Notification wording.** Foreground-service and alert notifications are now consistently branded **"Omi Offline"**; per-operation detail (sync/processing progress) moved into the notification body.
- **24-Hour Time toggle fix.** "Ghosted" entries and their detail sheet were always rendered in 24-hour time regardless of the setting. They now follow the toggle like the rest of the app.
- **Batched SharedPreferences writes.** `RecordingsManager.deleteConversations` was calling `removeUploadedFromHeypocket` once per conversation, paying N disk syncs for an N-file delete. Keys are now collected up front and removed in a single prefs write.
- **Concurrent per-file deletes.** The per-conversation `file → meta → bin` delete sequence now runs concurrently across conversations via `Future.wait`.
- **WAL save storm fixed.** `WalFileManager.saveWals` was firing per BLE packet (~50 Hz) from the fast-path sync. Throttled to 1 Hz; state-transition saves (deletion, transfer failure, end-of-sync) still persist immediately.
- **WAL file races closed.** `loadWals` and `saveWals` are now serialized by a `Mutex`, so the merge-read inside `saveWals` can no longer observe a mid-truncate empty file.
- **SD Write Drops opt-in.** The Debug Tools panel that polls SD-card drop counters every 2 s is now gated behind a toggle (off by default).
- **Diagnostic-log window.** The "Recent Diagnostics" block is now a fixed-height (240 px) terminal-style scroll box showing the last 50 entries, anchored to the bottom, refreshing every 2 s while the toggle is on.
- **Keep-Alive Pings.** Introduced a foreground keep-alive timer (`sendKeepAlive`) to prevent the firmware from prematurely idle-disconnecting. Dead connections are force-disconnected after consecutive keep-alive failures.
- **Background Leaks.** Closed reconnect leaks when "Maximize Battery" is on.
- **Android BLE Stability.** Added direct connect-by-MAC fast paths, static presence observation helpers, and auto-recovery for stale BLE bonds following an OTA update.
- **Default Mode.** Manual mode is now the default out-of-the-box experience.
- **Hardcoded VAD.** In manual mode, VAD and filter values are now hardcoded to ensure predictable recording capture; only the maximum length cap remains tunable.
- **SD Drop Diagnostics UI.** Drop stats from the firmware's diagnostic characteristic are now read and rendered on the Debug Tools page.
- **Robust Bin Cleanup.** Added guards to prevent re-VAD'ing leftover segments, reconcile bin file sizes with WAL offsets on sync resume, and wipe orphan-session raw bins during a "Delete Day" operation.

### 0.13

- **Markers (20-byte frames) are now stored directly within the raw `.bin` stream.** This replaces the legacy `markers.txt` intermediate sidecar, ensuring events are physically tied to the audio frames they accompany.
- **The VAD processor now parses inline markers during the decoding pass.** This ensures perfect synchronization between the audio stream and button-tap events.
- **Robust EDL Sidecars.** The JSON-based Edit Decision List (EDL) system has been hardened with atomic writes, reliable deduping (no more `_1.edl` duplicates), and support for "orphan" markers (taps during silence).
- **Timeline Recalibration.** Markers arriving mid-recording now recalibrate the anchor timestamp if the initial anchor was an estimate (derived from file mtime), fixing "second-order" drift in long recordings.
- **Silero VAD v6 upgrade.** Bumped the bundled `silero_vad.onnx` from v3 to v6.2.1 (~16% fewer errors on noisy real-life data). v6 collapses the separate LSTM `h`/`c` states into one 256-float recurrent `state` tensor, requires a 64-sample context window prepended to each 512-sample input, and a true 0-D scalar `sr`. Same `vadSpeechThreshold` default (0.5) but v6 is more conservative. Lower the threshold to 0.3–0.4 if quiet speech is missed.
- **Android 16 / 16 KB page support.** Swapped `onnxruntime: ^1.4.0` for `flutter_onnxruntime: ^1.7.1`, which bundles ORT 1.22.0 with 16 KB page-aligned `.so` files. Required for Android 16 devices and Play Store submissions targeting SDK 36+. `targetSdkVersion` 35 → 36, iOS minimum 15 → 16. ONNX inference is now async at the API layer — no longer FFI-blocks the platform thread.

### 0.12

- Removed the edge-to-edge opt-out from default and night styles across all SDK 31+ resource folders.
- Wrapped the marker and recording player bodies in `SafeArea` so content respects system bars.
- Enabled `OnBackInvokedCallback` in the manifest (Android 14+ predictive back gesture).
- `deleteDay`: replaced a serial EDL-deletion loop with O(M) concurrent deletion.
- Recordings list: dedup discards by id in `getDiscardsForDate`; show seconds for sub-minute ghost durations.
- Removed 46 unused dependencies and a SF Pro font block from `pubspec.yaml`.
- Deleted dead Android handlers (`WifiNetworkPlugin`, `NotificationOnKillService`), unused manifest entries, dead image / font / gif assets, and a sweep of unused imports across services, tests, and Flutter pages.

### 0.11

- **Ghost rows.** Stretches of audio that VAD dropped are recorded to `recordings/<date>/discards.jsonl` and shown as greyed-out rows in the recordings list, labelled "silenced by VAD" (noise) or "too short". Ghosts route through visible/hidden tabs by duration, with the threshold tied to `filterMinDurationSeconds`.
- **Two-button recovery sheet.** Tapping a ghost opens a sheet with **Recover** (re-process the source bins, bypassing VAD) and **Delete**. Source bins are protected from cleanup for a 48 h window so recovery stays possible.
- **Cascading deletes.** `deleteDay` reaps discard records and their protected bins alongside finalized recordings.
- **Omi Cloud integration rewrite.** Reverted to the full OAuth + PCM16 upload path (preserved from commit `21880ab`), then carried forward targeted fixes on top.
- **Upload filename fix.** On-disk recording names use millisecond timestamps; the Omi server expects epoch seconds. Filenames are now converted at upload time (`recording_fs320_<ms>.bin` → `recording_fs320_<s>.bin`).
- **Auto-enable on first login.** Toggling the Enabled switch on happens automatically when credentials first validate. Re-opening the settings page or the periodic token refresh does not override a manual disable.
- **Cancel pending uploads on disable.** Toggling Omi or HeyPocket off clears the in-flight upload queue.
- **Failed upload state.** After 3 consecutive failures the upload icon changes to an orange `!` circle. Tapping it manually retries and clears the counter on success.
- **Automatic retry reset.** Retry counters for all integrations are cleared automatically when a new Omi OAuth token is successfully refreshed, the user re-logs into Omi, or a new HeyPocket API key validates.

---

## Firmware

### oo-1.9.5

- **Removed the SD-card wipe on firmware version change.** Booting a new firmware version no longer reformats the SD card, so unsynced recordings survive an OTA/flash. The boot-time version comparison, the persisted `fw_version` NVS key, and the proactive-wipe/sentinel machinery that existed solely to drive it have all been removed. (User-initiated `CMD_CLEAR_STORAGE` is unchanged.)

### oo-1.9.4

- **BLE connect-failure diagnostics.** The firmware now counts failed connection establishments (HCI `0x3e`) along with the advertising mode in effect at the time, persists the count across reboots (throttled flash writes so a failing device still reports it after a power-cycle), and appends it to the `0x19B10062` diagnostics characteristic. Helps diagnose "advertising but won't connect" cases.

### oo-1.9.3

- **Increased SD write queue size.** Bumped `SD_REQ_QUEUE_MSGS` from 100 to 150, providing a ~3-second deeper buffer to survive SD card write stalls and maintenance cycles without audio loss.

### oo-1.9.2

- **Charging LED now restores previous state on unplug.** Plugging in the charger still forces the LED on for the charging indicator; unplugging now restores the prior state — stealth stays stealth, LED-on stays LED-on.

### oo-1.9.1

- **LED defaults to off after the boot sequence.** The initialization flash (white breathe → solid white → fade to off) still plays on every boot so you can confirm the device started. After the fade, the LED stays dark. Triple-tap to toggle it on.

### oo-1.9.0

- **Added `0x32` keep-alive command.** Accepts the keep-alive byte on the storage characteristic and resets the 30 s idle-disconnect timer, preventing mid-transfer disconnects during long file reads.

### oo-1.8.1

- **Session-end marker (`0xFFFFFFFC`) emitted on manual recording stop.** Enables the app to auto-finalize a manual recording without a Force Process step.
- **LED flashes green when a manual recording starts, red when it stops.**

### oo-1.7.11

- **New diagnostic characteristic (`0x19B10062`)** exposes SD card `storage_block_drops` counter for field debugging.

### oo-1.7.9

- **Background sync hardening.** Guard against overlapping background syncs, defer `CMD_READ_FILE` to the storage thread, correct BLE connection refcounting on connect-fail/shutdown, and always refresh storage stats at end of sync.
