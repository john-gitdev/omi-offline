# Changelog

### Fix: OTA no longer wipes SD card or forces BLE re-pair (0.17.1)

- **Firmware OTA no longer wipes BLE bonding keys or app settings.** The MCUmgr DFU was configured with `eraseAppSettings=true`, which wiped the NVS settings partition before every update. This deleted BLE bonds (requiring a re-pair on iOS after every flash) and deleted the stored firmware version string — causing the firmware's own version-change SD wipe to fire on every boot post-OTA, even when reflashing the same version. Setting `eraseAppSettings=false` restores correct behaviour: bonds survive OTA, and the SD wipe only triggers when the firmware version actually changes.

### Charging LED respects stealth mode; DFU no longer drops connection (0.17.0 / fw oo-1.9.2)

- **Charging no longer permanently disables stealth mode.** Plugging in the charger still forces the LED on so you can see the charging indicator, but unplugging now restores whichever state the device was in before — stealth stays stealth, LED-on stays LED-on.
- **Firmware OTA update no longer disconnects mid-transfer.** The app was cancelling its keep-alive timer when starting a DFU, but the MCUmgr SMP protocol uses a different GATT service than the Omi storage characteristic — so the firmware's 30 s idle-disconnect timer was never being reset during the transfer. The keep-alive now continues running throughout DFU, preventing mid-flash disconnects.

### Waveform display now shows dynamic range (0.16.11)

- **Waveform bars now reflect subtle level changes instead of appearing as a solid rectangle.** Loud or steady recordings previously rendered as a flat block because amplitudes were mapped linearly. Waveform values are now converted to dBFS with a −40 dB floor so quiet passages and level variations are perceptually visible in both the recording player and the marker player.

### Fix: discarded audio no longer reprocessed every sync (0.16.10)

- **Audio that VAD already discarded as noise is no longer re-decoded on every sync.** A date-key mismatch (raw-segment batches are keyed by epoch seconds misread as milliseconds, so they land in a 1970 bucket, while discard records are filed under the real date) left the reprocess-skip filter empty — so previously-discarded audio re-ran the full VAD pass each cycle, wasting battery and inflating the "~N min of audio to process" banner with audio that never produces a recording. The skip filter now reads the complete persisted discard set, and the banner estimate matches what will actually be processed. Adjustment Mode still keeps all bins for reprocessing, and Recover still brings a discarded day back.
- **Raw audio segments now group under their real date instead of January 1970.** The bin-filename timestamp (epoch seconds) was being read as milliseconds, so every segment was bucketed into 1970 and split from the same day's recordings in the batch list. Fixed at the source, so a day's raw segments, recordings, and discards share one batch — which also makes the reprocess-skip above correct by construction rather than by workaround.

### Faster VAD processing + tuned ONNX session (0.16.9)

- **Silero VAD now runs with tuned ONNX Runtime session options.** Both session-creation paths (foreground and the background processing isolate) now apply tuned threading and request the XNNPACK CPU execution provider when the device's ONNX build offers it, with automatic CPU fallback. Silero is a tiny recurrent model invoked ~112k times per recorded hour, so removing thread-pool overhead and using faster ARM CPU kernels speeds the decode/VAD pass with no change to VAD decisions.
- **Added opt-in VAD timing diagnostics.** With "Save Diagnostic Logs to File" enabled, the processor logs average per-inference timing (tensor create / inference run / result read) every ~64 s of audio, plus a one-time line recording which ONNX execution provider (XNNPACK vs CPU) and thread config the session actually used — together used to determine whether the platform-channel round-trip or the ONNX compute is the bottleneck. No effect when diagnostic logging is off.

### Faster recording save + WAV header fix (0.16.6)

- **Recording save is faster across all formats (WAV, M4A, OGG).** The WAV path no longer writes PCM to a temporary `.raw` file and copies it back to add the header — it counts samples up front, writes the header first, and streams PCM straight to the final file, eliminating ~2× the file size in disk I/O on long recordings. Silence-gap waveform computation is now O(buckets) instead of O(samples) (a 2-minute gap dropped from ~1.9M loop iterations to constant time), and redundant event-loop yields were removed from all three save paths.
- **Fixed a WAV corruption case when audio frames are dropped.** When a recording contains unreadable or undecodable frames, the single-pass WAV header is now patched with the true byte count after writing, so the `data`/RIFF sizes always match the file — preventing a noise tail, wrong duration, or "corrupt file" errors that could otherwise occur.

