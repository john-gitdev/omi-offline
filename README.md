# Omi Offline

A personal fork of the [Omi](https://github.com/BasedHardware/omi) wearable project, rebuilt entirely around local, private audio capture and processing. No cloud dependencies, no internet requirement — audio stays on your device until you choose to export it.

**Current versions:** App `0.36.4` · Firmware `oo-3.1.0`

---

## Screenshots

<table>
<tr>
<td align="center" width="33%"><img src="screenshots/Conversation%20Page.jpg" width="260"><br><sub>Conversation Page</sub></td>
<td align="center" width="33%"><img src="screenshots/Recording%20Modes.jpg" width="260"><br><sub>Recording Modes</sub></td>
<td align="center" width="33%"><img src="screenshots/VAD%20Option.jpg" width="260"><br><sub>VAD Option</sub></td>
</tr>
<tr>
<td align="center" width="33%"><img src="screenshots/Device%20Settings.jpg" width="260"><br><sub>Device Settings</sub></td>
<td align="center" width="33%"><img src="screenshots/Integrations.jpg" width="260"><br><sub>Integrations</sub></td>
<td width="33%"></td>
</tr>
</table>

---

## What it does

The nRF5340 wearable captures audio via PDM microphones, encodes it as Opus (16 kHz mono, 20 ms frames), and appends it to a raw circular log on the SD NAND. The Flutter app connects over BLE, pulls segments via a resumable WAL protocol, then cuts them into dated recordings. Manual mode (the default) brackets a recording with explicit button presses; Automatic mode splits on the firmware's own activity timestamps (AAD) or, optionally, by running Silero VAD locally on the phone. Recordings are saved as WAV by default (M4A optional). Everything runs on-device.

---

## Key Features

- **100% offline.** No cloud API, no internet check. Data never leaves the device unless you explicitly upload it.
- **Resumable BLE sync (WAL).** Per-file byte-offset bookmarks survive disconnects. Sync resumes exactly where it stopped.
- **AAD (firmware activity detection).** Automatic mode splits on the firmware's audio-activity timestamps and treats all captured audio as speech — no on-phone model. This is Automatic's default: it processes faster and uses less battery than Silero.
- **Silero VAD on-device (opt-in).** ONNX Runtime can run Silero VAD v6.2.1 locally on the phone to strip silence and segment speech. Disabled by default in Automatic mode; enabling it shows a one-time battery/processing-time warning. Runs in a background isolate so platform threads stay unblocked.
- **Two recording modes.** Manual (the default — explicit Record Start / Record Stop on the hardware button) and Automatic (hands-free; AAD by default, Silero optional). Each mode keeps its own button mapping and its own max-length cap; the app pushes the active mode's mapping to the device on connect and on every mode switch.
- **Customizable button mapping.** Single / double / triple tap, plus their press-and-hold variants, are each mappable to one of seven actions (None, Mute, Marker, Toggle LED, Record Start, Record Stop, Record Toggle) from Device Settings → Button Configuration. Each gesture can also be given its own vibration pattern. Both are synced to the firmware over encrypted characteristics on the Settings service and persisted in flash. The 4-tap-and-hold (3 s) Power Off and 5-tap-and-hold (10 s) Unpair gestures are hardware-reserved and cannot be remapped.
- **Mute.** Double-tap-and-hold mutes the mic under the Automatic default mapping (solid red LED); the firmware ignores mute in Manual mode, where what is or isn't recorded is already an explicit choice. The app shows a "Muted since H:MM" banner and notification line, exposes a mic-toggle button in the app bar (auto mode), and reads/writes mute state live over a BLE Mute service. Muted stretches are written inline into the audio stream and surface as delete-only "Muted" ghost rows on the day they happened.
- **Verified Markers.** The gesture mapped to the Marker action drops a timestamped bookmark inline in the audio stream; during processing the app parses it with sub-frame precision into an EDL sidecar. In automatic mode a marker is more than a bookmark — the firmware pins the audio gate open for 50 s and the app forces the same window through as speech, so roughly a minute from the tap is captured whatever the threshold and Silero would have decided. In a manual recording it is a plain bookmark. In manual standby there is nothing to bookmark, so the tap is swallowed and nothing is written.
- **Priority Recording.** In automatic mode, Record Start opens a high-priority capture: the firmware rotates the segment and marks the boundary, and the app finalizes whatever auto recording was open and force-captures everything until the matching stop — no silence splitting, rendered red in the list. A firmware-side safety cap (default 2 h, configurable, `0` = none) ends it if the stop never arrives.
- **Timestamp self-correction.** The Omi has no clock that survives a restart: it learns the time from the phone on connect and falls back to the IMU's counter, which wraps every ~29.8 h in the direction that makes a long gap look short. Whenever a diagnostics read gets through, the app records the device's uptime and session id against the real wall clock and uses that to place every recording from that boot. Recordings that already agree are never touched; only a timestamp the phone can prove wrong is overwritten, and a re-dated run gets an undo arrow that puts it back permanently. A whole session moves at once, and a re-date never renames one recording on top of another — a recording under a wrong date is recoverable, one overwritten is not.
- **Discard recovery (ghost rows).** Audio that processing dropped (silenced as noise, or too short) is surfaced as a greyed-out "ghost" row in the recordings list, appearing in real time as each discard is identified. Source bins are protected for a 48 h window so you can recover a clip with a lower threshold or delete it.
- **Encrypted BLE / single bond.** All sensitive and writable characteristics (offline storage, device settings, button and haptic config, time sync, mute, LED) require a bonded, encrypted connection, so a non-bonded device in range can't read recordings, mute the mic, or change settings. The device keeps a single bond slot (`CONFIG_BT_MAX_PAIRED=1`); the physical 5-tap unpair gesture (or the app's `CMD_UNPAIR`) is what frees it for a new phone. Unpairing is synchronized: "Forget Device" sends `CMD_UNPAIR` (`0x15`) so the Omi wipes its own bond keys at the same time the phone clears its own.
- **Background battery saving.** The app always disconnects BLE when backgrounded (after a ~15 s grace window to survive quick screen-off/on) and reconnects only when a sync is due — or immediately on next foreground if the last background sync was skipped. Backgrounding mid-sync no longer eats that window: it opens when the sync finishes, so leaving during a sync earns the same few seconds as leaving at any other time. The firmware records to the SD NAND regardless of phone connectivity. A `PARTIAL_WAKE_LOCK` is held over the background sync+process run so Android doesn't downclock the processing isolate when the screen is off.
- **Scheduled sync that outlives the UI.** The Dart engine belongs to the `Application`, not to the Activity, so Android reclaiming a backgrounded screen leaves the half of the app that decides to sync still running — otherwise the device stays connected, looks healthy, and nothing is ever collected from it. Three things can trigger a sync (an in-app timer, an Android exact alarm, a WorkManager backstop) and all three read the same record of when a sync last *completed*, so the interval means "since the last sync" whichever path ran it, a manual sync moves the schedule, and a sync that couldn't reach the Omi is recorded as skipped and retried at the next opportunity rather than pushing the schedule out.
- **Processing resume from checkpoint.** If processing is interrupted (background kill, BLE drop, cancel), the next run picks up from the last completed segment rather than re-decoding from scratch. When the segment list is unchanged it restores the exact Silero LSTM recurrent state with it; when new bins arrived or processed ones were pruned it resumes with fresh state and lets the `_draft` files on disk bridge the gap. A segment is skipped only if it is *both* older than the checkpoint *and* was in the list that checkpoint covered — a segment can arrive after a checkpoint is written and still be older than it, and skipping one on its timestamp alone stranded its audio.
- **Integrations.** Optional upload to HeyPocket or Omi after processing. Each integration has its own queue and uploads one recording at a time, but different integrations upload concurrently — a slow Omi upload no longer blocks HeyPocket. Omi uploads are split into ~5-minute chunks sent one at a time, with live chunk-level progress and resume-on-retry. Per-integration status (Queued / Uploading / Uploaded / Failed) is shown per recording with individual retry actions, plus per-day "Upload All" and multi-select "Upload Selected" batch actions.
- **Export & share.** Any recording exports through the system share sheet as its on-disk WAV/M4A file; a cropped marker clip is trimmed with FFmpeg (stream copy, no re-encode) before sharing; and each day card has an "Export All" that shares the whole day's recordings at once.
- **Local OTA firmware updates.** Pick a firmware `.zip` from Device Settings → Firmware and flash it to the device over BLE — MCUboot SMP (`mcumgr`) with a legacy Nordic DFU fallback and live install progress. No server round-trip: you flash the zip the build produces. After a successful update both sides clear the Bluetooth pairing and pair again automatically — the device frees its own key slot on the first boot after the flash, and the app clears the phone's bond — so an update always ends on a clean pairing instead of occasionally leaving one that can't be repaired.
- **In-app diagnostics.** An opt-in Debug Tools screen (enabled from App Settings) reads the firmware's live counters over the Diagnostics BLE service — SD-queue / block / codec drops, BLE connect failures, marker-write drops, worker stack high-water marks, mic liveness, capture duty cycle, advertising interval, reset cause and uptime — with a "Mark baseline" action, a copyable snapshot, and an optional shareable log file. Dev firmware builds add an on-device event log that timestamps the same health events the counters only total. A dropped link is logged with the last RSSI read on it and that reading's age, which is what separates "the Omi stopped answering" from "the Omi was out of range" after the fact.
- **Adjustment Mode.** A Debug Tools switch that sets aside an untouched copy of every raw `.bin` fetched from the Omi, so a processing change can be re-run against real capture instead of a fresh sync. The archive can be reprocessed in place or exported as a single `.zip` through the share sheet — file count and approximate size are confirmed first, because the bins are already-compressed audio and a week of them will exceed what most share targets accept. It is the only export in the app that hands over raw capture rather than a finished recording.
- **Remote reboot and shutdown.** Device Settings can cold-reboot the Omi or put it into ship mode over BLE; both close the SD log cleanly first. Ship mode wakes only on a button press or the charger.

