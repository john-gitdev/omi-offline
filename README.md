# Omi Offline

<div align="center">
  <img src="screenshots/hero-banner.jpg" alt="Omi Hero Banner" width="100%" />
</div>

<div align="center">
  <h3>The ultimate open-source offline wearable for capturing your life.</h3>
  <p>
    <b>Omi Offline</b> captures your life's audio completely offline, using hardware-accelerated machine learning to process, filter, and organize your conversations without a cloud subscription.
  </p>
</div>

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: Android | iOS](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-green.svg)]()
[![Hardware: nRF5340](https://img.shields.io/badge/Hardware-nRF5340-orange.svg)]()

</div>

---

## 📖 Overview

Omi Offline is a fork of [BasedHardware/omi](https://github.com/BasedHardware/omi), designed specifically for privacy-conscious users. **We removed all cloud sync, OAuth, remote transcription, and memory backend features.** Instead, the Omi hardware captures audio directly to its onboard eMMC storage, and your smartphone uses a native, highly-optimized Voice Activity Detection (VAD) engine to process and segment that audio entirely offline.

You own your hardware, and you own your data.

## ✨ Key Features

- **100% Offline Processing:** Audio is stored locally on the device (eMMC) and synced via BLE to your phone.
- **On-Device Machine Learning (Silero VAD):** Uses a highly optimized Native VAD Batch Runner for Android to process audio and filter out silence without draining your phone's battery.
- **Intelligent Audio Activity Detection (AAD):** Hardware-level acoustic gating ensures the mic pipeline sleeps when it's quiet, saving battery.
- **Customizable Recording Modes:** Choose between Manual (marker-based) or Automatic (continuous monitoring) modes.
- **Background Resilience:** Robust BLE syncing works in the background and gracefully handles Android's Doze mode.
- **Flexible Export:** Export your conversations in WAV (PCM), M4A (AAC), or OGG (Opus) formats.
- **Data Integrations:** Seamlessly upload finalized audio to third-party integrations like HeyPocket.
- **No Subscriptions, No Cloud:** Your recordings never leave your phone unless you explicitly upload them.

---

## 📸 Screenshots

<div align="center">
  <table style="border: none;">
    <tr>
      <td align="center"><img src="screenshots/Conversation Page.jpg" width="260px" alt="Conversation Page" /></td>
      <td align="center"><img src="screenshots/Recording Modes.jpg" width="260px" alt="Recording Modes" /></td>
      <td align="center"><img src="screenshots/VAD Option.jpg" width="260px" alt="VAD Options" /></td>
    </tr>
    <tr>
      <td align="center"><img src="screenshots/Device Settings.jpg" width="260px" alt="Device Settings" /></td>
      <td align="center"><img src="screenshots/Integrations.jpg" width="260px" alt="Integrations" /></td>
      <td align="center"></td>
    </tr>
  </table>
</div>

---

## 🏗️ Architecture

Omi uses an offline-first architecture prioritizing battery life and data sovereignty.

```mermaid
graph TD
    subgraph Hardware [Omi Wearable (nRF5340)]
        Mic[Microphones] --> AAD[Hardware AAD Gate]
        AAD --> Opus[Opus Encoder]
        Opus --> eMMC[(eMMC Storage)]
        eMMC -.-> |BLE Sync| BLE[Bluetooth LE]
    end

    subgraph Phone [Smartphone (App)]
        BLE_App[BLE Receiver] --> WAL[WAL Sync (Raw Bins)]
        WAL --> VAD[Native VAD Batch Runner]
        VAD --> File_Sys[(Finalized Recordings)]
        File_Sys --> UI[Recordings UI]
        File_Sys --> Export[M4A / WAV / OGG]
    end

    BLE --> BLE_App
```

### The Pipeline

1. **Capture:** The hardware monitors audio. In Automatic mode, the AAD threshold ensures it only records when noise is present. In Manual mode, the user double-taps to drop a marker.
2. **Storage:** Audio is compressed with Opus and saved to the onboard eMMC.
3. **Sync:** The phone connects via BLE and securely downloads the raw audio bins.
4. **Processing (VAD):** The **Native VAD Batch Runner** processes the audio using the Silero ONNX model. It intelligently identifies speech, trims silence, and finalizes segments into listenable files.
5. **UI & Export:** The finalized recordings are displayed in the app, marked with `AAD` or `VAD` processing tags, and can be retained or automatically uploaded based on user settings (e.g., "Upload on Wifi Only").

---

## 🛠️ Recording Modes

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

## 💡 LED State Machine

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

## ⚙️ Settings Reference

### App Settings

| Setting | Notes |
|---------|-------|
| Auto Sync Interval | Frequency of background BLE syncing. |
| Upload on Wifi Only | If enabled, integrations (like HeyPocket) will only upload when connected to Wi-Fi. |
| Save File Format | Output container: `wav` (PCM, default), `m4a`, or `ogg`. |
| Short Recordings | Filter out or Hide short recordings (applicable in both modes). |
| Keep recordings for | Retention policy (e.g., -1 = forever, 0 = delete immediately after upload). |
| Time Format | 12-hour or 24-hour time formatting in UI. |

### Recording Settings

| Setting | Default | Notes |
|---------|---------|-------|
| VAD enabled (Automatic mode) | false | On = run Silero; off (default) = AAD, split on firmware timestamps only. |
| Speech sensitivity | 0.5 | Silero cutoff (0–1). Lower = more sensitive. |
| Silence to split | 120 s | Silence duration triggering a new recording. |
| Max length | 60 min | Hard cap; forces a split even without silence. |
| AAD threshold | 250 | Firmware audio-activity gate; mode-specific overrides persisted separately. |

---

## 🔌 BLE Sync Protocol

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

## 🧰 Hardware

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

## 📁 Repository Structure

```text
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
│   │   │   ├── vad_audio_processor.dart
│   │   │   ├── vad_batch_runner_channel.dart # Native VAD bridge
│   │   ├── utils/
│   │   └── widgets/
│   ├── android/
│   │   └── app/src/main/kotlin/com/omi/offline/VadBatchRunner.kt # Native VAD
│   ├── test/unit/
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
├── CHANGELOG.md
└── CLAUDE.md
```

---

## 🚀 Recent Changes

See [CHANGELOG.md](CHANGELOG.md) for the complete per-version history. Recent major updates include:

- **Native VAD Optimization:** A new high-performance Native VAD Batch Runner for Android, drastically reducing memory leaks and improving processing speed.
- **Workflow & UI Improvements:** Relocated "Forget Device" to the discovery page, reorganized App Settings (including "Upload on Wifi Only" and Short Recordings filters), and added `AAD`/`VAD` processing indicators.
- **Sync Resilience:** Increased test coverage and hardened the audio pipeline against application crashes, unexpected hardware disconnections, and partial downloads.

---

## 🍴 Upstream

This is a fork of [BasedHardware/omi](https://github.com/BasedHardware/omi). The fork has diverged substantially — the entire cloud sync, OAuth, transcription, and memory backend has been removed in favour of the offline pipeline described above. Only the Opus codec, BLE characteristic UUIDs, and the nRF5340 board files remain compatible.

---

## 💻 Installation

### Mobile App (Flutter)
1. Install [Flutter](https://flutter.dev/docs/get-started/install) (sdk >=3.0.0 <4.0.0).
2. Install Android Studio or Xcode for your target platform.
3. Clone the repository and navigate to the `app/` directory.
4. Run `flutter pub get` to install dependencies.
5. Build and run on a physical device: `flutter run --release`. (The app relies heavily on BLE and native ONNX runtime, so simulators may not fully support all features).

### Firmware (Zephyr RTOS)
1. Set up the [nRF Connect SDK](https://developer.nordicsemi.com/nRF_Connect_SDK/doc/latest/nrf/getting_started.html).
2. Navigate to `omi/firmware/`.
3. Follow the build instructions detailed in `omi/firmware/readme.md` to compile for the nRF5340 board.
4. Flash the compiled firmware onto the Omi device via SWD/J-Link or DFU over BLE.

---

## 🛠️ Development Workflow
- All mobile app development occurs in the `app/` directory.
- Test coverage for critical sync logic and VAD batch processing is maintained in `app/test/unit/`.
- Ensure you run `flutter test` before submitting changes to the Flutter app.
- For firmware development, changes reside in `omi/firmware/omi/src/`. Maintainers handle over-the-air (OTA) updates for consumer hardware via standard Nordic DFU.

---

## ⚠️ Troubleshooting

- **No audio after sync:** Check that the hardware AAD threshold isn't too high. In Automatic mode, absolute silence is not recorded to save battery. Ensure the VAD model didn't incorrectly classify your speech as silence (you can lower the `vadSpeechThreshold` in Settings).
- **Device refuses to connect:** Try using the "Forget Device" option in the "Find Devices" page, then restart your phone's Bluetooth.
- **Sync stalls or freezes:** If you encounter `SocketException` or timeout errors during sync, try placing the device closer to your phone. The app will automatically resume from the last completed segment on the next cycle.
- **Excessive battery drain on phone:** Ensure Silero VAD is either disabled (relying purely on hardware AAD) or that your Android OS is allowing the `VadBatchRunner` to execute natively without excessive background restrictions.

---

## 🚧 Known Limitations
- The app relies on the mobile OS allowing background execution for BLE and native processing. If Android's battery optimizer strictly kills the background isolate, the sync process might be delayed until the phone is unlocked, though the Exact Alarm mechanism aims to mitigate this.
- Time synchronization (`0030`/`0031`) relies on the phone's clock. If the wearable reboots and is not connected to a phone, timestamps on files may reset to 0 until the next connection.
