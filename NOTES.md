# Notes

Running log of investigated bugs, deferred decisions, and findings that don't fit IDEAS or README.

---

## Live test data — raw .bin segments

`test-data/live_bins_20260603.tar` — 76 raw `.bin` segments captured 2026-06-03. Gitignored (133 MB), lives on your machine only.

To restore for a processing test run:

```bash
# 1. Uninstall + reinstall the app (clears notification channel, fresh state)
# 2. Launch the app once so Flutter creates its directories
# 3. Restore the bins:
bash test-data/restore-bins.sh
# 4. Open the app — processing starts automatically
```

To capture a new snapshot: back up `raw_segments/` via ADB (see `adb_backup/` session for the exact commands), copy the resulting `raw_segments.tar` into `test-data/` with a dated name, and update the default in `restore-bins.sh`.

---

## VAD perf: timing diagnostics + native batch-runner plan

**Status:** session options shipped (0.16.7) · timing instrumentation shipped · **investigation complete (2026-06-02): ~50/50 channel/compute; the compute half is dispatch-bound and unreducible (quantization structurally impossible; threads/XNNPACK flat). the native batch runner is the sole lever (~2× ceiling), now **deferred — full buildable spec in `IDEAS.md` → "VAD Native Batch Runner".**

### What I'm measuring (create / run / read)

`_runVad` (`app/lib/services/vad_audio_processor.dart`) emits this every 2000 inferences (~64 s of audio) when **Save Diagnostic Logs to File** is on:

```
VadAudioProcessor: VAD per-inference avg over 2000 runs — create 0.082ms, run 0.140ms, read 0.071ms (channel floor ≈ create+read 0.153ms)
```

Each inference crosses the Dart↔native platform channel 3× on the critical path:

- **create** — `OrtValue.fromList` marshals the 576-float input window to native and builds the tensor. ~Zero native compute → a proxy for the pure channel-hop floor.
- **run** — `session.run`: the same channel hop **plus** the actual Silero ONNX math.
- **read** — `asFlattenedList` fetches the single output prob back across the channel. ~Zero native compute → also pure channel-hop cost.

**Decision rule:**

- `run ≈ create + read` → **the platform channel dominates, compute is nearly free.** → Build the native batch runner (below). XNNPACK/threads barely matter.
- `run ≫ create + read` → **ONNX compute dominates.** → Native port won't help much; look at a quantized/smaller Silero, or chase XNNPACK gains.

Silero runs ~112,500× per recorded hour (one 512-sample / 32 ms window each), so whichever term dominates is multiplied by that. Also sanity-check the totals against overall processing wall-time to confirm VAD is actually the bottleneck (vs Opus decode / AAC encode / disk I/O).

**To collect:** enable "Save Diagnostic Logs to File" **before** starting a sync/process — the isolate captures the pref at launch (`recordings_manager.dart:1363`) — run a real recording through, then **Share Logs**.

### Measured (2026-06-02) — ~50/50 channel/compute, VAD ≈ 75% of the run

First on-device run (12 segments, ~16 min of recorded audio over a ~2 h span, ~30k inferences, 165 s total processing):

```
create 0.84ms · run 2.75ms · read 0.62ms → ~4.2ms / inference
```

