# Changelog

## App

### 0.22.6

- **Fix: "Conversation in progress" banner no longer shows a stale, too-early time.** The "Captured through" estimate now comes from the in-progress draft's own end instead of whichever raw bin happened to still be on disk — which could be an unrelated old discard (e.g. showing "~4:50 AM" long after that segment had been discarded). The time is clamped to now so a padded silence gap can't read into the future.
- **Fix: discarded segments stay recoverable.** Cleanup of already-decoded raw audio now deletes only the bins a finalized recording actually consumed (tracked exactly per recording), instead of any bin sitting inside a 10-minute window around it. Previously a short discard a few minutes before a recording could be swept up, silently turning its ghost row into a dead "recover" button.
- **New: "Delete Discards" button** on each day card (between Export All and Delete Day) clears that day's discarded segments and their audio in one tap, with confirmation. Only appears when the day has discards, and respects the active Main/Hidden/All tab.

### 0.22.5

- **Fix: recording could silently stop until a manual reboot.** Reverted the SD deep power-gate (added in oo-1.9.6): it fully powered the storage chip off after idle and remounted on wake, but a failed wake-remount latched the write path into a blocked state, dropping all audio until the device was rebooted. Idle power saving now uses SPI-bus suspend only (the card stays mounted and powered), matching the upstream firmware; the NAND powers fully off only at shutdown. Requires firmware `oo-1.9.8`.
- **Change: recording now continues down to the critical-voltage shutdown** instead of pausing at 15% battery. The card is flushed once at the low-battery threshold so captured audio is durable, but capture no longer stops early — the clean shutdown still happens at the critical voltage.
- **Fix: firmware updates no longer stall from the keep-alive.** During DFU the keep-alive write can transiently fail on the saturated BLE link; it no longer force-disconnects mid-update, which could leave OTA stuck at 0%.

### 0.22.4

- **Fix: device no longer drops and reconnects every ~15 seconds.** The foreground keep-alive ran every 20 s but the firmware idle-disconnects after 15 s, so the heartbeat could never arrive in time — the link dropped on a fixed ~15 s loop, which also peppered recordings with small lost-audio gaps. Keep-alive now fires every 10 s.
- **New: write-path diagnostics.** The Diagnostics card adds "SD queue peak depth" (how close the SD write path runs to its drop limit) and "Write-fairness activations". Requires firmware `oo-1.9.7`.
- **Firmware (`oo-1.9.7`):**
  - **Write fairness** in the SD worker so an active BLE sync (file reads) can no longer starve audio writes and drop blocks; reads and writes now share the worker under contention.
  - Audio-write drop tolerance relaxed (unified 25 ms) so transient stalls during connect/sync stop sacrificing audio; codec ring buffer 0.6 s → 1.0 s; SD write queue 150 → 100 slots (net RAM reduction).
  - Diagnostics characteristic extended with SD-queue peak depth and write-fairness activation counters.

### 0.22.3

- **Fix: "Conversation in progress" banner no longer shows a future end time.** The estimated end is now derived from the most recent bin (its timestamp plus a size-estimated duration) instead of the draft's decoded length, which could read minutes into the future when a silence gap was padded. When no timestamped bin is available, the banner and finalize dialog drop the time and simply offer to finalize the recording early.

### 0.22.2

- **New: codec drop counter in Diagnostics.** The Diagnostics card now shows audio dropped before encode (capture-stage starvation), alongside the existing SD-queue and BLE drop counters. Requires firmware `oo-1.9.6`.
- **Diagnostics reset is now a single "Reset all diagnostics" button** — resets the SD, codec, and BLE counters together, replacing the separate drops/BLE reset buttons.

### 0.22.1

- **Fix: Omi Cloud uploads now proceed oldest-to-newest.** Auto-upload iterates recordings from the oldest day to the newest, and within each day from the earliest recording to the latest.
- **Rework: "Conversation in progress" banner shows when the recording ends and finalizes in one tap.** When only a draft is open, the banner shows the estimated end time inline (e.g. `Captured through ~3:42 PM`) and the button confirms with the exact time. When raw audio is still waiting to be decoded, it processes immediately without a prompt.

### 0.22.0

