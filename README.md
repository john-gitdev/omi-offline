# Omi Offline: Architecture & Naming Standard

## What is Omi Offline?

Omi Offline is an **offline-first audio capture and processing system** for a wearable device.

Instead of streaming audio in real time, the system:

* Records continuously on-device
* Stores audio locally in structured segments
* Syncs data to the phone in batches over BLE
* Processes audio **offline on the phone** using VAD (RMS-based silence detection)

**Key properties:**

* No continuous BLE streaming (live streaming has been completely removed)
* No real-time cloud dependency
* Improved battery life (phone + wearable)
* Speech segmentation via post-processing

---

## The Evolution: From Streaming to Offline-First

Originally, the Omi wearable operated as a **live streaming system**. This has been **deprecated and removed** in favor of the offline-first architecture to solve critical issues:

### Problems with streaming

**Phone battery drain**

* Constant BLE activity and continuous wakeups
* High cellular data usage for real-time uploads

**Wearable constraints**

* High BLE bandwidth usage and rapid battery drain
* No tolerance for connection instability

### Solution: Offline-first architecture

The system was redesigned to:

* Record everything locally on-device (eMMC/SD)
* Defer all processing to the phone
* Batch transfer data over BLE using a robust native transport layer
* Run VAD and segmentation offline

### Result

* Significantly reduced battery usage for both devices
* Highly reliable data transfer even with intermittent connections

---

## System Overview

```
Wearable (MCU)
  - Records audio
  - Encodes Opus frames
  - Writes to eMMC/SD as .bin segments
  - Inserts metadata + markers

        ↓ Native BLE (WAL-based sync via Pigeon)

Mobile App (Flutter)
  - Syncs segments incrementally
  - Stores raw .bin files

        ↓

Offline Processing
  - VAD (noise-aware, adaptive)
  - Marker-based extraction (marker mode)

        ↓

Final Recordings
  - .m4a / .wav files

        ↓

Optional Upload
  - HeyPocket API
```

---

## Sync Pipeline (BLE + WAL)

### Data Storage (Firmware)

* Audio is encoded into **Opus frames (~20ms)**
* Frames are written into fixed-size `.bin` **Segments**
* Each segment consists entirely of pure Opus frames, each prefixed by a 4-byte Little-Endian length.

### Transfer Model

* The app syncs using a **Write-Ahead Log (WAL)** offset
* Sync is **append-only and resumable**

#### Native BLE Transport (Pigeon Bridge)

The sync layer uses a **Native GATT implementation** for iOS and Android via a Pigeon bridge. This replaces Dart-based BLE libraries for significantly higher throughput and connection stability.

#### Framed BLE Protocol

The protocol prevents audio repetition and corruption:

* **PACKET_DATA**: carries file offset in header — app checks for gaps and duplicates
* **PACKET_EOT**: signals end of file data
* **PACKET_ACK**: app acknowledges each packet; firmware only advances its offset on success and backs off on BLE errors

This ensures idempotent delivery: re-connections mid-sync resume cleanly without re-downloading or duplicating data.

> **Note:** WiFi/TCP sync (port 8080) is currently disabled. All sync runs over BLE only.

---

## Processing Pipeline

### Chronological Merging

* Segments are ordered by:

  * `(deviceSessionId, segmentIndex)`
* Processing is **continuous across boundaries**
* Recordings are **never split by day or batch**

### Cleanup

* After processing:

  * `.bin` segments are deleted
  * Final recordings are stored as `.m4a` / `.wav`
* Exception:

  * Segments are retained if **Adjustment Mode** is enabled

---

## Recording Modes

### Automatic Mode

A continuous forward-scanning VAD system.

* Evaluates every frame
* Splits when silence exceeds threshold
* Drops recordings below minimum speech duration
* Carries trailing silence as pre-buffer for next segment

---

### Marker Mode (Marker System)

User-triggered recording via double-tap.

#### Firmware behavior

* Writes a **254 (0xFE) marker packet** (16-byte payload) into the recording stream on the SD card
* Triggers LED feedback (`marker_flash_count`)

#### App behavior

* Intercepts `0xFE` marker packets during the BLE sync process
* Saves marker timestamps to a plain-text `markers.txt` file
* Performs **bidirectional extraction** around markers:

  * Up to 2 hours backward and forward
* Runs VAD **only within this window**

---

### Fixed Interval Mode

Cuts recordings at fixed wall-clock boundaries regardless of speech content.

* Boundaries fall **1 second before each interval multiple** (e.g. :29:59 / :59:59 for 30-min, :59:59 for 1hr)
* The −1 second offset ensures the last cut of any day always lands at 23:59:59 and never spills into the next day
* Boundary state is **persisted across restarts** (`fixedModeNextBoundaryMs` in SharedPreferences) so the processor resumes mid-interval cleanly after an app restart

#### Staleness guard

On startup, the persisted boundary is validated before use:

* If it is more than **2× the interval in the past** (device was offline for over 2 intervals) → discard
* If it is more than **1× the interval in the future** (corrupt data) → discard
* On discard, `fixedModeNextBoundaryMs` is reset to 0; the boundary is computed fresh from the first segment's timestamp when `processSegmentFile` runs

---

## VAD System

