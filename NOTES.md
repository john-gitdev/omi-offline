# Notes

Running log of investigated bugs, deferred decisions, and findings that don't fit IDEAS or README.

---

## iOS support removed (2026-07-31) — how it worked and how to get it back

**Status:** deliberate, reversible. iOS is not a target for now. Nothing about it was
broken — the build worked; it was removed to shrink the maintenance and review surface.

### Restore point

Tag **`ios-last-working`** → `afc0eadf7`, the last commit with a working iOS build.

```bash
git checkout ios-last-working -- app/ios .github/workflows/ios-build.yml
```

Then re-apply the two **generator config** changes that were made in the same removal
commit (they are *not* under `app/ios/`, so the checkout above won't bring them back):

- `app/lib/pigeon_interfaces.dart` — re-add `swiftOut: 'ios/Runner/PigeonCommunicator.g.swift'`
  and `swiftOptions: SwiftOptions(),` to `@ConfigurePigeon`, then `dart run pigeon`.
- `app/flavorizr.yaml` — re-add the `ios:` blocks: prod `bundleId: com.omi.offline`,
  dev `bundleId: com.omi.offline.development`, both `icon: assets/images/app_launcher_icon.png`.
- `app/pubspec.yaml` — flip `flutter_launcher_icons.ios` and `flutter_native_splash.ios`
  back to `true`, and restore `remove_alpha_ios: true` under `flutter_launcher_icons`.
- `app/setup.sh` — the `run_build_ios()` function and its `ios)` case arm
  (`flutter pub get && pushd ios && pod install --repo-update && popd && dart run build_runner build --delete-conflicting-outputs && flutter run --flavor dev`).

**Do not** rebuild the project with `flutter create --platforms=ios`. That scaffolds a
stock Runner and drops ~2,700 lines of hand-written Swift that has no equivalent in a
fresh template: `OmiBleManager.swift` (the native BLE stack incl. `CBCentralManager`
state restoration), `AppDelegate.swift` (BGTaskScheduler registration), `BleHostApiImpl`,
`VadBatchRunner` (the native VAD batch path behind `vad_batch_runner_channel.dart`),
`WifiNetworkPlugin`, `AppleHealthService`, `AppleRemindersService`.

### Why the generator config had to change (the actual footgun)

Four generators **write** into `app/ios/`: pigeon (`swiftOut`), flavorizr (`ios:` blocks),
`flutter_launcher_icons` (`ios: true`) and `flutter_native_splash` (`ios: true`). Had any
been left pointing at iOS, the next `dart run pigeon` / flavorizr / icon / splash regen
would have silently recreated part of the deleted tree — `PigeonCommunicator.g.swift`,
flavor files, `Assets.xcassets` icons — a half-resurrected project that looks restored but
isn't. That, not the file deletion, was the risky part.

### What was deliberately kept

- **The 16 `Platform.isIOS` branches across 11 Dart files**, plus
  `services/vad_batch_runner_channel.dart` (123 lines). Dead code on Android and nearly
  free to carry, but they encode *why* iOS behaved differently — the GATT-cache refresh
  being skipped on iOS (no `refresh()`, relies on Service Changed), the native VAD batch
  path, DFU differences. Deleting them loses reasoning that git can return only as a diff
  nobody will think to look for. Expect them to bit-rot; that's accepted.
- **`opus_flutter_ios` override and the vendored `third_party/flutter_onnxruntime`** in
  `app/pubspec.yaml`. The vendoring exists *only* to lower that plugin's iOS podspec from
  16.0 → 15.1 so the app installs on iOS 15 devices. It costs nothing on Android, and
  un-vendoring is a separate, independently revertible change.

### What the iOS build was

Unsigned dev IPA built on a GitHub-hosted macOS runner (`ios-build.yml`,
`workflow_dispatch`-only to conserve 10×-billed macOS minutes), targeting **iOS 15.0**,
installed on a **jailbroken** iPhone 6s Plus via AppSync Unified / TrollStore — no Apple
Developer account, no signing. Signing for stock iOS was never done; that idea (Apple
Developer Program, CI signing secrets, TestFlight vs ad-hoc) was dropped from IDEAS.md
along with this removal and is recoverable from git history if a stock device ever
becomes a target.

### Consequence: the repo now has no CI

`ios-build.yml` was the **only** workflow, so `.github/workflows/` is empty — there is no
automated Android build or `flutter test` run on push. Worth adding one; unrelated to iOS.

---

## Diagnostics `uptime` is the PREVIOUS session's length — a red herring for live health

**Status:** not a bug (2026-07-12) — clarified while reviewing a "sync failed then crawled" log.

**Symptom that looks alarming.** The `Device diagnostics: software reset (uptime: 12h 40m)` line logs the *identical* value on every reconnect across a session — e.g. 12h 40m at 01:55, 02:07, and 02:11 in the same night. It's tempting to read a frozen uptime as a wedged RTOS / stuck `k_uptime`.

**It is neither live nor stuck — it's a static historical record.** The Diagnostics char `0061` returns `[uint32 reset_cause][uint32 uptime_seconds]`, where `uptime_seconds` is **how long the *previous* session ran before it ended**, not the current session's uptime (`transport.c` `diagnostics_read_handler` → `app_settings_get_crash_session_uptime()`, transport.c:409). It's snapshotted once into NVS at boot (`main.c:327-330`, `app_settings_save_crash_session_uptime(prev_uptime)`) and never changes during the session — so reading the same value across reconnects is *correct*, not a wedge.

**`reset_cause` here is also last-boot, and `software reset` (0x02) is benign.** `RESET_SOFTWARE` is a deliberate `sys_reboot()` (OTA swap, clean restart), *not* a crash — crashes set `RESET_WATCHDOG` (0x10) or `RESET_CPU_LOCKUP` (0x100) and log `CRASH —` (`main.c` `log_reset_cause`, `device_crash_log.dart` `isCrash`). So "software reset (uptime: 12h 40m)" means only "the last reboot was deliberate and happened 12h 40m into that prior run." It carries **zero** signal about the current session's transfer health.

**Consequence for diagnosis.** Do not treat this field as a live-health or wedge indicator (same trap as the `low power wake` red herring below). For *current*-session liveness use char `0062` offset 16 (`current_uptime_ms`, `k_uptime_get()` at read time) — that one is live. A slow/failing sync in the same log is better explained by background BLE throttling + an unstable background link than by any firmware stall.

---

## Change 2 (PR #337) adopts an unsanctioned background reconnect via `_shouldSyncNow()` — intentionally eager

**Status:** by design (2026-07-12) — noted during the PR #337 review (F4).

`_handleDeviceConnected`'s background drop-guard now keeps an unsanctioned reconnect (native auto-reconnect / BT-toggle recovery landing while backgrounded) instead of dropping it, **when `_shouldSyncNow()` is true**. `_shouldSyncNow()` is deliberately eager — it returns true on `lastSyncSkipped`, on `lastSyncCompletedMs <= 0`, or once the interval has elapsed. Manual-Only (interval ≤ 0) never adopts. This is the intended behavior; documented here so a future reader doesn't mistake the eagerness for a bug.

**What bounds it is native's retry cap, NOT a stamp on the failure path (corrected 2026-08-31).** This section used to say the rate-limit was `_doBackgroundSync`'s catch stamping `lastSyncCompletedMs` even when the sync failed, so the next unsanctioned landing read "not due" and dropped — "at most one adopt-per-interval". That was real, and it was the wrong mechanism: a *completion* stamp is how all three sync triggers learn when the last sync finished, so using it as a loop guard bought the rate-limit by pushing the whole schedule out an interval on every failure, and by clearing `lastSyncSkipped` it disarmed the very adoption this section is about. Observed 2026-08-31: setup died at `gatt_status_8` five seconds into a cycle, native had the link back three seconds later, and the adopt path declined it because the catch had just recorded a completion — six files waited another hour. The catch now records a skip and leaves the stamp alone (see "Background sync scheduling" in CLAUDE.md).

The eagerness is bounded anyway, in two places that were always doing the real work:
- **Native stops handing links back.** `AUTONOMOUS_RETRY_STOP_AFTER` (`OmiBleForegroundService.kt`) ends native's own retry loop after 6 consecutive failures and hands reconnection to the sync schedule. A genuinely broken link therefore yields a bounded burst of adopt-then-fail, not an unbounded loop — and rapid `connectGatt`/`closeGatt` churn is exactly what that cap exists to prevent.
- **The failed cycle re-anchors the schedule.** The catch calls `_anchorAutoSyncSchedule()`, so the *scheduled* fallback is a full interval out even though the opportunistic retry is immediate.

And the throw path was never the whole story: `syncAll` returning `null` (a failed `CMD_LIST_FILES`, the more common failure) has always set `lastSyncSkipped = true` **without** stamping, so "adopt on every reconnect until one succeeds" has been shipping for that path throughout. The change makes the throw path agree with it rather than inventing new behaviour.

**An adopted link used to be swallowed by the cycle it was adopted from (fixed 2026-08-31).** Two faces of one overlap, both worth knowing because the shapes recur.

*The intent was spent on a call that did nothing.* The adopt path sets `_pendingBackgroundSync`; `_onDeviceConnected` consumes it **before** calling `_doBackgroundSync()`, which could then return at its `_backgroundSyncActive` re-entrancy guard — the cycle that just failed is still in `processAllCompletedSessions()`, and the VAD isolate easily outlasts a ~8 s reconnect + setup. `_doBackgroundSync` now returns **whether it ran**, and `_startSanctionedBackgroundSync` puts the intent back when it did not. `Future<bool>` rather than a flag on purpose: the return type makes the compiler reject any future early `return;`, so a new guard cannot silently join the declining set. It ORs the flags back rather than assigning, so a fresh intent set while the call was in flight outranks the stale one.

*The cycle then dropped the link the adopted sync needed.* The end-of-cycle disconnect fired on "this cycle is over", which is not the same as "nothing wants the link" — the adopted sync's `_doBackgroundSync` threw `DeviceConnectionException` for want of a connection that line had just closed. It now skips while `_pendingBackgroundSync` / `_pendingSyncResume` is set. The link cannot linger from this: the keep-alive is stopped a few lines earlier, so the firmware idle-drops within ~60 s.

`_runDeferredSyncIntent` closes the last gap. A restored intent has exactly one consumer — `_onDeviceConnected` — so with the link now deliberately held open, nothing would drop it and nothing would reconnect to spend it; it resolved only via that ~60 s idle-drop and a native reconnect. The finishing cycle hands it over directly instead, from its `finally`, **after** clearing `_backgroundSyncActive` so the handed-off cycle is not turned away by the one handing it over. It cannot recurse: the intent is cleared before the nested cycle starts and only a fresh connect sets it again, and a cycle that did not run does not hand off.

A lingering intent is the known hazard here (`_connectThenSyncOrFail` and the timer's `finally` both clear it so a failed connect cannot leave it stuck true and bypass the drop guard). The restore cannot accumulate one: it is set only when a cycle declined *while connected*, and it is then either spent by the hand-off, spent by the next connect, or cleared by those two failure paths.

**Not unit-tested, and not cheaply testable.** No test in the repo constructs a real `DeviceProvider` — every one uses a fake that `implements` it — so these are ordering guarantees held by the code and this note. If it ever regresses, the harness to build is the one `firmware_mixin_test.dart` uses for the DFU ordering: the real object with only the platform channels mocked.

---

## iOS: BLE transfer stops "randomly" mid-sync → native storage keep-alive

**Status:** fixed (2026-06-17) — native iOS storage keep-alive added in `app/ios/Runner/OmiBleManager.swift`.

**Symptom.** On iOS, SD-card WAL sync drops the BLE link at random during a sync session. Logs show a non-manual disconnect with `error=…disconnected from us.`, immediately followed by `SDCardWalSync: Connection lost after failure, aborting syncAll`, then a fast (<1 s) auto-reconnect, repeating.

**It is not iOS dropping the link.** `"…disconnected from us."` is the `localizedDescription` of `CBError.peripheralDisconnected` (code 7) — the *peripheral* terminated the link. A real RF/supervision loss would instead read `"…timed out unexpectedly"` (code 6). The disconnect is device-side.

**`low power wake (uptime: <10m)` is a red herring.** That diagnostics line (decoded in `device_crash_log.dart`, bit `0x080`) reads a *persisted boot* reset-cause and is re-logged on every reconnect, so it doesn't describe any given drop. The only firmware path that sets `RESET_LOW_POWER_WAKE` (0x80) is waking from a deliberate **4-tap-hold power-off** (`button.c` `turnoff_all()` → `sys_poweroff()`). It is explicitly *not* a crash (crashes set watchdog/CPU-lockup bits and log `CRASH —`).

**Root cause.** The firmware idle-disconnects after **15 s** of no storage-characteristic GATT activity, terminating with `bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN)` (`transport.c` `idle_disconnect_work_handler`) → iOS code 7 ("from us"). That timer is only deferred while `storage_transfer_active()` is true, i.e. a *single file's* read is in flight (`storage.c`). The vulnerable window is **between files in a batch** (and just after a read completes), where the flag is false and only the app's keep-alive holds the link up.

The keep-alive resets the firmware idle timer only via **storage-char GATT activity** (the `0x32` HEARTBEAT write). On iOS it was sent solely from a Dart `Timer.periodic(5 s)` (`device_provider.dart` `_startForegroundKeepAlive`), which iOS does **not** schedule reliably once the process is parked in the background — worsened by the concurrent VAD-processing isolate. Two slipped beats (>15 s silent) → firmware idle-drops. The native RSSI keep-alive (`OmiBleManager.swift` `startRssiKeepAlive` → `readRSSI()`) keeps the *controller* link warm (so the 6 s supervision timeout doesn't fire) but is an HCI read, **not** storage-char GATT activity, so it can't reset the firmware idle timer.

**Fix.** Mirror what Android already does (`OmiBleManager.kt` `startStorageKeepAlive`, started on connect in `OmiBleForegroundService.kt`, stopped in cleanup): drive the `0x32` keep-alive from a **native CoreBluetooth-side timer** so it survives Dart runloop parking. Added to iOS `OmiBleManager.swift`:

- `startStorageKeepAlive(for:)` / `stopStorageKeepAlive()` / `sendStorageKeepAlive(to:)`.
- 5 s `Timer`, writes `0x32` to the storage char with `.withoutResponse` (bypasses the GATT response wait; never stalls an in-flight read).
- Skips while a native download is active for that peripheral — during a download the firmware already defers its idle-disconnect and the stream is its own liveness.
- Started in `didDiscoverCharacteristicsFor` right after `startRssiKeepAlive`; stopped in `cleanupPeripheral`. Always-on while connected — the connection lifecycle is the gate (the app only holds a link when it wants one and disconnects otherwise), matching Android.

The Dart keep-alive stays (foreground liveness + its force-disconnect-on-failure probe + Android); the native timer is the reliable idle-timer reset that works when iOS has parked the app.

**Trade-off.** This defeats the firmware idle-disconnect as a battery *backstop* while connected — acceptable because the app is responsible for disconnecting when idle (`_doBackgroundSync` finally; post-background grace timer), and Android already makes the same trade-off.

**Can't build iOS from the dev machine (Windows).** Verify on a Mac/device: background a sync with several files queued and confirm no `disconnected from us.` drops between files.

---

## VAD perf: timing diagnostics + native batch-runner plan

**Status:** session options shipped (0.16.7) · timing instrumentation shipped · **native batch runner SHIPPED on both platforms** (`VadBatchRunner.kt` + `VadBatchRunner.swift` + Dart `vad_batch_runner_channel.dart`, wired unconditionally into the processing isolate; Android in app 0.19 / 2026-06-10, iOS port after). **⚠️ The 2026-06-02 investigation below concluded the runner was the "sole lever, ~2× ceiling" against a fixed ~2.1 ms compute floor — that forward-looking conclusion was FALSIFIED by the implementation:** measured ~0.3 ms/window batched ≈ **~14× faster, ~73 % off total processing** (not the projected ~37 %), because the "~2.1 ms unreducible compute floor" was almost entirely per-call channel/setup overhead that batching amortizes, not model dispatch. The dated analysis is kept below as the historical reasoning — read it knowing its conclusion was overturned.

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

**⚠️ SUPERSEDED (see Status at top):** the "~2.1 ms fixed compute floor / ~2× ceiling" conclusion below did **not** hold — the shipped batch runner measured ~0.3 ms/window (~14×, ~73 % off processing). The supposed floor was per-call overhead, not model compute. Kept as the historical 2026-06-02 reasoning.

**Conclusion (as reasoned 2026-06-02): the ~2.1 ms compute is fixed for this model on this runtime. The native batch runner (channel half) is the sole lever — ~2× ceiling, identical math, zero accuracy risk.** Tooling lived in `~/AppData/Roaming/Python/Python314/site-packages` (onnxruntime 1.26 + onnx 1.21 + sympy); throwaway scripts in `%TEMP%/vadquant`.

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

### Native batch runner (lever #2b) — SHIPPED (was deferred 2026-06-02, then built)

Built as planned: a self-contained `VadBatchRunner` channel (`VadBatchRunner.kt` + `VadBatchRunner.swift`, Dart side `vad_batch_runner_channel.dart`) + the two-pass refactor of `processSegmentFile` (`_applyVadVerdict` extraction + deferred-verdict replay). **Shipped on Android in app 0.19 (2026-06-10); iOS port shipped after.** The realized win was far larger than the "~2× on VAD ≈ ~37 % off processing" projection: **~0.3 ms/window batched ≈ ~14× faster, ~73 % off total processing** — the projected "~2.1 ms fixed compute floor" was mostly per-call channel/setup overhead that batching collapses, not model dispatch. (The buildable spec that used to live in `IDEAS.md` → "VAD Native Batch Runner" was removed once it shipped; see commits `fabd22bd6` → `58d4df46b` → `eef166d42`.)

---

## Bug: discarded bins reprocessed every sync cycle — FIXED (2026-06-02)

**Symptom:** after sync the UI shows "22 min / 14 min of audio to process" but creates no new entry, and old bins re-run VAD every cycle. Surfaced while testing with no speech (adjustment mode off) — so every bin is noise, maximally visible.

**The machinery that *should* prevent this (pre-existing, and it's correct):** when VAD discards a conversation as noise/too-short, it persists a discard record to `recordings/<localDate>/discards.jsonl` and `processAll` strips any bin with a discard record from the next run (the bins linger on disk for the 48 h recovery window, then the sweep deletes them). So a discarded bin should NOT re-run VAD.

**Why it failed (the actual root cause):** the strip set was derived only from the *handed-in* batches' discards (`processAll`: `batches.expand((b) => b.discards)`), and that set came up empty because of a **date-key mismatch**:

- Raw-segment batches were keyed by `DateTime.fromMillisecondsSinceEpoch(ts)` (the buggy read, now in `recordings_manager.dart` near the `getBatches` date-keying ~`:220`) — but `ts` is the bin filename's epoch **seconds** (e.g. `1780375808`). Treated as ms, every UTC-stamped bin lands in a **1970** batch.
- Discard records are filed under the conversation's real **local date** (2026-06-02).
- So the bin's batch (1970, has rawSegments) and its discard record's batch (2026, no rawSegments) never coincide, and callers pre-filter with `.where((b) => b.rawSegments.isNotEmpty)` — dropping the 2026 discard-only batch before `processAll` sees it. Strip set empty ⇒ every discarded bin re-runs VAD forever, and the byte-based "minutes to process" estimate (computed straight off `rawSegments`) re-counts them.

Confirmed in the log: the 07:20 run reprocessed 12 bins from 04:50–06:44 already discarded in the 06:39 run; `pruneConsumedBins` deleted only the 4 bins covered by the real 07:14–07:18 speech recordings.

**Fix (shipped):** new `RecordingsManager.discardedRelBinPaths()` reads the **full** persisted discard set (all `discards.jsonl`), AM-gated, mirroring `getDiscardsForDate`'s `silence_trimmed` skip. Used by both `processAll`'s strip and the three post-sync estimate sites in `recordings_controller.dart` (`_isProcessableBin`), so reprocessing stops and the displayed minutes match what's actually processed. Robust to the mis-dating without touching batch identity. Recover/Delete/sweep still remove the record → bin re-enters; Adjustment Mode still keeps all bins.

**Root mis-dating — also FIXED.** The seconds-as-ms read is corrected to `_dateStringFromMillis(ts * 1000)` (`recordings_manager.dart` ~`:225`; the canonical local-date helper, with the `kMinValidEpoch` 946684800 threshold; uptime/unparseable names still fall back to mtime). Raw bins now group under their real date alongside same-day recordings/discards. Regression test added: `getBatches groups epoch-second bin filenames under the real date, not 1970`.

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
3. **Breathing continues** — `boot_warming_sequence()` spin-waits for the SD worker to finish the card power-on + ring mount (fast and roughly constant; before `oo-2.9.0` this also waited on the LittleFS `lfs_fs_gc` pre-warm, which ran up to ~50 s with 200 MB on the card)
4. **Mic starts** — `mic_start()` runs once SD is ready
5. **Breathing stops, solid white → fade to off** — `boot_ready_fade()` holds solid white (R+G+B at `dim_ratio`) for 1 s, then fades all three channels down to 0 over ~1000 ms (100 × 10 ms steps). Main loop's `set_led_state()` (500 ms cadence) then takes over.

### LED State Machine (`set_led_state()`, runs every 500ms)

Priority order (highest first):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off (`is_off`) | Off |
| 2 | Fatal SD fault (`sd_fatal_error`) | **Blinking Red** (toggles each loop pass) — overrides stealth/mute/marker/charging; distinguishable from solid-red mute |
| 3 | Charging starts (`is_charging && !prev_is_charging`) | Save + force `is_led_enabled = true`, continue (restored when charger removed) |
| 4 | Marker flash (`marker_flash_count > 0`) | Solid `marker_flash_color`: **White** = auto marker, **Green** = manual-mode start, **Red** = manual-mode stop — overrides stealth |
| 5 | Stealth mode (`!is_led_enabled`) | Off |
| 6 | Muted | Solid Red |
| 7 | Low battery (< 10%) | Solid Purple (R+B) |
| 8 | BLE connected | Solid Blue (wins over recording state) |
| 9 | Manual recording active (AAD threshold == 65535) | Solid Yellow (R+G) |
| 10 | AAD auto-recording (`aad_is_recording()`) | Solid Yellow (R+G) |
| 11 | Idle / disconnected / standby | Off |

### Charging Override
Applied on top of the base state above:
- **Fully charged (≥ 98%):** Solid Green
- **Charging:** Blinks every 500ms between Green and the current base color (e.g. Green ↔ Blue if connected, Green ↔ Yellow if recording)
- Plugging in charger automatically disables Stealth Mode (`is_led_enabled = true`)

### Button Controls

**The 1–3-tap gestures are now user-configurable**, not hard-coded. `execute_button_action(taps, is_hold)` reads a 6-byte map via `app_settings_get_button_config()`, indexed `(taps-1)*2 + is_hold`, into a `button_action_t` (`BUTTON_ACTION_NONE=0`, `MUTE=1`, `MARKER=2`, `TOGGLE_LED=3`). `HOLD_TIME` = 1000 ms. The **4-tap and 5-tap** gestures below are fixed (handled directly in `check_button_level`, not via the config map).

Default config `{0, 0, 2, 1, 3, 0}` (`settings.c`) gives the out-of-box behavior:

| Gesture | Default action | Effect | Haptic |
|--------|--------|--------|--------|
| Single tap (± hold) | None | No action | None |
| Double tap | Marker | Marker flash (white; **green** on manual-mode start / **red** on manual-mode stop), `write_marker_to_storage()` — ignored if muted. In manual mode, toggles recording (sets AAD threshold 65535/32769) instead of writing a plain marker. | None |
| Double tap + hold (≥1s) | Mute | Toggle Mute — LED solid Red when muted, mic paused. Suppressed/no marker in manual mode. | None |
| Triple tap | Toggle LED | Toggle Stealth Mode (`is_led_enabled`) | None |
| Triple tap + hold (≥1s) | None | No action by default | None |
| **4-tap + hold (≥3s)** | *(fixed)* | Power off (`turnoff_all()`) | 100ms |
| **5-tap + hold (≥10s)** | *(fixed)* | Unpair — `bt_unpair(BT_ID_DEFAULT, BT_ADDR_LE_ANY)` clears all BLE bonds; red LED blinks ×3 | 1000ms |

### Hardware Error LEDs
The legacy `error_*()` functions in `feedback.c` log to UART/RTT only — no LED, and nothing ever called them, so the file is now parked (see "Other parked files" below). **The one exception is a fatal SD fault**, which `set_led_state()` surfaces as a **blinking red** LED (priority 2 above; `sd_fatal_error`). It overrides stealth/mute/marker/charging and toggles every ~500 ms loop pass, so it's distinguishable from solid-red mute. This is the only visual error indicator.

### Stealth Mode Notes
- Triple tap (default mapping) toggles `is_led_enabled`
- Stealth suppresses all base state LEDs (priority 5)
- Stealth does **not** suppress the marker flash (priority 4 fires first), nor a fatal-SD blink (priority 2)
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

- **~~BT TX power~~ — WITHDRAWN, the entry was wrong twice over.** It named
  `CONFIG_BT_CTLR_TX_PWR_ANTENNA=8` in `omi.conf`, which never did anything: that file
  configures the **application** core, which runs the BLE host only
  (`boards/omi/Kconfig.defconfig` gives cpuapp `BT_HCI_IPC` and gives `BT_CTLR` to cpunet),
  so every `BT_CTLR_*` symbol belongs to the **network** core — and `8` is the nRF52840's
  ceiling, not this chip's, which the line's own comment said out loud. The real setting is
  `CONFIG_BT_CTLR_TX_PWR_PLUS_3` in `boards/omi/omi_nrf5340_cpunet_defconfig`. The dead line
  is now gone.
  **Do not pursue it there either.** Idle TX duty is ~0.1 % — one advertising event per
  second, three channels, ~320 µs each — so +3 → 0 dBm is worth single-digit µA. Compare the
  fast→slow advertising change, which cut the *number* of events tenfold and bought
  300–500 µA (`adv_param_slow`, `transport.c`). Interval is a 10× lever; TX power is a
  ~1.5× lever on a 0.1 % duty cycle, and it costs 3 dB of link margin on a device whose
  acquisition is already marginal (BLE_Research.md, Wedge 9, −88/−93 dBm).
  `CONFIG_BT_CTLR_TX_PWR_DYNAMIC_CONTROL` is already on in that defconfig, so per-role
  runtime control needs no Kconfig change if this is ever revisited with a PPK2 in hand.
- **~~BLE connection interval~~ — DONE (`oo-3.0.0`).** Superseded by the two-set scheme in
  `transport.c`: `CONN_PARAM_IDLE_*` (100–200 ms) and `CONN_PARAM_XFER_*` (7.5–22.5 ms),
  selected from `storage_transfer_active()` in the idle-disconnect poll. The old entry's
  worry — that a longer interval would starve the audio path — does not arise, because the
  transfer set keeps the historic values and only the idle link is slowed. `latency` stays 0
  in both on purpose: slave latency would cut idle cost further but delays
  central→peripheral commands by `latency × interval`, and everything on this link is
  command/response.
- **~~IMU gyro left running (~1 mA)~~ — RULED OUT from the build, no device needed. The accel
  next to it was the real find, and is now fixed.** The suspicion was that
  `lsm6dsl_force_minimal_run_mode()` asks the gyro for 0 Hz, discards the return code, admits
  in its own comment that "not all drivers accept 0 Hz", and has had logging compiled out
  since `oo-2.10.0` — so nobody had ever confirmed the request lands. Three facts from the
  tree settle it:
  - `CONFIG_LSM6DSL_GYRO_ODR` and `CONFIG_LSM6DSL_ACCEL_ODR` are both **0** ("selected at
    runtime") in the generated `.config`, and `lsm6dsl_init_chip()` writes each straight into
    ODR_G / ODR_XL. **Both halves come up powered down**, so there was never a free-running
    gyro to find.
  - The driver *does* accept 0 Hz — `lsm6dsl_odr_map[0] == 0`, so `freq_to_odr_val(0)` returns
    index 0 rather than `-EINVAL`. The "not all drivers accept 0 Hz" caveat was never true of
    this one.
  - Init order makes the reads meaningful: I2C (prio 50) → the `lsm6dsl_en_pin`
    `regulator-fixed` with `regulator-boot-on` (75) → LSM6DSL (90), so the part is powered
    before the driver configures it.

  **What was actually wrong: the accelerometer, and it is not idleness.** The accel must keep
  running or the part gates its internal timebase and the 24-bit timestamp counter stops — and
  that counter *is* the System OFF time bridge. So `lsm6dsl_force_minimal_run_mode()` turning
  the accel **on** at 12.5 Hz is correct and load-bearing, despite the name. But `XL_HM_MODE`
  (CTRL6_C bit 4) **resets to 0 = high-performance**, and high performance on this part is
  ODR-independent: 12.5 Hz costs the same ~170 µA as 6.6 kHz. Since nothing reads the samples
  (there is no accelerometer driver in the build at all), that accuracy buys literally nothing.
  `lsm6dsl_set_accel_low_power()` now sets `XL_HM_MODE = 1` **before** the ODR, so the accel
  never spends an interval in high-performance mode. Roughly an order of magnitude less, and
  it lands where it matters most — during System OFF the IMU is one of the very few things
  still drawing.
  **Confirmed on-device 2026-08-19** (`oo-3.0.8`, first boot after the flash), which turns
  every inference above into a measurement. `DIAG_IMU_POWER_STATE` returned `arg0 = 0`
  (bus read fine, and both `sensor_attr_set` calls returned 0 — so the driver really does
  accept 0 Hz for the gyro) and `arg1 = 0x10021080`:
  `CTRL1_XL = 0x10` → ODR_XL 0x1, accel at 12.5 Hz; `CTRL2_G = 0x02` → ODR_G 0, gyro
  powered down; `CTRL6_C = 0x10` → **XL_HM_MODE = 1, low-power mode took**. Exactly the
  predicted healthy reading.
  **Now measured too (2026-08-19, same device, once bins existed):** the counter keeps
  ticking in low-power mode, accurately. Between two bins of one session with no
  checkpoint in between, it advanced 6521 ticks — 41 734 ms at 6.4 ms/tick — across
  41 885 ms of uptime, i.e. **99.6 %**. The one way this change could have failed
  silently does not happen.
  **Do not "fix" this by powering the accel down.** That stops the timestamp counter and
  silently breaks the cross-reboot time bridge, which fails in the direction nobody notices
  until recordings are mis-dated. Confirm on-device via `DIAG_IMU_POWER_STATE` (19): a healthy
  reading is `CTRL2_G == 0`, `CTRL1_XL == 0x10`, `CTRL6_C == 0x10`.
  **The low-power write has no gap, despite the odd placement.**
  `lsm6dsl_force_minimal_run_mode()` is the only thing in the tree that writes an accel ODR at
  all, and it is reached from exactly one place —`lsm6dsl_time_prepare_for_system_off()`, which
  returns early on `!rtc_is_valid()`. `lsm6dsl_time_boot_adjust_rtc()` never touches ODR. So
  before the first time-sync of a boot the accel is **OFF** (the driver's init left it there),
  not sitting in high-performance mode, and from the first time-sync on it is switched on
  low-power-first. There is no window in which it runs high-performance. (An earlier revision
  of this entry claimed otherwise; it was wrong.)
  What the placement *does* mean is that **there is no IMU setup in the boot path at all** — the
  timestamp counter is only enabled by a time-sync or a System OFF prep. That is a time-bridge
  question, not a power one.
  **Unverified, and it would matter more:** `lsm6dsl_init_chip()` opens by setting
  `CTRL3_C.BOOT`, on every boot, before `lsm6dsl_time_boot_adjust_rtc()` gets to read the
  counter. If that reboot clears TIMESTAMP0..2 the cross-restart bridge recovers nothing and
  has never worked — the failure is silent either way, since a zero delta just looks like a
  fast reboot. Worth confirming on-device before any further work on the bridge; the
  `boot adjust: ts_now=` / `delta_ticks=` log lines answer it directly.
- **The auto-mode mic never parks, and that is deliberate — it buys the pre-roll.**
  `mic_should_run()` (`aad.c`) returns true outright whenever `vad_threshold != 32769`,
  and 32769 is the manual-standby value, so in auto mode the mic, the PDM peripheral and
  the HFXO that PDM holds up are powered continuously whether the room is silent or not.
  That is milliamps, all day, and it dwarfs every µA item in this section.
  **It is not an oversight.** Auto mode keeps the mic hot so the *beginning* of an
  utterance is already captured when the VAD decides to keep it. Park the mic and the
  T5838's AAD wake, the PDM restart and the settling time all happen after the sound has
  started, so every recording opens with a clipped word.
  The hardware to do otherwise is present and wired: `pdm_wake_pin` (P1.2) has a real ISR
  in `aad.c`, and `mic_pause()` / `mic_resume()` / `aad_note_capture_gap()` /
  `mic_prearm` / `force_wake_until_ms` are all already used by manual standby. What is
  missing is only the decision, because the trade is pre-roll for battery and that is a
  product call, not an optimisation. **Do not "fix" this as if it were a bug** — the
  owner has weighed it (2026-08-19) and is keeping the pre-roll for now. Anyone
  revisiting it needs a PPK2 to size the saving and real speech to judge the clipping,
  not a code review.
- **Where the remaining battery actually is: capture duty, not idle.** `aad.c`'s own comment on
  `vad_voiced_ms` says it — the share of the day the VAD holds a recording open "governs how
  much of the day is encoded and written, and so [is] the largest remaining battery lever".
  Idle work is µA; recording is mA (mic + PDM + the HFXO it holds up, Opus encode, NAND
  writes). Read `vadVoicedMs` against `nowUptimeMs` (`0x0062`, offsets 88 and 16) off a device
  after a normal day before optimising anything else.
  **Do not confuse the two silence timers** — they are unrelated and only one costs power:
  - `CONFIG_OMI_VAD_HOLD_MS` (`omi.conf`, **10 s**; the Kconfig default of 3 s is overridden)
    is the **firmware** tail. At 10 s of silence `aad_process_audio()` clears
    `vad_is_recording`, pauses SD writes and drops advertising to slow (`aad.c:620`). This is
    the on-device lever. Note it does **not** stop the mic in auto mode — auto never parks, so
    the mic/PDM/HFXO floor is paid regardless; the hold gates the write + encode tail only.
  - `vadSplitSeconds` (**120 s** default) is **app-side only** — `VadAudioProcessor` and
    `RecordingsManager` use it to decide where to *split* already-captured audio during the
    decode pass on the phone. By the time it is applied the audio is long since encoded and on
    the card, so it has **zero** effect on device power. Changing it changes recording
    boundaries in the UI, nothing else.

- **Idle CPU wakeups — `aad.c` done, two left (and both are small).** Three threads poll on a timer
  with nothing to do in the dominant idle state: `aad.c` `aad_thread_fn` at 10 Hz
  (`k_sem_take(&aad_sem, K_MSEC(100))`), `mic.c` `mic_thread_function` at 10 Hz (the
  `k_sleep(K_MSEC(100))` in its `!mic_running` branch — which runs **only** while the mic is
  parked, i.e. exactly the manual-standby state the `oo-2.10.0` gate created), and `main.c`'s
  loop at 2 Hz (`k_msleep(500)`). ~22 wakes/s doing nothing. Same class of defect as the
  25 Hz button poll fixed in "Button: Interrupt-Driven" above; these three never got the same
  treatment. Notes on each, in descending order of value-per-risk:
  - **`aad.c` — DONE.** All seven `atomic_set` of the four flags the loop reads
    (`wake_pending`, `sd_pause_pending`, `adv_slow_req`, `adv_fast_req`) were already paired
    with `k_sem_give(&aad_sem)` (lines 316/404/460/610–611/630–631/737/848–849), and nothing
    in the loop body is time-driven, so the 100 ms timeout was pure polling. The semaphore's
    limit of 1 is not a hazard: one pass handles all four flags, so coalesced gives cannot
    lose an event. Now `K_FOREVER`. **Anything added to that loop must signal the semaphore
    or it will never run.**
  - **`mic.c` — use a bounded wait, NOT `K_FOREVER`.** Four sites set `mic_running = true`
    (`mic_start`, `mic_resume`, `mic_reset`, `mic_on`) and would each need to signal. More to
    the point, `mic_pause()` and `mic_reset()` both have STOP-failure bail paths that leave
    `mic_running` disagreeing with the hardware, so it is not a reliable wait predicate. A
    missed signal under `K_FOREVER` means the mic never captures again — the 14.5-hour
    silent-capture failure mode of BLE_Research Wedge 4. A `K_SECONDS(5)` backstop gives
    10 Hz → 0.2 Hz (99 % of the saving) and self-heals.
  - **`main.c` — lowest value, highest risk; do last or not at all.** Only 2 of the 22 wakes.
    `set_led_state()` is a polling display refresher over ~9 asynchronous inputs (mute,
    charging, connection, battery, threshold/recording state, `is_led_enabled`,
    `sd_fatal_error`, `marker_flash_count`), none of which notify the loop. The 30 s watchdog
    leaves plenty of headroom, but that is not the binding constraint — state-change latency
    is. Note `marker_flash_count` is *decremented once per loop pass*, so the flash duration
    is measured in passes, not milliseconds: slowing the loop stretches and delays every
    button flash unless all five setters in `button.c` also signal it.
- **~~Disable logging in production~~ — DONE (`oo-2.10.0`).** `CONFIG_LOG` was already off; `CONFIG_SERIAL=n` landed in `oo-2.10.0`. See "Firmware: logging is compiled out" below for what that costs and how to get logs back.

### Mic gating in manual standby (implemented, `oo-2.10.0`)

At threshold `32769` (manual standby) nothing acoustic can start a recording —
`has_voice` needs the `65535` sentinel or a button force-wake, and `avg|PCM|` cannot reach
32769 — so the PDM peripheral, the HFXO it holds up (`&pdm0 clock-source = "PCLK32M_HFXO"`,
requested by the dmic driver for as long as the stream runs) and both mics are pure load.
`aad_apply_mic_gate()` (`aad.c`) parks capture there and resumes it for any other threshold.

Two invariants:

- **Derived, not commanded.** Every producer of "should we be recording" funnels through
  `aad_set_threshold()` — button, BLE write, boot restore, priority safety cap — plus mute,
  which owns the other input and therefore also calls the gate. A caller that flipped the mic
  itself would fix its own path and leave the others wrong, two of them recording silence.
- **dmic STOP/START, never PDM_EN.** Same mechanism mute has used forever. Nothing here drives
  P1.4; see IDEAS.md "Mic rail (PDM_EN) is not driven by firmware".

Costs the ~0.8 s pre-roll before a manual start-tap (the ring is empty when capture starts) and
makes `DIAG_VAD_LEVEL` go quiet during standby *by design* — a zero-peak window while parked is
expected, not a wedge.

---

## Firmware: logging is compiled out — how to turn it back on

Since `oo-2.10.0` the build has **no logging path at all**: `CONFIG_LOG` is unset, `CONSOLE`,
`PRINTK`, `UART_CONSOLE` are `n`, `SHELL=n`, RTT is not enabled, and `CONFIG_SERIAL=n` removes
the UARTE driver itself.

**Consequence worth remembering:** every `LOG_ERR`/`LOG_WRN` in the tree is a no-op, so failures
that only report through them are *silent* on a shipping device — `mic_resume()`'s "START
trigger failed", `sd_set_io_low_power`'s suspend warnings, the conn-param retry exhaustion. If
you are chasing one of those, you need one of the paths below, or the diagnostic event log.

**Prefer the event log first.** `CONFIG_OMI_DIAG_LOG` (already on) + the Debug Tools toggle gives
timestamped on-device records over BLE with no cable and no rebuild. It answers most questions
these logs would, and it is the only option on a device that is already in the field.

### Path A — RTT (no cable beyond the debug probe, no UART, `SERIAL` stays off)

In `omi/firmware/omi/omi.conf`:

```
CONFIG_LOG=y
CONFIG_USE_SEGGER_RTT=y
CONFIG_LOG_BACKEND_RTT=y
CONFIG_LOG_BACKEND_UART=n
CONFIG_LOG_DEFAULT_LEVEL=3          # 4 = DBG; the VAD/mic modules are chatty at 4
CONFIG_SEGGER_RTT_BUFFER_SIZE_UP=4096   # default 1024 drops lines under load
```

For `printk()` as well as `LOG_*` (main.c's boot line, mcuboot-era prints):

```
CONFIG_CONSOLE=y
CONFIG_PRINTK=y
CONFIG_RTT_CONSOLE=y
CONFIG_UART_CONSOLE=n
```

Read with `JLinkRTTViewer`, or `west attach`-adjacent tooling against the app core.

**Deferred vs immediate.** Default is deferred: a log thread drains the buffer, so lines can be
lost on a hard fault and timestamps lag. `CONFIG_LOG_MODE_IMMEDIATE=y` prints in the calling
context — essential for crash-adjacent logging, but it *changes timing*, which matters here:
several of this firmware's bugs (marker drops at the SD pause gate, the priority rotate race)
are timing-sensitive and can vanish or move under immediate mode. Start deferred.

**RAM cost.** The app core sits at ~89 % of 440 KB. RTT up-buffer (4 KB above) plus the deferred
log buffer plus the log thread stack come out of the ~48 KB free — fine for a debug build, but
do not ship it, and re-check `sd_msgq_peak_depth` if you leave it on while testing the audio path.

### Path B — UART console (needs `SERIAL` back plus a wired adapter)

```
CONFIG_SERIAL=y
CONFIG_CONSOLE=y
CONFIG_PRINTK=y
CONFIG_UART_CONSOLE=y
CONFIG_LOG=y
```

Pins are TX **P0.3** / RX **P0.2** at 115200 (`boards/omi/omi-pinctrl.dtsi` `uart0_default`,
`boards/omi/omi_nrf5340_cpuapp.dts` `&uart0`); `zephyr,console = &uart0` is already in the
board's `chosen` block, so no DTS change is needed.

**This is the path that costs idle current even when unused** — which is why `SERIAL=n` landed.
With `CONFIG_SERIAL=y` Zephyr instantiates the UARTE driver for the enabled `uart0` node and
`uarte_periph_enable()` leaves the receiver armed (`nrf_uarte_enable` + `STARTRX` with a 1-byte
DMA buffer), holding up the 16 MHz clock domain forever whether or not anything is listening.

### Other images

- **Net core** (BLE controller): its own image — add log config to `omi/firmware/omi/sysbuild/ipc_radio.conf`, not `omi.conf`.
- **MCUboot**: `omi/firmware/omi/sysbuild/mcuboot.conf` (`CONFIG_MCUBOOT_LOG_LEVEL_WRN` is already set); it needs its own console/serial symbols to actually emit.

---

## Firmware: SD Write Queue Configuration

**Location:** `omi/firmware/omi/src/sd_card.c`

**Current values (`sd_card.c:48`):**
```c
#define SD_REQ_QUEUE_MSGS  120   // main audio write queue depth
#define SD_PRIO_QUEUE_MSGS  10   // priority queue (control requests)
#define MAX_READS_BETWEEN_WRITES 6  // write fairness: force a write turn after N reads
#define WRITE_FAIR_MIN  4        // write fairness: min writes drained per forced turn
#define WRITE_BATCH_COUNT  100   // frames accumulated per write batch
#define SD_FSYNC_INTERVAL_MS (60 * 1000)  // fsync every 60s
```

Each slot in `sd_msgq` holds one `sd_req_t`, which embeds a `uint8_t buf[MAX_WRITE_SIZE]` (440 B) directly — so the queue's RAM cost is ~`SD_REQ_QUEUE_MSGS × 452 B` (440 B buffer + type/len/ptr). At 120 that's **~53 KB** — the largest single RAM consumer in the app core (the ring's 40 KB append stage is next). A `k_mem_slab` refactor (pointer-in-slot instead of embedded buffer) was tried and **reverted** — same buffer depth = same RAM, no win. The only lever to shrink the queue's RAM is the slot **count**: each slot dropped frees ~452 B.

**Write fairness (`0095b1fa8`, 2026-06-10) is now what holds the line — not depth.** The priority (read) queue is normally drained first, but a steady read stream during an active sync must not starve audio writes. The worker forces a write turn after `MAX_READS_BETWEEN_WRITES` (6) consecutive reads and drains at least `WRITE_FAIR_MIN` (4) writes before yielding back to reads. This bounds write latency to ~6 read-ops regardless of read pressure, so the queue depth no longer has to absorb full read-burst diversions — which is why the depth could come back down from 150 to 100 without re-introducing the sync-time drops (see history below). Two new since-boot observability counters track headroom: `sd_msgq_peak_depth` (high-water mark of occupancy vs the queue limit — 120 as of `oo-2.6.2`, 100 before) and `write_fair_activations` (times fairness engaged); both are surfaced in Debug Tools (see "SD Write Drop Counters").

`SD_FSYNC_INTERVAL_MS` (60 s) is the wall-clock backstop on durability: audio is claimed only once the ring commits its cursor, which happens on whichever comes first — `RING_SYNC_BYTES` (256 KB ≈ 52 s) of appended audio, a segment rotation, a critical marker, or this 60 s timer. A hard power-off in that window loses up to ~1 min of tail audio; it can never corrupt what came before, because the log is append-only and bytes past the last cursor record were never claimed.

The `sd_boot_ready` gate prevents the queue from filling during the card power-on + mount window and during bursts of rapid audio ingestion.

### Depth history — 120 today (do not re-litigate without data)

**Current value: 120** (`oo-2.6.2`, 2026-07-18 — see the allocator-scan section below). It was **100** for the whole write-fairness era before that, and the reasoning in this section is written against that 100 baseline; read it as the history that justified 100, then the +20 for allocator-scan headroom on top. The depth has been a repeated tug-of-war between RAM and **audio frame drops during BLE sync**. Trajectory (git):

| Commit / date | Value | Reason |
|---|---|---|
| LittleFS migration | 100 | initial |
| `2c6db1be8` (Mar 23) | **25** | RAM recovery (−34 KB); claimed "25 slots = 500 ms backpressure" |
| `443d4c860` (BLE sync work) | 100 | bumped back during sync/stability work |
| `5d6d20fe8` (Apr 3) | **200** | **"to prevent frame drops"** (companion: `a1bf73ef8` "diagnose SD queue contention during BLE sync") |
| `252d3b0f1` (oo-1.4.0) | 100 | RAM |
| `b577639bc` (Jun 8) | **150** | settled compromise — RAM-affordable, still above the depth that dropped |
| `0095b1fa8` (Jun 10) | **100** | **write fairness added** — reads can no longer starve writes, so depth no longer has to absorb read-burst diversions; dropped back to 100 for RAM |
| 2026-07-18 | **120** | **allocator-scan headroom** — a second, previously-unaccounted stall class (the LittleFS block-allocator traversal, below) can peg the queue independent of sync; +20 slots adds only ~1.7 s at the ~5,100 B/s ingest (100→120 = ~8.6→10.3 s total tolerance) but rides out the short scans; long ones are left to the doubled lookahead + keeping the FS emptier |

**The binding constraint was read/write contention during phone sync** — NOT steady-state SD stalls. Audio writes and BLE file reads share one SD-worker thread; while the worker served a read burst it stopped draining the write queue, which then filled at the audio ingest rate and dropped frames. A bigger queue absorbed those diversions (100 demonstrably dropped frames during sync, which is why it went to 200, then settled at 150). **As of `0095b1fa8` the contention is addressed structurally by write fairness** (forced write turns, see above), not by queue depth — which is why the depth could safely return to 100. Before changing either lever, re-run a heavy sync-while-recording test and watch the drop counters + `sd_msgq_peak_depth` (see "SD Write Drop Counters" section).

**Rate note (the "2–4 s vs 13 s" confusion):** the Mar 23 commit assumed 25 slots = 500 ms (≈50 blocks/s → 100 = 2 s, 200 = 4 s). On-device measurement (`audio/stats.txt`) showed ~5,100 B/s, i.e. ~11.6 blocks/s → 150 = ~13 s, 100 = ~8.6 s. The queue holds **encoded Opus**, not PCM, so it fills ~6× slower than the 32 KB/s mic rate. The two estimates were never reconciled, but the *observed* drops at 100 settle the decision regardless.

### The second stall class: LittleFS allocator traversal (2026-07-18) — RESOLVED in `oo-2.9.0`

> **Historical.** This is the stall class the ring backend was built to eliminate, and removing LittleFS in `oo-2.9.0` retired it for good: a raw append-only log has no free-map to rebuild, so there is no scan to stall on. Kept because it is the rationale for the ring, and because the queue depth of 120 was sized partly around it.

The "read/write contention during sync" story above is not the whole picture. There is a second, **sync-independent** way to peg `sd_msgq`: the LittleFS block allocator. When its lookahead window drains, `lfs_alloc` runs a **full-FS traversal** (`lfs_alloc_scan → lfs_fs_traverse_`) that reads every block of every file on the single SD-worker thread — **10–50+ s on a full card** (`sd_card.c` lookahead comment, ~line 114). While it runs, writes queue and eventually drop. This is intermittent (fires only when the window drains, ~every `LFS_LOOKAHEAD_SIZE × 8 × block_size` bytes written) and its duration scales with how full the SD is. It is the likely cause of the peak-depth spiking toward the ceiling **without** an active sync — a case write fairness cannot help, because fairness interleaves discrete ops and cannot preempt one long `lfs_*` call.

**Two mitigations landed (2026-07-18):**
1. **`LFS_LOOKAHEAD_SIZE` 2048 → 4096** (64 MB → 128 MB window): halves scan *frequency* (~every 128 MB written). Does not shorten each scan.
2. **Queue 100 → 120** — rides out the short scans (see history row above).

Keeping the FS emptier (prompt app-side sync+delete) is what shortens each scan — scan cost ∝ data on disk — so it's the biggest lever on stall *duration*. (An earlier revision also pre-warmed the allocator with `lfs_fs_gc` during idle/disconnected silence — "idle-gc" — but it was removed: `lfs_fs_gc` is a single un-abortable multi-second scan on the worker, so anything arriving mid-scan (a connect, a sync, resumed speech) waited for the whole thing. Every gate we tried (disconnected-only, sync-exclusion, sustained-silence, a scan-duration cap) only made the race rarer or bounded, never eliminated it, and the safe version — bounded to *short* scans — could only pre-empt scans the 120-slot queue already absorbed. Net: complexity + a recurring race surface for ~no gain over queue + lookahead + FS-emptiness. If revisited, the constraint to design around is that the scan can't be interrupted.)

**RAM-reclaim diagnostic (`0x0062` offsets 68/72, payload grew 68→76 B):** `sd_worker_stack_used` and `codec_stack_used` — peak stack bytes used by those two threads since boot, via `k_thread_stack_space_get` (needs `CONFIG_INIT_STACKS` — already on — plus `CONFIG_THREAD_STACK_INFO`, added 2026-07-18). These are gauges, not counters (the sentinel fill isn't restored, so one read = peak-since-boot; read after a heavy session — an allocator scan is the SD worker's deepest path — to catch the worst case). Surfaced as "SD worker stack" / "Codec stack" (`used / configured`). **Current sizes, corrected 2026-08-08 — the 16384 / 19000 figures this note used to quote are both stale and were the basis of a false "codec stack is 94% full" reading:** `SD_WORKER_STACK_SIZE` is **12288** (10240 on a dev build, which carves out the 2 KB diag ring) and `codec_stack` is **23096** (`codec.c`). A measured 17,932 B of codec use is therefore 78%, not 94%. The app already draws both bars against the right sizes (`sync_page.dart`); only this note was wrong. Point: those two stacks are ~35 KB combined and are the **one RAM lever with no audio-pipeline tradeoff** — a large gap below the configured size is directly reclaimable to fund lookahead/queue depth. Amber only if usage rides >85% of the ceiling (overflow risk — do *not* trim then).

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
**Description:** "Permanently deletes raw, undecoded segment files downloaded to this phone. Decoded recordings and drafts are kept."
**Implementation:**
- Blocked if processing is active.
- Shows a confirmation dialog.
- Deletes the `raw_segments` directory (`${directory.path}/raw_segments`) recursively.
- Resets shared preferences related to sync progress.
**Conclusion:** Matches description. The `raw_segments` folder contains all the downloaded `.bin` files and markers.

### 6. Delete Phone Conversations
**Description:** "Permanently deletes decoded recordings on this phone — finalized conversations and in-progress drafts."
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

## Firmware: Removed Subsystems

Several source files used to sit in the tree as reference code, outside
`omi/firmware/omi/CMakeLists.txt` so the compiler never saw them. They were deleted
rather than parked, because git already keeps them and a file that looks like part
of the firmware but is not costs a reader's attention every time.

Everything below is at commit `e2b438a` and comes back with:

```bash
git checkout e2b438a -- <path>
```

| Removed | What it was | To bring it back |
|---|---|---|
| `src/lib/core/accel.c` / `accel.h` | BLE service (`32403790-…` / `32403791-…`) notifying accel + gyro XYZ once per second. No consumer — the app has only the placeholder capability bit. | Restore both files, add `accel.c` to `core_sources` gated on `CONFIG_OMI_ENABLE_ACCELEROMETER`, re-add that Kconfig option and the bring-up in `transport_start()` / teardown in `turnoff_all()`, and write the app-side subscriber. |
| `src/lib/core/speaker.c` / `speaker.h` | Speaker streaming + its BLE service. The Consumer board has no speaker. | Same shape, under `CONFIG_OMI_ENABLE_SPEAKER`. |
| `src/lib/core/nfc.c` / `nfc.h` | NFC tag output. Never referenced. | Restore, add to `CMakeLists.txt`, add a caller. |
| `src/lib/core/usb.h` | Declared `init_usb()`, which was never defined or called. `CONFIG_OMI_ENABLE_USB` is unrelated and still used (it gates the USB interrupt disable in `turnoff_all()` and a capability bit). | — |
| `src/feedback.c` / `feedback.h` | Eleven `error_*()` hooks, all with zero call sites. | Restore both, add `feedback.c` to `app_sources`, call the hooks. |
| `src/mcuboot_boot_zephyr.c` | A vendored copy of MCUboot's `boot/zephyr/main.c` with four Omi edits. No build file referenced it. | Restore and wire into the bootloader build if the MCUboot main ever needs patching again. |
| `scripts/test_button_fsm.c` | A host-compiled mock of the button FSM. It had drifted badly out of sync — three states instead of four (no `STATE_WAIT_FOR_RELEASE`), no `RECORD_START`/`STOP`/`TOGGLE` actions, and a default config that was not `settings.c`'s — so it passed against a design that no longer exists. | Rewrite against the current `check_button_level()` rather than restoring. |

**Do NOT confuse `accel.c` with `src/imu.c`**, which IS built and IS load-bearing.
`imu.c` uses the same physical LSM6DS3TR-C chip but only its **24-bit hardware
timestamp counter** (via raw I²C register reads, not the sensor API). That counter
keeps ticking through `system_off` deep sleep; on boot the firmware reads the delta to
recover wall-clock time across reboots/crashes, and stamps `imu_ticks` into each
recording header. The Flutter app's "IMU Bridge"
(`app/lib/services/vad_audio_processor.dart`, `tickDelta * 6.4` ms) uses it to stitch
recording segments correctly across a reboot. Removing `accel.c` did not affect it.

`src/lib/core/monitor.c` is a different case and is still present: it is gated in
`CMakeLists.txt` on `CONFIG_OMI_ENABLE_MONITOR`, which `omi.conf` sets to `n`. Flipping
it to `y` turns the module on. Note that four of the six counters
`monitor_log_metrics()` prints (`gatt_notify`, `mic_buffer`, `broadcast_audio`,
`broadcast_audio_failed`) have no `monitor_inc_*` call site anywhere and will read a
permanent 0 — only `tx_queue` and `storage` are actually fed.

---

## The app's IMU Bridge never matches — the checkpoint resets the counter under it

**Measured 2026-08-19, `oo-3.0.8`.** `VadAudioProcessor` tries to carry a recording across
a reboot without splitting it (`imuGapMatches`, `vad_audio_processor.dart`): it subtracts
the previous bin's `imu_ticks` from the new one's and, if the result matches the wall-clock
gap, treats the audio as continuous. The premise is that the counter free-runs across the
restart. It does not.

`lsm6dsl_time_prepare_for_system_off()` calls `lsm6dsl_timestamp_reset()` — and that
function is the **periodic checkpoint**, posted on every VAD-sleep transition, not just the
power-off path. So `imu_ticks` in a bin header is "time since the last checkpoint", never
"time since boot", and the two sides of the subtraction are counted from different origins.

The observed crossing, straight from the probe lines:

    session A, last bin:  ticks=37748
    session B, first bin: ticks=0
    dTicks = (0 - 37748) & 0xFFFFFF = 16739468  ->  ~107132595 ms = 29.8 h

That is the whole 24-bit wrap, not a reboot gap. It fails the `gapDiff < 5000` test, so the
recording splits — **the failure is safe**, and the symptom is only a split at a reboot that
might have been avoidable. Within a session the same subtraction is meaningful *only* when
no checkpoint intervened (99.6 % tracking when none did; 16 % and 0.2 % across two that did).

**The firmware-side bridge is fine and must not be "fixed" alongside it.** `boot_adjust_rtc`
compares against a base saved by the same checkpoint that did the reset, so both sides share
an origin and the arithmetic is coherent. Only the app's cross-session comparison is
unfounded.

Anyone repairing the app side needs an origin that survives — a checkpoint sequence number
in the bin header, or simply not resetting the counter — not a wider tolerance on the
existing subtraction.

## LFCLK runs on the RC oscillator, not a crystal (~217 ppm measured)

**Measured 2026-08-19** from six clock anchors taken across one 8.4-minute session. Each
pairs the Omi's uptime with the phone's wall clock, so each implies a boot instant; they
drift monotonically by **109 ms over 503 s = 217 ppm**, or ~19 s/day.

That settles the open question: `omi.conf` sets no `CLOCK_CONTROL_NRF_K32SRC_*`, so Zephyr's
default (`K32SRC_XTAL`) applies — but there is no `lfxo` node anywhere in the board DTS, and
nRF53 selects two-stage LFXO start, which begins on the RC and only switches once a crystal
reports ready. 217 ppm is RC territory; a fitted crystal would be tens of ppm. So no crystal
is being used, whatever the Kconfig nominally asks for.

Harmless for the clock-anchor design — `plausibleDriftMs` budgets 1000 ppm, so the measured
figure sits 4.6x inside it, and 550x inside the 60 s floor at that session length. It is four
orders of magnitude away from the ~29.8 h aliasing error the rule has to separate from, which
is the whole reason that constant never needed tuning.

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

**Recovery:** the canonical EDL is preserved; the dropped ones are still on disk (the dedup is in-memory only). (The old "Delete Problematic EDLs" debug button that used to live in `sync_page.dart` was removed 2026-06-07 — see "Debug Tools Audit" §7 — so there is no in-app cleanup for these; manually delete via filesystem if needed.)

---

## App: a downloaded bin can be skipped forever as "already decoded" (2026-09-06) — FIXED

**What happened.** A 227 KB bin (`1788707553`, 42.1 s of speech) was downloaded off the Omi, deleted
from the card, and never decoded. It produced no recording and no discard record, so it left no trace
in the UI at all — the audio was simply absent. The file sat intact in `raw_segments/` the whole time;
Force Process reported nothing to do. Settling it took a rebuilt debuggable APK and `adb run-as`.

**The mechanism.** Before decoding, `coveredBinPaths` asks "has a recording already consumed this
bin?" — a real question, because a kill between writing a recording and pruning its bins would
otherwise re-decode and duplicate. It answered geometrically:
`_buildMergedCoverageIntervals` gave every recording a window of
`[start − 10 min, end + vadSplitSeconds]` and **merged overlapping windows**. A bin whose
`[binStart, binEnd]` fell inside any merged window was skipped.

Both slacks are individually defensible — the left one is the 10-minute `FILE_ROTATION_INTERVAL_MS`,
so a bin really can start that far before the recording it fed — but merging makes coverage
**additive across unrelated recordings**, and it is not. Five recordings around a Priority Recording
stop:

    recording_1788707524000  15:12:04   6.0 s  ->  [15:02:04 .. 15:12:12]
    recording_1788707530512  15:12:10  21.1 s  ->  [15:02:10 .. 15:12:33]
    recording_1788707551000  15:12:31   1.5 s  ->  [15:02:31 .. 15:14:32]
    recording_1788707634611  15:13:54  31.0 s  ->  [15:03:54 .. 15:16:05]
    recording_1788707748502  15:15:48 415.9 s  ->  [15:05:48 .. 15:24:44]
                                       merged  ->  [15:02:04 .. 15:24:44]
    bin 1788707553                             ->   15:12:33 .. 15:13:29   (inside)

**Permanent, and self-reinforcing.** A skipped bin is never decoded, so it yields neither a recording
nor a discard, so nothing revisits it — while every later recording nearby widens the block. A
Priority Recording is the ideal trigger: it produces a dense cluster of short recordings, and a
10-minute left slack on each guarantees they chain. The user's own ghost-row recoveries
(`…551000`, `…634611`) each added a window and helped seal it.

### The fix

`coveredBinPaths` now answers from **exact membership**: every finalized `.meta` already lists the bins
its audio came from (`Conversation.relativeBins`), parsed by the same `Conversation.fromFile` the
interval builder was already calling and throwing away — so this costs no extra I/O.

The decisive argument is that **`pruneConsumedBins` — the DELETING side of the same question — has
always used that list**, and its doc comment already says legacy metas "contribute no entries and so
simply retain their bins (conservative)". The two were inconsistent, and in the wrong direction: the
function that deletes files was careful, and the function that merely skips them was guessing. A
skipped bin is audio the user never sees and is never offered again, so "merely skips" was the more
destructive of the two.

Geometry survives only for recordings that **cannot** answer — a `.meta` predating the bin-list field,
or one truncated by a kill between the `.wav` and the `.meta`. Recordings carrying a list contribute no
interval, which is what dissolves the merged block. That fallback logs loudly whenever it actually
skips something; **if that line never appears over real use, delete the geometry and make
`coveredBinPaths` a pure list lookup.**

- **Drafts stay in the exact set.** A draft already holds its bins' audio and grows by appending the
  next sync's bins, so re-decoding its own would duplicate. This is a different question from the one
  `pruneConsumedBins` answers, which is why that function *protects* the same bins from deletion. Do
  not decode them again, and do not delete them yet — both are true at once, and
  `recordings_manager_test.dart` pins each.
- **`_runProcessing` now logs every excluded bin and why.** In a healthy run nothing is excluded, so it
  is rare and high-signal. It exists because this failure is invisible by construction.
- **Debug Tools → Storage Inventory** writes the same picture to the log on demand. Deliberately a
  button that logs, not a screen: the app could already *delete* `raw_segments/` but never *show* it.

### Read before "improving" this

- **The size→duration estimate over-estimates, and that is load-bearing.** `opusBytesPerMs = 4050/1000`
  computes 56 s for a bin holding 42 s, because ~16 % of a bin is sentinel padding. That widens
  `[binStart, binEnd]`, which makes coverage HARDER to satisfy. "Correcting" the constant makes the
  filter more aggressive — the direction that loses audio.
- **Do not delete the merge from the legacy path.** A long bin genuinely straddling two consecutive
  recordings is consumed by both, and `recordings_manager_test.dart` pins it. The merge was never wrong
  in itself; applying it to recordings that could answer exactly was.
- **The fix is retroactive.** Anything currently stranded decodes on the next run; no migration and no
  recovery tooling. The 2026-09-06 bin was also pulled off the device and repackaged as Ogg-Opus, which
  is a useful trick to remember: the bin format is a plain framed Opus stream (see **Audio pipeline**),
  so 60 lines of Ogg paging turns any raw bin into a playable file without the app.

---

## Firmware: audio captured and discarded before the codec after an auto-mode Record Stop (2026-09-05) — ROOT CAUSE FOUND AND FIXED

**What happened.** Pressing Record Stop in auto mode could leave the Omi capturing into nothing: the mic
kept delivering, the VAD kept a recording open at ~100 % duty, and not one audio frame reached the SD
card. Reproducible on demand — two priority stops in the 2026-09-05 log, two blackouts, no others all
week. Both ended only when the room fell quiet.

    17:22:32 stop -> bins 36 B / 476 B / 36 B until 18:07:20   (44 min 46 s)
    21:19:12 stop -> bins 36 B / 36 B        until 21:40:49    (21 min 37 s)

### The mechanism

`aad_process_audio()` replays pre-roll one frame per callback, parking the concurrent live frames in
`vad_live_backlog_buf`. Both rings are 8 deep, so once replay finishes the backlog sits **pinned at 8**
for the rest of the recording: each callback flushes one old frame and pushes the current one. That is
the designed pacing, and it means the backlog is full at every moment a recording can end.

`aad_set_threshold()`'s `finalize_now` branch — the auto-mode Record Stop — cleared `vad_is_recording`
without calling `preroll_reset()`. The two sibling sites do: the silence -> sleep transition, and the
mic-park path via `aad_note_capture_gap()`. The `aad_apply_mic_gate()` at the end of the finalize does
not help, because auto mode keeps the mic running, so nothing parks and no capture gap is raised. **That
is the entire reason manual standby and mute were immune and auto was not.**

So the backlog stayed full across the stop. A noisy room then re-triggered the VAD within the 3-frame
debounce, `preroll_queue_flush()` set `vad_preroll_flush_pending = 3` against a backlog of 8, and:

```c
if (vad_preroll_flush_pending > 0) {
    if (!live_backlog_push(buffer)) {
        return false;          /* returned WITHOUT preroll_push_one() */
    }
    preroll_push_one();
```

`pending` never decremented, the backlog never drained (`live_backlog_flush_one()` is only reachable in
the `pending == 0` branch), and every subsequent frame took the same early return. **Nothing reached
`codec_receive_pcm()` again.** Self-sustaining, and only `preroll_reset()` clears it — which in auto
mode means the VAD-sleep transition, i.e. `CONFIG_OMI_VAD_HOLD_MS` (10 s) under threshold. A noisy room
refreshes `vad_last_voice_ms` every frame, so it never slept. Hence "recovers when the room goes quiet",
and hence reproducible on demand by keeping the room noisy.

Latent since `19f339bb` (2026-06-29) added the finalize path; the backlog predates it.

### Why every counter read healthy — the traps that sent the first investigation downstream

Each of these is a real reading of a real counter, and each one is wrong about what it appears to say.

- **`vad_voiced_ms` at 99–100 % duty is not proof of capture.** It is stamped on `vad_is_recording`
  alone, upstream of the replay block that was dropping the frames. 100 % duty over a bin holding no
  audio is exactly what this bug produces. The comment above it used to say "every frame the VAD holds a
  recording open is a frame that gets encoded and written" — that was false, and is corrected.
- **`codec_drops == 0` is not proof the audio was encoded.** `codec_dropped_count` only moves when
  `codec_receive_pcm()` finds its ring full. Zero is equally consistent with nothing ever being
  submitted, which is what happened. Reading it as "encoded, therefore the loss is downstream" is what
  pushed the first analysis all the way to `pusher()`.
- **`storage_block_drops == 0` really does rule out everything below the pusher**, and usefully so: a
  block rejected for any reason, including the uncounted `sd_write_blocked` early return in
  `write_to_file_impl()`, is counted one level up in `write_custom_packet_to_storage()`. So the loss was
  provably above the SD worker. It was further above than it looked.
- **`sd_msgq_peak_depth` unmoved proves nothing on its own** — it is a since-boot high-water mark.
- **`marker_pause_gate_saves` moving at the stop is the rescue working**, not a fault, and it stayed put
  for the whole blackout because nothing else met that gate.
- **`vad_voiced_ms` vs `live_uptime_ms` carries ±200 ms of sampling skew** (some windows show `voiced`
  exceeding uptime by 11–31 ms). Only multi-second differences are readable.
- **`CONFIG_LOG` is unset in `omi.conf`**, so `live_backlog_push()`'s `LOG_ERR("live backlog overflow")`
  compiled to nothing. The device hit that line ~10 times a second for 21 minutes in silence.

The 476 B bin is the single most direct piece of evidence and is worth keeping in mind as the signature:
header + one 440 B block holding `0xFFFFFFFD` at offset 0 and `0xFFFFFFFE` at offset 20, 400 B of
padding, zero audio frames. That is `buffer_offset` frozen at 20 for twenty minutes — the resume packet
staged at the re-trigger, then nothing at all until a button tap force-drained it.

### The fix

1. **The finalize branch of `aad_set_threshold()` now resets the replay state.** The root cause. Every
   site that clears `vad_is_recording` must clear the replay state with it.

   **Posted, not called** (`replay_reset_pending`), because that branch runs on the button/BLE thread.
   `preroll_reset()` is mic-thread-only for a concrete reason: `live_backlog_flush_one()` and
   `preroll_push_one()` each test a count for zero and then decrement it, so a reset landing between the
   two underflows a `uint8_t` to 255 and replays ~25 s of stale frames. The plain assignments that
   branch already makes carry no such hazard — none is a read-modify-write — which is why this one had
   to be posted and they did not. The file already states the rule, above `capture_gap_pending`.
2. **`preroll_reset()` in the WAKE-consumed clear** (`aad_process_audio`). Same omission, and a
   button-free second trigger: a hardware WAKE landing mid-recording clears `vad_is_recording` with the
   backlog still pinned.
3. **`preroll_queue_flush()` clears the live backlog itself.** This is the structural fix, and the one
   that matters most: a replay only ever starts at the RECORDING transition, so anything in the backlog
   then belongs to the previous recording and is stale by at least that recording's whole length. After
   this line the backlog is never full when the replay branch runs, so the wedge is unreachable — no
   matter which site forgot to reset, and no matter how the threads interleave. It needs no ordering of
   its own: it runs on the mic thread, immediately before the pending count it protects is set.

   It is deliberately not redundant with (1) and (2). Those drop the stale *pre-roll*, which this does
   not touch, and (1) posts across threads and therefore cannot be ordered against a mic thread already
   past its consume point. Do not delete this as duplication — it is what makes the other two
   non-load-bearing.

4. **Pre-roll drains even when the live backlog push fails.** `preroll_push_one()` is now unconditional,
   so a failed push costs one dropped 100 ms frame instead of a permanent stall. Belt to (3)'s braces:
   it bounds any interleaving that still reaches a full backlog to at most the 8 frames of one replay.
5. **`aad_set_threshold()`'s queued-pause re-check now tests `vad_is_recording`, not just
   `vad_threshold == 65535`.** Independent of the wedge and not implicated in it, but a real window:
   `sd_write_pause(true)` sets its flag before queueing `REQ_PAUSE_IO` and then waits on the worker for
   up to 10.5 s, so a silence→speech transition in that span runs its own inline `sd_write_pause(false)`
   first and ours buries it. The threshold test is false in exactly the case that matters, because a
   priority stop restores an *auto* threshold (250) — confirmed in the device's own `vad_level` records
   from the outage.
6. **`DIAG_WRITE_BLOCKED` / `DIAG_WRITE_BLOCKED_VAD_BACKLOG_FULL` (arg0 = 2)** is emitted at that drop,
   rate-limited to 1/s with a running total in arg1. It should read zero forever; it exists so a
   regression says so rather than being inferred from an absence, which is what cost the first
   investigation. `DIAG_WRITE_BLOCKED_TX_RING_FULL` (arg0 = 0) instruments the other uncounted discard
   in the chain — `write_to_tx_queue()`'s ring-full return — which was never implicated here and
   correctly stayed silent throughout.

### Residuals — read before "improving" this

- **The backlog record should now be structurally unreachable, and is kept anyway.** With (3) in place
  `vad_live_backlog_cnt` is 0 every time a replay begins, so the push cannot fail; the counter is a
  canary for a future regression in this state machine, not a live signal. Read a non-zero value as
  "someone changed the replay logic", not as a recurrence of the 2026-09-05 fault.

- **Every recording still loses the ~0.8 s sitting in the live backlog when it ends.** The backlog runs
  one-in-one-out for the life of a recording, so its contents are always that recording's last 0.8 s,
  and every end-of-recording path discards them. This is pre-existing and unchanged: the VAD-sleep path
  has always called `preroll_reset()` there, and before this fix a Record Stop either wedged (noisy) or
  hit that same reset ten seconds later (quiet), so the tail was never emitted correctly in either case.
  Fixing it properly means draining the backlog into the codec *before* `write_session_end_marker_to_
  storage()` runs, which is a different change on a different code path; do not bolt it onto the reset.

- **Not reproduced against the fix on hardware.** This repository has no firmware test harness, so the
  mechanism was derived by reading against the device log and the fix is verified by build only. The
  confirming test is cheap and specific: auto-mode Record Start, Record Stop, keep the room noisy, and
  check that the bin covering the next few minutes is not 36 B.
- **Do not "fix" a future recurrence by widening the backlog or the pre-roll ring.** Both were already
  equal at 8; the wedge came from state surviving across a recording boundary, not from depth. A deeper
  ring makes the wedge rarer and no less permanent.
- **Do not gate the reset on `vad_is_recording` being true.** The finalize is deliberately unconditional
  (see the comment above `leaving_always_record`) precisely because a WAKE can have cleared the flag
  microseconds earlier; a gated reset would skip exactly the interleaving that needs it most.
- **The ghost-row timestamp is a separate, unresolved bug.** Confirmed on-device 2026-09-05: the discard
  for bin `1788656840` renders 18:07:20–18:09:20 when the audio it describes runs 18:08:26–18:10:26 — a
  66 s offset equal to that bin's silent head. `_buildDiscardRecordFor` takes its `startMs` from
  `_recordingStartTime`, which is anchored per frame from `vadResumeTime` when a `0xFFFFFFFD` has been
  seen (`vad_audio_processor.dart:1762`), and the resume packet IS the first entry in that bin with
  `gapMs = 65050`, so the anchor was computed and did not reach the discard record. Needs a unit test
  over a synthetic bin (resume packet at head, UTC 65 s after `timerStart`, then audio) asserting the
  discard starts at the resume. Do not "fix" it by re-deriving the start from the bin header — that is
  the wrong value, it is just the one currently observed.

---

## Firmware + App: SD Write Drop Counters (diagnostic instrumentation)

**Status:** shipped and load-bearing as a canary. **"No drops" is a statement about the paths these
counters watch, and nothing more.** On 2026-09-05 the device discarded 44 and 21 minutes of captured
audio with every counter below reading zero — the loss was in the VAD gate, upstream of all of them,
before the encoder. Worse, `codec_drops == 0` positively misled: it only moves when a submitted frame
finds the ring full, so it reads zero just as convincingly when nothing is submitted at all. Read the
section immediately above before drawing any conclusion from a zero here.

### Why this exists

Originally built to validate a deferred proposal ("Sequence & Sync" marker re-synchronization, formerly in `IDEAS.md`). That proposal would have wrapped every audio packet in a sequence-number + uptime header so the app could detect dropped frames and reconstruct a gap-less timeline — protecting in-stream button-tap markers (`0xFFFFFFFE`) from drifting out of sync when frames are lost. In-stream markers currently rely on byte-position within the `.bin` stream to compute their audio timestamp; if the firmware/SD card drops frames the timeline "shrinks" but the marker stays at its byte-offset, so it drifts.

That proposal's complexity is only justified **if SD write drops actually happen**. These counters were built to measure that. **Result: zero drops across the entire usage history since they shipped** (subject to the blind spot in
the Status line above — a zero here does not mean no audio was lost) — so the Sequence & Sync proposal was dropped as solving a non-problem (the section was removed from `IDEAS.md` on 2026-05-28). The counters are retained as a permanent cheap canary: if a future firmware change reintroduces drops, the Debug Tools page surfaces it instead of silently shipping marker drift.

### Counters and their failure modes

These span the whole capture→card pipeline. In pipeline order (mic → encoder → SD queue → card):

| Counter | Source | Fires when |
|---|---|---|
| `codec_drops` | `codec.c::codec_receive_pcm` | The codec ring buffer (`AUDIO_BUFFER_SAMPLES`, 16000 = 1.0 s of PCM; defined in `src/lib/core/config.h`) is full when a mic chunk arrives — the **encoder** is CPU-starved. Each drop ≈ one mic chunk (~100 ms). This is the *capture-stage* loss; it's the number that tells you whether `AUDIO_BUFFER_SAMPLES` is too small. Added 2026-06-10. |
| `sd_stream_drops` | `sd_card.c::write_to_file` | `k_msgq_put(&sd_msgq, …)` times out after a 1–5 ms retry — a single audio frame is lost. Upstream signal; most block drops are downstream of a stream drop. |
| `block_drops` | `transport.c::write_custom_packet_to_storage` | `write_to_file` returns ≠ `MAX_WRITE_SIZE` — the entire 440 B block is lost (~5 Opus frames ≈ 100 ms). Headline number; exactly the loss the marker-drift proposal solved for. |
| `sd_boot_drops` | `sd_card.c::write_to_file` boot path | An audio frame arrives before the card power-on + ring mount completes. Cold-start issue, **not** relevant to mid-stream drift. |
| `ring_io_errors` | `sd_ring.c::note_io` | A ring disk primitive (write / read / CTRL_SYNC) returned non-zero. **This is the card-health counter** — the one to watch for the write-fault paths below. `0` means the ring has never had a failed disk op, which also means the write-fault recovery has never been anywhere near firing. Added `oo-2.7.3`. |
| `ring_max_io_ms` | `sd_ring.c::note_io` | Packed `(tag << 24) | ms` of the SLOWEST ring disk op since boot (tag 1=write, 2=read, 3=sync). Diagnoses *slowness*, not failure — a climbing value with `ring_io_errors == 0` is a congested card, not a failing one, and does **not** trip any of the recovery machinery. Field baseline was 307-381 ms, later 549 ms on a write. Added `oo-2.7.3`. |
| `conn_fails` | `transport.c::_transport_connected` | A BLE connection establishment fails (HCI error). Flash-persisted across reboots (survives the power-cycle needed to reconnect and read it). Plus `last_failed_adv_slow` = whether the last fail was during slow (1 s) advertising. |

**The write-fault recovery paths have NO dedicated counter — watch `ring_io_errors` instead.** Since `oo-2.9.0` the write path escalates on sustained failure: `sd_write_blocked` latches, blocks are buffered into the ring's append stage for ~8 s, and after `SD_RECOVERY_REMOUNT_THRESHOLD` (3) failed 2-second soft retries `sd_recover_remount()` power-cycles the card and re-mounts it. **None of that increments anything of its own** — the remount attempt is invisible to Debug Tools, visible only as a `[SD_WORK] ... power-cycling + remounting SD` log line, which goes nowhere without an RTT probe. Diagnose it indirectly:

- `ring_io_errors > 0` — the ring is getting errors from the card at all. **This is the precondition for everything below**; at `0` none of the recovery machinery can have run.
- `sd_stream_drops` climbing alongside it — audio that the ~8 s stage buffer could not hold. Blocks dropped inside a backoff window land here (before `oo-2.9.0` they were discarded silently, so an old firmware under-reports its own loss).
- `block_drops` flat while the two above move — the loss is at the card, not the transport.

Reaching the remount needs roughly **6 seconds of continuous write failure**, so it does not fire for a merely slow or congested card. Note that "failing card" is broader than a dying NAND: a latched SD controller, a desynced SPI slave, or a bad PM resume all present as write failures with healthy hardware, and are exactly what a power-cycle fixes and a plain retry cannot. If you want the remount itself observable rather than inferred, appending a counter to `0x0062` is the (append-only, backward-compatible) way to do it.

### BLE characteristic `0x19B10062` (diagnostics service)

**READ + NOTIFY** (notify added `oo-2.6.1`: while a client is subscribed the firmware pushes the payload every 2 s during an active transfer / 15 s idle heartbeat, stopping on unsubscribe/disconnect — see "Live diagnostics during sync"). Returns **100 bytes, little-endian**, twenty-five `u32` fields (as of `oo-3.0.x`; was 84 B / twenty-one at `oo-2.7.3` and 76 B / nineteen at `oo-2.6.2`). The 100-byte notify needs ATT MTU ≥ 103; on a link that never negotiated up (default 23 B) `bt_gatt_notify` returns `-EMSGSIZE` and the push is dropped (firmware `LOG_DBG`s it, doesn't retry). The plain **READ** is the MTU-agnostic fallback — ATT read-blob fragments across PDUs, so the full 100 B is always readable regardless of MTU. In practice `CONFIG_BT_L2CAP_TX_MTU=498` + `AUTO_UPDATE_MTU` make a sub-103 MTU the rare exception. **App gap (Part-1 subscribe lifecycle, tracked separately):** the Sync-page watchdog re-subscribes on notify silence but does not currently issue that READ fallback, so on a chronically small MTU the card would stay stale — a read fallback there must be gated on "not mid-transfer" to avoid the Error-133 read/stream race the notify design exists to dodge. Fields were appended over time — length grew 20 → 28 → 32 → 40 → 44 → 60 → 68 → 76 → 84 → 92 → 96 → 100 B — so an older app reads a shorter prefix and ignores the rest; the firmware always returns the full current length. Offsets past 36 (`estab_fail_count` @40 … `device_session_id` @96) are enumerated in the `transport.c` `diagnostics_drops_pack` header comment, which is the **single** authoritative list — CLAUDE.md used to mirror it and no longer does, because that copy drifted four appends behind. The layout below documents the original first 40 B in detail.

```
offset:  0            4                  8                12             16
        [ block_drops ][ last_drop_up_ms ][ sd_stream_drops ][ sd_boot_drops ][ now_uptime_ms ]
offset: 20            24                  28             32              36
        [ conn_fails  ][ last_failed_slow ][ codec_drops ][ msgq_peak ][ write_fair_acts ]
```

- `block_drops` / `sd_stream_drops` / `sd_boot_drops` / `codec_drops` — see table above.
- `last_drop_uptime_ms` (offset 4) — device uptime (ms) of the most recent **block** drop; 0 if none. Compare against `now_uptime_ms` to tell "recent" from "early-boot, long ago."
- `now_uptime_ms` (offset 16) — current device uptime, the reference clock for `last_drop_uptime_ms`.
- `conn_fails` (offset 20) — BLE connection-establishment failures (flash-persisted). `last_failed_slow` (offset 24) — 1 if the last fail was during slow advertising.
- `codec_drops` (offset 28) — capture-stage drops. Added 2026-06-10 (firmware grew 28 → 32 bytes).
- `msgq_peak` (offset 32) — `sd_msgq_peak_depth`, high-water mark of the SD write queue occupancy since boot (out of `SD_REQ_QUEUE_MSGS` = 120 as of `oo-2.6.2`; 100 on older firmware — the app derives the denominator from payload length). Low peak = plenty of write headroom. `write_fair_acts` (offset 36) — `write_fair_activations`, times the worker forced a write turn over pending reads (write fairness engaged; informational, not a fault). Both added with the write-fairness work (`0095b1fa8`); firmware grew 32 → 40 bytes.

**History of the length:** 20 B (legacy, 5 drop fields) → 28 B (+ `conn_fails` + `last_failed_slow`) → 32 B (+ `codec_drops`) → 40 B (+ `msgq_peak` + `write_fair_acts`) → 44 B (+ `estab_fail_count`) → 60 B (+ Priority-Recording lifecycle) → 68 B (+ `session_end_marker_emits` + `marker_pause_gate_saves`) → 76 B (+ `sd_worker_stack_used` @68 + `codec_stack_used` @72, `oo-2.6.2`) → 84 B (+ `ring_max_io_ms` @76 + `ring_io_errors` @80, `oo-2.7.3`) → 92 B (+ `last_mic_frame_uptime_ms` @84 + `vad_voiced_ms` @88) → 96 B (+ `adv_modes` @92) → **100 B** (+ `device_session_id` @96 — the clock anchor's other half, see CLAUDE.md "Timestamp self-correction"). Offsets 40–96 are enumerated in the `transport.c` `diagnostics_drops_pack` header comment, which is the sole authoritative list; the ASCII diagram above only details the original first 40 B. Keep appending; never reorder. (A briefly-added `idle_gc_runs`/`idle_gc_max_ms` pair at 68/72 was removed before release — see "The second stall class".)

All counters are cumulative since boot (except `conn_fails`, which is flash-persisted across reboots). There is **no firmware reset command** — the planned `0x19B10063` "reset stats" write was never added. Reset is done **app-side by baseline subtraction** (see below).

### Firmware variables / internals

- `transport.c`: `static atomic_t storage_block_drops` and `static atomic_t last_storage_drop_uptime_ms` (both `ATOMIC_INIT(0)`). Incremented together at the two `write_custom_packet_to_storage` failure sites (`atomic_inc` + `atomic_set(k_uptime_get())`). `conn_fails` = `failed_conn_count` atomic. Exposed via `diagnostics_drops_pack` (100 bytes), served on both the READ handler and the NOTIFY work; the `0x0062` characteristic is the last *characteristic* in `diagnostics_service_attr[]`, followed by its CCC descriptor (the actual last attribute — index 5; the value attr is index 4).
- `codec.c`: `static atomic_t codec_dropped_count` (`ATOMIC_INIT(0)`), incremented at both `codec_receive_pcm` failure sites (ring-full and partial-write). Accessor `codec_get_dropped_frames()` declared in `codec.h`; read by `transport.c` into the diagnostics payload.
- `sd_card.c`: `static atomic_t stat_dropped_frames` (stream drops) and `static atomic_t boot_dropped_frames` (boot drops). `SD_REQ_QUEUE_MSGS = 120` (sd_card.c:48) backs `K_MSGQ_DEFINE(sd_msgq, …)` — see "SD Write Queue Configuration" for the depth history. Also `static atomic_t sd_msgq_peak_depth` and `static atomic_t write_fair_activations` (write-path observability). Accessors: `sd_get_stream_dropped_frames()`, `sd_get_boot_dropped_frames()`, `sd_get_msgq_peak_depth()`, `sd_get_write_fair_activations()`.
- `sd_card.h`: declares `sd_get_stream_dropped_frames()`, `sd_get_boot_dropped_frames()`, `sd_get_msgq_peak_depth()`, `sd_get_write_fair_activations()`.

### App side / how to use it

1. Settings → **Sync** page (`SyncPage`). Turn on the **"Show Diagnostics"** toggle (`SharedPreferencesUtil().showSdWriteDrops`, off by default). The **Diagnostics** card **subscribes** to the characteristic (`_ensureDropSubscription`, retried on a tick) rather than polling — the firmware pushes the 76-byte payload (2 s during a transfer / 15 s idle), so the card updates live *during* a sync instead of racing a GATT read against the storage stream (Error 133 on Android). A liveness watchdog (`_dropSubHealthy`) re-subscribes if notifications go silent, and only trusts a subscription that belongs to the currently connected device.
2. State fields: `_dropStats` (latest notification), `_dropConn`/`_dropStatsSub` (the live subscription + its connection), `_dropBaseline` (SD/codec snapshot for delta), `_connFailBaseline` (BLE snapshot), `_peakSinceReset` (app-side peak high-water, since peak can't be delta-subtracted).
3. Rows shown: `440 B blocks dropped`, `Audio frames dropped (SD queue)`, **`Audio dropped pre-encode (codec)`**, `Boot-window frame drops`, `Last block drop`, `Device uptime`, **`SD queue peak depth`** (`{peak} / {sdQueueMax}` — 120 on `oo-2.6.2`+, 100 older — highlighted at ≥ 80 % of the limit), **`Write-fairness activations`**, Priority-Recording lifecycle rows, **`SD worker stack`** / **`Codec stack`** (peak used / configured), `BLE connect failures`, `Last fail adv mode`.
4. **One button — "Reset all diagnostics"** (`_resetAllDiagnostics()`) — snapshots a fresh baseline for *every* counter (SD/block/codec drops + BLE fails) at once. The header flips to **"Diagnostics (since reset)"** and all rows restart from 0. This is an **app-side baseline subtraction**, not a firmware zero — the device counters keep climbing; the app shows the delta. SD/codec baselines auto-clear on device reboot (those counters reset to 0 anyway); the BLE baseline persists (firmware counter is flash-backed). Baseline pref keys: `_kBaselineBlocks` / `_kBaselineFrames` / `_kBaselineBoot` / `_kBaselineCodec` / `_kBaselineConnFail`.
5. Healthy reading: all drop counts at 0 (or unchanged from baseline); `SD queue peak depth` well under its ceiling (120 on `oo-2.6.2`+, 100 before). Movement means real audio loss — investigate per the table above. **`codec_drops` moving = the encoder is CPU-starved → bump `AUDIO_BUFFER_SAMPLES` further (already raised 9600 → 16000 = 1.0 s; this counter is the only data that justifies raising it again).** `sd_stream_drops` moving (or `SD queue peak depth` riding the queue limit) = msgq saturation (marker-drift concern returns); `boot_drops` moving = cold-start leak.

### Forcing drops for a controlled test

- Run an active BLE sync **while recording**: the SD-worker retry budget tightens (`K_MSEC(5)` → `K_MSEC(1)`) and sync reads compete with writes on the same worker thread. ~30–60 min usually enough to provoke something if the system is marginal. This is the realistic `block_drops` / `sd_stream_drops` provocation.
- Or temporarily drop `SD_REQ_QUEUE_MSGS` from 120 → 8 in `sd_card.c` and rebuild — forces SD drops within minutes. Proves the counters fire; says nothing about real-world frequency. Revert after.
- For `codec_drops`: temporarily shrink `AUDIO_BUFFER_SAMPLES` (config.h) to a tiny value (e.g. 800) and/or add CPU load; the encoder will starve and drop. Revert after.

### Code locations

- `omi/firmware/omi/src/lib/core/transport.c` — `storage_block_drops` / `last_storage_drop_uptime_ms`, `diagnostics_drops_pack` (100 bytes incl. `codec_get_dropped_frames()`, `sd_get_msgq_peak_depth()`, `sd_get_write_fair_activations()`, `sd_get_worker_stack_used()`, `codec_get_stack_used()`, `ensure_device_session_id()`), shared by `diagnostics_drops_read_handler` + `diagnostics_notify_work_handler` (READ + NOTIFY), char registration in `diagnostics_service_attr[]`, increment sites in `write_custom_packet_to_storage`.
- `omi/firmware/omi/src/lib/core/codec.c` / `codec.h` — `codec_dropped_count` atomic + `codec_get_dropped_frames()`; increments in `codec_receive_pcm`.
- `omi/firmware/omi/src/sd_card.c` — `stat_dropped_frames` / `boot_dropped_frames` / `sd_msgq_peak_depth` / `write_fair_activations` atomics, `SD_REQ_QUEUE_MSGS` (line 48), `sd_get_stream_dropped_frames()`, `sd_get_boot_dropped_frames()`, `sd_get_msgq_peak_depth()`, `sd_get_write_fair_activations()`.
- `omi/firmware/omi/src/lib/core/sd_card.h` — accessor declarations.
- `app/lib/services/devices/device_drop_stats.dart` — `DeviceDropStats` model (incl. `codecFrameDrops`, `msgqPeakDepth`, `writeFairActivations`).
- `app/lib/services/devices/omi_connection.dart` — `diagnosticsDropsCharacteristicUuid` (line 57), `performGetDropStats()` (40-byte LE parsing: codec at offset 28, msgq peak at 32, write-fairness at 36).
- `app/lib/services/devices/device_connection.dart` — abstract `getDropStats()`.
- `app/lib/pages/settings/sync_page.dart` — `showSdWriteDrops` toggle, baseline keys (incl. `_kBaselineCodec`), `_buildDropStatsSection()`, `_resetAllDiagnostics()`.

### Removal plan (if ever decided the canary isn't worth keeping)

Delete the characteristic + handler + registration in `transport.c`, the `sd_card.c`/`.h` accessors if unused elsewhere, the Dart model/accessor, and the app widget + state. Leaves no functional residue — purely diagnostic surface area, no audio-path dependency.

---

## App: Background Connection Lifecycle (single mode + grace disconnect)

Shipped in 0.14.9. The two-mode "Maximize Battery" toggle is gone — there is now one background behavior. Recorded here because the invariants below are easy to undo by accident.

### Why one mode
The old default (Maximize Battery **off**) tried to stay connected in the background, but the keep-alive is off while backgrounded, so the firmware idle-dropped the link every ~15 s (`IDLE_DISCONNECT_TIMEOUT_MS`) and the app immediately reconnected — a perpetual connect↔disconnect churn that also made the foreground-service notification flicker between "Connected" and the sync status. Since the Omi records to SD regardless of BLE, holding the link in the background gained nothing. Collapsed to the old Maximize-**on** behavior: disconnect in the background, reconnect only when a sync is due (scheduled interval, or app open/resume). The `maximizeBattery` pref and the App Settings toggle were removed; every `maximizeBattery` branch was treated as always-on.

### Grace disconnect — load-bearing invariant
`onAppPaused` does **not** disconnect immediately; it arms `_pauseDisconnectTimer` (`_backgroundDisconnectGrace`, 15 s) so a quick app-switch / notification-shade glance doesn't force a reconnect on return.
- **The keep-alive must keep running during the grace window.** That — not the grace duration — is what stops the firmware idle-drop, so the link is still live if the user returns. `onAppPaused` therefore must **not** call `_stopForegroundKeepAlive()` (it used to, pre-0.14.9). A future "simplify" that re-adds the early stop silently reintroduces a mid-grace firmware drop. There's an inline comment on the field warning about this.
- **The tick polls while a sync is in flight, and the grace starts when the sync ends** (`_onPauseDisconnectTick`). Start-a-sync-then-background case: keep-alive holds the link through the sync; the tick re-checks every `_backgroundDisconnectPoll` (**3 s**) while `isSyncing` / `_backgroundSyncActive` is set, latches that it saw one (`_pauseGraceSawSync`), then hands back one **full** `_backgroundDisconnectGrace` (15 s) on the first idle tick and disconnects on the tick after that. Something must re-check: without it the one-shot timer bailed forever and the device stayed connected (keep-alive pinging) until the next scheduled sync. Local decode/VAD processing does **not** hold the BLE link, so it isn't part of the bail condition.
- **Do not collapse the poll back into the grace.** They were the same 15 s constant until 0.36.4, which made one value do two jobs: the tick re-armed a *full* grace whenever it found a sync running, so the grace a user actually got after a sync was however much of the window happened to be left when the sync ended — uniform in [0, 15 s]. A sync finishing a second before the tick dropped the link a second later, losing exactly the quick-return protection the grace exists for. Two constants, two jobs.
- **No `await` between the tick's `isSyncing` check and `disconnectDevice()`.** Dart's single thread makes that pair atomic only while it contains no suspension point — the same invariant as the GATT-cache fingerprint's `isSyncing`/`recycleConnection()` pair (CLAUDE.md). Noted at the site.
- Cancelled on resume, on any background disconnect (`onDeviceDisconnected`), in `dispose` and `prepareDFU`.
- **15 s value**: covers essentially all quick app-switches; extra connected time vs a shorter grace is negligible against the device's always-on mic draw. Deliberately a fixed constant, **not** user-selectable — a "grace seconds" slider is the battery-vs-convenience toggle we just removed, in disguise, and isn't a knob a user can reason about.

### Firmware idle-drop — keep it (do NOT remove)
The app-side disconnect is *cooperative* — it only fires while the app's process is alive and the OS runs its lifecycle callbacks. For the *non-cooperative* cases (app killed/swiped/crashed, frozen under Doze, phone out of range) nothing app-side fires, and the firmware's ~15 s idle-drop is the only thing that frees the Omi's radio. The grace delay *widens* the window where the app might not get to disconnect cleanly, so it relies on the firmware net more, not less. No firmware change was made for this work, and the idle-drop should stay.

### Notification
One foreground-service notification (id 2001), owned by the native `OmiBleForegroundService` (required `connectedDevice`-type FGS) and driven entirely by the Dart `SyncNotification` helper via `BleHostApi().setSyncStatus(title, text)` — see **"App: Notification Pipeline"** for the full state machine and strings. (The old second `flutter_foreground_task` service / `ForegroundUtil` is gone.) Dart idle writes go through `_showIdleNotification` → `SyncNotification.idle(...)`, guarded by `_syncOwnsNotification` (sync/processing/`_backgroundSyncActive`) so an active sync keeps its own live progress. The idle line shows an absolute "Next sync at H:MM" + last-sync summary (not the old relative countdown).

**Do not make the native side write its own connection state.** An earlier build had the native service post "Connected to Omi Device" / "Connecting…" / "Disconnected" / "Reconnecting…" on every GATT transition; because it shares id 2001 those clobbered the Dart-owned progress (the exact bug the Dart-side cleanup fixed — the native twin was missed). Native renders the `setSyncStatus` content Dart pushes, plus the resting line from `idleNotificationContent()`, and nothing else.

**This was a rule the code did not keep, and the gap was the "stuck on Connecting..." bug.** Four native writers survived the cleanup — `onCreate`'s `startForeground` baseline, `connectToDevice`'s retry repaint, `handleDisconnection`, and `clearSyncStatus` — all writing the literal `"Connecting..."`. Nothing settled them: the connect-settle alarm was armed **only** from `setSyncStatus`, i.e. only for a Dart-pushed transient, so a native paint had no recovery behind it at all and was cleared only by the next periodic sync alarm's `settleStaleConnectingToIdle()`. A headless service start therefore showed `Connecting...` for up to a full sync interval, re-stamped (so the notification's own `when` timestamp kept looking fresh) by every native retry and every backed-off recovery probe. In Manual Only there is no sync alarm and no recovery alarm, so `clearSyncStatus`'s copy was **permanent**. All four are gone; the baseline is now the resting line, and `DEFAULT_NOTIF_TEXT` is `"Ready to sync"`.

**And the transient it was rescuing barely existed.** On the background path `SyncNotification.connecting()` was overwritten within microseconds: `scanAndConnectToDevice()` calls `updateConnectingStatus(true)` on its first line, which pushes `idle()`, whose text does not start with `"Connecting"` — so `setSyncStatus` promptly **cancelled the settle alarm it had just armed**, and `handleDisconnection`'s pull-in (gated on `connectSettleDeadlineMs > 0`) was disarmed with it. The safety net was inert on the one path it was written for. The transient is now gone from both sides (`connecting()`, `connected()`, `disconnecting()` deleted), which removes the class rather than re-plumbing the net.

Foreground processing progress: `_onProcessingProgress` (a class method on `DeviceProvider`) is gated on `!_isAppInForeground`. When the app is open, `RecordingsController` owns the notification in time-remaining format. `_onProcessingProgress` is registered on `RecordingsManager.processingProgress` in `onAppPaused` (covering both background syncs and foreground-triggered processing that the user backgrounds) and unregistered in `onAppResumed`. `_doBackgroundSync` also registers/unregisters it for the duration of `processAllCompletedSessions`. Remove-before-add in `onAppPaused` prevents double-registration.

### Always disconnect after a background sync
`_doBackgroundSync`'s finally disconnects unconditionally in the background. The old `missingCount > 0` "keep the connection" branch was dropped — with the keep-alive stopped it just idle-dropped within ~15 s anyway. Leftover segments are picked up by the next scheduled sync / on resume (`onAppResumed` has a defensive drain for the rare resume-onto-live-link race).

### Code locations
- `app/lib/providers/device_provider.dart` — `_backgroundDisconnectGrace` + `_pauseDisconnectTimer` (field decl ~line 67), `onAppPaused` / `_armPauseDisconnect` / `_onPauseDisconnectTick`, `onAppResumed` (cancel), `_doBackgroundSync` finally (post-sync disconnect), `_handleDeviceConnected` background drop-guard, `onDeviceDisconnected` background guards, `_showIdleNotification` + `_syncOwnsNotification`.
- Removed: `maximizeBattery` getter/setter in `app/lib/backend/preferences.dart`; the `SwitchListTile` + `_maximizeBattery` state in `app/lib/pages/settings/app_settings_page.dart`.
- Keep-alive: `_startForegroundKeepAlive` / `_stopForegroundKeepAlive` (same file) — see the field-comment invariant above.

---

## App: `isConnected` latching true against a dead link (fixed 2026-08-31)

The worst class of bug this app can have — it does not crash, it does not log an error, and
every subsequent sync reports itself as a tidy little skip. Seven hours of a device holding
recordings while the app said, hourly, that it had checked.

### The chain

1. **08:42:44** — the process starts **headless** (`lifecycleState=detached uiAttached=false`,
   so `_isAppInForeground=false`). `DeviceProvider`'s constructor connects unconditionally via
   `periodicConnect('app open', …)`.
2. **08:42:45** — the connect succeeds. `scanAndConnectToDevice` sets `isConnected = true`. It does
   **not** set `connectedDevice`; only `setConnectedDevice`, called from `_onDeviceConnected`, does.
3. **08:42:47** — `_handleDeviceConnected`'s drop-guard fires: backgrounded, no pending sync, and
   `_shouldSyncNow()` false (the last sync finished eight minutes earlier). It disconnects
   **before** `_onDeviceConnected` runs.
4. The disconnect arrives at `onDeviceConnectionStateChanged`, whose disconnected branch was gated
   on `deviceId == connectedDevice?.id || deviceId == pairedDevice?.id`. Both were still null, so
   it matched nothing and **`onDeviceDisconnected` never ran**.
5. `isConnected` stayed `true`. Nothing else clears it. Every sync path branches on it, so none of
   them reconnected — and `syncAll` found `_device == null` and returned "did not run". Hourly,
   for seven hours, until the app was reopened.

### Why it appeared now

Step 1 is the 0.36.0 headless-start change meeting a comment that predates it. The constructor's
`_pendingAppOpenSync` block said, in as many words, *"`_isAppInForeground` is true here, so the
connection survives `_handleDeviceConnected`'s drop-guard long enough to sync."* That was true
while only a widget tree could build a `DeviceProvider`. A WorkManager or alarm wake now builds one
with no UI, where it is false — so the app connects and then hangs up on itself.

### The three layers, and why each is there

- **The disconnect must be observable before setup finishes.** The gate now also accepts the bonded
  id from `SharedPreferencesUtil().btDevice`, which exists from process start and is the same id
  `_scanConnectDevice` dials. Safe as the widest of the three because there is exactly one Omi
  (see **One Omi at a time**). This alone fixes the observed failure.
- **A headless start no longer connects just to be hung up on.** The constructor connects when
  `_isAppInForeground` **or** a sync is due. `uiAttached == null` still means "assume foreground",
  so a probe failure keeps the old behaviour.
- **No sync may start that the WAL layer cannot serve.** The device is handed over at the *very
  end* of `_onDeviceConnected`, so "the link is up" and "a sync can run" are different questions,
  and `_onBackgroundSyncRequested` and the auto-sync tick both branched on `isConnected` alone.
  `_doBackgroundSync` now **declines on `!hasDevice` itself** — guarded there rather than only at
  the callers because there are six of them and the whole bug was one path that did not check.
  Running anyway is not merely futile: `syncAll` returns null, the cycle records a user-visible
  "Skipped", and its `finally` **disconnects the device** — so a state only setup can repair got a
  teardown once an hour instead. It declines rather than recording a skip because this is an
  internal not-ready state, not "we tried and could not reach the Omi". On top of that, the two
  *scheduled* triggers check `hasDevice` at the branch and take the connect path, which runs setup —
  the only thing that actually fixes it. One guard prevents harm everywhere; two call sites recover.

**The third layer deliberately does not force a teardown to provoke a reconnect.** That branch is
also the ordinary few seconds of setup, and tearing down a healthy link to fix a state that is
about to fix itself is the worse trade. It sanctions the sync and lets the connect path run; if
the link really is up, `scanAndConnectToDevice` returns immediately and the intent waits for the
next connect.

Widening the disconnect gate cannot cause a reconnect storm: `onDeviceDisconnected` returns early
in the background without reconnecting at all (`if (!_isAppInForeground) … return`), and in the
foreground reconnecting to the bonded device is what it is for.

**Not unit-tested** — no test in the repo constructs a real `DeviceProvider`. The signature to look
for in a log is the one above: `_handleDeviceConnected: dropping` with no later
`proceeding to setup`, followed by `skipping syncAll — no device registered yet` on a tick that
reported `connected=true`.

---

## App: The Flutter engine outlives the Activity (0.36.0)

Shipped in 0.36.0–0.36.1. The prerequisite for background sync working at all, and the invariants below are the kind a "simplify the Android startup" pass removes without noticing.

### The failure it fixes

Android reclaims a backgrounded Activity under memory pressure — routinely, after a few hours — which destroyed its `FlutterEngine`. But `OmiBleForegroundService` keeps the **process** alive and only stops on a deliberate swipe-away. So the device stayed connected, the native BLE layer kept working, and Dart was simply gone. **Every path that can sync is Dart-side**, so both wake paths (WorkManager and the exact alarm) took their no-Dart branch and **returned success having done nothing**. That branch still exists and is still correct — a cold start reaches it before `main()` has run — but it is now a handoff: the skip it records is what makes `DeviceProvider`'s constructor connect and sync seconds later, so it no longer logs "sync deferred to next app open".

Measured on device 2026-08-28: seventeen consecutive hours where native logged 300+ records and Dart logged two, WorkManager firing on time throughout. Opening the app then drained 68 files / 125 MB / 11.3 h of audio in one go. Nothing was lost — recordings stay on the Omi until collected — but a day passed with a full device and an app that looked healthy.

### The shape

`MyApp` (the `Application`) creates the engine, caches it, and registers everything engine-scoped. `MainActivity` adopts it by id (`getCachedEngineId`) and never destroys it (`shouldDestroyEngineWithHost = false`). A reclaim therefore detaches the UI and leaves Dart running.

- **Exactly ONE engine, deliberately.** A headless per-sync engine would race the Activity's over the BLE stack; a single always-present engine has no such state to reconcile.
- **`cleanUpFlutterEngine` must NOT null `flutterApi` or clear `isFlutterAlive`.** The engine is not going away, and saying otherwise tells both wake paths Dart is dead while it runs fine — which is the original bug, restored. It releases only the Activity reference and the companion manager, both of which must not outlive the Activity.
- **`VadBatchRunner` is deliberately not destroyed.** That was right while it belonged to the Activity; destroying it now would leave later background syncs — the exact runs this enables — without a batch runner. Dart's own `dispose` releases the ORT session after each run.
- **Plugin registration still happens, but not where you'd look.** `FlutterActivity.configureFlutterEngine` returns early for a cached engine (`delegate.isFlutterEngineFromHost()`), so the Activity does **not** register plugins — `FlutterEngine(Context)` defaults `automaticallyRegisterPlugins` to true and the manifest carries no override, so the engine registers them itself before the entrypoint runs. If that default is ever changed the app loses every plugin channel at startup.
- **A failed pre-warm must not brick the app.** `FlutterActivity` throws on a cache miss, so engine creation is wrapped, `getCachedEngineId()` returns the id only if the cache actually has it, and `configureFlutterEngine` registers the platform APIs when it finds them unregistered. Worst case degrades to an Activity-owned engine (pre-change behaviour), not a launch failure.

### Four things fall out of it, all load-bearing

1. **`BleHostApiImpl` was Activity-gated.** `manageDevice` did `getActivity() ?: return`; reschedule/wake-lock did `getActivity()?.applicationContext ?: return`. A resident engine alone would have woken Dart up to make BLE calls that silently no-op. It takes the application context and falls back to it. Genuinely Activity-bound paths (companion pairing, permission dialogs) still return early exactly as before.
2. **The AAC encoder was Activity-scoped.** Once the Activity went, every `startEncoder` from the background processing isolate got `MissingPluginException` and the processor **silently fell back to WAV** — so background runs saved in the larger format. Nothing in it ever needed an Activity (MediaCodec plus a main-thread hop), so it lives in `AacEncoderChannel`, engine-scoped.
3. **`main()` now runs once per PROCESS, not per app-open**, and that process can live for days. The launch housekeeping (temp cleanup, discard recovery sweep, version stamp) would have quietly dropped to once per process. Native signals **every** attach — a process that started headless has to do its UI-only work the first time a screen appears, and that first attach is not a *re*-attach — and Dart re-runs the housekeeping, debounced on a 10 s window so a cold launch doesn't sweep the filesystem twice. Every step is idempotent. The manifest's `configChanges` covers orientation, uiMode, fontScale and density, so the Activity is not recreated for those and the signal only fires on real launches and reopens.
4. **`main()` requested permissions, and `permission_handler` THROWS without an Activity** (`PermissionManager` has an explicit `if (activity == null) errorCallback.onError("Unable to detect current Android Activity.")`). `main()` runs headless now — that is the point — so a WorkManager-started process would throw at `SyncNotification.requestPermissions()`, before `ServiceManager`, before `DeviceProvider`, and before the readiness signal. `hasUi` is asked **before** anything needing a screen, and permissions are skipped when there is none; they wait for the user to open the app.

### Two readiness signals that must not be inferred

- **`dartReady`, not "the engine was created".** `isFlutterAlive` used to be set when the engine was *constructed*, which is synchronously before a line of Dart runs — `executeDartEntrypoint` only schedules `main()`. A WorkManager-started process would be told Dart was ready and post a sync request at an engine with no Pigeon handler and no `DeviceProvider`. Dart now calls `dartReady` over the system channel once the sync path is genuinely up, so a `main()` that throws leaves the flag false and the wake paths correctly skip.
- **`hasUi`, not "lifecycleState is null".** `DeviceProvider` decided foreground with `state == null || state == AppLifecycleState.resumed`, where null meant "we just launched, assume foreground". Safe while only a widget tree could build it — a widget tree meant a screen. In a WorkManager-started process with no Activity the null **never resolves**, so the app would sit believing a user was watching: holding the link open with keep-alives and taking the foreground branch in `_handleDeviceConnected`. Flipping the default is wrong in the other direction (a genuine cold start is also briefly null, and `DeviceProvider` is now constructed before the first build), so native — the only party that actually knows — is asked. `lifecycleState` still wins whenever it is set; the native answer only fills the gap. The parameter is optional, so tests and callers that cannot ask keep the previous behaviour.

### `DeviceProvider` must be constructed eagerly

Its constructor registers `BleBridge.backgroundSyncRequestedCallback`, the entry point for **every** scheduled sync. A lazy `ChangeNotifierProvider` builds it on the first widget that reads it — fine while the engine died with the Activity (no UI meant no Dart at all), fatal with a resident engine: a WorkManager-started process may never attach an Activity, and with no view nothing drives a frame, so the tree may never build. Native would report Dart alive, deliver the request, and `BleBridge` would call a null callback. It is constructed in `main()` and handed to `ChangeNotifierProvider.value`, so it exists whether or not a UI ever attaches.

### Code locations

- `app/android/app/src/main/kotlin/com/omi/offline/MyApp.kt` — engine creation + cache, the `hasUi` / `dartReady` system channel, attach signalling.
- `app/android/app/src/main/kotlin/com/omi/offline/MainActivity.kt` — `getCachedEngineId`, `shouldDestroyEngineWithHost = false`, `cleanUpFlutterEngine`.
- `app/android/app/src/main/kotlin/com/omi/offline/AacEncoderChannel.kt` — the encoder, moved off the Activity.
- `app/android/app/src/main/kotlin/com/omi/offline/BleHostApiImpl.kt` — application-context fallback.
- `app/lib/main.dart` — `hasUi` probe, `dartReady`, eager `DeviceProvider`, `_launchHousekeeping` + its 10 s debounce.
- `app/lib/providers/device_provider.dart` — `_isAppInForeground` taking the native answer.

**Not device-verified at merge.** It changes app startup and Activity lifecycle and nothing in the host suite exercises either — see LIVE_TESTING.md.

---

## App: Notification Pipeline

**Single notification, single owner (rewritten — the old two-service model is gone).** There is now **one** persistent foreground-service notification: the native Android `OmiBleForegroundService` (id 2001, required `connectedDevice`-type FGS). The Dart `flutter_foreground_task` second service and its `ForegroundUtil` wrapper were **removed** (no longer in `pubspec.yaml`). All Dart-side content now flows through **`SyncNotification`** (`app/lib/utils/audio/sync_notification.dart`), which pushes a `(title, text)` pair to native via `BleHostApi().setSyncStatus(title, text)`; native renders it on the single notification. **All `SyncNotification` methods no-op on iOS** (no persistent notification — background work runs via BGProcessingTask).

`SyncNotification` is a small state machine. The states form the sync cycle:

```
idle → preparingSync → syncing → finishingSync →
preparingProcessing → processing → finishingProcessing → complete → idle
```

Discrete transitions are pushed immediately (live). Only the high-frequency in-state progress text (segment counter, processing %) is throttled by its callers. `setPersistent(bool)` keeps the FGS alive with no device connected so the idle line survives BLE disconnect + app background (true while auto-sync is on and a device is bound; false in Manual Only / unbound). `clear()` releases Dart ownership so native resumes its own connection-state text.

### Ownership rules

**`DeviceProvider`** is the sole writer when the app is in the background, and owns the FGS lifecycle (start/stop) + `SyncNotification.setPersistent` during background syncs. Its idle line goes through `_showIdleNotification()` → `SyncNotification.idle(...)`, guarded by `_syncOwnsNotification` so an active sync/processing run keeps its own live progress.

**`RecordingsController`** is the sole writer when the app is in the foreground. `_updateForegroundProgress()` (throttled 1 s foreground / 2 s background, only fires when `_spState` is `syncing` or `processing`) calls `SyncNotification.syncing(syncingNotificationText(...))` / `SyncNotification.processing(processingNotificationText())`.

**Transition guard:** `DeviceProvider._onProcessingProgress` is gated on `!_isAppInForeground`; `RecordingsController._updateForegroundProgress` only fires when `_spState == syncing || processing`. The two writers never overlap on the same tick.

### All notification strings, by state

Each row is one `SyncNotification` method, rendered natively as **title** + **text** (no longer a single em-dash-joined string):

| State (method) | Title | Text |
|---|---|---|
| `preparingSync()` | `Syncing recordings` | `Preparing…` |
| `syncing(text)` | `Syncing recordings` | `N of M segments (X%)` (or `Preparing...` when total = 0) — `RecordingsController.syncingNotificationText` |
| `finishingSync()` | `Syncing recordings` | `Finishing…` |
| `preparingProcessing()` | `Processing recordings` | `Preparing…` |
| `processing(text)` | `Processing recordings` | `~N min of audio to process (X%)` / `< 1 min of audio to process (X%)` / `Calculating… (X%)` / `Preparing...` / `Finishing...` — `RecordingsController.processingNotificationText` |
| `finishingProcessing()` | `Processing recordings` | `Finishing…` |
| `uploading(text)` | `Uploading recordings` | controller-composed one-line summary + per-integration lines (multi-line; shown only while the sync/process pipeline is idle) |
| `complete()` | `Conversations ready` | `Sync and processing complete` |
| `idle()`, auto-sync on, has synced | `Next sync at H:MM` | `Last Sync: {Complete\|Partial\|Skipped} • H:MM`, then ` • N% Battery` **only when that reading is current** — see below |
| `idle()`, no outcome recorded yet | `Next sync at H:MM` / `Omi Offline` | `Ready to sync` |
| `idle()`, muted | `Muted since H:MM` (or `Omi is Muted`) | `Next sync at H:MM` / `Auto-sync off` |

**Every state is work or an outcome; none is link state.** `connecting()` / `connected()` / `disconnecting()` are gone, and `idleBodyText`'s no-outcome fallback is the single string `Ready to sync` rather than the old `Omi is Connected` / `Connecting...` / `Omi is Disconnected` ladder. Two reasons, and the second is the binding one: a transient can be left standing by an isolate the OS froze, and native's mirror (`idleNotificationContent`) has **no view of the link at all** on a headless start, so any link-derived text makes the two renderers disagree in exactly the state where only the native one runs. `idle()` still takes `isConnected`, but purely to gate the battery clause below — it is never rendered as text. The link is visible in the app itself (the app-bar spinner in `recordings_page.dart`), an unreachable Omi surfaces as `Last Sync: Skipped`, and a persistent outage gets the separate "Omi can't reconnect" alert on its own channel.

The idle line now shows an **absolute next-sync time** ("Next sync at H:MM") and a last-sync outcome summary, not the old relative "Next sync in ~N min" countdown. `SyncNotification.nextSyncTime` / `isMuted` / `muteSince` are mirrored from `DeviceProvider` so any caller can render these.

### Battery freshness rule on the idle line (0.36.4)

`lastBatteryLevel` is a **stored** reading, and the idle line used to print it unconditionally. A **skipped** sync is one that never reached the Omi — out of range, or no answer — so on a skip that number is at least one interval old and ages through every cycle that misses while the line asserts it unchanged. A day away from the device and it still claimed a percentage from breakfast.

The percentage is now rendered only when the app has **current knowledge** of it: the last sync actually reached the device (not `lastSyncSkipped`), **or** the link is up right now. The live-link escape is load-bearing — `lastSyncSkipped` stays set until the next sync *completes*, so gating on it alone would blank the battery while the user is watching a connected device. A null `isConnected` counts as **not** connected (`SyncNotification.idle` has a caller that passes nothing): assert less rather than more.

Two renderers, one rule. `SyncNotification.idleBodyText()` (Dart) was extracted so the rule is unit-testable — `app/test/unit/utils/sync_notification_idle_text_test.dart`. `OmiBleForegroundService.idleNotificationContent` (Kotlin) is its documented mirror and carries the same branch; that half matters more, because it renders exactly when the Flutter isolate is frozen or gone, which is the long unreachable stretch where the stored reading is most stale. **The live-link escape used to be dead there** — its only caller wrote `lastSyncSkipped = true` immediately before rendering — and was carried anyway on the principle that a rule reading the same in both mirrors beats eliding a branch. It is genuinely reachable now: the Kotlin half is now the general resting renderer (`onCreate`'s `startForeground`, `clearSyncStatus`, and the sync alarm's refresh), so it runs with the link up while `lastSyncSkipped` is still set from an earlier miss.

The Kotlin half reads the next-sync time from `ble_config/next_sync_ms`, written by `SyncAlarmReceiver.schedule()` — the single funnel that arms or cancels the sync alarm, so the rendered time and the armed alarm cannot disagree. It replaced an in-memory field that a headless start always found at `0`, which rendered a bare `Omi Offline` title. A due-time already in the past renders as-is, matching what Dart's `idle()` does with its own `nextSyncTime`.

### Recording a cycle that could not run

The resting line is only as honest as the outcomes behind it: with no connect transient to
notice, a cycle that silently does nothing would leave the line asserting the *previous*
outcome indefinitely. `SyncAlarmReceiver` therefore records the skip itself, and does so
from a direct signal rather than an inference.

At each firing it resolves `flutterApi` **once** and reuses it for both the skip decision
and the delivery, so the two cannot disagree. `flutterApi == null` ⟺ `isFlutterAlive ==
false` ⟺ Dart never signalled `dartReady` in this process (`bleManager.flutterApi` is
assigned in `BleHostApiImpl`'s init, long before `main()` runs, and nothing ever nulls it —
see CLAUDE.md on `cleanUpFlutterEngine`). Every sync path is Dart-side, so that branch means
this alarm will pull nothing: it writes `flutter.lastSyncSkipped` / `flutter.lastSyncStatusMs`
and leaves `lastSyncCompletedMs` alone.

Three properties worth preserving:

- **The write happens before `startServicePersistent`.** On a cold start that call runs
  `onCreate`, whose `startForeground` renders from exactly these keys — so the first frame
  shows this cycle's outcome rather than the last one's. `apply()` updates the in-memory map
  synchronously, so the same-process read sees it.
- **The refresh (`renderIdleFromPrefs`) is inside the same `flutterApi == null` branch.**
  Unconditional, it would clobber live "Syncing…"/"Processing…" progress when a sync runs
  longer than one interval. Guarded, it cannot: no Dart means no sync in flight.
- **It replaced a text sniff.** The old `settleStaleConnectingToIdle()` inferred the same
  thing from the notification reading `"Connecting…"` — which required native to have
  written that text, the very thing that stranded the line, and could only conclude anything
  on the *next* alarm, a full interval later.

That alarm check covers a cycle that **never started**. A cycle that started and was then
**killed** is covered by its sibling, the cycle marker.

### The cycle marker

`SharedPreferencesUtil.syncCycleStartedMs` is stamped when a cycle is accepted and cleared on
every terminal path — `_armConnectSettleWatchdog` and `_doBackgroundSync`'s entry stamp it,
`_doBackgroundSync`'s `finally` and `_failSyncCycleToIdle` clear it. The pair to it is
**process liveness, not a second timestamp**: a non-zero value found by a *fresh* process
belongs to a cycle whose owner no longer exists and can therefore never finish.
`DeviceProvider._sweepOrphanedSyncCycle()` runs once from the constructor and records it.

Why not the obvious check — "did `lastSyncStatusMs` advance since the last alarm?" That cannot
tell a dead cycle from a sync legitimately running longer than one interval, so it would write
"Skipped" over a sync still in progress, and (via `renderIdleFromPrefs`) clobber its live
progress line. The liveness framing needs no staleness window and no heartbeat, so there is
nothing to tune.

Two rules, both in the pure `DeviceProvider.orphanedCycleStatusMs` so they are unit-testable
(`test/unit/providers/orphaned_sync_cycle_test.dart`):

- **Stamped at the marker's own time, never at "now".** The cycle failed when its process
  died, possibly hours earlier; "Last Sync: Skipped • 3:45 AM" is the true statement.
- **Yields to any outcome already recorded at or after that instant** — a foreground sync, or
  the alarm's own Dart-not-up skip — so the writers cannot fight over one cycle. The `>=` is
  the boundary a `>` would invert, and it fails toward fabricating a skip over a real result,
  so it is pinned explicitly.

The sweep runs **last** in the constructor: it can push the notification, and
`_startBackgroundSyncTimer` is what publishes `nextSyncTime`, without which the title renders
a bare "Omi Offline". The cost is that the `_shouldSyncNow()` earlier in the constructor ran
without the skip this may set, so an orphan brings the next sync forward by a tick rather than
forcing a connect during launch. The flag persists, so nothing is lost.

Still not covered, deliberately: Dart alive but **frozen** after receiving the request, in a
process that is never killed. `flutterApi` is non-null (a freeze is not a death, and no flag
distinguishes them) and the marker's owner still exists, so the line keeps the previous outcome
until Dart thaws and `_failSyncCycleToIdle` runs. Detecting *that* needs a heartbeat plus a
staleness threshold, which is the tuned knob the rest of this design avoids.

### Real-bin fixtures (`app/test/fixtures/bins/`)

Every other bin in the suite is **synthesised by the test**, writing headers and frame headers
by hand using the same model of the format the parser uses. A shared misunderstanding of what
the firmware actually emits is therefore invisible to all of them, by construction. Two tiny
fixtures off a real device (app 0.35.6, captured 2026-08-29) break that circle — 476 B with
four frames and a `0xFFFFFFFD` VAD-resume, and 36 B of metadata header alone (an empty-bin
rotation). `test/unit/services/real_bin_format_test.dart` drives the **production**
`VadAudioProcessor` over them with a counting stand-in decoder.

It earns its place: mutating the frame-advance rule from `4 + ((len + 3) & ~3)` to
`4 + len` — dropping the 4-byte alignment — takes the frame count from 4 to 1 and fails the
test, while every synthetic fixture, written by that same rule, stays green.

**What it cannot express, and must not be read as covering.** Nothing about audio. `opus_dart`
is FFI over libopus and `VadAudioProcessor` builds a decoder only on iOS/Android, so on the
host every real Opus payload decodes to whatever the stand-in returns — no real PCM, no
meaningful VAD verdicts, no recordings. It is evidence about *framing*, and about nothing
downstream of the decoder. VAD, splitting and stitching stay with the synthetic fixtures,
which can script speech and silence deliberately.

The 118-bin capture it came from settled three things. The app's format model walks every one
of them to exactly its length, with no unparsed tail and no implausible frame. SD-stored Opus
frames are **VBR, 61–160 B** (mean payload 87.0 B). And the codec's storage estimate was
**21% low**: measured across 1,538,037 frames the real rate is ~309,000 B/min, not the 243,000
the model gave, because that model assumed a 1-byte length prefix (it is 4 bytes), an 80 B mean
payload (87.0), and no block padding at all (10.3% of every bin).

That measurement is what settled the codec surface's fate rather than fixing it. Chasing the
constant's consumers showed the whole chain was dead — `getAudioCodec()` → `Wal.codec` →
`wals.json` → nothing, and `getStorageBytesPerMinute()` → `Wal.estimatedSegments` → `wals.json`
→ nothing, with `Wal.seconds` never even written. All of it is gone; see CLAUDE.md under the
BLE protocol section for the trace and the `wals.json` compatibility note. The numbers above
are kept here because they are the measurement, and the next person to wonder what an Omi
recording costs per minute should find it rather than re-derive it.

### "Calculating…" guard

`RecordingsController.processingNotificationText()` returns `Calculating… (X%)` when `RecordingsManager.minutesRemaining < 0` but progress has started (`progress > 0`) — i.e. the async file-size measurement hasn't completed yet — to avoid flashing "< 1 min" during the brief gap when `_spState` flips to `processing` before the byte-count is known. (At `progress == 0` with `minutesRemaining < 0` it shows `Preparing...`.)

### Foreground → background handoff

When the user backgrounds the app during a foreground-triggered processing run, `onAppPaused` does `removeListener(_onProcessingProgress)` + `addListener(_onProcessingProgress)` (remove-before-add prevents duplicates if `_doBackgroundSync` also registered it). From that point `DeviceProvider._onProcessingProgress` updates the notification even if `RecordingsController` is eventually disposed. `onAppResumed` removes the listener and `RecordingsController` resumes ownership.

### Stopping subtext

`SyncProcessCard` shows `"Stopping…"` with a dynamic subtext keyed on the stage the pipeline was in when Stop was pressed: `"Transferring current file…"` when `data.lastActiveStage == 'syncing'` (a BLE segment write may still be in flight, so it can't abort instantly without risking corruption), else `"Finishing current step"`. `lastActiveStage` is a controller-owned `String` (`'syncing'` / `'processing'`), passed in via `SyncCardData.lastActiveStage` from `controller.lastActiveStage` at the build site in `recordings_page.dart`.

### Code locations

- `app/lib/utils/audio/sync_notification.dart` — **`SyncNotification`**, the single Dart-side owner: state methods (`preparingSync`…`complete`, `idle`), the muted/idle title+text rendering, `setPersistent` / `clear`, and `_push` → `BleHostApi().setSyncStatus(title, text)`.
- `app/lib/providers/device_provider.dart` — `_onProcessingProgress` (class method), `_syncOwnsNotification`, `_showIdleNotification` (→ `SyncNotification.idle`), `SyncNotification.setPersistent`, `_doBackgroundSync` (lifecycle + listener register/unregister), `onAppPaused` / `onAppResumed` (listener handoff).
- `app/lib/pages/recordings/recordings_controller.dart` — `_updateForegroundProgress`, `syncingNotificationText`, `processingNotificationText`, `lastActiveStage`.
- `app/lib/pages/recordings/sync_process_card.dart` — `SyncProcessState.stopping` case (dynamic subtext via `data.lastActiveStage`).
- `app/lib/pages/recordings/recordings_types.dart` — `SyncCardData.lastActiveStage` field.
- `app/lib/pages/recordings/recordings_page.dart` — `SyncCardData` construction (passes `lastActiveStage` from `controller`).
- native `OmiBleForegroundService` — renders `setSyncStatus(title, text)` on the single id-2001 notification.

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

## BLE: "advertising but won't connect" (OPEN — central-side captured 2026-07-08; culprit side still undetermined)

**Status:** the peripheral **is** advertising and the phone **is** seeing those advertisements and sending `CONNECT_IND`. Each resulting link dies ~165 ms later with `0x3e`, before any data-channel packet is exchanged. This rules out hypothesis (A) (slow-adv interval unconnectable) and the "stale OS link holds the single conn slot" theory. It does **not** yet identify which side goes silent — see "What 0x3e does and does not prove". Do **not** change battery-affecting advertising behavior — the adv path is exonerated.

### Central-side capture (2026-07-08, `adb logcat` + `dumpsys bluetooth_manager`, OnePlus Open / CPH2551, Android 16)

Captured live while wedged. Four consecutive attempts inside one 30 s app-level connect window:

| ACL up | ACL down | alive |
|---|---|---|
| 22:37:42.609 (handle 4) | 22:37:42.765 | 156 ms |
| 22:37:45.632 (handle 5) | 22:37:45.798 | 166 ms |
| 22:37:55.672 (handle 6) | 22:37:55.844 | 172 ms |
| 22:37:58.704 (handle 7) | 22:37:58.870 | 166 ms |

Each one logs `OnLeConnectSuccess: Connection successful le remote:…a8:d5 handle:N initiator:local` → `btm_acl_created` → ~165 ms later `OnLeLinkDisconnected … reason:CONNECTION_FAILED_ESTABLISHMENT(0x3e)`. **Zero** SMP/encryption attempts in the whole buffer, so the link dies before bonding, before ATT, before anything reaches the Java layer.

~165 ms ≈ 6 connection intervals at the negotiated ~27.5 ms. Per spec the connection-establishment timeout is exactly 6 connection events: the central exchanged no data-channel packet with the peripheral in any of them.

### What `0x3e` does and does not prove

**Do not read `OnLeConnectSuccess` as "the peripheral accepted the connection."** On the central, `HCI_LE_Connection_Complete` fires as soon as the local controller transmits `CONNECT_IND` and creates its link context; it is **not** an acknowledgment from the peer. So the capture proves only two things: the phone received the Omi's `ADV_IND` (an initiator only sends `CONNECT_IND` in response to one), and the phone then heard nothing back for six connection events.

Three explanations remain, and the central's logs cannot separate them:
1. **The Omi never received the `CONNECT_IND`** — its TX is healthy (we see the ADVs) but its RX is deaf.
2. **The Omi received it but never transmitted** in the connection events (peripheral controller / netcore wedge). Note a *host* wedge cannot cause this: the peripheral's controller sends the empty LL PDU autonomously, no host involvement.
3. **The phone's own controller never listened** during those six events — radio starvation from an existing LE ACL plus continuous scanners.

The recovery evidence is split and is the strongest discriminator available:
- 2026-06-08: **power-cycling the Omi** fixed it instantly → favors (1)/(2).
- 2026-07-08 (and per NOTES §"Mitigation applied 2026-06-16"): **toggling the phone's Bluetooth** fixes it → favors (3), since cycling the phone's adapter cannot repair a wedged peripheral controller.

These may be two distinct failure modes wearing the same `0x3e`. Phone-side contention at the time of the 2026-07-08 capture was substantial: a live LE ACL to a Garmin Instinct 2X Solar, plus five ongoing LE scans including `com.heytap.accessory` (36.6 M ms cumulative active scan) and `com.facebook.stella` (50.2 M ms).

**`failed_conn_count` cannot settle it — the instrumentation is mis-targeted** (found 2026-07-08). It increments only in `_transport_connected`'s `err != 0` branch (`transport.c:1178-1194`). A peripheral hitting `0x3e` never takes that branch: its controller emits `LE Connection Complete` with *success* the moment it receives `CONNECT_IND`, so the host sees `connected(err=0)` and only afterwards `disconnected(0x3e)`. And `_transport_disconnected(conn, err)` (`transport.c:1244`) **discards `err`** — it does not even log the reason. So the counter reads 0 whether the Omi received 40 connect requests or none. Confirmed empirically: after the 2026-07-08 outage the app's `Device BLE connect-fail counter` line (`device_provider.dart:1485`) never printed, i.e. the counter was 0, despite 40+ `0x3e` on the phone.

**The measurement that would settle it:** count and persist peripheral-side *disconnect* reasons — specifically `err == BT_HCI_ERR_CONN_FAIL_TO_ESTAB (0x3e)` — in `_transport_disconnected`, and expose it in the existing drops characteristic. Then, after an outage:
- nonzero → the Omi **did** receive the `CONNECT_IND`s and the link died at establishment → (2), peripheral controller / RF / coex.
- zero → the Omi **never heard them** → (1) deaf RX, or (3) the phone never put a usable `CONNECT_IND` on air.

A **Bluetooth toggle is the preferred recovery for diagnostics** — it restores connectivity without resetting the Omi, so persisted counters keep their pre-outage values and device uptime is intact.

**Things this rules out, with evidence:**
- *Stale OS link holding the peripheral's single conn slot.* `dumpsys bluetooth_manager` shows `C3:94:71:EA:A8:D5` **only** in the bonded-device list — zero GATT connections, no ACL, not in any client's connection list. `com.heytap.accessory` holds a Scanner with `Connections: 0`; its GATT-server callbacks for the Omi are just passive `connected=false` notifications riding each failed link. Nothing on the phone holds a link. (This falsifies the comment at `OmiBleForegroundService.kt:50-52`.)
- *GATT client-interface exhaustion in our app.* `com.omi.offline.dev` holds exactly one client interface (`app_if: 17`). The registered-client list has three entries total.
- *Advertising stopped / slow-adv unconnectable.* ACLs form within 416 ms of `connectGatt`, four times in 16 s. The adv path works fine.

**`gatt_status_-1` is a red herring.** It is synthesized by our own `handleDisconnection(addr, hash, -1)` when the local connect timeout fires (`OmiBleForegroundService.kt`, the `timeoutRunnable` in `connectToDevice`). Android *does* deliver a disconnect for every one of these links — but at the BTA layer, to `bta_gattc_conn_cback`, before a Java `onConnectionStateChange` for our in-flight `connectGatt` ever materializes. So "no callback at all" means "the link never lived long enough to become a GATT connection", **not** "the phone's stack is wedged". Do not read `-1` as host-stack silence.

**`-1` *plus* a flat estab delta is a different matter** (2026-07-24 Wedge 3, 2026-08-04 Wedge 7 — see BLE_Research.md §4). The 2026-07-08 episode above could not be read from `-1` because the counter that discriminates did not yet work; `estab_fail_count` now does. An outage where every failure is `-1` **and** `estab_fail_count` is unchanged either side means the Omi never heard the `CONNECT_IND`s at all — i.e. explanation (1) or (3), not (2) — and both such episodes cleared only on a phone Bluetooth toggle, which points at (3). Read the *pair*, never `-1` alone. A toggle as brief as ~2.6 s has cured this class.

**Consequence for the recovery machinery:** `WEDGE_FORCE_PURGE_AFTER` / `purgeGhostGattForAddress(force=true)` and the "toggle Bluetooth" alert are firing on a ghost that provably does not exist here. The forced purge issues its own dummy `connectGatt` + immediate `disconnect()`/`close()` every 60 s, adding `cancelOpen` / accept-list churn on top of a peripheral that is already failing establishment. It cannot fix a 0x3e and should be re-scoped.

### Contention experiment (2026-07-08) — explanation (3) reproduced

Run live, mid-outage, after ~14 consecutive failed retries (#8 → #21), **without** a Bluetooth toggle and **without** touching the Omi:

```
adb shell am force-stop com.facebook.stella
adb shell am force-stop com.garmin.android.apps.connectmobile
```

This dropped the phone's only live LE ACL (to a Garmin Instinct 2X Solar) and two continuous scanners. The **very next** automatic retry (`retry_22_postpurge`, 22:52:50) connected in 2.5 s: `GATT_CONN_OK` → SMP → MTU 498 → 14 services → 11 WALs synced and deleted. **Zero `0x3e` in the following 80 s**, versus 40 in the preceding buffer.

So the Omi was never broken. Explanation **(3)** — central-side radio starvation — is the operative one for this outage.

**Why this shape of failure:** connection *establishment* is fragile (the peer must be heard within 6 consecutive connection events, ~165 ms) while an *established* link is robust (seconds of supervision timeout, connection latency tolerated). A busy central can therefore fail every new connection while happily servicing the links it already has. That is exactly why a **phone Bluetooth toggle "fixes" it**: the toggle tears down the competing ACL, the Omi wins the now-empty establishment window, and once established it coexists with the watch and the scanners indefinitely. It looks like the toggle repaired the Omi. It didn't.

**This result did NOT hold up.** Follow-up attempts the same evening (see "Failed reproduction" below) show contention alone does not cause the failure. Treat the force-stop recovery as coincidence until reproduced.

### Failed reproduction (2026-07-08, same session)

Two attempts to reproduce, both **invalid** — recorded so nobody repeats them:

1. **Restore `stella` + `garmin`, force a fresh Omi connect.** Connected first try, zero `0x3e`. Invalid: `monkey`-launching the apps did not restore their scans/ACL within 50 s, so the contention was never actually present.
2. **Drop the Omi link, re-establish with glasses + watch up.** Connected in 32 ms, zero `0x3e`. Invalid: `am force-stop com.omi.offline.dev` does **not** tear down the LE ACL (no `btm_acl_created` follows), so `connectGatt` merely reattached to the existing link. It never re-established.

What *is* established: three concurrent LE ACLs (Meta Ray-Bans `7F:02:83:…`, Garmin `CD:65:…`, Omi) plus four ongoing scans coexist fine, and the Omi connects in 32–400 ms under that load. **Contention alone is not sufficient.** The trigger for the wedged state remains unidentified.

Note also: after a sync completes and the firmware idle-drops the link (`reason=19`, `REMOTE_USER_TERM` — working as designed), the app makes **no** reconnect attempt until the next 30-minute sync tick. Any reproduction attempt must account for that or it will observe nothing.

**Caveats on the force-stop result:** n=1; two apps were stopped at once; and our own `SCAN_MODE_LOW_LATENCY` scan stopped 11 s before the successful connect, so the recovery is confounded with our own scan ending.

**Self-inflicted contention (worth fixing regardless):**
- `device_provider.dart:621-625` starts a parallel BLE scan 5 s into every connect (`unawaited(discover(timeout: 10))`) — i.e. it adds a scanner precisely while establishment is most fragile.
- `purgeGhostGattForAddress(force=true)` fires a dummy `connectGatt` + immediate `disconnect()`/`close()` 500 ms before each real connect, adding initiator/`cancelOpen`/accept-list churn. We now know there is no ghost to purge.
- Our 15 s / 30 s local timeout fires before Android surfaces the real disconnect status, so the app logs the synthetic `-1` and **never sees the `0x3e`**. The wedge detector keyed on `-1` is therefore counting "we gave up early", not "the stack went silent".

**Still open:** attribute the contention (Garmin ACL vs `stella` scan) by restoring one app at a time and forcing an Omi reconnect. Note that forcing a *real* re-establishment means waiting out the firmware's 15 s idle-drop or a sync tick — `am force-stop` will not do it (see above).

### Capturing the next outage without adb (`WedgeDiagnostics.kt`, added 2026-07-09)

The 2026-07-08 capture only happened because the outage was noticed while a cable was to hand. An outage that starts overnight is over before anyone can attach adb, so the app now snapshots one itself.

Fires from `OmiBleForegroundService.handleRetryLogic` on the sixth consecutive failed connect, i.e. the same latch that posts the toggle-Bluetooth notification, once per outage. Written from **native**, not Dart: outages happen while backgrounded, where the Flutter isolate may be Doze-frozen and unable to service a platform channel. The foreground service is still running.

Three events land in the `omi_debug_*.log` that `DebugLogManager` owns, in its own one-JSON-object-per-line `logEvent` shape, so the in-app viewer and "Save Diagnostic Logs to File" pick them up with no changes:

| Event | When | Carries |
|---|---|---|
| `ble_wedge` | immediately at detection | failure/retry counts, last GATT status, adapter + bond state, every LE link the system holds, whether a stale GATT/ACL link to the Omi exists, screen + Doze state |
| `ble_wedge_scan_probe` | ≥8 s later | `adv_packets`, RSSI min/max/last, `verdict`, `probe_ms` + `probe_requested_ms` |
| `ble_wedge_recovered` | on the next successful connect | how long the outage lasted, failures before recovery, and the **same environment snapshot** `ble_wedge` took (adapter state, contending LE links + count, screen + Doze) |

The environment snapshot appears on **both** `ble_wedge` and `ble_wedge_recovered` so the two can be diffed: a wedge that clears on its own (no `bluetooth_off` disconnect in the log before it) leaves no trace of *why* otherwise. A `contending_le_links` count that fell, `screen_interactive` flipping true, or `doze_mode` exiting between detection and recovery is the most likely cause of a spontaneous recovery — the transient central-side contention the 2026-07-08 experiment reproduced — and the only one these logs can name without adb. Diff `contending_le_links` (contenders only), **not** `le_link_count`: the latter folds in the Omi's own link, which is absent at wedge and present at recovery, so a lone contender dropping cancels against it and both events read the same total.

`ble_wedge_scan_probe.verdict` is the point of the exercise:
- `peripheral_advertising` → the phone can plainly hear the Omi while every connect dies at establishment. Its TX and our RX both work; the link dies in the handshake between them.
- `no_advertisements_heard` → either the Omi's radio stopped or the phone's never listened. Cross-check against the device's `estab_fail_count`.

**`probe_ms` is the window the scan actually listened for; `probe_requested_ms` is what it asked for.** They differ because the scan is stopped by a main-looper `postDelayed`, which in a backgrounded app runs late — the state every real outage is in. Divide `adv_packets` by `probe_ms`, never by the constant, and read a large gap between the two as its own finding: it measures how starved the main thread was. Logs from app ≤ 0.34.8 carry only `probe_ms` **and it is the constant**, so packet counts from those are not comparable between probes (BLE_Research.md §2).

**The verdict also gates the toggle-Bluetooth alert**, so the probe is load-bearing and runs even when file logging is off. Six failures alone do not mean a wedge — an out-of-range, powered-off, or otherwise-connected Omi produces the same streak, and Android reports the same generic `133` for a device that isn't there as for one whose links keep dying. Only `peripheral_advertising` means "present and unreachable", the one case where toggling Bluetooth is sensible advice. Every path where the probe cannot run reports `true`, preserving the pre-probe behaviour.

**Two counter invariants, both load-bearing:**
- The streak clears in `onGattServicesDiscovered`, **not** `onGattConnected`. `onGattConnected` fires on `newState == STATE_CONNECTED` with the GATT `status` ignored, so a link that comes up and dies — the exact failure being detected — would reset the streak on the way past and it could never reach `WEDGE_NOTIFY_AFTER`. The observed "connects, then service discovery times out at 30 s" loop does precisely this. Services discovered is the first point the link has demonstrably carried traffic.
- `wedgeDetected` latches at *detection*, not at notification. It is what makes capture once-per-outage; whether an alert follows is the probe's call.

The device's own counter cannot be read during an outage, by definition. Dart's `_finishDeviceSetup` logs it on the next successful connect, right after `ble_wedge_recovered` — which is why both halves of the picture end up in one file.

**Constraints that shaped this, so nobody tries to "improve" it:**
- The app **cannot** read `bt_stack` HCI logs or `dumpsys bluetooth_manager`. Those need `READ_LOGS` / `DUMP`, both `signature|privileged`. The phone-side `0x3e` count stays adb-only, permanently. The advertising probe is the reachable substitute, and it answers the same question.
- The probe uses `SCAN_MODE_LOW_LATENCY` — the exact duty cycle just removed from the discovery path. Deliberate: it is bounded to 8 s, at most once per outage, and runs inside the ~30 s gap between backed-off retries (retry #6 backs off to the 30 s cap) so no connect is in flight. A lower duty cycle would let the 1 s slow-advertising tier fall between scan windows and report a false `no_advertisements_heard` — the one reading this probe exists to make trustworthy.
- **It does not write the log file at all any more (0.36.5).** It encodes each record on the caller's thread, queues it, and drains to Dart over `BleFlutterApi.onNativeLogRecords`; `DebugLogManager.appendNativeRecords` does the writing under the same `_writeLock` as every other Dart writer. Native's own `FileOutputStream(append = true)` was a real `O_APPEND` write, and Dart's `FileMode.append` is not one — it resolves the offset at open — so Dart landed on top of native's records and destroyed them **whole**, leaving no torn line for the 0.34.9 tear-counting diagnostic to notice. One record of eight survived a 4.4 h capture. Do not restore a native writer to this file in any form; see BLE_Research.md for the full account and for why the original "negligible collision" estimate was wrong (the two writers are correlated — native emits on disconnect, which is exactly when Dart is bursting about that disconnect).
- Whether anything is captured is still Dart's call — `DebugLogManager` drops records when "Save Debug Logs to File" is off, so **nothing is captured unless it is on**. Native no longer infers this from the file's existence; it queues regardless and Dart discards. The queue is bounded at 256 records, and overflow emits a `native_log_records_dropped` record with the count rather than losing them silently.
- The queue drains when the next record is enqueued **and** when Dart signals `dartReady` (`MyApp.kt`). The second is not redundant: boot-time records have no successor to push them out, and they are the ones describing the state the app started in.

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
- `_transport_connected` err path (~line 1035): increments the counter, records the adv mode, schedules a throttled flash persist (`conn_fail_persist_work`, `app_settings_save_conn_fail`), and still RTT-logs `Connection failed (err 0x3e) adv_mode=slow failed_conn_count=N …`.
- Persisted via Zephyr settings key `omi/conn_fail` (`struct conn_fail_record { count; last_adv_slow; }`).
- Exposed by **appending 8 bytes to the existing drops characteristic `0x19B10062`** (28 B at the time: legacy 20 + `failed_conn_count` u32 @20 + `last_failed_adv_slow` u32 @24; the char has since grown to **100 B** — see "SD Write Drop Counters"). No new characteristic — backward compatible (old app reads first 20).

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

### Mitigation applied (2026-06-16): disabled CDM presence observation
Phone-side counterpart to the firmware-wedge hypotheses above — **a mitigation, not a confirmed root-cause fix** (section stays OPEN). The app used CompanionDeviceManager presence observation (`startObservingDevicePresence`) to wake on device-appeared and reconnect in the background. On OnePlus/Oplus/Realme stacks the OS satisfies that observation by holding its *own* passive LE link to the Omi, which contends for the firmware's single connection slot (`CONFIG_BT_MAX_CONN=1`). With the slot held by the OS, the app's `connectGatt` can't get in and the retry loop spins until a *phone*-BT toggle tears down every host-side link at once. That symptom — a **phone** BT toggle (not an Omi reboot) is what recovers it — points at the host stack / OEM accessory contention (cf. the `com.heytap.accessory` GATT connections in the 2026-06-08 log) rather than the firmware `0x3e` wedge.

**Change:** removed every `startObserving*` call site; kept the association. `manageDevice` now calls `stopObservingForAddress` instead of `startObservingForAddress`, so any observation a prior app version left armed is torn down on upgrade (releases the passive link without a re-pair). Background reconnect is unaffected in substance — it was already self-sufficient: `SyncAlarmReceiver` / `BackgroundSyncWorker` → `onBackgroundSyncRequested` → `device_provider._onBackgroundSyncRequested`, which calls `scanAndConnectToDevice()` (connect-by-address) whenever `!isConnected`. The only behavior dropped is instant presence-triggered reconnect while backgrounded; reconnection now waits for the next periodic sync tick. No capture impact — firmware writes to SD regardless of phone connectivity.

**Independent of the firmware watchdog (hypothesis B).** If `failed_conn_count` still climbs after this, an RF/controller wedge is also in play and the watchdog is still warranted. **Reversible:** re-add `startObservingForAddress` in `manageDevice` and `startObserving()` in `OmiCompanionManager.onActivityResult` — `BleCompanionService` and the manifest `companion_device_setup` entry were left intact.

**Code:** `OmiBleForegroundService.manageDevice`, `OmiCompanionManager` (the `startObserving*` methods were deleted; `stopObservingForAddress` retained), `find_devices_page._connectToDevice` (comment), CHANGELOG 0.24.5.

### Related (already fixed, separate bug)
The Android-side `PlatformException(channel-error … requestCompanionDeviceAssociation)` seen first was a **different** problem: `AndroidManifest.xml` was missing `<uses-feature android:name="android.software.companion_device_setup">`, so `CompanionDeviceManager.associate()` threw `IllegalStateException` synchronously → pigeon surfaced it as the opaque channel-error. Fixed by adding the `uses-feature` + a defensive try/catch in `BleHostApiImpl.requestCompanionDeviceAssociation`. That fix is what let the flow progress far enough to expose this firmware-side `0x3e`.

### Code locations
- `omi/firmware/omi/src/lib/core/transport.c` — `failed_conn_count` / `current_adv_mode` / `last_failed_adv_slow` / `conn_fail_persist_work` (~line 302), failure path in `_transport_connected` (~line 1035), 40-byte `diagnostics_drops_read_handler` (~line 369), boot seed in `transport_start` (~line 1737), `current_adv_mode` sets in `_transport_disconnected` / `transport_set_adv_slow` / `transport_set_adv_fast`, `adv_param_slow` definition.
- `omi/firmware/omi/src/settings.c` + `src/lib/core/settings.h` — `omi/conn_fail` persistence (`struct conn_fail_record`, `app_settings_save_conn_fail` / `app_settings_get_conn_fail`).
- `omi/firmware/omi/src/aad.c` — slow/fast switch requests (`adv_slow_req`/`adv_fast_req`, ~lines 244–247, 298, 318, 452).
- `omi/firmware/omi/omi.conf` — `BT_MAX_CONN`, `BT_CTLR_TX_PWR_ANTENNA`, (absence of) `BT_PRIVACY`, `BT_PERIPHERAL_PREF_*`.
- `app/lib/services/devices/device_drop_stats.dart` — `failedConnCount` / `lastFailedConnDuringSlowAdv` on `DeviceDropStats`.
- `app/lib/services/devices/omi_connection.dart` — `performGetDropStats` length-gated parse of bytes 20–27.
- `app/lib/providers/device_provider.dart` — `_finishDeviceSetup` connect-time log (`device_conn_fail`).
- `app/lib/pages/settings/sync_page.dart` — `_buildDropStatsSection` "BLE connect failures" rows.
- `app/android/app/src/main/AndroidManifest.xml` — the `companion_device_setup` uses-feature (the separate fix).

## Discard-recovery overhaul + audio-pipeline coverage + reboot/manual-mode semantics (2026-06-22)

Started from "discard recovery is still messed up" and fanned out into a full audio-pipeline coverage audit and the manual-mode/reboot recording semantics. All app changes below sit **on top of PR #322** (the original byte-range Recover fix, app 0.25.7).

**STATUS (updated): all of the below SHIPPED** — the app changes in **0.25**, the firmware change (§9) as **oo-2.4**. The original end-of-session note ("all changes local/uncommitted, app suite 353 green, analyzer clean, firmware unbuilt") is historical. **Follow-on work after this session (PR #323 + later commits) added the `discarded_segments` relocation**: a fully-processed, discard-claimed bin is now *moved* out of `raw_segments/` into a sibling `discarded_segments/` folder (`RecordingsManager.retainDiscardBin` / `resolveDiscardBin`) — retired from the processing pool but kept for Recover — rather than deleted. That refines the §2/§5 "delete the bin" behavior described below.

### 1. Recover bloat — coalesce `[min,max]` hull swallowed un-discarded audio
**Symptom:** a discard shown as "24s" recovered into a 4–9 minute clip. Device logs proved slicing WAS active (a recover run decoded 5647 of a ~13991-frame bin = ~40%), so it wasn't the old whole-bin bug — the slice itself was too wide.

**Root cause:** the on-disk discard ledger stores **tight per-record byte ranges**, but `DiscardStore._coalesceDiscards` -> `_unionBinRanges` collapsed several time-adjacent discards' per-bin spans into a single `[min, max]` **hull** at READ time. When two coalesced discards reference the same ~5-min bin at non-adjacent byte ranges (a head slice + a tail slice with a real recording in the gap — common under the AAD-fallback flood, whose bogus near-identical timestamps coalesce), the hull spans the un-discarded recording between them. Recover slices the hull -> re-derives the neighbor recording. The on-disk jsonl was fine; the hull was a read-time artifact -> **no migration needed**.

**Fix (disjoint intervals end-to-end):**
- `DiscardRecord.binRanges`: `Map<String,List<int>>` -> `Map<String,List<List<int>>>` (per-bin list of DISJOINT `[start,end)` intervals). In-memory only — the jsonl WRITE format stays flat `[s,e]` (one record is always one contiguous span); `_parseBinRanges` wraps flat->`[[s,e]]` and tolerates nested.
- `DiscardStore._mergeIntervals`: sort + merge only OVERLAPPING / byte-ADJACENT (`end == next start`); real gaps stay separate. `_unionBinRanges` is now interval-union, not a hull.
- `RecoverSlice` carries `List<List<int>> ranges`; `recoverDiscard` builds per-bin interval slices; `processAll` + `IsolateParams.segmentByteRanges` (`List<List<List<int>>?>`) + the worker plumb interval lists.
- `processSegmentFile`: param `startByte`/`endByte` -> `List<List<int>>? byteRanges`. The decode loop jumps the read head over gaps between intervals (decodes only interval frames) and **suppresses VAD-resume gap padding when sliced** so recovery matches frame content. Also suppress the inter-file gap padding when sliced (consecutive firmware bins carry no real gap; any "gap" is an anchor artifact).
- Tests: `discard_store_binranges_test.dart` — disjoint stays separate, byte-adjacent merges; nested parse shape.

### 2. Sibling-bin data loss — Recover deleting a bin another ghost needs
**Symptom (caught by the new logging):** `RecoverDiscard: NO bins on disk — dropping ghost WITHOUT recovering audio`. Bin `1782158329` was shared by two discards: a HEAD `[56,56900]` (19:58:49 ghost) and a TAIL `[56920,60712]` (part of a 20:01:16 ghost). Recovering the 20:01:16 ghost first ran `Deleting raw segment .../1782158329` — the WHOLE bin — so the head ghost then had nothing left.

**Root cause:** during a recover run, `processAll`'s in-isolate delete sweep (`discardProtectedPaths`) is seeded only by discards CREATED in that run (none, for recovery). It doesn't protect bins referenced by OTHER persisted discard records.

**Fix:** `DiscardStore.discardedRelBinPathsExcludingSpan(spanStartMs, spanEndMs)` returns bins of discards OUTSIDE the recovered record's span (the span test mirrors `removeDiscardRecord`, so the record's own coalesced constituents are excluded but a sibling sharing a bin is kept). `recoverDiscard` passes those as `processAll(seedProtectedBinPaths:)`, which seeds `discardProtectedPaths`. Recover now logs `Preserving raw segment for recovery: ...` for the shared bin instead of deleting it. One ghost was already lost before the fix — that bin was gone. Tests added.

### 3. "Completed" banner silently blocked Recover
**Symptom:** tapping Recover while the green "Completed" banner is up did nothing; a second tap (after it auto-cleared) "just made it disappear."

**Root cause:** `recoverDiscard` guarded on `if (_spState != SyncProcessState.idle) return;`. After any sync/process the controller sits in `successUi` (the banner) for ~10s before auto-dismissing to `idle`. `successUi` is SETTLED, not busy, so blocking on it was wrong. (Tapping Recover with the banner up was a harmless no-op — it returned before touching anything — so it did NOT lose the discard; the disappearance was the later tap actually recovering it.)

**Fix:** new `RecordingsController.isPipelineBusy` getter (`syncing|processing|stopping|isProcessingAny`, EXCLUDES `successUi`). `recoverDiscard` dismisses a lingering banner (`dismissSuccess()`) and proceeds; only no-ops when actually busy. `recordings_page` wraps per-row + multi-select recover with a busy-gate snackbar ("Finishing sync — try recovering again in a moment.").

### 4. Recorded-audio duration (`audioMs`) — shown length == recovered clip == what the Omi recorded
**Requirement (user):** the recovered clip and the shown duration must both equal the frames the device actually recorded. Real recorded silence (continuous quiet frames) counts; device-asleep `0xFFFFFFFD` gaps (firmware AAD slept, wrote NO frames) must NOT be padded in.

**Design:** the clip side was already right (resume-gap padding suppressed during sliced recovery). The DISPLAY was wrong — it showed the wall-clock span (`endTime - startTime`), which includes device-asleep gaps and, for coalesced ghosts, the time BETWEEN stretches.
- New `DiscardRecord.audioMs` = `frameCount * frameDurationMs` (real recorded frames), written in `_buildDiscardRecordFor`. `startTime`/`endTime`/`duration` (the wall-clock span) are KEPT for retention / removal-matching / draft-finalize non-speech accounting.
- `DiscardRecord.audioDuration` getter (falls back to `duration` for legacy records with `audioMs==0`).
- `DiscardStore` parses `audioMs`; `_coalesceDiscards` SUMS it across constituents (audio is additive; gaps carry none).
- UI (`batch_card.dart`): ghost-row label, bottom-sheet detail, and the visible/hidden filter all use `audioDuration`.
- Result: a 77s-span coalesced ghost with 26.5s of frames now reads ~27s and recovers to a ~27s clip.

### 5. RecoverDiscard logging (diagnostics)
All filterable by `RecoverDiscard:` (+ one `VadAudioProcessor: byte-slice recover ...` line). Trace per tap: `requested` (start/reason/dur/refBins/ranges/spState) -> `SKIPPED — pipeline busy` | `WARNING — N/M bins missing` | `NO bins on disk — dropping ghost WITHOUT recovering audio` (the silent-loss case, now loud) -> `byte-slicing N bin(s)` (or `WHOLE-BIN fallback`) -> `protecting N sibling bin(s)` -> `decoding X of Y B` -> `processAll FAILED` | `DONE`.

### 6. Full audio-pipeline coverage audit (Omi -> recording page)
Verified the discard work does NOT touch VAD recording creation (all changes are discard metadata, recovery-only `!sliced` paths, UI, banner, logging). Coverage invariant confirmed:
- `processSegmentFile` adds EVERY decoded frame (speech or not, even decode-failures) to `_currentRefs` (`:1404`).
- Two-pass `_flushVadBatch` replays EVERY deferred frame through `_applyVadVerdict`.
- At any boundary (silence-split / max-cap / session-end / mute / marker / EOF) `_currentRefs` is SAVED (recording) or DISCARDED (ghost) before it is cleared. Session-end / mute-on handlers flush+save BEFORE they start skipping.
- End of run -> `flushRemaining(isDraft:true)` -> `_draft` + bins kept -> re-stitched next cycle.

**Only non-recoverable drops (intentional):** muted stretches (skipped frames, surfaced as a delete-only "muted" ghost — mute = don't keep), and decode-failure frames (still byte-referenced, play as silence). Real recorded audio is fully accounted for (recording / discard ghost / pending draft).

### 7. Reboot gap — `_sessionEndPendingResume` not cleared on session change
`_sessionEndPendingResume` (the "ignore incoming audio" skip) is set by manual-stop (`0xFFFFFFFC`) and mute-on (`0xFFFFFFFA`); cleared by tap (`0xFFFFFFFE`), resume (`0xFFFFFFFD`), mute-off (`0xFFFFFFF9`) — but NOT by a session change. So mute/stop -> device reboots while still latched -> the flag carries into the new session and the new session's frames are dropped at the per-frame skip (`:1051`), unsurfaced. The app's own code already treats a session change as "effectively the unmute" (`_emitMutedDiscard` clears `_muted`) but forgot the skip flag.

**Fix:** in `processSegmentFile`, on `sessionChanged`, clear `_sessionEndPendingResume`. `_currentSessionId` is persisted in the VAD checkpoint (`'csi'`), so this also catches a reboot BETWEEN sync runs. With the firmware persist-change (below), this now mainly bites the **mute-in-auto + reboot** case (a manual-stop+reboot leaves the device in standby -> no frames to drop).

### 8. Manual-mode VAD threshold trace (firmware + app)
**Values:** recording ON = `65535` (gate `thr==65535 || avg>=thr` -> always); standby/OFF = `32769` (avg can't reach half-scale -> never); auto = ~`250` (sound-gated). `aad.c:276-289`.

**Persistence — the crux:**
- App (BLE write) -> `transport.c:704+710` calls BOTH `app_settings_save_vad_threshold` (flash) AND `aad_set_threshold` (runtime). **Persisted.**
- On-device BUTTON double-tap -> `button.c:171/178` calls ONLY `aad_set_threshold`. **Runtime, NOT persisted.** (Connected, the app echoes a BLE write that persists it — but offline it doesn't.)
- Boot loads the persisted value, default `DEFAULT_VAD_THRESHOLD = 32769` (`settings.c:12`, `aad.c:417`).

**Key correction:** the app only writes `32769` from `setManualMode(true)` (entering manual mode) — NOT on a normal button tap. The slider (`device_settings.dart:771`) is **auto-mode only** (`!manualMode`), so manual mode has no user-set threshold — recording on/off is purely the button sentinel. So `32769` after reboot comes from the firmware DEFAULT or a one-time `setManualMode` write, never the button; the button's `65535`/`32769` toggles are forgotten on reboot.

**Consequence (the real offline bug):** offline you button-start (runtime `65535`) -> reboot loads persisted `32769` -> **standby, recording silently stops.** Here the app's `_sessionEndPendingResume` fix is moot — the device writes no frames.

### 9. Firmware fix — persist the manual recording state
`button.c` manual branch now calls `app_settings_save_vad_threshold(65535)` on start and `app_settings_save_vad_threshold(32769)` on stop (alongside `aad_set_threshold`), mirroring the BLE path. So manual recording survives reboot (start->records, stop->stays stopped). Flash wear is a non-issue (manual taps are infrequent; the BLE path already persists on every change). **SHIPPED as firmware oo-2.4** — CHANGELOG: "Manual-mode recording now survives a reboot… saved to flash." (Verified in `button.c`: `app_settings_save_vad_threshold(65535)` on start, `(32769)` on stop.)

Mute in auto mode needs NO firmware change: `is_muted` is separate from the threshold and never persists, so an auto-mode device that was just muted comes back recording — and the section-7 app fix keeps those post-reboot frames.

### 10. Read-and-adopt threshold model (app)
**Principle (decided):** the firmware owns the threshold (persists across reboot + oo->oo OTA, which under MCUboot doesn't erase NVS — the reconcile-push only existed as OTA-wipe recovery, and a wipe only happens from non-oo / a partition-layout change). The app READS it and WRITES only on an explicit in-app action (auto slider, mode toggle).

**Changes (`device_provider.dart`):**
- **Button event:** was an echo that toggled off the app's own (possibly stale) `_manualRecording` guess and wrote the threshold — could flip the device to the OPPOSITE of what you did. Now READS `getVadThreshold()` and sets `_manualRecording` from it; no write.
- **Connect reconcile:** was read-then-PUSH (force device to the app's remembered mode -> stomped offline button changes). Now READ-and-ADOPT: `65535`/`32769` -> `manualMode=true` + recording state from the value; any real auto value -> `manualMode=false`; `thr==null` (read fail) -> leave as-is.
- `setManualMode` and the slider still write (the "set once, then persisted" path). `_setDeviceVadThreshold` retained (used by `setManualMode`).
- No automated test (device_provider is BLE-bound, no harness) — verify on device: manual-record offline -> reboot -> reconnect should still show "recording".

### Code locations (this session)
- `app/lib/models/recordings/recordings_models.dart` — `DiscardRecord.binRanges` (nested), `audioMs`, `audioDuration`.
- `app/lib/services/discard_store.dart` — `_parseBinRanges`, `_mergeIntervals`, `_unionBinRanges` (interval-union), `_coalesceDiscards` (sum `audioMs`), `discardedRelBinPathsExcludingSpan`, `audioMs` parse.
- `app/lib/services/vad_audio_processor.dart` — `processSegmentFile` byte-`ranges` slicing + padding suppression (`!sliced`), `_buildDiscardRecordFor` (`audioMs`, `frameCount`), `_sessionEndPendingResume` clear on `sessionChanged`.
- `app/lib/services/recordings_manager.dart` — `RecoverSlice` (intervals), `processAll(seedProtectedBinPaths)`, `discardProtectedPaths` seed, `discardedRelBinPathsExcludingSpan` wrapper.
- `app/lib/services/recordings_isolate_worker.dart` — `IsolateParams.segmentByteRanges` (`List<List<List<int>>?>`), passes `byteRanges:`.
- `app/lib/pages/recordings/recordings_controller.dart` — `isPipelineBusy`, `recoverDiscard` (banner-dismiss, sibling protection, logging).
- `app/lib/pages/recordings/recordings_page.dart` — `_recoverDiscard` wrapper + busy-gate snackbars.
- `app/lib/pages/recordings/batch_card.dart` — `audioDuration` for label/detail/filter.
- `app/lib/providers/device_provider.dart` — button event read, connect reconcile read-and-adopt.
- `omi/firmware/omi/src/lib/core/button.c` — `app_settings_save_vad_threshold` on manual start/stop.
