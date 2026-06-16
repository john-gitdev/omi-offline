# Changelog

Patch releases are rolled up into their minor version. Each section reflects the **net** behavior at the end of that series, so superseded or reverted intermediate changes aren't listed.

## App

### 0.24

- **New: Fully customizable button mapping.** Map any action (None, Mute, Marker, Toggle LED) to a single, double, or triple tap — and to each of their press-and-holds — directly from Device Settings. Mappings sync to the Omi over a dedicated **encrypted, value-validated** Bluetooth characteristic, and the firmware rejects out-of-range actions so a malformed mapping can never be persisted. The Button Configuration screen loads your live mapping from the device and shows a clear "Device not connected" state with a Retry button instead of displaying defaults and silently dropping edits.
- **Security: Dedicated Power Off & Unpair gestures.** 4-tap-and-hold (3 s) is reserved for Power Off and 5-tap-and-hold (10 s) for Unpairing; plain 4-tap and 5-tap are disabled to prevent accidental triggers.
- **Fix: Restored Android companion pairing & iOS build.** Re-enabled the Android system pairing association on first connect (which lets the OS wake the app for background sync and scan without location permission, complementing the encrypted bond), and added the missing native `removeBond` bridge so the iOS app builds and "Forget Device" works across platforms.
- **Fix: Accurate sync-status timestamp.** The "Last Sync" notification tracks the time of the last sync *outcome* (including a skip) separately from the last successful sync, so interval-based auto-sync scheduling is no longer nudged by skipped cycles.
- **Fix: Markers tapped while the device is idle are no longer dropped.** In auto mode, tapping to drop a marker after the device had gone quiet could silently lose the bookmark — and, if that moment was silent, the whole short clip around it — because the SD card was still in its low-power paused state when the marker was written. The firmware now resumes storage *before* writing the marker, so taps from sleep are saved reliably; the same fix makes the post-silence VAD-resume timestamp durable on acoustic wake, keeping conversation boundaries accurate. Requires firmware oo-2.2.2.
- Requires firmware oo-2.2.x.

### 0.23

- **New: Mute is now first-class.** When you mute the device (double-tap-and-hold → solid red LED, mic off) in auto mode, the recordings screen shows a red "Omi is Muted since H:MM" banner, the Android sync notification's resting line reads **"Muted since 3:42 PM" / "Next sync at 4:15 PM"**, and a red mic-off button in the app bar toggles mute over BLE (auto mode only — hidden in manual mode, where muting is unavailable). Mute state is read on connect and updates live, even mid-sync. Muted stretches also appear on the recordings list as a greyed-out, **delete-only** "Muted" ghost row bracketed by the exact mute/unmute times (if the device powered off while muted, the row ends at the next session's start — mute never survives a reboot). Requires firmware oo-2.0.0+.
- **New: Per-integration upload queues.** Each integration (Omi Cloud, HeyPocket) has its own queue that uploads one recording at a time — so no single server is ever hit in parallel — but different integrations upload **concurrently**, so a slow Omi upload no longer blocks HeyPocket. Manual taps jump ahead of automatic uploads; rows show **Queued → Uploading → Uploaded**, and a failed integration drops the rest of its own queue while the others keep going. On Android the sync notification shows aggregate progress ("Uploading N of M") and expands to a per-integration status line — including Omi's chunk progress and a "server busy, retry…" line when Omi is rate-limited (503). Uploads hold the device awake until they finish, pause if "Upload on Wifi Only" is on and wifi drops, and resume on the next launch if the app is killed mid-upload.
- **New: "Upload All" on each day card.** Queues all pending recordings for that day to your configured integrations, oldest to newest. Only appears when at least one integration is configured.
- **Reliable Bluetooth bonding.** The phone's bond is preserved through idle background disconnects **and** OTA firmware updates (the partition map keeps pairing keys across an OTA), so you no longer hit "Incorrect PIN" errors on reconnect. The aggressive "stale bond" recovery that deleted pairing keys on `GATT_INSUF_AUTHENTICATION` (status 5) is disabled, letting Android natively elevate security on the existing bond. The bond is only wiped when you explicitly tap "Forget Device" — which now also sends `CMD_UNPAIR` (`0x15`) so the Omi wipes its own bonding keys at the same time, for a clean slate on both devices. Reset Connection / Forget Device also surgically clear Android's native bond cache and purge ghost Companion-Device associations.
- **Optimized background battery logic.** The app pulses a keep-alive every 5 seconds (surviving up to two missed beats) and drops the connection natively after exactly 15 seconds in the background, matching the Omi's internal deadman switch. A background sync that fails to connect marks the notification **"Last Sync: Skipped"** at the time of the attempt, and the app immediately attempts to sync the moment you return to the foreground instead of waiting out the interval.
- **Fix: "Conversation in progress" banner shows the right time.** The "Captured through ~TIME" estimate comes from the in-progress draft's own end (start parsed correctly from its filename, clamped to now), so it no longer drifts to the current clock or reads into the future.
- **Fix: Diagnostics no longer hangs on "Reading drop counters".** The card now checks the connection and shows "Waiting for device connection…" instead of hanging indefinitely if the link drops.
- **Internal:** large-file refactor — recording domain models, upload/VAD value types, WAL sync exceptions, sync-page debug widgets, the integration upload manager, the discard ledger, and the background-processing isolate worker were split into focused units, with added unit-test coverage for the upload subsystem. Behavior unchanged.

