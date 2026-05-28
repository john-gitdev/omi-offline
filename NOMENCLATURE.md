# Omi Offline Naming Standard (NOMENCLATURE.md)

This document defines the official terminology for all audio-related data structures, variables, and files in the Omi Offline application. Use these terms consistently in code, documentation, and issues.

## 1. Core Hierarchy (Hardware to User)

| Term | Category | Level | Description | Old/Overloaded Terms |
| :--- | :--- | :--- | :--- | :--- |
| **Frame** | Data | Atomic | A single encoded Opus audio unit (~20ms). May include transport-specific prefix metadata. | `packet`, `byte_block`, `chunk` (when referring to audio data units) |
| **Segment** | Physical | Storage | A `.bin` file containing a sequence of **Frames**. | `chunk`, `bin`, `file` |
| **DeviceSession** | Hardware | Stream | An internal hardware-bound concept representing a continuous stream from boot to disconnect. | `session`, `wal_session`, `sessionId`, `device session` |
| **Marker** | Metadata | Event | A point-in-time event (e.g. Star) stored as a timestamp. | `star`, `event`, `stars.txt` |
| **WAL** | Metadata | Progress | A monotonic, append-only source of truth tracking ingestion progress of **Segments**. | `offset_log`, `sync_state`, `storageOffset` |
| **Capture** | State | Process | The active state in which **Frames** are being received from the device. | `isRecording`, `active_session` |
| **Processing** | Pipeline | Internal | The background task of merging and transcoding **Segments** into a **Recording**. | `finalizing`, `transcoding` |
| **Batch** | Logical | Grouping | A collection of **Segments** and **Conversations** grouped by UTC date. | `DailyBatch` |
| **Recording** | Artifact | Storage | The final transcoded audio file (`.m4a` or `.wav`) stored on disk. | `processed_file` |
| **Conversation** | Entity | Local | The local-only logical container (Recording + Timestamps) before AI enrichment. | `RecordingInfo`, `recording` |
| **Memory** | Entity | Unified | (Aspirational) The top-level user object (**Conversation** + Transcript + AI Summary). | `memory_info` |

---

## 2. Standardized Variable Names

### Raw Data & Metadata
- `timerStart`: The Unix UTC timestamp (seconds) the firmware assigns when it opens a new `.bin` file. Used as the WAL key and as the segment filename prefix.
- `sessionId` (WAL layer) / `deviceSessionId` (conceptual): The unique identifier for a hardware **DeviceSession** (a random 32-bit value generated at firmware boot). In code the bare `sessionId` is what most call sites use (e.g. `wal.sessionId`); `deviceSessionId` is the preferred term in new code and documentation.
- `walOffset`: The current monotonic byte position in the **WAL**. Always bytes — never a segment index. (Persisted as `storageOffset` in JSON for legacy reasons.)
- `segmentIndex`: Used only on the Apple Watch / pigeon bridge (`flutter_communicator.g.dart`, `watch_interface.dart`); it does **not** appear in the SD-card sync path. Segments on disk are keyed by `timerStart`, not by an index.

### Capture (Live State)
- `isCapturing`: A public getter on `VadAudioProcessor` (in `vad_audio_processor.dart`), only consumed internally — true while speech frames are being accumulated into an in-progress recording. There is no top-level/UI `isCapturing` flag.
- `startCapture()` / `stopCapture()`: Aspirational API for initiating/ending the device stream (not yet implemented).
- `captureStartTime`: Aspirational. The closest real value is the private `_recordingStartTime` inside `VadAudioProcessor`.

### VAD & Processing Settings (in `app/lib/backend/preferences.dart`)
- `vadSplitSeconds` (default 120): Silence duration required to split into a new **Recording**.
- `vadMinSpeechSeconds` (default 3): Minimum speech duration required for a valid **Recording**.
- `vadMaxConversationMinutes` (default 60 on the legacy global pref; the per-mode `autoModeVadMaxConversationMinutes` and `manualModeVadMaxConversationMinutes` both default to **0 = no cap** and are the values actually consulted now): Hard cap on a single **Recording**.
- `manualMode` (default `true` since 0.14.0): Selects which per-mode snapshot is applied. Manual mode pins VAD off, ignores `vadSplitSeconds` / `vadMinSpeechSeconds` (no speech/duration filtering), and relies on the firmware-emitted session-end marker (`0xFFFFFFFC`) as the conversation boundary; the only user-tunable manual-mode knob is `manualModeVadMaxConversationMinutes`.
- `autoMode*` variants: Per-mode overrides for auto mode (`autoModeVadEnabled`, `autoModeVadSpeechThreshold`, `autoModeVadMinSpeechSeconds`, `autoModeVadSplitSeconds`, `autoModeFilterMinDurationSeconds`, `autoModeDiscardShortRecordings`, `autoModeVadMaxConversationMinutes`).
- **Note:** There is no `vadGapSeconds`, `vadSnrMarginDb`, or `vadPreSpeechSeconds` setting. The gap threshold between consecutive files is derived as `vadSplitSeconds - _firmwareVadHoldMs` (10 s); the SNR margin lives inside `OfflineAudioProcessor` and is not a user preference.

