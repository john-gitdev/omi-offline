# Ideas

## Sync and Processing Improvements

### Stale Total Segment Count during Sync
- **Problem:** `RecordingsController` UI shows a stale total segment count (e.g., "4 segments to transfer") even if the device later reports more (e.g., 6 WALs).
- **Analysis:** `RecordingsController.onWalSyncedProgress` has a guard that only backfills `_totalCount` from the service if it is currently `<= 0`. Since an initial estimate is often set at the start of the pipeline, this backfill never triggers when the real count is discovered during `syncAll`.
- **Where to look for problem:** `app/lib/pages/recordings/recordings_controller.dart` (lines 550-575).
- **Proposed Fix:** Update `onWalSyncedProgress` to allow updating `_totalCount` if the service reports a different/larger count than the cached estimate.

### Premature Background Sync Termination on Disconnect
- **Problem:** Sync stops early and fails to resume if the BLE link drops while the app is in the background.
- **Analysis:** 
    1. `SDCardWalSync` aborts its internal loop on disconnect. 
    2. `RecordingsController` transitions the pipeline to processing/idle after the error, instead of waiting for a reconnect. 
    3. When the device auto-reconnects, `DeviceProvider` intentionally drops the connection if the app is backgrounded because the `_pendingBackgroundSync` flag (only used for scheduled timer syncs) is not set for foreground-initiated syncs that moved to the background.
- **Where to look for problem:** 
    - `app/lib/services/wals/sdcard_wal_sync.dart` (line 888) - `syncAll` aborts on connection loss.
    - `app/lib/pages/recordings/recordings_controller.dart` (lines 765-775) - Pipeline ends on sync error.
    - `app/lib/providers/device_provider.dart` (lines 1172-1176) - `_handleDeviceConnected` drops background connections.
- **Proposed Fix:** Maintain a "should resume sync" state that allows `DeviceProvider` to keep background connections alive if a sync was interrupted, and update `RecordingsController` to handle reconnections during an active pipeline.

### Dual/Conflicting Notifications during Processing
- **Problem:** Both `DeviceProvider` (background) and `RecordingsController` (UI) update the same foreground notification with different string formats (percentage vs time remaining), causing the notification to flicker/alternate.
- **Proposed Fix:** Centralize notification management. `DeviceProvider` should update a shared state, and only `RecordingsController` should be responsible for formatting and pushing the notification string.
- **Where to look for problem:** 
    - `app/lib/providers/device_provider.dart` (lines 665-670) - `onProcessingProgress` listener.
    - `app/lib/pages/recordings/recordings_controller.dart` (lines 252-268) - `_updateForegroundProgress` method.
- **Where to add fix:** Update `DeviceProvider` to not call `ForegroundUtil` directly during processing, and ensure `RecordingsController` is the primary writer.

### Incorrect "Stopping" Subtext during Sync Cancellation
- **Problem:** When cancelling sync, the UI immediately shows "Finishing current step" while the background process may still be transferring a large file segment to prevent corruption.
- **Proposed Fix:** Make the "Stopping" state subtext dynamic based on the actual WAL service status.
- **Where to look for problem:** `app/lib/pages/recordings/sync_process_card.dart` (line 101).
- **Where to add fix:** Modify the `SyncProcessState.stopping` case in `sync_process_card.dart` to check `ServiceManager.instance().wal.getSyncs().isSyncing`.

### "Calculating..." Race Condition in Notifications
- **Problem:** Notification shows "< 1 min" briefly before jumping to the true duration (e.g., "686 minutes") because the calculation is asynchronous.
- **Proposed Fix:** Add a guard to the notification formatter to show "Calculating..." if total minutes is 0 while in processing state.
- **Where to look for problem:** `app/lib/pages/recordings/recordings_controller.dart` (lines 262-266).
- **Where to add fix:** Update `_updateForegroundProgress` in `recordings_controller.dart` to check if `_totalMinutes == 0` during processing.

