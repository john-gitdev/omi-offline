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

## PENDING

## Device-driven BLE wake (firmware + iOS) [large] [Pending]

Shift background-sync triggering from the *phone* (opportunistic iOS `BGTaskScheduler` / Android alarms) to the *device*: the Omi opens a connectable advertising **window** on its own RTC-driven schedule, and the phone — holding a standing pending-connect — is woken by the OS the moment that window opens. This is the model commercial BLE wearables (e.g. CGMs) use for reliable background sync on iOS.

### The honest framing (why)
The primary win is **iOS wake *reliability* + device-controlled (punctual) timing**, **not** device battery. The firmware already advertises *slow* (~1 s, `adv_param_slow` in `transport.c`) when idle, which is already cheap; going fully "dark" saves only a bit more. The real reason: a standing pending-connect lets iOS wake the app on the *device's* schedule, replacing the opportunistic `BGTaskScheduler` path (which iOS fires unpredictably and never punctually). The same mechanism *forces* the firmware change — a standing pending-connect pointed at a device that advertises connectably **continuously** (today's behavior) would reconnect → idle-drop → reconnect forever (churn). So the device must advertise connectably only in **windows it controls**. **Net: mostly an iOS project.** Android already wakes reliably (FGS + exact alarm + WorkManager) and needs little/no change.

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

Phone side: a **standing pending-connect is always armed** (iOS `connect()` + restoration; Android `autoConnect=true`). The device's cooldown = the sync cadence, punctual because the device's RTC drives it.

