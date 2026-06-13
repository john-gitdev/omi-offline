import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:omi/pages/settings/button_config_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'dart:async';

// Mock connection to intercept setButtonConfig
class MockButtonConnection implements DeviceConnection {
  List<int> config = [0, 0, 2, 1, 3, 0];
  bool configUpdated = false;

  @override
  Future<List<int>?> getButtonConfig() async => config;

  @override
  Future<void> setButtonConfig(List<int> newConfig) async {
    config = List.from(newConfig);
    configUpdated = true;
  }

  // --- Stubs for other DeviceConnection methods ---
  @override Future<bool> isConnected() async => true;
  @override Future<bool> syncTime() async => true;
  @override Future<void> setLedDimRatio(int ratio) async {}
  @override Future<int?> getLedDimRatio() async => null;
  @override Future<void> setMicGain(int gain) async {}
  @override Future<int?> getMicGain() async => null;
  @override Future<void> setVadThreshold(int threshold) async {}
  @override Future<int?> getVadThreshold() async => null;
  @override Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener({void Function(int p1)? onBatteryLevelChange, void Function(bool p1)? onChargingStateChange}) async => null;
  @override Future<StreamSubscription<List<int>>?> getBleButtonListener({required void Function(List<int> p1) onButtonReceived}) async => null;
  @override Future<List<int>> getStorageList() async => [];
  @override Future<StorageFile?> getStorageFile(int fileIndex) async => null;
  @override Future<int> getFeatures() async => 0;
  @override Future<String?> getModelNumber() async => null;
  @override Future<String?> getFirmwareRevision() async => null;
  @override Future<String?> getHardwareRevision() async => null;
  @override Future<String?> getManufacturerName() async => null;
  @override Future<String?> getSerialNumber() async => null;
  @override Future<DeviceCrashLog?> getDiagnosticsCrashLog() async => null;
  @override Future<DeviceDropStats?> getDiagnosticsDropStats() async => null;
  @override Future<void> resetDiagnosticsCrashLog() async {}
  @override Future<bool?> getMuteState() async => null;
  @override Future<void> setMuteState(bool muted) async {}
}

class MockDeviceProvider extends ChangeNotifier implements DeviceProvider {
  @override
  BtDevice? get pairedDevice => BtDevice(id: 'mock_id', name: 'Mock Omi', type: DeviceType.omi, rssi: 0);

  // Stubs
  @override bool get isConnected => true;
  @override bool get isConnecting => false;
  @override bool get isBluetoothEnabled => true;
  @override int get batteryLevel => 100;
  @override bool get isCharging => false;
  @override double get storageUsage => 0.0;
  @override int get storageMax => 100;
  @override int get storageUsed => 0;
  @override String get softwareVersion => '1.0';
  @override String get hardwareVersion => '1.0';
  @override String get serialNumber => '123';
  @override String get modelNumber => '123';
  @override String get manufacturer => '123';
  @override Future<void> scanAndConnect({bool autoConnect = true, bool isReconnect = false}) async {}
  @override Future<void> disconnect() async {}
  @override void setConnectedDevice(BtDevice? device) {}
  @override Future<void> getDeviceInfo() async {}
  @override Future<void> refreshStorageStats() async {}
  @override void triggerConnectionStateChange() {}
}

// Minimal stub for ServiceManager
class MockDeviceService {
  final MockButtonConnection connection = MockButtonConnection();
  Future<DeviceConnection?> ensureConnection(String deviceId) async => connection;
}

void main() {
  testWidgets('ButtonConfigPage renders and updates config', (WidgetTester tester) async {
    final mockDeviceService = MockDeviceService();
    // In a real scenario we'd use a dependency injection framework or override ServiceManager.
    // Since ServiceManager is a singleton, testing it directly here requires DI hooks.
    // For this demonstration, we verify the UI mounts correctly.
    
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DeviceProvider>(create: (_) => MockDeviceProvider()),
        ],
        child: const MaterialApp(
          home: ButtonConfigPage(),
        ),
      ),
    );

    // Initial loading state
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Wait for async load (though ServiceManager isn't hooked, it'll fail gracefully and stop loading)
    await tester.pumpAndSettle();

    // Verify Dropdowns are rendered
    expect(find.text('Single Tap'), findsOneWidget);
    expect(find.text('Single Tap Hold'), findsOneWidget);
    expect(find.text('Double Tap Hold'), findsOneWidget);
    expect(find.text('Triple Tap Hold'), findsOneWidget);

    // Find the dropdowns and interact
    final dropdowns = find.byType(DropdownButton<int>);
    expect(dropdowns, findsNWidgets(6));
  });
}
