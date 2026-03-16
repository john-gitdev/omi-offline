---
name: mobile-app-flows
description: "Understand and explore the Omi offline Flutter app's UI flows, navigation patterns, and widget architecture. Use when developing features, fixing bugs, or verifying changes in app/lib/ Dart files. Provides agent-flutter commands to explore the live app, understand how screens connect, and verify your work."
allowed-tools: Bash, Read, Glob, Grep
---

# Omi Offline App — Flows & Exploration

This skill teaches the Omi offline Flutter app's navigation structure, screen architecture, and widget patterns. Use it when developing features (to understand how the app works), fixing bugs (to navigate to the affected screen), or verifying changes (to confirm your code works in the live app).

## How to Explore the App

You can interact with the running app via `agent-flutter` — a CLI that taps widgets, reads the widget tree, and captures screenshots through Flutter's Marionette debug protocol.

### Setup
```bash
# 1. Emulator must be running
adb devices                          # should show emulator-5554
# If not: sg kvm -c "$ANDROID_HOME/emulator/emulator -avd omi-dev -no-window -gpu swiftshader_indirect -no-audio -no-boot-anim &"

# 2. Set system language to English (REQUIRED — non-English IME breaks text input)
adb shell "settings put system system_locales en-US"
adb shell "setprop persist.sys.locale en-US"

# 3. App must be running in debug mode with flutter run stdout captured
cd app && flutter run -d emulator-5554 --flavor dev > /tmp/omi-flutter.log 2>&1 &
# Wait for "VM Service" line to appear in the log

# 4. Connect agent-flutter (AGENT_FLUTTER_LOG must point to flutter run stdout, NOT logcat)
AGENT_FLUTTER_LOG=/tmp/omi-flutter.log agent-flutter connect
agent-flutter snapshot -i --json    # see what's on screen
```

**Prerequisites:**
- AVD name: `omi-dev` (check: `$ANDROID_HOME/emulator/emulator -list-avds`)
- KVM access required: user must be in `kvm` group (`sg kvm -c "..."` if not in current session)
- App package: `com.omi.offline.dev` (dev flavor)
- **System language must be English** — non-English IME breaks `fill` commands
- Marionette already integrated: `marionette_flutter: ^0.3.0` in pubspec.yaml

### Commands

| Command | Purpose | Example |
|---------|---------|---------|
| `snapshot -i --json` | See all interactive widgets with refs, types, bounds | `agent-flutter snapshot -i --json` |
| `press @ref` | Tap a widget by ref | `agent-flutter press @e3` |
| `press x y` | Tap by coordinates (ADB input tap) | `agent-flutter press 540 1200` |
| `press @ref --adb` | Tap by ref using ADB (for stale refs) | `agent-flutter press @e3 --adb` |
| `dismiss` | Dismiss system dialogs (location, permissions) | `agent-flutter dismiss` |
| `find type X press` | Find widget by type and tap | `agent-flutter find type button press` |
| `find text "X" press` | Find by visible text and tap | `agent-flutter find text "Settings" press` |
| `find type X --index N press` | Tap Nth match (0-indexed) | `agent-flutter find type switch --index 0 press` |
| `fill @ref "text"` | Type into text field | `agent-flutter fill @e7 "search"` |
| `scroll down/up` | Scroll current view | `agent-flutter scroll down` |
| `back` | Android back button | `agent-flutter back` |
| `screenshot PATH` | Capture current screen | `agent-flutter screenshot /tmp/screen.png` |

**Key rules:**
- Refs go stale frequently (Flutter rebuilds widget tree aggressively) — always re-snapshot before every interaction, not just after mutations.
- `find type X` is more stable than hardcoded `@ref` numbers.
- `AGENT_FLUTTER_LOG` must point to `flutter run` stdout (not logcat).
- After hot restart: `disconnect` → wait 3s → `connect`.
- Widget text labels are often null — use `type`, `flutterType`, or `bounds` to identify.

### Recovery
```bash
# "No isolate with Marionette" → bring app to foreground + reconnect
adb -s emulator-5554 shell am start -n com.omi.offline.dev/com.omi.offline.MainActivity
agent-flutter disconnect && agent-flutter connect

# Unhealthy widget tree → hot restart
kill -SIGUSR2 $(pgrep -f "flutter_tools.*run" | head -1)
sleep 3 && agent-flutter disconnect && agent-flutter connect
```

## App Navigation Architecture

### Screen Map
```
Home — RecordingsPage (recordings_page.dart)
├── [top-right gear] → Settings Drawer (settings_drawer.dart)
│   ├── Find Omi Devices → FindDevicesPage (find_devices_page.dart)
│   │   └── Tap device row → connect via BLE
│   ├── Sync Device → SyncPage (sync_page.dart)
│   │   └── Sync status, local storage, recordings, fast transfer
│   ├── Offline Audio Processing → OfflineAudioSettingsPage (offline_audio_settings_page.dart)
│   │   └── STT provider, silence detection, output settings
│   └── Device Settings → DeviceSettings (device_settings.dart)  [only when BLE connected]
│       └── Device info, LED brightness, mic gain, double tap action
└── Recording row → RecordingPlayerPage (recording_player_page.dart)
    └── Waveform, play/pause, scrubber
```

