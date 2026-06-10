# Ideas

## ACTIVE

## Multi-select recordings: long-press → selection mode with Delete + Merge [medium] [Active]

Replace the current long-press-to-delete on a recording row with **long-press-to-enter-selection-mode**. Once in selection mode the user can tap rows to build a set, then act on the set via a contextual action bar: **Delete** (already trivially supported) or **Merge** (stitch N selected recordings into one continuous file, filling the inter-recording gaps with any ghost/raw audio that lives between them, silence only as a last resort).

The headline finding: **the merge audio logic already exists.** The draft-stitch pipeline in `recordings_manager.dart` already does exactly the gap-padding + ghost-splice + silence-fallback semantics we want — merge is mostly *repurposing* that machine to operate on two user-selected finalized recordings instead of "draft + following events." Estimated **~2–3 days** for a solid wav/ogg implementation with m4a gracefully disabled.

### What changes for the user
- **Long-press a recording** → enters selection mode (the row gets a checkbox/highlight) instead of immediately deleting.
- **Tap rows** to add/remove from the selection; a contextual app bar shows the count + a Delete icon and a Merge icon. Back / clear exits selection mode.
- **Delete icon** → deletes all selected recordings (wraps the existing list-delete).
- **Merge icon** → stitches the selected recordings (sorted by start time) into one recording:
  - Adds **gap padding** (silence) to account for the wall-clock gap between consecutive files.
  - Goes one step further: **processes any ghosts (discards) between the two recordings and appends that audio** into the merged file.
  - Also splices in any **uncut/"saved" raw bins** sitting in the gap window.
  - Only inserts **silence when there is genuinely no ghost recording and no saved bin** in between.

### Why merge is cheaper than it sounds — reuse the draft-stitch pipeline
The exact merge semantics described above already exist in the **draft-stitch pipeline** (`app/lib/services/recordings_manager.dart`):

- `_stitchDraftRecordings()` (~line 1676) walks events in time order (draft → intermediate ghosts → next audio), accumulating the inter-recording gap and deciding what to splice.
- `_stitchDiscard()` (~line 1858) re-decodes a ghost's `relativeBins` into a temp audio file of the same format and splices it in, **preceded by `gapMs` of silence** — i.e. "process the ghost and append it," exactly as specified.
- `_stitchSilence()` (~line 1927) is the no-ghost/no-bin silence fallback.
- `_performStitch` / `_stitchWav` (~2210) / `_stitchOgg` (~2158) concatenate audio; `_mergeMeta` rebuilds the `.meta` (totalSamples, durationMs, 200×u16 waveform, union of `relativeBins`) and **re-anchors marker EDLs** by the prefix's wall-clock duration (the marker offset-shift we'd otherwise have to invent ourselves — see the CLAUDE.md note "Markers re-anchored across stitched files have their offsets shifted by the prefix's wall-clock duration").

So a merge is essentially: *take this "draft + following events → one file" machine and point it at two (or N) user-selected finalized recordings.*

### The real work / risks
1. **New `mergeConversations(List<Conversation>)` in `RecordingsManager`** — sort selected by start time; for each adjacent pair compute the gap, gather discards **and uncut raw bins** in that time window, feed them through the existing stitch helpers; rebuild one merged `.meta`; delete the source recordings. The **"saved bin in the gap"** case (raw bins in `raw_segments/` that are neither part of a recording nor a ghost) is the one genuinely new bit — needs a time-window lookup over `raw_segments/{timerStart}/`, but it can reuse the bin→wav decode already living inside `_stitchDiscard` (`SimpleOpusDecoder` 16 kHz mono, inline-frame skipping). The existing pipeline only knew about "audio file" and "ghost" events; merge adds "bare bin in gap."

