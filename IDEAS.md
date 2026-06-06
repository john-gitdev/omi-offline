# Ideas

## ACTIVE

## VAD Native Batch Runner: collapse per-window Silero channel round-trips [major] [Active — Android first]

Speed up the post-sync **processing** phase (Opus-decode → Silero VAD split → AAC encode, run in a spawned isolate) by moving Silero's per-window inference loop native-side, collapsing the Dart↔native platform-channel round-trips. Pure performance — **bit-identical VAD output**, no accuracy risk. Full investigation in `NOTES.md` → "VAD perf: timing diagnostics". **Promoted from DEFERRED 2026-06-06 (thermal trigger — see "Why now" below). Shipping Android-only; iOS stays on the per-window fallback.**

### The optimization (what & why)
Silero runs once per 512-sample / 32 ms window — **~112,500 inferences per recorded hour** — and each `_runVad` (`vad_audio_processor.dart`) crosses the platform channel 3× on the critical path (`OrtValue.fromList` create + `session.run` + `asFlattenedList` read) plus 2 fire-and-forget disposes. On-device timing (2026-06-02):

```
create 0.84ms · run 2.75ms · read 0.62ms → ~4.2ms / inference
```

- **Channel ≈ 2.0 ms/inf** (create 0.84 + read 0.62 + run's own hop ~0.6) — fixed per-call round-trip latency. The 576-float input already uses StandardMessageCodec's typed-data fast path (`Float32List` → Kotlin `FloatArray`), so this is *call count*, not payload size. The only way to cut it is to make fewer calls.
- **Compute ≈ 2.1 ms/inf** — **fixed and unreducible** for this model on this runtime (dispatch-bound across ~800 tiny nodes; quantization structurally impossible; threads/XNNPACK flat — see NOTES "Compute half is dispatch-bound").

VAD inference is **~75 % of the processing run** (~126 s of a 165 s run). Batching the windows native-side removes the channel half → **~2× on VAD ≈ ~37 % off total processing** (165 s → ~105 s; proportionally larger on bigger backlogs). With N=64, channel crossings drop from ~340 k/hr to ~5 k/hr. The remaining floor is the ~2.1 ms native dispatch × N (the model still runs N times; only the Dart↔native hops collapse).

### Why now (promoted from deferred 2026-06-06)
Promoted off the back of a **thermal** complaint (device runs hot during processing) — which is exactly the "revisit if backlog grind becomes a real pain point" condition the deferral named, and the heat angle strengthens the case beyond the raw-speed framing:

- **~37 % less grind ≈ ~37 % less time dumping heat** and less time in the throttle regime. The 165 s sustained run is precisely where the CPU governor downclocks (see NOTES "Android CPU throttle spike").
- **Structurally kills the 0.18.2 channel-throttle spike.** `create`/`read` are pure platform-channel hops; screen-off scheduling ballooned `create` 0.64 → 9.55 ms mid-run. Collapsing ~340 k crossings/hr → ~5 k removes almost the entire surface that throttle bit. `PARTIAL_WAKE_LOCK` papered over it; the batch runner removes it.
- **Honest caveat:** this lowers *total* energy and runtime, not necessarily *peak* temperature — the compute half (~2.1 ms × N) is unchanged and pass-2 saturates the core *denser* (no channel-wait gaps interleaved). It finishes the heat sooner rather than running cooler at any instant. A clear win for "throttles and drags"; only indirect for "hot to the touch."
- **Every cheaper lever is spent:** per-inference compute is unreducible; pacing/yields just make an already-slow grind slower; NNAPI/CoreML offload loses on a recurrent LSTM (per-call delegation × 112 k + numeric drift that would shift split boundaries and break the re-stitch determinism invariant). The batch runner is the one remaining lever with zero accuracy risk.

### Android-first scope (no iOS hardware to test)
Ship Android-only; **iOS is a deliberate no-op that keeps running today's per-window path unchanged.** The existing fallback design makes this clean — an iOS build with no channel handler is just another "channel unavailable" case, the same bucket as desktop/web/tests.

- **No Swift, no Podfile change.** Skip `VadBatchRunner.swift`, skip `pod 'onnxruntime-objc'`, skip the `AppDelegate` registration. The ORT coordinate goes **only** into `app/android/app/build.gradle`. This roughly halves the cross-language surface vs. the original both-platforms plan.
- **Dart wrapper gates on platform.** Init `_available = Platform.isAndroid` and probe the channel; iOS never even attempts the call (catch `MissingPluginException` as belt-and-suspenders). iOS → per-window path, untouched. `flutter_onnxruntime` stays a dependency on **both** platforms for that fallback — we're *adding* an Android channel, not replacing the package.
- **Don't fork the load-bearing logic.** The pass-2 refactor of `processSegmentFile` is shared Dart and runs on iOS too, so extract the inline verdict application (silence-split / max-cap / marker-offset / high-water-trim) into one `_applyVadVerdict(prob, …)`. The single-pass path (iOS/desktop/tests) calls it inline after each `_runVad`; the two-pass path (Android) calls the **same** function in the replay loop. Only *when* probs are computed differs — the risky marker/trim logic has exactly one copy, so there's no chance of the two platforms drifting.
- **iOS is covered by host tests despite no device.** `vad_audio_processor_test.dart` runs the per-window path (no channel) on CI — i.e. exactly the iOS code path — so the `_applyVadVerdict` extraction is validated off-device. The Android-only native half is the part that needs the on-device APK + "Save Diagnostic Logs to File" loop.
- **Adding iOS later is purely additive:** write `VadBatchRunner.swift` mirroring the Kotlin, add the Podfile pod, register in `AppDelegate`. The Dart contract and the two-pass structure are already in place; no Dart changes needed.

### The trade-off (read before building)
The win **only cashes out as shorter post-sync grind on big backlogs.** It shortens the lag between "sync finished" and "recordings appear" (the `Processing recordings — ~N min of audio to process` notification). It never blocks recording (firmware writes to SD regardless), never blocks the UI thread, never blocks sync.

- **Invisible on frequent/incremental syncs** — a few minutes of audio already processes sub-perceptibly; 2× faster than "fast" is nothing felt.
- **Felt on backlogs** — the "didn't sync for a day → `~686 min of audio to process`" case is a genuinely long isolate grind, and ~37 % off it is real — plus the thermal payoff above.

Against that (Android-first): Kotlin + Dart + an ORT dependency in `app/android/app/build.gradle` only (iOS Swift/Podfile deferred), ~150 lines of native that can't be compile-tested off-device (validated only via the APK + "Save Diagnostic Logs to File" loop), plus the loop refactor below that touches load-bearing invariants.

### Architecture — self-contained app-side channel (not a package fork)
`flutter_onnxruntime`'s `run` is one-shot and won't thread recurrent LSTM state across a batch. Rather than fork/vendor the whole package (Kotlin + Swift + Linux/Windows/Web + permanent rebase tax), add a small purpose-built **`VadBatchRunner`** method channel in our own app module that owns its own `OrtSession` on `silero_vad.onnx` and keeps state / sr / context entirely native-side.

- Reuses the ORT native lib the package already pulls in — but that dep is `implementation`-scoped, so add the same coordinate to our own build: `com.microsoft.onnxruntime:onnxruntime-android:1.22.0` (`app/android/app/build.gradle`). *(iOS `onnxruntime-objc` `1.22.0` deferred until the Swift side is built.)*
- Cost: one extra ~2.3 MB model load, **only while a processing run is active** (init on processor start, dispose on finish).
- The existing per-window `_runVad` path **stays as the fallback** when the channel is unavailable (iOS, desktop/web, unit tests) and behind an A/B flag — so nothing regresses and it's measurable head-to-head.
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
The package's `FlutterOnnxruntimePlugin.kt` (`runInference` ~line 334) is the working Kotlin reference for: session-options build (XNNPACK probe), `OnnxTensor.createTensor(env, FloatBuffer.wrap(...), longShape)`, `session.run(...)`, unwrapping the `Optional[OnnxTensor]` output, and `tensor.floatBuffer.get(...)`. The method channel should use a background task queue so the batch never blocks the platform thread. *(The matching Swift reference, `FlutterOnnxruntimePlugin.swift`, is only needed when the iOS side is built later — mirror Kotlin↔Swift exactly at that point.)*

### The hard part — deferred-verdict refactor of `processSegmentFile`
Today the loop is **single-pass**: decode a frame → drain a 512-sample window → `_runVad` → use that prob *inline* to update `_silenceRunMs` / split / cap, interleaved with `FrameRef` accumulation. Batching delays the probs, so the loop must split into two passes **within each batch boundary**:

1. **Pass 1 — accumulate, decide nothing.** Walk frames, append `FrameRef`s, collect each completed 512-window into the batch buffer, record per-frame metadata (wall-clock, marker offsets), but make **no** split/cap decisions.
2. **Pass 2 — batch-infer, then replay verdicts in order.** One `runVadBatch` call, then iterate the N probs calling `_applyVadVerdict` (the extracted silence-split / max-cap / marker-offset / high-water-mark logic that runs inline today).

The **decision logic is unchanged** and lives in exactly one place (`_applyVadVerdict`, shared with the single-pass fallback path — see "Android-first scope"); the **control flow is not** — this is a genuine refactor of the core loop and must preserve the load-bearing invariants: marker `offsetAtMarkerMs` bookkeeping, trailing-silence-trim high-water marks (`_lastSpeechRefCount` / `_lastSpeechChunkMs`), and every state-reset → `_emitOrphanMarkers()` path (the two NOTES "Marker Pipeline Tripwires"). This is the riskiest slice and wants its own reviewed commit + a pass over `vad_audio_processor_test.dart`.

### Constraints / invariants to preserve
- **Batch only within a contiguous audio run.** Flush the batch (and call `runVadBatch(resetStateFirst: true)` on the next one) at every point the single-pass loop resets Silero state: session-end `0xFFFFFFFC`, gap / VAD-resume `0xFFFFFFFD`, inter-file splits, and EOF. A batched inference must never span a state reset. Audio runs are conversation-length, so N stays large enough for the win.
- **Context is native now.** Today Dart maintains `_vadContext` (trailing 64). Moving it native (the contract above) means the Dart-side `_vadContext` / `_cachedStateValue` / `_cachedSrValue` plumbing in `_runVad` is replaced by the channel for the batched path — but keep the per-window path intact for fallback.
- **Manual mode / AAD (`_session == null`)** never calls Silero (`isSpeech = true`); the batched path is only taken when a session would exist. Don't route AAD frames through the channel.

### Staging (Android-first — three commits)
1. **Safe, additive (Android native):** the `VadBatchRunner.kt` channel + registration in `MainActivity` + the Dart wrapper (`Platform.isAndroid`-gated) + the ORT dep in `app/android/app/build.gradle` + the A/B flag, with the per-window path still the default. Nothing uses the batch path yet → zero behavior change; verifies the channel loads + returns probs **bit-identical to the per-window path** on a sample bin.
2. **Risky (shared Dart):** extract `_applyVadVerdict`, then the deferred-verdict two-pass refactor of `processSegmentFile` that feeds the batch path behind the flag, with test updates. iOS/desktop/tests ride the single-pass branch through the same `_applyVadVerdict`, so they're covered by `vad_audio_processor_test.dart` on CI.
3. **Later — iOS (when hardware available):** `VadBatchRunner.swift` mirroring the Kotlin + `pod 'onnxruntime-objc', '1.22.0'` in `app/ios/Podfile` + registration in `AppDelegate`. Purely additive; no Dart changes.

### Relevant files
- `app/lib/services/vad_audio_processor.dart` — `_runVad` (the per-window path to keep as fallback), `processSegmentFile` (the single-pass loop to refactor), the new `_applyVadVerdict` extraction, `_vadContext` / `_cachedStateValue` / `_cachedSrValue` plumbing, `buildSileroSessionOptions` (reuse the XNNPACK+intraOp config native-side).
- `app/lib/services/recordings_manager.dart` — isolate session-creation site (~line 552); the processor is recreated per isolate run, so `init`/`dispose` the channel around the run there.
- `app/android/app/src/main/kotlin/com/omi/offline/` — new `VadBatchRunner.kt` (alongside `OmiBleForegroundService.kt`); register the channel in `MainActivity`.
- `app/android/app/build.gradle` — add `com.microsoft.onnxruntime:onnxruntime-android:1.22.0`.
- *(Phase 3 — iOS, deferred)* `app/ios/Runner/` — new `VadBatchRunner.swift`; register in `AppDelegate`. `app/ios/Podfile` — add `pod 'onnxruntime-objc', '1.22.0'`.
- Reference templates (read-only): `~/AppData/Local/Pub/Cache/hosted/pub.dev/flutter_onnxruntime-1.7.1/android/.../FlutterOnnxruntimePlugin.kt` (Kotlin, phase 1) + `ios/Classes/FlutterOnnxruntimePlugin.swift` (Swift, phase 3) — `runInference`, session-options, tensor I/O.

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
