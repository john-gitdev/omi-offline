# Ideas

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
