# Ideas

## Apple Watch Integration [minor]

The platform layer (watchOS app, iOS AppDelegate, Pigeon-generated Swift/Dart code) is complete and functional. The Dart side is never wired up.

### Issues

- **`WatchRecorderFlutterAPI.setUp()` never called** - Pigeon message channel handlers are never registered, so all incoming watch messages (audio segments, recording start/stop, battery updates) are silently dropped. Fix: instantiate `AppleWatchFlutterBridge` and call `WatchRecorderFlutterAPI.setUp(bridge)` in `ServiceManager.init()` or `main.dart`.

- **`AppleWatchFlutterBridge` never instantiated** - `app/lib/services/bridges/apple_watch_bridge.dart` exists but is never used anywhere in the app.

- **No consumer for watch audio data** - The `onSegment` callback in `AppleWatchFlutterBridge` has no handler. Watch audio frames need to be routed into the same pipeline as BLE audio.

- **No UI for watch status** - APIs exist to check pairing, reachability, battery level, and app installation (`WatchRecorderHostAPI`), but no Flutter screen or widget displays any of this.

### Relevant Files

- `app/lib/services/bridges/apple_watch_bridge.dart` - bridge class, needs instantiation + `setUp()` call
- `app/lib/gen/flutter_communicator.g.dart:468` - `WatchRecorderFlutterAPI.setUp()` defined here
- `app/lib/services/services.dart` - `ServiceManager.init()` is the right place to wire this up
- `app/ios/Runner/AppDelegate.swift` - WCSession delegate, already functional
- `app/ios/Runner/RecorderHostApiImpl.swift` - host API implementation, already functional
- `app/ios/omiWatchApp/` - watchOS app, already functional

## AAD Threshold Refactor & Noise Profiling

Refactor the hardware-acoustic Wake-on-Voice (AAD) system to be user-adjustable and self-tuning.

### Phase 1: Manual Adjustability [Complete]
Successfully implemented manual threshold control from the app.
- **Firmware:** Added `vad_threshold` to settings NVS, dynamic `aad_set_threshold()` API, and BLE Characteristic `0x19B10013`.
- **App:** Added AAD Sensitivity slider (0–32768) in Device Settings with presets and "Always On" (0) / "Manual Only" (32768) support.

### Phase 2: Learning & Auto-Tune [In Progress]
Implement a hybrid statistical/distribution profiling system to allow the device to "Auto-Tune" to its environment.