2. **Format is the one sharp edge.** The stitch helpers handle **`.wav` and `.ogg` only**; **`.m4a` is explicitly unsupported** (`recordings_manager.dart` ~line 2146: *"M4A stitching requires decode/re-encode which we can't do easily here"* — M4A can't be physically concatenated). The **default `audioSaveFormat` is `wav`** (`preferences.dart:109`), so the common case Just Works. If a user opted into `m4a`, merging needs an m4a→wav decode-stitch-(re-encode) path. **Recommendation: support wav/ogg, and disable/grey the Merge icon when any selected recording is `.m4a`** (cheap; the transcode path is +~1 day if we ever want it). There is already a WAV→M4A transcode path (`RecordingsManager.isTranscoding`) to model an m4a→wav decode on if needed.

3. **UI plumbing (selection mode).** Convert the `onLongPress` handlers (currently delete) to enter selection mode; add a selected-set to `RecordingsController`; checkbox/highlight on tiles; a contextual action bar with Delete + Merge. Touches:
   - `app/lib/pages/recordings/recordings_page.dart` (~line 398 — `onLongPress: () => _deleteConversation(conv)`; also the page scaffold for the contextual app bar)
   - `app/lib/pages/recordings/batch_card.dart` — `ConversationTile` (~line 184 `onLongPress: () => onDeleteConversation(conversation)`), and `MarkerSubEntry`
   - `app/lib/pages/recordings/marker_day_card.dart` — `MarkerTile` (~line 19/94)

### Delete is essentially free
`RecordingsController.deleteConversations(List<Conversation>)` (~line 1272) already exists and handles the full teardown: HeyPocket upload-key removal, `removeOmiSynced`, orphaned-session bin cleanup (so deleted recordings don't resurrect on next sync). The selection-mode Delete action just calls it with the selected list — no new audio/cleanup logic.

### Open questions to brainstorm before/while building
- **Markers (`MarkerConversation` / `MarkerSubEntry`) in selection mode** — are they selectable, mergeable, or selection-only-for-delete? They have their own `.edl` sidecars and `deleteMarkerConversation` path. Simplest first cut: selection mode applies to **recordings only**; markers keep their current long-press-to-delete (or are excluded from multiselect). Decide before wiring `MarkerSubEntry`/`MarkerTile`.
- **Non-adjacent / cross-day selection** — do we allow merging recordings from different day-batches, or constrain to same-day contiguous? The stitch helpers are time-driven and `_stitchBinIfPresent`/`_mergeMeta` already scan across day folders, so cross-day is mechanically possible, but the gap could be huge (hours of silence). Consider a sanity cap or a confirm dialog when the total inserted silence is large.
- **Merge confirmation / preview** — show the resulting duration (incl. inserted silence + spliced ghosts) before committing, since merge is destructive (deletes the sources).
- **Which timestamp/date the merged recording inherits** — earliest start time (keeps it anchored correctly in the day list). Filename `recording_{startMs}` from the earliest source.
- **Upload state after merge** — the merged recording is a new file with a fresh upload key; the sources' upload state is discarded. Confirm that's acceptable (it mirrors how draft-stitch already produces a fresh finalized file).

### Rough estimate
| Piece | Effort |
|---|---|
| Selection-mode state + UI (long-press → multiselect, contextual action bar, checkboxes) | ~half day |
| Delete-selected | trivial (wire to existing `deleteConversations`) |
| `mergeConversations` reusing stitch helpers (wav/ogg) | ~half–full day |
| Uncut-bin-in-gap handling + merged `.meta` / marker re-anchor verification | ~half day |
| m4a handling (block via greyed icon, or transcode) | small if blocked; +~1 day if transcoded |

**~2–3 days** for a solid wav/ogg implementation with m4a gracefully disabled.

### Suggested build order (de-risk first)
1. **Prototype `mergeConversations` against the existing stitch helpers** (the load-bearing risk). Confirm `_stitchWav`/`_stitchDiscard`/`_mergeMeta` generalize cleanly from "draft + next" to "two finalized files," including marker re-anchoring and the merged `.meta`. This de-risks the whole feature.
2. **Add the uncut-bin-in-gap lookup** (the one net-new audio bit).
3. **Build selection-mode UI** + wire Delete (free) and Merge.
4. **Decide markers + m4a policy** (grey the Merge icon for m4a / exclude markers from multiselect for v1).

### Relevant files
- `app/lib/services/recordings_manager.dart` — the stitch helpers to reuse (`_stitchDraftRecordings` ~1676, `_stitchDiscard` ~1858, `_stitchSilence` ~1927, `_performStitch`/`_stitchWav` ~2210/`_stitchOgg` ~2158, `_stitchBinIfPresent` ~2273, `_mergeMeta`), the `Conversation` model (~line 23, `relativeBins` ~43), `DiscardRecord` (~454), `MarkerConversation` (~481); new `mergeConversations` lives here.
- `app/lib/pages/recordings/recordings_controller.dart` — `deleteConversations` (~1272, reuse for Delete), `deleteConversation`/`deleteMarkerConversation`; add selection-set state + `mergeConversations` wiring + `reloadBatchesSilently`/`_loadBatches` after merge.
- `app/lib/pages/recordings/recordings_page.dart` — top-level long-press (~398) + page scaffold for the contextual selection app bar.
- `app/lib/pages/recordings/batch_card.dart` — `ConversationTile` (~184), `MarkerSubEntry` (~92), `GhostRow` (discards = ghosts, ~245); selection visuals.
- `app/lib/pages/recordings/marker_day_card.dart` — `MarkerTile` (~5).
- `app/lib/backend/preferences.dart` — `audioSaveFormat` (~101, default `wav`) gates the m4a-disable decision.

---

## DEFERRED

## VAD Native Batch Runner — iOS port (Android shipped) [major] [Deferred — no iOS hardware]

Speed up the post-sync **processing** phase (Opus-decode → Silero VAD split → AAC encode, run in a spawned isolate) by moving Silero's per-window inference loop native-side, collapsing the Dart↔native platform-channel round-trips. Pure performance — **bit-identical VAD output**, no accuracy risk. Full investigation in `NOTES.md` → "VAD perf: timing diagnostics".

**Status: shipped on Android (2026-06-10); iOS port remains deferred** — no iOS hardware to test the native half. iOS continues to run the per-window fallback unchanged (see "Android-first scope"). The Dart contract, the `_applyVadVerdict` extraction, and the two-pass `processSegmentFile` loop are all already in place, so the iOS work is purely additive (phase 3 in Staging below).

**Measured on Android (6-segment / ~4.9 MB / 28.5 s run, 2026-06-10):** batched Silero ran **~0.3 ms/window** (~20.3 k windows, ~6.1 s total VAD). That **beat this doc's own estimate by ~7×**: the projected "~2.1 ms/inf fixed and unreducible compute floor" and ~2× VAD speedup did not hold — the batched path is **~14× faster than the 4.2 ms/inf single-pass timing**, because the supposed compute floor was almost entirely per-call overhead (channel hop + per-call `session.run` setup/teardown + tensor alloc) that batching amortizes, not model dispatch. Net result: **~73 % off total processing** vs. the projected ~37 %. **Treat the ~2.1 ms floor below as falsified when sizing the iOS win — expect it to be much larger.**

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

### Staging — phases 1 & 2 shipped (Android); phase 3 (iOS) deferred
1. ✅ **Shipped — Android native:** the `VadBatchRunner.kt` channel + registration in `MainActivity` + the Dart wrapper (`Platform.isAndroid`-gated) + the ORT dep in `app/android/app/build.gradle` + the A/B flag. Verified channel loads + returns probs bit-identical to the per-window path.
2. ✅ **Shipped — shared Dart:** `_applyVadVerdict` extracted; the deferred-verdict two-pass refactor of `processSegmentFile` feeds the batch path. iOS/desktop/tests ride the single-pass branch through the same `_applyVadVerdict`, covered by `vad_audio_processor_test.dart` on CI.
3. ⏳ **Deferred — iOS (needs hardware):** `VadBatchRunner.swift` mirroring the Kotlin + `pod 'onnxruntime-objc', '1.22.0'` in `app/ios/Podfile` + registration in `AppDelegate`. Purely additive; no Dart changes. Mirror Kotlin↔Swift exactly; reference `FlutterOnnxruntimePlugin.swift` (`runInference`, session-options, tensor I/O).

### Relevant files
- `app/lib/services/vad_audio_processor.dart` — `_runVad` (the per-window path to keep as fallback), `processSegmentFile` (the single-pass loop to refactor), the new `_applyVadVerdict` extraction, `_vadContext` / `_cachedStateValue` / `_cachedSrValue` plumbing, `buildSileroSessionOptions` (reuse the XNNPACK+intraOp config native-side).
- `app/lib/services/recordings_manager.dart` — isolate session-creation site (~line 552); the processor is recreated per isolate run, so `init`/`dispose` the channel around the run there.
- `app/android/app/src/main/kotlin/com/omi/offline/` — new `VadBatchRunner.kt` (alongside `OmiBleForegroundService.kt`); register the channel in `MainActivity`.
- `app/android/app/build.gradle` — add `com.microsoft.onnxruntime:onnxruntime-android:1.22.0`.
- *(Phase 3 — iOS, deferred)* `app/ios/Runner/` — new `VadBatchRunner.swift`; register in `AppDelegate`. `app/ios/Podfile` — add `pod 'onnxruntime-objc', '1.22.0'`.
- Reference templates (read-only): `~/AppData/Local/Pub/Cache/hosted/pub.dev/flutter_onnxruntime-1.7.1/android/.../FlutterOnnxruntimePlugin.kt` (Kotlin, phase 1) + `ios/Classes/FlutterOnnxruntimePlugin.swift` (Swift, phase 3) — `runInference`, session-options, tensor I/O.

---

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
