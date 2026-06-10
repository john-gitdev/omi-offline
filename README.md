# Omi Offline

A personal fork of the [Omi](https://github.com/BasedHardware/omi) wearable project, rebuilt entirely around local, private audio capture and processing. No cloud dependencies, no internet requirement — audio stays on your device until you choose to export it.

**Current versions:** App `0.22.1` · Firmware `oo-1.9.5`

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

The nRF5340 wearable captures audio continuously via PDM microphones, encodes it as Opus (16 kHz mono, 20 ms frames), and writes it to an SD card. The Flutter app connects over BLE, pulls files via a resumable WAL protocol, then segments the audio into dated recordings — splitting on firmware activity timestamps (AAD, the default) or, optionally, by running Silero VAD locally on the phone. Recordings are saved as WAV by default (M4A optional). Everything runs on-device.

---

## Key Features

- **100% offline.** No cloud API, no internet check. Data never leaves the device unless you explicitly upload it.
- **Resumable BLE sync (WAL).** Per-file byte-offset bookmarks survive disconnects. Sync resumes exactly where it stopped.
- **AAD (firmware activity detection) by default.** Automatic mode splits on the firmware's audio-activity timestamps and treats all captured audio as speech — no on-phone model. This is the default: it processes faster and uses less battery than Silero.
- **Silero VAD on-device (opt-in).** ONNX Runtime can run Silero VAD v6.2.1 locally on the phone to strip silence and segment speech. Disabled by default in Automatic mode; enabling it shows a one-time battery/processing-time warning. Runs in a background isolate so platform threads stay unblocked.
- **Two recording modes.** Automatic (hands-free; AAD by default, Silero optional) and Manual (explicit double-tap start/stop on the hardware button).
- **Verified Markers.** A double-tap drops a timestamped bookmark stored inline within the audio stream. During processing, the app parses these events with sub-frame precision to build high-precision EDL sidecars for the resulting recordings.
- **Discard recovery (ghost rows).** Audio that processing dropped (silenced as noise, or too short) is surfaced as a greyed-out "ghost" row in the recordings list, appearing in real time as each discard is identified. Source bins are protected for a 48 h window so you can recover a clip with a lower threshold or delete it.
- **Background battery saving.** The app always disconnects BLE when backgrounded (after a ~30 s grace window to survive quick screen-off/on) and reconnects only when a sync is due. The firmware records to SD card regardless of phone connectivity. A `PARTIAL_WAKE_LOCK` is held over the background sync+process run so Android doesn't downclock the processing isolate when the screen is off.
- **Processing resume from checkpoint.** If processing is interrupted (background kill, BLE drop, cancel), the next run restores the exact Silero LSTM recurrent state from a checkpoint file and picks up from the last completed segment — no re-decoding from scratch.
- **Integrations.** Optional upload to HeyPocket or Omi after processing. Omi uploads are split into ~5-minute chunks sent one at a time, with live chunk-level progress and resume-on-retry. Per-integration status (Uploaded / Pending / Failed / Uploading) is shown per recording with individual retry actions.

---

## Architecture

```
PDM mics → Opus encoder (firmware) → SD card (.bin segments)
                                           |
                              BLE GATT (WAL, ACK-gated)
                                           |
                              Flutter app (raw .bin on phone)
                                           |
                      AAD timestamps (default) or Silero VAD (opt-in)
                                           |
                        recordings/<YYYY-MM-DD>/recording_<ms>.wav
```

### Firmware (Zephyr RTOS, nRF5340)

- **Audio:** PDM at 16 kHz → Opus VBR, complexity 5, 20 ms frames (codec ID `20`: 80 B/frame, 50 fps).
- **Storage:** LittleFS on SD card. Copy-on-write metadata and journaling means the filesystem stays consistent through sudden power loss.
- **SD write pipeline:** Frames queue into `sd_msgq` (depth 150). Worker batches 100 frames per LittleFS write, fsyncs every 60 s. SPI bus is power-gated between operations (`sd_io_low_power`).
- **Time sync:** On BLE connect the app writes UTC as a little-endian `u32` to characteristic `0x0031`. The firmware renames any `TMP_` files and anchors recording timestamps to real wall time.
- **LED:** Defaults to off (stealth) after the boot-sequence flash (white breathe → solid white → fade). Triple-tap to enable the LED; triple-tap again to return to stealth.
- **Button:** Interrupt-driven (no 25 Hz polling). GPIO callback wakes the FSM only on press.
- **Battery ADC:** 60 s when connected, 5 min when disconnected.

### App (Flutter)

- **Native BLE bridge.** Pigeon-generated code calls the platform's native iOS/Android Bluetooth stack directly, bypassing Dart BLE library limitations.
- **Connection serialization.** `DeviceService.ensureConnection()` uses a `Mutex` so N concurrent callers (battery, storage, WAL sync) share one attempt.
- **Background lifecycle.** Pressing Back minimizes the app (keeps the BLE foreground service running); swiping from Recents still stops it. The app disconnects BLE ~30 s after going to background and reconnects on the auto-sync schedule or on app open.
- **WAL sync (`SDCardWalSyncImpl`).** Saves segments to `raw_segments/<timerStart>/<timerStart>_<sessionId>.bin`, where `timerStart` is the firmware-assigned UTC epoch seconds and `sessionId` is the 32-bit DeviceSession ID (or `0` if unknown). Pre-time-sync files land in a `raw_segments/session_<sessionId>/` fallback folder shown in the UI under "Unorganized".
- **VAD processor (`VadAudioProcessor`).** Runs in a fresh isolate. Stateless across runs — uncut segments stay on disk and are re-processed next cycle. Silero LSTM state is kept as a live native tensor between inference calls (no Dart-layer copy), reducing per-call allocations from ~6 objects to ~1. End-of-run always flushes as a `_draft` file; finalization only on a confirmed silence or cap boundary.
- **Processing checkpoint.** After each completed segment, the processor writes `vad_checkpoint.json` containing the full VAD state. Interrupted runs restore from this snapshot so processing resumes at the last completed segment with identical Silero recurrent state.
- **Background disconnect.** Always disconnects BLE on backgrounding (after ~30 s grace). A native Android keep-alive (`0x32`, `WRITE_NO_RESPONSE`, every 15 s) prevents firmware idle-disconnect during long file reads without blocking the GATT command queue.
- **Foreground-service resilience.** A single persistent notification (owned by the native `OmiBle` service) covers the full sync/processing cycle — idle → syncing → processing → ready — and survives BLE disconnects, backgrounding, and swipe-away without a force-close. The `flutter_foreground_task` plugin has been dropped entirely. Recording Settings surfaces a warning card when the app is not exempt from battery optimization, with a one-tap Fix that opens the system exemption prompt. A native `AlarmManager` exact alarm (`setExactAndAllowWhileIdle`) is armed whenever the next sync time is set; if Android freezes the Dart isolate, the alarm fires natively and delivers the sync request without Dart.
- **Recordings manager.** Parses finalized recordings (`.wav` by default; `.m4a` if configured) from `recordings/` for UI binding. Each recording carries a `.meta` sidecar listing the raw bins it was built from (`relativeBins`); marker EDL sidecars live alongside their recordings.

---

## Recording Modes

### Manual (default)

Double-tap the button to start; double-tap again to stop. The LED flashes green on start and red on stop, then stays yellow while recording.

- The AAD threshold is forced to `0xFFFF` (always-on) so the firmware never suppresses audio.
- Stopping emits a dedicated `0xFFFFFFFC` session-end marker so the processor finalizes the recording without waiting for a silence timeout.
- The app treats the captured span as a recording regardless of Silero VAD output.
- AAD Sensitivity and certain VAD settings are hidden in the UI.

### Automatic

The device monitors audio continuously. The LED stays off until audio above the AAD threshold wakes the mic pipeline (yellow = recording). Double-tap drops a white-flash marker.

- **AAD is the default:** the app treats every captured frame as speech and splits only on the firmware's activity timestamps. No on-phone model runs.
- **Silero VAD is opt-in.** Enabling it (in Recording Settings) shows a one-time warning that Silero uses more battery and takes longer to process. When on, it segments speech from silence and splits on `vadSplitSeconds` of continuous silence (default 2 min).
- Either way, the `vadMaxConversationMinutes` cap (default 60 min) forces a split without silence.
- Recordings accumulate across sync cycles — partial in-progress recordings are re-processed each run.

---

## LED State Machine

Priority order (highest wins):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off | Off |
| 2 | Charging starts | Force LED on (restored to prior state on unplug), continue |
| 3 | Double-tap flash event | ~1 s flash, overrides stealth. White = marker tap (auto mode); Green = manual recording start; Red = manual recording stop |
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
| Double tap (automatic mode) | White flash; writes a timestamped marker |
| Double tap (manual mode) | Green flash starts a recording; second double-tap (red flash) stops it and emits a session-end marker |
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
| VAD enabled (Automatic mode) | `auto_vadEnabled` | false | On = run Silero; off (default) = AAD, split on firmware timestamps only. Enabling prompts a one-time battery warning. |
| Speech sensitivity | `vadSpeechThreshold` | 0.5 | Silero cutoff (0–1). Lower = more sensitive. |
| Silence to split | `vadSplitSeconds` | 120 s | Silence duration triggering a new recording |
| Min length | `filterMinDurationSeconds` | 0 s | Recordings shorter than this are discarded |
| Max length | `vadMaxConversationMinutes` | 60 min | Hard cap; forces a split even without silence |
| AAD threshold | `autoVadThreshold` | 250 | Firmware audio-activity gate; mode-specific overrides persisted separately |

### App Settings

| Setting | Pref key | Default | Notes |
|---------|----------|---------|-------|
| Recording format | `audioSaveFormat` | wav | Output container: `wav` (PCM, default) or `m4a` |
| Recording Retention | `keepRecordingsDays` | -1 | -1 = forever, 0 = delete immediately after upload |

---

## Hardware

| Component | Part | Spec |
|-----------|------|------|
| SoC | nRF5340-CLAA | Dual-core Bluetooth LE |
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
│   │   ├── backend/        # Preferences, BT device schema
│   │   ├── gen/            # Pigeon-generated platform channel code
│   │   ├── pages/          # UI screens (recordings, settings, DFU/OTA)
│   │   ├── providers/      # DeviceProvider (ChangeNotifier, drives all UI)
│   │   ├── services/
│   │   │   ├── devices/    # BLE connection, OmiConnection, DeviceService
│   │   │   ├── wals/       # SDCardWalSyncImpl, WalService
│   │   │   ├── audio/      # Opus decode, audio pipeline
│   │   │   ├── bridges/    # Native platform bridges (Apple Watch)
│   │   │   ├── recordings_manager.dart
│   │   │   └── vad_audio_processor.dart
│   │   ├── utils/
│   │   └── widgets/
│   ├── test/unit/
│   ├── integration_test/
│   └── assets/
│       ├── models/         # Silero VAD ONNX model
│       ├── images/
│       └── fonts/
├── omi/
│   ├── firmware/           # Zephyr RTOS firmware (nRF5340)
│   │   ├── omi/src/        # C source (main.c, sd_card.c, aad.c, mic.c, led.c, …)
│   │   └── boards/
│   └── hardware/consumer/  # PCB design files
├── releases/               # Built APKs
├── screenshots/
├── test-data/
├── CHANGELOG.md
├── NOTES.md
├── IDEAS.md
└── CLAUDE.md
```

---

## Recent Changes

See [CHANGELOG.md](CHANGELOG.md) for the per-version history.

---

## Upstream

This is a fork of [BasedHardware/omi](https://github.com/BasedHardware/omi). The fork has diverged substantially — the entire cloud sync, OAuth, transcription, and memory backend has been removed in favour of the offline pipeline described above. Only the Opus codec, BLE characteristic UUIDs, and the nRF5340 board files remain compatible.