- **Channel ≈ 2.0 ms/inf** (create 0.84 + read 0.62 + run's own hop ~0.6).
- **ONNX compute ≈ 2.1 ms/inf** (run 2.75 − one hop).
- VAD inference ≈ 30k × 4.2 ms ≈ **126 s of the 165 s run (~75%)** — the dominant processing cost.

**Verdict: NOT channel-dominated — it's ~50/50.** So the native batch runner removes only the channel half → caps at ~2× on VAD (~60 s). The compute half is equally large and 2.1 ms is suspiciously high for Silero v5, so chase the cheap compute wins **first**:

1. **Confirm XNNPACK engaged.** Added a per-session log line (`ORT providers available=… requested=…`). If XNNPACK isn't in `available`, the options silently ran default CPU and the "XNNPACK" win never happened — fixing or accepting that is free.
2. **A/B `_vadIntraOpThreads`** (1 / 2 / 4) — pinning to 1 may leave multi-core compute on the table. Watch the `run` ms.
3. **Try an int8-quantized `silero_vad.onnx`** — investigated and **ruled out** (structurally impossible — see "Compute half is dispatch-bound" below).

All three are now resolved: XNNPACK confirmed engaged, threads flat, quantization impossible. **The compute half (~2.1 ms) is fixed for this model on this runtime**, so the native batch runner's channel-half win is the **sole remaining lever** — ceiling ~2× (~4.2 ms → ~2.2 ms on the biggest chunk of processing).

**Experiment log:**

- **XNNPACK: confirmed engaged** (2026-06-02). `available=[CPU, NNAPI, XNNPACK] requested=[XNNPACK, CPU]` — the 2.1 ms compute was already on XNNPACK, not a CPU fallback. NNAPI is also available but not worth chasing for a recurrent LSTM (per-call delegation × 112k + numeric drift). So the high compute is inherent to fp32 Silero on this device, not a misconfig.
- **intraOp A/B — DONE: no real benefit** (2026-06-02). intraOp=2 `run` dropped 2.75 → ~1.52 ms, BUT `create` (0.84→0.55) and `read` (0.62→0.29) dropped proportionally — and threads can't touch those pure-channel ops. So the ~45% was **environmental (thermal/load: the 2.75 baseline was a 165 s sustained run → throttling; the 1.52 run was a quieter 52 s reprocess).** Load-normalized ratio `run/(create+read)`: **1.88 (intraOp=1) vs ~1.82 (intraOp=2) — flat.** ⇒ XNNPACK kernels for this tiny model are already thread-bound; **threads are a dead end.** Reverted to `intraOp=1` (resource-minimal).
- **Lesson:** absolute create/run/read ms is load-confounded (thermal throttling scales all three together). Use the `run/(create+read)` ratio for clean compute comparisons across runs.

### Compute half is dispatch-bound — quantization is structurally impossible (2026-06-02)

Cracked open `silero_vad.onnx` with onnxruntime + onnx (Python). The compute half (~2.1 ms) is **not** heavy matmul — it's **op-dispatch overhead across ~800 tiny nodes per inference**, which kills every compute lever at once:

- **Op census (recursing into the `If` subgraphs):** 12 Conv + 4 LSTM + 10 Relu + 2 Sigmoid, wrapped in **25 nested `If` nodes**, with **341 `Constant` nodes** and hundreds of shape ops (60 Slice, 46 Unsqueeze, 26 Concat, 20 each Shape/Gather/Cast…). The STFT front-end is built from primitives, not one op. Every node is a separate ORT kernel dispatch, so per-window cost tracks *dispatch count*, not FLOPs. That's exactly why XNNPACK and threads moved nothing — there is no big parallel matmul to accelerate.
- **`quantize_dynamic` (QInt8) is a no-op here.** It only quantizes MatMul/Conv weights that are **top-level graph initializers** — but this model reports **0 initializers**: every weight is a `Constant` node buried inside the nested `If` branches, which the quantizer does not recurse into. Result: identical op histogram and the file got *larger* (2.33 MB → 2.38 MB). Nothing was quantized. The one heavy recurrent op, **LSTM, is not dynamically quantizable in ORT** regardless. Silero ships no official int8 model. (The top-level `If` exists only to switch the 8 k / 16 k path within one file.)
- **fp16 considered, not pursued.** `convert_float_to_float16` *does* recurse into subgraphs (unlike the quantizer) so it would convert the weights, but ORT's CPU/XNNPACK EPs lack fp16 Conv/LSTM kernels for this op mix → they wrap each op in Cast→fp32→Cast. Expected neutral-to-regression on ARM; not worth a build/test cycle.
- **Only way to cut compute = fewer nodes = a structurally simpler / distilled VAD.** Out of scope (retraining).

**Conclusion: the ~2.1 ms compute is fixed for this model on this runtime. The native batch runner (channel half) is the sole lever — ~2× ceiling, identical math, zero accuracy risk.** Tooling lives in `~/AppData/Roaming/Python/Python314/site-packages` (onnxruntime 1.26 + onnx 1.21 + sympy); throwaway scripts in `%TEMP%/vadquant`.

### Android CPU throttle spike — FIXED (0.18.2, 2026-06-03)

**Symptom (observed in production logs, 2026-06-03):** the `create` cost spiked from ~0.64 ms to ~9.55 ms mid-run at ~6k inferences, with no change in the ONNX `run` time:

```
4000 runs:  create 0.643ms · run 1.365ms · read 0.476ms  → channel floor 1.119ms
6000 runs:  create 9.551ms · run 1.680ms · read 0.547ms  → channel floor 10.098ms  ← spike
8000 runs:  create 7.405ms · run 1.868ms · read 0.581ms  → channel floor 7.986ms
50000 runs: create 3.238ms · run 2.913ms · read 0.764ms  → channel floor 4.002ms
```

The spike correlates with the device screen going off / BLE disconnecting. The `create` step (`OrtValue.fromList`) does ~zero native compute; it's a pure platform-channel round-trip. When Android's CPU governor downclocks the background isolate's thread priority (screen-off / no `PARTIAL_WAKE_LOCK`), every channel hop waits longer in the OS scheduler. `run` barely moved because the ONNX compute is pinned to a native thread that wasn't throttled the same way.

**Fix:** acquire `PowerManager.PARTIAL_WAKE_LOCK` (`"omi:VadProcessing"`) at the start of `_doBackgroundSync` (alongside `WakelockPlus.enable()`) and release in `finally`. The 30-minute safety timeout ensures the lock is never permanently leaked on a crash.  
**Files:** `pigeon_interfaces.dart` + `BleHostApiImpl.kt` + `BleHostApiImpl.swift` (no-op stub) + `device_provider.dart`.

**Why `WakelockPlus` alone doesn't fix it:** `WakelockPlus` uses `WindowManager.FLAG_KEEP_SCREEN_ON`, which prevents the display from dimming. `PARTIAL_WAKE_LOCK` targets the CPU governor — it is what tells Android to keep the CPU clocked and the thread scheduler running at normal priority even with the screen off.

### Native batch runner (lever #2b) — DEFERRED, full spec in IDEAS.md

The channel half is the sole remaining lever (~2× on VAD ≈ ~37 % off processing, identical math). It's a real cross-language build (self-contained `VadBatchRunner` channel + ORT dep on both platforms + a two-pass refactor of `processSegmentFile`) whose payoff is **backlog-only** — invisible on frequent incremental syncs. Decision (2026-06-02): **deferred.** The complete buildable design — contract, native template, the deferred-verdict refactor, staging, relevant files, trade-off — lives in `IDEAS.md` → "VAD Native Batch Runner". Revisit if post-sync backlog grind becomes a real pain point.

---

## Bug: discarded bins reprocessed every sync cycle — FIXED (2026-06-02)

**Symptom:** after sync the UI shows "22 min / 14 min of audio to process" but creates no new entry, and old bins re-run VAD every cycle. Surfaced while testing with no speech (adjustment mode off) — so every bin is noise, maximally visible.

**The machinery that *should* prevent this (pre-existing, and it's correct):** when VAD discards a conversation as noise/too-short, it persists a discard record to `recordings/<localDate>/discards.jsonl` and `processAll` strips any bin with a discard record from the next run (the bins linger on disk for the 48 h recovery window, then the sweep deletes them). So a discarded bin should NOT re-run VAD.

**Why it failed (the actual root cause):** the strip set was derived only from the *handed-in* batches' discards (`processAll`: `batches.expand((b) => b.discards)`), and that set came up empty because of a **date-key mismatch**:

- Raw-segment batches are keyed by `DateTime.fromMillisecondsSinceEpoch(ts)` at `recordings_manager.dart:967` — but `ts` is the bin filename's epoch **seconds** (e.g. `1780375808`). Treated as ms, every UTC-stamped bin lands in a **1970** batch.
- Discard records are filed under the conversation's real **local date** (2026-06-02).
- So the bin's batch (1970, has rawSegments) and its discard record's batch (2026, no rawSegments) never coincide, and callers pre-filter with `.where((b) => b.rawSegments.isNotEmpty)` — dropping the 2026 discard-only batch before `processAll` sees it. Strip set empty ⇒ every discarded bin re-runs VAD forever, and the byte-based "minutes to process" estimate (computed straight off `rawSegments`) re-counts them.

Confirmed in the log: the 07:20 run reprocessed 12 bins from 04:50–06:44 already discarded in the 06:39 run; `pruneConsumedBins` deleted only the 4 bins covered by the real 07:14–07:18 speech recordings.

**Fix (shipped):** new `RecordingsManager.discardedRelBinPaths()` reads the **full** persisted discard set (all `discards.jsonl`), AM-gated, mirroring `getDiscardsForDate`'s `silence_trimmed` skip. Used by both `processAll`'s strip and the three post-sync estimate sites in `recordings_controller.dart` (`_isProcessableBin`), so reprocessing stops and the displayed minutes match what's actually processed. Robust to the mis-dating without touching batch identity. Recover/Delete/sweep still remove the record → bin re-enters; Adjustment Mode still keeps all bins.

**Root mis-dating (`:967`) — also FIXED.** The seconds-as-ms read is corrected to `_dateStringFromMillis(ts * 1000)` (the canonical local-date helper, with the `kMinValidEpoch` 946684800 threshold; uptime/unparseable names still fall back to mtime). Raw bins now group under their real date alongside same-day recordings/discards. Regression test added: `getBatches groups epoch-second bin filenames under the real date, not 1970`.

- **Non-AM (normal) processing is unchanged:** `processAllCompletedSessions` only filters by `finalizedRecordings` *in* AM, and `processAll` combines all batches into one stream regardless of date — so the regrouping changes only UI batch labelling and the now-working batch co-location, not what's processed or the estimate total.
- **AM interaction (an improvement, not a regression):** with correct dates, a day that already has recordings joins the recording-bearing batch, so the background auto-processor skips it in AM — previously it re-ran the phantom 1970 batch every cycle. Explicit reprocess / AM-cleanup paths are unaffected.

**Windows test failures — FIXED.** The 6 `recordings_manager_test.dart` failures were two separate issues:

- **Path separators (5 tests):** `pruneConsumedBins` parsed the bin basename via `path.split('/')`, and `deleteAllRawSegments` compared `/`-built protected paths against the host-separated `entity.path` — both broke on `\` temp paths. Fixed with `p.basename` and `p.normalize` (imported `package:path`). No on-device change — Android paths are `/`, where these are identities.
- **Stale coalescing test (1):** it fed a `silence_trimmed` record and expected it merged, but `getDiscardsForDate` intentionally drops `silence_trimmed` (trailing silence of a saved recording — added in the same coalesce feature commit). Corrected the test's record reason to a non-dropped one.

`recordings_manager_test.dart` is now 49/49. Full suite went `+170 -8` → `+177 -2`.

**Remaining 2 failures — also FIXED.** They were *not* wal/sync (those were just the tests *running* when the failure count printed) — both were in `vad_audio_processor_test.dart` (`consecutive in-stream silence splits…`, `real consecutive processor discards coalesce…`), failing deterministically (in isolation too), not from ordering. Cause: the 0.16.0 AAD fix (`isSpeech = _session == null`, commit f8005a0ab) made null-session frames count as *speech*, so these silence-split tests — which build the processor via `fromSettings` with no session — got 0 discards instead of 2. Fixed by handing them a non-null `OrtSession.fromMap` placeholder (never invoked — the host's null decoder skips `_runVad`) plus a `flutter_onnxruntime` channel mock so the placeholder's `close()` is a no-op.

**Full suite is now green: `+179`, 0 failures** (baseline was `+170 -8`).

---

## Firmware: LED Behavior

### Boot Sequence
1. **LEDs breathing white** — `boot_led_sequence()` starts `led_start_breathing()` right after `led_start()` (which just asserts PWM ready, doesn't drive any LED itself)
2. **Haptic buzz** (100ms) — fires during breathing while settings + SD init run
3. **Breathing continues** — `boot_warming_sequence()` spin-waits for the SD worker to finish mount + `lfs_fs_gc` + file open (< 5 s with little data, up to ~50 s with 200 MB)
4. **Mic starts** — `mic_start()` runs once SD is ready
5. **Breathing stops, solid white → fade to off** — `boot_ready_fade()` holds solid white (R+G+B at `dim_ratio`) for 1 s, then fades all three channels down to 0 over ~1000 ms (100 × 10 ms steps). Main loop's `set_led_state()` (500 ms cadence) then takes over.

### LED State Machine (`set_led_state()`, runs every 500ms)

Priority order (highest first):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off (`is_off`) | Off |
| 2 | Charging starts (`is_charging && !is_led_enabled`) | Force `is_led_enabled = true`, continue |
| 3 | Double-tap marker (`marker_flash_count > 0`) | White (R+G+B) — overrides stealth |
| 4 | Stealth mode (`!is_led_enabled`) | Off |
| 5 | Muted | Solid Red |
| 6 | Low battery (< 10%) | Solid Purple (R+B) |
| 7 | BLE connected | Solid Blue (wins over recording state) |
| 8 | Manual recording active (AAD threshold == 65535) | Solid Yellow (R+G) |
| 9 | AAD auto-recording (`aad_is_recording()`) | Solid Yellow (R+G) |
| 10 | Idle / disconnected / standby | Off |

### Charging Override
Applied on top of the base state above:
- **Fully charged (≥ 98%):** Solid Green
- **Charging:** Blinks every 500ms between Green and the current base color (e.g. Green ↔ Blue if connected, Green ↔ Yellow if recording)
- Plugging in charger automatically disables Stealth Mode (`is_led_enabled = true`)

### Button Controls
| Action | Effect | Haptic |
|--------|--------|--------|
| Single tap | No action | None |
| Double tap | White flash ~1s (marker recorded via `write_marker_to_storage()`) — ignored if muted. In manual AAD mode: toggles manual recording start/stop instead. | None |
| Double tap + hold (1s on second press) | Toggle Mute — LED goes Red when muted, mic paused. Suppressed in manual AAD mode. | None |
| Triple tap | Toggle Stealth Mode (`is_led_enabled`) | None |
| Triple tap + hold (3s on third press) | Power off (`turnoff_all()`) | 100ms |

### Hardware Error LEDs
**Removed in production.** All `error_*()` functions in `feedback.c` log to UART/RTT only. No visual LED feedback on errors.

### Stealth Mode Notes
- Triple tap toggles `is_led_enabled`
- Stealth suppresses all base state LEDs (priority 4)
- Stealth does **not** suppress double-tap white flash (priority 3 fires first)
- Charging always overrides stealth back on

---

## Firmware: Power / Battery Optimizations

### Button: Interrupt-Driven (implemented)

**Files:** `src/lib/core/button.c`, `src/main.c`, `src/lib/core/transport.c`

Previously `check_button_level` unconditionally rescheduled itself every 40ms (25 Hz) via a Zephyr work queue, preventing the CPU from sleeping between presses.

**Fix:** The GPIO interrupt (`button_gpio_callback`) schedules the work item (`K_NO_WAIT`) only when a press arrives while `fsm_state == STATE_IDLE`. The work item reschedules itself at 40ms while an interaction is in progress and stops when the state machine returns to `STATE_IDLE`. `activate_button_work()` still exists but is no longer called from `main.c` or `transport.c`.

### Battery ADC Poll Interval (implemented)

**File:** `src/lib/core/transport.c`

| State | Before | After |
|-------|--------|-------|
| Connected | 10 s | 60 s |
| Disconnected | 30 s | 5 min |

Battery voltage on the 150 mAh LiPo changes on the order of millivolts per minute. The previous intervals were excessively frequent and prevented the ADC/peripheral from reaching low-power states.

### Deferred Optimizations

- **BT TX power** (`CONFIG_BT_CTLR_TX_PWR_ANTENNA=8` → 0 or 4 dBm): saves power during every radio tx. Requires testing with phone in pocket/bag to confirm no audio dropouts.
- **BLE connection interval** (7.5–15ms → 30ms): large power savings from longer radio sleep. Requires empirical validation that Opus streaming (50 fps, 80 B/frame, MTU 498) doesn't overflow buffers or cause audio gaps at the longer interval. The `update_conn_params()` in `transport.c` hardcodes the interval at runtime and would need updating alongside the Kconfig values.
- **Disable logging in production**: `CONFIG_SERIAL=n`, `CONFIG_LOG=n` in a `release.conf` overlay. RTT logging stays on for development builds. The log processing thread and UART clock domain add baseline power draw.

---

## Firmware: SD Write Queue Configuration

**Location:** `omi/firmware/omi/src/sd_card.c`

**Current values:**
```c
#define SD_REQ_QUEUE_MSGS  100   // main audio write queue depth
#define SD_PRIO_QUEUE_MSGS  10   // priority queue (control requests)
#define WRITE_BATCH_COUNT  100   // frames accumulated per write batch
#define SD_FSYNC_INTERVAL_MS (60 * 1000)  // fsync every 60s
```

Each slot in `sd_msgq` holds one `sd_req_t`. The queue is backed by `K_MSGQ_DEFINE` (static allocation). The worker accumulates up to `WRITE_BATCH_COUNT` (100) frames into a batch buffer before flushing to LittleFS.

`SD_FSYNC_INTERVAL_MS` (60 s) controls durability: data is in the LittleFS write cache until fsync fires. A hard power-off within this window risks losing up to 60 s of audio, but LittleFS's copy-on-write metadata ensures the filesystem itself stays consistent.

The early-flush path (`sd_boot_ready` gate + high-watermark logic) prevents the queue from filling during the boot `lfs_fs_gc` pre-warm and during bursts of rapid audio ingestion.

---

## Debug Tools Audit

This section reviews the functionality of the Debug Tools present in `app/lib/pages/settings/sync_page.dart` to verify if they operate according to their given descriptions.

### 1. Sync Omi Segments
**Description:** "Download any pending raw segments from your Omi."
**Implementation:**
- Checks if processing is currently running (`RecordingsManager.isProcessingAny`), blocking the sync if true.
- Calls `ServiceManager.instance().wal.getSyncs().syncAll()`.
- Updates UI based on the response.
**Conclusion:** Matches description. `syncAll` correctly checks for pending segments and syncs them.

### 2. Force Sync Omi
**Description:** "Seals the current recording on the device and syncs everything, including the current session."
**Implementation:**
- Shows a confirmation dialog warning that it will close the current recording segment.
- Calls `ServiceManager.instance().wal.getSyncs().rotateAndSync()`.
- `rotateAndSync` connects to the device, executes a file rotation (`connection.rotateFile()`), updates the missing wals bypassing the minimum buffer threshold (`ignoreThreshold: true`), and then runs `syncAll()`.
**Conclusion:** Matches description. The `rotateFile` command forces the firmware to close the current file and start a new one, allowing immediate download.

### 3. Force Process Omi
**Description:** "Process raw segments immediately, including the newest (may be incomplete)."
**Implementation:**
- Checks if processing is already running.
- Calls `RecordingsManager.forceProcessAll()`.
- `forceProcessAll` retrieves all batches and filters for `rawSegments.isNotEmpty`. Unlike regular processing which skips the newest segment per session to prevent conflict with ongoing writing, `forceProcessAll` intentionally includes all segments.
**Conclusion:** Matches description. It correctly bypasses the `excludeNewestSegmentPerSession` filter.

### 4. Delete Omi Segments
**Description:** "Permanently deletes raw segments from your Omi. The device immediately starts a new recording file."
**Implementation:**
- Shows a confirmation dialog.
- Cancels any active sync.
- Calls `ServiceManager.instance().wal.getSyncs().deleteAllPendingWals()`.
- Resets shared preferences related to sync and processing progress.
- `deleteAllPendingWals` in `SDCardWalSyncImpl` sends the `CMD_CLEAR_STORAGE` (0x14) to the device. If that fails, it falls back to deleting each file individually.
**Conclusion:** Matches description.

### 5. Delete Phone Segments
**Description:** "Permanently deletes raw segment files stored on this phone."
**Implementation:**
- Blocked if processing is active.
- Shows a confirmation dialog.
- Deletes the `raw_segments` directory (`${directory.path}/raw_segments`) recursively.
- Resets shared preferences related to sync progress.
**Conclusion:** Matches description. The `raw_segments` folder contains all the downloaded `.bin` files and markers.

### 6. Delete Phone Conversations
**Description:** "Permanently deletes finalized recordings and conversations." (Confirmation dialog also warns that any open conversation in progress is included.)
**Implementation:**
- Blocked if processing is active.
- Shows a confirmation dialog.
- Deletes the `recordings` directory (`${directory.path}/recordings`) recursively.
- Deletes the `processing_temp` directory (`${directory.path}/processing_temp`) recursively.
- Resets shared preferences related to sync progress.
- Clears the HeyPocket upload history to allow re-upload if files are re-processed.
**Conclusion:** Matches description. `recordings` stores the `.m4a` files and EDL data, while `processing_temp` holds files currently being worked on.

### 7. Delete Problematic EDLs [REMOVED]
**Description:** This tool was removed on 2026-06-07 as it is no longer needed. The EDL system is now self-correcting (automated cross-midnight cleanup, in-memory deduplication, and support for orphan markers).

---

## SD Card Power-Gating and Locking Architecture

### App-Side (Client Locking & Triggers)
The Flutter app manages a `_storageMutex` to ensure that no two multi-step storage operations (e.g., `syncAll`, `deleteWal`, `rotateAndSync`) overlap. This prevents deadlocks and ensures the SD card stays awake for the full duration of a task.

1. **`app/lib/services/devices/omi_connection.dart`**:
   - Owns the `_storageMutex`.
   - `acquireStorageLock()`: Includes an active wake probe via `_waitForStorageReady()`, which calls `performGetStorageFileStats()` to wake the SD card if asleep.
   - `releaseStorageLock()`: Implements an idle release. It does not force an explicit BLE sleep command, allowing the firmware's idle timeout to safely handle powering down after operations conclude.

2. **`app/lib/services/wals/sdcard_wal_sync.dart`**:
   - Enforces the `_Locked` pattern.
   - Public methods (e.g., `syncAll`, `getMissingWals`) acquire the mutex and pass the locked connection to their private `_Locked` equivalents.
   - Prevents nested locks and re-entrant calls, ensuring atomic and uninterrupted workflows.

### Firmware-Side (Device Power Management)
The firmware leverages priority queues to intelligently gate SD card power without needing explicit wake/sleep commands from the app.

1. **`omi/firmware/omi/src/sd_card.c`**:
   - Runs the main SD worker thread.
   - **Per-operation power gating (`sd_io_low_power` atomic)**: The SPI3 bus (and SD device) are suspended via `sd_set_io_low_power(true)` immediately after each operation completes, and resumed via `sd_set_io_low_power(false)` before the next one starts. There is no fixed sleep timer — the bus is off whenever no operation is in flight. Write data manages its own gate inline (`spi_woken` flag within `process_write_data_req`); all other request types are wrapped at the worker loop level.
   - **OTA override**: `sd_set_ota_active(true)` keeps the bus awake for the duration of a firmware update.

2. **`omi/firmware/omi/src/lib/core/storage.c`**:
   - Acts as the BLE GATT translation layer.
   - When the app reads the `0x30295782...` characteristic (via `performGetStorageFileStats()`), it calls `get_audio_file_stats()`. This posts a `REQ_GET_FILE_STATS` to the `sd_prio_msgq`, signaling `sd_card.c` to wake up.

3. **`omi/firmware/omi/src/lib/core/sd_card.h`**:
   - Defines the API for interacting with the SD worker, including the `sd_req_type_t` enumeration (e.g., `REQ_GET_FILE_STATS`).

---

## Firmware: Parked / Unused Subsystems

Some source files exist in the tree as reference code but are **not part of the build**. They are not listed in `omi/firmware/omi/CMakeLists.txt`, so the compiler never sees them — zero flash, zero RAM, zero CPU impact. Leaving them parked (rather than deleting) keeps them available for future use.

### `src/lib/core/accel.c` — IMU BLE broadcast (parked)

Defines a BLE service (UUIDs `32403790-…` / `32403791-…`) that would notify accelerometer + gyroscope XYZ over BLE once per second.

**Status:** not in `CMakeLists.txt`; `CONFIG_OMI_ENABLE_ACCELEROMETER=n` in `omi.conf`; the `#ifdef CONFIG_OMI_ENABLE_ACCELEROMETER` blocks in `transport.c` (lines ~521, ~1289) and `button.c` (line ~334) compile to nothing. No consumer: the Flutter app never subscribes to the accel UUID — it only has a placeholder capability-bit constant (`accelerometer = 1 << 1` in `services/devices.dart` and `bt_device.dart`).

**Do NOT confuse with `src/imu.c`**, which IS built and IS load-bearing. `imu.c` uses the same physical LSM6DS3TR-C chip but only its **24-bit hardware timestamp counter** (via raw I²C register reads, not the sensor API). That counter keeps ticking through `system_off` deep sleep; on boot the firmware reads the delta to recover wall-clock time across reboots/crashes, and stamps `imu_ticks` into each recording header (`sd_card.c:1232`). The Flutter app's "IMU Bridge" (`app/lib/services/vad_audio_processor.dart:319`, `tickDelta * 6.4` ms) uses it to stitch recording segments correctly across a reboot. Removing accel.c does not affect this.

**To enable accel BLE broadcast later:**
1. Add `src/lib/core/accel.c` to `core_sources` in `CMakeLists.txt`, gated by `if(CONFIG_OMI_ENABLE_ACCELEROMETER) ... endif()` (mirror the `storage.c` pattern at lines 33-35).
2. Set `CONFIG_OMI_ENABLE_ACCELEROMETER=y` in `omi.conf`.
3. Add Flutter code to subscribe to UUID `32403791-…` and consume the 24 bytes/sec it produces.

A 3-axis accelerometer alone would cover typical wearable uses (wake-on-motion, worn/not-worn detection, step counting, tap gestures, fall detection, orientation); the gyroscope adds power draw and is only needed for precise rotation tracking.

Bug fixes already applied to `accel.c` (defensive, since the file doesn't currently compile): normalized `accel_start()` to standard `0`=success/negative=error return convention, and seeded the self-rescheduling `accel_work` timer in `register_accel_service()` (previously it was never started).

### Other parked files
`src/lib/core/nfc.c` and `src/lib/core/speaker.c` are likewise present but not in `CMakeLists.txt` (speaker is conditionally referenced via `CONFIG_OMI_ENABLE_SPEAKER` blocks but the source isn't added to the build).

---

## Firmware: IMU Time-Bridge Wrap Limit (~29.8 h)

**File:** `src/imu.c` (`lsm6dsl_time_boot_adjust_rtc`)

The cross-reboot clock recovery ("IMU Bridge") uses the LSM6DS3TR-C's 24-bit hardware timestamp counter at 6.4 ms/tick. That counter rolls over every 2^24 × 6.4 ms ≈ **29.8 hours**.

`delta_ticks = (ts_now - base_ts) & 0x00FFFFFFu` corrects a **single** rollover. It **cannot** detect multiple rollovers — the CPU is fully off during `system_off`, so nothing counts wraps. If the device is powered off longer than ~29.8 h and then powered on, the recovered wall-clock undercounts the gap by N × 29.8 h.

**Practical impact:** narrow. The IMU bridge only needs to span short crash/watchdog/reboot gaps (seconds). Any longer gap is corrected by the next BLE time-sync when the phone reconnects. The only residual symptom is recordings created in the window between a >29.8 h power-on and the next phone connection getting an early (wrong) UTC timestamp — and because they're already UTC-named, the time-sync rename pass (which only touches `TMP_` files) won't fix them retroactively.

**No software fix is possible:** the computed delta is always in [0, 29.8 h], so a magnitude guard would be dead code; there's no second time source to corroborate against. Documented rather than "fixed."

---

## App: Marker EDL Audio-Format Hard-coding

**File:** `app/lib/services/recordings_manager.dart` (`getMarkerConversations`, ~line 1856 draft-name fallback)

`getMarkerConversations` resolves an EDL's `segmentFilename` to an on-disk audio file via a one-shot `{basename → File}` index. When that misses, the fallback tries swapping between `recording_<ts>.<ext>` and `recording_<ts>_draft.<ext>` via:

```dart
RegExp(r'\.(m4a|wav|ogg)$')
```

This regex is hard-coded to the three formats Omi currently supports. If a future codec lands (opus container, mp4, aac in a different container, …) the swap fails and markers on those files show as "no audio attached" even when the file is on disk — purely a UI orphaning, not data loss.

**Why deferred:** no other codec is planned, and adding one would already require touching `_saveRecordingCore`, the encoder, and `audioSaveFormat` settings. Updating this regex is one line on top of that work.

**To re-enable when adding a format:**
1. Extend the regex's alternation list: `r'\.(m4a|wav|ogg|<new>)$'`.
2. Search the file for the same regex in other helpers (`_extractTimestamp`, `_finalizeDraft`, `_stitchOgg`/`_stitchWav` ext checks) and update each — they're independent literal regexes, not a shared constant.
3. Consider extracting a `const _audioExtRe = ...` so the next format only touches one place.

---

## App: Marker Pipeline Tripwires

Two `Logger.error` lines are now load-bearing in the marker pipeline. They should **never fire in a healthy system** — if they do during testing, file what triggered them. Both are diagnostic, not fatal: the pipeline keeps running.

### Tripwire 1 — pending markers wiped without orphan emit

**Source:** `app/lib/services/vad_audio_processor.dart` — `_resetState()`

```dart
if (_pendingMarkers.isNotEmpty) {
  Logger.error(
      'VadAudioProcessor: _resetState dropping ${_pendingMarkers.length} pending marker(s) — caller forgot _emitOrphanMarkers()');
  _pendingMarkers.clear();
}
```

**What it means:** every reset path that discards an in-progress recording is supposed to call `_emitOrphanMarkers()` first, so any queued button-tap is surfaced as an orphan EDL instead of being silently lost. If this line fires, an un-audited reset path exists somewhere.

**Audited reset paths (should never trip the tripwire):**
- `flushRemaining` — empty/discard branch: emits orphans before reset.
- `flushRemaining` — successful save branch: `_saveRecording` consumes `_pendingMarkers` into `_pendingEdlData` on success; on null result, the caller calls `_emitOrphanMarkers()` before `_resetState`.
- VAD-resume split (both refs-non-empty and refs-empty branches): emit orphans.
- Max-duration cut (both speech and noise branches): emit orphans.

**If you see it:** copy the surrounding log context (which segment file, what `_currentChunkDurationMs`, was there a 0xFFFFFFFD or marker frame nearby?), then look for the most recent direct or indirect call to `_resetState()` that doesn't have an `_emitOrphanMarkers()` above it. Most likely culprit: a future code change that adds a new state-reset site without routing through one of the discard paths above.

### Tripwire 2 — multiple EDLs at the same markerMs

**Source:** `app/lib/services/recordings_manager.dart` — `getMarkerConversations()` dedup loop

```dart
deduped.add(group[0]);
Logger.error(
    'RecordingsManager: ${group.length} EDLs at markerMs=${group[0].markerTime.millisecondsSinceEpoch} — keeping ${group[0].edlFile.path.split('/').last}, dropping ${group.skip(1).map((m) => m.edlFile.path.split('/').last).join(", ")}');
```

**What it means:** two physical button taps cannot share a UTC ms — firmware uses millisecond RTC resolution and a tap takes far longer than 1 ms. So a group of >1 EDLs at the same `markerTimestampMs` always indicates one of:

1. **Legacy data from before the B4/D1 fix:** older code wrote `marker_<ms>_1.edl`, `marker_<ms>_2.edl`, etc. on segment-filename collision. New code overwrites in place. If users have old data on disk, the dedup will surface the duplicates and drop the non-canonical ones (canonical = userSaved first, then non-pending, then alphabetically-first basename).
2. **A bug in `_writeMarkerEdl`'s collision policy:** something is creating multiple EDL files for the same physical tap that the in-place overwrite path didn't catch.
3. **Filesystem race during a re-process:** a concurrent run created a second EDL while the original was still on disk. Very narrow window since `_writeJsonAtomic` uses tmp+rename.

**If you see it:** check whether the dropped EDL filenames have a `_<n>` suffix (legacy data — safe to delete via the dropped log line) or are plain `marker_<ms>.edl` in a different folder (cross-folder collision — investigate `_writeMarkerEdl`'s date-folder derivation).

**Recovery:** the canonical EDL is preserved; the dropped ones are still on disk (the dedup is in-memory only). The hidden "Delete Problematic EDLs" debug button in `sync_page.dart` won't catch these because they're not pending — manually delete via filesystem if needed.

---

## Firmware + App: SD Write Drop Counters (diagnostic instrumentation)

**Status:** shipped and load-bearing as a canary; validated premise = no drops in real use.

### Why this exists

Originally built to validate a deferred proposal ("Sequence & Sync" marker re-synchronization, formerly in `IDEAS.md`). That proposal would have wrapped every audio packet in a sequence-number + uptime header so the app could detect dropped frames and reconstruct a gap-less timeline — protecting in-stream button-tap markers (`0xFFFFFFFE`) from drifting out of sync when frames are lost. In-stream markers currently rely on byte-position within the `.bin` stream to compute their audio timestamp; if the firmware/SD card drops frames the timeline "shrinks" but the marker stays at its byte-offset, so it drifts.

That proposal's complexity is only justified **if SD write drops actually happen**. These counters were built to measure that. **Result: zero drops across the entire usage history since they shipped** — so the Sequence & Sync proposal was dropped as solving a non-problem (the section was removed from `IDEAS.md` on 2026-05-28). The counters are retained as a permanent cheap canary: if a future firmware change reintroduces drops, the Debug Tools page surfaces it instead of silently shipping marker drift.

### Three counters, three failure modes

| Counter | Source | Fires when |
|---|---|---|
| `block_drops` | `transport.c::write_custom_packet_to_storage` | `write_to_file` returns ≠ `MAX_WRITE_SIZE` — the entire 440 B block is lost (~5 Opus frames ≈ 100 ms of audio). This is the headline number — exactly the loss the marker-drift proposal solved for. |
| `sd_stream_drops` | `sd_card.c::write_to_file` (~line 589) | `k_msgq_put(&sd_msgq, …)` times out after a 1–5 ms retry — a single audio frame is lost. This is the upstream signal; most block drops are downstream of a stream drop. |
| `sd_boot_drops` | `sd_card.c::write_to_file` boot path | An audio frame arrives before the SD mount + `lfs_fs_gc` + file-open completes. Separate cold-start issue, **not** relevant to mid-stream drift. |

### BLE characteristic `0x19B10062` (diagnostics service)

Read-only. Returns **20 bytes, little-endian**, five `u32` fields in this order:

```
[ block_drops u32 ][ last_drop_uptime_ms u32 ][ sd_stream_drops u32 ][ sd_boot_drops u32 ][ now_uptime_ms u32 ]
```

- `block_drops` — see table above.
- `last_drop_uptime_ms` — device uptime (ms) of the most recent block drop; 0 if none. Compare against `now_uptime_ms` to tell "recent" from "early-boot, long ago."
- `sd_stream_drops` — single-frame msgq-saturation drops.
- `sd_boot_drops` — cold-start pre-mount drops.
- `now_uptime_ms` — current device uptime, the reference clock for `last_drop_uptime_ms`.

All counters are cumulative since boot. They reset only on device reboot — there is no firmware reset command (the originally-planned `0x19B10063` "reset stats" write was never added; baseline subtraction is done app-side instead).

### Firmware variables / internals

- `transport.c`: `static atomic_t storage_block_drops` and `static atomic_t last_storage_drop_uptime_ms` (both `ATOMIC_INIT(0)`). Incremented together at the two `write_custom_packet_to_storage` failure sites (`atomic_inc` + `atomic_set(k_uptime_get())`). Exposed via `diagnostics_drops_read_handler`, registered as the last attribute in `diagnostics_service_attr[]`.
- `sd_card.c`: `static atomic_t stat_dropped_frames` (stream drops) and `static atomic_t boot_dropped_frames` (boot drops). `SD_REQ_QUEUE_MSGS = 100` (sd_card.c:48) backs `K_MSGQ_DEFINE(sd_msgq, …)` — ~10 s of write buffer at 50 fps; typical SD GC stalls are 100–400 ms and won't saturate it. Accessors: `sd_get_stream_dropped_frames()`, `sd_get_boot_dropped_frames()`.
- `sd_card.h`: declares `sd_get_stream_dropped_frames()` (line 160) and `sd_get_boot_dropped_frames()`.

### App side / how to use it

1. Open the **Debug Tools** page (`SyncPage`). Look at the **"SD Write Drops"** card (`_buildDropStatsSection()`, sync_page.dart:797). It polls the characteristic every 2 s via a `Timer.periodic` started in `initState`.
2. State fields: `_dropStats` (latest read), `_dropBaseline` (snapshot for delta measurement), `_dropsUnsupported` (true if the char read fails — older firmware without the characteristic).
3. **"Snapshot baseline"** button stores the current counters into `_dropBaseline`; the card then shows the delta since the snapshot — use this to measure drops over a specific window (e.g. an active sync-while-recording stress test) without rebooting the device.
4. Healthy reading: all four drop counts at 0 (or unchanged from baseline). Any movement means real audio loss — investigate per the table above (`sd_stream_drops` moving = genuine msgq saturation → the marker-drift concern is back on the table; `boot_drops` moving = cold-start window leak, a separate fix).

### Forcing drops for a controlled test

- Run an active BLE sync **while recording**: the SD-worker retry budget tightens (`K_MSEC(5)` → `K_MSEC(1)`) and sync reads compete with writes on the same worker thread. ~30–60 min usually enough to provoke something if the system is marginal.
- Or temporarily drop `SD_REQ_QUEUE_MSGS` from 100 → 8 in `sd_card.c` and rebuild — forces drops within minutes. This only proves the counters fire; it says nothing about real-world frequency. Revert after verifying.

### Code locations

- `omi/firmware/omi/src/lib/core/transport.c` — `storage_block_drops` / `last_storage_drop_uptime_ms` (declared ~line 293), `diagnostics_drops_read_handler` (~line 341), char registration in `diagnostics_service_attr[]` (UUID encode ~line 317), increment sites in `write_custom_packet_to_storage` (~lines 1157, 1187).
- `omi/firmware/omi/src/sd_card.c` — `stat_dropped_frames` / `boot_dropped_frames` atomics (~line 267), `SD_REQ_QUEUE_MSGS` (line 48), `sd_get_stream_dropped_frames()` (~line 2188), `sd_get_boot_dropped_frames()` (~line 2183).
- `omi/firmware/omi/src/lib/core/sd_card.h` — accessor declarations (line 160).
- `app/lib/services/devices/device_drop_stats.dart` — `DeviceDropStats` model + 20-byte LE parsing.
- `app/lib/services/devices/omi_connection.dart` — `diagnosticsDropsCharacteristicUuid` (line 53), `performGetDropStats()` (line 186).
- `app/lib/services/devices/device_connection.dart` — abstract `getDropStats()` (line 89).
- `app/lib/pages/settings/sync_page.dart` — state fields (lines 37–40), 2 s polling in `initState`, `_buildDropStatsSection()` (line 797).

### Removal plan (if ever decided the canary isn't worth keeping)

Delete the characteristic + handler + registration in `transport.c`, the `sd_card.c`/`.h` accessors if unused elsewhere, the Dart model/accessor, and the app widget + state. Leaves no functional residue — purely diagnostic surface area, no audio-path dependency.

---

## App: Background Connection Lifecycle (single mode + grace disconnect)

Shipped in 0.14.9. The two-mode "Maximize Battery" toggle is gone — there is now one background behavior. Recorded here because the invariants below are easy to undo by accident.

### Why one mode
The old default (Maximize Battery **off**) tried to stay connected in the background, but the keep-alive is off while backgrounded, so the firmware idle-dropped the link every ~30 s and the app immediately reconnected — a perpetual connect↔disconnect churn (~once/min) that also made the foreground-service notification flicker between "Connected" and the sync countdown. Since the Omi records to SD regardless of BLE, holding the link in the background gained nothing. Collapsed to the old Maximize-**on** behavior: disconnect in the background, reconnect only when a sync is due (scheduled interval, or app open/resume). The `maximizeBattery` pref and the App Settings toggle were removed; every `maximizeBattery` branch was treated as always-on.

### Grace disconnect — load-bearing invariant
`onAppPaused` does **not** disconnect immediately; it arms `_pauseDisconnectTimer` (`_backgroundDisconnectGrace`, 30 s) so a quick app-switch / notification-shade glance doesn't force a reconnect on return.
- **The keep-alive must keep running during the grace window.** That — not the grace duration — is what stops the firmware idle-drop, so the link is still live if the user returns. `onAppPaused` therefore must **not** call `_stopForegroundKeepAlive()` (it used to, pre-0.14.9). A future "simplify" that re-adds the early stop silently reintroduces a mid-grace firmware drop. There's an inline comment on the field warning about this.
- **The tick re-arms while a sync is in flight** (`_onPauseDisconnectTick` → `_armPauseDisconnect`). Start-a-sync-then-background case: keep-alive holds the link through the sync, the grace effectively restarts once `isSyncing` / `_backgroundSyncActive` clears, then it stops the keep-alive and disconnects. Without the re-arm the one-shot timer bailed forever and the device stayed connected (keep-alive pinging) until the next scheduled sync. Local decode/VAD processing does **not** hold the BLE link, so it isn't part of the bail condition.
- Cancelled on resume, on any background disconnect (`onDeviceDisconnected`), in `dispose` and `prepareDFU`.
- **30 s value**: covers essentially all quick app-switches; extra connected time vs 20 s is negligible against the device's always-on mic draw. Deliberately a fixed constant, **not** user-selectable — a "grace seconds" slider is the battery-vs-convenience toggle we just removed, in disguise, and isn't a knob a user can reason about.

### Firmware idle-drop — keep it (do NOT remove)
The app-side disconnect is *cooperative* — it only fires while the app's process is alive and the OS runs its lifecycle callbacks. For the *non-cooperative* cases (app killed/swiped/crashed, frozen under Doze, phone out of range) nothing app-side fires, and the firmware's ~30 s idle-drop is the only thing that frees the Omi's radio. The grace delay *widens* the window where the app might not get to disconnect cleanly, so it relies on the firmware net more, not less. No firmware change was made for this work, and the idle-drop should stay.

### Notification
One foreground-service notification (id 2001, channel `omi_ble_channel`). **Two foreground services share this single id, last-writer-wins**: the native `OmiBleForegroundService` (owns the BLE link, required `connectedDevice`-type FGS) and the Dart `flutter_foreground_task` (`ForegroundUtil`). The Dart side is the sole writer of *content*. All Dart idle writes go through `_showIdleNotification` — **connection-state-independent**, shows only the next-sync countdown — guarded by `_syncOwnsNotification` (sync/processing/`_backgroundSyncActive`) so an active sync keeps its own live progress. The old "Connected to Omi Device" / "Scanning for device…" background writes were removed; they fought the countdown across connect/disconnect transitions.

The **native** service must call `startForeground` (FGS requirement) but uses a single fixed baseline text ("Running in the background") and has **no `updateNotification`** — it never writes connection state. An earlier build had the native side post "Connected to Omi Device" / "Connecting…" / "Disconnected" / "Reconnecting…" on every GATT transition; because it shares id 2001 those clobbered the Dart-owned progress and countdown (the exact bug the Dart-side removal was meant to fix — the native twin was missed). Do not re-add native `updateNotification` calls.

Foreground processing progress: `_onProcessingProgress` (a class method on `DeviceProvider`) is gated on `!_isAppInForeground`. When the app is open, `RecordingsController` owns the notification in time-remaining format. `_onProcessingProgress` is registered on `RecordingsManager.processingProgress` in `onAppPaused` (covering both background syncs and foreground-triggered processing that the user backgrounds) and unregistered in `onAppResumed`. `_doBackgroundSync` also registers/unregisters it for the duration of `processAllCompletedSessions`. Remove-before-add in `onAppPaused` prevents double-registration.

### Always disconnect after a background sync
`_doBackgroundSync`'s finally disconnects unconditionally in the background. The old `missingCount > 0` "keep the connection" branch was dropped — with the keep-alive stopped it just idle-dropped within ~30 s anyway. Leftover segments are picked up by the next scheduled sync / on resume (`onAppResumed` has a defensive drain for the rare resume-onto-live-link race).

### Code locations
- `app/lib/providers/device_provider.dart` — `_backgroundDisconnectGrace` + `_pauseDisconnectTimer` (field decl ~line 67), `onAppPaused` / `_armPauseDisconnect` / `_onPauseDisconnectTick`, `onAppResumed` (cancel), `_doBackgroundSync` finally (post-sync disconnect), `_handleDeviceConnected` background drop-guard, `onDeviceDisconnected` background guards, `_showIdleNotification` + `_syncOwnsNotification`.
- Removed: `maximizeBattery` getter/setter in `app/lib/backend/preferences.dart`; the `SwitchListTile` + `_maximizeBattery` state in `app/lib/pages/settings/app_settings_page.dart`.
- Keep-alive: `_startForegroundKeepAlive` / `_stopForegroundKeepAlive` (same file) — see the field-comment invariant above.

---

## App: Notification Pipeline

One persistent foreground-service notification (id 2001, `omi_ble_channel`). **Two services share it, last-writer-wins**: the native `OmiBleForegroundService` (required `connectedDevice`-type FGS) and the Dart `flutter_foreground_task` (`ForegroundUtil`). The native service calls `startForeground` with a fixed baseline text and never calls `updateNotification` — all content writes go through the Dart side.

### Ownership rules

**`DeviceProvider`** is the sole writer when the app is in the background. It is also the owner of the foreground-service lifecycle (start/stop) during background syncs.

**`RecordingsController`** is the sole writer when the app is in the foreground. It calls `ForegroundUtil.updateNotification` via `_updateForegroundProgress()`, which is throttled (1 s foreground / 2 s background) and only fires when `_spState` is `syncing` or `processing`.

**Transition guard:** `DeviceProvider._onProcessingProgress` is gated on `!_isAppInForeground`. `RecordingsController._updateForegroundProgress` only fires when `_spState == processing || syncing`. The two writers never overlap on the same tick.

### All notification strings, by trigger

| When | Who writes | Text |
|---|---|---|
| Background sync starts | `DeviceProvider._doBackgroundSync` | `"Syncing recordings — preparing..."` |
| Background sync, per-packet | `_BackgroundSyncProgress.onWalSyncedProgress` | `"Syncing recordings — 47% complete"` |
| Background sync → processing handoff | `DeviceProvider._doBackgroundSync` | `"Processing recordings — preparing..."` |
| Background processing, per-segment | `DeviceProvider._onProcessingProgress` | `"Processing recordings — 47% complete"` |
| Background processing at 100% | `DeviceProvider._onProcessingProgress` | `"Processing recordings — finishing..."` |
| Background finalizing re-sync | `DeviceProvider._doBackgroundSync` | `"Syncing recordings — finalizing..."` |
| Foreground sync starts | `RecordingsController._runPipeline` / `_runSyncOnly` | `"Syncing recordings — preparing..."` |
| Foreground sync, per-packet | `RecordingsController._updateForegroundProgress` | `"Syncing recordings — N of M segments (X%)"` |
| Foreground processing starts | `RecordingsController._startProcessing` | `"Processing recordings — preparing..."` |
| Foreground processing, duration unknown | `RecordingsController._updateForegroundProgress` | `"Processing recordings — Calculating…"` |
| Foreground processing, ≥ 1 min remaining | `RecordingsController._updateForegroundProgress` | `"Processing recordings — ~686 min of audio to process"` |
| Foreground processing, < 1 min remaining | `RecordingsController._updateForegroundProgress` | `"Processing recordings — < 1 min of audio to process"` |
| Foreground transcoding | `RecordingsController._updateForegroundProgress` | `"Processing recordings — Converting to m4a"` |
| Delete recordings | `RecordingsController` | `"Cleaning up recordings..."` |
| Idle, auto-sync on | `DeviceProvider._showIdleNotification` | `"Next sync in ~N min"` / `"Syncing soon..."` |
| Idle, Manual Only (no schedule) | `DeviceProvider._showIdleNotification` | `"Omi is Connected"` / `"Connecting..."` / `"Omi is Disconnected"` |

### "Calculating…" guard

`_totalMinutes == 0` means the async file-size measurement (triggered in `_poll` via `_pendingProcessingTransition`) hasn't completed yet. `_updateForegroundProgress` shows "Calculating…" while `_totalMinutes == 0 || _minutesRemaining < 0` to avoid flashing "< 1 min" during the ~100–500 ms async gap when `_spState` flips to `processing` before the byte-count is known.

### Foreground → background handoff

When the user backgrounds the app during a foreground-triggered processing run, `onAppPaused` does `removeListener(_onProcessingProgress)` + `addListener(_onProcessingProgress)` (remove-before-add prevents duplicates if `_doBackgroundSync` also registered it). From that point `DeviceProvider._onProcessingProgress` updates the notification even if `RecordingsController` is eventually disposed. `onAppResumed` removes the listener and `RecordingsController` resumes ownership.

### Stopping subtext

`SyncProcessCard` shows `"Stopping…"` with a dynamic subtext: `"Transferring current file…"` while `isSyncing` is true (a BLE segment write is still in flight to avoid corruption), `"Finishing current step"` once the transfer has drained. `isSyncing` is passed in via `SyncCardData.isSyncing`, read from `ServiceManager.instance().wal.getSyncs().isSyncing` at the build site in `recordings_page.dart`.

### Code locations

- `app/lib/providers/device_provider.dart` — `_onProcessingProgress` (class method), `_syncOwnsNotification`, `_showIdleNotification`, `_doBackgroundSync` (registers/unregisters listener, writes lifecycle strings), `onAppPaused` / `onAppResumed` (listener handoff).
- `app/lib/pages/recordings/recordings_controller.dart` — `_updateForegroundProgress`, `_onProgressChanged`, `onWalSyncedProgress`.
- `app/lib/pages/recordings/sync_process_card.dart` — `SyncProcessState.stopping` case (dynamic subtext via `data.isSyncing`).
- `app/lib/pages/recordings/recordings_types.dart` — `SyncCardData.isSyncing` field.
- `app/lib/pages/recordings/recordings_page.dart` — `SyncCardData` construction (passes `isSyncing` from `ServiceManager`).
- `app/lib/services/wals/sdcard_wal_sync.dart` — `_BackgroundSyncProgress.onWalSyncedProgress` (per-packet background sync percentage).

---

## App: BLE Connection Latency Levers

Where reconnect time goes, and the knobs that control each stage. Motivated by the "why is reconnect so slow after an app update" investigation: an app update kills the process **and** the native foreground service, so all warm native BLE state is gone (the `autoConnect=true` passive-scan reconnect and the `OmiCompanionManager` OS-level presence observation are only re-registered when `manageDevice` runs again in the new process). The first reconnect after an update therefore pays the full cold sequence below, instead of the near-instant warm reattach a normal background sync gets. It's compounded when the firmware is in low-power sleep (idle-dropped to save battery, so not advertising continuously) — the phone literally cannot connect until the device wakes and advertises, and several of these timeouts are spent *waiting* on exactly that.

### Observed cold-reconnect timeline (~44 s, from a real post-update log)

| Stage | Duration | What's happening |
|---|---|---|
| App + FGS boot | ~5 s | Flutter engine + plugins start, then `initializeForegroundService` fires `ensureConnection(force: true)`. |
| Fast-path direct-connect timeout | **10 s → now 5 s** | `_scanConnectDevice` direct connect-by-MAC, wrapped in `.timeout(...)`. When the device is asleep this *cannot* succeed, so it just burns the whole timeout, swallows the error (`catch (_) {}`), and falls through to the scan. **This is the lever that was reduced.** |
| Full BLE scan window | 10 s | `discover(timeout: 10)` does `startScan` then `await Future.delayed(10s)` — a *fixed* wait regardless of when the device is actually found. |
| Native connect retries | ~19 s | Native fires its own 15 s connect timeout (`gatt_status_-1`, ignored by Dart as "transient" so native can retry), then retries on a flat 1.5 s backoff until the sleeping device finally wakes, advertises, and answers. |

### Lever 1 — fast-path direct-connect timeout (DONE)

**File:** `app/lib/providers/device_provider.dart` — `_scanConnectDevice()`, the `.timeout(...)` on the `ensureConnection(pairedDeviceId, force: true)` call.

**Change:** `10 s` → `5 s`. A cached fast reattach finishes in <1 s, so 5 s keeps full margin for the case the fast path can actually help; when the device is asleep the extra 5 s was pure dead time before the fallback scan started. Net: shaves up to 5 s off every cold reconnect (post-update, or any time the device is asleep / out of system cache).

**Why this is the safe one:** it only shortens a wait that, in the slow case, was *always* going to fail anyway. It cannot make a successful warm reattach slower (those complete well under 5 s).

### Lever 2 — run fast-path direct-connect and scan concurrently (NOT done)

**File:** same `_scanConnectDevice()`. Currently the fast path and the fallback `discover(timeout: 10)` are **sequential** — the scan only starts after the direct-connect attempt gives up. Racing them (or kicking off the scan and letting native's retry loop carry the direct connect) would overlap the two biggest stages instead of summing them.

**Why deferred:** more invasive — has to reconcile two connection attempts to the same MAC without tripping `ensureConnection`'s `_mutex` / the "don't dispose-and-recreate the transport" invariant (CLAUDE.md), and without two in-flight `connectGatt`s racing in native. Needs care and on-device testing across OEMs. Bigger potential win than Lever 1 (could overlap ~10 s) but higher risk.

### Lever 3 — shorten the fixed scan window (NOT done)

**File:** `app/lib/services/devices/discovery/native_bluetooth_discoverer.dart` — `discover()` does `_hostApi.startScan(timeout, [])` then `await Future.delayed(Duration(seconds: timeout))`. The wait is the **full** `timeout` every time; it does not early-exit when the desired device appears in the `peripheralDiscoveredCallback`.

**Two sub-levers:**
1. Drop the `timeout: 10` passed at the call site in `_scanConnectDevice` (and `periodicConnect`'s path) to something shorter, letting native's 1.5 s-backoff retry loop carry the rest.
2. Make `discover()` **early-exit**: complete as soon as `desirableDeviceId` shows up in `results` instead of always waiting the full window. This is the cleaner fix — turns a fixed 10 s into "as fast as the device advertises," with the timeout only as an upper bound.

**Why deferred:** sub-lever 2 changes discovery completion semantics (callers that expect the full device list after a scan would now sometimes get an early single-device result); needs an audit of `discover` callers. Sub-lever 1 is low-risk but only helps when the device is already advertising.

### Lever 4 — tighten native's first-attempt connect timeout (NOT done)

**File:** `app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt` — `connectToDevice()`. For `source == "manageDevice"` (the very first attempt) `autoConnect=false` and the timeout is `CONNECTION_TIMEOUT_MS = 30_000L`… wait, it's actually `15_000L` for the direct path (`timeoutMs = if (autoConnect) CONNECTION_TIMEOUT_MS else 15_000L`). That 15 s is what produces the `gatt_status_-1` "transient" line ~15 s after `manageDevice`. Lowering it (e.g. 15 s → 8–10 s) makes the **first** retry kick in sooner when the initial direct connect is doomed (device not yet advertising).

**Constants involved:** `CONNECTION_TIMEOUT_MS = 30_000L`, the inline `15_000L` direct-path timeout, `RECONNECT_DELAY_MS = 1_500L` (flat backoff between retries), `STABILITY_TIMER_MS = 60_000L` (resets `retryCount` after a connection holds 60 s), and the `retryCount <= 3` threshold that flips `autoConnect` false→true (direct → passive scan).

**Why deferred:** native timeout tuning is the riskiest — too short and you abort a connect that was about to succeed on a slow OEM stack, causing *more* churn (close → 1.5 s wait → fresh `connectGatt`), which can be net slower and burns radio. Wants real cross-device measurement before touching.

### Rule of thumb
Levers 1+3 attack *fixed dead-time waits* (safe, bounded downside). Levers 2+4 attack *sequential/serial structure and native timing* (bigger wins, real regression risk on slow OEM BLE stacks — measure on-device before shipping).

---

## App: Adding a New Integration (Generic Architecture)

The app uses a generic `PassthroughIntegration` architecture to handle uploads and synchronization. Adding a new integration requires zero changes to the UI or `RecordingsController`.

### 1. Create a Subclass in `passthrough_integration.dart`
Create a new class that implements `PassthroughIntegration`.

```dart
class NewServicePassthroughIntegration implements PassthroughIntegration {
  final SharedPreferencesUtil _prefs;
  NewServicePassthroughIntegration(this._prefs);

  @override
  String get name => 'New Service';

  @override
  bool isEnabled(Conversation c) {
    // Check if the service is enabled in settings AND configured (e.g. API key present)
    // AND any conversation-specific rules (e.g. date gates).
    return _prefs.newServiceEnabled && isConfigured;
  }

  @override
  bool get isConfigured => _prefs.newServiceEnabled && _prefs.newServiceApiKey.isNotEmpty;

  @override
  bool get isAutoUploadEnabled => _prefs.newServiceAutoUpload;

  @override
  bool hasDelivered(Conversation c) => _prefs.isUploadedToNewService(c.id);

  @override
  bool isFailed(Conversation c) => _prefs.getAutoUploadRetries(c.id) >= 3;

  @override
  Future<void> upload(Conversation c) async {
    // Implement the actual upload logic here (e.g. calling NewService.upload(c)).
    // Must call _prefs.markUploadedToNewService(c.id) on success.
  }
}
```

### 2. Register the Integration
Add your new class to the static `getIntegrations` list in `PassthroughIntegration`:

```dart
static List<PassthroughIntegration> getIntegrations(SharedPreferencesUtil prefs) => [
      HeyPocketPassthroughIntegration(prefs),
      OmiPassthroughIntegration(prefs),
      NewServicePassthroughIntegration(prefs), // Add here
    ];
```

### 3. Benefits of this Architecture
- **WiFi Control**: Your new integration automatically respects the "Upload on Wifi Only" toggle in App Settings.
- **UI Icons**: The `UploadIconButton` in `BatchCard` and `RecordingPlayerPage` will automatically include your integration when calculating sync status (Partial/All/Failed).
- **Auto-Upload**: The `tryAutoUploadAll` loop in `RecordingsController` will automatically pick up your integration and attempt background syncs.
- **Passthrough Mode**: If "Delete After Upload" is enabled, your integration will correctly block local file deletion until it confirms delivery via `hasDelivered`.
- **Validation**: The WiFi toggle will correctly detect that an integration is configured, allowing the user to turn it on.

---

## BLE: "advertising but won't connect" (OPEN — instrumented, awaiting next occurrence)

**Status:** root cause NOT yet determined. Firmware logging added 2026-06-08 to capture the answer on the next occurrence. Do **not** change battery-affecting advertising behavior until the instrumentation tells us which branch we're on (see decision tree).

### Symptom (observed 2026-06-08, one data point)
Phone could not connect to the Omi — every attempt failed with HCI `0x3e GATT_CONN_FAILED_ESTABLISHMENT` (`CONNECTION_FAILED_ESTABLISHMENT`), retrying through retry #3–#6 (15 s / 30 s timeouts). **Power-cycling the Omi fixed it instantly** — it connected on the first try afterward. So the device was at fault, and a reboot cleared whatever state it was in.

Crucially: **the device was advertising the whole time** — the phone's companion-discovery log showed `onDeviceFound() (BLE) c3:94:71:ea:a8:d5 'Omi' - New device`. So it was visible/discoverable but rejecting/failing the connection. This rules out "advertising stopped" (an adv-watchdog would not have helped).

### What `0x3e` means
The central received an ADV, sent `CONNECT_IND`, but the link never completed at the first connection event(s) — the peripheral didn't show up. By definition this is the *peripheral* (or the RF link to it) failing at connection setup, not the phone's app logic.

### Config facts that rule suspects in/out (`omi/firmware/omi/omi.conf`)
- **No `CONFIG_BT_PRIVACY`** → stable **static-random** address, NOT a rotating RPA. So address rotation is *not* the cause.
- **`CONFIG_BT_CTLR_TX_PWR_ANTENNA=8`** (+8 dBm) → TX power already high; not a weak-signal-from-device issue.
- **`CONFIG_BT_MAX_CONN=1` / `CONFIG_BT_MAX_PAIRED=1`** → single connection slot. A stale/half-open slot, or an OEM agent grabbing it, would block new connections until reboot.
- The phone is an **Oplus/OnePlus/Realme** device: logs showed `com.heytap.accessory` / `PTC.CONN.GattServer` *also* opening GATT connections to the same Omi — i.e., OEM accessory framework contending for the radio on the same device.

### Advertising state machine (`transport.c`)
- **Fast adv** `BT_LE_ADV_CONN` (100–150 ms): on boot (`transport_start`), after every disconnect (`_transport_disconnected`, ~line 914), and on AAD wake.
- **Slow adv** `adv_param_slow` (**1000–1200 ms**, `BT_LE_ADV_OPT_CONNECTABLE | BT_LE_ADV_OPT_ONE_TIME`): when AAD/VAD goes quiet (`aad.c:245`), saves ~300–500 µA.
- On reboot the device comes up in **fast** adv → connected immediately. So the failure *correlates* with having been in slow adv, but correlation ≠ cause (see below).

### Two competing hypotheses
- **(A) Slow-adv path / 1 s interval is unconnectable on this phone.** Fits the reboot-fixes-it observation (reboot → fast adv). If true, **tiering the interval does NOT fix it** — the important reconnect (idle → background sync) lands *after* idle, i.e. right back on the slow tier. The only fix would be to never advertise slower than the phone can connect to (raise the floor, e.g. 1 s → ~300–400 ms) — a permanent idle-battery cost.
- **(B) Controller/RF wedge cleared by reboot.** A BLE-stack or BLE↔Wi-Fi (nRF7002 / RF switch, `CONFIG_OMI_ENABLE_RFSW_CTRL`) coexistence wedge, or a stale connection slot (`MAX_CONN=1`). The "was in slow adv" detail is then coincidental.

**Why I lean away from a pure-interval explanation:** per BLE spec the peripheral opens an RX window for `CONNECT_IND` *after every ADV packet*, and that window is identical at 100 ms or 1 s spacing. The advertising interval changes *discovery latency*, not whether a `CONNECT_IND` is answered. So a 1 s interval shouldn't by itself produce a hard `0x3e`. That points more at (B) — or at a *bug* in the slow-adv path that makes it effectively non-connectable (the only real diffs from fast are interval + `ONE_TIME`, both nominally connectable).

### Instrumentation added (2026-06-08) — readable WITHOUT RTT
Surfaced over BLE + the app log, **persisted across power-cycle** so it survives the reboot the user must do to reconnect and read it (a failing device can't be connected to, so the count had to outlive the reboot). Zero battery cost (off the hot path; flash write is coalesced ~once per 10 s during a failure storm).

**Firmware (`transport.c` + `settings.c`):**
- `failed_conn_count` (atomic, **cumulative across boots** — seeded from flash in `transport_start` ~line 1491) + `last_failed_adv_slow` + `current_adv_mode` (`"slow"`/`"fast"`, set in `transport_set_adv_slow`/`_fast`, reset to `"fast"` in `_transport_disconnected`; boot default `"fast"`).
- `_transport_connected` err path (~line 858): increments the counter, records the adv mode, schedules a throttled flash persist (`conn_fail_persist_work`, `app_settings_save_conn_fail`), and still RTT-logs `Connection failed (err 0x3e) adv_mode=slow failed_conn_count=N …`.
- Persisted via Zephyr settings key `omi/conn_fail` (`struct conn_fail_record { count; last_adv_slow; }`).
- Exposed by **appending 8 bytes to the existing drops characteristic `0x19B10062`** (now 28 B: legacy 20 + `failed_conn_count` u32 @20 + `last_failed_adv_slow` u32 @24). No new characteristic — backward compatible (old app reads first 20).

**App:**
- `DeviceDropStats.failedConnCount` / `.lastFailedConnDuringSlowAdv` (parsed length-gated in `omi_connection.performGetDropStats`; 0/false on ≤20-byte firmware).
- **Debug Tools → "SD Write Drops" card** shows `BLE connect failures` + `Last fail adv mode` (`sync_page.dart` `_buildDropStatsSection`).
- **Logged on every connect** to `'Save Diagnostic Logs to File'** via `Logger.warning` + `DebugLogManager.logEvent('device_conn_fail', …)` when count > 0 (`device_provider._finishDeviceSetup`). So: reboot the Omi → reconnect with logging on → Share Logs → the pre-reboot count + last-failure adv mode are in the file.

**Decision tree for the next occurrence** (after it gets stuck, power-cycle the Omi to reconnect, then read Debug Tools / Share Logs — the count is persisted so it reflects the *pre-reboot* session):
1. **`failed_conn_count` increased (delta > 0) since you last checked** → the peripheral *was* receiving `CONNECT_IND` but the link died at establishment → **hypothesis (B)**: controller/RF wedge. Check `Last fail adv mode` (slow vs fast). Next step: BLE-recovery watchdog (on prolonged-disconnected + repeated failed establishments, full `bt_le_adv_stop`/restart, or controller reset) + investigate Wi-Fi/RF-switch coexistence and `MAX_CONN=1` slot cleanup in `_transport_disconnected`.
2. **`failed_conn_count` did NOT move** (you had failures but the counter stayed flat) → the `CONNECT_IND` never reached the device (peripheral never saw the connect) → asymmetric RF / RX or genuinely-not-listening. Then A/B: force slow vs fast adv and try many connects. If slow *consistently* fails and fast *consistently* works → **hypothesis (A)** real (slow-adv-path bug or raise the interval floor at a battery cost).
3. **`Last fail adv mode = fast`** → exonerates the slow interval → (B).

Note: cumulative-across-boots, so mentally baseline it (or snapshot the value now). The `0x3e` RTT line still exists for anyone who *does* have a probe attached.

### Battery note (for the eventual fix)
Advertising power only matters during long idle stretches (while recording, the mic/codec/SD dwarf it). The fast↔slow delta is ~300–500 µA. A watchdog (B-fix) is ~free if piggybacked on the existing AAD 100 ms loop and made mode-aware (restart adv in the *currently-intended* mode, not blindly fast). Raising the slow-interval floor (A-fix) is a real, permanent idle cost and should only be done if the instrumentation confirms (A).

### Related (already fixed, separate bug)
The Android-side `PlatformException(channel-error … requestCompanionDeviceAssociation)` seen first was a **different** problem: `AndroidManifest.xml` was missing `<uses-feature android:name="android.software.companion_device_setup">`, so `CompanionDeviceManager.associate()` threw `IllegalStateException` synchronously → pigeon surfaced it as the opaque channel-error. Fixed by adding the `uses-feature` + a defensive try/catch in `BleHostApiImpl.requestCompanionDeviceAssociation`. That fix is what let the flow progress far enough to expose this firmware-side `0x3e`.

### Code locations
- `omi/firmware/omi/src/lib/core/transport.c` — `failed_conn_count` / `current_adv_mode` / `last_failed_adv_slow` / `conn_fail_persist_work` (~line 302), failure path in `_transport_connected` (~line 858), 28-byte `diagnostics_drops_read_handler` (~line 372), boot seed in `transport_start` (~1491), `current_adv_mode` sets in `_transport_disconnected` (~937) / `transport_set_adv_slow` (~1439) / `transport_set_adv_fast` (~1459), `adv_param_slow` definition.
- `omi/firmware/omi/src/settings.c` + `src/lib/core/settings.h` — `omi/conn_fail` persistence (`struct conn_fail_record`, `app_settings_save_conn_fail` / `app_settings_get_conn_fail`).
- `omi/firmware/omi/src/aad.c` — slow/fast switch requests (`adv_slow_req`/`adv_fast_req`, ~lines 244–247, 298, 318, 452).
- `omi/firmware/omi/omi.conf` — `BT_MAX_CONN`, `BT_CTLR_TX_PWR_ANTENNA`, (absence of) `BT_PRIVACY`, `BT_PERIPHERAL_PREF_*`.
- `app/lib/services/devices/device_drop_stats.dart` — `failedConnCount` / `lastFailedConnDuringSlowAdv` on `DeviceDropStats`.
- `app/lib/services/devices/omi_connection.dart` — `performGetDropStats` length-gated parse of bytes 20–27.
- `app/lib/providers/device_provider.dart` — `_finishDeviceSetup` connect-time log (`device_conn_fail`).
- `app/lib/pages/settings/sync_page.dart` — `_buildDropStatsSection` "BLE connect failures" rows.
- `app/android/app/src/main/AndroidManifest.xml` — the `companion_device_setup` uses-feature (the separate fix).