- **Rework: Single persistent notification on Android.** The pair of notifications (BLE connection + sync/processing) is replaced by one persistent notification covering the full cycle: idle → syncing → processing → ready. It survives BLE disconnects, backgrounding, and swipe-away without requiring a force-close to recover. Background syncs now wake via an exact `AlarmManager` alarm instead of a 1-minute heartbeat, dropping the continuous CPU wakelock. Drops the `flutter_foreground_task` plugin entirely.
- **Fix: Omi Cloud uploads reattach to in-progress jobs instead of re-queuing.** Each chunk's job ID is persisted; if the server is slow and the app stops waiting, the recording is left "pending" and the next attempt reattaches to the existing job rather than re-uploading. On a 503, the upload backs off for a few minutes before retrying.
- **New: Omi Cloud upload rows show chunk-level progress** (e.g. "Uploading… (3/12 chunks)"), updated live. Resumes from the first failed chunk on retry.

### 0.21.6

- **Fix: Omi Cloud uploads now send one segment at a time** instead of all in parallel, preventing 503s from the transcription backend. Retrying a partial upload resumes from the first failed segment.
- **Fix: Android connection notification flips to "Connecting…" immediately** when the device drops, instead of staying stale at "Connected".

### 0.21.5

- **Fix: Large Omi Cloud uploads no longer time out on transcription.** Recordings are split into ~5-minute segments at upload time; a slow or failed segment fails on its own without failing the whole recording.

### 0.21.4

- **New: Clearer upload state labels.** "Ready to Upload" replaces "Pending"; failed uploads show "Last Upload Failed at: \<time\>". The day-list cloud badge counts only integrations needing attention.
- **New: Upload failures show the actual server error** instead of a generic message.
- **Fix: Upload state is stable through retries** — no flicker between "Uploading" and "Failed" during the auto-retry window.
- **Fix: Only one Omi upload runs at a time** — a second upload attempt while one is in progress is blocked with a message.

### 0.21.3

- **Fix: Force Sync bolt correctly marks the last actual recording** even when a discard row trails it.

### 0.21.2

- **New: Per-integration upload status in the recording player.** The cloud icon shows the worst pending state with a badge count; the player shows per-integration status and individual retry actions.
- **Fix: Manual upload works on recordings made before auto-upload was enabled.**
- **Fix: Auto-upload no longer sweeps recordings older than when the toggle was turned on.** With no recorded enable-time, auto-upload fails closed (manual upload still works).
- **Fix: Delivered recordings no longer show a red cloud icon.**
- **New: Auto-upload cutoff shown on the Integrations page.**
- **Removed: OGG (Opus) save format.** WAV and M4A only; existing OGG selections migrate to WAV automatically.

### 0.21.1

- **Fix: Android pairing "channel-error"** — added required manifest feature so the Companion Device pairing dialog opens correctly.
- **New: BLE connection-failure diagnostics** — firmware counts failed connection attempts and exposes them over the diagnostics characteristic; surfaced in Debug Tools and saved to diagnostic logs.
- **Firmware:** bumped to `oo-1.9.4`.

### 0.21.0

- **Fix: False-positive "Connected" snackbar** after a connection timeout.
- **Improved: Android Companion Device Manager integration** for more reliable background connections.
- **Fix: Bluetooth connection deadlock** that left the app stuck "Scanning" indefinitely.
- **Fix: Firmware clock re-synced on every reconnect** — prevents mis-stamped recordings after a native auto-reconnect.

### 0.20.4

- **Fix: SD sync no longer aborts on BLE packet gaps** — dropped packets are zero-padded (up to 8 MB) instead of failing the transfer.
- **Improved: Trailing silence preserved in recordings** — the full silence block that triggered a VAD split is now kept in the audio file.
- **Improved: Sync notifications** — tracks Partial vs Complete syncs; format is "Last Sync: [Status] · [Time] · [Battery]%".
- **Fix: Passthrough upload metadata written correctly** — prevents recordings from disappearing from the list after upload.

### 0.20.3

- **Improved: "Forget Device" moved** from Debug Tools to the "Find Omi Devices" page for easier access during connection troubleshooting.

### 0.20.2

- **Improved: App Settings reorganized** with consistent flow and styling matching Debug Tools.
- **Improved: "Clean up Short Recordings" also removes ghost discard records.**

