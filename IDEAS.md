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

## VAD Native Batch Runner: collapse per-window Silero channel round-trips [major] [Deferred]

Speed up the post-sync **processing** phase (Opus-decode → Silero VAD split → AAC encode, run in a spawned isolate) by moving Silero's per-window inference loop native-side, collapsing the Dart↔native platform-channel round-trips. Pure performance — **bit-identical VAD output**, no accuracy risk. Full investigation in `NOTES.md` → "VAD perf: timing diagnostics".

### The optimization (what & why)
Silero runs once per 512-sample / 32 ms window — **~112,500 inferences per recorded hour** — and each `_runVad` (`vad_audio_processor.dart`) crosses the platform channel 3× on the critical path (`OrtValue.fromList` create + `session.run` + `asFlattenedList` read) plus 2 fire-and-forget disposes. On-device timing (2026-06-02):

```
create 0.84ms · run 2.75ms · read 0.62ms → ~4.2ms / inference
```

- **Channel ≈ 2.0 ms/inf** (create 0.84 + read 0.62 + run's own hop ~0.6) — fixed per-call round-trip latency. The 576-float input already uses StandardMessageCodec's typed-data fast path (`Float32List` → Kotlin `FloatArray`), so this is *call count*, not payload size. The only way to cut it is to make fewer calls.
- **Compute ≈ 2.1 ms/inf** — **fixed and unreducible** for this model on this runtime (dispatch-bound across ~800 tiny nodes; quantization structurally impossible; threads/XNNPACK flat — see NOTES "Compute half is dispatch-bound").

VAD inference is **~75 % of the processing run** (~126 s of a 165 s run). Batching the windows native-side removes the channel half → **~2× on VAD ≈ ~37 % off total processing** (165 s → ~105 s; proportionally larger on bigger backlogs). With N=64, channel crossings drop from ~340 k/hr to ~5 k/hr. The remaining floor is the ~2.1 ms native dispatch × N (the model still runs N times; only the Dart↔native hops collapse).

### The trade-off (read before building)
The win **only cashes out as shorter post-sync grind on big backlogs.** It shortens the lag between "sync finished" and "recordings appear" (the `Processing recordings — ~N min of audio to process` notification). It never blocks recording (firmware writes to SD regardless), never blocks the UI thread, never blocks sync.

- **Invisible on frequent/incremental syncs** — a few minutes of audio already processes sub-perceptibly; 2× faster than "fast" is nothing felt.
- **Felt on backlogs** — the "didn't sync for a day → `~686 min of audio to process`" case is a genuinely long isolate grind, and ~37 % off it is real.

Against that: a real cross-language commitment (Kotlin + Swift + Dart + an ORT dependency added to **both** the Android `build.gradle` and the iOS Podfile), ~300 lines of native that can't be compile-tested off-device (validated only via the APK + "Save Diagnostic Logs to File" loop), plus the loop refactor below that touches load-bearing invariants. **Build it only if backlog grind is a real pain point.**

### Architecture — self-contained app-side channel (not a package fork)
`flutter_onnxruntime`'s `run` is one-shot and won't thread recurrent LSTM state across a batch. Rather than fork/vendor the whole package (Kotlin + Swift + Linux/Windows/Web + permanent rebase tax), add a small purpose-built **`VadBatchRunner`** method channel in our own app module that owns its own `OrtSession` on `silero_vad.onnx` and keeps state / sr / context entirely native-side.

- Reuses the ORT native lib the package already pulls in — but that dep is `implementation`-scoped, so add the same coordinate to our own build: `com.microsoft.onnxruntime:onnxruntime-android:1.22.0` (app `build.gradle`) and `onnxruntime-objc` `1.22.0` (iOS Podfile / a Runner podspec dependency).
- Cost: one extra ~2.3 MB model load, **only while a processing run is active** (init on processor start, dispose on finish).
- The existing per-window `_runVad` path **stays as the fallback** when the channel is unavailable (desktop/web, unit tests) and behind an A/B flag — so nothing regresses and it's measurable head-to-head.
- The model is a Flutter asset; native can't read it by asset key easily. Dart materializes it once (copy `assets/models/silero_vad.onnx` bytes → a temp file) and passes the path to `init`.

### The native contract (one method does the loop)
```
init(modelPath: String)            // load OrtSession w/ XNNPACK+intraOp=1 options; alloc zero state + sr=16000 + 64-sample context
runVadBatch(samples: Float32List,  // N · 512 raw new samples (no context — native owns it)
            resetStateFirst: Bool) // true at a conversation boundary: zero LSTM state + clear context before running
   -> Float32List                  // N probs, in order
dispose()                          // close session, free state
```
Native `runVadBatch` loops N times: build `[context64 | window512]` (576) input tensor → `session.run({input, state, sr})` → read `output[0]` into `probs[i]` → adopt `stateN` as next `state` → set context = trailing 64 of this window. This mirrors today's `_runVad` exactly; the only change is the loop lives native-side and N probs come back in one response. **Do NOT register intermediate tensors in a long-lived map** (the package's `runInference` leaks every output into `ortValues` until released) — close each input/output tensor inside the loop; keep only the rolling `state`.

