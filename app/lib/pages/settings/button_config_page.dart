import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';

class ButtonConfigPage extends StatefulWidget {
  const ButtonConfigPage({super.key});

  @override
  State<ButtonConfigPage> createState() => _ButtonConfigPageState();
}

class _ButtonConfigPageState extends State<ButtonConfigPage> {
  bool _isLoading = true;
  List<int> _config = [0, 0, 2, 1, 3, 0];

  final List<String> _actions = ['None', 'Mute', 'Marker', 'Toggle LED'];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final deviceProvider = context.read<DeviceProvider>();
    final pairedDevice = deviceProvider.pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
      if (connection != null) {
        final config = await connection.getButtonConfig();
        if (config != null && config.length == 6) {
          if (mounted) {
            setState(() {
              _config = config;
              _isLoading = false;
            });
          }
          return;
        }
      }
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _updateConfig(int index, int action) async {
    setState(() {
      _config[index] = action;
    });
    final deviceProvider = context.read<DeviceProvider>();
    final pairedDevice = deviceProvider.pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      final connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
      if (connection != null) {
        await connection.setButtonConfig(_config);
      }
    }
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
            underline: Container(),
            onChanged: (int? newValue) {
              if (newValue != null) {
                _updateConfig(index, newValue);
              }
            },
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Customize what actions are triggered by different button presses.',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
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
                  padding: EdgeInsets.all(16.0),
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