### Foreground notification fully silent (0.16.6)

- **The foreground notification no longer makes any sound or vibration.** The channel now explicitly sets `setSound(null, null)` and `enableVibration(false)`, and each notification is built with `.setSilent(true)` and `.setOnlyAlertOnce(true)` — covering cases where Android serves a cached channel config from a prior install.

### LED off by default after boot (fw oo-1.9.1)

- **LED now defaults to off after the boot sequence completes.** The initialization flash (white breathe → solid white → fade to off) still plays on every boot so you can confirm the device started correctly. After the fade, the LED stays dark. Triple-tap to toggle it on; triple-tap again to return to stealth.

### SD Write Drops status subtext during sync (0.16.5)

- **SD Write Drops panel now shows "Waiting for sync to complete…" instead of "Reading drop counters…" when a file transfer is in progress.** The drop-counter poll is intentionally skipped during active storage operations to avoid GATT conflicts, but the UI previously showed the generic loading text regardless — making it look like a slow read rather than a deliberate wait.

### Native storage keep-alive — fix 30s idle disconnect during file reads (0.16.4)

- **File transfers no longer time out with "Stream closed without EOT" on large files.** The firmware disconnects after 30 s of receiving no write command ("idle disconnect"). The Dart-layer keep-alive was skipped whenever a storage operation was in flight (`isStorageBusy`) — so any file read longer than 30 s would hit the firmware's idle timer mid-transfer. The fix moves the keep-alive to the native Android service: `OmiBleManager.startStorageKeepAlive()` sends `0x32` with `WRITE_TYPE_NO_RESPONSE` every 15 s, bypassing the GATT command queue entirely so it never stalls an in-flight read. The Dart keep-alive is unchanged (still serves as a liveness probe when storage is not busy).

### BLE bonding and notification fixes (0.16.3)

- **Opening Debug Tools no longer triggers a Bluetooth pairing dialog or disconnects the device.** The `ensureConnection` default was `requiresBond: true`, so every routine GATT call (drop-counter poll, device info read, battery, VAD threshold) would mark the managed device as needing a bond. On the next reconnect `requestBond()` fired, Android showed a system pairing UI, the firmware rejected it with no passcode, and the connection dropped. Default changed to `requiresBond: false`; no existing caller requested bonding explicitly so the fix is global.
- **Foreground notification no longer makes sound on every sync status update.** The Android notification channel was configured with `priority: HIGH` (audible on pre-Android-8) and `onlyAlertOnce: false`, causing a sound every time the notification text was updated during a sync or processing run. Priority lowered to `LOW` and `onlyAlertOnce: true` added so the alert fires only when the notification first appears.

### BLE stability and notification fixes (0.16.2)

- **SD Write Drops polling no longer disconnects the device during file transfer.** The 2-second drop-counter poll (`19b10062`) was issuing a GATT characteristic read concurrently with the notification stream from an active file download. On Android this causes GATT Error 133 and a connection drop mid-sync. The poll now skips when the storage lock is held (`conn.isStorageBusy`), so the read only fires in the window between transfers.
- **The foreground notification now updates immediately when the device connects.** Previously the Android `OmiBleForegroundService` wrote "Connecting…" once at `onCreate` and never updated it, so the notification stayed stuck at "Connecting…" even after the device was shown as connected in the app UI. The native service now flips to "Connected" when `fireDeviceReady` is called (unless a Dart-owned sync/processing notification is active), and back to "Connecting…" when a reconnect attempt begins — both changes are gated on Dart not having claimed the notification.
- **WAL save log spam removed.** "Successfully saved X WALs to file" was emitted on every throttled persist tick (~once per second during sync), flooding the log. Removed; the surrounding `getMissingWals` and `deleting synced WAL` lines are sufficient.

### Ghost bin sheet and debug UI polish (0.16.1)

- **Ghost bin sheet no longer shows a raw "Reason" debug line.** The `Reason: … (voice_prob max …)` subtext has been removed — the description and expiry line are sufficient context for deciding whether to recover.
- **"Recover (listen to decide)" renamed to "Recover to Recording"** for clarity.
- **"Reset to zero" button in the SD Write Drops panel now spans the full width** and its style (border radius, padding, font weight) matches the other action buttons in the debug tools page.

