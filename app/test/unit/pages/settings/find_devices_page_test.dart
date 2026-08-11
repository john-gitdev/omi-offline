import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/pages/settings/find_devices_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';

/// Find Devices is only reachable while disconnected, so everything it does once a
/// link comes up is behaviour no user can trigger from the page itself — the pairing
/// request is accepted in the Android system dialog. These tests drive that from the
/// one thing the page can observe: DeviceProvider.
///
/// The page is driven for real (not a stripped-down copy) so the route mechanics —
/// which route is popped, and whether it is popped at all while a dialog covers the
/// page — are exercised as shipped.
class FakeDeviceProvider extends ChangeNotifier implements DeviceProvider {
  @override
  bool isConnected = false;

  @override
  BtDevice? connectedDevice;

  @override
  bool isBluetoothEnabled = true;

  void connect(BtDevice device) {
    connectedDevice = device;
    isConnected = true;
    notifyListeners();
  }

  /// Everything the page reads is declared above; anything else it touches would be
  /// a surprise, and noSuchMethod makes that surprise loud rather than silent.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bondedChannelName = 'dev.flutter.pigeon.omi_pigeon.BleHostApi.getBondedDeviceIds';
  const permissionChannel = MethodChannel('flutter.baseflow.com/permissions/methods');

  /// Answers of the bonded-device query, in call order. Recorded so a test can assert
  /// the page asked at all.
  late List<String> bondedIds;
  late int bondedQueryCount;

  /// Held open by the one test that needs the permission request to still be in
  /// flight while the page goes away — the real one is a system window the user can
  /// sit in front of for as long as they like. Null in every other test, where the
  /// answer comes back immediately.
  Completer<void>? permissionGate;

