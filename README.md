# omi-offline

Offline-first audio recorder for the Omi wearable. The device captures audio continuously with no cloud dependency — recordings sync to your phone over BLE or WiFi on demand.

## How it works

1. **Omi device** captures audio via Opus codec (16 kHz mono) and stores to SD card
2. **App connects** over BLE, reads the file list, and pulls recordings via resumable WAL sync
3. **App decodes** Opus → WAV, splits by silence, and organises recordings by date
4. **WiFi sync** (optional) uses a direct TCP connection for faster transfers on the same network

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
flutter run --flavor dev
```

**Firmware** — pre-built binaries for flashing are in `omi/firmware/FLASH_3.0.8/`. Source is in `omi/firmware/omi/`.

## License

MIT