### 0.22

- **Rework: Single persistent Android notification.** One persistent notification covers the full cycle — idle → syncing → processing → ready — and survives BLE disconnects, backgrounding, and swipe-away without requiring a force-close. Background syncs wake via an exact `AlarmManager` alarm instead of a 1-minute heartbeat, dropping the continuous CPU wakelock. The `flutter_foreground_task` plugin is dropped entirely.
- **Rework: "Conversation in progress" banner shows when the recording ends and finalizes in one tap.** When only a draft is open, the banner shows the estimated end time inline (e.g. `Captured through ~3:42 PM`) derived from the draft's own end and clamped to now, and the button confirms with the exact time — or falls back to "Tap to finalize early" when no end estimate is available. When raw audio is still waiting to be decoded, it processes immediately without a prompt.
- **Omi Cloud uploads: reliable large-file delivery.** Recordings upload oldest-to-newest, split into ~5-minute chunks sent one at a time with live chunk-level progress (e.g. "Uploading… (3/12 chunks)"). Each chunk's job ID is persisted, so a slow server leaves the recording "pending" and the next attempt reattaches to the existing job rather than re-uploading; on a 503 the upload backs off a few minutes before retrying, resuming from the first failed chunk.
- **New: Delete Discards.** A per-day "Delete Discards" action clears that day's discarded segments and their audio in one tap (with confirmation), respecting the active Main/Hidden/All tab. Only appears when the day has discards.
- **Fix: Discarded segments stay recoverable.** Cleanup of already-decoded raw audio deletes only the bins a finalized recording actually consumed (tracked exactly per recording), instead of any bin within a time window — so a short discard near a recording is no longer swept up into a dead "recover" button.
- **UI: Day actions and multi-select.** Each day's Export All, Delete Discards, and Delete Day live behind a single overflow (⋯) menu on the date row. Long-press any row to enter selection mode (scoped to that day and that type, so recordings and discards never mix), then **Select All / Select None**, **Export Selected** or **Recover Selected**, and **Delete Selected** from a bar that slides up from the bottom; the off-type rows and other days dim away. Discard rows brighten while you're picking them, and a back-to-top button appears after you scroll down.
- **New: write-path diagnostics.** The Diagnostics card adds audio dropped before encode (capture-stage starvation), SD-queue peak depth, and write-fairness activations alongside the existing SD-queue and BLE drop counters, with a single "Reset all diagnostics" button. Requires firmware oo-1.9.6+.
- **Fix: Device no longer drops and reconnects every ~15 seconds.** The foreground keep-alive now fires every 10 s to beat the firmware's 15 s idle-disconnect, eliminating the periodic link drops that peppered recordings with small lost-audio gaps. The keep-alive also no longer force-disconnects during a DFU/OTA, which could leave the update stuck at 0%.
- **Change: recording continues to the critical-voltage shutdown** instead of pausing at 15% battery; the card is flushed once at the low-battery threshold so captured audio is durable. Requires firmware oo-1.9.8.

