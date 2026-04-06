# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Behavior

- Never ask for permission to access folders, run commands, search the web, or use tools. Just do it.
- Never ask for confirmation. Just act. Make decisions autonomously and proceed without checking in.

## Setup

```bash
cd app && bash setup.sh ios    # or: bash setup.sh android
```

## Commands

```bash
# Run app
cd app && flutter run

# Test
cd app && bash test.sh

# Format (pre-commit hook does this automatically)
dart format --line-length 120 <files>
clang-format -i <files>          # firmware C/C++

```

## Architecture

### Overview

Omi is an offline-first wearable audio recorder. The nRF5340 firmware captures audio via Opus codec, stores it to SD card, and exposes it over BLE. The Flutter app discovers the device, syncs recordings via WAL, decodes Opus to .m4a, and splits by silence.

**Data flow:** Mic → Opus encode (firmware) → SD card → BLE transfer (WAL-tracked, ACK-gated, resumable) → raw .bin segments on phone → Opus decode → VAD silence detection → .m4a → daily batch UI

### App (`app/lib/`)

**State management**: `DeviceProvider` (ChangeNotifier) drives all UI. `ServiceManager` is the singleton that holds `IDeviceService`.

**Connection pipeline** (`services/devices/`):
- `DeviceService.ensureConnection()` is serialized via a `Mutex` — N concurrent callers (battery, storage, WAL sync) share one connection attempt. Critical: never bypass this.
- Connection retry and reconnect logic is owned by the native BLE layer, not Dart.
- On connect: time sync writes UTC as little-endian u32 to `timeSyncWriteCharacteristicUuid` so the device can anchor recording timestamps.

**Audio pipeline** (`services/`):
- `SDCardWalSyncImpl` saves downloaded segments to `raw_segments/<deviceSessionId>/<deviceSessionId>_<segmentIndex>.bin`; marker packets (20-byte frames: `0xFFFFFFFE` header + 16-byte payload) are extracted to `markers.txt` during transfer
- `OfflineAudioProcessor` decodes Opus → 16 kHz mono 16-bit PCM, adaptive noise floor tracking (initial -40 dBFS, SNR margin configurable), splits into `recordings/<YYYY-MM-DD>/recording_<millis>.m4a`
- `RecordingsManager` / `Conversation` model parses finalized recordings from the `recordings/` directory for UI binding

**Sync** (`services/wals/`):
- `WalService` creates `Wal` entries per file (tracks codec, device, storage location, sync status: miss → syncing → synced)
- `SDCardWalSyncImpl` reads files over BLE — allows resume on reconnect without re-downloading

### Hardware (`omi/hardware/consumer/`)

Omi Consumer — open-source AI wearable. PCB: mainboard (v1.2) + charger board (v1.0) + FPC (v1.0).

| Component | Part | Spec |
|-----------|------|------|
| SoC | nRF5340-CLAA | Dual-core Bluetooth LE (Nordic Semiconductor) |
| Wi-Fi | nRF7002-CEAA-R7 | Wi-Fi 6 (Nordic Semiconductor) |
| Microphones | MMICT5838-00-012 ×2 | TDK top-port PDM |
| NAND Flash | CSNP4GCR01-DPW | 512 MB (CS Semiconductor) |
| IMU | LSM6DS3TR-C | 6-axis accelerometer/gyroscope (STMicroelectronics) |
| Battery | GRP1654M1-1C-1S1P | 3.7 V 150 mAh LiPo, D16×H6.1 mm (GERUIPU) |
| Charger IC | BQ25101YFPR | Li-Ion, magnetic pogo pins (Texas Instruments) |
| Motor | — | 3 V vibration, D5.0×H2.5 mm |

Enclosure: CNC aluminium covers (Case A/B), PC+ABS injection-moulded shell, SLA frame + LED guide, silicone internal pad (50A/80A). 88 components total.

### Firmware (`omi/firmware/omi/src/`)

Zephyr RTOS on nRF5340. Key threads: mic capture → codec ring buffer → Opus encode → BLE notify / SD card write.

**Opus config**: 16 kHz mono, VBR, complexity 5, 20 ms frames.

### BLE Protocol

All Omi services use base UUID `19b100xx-e8f2-537e-4f6c-d104768a1214`:

| Service | UUID suffix | Purpose |
|---------|-------------|---------|
| Audio | `0000` / `0001` / `0002` | Stream + codec ID |
| Settings | `0010` / `0011` / `0012` | Dim ratio, mic gain |
| Features | `0020` / `0021` | Capability flags |
| Time sync | `0030` / `0031` | Write epoch seconds (u32 LE) |
| Speaker/haptic | `0040` / `0041` | Playback commands |
| Battery detail | `0050` / `0051` | Notify 4 bytes: uint16 LE millivolts (bytes 0–1), uint8 percentage 0–100 (byte 2), uint8 charging 0/1 (byte 3) |
| Storage | `30295780-…` | File list + read/delete |
| Button | `23ba7924-…` | Tap events (1=single, 2=double, 3=long, 4=press, 5=release) |

Storage protocol: write commands to `storageDataStreamCharacteristicUuid`: `0x10`=LIST_FILES, `0x11`=READ `[cmd, fileNum, offset_4B LE]`, `0x12`=DELETE `[cmd, fileNum]`, `0x13`=ROTATE, `0x14`=CLEAR_STORAGE.

Audio codec IDs: 1=pcm8, 20=opus (80 B/frame, 50 fps), 21=opusFS320 (40 B/frame, 50 fps).

## App (Flutter)

### Verifying UI Changes (agent-flutter)

After editing Flutter UI code, **verify the change programmatically** — do not just hot restart and hope.

Marionette is already integrated in debug builds (`marionette_flutter: ^0.3.0`). Install agent-flutter once: `npm install -g agent-flutter-cli`.

```bash
kill -SIGUSR2 $(pgrep -f "flutter run" | head -1)   # hot restart
AGENT_FLUTTER_LOG=/tmp/flutter-run.log agent-flutter connect
agent-flutter snapshot -i              # list interactive widgets
agent-flutter press @e3                # tap by ref (re-snapshot first — refs go stale)
agent-flutter press 540 1200           # tap by coordinates (ADB fallback)
agent-flutter find type button press   # more stable than @ref
agent-flutter fill @e5 "hello"
agent-flutter screenshot /tmp/after.png
```

- `AGENT_FLUTTER_LOG` must point to the flutter run stdout log (not logcat).
- Use `Key('descriptive_name')` on new interactive widgets so agents can use `find key`.
- See `app/e2e/SKILL.md` for screen map and known flows.

## Formatting

The pre-commit hook handles formatting automatically. To run manually:

```bash
dart format --line-length 120 <files>   # Dart (not *.gen.dart or *.g.dart)
clang-format -i <files>                  # C/C++ firmware
```

## Git

- Always commit to the current branch — never switch branches.
- Never squash merge PRs — use regular merge.
- Make individual commits per file, not bulk commits.
- If push fails because the remote is ahead: `git pull --rebase && git push`.
- Never push or create PRs unless explicitly asked — commit locally by default.

### RELEASE / release command
When the user says "release" or "RELEASE", increment the patch digit in `app/pubspec.yaml` by 1, commit, and push. The patch digit serves as the build number — there is no separate `+N` suffix. Example: `0.3.18` → `0.3.19`.
