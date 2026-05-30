# Changelog

### Ghost recordings: fixed overlapping timestamps & grouped consecutive discards (0.14.17)

- **Discarded "ghost" recordings no longer stack on top of each other with identical timestamps.** After an in-stream silence split, the next conversation was re-anchored to the *start of the bin file* (or the last VAD-resume point) instead of the current frame's wall clock — so every chunk in a long ambient-noise stream got the same start time and the discard records piled onto each other in the recordings list. Each new conversation is now anchored to its first frame's actual time, so timestamps advance monotonically and never overlap.
- **Consecutive discards now group into a single entry.** A continuous noise/silence period — which the processor internally splits into many ~2-minute chunks — used to surface as dozens of back-to-back ghost rows. The recordings list now coalesces discards whose gaps are within 30s (RTC-drift tolerance) into one entry spanning the whole period, with the union of their bins. A real recording or a device-idle gap still separates genuinely distinct periods. Note: recovering or deleting a grouped entry now acts on the whole span (the merged block recovers as one recording).

### Banner shows bin count alongside minutes-to-process (0.14.16)

- The "Audio to process" banner now reads **"~X minutes to process · Y bins"**, so you can see both the estimated decode time and how many raw `.bin` files are waiting. The draft fallback is unchanged ("X min Y sec accumulated").

### Banner title follows its figure (0.14.15)

- The pending-audio banner now titles itself **"Audio to process"** when it's showing the minutes-to-process figure, and keeps **"Conversation in progress"** only when it falls back to an open draft's accumulated duration — so a large backlog no longer reads as a single in-progress conversation.

### Banner shows minutes-to-process (0.14.14)

- **The "Conversation in progress" banner now leads with how much audio is actually waiting to be decoded** — "~N minutes to process", counting only the raw `.bin` audio that's pending (finalized-session and discarded/silence bins excluded, matching what processing actually does). It falls back to the open draft's "Xm Ys accumulated" only when there's no raw audio left to process. This removes the confusing jump where the banner showed a tiny "accumulated" figure and the next screen then showed a much larger "to process" number for the same backlog.

### App-side silence splitting so conversations actually finalize (0.14.13)

- **Auto-mode recordings now split on the app's own VAD detecting silence, not only on the firmware's gap signal.** Previously, conversation boundaries depended entirely on the firmware reporting a long-enough silence gap (`0xFFFFFFFD`). In a continuous-audio environment the firmware rarely produces a gap anywhere near the ~110s threshold, so the *entire* synced backlog stitched into one unbounded conversation that never finalized — its `.bin` files were never deleted, and every sync re-decoded the whole growing pile from scratch (~80s per ~12-min segment), which the OS then killed before it could finish. The processor now independently cuts when its Silero VAD has seen `vadSplitSeconds` of continuous non-speech: the speech is finalized (trailing silence trimmed off), so its bins are deleted and the backlog drains instead of growing. Long pure-silence stretches are trashed, but their raw `.bin` files are kept recoverable on disk (excluding any bin that also backs a saved recording, so nothing gets duplicated).

### Stuck-sync recovery & "Keep Screen On" toggle (0.14.12)

- **The sync/processing banner can no longer wedge with no way out.** When the BLE link died mid-transfer (e.g. the device stopped streaming partway through a file in the background), the WAL service's "syncing" flag could stay stuck set, stranding the banner in *Syncing…* or — after tapping Cancel — *Stopping…* forever, with no way to start a new sync short of force-closing the app. A watchdog now force-recovers to idle when a sync makes no progress for 60s, or when a cancel doesn't take effect within 12s, releasing the wakelock and foreground notification the same way a normal finish does. The recovery is logged (with the stuck flags and time-since-progress) so the underlying stall is diagnosable.
- **New "Keep Screen On" toggle in Debug Tools.** Holds a wakelock while the app is open so the screen never sleeps — useful for babysitting a foreground sync/processing run. It survives backgrounding (re-asserted on resume) and no longer gets cleared when a sync/processing pass finishes.

### Debug logging now captures background audio processing (0.14.11)

- **VAD/processing logs reach the debug log file.** With dev logging enabled, the audio-processing pass (Opus decode → VAD → encode) runs in a background isolate where `SharedPreferences` isn't initialized, so `DebugLogManager` read its `false` default and silently dropped every line — none of the processor's per-file, marker, or stitching logs ever hit `omi_debug_*.log`. The real preference is now forwarded across the isolate boundary, so those lines are persisted alongside the main-isolate logs.
- **Per-run processing timings.** The processing isolate now logs run start (segment count + background flag), per-segment wall-clock time (`segment i/N (bytes) processed in Nms`), and a run-end summary (total segments/bytes/ms) — to make it possible to diagnose why a background pass takes as long as it does.

