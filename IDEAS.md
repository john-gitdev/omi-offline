# Ideas

## Table of Contents

### ACTIVE
- [1. BLE stability: partial syncs, stuck notifications [medium] [Active]](#1-ble-stability-partial-syncs-stuck-notifications-medium-active)
### PENDING
- [2. Device-driven BLE wake (firmware + iOS) [large] [Pending]](#2-device-driven-ble-wake-firmware-ios-large-pending)
- [4. Streaming WAV stitch — fix OOM on long-recording merge [small] [Pending]](#4-streaming-wav-stitch--fix-oom-on-long-recording-merge-small-pending)
- [5. Background reconnect recovery latency after native retry back-off [small] [Shipped — validate on device]](#5-background-reconnect-recovery-latency-after-native-retry-back-off-small-shipped--validate-on-device)
- [6. On-device diagnostic event log [medium] [Pending — spec ready]](#6-on-device-diagnostic-event-log-medium-pending--spec-ready)
### DEFERRED
- [3. iOS code signing & non-jailbroken distribution [medium] [Deferred]](#3-ios-code-signing-non-jailbroken-distribution-medium-deferred)

---


## ACTIVE

### 1. BLE stability: partial syncs, stuck notifications [medium] [Active]

Remaining BLE-reliability work from the 2026-06-27 device-log analysis plus a code
review of [OmiBleManager.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt)
and [OmiBleForegroundService.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt).
The GATT-churn fixes — exponential reconnect backoff and `disconnect()` before
`close()` across all cleanup paths — shipped in app 0.26.9, and most follow-ups
(resume-from-offset, the keepalive margin, and stuck-"Connecting…" recovery) have since
shipped too. **The one remaining open item is connection-param tuning** (below); the
already-handled items are noted in the callout below for context.

> **Already handled, so not listed below.** The firmware LE **supervision timeout is
> already 6 s** (`transport.c` `update_conn_params`, `.timeout = 600`) — the original
> "raise it to 4–6 s, highest-impact fix" was a no-op. The stranded-notification
> settle alarm **already uses `setExactAndAllowWhileIdle`** (`SyncAlarmReceiver.kt`).
> The dummy-GATT ghost-purge redesign was **rejected**: its only reliable variant
> (`adapter.disable()`/`enable()`) would also disconnect the user's *other* BLE devices.

#### Root cause
The drops are `gatt_status_8` (`GATT_CONN_TIMEOUT`): the LE link-supervision timer
(6 s) expired because the peripheral stopped sending LL keepalive PDUs, or the channel
was too degraded to receive them. With the supervision timeout already maxed, these
are genuine multi-second RF/firmware stalls — not a tuning problem — so the items
below mitigate the *fallout* (don't lose the partial transfer, don't strand the UI)
rather than preventing the stall.

#### Open: connection-param tuning during transfer
Syncs transfer over `CONNECTION_PRIORITY_HIGH` (`OmiBleManager.kt`, ~11.25–15 ms
interval) — great throughput, RF-fragile. The open experiment is whether
`CONNECTION_PRIORITY_BALANCED` (30 ms) during a transfer trades throughput for fewer drops:
- `BALANCED` ~halves throughput, but each interval is more RF-robust (fewer drops per unit
  time) — at the cost of a longer transfer (more total exposure). Net effect on "did the
  whole transfer finish" is empirical.
- **Kept at HIGH on purpose for now:** resume-from-offset (shipped, below) already makes a
  drop cheap, so HIGH + resume beats BALANCED unless measurement shows BALANCED's lower drop
  rate outweighs the throughput cost. Wire it behind something measurable and A/B
  throughput vs. drop-rate before committing. Android-only lever; the firmware's
  `update_conn_params` (7.5–22.5 ms) bounds the floor either way.

> **Guardrail (learned while shipping the stuck-notification fix):** don't reduce
> `CONNECT_SETTLE_MS` (160 s) below Dart's 150 s connect-settle watchdog — it sits just above
> it on purpose so native never preempts Dart's own handling. The recovery instead pulls the
> settle alarm in on *disconnect* (to `now + 60 s`, never later than the original deadline),
> which rescues a frozen-Dart strand without that risk.

#### Relevant files
| File | What it does |
|------|-------------|
| `OmiBleManager.kt` | `cleanupPeripheral`, `StorageDownloadSession` (`startOffset`), storage keepalive (`0x32`), `requestConnectionPriority` |
| `OmiBleForegroundService.kt` | `CONNECT_SETTLE_MS`, `setSyncStatus`, `settleStaleConnectingToIdle`, `handleDisconnection` |
| `SyncAlarmReceiver.kt` | Doze-exempt settle alarm |
| `transport.c` | `IDLE_DISCONNECT_TIMEOUT_MS` (15 s), `update_conn_params` (`.timeout = 600`) |

---

## PENDING

### 2. Device-driven BLE wake (firmware + iOS) [large] [Pending]

Shift background-sync triggering from the *phone* (opportunistic iOS `BGTaskScheduler` / Android alarms) to the *device*: the Omi opens a connectable advertising **window** on its own RTC-driven schedule, and the phone — holding a standing pending-connect — is woken by the OS the moment that window opens. This is the model commercial BLE wearables (e.g. CGMs) use for reliable background sync on iOS.

#### The honest framing (why)
The primary win is **iOS wake *reliability* + device-controlled (punctual) timing**, **not** device battery. The firmware already advertises *slow* (~1 s, `adv_param_slow` in `transport.c`) when idle, which is already cheap; going fully "dark" saves only a bit more. The real reason: a standing pending-connect lets iOS wake the app on the *device's* schedule, replacing the opportunistic `BGTaskScheduler` path (which iOS fires unpredictably and never punctually). The same mechanism *forces* the firmware change — a standing pending-connect pointed at a device that advertises connectably **continuously** (today's behavior) would reconnect → idle-drop → reconnect forever (churn). So the device must advertise connectably only in **windows it controls**. **Net: mostly an iOS project.** Android already wakes reliably (FGS + exact alarm + WorkManager) and needs little/no change.

#### Second motivation: privacy / smaller attack surface (going dark)
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

#### Current state
- **Firmware (`transport.c`, `aad.c`):** idle-disconnects after 15 s of no storage GATT activity (`idle_disconnect_work_handler`, `IDLE_DISCONNECT_TIMEOUT_MS`), then reverts to advertising. Two **always-connectable** modes: fast (`BT_LE_ADV_CONN`) and slow (`adv_param_slow`), via `transport_set_adv_fast/slow()`. **AAD currently owns advertising cadence** (recording → fast `aad.c:310`, silence → slow `aad.c:330`). Conn params 7.5–22.5 ms, **latency 0** (`update_conn_params`); iOS recheck falls back to 15–30 ms. Audio records to SD **independent of BLE** — nothing lost while dark/disconnected.
- **iOS (`OmiBleManager.swift`, `device_provider.dart`):** state restoration *is* wired (`CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState` → `onStateRestored`), **but the aggressive disconnect neutralizes it**: `disconnectDevice(isManual:true)` (`device_provider.dart:884`, `:996`) → `disconnectPeripheral` adds to `manuallyDisconnected` + cancels the link, and `didDisconnectPeripheral` re-arms `connect()` *only if not manual*. Steady state = no pending connect = nothing for iOS to wake on.
- **Android (`OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`):** FGS (`FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`) + WorkManager periodic + `setExactAndAllowWhileIdle`; already uses `connectGatt(autoConnect=true)` as a pending-connect fallback. Reliable today.

#### Target architecture
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

#### Firmware changes (the enabling work)
1. **Dark state** — `transport_set_adv_dark()`: prefer **non-connectable** advertising (`BT_LE_ADV_NCONN`) so the device stays visible for diagnostics/UI but rejects CONNECT_IND (or fully `bt_le_adv_stop()` for lowest power). Track in `current_adv_mode`.
2. **Sync-window scheduler** (new `sync_window.c` or folded into `transport.c`, a `k_work_delayable`, driven by the **monotonic clock** so it's immune to time-sync state): DARK for `cooldown_ms` → open SYNC WINDOW (`transport_set_adv_fast()`). The window is a **connectability *ceiling*, not a broadcast duration** — fast-advertise up to `window_ms` (**45–60 s**; iOS background scan is duty-cycled and slow to notice adverts), but **stop advertising the moment a phone connects** (you only needed to be findable long enough to latch). Once connected, the existing `idle_disconnect_work` owns teardown, so a sync runs as long as data flows — far past `window_ms`. On `_transport_disconnected`, **schedule the next window as `now + cooldown` on the monotonic clock**: because it resets off the *last disconnect*, a manual button-sync automatically pushes the next scheduled window out by a full interval — the "manual sync moves the timer" behavior, free, no special handling. Window expiry with no connect → DARK, restart cooldown.
3. **Hand advertising ownership from AAD to the scheduler** — keep AAD's VAD/SD-pause logic; remove/gate its `adv_*_req` writes (`aad.c:310,330,464`, applied in the AAD loop `aad.c:247-250`). Most invasive *refactor*; regression-test VAD recording, SD pause/resume, marker durability.
4. **Gate windows on "has unsynced data"** — use "SD has stored files" as the proxy (app deletes via `CMD_DELETE_FILE`); SD empty → stay DARK until new audio is recorded.
5. **Config characteristic + user-facing "Dark Mode" toggle (default OFF)** — new char under Settings service (`0010`, e.g. `0017` — `0014`/`0015`/`0016` are now taken by the priority-record cap + the consolidated button/haptic config): `interval_minutes(u16) + window_seconds(u8) + enabled(u8)` (+ optional `next_override_seconds(u16)` for app-side policy nudges), persisted via `settings.c`, range-validated, with a **compiled-in default** (`config.h`) as the floor for a never-configured device. Surfaces in the app as a single **Dark Mode** switch (writes `enabled=1`). **Cadence reuses the existing "Auto Sync Interval" dropdown** (`app_settings_page.dart`: 15/30/60 min / Manual Only) — no new cadence setting; the user's existing `backgroundSyncIntervalMinutes` drives the *device's* cooldown. **"Manual Only" (`-1`) maps to button-only wake** — firmware opens *no* scheduled windows, only the button window. The app **re-pushes config on every connect** (belt-and-suspenders: the device never holds stale config; the dropdown is the source of truth). Firmware default is `enabled=0` = today's always-connectable behavior (old apps and Android untouched). `enabled=1` activates DARK/window cycling. See "Cross-platform: why this is opt-in" below.
6. **Capability bit** — add `deviceDrivenSync` to the Features bitfield (`0021`, `OmiFeatures`) for mixed-version safety (new app + old fw → old timer path; old app + new fw → covered by #7).
7. **On-demand connectability + recovery floors (critical UX safeguard, see "Button-to-wake" below)** — button/motion triggers open a window immediately. Plus two recovery behaviors so the device can't strand itself:
   - **Boot:** on reboot, **advertise connectably (like `enabled=0`) until the phone connects and writes config at least once, then resume the persisted dark schedule** — re-anchoring `last_disconnect` to that fresh contact so there's no post-reboot blackout (the phone's standing pending-connect latches the moment the device advertises). **Cap the stay-open at ~15 min:** if the phone never shows (rebooted away from the phone), fall back to the persisted last-known config and resume dark scheduling so continuous advertising doesn't drain the 150 mAh cell.
   - **Liveness floor:** no successful sync for `> N` intervals → fall back to continuous connectable advertising so the device can't become permanently unreachable.
8. **(Alternative model) Held low-power connection** — instead of windowing, set **slave latency > 0** in `update_conn_params` + a "data ready" notify characteristic (the CGM model). Lower wake latency, simpler app logic, but the radio stays in-connection (more device power than DARK). Default to windowed for the 150 mAh budget; keep this in reserve.

#### Button-to-wake (user-selectable, integrates with existing button mapping)
The on-demand trigger (#7) is a natural fit for the **already-shipped customizable button-mapping system** (`button_config_service` in firmware, `button_config_page.dart` in app — maps None/Mute/Marker/Toggle-LED to single/double/triple tap and their holds, synced over the encrypted value-validated button-config characteristic). Add a **new "Wake for Sync" action** to that action set:
- Firmware: on the mapped gesture, `button.c` kicks the sync-window scheduler straight to SYNC WINDOW (open a connectable window now), regardless of cooldown.
- App: expose "Wake for Sync" as a selectable action in `button_config_page.dart`; **default to single tap**, but user-customizable exactly like every other mapping (open to making it single tap out of the box or fully user-selectable — both are supported by the existing infra).
- Firmware must range-accept the new action value (the config char already rejects out-of-range actions — bump the accepted enum).
- UX: foreground "Sync now" prompts "tap your Omi to sync now" when the device is DARK between windows.

#### Decoupling wake from sync (a connection is not a sync)
A device wake — scheduled window *or* button combo — only establishes a **connection**; the **app** then decides whether to pull data. Two clean concerns:
- **Device** = *make a connection possible*: open a window on its RTC cadence (config-char interval) + immediately on the button combo.
- **App** = *policy*: on each device-initiated connection, decide whether to sync.

The building block already exists: `_onStateRestored` runs `final due = _shouldSyncNow(); if (!due) return;` (`device_provider.dart:232`) — "connection arrived, skip if not due." Generalize into a setting:
- **"Sync on every device wake"** → always pull whenever the device wakes/connects.
- **"Only when due"** → gate on the autosync interval (`_shouldSyncNow()`); an early wake connects, finds nothing due, and disconnects without transferring.

**Recommended semantics:** a *scheduled* window honors the setting (default "only when due"); a *button combo* is explicit user intent → **force-sync** (always pull), since the user tapped precisely to sync now. Make force the button's natural behavior; optionally expose the choice.

**Telling the two apart on connect.** The app can't receive the button event *before* it connects (the tap is what wakes it), so the reason can't arrive over Button char `0041` in time. Add a **"last wake reason" byte the app reads on connect** (scheduled / button / motion) — a small new read char or folded into diagnostics `0061`; on `onDeviceReady` the app maps button ⇒ force-sync, scheduled ⇒ if-due. In `enabled=0`/always-connectable mode this is unneeded — the device never goes dark, so a button tap arrives live over `0041` while connected and force-syncs directly.

**Battery note:** align the device's window cadence with the app's autosync interval (push via the config char) so early "connect-then-skip" cycles are rare; the if-due check mainly backstops button taps and edge timing — a connect/disconnect with no transfer still costs a little device radio energy.

#### iOS app changes (the real payoff)
1. **Standing pending-connect** — after routine sync/disconnect, **re-arm `centralManager.connect(peripheral, options:nil)`** instead of leaving it cancelled, so iOS holds it pending and wakes the app at the device's next window. Add a `standingConnect: Set<String>` alongside `manuallyDisconnected`; distinguish "Forget Device" (truly cancel) from "routine post-sync disconnect" (cancel link, re-arm pending connect). **Also re-arm on app launch** — a user force-quit drops the OS-held pending connect, so re-issuing `connect()` at startup (iOS: `retrievePeripherals(withIdentifiers:)` with the saved device ID; Android: `connectGatt(autoConnect=true)` with the saved address) restores the wait that force-quit destroyed. Note this only re-arms the wait — it can't connect a *dark* device until its next window or a button tap; for an immediate post-relaunch sync the user taps the button (or the staleness banner, #5).
2. **Routine disconnect ≠ terminal in Dart** — post-sync (`device_provider.dart:884`) and pause-grace (`:996`) map to a new "disconnect-but-stay-armed" path (`disconnectKeepingPendingConnect`), not `unmanageDevice`. Only true unpair calls full `unmanageDevice`/`disconnectPeripheral`.
3. **Wake → sync** — mostly there: the wake arrives as `didConnect` → `onDeviceReady` → `_handleDeviceConnected`; ensure the background drop-guard lets a device-initiated wake through (set pending-sync flag, as `_onBackgroundSyncRequested` does). `_onStateRestored` (`device_provider.dart:232`) already sanctions a due sync.
4. **Demote BGTaskScheduler to backstop** — keep the `BGProcessing`/`BGAppRefresh` tasks (shipped 0.25.4) as the fallback for when pending-connect misses (notably after **user force-quit** — iOS won't relaunch for BLE then).
5. **Foreground UX + staleness banner** — surface the button-to-wake affordance since the device may be DARK on app open. Add a **"haven't synced in a while — tap your Omi to sync" banner** that triggers after **N missed windows** (`now − lastSuccessfulSync ≥ N × interval`, with a floor so short intervals don't nag; suppressed in Manual-Only mode). It's the safety net for the irreducible cases — force-quit dropped the standing connect, or the device was out of range — proactively pointing the user at the button to realign instead of silently accumulating stale data. Tapping it re-arms the standing connect and prompts the physical tap. Generally useful even on `enabled=0`.

#### Cross-platform: why windowing is opt-in (and Android keeps the status quo)
It's **one device** — the firmware can't be DARK for iOS yet always-connectable for Android at the same time; whichever phone is nearby sees the same advertising behavior. The two platforms want opposite things:
- **iOS** *gains* from DARK/window cycling (reliable background wake it otherwise lacks), and loses little on-demand connect (iOS has no good instant on-demand today anyway).
- **Android** *loses* from it: today the device is always connectable, so opening the app connects **instantly**, anytime. DARK between windows breaks that instant on-demand connect (you'd wait for the next window or tap Wake-for-Sync). Android is the platform with the *good* on-demand experience, so it has the most to lose — and it doesn't need device-driven wake (FGS + exact alarm already wake it reliably).

Resolution: **windowing is the per-device `enabled` flag (#5 above), default OFF.** `enabled=0` = today's always-connectable behavior (instant on-demand connect, no tap, alarm-driven) — **Android stays here → zero regression**. `enabled=1` = device-driven windows — iOS opts in. Note: **scheduled** sync needs no tap on either mode (windows auto-connect via the pending-connect); only **immediate/on-demand** connect regresses under `enabled=1`, which is exactly what the Wake-for-Sync tap mitigates.

#### Android changes (none required — stays on `enabled=0`)
Android keeps today's path entirely: always-connectable firmware, FGS + WorkManager + exact alarm wake, instant on-demand connect, no tap. The firmware windowing is inert for Android because the app never sets `enabled=1`. (If an Android user *wanted* device-driven cycling, `autoConnect=true` (`OmiBleForegroundService.kt:470`) would catch the windows the same way iOS does — but there's no reason to, so leave it off.) **Do not** re-introduce `CompanionDeviceManager` presence observation — this fork removed it due to OnePlus/Oppo/Realme connection wedges (0.24 changelog). Keep the alarm as the safety net.

#### Hard tradeoffs & risks
1. **On-demand connect regresses (only when `enabled=1`)** — DARK between windows means no instant connect on app open; fully dependent on button/motion triggers + safety floor. Biggest UX risk — but scoped to opted-in (iOS) devices; Android and opt-out users on `enabled=0` keep instant on-demand connect.
2. **iOS user force-quit kills background BLE wake** until next manual launch (iOS platform rule). BGTask backstop partially covers it; **re-arm-on-launch** restores the standing connect the moment the app reopens, and the **staleness banner** points the user at the button if data has piled up.
3. **iOS background-scan latency** — window must be long + fast-advertising (≥45–60 s); too short → iOS misses it, too long → device power. Needs tuning + measurement.
4. **Mixed firmware/app versions** — gate on the capability bit + safety floor so no combination bricks reachability.
5. **AAD refactor** touches a working, subtle thread — regression-test VAD recording, SD pause/resume, marker durability.
6. **Must measure** — put it on a Nordic PPK2: today's continuous-slow-adv vs DARK+window current draw, plus real-world iOS wake hit-rate (worn all day, app backgrounded). Don't ship on theory.

#### Phasing
- **Phase 1 — Firmware:** dark state + window scheduler + config char + capability bit + button/motion triggers (incl. the "Wake for Sync" button action) + safety floor. Validate on PPK2 + manual nRF connect. Ship behind the capability bit.
- **Phase 2 — iOS:** standing pending-connect (1–3), routine-disconnect-keeps-armed, wake→sync, BGTask demoted to backstop. Measure background wake hit-rate vs. the BGTask-only baseline.
- **Phase 3 — Android (optional):** only if measurement shows a worthwhile phone-battery saving from relaxing the alarm cadence.

Highest-leverage cheap validation: **Phase 1 window scheduler + Phase 2 standing pending-connect**, measured against current BGTask reliability — tells you whether device-driven wake is worth the full build-out before committing.

#### Relevant files
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

### 4. Streaming WAV stitch — fix OOM on long-recording merge [small] [Pending]

Observed 2026-07-08 00:39:06 (device log): `RecordingsManager: Stitch failed: Out of Memory` while stitching a draft onto a 2-hour recording (`recording_1783461803610.wav`, 7,353,745 ms of 16 kHz mono 16-bit PCM ≈ 235 MB).

#### What happens today (no data loss, but conversations split) — code-verified 2026-07-08
`_stitchWav` (`recordings_manager.dart:1465`) loads **both entire WAVs into RAM plus a combined copy** — `readAsBytes()` on draft + next, then a `BytesBuilder` (`copy:true` default) that copies draft PCM + silence + next PCM into a second buffer — peak ≈ 2× the combined file size (~½ GB in the observed case), worse momentarily if the `BytesBuilder` grow-doubles. It hard-fails on exactly the long recordings the stitch matters most for. The failure path is *mostly* clean: the allocations all precede `draftFile.openWrite()` (:1496), so the draft is untouched on disk and `_performStitch`'s catch (:1458) finalizes the draft as its own recording (`_draft.wav` → `.wav`, meta promoted, EDLs re-pointed). Net effect: one continuous conversation surfaces as **two separate recordings** with no inserted gap — cosmetic, not data loss. The finalized file even uploads fine afterwards.

**Why it's worth fixing despite being cosmetic (the real argument):** `vadMaxConversationMinutes` defaults to `0` (no cap), so drafts grow unbounded, and every incremental stitch re-materializes the *entire* accumulated draft — peak memory is **O(total recording length)**. So multi-hour conversations don't just occasionally split; they **reliably fragment as they grow**, on exactly the long recordings stitching exists to hold together. That scaling behavior, not any single failure, is the reason to do this.

**One caveat to the "clean failure" claim:** `openWrite()` uses `FileMode.write`, which **truncates the draft to zero first**. `takeBytes()` doesn't re-allocate, so a marginal OOM landing *during* the post-truncate write/close is unlikely — but nonzero, and would lose the draft entirely rather than just split it. The proposed rollback (below) closes this window too, so it's mild extra value, not just parity.

#### Proposed fix
Stream instead of materializing:
1. Open the draft in **append** mode (never rewrite its existing PCM — today's truncate-and-rewrite of the draft's own bytes is redundant work anyway).
2. Write the silence gap, then copy the next file's PCM through in chunks (~64 KB).
3. Patch the WAV header size fields in place afterwards (`RandomAccessFile`, RIFF size at offset 4, data size at offset 40).
4. **Rollback on failure:** record the draft's original length first; on any mid-stream error, `RandomAccessFile.truncate(originalLen)` restores the draft exactly, then fall back to the existing finalize-separately path. This is the one property the in-memory version got for free (all-or-nothing) that streaming must implement explicitly — without it, a crash mid-append leaves junk trailing bytes and a retry would double-append.
5. Only run the post-write steps (`_mergeMeta`, `_reanchorMarkerEdls`, delete `nextFile`) after a *verified* complete append.

Trade-offs accepted: a small partial-write crash window (mitigated by the truncate-back rollback; an unpatched header still describes the original length, so players ignore a partial tail), and a bit more code. Performance is a wash or better (no giant allocation / GC pressure); final disk footprint identical.

Same pattern applies to `_stitchBinIfPresent` (`:1528`), which reads the whole next Opus bin into RAM before appending — less urgent (bins are ~30× smaller than PCM) but trivial to convert while in there.

#### Implementation caveats (verified 2026-07-08 — the idea under-specifies these)
1. **Dart has no O_RDWR-without-truncate-without-append `FileMode`, so the naive "append then seek-patch the header" won't work.** `FileMode.write`/`writeOnly` truncate; `FileMode.append`/`writeOnlyAppend` are `O_APPEND`, which on POSIX forces every write to EOF and **ignores `setPosition`** — so `setPosition(4)` + `writeFrom` to patch the RIFF/data-size fields silently lands at end-of-file instead. The header patch (step 3) needs a deliberate approach: precompute all sizes (they're all known up front — `draftLen-44`, silence, `nextLen-44`) and patch the 8 header bytes with a *non-append* handle, or do the body append and header patch as two distinct operations with the right mode. The naive version can pass a quick smoke test while shipping a broken/understated header.
2. **The header patch is load-bearing because the default output format is WAV** (`preferences.dart:161`, `audioSaveFormat` defaults to `'wav'`), and `_finalizeDraft` (:1271) only **renames** the draft — it never rewrites the header. So for the default path a stale/understated `data` size truncates player playback. (For `m4a` users it's moot: `_transcodeWavToM4a` (:1409) reads everything past offset 44 and ignores the header — which is why the next point has gone unnoticed.)
3. **Fix the pre-existing `_stitchSilence` stale-header bug in the same place.** `_stitchSilence` (:1236) **already appends silence to WAV drafts via `FileMode.append` without patching the header**, then only updates the `.meta`. So a WAV-format draft whose last pre-finalize mutation was a silence stitch already finalizes with an understated header today. The streaming rewrite of `_stitchWav` should share a header-patch helper that `_stitchSilence` also calls, closing both at once. (`_stitchWav` currently masks this by regenerating a full correct header via `_generateWavHeader` — but only when a WAV stitch *follows* the silence stitch.)
4. **`_transcodeWavToM4a` (:1409) has the same whole-file `readAsBytes`** and can OOM independently on the finalize path — though it *views* (not copies) past offset 44, so its peak is 1× not 2×. Worth a glance while in there; not the OOM driver.

#### Relevant files
- `app/lib/services/recordings_manager.dart` — `_stitchWav` (`:1465`, the in-memory read/combine/write), `_performStitch` (`:1441`, catch → `_finalizeDraft` fallback to keep), `_stitchSilence` (`:1236`, already appends without a header patch — fix in the same helper), `_stitchBinIfPresent` (`:1528`, whole-bin `readAsBytes` append), `_finalizeDraft` (`:1271`, unchanged fallback — renames only, no header rewrite), `_generateWavHeader` (`:1632`, offsets 4/40 for the patch), `_transcodeWavToM4a` (`:1409`, same whole-file read, 1× peak), `_mergeMeta` / `_reanchorMarkerEdls` (post-write steps that must gate on verified append).
- `app/lib/backend/preferences.dart` — `audioSaveFormat` (`:153`, defaults to `'wav'`; why the header patch is load-bearing).

---

### 5. Background reconnect recovery latency after native retry back-off [small] [Shipped — validate on device]

Shipped in **0.29.0 (PR #338)**, follow-up to PR #337. Once native pauses its retry loop
(`AUTONOMOUS_RETRY_STOP_AFTER`) and hands reconnection to the sync schedule, two latencies regressed
(recovery after a wedge clears: ~30 s → up to one sync interval; wedge re-probe of a returned device:
~15 min → ~15 h). Both fixed: a dedicated **outage-recovery alarm** (`SyncAlarmReceiver`
`ACTION_RECOVER`) bridges the gap — backs off 2 → 4 → 8 → 16 min then self-terminates onto the sync
interval — and the wedge re-probe was re-keyed to wall-clock time (`WEDGE_REPROBE_INTERVAL_MS`). The
whole recovery lifecycle is gated by one `recoveryWanted()` invariant (auto-sync on + user not
disconnected + BT on + `wedgeDetected`). Mechanism + rationale live in the code
(`OmiBleForegroundService.kt` `recoveryProbe*` / `recoveryWanted` / `onRecoveryProbeAlarm`,
`SyncAlarmReceiver.kt` `ACTION_RECOVER`) and the 0.29 CHANGELOG entry — not duplicated here.

**Remaining — on-device validation only** (the reason this stays open):
- A wedge that clears mid-outage reconnects within the recovery-alarm cadence, not the sync interval.
- The recovery alarm self-terminates (no indefinite tight polling) for a genuinely-absent device.
- Doze throttling behaves as expected (the ~9 min `setExactAndAllowWhileIdle` floor).
- Battery cost of the ~4 extra attempts vs. the recovery-latency win is acceptable.

### 6. On-device diagnostic event log [medium] [Pending — spec ready]

Full design spec: **[DIAG_LOG_SPEC.md](DIAG_LOG_SPEC.md)** — hand-off ready, implementable as-is.

A dev-tools-gated, RAM-resident binary event ring that captures **per-event** diagnostics
(empty-bin rotations, marker/priority drops, pause-gate saves — the *"why + when"*, not just the
aggregate since-boot counters at `0x0062`) and ships them to the phone over a new BLE
characteristic on connect, ack-clearing itself afterward. Design constraints, all met: **zero
filesystem interference** (never touches LittleFS/ring audio storage), **RAM reclaimed from the
oversized SD-worker stack** (`SD_WORKER_STACK_SIZE`, measured 2.7 / 12 KB used — precedent at
`codec.c:81`), **compiled out entirely in production** (`CONFIG_OMI_DIAG_LOG`, dev/internal builds
only), and **off by default** behind a capability-gated dev-tools toggle pushed on connect. See the
spec for the 16-byte record format, event-code table, GATT `0x0063`/`0x0064` layout, app
integration points, testing plan, and the post-LittleFS persistent-log upgrade path (ring reserved
sectors 81–255).

---

## DEFERRED

### 3. iOS code signing & non-jailbroken distribution [medium] [Deferred]

The iOS build works end-to-end via CI (`.github/workflows/ios-build.yml`) and produces an **unsigned** dev IPA that installs on a **jailbroken** device (AppSync Unified / TrollStore — current path for the iPhone 6s Plus). To run on a **stock** (non-jailbroken) iPhone, the IPA must be code-signed, which needs an Apple Developer account plus signing material wired into CI.

#### What it takes
- **Apple Developer Program ($99/yr)** — required for a real signing certificate + provisioning profile. (A free Apple ID only does 7-day Xcode sideloading on a Mac, which headless CI can't drive.)
- **Signing secrets in GitHub Actions** — distribution certificate (`.p12` + password) and a provisioning profile stored as encrypted repo secrets, imported into a temporary keychain on the runner (e.g. `apple-actions/import-codesign-certs`).
- **Build a signed IPA** — replace the workflow's `flutter build ios --no-codesign` with `flutter build ipa` + an `ExportOptions.plist`: method `app-store` for TestFlight, or `ad-hoc` / `development` for direct install with the target device UDID registered in the profile.
- **Distribution**
  - **TestFlight** (cleanest — no per-device UDID): upload via `xcrun altool`/`notarytool` or `apple-actions/upload-testflight-build`; install via the TestFlight app. No Mac needed locally.
  - **Ad-hoc**: register target device UDIDs in the profile; install the signed IPA directly (Apple Configurator / `ideviceinstaller`).

#### Why deferred
The jailbroken-device path (unsigned IPA, already working) covers the current 6s Plus for free. Signing only matters when targeting a non-jailbroken iPhone, and it carries an annual fee + secret management. Revisit if/when a stock-iOS device becomes a target.

#### Relevant files
- `.github/workflows/ios-build.yml` — today: `flutter build ios --flavor dev --no-codesign` → zips `Payload/Runner.app` into an unsigned IPA. Signing adds a cert-import step, switches to `flutter build ipa`, and adds an upload/export step.
- Flavors (`app/flavorizr.yaml`): `dev` = `com.omi.offline.development`, `prod` = `com.omi.offline` — the provisioning profile must be issued for whichever bundle id is shipped.