### 0.20.1

- **Fix: "Delete Day" works** when a day contains only ghost recordings.

### 0.20.0

- **Reworked: Adjustment Mode.** The Reprocess Day pipeline and prior Adjustment Mode have been replaced. The new Adjustment Mode copies incoming raw segments to an isolated folder; a button pushes them back into the processing pipeline. The `| ADJ` tag appears once all underlying bins are backed up.
- **Fix: Empty day cards no longer render** for days with only unprocessed raw audio.

### 0.19

- **Added: Processing mode indicator (AAD / VAD)** next to recording size in the list and player.
- **New: "Upload on WiFi Only" toggle** in App Settings — restricts uploads to WiFi, preserving mobile data.
- **Fix: Back-to-back recording splits on marker tap** — the VAD-resume signal now respects the marker protection window anchored to the hardware RTC.
- **Improved: Ghost-aware stitching** — cumulative non-speech duration (silence gaps + ghost records) is tracked against the split threshold, so conversations no longer stay "In Progress" indefinitely.
- **Improved: Intermediate ghost segments healed into recordings** — noise segments within the split threshold are re-decoded and merged into the surrounding conversation.
- **Fix: Background notification no longer disappears** after "Conversations ready" — transitions smoothly to the idle countdown.
- **Performance: Android native VAD batch runner** — VAD inference runs in a native Kotlin thread with batch frame evaluation, significantly faster on large backlogs.

### 0.18

- **Fix: Sync notification shows absolute scheduled time** ("Next sync at 3:45 PM") instead of a stale countdown.
- **New: BLE notification shows device battery level** and last-connected time.
- **Voice Activity Detection defaults to off in Automatic Recording Mode.** Must be explicitly enabled by the user.
- **Fix: Background sync fires on time via native `AlarmManager` alarm** even when Android freezes the Dart isolate — the alarm re-arms itself from shared prefs and survives repeated Dart freezes.
- **Fix: Android 14+ foreground notifications return after being swiped away.**
- **Fix: VAD processing is no longer throttled when the screen turns off** — `PARTIAL_WAKE_LOCK` held for the full sync+process run.

### 0.17

- **Fix: Foreground service declared as `dataSync`** so OEM battery managers don't kill it when BLE disconnects mid-processing.
- **Fix: Processing stall watchdog extended to 10 minutes** and no longer stops the foreground service on a false trigger.
- **Fix: Checkpoint resumes by timestamp** — the correct resume point is found after an app kill even when file indices have shifted.
- **Android: WorkManager periodic sync** fires reliably even when the foreground service is killed by OEM battery managers.
- **Android: BLE storage transfers run in native Kotlin** — avoids Dart platform-channel throttling when backgrounded.
- **Fix: Firmware OTA no longer wipes BLE bonding keys** or triggers a spurious SD card wipe on every boot.
- **Fix: Firmware OTA keep-alive continues during DFU** — device no longer idle-disconnects mid-transfer.

### 0.16

- **Waveform uses percentile normalization** so level variation is visible regardless of absolute recording level.
- **Fix: Previously-discarded audio no longer re-runs VAD on every sync** — date-key mismatch in the skip filter corrected.
- **Fix: Raw audio segments bucket under their real date** instead of January 1970.
- **Silero VAD uses tuned ONNX Runtime session options** (XNNPACK CPU provider, optimized threading) for faster inference.
- **Fix: WAV header always correct** when frames are dropped during decode.
- **Fix: Large file transfers no longer time out** — keep-alive moved to native Android service, bypassing the GATT queue.

### 0.15

- **Interrupted processing resumes from the last completed segment** via a checkpoint file — no full re-decode after a crash or app kill.
- **VAD inference significantly faster** — LSTM state kept as a live native tensor; per-call allocations reduced ~6×.
- **Fix: Accumulated-audio banner correctly counts pending bins** — bins covered by open drafts no longer incorrectly excluded.
- **Fix: Silero LSTM state cleared at each conversation boundary** — new conversations no longer inherit previous state.
- **Fix: Sync interrupted by mid-transfer BLE drop resumes immediately** on reconnect instead of waiting for the next scheduled tick.
- **Back button on recordings screen minimizes the app** instead of closing it.