### Ghost entry labels and AAD noise-discard fixes (0.16.0)

- **"Silenced by VAD" no longer appears when hardware AAD is in use.** The speech-minimum check (`tooShortSpeech`) was not gated on the Silero session being active, so recordings could be marked as noise even when the app had no speech detector running and was relying entirely on the firmware's AAD. The check is now skipped when `_session == null`.
- **Speech frame count is now accurate in AAD mode.** When Silero is disabled, every Opus frame is speech by definition — but the processor was only setting `isSpeech = true` on frames that happened to complete a 512-sample VAD window (~12.5% of frames), severely undercounting `speechMs`. The frame loop now initialises `isSpeech = true` in AAD mode and skips the PCM buffer accumulation entirely.
- **Trailing-silence ghost entries are no longer shown.** `silence_trimmed` records (the quiet runout trimmed off the end of a saved recording) appeared as separate ghost entries even though the speech portion was already kept. They are now filtered at load time; the records remain on disk for bin-recovery tracking.
- **Ghost entry labels are clearer.** "Silenced by VAD" → **"below minimum speech"** (Silero detected less speech than the *Minimum Speech Required* setting); "too short" is now split into **"no speech detected"** (entire buffer was silence) and **"below minimum length"** (recording shorter than the *Short Recordings* filter).

### Sync banner and transfer speed fixes (0.15.10)

- **The sync banner no longer shows a stale segment count at startup.** The count was read from WALs persisted on disk from the previous session before the device was queried, so the banner would flash the wrong number (e.g. "4 segments") immediately on sync start. The count is now left at zero until `getMissingWals` completes and the first real progress callback arrives from the device — the banner shows "Scanning device…" in the interim.
- **File transfers are no longer stalled by keep-alive timeouts.** The foreground keep-alive writes `0x32` to the same BLE characteristic used for storage streaming. During an active transfer the firmware is busy sending data and cannot service the write, causing a 10-second `TimeoutException` per keep-alive tick. The keep-alive is now skipped whenever a storage operation holds the lock — an active data stream already proves the link is alive — eliminating multi-second stalls mid-download.

### Marker pipeline: synthetic test harness