### Markers
- `markerTimestamps`: `List<DateTime>` field on `Batch` — the event timestamps (button taps) of all markers that fell in that **Batch**'s UTC day.

### Recording (Artifacts)
- `recordingFile`: The `File` object for the transcoded audio artifact.
- `recordingPath`: The absolute string path to the **Recording**.
- `finalizedRecordings`: List of finished audio artifacts ready for UI binding.

---

## 3. Directory Structure Mapping

- `/raw_segments/`: Physical storage for raw audio data.
  - `/{timerStart}/`: Numeric folder grouping **Segments** that share a `timerStart` (Unix UTC seconds), e.g. `raw_segments/1713892490/`. This is the normal "synced timestamps" layout.
  - `/session_{sessionId}/`: Fallback folder used when `timerStart` predates the epoch validity check (`< 946684800`) — i.e. pre-time-sync data. `sessionId` is rendered as a decimal `int` (e.g. `session_2847583920/`), not hex. The UI groups these under "Unorganized".
    - `{timerStart}_{sessionId}.bin`: **Segment** file. Written by `_flushToDisk()` in `sdcard_wal_sync.dart`. `sessionId` is the firmware's 32-bit DeviceSession ID (or `0` if unknown).
    - **Markers are not written here.** Marker events (`0xFFFFFFFE` packets inside the `.bin` stream) are decoded in-line by `VadAudioProcessor` and persisted as `.edl` sidecars next to the finalized recording.
- `/recordings/`: Physical storage for finalized audio artifacts.
  - `/{yyyy-mm-dd}/`: Organized by the UTC date of the recording's start time.
    - `recording_{startMs}.m4a` / `.wav`: The final **Recording** artifact (millisecond UTC timestamp).
    - `recording_{startMs}_draft.m4a` / `.wav`: In-progress flush. Written by `flushRemaining(isDraft: true)` at end-of-run and re-stitched on the next sync+process cycle until silence/cap conditions promote it to a finalized recording. Not surfaced in the UI.
    - `recording_{startMs}.meta`: Optional metadata sidecar (binary; carries duration, end timestamp, capEnded flag, upload key, passthrough/forceSynced flags, session id).
    - `marker_{markerMs}.edl`: **Marker** sidecar — JSON with `markerTimestampMs`, `segmentFilename`, `markerOffsetMs`, `cropStartMs`, `cropEndMs`, and `userSaved` fields. Created during processing; orphan markers (no surrounding audio) are written with an empty `segmentFilename` and detected via `getMarkerConversations()`. Collision policy: if the same `markerMs` re-fires it lands at `marker_{markerMs}_{n}.edl`.
    - `discards.jsonl`: One JSONL line per stretch of audio that VAD dropped, surfaced as greyed-out "ghost" rows in the recordings list so the user can attempt recovery. Parsed by `RecordingsManager.loadDiscards()` into `DiscardRecord`s.

---

## 4. State Definitions

### SyncProcessState (UI state machine, `app/lib/pages/recordings/recordings_types.dart`)
The actual enum values in use:
- **idle**: No sync or processing is running.
- **syncing**: The **WAL** is catching up; **Segments** are being pulled from device storage.
- **processing**: The pipeline is actively merging/transcoding **Segments** into a **Recording**.
- **stopping**: A cancellation has been requested; waiting for the current operation to wind down.
- **resume**: Returning to idle after a completed or cancelled operation.
- **error**: A sync or processing error occurred.
- **successUi**: Transient state indicating a successful completion to trigger UI feedback.

### Conceptual states (not yet in enum)
- **PARTIAL_READY**: At least one playable portion of a **Recording** has been produced from an ongoing **Capture**, but the **Capture** has not ended. Aspirational.
- **READY**: The **Recording** is finalized, stored on disk, and associated with a **Memory**. Aspirational.