### 0.14

- **Fix: Mid-sync disconnect now decodes already-downloaded segments** instead of discarding them.
- **Cancel sync prompts a choice**: *Process downloaded* or *Stop everything.*
- **Auto-mode recordings split on app-side VAD silence**, not only firmware gap signals — prevents unbounded stitching in continuous-audio environments.
- **Manual mode is now the default** out-of-the-box.
- **Android: Keep-alive sent every 20 s during background sync** so the device doesn't idle-disconnect mid-transfer.
- **Background sync triggers on app open** when a sync is due.

### 0.13

- **Markers stored inline in the `.bin` stream** (20-byte `0xFFFFFFFE` frames), replacing the `markers.txt` sidecar.
- **Silero VAD v6.2.1** — ~16% fewer errors on noisy real-life data; requires 256-float recurrent state + 64-sample context window.
- **Android 16 / 16 KB page support** — switched to `flutter_onnxruntime` (ORT 1.22.0). `targetSdkVersion` 36, iOS minimum 16.

### 0.12

- Internal cleanup: removed 46 unused dependencies, dead Android handlers, unused assets and imports.

### 0.11

- **Ghost rows** — VAD-discarded audio shown as greyed-out rows with Recover and Delete actions.
- **Omi Cloud integration** — OAuth + PCM16 upload with per-segment delivery, auto-enable on first login, cancel on disable, failed-upload state with retry.

---

## Firmware

### oo-1.9.6

- **Battery: SD card fully powers off during long silence.** After ~2 minutes of continuous VAD silence while disconnected, the SD chip is unmounted and power-gated (not just the SPI bus suspended). It remounts on demand when audio resumes or the phone reconnects. Skipped during OTA.
- **Battery: idle-disconnect shortened from 30 s to 15 s.** The device drops an idle BLE link sooner to fall back to low-power advertising.
- **Reliability: in-stream markers survive SD congestion.** Button-tap (`0xFFFFFFFE`), session-end (`0xFFFFFFFC`), and VAD-resume (`0xFFFFFFFD`) markers now use a blocking SD write so they aren't dropped if the write queue is briefly saturated. Audio ordering is preserved.
- **Reliability: auto-recovery for a stuck SD card.** If writes fail repeatedly mid-recording, the firmware power-cycles and remounts the card instead of dropping audio until the next reboot.
- **Reliability: bounded SD boot with a fault indicator.** If the SD card fails to initialize within 90 s, the device still comes up (BLE + mic) and locks the LED solid red so the fault is visible, instead of hanging on boot.
- **Codec drop counter** added to the `0x19B10062` diagnostics characteristic (now 32 bytes) — surfaces audio dropped before encode when the encoder is CPU-starved.

### oo-1.9.5

- **Removed the SD-card wipe on firmware version change.** Booting a new firmware version no longer reformats the SD card, so unsynced recordings survive an OTA/flash.

### oo-1.9.4

- **BLE connect-failure diagnostics.** Counts failed connection establishments, persists across reboots, and appends to the `0x19B10062` diagnostics characteristic.

### oo-1.9.3

- **Increased SD write queue size** from 100 to 150 entries — ~3 s deeper buffer to survive SD write stalls without audio loss.

### oo-1.9.2

- **Charging LED restores previous state on unplug** — stealth stays stealth, LED-on stays LED-on.

### oo-1.9.1

- **LED defaults to off after the boot sequence.** The initialization flash still plays on every boot; after the fade the LED stays dark.

### oo-1.9.0

- **Added `0x32` keep-alive command** — resets the 30 s idle-disconnect timer, preventing disconnects during long file reads.

### oo-1.8.1

- **Session-end marker (`0xFFFFFFFC`) emitted on manual recording stop** — enables the app to auto-finalize without a Force Process step.
- **LED flashes green on manual recording start, red on stop.**

### oo-1.7.11

- **New diagnostic characteristic (`0x19B10062`)** exposes SD card `storage_block_drops` counter for field debugging.

### oo-1.7.9

- **Background sync hardening** — guard against overlapping syncs, defer `CMD_READ_FILE` to the storage thread, fix BLE connection refcounting, always refresh storage stats at end of sync.