### Notification fix: native connection-state clobber & live foreground processing progress (0.14.10)

- **"Connected to Omi Device" no longer overrides sync/processing progress.** 0.14.9 stopped the *Dart* side from writing connection state to the persistent notification, but the native Android BLE service shares that same notification and was still posting "Connected to Omi Device" / "Connecting…" / "Disconnected" / "Reconnecting…" on every connection change — so the moment the link (re)connected during a sync or processing pass, it clobbered the progress text. The native service now uses a single fixed baseline and never writes connection state.
- **Notification shows live processing progress with the app open.** When a sync finished and processing began while you were watching the app, the notification froze at "Processing recordings — preparing…" instead of advancing. It now counts through the actual processing progress in the foreground, the same as it already did in the background.

### Single background mode, grace-period disconnect & notification fix (0.14.9)

- **One background behaviour; "Maximize Battery" toggle removed.** The app used to have two background modes — stay-connected (the default) and disconnect-after-sync ("Maximize Battery") — but the stay-connected default never actually held the link: with no background keep-alive the firmware idle-dropped the connection every ~30 s and the app immediately reconnected, churning Bluetooth (and the notification) about once a minute for no benefit. Since the Omi records to its SD card whether or not the phone is connected, holding the link in the background gained nothing. The app now **always disconnects Bluetooth while backgrounded** and reconnects only when a sync is due (on the auto-sync interval, or on app open/resume). The toggle and its setting are gone.
- **Grace period before the backgrounded disconnect.** To avoid paying a reconnect on quick app-switches, the app now waits ~30 s after being backgrounded before dropping the link, keeping the firmware keep-alive running so the connection survives that window. Come back within ~30 s and you're still connected; stay away and it disconnects to save battery. If a sync is still running when the window elapses, the keep-alive holds the link through the sync and the grace restarts once it finishes. (The device's own idle-disconnect remains the safety net for when the app is killed or frozen and can't disconnect cleanly.)
- **Background notification no longer flickers.** The persistent notification used to flip between "Connected to Omi Device" and "Next sync in ~N min" as the connection churned. It now shows only the next-sync countdown — stable regardless of connection state — while a running sync/processing pass still takes over the notification with its own progress.
- **Always disconnect after a background sync.** Removed a leftover branch that kept the connection alive when segments still remained after a sync; with the keep-alive stopped it just idle-dropped within ~30 s anyway. Any leftover segments are picked up by the next scheduled sync (or on app open/resume).

### Background-sync keep-alive & "Conversation in progress" banner (0.14.8)

- **Large recordings now finish syncing in the background.** During a background sync the app now sends the firmware keep-alive (HEARTBEAT `0x32`, the same one used in the foreground) every 20 s, so the device no longer trips its 30-second idle-disconnect mid-transfer. Previously any single file that took longer than ~30 s to download — typically the large stitched/draft recordings — dropped with "Stream closed without EOT" and only inched forward via resume across reconnects; with **Maximize Battery** on (which suppresses background reconnects) such a file could stall indefinitely. Batches of small files were unaffected, because each file's read/delete command already reset the firmware's idle timer.
- **Unprocessed-bin count in the banner.** The "Conversation in progress" banner now surfaces how many synced raw `.bin` files are still waiting to be folded into the accumulated draft, alongside the existing accumulated duration (e.g. "2m 30s accumulated · 4 bins pending"). Finalized and VAD-discarded bins are excluded. The banner now also appears when there are pending bins even if the accumulated draft duration is still under a second.

### Background Sync, Notifications & Fixes (0.14.7)

- **Sync on app open.** With "Maximize Battery" on, opening the app now triggers a sync whenever one is due — i.e. once the auto-sync interval has elapsed since the last sync (the same timer the background sync uses; "Manual Only" never auto-syncs on open). Previously the sync-on-open path was gated to non-battery-saver mode, so battery-saver users had to sync manually every time — opening the app only pushed the next-sync time out by another interval without actually syncing.
- **Countdown re-anchors to the last sync.** The auto-sync countdown now resets to the moment the most recent sync *finished*, so a sync at 3:05 with a 30-min interval schedules the next one at ~3:35. Applies uniformly to manual syncs (the recordings pipeline and Debug Tools) and background syncs — previously a manual sync left the periodic timer on its original schedule.
- **Sync-timer notification.** The persistent background notification is now titled **"Omi Offline Sync Timer"** and counts down to the next scheduled sync ("Next sync in ~N min"), refreshed on each ~5-min background heartbeat. The heartbeat continues to kick off the sync itself once the timer elapses (reconnecting first when needed).
- **Notification wording.** Foreground-service and alert notifications are now consistently branded **"Omi Offline"**; the connected-state notification reads **"Connected to Omi Device"**. Per-operation detail (sync/processing progress) moved into the notification body.
- **24-Hour Time toggle fix.** "Ghosted" entries (discarded / too-short recordings) and their detail sheet were always rendered in 24-hour time regardless of the 24-Hour Time setting. They now follow the toggle like the rest of the app.