---

## Architecture

```
PDM mics → Opus encoder (firmware) → SD NAND circular log (.bin segments)
                                           |
                              BLE GATT (WAL, ACK-gated)
                                           |
                              Flutter app (raw .bin on phone)
                                           |
              inline markers + AAD timestamps, or Silero VAD (opt-in)
                                           |
                        recordings/<YYYY-MM-DD>/recording_<ms>.wav
```

### Firmware (Zephyr RTOS, nRF5340)

- **Audio:** PDM at 16 kHz → Opus VBR (32 kbps, complexity 3, CELT), 20 ms frames at 50 fps (codec ID `21` = opusFS320). BLE carries 40 B frames; on the SD log a VBR frame averages ~81 B including its length prefix.
- **Storage:** no filesystem. Audio is appended to a raw circular log (`sd_ring.c`) on the 512 MB SD NAND: a 128 KB metadata reserve (format header, 64-slot cursor log, two segment-table copies) followed by an append-only byte ring. This replaced LittleFS, whose block allocator had no persistent free-map and ran a full-filesystem scan — tens of seconds on the single SD worker thread, dropping audio the whole time — exactly when the card was full. Appending is now O(1), nothing ever scans, and the cursor is only advanced after the bytes are durable, so a power cut can lose at most the un-claimed tail. The SD NAND is a separate chip that DFU never addresses, so the log survives firmware updates by construction.
- **SD write pipeline:** frames are assembled into 440 B blocks and queued on `sd_msgq` (depth 120); BLE reads use a separate priority queue (depth 10). The worker drains up to 16 further writes per wake, and syncs the ring cursor at most every 60 s. A write-fairness rule forces a write turn after a run of reads so an active BLE sync can't starve audio. The SPI bus is woken lazily — an append that fits the staging buffer is just a memcpy — and suspended after each burst; the NAND is only fully powered off at shutdown.
- **Security:** sensitive GATT characteristics (storage, settings, button/haptic config, time sync, mute, LED) are encryption-gated and require a bond, so a non-bonded device can't read recordings or change settings. The device keeps a single bond slot (`CONFIG_BT_MAX_PAIRED=1`), and `CONFIG_BT_ID_UNPAIR_MATCHING_BONDS` makes a re-pair from the same address replace the matching bond rather than pile up. A 5-tap-and-hold (10 s) gesture, or the app's `CMD_UNPAIR`, wipes all bonds from NVS.
- **Time sync:** on BLE connect the app writes UTC as a little-endian `u32` to characteristic `0x0031` (`0x0032` reads it back). The firmware sets its RTC and rotates to a fresh UTC-keyed segment, so everything after the sync is dated. Segments recorded before it keep their uptime key — there is no directory to rename, and their real timing is recoverable from the inline `0xFFFFFFFB` header — so they surface in the app under "Unorganized" until a clock anchor can place them.
- **LED:** the master gate lives in RAM and is seeded at boot from a persisted default, which ships as off (stealth) — so the LEDs come up dark after the boot-sequence flash (white breathe → solid white → fade) unless you change that default from the app. The gesture mapped to Toggle LED flips the gate for the session without touching the default. A separate switch turns off the solid-blue connected indicator, which lets recording / mute / battery state show through while the phone is attached.
- **Button:** Interrupt-driven (no 25 Hz polling). GPIO callback wakes a counter-based FSM only on press. Tap-count + hold resolves against the customizable mapping synced from the app; 4-tap-hold (Power Off) and 5-tap-hold (Unpair) are reserved and bypass the mapping.
- **Battery:** ADC read every 60 s when connected, 5 min when disconnected. Charging state is notified on the same cadence, and keeps flowing during a file sync. Recording continues down to the critical-voltage clean shutdown (with one durable flush at the low-battery threshold) rather than pausing early.