### Auto-Sync Bypass of "Manual Only" Setting
- **Problem:** App triggers an automatic sync on app resume even when set to "Manual Only".
- **Proposed Fix:** Wrap the defensive resume-sync logic with a check for the sync interval setting.
- **Where to look for problem:** `app/lib/providers/device_provider.dart` (lines 847-850).
- **Where to add fix:** Add `if (SharedPreferencesUtil().backgroundSyncIntervalMinutes > 0)` before the `_doBackgroundSync()` call in `device_provider.dart`.

### Processing Persistence (VAD Checkpointing)
- **Problem:** Processing always restarts from the first unprocessed bin because VAD state and progress are not persisted across sessions.
- **Proposed Fix:** Implement a checkpointing system that saves the Silero VAD RNN state and conversation metadata to a temporary file after each successful bin processing.
- **Where to look for problem:** 
    - `app/lib/services/recordings_manager.dart` (lines 1030-1400) - Isolate spawning and management.
    - `app/lib/services/vad_audio_processor.dart` - `_state`, `_vadContext`, and `_currentRefs` management.
- **Where to add fix:** 
    - Update `VadAudioProcessor` to serialize/deserialize state.
    - Update `RecordingsManager` isolate loop to save checkpoints and check for existing ones on startup.

### High-Performance VAD Processing (Zero-Allocation & Native Persistence)

**Problem:** The current VAD implementation causes significant processing backlogs and "noticeable delay" due to high object churn (~150 objects/sec), redundant Dart ↔ Native memory copies for LSTM state, and $O(N)$ list operations during windowing.

**Analysis of Current Bottlenecks:**
The current implementation performs roughly 31 inference cycles per second of audio. Each cycle involves:
1. **Generic List Operations:** `_pcmWindow.sublist` and `removeRange` on a generic `List<double>` which are $O(N)$ operations involving copying.
2. **Object Churn:** Creation of 3 `OrtValue` tensors, 1 `Int64List`, and 1 `Float32List` per 32ms.
3. **Context Switching:** Multiple `await` calls that yield the isolate thread, adding micro-latency.

**Detailed Implementation Plan:**

#### Phase 1: Zero-Allocation Class Fields
Location: `VadAudioProcessor` class definition (around line 75).
- Replace `List<double> _pcmWindow` with `Float32List _pcmBuffer`.
- Add persistent `OrtValue` fields for the Sample Rate and Model State.
- Pre-allocate the concatenated input buffer (`[context (64) | window (512)]`).

```dart
// Precise additions to class VadAudioProcessor:
final Float32List _pcmBuffer = Float32List(1024); // Replaces _pcmWindow
int _pcmBufferLen = 0;
final Float32List _windowedInputBuffer = Float32List(576); // Pre-allocated concat buffer
OrtValue? _cachedSrValue;
OrtValue? _cachedStateValue; // Replaces _state Float32List over time
```

#### Phase 2: Optimized Tensor Handover
Location: `_runVad` method (lines 254–303).
- Stop converting the native "state" back to a Dart `Float32List` (`_state`).
- Manually dispose only the transient input tensor and keep the state and sr tensors alive.
- Impact: Reduces Native-to-Dart memory copying for the state tensor (size: 2 × 1 × 128 floats).

**Detailed logic:**
1. Prepare `_windowedInputBuffer` using `setRange` (faster than for loops).
2. Lazily initialize `_cachedSrValue` on the first call.
3. If `_cachedStateValue` is null, create it from the initial `_state`.
4. Run session.
5. **Crucial:** Dispose the previous `_cachedStateValue` and assign the new output state to it.

#### Phase 3: Fast-Path Windowing
Location: `processSegmentFile` while-loop (lines 617–630).
- Eliminate the while loop's dependency on `sublist`.
- Use `_pcmBuffer.setRange` to fill the buffer and `Float32List.sublistView` to pass data to `_runVad`.

