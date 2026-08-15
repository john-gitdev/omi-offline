import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';

// Editing is only allowed once we've read a live config off the device; otherwise the
// page sits in loading or the not-connected state with a Retry affordance.
enum _ConfigStatus { loading, ready, noDevice }

class ButtonConfigPage extends StatefulWidget {
  const ButtonConfigPage({super.key});

  @override
  State<ButtonConfigPage> createState() => _ButtonConfigPageState();
}

class _ButtonConfigPageState extends State<ButtonConfigPage> {
  _ConfigStatus _status = _ConfigStatus.loading;

  // Per-mode button configs, app-owned (the firmware holds only the active one).
  // _activeIsManual is the device's actual mode (which config is live on the
  // firmware); _selectedManual is which mode's mapping the segmented control is
  // currently viewing/editing.
  List<int> _configManual = SharedPreferencesUtil().buttonConfigManual;
  List<int> _configAuto = SharedPreferencesUtil().buttonConfigAuto;
  final bool _activeIsManual = SharedPreferencesUtil().manualMode;
  late bool _selectedManual = _activeIsManual;

  // Global switch (both modes): collapse the split Record Start/Stop actions
  // into a single Record Toggle. Local mirror of the pref for instant UI.
  bool _combineRecord = SharedPreferencesUtil().combineRecordButton;

  // Whether the connected firmware accepts the RECORD_TOGGLE action (byte 6).
  // Older firmware rejects it, so we hide the switch + Toggle option there and
  // fall back to split Start/Stop, exactly like the haptic / priority-cap gates.
  bool _recordToggleSupported = false;

  // True while a config write is in flight, so we can disable the switch and the
  // dropdowns and serialize mutations — a second flip or a slot edit racing an
  // in-flight flip could otherwise be clobbered by the flip's whole-config revert.
  bool _busy = false;

  // Combine is only in effect when the pref is on AND the device supports it;
  // an unsupported device always shows split Start/Stop regardless of the pref.
  bool get _combineActive => _combineRecord && _recordToggleSupported;

  bool get _controlsEnabled => _editable && !_busy;

  List<int> get _config => _selectedManual ? _configManual : _configAuto;

  // Per-slot vibration pattern (0=Off, 1=Single, 2=Double, 3=Triple), same slot
  // order as the button config. Shared across both modes (the buzz confirms the
  // gesture, not the action). Only surfaced when the device reports the
  // haptic-config characteristic — older firmware returns null and we hide it.
  List<int> _hapticConfig = [0, 0, 0, 0, 0, 0];
  bool _hapticSupported = false;

  static const List<String> _vibrationPatterns = ['Off', 'Single', 'Double', 'Triple'];

  // Whether red "Priority Recording" markers (auto-mode Priority Recordings) show
  // in the timeline. Local mirror of the pref so the switch updates instantly.
  bool _showHighPriorityMarker = SharedPreferencesUtil().showHighPriorityMarker;

  // value → label, in dropdown order. Values match the firmware's config bytes
  // (0=None, 1=Mute, 2=Marker, 3=Toggle LED, 4=Record Start, 5=Record Stop,
  // 6=Record Toggle). Mute is a no-op while recording is under manual control,
  // so it reads as disabled in the Manual view. The recording actions depend on
  // the global Combine switch: split Start/Stop, or a single Toggle. On the Auto
  // tab they say "Prio Rec" to mark that they bracket a red Priority Recording
  // rather than the ambient auto capture.
  Map<int, String> get _actionOptions {
    final m = <int, String>{
      0: 'None',
      1: _selectedManual ? 'Mute - Disabled' : 'Mute',
      2: 'Marker',
      3: 'Toggle LED',
    };
    if (_combineActive) {
      m[6] = _selectedManual ? 'Toggle Recording' : 'Toggle Prio Rec';
    } else {
      m[4] = _selectedManual ? 'Start Recording' : 'Start Prio Rec';
      m[5] = _selectedManual ? 'Stop Recording' : 'Stop Prio Rec';
    }
    return m;
  }

