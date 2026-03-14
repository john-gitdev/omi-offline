# omi-offline

An offline-first audio recorder for the [Omi](https://omi.me) wearable. The device captures audio continuously and stores it locally — no cloud required. The app syncs recordings to your phone over BLE or WiFi, decodes them, and organizes them by day.

## How it works

1. **Omi device** captures audio via Opus codec (16 kHz mono) and writes to its SD card
2. **App connects** over BLE, reads the file list, and pulls recordings via WAL sync (resumable on disconnect)
3. **App decodes** Opus → WAV, splits by silence, and saves recordings organized by date
4. **WiFi sync** (optional) switches to a direct TCP connection for faster transfers when on the same network

## Repo structure

```
omi/        nRF52840 firmware (Zephyr RTOS, C/C++)
app/        Flutter mobile app (iOS + Android)
scripts/    Pre-commit hook, OTA update tooling
```

## Getting started

**Firmware** — see `omi/firmware/devkit/` for Zephyr build instructions.

**App:**
```bash
cd app
bash setup.sh ios       # or: bash setup.sh android
flutter run
```

Install the pre-commit hook (auto-formats Dart and C++ on commit):
```bash
ln -s -f ../../scripts/pre-commit .git/hooks/pre-commit
```

## License

MIT
