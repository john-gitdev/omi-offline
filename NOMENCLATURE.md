# Omi Offline Naming Standard (NOMENCLATURE.md)

This document defines the official terminology for all audio-related data structures, variables, and files in the Omi Offline application. Use these terms consistently in code, documentation, and issues.

## 1. Core Hierarchy (Hardware to User)

| Term | Category | Level | Description | Old/Overloaded Terms |
| :--- | :--- | :--- | :--- | :--- |
| **Frame** | Data | Atomic | A single encoded Opus audio unit (~20ms). May include transport-specific prefix metadata. | `packet`, `byte_block` |
| **Segment** | Physical | Storage | A `.bin` file containing a fixed target number of **Frames**. The final Segment in a sequence may be partial. | `chunk`, `bin`, `file` |
| **DeviceSession** | Hardware | Stream | An internal hardware-bound concept representing a continuous stream from boot to disconnect. | `session`, `wal_session` |
| **WAL** | Metadata | Progress | A monotonic, append-only source of truth tracking ingestion progress of Segments via an offset (byte or segment index). | `offset_log`, `sync_state` |
| **Capture** | State | Process | The active state in which Frames are being received from the device. (Verb: *to capture*) | `isRecording`, `active_session` |
| **Processing** | Pipeline | Internal | The background task of merging and transcoding Segments into a Recording. | `finalizing`, `transcoding` |
| **Recording** | Artifact | Storage | The final, re-encoded audio file (`.m4a` or `.wav`) stored on disk. | `processed_file`, `recording` |
| **Memory** | Entity | UI | The top-level user object (Recording + Transcript + AI Summary). | `conversation`, `memory_info` |

---

## 2. Standardized Variable Names

### Raw Data & Metadata
- `framesPerSegment`: The target count of frames stored in a single Segment file.
- `segmentIndex`: The zero-based position of a Segment within its DeviceSession.
- `walOffset`: The current monotonic byte or segment index position in the WAL.
- `lastSyncedSegmentIndex`: The index of the last Segment successfully ingested from the device.

### Capture (Live State)
- `isCapturing`: Boolean state indicating if a device stream is active.
- `startCapture()` / `stopCapture()`: Methods initiating/ending the device stream.
- `captureStartTime`: UTC timestamp of the first received Frame.

### Recording (Artifacts)
- `recordingFile`: The `File` object for the transcoded audio artifact.
- `recordingPath`: The absolute string path to the Recording.
- `finalizedRecordings`: List of finished audio artifacts ready for UI binding.

---

## 3. Directory Structure Mapping

- `/raw_segments/`: Physical storage for raw audio data.
  - `/device_session_{id}/`: Groups **Segments** by their hardware session.
    - `segment_{index}.bin`: The physical Segment file.
- `/recordings/`: Physical storage for finalized audio artifacts.
  - `/{yyyy-mm-dd}/`: Organized by the date of **captureStartTime (UTC)**.
    - `recording_{id}.m4a`: The final Recording artifact.

---

## 4. State Definitions

- **IDLE**: No device connected and no active background tasks.
- **CAPTURING**: Frames are actively being received from the device.
- **SYNCING**: The WAL is catching up; Segments are being pulled from device storage.
- **PROCESSING**: The pipeline is actively merging/transcoding Segments into a Recording.
- **PARTIAL_READY**: At least one playable portion of a Recording has been produced from an ongoing Capture, but the Capture has not ended.
- **READY**: The Recording is finalized, stored on disk, and associated with a Memory.

---

## 5. Invariants

- A **Segment** belongs to exactly one **DeviceSession**.
- A **Recording** may span multiple **Segments** but never multiple **DeviceSessions**.
- A **Memory** maps 1:1 to a **Recording**.
- **WAL** ordering is the authoritative source for ingestion sequence and must be monotonic.
- **WAL** offset progression must align with **Segment** ingestion order and must never skip or reorder Segments.
- **Segment** ordering within a **DeviceSession** is strictly increasing by `segmentIndex`.
- **Frame** order within a **Segment** is strictly preserved.

---

## 6. Terminology Rules

- **Segment** is the only valid term for `.bin` files. "chunk" and "bin" are forbidden in code and comments.
- **Recording** refers only to finalized audio artifacts, never live state.
- **DeviceSession** must be prefixed explicitly in all internal variable names (e.g., `deviceSessionId`).
- **DeviceSession** is an internal concept and must never be exposed to the UI or user-facing logs.

---

## 7. Enforcement

- All new code must adhere to this nomenclature.
- PRs introducing conflicting terminology must be rejected or refactored.
- Legacy terms (chunk, bin, session) must not be reintroduced.