### Widget Patterns

**Settings gear:**
- Gesture widget in top-right of home screen
- Detect with: sort gesture widgets by `bounds.x` descending, take first

**Settings rows:**
- `gesture` widgets inside the settings drawer bottom sheet
- Four rows: Find Omi Devices, Sync Device, Offline Audio Processing, Device Settings (conditional)

**Recording rows:**
- Gesture widgets in the main scroll list grouped by date
- Each shows duration and timestamp

## Prerequisites Reference

| Prerequisite | What it means | How to achieve |
|-------------|---------------|----------------|
| `auth_ready` | App launched and home (recordings) screen is visible | Launch app — no sign-in required for offline use |
| `ble_on` | Bluetooth enabled on device | Enable Bluetooth in device Settings. **Emulators have no BLE** — physical device only |
| `omi_device_connected` | Omi hardware paired and connected via BLE | Power on Omi device within BLE range → Settings → Find Omi Devices → tap device |

## YAML Flow Schema

Each flow file has these top-level keys:
```yaml
name: string          # Flow identifier
description: string   # What this flow covers
covers: [string]      # Source files this flow exercises
prerequisites: [string]  # Conditions required — see Prerequisites Reference above
setup: normal | { requires: condition }
steps: [Step]         # Ordered list of actions
```

Each step can use these action keys (map to agent-flutter commands):

| YAML Key | agent-flutter Command | Example |
|----------|----------------------|---------|
| `press: { type: X }` | `find type X press` | `press: { type: button }` |
| `press: { type: X, hint: "..." }` | `find type X press` (hint helps identify which) | `press: { type: gesture, hint: "settings gear" }` |
| `fill: { type: X, value: "..." }` | `find type X` then `fill @ref "value"` | `fill: { type: textfield, value: "test" }` |
| `scroll: up\|down` | `agent-flutter scroll up\|down` | `scroll: down` |
| `back: true` | `agent-flutter back` | `back: true` |
| `assert: { text, interactive_count }` | `snapshot -i --json` then verify | `assert: { text: "Settings" }` |
| `screenshot: name` | `agent-flutter screenshot /tmp/name.png` | `screenshot: home-view` |
| `dismiss: true` | `agent-flutter dismiss` | `dismiss: true` |
| `wait: { text: "..." }` | poll `snapshot` until text appears | `wait: { text: "Loading" }` |
| `note: string` | No command — context for the agent | `note: "row is only visible when connected"` |
| `name: string` | No command — step label | `name: "Open settings"` |

## Known Flows

6 flows in `app/e2e/flows/*.yaml` covering all current screens.

| Flow | Prerequisites | What it describes |
|------|--------------|-------------------|
| `flows/recordings.yaml` | auth_ready | Home recordings list, tap to open player, play/pause |
| `flows/find-devices.yaml` | auth_ready, ble_on | Settings → Find Omi Devices — scan and connect |
| `flows/settings-sync.yaml` | auth_ready | Settings → Sync Device — sync status, storage, fast transfer |
| `flows/offline-audio-settings.yaml` | auth_ready | Settings → Offline Audio Processing — STT, silence detection |
| `flows/settings-device.yaml` | auth_ready, ble_on, omi_device_connected | Settings → Device Settings — LED, mic gain, double tap |
| `flows/device-management.yaml` | auth_ready, ble_on, omi_device_connected | Device info, firmware update, disconnect |

When you modify a Dart file, check if any flow's `covers:` includes it. If so, that flow describes the user journey your change affects — use it to understand context and verify your work.

## Verification & Evidence

After making changes, verify them in the live app:
1. Navigate to the affected screen using the commands above
2. Check that your changes appear (snapshot, screenshot)
3. Test interactions (press buttons, fill fields, scroll)
4. Capture evidence: `agent-flutter screenshot /tmp/evidence.png`

## Decision Tree

| Problem | Solution |
|---------|----------|
| Widget not found | Re-snapshot, try scrolling, check if on wrong screen, match by bounds position |
| Ref expired between commands | Use `press x y` with coordinates from last snapshot bounds, or `press @ref --adb` |
| System dialog blocking | `agent-flutter dismiss` |
| "No isolate with Marionette" | ADB foreground + disconnect + reconnect |
| Snapshot returns 0 interactive elements | Marionette lost widget tree — `disconnect` then `connect` to re-attach |
| Hot restart breaks connection | Wait 3s → disconnect → connect |
| Text labels null | Match by `type`, `flutterType`, or `bounds` |
| Non-English IME breaks text input | Set system locale to English: `adb shell "settings put system system_locales en-US"` |

## Guard Conditions

**NEVER:**
- Modify source code to make tests pass — report the failure instead
- Commit screenshots to git — use GCS upload for PR evidence
