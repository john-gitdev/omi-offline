# Ideas

## ACTIVE

## Multi-select recordings: long-press → selection mode with Delete + Merge [medium] [Active]

Replace the current long-press-to-delete on a recording row with **long-press-to-enter-selection-mode**. Once in selection mode the user can tap rows to build a set, then act on the set via a contextual action bar: **Delete** (already trivially supported) or **Merge** (combine N selected recordings into one continuous file).

**Merge is implemented as reprocess-from-bins, not file concatenation** (revised design — see history at the bottom of this entry). Merge gathers **the bins owned by the selected recordings** — the union of each recording's `relativeBins`, deduped and sorted by time — and **re-runs the decode pipeline with VAD off, no silence padding**, producing one fresh recording in the user's chosen format. It processes *only the selected recordings' own bins*, never a time-span, so un-selected recordings sitting between two selections are simply never touched (no absorb, no contiguity rule, their bins stay theirs). This depends on a new **Recording Retention** policy under which **bins are kept for the life of their recording** (default retention **7 days**): if a recording exists, its bins exist; when a recording is deleted, its bins are deleted with it. Because of that coupling there is no "bins expired" state, no greying out, and no fallback path — any recording you can see, you can merge.

### What changes for the user
- **Long-press a recording** → enters selection mode (the row gets a checkbox/highlight) instead of immediately deleting.
- **Tap rows** to add/remove from the selection; a contextual app bar shows the count + a Delete icon and a Merge icon. Back / clear exits selection mode.
- **Delete icon** → deletes all selected recordings (wraps the existing list-delete).
- **Merge icon** → re-derives one recording from the selected recordings' own bins (deduped, sorted by start time):
  - **VAD off**: every selected bin is decoded and kept — nothing is re-trimmed, and **no drafts, discards, or ghosts are emitted** (this is a pure re-derivation, not a sync pass).
  - **No silence padding**: bins are AAD-gated (firmware only writes to SD when audio is present), so the captured audio is simply concatenated in order. The merged file's duration is the *sum of the selected recordings' captured audio* — nothing from the gaps between them. Merging the morning's recordings yields the morning's audio back-to-back; if the user merges the whole day, so be it.
  - Output is encoded **once** in the user's `audioSaveFormat` (**m4a included** — see below).
  - Markers regenerate for free: button-tap markers are inline `0xFFFFFFFE` frames in the bin stream and `VadAudioProcessor` re-parses them on the decode pass, so the merged recording's `.edl` markers land at correct offsets by construction — no offset re-anchoring math.

### Why reprocess-from-bins is the right mechanism
Conceiving merge as **concatenation of finished files** is what created its sharp edges. Reprocessing from raw bins removes them:

- **Format-agnostic / solves m4a.** You can't byte-concatenate `.m4a` (the old blocker — `recordings_manager.dart` ~2146 *"M4A stitching requires decode/re-encode"*). Reprocess never concatenates encoded audio; it decodes Opus → PCM → encodes once, exactly like the normal pipeline, so the output is native m4a/wav/ogg with no transcode hack.
- **No `.meta` hand-rebuild.** The pipeline emits a correct `.meta` (totalSamples, durationMs, 200×u16 waveform, `relativeBins`) natively — no `_mergeMeta` reconstruction.
- **No marker re-anchoring.** Markers come back from the inline bin frames (above), so the fiddly "shift EDL offsets by prefix wall-clock duration" step is gone.
- **The mode mostly exists.** Manual mode *is* "VAD off, one continuous file" (`vadThreshold=65535`, `vadSplitSeconds=0`). Reprocess-merge is manual-mode semantics pointed at the selected bins: feed each bin to `VadAudioProcessor.processSegmentFile(File, DateTime, …)` with `silenceDurationToSplitMs` effectively infinite (never split) and VAD disabled. **Caveat (the real risk):** `processSegmentFile` is built to run a *sync pass* — it also emits drafts, discards/ghosts, and `delete_segments` of consumed bins, and it checkpoints. Merge wants none of those side effects (just "these bins → one file, leave the sources alone"). That likely means threading a real `reprocessOnly`/merge flag through the processor, not just flipping `vadSplitSeconds`. **Prototype this first** — if it fights the control flow, the estimate moves.

### Dependency: Recording Retention (bins live with their recording, default 7 days)
Reprocess needs the selected recordings' bins on disk, and the retention model guarantees it: **bins are owned by their recording.** Today bins are deleted at the conversation boundary (`delete_segments`, the central chokepoint in `vad_audio_processor.dart` — sites at ~666/765/808), keeping only ghosts; the change makes finalized recordings *retain* their source bins instead. The rules:

