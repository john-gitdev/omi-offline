import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:omi/pages/settings/button_config_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';

// Mock connection to intercept setButtonConfig. Only the button-config methods are
// real; everything else on the DeviceConnection surface routes to noSuchMethod (these
// mocks are defined for completeness — the widget test below drives the page through
// the real, uninitialized ServiceManager, which the page handles gracefully).
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockDeviceProvider extends ChangeNotifier implements DeviceProvider {
  @override
  BtDevice? get pairedDevice => BtDevice(id: 'mock_id', name: 'Mock Omi', type: DeviceType.omi, rssi: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Minimal stub for ServiceManager
class MockDeviceService {
  final MockButtonConnection connection = MockButtonConnection();
  Future<DeviceConnection?> ensureConnection(String deviceId) async => connection;
}

void main() {
  testWidgets('ButtonConfigPage renders all six mappings and a not-connected state', (WidgetTester tester) async {
    // ServiceManager is a singleton and is not initialized in this test, so the page's
    // connection attempt fails gracefully and the page settles into its not-connected state.
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

    await tester.pumpAndSettle();

    // All six tap/hold rows render with a dropdown each.
    expect(find.text('Single Tap'), findsOneWidget);
    expect(find.text('Single Tap Hold'), findsOneWidget);
    expect(find.text('Double Tap'), findsOneWidget);
    expect(find.text('Double Tap Hold'), findsOneWidget);
    expect(find.text('Triple Tap'), findsOneWidget);
    expect(find.text('Triple Tap Hold'), findsOneWidget);
    expect(find.byType(DropdownButton<int>), findsNWidgets(6));

    // With no live device the page surfaces a not-connected banner (with Retry) instead
    // of silently showing editable defaults — the behaviour fixed alongside this test.
    expect(find.textContaining('Device not connected'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