  void installPlatformMocks() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // permission_handler: grant whatever the page asks for, so _startScan gets past
    // its gate and reaches the discovery + bond-refresh path.
    messenger.setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'requestPermissions') {
        await permissionGate?.future;
        final requested = List<int>.from(call.arguments as List);
        // 1 == PermissionStatus.granted.
        return <int, int>{for (final p in requested) p: 1};
      }
      if (call.method == 'checkPermissionStatus') return 1;
      if (call.method == 'checkServiceStatus') return 1;
      return null;
    });

    const bondedChannel = BasicMessageChannel<Object?>(bondedChannelName, BleHostApi.pigeonChannelCodec);
    messenger.setMockDecodedMessageHandler<Object?>(bondedChannel, (Object? message) async {
      bondedQueryCount++;
      // Pigeon wraps a successful reply as a single-element list.
      return <Object?>[bondedIds];
    });
  }

  setUp(() async {
    bondedIds = <String>[];
    bondedQueryCount = 0;
    permissionGate = null;
    installPlatformMocks();
    // The page reaches for the singleton in _startScan before anything else. A real
    // DeviceService that was never start()ed reports status `init`, so discover()
    // short-circuits to an empty list without touching the BLE channels — exactly the
    // "nothing in range" state these tests want.
    try {
      await ServiceManager.init();
    } catch (_) {
      // Already initialised by an earlier test in this file.
    }
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissionChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(
      const BasicMessageChannel<Object?>(bondedChannelName, BleHostApi.pigeonChannelCodec),
      null,
    );
  });

  /// A host route with a button that pushes Find Devices, mirroring how every real
  /// entry point reaches it — pushed onto something, never as the root route.
  Widget host(FakeDeviceProvider provider) {
    return ChangeNotifierProvider<DeviceProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const FindDevicesPage()),
                ),
                child: const Text('open find devices'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openFindDevices(WidgetTester tester, FakeDeviceProvider provider) async {
    await tester.pumpWidget(host(provider));
    await tester.tap(find.text('open find devices'));
    await tester.pumpAndSettle();
    expect(find.text('Find Omi Devices'), findsOneWidget, reason: 'the page under test should be on screen');
  }

  group('closes itself once an Omi connects', () {
    testWidgets('a connect that lands with the page open pops it', (tester) async {
      final provider = FakeDeviceProvider();
      await openFindDevices(tester, provider);

      // The post-update case: the user accepted the system pairing dialog, so the
      // link comes up with nothing on this page having been touched.
      provider.connect(BtDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Omi', type: DeviceType.omi, rssi: 0));
      await tester.pumpAndSettle();

      expect(find.text('Find Omi Devices'), findsNothing);
      expect(find.text('open find devices'), findsOneWidget, reason: 'it should pop back to where it was pushed from');
    });

    testWidgets('an unrelated notification while disconnected leaves it open', (tester) async {
      final provider = FakeDeviceProvider();
      await openFindDevices(tester, provider);

      provider.notifyListeners();
      await tester.pumpAndSettle();

      expect(find.text('Find Omi Devices'), findsOneWidget);
    });

    testWidgets('opening onto an already-live link closes it without waiting for a notification', (tester) async {
      // Nothing notifies here after the push, so only the post-frame evaluation in
      // didChangeDependencies can catch this.
      final provider = FakeDeviceProvider()
        ..isConnected = true
        ..connectedDevice = BtDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Omi', type: DeviceType.omi, rssi: 0);

      await tester.pumpWidget(host(provider));
      await tester.tap(find.text('open find devices'));
      await tester.pumpAndSettle();

      expect(find.text('Find Omi Devices'), findsNothing);
      expect(find.text('open find devices'), findsOneWidget);
    });

    testWidgets('a connect during the permission request does not outlive the page', (tester) async {
      // The permission prompt is a system window, not a Flutter route, so this page
      // stays `isCurrent` behind it and the auto-close pops it right out from under
      // the scan that is still waiting on the answer. Whatever that scan touches
      // afterwards is touching a disposed state.
      final gate = Completer<void>();
      permissionGate = gate;
      final provider = FakeDeviceProvider();
      await openFindDevices(tester, provider);

      provider.connect(BtDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Omi', type: DeviceType.omi, rssi: 0));
      await tester.pumpAndSettle();
      expect(find.text('Find Omi Devices'), findsNothing, reason: 'the connect should have closed it');

      gate.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'the answer landed after dispose and must be dropped, not used');
    });

    testWidgets('a connect under a dialog pops the page, not the dialog', (tester) async {
      final provider = FakeDeviceProvider();
      await openFindDevices(tester, provider);

      // Stand in for the connecting-spinner dialog the tap path puts up: it is pushed
      // on the same navigator, so a page that popped on connect would take this
      // instead and leave the user staring at the scan list with the spinner gone.
      final pageContext = tester.element(find.text('Find Omi Devices'));
      unawaitedShowDialog(pageContext);
      await tester.pumpAndSettle();
      expect(find.text('a dialog'), findsOneWidget);

      provider.connect(BtDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Omi', type: DeviceType.omi, rssi: 0));
      await tester.pumpAndSettle();

      expect(find.text('a dialog'), findsOneWidget, reason: 'the dialog must survive');
      expect(find.text('Find Omi Devices'), findsOneWidget, reason: 'and the page must wait its turn');

      // Once the dialog goes, the next notification finds the page topmost and closes
      // it — which is why the close is retried on every notification rather than only
      // on the connect transition.
      Navigator.of(tester.element(find.text('a dialog'))).pop();
      await tester.pumpAndSettle();
      provider.notifyListeners();
      await tester.pumpAndSettle();

      expect(find.text('Find Omi Devices'), findsNothing);
    });
  });

  group('bond marks', () {
    testWidgets('the page asks the OS for the bonded set on open', (tester) async {
      bondedIds = <String>['AA:BB:CC:DD:EE:FF'];
      final provider = FakeDeviceProvider();
      await openFindDevices(tester, provider);

      expect(bondedQueryCount, greaterThan(0), reason: 'the marks cannot render without this answer');
    });
  });

  group('DeviceStatusIcon', () {
    Widget iconHost(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('connected renders a green check', (tester) async {
      await tester.pumpWidget(iconHost(const DeviceStatusIcon(isConnected: true, isBonded: true)));

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.check_circle);
      expect(icon.color, const Color(0xFF4ADE80));
      expect(find.byTooltip('Connected'), findsOneWidget);
    });

    testWidgets('bonded but not connected renders a grey check', (tester) async {
      await tester.pumpWidget(iconHost(const DeviceStatusIcon(isConnected: false, isBonded: true)));

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.check_circle);
      expect(icon.color, Colors.grey.shade600);
      expect(find.byTooltip('Paired — not connected'), findsOneWidget);
    });

    testWidgets('an unknown device keeps the chevron', (tester) async {
      await tester.pumpWidget(iconHost(const DeviceStatusIcon(isConnected: false, isBonded: false)));

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.chevron_right);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('connected wins over bonded — never the weaker of the two facts', (tester) async {
      // A live link is always also bonded, so this is the ordinary state of the
      // connected row, not a corner case.
      await tester.pumpWidget(iconHost(const DeviceStatusIcon(isConnected: true, isBonded: true)));

      expect(tester.widget<Icon>(find.byType(Icon)).color, const Color(0xFF4ADE80));
    });
  });
}

/// Pushes a bare dialog on the page's navigator without awaiting it — the same shape
/// as the connecting spinner in _connectToDevice, whose future outlives the tap.
void unawaitedShowDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(content: Text('a dialog')),
  );
}