- **The marker pipeline now has a CI-enforced test harness.** Twenty-one tests cover the fifteen interacting fixes that were previously verified only by reading the code. Six tests exercise `VadAudioProcessor` directly against synthetic `.bin` payloads: mid-recording and start-of-recording tap offset, bad-UTC fallback to audio wall time, the >60 s drift guard, orphan EDL emission when no audio surrounds a tap, and session-end finalisation with trailing-frame suppression. Fifteen tests exercise `RecordingsManager` via new `@visibleForTesting` wrappers: `_writeMarkerEdl` collision policy (user-saved preservation, default-crop in-place overwrite, corrupt overwrite, noop); `_reanchorMarkerEdls` (default-crop reset, user-saved shift and clamp, cross-folder reanchor, non-matching noop); and `getMarkerConversations` dedup (same-segment dedup, userSaved canonicalization, non-pending-over-pending, legacy `_1.edl` discovery).
- **`getMarkerConversations` now resolves filenames correctly on Windows.** The scanner used `e.path.split('/')` to extract the last path component from directory listings, which silently returned the full path on Windows (where `dart:io` joins child entries with `\`). Both usages replaced with `e.uri.pathSegments.last`, which normalises to forward slashes on all platforms.

### Processing robustness and notification cleanups (0.15.9)

- **A decoded audio frame larger than the VAD window can no longer overrun the sample buffer.** The fixed-size PCM buffer was filled with a whole decoded frame before any 512-sample windows were drained, so a frame bigger than the buffer's headroom would have thrown a range error mid-decode. Windows are now drained the instant one is complete, bounding the buffer at a single window regardless of decoded frame size.
- **Processing checkpoints are written far less often on long sessions.** The checkpoint serializes the entire in-flight conversation, whose frame list is uncapped by default, so writing it after every ~5-minute segment could rival the decode time itself. Writes are now throttled to once every few seconds — except a write is always forced (and the segment-file deletion held back) right before any source file is deleted, so a resumed run can never reference a file already removed from disk.
- **The background processing-progress notification can no longer fire its update twice per tick.** A duplicate listener registration is now prevented.
- **The "Stopping…" subtext is now driven by the controller's own state** rather than a live snapshot read during widget build, so it stays accurate as the cancel drains.
- **The in-app sync card no longer flashes "< 1 min" for a large backlog.** It now shows "Calculating…" until the audio total is measured, matching the notification.
- **The accumulated-audio banner no longer hides bins that are still waiting to be decoded.** It excluded every bin sharing a session id with any already-finalized recording — but a single firmware session routinely finalizes one recording while a later conversation is still an open draft with its source bins kept on disk. Those kept bins were hidden, so the banner showed "Conversation in progress" while real, decodable audio sat on disk. The banner now counts exactly what processing will decode (all bins except VAD-discarded ones), so it correctly shows "~N minutes to process · N bins".

### Notification pipeline fixes (0.15.8)

- **The notification no longer flickers between percentage and time-remaining formats during processing.** When a background sync ran while the app was open, both `DeviceProvider` and `RecordingsController` were writing to the same notification on every progress tick — one in "47% complete" format, the other in "~686 min remaining" format. `DeviceProvider` now stays silent while the app is in the foreground and `RecordingsController` owns the notification.
- **The notification no longer briefly shows "< 1 min" before snapping to the true duration.** When the controller initialised mid-processing, it set state to `processing` before the async file-size calculation completed, hitting the `else` branch and showing "< 1 min". Now shows "Calculating…" until the byte-count is known.
- **The notification stays live if you background the app during a foreground-triggered processing run.** Previously, if the user started a sync from the recordings page and then backgrounded the app, the notification froze once `RecordingsController` was disposed. `DeviceProvider` now registers its processing-progress listener in `onAppPaused` and unregisters it in `onAppResumed` to cover this gap.
- **The segment count in the notification now updates upward if the device reports more files than the initial estimate.** The backfill guard (`_totalCount <= 0`) prevented the count from updating once any estimate was set, so the notification could show "4 of 4 segments" when the device actually had 6. The guard now updates whenever the service reports a higher count.
- **Cancelling a sync now shows accurate subtext.** While a BLE file transfer is still in flight after a cancel (to avoid corruption), the card showed the hardcoded "Finishing current step". Now shows "Transferring current file…" while the transfer is draining and flips to "Finishing current step" once it's done.

### Processing resumes from where it left off instead of restarting (0.15.7)

- **Interrupted processing now picks up from the last completed segment instead of re-decoding everything from scratch.** After each segment finishes, the app writes a small checkpoint file (`vad_checkpoint.json`) containing the full VAD processor state — Silero LSTM weights, context buffer, PCM tail, conversation frame list, and all counters. When processing resumes (after a background kill, BLE disconnect, or manual cancel), the isolate restores this snapshot and skips all segments already processed. The Silero model continues with the exact recurrent state it had when the run was interrupted, so conversation boundaries and silence detection behave identically to an uninterrupted run. Any bin files that were ready for deletion in the prior run but weren't cleaned up are re-sent on resume. The checkpoint is automatically deleted on clean completion and preserved on cancel.

### VAD processing: faster inference and cleaner conversation boundaries (0.15.6)

- **Processing a backlog is now significantly faster.** The Silero VAD model's 256-float LSTM state used to make a full round-trip through Dart memory on every inference cycle (~31 cycles per second of audio): native → Dart list → native again. The state is now kept as a live native tensor and swapped in-place between calls, removing that copy entirely. The per-call allocations dropped from ~6 objects to ~1 (only the transient input tensor), and the sample accumulation buffer was replaced with a fixed typed-data ring buffer so window management no longer triggers GC.
- **The last 1–2 frames of each conversation are now correctly VAD-scored before the boundary is committed.** Each Opus frame decodes to 320 samples; the VAD window is 512. At any split or flush point, 0–511 samples were stranded in the accumulator, added to the recording's frame list as silence (the default), but never actually evaluated. Those tail frames are now zero-padded to 512 and passed through Silero before the boundary fires — so the speech high-water mark used to trim trailing silence lands at the right frame instead of potentially one or two frames early.
- **A new conversation no longer inherits the previous conversation's Silero LSTM state.** The recurrent state and context buffer are now cleared at every conversation boundary — including the two inline-reset paths (`0xFFFFFFFD` gap-split and max-cap cut) that were previously skipping the reset entirely.

### Sync reliability: Manual-Only respected on resume; interrupted syncs resume on reconnect (0.15.5)

- **With auto-sync off (Manual Only), the app no longer triggers a sync when you resume to a still-live connection.** If the app came to the foreground while the Omi was still connected with pending segments — e.g. a quick screen-on-off bounce before the pause-disconnect timer fired — it would silently trigger a background sync regardless of the sync-interval setting. Every other auto-sync path already checked the setting; this "drain the pending connection" shortcut was the one gap.
- **A sync interrupted by a mid-transfer BLE drop now resumes as soon as the device reconnects, instead of waiting for the next scheduled tick.** When BLE dropped during an active sync while the app was backgrounded, the Omi's firmware kept trying to reconnect (as expected). The app, however, was immediately dropping those reconnections because the "sanctioned background sync" flag is only set by the periodic timer path — not by user-initiated or app-open syncs that moved to the background. The remaining files are now fetched and processed as soon as the link comes back.

### Cross-midnight marker cleanup (0.15.4)

- **A button-tap marker made just before midnight no longer leaves a stale orphan file on disk.** If the user tapped near midnight and there was silence at that moment, the app wrote a temporary "orphan" marker entry in that day's folder. When audio from the next day later arrived and paired with the tap, a second marker entry was correctly written into the new day's folder, but the original orphan was never removed. The stale orphan was harmless to display (a dedup pass already suppressed it), but it emitted an error-level log on every load and left a dead file accumulating on disk. The orphan is now deleted as soon as the paired entry is written.

### Cancelling processing no longer crashes the app (0.15.3)

- **Pressing Cancel during the processing phase used to occasionally take the whole app down with it.** The decode isolate only checked for a cancel between segments, and a single segment can take more than 12 s of VAD/ONNX work — so a cancel mid-segment never landed in time and the stall watchdog had to fall back to force-killing the isolate. That kill, while the isolate was parked in a native ONNX or Opus call, corrupted process-level native state and crashed the app outright. Cancel is now polled from inside the per-frame decode loop, so it takes effect within milliseconds even mid-segment; the watchdog's force-kill path is no longer reached on a normal cancel, and the rare last-resort kill now waits for in-flight native calls to finish first instead of yanking them mid-flight.

### Background processing and notification reliability (0.15.2)

- **A large recording backlog now drains in one pass instead of re-processing the same segments over and over.** Processing a big backlog could leave the notification stuck (e.g. "Processing 63% complete" for many minutes) while the app appeared to connect, sync, and disconnect repeatedly. Root cause: the foreground service was being torn down while a background decode was still running, which let Android suspend the process mid-decode; on wake, the processing-stall watchdog misread the elapsed time as a wedge and force-killed a perfectly healthy run, restarting the whole backlog. The foreground service is now held for the full duration of a processing run, the watchdog re-anchors across a suspension/wake gap instead of killing, and the decode/save loops now emit a liveness signal so a slow-but-progressing run (decoding a large segment or saving a multi-hour stitched recording) is no longer mistaken for a hang. A genuinely wedged decode is still caught and recovered as before.
- **The persistent notification stays on the live sync/processing text instead of briefly reverting to "Connecting…".** The native BLE service and the Dart foreground task share the same notification (id 2001, last-writer-wins). When the BLE service spun up or restarted mid-cycle — most visibly at the sync→processing handoff while the local models load — its mandatory startup notification hardcoded "Connecting…", clobbering the accurate "Processing recordings — …" text until the next progress tick overwrote it. Dart now mirrors its current notification title/text to shared storage, and the native service reuses that on startup (falling back to "Connecting…" only when no sync/processing is active), eliminating the flash.

### Sync no longer freezes on a half-dead BLE link (0.15.1)

- **A stalled sync now recovers into processing instead of getting stuck.** If the Omi's firmware wedged mid-transfer while the BLE link stayed nominally "connected" (the phone never saw a disconnect), the app could hang forever on the in-flight BLE command — leaving the notification frozen at "Syncing recordings — N% complete" with no progress and no way out short of reopening the app. Every native BLE read/write is now time-bounded (10 s), so a dead peer surfaces as a normal error: the sync unwinds, the segments already downloaded are decoded, and the notification advances to the processing details (and then the idle/next-sync state) — the expected disconnect-then-process behavior.
- **A wedged command no longer poisons the next connection (Android).** The native GATT command queue is now cleared on disconnect, so a command left stuck by a half-dead link can't block the first commands of the following connection.
- **Faster reconnect when the device is asleep.** The fast-path direct connect-by-MAC attempt now times out after 5 s instead of 10 s. When the Omi isn't advertising (e.g. after an app update kills the warm native reconnect state) that attempt can't succeed anyway, so the old 10 s was pure dead time before the fallback scan even started; 5 s still covers a cached fast reattach with margin.

### Back button keeps the app running; clearer Manual-Only notification (0.15.0)

- **Pressing Back on the recordings screen now minimizes the app instead of closing it.** Previously Back finished the activity, which tore down the BLE foreground service and made its persistent notification vanish — so background sync silently stopped. Back now pushes the app to the background (like Home) and the service keeps running. Swiping the app away from Recents still stops it as before.
- **With auto-sync off (Manual Only), the notification now shows the connection state** — "Omi is Connected", "Connecting...", or "Omi is Disconnected" — instead of the generic "Running in the background". When auto-sync is on, the notification still shows only the next-sync countdown (reflecting the transient connect/disconnect cycle there would just make it flicker).
- **The background heartbeat now ticks every minute instead of every five.** A due background sync is picked up sooner and the notification's countdown / connection-state text stays fresher.

### Interrupted sync no longer strands the segments it already downloaded (0.14.19)

- **If the Omi disconnects mid-sync, the app now automatically decodes the raw segments that already reached the phone** instead of erroring out and leaving them on disk until the next sync. This applies to both manual syncs and the background scheduled sync. (A disconnect *during* a transfer already did this; this also covers a disconnect before/between transfers, which previously just surfaced an error and skipped processing.)
- **Cancelling a sync now asks what you want to do** — *Process downloaded* (decode the segments already pulled to the phone) or *Stop everything* (leave them for the next sync). Previously Cancel always dropped straight back to idle, leaving the just-downloaded `.bin` files unprocessed. Cancelling during the processing phase still just stops.
- In every interruption case — auto-process on disconnect, a "Process downloaded" cancel, or an interrupted **Force Sync** — processing runs in draft mode, so the trailing (possibly partial) segment is flushed as a draft and its source bin is kept for resume rather than being prematurely finalized and its bin deleted. (Previously an interrupted Force Sync could finalize that partial segment and prune its source, corrupting resume on the next sync.) A clean Force Sync still finalizes drafts as before; a genuine failure with nothing downloaded still shows the error.
- **The processing banner no longer spins forever if decoding wedges.** A processing-stall watchdog now recovers the UI to idle when no progress is seen for 3 minutes (outside the final audio-conversion step, which legitimately pauses progress). Recovery force-kills the stuck decode worker so it actually stops — previously a wedged decode left the banner stuck with no way out, and even pressing Cancel couldn't fully clear it. Partial results already written are kept; remaining segments re-process on the next run.

### Diagnostic logs: blank-window fix & simpler one-file lifecycle (0.14.18)

- **The Debug Tools log window no longer shows "No logs yet." on a non-empty log.** A single malformed UTF-8 byte — e.g. from a torn write when the main and background isolates append concurrently — made the strict reader throw on the whole file, so the in-app window went blank even though the log had content and was still shareable. The reader now decodes leniently (bad bytes become `U+FFFD`) and skips only the affected line, and it tail-reads the file so the 2s refresh stays cheap as the log grows.
- **Diagnostic logging is now a single file with a clear on/off lifecycle.** Instead of rolling a new file per day, there's one `omi_debug_*.log` named for the day logging started. Turning the toggle **on** cleans up any old log files and opens a fresh one; turning it **off** deletes the file; **Clear Logs** deletes the file and starts a new one; **Share Logs** shares the current file. On overflow (20 MB) the most recent half is kept, so the log stays a sliding window of recent activity instead of being wiped wholesale.

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