### 0.21

- **Fix: Bluetooth connection reliability.** Fixed false-positive "Connected" snackbars after a timeout, improved Android Companion Device Manager integration for background connections, resolved a deadlock that left the app stuck "Scanning", and added the required manifest feature so the Companion pairing dialog opens (no more "channel-error"). The firmware clock is re-synced on every reconnect to prevent mis-stamped recordings, and the connection notification flips to "Connecting…" immediately when the device drops.
- **Omi Cloud uploads.** Per-integration upload status in the recording player (the cloud icon shows the worst pending state with a badge count; per-integration retry actions). Clearer labels ("Ready to Upload", "Last Upload Failed at: \<time\>"), failures show the actual server error, and state stays stable through the auto-retry window. Large recordings are split into ~5-minute segments at upload time and sent **one segment at a time** (preventing 503s from the transcription backend); a failed segment fails on its own and retry resumes from the first failed segment, and only one Omi upload runs at a time. Manual upload works on recordings made before auto-upload was enabled; auto-upload no longer sweeps recordings older than when the toggle was turned on (fails closed with no recorded enable-time), and the cutoff is shown on the Integrations page. Delivered recordings no longer show a red cloud icon.
- **New: BLE connection-failure diagnostics.** Firmware counts failed connection attempts and exposes them over the diagnostics characteristic; surfaced in Debug Tools and saved to diagnostic logs. Requires firmware oo-1.9.4.
- **Fix: Force Sync bolt marks the last actual recording** even when a discard row trails it.
- **Removed: OGG (Opus) save format.** WAV and M4A only; existing OGG selections migrate to WAV automatically.

### 0.20

- **Reworked: Adjustment Mode.** Copies incoming raw segments to an isolated folder; a button pushes them back into the processing pipeline. The `| ADJ` tag appears once all underlying bins are backed up. (Replaces the prior Reprocess Day pipeline and Adjustment Mode.)
- **Fix: SD sync no longer aborts on BLE packet gaps** — dropped packets are zero-padded (up to 8 MB) instead of failing the transfer.
- **Improved: Trailing silence preserved in recordings** — the full silence block that triggered a VAD split is kept in the audio file.
- **Improved: Sync notifications track Partial vs Complete** — format is "Last Sync: [Status] · [Time] · [Battery]%".
- **Fix: Passthrough upload metadata written correctly** — prevents recordings from disappearing from the list after upload.
- **UI: App Settings reorganized** with consistent flow and styling matching Debug Tools; "Forget Device" moved to the "Find Omi Devices" page for easier access during connection troubleshooting; "Clean up Short Recordings" also removes ghost discard records.
- **Fix: Empty / ghost-only day cards.** Empty day cards no longer render for days with only unprocessed raw audio, and "Delete Day" works when a day contains only ghost recordings.

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

### oo-2.2

- **New: Customizable button finite state machine.** Replaced the static button click logic with a counter-based state machine that resolves each tap-count + hold against the custom mapping synced from the app over a new **encrypted, value-validated** BLE service. 4-tap and 5-tap holds are hardware-enforced for Power Off and Unpair and cannot be overridden by a custom mapping; over-tapping past 5 is a harmless no-op.

### oo-2.1

- **Security: GATT encryption lockdown.** All sensitive and writable characteristics — offline storage, device settings, time sync, haptics, mute, and the accelerometer CCCD — require mandatory encryption (pairing), so an unauthorized device in range can't download recordings, mute the mic, or alter settings. `CONFIG_BT_KEYS_OVERWRITE_OLDEST` and unauthenticated-overwrite are removed, so the Omi won't let any unauthenticated device overwrite your existing bond slot — it accepts only the legitimately bonded phone, or a new phone after a physical unpair gesture. Core recording infrastructure (the SD writer thread and audio pipelines) is left untouched.
- **Security: Hardware unpair gesture + native unpair command.** Tap the button 5 times and hold for 10 s to wipe all BLE bonds from NVS (LED blinks red 3× followed by a 1 s vibration). The app can trigger the same wipe with `CMD_UNPAIR` (`0x15`) on the storage characteristic, which calls `bt_unpair()` and drops the connection for synchronized unpairing.
- **Fix: "Incorrect PIN/Passkey" pairing errors resolved.** Pairing uses Zephyr's default "Just Works" (NoInputNoOutput) capability, so Android never prompts for a non-existent PIN.
- **Fix: Bluetooth connection hardening.** Fixed false-positive "Connected" snackbars, improved Companion Device Manager integration, resolved a connection deadlock that left the app stuck "Scanning", and re-synced the firmware clock on every reconnect to prevent mis-stamped recordings after a native auto-reconnect.

