# Changelog

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