### Firmware changes (the enabling work)
1. **Dark state** — `transport_set_adv_dark()`: prefer **non-connectable** advertising (`BT_LE_ADV_NCONN`) so the device stays visible for diagnostics/UI but rejects CONNECT_IND (or fully `bt_le_adv_stop()` for lowest power). Track in `current_adv_mode`.
2. **Sync-window scheduler** (new `sync_window.c` or folded into `transport.c`, a `k_work_delayable`): DARK for `cooldown_ms` → open SYNC WINDOW (`transport_set_adv_fast()` for `window_ms`, **45–60 s** — iOS background scan is duty-cycled and slow to notice adverts) → on connect, the existing `idle_disconnect_work` owns teardown; on `_transport_disconnected`, restart cooldown; window expiry with no connect → DARK, restart cooldown.
3. **Hand advertising ownership from AAD to the scheduler** — keep AAD's VAD/SD-pause logic; remove/gate its `adv_*_req` writes (`aad.c:310,330,464`, applied in the AAD loop `aad.c:247-250`). Most invasive *refactor*; regression-test VAD recording, SD pause/resume, marker durability.
4. **Gate windows on "has unsynced data"** — use "SD has stored files" as the proxy (app deletes via `CMD_DELETE_FILE`); SD empty → stay DARK until new audio is recorded.
5. **Config characteristic + opt-in mode (default OFF)** — new char under Settings service (`0010`, e.g. `0014`): `interval_minutes(u16) + window_seconds(u8) + enabled(u8)`, persisted via `settings.c`, range-validated in firmware. Makes the app's existing `backgroundSyncIntervalMinutes` drive the *device's* cadence. **Crucially, the windowing is a per-device mode the app pushes, and the firmware default is `enabled=0` = today's always-connectable behavior** (so old apps and Android are untouched). `enabled=1` activates DARK/window cycling. See "Cross-platform: why this is opt-in" below.
6. **Capability bit** — add `deviceDrivenSync` to the Features bitfield (`0021`, `OmiFeatures`) for mixed-version safety (new app + old fw → old timer path; old app + new fw → covered by #7).
7. **On-demand connectability (critical UX safeguard, see "Button-to-wake" below)** — button/motion triggers to open a window immediately, plus a **safety floor**: no successful sync for `> N` intervals → fall back to continuous connectable advertising so the device can't become permanently unreachable.
8. **(Alternative model) Held low-power connection** — instead of windowing, set **slave latency > 0** in `update_conn_params` + a "data ready" notify characteristic (the CGM model). Lower wake latency, simpler app logic, but the radio stays in-connection (more device power than DARK). Default to windowed for the 150 mAh budget; keep this in reserve.

### Button-to-wake (user-selectable, integrates with existing button mapping)
The on-demand trigger (#7) is a natural fit for the **already-shipped customizable button-mapping system** (`button_config_service` in firmware, `button_config_page.dart` in app — maps None/Mute/Marker/Toggle-LED to single/double/triple tap and their holds, synced over the encrypted value-validated button-config characteristic). Add a **new "Wake for Sync" action** to that action set:
- Firmware: on the mapped gesture, `button.c` kicks the sync-window scheduler straight to SYNC WINDOW (open a connectable window now), regardless of cooldown.
- App: expose "Wake for Sync" as a selectable action in `button_config_page.dart`; **default to single tap**, but user-customizable exactly like every other mapping (open to making it single tap out of the box or fully user-selectable — both are supported by the existing infra).
- Firmware must range-accept the new action value (the config char already rejects out-of-range actions — bump the accepted enum).
- UX: foreground "Sync now" prompts "tap your Omi to sync now" when the device is DARK between windows.

### iOS app changes (the real payoff)
1. **Standing pending-connect** — after routine sync/disconnect, **re-arm `centralManager.connect(peripheral, options:nil)`** instead of leaving it cancelled, so iOS holds it pending and wakes the app at the device's next window. Add a `standingConnect: Set<String>` alongside `manuallyDisconnected`; distinguish "Forget Device" (truly cancel) from "routine post-sync disconnect" (cancel link, re-arm pending connect).
2. **Routine disconnect ≠ terminal in Dart** — post-sync (`device_provider.dart:884`) and pause-grace (`:996`) map to a new "disconnect-but-stay-armed" path (`disconnectKeepingPendingConnect`), not `unmanageDevice`. Only true unpair calls full `unmanageDevice`/`disconnectPeripheral`.
3. **Wake → sync** — mostly there: the wake arrives as `didConnect` → `onDeviceReady` → `_handleDeviceConnected`; ensure the background drop-guard lets a device-initiated wake through (set pending-sync flag, as `_onBackgroundSyncRequested` does). `_onStateRestored` (`device_provider.dart:232`) already sanctions a due sync.
4. **Demote BGTaskScheduler to backstop** — keep the `BGProcessing`/`BGAppRefresh` tasks (shipped 0.25.4) as the fallback for when pending-connect misses (notably after **user force-quit** — iOS won't relaunch for BLE then).
5. **Foreground manual-sync UX** — surface the button-to-wake affordance since the device may be DARK on app open.

### Cross-platform: why windowing is opt-in (and Android keeps the status quo)
It's **one device** — the firmware can't be DARK for iOS yet always-connectable for Android at the same time; whichever phone is nearby sees the same advertising behavior. The two platforms want opposite things:
- **iOS** *gains* from DARK/window cycling (reliable background wake it otherwise lacks), and loses little on-demand connect (iOS has no good instant on-demand today anyway).
- **Android** *loses* from it: today the device is always connectable, so opening the app connects **instantly**, anytime. DARK between windows breaks that instant on-demand connect (you'd wait for the next window or tap Wake-for-Sync). Android is the platform with the *good* on-demand experience, so it has the most to lose — and it doesn't need device-driven wake (FGS + exact alarm already wake it reliably).

Resolution: **windowing is the per-device `enabled` flag (#5 above), default OFF.** `enabled=0` = today's always-connectable behavior (instant on-demand connect, no tap, alarm-driven) — **Android stays here → zero regression**. `enabled=1` = device-driven windows — iOS opts in. Note: **scheduled** sync needs no tap on either mode (windows auto-connect via the pending-connect); only **immediate/on-demand** connect regresses under `enabled=1`, which is exactly what the Wake-for-Sync tap mitigates.

### Android changes (none required — stays on `enabled=0`)
Android keeps today's path entirely: always-connectable firmware, FGS + WorkManager + exact alarm wake, instant on-demand connect, no tap. The firmware windowing is inert for Android because the app never sets `enabled=1`. (If an Android user *wanted* device-driven cycling, `autoConnect=true` (`OmiBleForegroundService.kt:470`) would catch the windows the same way iOS does — but there's no reason to, so leave it off.) **Do not** re-introduce `CompanionDeviceManager` presence observation — this fork removed it due to OnePlus/Oppo/Realme connection wedges (0.24 changelog). Keep the alarm as the safety net.

### Hard tradeoffs & risks
1. **On-demand connect regresses (only when `enabled=1`)** — DARK between windows means no instant connect on app open; fully dependent on button/motion triggers + safety floor. Biggest UX risk — but scoped to opted-in (iOS) devices; Android and opt-out users on `enabled=0` keep instant on-demand connect.
2. **iOS user force-quit kills background BLE wake** until next manual launch (iOS platform rule). BGTask backstop partially covers it.
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
- `app/lib/providers/device_provider.dart` — `disconnectDevice(isManual:true)` sites (`:884`,`:996`), `_onStateRestored` (`:232`), `_onBackgroundSyncRequested` (`:208`).
- `app/lib/services/devices/transports/native_ble_transport.dart` — add `disconnectKeepingPendingConnect`; `app/lib/pigeon_interfaces.dart` for the new host API + the window-config write.
- `app/lib/pages/settings/button_config_page.dart` — expose "Wake for Sync" as a selectable button action (default single tap).
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