- **Recording exists ⇒ its bins exist; recording deleted ⇒ its bins deleted.** No separate bin GC racing against recordings, no orphaned bins, no "expired bins" state. Bin lifetime == recording lifetime.
- **New `Recording Retention` setting** (preference, default **7 days**) governs how long recordings — and their bins together — are kept; old recordings age out at the window. The user can extend it (e.g. 30 days) or choose **"Always keep."** Selecting Always-keep **pops a warning dialog** that recordings + raw bins will accumulate indefinitely and can consume a lot of space (storage is the user's call — we just warn).
- **Stop the boundary delete; retain bins under the finalized recording.** Convert the `delete_segments` consumers from "delete consumed bins now" to "hand the consumed bins to the finalized recording" (track them in the recording's `relativeBins` / a per-recording bin folder). Deletion then happens only via `deleteConversations` and the retention age-out — both of which delete the recording and its bins together.
- **Disk cost** scales with the window and isn't a blocker (user owns the tradeoff). Memory has encoded ingest at ~5,100 B/s (~440 MB/day continuous, far less AAD-gated); 7 days is a modest default, Always-keep grows without bound (hence the warning).

### The real work / risks
1. **Recording Retention + bin ownership** — the enabling dependency. New preference; convert the `delete_segments` consumers from immediate-delete to "retain under the finalized recording"; age-out old recordings+bins at the window (guarded by the existing sync `Mutex` so it can't race draft re-stitch / a resuming sync; honor `discardProtectedPaths`).
2. **New `mergeConversations(List<Conversation>)` in `RecordingsManager`** — collect the union of the selected recordings' `relativeBins`, **dedupe** (a bin straddling a VAD boundary can appear in two recordings' lists), sort by time; feed them through `processSegmentFile` with VAD off / split disabled and side-effects suppressed; write one fresh recording (+ `.meta`, regenerated `.edl` markers); delete the source recordings and re-home their bins under the new merged recording (so the merged recording owns its bins and stays mergeable/reprocessable itself).
3. **Selection is bin-exact, not span-based.** Because merge processes only the selected recordings' own bins, un-selected recordings between them are never pulled in — no absorb-vs-contiguous decision, no "hole in the span" case. The only edge is the **boundary-straddling bin**: if a single ~5-min bin was split by VAD across recording A (tail) and B (start), merging just A reprocesses that whole bin and includes a sliver of B's audio at the seam. Minor over-inclusion; acceptable, or trim at the known VAD offset if it ever matters.
4. **VAD-off + no-side-effects knob.** Confirm `processSegmentFile` can be driven in a true pass-through (no re-trim) mode that also suppresses draft/discard/ghost emission and source-bin deletion (see the caveat under "The mode mostly exists"). The merged output keeps the selected bins' audio verbatim — the intended "faithful" behavior.
5. **UI plumbing (selection mode).** Convert the `onLongPress` handlers (currently delete) to enter selection mode; add a selected-set to `RecordingsController`; checkbox/highlight on tiles; a contextual action bar with Delete + Merge. Touches:
   - `app/lib/pages/recordings/recordings_page.dart` (~line 398 — `onLongPress: () => _deleteConversation(conv)`; also the page scaffold for the contextual app bar)
   - `app/lib/pages/recordings/batch_card.dart` — `ConversationTile` (~line 184 `onLongPress: () => onDeleteConversation(conversation)`), and `MarkerSubEntry`
   - `app/lib/pages/recordings/marker_day_card.dart` — `MarkerTile` (~line 19/94)

### Delete is essentially free
`RecordingsController.deleteConversations(List<Conversation>)` (~line 1272) already exists and handles the full teardown: HeyPocket upload-key removal, `removeOmiSynced`, orphaned-session bin cleanup (so deleted recordings don't resurrect on next sync). The selection-mode Delete action just calls it with the selected list — no new audio/cleanup logic. **With the retention coupling, delete also deletes the recording's owned bins** (recording deleted ⇒ bins deleted) — verify `deleteConversations` purges the recording's `relativeBins`, not just the recording file/meta, so deleted audio leaves no orphaned bins behind.

### Open questions to brainstorm before/while building
- **7-day default is for new installs only.** Existing users are not migrated — on upgrade they keep their current behavior (effectively Always-keep), so no old audio is silently deleted. Only fresh installs default to 7 days. Implementation: seed `recordingRetentionDays` to Always-keep when the preference is absent *and* the app has existing data/an existing install marker; seed it to 7 only for a clean first run. (They can change it either way in settings afterward.)
- **Markers (`MarkerConversation` / `MarkerSubEntry`) in selection mode** — selectable, mergeable, or selection-only-for-delete? Simplest first cut: selection mode applies to **recordings only**; markers keep their current long-press-to-delete. (Reprocess regenerates markers anyway, so any button-tap markers inside the selected bins re-emit.)
- **Cross-day selection** — mechanically fine: it's just the union of two recordings' `relativeBins`, which can live in different day folders. With bin-exact selection there's no gap audio at all, so the old "huge silent gap" concern is fully moot. Still worth a duration preview.
- **Merge confirmation / preview** — show the resulting duration (sum of the selected recordings' captured audio) before committing, since merge is destructive (deletes the sources).
- **Which timestamp/date the merged recording inherits** — earliest start time. Filename `recording_{startMs}` from the earliest source.
- **Upload state after merge** — the merged recording is a new file with a fresh upload key; the sources' upload state is discarded (mirrors how draft-stitch already produces a fresh finalized file). If Omi Cloud is on, a fresh `recording_fs320_<ms>.bin` is written for the merged result.

### Rough estimate
| Piece | Effort |
|---|---|
| Recording Retention: bins owned by recording (flip `delete_segments` → retain under finalized recording) + age-out old recordings+bins at window, under sync Mutex. **Cross-cutting** — audit every bin-deletion site (WAL service, truncate-on-resume guard, orphaned-session cleanup, draft re-stitch), not just `delete_segments`. | ~1.5–2 days |
| `processSegmentFile` reprocess/merge mode — VAD off + suppress drafts/discards/ghosts + don't delete source bins (the real risk; prototype first) | ~1 day |
| Selection-mode state + UI (long-press → multiselect, contextual action bar, checkboxes) | ~half day |
| Delete-selected | trivial (wire to existing `deleteConversations`; verify it purges owned bins) |
| `mergeConversations` = gather + dedupe selected recordings' bins in order + reprocess + re-home bins under merged recording | ~1 day |

**~4–5 days.** Earlier "~2.5–3" under-counted the bin-ownership audit (cross-cutting) and the processor reprocess-mode flag (not a config flip). The merge logic itself is small; the dependencies are the cost.

### Suggested build order (de-risk first)
1. **Prototype the `processSegmentFile` reprocess mode** (highest risk) — drive it over a known set of bins with VAD off, splitting disabled, and side-effects suppressed (no draft/discard/ghost, no source-bin delete). Confirm it produces one clean file with a correct `.meta` + regenerated markers, in `audioSaveFormat` (**test m4a explicitly — the whole point**). If this fights the control flow, everything else waits.
2. **Recording Retention / bin ownership** with default 7 days (new installs only). Audit all bin-deletion sites; verify finalized recordings retain their bins, delete purges them, and old recordings+bins age out together. The load-bearing dependency.
3. **`mergeConversations`** — gather + dedupe a 2-recording selection's bins, reprocess, re-home bins under the merged recording, delete sources.
4. **Build selection-mode UI** + wire Delete (free) and Merge.
5. **Decide markers policy** (exclude from multiselect for v1).

### Relevant files
- `app/lib/services/vad_audio_processor.dart` — `processSegmentFile` (~529) is the reprocess entrypoint (needs a reprocess/merge mode: VAD off, split disabled, no draft/discard/ghost emission, no source-bin delete); `silenceDurationToSplitMs`/`vadSplitSeconds` (~57) controls splitting; `delete_segments` sends (~666/765/808) are the deletion chokepoint to convert from "delete consumed bins" to "retain under finalized recording"; `discardProtectedPaths` shows the protection pattern to reuse.
- `app/lib/services/recordings_manager.dart` — new `mergeConversations` lives here; the bin→PCM decode (`SimpleOpusDecoder` 16 kHz mono, inline-frame skipping); `Conversation` (~23, `relativeBins` ~43 — now the recording's owned-bin list), `DiscardRecord` (~454), `MarkerConversation` (~481). (The old draft-stitch helpers `_stitchWav`/`_stitchDiscard`/`_mergeMeta` etc. are **not** used by the reprocess path — reprocess goes through `VadAudioProcessor`, not file concatenation.)
- `app/lib/pages/recordings/recordings_controller.dart` — `deleteConversations` (~1272, reuse for Delete); add selection-set state + `mergeConversations` wiring + `reloadBatchesSilently`/`_loadBatches` after merge.
- `app/lib/pages/recordings/recordings_page.dart` — top-level long-press (~398) + page scaffold for the contextual selection app bar.
- `app/lib/pages/recordings/batch_card.dart` — `ConversationTile` (~184), `MarkerSubEntry` (~92), `GhostRow` (~245); selection visuals.
- `app/lib/pages/recordings/marker_day_card.dart` — `MarkerTile` (~5).
- `app/lib/backend/preferences.dart` — `audioSaveFormat` (~101, default `wav`) drives the merged output format; **new `recordingRetentionDays` (default 7)** lives here.

### Design history (why the pivot)
- **v1 (concatenation):** merge = repurpose the draft-stitch pipeline to splice finished files + ghosts, silence as last resort. Cheap (the machine exists) but had two sharp edges: `.m4a` can't be concatenated (greyed), and it only opportunistically found raw bins in gaps because bins were reaped at the conversation boundary.
- **v2 (reprocess, current):** retain bins under their recording via Recording Retention, then merge by reprocessing the selection's bins with VAD off. This dissolves the m4a edge (encode-once, any format), regenerates markers for free, drops `_mergeMeta`, and produces a faithful lossless result — at the cost of the retention dependency (which the reprocess consumer now justifies). Bins are coupled to recordings (exist together, delete together), so there is no orphaned-bin state, no greying out, and no concatenation fallback — the v1 stitch path is dropped entirely.
- Earlier standalone "retain all bins" brainstorm concluded YAGNI *absent a consumer*; reprocess-merge is that consumer.

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
