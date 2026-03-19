# Omi Offline Naming Standard & System Architecture

Welcome to the Omi Offline system documentation. This document deeply explains the core architecture, data lifecycle, and implementation details of the wearable system, which has evolved significantly from its original design.

## The Evolution: From Streaming to Offline-First

Originally, the Omi wearable operated as a **streaming audio system**. It continuously streamed live audio packets over BLE to the connected phone, which then had to immediately receive and upload that audio to the cloud. There was no Voice Activity Detection (VAD) gating on either the device or the phone. This approach proved insufficient primarily due to battery drain:
1. **Phone Battery Drain:** The constant BLE connection combined with the phone's requirement to continuously wake up, process audio packets, and use its cellular radio to upload them caused severe, unsustainable battery drain on the user's phone.
2. **Wearable Battery & Bandwidth:** Constant BLE streaming also exhausted the wearable's battery quickly and saturated the BLE channel, leaving no room for dropouts or network instability.

To solve this, the architecture was transformed into an **offline-first, batch-processing system**. 

Today, the firmware acts as a dumb, reliable pipe: it continuously records all audio, chunks it into segments, and writes it directly to a local SD card. The companion app later synchronizes these segments over BLE (or WiFi) using a Write-Ahead Log (WAL) approach, and processes the audio locally on the phone. This allows the app to use a highly sophisticated, bidirectional VAD algorithm with rich context windows, preserving battery life on both the phone and the wearable while drastically improving transcription accuracy.

---

## 1. Local VAD Gating

Because the firmware acts as a simple storage pipe, all "Local VAD" runs strictly on the **app side (Flutter/Dart)** during the offline processing phase. 

### How it works (`OfflineAudioProcessor`)
When the app processes synchronized `.bin` segments, it doesn't load the entire file into memory. Instead:
1. **Frame Decoding:** It iterates through the `.bin` file frame-by-frame, decoding the Opus payload into PCM data.
2. **dBFS Calculation:** It calculates the RMS of the PCM data to determine the dBFS (decibels relative to full scale).
3. **Asymmetric Noise Floor Tracking:** The system continuously tracks environmental noise using two exponential moving averages. It adapts slowly to loud transients (`alphaRise = 0.995`, ~10s) so it doesn't suppress speech, but adapts quickly downward (`alphaFall = 0.98`, ~2s) when leaving a noisy environment.
4. **Speech Gating:** A frame is considered speech if its `dBFS > noiseFloor + snrMarginDb`.
5. **Memory Efficiency:** Instead of caching audio bytes, the VAD algorithm accumulates `FrameRef` objects (disk pointers with byte offsets and lengths). Once a conversation completes, these pointers are sequentially read from the SD card segments and transcoded into an `.m4a` or `.wav` file.

---

## 2. Automatic vs. Manual Modes

The app supports two primary processing heuristics, defining how raw segments are converted into finalized recordings.

### Automatic Mode
In this mode, the `OfflineAudioProcessor` acts as a continuous, forward-scanning state machine. It evaluates every frame for speech.
- **Splitting:** If continuous silence exceeds the split threshold, the recording is finalized. 
- **Dropping:** If the accumulated speech duration is less than the minimum speech threshold, the recording is discarded.
- **Context:** A predefined buffer of trailing silence is carried over to the next recording to serve as a pre-speech buffer.

### Manual Mode (Marker / Star System)
Instead of relying purely on voice activity, users can manually trigger a recording by double-tapping the wearable. 
- **Firmware behavior:** The firmware immediately flashes the LED (`marker_flash_count`) and writes a `0xFE` packet into the storage stream. This is a point-in-time event.
- **App behavior (`ManualRecordingExtractor`):** The app searches the synchronized segments for these marker timestamps. It then executes a **bidirectional scan**, moving up to 2 hours backward and forward from the marker. 
- **VAD within Windows:** It runs the VAD pass *only* within these localized windows to extract the exact conversation surrounding the button press, saving battery and compute time.

---

## 3. VAD Sliders & Tuning System

The app exposes a robust tuning system (`SharedPreferencesUtil`), which dictates the exact thresholds used by the VAD state machine.

