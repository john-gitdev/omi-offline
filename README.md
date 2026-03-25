# Omi Offline: Architecture & Naming Standard

## What is Omi Offline?

Omi Offline is an **offline-first audio capture and processing system** for a wearable device.

Instead of streaming audio in real time, the system:

* Records continuously on-device
* Stores audio locally in structured segments
* Syncs data to the phone in batches over BLE
* Processes audio **offline on the phone** using VAD (RMS-based silence detection)

**Key properties:**

* No continuous BLE streaming
* No real-time cloud dependency
* Improved battery life (phone + wearable)
* Speech segmentation via post-processing

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

* Reduced battery usage
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

#### Framed BLE Protocol

The sync layer uses an explicit framing protocol to prevent audio repetition and corruption:

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

* Sends a **0xFE marker packet** during the BLE stream
* Triggers LED feedback (`marker_flash_count`)

#### App behavior

* Intercepts `0xFE` marker packets during the BLE stream
* Saves marker timestamps to a plain-text `markers.txt` file and excludes them from the raw `.bin` segments
* Performs **bidirectional extraction** around markers:

  * Up to 2 hours backward and forward
* Runs VAD **only within this window**

**Benefit:**

* Precise conversation capture
* Reduced compute and battery usage

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

The sentinel value 0 means "wait for real audio data before committing to a boundary." This avoids anchoring to wall-clock `now()` in the constructor, which could cause an off-by-a-few-seconds boundary mismatch relative to the actual audio timestamps arriving over BLE.

Gap detection handles genuine long offline periods correctly once processing begins.

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

* Marker (user initiated)
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

## Reliability & Stability

Key correctness fixes applied since initial implementation:

| Area | Fix |
| ---- | --- |
| BLE connection | 15-second timeout on adapter and connection waits prevents indefinite hangs |
| BLE sync | Framed protocol with ACK gating eliminates duplicate/gap audio |
| Firmware storage | Storage offset parsing aligned to little-endian (matches firmware write order) |
| Firmware uptime | `last_timestamp_uptime` reset on wipe; uptime rollover handled correctly |
| Opus decode | One decoder per extraction range — state preserved across segment boundaries |
| Subscription lifecycle | Subscriptions stored and cancelled in all providers, services, and transport layers |
| WAL sync async safety | `sdcard_wal_sync` prevents double-complete, async-void fire-and-forget, and stream cancel races |
| `ServiceManager` | `deinit()` is `async`; callers must await it to avoid torn-down services |
| Noise floor | Reset correctly on segment boundaries in `OfflineAudioProcessor` |
| Fixed interval boundary | Staleness guard discards persisted boundary if > 2× interval old or in future; resets to 0 so boundary is anchored to first real audio timestamp |
| Recordings page | Sync state and dialog lifecycle fixed to reflect true sync status |
| Low battery alert | Alert now fires correctly during an active session |
| Connection pipeline | `FindDevicesPage` routes through `DeviceService.ensureConnection()` — never bypasses it |
| VAD slider | Debounce cancels and restarts on every change (no stale previous timer) |
| `TcpTransport` | Recursive disconnect loop prevented in error handler |
| Force sync | Always refreshes WAL list from device regardless of sync threshold |
| Delete Omi Segments | Firmware immediately creates a new recording file on delete; no BLE reconnect cycle needed |
| Firmware boot | 200ms haptic buzz on power-on; LED pulses yellow during LittleFS pre-warm; mic capture delayed until SD is ready |
| Firmware boot | Blue LED blink on boot removed; haptic is the sole power-on signal |
| SD semaphore | Drain after ring-buffer batch to prevent spurious wakeups |
| Firmware transport | Stray `transport_started = 0` removed — no longer discards first CMD_READ_FILE after delete |

---

## Repository Structure (Suggested)

```
/firmware   → Embedded recording + BLE transport
/app        → Flutter app (sync, VAD, processing, UI)
```

### Key Components

* `OfflineAudioProcessor` → VAD + segmentation engine
* `MarkerRecordingExtractor` → Marker-based extraction; uses per-range Opus decoder for clean cross-segment decoding
* `SDCardWalSyncImpl` → Framed BLE sync with ACK gating and gap detection
* `FixedIntervalAudioProcessor` → Fixed wall-clock boundary cutting with cross-restart boundary persistence and staleness guard

---
