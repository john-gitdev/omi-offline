import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/dfuota/firmware_mixin.dart';
import 'package:omi/pages/dfuota/firmware_update.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/pages/settings/find_devices_page.dart';
import 'package:omi/providers/device_provider.dart';

/// The post-update screen has to react to something no tap on it produces: the
/// Android system pairing dialog can be accepted while it is still on screen, and
/// the reconnect that follows arrives from DeviceProvider alone.
///
/// The bug these guard against is the screen instructing the user to redo what they
/// have already done — "You need to pair again" in front of a connected device, and
/// a Done button that lands them on a scan list they cannot act on.
class FakeDeviceProvider extends ChangeNotifier implements DeviceProvider {
  @override
  bool isConnected = false;

  bool firmwareStateReset = false;
  bool onUpdatePage = false;

  @override
  void setOnFirmwareUpdatePage(bool value) => onUpdatePage = value;

  @override
  void resetFirmwareUpdateState() => firmwareStateReset = true;

  void reconnect() {
    isConnected = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final device = BtDevice(
    id: 'AA:BB:CC:DD:EE:FF',
    name: 'Omi',
    type: DeviceType.omi,
    rssi: 0,
    firmwareRevision: 'oo-3.0.2',
  );

  /// Pump the real page and drive it to the state a finished flash leaves behind.
  ///
  /// `isInstalled` lives on FirmwareMixin and is normally set by the DFU success
  /// callback; setting it directly is what stands in for a flash, since nothing else
  /// on this screen can be reached without one.
  Future<void> pumpInstalledScreen(WidgetTester tester, FakeDeviceProvider provider) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<DeviceProvider>.value(
        value: provider,
        child: MaterialApp(home: FirmwareUpdate(device: device)),
      ),
    );
    await tester.pumpAndSettle();

    (tester.state(find.byType(FirmwareUpdate)) as FirmwareMixin).isInstalled = true;
    tester.element(find.byType(FirmwareUpdate)).markNeedsBuild();
    await tester.pumpAndSettle();

    expect(find.text('Firmware updated!'), findsOneWidget);
  }

  group('the success screen tracks the re-pair', () {
    testWidgets('before the re-pair it asks for one', (tester) async {
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider);

      expect(find.text('You need to pair again'), findsOneWidget);
      expect(find.text('Paired again'), findsNothing);
      expect(find.textContaining('is restarting to finish the update'), findsOneWidget);
    });

    testWidgets('a reconnect while the screen is up replaces the instructions', (tester) async {
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider);

      // The user accepted the system pairing dialog without touching this screen.
      provider.reconnect();
      await tester.pumpAndSettle();

      expect(find.text('You need to pair again'), findsNothing,
          reason: 'telling a connected user to pair again is the defect this exists for');
      expect(find.text('Paired again'), findsOneWidget);
      expect(find.textContaining('is paired again and connected'), findsOneWidget);
    });

    testWidgets('Done pushes exactly the destinations for the current state', (tester) async {
      // Ties the button to postUpdateDestinations, so the pure tests below are not
      // asserting a helper nothing calls.
      //
      // The pushed routes are inspected without ever pumping a frame: both
      // destinations are real app pages that need providers and services this test
      // has no business standing up, and a route that is never given a frame is
      // never built. tap() dispatches the tap synchronously and does not pump.
      final observer = _RecordingObserver();
      final provider = FakeDeviceProvider();

      await tester.pumpWidget(
        ChangeNotifierProvider<DeviceProvider>.value(
          value: provider,
          child: MaterialApp(
            navigatorObservers: [observer],
            home: FirmwareUpdate(device: device),
          ),
        ),
      );
      await tester.pumpAndSettle();
      (tester.state(find.byType(FirmwareUpdate)) as FirmwareMixin).isInstalled = true;
      tester.element(find.byType(FirmwareUpdate)).markNeedsBuild();
      await tester.pumpAndSettle();

      final builderContext = tester.element(find.byType(FirmwareUpdate));
      observer.pushed.clear();
      // The un-reconnected screen is taller than the test viewport, so Done starts
      // off-screen; scrolling it into view is not part of what is under test.
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));

      expect(provider.firmwareStateReset, isTrue);
      expect(observer.pushedPages(builderContext), [isA<RecordingsPage>(), isA<FindDevicesPage>()]);

      // Drop the tree before any frame can build those pages.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Done after a reconnect pushes home and nothing else', (tester) async {
      final observer = _RecordingObserver();
      final provider = FakeDeviceProvider();

      await tester.pumpWidget(
        ChangeNotifierProvider<DeviceProvider>.value(
          value: provider,
          child: MaterialApp(
            navigatorObservers: [observer],
            home: FirmwareUpdate(device: device),
          ),
        ),
      );
      await tester.pumpAndSettle();
      (tester.state(find.byType(FirmwareUpdate)) as FirmwareMixin).isInstalled = true;
      tester.element(find.byType(FirmwareUpdate)).markNeedsBuild();
      await tester.pumpAndSettle();
      provider.reconnect();
      await tester.pumpAndSettle();

      final builderContext = tester.element(find.byType(FirmwareUpdate));
      observer.pushed.clear();
      // The un-reconnected screen is taller than the test viewport, so Done starts
      // off-screen; scrolling it into view is not part of what is under test.
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));

      expect(observer.pushedPages(builderContext), [isA<RecordingsPage>()]);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('where Done lands', () {
    test('not yet re-paired: home, then the scan list on top', () {
      final destinations = FirmwareUpdate.postUpdateDestinations(isReconnected: false);

      expect(destinations, hasLength(2));
      expect(destinations.first, isA<RecordingsPage>(), reason: 'home has to be the base of the stack');
      expect(destinations.last, isA<FindDevicesPage>());
    });

    test('already re-paired: home alone', () {
      final destinations = FirmwareUpdate.postUpdateDestinations(isReconnected: true);

      expect(destinations, hasLength(1));
      expect(destinations.single, isA<RecordingsPage>());
      expect(destinations.whereType<FindDevicesPage>(), isEmpty,
          reason: 'a connected user cannot act on the scan list — it would only need dismissing');
    });
  });
}

/// Captures pushes so the Done button's route stack can be read back without any of
/// its destinations being built.
class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushed.add(route);

  /// The widget each pushed route *would* build. Calling a PageRoute's builder only
  /// constructs the widget object — it does not mount or build it.
  List<Widget> pushedPages(BuildContext context) =>
      pushed.whereType<MaterialPageRoute<dynamic>>().map((route) => route.builder(context)).toList();
}
