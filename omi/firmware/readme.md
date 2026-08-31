# Omi Firmware

Zephyr RTOS firmware for the Omi Consumer wearable (nRF5340). Handles audio capture, Opus encoding, SD card storage, BLE transport, and button/LED control.

## Directory Structure

- `omi/` — Main application
  - `src/` — C source at the root (`main.c`, `sd_card.c`, `aad.c`, `mic.c`, `led.c`, `battery.c`, `haptic.c`, `imu.c`, `rtc.c`, `settings.c`, `spi_flash.c`, `wdog_facade.c`)
  - `src/lib/core/` — the rest (`transport.c`, `button.c`, `codec.c`, `storage.c`, `sd_ring.c`, `diag_log.c`, `monitor.c`) plus vendored `opus-1.2.1`
  - `boards/` — Board-specific overlay and config files, including `pm_static.yml` (the partition map — the build asserts the app's link address against it)
  - `CMakeLists.txt` / `CMakePresets.json` — Build configuration
- `boards/` — Custom Zephyr board definitions
- `bootloader/` — MCUboot binaries and deprecated flash packages
- `BUILD_AND_OTA_FLASH.md` — Build and OTA flash instructions

## Building

See [`BUILD_AND_OTA_FLASH.md`](BUILD_AND_OTA_FLASH.md).

## Key Components

- **Audio capture** (`mic.c`) — PDM at 16 kHz, fed into the Opus encoder.
- **Codec** (`codec.c`, `transport.c`) — Opus VBR (32 kbps, complexity 3, CELT), 16 kHz mono, 20 ms frames at 50 fps (codec ID `21` = opusFS320). BLE carries 40 B frames; on the SD log a VBR frame averages ~81 B including its length prefix.
- **Storage** (`sd_card.c`, `sd_ring.c`) — **no filesystem.** Audio is appended to a raw circular log on the 512 MB SD NAND: a 128 KB metadata reserve (format header, 64-slot cursor log, two segment-table copies) followed by an append-only byte ring. This replaced LittleFS, whose block allocator had no persistent free-map and ran a full-filesystem scan — tens of seconds on the single SD worker thread, dropping audio throughout — exactly when the card was full. Appending is O(1), nothing ever scans, and the cursor advances only once the bytes are durable, so a power cut can lose at most the un-claimed tail. Frames are assembled into 440 B blocks and queued on `sd_msgq` (depth 120); BLE reads use a separate priority queue, and a write-fairness rule forces a write turn after a run of reads so an active sync can't starve audio. The ring cursor syncs at most every 60 s.
- **Inline markers** — written into the audio stream rather than a sidecar, so they survive with the audio and need no connected phone: `0xFFFFFFFB` metadata header, `0xFFFFFFFE` button-tap, `0xFFFFFFFC` session-end, `0xFFFFFFFD` AAD VAD-resume, `0xFFFFFFFA`/`0xFFFFFFF9` mute on/off, `0xFFFFFFF8` Priority Recording start. Layouts in the root CLAUDE.md.
- **Transport** (`transport.c`) — BLE GATT custom services and the storage sync protocol (audio is written to SD, not streamed over BLE). Manages `device_session_id` and marker writes.
- **AAD** (`aad.c`) — Hardware audio-activity detection; writes VAD-resume timestamps and session-end markers.
- **Button** (`button.c`) — Interrupt-driven FSM (no polling); the GPIO callback wakes a counter-based tap/hold resolver only on press. Six gestures (single/double/triple tap, each with a press-and-hold variant) resolve against a **configurable** action map synced from the app over the Settings service and persisted in flash — `None`, `Mute`, `Marker`, `Toggle LED`, `Record Start`, `Record Stop`, `Record Toggle`. The 4-tap-and-hold (Power Off) and 5-tap-and-hold (Unpair) gestures are reserved and bypass the map.
- **Diagnostics** (`diag_log.c`, `monitor.c`) — drop/health counters read over the Diagnostics BLE service, plus an on-device event log in dev builds (`CONFIG_OMI_DIAG_LOG`) that timestamps the events the counters only total.
- **Settings** (`settings.c`) — persisted app settings in NVS: LED dim ratio, mic gain, AAD threshold, Priority Recording safety cap, button and haptic maps, LED boot gate, and the one-shot post-DFU bond-wipe flag.
- **LED** (`led.c`) — Priority-ordered state machine (stealth, charging, mute, battery, BLE, recording).
