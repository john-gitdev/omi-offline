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

## Migrate VAD off unmaintained `onnxruntime` → `flutter_onnxruntime` (16 KB page alignment)

### Why
- Current dep `onnxruntime: ^1.4.0` (resolved to `1.4.1`, published ~2 years ago) is unmaintained.
- Its bundled `libonnxruntime.so` for `arm64-v8a` is 4 KB-page aligned (`LOAD` segment align `0x1000`). Verified via `readelf -lW` on `app/build/app/intermediates/merged_native_libs/devDebug/.../arm64-v8a/libonnxruntime.so`.
- Android 16 (API 36) devices booted with 16 KB pages refuse to load 4 KB-aligned `.so` files → VAD crashes on first model load. Google Play also enforces 16 KB alignment for new submissions targeting SDK 36+ as of Nov 2025.
- Today this does not affect the dev's Pixel 8 Pro (default 4 KB pages), but the moment a 16 KB device is in the loop the app breaks.

### Replacement package
- **`flutter_onnxruntime`** (different maintainer; not a drop-in fork of the Telosnex package).
- Latest version at time of writing: `1.7.1`, bundles ORT native lib `1.22.0`, 16 KB aligned for arm64 since its `1.5.1` release.
- pub.dev: https://pub.dev/packages/flutter_onnxruntime
- iOS minimum bumps to `iOS 16`, macOS minimum to `macOS 14`. Verify these match `app/ios/Podfile` and `app/macos/Podfile` before bumping.

### API delta (read these before editing)
Old API (currently in use, synchronous):
```dart
OrtEnv.instance.init();
final opts = OrtSessionOptions();
final session = OrtSession.fromBuffer(modelBytes, opts);
final input = OrtValueTensor.createTensorWithDataList(data, [1, N]);
final runOptions = OrtRunOptions();
final outputs = session.run(runOptions, {'input': input, ...});
// cleanup
input.release(); runOptions.release(); outputs.forEach((o) => o?.release()); session.release();
```

New API (`flutter_onnxruntime` 1.7.x, **async** + different entry point):
```dart
final ort = OnnxRuntime();
final session = await ort.createSessionFromAsset('assets/models/silero_vad.onnx');
// or createSessionFromBuffer / createSessionFromFile — verify exact names against the package's API docs.
final input = await OrtValue.fromList(data, [1, N]);
final outputs = await session.run({'input': input, ...});
// memory mgmt is handled natively; explicit .release() calls are removed.
```

Key naming / behavioral changes to handle:
- `OrtSession.fromBuffer(bytes, opts)` → `await ort.createSessionFromBuffer(bytes)` (or `createSessionFromAsset` if loading the model from `assets/models/silero_vad.onnx` directly — preferred, lets the plugin skip Dart-side `rootBundle.load`).
- `OrtValueTensor.createTensorWithDataList(data, shape)` → `await OrtValue.fromList(data, shape)`.
- `OrtRunOptions()` is gone; `session.run(...)` no longer takes a runOptions arg.
- Inference call is now `async` — every call site has to `await`.
- No explicit `.release()` on tensors / outputs / session in normal flow (verify if `dispose()` is needed for explicit lifecycle control before re-spawning the processing isolate).

### Call sites that need editing
1. `app/lib/services/vad_audio_processor.dart`
   - Line 7: `import 'package:onnxruntime/onnxruntime.dart';` → `import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';`
   - Line 62: `OrtSession? _session;` — type still exists.
   - Lines 146–157: init + session creation block (`OrtEnv.instance.init()` + `OrtSession.fromBuffer`).
   - Lines 211–214: `OrtValueTensor.createTensorWithDataList(...)` × 4 (input, sr, h, c).
   - Lines 217–221: `OrtRunOptions()` + `_session!.run(runOptions, inputs)`.
   - Lines 197, 233, 235, 236: all the `.release()` calls — likely deletable.
   - The whole `_process()` method is currently sync; converting `run()` to `await` propagates up. Check whether `VadAudioProcessor` is invoked from an isolate entry point that's already `async` (it is — `runRecoverySweep` spawns an isolate and the entry function is async). Should be straightforward.

2. `app/lib/services/recordings_manager.dart`
   - Line 9: import swap.
   - Line 473: comment references `ForegroundServiceDidNotStartInTimeException caused by onnxruntime FFI` — review whether the new package has the same FFI-blocks-main-thread issue (likely better since it's async). If improved, the workaround comment + any defensive delay can be simplified.
   - Lines 499, 504, 507, 508: `OrtEnv.instance.init()`, `OrtSession?`, `OrtSessionOptions()`, `OrtSession.fromBuffer(...)`.

### Other assets to check
- `app/assets/models/silero_vad.onnx` — already present; if the new package supports `createSessionFromAsset`, the `rootBundle.load` step in `vad_audio_processor.dart:154` becomes unnecessary.
- `app/pubspec.yaml:21` — replace `onnxruntime: ^1.4.0` with `flutter_onnxruntime: ^1.7.1` (pin to a known-good 1.7.x at time of update).
- iOS `Podfile` / macOS `Podfile` minimum platform versions.

### Verification steps after migration
1. `cd app && flutter pub get && flutter build apk --debug --flavor dev`.
2. Confirm new alignment:
   ```bash
   readelf -lW app/build/app/intermediates/merged_native_libs/devDebug/mergeDevDebugNativeLibs/out/lib/arm64-v8a/libonnxruntime.so | grep LOAD
   ```
   First `LOAD` segment must show align `0x4000` (or larger).
3. Run a recovery sweep on a populated `raw_segments/` directory; confirm VAD still detects speech boundaries identically to the old package on a regression clip.
4. Run on a 16 KB-mode device (Pixel 8/9 with Developer Options → "Boot with 16 KB page size" enabled) and confirm the lib loads.

### Risks / unknowns
- The new package may not expose a direct equivalent for stateful Silero VAD inputs (`h`, `c` hidden states) — verify it accepts arbitrary named inputs of arbitrary shape.
- Async conversion of the per-frame inference loop adds event-loop overhead. Should still be well under real-time (current sync call is ~1 ms/frame). If latency regresses materially, look for the new package's batch/streaming inference helper.
- Existing comment at `recordings_manager.dart:473` documents a real Android `ForegroundServiceDidNotStartInTimeException` caused by FFI blocking. Confirm the new async API doesn't reintroduce it, particularly during cold session creation.