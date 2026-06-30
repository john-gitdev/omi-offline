import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:omi/backend/preferences.dart';
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

  // Labels match the firmware's config bytes (0=None, 1=Mute, 2=Marker,
  // 3=Toggle LED, 4=Record Start, 5=Record Stop). Mute is a no-op while recording
  // is under manual control, so it reads as disabled in the Manual view. Record
  // Start/Stop are explicit distinct-gesture controls: in manual they start/stop
  // a manual recording; in auto they bracket a red "Priority Recording" (so the
  // auto-tab labels say so, to distinguish it from the ambient auto capture).
  List<String> get _actions => [
        'None',
        _selectedManual ? 'Mute - Disabled' : 'Mute',
        'Marker',
        'Toggle LED',
        _selectedManual ? 'Start Recording' : 'Start Prio Rec',
        _selectedManual ? 'Stop Recording' : 'Stop Prio Rec',
      ];

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
      final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
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
      if (mounted) {
        setState(() {
          _configManual = prefs.buttonConfigManual;
          _configAuto = prefs.buttonConfigAuto;
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

  Future<void> _updateConfig(int index, int action) async {
    final cfg = _config;
    final previous = cfg[index];
    setState(() {
      cfg[index] = action;
    });
    _persistSelectedConfig();

    // Only the device's currently-active mode is live on the firmware. Editing
    // the other mode just saves to prefs; it goes live when that mode activates
    // (DeviceProvider.pushActiveButtonConfig on the next mode switch / connect).
    if (_selectedManual != _activeIsManual) return;

    final pairedDevice = context.read<DeviceProvider>().pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      try {
        final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
        if (connection != null) {
          // Write the config captured at call time, not `_config` — the user may
          // have switched the segmented control to the other mode while this
          // ensureConnection await was pending, which would otherwise install the
          // wrong mode's mapping on the device.
          await connection.setButtonConfig(cfg);
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
        final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
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
    int currentVal = _config[index];
    if (currentVal >= _actions.length) currentVal = 0;

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
                disabledHint: Text(_actions[currentVal], style: const TextStyle(color: Colors.white38, fontSize: 16)),
                underline: Container(),
                onChanged: _editable
                    ? (int? newValue) {
                        if (newValue != null) {
                          _updateConfig(index, newValue);
                        }
                      }
                    : null,
                items: List.generate(_actions.length, (i) {
                  return DropdownMenuItem<int>(
                    value: i,
                    child: Text(_actions[i]),
                  );
                }),
              ),
            ],
          ),
        ),
        if (showHaptic) _buildHapticItem(index),
      ],
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
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Text(
                    'Note: 4 tap and hold (3s) always powers off the device. 5 tap and hold (10s) unpairs the device.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                // Priority Recording markers are an auto-mode-only concept (manual-mode
                // RECORD_START writes no priority marker — every manual recording
                // is user-triggered), so only offer the visibility toggle on the
                // Auto tab.
                if (!_selectedManual)
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
              ],
            ),
    );
  }
}
