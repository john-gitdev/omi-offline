# Live testing — app 0.36.4 / firmware oo-3.1.0

On-device test plan for the **background-sync engine lifetime** (0.36.0–0.36.1) and the
**sync-schedule rework** (0.36.4). Everything in it builds and 732 tests pass; the engine change
is marked **NOT device-verified** in its own commits, because it changes app startup and Activity
lifecycle and nothing in the host suite exercises either. That is what this document is for.

Firmware is unchanged since `oo-3.1.0` — this is an app-side plan. The mic watch list at the end
is carried over from the previous plan and is still open evidence for IDEAS.md #5.

Work top to bottom — the later scenarios assume the earlier ones passed. Each one states what
"pass" looks like as a concrete reading, because "seems fine" is not a result.

## Before you start

1. **Install app 0.36.4.** No firmware flash needed, so no re-pair.
2. **Turn on Save Debug Logs** — Debug Tools → Save Debug Logs. Most of the checks below read the
   pulled log, and it is off by default.
3. **Have `adb logcat` available.** Three scenarios are only observable natively:

   ```bash
   adb logcat -s OmiBle.MyApp:D OmiBle.FgService:D flutter:D
   ```

   | Line | Means |
   |---|---|
   | `onCreate: Flutter engine created and cached as …` | The `Application` pre-warmed the engine. Absent ⟹ the pre-warm failed and you are testing the **degraded** path, not this change |
   | `dartReady: Dart is up — background wake paths may deliver` | Dart declared itself ready. **Until this appears, every wake correctly skips** |
   | `main: UI attached to a running engine — permissions + launch housekeeping` | A screen attached to a process that was already running |
   | `main: UI attached, but this launch already did its UI work — skipping` | The 10 s debounce fired — expected on a normal cold launch, *not* expected on the first attach after a headless start |

4. **The lever for "Android reclaimed the Activity".** Developer Options → **Don't keep
   activities**. It destroys the Activity the moment you leave the app while leaving the process
   and the foreground service running — which is exactly the reclaim this change is about, on
   demand instead of after hours of memory pressure. Turn it **off** again before scenario 7.

5. **Set the sync interval to 15 minutes** (App Settings → Background sync interval) so a
   scheduled sync is observable inside a test session rather than half an hour later.

> **Snapshots are worth more taken immediately after an action than at random.** Note which
> scenario you just ran when you save one.

---

## 1. Normal cold start still works *(the regression net — run this first)*

**Do:** force-stop the app, clear it from Recents, launch it from the launcher.

| Check | Pass |
|---|---|
| Launcher opens the app | It comes up. A **brick here is the one catastrophic outcome** of this change — `FlutterActivity` throws on a cache miss, so a failed pre-warm has to degrade to an Activity-owned engine, not a failure to launch |
| `onCreate: Flutter engine created and cached` | Present, once |
| `dartReady` | Present, **after** the engine line, not with it |
| Permission prompts | Appear as they always did (first install / after revoking) |
| `main: UI attached…already did its UI work — skipping` | Present — main() did the housekeeping and native's attach signal landed within 10 s. Seeing the *un*-debounced line here means the launch swept the filesystem twice |

---

## 2. A scheduled sync runs with the Activity destroyed *(the change itself)*

**Do:** with **Don't keep activities ON** — open the app, confirm the Omi is connected, press Home.
Wait out one sync interval without reopening.

| Check | Pass |
|---|---|
| The sync happens | The notification moves off the idle line into `Syncing recordings` on its own. **This is the whole test** — before 0.36.0 it stayed idle and the wake reported success having done nothing |
| Recordings appear | Reopen afterwards: the new recordings are already there, not pulled down in a burst on open |
| `flutter:` log activity during the window | Non-empty. The original failure was **native logging 300+ records and Dart two** over seventeen hours; that ratio is the signature |
| No `Flutter engine not running — sync deferred to next app open` | Absent. If present, the engine did not survive |

---

## 3. A headless cold start — WorkManager starts the process with no Activity ever

**Do:** force-stop the app (`adb shell am force-stop com.omi.offline` — append `.dev` for a
`build.sh` dev-flavor build). Do **not** open it.
Wait for the WorkManager backstop (≤ 15 min).

| Check | Pass |
|---|---|
| The process starts and syncs | The foreground-service notification appears and works a sync, with no Activity ever attached |
| `dartReady` appears | Yes — this is the case where readiness had to stop being "the engine was constructed" |
| **No permission dialog, no crash** | `permission_handler` throws without an Activity. A `PlatformException` at `requestPermissions` here would kill `main()` before `ServiceManager` — the log shows the request being **skipped**, not failing |
| `main: UI attached…` | **Absent** until you open the app |

**Then open the app.** The attach must do the UI-only work it skipped:

| Check | Pass |
|---|---|
| `main: UI attached to a running engine — permissions + launch housekeeping` | Present, **not** debounced away. A headless start leaves the debounce null precisely so the first real attach is not skipped |
| Permissions | Requested now, if any are outstanding |

---

## 4. No phantom foreground

**Do:** during the headless window of scenario 3, watch the link.