### Native implementation (template: the package's `runInference`)
The package's `FlutterOnnxruntimePlugin.kt` (`runInference` ~line 334) and `FlutterOnnxruntimePlugin.swift` are working references for: session-options build (XNNPACK probe), `OnnxTensor.createTensor(env, FloatBuffer.wrap(...), longShape)`, `session.run(...)`, unwrapping the `Optional[OnnxTensor]` output, and `tensor.floatBuffer.get(...)`. Mirror Kotlin↔Swift exactly. The method channel should use a background task queue (the package uses `makeBackgroundTaskQueue()`) so the batch never blocks the platform thread.

### The hard part — deferred-verdict refactor of `processSegmentFile`
Today the loop is **single-pass**: decode a frame → drain a 512-sample window → `_runVad` → use that prob *inline* to update `_silenceRunMs` / split / cap, interleaved with `FrameRef` accumulation. Batching delays the probs, so the loop must split into two passes **within each batch boundary**:

1. **Pass 1 — accumulate, decide nothing.** Walk frames, append `FrameRef`s, collect each completed 512-window into the batch buffer, record per-frame metadata (wall-clock, marker offsets), but make **no** split/cap decisions.
2. **Pass 2 — batch-infer, then replay verdicts in order.** One `runVadBatch` call, then iterate the N probs applying the exact silence-split / max-cap / marker-offset / high-water-mark logic that runs inline today.

The **decision logic is unchanged**; the **control flow is not** — this is a genuine refactor of the core loop and must preserve the load-bearing invariants: marker `offsetAtMarkerMs` bookkeeping, trailing-silence-trim high-water marks (`_lastSpeechRefCount` / `_lastSpeechChunkMs`), and every state-reset → `_emitOrphanMarkers()` path (the two NOTES "Marker Pipeline Tripwires"). This is the riskiest slice and wants its own reviewed commit + a pass over `vad_audio_processor_test.dart`.

### Constraints / invariants to preserve
- **Batch only within a contiguous audio run.** Flush the batch (and call `runVadBatch(resetStateFirst: true)` on the next one) at every point the single-pass loop resets Silero state: session-end `0xFFFFFFFC`, gap / VAD-resume `0xFFFFFFFD`, inter-file splits, and EOF. A batched inference must never span a state reset. Audio runs are conversation-length, so N stays large enough for the win.
- **Context is native now.** Today Dart maintains `_vadContext` (trailing 64). Moving it native (the contract above) means the Dart-side `_vadContext` / `_cachedStateValue` / `_cachedSrValue` plumbing in `_runVad` is replaced by the channel for the batched path — but keep the per-window path intact for fallback.
- **Manual mode / AAD (`_session == null`)** never calls Silero (`isSpeech = true`); the batched path is only taken when a session would exist. Don't route AAD frames through the channel.

### Staging (two commits)
1. **Safe, additive:** the `VadBatchRunner` native channel (Kotlin + Swift) + Dart wrapper + the ORT deps + the A/B flag, with the per-window path still the default. Nothing uses the batch path yet → zero behavior change; verifies the channel loads + returns correct probs against the per-window path on a sample bin.
2. **Risky:** the deferred-verdict refactor of `processSegmentFile` that actually feeds the batch path, behind the flag, with test updates.

### Relevant files
- `app/lib/services/vad_audio_processor.dart` — `_runVad` (the per-window path to keep as fallback), `processSegmentFile` (the single-pass loop to refactor), `_vadContext` / `_cachedStateValue` / `_cachedSrValue` plumbing, `buildSileroSessionOptions` (reuse the XNNPACK+intraOp config native-side).
- `app/lib/services/recordings_manager.dart` — isolate session-creation site (~line 552); the processor is recreated per isolate run, so `init`/`dispose` the channel around the run there.
- `app/android/app/src/main/kotlin/com/omi/offline/` — new `VadBatchRunner.kt` (alongside `OmiBleForegroundService.kt`); register the channel in `MainActivity`.
- `app/android/app/build.gradle` — add `com.microsoft.onnxruntime:onnxruntime-android:1.22.0`.
- `app/ios/Runner/` — new `VadBatchRunner.swift`; register in `AppDelegate`. `app/ios/Podfile` — add `pod 'onnxruntime-objc', '1.22.0'`.
- Reference templates (read-only): `~/AppData/Local/Pub/Cache/hosted/pub.dev/flutter_onnxruntime-1.7.1/android/.../FlutterOnnxruntimePlugin.kt` + `ios/Classes/FlutterOnnxruntimePlugin.swift` (`runInference`, session-options, tensor I/O).

### Why deferred
The payoff is **backlog-only** (above) — invisible to a user who syncs frequently — and the cost is a cross-language surface (new ORT dependency on both platforms + a refactor of the core VAD loop that can only be validated on-device). The compute half is already proven unreducible, so this is the *last* VAD-perf lever, not a stepping stone. Revisit if the post-sync processing grind on large backlogs becomes a real complaint. The cheap, reversible session-options win (XNNPACK + thread pinning) already shipped in 0.16.x.

