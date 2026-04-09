# Omi Offline

## What is Omi Offline?

Omi Offline is an **offline-first audio capture and processing system** for a wearable device. This is a personal fork of the Omi project focused entirely on local, private recording — no cloud dependencies.

Instead of streaming audio in real time, the system:

* Records continuously on-device
* Stores audio locally in structured segments
* Syncs data to the phone in batches over BLE
* Processes audio **entirely on the phone** using Silero neural VAD

**Key properties:**

* No continuous BLE streaming
* No cloud dependency of any kind (internet connectivity checks and all cloud APIs removed)
* HeyPocket is the only external integration
* Speech segmentation via post-processing with tunable VAD parameters
* Adjustment Mode for iterating on VAD settings without re-syncing

---

## System Overview

```
Wearable (nRF5340)
  - Records audio via PDM microphones
  - Encodes Opus frames (16 kHz mono, 20 ms)
  - Writes to SD card as .bin segments
  - Inserts marker packets on button press

        ↓ Native BLE (WAL-based sync via Pigeon)

Mobile App (Flutter)
  - Syncs segments incrementally, resumably
  - Stores raw .bin files on phone

        ↓

Offline Processing (VadAudioProcessor)
  - Silero neural VAD (ONNX, on-device)
  - Splits audio at silence boundaries
  - Extracts marker-tagged moments

        ↓

Final Recordings
  - .m4a files in recordings/<YYYY-MM-DD>/

        ↓

Optional Upload
  - HeyPocket API
```

---

## Sync Pipeline (BLE + WAL)

### Data Storage (Firmware)

* Audio is encoded into **Opus frames (~20ms)**
* Frames are written into fixed-size `.bin` **Segments**
* Each segment is pure Opus frames, each prefixed by a 4-byte little-endian length
* Marker packets (`0xFE` header) are embedded in the stream on button press

### Transfer Model

* The app syncs using a **Write-Ahead Log (WAL)** offset — append-only and resumable
* Marker packets are extracted to `markers.txt` during transfer

#### Native BLE Transport (Pigeon Bridge)

The sync layer uses a **native GATT implementation** for iOS and Android via a Pigeon bridge for higher throughput and connection stability than Dart-based BLE libraries.

#### Framed BLE Protocol

* **`0x01` (data)**: carries 4-byte file offset — app checks for gaps; duplicate/overlapping packets are trimmed
* **`0x02` (EOT)**: firmware signals end of file; app flushes and completes transfer
* **`0x03` (ACK)**: firmware confirms receipt of read command; app waits before processing

Re-connections mid-sync resume cleanly without re-downloading or duplicating data.

---

## Processing Pipeline

### VAD Engine (VadAudioProcessor)

Powered by **Silero VAD** — a lightweight neural network running on-device via ONNX Runtime. Falls back to amplitude-based detection if the model fails to load.

* Processes audio frame-by-frame (no full file load into RAM)
* Uses `FrameRef` disk-pointers — PCM is never held in memory
* One Opus decoder per processing pass — state preserved across segment boundaries
* Settings are cached at construction time for the lifetime of one `processAll` pass

### Chronological Merging

* Segments are sorted by `(deviceSessionId, segmentIndex)` across all batches
* Processing is continuous across day boundaries — a conversation spanning midnight is never artificially cut
* Output files land in `recordings/<date>/` based on the recording's actual start timestamp

### Cleanup

After processing, `.bin` segments are deleted.

**Exception — Adjustment Mode:** when enabled, `.bin` files are preserved so days can be reprocessed with different VAD settings via the **Reprocess Day** button. When Adjustment Mode is turned off, a banner prompts the user to process any remaining unprocessed days and delete all raw files.

---

## Recording Mode

### Automatic (VAD-based)

The only recording mode. A continuous forward-scanning VAD system:

* Classifies every 20ms frame as speech or silence using Silero
* Splits into a new conversation when silence exceeds the configured threshold
* Drops recordings below the minimum speech duration
* Merges nearby speech segments within the gap threshold

