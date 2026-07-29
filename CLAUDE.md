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

**State management**: two `ChangeNotifier`s drive the UI. `DeviceProvider` owns device discovery/connection/battery/mute state. `RecordingsController` (`pages/recordings/recordings_controller.dart`) owns the recordings page: it runs the sync→process pipeline state machine (`SyncProcessState`: idle/syncing/processing/stopping/resume/error/successUi, with a stall watchdog that force-recovers wedged BLE transfers), builds the daily `Batch` / `MarkerConversation` UI models from `RecordingsManager`, handles deletion + discard recovery, and delegates external-integration uploads to `IntegrationUploadManager` (`integration_upload_manager.dart`, with `passthrough_integration.dart`). `ServiceManager` is the singleton that holds `IDeviceService`.

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
  - `0xFFFFFFF8` priority-recording start marker (20 B): 4-byte header + same 16-byte payload as the button-tap marker; written by firmware on an auto-mode RECORD_START (after rotating the bin). The app finalizes the current auto recording at this boundary and opens a high-priority ("Priority Recording") recording rendered red, force-captured (no silence split) until the matching `0xFFFFFFFC` stop. **This is the only marker that finalizes mid-stream and keeps consuming into a new recording**, which is why the firmware rotates the bin around it (recording boundary = bin boundary; avoids whole-bin re-VAD duplication).
  - `0xFFFFFFFF` / `0`: sentinel slots
  These frames are left inline in the bin file — not extracted at transfer time. `VadAudioProcessor` parses them during the decode pass.
- `VadAudioProcessor` decodes Opus → 16 kHz mono 16-bit PCM (`opus_dart`) and runs Silero v5+ VAD (`flutter_onnxruntime`, model `assets/models/silero_vad.onnx`; 512-sample windows, 64-sample context, persistent LSTM state reset on gap) to detect speech, splitting into `recordings/<YYYY-MM-DD>/recording_<millis>.m4a`. It also writes the `.meta` sidecar.
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
- `recordings/{yyyy-mm-dd}/recording_{startMs}.meta` — binary sidecar: `totalSamples` u32, `durationMs` u32, 200×u16 waveform, `sessionId` u32, `startUptime` u32, upload key, passthrough/forceSynced/capEnded/isSilero flags, JSON relative-bin list.
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
| `write_session_end_marker_to_storage()` | `transport.c/h`, `aad.c` | manual-mode stop / Priority-Recording stop boundary; header `0xFFFFFFFC` + same 16 B payload |
| `write_priority_recording_marker_to_storage()` | `transport.c/h`, `button.c` | auto-mode RECORD_START boundary; header `0xFFFFFFF8` + same 16 B payload; app opens a high-priority recording (`isHighPriority`), VAD-off until `0xFFFFFFFC` |
| `write_mute_on_marker_to_storage()` / `write_mute_off_marker_to_storage()` | `transport.c/h`, `button.c` | mute bracket; headers `0xFFFFFFFA` / `0xFFFFFFF9` + same 16 B payload |
| `write_custom_packet_to_storage(0xFFFFFFFD, …)` | `aad.c` | AAD VAD-resume timestamp; 16 B payload `utc_s` (u32) + `uptime_ms` (u32) + 8 zero bytes — **not** the header-marker layout (seconds not ms, no session id) |
| `marker_flash_count` (`volatile uint8_t`) | `button.c/h`, `main.c` | *(no Dart equivalent)* — drives LED flash on double-tap |
| `PACKET_EOT` = `0x02` | `storage.c` | end-of-transfer signal; consumed by `SDCardWalSyncImpl`, not stored |

Paths in the *Source file* column are relative to `omi/firmware/omi/src/`; `transport.*`, `button.*`, and `storage.*` live under `lib/core/`, while `aad.c` and `main.c` are at the `src/` root.

### BLE Protocol

Omi-custom services use base UUID `19b100xx-e8f2-537e-4f6c-d104768a1214`. Source of truth is `app/lib/services/devices/omi_connection.dart`. There is no live audio-stream service in this offline fork (no `0000`/`0001`) — audio goes Mic → SD → storage-sync, never a BLE stream.

Discovery: the firmware advertises the device name `Omi` plus the Settings service `0010` (UUID128_ALL); the app matches peripherals whose name contains `omi` or that advertise `0010` (`native_bluetooth_discoverer.dart`).

