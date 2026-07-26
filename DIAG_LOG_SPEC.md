# On-Device Diagnostic Event Log — Design Spec

**Status:** IMPLEMENTED (2026-07-25, firmware `oo-2.8.0` / app 0.31.x). Firmware:
`omi/firmware/omi/src/lib/core/diag_log.{c,h}`, Kconfig `OMI_DIAG_LOG`, BLE
`0x0063`/`0x0064` + feature bit `1<<12` in `transport.c`, instrumentation in
`sd_card.c` / `transport.c` / `codec.c`, stack reclaim in `sd_card.c`. App:
`diag_log_record.dart`, drain/ack/enable in `omi_connection.dart`, push+drain in
`device_provider.dart`, Debug Tools UI in `sync_page.dart`, pref `diagLogEnabled`.
Deviation from §5.5: this fork ships a single build config, so `CONFIG_OMI_DIAG_LOG=y`
lives in `omi.conf` (still runtime-gated OFF by default). §5.4 scoped: codes 9–11
(write-blocked / ring-io-error / backend-mount) are defined but not yet instrumented
(no single counter site). Original hand-off doc preserved below.
**Author context:** Written 2026-07-25 after a design conversation. Repo: `omi-offline`.

---

## 1. Problem

The firmware exposes ~19 cumulative drop/health **counters** over BLE (`0x19B10062`, see
`transport.c` `diagnostics_drops_pack()` around line 504, layout documented at
`transport.c:440-464`). These are aggregate-since-boot counts. They tell you *how many* empty-bin
rotations / marker drops / pause-gate saves happened, but **not when, in what order, or why**. To
recover the "why" today you correlate counter deltas across two connects, or attach an RTT probe —
neither is available to a normal user in the field.

Concrete driving case: **`empty_bin_rotations`** (the on-device fingerprint of a lost Priority
Recording — a bin opened at a rotation boundary whose force-captured audio was dropped before it
landed). The counter says "1 happened since boot" (see the attached Debug Tools screenshot: *Empty
bin rotations = 1*). It cannot say which recording, at what uptime, or whether the audio was lost at
the SD queue, the codec, or the `sd_write_paused` gate. Those causes live in *separate* counters, so
"why" is always an inference.

**Goal:** a lightweight on-device event log that captures per-event records (with timestamp + cause
context), ships them to the phone on connect, and clears itself — so field diagnosis needs no RTT.

## 2. Hard constraints (from the design conversation — do not relax without asking)

1. **Zero filesystem interference.** Must not corrupt, overwrite, or be overwritten by the audio
   filesystem (LittleFS or the ring backend). This is the strongest requirement.
2. **Very little RAM — ideally zero in production.** The device is RAM-constrained (there's a
   documented history of SD-queue/codec RAM tuning; see `codec.c:81`).
3. **Ships to phone + deletes itself on connect**, without losing or overwriting un-sent records if a
   transfer is interrupted.
4. **Gated behind a dev-tools toggle — "not always running."** Off by default; only active when a
   developer enables it on the bench.

## 3. Chosen design (one paragraph)

A **volatile, RAM-resident, binary event ring**, drained over a **new BLE characteristic** with an
**ack-gated clear**, compiled into **dev/internal builds only** (`CONFIG_OMI_DIAG_LOG`), and
runtime-gated by a **capability-checked dev-tools toggle** that pushes an enable bit on connect
(default OFF, not persisted). The ring's RAM is **reclaimed from the SD worker thread's oversized
stack**, so the feature is RAM-neutral in dev builds and costs **zero bytes + zero code in
production**.

This is "Option B" from the design discussion. Alternatives and why they lost are in §11.

## 4. Why RAM-from-the-SD-worker-stack works

- `SD_WORKER_STACK_SIZE = 12288` (12 KB), `sd_card.c:446-448`.
- **Measured peak usage: 2.7 KB / 12 KB** (Debug Tools screenshot, `sd_worker_stack_used`, exposed at
  `0x0062` offset 68 via `sd_get_worker_stack_used()`, `sd_card.c:3071-3076`). ~9 KB idle.
- **Precedent:** `codec.c:81` — *"23096 = old 19000 + the 4 KB reclaimed from SD_WORKER_STACK_SIZE
  (16384→12288)."* The SD worker stack was already shrunk once and its headroom handed to another
  thread. We do the same again.

