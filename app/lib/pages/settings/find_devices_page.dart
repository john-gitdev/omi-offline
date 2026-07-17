import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/widgets/dialog.dart';

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

  Future<void> _startScan({bool userInitiated = false}) async {
    if (_isScanning) return;

    if (ServiceManager.instance().device.status == DeviceServiceStatus.scanning) {
      // Only surface the "already scanning" notice for an explicit Scan/Refresh
      // tap. Automatic scans (page open, post-forget rescan) silently defer to
      // the running background scan instead of flashing a snackbar.
      if (userInitiated && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A background scan is already running. Please wait.')),
        );
      }
      return;
    }

    // Request permissions. bluetoothScan / bluetoothConnect are Android 12+ (API 31)
    // runtime permissions; on iOS permission_handler has no strategy for them and
    // reports permanentlyDenied, which would wedge the gate below and stop scanning
    // entirely. iOS needs only the single CoreBluetooth authorization and no location
    // grant for BLE, so branch the request and the gate by platform.
    final List<Permission> toRequest = Platform.isAndroid
        ? [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location]
        : [Permission.bluetooth];
    final Map<Permission, PermissionStatus> statuses = await toRequest.request();

    // Android scanning requires scan+connect (location is best-effort, as before);
    // iOS requires the bluetooth authorization.
    final List<Permission> mustGrant =
        Platform.isAndroid ? [Permission.bluetoothScan, Permission.bluetoothConnect] : [Permission.bluetooth];
    if (mustGrant.any((p) => statuses[p]?.isGranted != true)) {
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
    final deviceService = ServiceManager.instance().device;
    // Companion Device Pairing defaults ON (see preferences.companionDeviceEnabled):
    // companion status exempts the app from aggressive OEM battery-manager freezing so the
    // foreground service can recover from a ghost-GATT wedge on its own. We establish the
    // CompanionDeviceManager association BEFORE connecting (it never arms presence
    // observation — that path, the OnePlus/Oppo/Realme passive-link contention, was removed).
    // hasCompanionDeviceAssociation() gates the chooser to first-connect only, so an existing
    // association is never re-prompted. Users on an OEM where a bare association still hurts
    // can turn it off in App Settings. Background reconnect runs on the periodic sync
    // alarm/worker regardless.
    final isAndroid = TargetPlatform.android == Theme.of(context).platform;
    if (isAndroid &&
        SharedPreferencesUtil().companionDeviceEnabled &&
        !(await deviceService.hasCompanionDeviceAssociation())) {
      if (!mounted) return;
      bool? confirm = await showDialog<bool>(
        context: context,
        builder: (c) => getDialog(
          context,
          () => Navigator.of(context).pop(false),
          () => Navigator.of(context).pop(true),
          'Pair with Android',
          'To ensure a reliable connection, Android requires a system pairing association. This will show a system dialog to pair with ${device.name}.',
          confirmText: 'Pair',
        ),
      );
      if (confirm == true) {
        try {
          final associatedAddress = await deviceService.requestCompanionDeviceAssociation(device.id);
          if (associatedAddress.isEmpty) return; // User cancelled or failed
        } catch (e) {
          Logger.error('FindDevicesPage: Companion association failed: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Pairing failed: $e')),
            );
          }
          return;
        }
      } else {
        return;
      }
    }

    // Show connecting indicator
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => const Center(
        child: CircularProgressIndicator(color: Colors.deepPurpleAccent),
      ),
    );

    try {
      final connection =
          await ServiceManager.instance().device.ensureConnection(device.id, force: true, requiresBond: true);
      if (connection == null) {
        throw Exception(
            "Connection timed out. If it's nearby, toggle your phone's Bluetooth off and on to clear the system cache.");
      }

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

  Future<void> _forgetDevice() async {
    Logger.debug('FindDevicesPage: Forget Device tapped');
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Forget Device',
        'This clears the stored Bluetooth pairing so the app can rediscover the device fresh. Use this if the device is visible but refuses to connect (e.g. after a firmware update wiped bonding keys). You will need to reconnect afterwards.',
        confirmText: 'Forget',
      ),
    );
    if (confirm != true || !mounted) return;

    final prefs = SharedPreferencesUtil();
    final deviceId = prefs.btDevice.id;

    final provider = Provider.of<DeviceProvider>(context, listen: false);

    ServiceManager.instance().wal.getSyncs().cancelSync();
    ServiceManager.instance().wal.getSyncs().setDevice(null);

    if (deviceId.isNotEmpty) {
      await ServiceManager.instance().device.forgetDevice(deviceId);
      try {
        await BleHostApi().unmanageDevice(deviceId);
      } catch (_) {}
    }

    await prefs.btDeviceSet(BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0));
    prefs.deviceName = '';

    provider.setIsConnected(false);
    await provider.setConnectedDevice(null);
    provider.updateConnectingStatus(false);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Device forgotten — scan to reconnect')),
    );
    _startScan();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DeviceProvider>();
    final isBluetoothEnabled = provider.isBluetoothEnabled;
    final isServiceScanning = ServiceManager.instance().device.status == DeviceServiceStatus.scanning;
    final isScanning = _isScanning || isServiceScanning;

    // The page only populates _discoveredDevices from its own _startScan, but a
    // background scan (Reset Connection / periodicConnect) populates the service
    // list instead. Merge both — deduped by id — so background-scan results are
    // shown rather than leaving the page on "No devices found" after one runs.
    final mergedById = <String, BtDevice>{
      for (final d in ServiceManager.instance().device.devices) d.id: d,
      for (final d in _discoveredDevices) d.id: d,
    };
    final displayDevices = mergedById.values.toList();

    // Gate on the stored pairing (source of truth, also what _forgetDevice reads),
    // not provider.pairedDevice — that field is null at cold start and only hydrates
    // after a successful connect or a disconnect transition, so a provider gate would
    // hide the button in exactly the "stored device that refuses to connect" case it
    // exists for. We still read provider above via watch() so this rebuilds on changes.
    final hasPairedDevice = SharedPreferencesUtil().btDevice.id.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text('Find Omi Devices', style: TextStyle(color: Colors.white)),
        actions: [
          if (isScanning)
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
          else if (isBluetoothEnabled)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed: () => _startScan(userInitiated: true),
              tooltip: 'Refresh devices',
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: !isBluetoothEnabled
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FaIcon(FontAwesomeIcons.bluetooth, size: 60, color: Colors.grey.shade700),
                        const SizedBox(height: 24),
                        const Text(
                          'Bluetooth is Off',
                          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Please enable Bluetooth to scan for devices',
                          style: TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                      ],
                    ),
                  )
                : isScanning && displayDevices.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Colors.deepPurpleAccent,
                        ),
                      )
                    : displayDevices.isEmpty
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
                                  onPressed: () => _startScan(userInitiated: true),
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
                            itemCount: displayDevices.length,
                            itemBuilder: (context, index) {
                              final device = displayDevices[index];
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
          ),
          if (hasPairedDevice)
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _forgetDevice,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                    foregroundColor: Colors.redAccent,
                    elevation: 0,
                    side: const BorderSide(color: Colors.redAccent, width: 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'Reset Connection',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