### App (Flutter)

- **Native BLE bridge.** Pigeon-generated code calls the platform's native Android Bluetooth stack directly, bypassing Dart BLE library limitations. (Android is the only supported platform — iOS was removed; see NOTES.md.)
- **Connection serialization.** `DeviceService.ensureConnection()` uses a `Mutex` so N concurrent callers (battery, storage, WAL sync) share one attempt.
- **Background lifecycle.** Pressing Back minimizes the app (keeps the BLE foreground service running); swiping from Recents still stops it. The app disconnects BLE ~15 s after going to background — while a sync still holds the link the timer re-checks every 3 s instead, and hands back one full 15 s grace once it goes idle, so backgrounding mid-sync costs no grace — and reconnects on the auto-sync schedule or on app open. A skipped background sync (couldn't connect) is tracked separately from the last successful sync, so the next foreground reconnects immediately instead of waiting out the interval.
- **The Flutter engine outlives the Activity.** `MyApp` (the `Application`) creates and caches exactly one `FlutterEngine`; `MainActivity` adopts it by id and never destroys it (`shouldDestroyEngineWithHost = false`). Android reclaiming a backgrounded Activity therefore detaches the UI and leaves Dart running — which is what every sync path needs, since they are all Dart-side while the native foreground service keeps the process alive with or without a screen. Three consequences are handled explicitly: the BLE host API falls back to the application context instead of returning early when there is no Activity; the AAC encoder is engine-scoped rather than Activity-scoped (Activity-scoped, background processing silently fell back to WAV once the screen was gone); and `main()` now runs once per *process*, so the idempotent launch housekeeping is re-run on each UI attach. Dart signals `dartReady` over the system channel only once the sync path is genuinely up — creating an engine merely schedules `main()` — and asks native `hasUi` rather than inferring a foreground from an unset lifecycle state, which in a WorkManager-started process never resolves.
- **WAL sync (`SDCardWalSyncImpl`).** Saves segments to `raw_segments/<timerStart>/<timerStart>_<sessionId>.bin`, where `timerStart` is the firmware-assigned UTC epoch seconds and `sessionId` is the 32-bit DeviceSession ID (or `0` if unknown). Pre-time-sync files land in a `raw_segments/session_<sessionId>/` fallback folder shown in the UI under "Unorganized". A file listing that goes unanswered is distinguished from an Omi that genuinely holds nothing, and a listing that arrives short of its own declared count is reported as a partial sync — neither is allowed to look like a completed one, because a completed sync is what licenses finalizing the partial recordings on the phone.
- **VAD processor (`VadAudioProcessor`).** Runs in a fresh isolate. Stateless across runs — uncut segments stay on disk and are re-processed next cycle. Silero LSTM state is kept as a live native tensor between inference calls (no Dart-layer copy), reducing per-call allocations from ~6 objects to ~1. It also parses the inline frames the firmware writes into the audio stream — button markers, session-end, mute brackets, Priority Recording boundaries, AAD resume timestamps — which is what creates recording boundaries that no amount of silence analysis could infer. End-of-run always flushes as a `_draft` file; finalization only on a confirmed silence, cap, or marker boundary.
- **Processing checkpoint.** After each completed segment, the processor writes `vad_checkpoint.json` containing the full VAD state. An interrupted run resumes from it: with identical Silero recurrent state when the segment list is unchanged, otherwise with fresh state, leaning on the `_draft` files to bridge the gap. A segment is skippable only if the checkpoint's own covered prefix named it *and* it predates the checkpoint — timestamp alone is not enough, because a retried transfer or a short listing can deliver a bin after the checkpoint was written that is nonetheless older than it. The file carries a format `version` and is discarded unread when it doesn't match the current one, since a checkpoint written under an older rule may record a skip that was never true and nothing in the file distinguishes that from an honest one.
- **Background disconnect.** Always disconnects BLE on backgrounding, after a ~15 s grace window. The firmware drops an idle link after 60 s, so a `0x32` keep-alive (`WRITE_NO_RESPONSE`) resets that timer during long file reads without blocking the GATT command queue — fired every 10 s by the Dart foreground loop, and by a native Android timer while the foreground service holds the connection. Two consecutive keep-alive failures force-drop a link that is dead but not yet reported as such.
- **Foreground-service resilience.** A single persistent notification (owned by the native `OmiBle` service) covers the full sync/processing cycle — idle → syncing → processing → ready — and survives BLE disconnects, backgrounding, and swipe-away without a force-close. The `flutter_foreground_task` plugin has been dropped entirely. Recording Settings surfaces a warning card when the app is not exempt from battery optimization, with a one-tap Fix that opens the system exemption prompt. A native `AlarmManager` exact alarm (`setExactAndAllowWhileIdle`) is armed whenever the next sync time is set; if Android freezes the Dart isolate, the alarm fires natively and delivers the sync request without Dart. A WorkManager job is the third trigger and a floor rather than a schedule of its own (15 min minimum, fired inexactly), so it gates on the same last-completed-sync record the other two anchor to, and honours a recorded skip the same way. The resting notification line shows the Omi's battery percentage only when the app has current knowledge of it — the last sync reached the device, or the link is up right now — instead of repeating a stored reading through every cycle that missed; the same rule applies to the copy of that line native renders on its own when the Dart isolate is frozen or gone.
- **Recordings manager.** Parses finalized recordings (`.wav` by default; `.m4a` if configured) from `recordings/` for UI binding. Each recording carries a `.meta` sidecar holding its waveform, duration, session id, flag bits (recording mode, forced sync, cap-ended, clock-corrected) and the raw bins it was built from (`relativeBins`); marker EDL sidecars and the day's discard ledger live alongside.

---

## Recording Modes

### Manual (default)

Press the gesture mapped to **Record Start** to begin and **Record Stop** to end — double-tap and triple-tap under the default manual mapping. The LED flashes green on start and red on stop, and shows solid yellow while recording (unless the phone is connected and the connected-LED indicator is on, which takes priority).

- Start sets the AAD threshold to `65535` (always-on) so the firmware never suppresses audio while recording; stop returns it to `32769` (manual standby). Both values mark manual mode.
- Stopping emits a `0xFFFFFFFC` session-end marker **and rotates the segment**, so the bin holding that marker is listable on the next sync and the processor can finalize without waiting for a silence timeout. (Without the rotate, the last bin of a manual recording — the one carrying its own stop marker — stays unlistable until something else writes.)
- The app treats the captured span as one recording regardless of Silero VAD output.
- Mute is ignored by the firmware in manual mode. Marker works inside a recording and is swallowed in standby.
- AAD Sensitivity and certain VAD settings are hidden in the UI.
- A single **Record Toggle** action can replace the separate Start/Stop pair — enable "Single recording button" and both mode mappings are normalized so the picker and the firmware never hold an action that doesn't apply.

### Automatic

The device monitors audio continuously. The LED stays off until audio above the AAD threshold wakes the mic pipeline (yellow = recording, when disconnected). The gesture mapped to Marker drops a white-flash bookmark.

- **AAD is the default:** the app treats every captured frame as speech and splits only on the firmware's activity timestamps. No on-phone model runs.
- **Silero VAD is opt-in.** Enabling it (in Recording Settings) shows a one-time warning that Silero uses more battery and takes longer to process. When on, it segments speech from silence and splits on `vadSplitSeconds` of continuous silence (default 2 min).
- Either way, an optional max-length cap (`vadMaxConversationMinutes`, off by default) can force a split even without silence.
- A **marker also protects audio**: the firmware pins the gate open for 50 s and the app forces the matching window through as speech, so ~60 s from the tap survives regardless of threshold or Silero.
- **Record Start opens a Priority Recording**: the firmware rotates the segment and writes a `0xFFFFFFF8` boundary, the app finalizes the auto recording in progress and force-captures — no silence splitting, shown red — until the matching stop or the firmware's safety cap (default 2 h).
- Recordings accumulate across sync cycles — partial in-progress recordings are re-processed each run.

---

## Button Mapping

Most tap gestures are remappable from **Device Settings → Button Configuration**. Each of six gestures can be assigned one of seven actions and its own vibration pattern; both are written to the device live over encrypted characteristics and persisted in the firmware's flash, so they survive reboots and reconnects.

### Actions

| # | Action | Effect |
|---|--------|--------|
| 0 | None | No-op |
| 1 | Mute | Toggle mic mute — solid red LED, mic paused (ignored by the firmware in manual mode) |
| 2 | Marker | White-flash + timestamped bookmark written inline into the audio stream. In auto mode it also forces ~60 s of capture from the tap; in manual standby there is nothing to bookmark, so nothing is written |
| 3 | Toggle LED | Toggle the LED master gate for this session (the persisted boot default is unchanged) |
| 4 | Record Start | Manual: green-flash, start a recording. Auto: open a Priority Recording |
| 5 | Record Stop | Red-flash, stop the recording and emit a `0xFFFFFFFC` session-end marker |
| 6 | Record Toggle | Stop if anything is recording, else start — the "Single recording button" option. Requires firmware advertising the `recordToggle` capability bit |

### Gestures & default mapping

The firmware holds one active mapping; the app owns one per mode and pushes the active one on connect and on every mode switch.

| Gesture | Manual default | Automatic default |
|---------|----------------|-------------------|
| Single tap | None | None |
| Single tap + hold (1 s) | Marker | Record Start |
| Double tap | Record Start | Marker |
| Double tap + hold (1 s) | Toggle LED | Mute |
| Triple tap | Record Stop | Toggle LED |
| Triple tap + hold (1 s) | None | Record Stop |

The mapping is a 6-byte array — one action index per gesture, in the order above — read and written on the Settings service (`19b10010-…` / char `19b10015-…`); the parallel haptic map (`…0016`, `0` off, `1` single, `2` double, `3` triple buzz) sits beside it. Both require a bonded/encrypted connection, and the firmware validates every value before applying it. These moved here from the retired `23ba7926-…` service in app 0.26.x — the byte layouts are unchanged, but the move required a re-pair. The settings page only allows edits while the Omi is connected, and a change that can't reach the device is reverted so the UI always mirrors what's actually on the firmware.

### Reserved gestures (not remappable)

Two long-hold gestures are hardware-enforced and bypass the custom mapping:

| Gesture | Action |
|---------|--------|
| 4-tap + hold (3 s) | **Power off** — shuts the device down |
| 5-tap + hold (10 s) | **Unpair** — wipes all BLE bonds (3× red blink + 1 s vibration) |

Over-tapping past 5 is a harmless no-op.

---

## LED State Machine

Priority order (highest wins):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off | Off |
| 2 | Fatal SD fault | Blinking Red (~500 ms) — overrides stealth / mute / flash / charging; the blink distinguishes it from solid-red mute |
| 3 | Flash event | ~1 s flash, overrides stealth. White = marker; Green = recording start; Red = recording stop |
| 4 | Stealth (LED gate off, not charging) | Off |
| 5 | Muted | Solid Red |
| 6 | Low battery (< 10%) | Solid Purple |
| 7 | BLE connected **and** the connected-LED indicator is enabled | Solid Blue (wins over recording state) |
| 8 | Manual recording active (AAD threshold = 65535) | Solid Yellow |
| 9 | AAD auto-recording (`aad_is_recording()`) | Solid Yellow |
| 10 | Idle, or manual standby | Off |

**Charging overlay** (applied on top of base state):
- Fully charged (>= 98%): Solid Green
- Charging: 500 ms blink between Green and current base color

Charging **bypasses the stealth gate at display time** rather than turning the gate on — so the charge indicator shows in stealth without mutating the stored state, and unplugging can't drop a live mute indicator. Muting does force the gate on, so a mute tap always gives feedback from the default-off state; Toggle LED can still turn it back off mid-mute.

**Button actions** that drive these LED states (marker flash, record start/stop, mute, LED toggle) are user-configurable — see [Button Mapping](#button-mapping) for the gesture map, available actions, and reserved gestures.

---

## BLE Sync Protocol

Most Omi services use base UUID `19b100xx-e8f2-537e-4f6c-d104768a1214`. Characteristics marked 🔒 require a bonded/encrypted connection. There is no live audio-stream service in this offline fork — audio goes Mic → SD → storage-sync, never a BLE stream. The device advertises its name (`Omi`) plus the Settings service (`0010`); the app matches on either.

Handle stability matters here: Settings is registered early (third, behind only the button and haptic services), so a new characteristic on it shifts every later service's handles and costs a re-pair. New attributes belong on the last-registered service, which is why `0080` exists and why the unused Button service is kept rather than removed.

| Service | UUID suffix | Purpose |
|---------|-------------|---------|
| Settings 🔒 | `0010` / `0011`–`0016` | `0011` LED dim ratio, `0012` mic gain, `0013` AAD/VAD threshold, `0014` Priority Recording safety cap (u16 LE minutes, `0` = none), `0015` 6-byte gesture→action map, `0016` 6-byte gesture→haptic map |
| Features | `0020` / `0021` / `0022` | `0021` capability bitfield — the app hides UI the firmware can't honour (`recordToggle` gates the single-button option, `diagLog` the event-log toggle, `ledService` the two LED switches); `0022` codec ID |
| Time sync 🔒 | `0030` / `0031` / `0032` | `0031` write epoch (u32 LE); `0032` read it back |
| Battery detail | `0050` / `0051` | Notify 1 byte: uint8 charging 0/1 |
| Diagnostics | `0060` / `0061` / `0062` / `0063` / `0064` | `0061` reset cause + uptime (8 B). `0062` 100 B of append-only u32 counters — SD/codec/BLE drops, marker-write drops, stack high-water marks, mic liveness, capture duty cycle, advertising mode, and the boot's device session id. `0063`/`0064` drain and gate the on-device event log (dev builds only, `CONFIG_OMI_DIAG_LOG`) |
| Mute 🔒 | `0070` / `0071` | Read/Write/Notify 9 B: `[muted][since_utc_s LE][since_uptime_ms LE]` |
| LED 🔒 | `0080` / `0081` / `0082` | `0081` connected-LED indicator on/off (default on); `0082` boot value of the LED master gate (default off). Registered last, so adding to it moves no existing handle |
| Storage 🔒 | `30295780-…` | File list + read/delete, and the device-control commands below |
| Button | `23ba7924-…` / `23ba7925-…` | Registered but unused in both directions — the firmware notifies no tap events and the app never reads or subscribes. Button state reaches the app as inline markers in the audio stream instead, which is what a recorder built to run disconnected needs. Kept because it registers early, so removing it would shift every later handle and cost a re-pair |

The accelerometer service is compiled out (`CONFIG_OMI_ENABLE_ACCELEROMETER=n`); the IMU chip itself stays powered in low-power mode purely for its clock counter, which is what lets uptime bridge a restart.

**Storage commands** (write to `storageDataStreamCharacteristicUuid`):

| Command | Byte | Payload |
|---------|------|---------|
| STOP_SYNC | `0x03` | — |
| LIST_FILES | `0x10` | — (up to 150 entries; the segment currently being written is **not** listed) |
| READ_FILE | `0x11` | `[cmd, fileNum, offset_4B LE, timestamp_4B LE]` |
| DELETE_FILE | `0x12` | `[cmd, fileNum, timestamp_4B LE]` |
| ROTATE | `0x13` | — |
| CLEAR_STORAGE | `0x14` | — |
| UNPAIR | `0x15` | — (firmware calls `bt_unpair()` and drops the link) |
| REBOOT | `0x16` | — (ACKs, closes the SD log cleanly, then cold-reboots) |
| POWER_OFF | `0x17` | — (ACKs, then ship mode; wakes on button or charger) |
| *(retired)* | `0x18` | Was ARM_POST_DFU_UNPAIR. Answers `INVALID_COMMAND`; the opcode is not reused, because older app builds still emit it |
| KEEP_ALIVE | `0x32` | — (resets the firmware's 60 s idle-disconnect timer) |

File indices are cache positions (0-based, rebuilt after every LIST and every delete). Supplying the timestamp in READ and DELETE lets the firmware re-locate the file by timestamp if the index shifted.

**Every successful DFU clears the BLE bond on both sides**, unconditionally — not gated on the version changing. The device watches its own `DFU_PENDING` event and unpairs on the next boot; the app releases the device and removes the phone-side bond from the DFU success callback, then waits until it hears the Omi advertising again before reconnecting. An occupied key slot refuses a fresh pairing whether the key in it is valid or corrupt, so a bond a flash damages cannot be recovered from the phone — which is exactly the same-version reflash a user performs *because* pairing is already broken.

---

## Settings Reference

### Recording Settings

| Setting | Pref key | Default | Notes |
|---------|----------|---------|-------|
| VAD enabled (Automatic mode) | `auto_vadEnabled` | false | On = run Silero; off (default) = AAD, split on firmware timestamps only. Enabling prompts a one-time battery warning. |
| Speech sensitivity | `vadSpeechThreshold` | 0.5 | Silero cutoff (0–1). Lower = more sensitive. |
| Silence to split | `vadSplitSeconds` | 120 s | Silence duration triggering a new recording |
| Min length | `filterMinDurationSeconds` | 0 s | Recordings shorter than this are discarded |
| Max length | `auto_` / `manual_vadMaxConversationMinutes` | 0 (off) | Hard cap; forces a split even without silence. `0` = no cap. Persisted per mode; mirrored into the legacy `vadMaxConversationMinutes` key the processor reads. |
| AAD threshold | `autoVadThreshold` | 250 | Firmware audio-activity gate; mode-specific overrides persisted separately |
| Recording mode | `manualMode` | true | Manual is the default. The app pushes this mode's button config and VAD threshold on connect and on every switch |

### App Settings

| Setting | Pref key | Default | Notes |
|---------|----------|---------|-------|
| Recording format | `audioSaveFormat` | wav | Output container: `wav` (PCM, default) or `m4a`. A legacy `ogg` value is coerced to `wav` |
| Recording Retention | `keepRecordingsDays` | -1 | -1 = forever, 0 = delete immediately after upload |
| Background sync interval | `backgroundSyncIntervalMinutes` | 30 | How often a background sync becomes due, measured from the last *completed* sync — a manual one counts. `-1` = Manual Only: no schedule, no exact alarm, and the foreground service falls back to connection-only |
| Show recording mode | `showRecordingMode` | true | Label recordings `Manual` / `Auto/VAD` / `Auto/AAD` instead of a bare `VAD`/`AAD` |
| Single recording button | `combineRecordButton` | false | Swap the split Record Start/Stop picker options for one Record Toggle; flipping it normalizes both mode mappings |
| Debug menu | `showDebugMenu` | false | Reveals the Debug Tools screen in the drawer |

---

## Hardware

| Component | Part | Spec |
|-----------|------|------|
| SoC | nRF5340-CLAA | Dual-core Bluetooth LE |
| Wi-Fi | nRF7002-CEAA-R7 | Wi-Fi 6 (present on the board; unused by this firmware) |
| Microphones | MMICT5838-00-012 x2 | TDK top-port PDM |
| NAND Flash | CSNP4GCR01-DPW | 512 MB |
| IMU | LSM6DS3TR-C | 6-axis accel/gyro. The gyro is off and the accelerometer runs in low-power mode — nothing reads the motion data; the accelerometer stays on only because the chip stops its clock counter if both halves idle, and that counter is what bridges a restart |
| Battery | GRP1654M1-1C-1S1P | 3.7 V 150 mAh LiPo |
| Charger | BQ25101YFPR | Li-Ion, magnetic pogo pins |
| Motor | — | 3 V vibration, D5.0×H2.5 mm |

PCB: mainboard (v1.2) + charger board (v1.0) + FPC (v1.0). Enclosure: CNC aluminium covers, PC+ABS shell, SLA frame, silicone pad. 88 components total.

---

## Repository Structure

```
omi-offline/
├── app/                    # Flutter mobile app
│   ├── lib/
│   │   ├── backend/        # Preferences, BT device schema
│   │   ├── gen/            # Pigeon-generated platform channel code
│   │   ├── models/
│   │   ├── pages/          # UI screens
│   │   │   ├── recordings/ # Recordings list, controller, players, uploads
│   │   │   ├── settings/   # Device Settings, Button Config, Debug Tools
│   │   │   └── dfuota/     # Firmware update
│   │   ├── providers/      # DeviceProvider (ChangeNotifier, drives all UI)
│   │   ├── services/
│   │   │   ├── devices/    # OmiConnection, DeviceService, transports, discovery
│   │   │   ├── wals/       # SDCardWalSyncImpl, WalService
│   │   │   ├── audio/      # AAC encoder
│   │   │   ├── bridges/    # ble_bridge.dart (Pigeon channel to native BLE)
│   │   │   ├── vad/
│   │   │   ├── recordings_manager.dart
│   │   │   ├── device_clock_anchor.dart
│   │   │   └── vad_audio_processor.dart
│   │   ├── utils/
│   │   └── widgets/
│   ├── android/            # Native BLE stack, foreground service, VAD runner,
│   │                       #   resident Flutter engine (MyApp), AAC encoder
│   ├── test/unit/
│   ├── third_party/        # Vendored flutter_onnxruntime
│   └── assets/
│       ├── models/         # Silero VAD ONNX model (v6.2.1 — see models/README.md for hashes + update steps)
│       ├── images/
│       └── fonts/
├── omi/
│   ├── firmware/           # Zephyr RTOS firmware (nRF5340)
│   │   ├── omi/src/        # C source (main.c, sd_card.c, sd_ring.c, aad.c, mic.c, …)
│   │   └── boards/
│   └── hardware/consumer/  # PCB design files
├── releases/               # Built APKs (gitignored)
├── screenshots/
├── CHANGELOG.md
├── NOTES.md
├── BLE_Research.md
├── LIVE_TESTING.md
├── IDEAS.md
└── CLAUDE.md
```

---

## Recent Changes

See [CHANGELOG.md](CHANGELOG.md) for the per-version history.

---

## Upstream

This is a fork of [BasedHardware/omi](https://github.com/BasedHardware/omi). The fork has diverged substantially — the entire cloud sync, OAuth, transcription, and memory backend has been removed in favour of the offline pipeline described above. Only the Opus codec and the nRF5340 board files remain compatible; the BLE GATT layout has also diverged (this fork has no live audio-stream service, and the codec ID is read at `0022` under the Features service).