```dart
// Location: app/lib/services/vad_audio_processor.dart:617
final int pcmLen = pcmData.length;
for (int i = 0; i < pcmLen; i++) {
  _pcmBuffer[_pcmBufferLen++] = pcmData[i] / 32768.0;
}
while (_pcmBufferLen >= 512) {
  // Pass a view, not a copy
  if (await _runVad(Float32List.sublistView(_pcmBuffer, 0, 512))) isSpeech = true;
  // Shift remaining samples left
  _pcmBuffer.setRange(0, _pcmBufferLen - 512, _pcmBuffer, 512);
  _pcmBufferLen -= 512;
}
```

#### Phase 4: Resource Cleanup
Location: `destroy()` method (line 247).
- Add explicit calls to `_cachedSrValue?.dispose()` and `_cachedStateValue?.dispose()`.
- Impact: Ensures zero native memory leaks when the background isolate finishes a batch.

**Expected Impact Matrix:**

| Operation | Current Implementation | Optimized Implementation | Impact |
| :--- | :--- | :--- | :--- |
| **Object Allocation** | ~150 objects / second | ~32 objects / second | 78% reduction in GC pressure |
| **Data Copying** | Multiple Dart ↔ Native copies | Native-persistent state | ~50% reduction in bridge latency |
| **List Management** | $O(N)$ sublist + removeRange | $O(N)$ index-based setRange | ~90% reduction in windowing overhead |
| **Overall Speed** | "Noticeable delay" | "Almost instant" | Eliminates processing backlog |

**Feasibility Conclusion:**
The plan is highly feasible. The `flutter_onnxruntime` plugin supports manual management of `OrtValue` objects, and Dart's `TypedData` (`Float32List`) is specifically designed for this type of high-performance buffer manipulation.

## ACTIVE

### VAD state reset: centralize cleanup + flush partial window at conversation end

**File:** `app/lib/services/vad_audio_processor.dart`

Two separate bugs, both need fixing.

---

#### Bug 1: `_resetState()` doesn't clear Silero model state

`_resetState()` (line 918) resets conversation-tracking variables but omits the three VAD buffers:
- `_pcmWindow` — accumulated samples toward the next 512-sample VAD window
- `_state` — Silero LSTM recurrent state (`Float32List(2 * 1 * 128)`)
- `_vadContext` — trailing 64 samples used as context for the next window

Result: a new conversation inherits the previous conversation's model state and partial audio context, causing stale bias in the first few VAD decisions.

**Fix — add to `_resetState()`:**
```dart
_pcmWindow.clear();
_state = Float32List(2 * 1 * 128);
_vadContext = Float32List(_vadContextSamples);
```

This covers paths through `_splitOnSilence` (line 860) and `flushRemaining` (lines 883, 893).

**Critical: two inline-reset paths bypass `_resetState()` entirely and also need the clears:**
1. `0xFFFFFFFD` split path (lines ~629–636): when the VAD-resume gap exceeds the split threshold, inline reset without calling `_resetState()`. Add the three clears there too.
2. Max-cap cut (lines ~774–781): same — inline reset, no `_resetState()` call.

**Redundant clears to remove after fixing `_resetState()`:**
- Inter-file gap split (lines 393–395): manual clears *before* `flushRemaining()`. Redundant — `_resetState()` inside `flushRemaining()` handles it.
- `0xFFFFFFFC` session-end (lines 555–557): manual clears *after* `flushRemaining()`. Redundant for the same reason.

**Stitching invariant to preserve:** when `0xFFFFFFFD` decides to *stitch* (gap below threshold), `_resetState()` must NOT be called — the model needs temporal continuity across the silence padding.

---

#### Bug 2: last partial window at conversation end is never VAD-scored

Each Opus frame decodes to 320 samples. VAD fires only when `_pcmWindow` reaches 512. The accumulation cycle (320 → 640→fire+128 → 448 → 768→fire+256 → ...) means 0–511 samples are always left in `_pcmWindow` at any conversation boundary.

