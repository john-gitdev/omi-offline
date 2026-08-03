# Ideas

## Table of Contents

### ACTIVE
- [1. BLE stability: partial syncs, stuck notifications [medium] [Active]](#1-ble-stability-partial-syncs-stuck-notifications-medium-active)

### PENDING
- [2. Streaming WAV stitch — fix OOM on long-recording merge [small] [Pending]](#2-streaming-wav-stitch--fix-oom-on-long-recording-merge-small-pending)
- [3. Diagnostic event log — persistent (reboot-surviving) upgrade [small] [Pending — post-LittleFS]](#3-diagnostic-event-log--persistent-reboot-surviving-upgrade-small-pending--post-littlefs)
- [5. Mic rail (PDM_EN) is not driven by firmware [small] [Pending — awaiting field evidence]](#5-mic-rail-pdm_en-is-not-driven-by-firmware-small-pending--awaiting-field-evidence)
- [6. Offer a re-pair when an OTA eats the bond [small] [Pending]](#6-offer-a-re-pair-when-an-ota-eats-the-bond-small-pending)
- [7. An OTA that eats `storage_backend` wipes the SD card [small] [Pending — closes itself with LittleFS removal]](#7-an-ota-that-eats-storage_backend-wipes-the-sd-card-small-pending--closes-itself-with-littlefs-removal)

### LARGE
- [4. Device-driven BLE wake (firmware + iOS) [large] [Parked — lost its primary motivation]](#4-device-driven-ble-wake-firmware--ios-large-parked--lost-its-primary-motivation)

Shipped ideas are removed once they land — the code, CHANGELOG.md and CLAUDE.md are the
record. Only open work lives here.

---

## ACTIVE

### 1. BLE stability: partial syncs, stuck notifications [medium] [Active]

From the 2026-06-27 device-log analysis plus a code review of
[OmiBleManager.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleManager.kt)
and [OmiBleForegroundService.kt](app/android/app/src/main/kotlin/com/omi/offline/OmiBleForegroundService.kt).
Everything that analysis turned up has since shipped — the GATT-churn fixes (0.26.9),
resume-from-offset, the keepalive margin, stuck-"Connecting…" recovery, and the
outage-recovery alarm (0.29.0) — **except connection-param tuning**, which is all that
remains below. The callout records what was investigated and deliberately *not* done, so
it doesn't get re-litigated.

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

> **Background-specific partials had TWO further causes, both CPU-wakelock, both fixed
> 2026-08-03 — don't re-derive them.** Neither is RF, and both present as a mid-sync
> `gatt_status_8`, so they are easy to misattribute to the tuning item below.
>
> 1. **The foreground pipeline never held a CPU lock at all (the bigger one).**
>    `RecordingsController._acquireWake` called only `WakelockPlus.enable()` —
>    `FLAG_KEEP_SCREEN_ON`, a *screen* flag that lapses as soon as the app is
>    backgrounded. Tap Sync, pocket the phone, and nothing held the CPU: suspend within
>    seconds. Now takes `acquireProcessingWakeLock` alongside, released when the last
>    wake reason drops (and in `dispose()`, since the native lock is refcounted).
> 2. **The background cycle's lock expired mid-run.** `acquireProcessingWakeLock` used
>    `acquire(30 * 60 * 1000L)` and never renewed, and a large backlog outlives 30 min.
>    Now renewed on a timer, with a **2 h absolute ceiling** — renewing forever would
>    have defeated the leak backstop the timeout existed to be.
>
> Why either one drops the link: **both** keep-alives are `Handler`/`Timer` posts (native
> 0x32 in `OmiBleManager`, Dart's 5 s timer), and `postDelayed` runs on `uptimeMillis()`,
> which **does not advance while the SoC is suspended**. So both stall together and the
> firmware's 15 s `IDLE_DISCONNECT_TIMEOUT_MS` fires. **Lesson: a wake-lock timeout is a
> leak backstop, not a work budget — and any Handler-driven keep-alive is only as
> reliable as the wake-lock above it.**
>
> Also landed: the Bluetooth-off path now stops the *storage* keep-alive too (it stopped
> only the RSSI one, so the storage Runnable kept reposting every 5 s against a dead gatt
> until the next connect replaced it).
>
> **Two changes tried and reverted, deliberately — don't re-add without evidence.**
> (a) Keying the keep-alive Runnables by address: the app manages exactly one peripheral
> (one paired device in prefs, one `NativeBleTransport`), so the multi-device
> cancel-each-other hazard cannot occur. (b) Re-asserting `CONNECTION_PRIORITY_HIGH` per
> transfer in `downloadStorageFile`: the premise (Android silently downgrades priority for
> background apps) was never verified, and `requestConnectionPriority` triggers an LL
> parameter-update procedure, so one per file is not free on an RF-fragile link. It is a
> *candidate* for the experiment below, not a fix — measure it, don't assume it.

#### Open: connection-param tuning during transfer
Syncs transfer over `CONNECTION_PRIORITY_HIGH` (`OmiBleManager.kt`, ~11.25–15 ms
interval) — great throughput, RF-fragile. The open experiment is whether
`CONNECTION_PRIORITY_BALANCED` (30 ms) during a transfer trades throughput for fewer drops:
- `BALANCED` ~halves throughput, but each interval is more RF-robust (fewer drops per unit
  time) — at the cost of a longer transfer (more total exposure). Net effect on "did the
  whole transfer finish" is empirical.
- **Kept at HIGH on purpose for now:** resume-from-offset (already shipped) already makes a
  drop cheap, so HIGH + resume beats BALANCED unless measurement shows BALANCED's lower drop
  rate outweighs the throughput cost. Wire it behind something measurable and A/B
  throughput vs. drop-rate before committing. Android-only lever; the firmware's
  `update_conn_params` (7.5–22.5 ms) bounds the floor either way.
- **Re-measure before running this experiment.** Both wakelock fixes above changed the
  baseline this A/B would be judged against, and both presented as mid-sync drops —
  i.e. indistinguishable from the RF stalls this item is about. Get a clean post-fix
  partial-sync rate first, or `BALANCED` will be credited with someone else's fix.
  The reverted per-transfer HIGH re-assert belongs in the same experiment, as a third arm.

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

### 2. Streaming WAV stitch — fix OOM on long-recording merge [small] [Pending]

Observed 2026-07-08 00:39:06 (device log): `RecordingsManager: Stitch failed: Out of Memory` while stitching a draft onto a 2-hour recording (`recording_1783461803610.wav`, 7,353,745 ms of 16 kHz mono 16-bit PCM ≈ 235 MB).

#### What happens today (no data loss, but conversations split) — code-verified 2026-07-08
`_stitchWav` (`recordings_manager.dart:1557`) loads **both entire WAVs into RAM plus a combined copy** — `readAsBytes()` on draft + next, then a `BytesBuilder` (`copy:true` default) that copies draft PCM + silence + next PCM into a second buffer — peak ≈ 2× the combined file size (~½ GB in the observed case), worse momentarily if the `BytesBuilder` grow-doubles. It hard-fails on exactly the long recordings the stitch matters most for. The failure path is *mostly* clean: the allocations all precede `draftFile.openWrite()` (:1588), so the draft is untouched on disk and `_performStitch`'s catch (:1550) finalizes the draft as its own recording (`_draft.wav` → `.wav`, meta promoted, EDLs re-pointed). Net effect: one continuous conversation surfaces as **two separate recordings** with no inserted gap — cosmetic, not data loss. The finalized file even uploads fine afterwards.

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

Same pattern applies to `_stitchBinIfPresent` (`:1620`), which reads the whole next Opus bin into RAM before appending — less urgent (bins are ~30× smaller than PCM) but trivial to convert while in there.

#### Implementation caveats (verified 2026-07-08 — the idea under-specifies these)
1. **Dart has no O_RDWR-without-truncate-without-append `FileMode`, so the naive "append then seek-patch the header" won't work.** `FileMode.write`/`writeOnly` truncate; `FileMode.append`/`writeOnlyAppend` are `O_APPEND`, which on POSIX forces every write to EOF and **ignores `setPosition`** — so `setPosition(4)` + `writeFrom` to patch the RIFF/data-size fields silently lands at end-of-file instead. The header patch (step 3) needs a deliberate approach: precompute all sizes (they're all known up front — `draftLen-44`, silence, `nextLen-44`) and patch the 8 header bytes with a *non-append* handle, or do the body append and header patch as two distinct operations with the right mode. The naive version can pass a quick smoke test while shipping a broken/understated header.
2. **The header patch is load-bearing because the default output format is WAV** (`preferences.dart:208`, `audioSaveFormat` defaults to `'wav'`), and `_finalizeDraft` (:1363) only **renames** the draft — it never rewrites the header. So for the default path a stale/understated `data` size truncates player playback. (For `m4a` users it's moot: `_transcodeWavToM4a` (:1501) reads everything past offset 44 and ignores the header — which is why the next point has gone unnoticed.)
3. **Fix the pre-existing `_stitchSilence` stale-header bug in the same place.** `_stitchSilence` (:1328) **already appends silence to WAV drafts via `FileMode.append` without patching the header**, then only updates the `.meta`. So a WAV-format draft whose last pre-finalize mutation was a silence stitch already finalizes with an understated header today. The streaming rewrite of `_stitchWav` should share a header-patch helper that `_stitchSilence` also calls, closing both at once. (`_stitchWav` currently masks this by regenerating a full correct header via `_generateWavHeader` — but only when a WAV stitch *follows* the silence stitch.)
4. **`_transcodeWavToM4a` (:1501) has the same whole-file `readAsBytes`** and can OOM independently on the finalize path — though it *views* (not copies) past offset 44, so its peak is 1× not 2×. Worth a glance while in there; not the OOM driver.

#### Relevant files
- `app/lib/services/recordings_manager.dart` — `_stitchWav` (`:1557`, the in-memory read/combine/write), `_performStitch` (`:1533`, catch → `_finalizeDraft` fallback to keep), `_stitchSilence` (`:1328`, already appends without a header patch — fix in the same helper), `_stitchBinIfPresent` (`:1620`, whole-bin `readAsBytes` append), `_finalizeDraft` (`:1363`, unchanged fallback — renames only, no header rewrite), `_generateWavHeader` (`:1724`, offsets 4/40 for the patch), `_transcodeWavToM4a` (`:1501`, same whole-file read, 1× peak), `_mergeMeta` / `_reanchorMarkerEdls` (post-write steps that must gate on verified append).
- `app/lib/backend/preferences.dart` — `audioSaveFormat` (`:208`, defaults to `'wav'`; why the header patch is load-bearing).

---

### 3. Diagnostic event log — persistent (reboot-surviving) upgrade [small] [Pending — post-LittleFS]

The event log itself **shipped** in firmware `oo-2.8.0` / app 0.31.x (volatile RAM ring, GATT
`0x0063`/`0x0064`, capability bit `1<<12`, dev-tools toggle). Record format and event codes live in
`omi/firmware/omi/src/lib/core/diag_log.h`; the wire protocol is in CLAUDE.md's Diagnostics-service
row. What remains is its one known limitation: **a reboot loses the log** (mostly covered by the
reset-cause char `0x0061`).

If reboot-survival is later needed, promote the ring to a persistent CRC'd log in the ring backend's
**already-reserved metadata sectors 81–255** (`sd_ring.h:30-33,69` — 128 KB, never touched by audio,
DFU-proof because DFU never addresses the SD NAND), reusing the ring cursor's torn-write pattern
(per-sector CRC, highest valid seq wins, discard torn tail on boot; `sd_ring.h:35-42`).

**Also closed by LittleFS removal:** IDEAS entry 7 — an OTA that loses `storage_backend` currently
reformats the SD card, which one backend makes impossible.

**Why it waits for LittleFS removal:** the reserved sectors exist only on the ring backend, so doing
it now means backend asymmetry (a persistent log on ring, volatile on LittleFS) plus torn-write
handling for both. Once LittleFS is gone it's a clean single path. Removing LittleFS also lets
`SD_WORKER_STACK_SIZE` shrink further with confidence — the ring path's shallow ~2.7 KB peak becomes
the true ceiling instead of LFS's deep allocator-scan/GC/format paths — freeing RAM for a deeper ring.

---

### 5. Mic rail (PDM_EN) is not driven by firmware [small] [Pending — awaiting field evidence]

**Status: deliberately reverted in `oo-2.8.5`. Revisit only if the mic still drops.**

The firmware no longer touches PDM_EN (P1.4), the enable for the T5838 mic + TXS0104 level-shifter
rail. The pin is left in its reset state — input, disconnected — and a board pull-up holds it high,
so the mic simply always has power. That is how it worked for the project's whole life until
`oo-2.6.0`.

#### Why it was reverted

The mic had **never** frozen. Then:

| Date | Version | Change |
|---|---|---|
| 2026-03-13 | 3.0.15 | `mic.c` has no GPIO code at all — PDM_EN untouched |
| **2026-07-17** | **oo-2.6.0** | `530b23140` cuts PDM_EN in `mic_off()`; `6c84bc5ff` restores it in `mic_on()` — **first time firmware ever drove the pin** |
| 2026-07-28 | oo-2.8.0 | `aa503aa43` adds `mic_reset()`, power-cycling the rail on button gestures |
| 2026-07-28 | oo-2.8.0 | first recorded mic freeze (BLE_Research.md, Wedge 4 companion) |
| 2026-08-02 | oo-2.8.2/4 | ~2 h of lost audio; recovered only when a Priority Recording called `mic_reset()` |

Eleven days between the firmware first driving that rail and the first freeze, on a device that had
never had one. Nothing else in the mic path changed. `mic_reset()` is **not** implicated in the
first freeze — it was committed at 20:15 UTC on 07-28, after the log that recorded it.

So the leading hypothesis is that **driving PDM_EN is what made the mic freezable**, which would
make `mic_reset()`'s power cycle a cure for a disease the same subsystem causes. Removing every
driver of the pin isolates that variable.

#### What this costs

- **~1 mA leak in ship mode.** `530b23140` cut the rail so the mic + shifter fully power down in
  System OFF; without it they stay powered off a 150 mAh cell. That is the price of the experiment.
- **`mic_reset()` can no longer clear a wedged T5838.** It is a dmic re-trigger now, which by its own
  prior comment does not recover the part. The seven call sites are kept precisely so the cycle is
  one small edit away.
- **No post-update rail cycle.** The `oo-2.8.5` fix for the "silent after a flash" case is gone with
  it, along with `app_settings_firmware_version_changed()` / `..._mark_firmware_version_booted()` and
  the `last_boot_fw` NVS key. `DIAG_MIC_POWER_CYCLE` (code 17) stays reserved and the app still
  decodes it, so restoring needs no protocol change.

#### How to tell whether this worked

`DIAG_VAD_LEVEL` (code 16) is the instrument, added in the same release. It reports the AAD input
level as a 5-minute peak-hold on a silent↔non-silent transition or hourly:

- **peak pinned at 0 across consecutive windows** ⟹ the mic is still wedging without anything driving
  PDM_EN ⟹ this hypothesis is wrong, and the rail cycle should come back as the only known cure.
- **no zero-peak windows over a few days of normal use** ⟹ the freezing tracked the firmware driving
  the rail, and it should stay untouched.

#### If it needs to come back

Restore in this order, smallest first, and re-test between each:

1. `mic_reset()`'s cycle alone (the wedge cure, button-triggered) — `mic.c`, plus `void` → `bool`.
2. The post-update cycle in `main.c` and the settings version tracking.
3. `mic_off()`'s ship-mode cut (the ~1 mA saving) — **last**, and only with `turnoff_all()`'s
   bail paths still rebooting, since that cut is what strands the rail when a shutdown fails.

Also unexplained and worth keeping in view: the 2026-08-02 freeze survived a DFU reset **and** a
System-OFF wake. A SoC reset returns PDM_EN to an input, so the pull-up should have re-powered the
rail either way. Either something else is also going on, or that model of the reset behaviour is
wrong. A scope trace on PDM_EN across a reset would settle it.

**Related, untouched:** `pdm_thsel_pin` (P1.5) is declared in the board DTS and never referenced by
any code, so the T5838's AAD threshold-select input runs at its default. Deliberately left alone —
it was never driven, and the whole point here is to stop changing things that were not changed
before.

#### Relevant files

- `omi/firmware/omi/src/mic.c` — the `pdm_en` comment block records the decision at the point of use
- `omi/firmware/omi/src/lib/core/mic.h` — `mic_reset()` contract
- `omi/firmware/omi/src/aad.c` — `DIAG_VAD_LEVEL` emit (`VAD_DIAG_LEVEL_WINDOW_MS`)
- `omi/firmware/boards/omi/omi_nrf5340_cpuapp.dts` — `pdm_en_pin`, `pdm_thsel_pin`
- `BLE_Research.md` — "Wedge 4 companion finding" for the first freeze

---

### 6. Offer a re-pair when an OTA eats the bond [small] [Pending]

Roughly **1 OTA in 8** silently drops the BLE pairing — see `BLE_Research.md` §9: the settings NVS
sits inside the MCUboot primary slot, and overwrite-only-FAST erases one of its eight sectors on
every update. Whichever key's live copy is in that sector is lost, and bonds are rewritten rarely
enough to sit still between flashes.

The definitive fix is a partition move, and it **cannot ship over the air**: MCUboot is not
OTA-updatable here (`SB_CONFIG_MCUBOOT_UPDATEABLE_IMAGES=2` covers the app and net cores only), so
the installed bootloader keeps writing its trailer at `0x100000` no matter what the new app image
believes. Wired flash only. Until that happens, the user-facing problem is not the loss — it is
that the loss is *opaque*: the device connects and drops every few seconds, forever, with nothing
explaining why. On 2026-08-02 that took ~26 minutes to work out by hand.

#### What does NOT work, and why

**Reading `DIAG_BOND_STATE` from the device.** The obvious idea, and it cannot fire. `0x0063` is
`BT_GATT_PERM_READ_ENCRYPT` (deliberately — forced boot records put `transport_bond_count()` behind
it, and unauthenticated peers must not learn pairing state). The failure being detected *is*
encryption failing, so the characteristic is unreadable exactly when it matters. It only reads
after a successful re-pair, which is forensics, not a prompt. The drain is also gated on the
`diagLogEnabled` dev pref and needs a `CONFIG_OMI_DIAG_LOG` build.

**A general stale-bond self-heal.** `OmiBleForegroundService.kt:964-970` already has one, disabled,
because intercepting status 5 sabotages Android's own security elevation. Widening it to 8/133 is
worse — those dominate ordinary RF trouble.

#### What does work

Detect the signature app-side, which needs nothing encrypted:

```
connect succeeds → service discovery completes (15 services)
→ every encrypted read fails (133 / Rejected) → drop within seconds → repeats
```

This is specifically **not** the marginal-RF signature: in the 2026-08-02 overnight range episode
discovery itself failed or took 6–11 s, whereas here discovery completes cleanly and only the reads
fail. That distinction is what keeps the false-positive rate low enough to act on.

**Scope it to the post-DFU window** rather than running a general detector. The app knows when it
just flashed; arm a one-shot "watch the next connect" flag on DFU success, and if that connect shows
the signature, surface *"Pairing may have been lost during the update — re-pair?"* → `removeBond()`
+ reconnect. Bounded window, near-zero false positives, and it targets the 1-in-8 directly.

Keep the destructive action **user-confirmed**. That is the whole difference between this and the
disabled status-5 self-heal above.

#### Relevant files

- `app/lib/pages/dfuota/firmware_mixin.dart` — DFU success callbacks; where the one-shot arms
- `app/lib/providers/device_provider.dart` — `_onDeviceConnected` / setup failure path
- `app/android/.../OmiBleForegroundService.kt:964-970` — the disabled self-heal, and why
- `BLE_Research.md` §9 — root cause, the wired-flash fix, and the two dead ends

---

### 7. An OTA that eats `storage_backend` wipes the SD card [small] [Pending — closes itself with LittleFS removal]

**Do not build a guard for this. Sync before flashing, and let LittleFS removal delete it.**

Same mechanism as entry 6 and `BLE_Research.md` §9 — one NVS sector erased per OTA, ~1 flash in 8
for any rarely-rewritten key — but the consequence is data loss rather than a re-pair:

```
omi/storage_backend lost in the sector erase
  → app_settings_get_storage_backend() falls back to DEFAULT_STORAGE_BACKEND (LittleFS)
  → card is actually ring-formatted
  → lfs_mount() fails (no LFS superblock)
  → boot mount has allow_format = true
  → lfs_format()  ← every unsynced recording is gone
```

`sd_card.c` narrates it: *"LFS mount failed — existing data on SD will be ERASED by format"*.
Symmetric: a LittleFS card on a device that lost the key while set to ring hits `sd_ring_format()`.

`sd_ring.c` already defends the *other* direction — when a partial tail sector is unreadable it
refuses to fail the mount precisely because "the caller would fall back to LittleFS and
lfs_format() the volume, wiping every…". The NVS-loss route into the same place was never
considered.

#### Why no fix

Removing LittleFS deletes the failure mode outright: no second backend means no
`storage_backend` key to lose, no `DEFAULT_STORAGE_BACKEND` fallback, and no mismatch path. A
guard written now is dead code the day that lands.

The interim mitigation is operational and free: **sync before flashing.** Only unsynced audio is
at risk, and flashing is a deliberate act — a drained card can be reformatted at no cost.

#### The fix, if the gap turns out to be long

Only worth building if LittleFS removal stalls *and* flashes with unsynced audio become routine.
Make the card authoritative for its own layout and NVS merely advisory: before either branch
formats, probe the other backend. `sd_ring_mount()` is already a safe read-only probe — one header
sector, magic + CRC32, `-ENOENT` if it is not a ring. If the other backend mounts, the setting was
lost rather than the data: adopt it and re-persist `storage_backend`. Costs one sector read on a
mount that was about to fail anyway, and inverts the trust the right way round — the bytes on the
card know what they are; a 32 KB NVS partition sitting inside the bootloader's erase path does not.

**Not a candidate: flipping `DEFAULT_STORAGE_BACKEND` to ring.** It only moves the bullet — a
LittleFS device that lost the key would then hit `sd_ring_format()` instead.

#### Relevant files

- `omi/firmware/omi/src/sd_card.c` — `sd_mount()`, the `ring_active()` branch and the `lfs_format()` fallback
- `omi/firmware/omi/src/sd_ring.c` — `sd_ring_mount()`, the read-only probe
- `omi/firmware/omi/src/settings.c` — `DEFAULT_STORAGE_BACKEND`
- `BLE_Research.md` §9 — the NVS-erase mechanism and why the real fix needs a wired flash

---

## LARGE

### 4. Device-driven BLE wake (firmware + iOS) [large] [Parked — lost its primary motivation]

> **Parked 2026-07-31, when iOS support was removed** (see NOTES.md). By this idea's own
> framing it was "mostly an iOS project" — the payoff was reliable iOS background wake, and
> Android already wakes reliably via FGS + exact alarm + WorkManager. With no iOS target,
> **the entire phone-side half (§iOS app changes) has no consumer**, and on Android the
> windowing is a straight regression (it breaks instant on-demand connect, which is exactly
> why `enabled` defaults to OFF for Android).
>
> **What survives the removal:** the *privacy / going-dark* motivation below is
> platform-independent — an always-advertising audio recorder is trackable by any passive
> scanner regardless of which phone syncs it. That argument stands on its own and needs only
> the firmware half (dark state + window scheduler + button-to-wake), not the iOS work. If
> this is ever revived for that reason, read it as a firmware-only idea and treat every iOS
> section as historical. Kept in full because the firmware design and its tradeoffs are
> still sound, and because restoring iOS restores the original case.

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
- **Firmware (`transport.c`, `aad.c`):** idle-disconnects after 15 s of no storage GATT activity (`idle_disconnect_work_handler`, `IDLE_DISCONNECT_TIMEOUT_MS`), then reverts to advertising. Two **always-connectable** modes: fast (`BT_LE_ADV_CONN`) and slow (`adv_param_slow`), via `transport_set_adv_fast/slow()`. **AAD currently owns advertising cadence** (recording → fast `aad.c:340`, silence → slow `aad.c:360`). Conn params 7.5–22.5 ms, **latency 0** (`update_conn_params`); iOS recheck falls back to 15–30 ms. Audio records to SD **independent of BLE** — nothing lost while dark/disconnected.
- **iOS (`OmiBleManager.swift`, `device_provider.dart`):** state restoration *is* wired (`CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState` → `onStateRestored`), **but the aggressive disconnect neutralizes it**: `disconnectDevice(isManual: true)` (`device_provider.dart`, post-sync + pause-grace) → `disconnectPeripheral` adds to `manuallyDisconnected` + cancels the link, and `didDisconnectPeripheral` re-arms `connect()` *only if not manual*. Steady state = no pending connect = nothing for iOS to wake on.
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
3. **Hand advertising ownership from AAD to the scheduler** — keep AAD's VAD/SD-pause logic; remove/gate its `adv_*_req` writes (`aad.c:340,360,520`, applied in the AAD loop `aad.c:277-279`). Most invasive *refactor*; regression-test VAD recording, SD pause/resume, marker durability.
4. **Gate windows on "has unsynced data"** — use "SD has stored files" as the proxy (app deletes via `CMD_DELETE_FILE`); SD empty → stay DARK until new audio is recorded.
5. **Config characteristic + user-facing "Dark Mode" toggle (default OFF)** — put it in a **new service registered last** (next free prefix after the LED service `0080`, e.g. `0090`), **not** a new Settings characteristic: Settings is registered first, so every char added there renumbers the handles of storage/diagnostics/mute/LED and costs a re-pair (see CLAUDE.md's Settings row — adding `0015`/`0016` already cost one, which is exactly why the LED service went last). Payload: `interval_minutes(u16) + window_seconds(u8) + enabled(u8)` (+ optional `next_override_seconds(u16)` for app-side policy nudges), persisted via `settings.c`, range-validated, with a **compiled-in default** (`config.h`) as the floor for a never-configured device. Surfaces in the app as a single **Dark Mode** switch (writes `enabled=1`). **Cadence reuses the existing "Auto Sync Interval" dropdown** (`app_settings_page.dart`: 15/30/60 min / Manual Only) — no new cadence setting; the user's existing `backgroundSyncIntervalMinutes` drives the *device's* cooldown. **"Manual Only" (`-1`) maps to button-only wake** — firmware opens *no* scheduled windows, only the button window. The app **re-pushes config on every connect** (belt-and-suspenders: the device never holds stale config; the dropdown is the source of truth). Firmware default is `enabled=0` = today's always-connectable behavior (old apps and Android untouched). `enabled=1` activates DARK/window cycling. See "Cross-platform: why windowing is opt-in" below.
6. **Capability bit** — add `deviceDrivenSync` to the Features bitfield (`0021`, `OmiFeatures`) for mixed-version safety (new app + old fw → old timer path; old app + new fw → covered by #7).
7. **On-demand connectability + recovery floors (critical UX safeguard, see "Button-to-wake" below)** — button/motion triggers open a window immediately. Plus two recovery behaviors so the device can't strand itself:
   - **Boot:** on reboot, **advertise connectably (like `enabled=0`) until the phone connects and writes config at least once, then resume the persisted dark schedule** — re-anchoring `last_disconnect` to that fresh contact so there's no post-reboot blackout (the phone's standing pending-connect latches the moment the device advertises). **Cap the stay-open at ~15 min:** if the phone never shows (rebooted away from the phone), fall back to the persisted last-known config and resume dark scheduling so continuous advertising doesn't drain the 150 mAh cell.
   - **Liveness floor:** no successful sync for `> N` intervals → fall back to continuous connectable advertising so the device can't become permanently unreachable.
8. **(Alternative model) Held low-power connection** — instead of windowing, set **slave latency > 0** in `update_conn_params` + a "data ready" notify characteristic (the CGM model). Lower wake latency, simpler app logic, but the radio stays in-connection (more device power than DARK). Default to windowed for the 150 mAh budget; keep this in reserve.

#### Button-to-wake (user-selectable, integrates with existing button mapping)
The on-demand trigger (#7) is a natural fit for the **already-shipped customizable button-mapping system** (firmware char `0015` under the Settings service + `button_action_t` in `button.h`; `button_config_page.dart` in app — maps one action per gesture slot across single/double/triple tap and their holds, synced over the encrypted value-validated config char). Add a **new "Wake for Sync" action** to that action set:
- Firmware: on the mapped gesture, `button.c` kicks the sync-window scheduler straight to SYNC WINDOW (open a connectable window now), regardless of cooldown.
- App: expose "Wake for Sync" as a selectable action in `button_config_page.dart`; **default to single tap**, but user-customizable exactly like every other mapping (open to making it single tap out of the box or fully user-selectable — both are supported by the existing infra). Note the app now holds **two** per-mode configs (`buttonConfigManual`/`buttonConfigAuto`) and pushes the active one — the new action has to be valid in both, or explicitly mode-scoped.
- Firmware must range-accept the new action value: `button_action_t` currently tops out at `BUTTON_ACTION_RECORD_TOGGLE = 6` and the write handler rejects anything higher, so the new action is `7` and that bound moves with it.
- UX: foreground "Sync now" prompts "tap your Omi to sync now" when the device is DARK between windows.

#### Decoupling wake from sync (a connection is not a sync)
A device wake — scheduled window *or* button combo — only establishes a **connection**; the **app** then decides whether to pull data. Two clean concerns:
- **Device** = *make a connection possible*: open a window on its RTC cadence (config-char interval) + immediately on the button combo.
- **App** = *policy*: on each device-initiated connection, decide whether to sync.

The building block already exists: `_onStateRestored` runs `final due = _shouldSyncNow(); if (!due) return;` (`device_provider.dart:276`) — "connection arrived, skip if not due." Generalize into a setting:
- **"Sync on every device wake"** → always pull whenever the device wakes/connects.
- **"Only when due"** → gate on the autosync interval (`_shouldSyncNow()`); an early wake connects, finds nothing due, and disconnects without transferring.

**Recommended semantics:** a *scheduled* window honors the setting (default "only when due"); a *button combo* is explicit user intent → **force-sync** (always pull), since the user tapped precisely to sync now. Make force the button's natural behavior; optionally expose the choice.

**Telling the two apart on connect.** The app can't receive the button event *before* it connects (the tap is what wakes it), so the reason can't arrive over the button trigger char (`23ba7925`) in time. Add a **"last wake reason" byte the app reads on connect** (scheduled / button / motion) — cheapest as a second characteristic on the new dark-mode service (#5), which avoids touching the fixed-length diagnostics char `0061`; on `onDeviceReady` the app maps button ⇒ force-sync, scheduled ⇒ if-due. **This byte is load-bearing even in `enabled=0` mode:** the "tap arrives live over the button char instead" fallback does not exist today — `transport_notify_button_state()` is defined in `transport.c` but never called, so the firmware pushes no tap events at all and the app's button listener is inert (see CLAUDE.md's Button-service row). Either read the wake-reason byte or wire up that notify; don't assume the live path works.

**Battery note:** align the device's window cadence with the app's autosync interval (push via the config char) so early "connect-then-skip" cycles are rare; the if-due check mainly backstops button taps and edge timing — a connect/disconnect with no transfer still costs a little device radio energy.

#### iOS app changes (the real payoff)
1. **Standing pending-connect** — after routine sync/disconnect, **re-arm `centralManager.connect(peripheral, options:nil)`** instead of leaving it cancelled, so iOS holds it pending and wakes the app at the device's next window. Add a `standingConnect: Set<String>` alongside `manuallyDisconnected`; distinguish "Forget Device" (truly cancel) from "routine post-sync disconnect" (cancel link, re-arm pending connect). **Also re-arm on app launch** — a user force-quit drops the OS-held pending connect, so re-issuing `connect()` at startup (iOS: `retrievePeripherals(withIdentifiers:)` with the saved device ID; Android: `connectGatt(autoConnect=true)` with the saved address) restores the wait that force-quit destroyed. Note this only re-arms the wait — it can't connect a *dark* device until its next window or a button tap; for an immediate post-relaunch sync the user taps the button (or the staleness banner, #5).
2. **Routine disconnect ≠ terminal in Dart** — the post-sync and pause-grace `disconnectDevice(isManual: true)` sites in `device_provider.dart` map to a new "disconnect-but-stay-armed" path (`disconnectKeepingPendingConnect`), not `unmanageDevice`. Only true unpair calls full `unmanageDevice`/`disconnectPeripheral`.
3. **Wake → sync** — mostly there: the wake arrives as `didConnect` → `onDeviceReady` → `_handleDeviceConnected`; ensure the background drop-guard lets a device-initiated wake through (set pending-sync flag, as `_onBackgroundSyncRequested` does). `_onStateRestored` (`device_provider.dart:276`) already sanctions a due sync.
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
- `omi/firmware/omi/src/lib/core/transport.c` — `idle_disconnect_work_handler` (`:1540`, 15 s), `transport_set_adv_fast/slow` (`:2397`) + `adv_param_slow`, `_transport_disconnected` (adv restart), `update_conn_params` (`:1886`, latency 0); add dark state + window scheduler.
- `omi/firmware/omi/src/aad.c` — `adv_slow_req`/`adv_fast_req` writes (`:340,:360,:520`) and the apply loop (`:277-279`) to hand advertising ownership to the scheduler.
- `omi/firmware/omi/src/lib/core/settings.c` / `settings.h` — persist the window config (mirror `app_settings_save_conn_fail`).
- `omi/firmware/omi/src/lib/core/button.c` + `button.h` (`button_action_t`, ceiling `BUTTON_ACTION_RECORD_TOGGLE = 6`) and the config char `0015` under the Settings service (`transport.c:163,201`) — add the "Wake for Sync" action; kick the scheduler on the mapped gesture.
- `app/ios/Runner/OmiBleManager.swift` — `manuallyDisconnected`/`disconnectPeripheral`/`didDisconnectPeripheral`/`willRestoreState`; add `standingConnect` + pending-connect re-arm.
- `app/ios/Runner/AppDelegate.swift` — keep `BGProcessing`/`BGAppRefresh` as backstop.
- `app/lib/providers/device_provider.dart` — the `disconnectDevice(isManual: true)` sites (post-sync / pause-grace / unpair; grep the symbol — they move), `_onStateRestored` (`:276`, already does the "skip if not due" gate to generalize), `_shouldSyncNow()`, `_onBackgroundSyncRequested` (`:252`); apply the wake→policy decision (force vs if-due) on device-initiated connect.
- `app/lib/backend/preferences.dart` — add the "sync on every device wake" vs "only when due" setting (alongside `backgroundSyncIntervalMinutes`).
- Firmware "last wake reason" — expose a 1-byte read (scheduled/button/motion) via a new char or folded into diagnostics `0061` (`transport.c`), read by the app on `onDeviceReady` to pick force-sync vs if-due.
- `app/lib/services/devices/transports/native_ble_transport.dart` — add `disconnectKeepingPendingConnect`; `app/lib/pigeon_interfaces.dart` for the new host API + the window-config write.
- `app/lib/pages/settings/button_config_page.dart` — expose "Wake for Sync" as a selectable button action (default single tap).
- `app/lib/pages/settings/app_settings_page.dart` — add the **Dark Mode** toggle (writes `enabled`); the existing "Auto Sync Interval" dropdown (15/30/60 / Manual Only, ~`:190`) already supplies the cadence — Manual Only = button-only. The staleness banner lives wherever sync status surfaces (home/recordings).
- Android (phase 3, optional): `OmiBleForegroundService.kt`, `BackgroundSyncWorker.kt`, `SyncAlarmReceiver.kt`.

---
