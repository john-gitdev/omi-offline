# Ideas

## ACTIVE

## BLE stability: stuck notifications, partial syncs, Bluetooth wedge [large] [Active]

Findings from analysing the device logs of 2026-06-27 and a full code review of `OmiBleManager.kt` and `OmiBleForegroundService.kt`.

### 1. Notifications stuck on "Connecting…"

**Problem:** The foreground-service notification shows "Connecting…" and never transitions back to idle. This happens when the Dart engine is frozen by Doze (or killed) while a background sync connect attempt is in progress. The native `setSyncStatus` pushes the "Connecting…" text and arms a `CONNECT_SETTLE_MS` (160 s) exact alarm. If Dart never resolves the connect, the notification stays stuck until the 160 s alarm fires, which under Doze can be deferred to the OS's ~9 min throttle window.

**Fix ideas:**
1. **Reduce `CONNECT_SETTLE_MS`** to something closer to the Dart connect-settle watchdog (e.g. 90–120 s).
2. **Use `AlarmManager.setExactAndAllowWhileIdle`** so Doze doesn't batch it.
3. **Push a native-side notification update** immediately when the GATT callback fires, instead of relying on Dart.

### 2. Partial sync completions

**Problem:** Background syncs abort partway through because the Bluetooth connection drops mid-transfer, resulting in `gatt_status_8` (`GATT_CONN_TIMEOUT`). The peripheral stopped responding to LL keepalives, severing the link and causing "Stream closed without EOT".

**Fix ideas:**
1. **Increase firmware LE supervision timeout.** The repeated `gatt_status_8` suggests the Zephyr LE supervision timeout may be too short. Increasing it to 4–6 seconds (`CONFIG_BT_PERIPHERAL_PREF_TIMEOUT`) would tolerate brief RF interference. This is the single highest-impact fix.
2. **Request robust connection parameters from Android.** Consider switching from `CONNECTION_PRIORITY_HIGH` (11.25–15 ms) to `CONNECTION_PRIORITY_BALANCED` (30 ms) during transfer for better reliability.
3. **Resume-from-offset after reconnect.** Persist the last successfully written offset and resume instead of re-downloading the entire file.

### 3. Phone stops connecting to Omi (requires Bluetooth toggle)

**Problem:** Connection attempts fail with `gatt_status_8` and the Android BLE stack gets into a wedged state.

**Root causes (from code review):**
1. **Ghost-purge dummy GATT approach worsens the wedge:** Creating a dummy GATT client, immediately disconnecting, and closing it within the same looper pass (`purgeGhostGattForAddress`) can corrupt the Android Bluetooth daemon's internal connection refcounting, actually *causing* the ghost state on some OEMs.
2. **Missing `disconnect()` before `close()`:** In `OmiBleManager.kt`, existing GATT objects are closed without calling `disconnect()` first. If the radio still thinks it's connected, this orphans the connection.
3. **Rapid retry cycling:** A fixed `RECONNECT_DELAY_MS` of 1,500ms with no exponential backoff causes rapid GATT client churn, the #1 trigger for stack wedges.

**Fix ideas:**
1. **Replace dummy-GATT ghost purge** with either programmatic adapter toggling (if permitted) or add a delay between connect and disconnect on the dummy GATT.
2. **Add `disconnect()` before `close()`** in all cleanup paths, especially `connectGatt` and `STATE_TURNING_OFF`.
3. **Add exponential backoff to retry logic** (1.5 s → 3 s → 6 s → 12 s → 30 s).

---

## PENDING

## Clean session-end marker when entering Manual Mode [medium] [Pending]

When the user toggles Manual Mode *on* in the app settings, the device transitions its VAD threshold to `32769` (manual standby). Currently, because the previous threshold wasn't `65535` (manual recording), the firmware doesn't instantly inject a `session-end` marker. Instead, it relies on the VAD's natural 10-second silence timeout (`CONFIG_OMI_VAD_HOLD_MS`) to put the recording to sleep. 

### Why this should change
Switching modes is a hard context boundary. Any ongoing auto-mode conversation should be cleanly finalized with a `session-end` marker the moment the user switches to Manual Mode, rather than letting it bleed out over a 10-second silence timeout. 