Those frames were already added to `_currentRefs` and `_currentChunkDurationMs` unconditionally, but `isSpeech` defaulted to `false` — so `_lastSpeechRefCount` / `_lastSpeechChunkMs` can be off by 1–2 frames, causing `_splitOnSilence` to over-trim by up to ~32 ms.

Bug 1's fix clears the partial window on reset (correct — prevents contamination of the next conversation's first VAD call), but doesn't retroactively classify those tail frames for the *current* conversation.

**Fix — zero-pad the partial window and run one final VAD pass before `_resetState()`:**
```dart
if (_pcmWindow.isNotEmpty) {
    final padded = List<double>.from(_pcmWindow)
      ..addAll(List.filled(512 - _pcmWindow.length, 0.0));
    if (await _runVad(padded)) {
        _lastSpeechRefCount = _currentRefs.length;
        _lastSpeechChunkMs = _currentChunkDurationMs;
    }
}
```

This needs to run at every site that calls `_resetState()` *and* at the two inline-reset paths in Bug 1. Extract into a `_flushPartialWindow()` helper (async, since `_runVad` is async) called immediately before each reset.

**Where this actually matters:** `0xFFFFFFFC` manual stop mid-speech and draft flushes — the tail could be live speech that gets miscounted as silence and trimmed. For silence-triggered splits and `0xFFFFFFFD` gaps the tail is almost certainly silence, so the default `false` is usually fine.

---

### Marker Pipeline: Test Coverage

