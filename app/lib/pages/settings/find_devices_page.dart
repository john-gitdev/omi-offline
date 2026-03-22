import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/logger.dart';

class FindDevicesPage extends StatefulWidget {
  const FindDevicesPage({super.key});

  @override
  State<FindDevicesPage> createState() => _FindDevicesPageState();
}

class _FindDevicesPageState extends State<FindDevicesPage> {
  List<BtDevice> _discoveredDevices = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    if (_isScanning) return;

    // Request permissions
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    if (statuses[Permission.bluetoothScan] != PermissionStatus.granted ||
        statuses[Permission.bluetoothConnect] != PermissionStatus.granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bluetooth permissions are required to find Omi devices.')),
        );
      }
      return;
    }

    setState(() {
      _isScanning = true;
      _discoveredDevices = [];
    });

    try {
      // Warmup: give BLE stack a moment to settle before scanning
      await Future.delayed(const Duration(milliseconds: 500));

      var devices = await ServiceManager.instance().device.discover();

      // Auto-retry once on empty results
      if (devices.isEmpty && mounted) {
        await Future.delayed(const Duration(milliseconds: 500));
        devices = await ServiceManager.instance().device.discover();
      }

      if (mounted) {
        setState(() {
          _discoveredDevices = devices;
        });
      }
    } catch (e) {
      Logger.error('FindDevicesPage: Error scanning for devices: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error scanning: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<void> _connectToDevice(BtDevice device) async {
    final deviceProvider = context.read<DeviceProvider>();

    // Show connecting indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(
        child: CircularProgressIndicator(color: Colors.deepPurpleAccent),
      ),
    );

    try {
      await ServiceManager.instance().device.ensureConnection(device.id);

      // Save paired device — state transitions (setConnectedDevice, setIsConnected, WAL sync, etc.)
      // are handled by DeviceProvider._onDeviceConnected via the onDeviceConnectionStateChanged callback.
      SharedPreferencesUtil().btDevice = device;

      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        Navigator.of(context).pop(); // Go back to settings
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected to ${device.name}')),
        );
      }
    } catch (e) {
      Logger.error('FindDevicesPage: Error connecting to device: $e');
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text('Find Omi Devices', style: TextStyle(color: Colors.white)),
        actions: [
          if (_isScanning)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(right: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed: _startScan,
            ),
        ],
      ),
      body: _discoveredDevices.isEmpty && !_isScanning
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FaIcon(FontAwesomeIcons.bluetooth, size: 64, color: Colors.grey.shade800),
                  const SizedBox(height: 24),
                  const Text(
                    'No Omi devices found nearby.',
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Make sure your Omi is turned on.',
                    style: TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: _startScan,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurpleAccent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Scan Again'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _discoveredDevices.length,
              itemBuilder: (context, index) {
                final device = _discoveredDevices[index];
                return Card(
                  color: const Color(0xFF1C1C1E),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    leading: const CircleAvatar(
                      backgroundColor: Colors.deepPurpleAccent,
                      child: FaIcon(FontAwesomeIcons.microchip, color: Colors.white, size: 18),
                    ),
                    title: Text(
                      device.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      device.id,
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                    onTap: () => _connectToDevice(device),
                  ),
                );
              },
            ),
    );
  }
}
