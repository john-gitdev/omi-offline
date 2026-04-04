# Notes

Running log of investigated bugs, deferred decisions, and findings that don't fit TODO or README.

---

## Firmware: LED Behavior

### Boot Sequence
1. **LEDs breathing white** — starts immediately on `led_start()` before anything else
2. **Haptic buzz** (100ms) — fires during breathing while settings + SD init run
3. **Breathing continues** — waiting for SD worker to finish mount + `lfs_fs_gc` + file open (< 5 s with little data, up to ~50 s with 200 MB)
4. **Mic starts** — once SD is ready (`sd_is_boot_ready()`)
5. **Breathing stops, fade to yellow** — R+G fade from 0 → `dim_ratio` over 300 ms; `set_led_state()` takes over

### LED State Machine (`set_led_state()`, runs every 500ms)

Priority order (highest first):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off (`is_off`) | Off |
| 2 | Charging starts (`is_charging && !is_led_enabled`) | Force `is_led_enabled = true`, continue |
| 3 | Double-tap marker (`marker_flash_count > 0`) | White (R+G+B) — overrides stealth |
| 4 | Stealth mode (`!is_led_enabled`) | Off |
| 5 | Muted | Solid Red |
| 6 | Low battery (< 10%) | Solid Purple (R+B) |
| 7 | BLE connected | Solid Blue |
| 8 | Default / recording | Solid Yellow (R+G) |

### Charging Override
Applied on top of the base state above:
- **Fully charged (≥ 98%):** Solid Green
- **Charging:** Blinks every 500ms between Green and the current base color (e.g. Green ↔ Blue if connected, Green ↔ Yellow if recording)
- Plugging in charger automatically disables Stealth Mode (`is_led_enabled = true`)

### Button Controls
| Action | Effect | Haptic |
|--------|--------|--------|
| Single tap | Toggle Stealth Mode (LED on/off) | None |
| Long press (1s) | Toggle Mute — LED goes Red when muted, mic paused | 500ms |
| Double tap | White flash ~1s (marker recorded) — ignored if muted | 300ms |
| Double tap + hold (3s on second press) | Power off | 1000ms |

### Hardware Error LEDs
**Removed in production.** All `error_*()` functions in `feedback.c` log to UART/RTT only. No visual LED feedback on errors.

### Stealth Mode Notes
- Single tap toggles `is_led_enabled`
- Stealth suppresses all base state LEDs (priority 4)
- Stealth does **not** suppress double-tap white flash (priority 3 fires first)
- Charging always overrides stealth back on

---

## Firmware: SD Write Queue Configuration

**Location:** `omi/firmware/omi/src/sd_card.c`

**Current values:**
```c
#define SD_REQ_QUEUE_MSGS  200   // main audio write queue depth
#define SD_PRIO_QUEUE_MSGS  10   // priority queue (control requests)
#define WRITE_DRAIN_BURST   16   // frames drained per worker iteration
#define SD_FSYNC_INTERVAL_MS (60 * 1000)  // fsync every 60s
```

Each slot in `sd_msgq` holds one `sd_req_t`. The queue is backed by `K_MSGQ_DEFINE` (static allocation). The worker drains up to `WRITE_DRAIN_BURST` (16) messages per iteration before yielding.

`SD_FSYNC_INTERVAL_MS` (60 s) controls durability: data is in the LittleFS write cache until fsync fires. A hard power-off within this window risks losing up to 60 s of audio, but LittleFS's copy-on-write metadata ensures the filesystem itself stays consistent.

The early-flush path (`sd_boot_ready` gate + high-watermark logic) prevents the queue from filling during the boot `lfs_fs_gc` pre-warm and during bursts of rapid audio ingestion.