**File:** `app/test/unit/recordings_manager_test.dart` (exists; doesn't yet cover the marker pipeline)

The marker pipeline now has roughly fifteen interacting fixes (`vad_audio_processor.dart` orphan emission, `recordings_manager.dart` re-anchor / atomic-write / dedup / migration, firmware atomic session ID, UI long-press affordance). It's currently verified only by reading the code. The right next investment is a synthetic-input test harness so regressions land in CI instead of in the wild.

### What to cover

1. **`VadAudioProcessor.processSegmentFile` against synthetic .bin frames**
   - Build a `Uint8List` containing: a `0xFFFFFFFB` header, N Opus frames (or 4-byte length-prefixed dummy payloads if Opus decode is hard to stub), a `0xFFFFFFFE` marker at frame N/2, more frames, end.
   - Assert `_pendingEdlData` (via `consumePendingEdlData`) emits `{filename, markerMs, offsetMs}` with the expected offsetMs == (N/2 * 20).
   - Variants: marker at offset 0 → fresh recording; marker after a 0xFFFFFFFD VAD-resume → recalibration; marker with bad UTC (< 2000-01-01) → fall back to audio time; marker with UTC drifting > 60 s from audio time → keep audio time (B8).
   - Edge cases: marker followed by zero audio frames → orphan emit; marker → noise → marker → flush → exactly two orphans; encoder-null path (`_saveRecording` returns null) → orphans emitted not silently dropped (A1).

2. **`RecordingsManager._writeMarkerEdl` collision policy**
   - Pre-seed disk with an EDL having `userSaved: true` and custom crops; call `_writeMarkerEdl` with different segmentFilename; assert the EDL was rewritten in place with new segmentFilename but unchanged crops/userSaved.
   - Pre-seed disk with a default-crop EDL; call `_writeMarkerEdl` with different filename; assert the EDL was overwritten in place (no `_1.edl` produced — B4/D1).
   - Pre-seed disk with a corrupt (non-JSON) EDL; assert `_writeMarkerEdl` overwrites it cleanly.

3. **`RecordingsManager._reanchorMarkerEdls`**
   - Pre-seed an EDL with `segmentFilename = next.wav`, `userSaved=false`, `cropStart=0`, `cropEnd=10000`.
   - Call `_reanchorMarkerEdls(from='next.wav', to='draft.wav', offsetShiftMs=300000, newDurationMs=400000, folders=[dir])`.
   - Assert: segmentFilename rewritten to `draft.wav`; markerOffsetMs shifted by 300000; cropStart=0, cropEnd=400000 (default-crop reset, NOT shifted, NEW6/E5).
   - Pre-seed a user-saved EDL (`userSaved=true`, `cropStart=2000`, `cropEnd=8000`); assert the shift applies and clamps to newDurationMs.
   - Cross-folder: pass `folders=[dirA, dirB]`, drop a target EDL in `dirB`; assert it's rewritten.

4. **`RecordingsManager.getMarkerConversations` dedup**
   - Pre-seed two EDLs with the same markerMs and same segmentFilename → expect one MarkerConversation (segment-dedup).
   - Pre-seed two EDLs with the same markerMs and different segmentFilenames → expect canonical = userSaved-first / non-pending / basename-asc (A4/D8).
   - Pre-seed a legacy `marker_<ms>_1.edl` file → expect both to surface as distinct entries (transitional support).

5. **`RecordingsManager` stitch failure paths**
   - `_stitchOgg` / `_stitchWav` with a missing `.meta` for the draft → expect `_finalizeDraft` called and `nextFile` left in place (D3).
   - `_reanchorMarkerEdls` returning false → expect `nextFile.delete()` skipped, audio stitched, EDL untouched (D2).

### Why deferred to a separate session
- Needs to think through what an "encoder-null" stub looks like — `_saveRecordingCore` reaches into platform channels (`AacEncoder.startEncoder`) that need to be mocked. Probably easiest with a fake decoder/encoder injected via constructor.
- The fakes for `Directory`/`File` would let tests run on every dart-test invocation without filesystem dependencies; not strictly required if a `tmp_<test>` directory pattern is acceptable.
- Want a focused PR that doesn't entangle with logic changes — easier to review one big test suite against a frozen pipeline.

### Relevant files
- `app/lib/services/vad_audio_processor.dart` — entry point: `processSegmentFile`
- `app/lib/services/recordings_manager.dart` — entry point: `getMarkerConversations`, `_writeMarkerEdl`, `_reanchorMarkerEdls`
- `app/test/unit/recordings_manager_test.dart` — existing test scaffold to extend

---

## DEFERRED

## Apple Watch Integration [minor] [Deferred]

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

## AAD Threshold Refactor & Noise Profiling [Deferred]

Refactor the hardware-acoustic Wake-on-Voice (AAD) system to be user-adjustable and self-tuning.

### Phase 1: Manual Adjustability [Complete]
Successfully implemented manual threshold control from the app.
- **Firmware:** Added `vad_threshold` to settings NVS, dynamic `aad_set_threshold()` API, and BLE Characteristic `0x19B10013`.
- **App:** Added AAD Sensitivity slider (0–32768) in Device Settings with presets and "Always On" (0) / "Manual Only" (32768) support.

### Phase 2: Learning & Auto-Tune [Deferred]
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

## Auto-Tune Mic Gain [Deferred]
- [ ] Incorporate automatic tuning of Mic Gain based on hardware amplitude detection.
  - **Concept:** Use the peak amplitude tracking from the Noise Profiler to dynamically adjust the hardware microphone gain.
  - **Anti-Clipping:** If the peak amplitude consistently hits the ceiling (e.g., > 30,000), automatically step down the `mic_gain` to prevent distorted, blown-out audio.
  - **Auto-Boost:** If the peak amplitude of recorded speech is consistently very low, incrementally step up the `mic_gain` to improve signal-to-noise ratio.
  - **Implementation Idea:** The firmware could run a slow PID loop or hysteresis check on the `peak` value over a multi-minute window, adjusting the gain setting directly and notifying the app of the change.

## Firmware AAD: VAD Sensitivity Presets [Deferred]

Brainstormed three sensitivity presets for the hardware AAD threshold, adjustable via a new BLE characteristic (same pattern as mic gain — `settings.c` + `transport.c` + `aad.c`).

| Preset | Threshold | Debounce | Rationale |
|--------|-----------|----------|-----------|
| High sensitivity | 250 (~-42 dBFS) | 4 frames (80ms) | Current default. Extra debounce compensates for low threshold catching noise. |
| Medium (balanced) | 500 (~-36 dBFS) | 3 frames (60ms) | Balanced start latency vs false triggers. |
| Low (noise-resistant) | 1000 (~-30 dBFS) | 2 frames (40ms) | Higher threshold rejects noise, so fewer debounce frames needed. |

Hold time (`CONFIG_OMI_VAD_HOLD_MS = 10000`) could also vary per preset — longer hold at high sensitivity (quiet speech trails off slowly), shorter at low sensitivity (trust the threshold drop).

**Decision: deferred.** Risk of missing audio outweighs the benefit. No real user complaints driving this. Battery drain from AAD is less impactful than BLE/SD/codec — and hold time is a bigger battery lever than threshold anyway. Revisit if noise-environment complaints surface.

## Background Sync: Migrate from Dart Timer to WorkManager [major] [Deferred]

Make scheduled background sync survive process death / Doze, instead of relying on a main-isolate Dart timer that Android can freeze or kill.

### Current state (what this replaces)
Two main-isolate mechanisms drive background sync, both in `DeviceProvider`:
- `_backgroundSyncTimer` — a `Timer.periodic(interval)` set in `_startBackgroundSyncTimer()`; on fire it resets `nextSyncTime`, reconnects if needed, and calls `_doBackgroundSync()`.
- The `flutter_foreground_task` heartbeat — `ForegroundTaskEventAction.repeat(5 min)` (`foreground.dart`) fires `onRepeatEvent` in the task isolate → `sendDataToMain('heartbeat')` → `_onForegroundTaskData` in the main isolate → if `nextSyncTime` elapsed, triggers the sync.

Both only fire while the app process is alive. The foreground service + `allowWakeLock` + battery-opt exemption keep it alive on many devices, but Doze and OEM battery managers can freeze/kill it, so background sync is **best-effort**. Sync-on-open (added 0.14.7, `onAppResumed`) is the reliable backstop. WorkManager is Android's deferrable-but-**guaranteed-eventually** scheduler: it persists across process death and reboots and fires in Doze maintenance windows, trading punctuality (min period 15 min, may fire late) for reliability.

### The hard part — read before estimating
- The `workmanager` Flutter plugin runs its callback in a **fresh background isolate** (`callbackDispatcher` / `executeTask`), NOT the main isolate. The entire pipeline — `ServiceManager`, `DeviceProvider`, BLE transport, `WalService`, `RecordingsManager` — lives in the main isolate. A WM task **cannot** just call `DeviceProvider._doBackgroundSync()`.
- Platform channels (Pigeon `BleHostApi`/`BleFlutterApi`, `SharedPreferences`, opus) must be re-bound in the WM isolate via `BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken)`. The native BLE layer (`OmiBleManager` / `OmiBleForegroundService`) is a **process-level singleton** and delivers GATT callbacks to whichever isolate last registered `BleFlutterApi` — so the main and WM isolates must never both own BLE at the same time.

### Refactor prerequisite (do first — benefits either approach)
Extract the body of `DeviceProvider._doBackgroundSync()` into a UI-free `BackgroundSyncRunner.run()` (e.g. `app/lib/services/background_sync_runner.dart`):
- It already only touches `ServiceManager`, `RecordingsManager`, `ForegroundUtil`, `WakelockPlus` — the only UI coupling is the `notifyListeners()` / `lastSyncError` / `nextSyncTime` writes. Replace those with a returned result object.
- `_doBackgroundSync()` becomes a thin wrapper that calls the runner and copies the result into its observable fields.
- Preserve the `_backgroundSyncActive` re-entrancy guard semantics in the runner (the wakelock is a global bool, not ref-counted — two concurrent runs corrupt it).
- Result: the same sync is callable from the main isolate (today) and the WM isolate (Approach A).

### Approach A — WM runs a headless sync in its own isolate (recommended target; true process-death resilience)
1. Add `workmanager` dep. In `main()` call `Workmanager().initialize(callbackDispatcher)` and register a periodic task. Re-register on the settings-save path that today calls `restartBackgroundSyncTimer()` (`app_settings_page.dart:_saveSettings`). Map interval: 15 min → 1:1 (WM floor), 30/60 → multiples or self-rescheduling one-off `registerOneOffTask` with `initialDelay` for punctuality; "Manual Only" (`-1`) → `cancelByUniqueName`.
2. `callbackDispatcher` (top-level, `@pragma('vm:entry-point')`):
   - `BackgroundIsolateBinaryMessenger.ensureInitialized(token)` (capture `RootIsolateToken.instance` at registration, pass via `inputData`).
   - `initOpus(...)`, `SharedPreferencesUtil.init()`, `BleFlutterApi.setUp(BleBridge.instance)`, `ServiceManager.init()` + `start()`.
   - `manageDevice(boundId)` via the native FG service, await `onDeviceReady`, then `BackgroundSyncRunner.run()`.
   - Disconnect (maximize-battery), return `Future.value(true)`.
3. Mutual exclusion: if the app is foregrounded (main isolate owns BLE), the WM task must no-op — gate on a shared flag (prefs key / lock file) set by `onAppResumed`/`onAppPaused`, and let the main-isolate path win.

### Approach B — WM as a wakeup that defers to the existing main-isolate path (smaller, weaker guarantee)
WM periodic task just (re)starts native `OmiBleForegroundService` for the bound device + the `flutter_foreground_task` service, bringing the machinery up; the existing `_pendingBackgroundSync` → `_onDeviceConnected` → `_doBackgroundSync()` path then runs in the main isolate. Reuses everything, but mostly duplicates what the foreground service already does, so the reliability gain over today is marginal. Use only as a stepping stone.

### Gotchas to preserve
- WAL transfer is **resumable**, so a WM task killed mid-sync is safe — it resumes next fire (the truncate-on-resume guard bounds re-fetch).
- `nextSyncTime` is UI state for the App Settings "Next sync at…" row and the "Omi Offline Sync Timer" notification. With WM owning scheduling, either derive it from the registered period or drop the live countdown when the process is asleep (the FG-service notification only exists while the process is alive anyway).
- Keep requesting the battery-opt exemption (`ForegroundUtil.requestPermissions`).
- **Scope to Android.** iOS WorkManager → `BGTaskScheduler` is even less punctual, and the notification/FG path is already Android-only (iOS `showNotification: false`).

### Relevant files
- `app/lib/providers/device_provider.dart` — `_startBackgroundSyncTimer`, `_backgroundSyncTimer`, `nextSyncTime`, `_onForegroundTaskData` (heartbeat), `_doBackgroundSync` (body to extract).
- `app/lib/utils/audio/foreground.dart` — `flutter_foreground_task` setup + the `onRepeatEvent` heartbeat WM would replace/augment.
- `app/lib/main.dart` — where to call `Workmanager().initialize`.
- `app/lib/pages/settings/app_settings_page.dart` — `_saveSettings` (`restartBackgroundSyncTimer()`); mirror for WM (re)registration; the "Next sync at…" consumer.
- `app/lib/services/services.dart` — `ServiceManager.init/start` to re-run in the WM isolate (Approach A).
- `app/lib/services/bridges/ble_bridge.dart` — `BleFlutterApi.setUp` binding; must be re-bound in the WM isolate.
- `app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt` — native BLE owner; Approach B (re)starts it from WM.

### Why deferred
Large and cross-cutting (Dart + native + isolate lifecycle), and the 0.14.7 sync-on-open fix already covers the dominant case (open app → syncs when due). WorkManager only buys the "phone in pocket for hours, app killed" window, against real complexity and the isolate/BLE-ownership hazards above. Revisit if users report missed overnight syncs despite sync-on-open.