---

## 5. Invariants

- A **Segment** belongs to exactly one **DeviceSession**.
- A **Recording** may span multiple **Segments** but never multiple **DeviceSessions**.
- A **Memory** maps 1:1 to a **Recording**.
- **WAL** ordering is the authoritative source for ingestion sequence and must be monotonic.
- **WAL** offset (`walOffset`) is always a byte count — never a segment index.
- **Segment** ordering within a **DeviceSession** is strictly increasing by `timerStart` (segments are keyed by timestamp on the SD-card sync path, not by an index).
- **Frame** order within a **Segment** is strictly preserved.
- **Marker** timestamps must be strictly ordered within a **DeviceSession**.
- **Marker** timestamps must fall within the temporal bounds of their associated **DeviceSession**.
- A **Recording** derived from **Markers** must align to **Segment** boundaries and preserve **Frame** ordering.

---

## 6. Terminology Rules

- **Segment** is the only valid term for `.bin` files. "bin" is forbidden in code and comments when referring to audio data files.
- **Recording** refers only to finalized audio artifacts, never live state.
- **DeviceSession** is the preferred conceptual term and `deviceSessionId` is preferred in new code. The WAL layer currently uses bare `sessionId` (e.g. `wal.sessionId`); that is the existing convention and is acceptable in WAL-layer code. Outside that layer, use `deviceSessionId`.
- **DeviceSession** is an internal concept and must never be exposed to the UI or user-facing logs.
- "chunk" is forbidden when referring to a **Segment** or **Frame** (audio data units). It is permitted in low-level disk I/O, WAV file format parsing (RIFF/fmt/data chunks), and platform channel streaming contexts.

---

## 7. Firmware Name Mapping

The firmware (C / Zephyr RTOS on nRF5340) uses C snake_case conventions. Firmware naming is now fully aligned with application nomenclature. These renames do not affect the binary protocol — byte offsets define the wire format.

| Firmware (C) | File | App (Dart) | Notes |
| :--- | :--- | :--- | :--- |
| File timestamp | `CMD_LIST_FILES` | `timerStart` (and folder name) | The UNIX UTC timestamp (seconds) the firmware reports for each file. |
| `device_session_id` (`atomic_t`, read as u32) | `transport.c`, `transport.h`, `main.c` | `wal.sessionId` / `deviceSessionId` | 32-bit random ID; lazy-initialized via `ensure_device_session_id()` in `transport.c` and also seeded from `main()` at boot. |
| `write_marker_to_storage()` | `transport.c`, `transport.h`, `button.c` | `Marker` | Writes a custom-packet frame with the 32-bit length prefix value `0xFFFFFFFE` (not a single `0xFE` byte) and a 16-byte payload: `utc_time_ms` (u64), `uptime_ms` (u32), `device_session_id` (u32). |
| `write_session_end_marker_to_storage()` | `transport.c`, `transport.h`, `aad.c` | Manual-mode stop boundary | Writes a 20-byte session-end frame (header `0xFFFFFFFC` + 16-byte payload). Emitted when manual mode receives a stop-tap and used by `VadAudioProcessor` to auto-finalize the recording without a Force Process. |
| `write_custom_packet_to_storage(0xFFFFFFFD, …)` | `aad.c` | AAD VAD resume | Written by hardware AAD when a VAD event re-opens recording after silence; 16-byte payload similar to the marker. |
| `marker_flash_count` (`volatile uint8_t`) | `button.c`, `button.h`, `main.c` | *(no app equivalent)* | Drives the transient white LED flash on double-tap (Marker event). |
| `PACKET_EOT` = `0x02` (single byte) | `storage.c` | end-of-transfer signal | Sent over the storage data-stream characteristic to signal end of file (or end of file list); consumed by `SDCardWalSyncImpl`, not stored. |

---

## 8. Enforcement

- All new code must adhere to this nomenclature.
- PRs introducing conflicting terminology must be rejected or refactored.
- Legacy terms (`bin` for audio files, `star` for Marker) must not be reintroduced. Bare `sessionId` is retained inside the WAL layer for historical reasons; new code outside that layer should use `deviceSessionId`.
- `chunk` is permitted only in low-level I/O, WAV format parsing, and platform channel streaming; it must not be used to refer to Segments or Frames.
- `packet` is permitted only when referring to BLE transport layer packets or other low-level network data chunks, but must not be used for generic audio data units.
