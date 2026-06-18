# Ideas

## ACTIVE

## Multi-select recordings: Merge selected into one file [medium] [Active]

The selection-mode shell already ships: long-press a recording (or ghost) enters selection mode, tap rows to build a set, and a contextual action bar offers **Delete**, **Export**, and **Recover** (`recordings_page.dart` — `_enterSelection`/`_toggleSelection`/`_buildSelectionBar`, wired through `batch_card.dart`). The remaining piece is a **Merge** action: combine N selected recordings into one continuous file.

**Merge is reprocess-from-bins, not file concatenation.** Merge gathers **the raw bins owned by the selected recordings** — the union of each recording's source bins, deduped and sorted by time — and **re-runs the decode pipeline with VAD off, no silence padding**, producing one fresh recording in the user's chosen format. It processes *only the selected recordings' own bins*, never a time-span, so un-selected recordings sitting between two selections are never touched (no absorb, no contiguity rule, their bins stay theirs).

### Why reprocess-from-bins is the right mechanism
Conceiving merge as **concatenation of finished files** is what created its sharp edges; reprocessing from raw bins removes them:

- **Format-agnostic / solves m4a.** You can't byte-concatenate `.m4a`. Reprocess decodes Opus → PCM → encodes once, exactly like the normal pipeline, so the output is native m4a/wav/ogg with no transcode hack.
- **No `.meta` hand-rebuild.** The pipeline emits a correct `.meta` (totalSamples, durationMs, 200×u16 waveform, bin list) natively.
- **No marker re-anchoring.** Button-tap markers are inline `0xFFFFFFFE` frames in the bin stream and `VadAudioProcessor` re-parses them on the decode pass, so the merged recording's `.edl` markers land at correct offsets by construction.

**The reprocess mode already exists.** `RecordingsController.recoverDiscard` (~line 1363) drives `RecordingsManager.processAll` over a `syntheticBatch` of bins with a `ProcessingSettings` override — `vadEnabled: false`, `silenceDurationToSplitMs: 0x7FFFFFFF` (never split), `maxChunkMs` ≈ max (no cap) — and produces one continuous file with a correct `.meta` and regenerated markers. Merge is that same call pointed at the union of the selected recordings' bins. The "prototype the reprocess mode first" risk from the old write-up is effectively answered by this path.

### The one real blocker: bins must outlive the boundary (bin ownership)
`recoverDiscard` works because a discard's bins are still on disk. **Finalized recordings don't keep their raw bins** — they're deleted at the conversation boundary (`delete_segments` in `recordings_manager.dart` / `recordings_isolate_worker.dart`), and a recording only tracks its Omi-Cloud upload bin (`recording_fs320_<ts>.bin`, via `_binPathsForConversations` ~1563), not its `raw_segments`. So an existing finalized recording currently has **no source bins to reprocess**. Merge needs the raw bins retained under the recording:

- **Recording exists ⇒ its raw bins exist; recording deleted ⇒ its bins deleted.** Convert the `delete_segments` consumers from "delete consumed bins now" to "hand the consumed bins to the finalized recording" (track them on the `Conversation`, e.g. a per-recording bin list / folder).
- **Tie lifetime to the existing retention setting.** A time-based retention already ships — `keepRecordingsDays` (`preferences.dart` ~141, default `-1` = always keep; `0` = passthrough). Age-out (`_enforceRetentionPolicy`, ~1343) deletes recordings older than the window. Extend that teardown to also purge the recording's retained raw bins, so bins age out with their recording and there's no separate bin GC.
- **Disk cost** scales with the window and is the user's tradeoff (memory has encoded ingest at ~5,100 B/s). The retention window already bounds it; "always keep" grows without bound.

### The remaining work
1. **Bin ownership** — flip the `delete_segments` consumers from immediate-delete to "retain under the finalized recording"; extend `deleteConversations` + `_enforceRetentionPolicy` to purge those retained bins. **Cross-cutting** — audit every bin-deletion site (WAL service, truncate-on-resume guard, orphaned-session cleanup, draft re-stitch), under the sync `Mutex`, honoring `discardProtectedPaths`.
2. **`mergeConversations(List<Conversation>)` in `RecordingsManager`/controller** — collect the union of the selected recordings' retained bins, **dedupe** (a bin straddling a VAD boundary can appear in two recordings' lists), sort by time, run through the existing VAD-off `processAll` override (as `recoverDiscard` does), write one fresh recording, delete the source recordings, and re-home the bins under the merged recording (so it stays mergeable itself).
3. **Merge button** — add a Merge icon to the existing selection bar in `_buildSelectionBar` (`recordings_page.dart` ~208), enabled when ≥2 recordings are selected; wire to `mergeConversations` + a reload.

### Open questions
- **Boundary-straddling bin.** If a single ~5-min bin was split by VAD across recording A (tail) and B (start), merging just A reprocesses that whole bin and includes a sliver of B's audio at the seam. Minor over-inclusion; acceptable, or trim at the known VAD offset if it matters.
- **Merge preview/confirm.** Merge is destructive (deletes the sources) — show the resulting duration (sum of the selected recordings' captured audio) before committing.
- **Inherited timestamp** — earliest start time; filename `recording_{startMs}` from the earliest source.
- **Upload state after merge** — the merged recording is a new file with a fresh upload key; the sources' upload state is discarded (mirrors draft-stitch). If Omi Cloud is on, a fresh `recording_fs320_<ms>.bin` is written for the merged result.
- **Markers in selection mode** — simplest first cut: merge applies to **recordings only**; markers keep their current long-press-to-delete (reprocess regenerates any button-tap markers inside the selected bins anyway).

### Rough estimate
| Piece | Effort |
|---|---|
| Bin ownership: flip `delete_segments` → retain under finalized recording + purge on delete/age-out. **Cross-cutting** — audit every bin-deletion site under the sync Mutex. | ~1.5–2 days |
| `mergeConversations` = gather + dedupe selected recordings' bins, reprocess via the existing VAD-off `processAll` override, re-home bins under the merged recording | ~1 day |
| Merge button in the existing selection bar + confirm/preview | ~half day |

**~3 days.** The selection UI, delete-selected, the reprocess-VAD-off mechanism, and a time-based retention are already shipped; the cost is the bin-ownership audit (the load-bearing dependency) plus the small merge logic on top.

### Relevant files
- `app/lib/services/recordings_manager.dart` — `delete_segments` sends are the deletion chokepoint to convert from "delete consumed bins" to "retain under finalized recording"; `Conversation` model (`relativeBins`); the bin→PCM decode pipeline.
- `app/lib/services/recordings_isolate_worker.dart` — the other `delete_segments` site.
- `app/lib/pages/recordings/recordings_controller.dart` — `recoverDiscard` (~1363, the working VAD-off reprocess template) and its `ProcessingSettings` override; `_enforceRetentionPolicy` (~1343) + `keepRecordingsDays`; `deleteConversations` (~1272) and `_binPathsForConversations` (~1563) — extend to purge retained raw bins; add `mergeConversations`.
- `app/lib/pages/recordings/recordings_page.dart` — `_buildSelectionBar` (~208) to add the Merge icon; selection-mode state already in place.
- `app/lib/backend/preferences.dart` — `keepRecordingsDays` (~141) governs retention; `audioSaveFormat` drives the merged output format.

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