### Bulk delete perf (0.14.6)

- **Batched SharedPreferences writes.** `RecordingsManager.deleteConversations` was calling `removeUploadedFromHeypocket({key})` once per conversation, paying N disk syncs for an N-file delete. Keys are now collected up front and removed in a single prefs write.
- **Concurrent per-file deletes.** The per-conversation `file → meta → bin` delete sequence now runs concurrently across conversations via `Future.wait`. Each conversation touches disjoint paths; fail-soft semantics on every delete are preserved. Speeds up multi-select delete, retention sweeps, and the short-recording purge.

### Debug Tools & WAL persistence (0.14.5)

- **WAL save storm fixed.** `WalFileManager.saveWals` was firing per BLE packet (~50 Hz) from the fast-path sync, hammering the disk and flooding logs with identical writes. Throttled to 1 Hz; state-transition saves (deletion, transfer failure, end-of-sync) still persist immediately.
- **WAL file races closed.** `loadWals` and `saveWals` are now serialized by a `Mutex`, so the merge-read inside `saveWals` can no longer observe a mid-truncate empty file — a latent path that could have silently dropped other devices' WAL entries.
- **SD Write Drops opt-in.** The Debug Tools panel that polls SD-card drop counters every 2 s is now gated behind a toggle (off by default). Since the counter has stayed at zero in the field, the BLE read no longer runs unless you're actively investigating.
- **Diagnostic-log window.** The "Recent Diagnostics" block is now a fixed-height (240 px) terminal-style scroll box showing the last 50 entries, anchored to the bottom. It no longer reflows the surrounding UI as logs accumulate, and refreshes every 2 s while the toggle is on.

### Connection Reliability & Battery (0.14.4, Firmware oo-1.9.0)

- **Keep-Alive Pings.** Introduced a foreground keep-alive timer (`sendKeepAlive`) to prevent the firmware from prematurely idle-disconnecting. Dead connections are force-disconnected after consecutive keep-alive failures.
- **Background Leaks.** Closed reconnect leaks when "Maximize Battery" is on, ensuring the app actually stays disconnected in the background.
- **Android BLE Stability.** Added direct connect-by-MAC fast paths, static presence observation helpers, and auto-recovery for stale BLE bonds following an OTA update.

### Manual Mode Enhancements (0.14.0, Firmware oo-1.8.1)

- **Default Mode.** Manual mode is now the default out-of-the-box experience.
- **Hardcoded VAD.** In manual mode, VAD and filter values are now hardcoded to ensure predictable recording capture; only the maximum length cap remains tunable.
- **Session-End Markers.** Stopping a manual recording now emits a dedicated `0xFFFFFFFC` session-end marker to explicitly finalize the recording stream.
- **Colored Flashes.** The device LED now flashes Green when manually starting a recording, and Red when stopping.

### Diagnostics & Data Management (0.13.3 – 0.14.1, Firmware oo-1.7.11)

- **SD Drop Diagnostics.** Implemented a new diagnostic characteristic (`0x19B10062`) to count `storage_block_drops` on the firmware. Drop stats are now read and rendered on the app's Debug Tools page.
- **Robust Bin Cleanup.** Added guards to prevent re-VAD'ing leftover segments, reconcile bin file sizes with WAL offsets on sync resume, and wipe orphan-session raw bins during a "Delete Day" operation.

### Marker Creation Pipeline (0.13.2)

- **Inline Source.** Markers (20-byte frames) are now stored directly within the raw `.bin` stream. This replaces the legacy `markers.txt` intermediate sidecar, ensuring that events are physically tied to the audio frames they accompany.
- **On-the-fly Parsing.** The VAD processor now parses these inline markers during the decoding pass. This architectural shift ensures perfect synchronization between the audio stream and button-tap events.
- **Robust EDL Sidecars.** The JSON-based **Edit Decision List (EDL)** system has been hardened with atomic writes, reliable deduping (no more `_1.edl` duplicates), and support for "orphan" markers (taps during silence).
- **Timeline Recalibration.** Markers arriving mid-recording now recalibrate the anchor timestamp if the initial anchor was an estimate (derived from file mtime), fixing "second-order" drift in long recordings.

