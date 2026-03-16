# omi-offline

Offline-first audio recorder for the Omi wearable. The device captures audio continuously with no cloud dependency — recordings sync to your phone over BLE and are stored locally as AAC (M4A) files.

## How it works

1. **Omi device** captures audio via Opus codec (16 kHz mono) and writes to SD card
2. **App connects** over BLE, reads the file list, and pulls recordings via resumable WAL sync
3. **App decodes** Opus → PCM, runs silence detection to split conversations, and encodes each segment to AAC (M4A) organised by date

## Repo structure

```
omi/    nRF52840 firmware (Zephyr RTOS, C/C++)
app/    Flutter mobile app (iOS + Android)
```

## Getting started

**App:**
```bash
cd app
bash setup.sh ios       # or: bash setup.sh android
flutter run
```

**Firmware** — build from source in `omi/firmware/omi/` using Zephyr. `omi/firmware/FLASH_3.0.8/` contains pre-built binaries.

## Storage

Recordings are saved as AAC at 32 kbps (~0.24 MB/min). A `.meta` sidecar file is written alongside each recording and stores duration and waveform data so the player doesn't need to decode the audio file.

Legacy `.wav` recordings from earlier builds are still supported for playback.

## License

MIT
