# Notes

Running log of investigated bugs, deferred decisions, and findings that don't fit TODO or README.

---

## Firmware: LED Behavior

### Boot Sequence
1. **Haptic buzz** (200ms) — only power-on signal, no LED
2. **LEDs Off** — SD card pre-warming (`lfs_fs_gc`). Mic is NOT started yet; no audio is dropped.
3. **Fade to solid yellow** (0→100%) — pre-warm complete, mic starts, main loop takes over

### LED State Machine (`set_led_state()`, runs every 500ms)

Priority order (highest first):

| Priority | Condition | LED |
|----------|-----------|-----|
| 1 | Device off | Off |
| 2 | Double-tap marker (`marker_flash_count > 0`) | White (R+G+B) — overrides stealth |
| 3 | Stealth mode (`is_led_enabled == false`) | Off |
| 4 | Muted (long press) | Solid Red |
| 5 | Low battery (< 10%) | Solid Purple (R+B) |
| 6 | BLE connected | Solid Blue |
| 7 | Default / recording | Solid Yellow (R+G) |

### Charging Override
Applied on top of the base state above:
- **Fully charged (≥ 98%):** Solid Green
- **Charging:** Blinks every 500ms between Green and the current base color (e.g. Green ↔ Blue if connected, Green ↔ Yellow if recording)
- Plugging in charger automatically disables Stealth Mode (`is_led_enabled = true`)

### Button Controls
| Action | Effect |
|--------|--------|
| Single tap | Toggle Stealth Mode (LED on/off) |
| Long press (1s) | Toggle Mute — LED goes Red when muted |
| Double tap | White flash ~1s (marker recorded) — ignored if muted |
| Double tap + hold (3s) | Power off |

### Hardware Error LEDs
**Removed in production.** The `feedback.c` error functions (`error_sd_card()`, `error_transport()`, etc.) only log to UART/RTT. No visual LED feedback on errors. Color codes are documented in `feedback.h` comments for reference only.

### Stealth Mode Notes
- Single tap toggles `is_led_enabled`
- Stealth suppresses all base state LEDs
- Stealth does **not** suppress: double-tap white flash
- Charging always overrides stealth back on

---

## Firmware: `WRITE_BATCH_COUNT` and `WRITE_DRAIN_BURST` tuning

**Location:** `omi/firmware/devkit/src/` (SD card write queue config)

**Current values (this repo):**
```c
#define WRITE_BATCH_COUNT  32
#define WRITE_DRAIN_BURST  16
```

**Upstream values (`BasedHardware/omi`):**
```c
#define WRITE_BATCH_COUNT  200
#define WRITE_DRAIN_BURST  16
```

### Analysis

`WRITE_BATCH_COUNT` sets the static queue depth. Each slot holds one audio frame (440 bytes for Opus at 20 ms / 50 fps).

| Metric | 32 (this repo) | 200 (upstream) |
|--------|---------------|----------------|
| Static RAM used | 14 KB | 86 KB (33% of nRF52840's 256 KB) |
| SD flush frequency | ~every 3.5 s of audio | ~every 22 s |
| SD write cycles | Higher | Lower |
| Avg power draw | Slightly higher | Lower |
| Data loss on hard power-off | ≤14 KB (~3.5 s) | ≤88 KB (~22 s) |

`WRITE_DRAIN_BURST 16` is identical in both — no difference.

### Verdict

**32 is the right value for the nRF52840.** 86 KB as a single static buffer on a 256 KB device is aggressive and leaves little headroom for the BLE stack, Zephyr kernel, and other subsystems.

The queue-pressure early-flush (triggered at 8 queued messages) is the effective ceiling in practice — if audio arrives faster than the SD can drain, the flush fires long before reaching 32 anyway. And since `fsync` only runs every 60 seconds regardless, batching beyond a few seconds provides no durability benefit.

Going higher would marginally reduce `fs_write()` call frequency, but those calls are cheap (filesystem cache, not physical SD writes) and already amortized by the 60 s fsync cadence.

**The 6× smaller data-loss window on hard power-off (3.5 s vs 22 s) is a genuine safety improvement.**

The upstream value of 200 likely targets a device with more RAM or was set without accounting for the nRF52840's memory constraints.
