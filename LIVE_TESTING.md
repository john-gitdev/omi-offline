# Live testing — app 0.33.0 / firmware oo-2.10.0

On-device test plan for the mic-gate change set. Everything in it builds and passes CI; **none
of it has run on hardware**, which is what this document is for.

Work top to bottom — the later scenarios assume the earlier ones passed. Each one states what
"pass" looks like as a concrete reading, because "seems fine" is not a result.

## Before you start

1. **Install both halves.** Firmware `oo-2.10.0` and app `0.33.0`. Mixed versions degrade rather
   than break: an older firmware makes the new `mic:` line read `n/a`, and an older app ignores
   the appended `0x0062` fields.
2. **Expect to re-pair.** Every DFU clears the Bluetooth bond on both sides — by design, not a
   fault. Don't spend time diagnosing it.
3. **Turn the event log on** — Debug Tools → Event log. Nothing below produces records without
   it, and it is off by default and cleared by every reboot.
4. **Where to read the mic.** Debug Tools → Diagnostics → the **Microphone** group. Three rows:

   | Row | Means |
   |---|---|
   | **Last audio frame** | The one to watch. Frames land every 100 ms, so **under ~200 ms means the mic is delivering right now**. Seconds means parked. Minutes means stopped — and it turns amber past ten |
   | **Capture duty** | Recorded time as a share of uptime |
   | **Recorded since boot** | Total voiced time |

   The group header summarises it without expanding: *delivering*, or *parked 4m 12s*.

5. **The same readings in text**, for pasting into a report — Debug Tools → Copy snapshot:

   ```
   mic: silentFor=142ms voiced=18320450ms duty=81.4%
   events: capture=true (pref=true, confirmed 3s ago) supported=true held=4 dropped=0
   ```

   - `silentFor` is the same reading as **Last audio frame** above.
   - `capture=` is the **device's** gate, with your app preference beside it. If they disagree, the
     push was skipped (a sync holds the storage lock) — the log is not recording, whatever the
     toggle says.

> **Snapshots are worth more taken immediately after an action than at random.** Several of these
> test a transition. Note which scenario you just ran when you save one.

---

## 1. First boot

**Do:** flash, re-pair, open Debug Tools, snapshot.

| Check | Pass |
|---|---|
| Device Settings → Firmware | `oo-2.10.0` |
| `mic: silentFor` | under ~200 ms (auto mode: the mic never parks) |
| `sd:` counters | all `0` |
| `events: capture=` | `true` once you have enabled the toggle and reconnected |

**Fail:** `capture=false (pref=true, …)` persisting across reconnects means the gate write is
being skipped every time — everything below that depends on the event log will be silent.

---

## 2. Auto mode, a normal day *(your mode — this is the regression net)*

**Do:** wear it as usual. Snapshot at the end of the day.

| Check | Pass |
|---|---|
| `sd: blocks/frames/codec/boot` | all `0` |
| `mic: silentFor` | under ~200 ms |
| `mic: duty` | plausible for your day (≈80 % is what this device measured before the change) |
| `queue: peak` | ≤ ~70 of 120 |
| `ring: ioErrors` | `0` |
| `DIAG_MIC_STATE` records | **none at all**, except one `parked`/`resumed` pair per mute |

**Why no records is the pass:** auto mode never parks the mic, so the gate never transitions.
Any other `mic_state` record here is a finding, not noise.

---

## 3. Manual standby parks the mic

**Do:** switch to Manual Mode. Wait 60 s. Snapshot.

| Check | Pass |
|---|---|
| `mic: silentFor` | tens of seconds **and climbing** on each new snapshot |
| Event log | a `Mic parked — capture stopped (threshold 32769)` record |

**This is the single most valuable reading in the whole plan** — it is the direct evidence that
the battery change does anything at all.

**Fail:** `silentFor` staying under a second means the gate never parked; the mic is still
running and there is no saving.

---

## 4. Pre-arm keeps the start of a manual recording *(needs your ears — a snapshot cannot show this)*

**Do:** in Manual standby, **start talking first**, then press record mid-sentence. Say
"testing one two three" with the press landing on "testing". Stop. Play it back.

| Check | Pass |
|---|---|
| The recording | **the first word is there** |
| Event log | `Mic resumed` at the press, `Mic parked` after the stop |

**Fail:** the recording opens on "two three". That means the mic woke at dispatch rather than at
the press edge, and roughly 700 ms is being lost off the front of every manual recording.

---

## 5. Stopping a manual recording parks it again

**Do:** start a manual recording, stop it, snapshot after ~10 s and again after a minute.

| Check | Pass |
|---|---|
| `mic: silentFor` | climbing within a second or two of the Stop |
| Event log | `Mic parked` after the stop |

This exercises the park driven by the **button FSM**. Scenario 7 exercises the other one.

---

## 6. A marker does nothing in Manual standby

**Do:** in Manual standby (mic parked), tap your marker gesture. Watch the device.

| Check | Pass |
|---|---|
| LED | **no white flash** |
| Event log | no new record |
| App | no bookmark, no empty bookmark row |
| `mic: silentFor` | keeps climbing — the mic never woke |

**The absence of the LED flash is the signal.** A real marker flashes white even with LEDs off
(it overrides stealth), so nothing flashing means nothing happened — which is the intended
behaviour, not a dead button.