### Implementation details
- **Firmware (`aad.c`):** Update `aad_set_threshold()` so that injecting a `session-end` marker (`0xFFFFFFFC`) isn't strictly gated by `leaving_manual_record` (`prev == 65535 && threshold != 65535`). If the threshold is dropping to `32769` (entering manual mode) from an active auto-recording state (e.g., `prev == 250` and `vad_is_recording == true`), it should also trigger `write_session_end_marker_to_storage()` and instantly put the VAD to sleep.


## Split manual recording Start/Stop from the Marker action [medium] [Pending]

Back when the device had limited button gestures, the `MARKER` action (`BUTTON_ACTION_MARKER`) was overloaded to act as a Start/Stop toggle when `in_manual == true`. Now that the device has a customizable multi-gesture button configuration (`_config` array supporting single/double/triple taps), this overload is actively harmful.

### Why this should change
1. **Regain Marker utility:** Because `MARKER` is overloaded, a user cannot drop a timestamp marker *during* an active manual recording. By splitting them, `MARKER` can go back to just dropping the `0xFFFFFFFE` marker packet and flashing white, regardless of what mode the device is in.
2. **Eliminate state confusion:** Toggles create "state confusion" (e.g., "Did I just start or stop it?"). With explicit Start/Stop actions, a user can map Double-Tap to Start and Triple-Tap to Stop. The gesture guarantees the intent, no LED checking required.
3. **Cleaner codebase:** The `if (in_manual)` branching inside the `MARKER` switch case in `button.c` can be removed, and the ternary UI label hack in `button_config_page.dart` can be deleted.

### Implementation details
1. **Firmware (`button.h`):** Expand `button_action_t` to include `BUTTON_ACTION_RECORD_TOGGLE = 4`, `BUTTON_ACTION_RECORD_START = 5`, `BUTTON_ACTION_RECORD_STOP = 6`.
2. **Firmware (`button.c`):** Remove the `in_manual` threshold logic from `BUTTON_ACTION_MARKER`. Add new `switch` cases for the new actions that call `aad_set_threshold(65535)` for start and `aad_set_threshold(32769)` for stop (and toggle between them based on current `aad_get_threshold()`).
3. **App (`button_config_page.dart`):** Expand the `_actions` list to include `'Toggle Recording'`, `'Start Recording'`, and `'Stop Recording'`. Remove the `_manualMode ? ... : ...` ternary logic for the Marker label.

## Device-side toggle for Manual/Auto Mode [medium] [Pending]

Add a new button action that allows users to toggle between Auto Recording and Manual Recording directly from the device, without needing to use the app.

### Why this is needed
Users may want to quickly switch between continuous auto-recording and on-demand manual capture while on the go. Currently, this requires opening the app. 

A key architectural strength already exists for this: the app prevents offline mode editing and treats the device's `vad_threshold` as the ultimate source of truth upon connection. Therefore, if the device toggles the mode locally, no "timestamp conflict resolution" is needed. The app will simply read the new state upon its next connection and update the UI accordingly.

### The Firmware Catch
Currently, the firmware only has one persisted threshold variable (`vad_threshold`). When the app switches the device into Manual Mode, it overwrites this variable with `32769`, effectively erasing the user's preferred Auto Mode threshold (e.g., `250`). If a device-side button tries to toggle *back* to Auto Mode, it doesn't know what threshold to fall back to.

### Implementation details
1. **Firmware (`settings.c`, `settings.h`):** Add a new persisted setting called `auto_vad_threshold` (e.g., defaulting to `250`). This ensures the device always remembers the user's preferred auto-sensitivity even while in manual standby.
2. **App BLE Communication:** Update the "Auto VAD Threshold" slider in the app so that it writes the value not just to the active threshold (if in auto mode), but also explicitly saves it to the firmware's new `auto_vad_threshold` backup slot.
3. **Firmware (`button.h`, `button.c`):** 
   - Add `BUTTON_ACTION_MODE_TOGGLE = 7` to the action enum.
   - When pressed: if `vad_threshold >= 32769` (currently in manual mode), switch the active threshold to the saved `auto_vad_threshold`. If `vad_threshold < 32769` (currently in auto mode), switch the active threshold to `32769`.
4. **App (`button_config_page.dart`):** Add `'Toggle Auto/Manual Mode'` to the `_actions` list so users can assign it to a tap gesture.

## Device-driven BLE wake (firmware + iOS) [large] [Pending]