#### Marker System

User-triggered moment tagging via button press (double-tap).

* **Firmware**: writes a `0xFE` marker packet into the SD card stream; triggers LED flash
* **App**: extracts marker timestamps to `markers.txt` during BLE sync, then creates `.edl` sidecar files linking each marker to its enclosing `.m4a` recording

---

## VAD Tuning

All parameters are user-configurable in **Recording Settings** and backed by `SharedPreferencesUtil`.

| Setting | Key | Default | Description |
|---|---|---|---|
| Speech Sensitivity | `vadSpeechThreshold` | 0.5 | Silero probability cutoff (0–1). Lower = more sensitive |
| Silence to End Conversation | `vadSplitSeconds` | 120s | Silence duration that triggers a conversation cut |
| Minimum Conversation Length | `vadMinSpeechSeconds` | 5s | Segments shorter than this are discarded |
| Speech Holdover | `vadHangoverSeconds` | 0.5s | How long to keep recording after speech drops out |
| Pre-Speech Buffer | `vadPreSpeechSeconds` | 1.0s | Audio captured before speech onset |
| Segment Gap Threshold | `vadGapSeconds` | 30s | Nearby segments closer than this are merged |
| Max Conversation Length | `vadMaxConversationMinutes` | 60 min | Hard cap; forces a cut even without silence |

---

## Adjustment Mode

Enables iterative VAD tuning without re-syncing from the device.

* **On**: raw `.bin` files are kept after processing; each day shows a **Reprocess Day** button instead of Delete Day
* **Off**: normal cleanup; if bins are still on disk a banner appears prompting **Process & Delete**
* Auto-processing skips days that already have processed recordings — only unprocessed days are touched automatically

---

## HeyPocket Integration

The only external integration. Uploads finalized `.m4a` recordings to:
`https://public.heypocketai.com/api/v1`

Configured via an API key in Settings → Integrations.

---

## Core Nomenclature

| Term | Definition |
|---|---|
| Frame | Single Opus unit (~20ms) |
| Segment | `.bin` file containing frames (**never "chunk"**) |
| DeviceSession | Hardware recording session identified by its UTC start timestamp |
| Marker | `0xFE` user event (**never "star"**) |
| WAL | Byte-offset sync state |
| Recording | Final `.m4a` output |
| Conversation | A VAD-delimited recording or a marker-tagged clip |

---

## Reliability

| Area | Detail |
|---|---|
| BLE connection | Native iOS/Android GATT via Pigeon — higher stability than Dart BLE |
| Sync protocol | Framed protocol with ACK gating and offset gap detection; idempotent on reconnect |
| Battery/Charging | Immediate read on connect; 4-byte detail characteristic (millivolts, %, charging flag) |
| Firmware storage | Serialized operations; `performListFiles` 120s timeout with CCCD re-send at 10s; `deleteFile` 35s timeout |
| Firmware storage | Ring buffer uses `ring_buf_put_claim`/`ring_buf_put_finish` — atomic writes, no partial corruption |
| Opus decode | One decoder per processing pass — state preserved across segment boundaries |
| `ServiceManager` | `deinit()` is async; callers must await it |

---

## Repository Structure

```
/omi/firmware   → nRF5340 Zephyr firmware (Opus encode, SD card, BLE transport)
/app            → Flutter app (BLE sync, Silero VAD, processing, UI)
```

### Key Components

| Component | Purpose |
|---|---|
| `VadAudioProcessor` | Silero VAD + Opus decode + `.m4a` output |
| `SDCardWalSyncImpl` | Framed BLE sync with ACK gating and gap detection |
| `RecordingsManager` | Batch orchestration, `processAll`, `reprocessDay`, `deleteAllRawSegments` |
| `NativeBluetoothDiscoverer` | Native BLE device discovery via Pigeon |
| `DeviceProvider` | Central UI state — BLE connection, battery, sync status |