| Service | UUID suffix | Purpose |
|---------|-------------|---------|
| Settings | `0010` / `0011`–`0016` | `0011` LED dim ratio, `0012` mic gain, `0013` VAD threshold, `0014` Priority Recording safety cap (u16 LE minutes, `0`=no cap), `0015` button config (6 B), `0016` haptic config (6 B). Button + haptic config were consolidated here from the retired `23ba7926` service (app 0.26.x); byte layouts unchanged, requires a re-pair. **Do not add characteristics here** — Settings is registered first (`transport_start`), so each one shifts the handles of every later service (storage/diagnostics/mute) and costs a re-pair; put new settings in a service registered last, as `0080` does. |
| Button + haptic config | under Settings `0010`: char `0015` (button) / `0016` (haptic) | 6 B read/write button-action config (one byte per slot: single/single-hold/double/double-hold/triple/triple-hold); actions `0=None, 1=Mute, 2=Marker, 3=Toggle LED, 4=Record Start, 5=Record Stop, 6=Record Toggle` (`button_action_t`; firmware rejects values `> BUTTON_ACTION_RECORD_TOGGLE`). `RECORD_TOGGLE` stops if a recording is active (runtime threshold `65535` — held by both manual recording and auto priority-recording) else starts one, dispatching into the same `record_start()`/`record_stop()` paths as `4`/`5` (`button.c`). The firmware holds **one** active config; the **app owns two per-mode configs** (`buttonConfigManual` / `buttonConfigAuto` in prefs) and pushes the active mode's config on connect + on mode switch (`DeviceProvider.pushActiveButtonConfig`, with a one-time migration seeding `buttonConfigAuto` from the device's existing config). `MARKER` is a plain bookmark in all modes (the old manual-mode start/stop overload was removed in favor of explicit Record Start/Stop). Surfaced in Settings → `ButtonConfigPage` (Manual/Auto segmented editor). A global **"Single recording button"** switch (`combineRecordButton` pref, default off) swaps the split `4`/`5` picker options for a single `6` (Toggle); flipping it normalizes both mode configs via `SharedPreferencesUtil.normalizeButtonConfigForCombine` (ON: `4→6`, `5→0`; OFF: `6→0`) so the picker/firmware never hold an out-of-mode action. `0016`: 6 B per-slot vibration pattern (0=off, 1=single, 2=double, 3=triple), persisted as `omi/haptic_config`. |
| Features | `0020` (service) / `0021` / `0022` | `0021` capability bitfield (see `OmiFeatures`: accelerometer, button, battery, usb, haptic, offlineStorage, ledDimming, micGain, vadThreshold, priorityRecordCap, `recordToggle` (`1<<11`, AAD-gated) — the app hides the "Single recording button" switch / Toggle action on firmware without it; `diagLog` (`1<<12`, set only under `CONFIG_OMI_DIAG_LOG`) — gates the Debug Tools event-log toggle; `connectedLed` (`1<<13`) — the LED service `0080` exists; gates the Customization "Connected LED" switch); `0022` audio codec ID read. |
| Time sync | `0030` / `0031` | Write epoch seconds (u32 LE) |
| Battery detail | `0050` / `0051` | Notify 1 byte: `charging` (0/1) |
| Diagnostics | `0060` / `0061` / `0062` | `0061` 8 B: `reset_cause u32 LE` + `uptime_seconds u32 LE`. `0062` 76 B drop counters (nineteen u32 LE): `blockDrops` + `lastDropUptimeMs` + `sdStreamDrops` + `sdBootDrops` + `nowUptimeMs` + `connFails` + `lastFailedAdvSlow` + `codecDrops` + `msgqPeakDepth` + `writeFairActivations` + `estabFailCount` + `priorityRecordStarts` + `priorityRecordStops` + `markerWriteDrops` + `emptyBinRotations` + `sessionEndMarkerEmits`(off 60) + `markerPauseGateSaves`(off 64) + `sdWorkerStackUsed`(off 68) + `codecStackUsed`(off 72). Append-only; older apps read a prefix (length grew 20→28→32→40→44→60→68→76 B). Full layout in NOTES.md "SD Write Drop Counters". `0063`/`0064` (dev builds only, `CONFIG_OMI_DIAG_LOG`) = the on-device diagnostic **event log**: `0063` drain read returns a 12 B snapshot header `[record_size u8][reserved u8][record_count u16][dropped_count u32][max_seq u32]` + N×16 B packed `diag_event_t` records `[seq u32][uptime_ms u32][code u8][backend u8][arg0 u16][arg1 u32]`; `0064` control write `[enable u8][ack_seq u32 LE]` (5 B, fail-closed on short write) sets the runtime gate and drops records with `seq ≤ ack_seq`. The ring is volatile RAM (reclaimed from `SD_WORKER_STACK_SIZE`), keep-newest on overflow, drained+acked on connect when the app pref `diagLogEnabled` is on. Records timestamp/contextualize the same health events the `0062` counters only total (empty-bin rotation, marker drop, pause-gate save, priority start/stop, session-end, block/codec drop). Firmware `diag_log.c`/`diag_log.h`; app `diag_log_record.dart`. |
| Mute | `0070` / `0071` | 9 B read/write/notify mute state: `[muted u8][since_utc_s u32 LE][since_uptime_ms u32 LE]`. Write `[0]`/`[1]` to unmute/mute (no-op on the device while in manual mode). Wired through `getMuteState` / `setMute` / `getMuteListener`. |
| LED | `0080` / `0081` | 1 B read/write: `0` = the connected (solid blue) indicator is off, non-zero = on; default on. With it off, `is_connected` drops out of the firmware LED state machine entirely, so recording/mute/low-battery/charging show through instead (`main.c set_led_state`). Wired through `getConnectedLed` / `setConnectedLed`; gated on the `connectedLed` capability bit. Its own service, registered last, so no existing handle moves and no re-pair is needed. |

