# Omi Offline: Architecture & Naming Standard

## What is Omi Offline?

Omi Offline is an **offline-first audio capture and processing system** for a wearable device.

Instead of streaming audio in real time, the system:

* Records continuously on-device
* Stores audio locally in structured segments
* Syncs data to the phone in batches over BLE
* Processes audio **offline on the phone** using VAD and contextual analysis

**Key properties:**

* No continuous BLE streaming
* No real-time cloud dependency
* Significantly improved battery life (phone + wearable)
* High-quality speech segmentation via post-processing

---

## The Evolution: From Streaming to Offline-First

Originally, the Omi wearable operated as a **live streaming system**:

* Audio was continuously sent over BLE
* The phone immediately uploaded it to the cloud
* No VAD existed on-device or on-phone

### Problems with streaming

**Phone battery drain**

* Constant BLE activity
* Continuous wakeups
* Cellular uploads

**Wearable constraints**

* High BLE bandwidth usage
* Rapid battery drain
* No tolerance for connection instability

### Solution: Offline-first architecture

The system was redesigned to:

* Record everything locally on-device
* Defer all processing to the phone
* Batch transfer data over BLE
* Run VAD and segmentation offline

### Result

* Dramatically reduced battery usage
* More reliable data transfer

---

## System Overview

```
Wearable (MCU)
  - Records audio
  - Encodes Opus frames
  - Writes to eMMC as .bin segments
  - Inserts metadata + markers

        ↓ BLE (WAL-based sync)

Mobile App (Flutter)
  - Syncs segments incrementally
  - Stores raw .bin files

        ↓

Offline Processing
  - VAD (noise-aware, adaptive)
  - Marker-based extraction (manual mode)

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
* Each segment begins with a **0xFF metadata packet** containing:

  * `deviceSessionId` (random u32 per boot)
  * `segmentIndex`
  * UTC timestamp
  * Device uptime

### Transfer Model

* The app syncs using a **Write-Ahead Log (WAL)** offset
* Firmware streams raw bytes over BLE:

  * Packet size = negotiated MTU - 3 bytes
* Sync is **append-only and resumable**

### End of Transfer

* Firmware sends a **0xFD (EOT marker)** when no more data is available
* This is required for correct termination of sync loops

---

## Processing Pipeline

### Chronological Merging

* Segments are ordered by:

  * `(deviceSessionId, segmentIndex)`
* Processing is **continuous across boundaries**
* Recordings are **never split by day or batch**

### Timestamp Correction

* The device may not have accurate RTC at boot
* The app writes anchor mappings:

```
anchor_utc_device_session_{id}
```

* This maps device uptime → real-world timestamps

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

### Manual Mode (Marker System)

User-triggered recording via double-tap.

#### Firmware behavior

* Writes a **0xFE marker packet**
* Triggers LED feedback (`marker_flash_count`)

#### App behavior

* Scans for marker timestamps
* Performs **bidirectional extraction**:

  * Up to 2 hours backward and forward
* Runs VAD **only within this window**

**Benefit:**

* Precise conversation capture
* Reduced compute and battery usage

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

### Tradeoffs

* Lower SNR → more false positives
* Higher SNR → missed quiet speech
* Longer hangover → smoother speech, less fragmentation
* Short split duration → more aggressive segmentation

---

## HeyPocket Integration

API:
[https://public.heypocketai.com/api/v1](https://public.heypocketai.com/api/v1)

### Upload Model

* Multipart POST with `.m4a` file + API key

### Trigger Modes

* Manual (user initiated)
* Automatic:

  * Requires `autoSyncEnabled` + `heypocketEnabled`
  * Background polling via `_pollHeyPocket()`

### Idempotency

* Stored in:

```
heypocketUploadedFiles (SharedPreferences)
```

* Prevents duplicate uploads across restarts

### Error Handling

* Wrapped in `HeyPocketException`
* Supports retry on:

  * Network failures
  * 4xx / 5xx responses

---

## Core Invariants & Nomenclature

All contributors must follow **NOMENCLATURE.md** strictly:

| Term          | Definition                                        |
| ------------- | ------------------------------------------------- |
| Frame         | Single Opus unit (~20ms)                          |
| Segment       | `.bin` file containing frames (**never "chunk"**) |
| DeviceSession | One boot lifecycle (`deviceSessionId`)            |
| Marker        | 0xFE user event (**never "star"**)                |
| WAL           | Byte-offset sync state                            |
| Recording     | Final `.m4a` / `.wav` output                      |

---

## Performance Constraints

### BLE Bottlenecks

* Limited throughput
* Requires:

  * Efficient MTU usage
  * Explicit EOT (0xFD)

### Memory Constraints

* Loading full PCM is not allowed
* `FrameRef` architecture is mandatory

### Battery Optimization

* Firmware does:

  * Record
  * Encode
  * Store

* Firmware does **not**:

  * Run VAD
  * Perform analysis

This keeps:

* MCU mostly idle
* Power usage minimal
* System predictable and reliable

---

## Repository Structure (Suggested)

```
/firmware   → Embedded recording + BLE transport
/app        → Flutter app (sync, VAD, processing, UI)
```

### Key Components

* `OfflineAudioProcessor` → VAD + segmentation engine
* `ManualRecordingExtractor` → Marker-based extraction
* `SDCardWalSyncImpl` → BLE sync implementation

---