**Fail worth catching:** the mic wakes (`silentFor` resets, a `Mic resumed` appears) but no
bookmark is written. That would mean the marker write is suppressed while the force-wake still
fires — the worst of both.

---

## 7. A marker during a manual recording still works, and does not outlive the Stop

**Do:** start a manual recording. Tap a marker mid-recording. Stop **within 30 s of the marker**.
Snapshot immediately, then again a minute later.

| Check | Pass |
|---|---|
| The recording | bookmark present at the tap |
| `mic: silentFor` after the Stop | climbing within a second or two |

**Fail:** capture continues for up to 50 s past the Stop. That is `force_wake_until_ms` outliving
the stop and resuming capture in standby — the specific bug the manual force-wake gate exists to
prevent. This is the scenario most likely to catch a real defect.

---

## 8. A marker in Auto mode records at least a minute

**Do:** in Auto mode, in a **quiet** room (so the VAD would not otherwise record), tap a marker.
Stay quiet. Then repeat, but talk for two minutes after the tap.

| Check | Pass |
|---|---|
| Quiet case | a recording of roughly 60 s exists around the bookmark |
| Talking case | the recording **extends** past a minute and runs as long as you keep talking |

The minute is a floor, not a duration — 50 s of forced capture plus the 10 s VAD hold, with real
audio refreshing the hold.

---

## 9. Mute round-trip timestamps *(auto mode — checked in the conversation list, not the snapshot)*

**Do:** in Auto mode, get a recording going. Mute. Wait **5+ minutes**. Unmute and talk again.

| Check | Pass |
|---|---|
| The recording created after unmuting | stamped at the time you **actually unmuted** |
| Event log | a clean `Mic parked` / `Mic resumed` pair |
| The muted stretch | appears as a "muted" ghost row |

**Fail:** the new recording is stamped ~5 minutes early — i.e. by the mute duration. A long
enough mute files it under the wrong hour, or the wrong day.

> Mute is refused outright in Manual Mode (pre-existing, not part of this change) — don't read
> that as a bug.

---

## 10. Boot restore

**Do:** leave the device in Manual standby, reboot it (Device Settings → Reboot Omi), reconnect,
snapshot after a minute.

| Check | Pass |
|---|---|
| `mic: silentFor` | tens of seconds and climbing — it came up parked |
| Mode | still Manual standby |

Then repeat with a **manual recording running** when you reboot: it should come back up recording
(the threshold is persisted), and `silentFor` should stay under 200 ms.

---

## 11. Priority Recording (auto mode)

**Do:** in Auto mode, start a Priority Recording, talk, stop.

| Check | Pass |
|---|---|
| The head of the recording | no gap or click at the very start |
| Event log | `priority_record_start` and `priority_record_stop` |
| `markers:` counters | `starts` and `stops` both incremented, `drops` still `0` |
| `mic: silentFor` | under 200 ms throughout (auto never parks) |

The head is the thing to listen for: the mic no longer stops and restarts at the start of a
Priority Recording.

---

## 12. Battery *(the point of the exercise)*

**Do:** a Manual-mode day with the phone mostly away, against a comparable Automatic-mode day.
Note the battery percentage at the same times of day.

Crude, but it is the only measurement available without a PPK2, and it separates "worth it" from
"wasn't". The mic path is the dominant idle draw, so if manual standby parking works you should
see it here or nowhere.

---

## 13. Advertising settles to the slow interval when idle

**Do:** power-cycle the Omi in a quiet room, leave the phone away for **90 s**, then connect and
snapshot. Repeat after leaving it idle and disconnected for a couple of minutes.

| Check | Pass |
|---|---|
| `ble: … adv=` | `slow` |
| A trailing `(want … — switch not applied)` | absent |

`adv=` is the **live** interval, read at connect time — advertising stops while connected, so it
reports what was in force when your phone found the device. That is exactly the question.

**Fail:** `adv=fast` after 90 s of idle means the backstop never fired. `adv=fast (want slow —
switch not applied)` is different and more interesting: the backstop *did* fire, and the
advertising watchdog has not applied the switch.

> Don't read `lastFailAdv=` for this. That is the interval during the last *failed* connection —
> a different field, and it was misread as the live mode twice during review, which is why
> `adv=` now exists.

---

## Watch list — the next few days

Check a snapshot every couple of days. Any of these is worth stopping for:

| Signal | Means |
|---|---|
| **`Mic resumed but SILENT`** | The wedge, caught live. START succeeded and the part returned digital zero, which a real room cannot produce. **This is also the evidence that says restore the PDM_EN cycle** (IDEAS.md #5) |
| `Mic resume FAILED` | dmic START rejected twice. Should never appear |
| `silentFor` in minutes with **no** preceding `Mic parked` | The mic stopped on its own — not the gate |
| New `sd:` block or frame drops | Audio lost. Was `0` for 22 h before this change |
| `queue: peak` past ~70 | Rising queue pressure; check `ring: maxIo` alongside |
| `ring: ioErrors` above `0` | The card is rejecting writes |
| Rapid `parked`/`resumed` churn | dmic cycling more than expected — the risk this change carries |

---

## What this plan cannot tell you

- **Whether the post-resume probe works**, short of an actually wedged mic. It cannot be forced.
- **Real current draw.** Everything about the battery here is inference from percentages. Four
  states on a PPK2 (auto-silent disconnected / muted / recording / syncing) would turn the whole
  list of levers into a ranking.