Non-Omi-prefix services in use:

| Service | UUID | Purpose |
|---------|------|---------|
| Standard Battery | `0000180f-…` / char `00002a19-…` | Battery level (0–100 %) |
| Device Info (DIS) | `0000180a-…` | Model `2a24`, firmware rev `2a26`, hardware rev `2a27`, manufacturer `2a29`, serial `2a25` |
| Storage | `30295780-4301-eabd-2904-2849adfeae43` | Data stream char `…81`, read-control char `…82` |
| Button | `23ba7924-0000-1000-7450-346eac492e92` / trigger char `…7925` | Tap-event notify (1 byte). `transport_notify_button_state` exists but is currently uncalled in firmware, so no tap events are pushed; the app's button listener (`device_provider.dart`) is effectively inert. Button behavior is driven entirely by the firmware FSM + inline audio-stream markers (`0xFFFFFFFE` marker, `0xFFFFFFF8` priority-start, etc.). The button *trigger* service stays here; button **config** moved to the Settings service (`0015`/`0016`) — see the Omi services table above. |

Storage protocol: write commands to `storageDataStreamCharacteristicUuid` (`…81`). Responses arrive on the same characteristic; `0x03` first byte = `PACKET_ACK` (`data[1]==0` = success).

| Cmd | Name | Payload |
|-----|------|---------|
| `0x03` | STOP_STORAGE_SYNC | `[0x03]` |
| `0x10` | LIST_FILES | `[0x10]` |
| `0x11` | READ_FILE | `[0x11, fileIndex, offset_4B LE, timestamp_4B LE?]` (timestamp optional, used for index-shift recovery) |
| `0x12` | DELETE_FILE | `[0x12, fileIndex, timestamp_4B LE?]` (timestamp optional) |
| `0x13` | ROTATE_FILE | `[0x13]` |
| `0x14` | CLEAR_STORAGE | `[0x14]` |
| `0x15` | UNPAIR | `[0x15]` (firmware `bt_unpair` — wipes the device's own BLE bonds; `sendUnpairCommand`) |
| `0x16` | REBOOT | `[0x16]` (deferred to the storage thread: ACKs, gracefully closes the SD card (`app_sd_off()` when `is_sd_on()` — flush + unmount), then `sys_reboot(SYS_REBOOT_COLD)`; `sendRebootCommand`. Surfaced as "Reboot Omi" in Device Settings) |
| `0x17` | POWER_OFF | `[0x17]` (deferred to the storage thread: ACKs, then `turnoff_all()` → `sys_poweroff()` — ship mode, wakes only on button/charger; `sendShutdownCommand`. Surfaced as "Shutdown Omi" in Device Settings) |
| `0x18` | ARM_POST_DFU_UNPAIR | `[0x18, arm]` (`arm`=1 arm / 0 disarm; a short/malformed write is rejected — fail-closed on a destructive action). Arming records the **current firmware version** in NVS (`omi/unpair_armed_fw`); on boot `transport_start` (after BT bonds load) consumes the marker and runs `bt_unpair` **only when the running version differs** from the armed one — so a failed/aborted flash (same version) never wipes, and a stale arm can't fire on an ordinary reboot / the Reboot command. Fail-closed: if arming didn't persist, no version is stored and nothing wipes. Armed pre-flash by the app's "Reset pairing after update" toggle (`sendArmPostDfuUnpair`); the app gates its phone-side `removeBond` (on success) on the arm write landing. |
| `0x32` | KEEP_ALIVE | `[0x32]` (added 0.14.4; prevents firmware idle-disconnect) |

File indices are **cache positions** (0-based sequential) that shift after each deletion — the firmware rebuilds its file-list cache on every CMD_LIST_FILES and after every delete, so after deleting index 0, what was index 1 becomes index 0. Supplying the timestamp in CMD_READ_FILE and CMD_DELETE_FILE lets the firmware re-locate the file by timestamp if the index shifted between LIST and READ/DELETE.

Audio codec ID (read from `0022`, under the Features service `0020`): the app explicitly recognises `20` = opus (80 B/frame, 50 fps) and `21` = opusFS320 (40 B/frame, 50 fps). Anything else falls back to `pcm8`. Current firmware reports `21` (`CODEC_ID` in `lib/core/config.h`). The `BleAudioCodec` enum also defines `pcm16`, `mulaw8`, `mulaw16`, `unknown` but no current code path reads those over the wire.

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