  bool get _editable => _status == _ConfigStatus.ready;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final pairedDevice = context.read<DeviceProvider>().pairedDevice;
    if (pairedDevice == null || pairedDevice.id.isEmpty) {
      if (mounted) setState(() => _status = _ConfigStatus.noDevice);
      return;
    }
    try {
      // force: true. Without it ensureConnection NEVER establishes a link — it
      // hands back one that already exists, or null (`if (!force) return null;`).
      // So opening this page at any moment the app is not already connected went
      // straight to _ConfigStatus.noDevice with no connection attempt at all,
      // every dropdown dead, and nothing in the log to say why.
      //
      // The app does hold the link while it is in the foreground (the keep-alive
      // runs, and all three disconnect paths in DeviceProvider are gated on
      // !_isAppInForeground), so this is not the steady state — but the gap is
      // routine: after a background/foreground cycle before the reconnect lands,
      // or after any of the link drops this device sees regularly.
      //
      // Safe: ensureConnection returns early when already connected to this
      // device, so force costs nothing when the link is up, and only one Omi is
      // ever paired. Matches what every other UI path that needs the device does
      // (find_devices_page, sync_page, the DFU flow). The initial `loading` state
      // covers the ~1 s the connect takes.
      final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id, force: true);
      if (connection == null) {
        if (mounted) setState(() => _status = _ConfigStatus.noDevice);
        return;
      }
      final prefs = SharedPreferencesUtil();
      // Per-mode configs come from prefs (app-owned). The one-time migration that
      // seeds buttonConfigAuto from the device's existing config runs in
      // DeviceProvider.pushActiveButtonConfig on connect, which has already
      // happened by the time this page is reachable.
      //
      // Best-effort: older firmware lacks the haptic characteristic and returns
      // null, in which case we simply don't offer vibration patterns.
      final haptic = await connection.getHapticConfig();
      // Capability gate for the Record Toggle action (byte 6): older firmware
      // rejects it, so hide the switch / Toggle option there. A failed/zero read
      // means unsupported (fail closed) — never offer a byte the device rejects.
      //
      // getFeaturesIfIdle, NEVER getFeatures. This page is most often reached
      // straight after a mode switch — the settings save prompts for it — which is
      // exactly when a sync is likely to be running on the same link. A plain GATT
      // read racing the storage notify stream drops the link on Android with Error
      // 133 (see performGetFeaturesIfIdle, which takes the storage mutex for this
      // reason). The old call therefore did worse than fail: it could kill the
      // connection, after which the catch below reported "no device" for a device
      // that was connected until this page asked.
      //
      // A null answer means a transfer holds the lock, NOT that the Omi is absent.
      // Fail closed on the capability — never offer a byte the firmware may reject —
      // but stay usable: the mappings themselves are app-owned and need no device to
      // read, and the write paths report their own failures.
      final features = await connection.getFeaturesIfIdle();
      if (mounted) {
        setState(() {
          _configManual = prefs.buttonConfigManual;
          _configAuto = prefs.buttonConfigAuto;
          _combineRecord = prefs.combineRecordButton;
          _recordToggleSupported = features != null && OmiFeatures.hasFeature(features, OmiFeatures.recordToggle);
          if (haptic != null && haptic.length == 6) {
            _hapticConfig = haptic;
            _hapticSupported = true;
          } else {
            _hapticSupported = false;
          }
          _status = _ConfigStatus.ready;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _status = _ConfigStatus.noDevice);
    }
  }

  void _persistSelectedConfig() {
    final prefs = SharedPreferencesUtil();
    if (_selectedManual) {
      prefs.buttonConfigManual = _configManual;
    } else {
      prefs.buttonConfigAuto = _configAuto;
    }
  }