Shift background-sync triggering from the *phone* (opportunistic iOS `BGTaskScheduler` / Android alarms) to the *device*: the Omi opens a connectable advertising **window** on its own RTC-driven schedule, and the phone ΓÇö holding a standing pending-connect ΓÇö is woken by the OS the moment that window opens. This is the model commercial BLE wearables (e.g. CGMs) use for reliable background sync on iOS.

### The honest framing (why)
The primary win is **iOS wake *reliability* + device-controlled (punctual) timing**, **not** device battery. The firmware already advertises *slow* (~1 s, `adv_param_slow` in `transport.c`) when idle, which is already cheap; going fully "dark" saves only a bit more. The real reason: a standing pending-connect lets iOS wake the app on the *device's* schedule, replacing the opportunistic `BGTaskScheduler` path (which iOS fires unpredictably and never punctually). The same mechanism *forces* the firmware change ΓÇö a standing pending-connect pointed at a device that advertises connectably **continuously** (today's behavior) would reconnect ΓåÆ idle-drop ΓåÆ reconnect forever (churn). So the device must advertise connectably only in **windows it controls**. **Net: mostly an iOS project.** Android already wakes reliably (FGS + exact alarm + WorkManager) and needs little/no change.

### Second motivation: privacy / smaller attack surface (going dark)
For an *audio recorder*, the stealth of DARK is arguably as compelling as the iOS-wake win. Today the device advertises connectably 24/7 as "Omi" + service UUIDs, so it is:
- **Visible to any BLE scanner** ΓÇö and continuously broadcasting *"someone here is wearing a recording device."*
- **Trackable** ΓÇö a constant advertiser is a beacon a passive scanner can log and correlate across locations (AirTag-stalking vector).
- **Reachable** ΓÇö any device can occupy its single connection slot (lock-out / DoS) or probe its GATT table.

DARK shrinks exposure from "always visible + reachable" to "brief periodic windows + button press." Precise scope of what this protects: **reachability/visibility, not data confidentiality** ΓÇö the audio and encrypted characteristics are *already* bond/encryption-gated today, so DARK isn't adding data secrecy; it's removing the ability to *find, track, or connect to* the device, which is the basis of passive tracking and most targeted attacks.

**Inseparable coupling (same as the UX cost):** "others can't find/connect it while dark" is literally identical to "your own phone can't either, until a window or button." Your phone copes via the standing pending-connect catching scheduled windows (auto, no tap) + button for immediate connect; attackers only ever get the brief windows. You cannot have the stealth without the not-instantly-connectable.