### Silero VAD v6 upgrade (0.13.0)

- Bumped the bundled `silero_vad.onnx` from v3 to v6.2.1 (~16% fewer errors on noisy real-life data per Silero's release notes).
- v6 collapses the separate LSTM `h` / `c` states into one 256-float recurrent `state` tensor, requires a 64-sample context window prepended to each 512-sample input, and a true 0-D scalar `sr`. The processor handles all of this internally.
- Same `vadSpeechThreshold` default (0.5) but v6 is more conservative — fewer false positives. Lower the threshold to 0.3–0.4 if quiet speech is missed.

### Android 16 / 16 KB page support (0.13.0)

- Swapped `onnxruntime: ^1.4.0` for `flutter_onnxruntime: ^1.7.1`, which bundles ORT 1.22.0 with 16 KB page-aligned `.so` files. Required for Android 16 devices booted with 16 KB pages and for Play Store submissions targeting SDK 36+ (enforced since Nov 2025).
- `targetSdkVersion` 35 → 36, iOS minimum 15 → 16 (`Podfile`, `Runner.xcodeproj`).
- ONNX inference is now async at the API layer — no longer FFI-blocks the platform thread, reducing the chance of `ForegroundServiceDidNotStartInTimeException` during cold session creation.
- The VAD model is pre-copied from `rootBundle` to `getApplicationSupportDirectory()` on the main isolate, then loaded in the processing isolate via `OnnxRuntime().createSession(path)` (the `createSessionFromAsset` API isn't usable from a background isolate).

### Edge-to-edge UI (0.12.0)

- Removed the edge-to-edge opt-out from default and night styles across all SDK 31+ resource folders.
- Wrapped the marker and recording player bodies in `SafeArea` so content respects system bars.
- Enabled `OnBackInvokedCallback` in the manifest (Android 14+ predictive back gesture).

### Perf, fixes & cleanup (0.12.0)

- `deleteDay`: replaced a serial EDL-deletion loop with O(M) concurrent deletion.
- Recordings list: dedup discards by id in `getDiscardsForDate`; show seconds for sub-minute ghost durations.
- Removed 46 unused dependencies and a SF Pro font block from `pubspec.yaml`.
- Deleted dead Android handlers (`WifiNetworkPlugin`, `NotificationOnKillService`), unused manifest entries, dead image / font / gif assets, and a sweep of unused imports across services, tests, and Flutter pages.

### Discard recovery & ghost rows (0.11.1 – 0.11.2)

- **Ghost rows.** Stretches of audio that VAD dropped are recorded to `recordings/<date>/discards.jsonl` and shown as greyed-out rows in the recordings list, labelled "silenced by VAD" (noise) or "too short". Ghosts route through visible/hidden tabs by duration, with the threshold tied to `filterMinDurationSeconds`.
- **Two-button recovery sheet.** Tapping a ghost opens a sheet with **Recover** (re-process the source bins, bypassing VAD) and **Delete**. Source bins are protected from cleanup for a 48 h window so recovery stays possible.
- **Cascading deletes.** `deleteDay` reaps discard records and their protected bins alongside finalized recordings.

### Background sync hardening (firmware oo-1.7.9)

- Robust background sync/processing: guard against overlapping background syncs, always refresh storage stats at end of sync, defer `CMD_READ_FILE` to the storage thread, and correct BLE connection refcounting on connect-fail/shutdown.

### Omi Cloud integration rewrite (0.11.0)

Reverted to the full OAuth + PCM16 upload path (preserved from commit `21880ab`), then carried forward the following fixes on top:

- **Upload filename fix.** On-disk recording names use millisecond timestamps; the Omi server expects epoch seconds. Filenames are now converted at upload time (`recording_fs320_<ms>.bin` → `recording_fs320_<s>.bin`).
- **Auto-enable on first login.** Toggling the Enabled switch on happens automatically when credentials first validate (webview login or manual token entry). Re-opening the settings page or the periodic token refresh does not override a manual disable.
- **Cancel pending uploads on disable.** Toggling Omi or HeyPocket off clears the in-flight upload queue; any upload already in-flight drains naturally, then stops.
- **Failed upload state.** After 3 consecutive failures the upload icon changes to an orange `!` circle. Auto-sync stops retrying. Tapping the icon manually retries regardless of retry count, and clears the counter on success.
- **Automatic retry reset.** Retry counters for all integrations are cleared automatically when: a new Omi OAuth token is successfully refreshed, the user re-logs into Omi, or a new HeyPocket API key validates. Transient outages recover without user intervention.