| Check | Pass |
|---|---|
| The link is dropped when idle | The app must not sit holding the connection with keep-alives. With no Activity, `lifecycleState` is null forever, and the pre-0.36.0 reading of null was "assume foreground" — which would keep-alive indefinitely and take the foreground branch on connect |
| Battery over a long headless stretch | No worse than a comparable stretch with the app merely backgrounded |

---

## 5. Background processing still writes M4A *(the silent one)*

**Do:** App Settings → Recording format = **M4A**. Then run scenario 2 or 3 so a *background*
run does the processing.

| Check | Pass |
|---|---|
| The resulting files | `.m4a`. **This fails silently** — Activity-scoped, the AAC encoder threw `MissingPluginException` from the background isolate and the processor fell back to `.wav` with no error surfaced. Check the extension on disk, not the UI |

---

## 6. The schedule means "since the last sync" *(0.36.4)*

**Do:** interval at 15 min. Note the `Next sync at H:MM` on the notification. At ~14 minutes in,
pull to sync **by hand**.

| Check | Pass |
|---|---|
| `Next sync at H:MM` moves | It jumps to ~15 min from **now**, not the old time. Before 0.36.4 a manual sync stamped the completion but moved nothing, so the Omi was woken a minute later for a sync with nothing to do |
| No sync a minute later | Correct |
| After a sync that **could not reach** the Omi (walk out of range) | The schedule does **not** move — a skip is retried at the next opportunity rather than pushing the interval out |

---

## 7. Backgrounding mid-sync costs no grace *(0.36.4)*

**Do:** turn **Don't keep activities OFF** first. Start a sync, and press Home while it is still
running. Come back ~10 s after the sync finishes.

| Check | Pass |
|---|---|
| Still connected on return | Yes. The grace now *starts* when the sync ends; before 0.36.4 the wait was spent watching the sync and whatever was left became the whole grace — anywhere in [0, 15 s], often none |
| Leave it longer than 15 s after the sync ends | It disconnects, as it always did |

---

## 8. The notification stops claiming a battery level it cannot know *(0.36.4)*

**Do:** leave the Omi at home (or powered off) and let several sync cycles miss.

| Check | Pass |
|---|---|
| Idle line | `Last Sync: Skipped • H:MM` — **with no `• N% Battery`**. The percentage may only appear when the last sync reached the device or the link is up right now |
| Reconnect | The percentage comes back |
| After a force-stop, while still out of range | Android renders its own copy of that line; it must follow the same rule. This is the version most likely to be showing during a long stretch away |

---

## 9. The original symptom, end to end

**Do:** a full day. App backgrounded, Omi worn, Don't keep activities **off** (real conditions).

| Check | Pass |
|---|---|
| Syncs through the day | Recordings arrive in interval-sized batches, not one 11-hour catch-up on open |
| Opening the app in the evening | Pulls down minutes of audio, not hours. The reported failure was **68 files / 125 MB / 11.3 h** in one go after seventeen hours that all looked healthy |

---

## Watch list — the next few days

Check a snapshot every couple of days. Any of these is worth stopping for.

**App (this change):**

| Signal | Means |
|---|---|
| A catch-up burst on app open | The engine is dying with the Activity again — scenario 2 regressed |
| Background recordings in `.wav` with M4A selected | The AAC encoder went back to Activity scope |
| Repeated `main: UI attached to a running engine` with no reopen | The attach signal is firing more than it should; the housekeeping is idempotent, but it sweeps the filesystem each time |
| `dartReady` absent while the app is plainly running | The wake paths are skipping every sync — the failure this change replaced, in its fail-safe direction |

**Mic (carried over — still open evidence for IDEAS.md #5):**

| Signal | Means |
|---|---|
| **`Mic resumed but SILENT`** | The mic wedge, caught live. START succeeded and the part returned digital zero, which a real room cannot produce. **This is the evidence that says restore the PDM_EN cycle** (IDEAS.md #5, still *Pending — awaiting field evidence*) |
| `Mic resume FAILED` | dmic START rejected twice. Should never appear |
| `silentFor` in minutes with **no** preceding `Mic parked` | The mic stopped on its own — not the gate |
| New `sd:` block or frame drops | Audio lost |
| `queue: peak` past ~70 | Rising queue pressure; check `ring: maxIo` alongside |
| `ring: ioErrors` above `0` | The card is rejecting writes |

**BLE (new instrument, nothing to check — just collect):**

Every disconnect now logs `ble_link_drop` with the connected RSSI and its age. Nothing here is a
pass/fail; the point is to accumulate a multi-day log so the mid-transfer `gatt_status_8` drops
can finally be sorted into "device stalled" (≈ −60 dBm) and "out of range" (≈ −100 dBm). See
BLE_Research.md §7 and IDEAS.md ACTIVE #1.

---

## What this plan cannot tell you

- **Whether a real memory-pressure reclaim behaves like "Don't keep activities".** The developer
  option destroys the Activity deterministically on background; a genuine reclaim happens under
  memory pressure at an arbitrary point, possibly mid-sync. Scenario 2 is the closest available
  approximation, not the thing itself.
- **Whether the pre-warm failure path degrades correctly.** `FlutterEngine(Context)` failing in
  `Application.onCreate` cannot be forced from outside the app. The guard exists so a failure
  falls back to an Activity-owned engine rather than bricking the launcher; scenario 1 only
  confirms the *happy* path.
- **Real current draw.** Everything about battery here is inference from percentages.
