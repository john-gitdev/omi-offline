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
  List<int> _config = [0, 0, 2, 1, 3, 0];

  // Manual mode is the default capture mode. In it the firmware ignores the Mute
  // action and the Marker action instead toggles recording on/off — so the labels
  // are tailored to the active mode. Read once: the page is pushed fresh each time.
  final bool _manualMode = SharedPreferencesUtil().manualMode;

  // Labels are index-addressed to match the firmware's config bytes
  // (0=None, 1=Mute, 2=Marker, 3=Toggle LED); only the mode-sensitive labels change.
  List<String> get _actions => [
        'None',
        _manualMode ? 'Mute - Disabled' : 'Mute',
        _manualMode ? 'Start/Stop Recording' : 'Marker',
        'Toggle LED',
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
      final config = await connection.getButtonConfig();
      if (config != null && config.length == 6) {
        if (mounted) {
          setState(() {
            _config = config;
            _status = _ConfigStatus.ready;
          });
        }
        return;
      }
      // Live connection but the read came back empty (transient BLE hiccup) — surface the
      // not-connected/retry state rather than letting the user edit a phantom config.
      if (mounted) setState(() => _status = _ConfigStatus.noDevice);
    } catch (_) {
      if (mounted) setState(() => _status = _ConfigStatus.noDevice);
    }
  }

  Future<void> _updateConfig(int index, int action) async {
    final previous = _config[index];
    setState(() {
      _config[index] = action;
    });

    final pairedDevice = context.read<DeviceProvider>().pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      try {
        final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
        if (connection != null) {
          await connection.setButtonConfig(_config);
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
      _config[index] = previous;
      _status = _ConfigStatus.noDevice;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device not connected — change not saved.')),
    );
  }

  Widget _buildConfigItem(String label, int index) {
    int currentVal = _config[index];
    if (currentVal >= _actions.length) currentVal = 0;

    return Padding(
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
                    'Customize what actions are triggered by different button presses.',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
                if (!_editable) ...[
                  _buildStatusBanner(),
                  const SizedBox(height: 16),
                ],
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
              ],
            ),
    );
  }
}