**Cheap hardening that pairs with DARK:**
- **Resolvable Private Address (RPA).** If the firmware advertises a static/public BLE address, the device is still trackable *during* windows. A rotating RPA (bonded phone resolves it via the IRK; strangers can't) closes the window-time tracking gap. *Verify the current address type in firmware.*
- **Reject non-bonded connections fast** ΓÇö *low value, likely skip.* The payoff is marginal: every meaningful characteristic is already `*_ENCRYPT`-gated (`storage.c`, `transport.c`, button-config, mute, accel), so a non-bonded peer can read *nothing* ΓÇö confidentiality is already solved. The only real gain is connection-slot DoS, which is *already half-covered* by the 15 s idle-disconnect (`idle_disconnect_work_handler` drops an idle hogger in 15 s). Against that thin benefit it needs solid RPA resolution or it risks **false-rejecting your own iPhone** (rotating address). Net negative ΓÇö the encryption perms do the security work. (If maximum window-time stealth is ever wanted, *directed* advertising aimed only at the bonded central is the cleaner lever than connection-level rejection.)

So DARK now carries two stacked upsides ΓÇö **low-power + reliable iOS background wake**, *and* **a much smaller privacy/tracking/attack surface** ΓÇö against the one cost (not instantly connectable on app open).

### Current state
- **Firmware (`transport.c`, `aad.c`):** idle-disconnects after 15 s of no storage GATT activity (`idle_disconnect_work_handler`, `IDLE_DISCONNECT_TIMEOUT_MS`), then reverts to advertising. Two **always-connectable** modes: fast (`BT_LE_ADV_CONN`) and slow (`adv_param_slow`), via `transport_set_adv_fast/slow()`. **AAD currently owns advertising cadence** (recording ΓåÆ fast `aad.c:310`, silence ΓåÆ slow `aad.c:330`). Conn params 7.5ΓÇô22.5 ms, **latency 0** (`update_conn_params`); iOS recheck falls back to 15ΓÇô30 ms. Audio records to SD **independent of BLE** ΓÇö nothing lost while dark/disconnected.
- **iOS (`OmiBleManager.swift`, `device_provider.dart`):** state restoration *is* wired (`CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState` ΓåÆ `onStateRestored`), **but the aggressive disconnect neutralizes it**: `disconnectDevice(isManual:true)` (`device_provider.dart:884`, `:996`) ΓåÆ `disconnectPeripheral` adds to `manuallyDisconnected` + cancels the link, and `didDisconnectPeripheral` re-arms `connect()` *only if not manual*. Steady state = no pending connect = nothing for iOS to wake on.
- **Android (`OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`):** FGS (`FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`) + WorkManager periodic + `setExactAndAllowWhileIdle`; already uses `connectGatt(autoConnect=true)` as a pending-connect fallback. Reliable today.

### Target architecture
A device-side **sync-window state machine** replaces AAD's ownership of advertising:

```
        ΓöîΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ DARK ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ        no phone connects
        Γöé non-connectable / adv stopped ΓöéΓùäΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ within window ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ
        Γöé radio mostly off; SD recording Γöé                            Γöé
        ΓööΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö¼ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÿ                            Γöé
   cooldown elapsed AND Γöé (cooldown = sync interval, pushed by app)   Γöé
   has-unsynced data    Γû╝                                            Γöé
        ΓöîΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ SYNC WINDOW ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ    phone connects   ΓöîΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö┤ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÉ
        Γöé fast CONNECTABLE adv, Γëñ W sec ΓöéΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓû║  Γöé   CONNECTED     Γöé
        ΓööΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÿ                    Γöé sync; existing  Γöé
                                                             Γöé 15 s idle-drop  Γöé
                                                             ΓööΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓö¼ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÿ
                                                                      Γöé disconnect ΓåÆ DARK (restart cooldown)
```

Phone side: a **standing pending-connect is always armed** (iOS `connect()` + restoration; Android `autoConnect=true`). The device's cooldown = the sync cadence, punctual because the device's RTC drives it. **In `enabled=1` mode the app's own autosync timer goes dormant on *both* platforms** ΓÇö there's exactly one schedule, owned by the device, so there's nothing for an app timer and a device timer to drift out of. The app's job shrinks to: hold the standing connect, re-push config on each connect, and sync on any device-initiated wake.

### Firmware changes (the enabling work)
1. **Dark state** ΓÇö `transport_set_adv_dark()`: prefer **non-connectable** advertising (`BT_LE_ADV_NCONN`) so the device stays visible for diagnostics/UI but rejects CONNECT_IND (or fully `bt_le_adv_stop()` for lowest power). Track in `current_adv_mode`.
2. **Sync-window scheduler** (new `sync_window.c` or folded into `transport.c`, a `k_work_delayable`, driven by the **monotonic clock** so it's immune to time-sync state): DARK for `cooldown_ms` ΓåÆ open SYNC WINDOW (`transport_set_adv_fast()`). The window is a **connectability *ceiling*, not a broadcast duration** ΓÇö fast-advertise up to `window_ms` (**45ΓÇô60 s**; iOS background scan is duty-cycled and slow to notice adverts), but **stop advertising the moment a phone connects** (you only needed to be findable long enough to latch). Once connected, the existing `idle_disconnect_work` owns teardown, so a sync runs as long as data flows ΓÇö far past `window_ms`. On `_transport_disconnected`, **schedule the next window as `now + cooldown` on the monotonic clock**: because it resets off the *last disconnect*, a manual button-sync automatically pushes the next scheduled window out by a full interval ΓÇö the "manual sync moves the timer" behavior, free, no special handling. Window expiry with no connect ΓåÆ DARK, restart cooldown.
3. **Hand advertising ownership from AAD to the scheduler** ΓÇö keep AAD's VAD/SD-pause logic; remove/gate its `adv_*_req` writes (`aad.c:310,330,464`, applied in the AAD loop `aad.c:247-250`). Most invasive *refactor*; regression-test VAD recording, SD pause/resume, marker durability.
4. **Gate windows on "has unsynced data"** ΓÇö use "SD has stored files" as the proxy (app deletes via `CMD_DELETE_FILE`); SD empty ΓåÆ stay DARK until new audio is recorded.
5. **Config characteristic + user-facing "Dark Mode" toggle (default OFF)** ΓÇö new char under Settings service (`0010`, e.g. `0014`): `interval_minutes(u16) + window_seconds(u8) + enabled(u8)` (+ optional `next_override_seconds(u16)` for app-side policy nudges), persisted via `settings.c`, range-validated, with a **compiled-in default** (`config.h`) as the floor for a never-configured device. Surfaces in the app as a single **Dark Mode** switch (writes `enabled=1`). **Cadence reuses the existing "Auto Sync Interval" dropdown** (`app_settings_page.dart`: 15/30/60 min / Manual Only) ΓÇö no new cadence setting; the user's existing `backgroundSyncIntervalMinutes` drives the *device's* cooldown. **"Manual Only" (`-1`) maps to button-only wake** ΓÇö firmware opens *no* scheduled windows, only the button window. The app **re-pushes config on every connect** (belt-and-suspenders: the device never holds stale config; the dropdown is the source of truth). Firmware default is `enabled=0` = today's always-connectable behavior (old apps and Android untouched). `enabled=1` activates DARK/window cycling. See "Cross-platform: why this is opt-in" below.
6. **Capability bit** ΓÇö add `deviceDrivenSync` to the Features bitfield (`0021`, `OmiFeatures`) for mixed-version safety (new app + old fw ΓåÆ old timer path; old app + new fw ΓåÆ covered by #7).
7. **On-demand connectability + recovery floors (critical UX safeguard, see "Button-to-wake" below)** ΓÇö button/motion triggers open a window immediately. Plus two recovery behaviors so the device can't strand itself:
   - **Boot:** on reboot, **advertise connectably (like `enabled=0`) until the phone connects and writes config at least once, then resume the persisted dark schedule** ΓÇö re-anchoring `last_disconnect` to that fresh contact so there's no post-reboot blackout (the phone's standing pending-connect latches the moment the device advertises). **Cap the stay-open at ~15 min:** if the phone never shows (rebooted away from the phone), fall back to the persisted last-known config and resume dark scheduling so continuous advertising doesn't drain the 150 mAh cell.
   - **Liveness floor:** no successful sync for `> N` intervals ΓåÆ fall back to continuous connectable advertising so the device can't become permanently unreachable.
8. **(Alternative model) Held low-power connection** ΓÇö instead of windowing, set **slave latency > 0** in `update_conn_params` + a "data ready" notify characteristic (the CGM model). Lower wake latency, simpler app logic, but the radio stays in-connection (more device power than DARK). Default to windowed for the 150 mAh budget; keep this in reserve.

### Button-to-wake (user-selectable, integrates with existing button mapping)
The on-demand trigger (#7) is a natural fit for the **already-shipped customizable button-mapping system** (`button_config_service` in firmware, `button_config_page.dart` in app ΓÇö maps None/Mute/Marker/Toggle-LED to single/double/triple tap and their holds, synced over the encrypted value-validated button-config characteristic). Add a **new "Wake for Sync" action** to that action set:
- Firmware: on the mapped gesture, `button.c` kicks the sync-window scheduler straight to SYNC WINDOW (open a connectable window now), regardless of cooldown.
- App: expose "Wake for Sync" as a selectable action in `button_config_page.dart`; **default to single tap**, but user-customizable exactly like every other mapping (open to making it single tap out of the box or fully user-selectable ΓÇö both are supported by the existing infra).
- Firmware must range-accept the new action value (the config char already rejects out-of-range actions ΓÇö bump the accepted enum).
- UX: foreground "Sync now" prompts "tap your Omi to sync now" when the device is DARK between windows.

### Decoupling wake from sync (a connection is not a sync)
A device wake ΓÇö scheduled window *or* button combo ΓÇö only establishes a **connection**; the **app** then decides whether to pull data. Two clean concerns:
- **Device** = *make a connection possible*: open a window on its RTC cadence (config-char interval) + immediately on the button combo.
- **App** = *policy*: on each device-initiated connection, decide whether to sync.

The building block already exists: `_onStateRestored` runs `final due = _shouldSyncNow(); if (!due) return;` (`device_provider.dart:232`) ΓÇö "connection arrived, skip if not due." Generalize into a setting:
- **"Sync on every device wake"** ΓåÆ always pull whenever the device wakes/connects.
- **"Only when due"** ΓåÆ gate on the autosync interval (`_shouldSyncNow()`); an early wake connects, finds nothing due, and disconnects without transferring.

**Recommended semantics:** a *scheduled* window honors the setting (default "only when due"); a *button combo* is explicit user intent ΓåÆ **force-sync** (always pull), since the user tapped precisely to sync now. Make force the button's natural behavior; optionally expose the choice.

**Telling the two apart on connect.** The app can't receive the button event *before* it connects (the tap is what wakes it), so the reason can't arrive over Button char `0041` in time. Add a **"last wake reason" byte the app reads on connect** (scheduled / button / motion) ΓÇö a small new read char or folded into diagnostics `0061`; on `onDeviceReady` the app maps button ΓçÆ force-sync, scheduled ΓçÆ if-due. In `enabled=0`/always-connectable mode this is unneeded ΓÇö the device never goes dark, so a button tap arrives live over `0041` while connected and force-syncs directly.

**Battery note:** align the device's window cadence with the app's autosync interval (push via the config char) so early "connect-then-skip" cycles are rare; the if-due check mainly backstops button taps and edge timing ΓÇö a connect/disconnect with no transfer still costs a little device radio energy.

### iOS app changes (the real payoff)
1. **Standing pending-connect** ΓÇö after routine sync/disconnect, **re-arm `centralManager.connect(peripheral, options:nil)`** instead of leaving it cancelled, so iOS holds it pending and wakes the app at the device's next window. Add a `standingConnect: Set<String>` alongside `manuallyDisconnected`; distinguish "Forget Device" (truly cancel) from "routine post-sync disconnect" (cancel link, re-arm pending connect). **Also re-arm on app launch** ΓÇö a user force-quit drops the OS-held pending connect, so re-issuing `connect()` at startup (iOS: `retrievePeripherals(withIdentifiers:)` with the saved device ID; Android: `connectGatt(autoConnect=true)` with the saved address) restores the wait that force-quit destroyed. Note this only re-arms the wait ΓÇö it can't connect a *dark* device until its next window or a button tap; for an immediate post-relaunch sync the user taps the button (or the staleness banner, #5).
2. **Routine disconnect Γëá terminal in Dart** ΓÇö post-sync (`device_provider.dart:884`) and pause-grace (`:996`) map to a new "disconnect-but-stay-armed" path (`disconnectKeepingPendingConnect`), not `unmanageDevice`. Only true unpair calls full `unmanageDevice`/`disconnectPeripheral`.
3. **Wake ΓåÆ sync** ΓÇö mostly there: the wake arrives as `didConnect` ΓåÆ `onDeviceReady` ΓåÆ `_handleDeviceConnected`; ensure the background drop-guard lets a device-initiated wake through (set pending-sync flag, as `_onBackgroundSyncRequested` does). `_onStateRestored` (`device_provider.dart:232`) already sanctions a due sync.
4. **Demote BGTaskScheduler to backstop** ΓÇö keep the `BGProcessing`/`BGAppRefresh` tasks (shipped 0.25.4) as the fallback for when pending-connect misses (notably after **user force-quit** ΓÇö iOS won't relaunch for BLE then).
5. **Foreground UX + staleness banner** ΓÇö surface the button-to-wake affordance since the device may be DARK on app open. Add a **"haven't synced in a while ΓÇö tap your Omi to sync" banner** that triggers after **N missed windows** (`now ΓêÆ lastSuccessfulSync ΓëÑ N ├ù interval`, with a floor so short intervals don't nag; suppressed in Manual-Only mode). It's the safety net for the irreducible cases ΓÇö force-quit dropped the standing connect, or the device was out of range ΓÇö proactively pointing the user at the button to realign instead of silently accumulating stale data. Tapping it re-arms the standing connect and prompts the physical tap. Generally useful even on `enabled=0`.

### Cross-platform: why windowing is opt-in (and Android keeps the status quo)
It's **one device** ΓÇö the firmware can't be DARK for iOS yet always-connectable for Android at the same time; whichever phone is nearby sees the same advertising behavior. The two platforms want opposite things:
- **iOS** *gains* from DARK/window cycling (reliable background wake it otherwise lacks), and loses little on-demand connect (iOS has no good instant on-demand today anyway).
- **Android** *loses* from it: today the device is always connectable, so opening the app connects **instantly**, anytime. DARK between windows breaks that instant on-demand connect (you'd wait for the next window or tap Wake-for-Sync). Android is the platform with the *good* on-demand experience, so it has the most to lose ΓÇö and it doesn't need device-driven wake (FGS + exact alarm already wake it reliably).

Resolution: **windowing is the per-device `enabled` flag (#5 above), default OFF.** `enabled=0` = today's always-connectable behavior (instant on-demand connect, no tap, alarm-driven) ΓÇö **Android stays here ΓåÆ zero regression**. `enabled=1` = device-driven windows ΓÇö iOS opts in. Note: **scheduled** sync needs no tap on either mode (windows auto-connect via the pending-connect); only **immediate/on-demand** connect regresses under `enabled=1`, which is exactly what the Wake-for-Sync tap mitigates.

### Android changes (none required ΓÇö stays on `enabled=0`)
Android keeps today's path entirely: always-connectable firmware, FGS + WorkManager + exact alarm wake, instant on-demand connect, no tap. The firmware windowing is inert for Android because the app never sets `enabled=1`. (If an Android user *wanted* device-driven cycling, `autoConnect=true` (`OmiBleForegroundService.kt:470`) would catch the windows the same way iOS does ΓÇö but there's no reason to, so leave it off.) **Do not** re-introduce `CompanionDeviceManager` presence observation ΓÇö this fork removed it due to OnePlus/Oppo/Realme connection wedges (0.24 changelog). Keep the alarm as the safety net.

### Hard tradeoffs & risks
1. **On-demand connect regresses (only when `enabled=1`)** ΓÇö DARK between windows means no instant connect on app open; fully dependent on button/motion triggers + safety floor. Biggest UX risk ΓÇö but scoped to opted-in (iOS) devices; Android and opt-out users on `enabled=0` keep instant on-demand connect.
2. **iOS user force-quit kills background BLE wake** until next manual launch (iOS platform rule). BGTask backstop partially covers it; **re-arm-on-launch** restores the standing connect the moment the app reopens, and the **staleness banner** points the user at the button if data has piled up.
3. **iOS background-scan latency** ΓÇö window must be long + fast-advertising (ΓëÑ45ΓÇô60 s); too short ΓåÆ iOS misses it, too long ΓåÆ device power. Needs tuning + measurement.
4. **Mixed firmware/app versions** ΓÇö gate on the capability bit + safety floor so no combination bricks reachability.
5. **AAD refactor** touches a working, subtle thread ΓÇö regression-test VAD recording, SD pause/resume, marker durability.
6. **Must measure** ΓÇö put it on a Nordic PPK2: today's continuous-slow-adv vs DARK+window current draw, plus real-world iOS wake hit-rate (worn all day, app backgrounded). Don't ship on theory.

### Phasing
- **Phase 1 ΓÇö Firmware:** dark state + window scheduler + config char + capability bit + button/motion triggers (incl. the "Wake for Sync" button action) + safety floor. Validate on PPK2 + manual nRF connect. Ship behind the capability bit.
- **Phase 2 ΓÇö iOS:** standing pending-connect (1ΓÇô3), routine-disconnect-keeps-armed, wakeΓåÆsync, BGTask demoted to backstop. Measure background wake hit-rate vs. the BGTask-only baseline.
- **Phase 3 ΓÇö Android (optional):** only if measurement shows a worthwhile phone-battery saving from relaxing the alarm cadence.

Highest-leverage cheap validation: **Phase 1 window scheduler + Phase 2 standing pending-connect**, measured against current BGTask reliability ΓÇö tells you whether device-driven wake is worth the full build-out before committing.

### Relevant files
- `omi/firmware/omi/src/lib/core/transport.c` ΓÇö `idle_disconnect_work_handler` (15 s), `transport_set_adv_fast/slow` + `adv_param_slow`, `_transport_disconnected` (adv restart), `update_conn_params` (latency 0); add dark state + window scheduler.
- `omi/firmware/omi/src/aad.c` ΓÇö `adv_slow_req`/`adv_fast_req` writes (`:310,:330,:464`) and the apply loop (`:247-250`) to hand advertising ownership to the scheduler.
- `omi/firmware/omi/src/lib/core/settings.c` / `settings.h` ΓÇö persist the window config (mirror `app_settings_save_conn_fail`).
- `omi/firmware/omi/src/button.c` + button-config service (registered `transport.c:1810`) ΓÇö add the "Wake for Sync" action; kick the scheduler on the mapped gesture.
- `app/ios/Runner/OmiBleManager.swift` ΓÇö `manuallyDisconnected`/`disconnectPeripheral`/`didDisconnectPeripheral`/`willRestoreState`; add `standingConnect` + pending-connect re-arm.
- `app/ios/Runner/AppDelegate.swift` ΓÇö keep `BGProcessing`/`BGAppRefresh` as backstop.
- `app/lib/providers/device_provider.dart` ΓÇö `disconnectDevice(isManual:true)` sites (`:884`,`:996`), `_onStateRestored` (`:232`, already does the "skip if not due" gate to generalize), `_shouldSyncNow()`, `_onBackgroundSyncRequested` (`:208`); apply the wakeΓåÆpolicy decision (force vs if-due) on device-initiated connect.
- `app/lib/backend/preferences.dart` ΓÇö add the "sync on every device wake" vs "only when due" setting (alongside `backgroundSyncIntervalMinutes`).
- Firmware "last wake reason" ΓÇö expose a 1-byte read (scheduled/button/motion) via a new char or folded into diagnostics `0061` (`transport.c`), read by the app on `onDeviceReady` to pick force-sync vs if-due.
- `app/lib/services/devices/transports/native_ble_transport.dart` ΓÇö add `disconnectKeepingPendingConnect`; `app/lib/pigeon_interfaces.dart` for the new host API + the window-config write.
- `app/lib/pages/settings/button_config_page.dart` ΓÇö expose "Wake for Sync" as a selectable button action (default single tap).
- `app/lib/pages/settings/app_settings_page.dart` ΓÇö add the **Dark Mode** toggle (writes `enabled`); the existing "Auto Sync Interval" dropdown (15/30/60 / Manual Only, ~`:248`) already supplies the cadence ΓÇö Manual Only = button-only. The staleness banner lives wherever sync status surfaces (home/recordings).
- Android (phase 3, optional): `OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`.

---

## DEFERRED

## iOS code signing & non-jailbroken distribution [medium] [Deferred]

The iOS build works end-to-end via CI (`.github/workflows/ios-build.yml`) and produces an **unsigned** dev IPA that installs on a **jailbroken** device (AppSync Unified / TrollStore ΓÇö current path for the iPhone 6s Plus). To run on a **stock** (non-jailbroken) iPhone, the IPA must be code-signed, which needs an Apple Developer account plus signing material wired into CI.

### What it takes
- **Apple Developer Program ($99/yr)** ΓÇö required for a real signing certificate + provisioning profile. (A free Apple ID only does 7-day Xcode sideloading on a Mac, which headless CI can't drive.)
- **Signing secrets in GitHub Actions** ΓÇö distribution certificate (`.p12` + password) and a provisioning profile stored as encrypted repo secrets, imported into a temporary keychain on the runner (e.g. `apple-actions/import-codesign-certs`).
- **Build a signed IPA** ΓÇö replace the workflow's `flutter build ios --no-codesign` with `flutter build ipa` + an `ExportOptions.plist`: method `app-store` for TestFlight, or `ad-hoc` / `development` for direct install with the target device UDID registered in the profile.
- **Distribution**
  - **TestFlight** (cleanest ΓÇö no per-device UDID): upload via `xcrun altool`/`notarytool` or `apple-actions/upload-testflight-build`; install via the TestFlight app. No Mac needed locally.
  - **Ad-hoc**: register target device UDIDs in the profile; install the signed IPA directly (Apple Configurator / `ideviceinstaller`).

### Why deferred
The jailbroken-device path (unsigned IPA, already working) covers the current 6s Plus for free. Signing only matters when targeting a non-jailbroken iPhone, and it carries an annual fee + secret management. Revisit if/when a stock-iOS device becomes a target.

### Relevant files
- `.github/workflows/ios-build.yml` ΓÇö today: `flutter build ios --flavor dev --no-codesign` ΓåÆ zips `Payload/Runner.app` into an unsigned IPA. Signing adds a cert-import step, switches to `flutter build ipa`, and adds an upload/export step.
- Flavors (`app/flavorizr.yaml`): `dev` = `com.omi.offline.development`, `prod` = `com.omi.offline` ΓÇö the provisioning profile must be issued for whichever bundle id is shipped.
