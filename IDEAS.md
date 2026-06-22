# Ideas

## ACTIVE

## Multi-select recordings: Merge selected into one file [medium] [Designed — prototype was buggy; re-brainstorming, not on main]

> **STATUS (2026-06-22):** A full merge feature was prototyped on branch `claude/merge-plan-analysis-f5ysc8` (local app `0.25.6`) — `keepBinsForMerge` retention, `mergeConversations`, the `padInterFileGaps`/`splitOnSessionChange` flags, the merge badge, merged-recordings-skip-auto-upload, and the source-audio storage readout. **That branch is being discarded: the implementation has whole-bin-ownership correctness bugs (below) and is NOT on main.** This entry preserves the analysis so the merge logic + location can be re-brainstormed and reimplemented cleanly.
>
> **Build on what already landed:** sub-bin **byte-range ownership** has since shipped on main for **Recover Discard** (PR #322, app 0.25.5) — but via a **separate `binRanges` field** on the discard record (`{rel: [startByte, endByte]}`), *not* the `relativeBins@start-end` path format proposed in "Corrected design" below. The separate-field approach was chosen for lower blast radius (every path-keyed consumer — prune/protect/sweep — stays untouched). `processSegmentFile` already accepts `startByte`/`endByte` and anchors a mid-bin start, and `processAll` threads a per-segment `RecoverSlice`. **The merge redesign should reuse that proven mechanism** rather than re-deriving the `@start-end` path format.

### Bugs found in testing — the whole-bin-ownership failure
Ownership is tracked at **whole-bin granularity** (`relativeBins` = a list of `<folder>/<file>.bin`). The firmware writes ~5-min bins, and a recording boundary (silence split) routinely falls **mid-bin**, so one bin is owned by **two** recordings (A owns the head, B owns the tail). That single fact causes every symptom seen:
- **Overlapping recordings.** With `keepBinsForMerge` ON, `pruneConsumedBins` is disabled (bins retained), so the *only* defense against reprocessing a consumed bin is `coveredBinPaths`. A straddle bin is partly A's, partly B's; neither geometric coverage (duration-based — misses the byte tail) nor exact membership (`finalizedConsumedRelBins`, which **excludes drafts**) covers it fully → it gets reprocessed into a **second, overlapping** recording every pass. Observed: 40–62 min recordings overlapping by minutes (device log 2026-06-21).
- **No merge badge / "cannot merge".** `_mergeMeta` (recordings_manager.dart:1579) rebuilds a stitched draft's `.meta` from the **draft's bytes only** — it never unions the *next* recording's `relativeBins`. The stitched-in bins become **orphaned** (owned by no recording) → `hasAllBins` fails → badge off, merge guard rejects.
- **Merge over-inclusion (the sliver).** Even with clean ownership, merging A reprocesses the **whole** straddle bin → pulls in B's sliver at the seam.
- **Separate upstream cause of the junk/giant recordings:** a transient **Silero VAD load failure → silent AAD fallback** ("every frame is speech", no on-phone silence split) produced the giant recordings and an earlier **3482× 0 s** flood. Device-specific / one-off (model normally fine), but the **silent** fallback + a missing **min-duration floor** at vad_audio_processor.dart:907 (the AAD resume-split save has no duration floor) let one VAD blip cascade. Fix = surface the fallback + floor the AAD save path; don't chase the model.

### Corrected design: sub-bin range ownership (track the split point inside the bin)
Make ownership **exact at sub-bin granularity**. When VAD cuts a bin mid-stream at byte offset `K`, **A owns `bin[0..K)`** and **B owns `bin[K..end)`** — every byte of every bin is owned by exactly one recording, so there is no straddle to mis-cover or over-merge. Chosen **logical ranges** over physically splitting the file: bins stay **immutable** (they are WAL-tracked / resumable — rewriting them mid-pipeline is its own bug class) and there is no per-boundary I/O amplification.

- **`relativeBins` entry format:** `"<folder>/<file>.bin"` (whole bin — unchanged, backward-compatible) OR `"<folder>/<file>.bin@<startByte>-<endByte>"` (partial). Absent range ⇒ whole bin.
- **`_binsOf` (vad_audio_processor.dart:~1483) emits ranges:** for each bin, the span `[min(byteOffset), max(byteOffset+frameLength))` over the FrameRefs that recording used. The split offset is **free** — it's exactly where A's last frame ends and B's first begins (`FrameRef.byteOffset`).
- **Coverage = interval-union per bin** (replaces geometric + exact-membership): a bin byte range is covered iff some recording's/draft's range covers it. A's `[0..K)` + B's `[K..end)` = fully covered → never reprocessed → **no overlap**. If only A exists yet, `[K..end)` is *uncovered* → processed into the next recording → **no loss** (this is the straddle-tail case raised in review).
- **Merge reads ranges:** the reprocess input becomes `(file, startByte, endByte)` instead of a bare `File`; the processor decodes only the owned span → merging A pulls **none** of B → exact, non-overlapping merge ("merge from the middle of a bin").
- **`processSegmentFile` gains start/stop byte offsets** (it's already offset-based internally, so this is an extension not a rewrite) + correct timestamp anchoring for a mid-bin start (anchor = segment start + the duration of frames before `startByte`). **DONE on main** for Recover Discard (PR #322): `processSegmentFile(..., startByte, endByte)` decodes only the slice and uses the caller's anchor for a mid-bin start.
- **This replaces the coverage / `_mergeMeta` band-aids** — with exact ranges there is no straddle to mis-cover or to drop during stitching, so `finalizedConsumedRelBins`-includes-drafts and `_mergeMeta`-union become moot.

> **NB (post-#322):** prefer a **separate `binRanges` field** over the `relativeBins@start-end` path format below — see the STATUS note up top. The decode-time slicing (`processSegmentFile` byte offsets, `RecoverSlice` plumbing through `processAll`) already exists and is tested; the merge work that remains is range **capture for finalized recordings** + **interval-union coverage**, not the slicer.

### Implementation order (test-first)
1. **Regression tests** reproducing, against the *current* model: (a) a straddle bin reprocessed into an overlapping recording with `keepBinsForMerge` ON; (b) `_mergeMeta` dropping the next file's bins; (c) merge pulling a neighbour's sliver. Unit-testable via `coveredBinPaths` / `relativeBins`; the full pipeline needs the isolate.
2. `relativeBins@start-end` **write** (`_binsOf`) + **parse** (`Conversation.fromFile`), backward-compatible (no range = whole bin).
3. **Interval-union `coveredBinPaths`** (and include drafts).
4. `_mergeMeta` **union of ranges** across stitch.
5. `processSegmentFile` **byte-range support** + `mergeConversations` passing ranges.
6. **Gate `keepBinsForMerge` OFF / manual-only** until the above lands (it currently corrupts the Automatic-mode pipeline).

### Original design notes (context — the retention mechanism, still valid)

The selection-mode shell already ships: long-press a recording (or ghost) enters selection mode, tap rows to build a set, and a contextual action bar offers **Delete**, **Export**, and **Recover** (`recordings_page.dart` — `_enterSelection`/`_toggleSelection`/`_buildSelectionBar`, wired through `batch_card.dart`). The remaining piece is a **Merge** action: combine N selected recordings into one file by re-running the decode pipeline over the union of their raw bins with VAD off.

**Merge is reprocess-from-bins, not file concatenation.** Merge gathers **the raw bins owned by the selected recordings** — the union of each recording's source bins, deduped and sorted by time — and **re-runs the decode pipeline with VAD off and inter-file gap-padding off**, producing **exactly one** fresh recording in the user's chosen format. It processes *only the selected recordings' own bins*, never a time-span, so un-selected recordings sitting between two selections are never reprocessed (their bins stay theirs).

**Intended behavior (confirmed with the user):** the selected recordings' audio is **butted together with no silence inserted between them** — gaps and reboots are collapsed, not padded. Consequently the **merged file length ≈ the sum of captured audio, which is ≤ the wall-clock span** (any real silence recorded *inside* the bins remains). The result surfaces as **one entry labeled "Merged — [begin] — [end]"**, where `[begin]` is the earliest source's start and `[end]` is the latest source's wall-clock end; the playback **duration is shorter than `[end] − [begin]`** whenever gaps were collapsed. Two override flags make this true regardless of input (see "Single-entry, no-pad" below): without them the existing reprocess path pads gaps with silence and splits on device reboots.

### Why reprocess-from-bins is the right mechanism
Conceiving merge as **concatenation of finished files** is what created its sharp edges; reprocessing from raw bins removes them:

- **Format-agnostic / solves m4a.** You can't byte-concatenate `.m4a`. Reprocess decodes Opus → PCM → encodes once, exactly like the normal pipeline, so the output is native m4a/wav/ogg with no transcode hack.
- **No `.meta` hand-rebuild.** The pipeline emits a correct `.meta` (totalSamples, durationMs, 200×u16 waveform, sessionId, bin list) natively.
- **No marker re-anchoring.** Button-tap markers are inline `0xFFFFFFFE` frames in the bin stream and `VadAudioProcessor` re-parses them on the decode pass, so the merged recording's `.edl` markers land at correct offsets by construction.

**The reprocess mode already exists and is verified.** `RecordingsController.recoverDiscard` (`recordings_controller.dart:1363`) drives `RecordingsManager.processAll` over a `syntheticBatch` of bins with a `ProcessingSettings` override — `vadEnabled: false`, `silenceDurationToSplitMs: 0x7FFFFFFF`, `maxChunkMs: 0x7FFFFFFFFFFFFFFF`, `omiEnabled: false`, `audioSaveFormat: _prefs.audioSaveFormat` — and produces one continuous file with a correct `.meta` and regenerated markers. Merge is that same call pointed at the union of the selected recordings' bins, **plus the two new override flags** (`padInterFileGaps: false`, `splitOnSessionChange: false`) that the discard-recovery path does not need.

### Verified mechanics (researched against the current code)
These determine exactly what "one file" means and where the edges are:

- **`relativeBins` already exists — it *is* the per-recording bin list.** `Conversation` (`recordings_models.dart:28`) parses `relativeBins` from the `.meta` sidecar (written by `_saveRecording`; format `"<folderName>/<file>.bin"` relative to `raw_segments/`). **No new "folder per recording" or model field is needed** — ownership is already recorded; the *only* missing piece is that the bins are physically deleted. This materially shrinks the bin-ownership task versus the original write-up.
- **`processAll` does NOT internally skip covered bins — the caller picks the bins.** It processes exactly the `rawSegments` of the `Batch` it's handed (`recordings_manager.dart:500-537`). So `mergeConversations` builds a synthetic `Batch` from the resolved union and that's the entire input set — unselected bins are structurally excluded.
- **The split predicate splits on session change even with VAD off — merge must suppress it.** The predicate (`vad_audio_processor.dart:588`) is `(sessionChanged && !imuGapMatches) || (gapMs > silenceDurationToSplitMs − 10s && !isClockJump)`. The override neutralizes the gap term, **but `sessionChanged` still splits.** `device_session_id` is a random u32 fixed once per **boot** (`transport.c:1484`, `ensure_device_session_id`), so it only changes across a **device reboot** — but to honor "exactly one entry" merge must NOT split there. ⇒ Add a `splitOnSessionChange` flag (default `true`; merge passes `false`) gating the `sessionChanged` term so a reboot-spanning selection still collapses into one file.
- **Inter-file gaps ≥10 s are padded with silence — merge must suppress that too (`vad_audio_processor.dart:617-622`).** Today the stitch branch unconditionally does `_currentRefs.add(Duration(milliseconds: gapMs))` for any non-clock-jump gap ≥10 s. That is the *opposite* of the intended "no space between them." ⇒ Add a `padInterFileGaps` flag (default `true`; merge passes `false`) gating that branch so gaps are skipped, not filled. With padding off, the audio butts together and the merged **duration = sum of captured audio (≤ span)**, exactly the user's model. (Manual mode — the default — records contiguously, so the only collapsed gaps are the real time *between* selected recordings; auto-mode AAD-pause gaps inside a recording also collapse, which is consistent with "no inserted silence.")
- **Retained bins are skipped on the next sync via `coveredBinPaths` — but that filter is *geometric*, not exact.** The normal pipeline filters with `_isProcessableBin(f, discarded, covered)` (`recordings_controller.dart:490,518,896`), and `coveredBinPaths` (`recordings_manager.dart:2351`) builds time intervals with a 10-min left slack + `vadSplitSeconds` right slack. `pruneConsumedBins` already abandoned that geometric rule for **exact `relativeBins` membership** (`recordings_manager.dart:2422`) precisely because the slack mis-covered neighbours. ⇒ If we retain finalized bins and rely only on geometric coverage to suppress reprocessing, an edge bin could slip through and resurrect a duplicate. **Refinement (load-bearing): extend the skip filter to also exclude the exact union of every finalized recording's `relativeBins`**, mirroring `pruneConsumedBins`. This is the correctness keystone of bin retention.

### Bin ownership: precise deletion-site audit
`recoverDiscard` works because a discard's bins are still on disk. Finalized recordings have their consumed bins deleted. The bins live in `raw_segments/<timerStart>/<timerStart>_<sessionId>.bin`; retention = *stop deleting them*, the `.meta` `relativeBins` link already names them. The sites that delete finalized-consumed bins (all under the processing/sync `Mutex`):

1. **Producer:** `recordings_isolate_worker.dart` — `processor.consumeSafeToDeletePaths()` feeds the `delete_segments` IPC (`:169`, `:239/:268`, `:307/:311`). This is where "safe to delete" is computed.
2. **Consumer:** `recordings_manager.dart` `delete_segments` handler (`:747`) actually unlinks, honoring `discardProtectedPaths` (`:675`).
3. **Launch sweep:** `pruneConsumedBins` (`recordings_manager.dart:2422`) deletes `consumed − protected` on startup.

**Gate retention behind a flag and short-circuit all three** when enabled (keep deleting when off, so non-merge users are unaffected). **Leave these as-is** — they are not finalized-bin deletions:
- `deleteBinsForSessions` (`recordings_manager.dart:2490`) — orphaned-session cleanup; only fires when a session has *no* live recording (correct to keep, see merge ordering below).
- `discard_store.dart removeDiscardRecord(deleteBins:true)` (`:187`) — deletes *discard*-referenced bins. Edge case: a straddle bin owned by both a finalized recording and a discard could be dropped here; add finalized-owned bins to its protected set when retention is on.
- `sdcard_wal_sync.dart` truncate-on-resume (`:457`, `:678`) — trims partially re-fetched bytes of an **in-flight** download, never an owned bin. No change.

**Teardown (purge retained bins with their recording):** extend `RecordingsManager.deleteConversations` (`:2001`) to also delete each conversation's `relativeBins` from `raw_segments/` (then drop emptied session folders), and let `_enforceRetentionPolicy` (`recordings_controller.dart:1343`) inherit that automatically since it routes through `deleteConversations`. `_binPathsForConversations` (`:1563`) stays for the Omi upload bin; the raw-bin purge is the new sibling.

### Storage-cost decision (recommend gating, not always-on)
The original plan ties retention to `keepRecordingsDays` (`preferences.dart:141`) — **but its default is `-1` = always keep**, so naively retaining consumed bins would silently ~double on-disk audio (raw Opus bins kept alongside the encoded recording) **for every user, unbounded.** Recommendation: add a dedicated **`keepBinsForMerge` bool pref (default OFF)**; Merge is offered only when it's on (or the row is offered but prompts to enable it). Age-out still purges via the teardown above. This makes the disk cost an explicit opt-in rather than a default regression. (`keepRecordingsDays` continues to bound lifetime when a finite window is set.)

### Single-entry, no-pad: the two new processing flags
Both default to today's behavior so nothing else changes; only the merge call passes the non-default value.
- **`padInterFileGaps` (bool, default `true`)** — add to `ProcessingSettings` (`vad/vad_types.dart`, all-primitive so isolate-safe) and thread to the processor; gate the stitch-pad branch (`vad_audio_processor.dart:619-622`) on it. `false` ⇒ skip `_currentRefs.add(Duration(...))`, so gaps collapse instead of filling.
- **`splitOnSessionChange` (bool, default `true`)** — same plumbing; gate the `sessionChanged` term of the split predicate (`vad_audio_processor.dart:588-590`) on it. `false` ⇒ a reboot-spanning union stays one file. (Leave the `isClockJump`/timestamp recalibration intact — we still want correct frame timing; we just don't *cut*.)
- These are the *only* `ProcessingSettings` additions; `recoverDiscard` keeps both at their defaults (it wants the padded, session-split behavior).

### The remaining work
1. **Bin ownership** (load-bearing) —
   - Gate the three deletion sites (§audit 1–3) on `keepBinsForMerge`; when on, skip deletes for finalized-consumed bins.
   - Extend the VAD skip filter to exclude the **exact `relativeBins` union of finalized recordings** (not just geometric `coveredBinPaths`) so retained bins never reprocess into duplicates.
   - Extend `RecordingsManager.deleteConversations` to purge each conversation's `relativeBins` (+ empty-folder cleanup); confirm `_enforceRetentionPolicy` inherits it.
   - Protect finalized-owned bins in `discard_store.removeDiscardRecord`.
2. **Processing flags** — add `padInterFileGaps` + `splitOnSessionChange` to `ProcessingSettings` and gate the two `vad_audio_processor` branches (see above).
3. **`mergeConversations(List<Conversation>)`** (controller, mirrors `recoverDiscard`) —
   - Resolve the **union** of selected recordings' `relativeBins` to `raw_segments/<rel>` files, **dedupe** (a straddle bin appears in two lists), drop missing, **sort by filename** (timestamp order).
   - Build a synthetic `Batch` (date from earliest start) and call `processAll` with the VAD-off override **plus `padInterFileGaps: false`, `splitOnSessionChange: false`** so the result is exactly one gap-collapsed file.
   - **Record the label bookends.** The merged file's own duration can't reconstruct the latest source's wall-clock end (gaps were collapsed), so capture `mergedEndMs = max(source.endTime)` (and a `merged` flag) at merge time and persist it — simplest is a new tail field in the `.meta` sidecar (append after the existing bin-list block; `Conversation.fromFile` reads it back, defaulting to `startTime + duration` for non-merged recordings). `[begin]` = earliest `startTime` (already the filename).
   - **Ordering (critical):** process → `reloadBatchesSilently` (merged recording now live, same sessionId) → `deleteConversations(sources)`. Because the merged recording shares the sessionId, the orphan sweep in `deleteConversations` (`:1303-1314`) sees a live recording and does **not** wipe the shared raw bins. The merged output `recording_<earliestMs>` collides with the earliest source's filename (same start) and is overwritten in place by `moveTempFilesToLive` (`:463-465`) — **exclude the source whose `file.path` equals the merged path** from the delete step.
   - Fresh upload key by construction; sources' upload state discarded (mirrors draft-stitch). With `omiEnabled:false` in the override, no `recording_fs320` bin is written during merge — re-enable per the normal cloud path if Omi Cloud is on.
4. **Merge button + entry label** —
   - Add a Merge icon to `_buildSelectionBar` (`recordings_page.dart:208`), shown for `isRec` and **enabled when ≥2 selected**; confirm dialog (mirror `_deleteSelectedRecordings`, `:124`) showing the **bookend span "[begin] — [end]"** and the **actual (shorter) merged duration**; on confirm call `controller.mergeConversations(sel)` then exit selection.
   - Render the merged row as **"Merged — [begin] — [end]"** (using the stored `mergedEndMs`), with the playback duration as usual. A `merged` flag on `Conversation` drives the label; non-merged rows are unchanged.

### Open questions / accepted edges
- **No-pad collapses real gaps by design.** Merging non-adjacent recordings butts their audio together with no silence; the merged duration is the sum of captured audio, and the row's "[begin] — [end]" shows the true wall-clock bookends while playback is shorter. This is the confirmed intent, not an edge to warn about.
- **Auto-mode intra-recording silence also collapses.** With `padInterFileGaps:false`, AAD-pause gaps *inside* an auto-mode source are dropped too, so re-merging even a single such recording would be shorter than the original. Consistent with "no inserted silence," but note it differs from naive concatenation of the source m4a files.
- **`mergedEndMs` storage.** Recommend a `.meta` tail field (defaulting to `startTime + duration`); alternative is encoding both bookends in the filename. Meta keeps the filename pipeline-compatible.
- **Boundary-straddling bin.** Merging A (tail) when a bin straddles A/B reprocesses that whole bin, including a sliver of B at the seam. Minor over-inclusion; acceptable.
- **Inherited timestamp** — earliest start; `recording_{startMs}` derived natively from the earliest bin's `timerStart`.
- **Markers in selection mode** — first cut: Merge applies to recordings only; reprocess regenerates any button-tap markers inside the selected bins anyway.

### Rough estimate
| Piece | Effort |
|---|---|
| Bin ownership: `keepBinsForMerge` gate on 3 deletion sites + exact-membership skip filter + teardown purge in `deleteConversations` + discard-store protection | ~1.5–2 days |
| `padInterFileGaps` + `splitOnSessionChange` flags through `ProcessingSettings` → `vad_audio_processor` | ~half day |
| `mergeConversations` = resolve+dedupe `relativeBins` union, reprocess via the override (no-pad/no-session-split), `mergedEndMs` capture, ordered source teardown (collision-safe) | ~1 day |
| Merge button + confirm/preview ("[begin]—[end]" span + actual duration) + "Merged" row label | ~half day |

**~3–3.5 days.** The selection UI, delete-selected, the reprocess-VAD-off mechanism, and time-based retention all ship today; `relativeBins` already records ownership. The real cost is making bin *retention* correct (gate + exact-membership skip + teardown) — the load-bearing dependency — plus the two small processing flags and the merge logic on top.

### Relevant files
- `app/lib/models/recordings/recordings_models.dart` — `Conversation.relativeBins` (`:28`, parsed from `.meta`) is the existing per-recording bin list — the ownership record merge depends on; add `mergedEndMs`/`merged` parsed from the new `.meta` tail field for the row label.
- `app/lib/services/vad/vad_types.dart` — `ProcessingSettings` (`:17`); add `padInterFileGaps` + `splitOnSessionChange` (both default `true`).
- `app/lib/services/recordings_manager.dart` — `delete_segments` consumer (`:747`); `pruneConsumedBins` (`:2422`, exact-membership model to mirror); `coveredBinPaths`/`_buildMergedCoverageIntervals` (`:2351`/`:2306`, the geometric skip filter to extend); `deleteConversations` (`:2001`, add raw-bin purge); `deleteBinsForSessions` (`:2490`); `_saveRecording` (writes the `.meta` — add the `mergedEndMs` tail field); decode pipeline.
- `app/lib/services/recordings_isolate_worker.dart` — `consumeSafeToDeletePaths`/`delete_segments` producer (`:239`,`:268`,`:307`).
- `app/lib/services/vad_audio_processor.dart` — gate the `sessionChanged` split term (`:588-590`) on `splitOnSessionChange` and the inter-file gap padding (`:617-622`) on `padInterFileGaps`.
- `app/lib/pages/recordings/recordings_controller.dart` — `recoverDiscard` (`:1363`, the working VAD-off template) + its `ProcessingSettings` override (`:1389`); `_isProcessableBin` (`:869`) skip filter; `deleteConversations` (`:1292`, incl. orphan sweep `:1303`); `_enforceRetentionPolicy` (`:1343`); `_binPathsForConversations` (`:1563`); add `mergeConversations`.
- `app/lib/pages/recordings/recordings_page.dart` — `_buildSelectionBar` (`:208`) + `_deleteSelectedRecordings` (`:124`, the confirm-dialog template); add Merge icon + `mergeConversations` wiring.
- `app/lib/backend/preferences.dart` — add `keepBinsForMerge` (default OFF) to gate retention; `keepRecordingsDays` (`:141`) bounds lifetime; `audioSaveFormat` (`:104`) drives merged output format.
- `app/lib/services/discard_store.dart` — `removeDiscardRecord(deleteBins:true)` (`:187`); protect finalized-owned bins when retention is on.

---

## PENDING

## Unify Adjustment Mode and Keep Source Audio into one raw-bin retention [medium] [Pending]

Two parallel raw-bin archives now exist, and they overlap enough to confuse — and to **double on-disk audio when both are on**. Consolidate them into a single **"Keep Raw Audio"** retention with a reprocess *mode*, instead of two separate folders and two toggles in two settings pages.

### The overlap (and why they're NOT yet redundant)
Both keep raw Opus bins for reprocessing, but they differ on three axes that block a naive merge:

| | **Keep Source Audio for Merging** (`keepBinsForMerge`) | **Adjustment Mode** (`adjustmentMode`) |
|---|---|---|
| Mechanism | *Skips pruning* of the originals | *Copies* each bin at download time |
| Folder | `raw_segments/` (live) | `adjustment_mode_segments/` (isolated archive) |
| Reprocess type | Merge only — VAD **off**, collapse | Restore + full re-VAD with **new settings** (re-split) |
| Lifetime | Ages out with the recording; **purged on delete** | Persists until the toggle is turned off |
| Scope | Only bins a recording **owns** (`relativeBins`) | **Every** downloaded bin (complete archive) |
| Pipeline visibility | **Skipped** via exact-membership (`coveredBinPaths`) | Inert until explicitly copied back |

The blocker is the **exact-membership skip**: retained `raw_segments` bins are deliberately marked "covered" (`finalizedConsumedRelBins` in `coveredBinPaths`, `recordings_manager.dart`) so the pipeline won't reprocess them into duplicates. That is exactly what stops `keepBinsForMerge` from supporting adjustment mode's *re-tune* workflow — the bins are present but the pipeline ignores them, so changing VAD settings and re-syncing does nothing. Adjustment mode's separate, never-skipped archive exists precisely so it can be **copied back** (`_copyAdjustmentBinsForReprocessing`, `sync_page.dart:1013`) and re-VAD'd. And `keepBinsForMerge`'s age-out / purge-on-delete (`_purgeRetainedBins` in `deleteConversations`/`deleteDay`) means the bins you'd want to re-tune may already be gone.

### Target: one retention, two reprocess modes
Make `keepBinsForMerge` (rename → **Keep Raw Audio**) the single archive and give adjustment mode's *re-tune* capability a first-class action on it:

1. **"Reprocess with current VAD settings" action** — a controller path (sibling of `mergeConversations` / `recoverDiscard`) that reprocesses a recording's (or a day's) `relativeBins` with VAD **on** at the *current* settings, **bypassing the exact-membership skip** for the selected bins, and **atomically replaces** the old recordings with the new split. This is the re-tune workflow without the separate `adjustment_mode_segments` copy.
2. **Retention lifetime option** — a "permanent / don't age out" mode (or a per-recording pin) so re-tunable bins survive recording deletion, matching adjustment mode's keep-until-cleared semantics. Default still ages out (storage hygiene).
3. **(Optional) Full archive, not just owned bins** — to fully match adjustment mode, retention would also need to keep bins VAD dropped entirely (no recording, no discard). Decide whether that recovery is in scope or whether "owned + discarded" coverage is enough (usually it is).

Then **delete** the `adjustmentMode` pref, the download-time copy (`sdcard_wal_sync.dart:392,732`), `adjustment_mode_segments/`, the sync-page section, and the ADJ badge — folding `_isAdjustmentMode` and the new `_hasAllBins` merge badge into one "raw audio retained" indicator.

### Why bother
- **Halves storage** for anyone running both today (bins kept twice).
- **One mental model**: "your raw audio is kept — you can *merge* it (collapse) or *re-tune* it (re-split)" — instead of two overlapping toggles.
- Removes the per-bin `file.copy` from the sync hot path.

### Open questions / risks
- **The exact-membership-skip bypass is delicate.** Re-tune must reprocess → swap → delete-old atomically, or a half-run leaves duplicates — the same ordering hazard `mergeConversations` already navigates.
- **Dropped-silence recovery.** If retention only keeps owned+discarded bins, a re-tune can't recover audio VAD threw away entirely; adjustment mode's full archive can. If that matters, retention must keep *all* downloaded bins (bigger storage).
- **Migration.** Existing `adjustment_mode_segments/` archives on upgrade — copy into the unified archive or just drop them.

### Relevant files
- `app/lib/backend/preferences.dart` — `keepBinsForMerge` (→ Keep Raw Audio); `adjustmentMode`/`adjustmentModeEnabledAt` (`:42-47`, to remove).
- `app/lib/services/wals/sdcard_wal_sync.dart` — download-time adjustment copy (`:392`, `:732`) to delete.
- `app/lib/services/recordings_manager.dart` — `coveredBinPaths`/`finalizedConsumedRelBins` (the skip to bypass for re-tune), `hasAllBins`, `_purgeRetainedBins`, `deleteConversations`/`deleteDay` teardown.
- `app/lib/pages/recordings/recordings_controller.dart` — `mergeConversations`/`recoverDiscard` (templates for the reprocess-with-current-VAD action).
- `app/lib/pages/settings/sync_page.dart` — adjustment-mode section + `_copyAdjustmentBinsForReprocessing` (`:1013`) to fold in / remove.
- `app/lib/pages/recordings/batch_card.dart` — `_isAdjustmentMode` (`:212`) + the new `_hasAllBins` merge badge → unify into one indicator.

### Rough estimate
~2–3 days: the reprocess-with-current-VAD action (exact-membership bypass + atomic swap) is the bulk; the rest is removing the parallel system and migrating archives.

---

## Device-driven BLE wake (firmware + iOS) [large] [Pending]

Shift background-sync triggering from the *phone* (opportunistic iOS `BGTaskScheduler` / Android alarms) to the *device*: the Omi opens a connectable advertising **window** on its own RTC-driven schedule, and the phone — holding a standing pending-connect — is woken by the OS the moment that window opens. This is the model commercial BLE wearables (e.g. CGMs) use for reliable background sync on iOS.

### The honest framing (why)
The primary win is **iOS wake *reliability* + device-controlled (punctual) timing**, **not** device battery. The firmware already advertises *slow* (~1 s, `adv_param_slow` in `transport.c`) when idle, which is already cheap; going fully "dark" saves only a bit more. The real reason: a standing pending-connect lets iOS wake the app on the *device's* schedule, replacing the opportunistic `BGTaskScheduler` path (which iOS fires unpredictably and never punctually). The same mechanism *forces* the firmware change — a standing pending-connect pointed at a device that advertises connectably **continuously** (today's behavior) would reconnect → idle-drop → reconnect forever (churn). So the device must advertise connectably only in **windows it controls**. **Net: mostly an iOS project.** Android already wakes reliably (FGS + exact alarm + WorkManager) and needs little/no change.

### Second motivation: privacy / smaller attack surface (going dark)
For an *audio recorder*, the stealth of DARK is arguably as compelling as the iOS-wake win. Today the device advertises connectably 24/7 as "Omi" + service UUIDs, so it is:
- **Visible to any BLE scanner** — and continuously broadcasting *"someone here is wearing a recording device."*
- **Trackable** — a constant advertiser is a beacon a passive scanner can log and correlate across locations (AirTag-stalking vector).
- **Reachable** — any device can occupy its single connection slot (lock-out / DoS) or probe its GATT table.

DARK shrinks exposure from "always visible + reachable" to "brief periodic windows + button press." Precise scope of what this protects: **reachability/visibility, not data confidentiality** — the audio and encrypted characteristics are *already* bond/encryption-gated today, so DARK isn't adding data secrecy; it's removing the ability to *find, track, or connect to* the device, which is the basis of passive tracking and most targeted attacks.

**Inseparable coupling (same as the UX cost):** "others can't find/connect it while dark" is literally identical to "your own phone can't either, until a window or button." Your phone copes via the standing pending-connect catching scheduled windows (auto, no tap) + button for immediate connect; attackers only ever get the brief windows. You cannot have the stealth without the not-instantly-connectable.

**Cheap hardening that pairs with DARK:**
- **Resolvable Private Address (RPA).** If the firmware advertises a static/public BLE address, the device is still trackable *during* windows. A rotating RPA (bonded phone resolves it via the IRK; strangers can't) closes the window-time tracking gap. *Verify the current address type in firmware.*
- **Reject non-bonded connections fast** — *low value, likely skip.* The payoff is marginal: every meaningful characteristic is already `*_ENCRYPT`-gated (`storage.c`, `transport.c`, button-config, mute, accel), so a non-bonded peer can read *nothing* — confidentiality is already solved. The only real gain is connection-slot DoS, which is *already half-covered* by the 15 s idle-disconnect (`idle_disconnect_work_handler` drops an idle hogger in 15 s). Against that thin benefit it needs solid RPA resolution or it risks **false-rejecting your own iPhone** (rotating address). Net negative — the encryption perms do the security work. (If maximum window-time stealth is ever wanted, *directed* advertising aimed only at the bonded central is the cleaner lever than connection-level rejection.)

So DARK now carries two stacked upsides — **low-power + reliable iOS background wake**, *and* **a much smaller privacy/tracking/attack surface** — against the one cost (not instantly connectable on app open).

### Current state
- **Firmware (`transport.c`, `aad.c`):** idle-disconnects after 15 s of no storage GATT activity (`idle_disconnect_work_handler`, `IDLE_DISCONNECT_TIMEOUT_MS`), then reverts to advertising. Two **always-connectable** modes: fast (`BT_LE_ADV_CONN`) and slow (`adv_param_slow`), via `transport_set_adv_fast/slow()`. **AAD currently owns advertising cadence** (recording → fast `aad.c:310`, silence → slow `aad.c:330`). Conn params 7.5–22.5 ms, **latency 0** (`update_conn_params`); iOS recheck falls back to 15–30 ms. Audio records to SD **independent of BLE** — nothing lost while dark/disconnected.
- **iOS (`OmiBleManager.swift`, `device_provider.dart`):** state restoration *is* wired (`CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState` → `onStateRestored`), **but the aggressive disconnect neutralizes it**: `disconnectDevice(isManual:true)` (`device_provider.dart:884`, `:996`) → `disconnectPeripheral` adds to `manuallyDisconnected` + cancels the link, and `didDisconnectPeripheral` re-arms `connect()` *only if not manual*. Steady state = no pending connect = nothing for iOS to wake on.
- **Android (`OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`):** FGS (`FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`) + WorkManager periodic + `setExactAndAllowWhileIdle`; already uses `connectGatt(autoConnect=true)` as a pending-connect fallback. Reliable today.

### Target architecture
A device-side **sync-window state machine** replaces AAD's ownership of advertising:

```
        ┌──────────── DARK ────────────┐        no phone connects
        │ non-connectable / adv stopped │◄────── within window ───────┐
        │ radio mostly off; SD recording │                            │
        └──────────────┬────────────────┘                            │
   cooldown elapsed AND │ (cooldown = sync interval, pushed by app)   │
   has-unsynced data    ▼                                            │
        ┌──────── SYNC WINDOW ─────────┐    phone connects   ┌────────┴───────┐
        │ fast CONNECTABLE adv, ≤ W sec │─────────────────►  │   CONNECTED     │
        └───────────────────────────────┘                    │ sync; existing  │
                                                             │ 15 s idle-drop  │
                                                             └────────┬────────┘
                                                                      │ disconnect → DARK (restart cooldown)
```

Phone side: a **standing pending-connect is always armed** (iOS `connect()` + restoration; Android `autoConnect=true`). The device's cooldown = the sync cadence, punctual because the device's RTC drives it. **In `enabled=1` mode the app's own autosync timer goes dormant on *both* platforms** — there's exactly one schedule, owned by the device, so there's nothing for an app timer and a device timer to drift out of. The app's job shrinks to: hold the standing connect, re-push config on each connect, and sync on any device-initiated wake.

### Firmware changes (the enabling work)
1. **Dark state** — `transport_set_adv_dark()`: prefer **non-connectable** advertising (`BT_LE_ADV_NCONN`) so the device stays visible for diagnostics/UI but rejects CONNECT_IND (or fully `bt_le_adv_stop()` for lowest power). Track in `current_adv_mode`.
2. **Sync-window scheduler** (new `sync_window.c` or folded into `transport.c`, a `k_work_delayable`, driven by the **monotonic clock** so it's immune to time-sync state): DARK for `cooldown_ms` → open SYNC WINDOW (`transport_set_adv_fast()`). The window is a **connectability *ceiling*, not a broadcast duration** — fast-advertise up to `window_ms` (**45–60 s**; iOS background scan is duty-cycled and slow to notice adverts), but **stop advertising the moment a phone connects** (you only needed to be findable long enough to latch). Once connected, the existing `idle_disconnect_work` owns teardown, so a sync runs as long as data flows — far past `window_ms`. On `_transport_disconnected`, **schedule the next window as `now + cooldown` on the monotonic clock**: because it resets off the *last disconnect*, a manual button-sync automatically pushes the next scheduled window out by a full interval — the "manual sync moves the timer" behavior, free, no special handling. Window expiry with no connect → DARK, restart cooldown.
3. **Hand advertising ownership from AAD to the scheduler** — keep AAD's VAD/SD-pause logic; remove/gate its `adv_*_req` writes (`aad.c:310,330,464`, applied in the AAD loop `aad.c:247-250`). Most invasive *refactor*; regression-test VAD recording, SD pause/resume, marker durability.
4. **Gate windows on "has unsynced data"** — use "SD has stored files" as the proxy (app deletes via `CMD_DELETE_FILE`); SD empty → stay DARK until new audio is recorded.
5. **Config characteristic + user-facing "Dark Mode" toggle (default OFF)** — new char under Settings service (`0010`, e.g. `0014`): `interval_minutes(u16) + window_seconds(u8) + enabled(u8)` (+ optional `next_override_seconds(u16)` for app-side policy nudges), persisted via `settings.c`, range-validated, with a **compiled-in default** (`config.h`) as the floor for a never-configured device. Surfaces in the app as a single **Dark Mode** switch (writes `enabled=1`). **Cadence reuses the existing "Auto Sync Interval" dropdown** (`app_settings_page.dart`: 15/30/60 min / Manual Only) — no new cadence setting; the user's existing `backgroundSyncIntervalMinutes` drives the *device's* cooldown. **"Manual Only" (`-1`) maps to button-only wake** — firmware opens *no* scheduled windows, only the button window. The app **re-pushes config on every connect** (belt-and-suspenders: the device never holds stale config; the dropdown is the source of truth). Firmware default is `enabled=0` = today's always-connectable behavior (old apps and Android untouched). `enabled=1` activates DARK/window cycling. See "Cross-platform: why this is opt-in" below.
6. **Capability bit** — add `deviceDrivenSync` to the Features bitfield (`0021`, `OmiFeatures`) for mixed-version safety (new app + old fw → old timer path; old app + new fw → covered by #7).
7. **On-demand connectability + recovery floors (critical UX safeguard, see "Button-to-wake" below)** — button/motion triggers open a window immediately. Plus two recovery behaviors so the device can't strand itself:
   - **Boot:** on reboot, **advertise connectably (like `enabled=0`) until the phone connects and writes config at least once, then resume the persisted dark schedule** — re-anchoring `last_disconnect` to that fresh contact so there's no post-reboot blackout (the phone's standing pending-connect latches the moment the device advertises). **Cap the stay-open at ~15 min:** if the phone never shows (rebooted away from the phone), fall back to the persisted last-known config and resume dark scheduling so continuous advertising doesn't drain the 150 mAh cell.
   - **Liveness floor:** no successful sync for `> N` intervals → fall back to continuous connectable advertising so the device can't become permanently unreachable.
8. **(Alternative model) Held low-power connection** — instead of windowing, set **slave latency > 0** in `update_conn_params` + a "data ready" notify characteristic (the CGM model). Lower wake latency, simpler app logic, but the radio stays in-connection (more device power than DARK). Default to windowed for the 150 mAh budget; keep this in reserve.

### Button-to-wake (user-selectable, integrates with existing button mapping)
The on-demand trigger (#7) is a natural fit for the **already-shipped customizable button-mapping system** (`button_config_service` in firmware, `button_config_page.dart` in app — maps None/Mute/Marker/Toggle-LED to single/double/triple tap and their holds, synced over the encrypted value-validated button-config characteristic). Add a **new "Wake for Sync" action** to that action set:
- Firmware: on the mapped gesture, `button.c` kicks the sync-window scheduler straight to SYNC WINDOW (open a connectable window now), regardless of cooldown.
- App: expose "Wake for Sync" as a selectable action in `button_config_page.dart`; **default to single tap**, but user-customizable exactly like every other mapping (open to making it single tap out of the box or fully user-selectable — both are supported by the existing infra).
- Firmware must range-accept the new action value (the config char already rejects out-of-range actions — bump the accepted enum).
- UX: foreground "Sync now" prompts "tap your Omi to sync now" when the device is DARK between windows.

### Decoupling wake from sync (a connection is not a sync)
A device wake — scheduled window *or* button combo — only establishes a **connection**; the **app** then decides whether to pull data. Two clean concerns:
- **Device** = *make a connection possible*: open a window on its RTC cadence (config-char interval) + immediately on the button combo.
- **App** = *policy*: on each device-initiated connection, decide whether to sync.

The building block already exists: `_onStateRestored` runs `final due = _shouldSyncNow(); if (!due) return;` (`device_provider.dart:232`) — "connection arrived, skip if not due." Generalize into a setting:
- **"Sync on every device wake"** → always pull whenever the device wakes/connects.
- **"Only when due"** → gate on the autosync interval (`_shouldSyncNow()`); an early wake connects, finds nothing due, and disconnects without transferring.

**Recommended semantics:** a *scheduled* window honors the setting (default "only when due"); a *button combo* is explicit user intent → **force-sync** (always pull), since the user tapped precisely to sync now. Make force the button's natural behavior; optionally expose the choice.

**Telling the two apart on connect.** The app can't receive the button event *before* it connects (the tap is what wakes it), so the reason can't arrive over Button char `0041` in time. Add a **"last wake reason" byte the app reads on connect** (scheduled / button / motion) — a small new read char or folded into diagnostics `0061`; on `onDeviceReady` the app maps button ⇒ force-sync, scheduled ⇒ if-due. In `enabled=0`/always-connectable mode this is unneeded — the device never goes dark, so a button tap arrives live over `0041` while connected and force-syncs directly.

**Battery note:** align the device's window cadence with the app's autosync interval (push via the config char) so early "connect-then-skip" cycles are rare; the if-due check mainly backstops button taps and edge timing — a connect/disconnect with no transfer still costs a little device radio energy.

### iOS app changes (the real payoff)
1. **Standing pending-connect** — after routine sync/disconnect, **re-arm `centralManager.connect(peripheral, options:nil)`** instead of leaving it cancelled, so iOS holds it pending and wakes the app at the device's next window. Add a `standingConnect: Set<String>` alongside `manuallyDisconnected`; distinguish "Forget Device" (truly cancel) from "routine post-sync disconnect" (cancel link, re-arm pending connect). **Also re-arm on app launch** — a user force-quit drops the OS-held pending connect, so re-issuing `connect()` at startup (iOS: `retrievePeripherals(withIdentifiers:)` with the saved device ID; Android: `connectGatt(autoConnect=true)` with the saved address) restores the wait that force-quit destroyed. Note this only re-arms the wait — it can't connect a *dark* device until its next window or a button tap; for an immediate post-relaunch sync the user taps the button (or the staleness banner, #5).
2. **Routine disconnect ≠ terminal in Dart** — post-sync (`device_provider.dart:884`) and pause-grace (`:996`) map to a new "disconnect-but-stay-armed" path (`disconnectKeepingPendingConnect`), not `unmanageDevice`. Only true unpair calls full `unmanageDevice`/`disconnectPeripheral`.
3. **Wake → sync** — mostly there: the wake arrives as `didConnect` → `onDeviceReady` → `_handleDeviceConnected`; ensure the background drop-guard lets a device-initiated wake through (set pending-sync flag, as `_onBackgroundSyncRequested` does). `_onStateRestored` (`device_provider.dart:232`) already sanctions a due sync.
4. **Demote BGTaskScheduler to backstop** — keep the `BGProcessing`/`BGAppRefresh` tasks (shipped 0.25.4) as the fallback for when pending-connect misses (notably after **user force-quit** — iOS won't relaunch for BLE then).
5. **Foreground UX + staleness banner** — surface the button-to-wake affordance since the device may be DARK on app open. Add a **"haven't synced in a while — tap your Omi to sync" banner** that triggers after **N missed windows** (`now − lastSuccessfulSync ≥ N × interval`, with a floor so short intervals don't nag; suppressed in Manual-Only mode). It's the safety net for the irreducible cases — force-quit dropped the standing connect, or the device was out of range — proactively pointing the user at the button to realign instead of silently accumulating stale data. Tapping it re-arms the standing connect and prompts the physical tap. Generally useful even on `enabled=0`.

### Cross-platform: why windowing is opt-in (and Android keeps the status quo)
It's **one device** — the firmware can't be DARK for iOS yet always-connectable for Android at the same time; whichever phone is nearby sees the same advertising behavior. The two platforms want opposite things:
- **iOS** *gains* from DARK/window cycling (reliable background wake it otherwise lacks), and loses little on-demand connect (iOS has no good instant on-demand today anyway).
- **Android** *loses* from it: today the device is always connectable, so opening the app connects **instantly**, anytime. DARK between windows breaks that instant on-demand connect (you'd wait for the next window or tap Wake-for-Sync). Android is the platform with the *good* on-demand experience, so it has the most to lose — and it doesn't need device-driven wake (FGS + exact alarm already wake it reliably).

Resolution: **windowing is the per-device `enabled` flag (#5 above), default OFF.** `enabled=0` = today's always-connectable behavior (instant on-demand connect, no tap, alarm-driven) — **Android stays here → zero regression**. `enabled=1` = device-driven windows — iOS opts in. Note: **scheduled** sync needs no tap on either mode (windows auto-connect via the pending-connect); only **immediate/on-demand** connect regresses under `enabled=1`, which is exactly what the Wake-for-Sync tap mitigates.

### Android changes (none required — stays on `enabled=0`)
Android keeps today's path entirely: always-connectable firmware, FGS + WorkManager + exact alarm wake, instant on-demand connect, no tap. The firmware windowing is inert for Android because the app never sets `enabled=1`. (If an Android user *wanted* device-driven cycling, `autoConnect=true` (`OmiBleForegroundService.kt:470`) would catch the windows the same way iOS does — but there's no reason to, so leave it off.) **Do not** re-introduce `CompanionDeviceManager` presence observation — this fork removed it due to OnePlus/Oppo/Realme connection wedges (0.24 changelog). Keep the alarm as the safety net.

### Hard tradeoffs & risks
1. **On-demand connect regresses (only when `enabled=1`)** — DARK between windows means no instant connect on app open; fully dependent on button/motion triggers + safety floor. Biggest UX risk — but scoped to opted-in (iOS) devices; Android and opt-out users on `enabled=0` keep instant on-demand connect.
2. **iOS user force-quit kills background BLE wake** until next manual launch (iOS platform rule). BGTask backstop partially covers it; **re-arm-on-launch** restores the standing connect the moment the app reopens, and the **staleness banner** points the user at the button if data has piled up.
3. **iOS background-scan latency** — window must be long + fast-advertising (≥45–60 s); too short → iOS misses it, too long → device power. Needs tuning + measurement.
4. **Mixed firmware/app versions** — gate on the capability bit + safety floor so no combination bricks reachability.
5. **AAD refactor** touches a working, subtle thread — regression-test VAD recording, SD pause/resume, marker durability.
6. **Must measure** — put it on a Nordic PPK2: today's continuous-slow-adv vs DARK+window current draw, plus real-world iOS wake hit-rate (worn all day, app backgrounded). Don't ship on theory.

### Phasing
- **Phase 1 — Firmware:** dark state + window scheduler + config char + capability bit + button/motion triggers (incl. the "Wake for Sync" button action) + safety floor. Validate on PPK2 + manual nRF connect. Ship behind the capability bit.
- **Phase 2 — iOS:** standing pending-connect (1–3), routine-disconnect-keeps-armed, wake→sync, BGTask demoted to backstop. Measure background wake hit-rate vs. the BGTask-only baseline.
- **Phase 3 — Android (optional):** only if measurement shows a worthwhile phone-battery saving from relaxing the alarm cadence.

Highest-leverage cheap validation: **Phase 1 window scheduler + Phase 2 standing pending-connect**, measured against current BGTask reliability — tells you whether device-driven wake is worth the full build-out before committing.

### Relevant files
- `omi/firmware/omi/src/lib/core/transport.c` — `idle_disconnect_work_handler` (15 s), `transport_set_adv_fast/slow` + `adv_param_slow`, `_transport_disconnected` (adv restart), `update_conn_params` (latency 0); add dark state + window scheduler.
- `omi/firmware/omi/src/aad.c` — `adv_slow_req`/`adv_fast_req` writes (`:310,:330,:464`) and the apply loop (`:247-250`) to hand advertising ownership to the scheduler.
- `omi/firmware/omi/src/lib/core/settings.c` / `settings.h` — persist the window config (mirror `app_settings_save_conn_fail`).
- `omi/firmware/omi/src/button.c` + button-config service (registered `transport.c:1810`) — add the "Wake for Sync" action; kick the scheduler on the mapped gesture.
- `app/ios/Runner/OmiBleManager.swift` — `manuallyDisconnected`/`disconnectPeripheral`/`didDisconnectPeripheral`/`willRestoreState`; add `standingConnect` + pending-connect re-arm.
- `app/ios/Runner/AppDelegate.swift` — keep `BGProcessing`/`BGAppRefresh` as backstop.
- `app/lib/providers/device_provider.dart` — `disconnectDevice(isManual:true)` sites (`:884`,`:996`), `_onStateRestored` (`:232`, already does the "skip if not due" gate to generalize), `_shouldSyncNow()`, `_onBackgroundSyncRequested` (`:208`); apply the wake→policy decision (force vs if-due) on device-initiated connect.
- `app/lib/backend/preferences.dart` — add the "sync on every device wake" vs "only when due" setting (alongside `backgroundSyncIntervalMinutes`).
- Firmware "last wake reason" — expose a 1-byte read (scheduled/button/motion) via a new char or folded into diagnostics `0061` (`transport.c`), read by the app on `onDeviceReady` to pick force-sync vs if-due.
- `app/lib/services/devices/transports/native_ble_transport.dart` — add `disconnectKeepingPendingConnect`; `app/lib/pigeon_interfaces.dart` for the new host API + the window-config write.
- `app/lib/pages/settings/button_config_page.dart` — expose "Wake for Sync" as a selectable button action (default single tap).
- `app/lib/pages/settings/app_settings_page.dart` — add the **Dark Mode** toggle (writes `enabled`); the existing "Auto Sync Interval" dropdown (15/30/60 / Manual Only, ~`:248`) already supplies the cadence — Manual Only = button-only. The staleness banner lives wherever sync status surfaces (home/recordings).
- Android (phase 3, optional): `OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`.

---

## DEFERRED

## iOS code signing & non-jailbroken distribution [medium] [Deferred]

The iOS build works end-to-end via CI (`.github/workflows/ios-build.yml`) and produces an **unsigned** dev IPA that installs on a **jailbroken** device (AppSync Unified / TrollStore — current path for the iPhone 6s Plus). To run on a **stock** (non-jailbroken) iPhone, the IPA must be code-signed, which needs an Apple Developer account plus signing material wired into CI.

### What it takes
- **Apple Developer Program ($99/yr)** — required for a real signing certificate + provisioning profile. (A free Apple ID only does 7-day Xcode sideloading on a Mac, which headless CI can't drive.)
- **Signing secrets in GitHub Actions** — distribution certificate (`.p12` + password) and a provisioning profile stored as encrypted repo secrets, imported into a temporary keychain on the runner (e.g. `apple-actions/import-codesign-certs`).
- **Build a signed IPA** — replace the workflow's `flutter build ios --no-codesign` with `flutter build ipa` + an `ExportOptions.plist`: method `app-store` for TestFlight, or `ad-hoc` / `development` for direct install with the target device UDID registered in the profile.
- **Distribution**
  - **TestFlight** (cleanest — no per-device UDID): upload via `xcrun altool`/`notarytool` or `apple-actions/upload-testflight-build`; install via the TestFlight app. No Mac needed locally.
  - **Ad-hoc**: register target device UDIDs in the profile; install the signed IPA directly (Apple Configurator / `ideviceinstaller`).

### Why deferred
The jailbroken-device path (unsigned IPA, already working) covers the current 6s Plus for free. Signing only matters when targeting a non-jailbroken iPhone, and it carries an annual fee + secret management. Revisit if/when a stock-iOS device becomes a target.

### Relevant files
- `.github/workflows/ios-build.yml` — today: `flutter build ios --flavor dev --no-codesign` → zips `Payload/Runner.app` into an unsigned IPA. Signing adds a cert-import step, switches to `flutter build ipa`, and adds an upload/export step.
- Flavors (`app/flavorizr.yaml`): `dev` = `com.omi.offline.development`, `prod` = `com.omi.offline` — the provisioning profile must be issued for whichever bundle id is shipped.
