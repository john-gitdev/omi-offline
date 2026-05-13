# TODO

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