**Mechanism (do NOT put the buffer on the stack).** The ring is a `static` `.bss` array with a
spinlock, because events are enqueued from *multiple threads* (sd_worker, button, aad) and a thread
cannot safely write another thread's stack. "Take RAM from the stack" is realized by **shrinking
`SD_WORKER_STACK_SIZE` by the ring size when the feature is compiled in**, so the total budget is
unchanged:

```c
/* sd_card.c */
#if defined(CONFIG_OMI_DIAG_LOG)
  #define DIAG_LOG_RING_BYTES 2048                       /* 128 records * 16 B */
  #define SD_WORKER_STACK_SIZE (12288 - DIAG_LOG_RING_BYTES)   /* 10240 -> 7.5 KB headroom over 2.7 KB peak */
#else
  #define SD_WORKER_STACK_SIZE 12288                     /* production: unchanged, no ring */
#endif
```

Net: dev = 10240 stack + 2048 ring = 12288 (identical to prod's 12288 stack + 0 ring). Production
compiles the ring out entirely — no `.bss`, no code.

**Caveat for the implementer:** the 2.7 KB peak was measured on the **Ring** backend. LittleFS paths
(allocator scan / `lfs_fs_traverse` / GC / format) can be deeper. Until LittleFS is removed (§10),
verify the sd_worker peak on a **near-full LittleFS card** before trusting the reduced stack — or keep
`DIAG_LOG_RING_BYTES` conservative. 7.5 KB headroom over the observed ring peak is comfortable, but
confirm LFS worst-case. After LittleFS removal the ring path's shallow peak is the true ceiling and the
stack can be shrunk further with confidence.

## 5. Firmware design

### 5.1 New module: `diag_log.c` / `diag_log.h` (under `omi/firmware/omi/src/lib/core/`)

Everything behind `#ifdef CONFIG_OMI_DIAG_LOG`; provide no-op `static inline` stubs in the header for
the disabled build so call sites compile unconditionally with zero cost.

**Record (16 bytes, packed, little-endian on the wire):**

```c
typedef struct __packed {
    uint32_t seq;        /* monotonic, assigned at enqueue; ack/drain key */
    uint32_t uptime_ms;  /* k_uptime_get_32() at the event */
    uint8_t  code;       /* diag_event_code_t (see table) */
    uint8_t  backend;    /* 0 = littlefs, 1 = ring (sd_get_active_backend()) */
    uint16_t arg0;       /* event-specific */
    uint32_t arg1;       /* event-specific */
} diag_event_t;          /* 16 bytes */
```

`seq` is u32: at any realistic event rate it never wraps in device lifetime, so ack logic needs no
wrap handling.

**Ring:** `static diag_event_t ring[DIAG_LOG_RING_DEPTH];` (default depth 128 = 2 KB). Head/tail
indices, a `dropped_count` (u32), and a `uint32_t next_seq`. **Keep-newest wrap:** when full, overwrite
the oldest un-acked record and `dropped_count++`. Rationale: the newest events are the ones you're
debugging; the phone connects often enough that wrap is rare.

**Concurrency:** a single `struct k_spinlock`. `diag_log_event()` takes it, stamps seq+uptime, writes
one slot, releases. O(1), no NAND, no context switch — safe to call from any thread including ISR-ish
contexts if needed (spinlock, not mutex). **Never** do a synchronous NAND write here — that would
inject latency into the audio path and risk causing the very drops you're measuring (observer effect).

**Enable gate:** `static atomic_t diag_enabled;` First line of `diag_log_event()`:
`if (!atomic_get(&diag_enabled)) return;` — one relaxed read, so a disabled log costs a single
predictable branch at each call site.

### 5.2 API surface (`diag_log.h`)

```c
void     diag_log_init(void);                       /* zero state; enabled=false */
void     diag_log_set_enabled(bool on);             /* dev-tools toggle target */
bool     diag_log_is_enabled(void);
void     diag_log_event(uint8_t code, uint8_t backend, uint16_t arg0, uint32_t arg1);

/* Drain: snapshot-based, offset-addressable so the phone can GATT Long-Read the whole
 * ring as one stable blob. On first read at offset 0, snapshot head so records don't
 * shift mid-transfer; serve packed records from the snapshot for subsequent offsets. */
size_t   diag_log_drain(uint8_t *out, size_t max, uint16_t offset);  /* bytes written */
uint32_t diag_log_max_seq(void);                    /* highest seq in current snapshot */
void     diag_log_ack(uint32_t through_seq);        /* drop all records with seq <= through_seq */
uint32_t diag_log_dropped_count(void);
```

Disabled-build stubs: `diag_log_event` → `((void)0)`, getters → 0, etc.

### 5.3 Event code table (append-only, like the drop counters — never renumber)

| code | name | arg0 | arg1 |
|---|---|---|---|
| 0 | `DIAG_RESERVED` | — | — |
| 1 | `DIAG_EMPTY_BIN_ROTATION` | backend | `current_file_size` (bytes in the empty bin) |
| 2 | `DIAG_MARKER_WRITE_DROP` | marker header low16 | uptime or marker payload hint |
| 3 | `DIAG_MARKER_PAUSE_GATE_SAVE` | marker header low16 | block len |
| 4 | `DIAG_PRIORITY_RECORD_START` | — | session_id |
| 5 | `DIAG_PRIORITY_RECORD_STOP` | — | session_id |
| 6 | `DIAG_SESSION_END_MARKER_EMIT` | — | session_id |
| 7 | `DIAG_SD_BLOCK_DROP` | sd_msgq depth | `last_drop_uptime` delta |
| 8 | `DIAG_CODEC_DROP` | — | ring-full count snapshot |
| 9 | `DIAG_WRITE_BLOCKED` | recovery cycle | errno |
| 10 | `DIAG_RING_IO_ERROR` | tag (1=write/2=read/3=sync) | errno |
| 11 | `DIAG_BACKEND_MOUNT` | backend | ms taken / result |

Extend by appending. The app keeps the matching decode table; unknown codes render as
`code=<n> arg0=.. arg1=..` so a newer device against an older app still shows *something*.

### 5.4 Instrumentation sites (add one `diag_log_event(...)` line each)

Confirm exact lines at implementation time; anchors as of this writing:

- **Empty bin, LittleFS** — `sd_card.c:1703-1705` (next to `atomic_inc(&empty_bin_rotations)`).
- **Empty bin, ring** — `sd_card.c:3136-3138`.
- **Pause-gate save** — `sd_card.c:845-846` (`atomic_inc(&marker_pause_gate_saves)`).
- **Priority start / stop** — `button.c` `write_priority_recording_marker_to_storage()` /
  `aad.c` `write_session_end_marker_to_storage()` (see CLAUDE.md C↔Dart marker table).
- **Marker write drop / block drop / codec drop / ring IO error / write-blocked** — co-locate with the
  existing counter increments (`grep` the counter names from `transport.c:440-464`).

Keep these to a single cheap call each. Do not add formatting or allocation at the sites.

### 5.5 Kconfig

`omi/firmware/omi/Kconfig`:

```
config OMI_DIAG_LOG
    bool "On-device diagnostic event log (dev/internal builds only)"
    default n
    help
      Static RAM event ring drained over BLE 0x0063/0x0064. RAM is reclaimed
      from SD_WORKER_STACK_SIZE. Leave OFF for production.
```

Enable it in the dev/internal build config (the `.conf` used by `app/build.sh`'s firmware step /
dev flavor), NOT in the base `omi.conf`.

## 6. BLE / GATT protocol

Add two characteristics to the **existing Diagnostics service** `0x19B10060`
(`transport.c:465-470`), alongside `0x0061` (reset cause) and `0x0062` (drop counters):

- **`0x19B10063` — diag-log read (drain).** Long-readable. Layout:
  ```
  [u8  record_size = 16]
  [u8  reserved]
  [u16 record_count]        # records in this snapshot
  [u32 dropped_count]       # keep-newest overwrites since last ack
  [u32 max_seq]             # highest seq in snapshot (ack target)
  [ record_count * 16B packed diag_event_t ]
  ```
  First read at `offset 0` snapshots the ring; subsequent offset reads serve the same snapshot so a
  GATT Long Read returns a stable blob (2 KB ring ≈ a handful of ATT reads).
- **`0x19B10064` — diag-log control (write).** `[u8 enable][u32 ack_seq]` (5 B). `enable` sets the
  runtime gate; `ack_seq` (when non-zero) drops all records with `seq <= ack_seq`. A short/malformed
  write is rejected (fail-closed).

**Capability bit:** add `OMI_FEATURE_DIAG_LOG = (1 << 12)` to `features.h` (next free bit;
`OMI_FEATURE_RECORD_TOGGLE = (1 << 11)` is the current highest, `features.h:24`). Set it in
`transport.c` near line 1082 under `#ifdef CONFIG_OMI_DIAG_LOG`. The app hides the toggle when the bit
is absent (mirrors how `recordToggle` gates the "Single recording button" UI).

**Wire safety:** all multi-byte fields little-endian, matching every other Omi characteristic.

## 7. Delete-on-connect / ack semantics (interruption-safe)

1. App connects, sees the `diagLog` capability + local pref ON → writes `enable=1` to `0x0064`.
2. App GATT-Long-Reads `0x0063` → gets snapshot header + records, notes `max_seq`.
3. App persists/decodes the records (DebugLogManager + on-screen viewer).
4. **Only after** a successful full read, app writes `ack_seq = max_seq` to `0x0064`.
5. Device drops records `seq <= max_seq`. Events that arrived *during* the drain have `seq > max_seq`
   and survive.

If the app disconnects between steps 2 and 4, nothing is acked → next connect re-reads from the oldest
record. **Records are never lost or overwritten by the transport** (only by keep-newest wrap while the
phone is away, which is counted). This is the same ack-and-advance discipline the ring backend's tail
uses (`sd_ring.h:77`, `sd_ring_ack_segment`).

## 8. App integration (`app/lib/`)

- **Pref:** `SharedPreferencesUtil` bool `diagLogEnabled`, default `false`.
- **Push on connect + on toggle:** a `DeviceProvider.pushDiagLogEnabled()` mirroring
  `pushActiveButtonConfig` — writes `0x0064` `[enable][0]` on connect (after time-sync/config push)
  and whenever the toggle flips. Default OFF means a rebooted device stays silent until the app
  re-enables (fail-safe; no NVS needed on-device).
- **Drain path:** gate the on-connect read of `0x0063` behind `diagLogEnabled`. Reuse the
  `0x0062` read plumbing in `omi_connection.dart` (see the drop-stats parse at `omi_connection.dart:247`
  and the `DeviceDropStats` model in `services/devices/device_drop_stats.dart`). Add a
  `DiagLogRecord` model + a `code → label` decode table.
- **Surface:** `DebugLogManager.logEvent('device_diag_log', {...})` per record (see the existing
  priority-stats logging at `device_provider.dart:1629-1636`) **plus** an on-screen viewer in the
  Debug Tools page (the screen in the screenshot — built from `pages/settings/sync_page.dart`, drop
  rendering around `sync_page.dart:1648`).
- **Dev Tools UI additions:** a capability-gated switch ("On-device event log"), a "Pull now" action,
  a `dropped_count` readout, and "Clear". Only visible when `OMI_FEATURE_DIAG_LOG` is advertised.
- After a successful pull, send the ack (§7 step 4).

## 9. Testing

**Unit (firmware, host-buildable ring logic if factored out):** wrap/keep-newest + `dropped_count`;
seq monotonicity; `diag_log_ack` drops the right prefix; drain snapshot stability across offset reads;
disabled gate = no writes.

**Unit (app):** record decode round-trip; unknown-code fallback rendering; ack only after full read;
`DeviceDropStats`-style parse of the `0x0063` header.

**Device:** enable via toggle → trigger a Priority Recording that produces an empty bin (the driving
case) → confirm a `DIAG_EMPTY_BIN_ROTATION` record with plausible `uptime_ms`/`backend`/`arg1` arrives
and decodes; verify counters still move in lockstep. Disconnect mid-drain → verify re-read on reconnect
(no loss). Toggle OFF → verify no new records.

**RAM/stack:** after reducing `SD_WORKER_STACK_SIZE`, read `sd_worker_stack_used` (0x0062 offset 68)
under load on **both** backends (esp. near-full LittleFS) and confirm comfortable headroom.

## 10. Roadmap interaction: LittleFS removal

LittleFS will be removed in favor of the ring backend once the ring is confirmed stable. That
**simplifies and unlocks** this feature:

- **Stack shrink becomes confident.** With LFS's deep allocator-scan/GC/format paths gone, the ring
  path's shallow (~2.7 KB) peak is the real ceiling → `SD_WORKER_STACK_SIZE` can be reduced further,
  freeing more RAM (for a bigger ring or elsewhere).
- **Persistent upgrade becomes universal.** The volatile RAM ring's one limitation is that a reboot
  loses the log (mostly covered by the existing reset-cause char `0x0061`). If reboot-survival is later
  needed, promote to a persistent CRC'd log in the ring's **already-reserved metadata sectors 81–255**
  (`sd_ring.h:30-33,69` — 128 KB reserved region, never touched by audio, DFU-proof because DFU never
  addresses the SD NAND). Reuse the ring cursor's torn-write pattern (per-sector CRC, highest valid seq
  wins, discard torn tail on boot; `sd_ring.h:35-42`). This was "Option C" — deferred, and it becomes
  clean (no backend asymmetry) only after LittleFS is gone, which is exactly why it's deferred.