### oo-2.0

- **New: mute markers in the audio stream.** Engaging/releasing mute writes a mute-on (`0xFFFFFFFA`) / mute-off (`0xFFFFFFF9`) marker into the recording stream (same 16-byte payload as the other markers: UTC ms, uptime ms, session id), so the app can reconstruct exactly when the mic was muted. SD writes are resumed before the marker is written, so it survives even if mute was toggled during a VAD silence gap; the markers are force-drained like button-tap/session-end markers so they're durable with no audio flowing.

### oo-1.9

- **New: `0x32` keep-alive command** resets the idle-disconnect timer — now **15 s** (shortened from 30 s) — to prevent disconnects during long file reads; the device falls back to low-power advertising when idle.
- **New: mute state exposed over BLE.** A Mute service (`0x19B10070` / characteristic `0x19B10071`, Read/Write/Notify) reports whether the mic is muted plus when mute was engaged (`[muted][since_utc_s][since_uptime_ms]`); writing `0`/`1` toggles mute (honored only in auto mode, mirroring the physical-button gate). Notifications fire on subscribe and on every change and are intentionally **not** suppressed during file sync. The characteristic is registered last so all existing handles stay stable.
- **Diagnostics characteristic (`0x19B10062`), now 40 bytes.** Exposes reset cause + uptime and SD/codec/BLE drop counters, plus failed-connection count, SD-queue peak depth, and write-fairness activation count. Older apps read the prefix.
- **Reliability: write fairness.** The SD worker forces a write turn after a run of consecutive file reads, so an active BLE sync (file reads) can't starve audio writes; transient write stalls during connect/sync no longer drop audio immediately (retry window relaxed to 25 ms). The SD request queue holds 100 slots and the codec ring buffer is 1.0 s (up from 0.6 s) for more headroom against codec-thread stalls.
- **Reliability: durable in-stream markers.** Button-tap (`0xFFFFFFFE`), session-end (`0xFFFFFFFC`), and VAD-resume (`0xFFFFFFFD`) markers use a blocking SD write so they aren't dropped when the write queue is briefly saturated; audio ordering is preserved.
- **Reliability: SD recovery and bounded boot.** If writes fail repeatedly mid-recording, the firmware power-cycles and remounts the card instead of dropping audio until the next reboot. If the SD card fails to initialize within 90 s, the device still comes up (BLE + mic) and **blinks** the LED red so the fault is visible (and distinguishable from the solid-red mute indicator) instead of hanging on boot.
- **Battery: idle power saving is SPI-bus suspend only** — the card stays mounted and powered, and the NAND only fully powers off at shutdown. (An earlier deep power-gate that fully powered the NAND off during long silence was reverted: a failed wake-remount could latch the write path and silently drop all audio until a manual reboot.) Recording continues down to the critical-voltage clean shutdown, with one durable flush at the low-battery threshold, instead of pausing at 15% battery.
- **Removed: the SD-card wipe on firmware version change** — booting a new firmware version no longer reformats the SD card, so unsynced recordings survive an OTA/flash.
- **LED: defaults to off after the boot sequence** (the initialization flash still plays on every boot); charging restores the previous LED state on unplug (stealth stays stealth, LED-on stays LED-on).

### oo-1.8

- **Session-end marker (`0xFFFFFFFC`) emitted on manual recording stop** — enables the app to auto-finalize without a Force Process step.
- **LED flashes green on manual recording start, red on stop.**

### oo-1.7

- **New diagnostic characteristic (`0x19B10062`)** exposes the SD card `storage_block_drops` counter for field debugging.
- **Background sync hardening** — guard against overlapping syncs, defer `CMD_READ_FILE` to the storage thread, fix BLE connection refcounting, and always refresh storage stats at end of sync.
</content>
</invoke>
