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

# Format (run manually — no pre-commit hook is installed)
dart format --line-length 120 <files>
clang-format -i <files>          # firmware C/C++

# Build dev-flavor APK, rename oo<version>.apk, drop in releases/ at repo root.
# Reads version from app/pubspec.yaml; deterministic only — no bump/commit/push.
# Also builds the firmware zip if the Zephyr/nRF toolchain is present; that step is
# best-effort and is skipped (non-fatal) when the toolchain is missing.
./app/build.sh
```

The per-version history lives in [CHANGELOG.md](CHANGELOG.md).

## Architecture

### Overview

Omi is an offline-first wearable audio recorder. The nRF5340 firmware captures audio via Opus codec, stores it to SD card, and exposes it over BLE. The Flutter app discovers the device, syncs recordings via WAL, decodes Opus to .m4a, and splits by silence.

**Data flow:** Mic → Opus encode (firmware) → SD card → BLE transfer (WAL-tracked, ACK-gated, resumable) → raw .bin segments on phone → Opus decode → VAD silence detection → .m4a → daily batch UI

### App (`app/lib/`)

**State management**: `DeviceProvider` (ChangeNotifier) drives all UI. `ServiceManager` is the singleton that holds `IDeviceService`.

**Connection pipeline** (`services/devices/`):
- `DeviceService.ensureConnection()` is serialized via a `Mutex` (`devices.dart`) — N concurrent callers (battery, storage, WAL sync) share one connection attempt. Critical: never bypass this.
- Connection retry and reconnect logic is owned by the native BLE layer, not Dart. When the transport exists but is disconnected, do not dispose and recreate it — that cancels native's auto-reconnect.
- `OmiDeviceConnection` has its own `_storageMutex` covering CMD_LIST_FILES / CMD_READ_FILE / CMD_DELETE_FILE so storage commands serialize against each other even when sharing the same connection.
- On connect: time sync writes UTC as little-endian u32 to `timeSyncWriteCharacteristicUuid` so the device can anchor recording timestamps.
- Foreground sends a periodic keep-alive (`0x32` to `storageDataStreamCharacteristicUuid`) to keep the firmware from idle-disconnecting. Dead connections are force-dropped after consecutive keep-alive failures.

**Audio pipeline** (`services/`):
- `SDCardWalSyncImpl` saves downloaded segments to `raw_segments/<timerStart>/<timerStart>_<sessionId>.bin`, where `<timerStart>` is the firmware-assigned UTC epoch seconds (as a decimal string). Pre-time-sync files (timerStart < 946684800) land in `raw_segments/session_<sessionId>/` instead and appear in the UI under "Unorganized". Inline-frame types in the bin stream:
  - `0xFFFFFFFB` metadata header (36 B: 4-byte tag + 4-byte length + 28-byte payload), peeked at offset 0
  - `0xFFFFFFFC` session-end marker (20 B): 4-byte header + same 16-byte payload as the button-tap marker; written by firmware on manual-mode stop
  - `0xFFFFFFFD` VAD-resume timestamp (20 B): 4-byte header + 16-byte payload `utc_s(u32) + uptime_ms(u32) + 8 zero bytes`, written when AAD wakes after silence. **Payload layout differs from the other markers**: UTC is epoch *seconds* (u32), not ms (u64), and there is no session id.
  - `0xFFFFFFFE` button-tap marker (20 B): 4-byte header + 16-byte payload of `utc_ms(u64) + uptime_ms(u32) + session_id(u32)`
  - `0xFFFFFFFA` / `0xFFFFFFF9` mute-on / mute-off markers (20 B each): 4-byte header + same 16-byte payload as the button-tap marker; bracket a muted stretch in the stream (rendered as a "muted" ghost row)
  - `0xFFFFFFFF` / `0`: sentinel slots
  These frames are left inline in the bin file — not extracted at transfer time. `VadAudioProcessor` parses them during the decode pass.
- `OfflineAudioProcessor` decodes Opus → 16 kHz mono 16-bit PCM, adaptive noise floor tracking (initial -40 dBFS, SNR margin configurable), splits into `recordings/<YYYY-MM-DD>/recording_<millis>.m4a`
- `VadAudioProcessor` emits an EDL sidecar `recordings/<YYYY-MM-DD>/marker_<markerMs>.edl` (JSON: `markerTimestampMs`, `segmentFilename`, `markerOffsetMs`, `cropStartMs`, `cropEndMs`, `userSaved`) per detected button-tap. Markers with no surrounding audio are emitted as orphan EDLs with an empty `segmentFilename`. Markers re-anchored across stitched files have their offsets shifted by the prefix's wall-clock duration.
- `RecordingsManager` / `Conversation` model parses finalized recordings from the `recordings/` directory for UI binding; `RecordingsManager.getMarkerConversations()` builds the `MarkerConversation` list from the EDL sidecars.

**VAD processing design invariants** (`services/vad_audio_processor.dart`, `services/recordings_manager.dart`):
- The firmware writes ~5-minute sequential bin files. Each file's `segmentStartTime` (the WAL `timerStart`) picks up exactly where the previous file ended — no overlaps, no gaps larger than clock drift.
- The processor treats all bin files as one continuous audio stream. A recording starts when speech is detected and ends only on: (a) `vadSplitSeconds` of continuous silence (auto-mode default 120 s; manual mode forces 0 / VAD-off), or (b) `vadMaxConversationMinutes` cap (auto/manual default 0 = no cap; legacy `vadMaxConversationMinutes` still exists for migration with default 60). Nothing else creates a boundary.
- There is no separate `vadGapSeconds` constant. The gap threshold between consecutive files is `vadSplitSeconds - _firmwareVadHoldMs` (10 s). With the default `vadSplitSeconds` of 120 s, file gaps up to 110 s are stitched. BLE disconnects do not create file gaps — firmware writes straight to SD card regardless of phone connectivity.
- Manual mode is the default since 0.14.0 (`manualMode` preference defaults to `true`). In manual mode the app writes `vadThreshold=65535` (VAD off, recording on) on start-tap and `32769` on stop-tap; the firmware emits `0xFFFFFFFC` on stop so the processor can auto-finalize without Force Process.
- **End-of-run always flushes as a `_draft` file**, in both background and foreground modes. Recordings in progress are written via `flushRemaining(isDraft: true)`; the resulting `_draft.*` files are not surfaced as finalized recordings and are re-stitched with newly downloaded bins on the next sync+process cycle, then promoted to finalized recordings once silence/cap conditions are met. Do not change `isDraft: true` to `false` in the background path — that would prematurely promote partials and delete their source bin files, anchoring the next run's recordings to a too-early timestamp.
- The `VadAudioProcessor` is stateless across runs (recreated in a fresh isolate each time). Persistence is implicit: `_draft` files plus uncut bin files stay on disk and are re-processed.

**Sync** (`services/wals/`):
- `WalService` creates `Wal` entries per file (tracks codec, device, storage location, sync status: miss → syncing → synced)
- `SDCardWalSyncImpl` reads files over BLE — allows resume on reconnect without re-downloading
- `WalFileManager.saveWals` / `loadWals` are serialized via a `Mutex` so a concurrent multi-device sync can't have one device's `saveWals` observe a mid-truncate empty file and drop another device's WALs.
- During fast-path sync, `onProgress` fires per BLE packet (~50 Hz). Persist calls are throttled to ~1 Hz; state-transition saves (deletion, transfer failure, end-of-sync) still persist immediately. The truncate-on-resume guard at the start of `_readStorageBytesToFileLocked` bounds re-fetch on crash to one persist-window of bytes.

**Storage layout** (relative to `getApplicationDocumentsDirectory()`):
- `raw_segments/{timerStart}/{timerStart}_{sessionId}.bin` — one folder per segment, named by UTC epoch-seconds `timerStart`. Pre-time-sync → `raw_segments/session_{sessionId}/`.
- `recordings/{yyyy-mm-dd}/recording_{startMs}.wav` (or `.m4a` / `.ogg`) — finalized recording; date is **local** calendar date.
- `recordings/{yyyy-mm-dd}/recording_{startMs}_draft.wav` — in-progress flush (always `.wav` — M4A can't be stitched); not surfaced in UI.
- `recordings/{yyyy-mm-dd}/unknown_{startMs}.wav` — recording with derived/uncertain timestamp (time-sync unavailable).
- `recordings/{yyyy-mm-dd}/recording_{startMs}.meta` — binary sidecar: `totalSamples` u32, `durationMs` u32, 200×u16 waveform, `sessionId` u32, `startUptime` u32, upload key, passthrough/forceSynced/capEnded flags, JSON relative-bin list.
- `recordings/{yyyy-mm-dd}/marker_{markerMs}.edl` — JSON marker sidecar: `markerTimestampMs`, `segmentFilename`, `markerOffsetMs`, `cropStartMs`, `cropEndMs`, `userSaved`. Orphan markers have empty `segmentFilename`.
- `recordings/{yyyy-mm-dd}/discards.jsonl` — one line per VAD-dropped stretch; surfaced as ghost rows in the UI.

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

**Opus config**: 16 kHz mono, VBR (32 kbps, complexity 3, CELT), 20 ms frames (codec ID `21` = opusFS320).

**C ↔ Dart name mapping** (wire format unchanged — byte offsets define the protocol):

| Firmware (C) | Source file | Dart equivalent |
|---|---|---|
| File timestamp from `CMD_LIST_FILES` | — | `timerStart` (WAL key + folder name) |
| `device_session_id` (`atomic_t` u32) | `transport.c/h`, `main.c` | `wal.sessionId` / `deviceSessionId` |
| `write_marker_to_storage()` | `transport.c/h`, `button.c` | button-tap `Marker`; header `0xFFFFFFFE` + 16 B payload: `utc_time_ms` (u64), `uptime_ms` (u32), `device_session_id` (u32) |
| `write_session_end_marker_to_storage()` | `transport.c/h`, `aad.c` | manual-mode stop boundary; header `0xFFFFFFFC` + same 16 B payload |
| `write_mute_on_marker_to_storage()` / `write_mute_off_marker_to_storage()` | `transport.c/h`, `button.c` | mute bracket; headers `0xFFFFFFFA` / `0xFFFFFFF9` + same 16 B payload |
| `write_custom_packet_to_storage(0xFFFFFFFD, …)` | `aad.c` | AAD VAD-resume timestamp; 16 B payload `utc_s` (u32) + `uptime_ms` (u32) + 8 zero bytes — **not** the header-marker layout (seconds not ms, no session id) |
| `marker_flash_count` (`volatile uint8_t`) | `button.c/h`, `main.c` | *(no Dart equivalent)* — drives LED flash on double-tap |
| `PACKET_EOT` = `0x02` | `storage.c` | end-of-transfer signal; consumed by `SDCardWalSyncImpl`, not stored |

### BLE Protocol

Omi-custom services use base UUID `19b100xx-e8f2-537e-4f6c-d104768a1214`. Source of truth is `app/lib/services/devices/omi_connection.dart`. There is no live audio-stream service in this offline fork (no `0000`/`0001`) — audio goes Mic → SD → storage-sync, never a BLE stream.

Discovery: the firmware advertises the device name `Omi` plus the Settings service `0010` (UUID128_ALL); the app matches peripherals whose name contains `omi` or that advertise `0010` (`native_bluetooth_discoverer.dart`).

| Service | UUID suffix | Purpose |
|---------|-------------|---------|
| Settings | `0010` / `0011` / `0012` / `0013` | LED dim ratio, mic gain, VAD threshold |
| Features | `0020` (service) / `0021` / `0022` | `0021` capability bitfield (see `OmiFeatures`: accelerometer, button, battery, usb, haptic, offlineStorage, ledDimming, micGain, vadThreshold); `0022` audio codec ID read. |
| Time sync | `0030` / `0031` | Write epoch seconds (u32 LE) |
| Button | `0040` / `0041` | Tap-event notify (1 byte). App currently consumes event `2` only (double-tap → manual mode toggle). Firmware emits inline `0xFFFFFFFE` markers in the audio stream regardless. |
| Battery detail | `0050` / `0051` | Notify 1 byte: `charging` (0/1) |
| Diagnostics | `0060` / `0061` / `0062` | `0061` 8 B: `reset_cause u32 LE` + `uptime_seconds u32 LE`. `0062` 20 B drop counters: `blockDrops` + `lastDropUptimeMs` + `sdStreamDrops` + `sdBootDrops` + `nowUptimeMs` (all u32 LE). |

Non-Omi-prefix services in use:

| Service | UUID | Purpose |
|---------|------|---------|
| Standard Battery | `0000180f-…` / char `00002a19-…` | Battery level (0–100 %) |
| Device Info (DIS) | `0000180a-…` | Model `2a24`, firmware rev `2a26`, hardware rev `2a27`, manufacturer `2a29`, serial `2a25` |
| Storage | `30295780-4301-eabd-2904-2849adfeae43` | Data stream char `…81`, read-control char `…82` |

Storage protocol: write commands to `storageDataStreamCharacteristicUuid` (`…81`). Responses arrive on the same characteristic; `0x03` first byte = `PACKET_ACK` (`data[1]==0` = success).

| Cmd | Name | Payload |
|-----|------|---------|
| `0x03` | STOP_STORAGE_SYNC | `[0x03]` |
| `0x10` | LIST_FILES | `[0x10]` |
| `0x11` | READ_FILE | `[0x11, fileIndex, offset_4B LE, timestamp_4B LE?]` (timestamp optional, used for index-shift recovery) |
| `0x12` | DELETE_FILE | `[0x12, fileIndex, timestamp_4B LE?]` (timestamp optional) |
| `0x13` | ROTATE_FILE | `[0x13]` |
| `0x14` | CLEAR_STORAGE | `[0x14]` |
| `0x32` | KEEP_ALIVE | `[0x32]` (added 0.14.4; prevents firmware idle-disconnect) |

File indices are **cache positions** (0-based sequential) that shift after each deletion — the firmware rebuilds its file-list cache on every CMD_LIST_FILES and after every delete, so after deleting index 0, what was index 1 becomes index 0. Supplying the timestamp in CMD_READ_FILE and CMD_DELETE_FILE lets the firmware re-locate the file by timestamp if the index shifted between LIST and READ/DELETE.

Audio codec ID (read from `0022`, under the Features service `0020`): the app explicitly recognises `20` = opus (80 B/frame, 50 fps) and `21` = opusFS320 (40 B/frame, 50 fps). Anything else falls back to `pcm8`. Current firmware reports `21` (`CODEC_ID` in `config.h`). The `BleAudioCodec` enum also defines `pcm16`, `mulaw8`, `mulaw16`, `unknown` but no current code path reads those over the wire.

## Formatting

There is no pre-commit hook installed in this repo — run formatters manually before committing:

```bash
dart format --line-length 120 <files>   # Dart (skip *.gen.dart and *.g.dart)
clang-format -i <files>                  # C/C++ firmware
```

## Git

- Always commit to the current branch — never switch branches.
- Never squash merge PRs — use regular merge.
- Make individual commits per file, not bulk commits.
- If push fails because the remote is ahead: `git pull --rebase && git push`.
- Never push or create PRs unless explicitly asked — commit locally by default.

### RELEASE / release command
When the user says "release" or "RELEASE", increment the patch digit in `app/pubspec.yaml` by 1, commit, and push. The patch digit serves as the build number — there is no separate `+N` suffix. Example: `0.3.18` → `0.3.19`. After the bump, `app/build.sh` can produce the matching `oo<digits>.apk` at repo root (deterministic, no extra git ops).

Document user-visible behavioural changes in `CHANGELOG.md` (newest entry on top). `README.md` only links to it.