Until then: **volatile RAM ring only.** Do not build the persistent path yet.

## 11. Alternatives considered (and why rejected)

| Option | Idea | Verdict |
|---|---|---|
| A | Add "last event" registers (`last_empty_bin_uptime`, `reason_code`) to `0x0062` | ~Free, but gives only the *last* event, not a stream. Fold its `{uptime, code}` idea into records; not a substitute. |
| **B** | **Volatile RAM binary ring, drained over BLE, ack-gated, dev-toggle** | **CHOSEN.** Meets every constraint; lowest risk (lives entirely outside the audio/FS path). |
| C | Persistent log in isolated SD sectors / internal partition | Reboot-survival, but backend asymmetry (ring has reserved sectors, LittleFS doesn't) + torn-write handling + partition risk. Deferred to post-LittleFS (§10). |
| D | Log as a real FS file / ring segment | Rejected — exactly the FS interference we forbade; VAD would ingest it, ring segment table pollution. |

## 12. Open decisions for the implementer

- Ring depth: default 128 (2 KB). Bump if LittleFS removal frees more stack.
- Whether to also `Notify` on `0x0063` for live streaming during a bench session, or read-only pull on
  connect (spec assumes pull-only; Notify is a cheap add later).
- Exact `arg0/arg1` payloads per event code (table §5.3 is a starting point — pick what's diagnostic).
- Whether "Pull now" should auto-ack or require an explicit "Clear" (spec assumes ack after pull).

## 13. Key file references (jump-start map)

**Firmware:**
- `sd_card.c:446-448` — `SD_WORKER_STACK_SIZE` + stack define (reduce here).
- `sd_card.c:3071-3076` — `sd_get_worker_stack_used()` (stack high-water getter).
- `sd_card.c:1703-1705`, `3136-3138` — empty-bin increments (instrument here).
- `sd_card.c:835-854` — `sd_write_paused` gate + `marker_pause_gate_saves` (instrument).
- `codec.c:81` — precedent for reclaiming SD-worker-stack RAM.
- `transport.c:440-464` — `0x0062` drop-counter wire layout doc (append new fields / mirror pattern).
- `transport.c:465-491` — Diagnostics service + `0x0061`/`0x0062` UUIDs and read handler (add
  `0x0063`/`0x0064` here; find the `BT_GATT_SERVICE_DEFINE` block in the same file).
- `transport.c:1051-1082` — feature bitfield assembly (add `OMI_FEATURE_DIAG_LOG` set).
- `features.h:19-24` — `OMI_FEATURE_*` enum (add `(1 << 12)`).
- `sd_ring.h:30-42,69,77` — reserved sectors + torn-write pattern (for the deferred persistent path).

**App:**
- `services/devices/omi_connection.dart:247` — drop-stats parse (mirror for `0x0063`).
- `services/devices/device_drop_stats.dart` — counter model (mirror for `DiagLogRecord`).
- `providers/device_provider.dart:1600-1637` — connect-time diagnostics polling + `DebugLogManager`
  (add diag-log drain + push-enable here; mirror `pushActiveButtonConfig`).
- `pages/settings/sync_page.dart:1648` — Debug Tools diagnostics rendering (add viewer + toggle).

**Docs:** `CLAUDE.md` — BLE protocol tables (Diagnostics service, Features bitfield, marker frames).
