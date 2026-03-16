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

# Regenerate l10n after editing ARB files
cd app && flutter gen-l10n
```

## Architecture

### Overview

Omi is an offline-first wearable audio recorder. The nRF52840 firmware captures audio via Opus codec, stores it to SD card, and exposes it over BLE. The Flutter app discovers the device, syncs recordings via WAL, decodes Opus to WAV, and splits by silence.

**Data flow:** Mic → Opus encode (firmware) → SD card → BLE/WiFi transfer → WAL sync → Opus decode → silence detection → WAV files → daily batch UI

### App (`app/lib/`)

**State management**: `DeviceProvider` (ChangeNotifier) drives all UI. `ServiceManager` is the singleton that holds `IDeviceService`.

**Connection pipeline** (`services/devices/`):
- `DeviceService.ensureConnection()` is serialized via `_pendingConnection` future — N concurrent callers (battery, storage, WAL sync) share one connection attempt. Critical: never bypass this.
- `BleTransport` retries service discovery up to 3× if service is missing (transient), but bails immediately if service is found but characteristic is absent (firmware lacks it — retrying cannot help).
- On connect: time sync writes UTC as little-endian u32 to `timeSyncWriteCharacteristicUuid` so the device can anchor recording timestamps.

**Audio pipeline** (`services/`):
- `RecordingsManager` stores raw BLE frames in `raw_chunks/<sessionId>/<chunk>.bin`
- `OfflineAudioProcessor` decodes Opus → 16 kHz mono 16-bit PCM, applies RMS silence detection (-55 dBFS threshold), splits into `recordings/<YYYY-MM-DD>/<recording_<millis>>.wav`
- Metadata packets (255-byte frames) carry UTC + device uptime for timestamp anchoring when device clock was reset

**Sync** (`services/wals/`):
- `WalService` creates `Wal` entries per file (tracks codec, device, storage location, sync status: miss → syncing → synced)
- `SDCardWalSyncImpl` reads files over BLE (256-byte chunks) or TCP (WiFi, port 8080) — allows resume on reconnect without re-downloading

### Firmware (`omi/firmware/devkit/src/`)

Zephyr RTOS on nRF52840. Key threads: mic capture → codec ring buffer → Opus encode → BLE notify / SD card write.

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
| Storage | `30295780-…` | File list + read/delete |
| Button | `23ba7924-…` | Tap events (1=single, 2=double, 3=long, 4=press, 5=release) |

Storage protocol: read characteristic returns 4-byte LE file lengths; write `[cmd, fileNum, offset_4B]` where cmd: 0=READ, 1=DELETE, 2=NUKE, 3=STOP.

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

### RELEASE command
When the user says "RELEASE", create a branch from `main`, make individual commits per changed file, push/create a PR, merge without squash, then switch back to `main` and pull.

### Version bumping
When the user says "release" or asks to ship a build, increment the build number in `app/pubspec.yaml` by 1 (the `+N` part). Only change the semver (`X.Y.Z`) if the user explicitly specifies a new version. Example: `1.1.0+3` → `1.1.0+4`.
