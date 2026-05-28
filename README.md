# Omi Offline

A personal fork of the [Omi](https://github.com/BasedHardware/omi) wearable project, rebuilt entirely around local, private audio capture and processing. No cloud dependencies, no internet requirement — audio stays on your device until you choose to export it.

**Current versions:** App `0.13.2` · Firmware `oo-1.7.10`

---

## What it does

The nRF5340 wearable captures audio continuously via PDM microphones, encodes it as Opus (16 kHz mono, 20 ms frames), and writes it to an SD card. The Flutter app connects over BLE, pulls files via a resumable WAL protocol, then runs Silero VAD locally to segment speech into dated `.m4a` recordings. Everything runs on-device.

---

## Key Features

- **100% offline.** No cloud API, no internet check. Data never leaves the device unless you explicitly upload it.
- **Resumable BLE sync (WAL).** Per-file byte-offset bookmarks survive disconnects. Sync resumes exactly where it stopped.
- **Silero VAD on-device.** ONNX Runtime executes Silero VAD v6.2.1 locally on the phone to strip silence and segment speech. Runs in a background isolate so platform threads stay unblocked.
- **Two recording modes.** Automatic (VAD-driven, hands-free) and Manual (explicit double-tap start/stop on the hardware button).
- **Verified Markers.** A double-tap drops a timestamped bookmark stored inline within the audio stream. During processing, the app parses these events with sub-frame precision to build high-precision EDL sidecars for the resulting recordings.
- **Adjustment Mode.** Re-run VAD on already-downloaded segments without touching the device — tweak sensitivity and reprocess offline.
- **Discard recovery (ghost rows).** Audio that VAD dropped (silenced as noise, or too short) is surfaced as a greyed-out "ghost" row in the recordings list. Source bins are protected for a 48 h window so you can recover a clip with a lower threshold or delete it.
- **AAD (All-As-Detected).** Disable Silero entirely and treat all audio as speech, splitting only on firmware timestamps.
- **Maximize Battery.** Disconnects BLE after each sync cycle so the wearable's 150 mAh cell lasts longer.
- **Integrations.** Optional upload to HeyPocket or Omi after processing.

---

## Architecture

```
PDM mics → Opus encoder (firmware) → SD card (.bin segments)
                                           |
                              BLE GATT (WAL, ACK-gated)
                                           |
                              Flutter app (raw .bin on phone)
                                           |
                           Silero VAD (ONNX, phone-local)
                                           |
                        recordings/<YYYY-MM-DD>/recording_<ms>.m4a
```

### Firmware (Zephyr RTOS, nRF5340)

- **Audio:** PDM at 16 kHz → Opus VBR, complexity 5, 20 ms frames (codec ID `20`: 80 B/frame, 50 fps).
- **Storage:** LittleFS on SD card. Copy-on-write metadata and journaling means the filesystem stays consistent through sudden power loss.
- **SD write pipeline:** Frames queue into `sd_msgq` (depth 100). Worker batches 100 frames per LittleFS write, fsyncs every 60 s. SPI bus is power-gated between operations (`sd_io_low_power`).
- **Time sync:** On BLE connect the app writes UTC as a little-endian `u32` to characteristic `0x0031`. The firmware renames any `TMP_` files and anchors recording timestamps to real wall time.
- **Button:** Interrupt-driven (no 25 Hz polling). GPIO callback wakes the FSM only on press.
- **Battery ADC:** 60 s when connected, 5 min when disconnected.

### App (Flutter)

- **Native BLE bridge.** Pigeon-generated code calls the platform's native iOS/Android Bluetooth stack directly, bypassing Dart BLE library limitations.
- **Connection serialization.** `DeviceService.ensureConnection()` uses a `Mutex` so N concurrent callers (battery, storage, WAL sync) share one attempt.
- **WAL sync (`SDCardWalSyncImpl`).** Saves segments to `raw_segments/<timerStart>/<timerStart>_<sessionId>.bin`, where `timerStart` is the firmware-assigned UTC epoch seconds and `sessionId` is the 32-bit DeviceSession ID (or `0` if unknown). Pre-time-sync files land in a `raw_segments/session_<sessionId>/` fallback folder shown in the UI under "Unorganized".
- **VAD processor (`OfflineAudioProcessor`).** Runs in a fresh isolate. Stateless across runs — uncut segments stay on disk and are re-processed next cycle. Never flushes mid-run in background mode.
- **Recordings manager.** Parses finalized `.m4a` files from `recordings/` for UI binding. Marker EDL sidecars live alongside their recordings.

---

## Recording Modes

### Automatic (default)

The device monitors audio continuously. Silero VAD segments speech from silence; the LED stays off until audio above the AAD threshold wakes the mic pipeline (yellow = recording).

- Split on: `vadSplitSeconds` of continuous silence (default 2 min), or `vadMaxConversationMinutes` cap (default 60 min).
- Recordings accumulate across sync cycles — partial in-progress recordings are re-processed each run.

### Manual

Double-tap the button to start; double-tap again to stop. The LED turns yellow while recording and off while waiting.

- The AAD threshold is forced to `0xFFFF` (always-on) so the firmware never suppresses audio.
- The app treats the captured span as a recording regardless of Silero VAD output.
- AAD Sensitivity and certain VAD settings are hidden in the UI.

---

## LED State Machine

Priority order (highest wins):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off | Off |
| 2 | Charging starts | Force LED on, continue |
| 3 | Double-tap marker | White (~1 s flash, overrides stealth) |
| 4 | Stealth mode | Off |
| 5 | Muted | Solid Red |
| 6 | Low battery (< 10%) | Solid Purple |
| 7 | BLE connected | Solid Blue (wins over recording) |
| 8 | Manual recording active (AAD threshold = 65535) | Solid Yellow |
| 9 | AAD auto-recording (`aad_is_recording()`) | Solid Yellow |
| 10 | Idle / disconnected | Off |

**Charging overlay** (applied on top of base state):
- Fully charged (>= 98%): Solid Green
- Charging: 500 ms blink between Green and current base color

**Button actions:**

| Action | Effect |
|--------|--------|
| Single tap | No action |
| Double tap | White flash; marks a timestamped event |
| Double tap + hold (1 s on second press) | Toggle mute (Red LED, mic paused) |
| Triple tap | Toggle Stealth Mode |
| Triple tap + hold (3 s on third press) | Power off |

---

## BLE Sync Protocol

All Omi services use base UUID `19b100xx-e8f2-537e-4f6c-d104768a1214`.

| Service | UUID suffix | Purpose |
|---------|-------------|---------|
| Audio | `0000` / `0001` / `0002` | Stream + codec ID |
| Settings | `0010` / `0011` / `0012` | Dim ratio, mic gain |
| Features | `0020` / `0021` | Capability flags |
| Time sync | `0030` / `0031` | Write epoch (u32 LE) |
| Speaker/haptic | `0040` / `0041` | Playback commands |
| Battery detail | `0050` / `0051` | Notify 1 byte: uint8 charging 0/1 |
| Storage | `30295780-…` | File list + read/delete |
| Button | `23ba7924-…` | Tap events (1=single 2=double 3=long 4=press 5=release) |

**Storage commands** (write to `storageDataStreamCharacteristicUuid`):

| Command | Byte | Payload |
|---------|------|---------|
| LIST_FILES | `0x10` | — |
| READ_FILE | `0x11` | `[cmd, fileNum, offset_4B LE, timestamp_4B LE]` |
| DELETE_FILE | `0x12` | `[cmd, fileNum, timestamp_4B LE]` |
| ROTATE | `0x13` | — |
| CLEAR_STORAGE | `0x14` | — |

File indices are cache positions (0-based, rebuilt after every LIST and every delete). Supplying the timestamp in READ and DELETE lets the firmware re-locate the file by timestamp if the index shifted.

---

## Settings Reference

### Recording Settings

| Setting | Pref key | Default | Notes |
|---------|----------|---------|-------|
| VAD enabled | `vadEnabled` | true | Off = AAD mode, split on firmware timestamps only |
| Speech sensitivity | `vadSpeechThreshold` | 0.5 | Silero cutoff (0–1). Lower = more sensitive. |
| Silence to split | `vadSplitSeconds` | 120 s | Silence duration triggering a new recording |
| Min length | `filterMinDurationSeconds` | 0 s | Recordings shorter than this are discarded |
| Max length | `vadMaxConversationMinutes` | 60 min | Hard cap; forces a split even without silence |
| AAD threshold | `autoVadThreshold` | 250 | Firmware audio-activity gate; mode-specific overrides persisted separately |

### App Settings

| Setting | Pref key | Default | Notes |
|---------|----------|---------|-------|
| Adjustment Mode | `adjustmentMode` | false | Keep raw segments for offline reprocessing |
| Keep recordings for | `keepRecordingsDays` | -1 | -1 = forever, 0 = delete immediately after upload |
| Maximize Battery | `maximizeBattery` | false | Disconnect BLE after each sync cycle |
| 24-hour time | `use24HourFormat` | false | Toggle AM/PM vs 24 h in UI |

---

## Hardware

| Component | Part | Spec |
|-----------|------|------|
| SoC | nRF5340-CLAA | Dual-core Bluetooth LE |
| Wi-Fi | nRF7002-CEAA-R7 | Wi-Fi 6 |
| Microphones | MMICT5838-00-012 x2 | TDK top-port PDM |
| NAND Flash | CSNP4GCR01-DPW | 512 MB |
| IMU | LSM6DS3TR-C | 6-axis accel/gyro |
| Battery | GRP1654M1-1C-1S1P | 3.7 V 150 mAh LiPo |
| Charger | BQ25101YFPR | Li-Ion, magnetic pogo pins |

PCB: mainboard (v1.2) + charger board (v1.0) + FPC (v1.0). Enclosure: CNC aluminium covers, PC+ABS shell, SLA frame, silicone pad. 88 components total.

---

## Repository Structure

```
omi-offline/
├── app/                    # Flutter mobile app
│   ├── lib/
│   │   ├── pages/          # UI screens (recordings, settings, device)
│   │   ├── providers/      # DeviceProvider (ChangeNotifier, drives all UI)
│   │   └── services/
│   │       ├── devices/    # BLE connection, OmiConnection, DeviceService
│   │       ├── wals/       # SDCardWalSyncImpl, WalService
│   │       └── vad_audio_processor.dart
│   └── test/
├── omi/
│   └── firmware/
│       └── omi/src/        # Zephyr C source (main.c, sd_card.c, aad.c, mic.c, led.c, battery.c, …)
├── NOMENCLATURE.md         # Canonical project glossary
├── NOTES.md                # Engineering notes and findings
├── IDEAS.md                # Backlog / future ideas
└── CLAUDE.md               # AI assistant instructions
```

---

## Development

### App

```bash
# First-time setup (installs deps, runs pod install on iOS, then launches the app)
cd app && bash setup.sh ios     # or android

# Subsequent runs (workspace already exists)
cd app && flutter run --flavor dev

# Test
cd app && bash test.sh

# Format
dart format --line-length 120 <files>
```

### Firmware

Requires nRF Connect SDK 2.9.0 via `nrfutil toolchain-manager`. Full setup in [`omi/firmware/BUILD_AND_OTA_FLASH.md`](omi/firmware/BUILD_AND_OTA_FLASH.md).

```bash
# Launch the SDK environment (run from omi/firmware/omi/)
nrfutil toolchain-manager launch --ncs-version v2.9.0 --shell

# Build using the CMake preset
cmake --preset OMI
cmake --build build/omi
# CMakePresets.json sets board (omi/nrf5340/cpuapp), conf file (omi.conf),
# and build dir (build/omi) — no extra flags needed.

# Package for OTA: reads version from omi.conf, stamps version.txt into the zip
# so the app can display the firmware version string.
./package_firmware.sh
# Output: build/omi/dfu_application_release.zip
```

Flash via **nRF Connect for Mobile**: connect to the device, go to DFU tab, select `dfu_application_release.zip`.

---

## Nomenclature

See [`NOMENCLATURE.md`](NOMENCLATURE.md) for the full glossary. Key terms:

| Term | Definition |
|------|-----------|
| Frame | Single Opus unit (~20 ms) |
| Segment | A `.bin` file containing frames |
| DeviceSession | Continuous hardware stream from boot to disconnect; identified by UTC start timestamp |
| Marker | Double-tap event — timestamped bookmark written by firmware as `0xFE` frame type |
| WAL | Byte-offset sync state tracking download progress per segment |
| Recording | Finalized `.m4a` audio file on disk |
| Conversation | Recording + timestamps, the local UI entity |

---

## Recent Changes

### Connection Reliability & Battery (0.14.4, Firmware oo-1.9.0)

- **Keep-Alive Pings.** Introduced a foreground keep-alive timer (`sendKeepAlive`) to prevent the firmware from prematurely idle-disconnecting. Dead connections are force-disconnected after consecutive keep-alive failures.
- **Background Leaks.** Closed reconnect leaks when "Maximize Battery" is on, ensuring the app actually stays disconnected in the background.
- **Android BLE Stability.** Added direct connect-by-MAC fast paths, static presence observation helpers, and auto-recovery for stale BLE bonds following an OTA update.

### Manual Mode Enhancements (0.14.0, Firmware oo-1.8.1)

- **Default Mode.** Manual mode is now the default out-of-the-box experience.
- **Hardcoded VAD.** In manual mode, VAD and filter values are now hardcoded to ensure predictable recording capture; only the maximum length cap remains tunable.
- **Session-End Markers.** Stopping a manual recording now emits a dedicated `0xFFFFFFFC` session-end marker to explicitly finalize the recording stream.
- **Colored Flashes.** The device LED now flashes Green when manually starting a recording, and Red when stopping.

### Diagnostics & Data Management (0.13.3 – 0.14.1, Firmware oo-1.7.11)

- **SD Drop Diagnostics.** Implemented a new diagnostic characteristic (`0x19B10062`) to count `storage_block_drops` on the firmware. Drop stats are now read and rendered on the app's Debug Tools page.
- **Robust Bin Cleanup.** Added guards to prevent re-VAD'ing leftover segments, reconcile bin file sizes with WAL offsets on sync resume, and wipe orphan-session raw bins during a "Delete Day" operation.

### Marker Creation Pipeline (0.13.2)

- **Inline Source.** Markers (20-byte frames) are now stored directly within the raw `.bin` stream. This replaces the legacy `markers.txt` intermediate sidecar, ensuring that events are physically tied to the audio frames they accompany.
- **On-the-fly Parsing.** The VAD processor now parses these inline markers during the decoding pass. This architectural shift ensures perfect synchronization between the audio stream and button-tap events.
- **Robust EDL Sidecars.** The JSON-based **Edit Decision List (EDL)** system has been hardened with atomic writes, reliable deduping (no more `_1.edl` duplicates), and support for "orphan" markers (taps during silence).
- **Timeline Recalibration.** Markers arriving mid-recording now recalibrate the anchor timestamp if the initial anchor was an estimate (derived from file mtime), fixing "second-order" drift in long recordings.

### Silero VAD v6 upgrade (0.13.0)

- Bumped the bundled `silero_vad.onnx` from v3 to v6.2.1 (~16% fewer errors on noisy real-life data per Silero's release notes).
- v6 collapses the separate LSTM `h` / `c` states into one 256-float recurrent `state` tensor, requires a 64-sample context window prepended to each 512-sample input, and a true 0-D scalar `sr`. The processor handles all of this internally.
- Same `vadSpeechThreshold` default (0.5) but v6 is more conservative — fewer false positives. Lower the threshold to 0.3–0.4 if quiet speech is missed.

### Android 16 / 16 KB page support (0.13.0)

- Swapped `onnxruntime: ^1.4.0` for `flutter_onnxruntime: ^1.7.1`, which bundles ORT 1.22.0 with 16 KB page-aligned `.so` files. Required for Android 16 devices booted with 16 KB pages and for Play Store submissions targeting SDK 36+ (enforced since Nov 2025).
- `targetSdkVersion` 35 → 36, iOS minimum 15 → 16 (`Podfile`, `Runner.xcodeproj`).
- ONNX inference is now async at the API layer — no longer FFI-blocks the platform thread, reducing the chance of `ForegroundServiceDidNotStartInTimeException` during cold session creation.
- The VAD model is pre-copied from `rootBundle` to `getApplicationSupportDirectory()` on the main isolate, then loaded in the processing isolate via `OnnxRuntime().createSession(path)` (the `createSessionFromAsset` API isn't usable from a background isolate).

### Edge-to-edge UI (0.12.0)

- Removed the edge-to-edge opt-out from default and night styles across all SDK 31+ resource folders.
- Wrapped the marker and recording player bodies in `SafeArea` so content respects system bars.
- Enabled `OnBackInvokedCallback` in the manifest (Android 14+ predictive back gesture).

### Perf, fixes & cleanup (0.12.0)

- `deleteDay`: replaced a serial EDL-deletion loop with O(M) concurrent deletion.
- Recordings list: dedup discards by id in `getDiscardsForDate`; show seconds for sub-minute ghost durations.
- Removed 46 unused dependencies and a SF Pro font block from `pubspec.yaml`.
- Deleted dead Android handlers (`WifiNetworkPlugin`, `NotificationOnKillService`), unused manifest entries, dead image / font / gif assets, and a sweep of unused imports across services, tests, and Flutter pages.

### Discard recovery & ghost rows (0.11.1 – 0.11.2)

- **Ghost rows.** Stretches of audio that VAD dropped are recorded to `recordings/<date>/discards.jsonl` and shown as greyed-out rows in the recordings list, labelled "silenced by VAD" (noise) or "too short". Ghosts route through visible/hidden tabs by duration, with the threshold tied to `filterMinDurationSeconds`.
- **Two-button recovery sheet.** Tapping a ghost opens a sheet with **Recover** (re-process the source bins, bypassing VAD) and **Delete**. Source bins are protected from cleanup for a 48 h window so recovery stays possible.
- **Cascading deletes.** `deleteDay` reaps discard records and their protected bins alongside finalized recordings.

### Background sync hardening (firmware oo-1.7.9)

- Robust background sync/processing: guard against overlapping background syncs, always refresh storage stats at end of sync, defer `CMD_READ_FILE` to the storage thread, and correct BLE connection refcounting on connect-fail/shutdown.

### Omi Cloud integration rewrite (0.11.0)

Reverted to the full OAuth + PCM16 upload path (preserved from commit `21880ab`), then carried forward the following fixes on top:

- **Upload filename fix.** On-disk recording names use millisecond timestamps; the Omi server expects epoch seconds. Filenames are now converted at upload time (`recording_fs320_<ms>.bin` → `recording_fs320_<s>.bin`).
- **Auto-enable on first login.** Toggling the Enabled switch on happens automatically when credentials first validate (webview login or manual token entry). Re-opening the settings page or the periodic token refresh does not override a manual disable.
- **Cancel pending uploads on disable.** Toggling Omi or HeyPocket off clears the in-flight upload queue; any upload already in-flight drains naturally, then stops.
- **Failed upload state.** After 3 consecutive failures the upload icon changes to an orange `!` circle. Auto-sync stops retrying. Tapping the icon manually retries regardless of retry count, and clears the counter on success.
- **Automatic retry reset.** Retry counters for all integrations are cleared automatically when: a new Omi OAuth token is successfully refreshed, the user re-logs into Omi, or a new HeyPocket API key validates. Transient outages recover without user intervention.

---

## Upstream

This is a fork of [BasedHardware/omi](https://github.com/BasedHardware/omi). The fork has diverged substantially — the entire cloud sync, OAuth, transcription, and memory backend has been removed in favour of the offline pipeline described above. Only the Opus codec, BLE characteristic UUIDs, and the nRF5340 board files remain compatible.