### High-Level Behavior

The system uses:

* Adaptive noise floor tracking
* Signal-to-noise ratio (SNR) gating
* Frame-level analysis

All VAD runs **on-device (phone), not firmware**.

---

### Implementation Details (OfflineAudioProcessor)

**Streaming decode**

* Iterates frame-by-frame (no full file load)

**dBFS calculation**

* RMS → dBFS per frame

**Adaptive noise floor**

* Two exponential moving averages:

```
alphaRise = 0.995  (~10s adaptation to louder environments)
alphaFall = 0.98   (~2s adaptation to quieter environments)
```

**Speech condition**

```
frame_dbfs > noiseFloor + snrMarginDb
```

**Opus decoder lifetime**

* One decoder is created per extraction range (not per segment)
* Decoder state carries across segment boundaries, ensuring the first frames of each segment decode cleanly

**Memory model (critical)**

* Uses `FrameRef` (byte offsets + lengths)
* Avoids loading PCM into RAM
* Reads data only when finalizing recordings

---

## VAD Tuning System (Sliders)

Backed by `SharedPreferencesUtil`.

| Setting           | Internal Variable           | Description                                    |
| ----------------- | --------------------------- | ---------------------------------------------- |
| SNR Margin        | `_snrMarginDb`              | Required dB above noise floor to detect speech |
| Hangover Time     | `_hangoverFrameCount`       | Keeps speech active briefly after drop         |
| Split Duration    | `_silenceDurationToSplitMs` | Silence needed to finalize recording           |
| Min Speech        | `_minSpeechMs`              | Minimum speech length to keep recording        |
| Pre-Speech Buffer | `_preSpeechBufferMs`        | Preserves audio before speech start            |
| Gap Threshold     | `_gapThresholdMs`           | Forces split on large timestamp gaps           |

---

## HeyPocket Integration

API:
[https://public.heypocketai.com/api/v1](https://public.heypocketai.com/api/v1)

---

## Core Invariants & Nomenclature

All contributors must follow **NOMENCLATURE.md** strictly:

| Term          | Definition                                        |
| ------------- | ------------------------------------------------- |
| Frame         | Single Opus unit (~20ms)                          |
| Segment       | `.bin` file containing frames (**never "chunk"**) |
| DeviceSession | Hardware recording session identified by its UTC start timestamp (`deviceSessionId`) |
| Marker        | 0xFE user event (**never "star"**)                |
| WAL           | Byte-offset sync state                            |
| Recording     | Final `.m4a` / `.wav` output                      |

---

## Performance Constraints

### BLE Bottlenecks

* Limited throughput
* Requires:

  * Efficient MTU usage
  * Explicit EOT (0x02)

### Memory Constraints

* Loading full PCM is not allowed
* `FrameRef` architecture is mandatory

---

## Reliability & Stability

Key correctness fixes applied:

| Area | Fix |
| ---- | --- |
| BLE connection | **Native Migration (Pigeon):** Migrated to native iOS/Android GATT for high-stability connections |
| Connection States | Added `connecting` state to `DeviceConnectionState` to handle transient states correctly |
| Battery/Charging | **Immediate Read:** Force immediate battery level and charging state read on connect |
| Battery/Charging | **Detail Characteristic:** Prefer 4-byte battery detail characteristic (19b10051) for richer data |
| BLE sync | **Protocol Gap Detection:** Inline retry and rewinding for offset mismatches during sync |
| BLE sync | Framed protocol with ACK gating eliminates duplicate/gap audio |
| Firmware storage | **Serialization:** Serialized storage operations to prevent race conditions during list/read/delete |
| Firmware storage | **Retry Logic:** `performListFiles` retries up to 3x on 0xFF firmware error; timeout increased to 35s |
| Firmware storage | **Immediate WAL:** Set WAL device immediately on connect without blocking on `listFiles` |
| Firmware uptime | `last_timestamp_uptime` reset on wipe; uptime rollover handled correctly |
| Opus decode | One decoder per extraction range — state preserved across segment boundaries |
| Subscription lifecycle | Subscriptions stored and cancelled in all providers, services, and transport layers |
| `ServiceManager` | `deinit()` is `async`; callers must await it to avoid torn-down services |
| Fixed interval | Staleness guard discards persisted boundary if > 2× interval old or in future |
| Firmware boot | **oo-1.4.10:** Breathing LED boot pattern and improved SD/Mic initialization sequence |
| Upstream Tracking | `UPSTREAM.md` tracks reviewed but unmerged PRs from the main Omi repository |

---

## Repository Structure

```
/firmware   → Embedded recording + BLE transport
/app        → Flutter app (sync, VAD, processing, UI)
UPSTREAM.md → Tracking of unmerged upstream changes
```

### Key Components

* `OfflineAudioProcessor` → VAD + segmentation engine
* `MarkerRecordingExtractor` → Marker-based extraction; uses per-range Opus decoder for clean cross-segment decoding
* `SDCardWalSyncImpl` → Framed BLE sync with ACK gating and gap detection
* `NativeBluetoothDiscoverer` → Native BLE device discovery via Pigeon
* `FixedIntervalAudioProcessor` → Fixed wall-clock boundary cutting with cross-restart boundary persistence
