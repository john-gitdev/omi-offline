# Changelog

Patch releases are rolled up into their minor version. Each section reflects the **net** behavior at the end of that series, so superseded or reverted intermediate changes aren't listed.

## App

### 0.25

- **Fix: "Recover to Recording" no longer pulls in neighboring audio.** A discarded stretch usually shares a single ~5-minute raw segment with the recording right before or after it. Recovering it used to reprocess that whole segment, so the recovered clip swallowed the neighbor's audio — coming out far longer than the discard and overlapping the existing recording. Recovery now re-derives only the discarded slice itself, anchored at its real start time. (Discards are recorded with their exact byte span going forward; older discards from before this change still recover the whole segment.)
- **Fix: Force Process no longer rewrites your already-finalized recordings.** The debug **Force Process** button used to re-derive your entire history from raw segments on every run — overwriting finalized recordings (re-stitching adjacent audio and shifting their boundaries) and getting slower as segments accumulated. It now skips audio already covered by an existing recording, exactly like the normal Process button and background sync do. The old "rebuild everything from saved segments" behavior moved to a separate, confirmation-gated **Reprocess All from Segments** button in Adjustment Mode, so a full re-cut is now a deliberate choice rather than a side effect of pressing Force Process.
- **New: A banner warns when on-phone voice detection falls back to the device.** If the phone-side voice-detection model (Silero VAD) can't load during a sync, processing silently falls back to the device's own acoustic detection, which treats every frame as speech and can split recordings oddly. The recordings screen now shows an orange "Voice detection unavailable — using device fallback" banner while that fallback is active, and it clears itself automatically on the next healthy sync.
- **Fix: Guard against a flood of tiny junk recordings.** A clock-anchor mismatch on the device could make every post-silence resume marker read as a huge time gap, spraying out hundreds of one-frame recordings (one report hit ~3,500 in a minute). While the app is on device-fallback detection and sees a sustained run of these sub-second splits, it now coalesces further resume markers onto a single recording instead of splitting on each one. A lone short note still stands on its own — only a genuine flood is collapsed.
- **Fix: Recordings no longer lose track of their source segments.** Hardened how a recording records which raw segments it was built from — it no longer drops a segment reference on unusual path forms (which previously left a recording listing no source segments) — and a recording's saved metadata is now stamped with the correct session id even when that id was reset across a stitch. Also, "Copy Bins for Reprocessing" in Adjustment Mode now reports how many segments it copied (with a snackbar and refreshed folder count) instead of running silently.
- **iOS: more chances for background auto-sync to fire.** Alongside the existing background-sync task, the app now also registers an iOS *app-refresh* task — which iOS grants more often, and without waiting for the phone to be charging. Both honor your auto-sync interval as a floor. This only raises the odds of an opportunistic background sync; iOS still decides when (or whether) to actually run them, so it's a best-effort improvement, not a guaranteed schedule. Battery is unaffected — the Omi still stays disconnected between syncs exactly as before, and there's no continuous connection or background-audio trick involved. Android is unchanged (it already wakes on schedule via WorkManager/alarms).
- **Cancel an upload from the recording's Integrations list.** A recording with an upload actually in flight or waiting its turn now shows a **Cancel** button (in place of the old static "Waiting…"). If it's the only thing active for that integration, tapping Cancel just stops it; if a queue is backed up behind it, you're asked whether to cancel **This Recording** or the **Entire Queue** (tap outside the dialog or press back to keep everything). While an in-flight upload winds down to its next stopping point the row shows "Cancelling…" and hides the button so you get feedback and can't tap it repeatedly. An in-flight Omi Cloud upload stops cleanly between chunks (already-uploaded chunks are kept); a HeyPocket upload already mid-request finishes. (An auto-upload you cancel this way may come back on the next auto sweep while Auto-Upload is still on; a manual one stays cancelled. The button is hidden during the brief auto-retry window, where there's no in-flight or queued job to stop.)
- **Turning off an integration now stops its uploads immediately.** For Omi Cloud / HeyPocket, switching off **Auto-Upload** cancels in-progress and queued *auto* uploads (an explicit manual upload you started keeps running), and switching off **Enabled** cancels *everything* for that integration — in-progress and queued. Previously, turning off Auto-Upload left uploads running entirely, and turning off Enabled only dropped the queue while the active upload kept going. A chunked Omi Cloud upload stops cleanly between chunks (already-delivered chunks are kept and the rest resume if you switch it back on); a cancelled upload is not counted as a failure. (A HeyPocket upload already mid-request finishes, since a single request can't be interrupted once sent.)
- **iOS: the screen no longer sleeps mid firmware update.** A firmware (OTA) install now holds the screen awake — plus an iOS background-execution assertion — for the whole flash. Previously nothing kept the display on, so if it auto-locked the app dropped to the background and iOS suspended the Bluetooth transfer mid-update, which could leave the device in a bad state. The wakelock is released as soon as the update finishes, fails, or you leave the screen (and respects "Keep Screen On" if you have it pinned).
- **iOS: faster SD-card sync.** Incoming Bluetooth packets are now parsed and written to disk off the CoreBluetooth delivery thread, so iOS is no longer blocked from handing over the next batch while a packet is being saved — the transfer pipe stays full instead of stalling once per packet. Paired with the firmware change below, iPhone sync is substantially quicker.
- **iOS: background auto-sync wakes when the Omi comes into range.** Using CoreBluetooth state preservation & restoration, iOS relaunches the app in the background when your bound Omi returns to Bluetooth range and runs a sync if one is due — gated on your auto-sync interval, so Manual Only and not-yet-due wakes stay quiet. This is far more dependable than relying on iOS's opportunistic background-task scheduler alone, which fires unpredictably. Android's existing behavior — waking on schedule regardless of whether the device is in range — is unchanged.
- **iOS: recording processing isn't killed the instant you background the app.** The decode/VAD pass now holds an iOS background-execution assertion for its bounded window; a decode that outruns that window resumes on the next sync via the existing draft pipeline, so nothing is lost.
- **iOS: Bluetooth no longer drops at random mid-sync.** The heartbeat that stops the Omi from idle-disconnecting now runs natively in the CoreBluetooth layer instead of from a Dart timer, which iOS stops firing reliably once the app is backgrounded. Previously, in the gap between files of a multi-file sync the heartbeat could go silent long enough for the device to drop the link, abort the transfer, reconnect, and repeat. The native heartbeat keeps the link up between files so a background sync runs to completion — matching Android's existing behavior.
- Requires firmware oo-2.3.0 for the faster iOS connection interval (see Firmware below). The other iOS improvements work on any oo-2.x firmware.

### 0.24

- **Fix: "Share Logs" no longer creates a phantom second file.** Sharing the diagnostic log passed the share title as a separate text item alongside the file, so iOS save/upload targets materialized an extra file containing just the label. The title is now share-sheet metadata, so only the actual `.log` file is shared.
- **Change: Shared diagnostic logs get a clearer name.** Sharing/uploading the log now names it `omi_offline_debug_<date>.log` instead of the plain `omi_debug_<date>.log` — the name is applied to the file itself (not just the share-sheet title), so it lands on upload/save targets too. Lowercase and underscored, with no spaces or apostrophes, so it's easy to work with.
- **New: Fully customizable button mapping.** Map any action (None, Mute, Marker, Toggle LED) to a single, double, or triple tap — and to each of their press-and-holds — directly from Device Settings. Mappings sync to the Omi over a dedicated **encrypted, value-validated** Bluetooth characteristic, and the firmware rejects out-of-range actions so a malformed mapping can never be persisted. The Button Configuration screen loads your live mapping from the device and shows a clear "Device not connected" state with a Retry button instead of displaying defaults and silently dropping edits.
- **Security: Dedicated Power Off & Unpair gestures.** 4-tap-and-hold (3 s) is reserved for Power Off and 5-tap-and-hold (10 s) for Unpairing; plain 4-tap and 5-tap are disabled to prevent accidental triggers.
- **Fix: Restored Android companion pairing & iOS build.** Re-enabled the Android system pairing association on first connect (which complements the encrypted bond and gives the app a system "companion" status), and added the missing native `removeBond` bridge so the iOS app builds and "Forget Device" works across platforms.
- **Fix: Fewer connections stuck until you toggle phone Bluetooth.** The app no longer arms Android's Companion Device *presence observation*. On some phones (OnePlus/Oppo/Realme) that observation made the OS hold its own hidden Bluetooth link to the Omi, which competed with the app for the device's single connection slot and could wedge reconnection until you turned phone Bluetooth off and back on. The system pairing association itself is kept, so bonding and battery behavior are unchanged; background reconnection is now driven entirely by the periodic sync. The only difference you'll notice: after walking back into range with the app in the background, the Omi reconnects on the next sync cycle instead of instantly — no audio is affected, since the Omi records to its SD card whether or not the phone is connected.
- **Fix: Auto-recovery from a wedged Bluetooth connection.** If the phone's Bluetooth stack gets stuck holding a stale system link to the Omi — the state that previously forced you to toggle phone Bluetooth off and on to reconnect — the app now detects it during reconnection (the OS still reports the device connected while the app holds no working link) and clears that ghost link itself before retrying. The recovery is conditional (it does nothing on a normal disconnect) and rate-limited, so it only kicks in when a reconnect is genuinely blocked.
- **Change: Android Companion Device pairing is now off by default** (toggle in App Settings). The app connects to the Omi purely by address + bond. This fixes connection wedges on OnePlus/Oppo/Realme phones, where the OS kept a hidden system link that fought the app for the Omi's single connection slot and forced you to toggle Bluetooth to reconnect — and the companion association wasn't load-bearing anyway (background sync runs on the foreground service + alarms, not the companion grant). Toggling it applies immediately: off reconnects and clears the association, on reconnects and opens the system pairing dialog (no re-pair needed). If you're on a different OEM and prefer the app to register as a system companion (it can help background survival on aggressive battery managers), turn **Companion Device Pairing** back on.
- **Fix: Accurate sync-status timestamp.** The "Last Sync" notification tracks the time of the last sync *outcome* (including a skip) separately from the last successful sync, so interval-based auto-sync scheduling is no longer nudged by skipped cycles.
- **Fix: Sync notification no longer sticks on "Connecting…".** A scheduled background sync that started connecting could be frozen by Doze mid-attempt — before the normal "settle back to idle" step ran — leaving the notification stranded on "Connecting…" until the next scheduled wake (sometimes 20+ minutes). A watchdog now forces the notification back to the idle "Last Sync" line when a connect attempt fails to connect in time, and because an overdue timer fires the instant the process thaws, a frozen attempt is recovered on the next wake instead of waiting out the whole interval.
- **Fix: Markers tapped while the device is idle are no longer dropped.** In auto mode, tapping to drop a marker after the device had gone quiet could silently lose the bookmark — and, if that moment was silent, the whole short clip around it — because the SD card was still in its low-power paused state when the marker was written. The firmware now resumes storage *before* writing the marker, so taps from sleep are saved reliably; the same fix makes the post-silence VAD-resume timestamp durable on acoustic wake, keeping conversation boundaries accurate. Requires firmware oo-2.2.2.
- **iOS: minimum version lowered to 15.1** (was 16.0), so the app installs on iPhones running iOS 15. Fixed BLE device discovery on iOS: scanning never started because the app requested the Android-only `bluetoothScan`/`bluetoothConnect` runtime permissions (which iOS reports as permanently denied), and discovered peripherals read their name from the wrong CoreBluetooth field, so the "Omi" name filter never matched.
- **Internal:** removed the unused Apple Watch integration inherited from upstream — its Dart bridge was never wired up, so the watchOS target, watch Pigeon bindings, and related native stubs were deleted with no behavior change.
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

### oo-2.3

- **Faster sync on iOS via an Apple-compatible connection-interval fallback.** The device requests an aggressive 7.5 ms Bluetooth connection interval for fast SD-card sync, but iOS rejects any request below 15 ms outright and silently leaves the link at its slow default (~30 ms), so iPhone sync crawled. The firmware now rechecks the *actual* negotiated interval a few seconds after connect and, only if its fast request wasn't honored (i.e. an iPhone), sends a single Apple-compliant request (15–30 ms). Android is unaffected — its phone already drives the interval to ~11 ms via a high-priority request, so the recheck sees a fast interval and does nothing. The fallback self-targets iOS by observing what the central accepted rather than detecting the OS, and is sent at most once per connection so it can never loop. Pairs with the iOS app changes in 0.25.

### oo-2.2

- **Fix: No more mid-transfer disconnect loop on slow links (notably iOS).** During an SD-card transfer the device keeps the BLE link up even when the phone drains data slowly. Previously a slow consumer could back-pressure the firmware's send path so no data flowed for >15 s, tripping the idle-disconnect that exists to save power when truly idle — which cut the transfer off, and the resumed transfer cut off again, looping. The idle-disconnect is now deferred while a transfer is in progress (the BLE supervision timeout still drops a genuinely dead link). This mainly affected iOS, where the file read runs packet-by-packet on the phone instead of in native code.
- **New: Clean slate when flashing over non-Omi-offline firmware.** The first boot after flashing onto a device that was running a different (e.g. stock Omi) firmware wipes the SD card storage so old, incompatible recordings don't linger. The trigger is the on-card filesystem itself — the NAND is reformatted whenever it isn't recognized as an Omi-offline filesystem (every Omi-offline format stamps a magic cookie) — so this runs exactly once on migration. **Bluetooth bonds are left intact**: the pairing key stays valid across the firmware swap, so your phone reconnects without re-pairing (iOS in particular has no API for an app to clear a system pairing, so wiping only the device side would have forced a manual "Forget This Device"). Use the 5-tap-and-hold unpair gesture or Forget Device if you deliberately want a fresh pairing. Upgrading between Omi-offline versions keeps the cookie and therefore **never** wipes storage (unlike the old per-version wipe removed in oo-1.9).
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