**Architectural Separation:**
1. **Runtime Autotune Engine (Welford's Algorithm):** 
   - Lightweight, production-safe running stats (Mean, Variance/StdDev).
   - Used for "Auto-Tune" button calculation: `Threshold = Mean + 3*StdDev`.
2. **Developer Diagnostics (Logarithmic Histogram):**
   - 8-bucket distribution visualization for debugging and environmental insight.
   - Buckets: 0-31, 32-63, 64-127, 128-255, 256-511, 512-1023, 1024-2047, 2048+.

**Firmware Tasks:**
- [ ] Implement `vad_profile_t` in `aad.c` using Welford's Online Algorithm.
- [ ] Add 8-bucket logarithmic histogram tracking in `aad.c`.
- [ ] Add BLE Characteristic `0x19B10062` (Read Profile Data: N, Mean, M2, Buckets, Peak, Recording Frames).
- [ ] Add BLE Characteristic `0x19B10063` (Write: Reset Stats).
- [ ] Add periodic persistence for Mean/M2 in `settings.c`.

**App Tasks:**
- [ ] Add **Developer: Noise Diagnostics** dashboard in Device Settings.
- [ ] Implement Bar Chart visualization for logarithmic histogram.
- [ ] Implement **Threshold Overlay** (white line) on top of histogram.
- [ ] Implement **Safe Zone Overlay** (green shaded area for `Mean +/- 3*StdDev`).
- [ ] Implement **Auto-Tune** button: calculates and writes new threshold based on profile.
- [ ] Add "Learning Progress" indicator (Total Frames / Duration).

**Relevant Files:**
- `omi/firmware/omi/src/aad.c` - VAD logic and statistical engine.
- `omi/firmware/omi/src/lib/core/transport.c` - BLE characteristic handlers.
- `app/lib/pages/settings/device_settings.dart` - UI Dashboard and Auto-Tune logic.
- `app/lib/services/devices/omi_connection.dart` - BLE communication.

## Auto-Tune Mic Gain
- [ ] Incorporate automatic tuning of Mic Gain based on hardware amplitude detection.
  - **Concept:** Use the peak amplitude tracking from the Noise Profiler to dynamically adjust the hardware microphone gain.
  - **Anti-Clipping:** If the peak amplitude consistently hits the ceiling (e.g., > 30,000), automatically step down the `mic_gain` to prevent distorted, blown-out audio.
  - **Auto-Boost:** If the peak amplitude of recorded speech is consistently very low, incrementally step up the `mic_gain` to improve signal-to-noise ratio.
  - **Implementation Idea:** The firmware could run a slow PID loop or hysteresis check on the `peak` value over a multi-minute window, adjusting the gain setting directly and notifying the app of the change.

## Firmware AAD: VAD Sensitivity Presets (Deferred)

Brainstormed three sensitivity presets for the hardware AAD threshold, adjustable via a new BLE characteristic (same pattern as mic gain — `settings.c` + `transport.c` + `aad.c`).

| Preset | Threshold | Debounce | Rationale |
|--------|-----------|----------|-----------|
| High sensitivity | 250 (~-42 dBFS) | 4 frames (80ms) | Current default. Extra debounce compensates for low threshold catching noise. |
| Medium (balanced) | 500 (~-36 dBFS) | 3 frames (60ms) | Balanced start latency vs false triggers. |
| Low (noise-resistant) | 1000 (~-30 dBFS) | 2 frames (40ms) | Higher threshold rejects noise, so fewer debounce frames needed. |

Hold time (`CONFIG_OMI_VAD_HOLD_MS = 10000`) could also vary per preset — longer hold at high sensitivity (quiet speech trails off slowly), shorter at low sensitivity (trust the threshold drop).

**Decision: deferred.** Risk of missing audio outweighs the benefit. No real user complaints driving this. Battery drain from AAD is less impactful than BLE/SD/codec — and hold time is a bigger battery lever than threshold anyway. Revisit if noise-environment complaints surface.

## Background Recording Finalization Flaw

### Issue Summary
Recordings are often not finalized when the app is running in the background. Instead, they remain indefinitely as `_draft.wav` files in the app's internal storage until a future background sync or a manual "Force Process".

### The User's Theory (Wall-Clock Finalization)
The user proposed that if `syncAll()` retrieves `0 WALs` (indicating the device is caught up), the app could check the real-world clock. If `Wall Clock Time > Draft End Time + Gap Threshold (e.g. 2 mins)`, the app could safely assume no further speech occurred and finalize the draft.

### The Firmware Hurdle
The user's theory is mathematically sound *if* the app could guarantee there was no audio left on the device. However, the firmware explicitly excludes the currently-open (active) recording bin from the BLE sync list to prevent read/write contention on the SD card.

**Firmware proof (`omi/src/lib/core/storage.c`):**
```c
static int send_file_list_response(struct bt_conn *conn)
{
    // ...
    if (sd_is_current_recording_file_meta(&meta)) {
        continue; // The active file is excluded from the list!
    }
    // ...
}
```

Because the firmware completely hides the active file, a background `syncAll()` will return `0 WALs` even if the user just spoke a 10-second sentence that is now sitting in the active bin.

If we applied the user's wall-clock logic in this scenario:
1. `0:00` - Previous speech ends, sync runs, saves a draft.
2. `1:30` - User speaks for 10 seconds. This goes into the active, hidden bin.
3. `3:00` - Background sync runs. It gets `0 WALs` because the active bin is hidden.
4. `3:00` - Wall Clock Logic sees `0 WALs` and `Time (3:00) > Draft End (0:00) + 2 mins`. It incorrectly finalizes the draft!
5. `10:00` - The active bin finally rotates natively on the device, becomes visible, and is synced. The 10-second sentence from `1:30` is completely orphaned into a fragmented conversation.

### The 1-Minute UI Threshold Guard
During the investigation, we also examined a 1-minute `threshold` check in the Dart `SDCardWalSync._buildWalsFromFilesLocked` loop:
```dart
      final newBytes = file.size - walOffset;
      if (!ignoreThreshold && walOffset == 0 && newBytes < threshold) {
        continue;
      }
```
This guard does *not* affect the active file (since the active file is already hidden by the firmware). Instead, its purpose is to debounce partial downloads of *newly closed* files. It prevents the app from constantly waking up the background service or flashing the "Pending Sync" UI badge for trivial amounts of audio (under 1 minute) after a rotation occurs. When a sync actually starts (like a scheduled background task or a manual press), it passes `ignoreThreshold: true` to bypass this guard and sweep up everything.

### Conclusion
The current logic in `_stitchDraftRecordings` relies strictly on the timestamp of a *future* synced file to confirm that the gap threshold has elapsed. This is the only safe method, as it empirically proves no speech occurred during the gap, circumventing the firmware's active-file blindspot. Wall-clock finalization cannot be implemented safely without changing the firmware to allow syncing the active file.

## Marker Accuracy & Timestamp Synchronization

### Issue Summary
In-stream marker packets (`0xFFFFFFFE`) currently rely on their byte-position within the `.bin` stream to determine their timestamp in the final audio. If the firmware or SD card drops audio frames (due to write latency or buffer overflows), the timeline "shrinks," but the marker remains at its byte-offset, causing it to drift out of sync with the actual audio events.

### Proposed Solution: The "Sequence & Sync" Strategy

To achieve sub-millisecond accuracy and foolproof attribution, the system must move from "Offset-Based" to "Sequence-Based" synchronization.

#### 1. "Sequence & Sync" Packets (Firmware)
Wrap audio data in a tiny header that includes a **Sequence Number** and **Local Uptime**.
- **Audio Packet:** `[Length:4][Sequence:4][UptimeMS:4][Audio Data:N]`
- **Benefit:** If the app sees Sequence #100 followed by Sequence #105, it knows exactly 100ms of audio is missing and can compensate.

#### 2. "Double-Anchored" Markers (Firmware)
Markers should "hard-link" to the audio stream by referencing the last sent audio packet.
- **Marker Packet:** Includes `UTC_Time`, `Uptime_MS`, and **`Last_Sequence_Number`**.
- **Benefit:** The app can look at the marker and say: "This event happened exactly after Audio Packet #4502," regardless of how much audio was lost before or after that point.

#### 3. "Virtual Timeline" Reconstruction (App)
The `VadAudioProcessor` should treat the incoming stream as a sparse set of samples and reconstruct a rigid, gap-less timeline.
- **Implementation:** When a sequence gap is detected, the processor inserts **Silence Frames** into the output `.wav`/`.m4a` file to maintain the correct wall-clock duration.
- **Result:** The resulting audio file's length matches the real-world time elapsed, and markers placed via sequence numbers remain perfectly accurate.

#### 4. Session Integrity & Guarding
- **Sentinel Footer:** Firmware writes a "Footer Packet" at the end of every VAD-session containing the `Total_Samples_Captured` for audit/validation.
- **Session ID Guard:** App strictly enforces the `Device_Session_ID` within markers to prevent "Cross-Pollination" (markers from one recording accidentally being tagged to another during a messy sync).

### Trade-offs & Realism
- **Pros:** Sample-accurate sync, resilience to SD card drops, "Instant-On" UI (if using a separate marker file/summary), and deterministic debugging.
- **Cons:** Increased packet overhead (more bytes per write), slightly higher battery/SD card usage, and increased firmware/app complexity for the new demuxer logic.