| Slider / Setting | Internal Variable | Implementation Detail & Tradeoffs |
| :--- | :--- | :--- |
| **SNR Margin** | `_snrMarginDb` | The dB threshold above the dynamically tracked noise floor required to trigger speech. *Tradeoff:* Lower values increase false positives (background noise recorded); higher values miss quiet speech. |
| **Hangover Time** | `_hangoverFrameCount` | The number of frames to keep VAD "high" after the signal drops below the SNR threshold. Prevents mid-sentence stuttering or micro-cuts during natural pauses. |
| **Split Duration** | `_silenceDurationToSplitMs` | The duration of continuous silence required to close a recording session and finalize the artifact. |
| **Min Speech** | `_minSpeechMs` | The absolute minimum duration of active speech required to save a recording. Filters out transient noises like coughs, bumps, or throat clearing. |
| **Pre-Speech Buffer** | `_preSpeechBufferMs` | The amount of silence to preserve *before* the VAD triggers. Captures the breath before a sentence and ensures the very first syllable is not clipped. |
| **Gap Threshold** | `_gapThresholdMs` | A safety mechanism. If the absolute timestamp difference between two physical segments exceeds this value (e.g., the device was powered off), the system forces a split regardless of VAD state. |

---

## 4. Sync & Process Pipeline

The data lifecycle relies on strict ordering and physical boundaries to guarantee zero data loss.

### The Sync Pipeline (BLE Transport)
- **Data Storage:** The wearable stores Opus audio frames into fixed-size `.bin` files (`Segments`). 
- **Metadata:** Each segment starts with a `0xFF` metadata packet (255 length) containing the `deviceSessionId` (a random u32 generated at boot), `segmentIndex`, UTC time, and uptime.
- **Transfer Model:** The app requests data starting from a specific byte offset (WAL offset). The firmware streams packets over BLE (up to negotiated MTU - 3 bytes). 
- **EOT Marker:** When the firmware exhausts its written data, it sends a `0xFD` marker byte. This explicitly signals the end-of-transfer to the app's `SDCardWalSyncImpl`.

### The Process Pipeline
- **Chronological Merging:** Crucially, the app organizes segments by `(deviceSessionId, segmentIndex)`. It **never artificially cuts** recordings at batch or calendar day boundaries. A conversation that spans midnight is processed contiguously.
- **State Cleanup:** Once segments are processed and transcoded to final `.m4a` files (`Recordings`), the raw `.bin` segments are deleted from the phone to save space, unless the user has "Adjustment Mode" enabled.
- **SharedPreferences Anchors:** Because the wearable might not have an immediate RTC lock, the app writes anchor timestamps (`anchor_utc_device_session_{id}`) correlating device uptime with the phone's wall-clock time. This ensures absolute timestamp accuracy during the processing phase.

---

## 5. HeyPocket Integration

The app features a native integration with the HeyPocket API (`https://public.heypocketai.com/api/v1`).

- **API Model:** Uses a standard REST POST multipart upload of the finalized `.m4a` recording file alongside an API Key.
- **Upload Flow:** 
  - **Manual:** Triggered by the user via the UI.
  - **Automatic:** If `autoSyncEnabled` and `heypocketEnabled` are true, the system runs a background poll (`_pollHeyPocket()`) evaluating the `finalizedRecordings` list.
- **Idempotency & State:** The app maintains a registry of successfully uploaded files (`heypocketUploadedFiles` in SharedPreferences) using a unique upload key derived from the file path. This prevents duplicate uploads even if the system restarts.
- **Error Handling:** Network timeouts or 4xx/5xx HTTP errors are wrapped in a `HeyPocketException`, allowing the UI to display precise SnackBar notifications and enabling the background loop to retry gracefully on subsequent passes.

---

## Core Invariants & Nomenclature

If you are contributing to this codebase, you must adhere to the semantic terminology defined in `NOMENCLATURE.md`:

- **Frame:** A single encoded Opus audio unit (~20ms).
- **Segment:** A `.bin` file stored on the SD card containing multiple Frames. (Never refer to this as a "chunk").
- **DeviceSession:** A stream of segments representing a single hardware boot lifecycle. (Variable: `deviceSessionId`).
- **Marker:** A user-initiated event (double-tap) stored as a `0xFE` packet. (Never refer to this as a "star").
- **WAL:** The append-only byte-offset state tracking synchronization progress.
- **Recording:** The final, transcoded artifact (`.m4a` or `.wav`).

### Performance Constraints
- **BLE Bottlenecks:** Transferring raw segments over BLE is inherently slow. The system heavily relies on `0xFD` (EOT) markers and specific MTU sizes to maximize throughput.
- **Memory Footprint:** The `FrameRef` architecture is a strict requirement. Mobile operating systems will kill the app if it attempts to load hours of PCM data into RAM simultaneously.
- **Battery Optimization:** By moving VAD from the firmware to the mobile app's offline processing phase, the wearable's compute load is minimized, allowing the MCU to sleep between simple SD card write operations.