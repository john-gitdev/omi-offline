# Omi Firmware

Zephyr RTOS firmware for the Omi Consumer wearable (nRF5340). Handles audio capture, Opus encoding, SD card storage, BLE transport, and button/LED control.

## Directory Structure

- `omi/` — Main application
  - `src/` — C source files (`main.c`, `sd_card.c`, `aad.c`, `mic.c`, `led.c`, `transport.c`, …)
  - `boards/` — Board-specific overlay and config files
  - `CMakeLists.txt` / `CMakePresets.json` — Build configuration
- `boards/` — Custom Zephyr board definitions
- `bootloader/` — MCUboot binaries and deprecated flash packages
- `BUILD_AND_OTA_FLASH.md` — Build and OTA flash instructions

## Building

See [`BUILD_AND_OTA_FLASH.md`](BUILD_AND_OTA_FLASH.md).

## Key Components

- **Audio capture** (`mic.c`) — PDM at 16 kHz, fed into the Opus encoder.
- **Codec** (`transport.c`) — Opus VBR (32 kbps, complexity 3), 20 ms frames (~80 B/frame avg at 50 fps).
- **Storage** (`sd_card.c`) — LittleFS on SD card. Frames are batched and written 100 at a time; fsync every 60 s. Inline marker frames (`0xFFFFFFFE` button-tap, `0xFFFFFFFC` session-end, `0xFFFFFFFD` VAD-resume) are written into the audio stream.
- **Transport** (`transport.c`) — BLE GATT audio stream and storage sync protocol. Manages `device_session_id` and marker writes.
- **AAD** (`aad.c`) — Hardware audio-activity detection; writes VAD-resume timestamps and session-end markers.
- **Button** (`button.c`) — Interrupt-driven FSM. Double-tap writes a marker; double-tap in manual mode starts/stops recording.
- **LED** (`led.c`) — Priority-ordered state machine (stealth, charging, mute, battery, BLE, recording).