  // Flip the global Combine switch. Remaps BOTH mode configs to the new style
  // (asymmetric: turning ON preserves the Start gesture as the Toggle; turning
  // OFF blanks the Toggle so no lone Start-without-Stop is ever auto-created),
  // persists them, and pushes the active one to the firmware.
  Future<void> _setCombineRecord(bool on) async {
    // Acquire the write lock UP FRONT — before the async recording-state read +
    // confirmation dialog below — so a slot edit or a second flip can't start its
    // own config write during those pre-checks and race this flip. Released again
    // on every early return.
    setState(() => _busy = true);

    // Turning OFF blanks the Toggle, leaving no button to stop an in-progress
    // recording. If a MANUAL recording is live (persisted VAD threshold 65535 —
    // the only recording state the app can read; auto priority recordings read
    // back the persisted auto value and are backstopped by the safety cap),
    // confirm before stranding it. Turning ON keeps a Toggle (which can stop),
    // so it's always safe and needs no prompt.
    if (!on) {
      final pairedDevice = context.read<DeviceProvider>().pairedDevice;
      if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
        try {
          final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id, force: true);
          final thr = await connection?.getVadThreshold();
          if (thr == 65535 && mounted) {
            final proceed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1C1C1E),
                title: const Text('Recording in progress', style: TextStyle(color: Colors.white)),
                content: const Text(
                  'A recording is in progress. Switching off the single recording button clears your '
                  'recording gestures, so you\'ll have no button to stop it — reassign one afterwards, '
                  'or switch recording mode to end it.',
                  style: TextStyle(color: Colors.white70),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Continue')),
                ],
              ),
            );
            if (proceed != true) {
              if (mounted) setState(() => _busy = false); // release; leave the switch where it was
              return;
            }
          }
        } catch (_) {
          // Couldn't read the device state — proceed (lock stays held).
        }
      }
    }
    if (!mounted) return;

    final prefs = SharedPreferencesUtil();
    // Snapshot for revert-on-failure: the flip remaps BOTH mode configs and the
    // pref, so a mid-push BLE drop must restore all of them (mirrors
    // _updateConfig's optimistic-write-then-revert).
    final prevManual = List<int>.of(_configManual);
    final prevAuto = List<int>.of(_configAuto);
    final prevCombine = _combineRecord;

    // _busy is already held from the top; apply the optimistic flip.
    setState(() => _combineRecord = on);
    _configManual = SharedPreferencesUtil.normalizeButtonConfigForCombine(_configManual, on);
    _configAuto = SharedPreferencesUtil.normalizeButtonConfigForCombine(_configAuto, on);
    prefs.buttonConfigManual = _configManual;
    prefs.buttonConfigAuto = _configAuto;
    prefs.combineRecordButton = on;

    // The flip changed the active mode's config regardless of which tab is
    // shown, so push via the provider (which reads the active config fresh)
    // rather than the tab-gated per-slot path.
    final ok = await context.read<DeviceProvider>().pushActiveButtonConfig();
    if (ok) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    // Push failed (e.g. the link dropped mid-flip). Revert the in-memory state
    // AND prefs UNCONDITIONALLY — even if we've since unmounted — so the flip is
    // all-or-nothing against the firmware write. Otherwise a failure after the
    // page closed would leave prefs ahead of the device, and the next connect's
    // pushActiveButtonConfig would push the un-reverted config. UI feedback is
    // still mount-gated.
    _configManual = prevManual;
    _configAuto = prevAuto;
    _combineRecord = prevCombine;
    prefs.buttonConfigManual = prevManual;
    prefs.buttonConfigAuto = prevAuto;
    prefs.combineRecordButton = prevCombine;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = _ConfigStatus.noDevice;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device not connected — change not saved.')),
    );
  }

  Future<void> _updateConfig(int index, int action) async {
    final cfg = _config;
    final previous = cfg[index];
    setState(() {
      cfg[index] = action;
    });
    // Snapshot the intended bytes now, before any await. `cfg` is the live
    // per-mode list, so a later same-mode edit (or its failure-revert) while the
    // ensureConnection below is pending could otherwise mutate what THIS write
    // sends — leaking an unconfirmed/reverted value onto the firmware.
    final pending = List<int>.of(cfg);
    _persistSelectedConfig();

    // Only the device's currently-active mode is live on the firmware. Editing
    // the other mode just saves to prefs; it goes live when that mode activates
    // (DeviceProvider.pushActiveButtonConfig on the next mode switch / connect).
    if (_selectedManual != _activeIsManual) return;

    // Serialize against a concurrent flip / slot edit while this write is pending
    // (disables the switch + dropdowns) so overlapping mutations can't clobber.
    setState(() => _busy = true);
    final pairedDevice = context.read<DeviceProvider>().pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      try {
        final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id, force: true);
        if (connection != null) {
          // Send the snapshot taken at call time — not `_config` (a tab-dependent
          // getter, wrong mode if the tab switched) and not the live `cfg` (whose
          // values can change under us while this await is pending). Normalize
          // against the effective combine style so an *untouched* slot still
          // holding a Toggle byte (6) can't ship to firmware that rejects it —
          // on an unsupported device `_combineActive` is false, mapping 6 → 0.
          await connection
              .setButtonConfig(SharedPreferencesUtil.normalizeButtonConfigForCombine(pending, _combineActive));
          if (mounted) setState(() => _busy = false);
          return;
        }
      } catch (_) {
        // Fall through to revert + notify below.
      }
    }

    // Couldn't reach the device — revert the optimistic change so the UI keeps
    // reflecting what's actually on the firmware, and tell the user why.
    if (!mounted) return;
    setState(() {
      cfg[index] = previous;
      _busy = false;
      _status = _ConfigStatus.noDevice;
    });
    _persistSelectedConfig();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device not connected — change not saved.')),
    );
  }

  Future<void> _updateHapticConfig(int index, int pattern) async {
    final previous = _hapticConfig[index];
    setState(() {
      _hapticConfig[index] = pattern;
    });

    final pairedDevice = context.read<DeviceProvider>().pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      try {
        final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id, force: true);
        if (connection != null) {
          await connection.setHapticConfig(_hapticConfig);
          return;
        }
      } catch (_) {
        // Fall through to revert + notify below.
      }
    }

    // Couldn't reach the device — revert the optimistic change so the UI keeps
    // reflecting what's actually on the firmware, and tell the user why.
    if (!mounted) return;
    setState(() {
      _hapticConfig[index] = previous;
      _status = _ConfigStatus.noDevice;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device not connected — change not saved.')),
    );
  }

  Widget _buildConfigItem(String label, int index) {
    final options = _actionOptions;
    int currentVal = _config[index];
    // Defensive: coerce a value the current style doesn't offer (flip/migration
    // normalize the stored config, so this shouldn't happen — but a stale value
    // would otherwise assert inside DropdownButton).
    if (!options.containsKey(currentVal)) currentVal = 0;

    // Only offer a vibration pattern when this slot has an action assigned and
    // the firmware supports the haptic-config characteristic.
    final bool showHaptic = _hapticSupported && currentVal != 0;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
              DropdownButton<int>(
                value: currentVal,
                dropdownColor: const Color(0xFF2C2C2E),
                style: const TextStyle(color: Colors.white, fontSize: 16),
                disabledHint:
                    Text(options[currentVal] ?? 'None', style: const TextStyle(color: Colors.white38, fontSize: 16)),
                underline: Container(),
                onChanged: _controlsEnabled
                    ? (int? newValue) {
                        if (newValue != null) {
                          _updateConfig(index, newValue);
                        }
                      }
                    : null,
                items: options.entries.map((e) => DropdownMenuItem<int>(value: e.key, child: Text(e.value))).toList(),
              ),
            ],
          ),
        ),
        if (showHaptic) _buildHapticItem(index),
      ],
    );
  }

  // Warning shown in split mode when a tab maps Start but not Stop: you can
  // begin a recording with no button to end it. Auto softens the wording since
  // the Priority Recording safety cap backstops it (unless the cap is 0). Never
  // fires in combined mode (a Toggle stops itself) or from the flip (the remap
  // never auto-creates a lone Start).
  Widget _buildNoStopWarning() {
    if (_combineActive) return const SizedBox.shrink();
    final cfg = _config;
    final hasStart = cfg.contains(4);
    final hasStop = cfg.contains(5);
    if (!hasStart || hasStop) return const SizedBox.shrink();

    String msg;
    if (_selectedManual) {
      msg = 'You\'ve assigned Start Recording but no Stop Recording. You can start a recording but '
          'won\'t be able to stop it by button — assign a Stop Recording gesture too.';
    } else {
      final cap = SharedPreferencesUtil().priorityRecordMaxMinutes;
      msg = cap > 0
          ? 'You\'ve assigned Start Prio Rec but no Stop Prio Rec. You can start a priority recording but '
              'have no button to stop it — it will run until the $cap-minute safety cap.'
          : 'You\'ve assigned Start Prio Rec but no Stop Prio Rec. You can start a priority recording but '
              'have no button to stop it, and no safety cap is set.';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF3A2E12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF7A5C1E)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFE0A93B), size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: const TextStyle(color: Color(0xFFE8C97A), fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildHapticItem(int index) {
    int currentVal = _hapticConfig[index];
    if (currentVal >= _vibrationPatterns.length) currentVal = 0;

    return Padding(
      padding: const EdgeInsets.only(left: 32.0, right: 16.0, bottom: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Row(
            children: [
              Icon(Icons.vibration, color: Colors.white38, size: 16),
              SizedBox(width: 8),
              Text('Vibration', style: TextStyle(color: Colors.white54, fontSize: 14)),
            ],
          ),
          DropdownButton<int>(
            value: currentVal,
            dropdownColor: const Color(0xFF2C2C2E),
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            disabledHint:
                Text(_vibrationPatterns[currentVal], style: const TextStyle(color: Colors.white38, fontSize: 14)),
            underline: Container(),
            onChanged: _editable
                ? (int? newValue) {
                    if (newValue != null) {
                      _updateHapticConfig(index, newValue);
                    }
                  }
                : null,
            items: List.generate(_vibrationPatterns.length, (i) {
              return DropdownMenuItem<int>(
                value: i,
                child: Text(_vibrationPatterns[i]),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.bluetooth_disabled, color: Colors.white54, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Device not connected. Connect your Omi to view and edit button actions.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() => _status = _ConfigStatus.loading);
              _loadConfig();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    Widget seg(String label, bool manual) {
      final selected = _selectedManual == manual;
      return Expanded(
        child: GestureDetector(
          onTap: selected ? null : () => setState(() => _selectedManual = manual),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? Colors.deepPurpleAccent : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white54,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                fontSize: 14,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          seg('Manual mode', true),
          seg('Auto mode', false),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        leading: IconButton(
          icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Button Configuration', style: TextStyle(color: Colors.white, fontSize: 18)),
        centerTitle: true,
      ),
      body: _status == _ConfigStatus.loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Text(
                    'Customize what actions are triggered by different button presses, '
                    'and how the device vibrates to confirm them. Each recording mode '
                    'has its own button mapping.',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
                if (!_editable) ...[
                  _buildStatusBanner(),
                  const SizedBox(height: 16),
                ],
                // Only offered when the firmware accepts the Toggle action; on
                // older firmware the switch is hidden and split Start/Stop stays.
                if (_recordToggleSupported) ...[
                  Material(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: SwitchListTile(
                      value: _combineRecord,
                      onChanged: _controlsEnabled ? (v) => _setCombineRecord(v) : null,
                      title: const Text('Single recording button', style: TextStyle(color: Colors.white, fontSize: 16)),
                      subtitle: const Text(
                        'Use one button that toggles recording on/off, instead of separate Start and Stop actions. '
                        'Applies to both modes.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      activeThumbColor: Colors.deepPurpleAccent,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // Visibility of the red auto-mode Priority Recording markers.
                // A global display preference (no device/tab dependency), so it
                // sits with the other top-level switches above the mode selector.
                Material(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile(
                    value: _showHighPriorityMarker,
                    onChanged: (v) {
                      setState(() => _showHighPriorityMarker = v);
                      SharedPreferencesUtil().showHighPriorityMarker = v;
                    },
                    title: const Text('Show Priority Recording markers',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                    subtitle: const Text(
                      'Display the red markers added when you start a priority recording in auto mode.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    activeThumbColor: Colors.red,
                  ),
                ),
                const SizedBox(height: 12),
                // Warns (for the currently-viewed mode) when a Start action is
                // mapped with no matching Stop — kept above the selector so it's
                // visible whichever tab is showing.
                _buildNoStopWarning(),
                _buildModeSelector(),
                Padding(
                  padding: const EdgeInsets.only(top: 8.0, bottom: 12.0, left: 4.0),
                  child: Text(
                    _selectedManual == _activeIsManual
                        ? 'This mode is active on your device now.'
                        : 'Saved for when you switch to this mode.',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                Material(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      _buildConfigItem('Single Tap', 0),
                      const Divider(height: 1, color: Color(0xFF3C3C43)),
                      _buildConfigItem('Single Tap Hold', 1),
                      const Divider(height: 1, color: Color(0xFF3C3C43)),
                      _buildConfigItem('Double Tap', 2),
                      const Divider(height: 1, color: Color(0xFF3C3C43)),
                      _buildConfigItem('Double Tap Hold', 3),
                      const Divider(height: 1, color: Color(0xFF3C3C43)),
                      _buildConfigItem('Triple Tap', 4),
                      const Divider(height: 1, color: Color(0xFF3C3C43)),
                      _buildConfigItem('Triple Tap Hold', 5),
                    ],
                  ),
                ),
                // Marker's side effect was undisclosed until now: in auto mode it does
                // not merely bookmark, it forces the mic to keep capturing for ~1 min
                // regardless of what the VAD thinks. That is deliberate — you cannot
                // know whether the Omi considered the moment worth recording, so the
                // tap asserts that it was — but it has to be stated, not discovered.
                Padding(
                  padding: const EdgeInsets.only(top: 16.0),
                  child: Text(
                    _selectedManual
                        ? 'Marker only works while a recording is running. In standby there is nothing '
                            'to bookmark, so the tap does nothing at all.'
                        : 'Marker also records for at least a minute from the tap and will continue '
                            'automatic recording if sound is detected.',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Text(
                    'Note: 4 tap and hold (3s) always powers off the device. 5 tap and hold (10s) unpairs the device.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }
}
