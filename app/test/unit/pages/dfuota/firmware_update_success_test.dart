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

  /// What DIS reported on the re-paired link. `_onDeviceConnected` refreshes this from
  /// the device itself, which is the only reason the screen can claim a version.
  @override
  BtDevice? pairedDevice;

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

  /// The release closing the pre-DFU link, which reaches the provider a debounce
  /// after the flash reported success.
  void dropLink() {
    isConnected = false;
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

  /// Two frames, not pumpAndSettle.
  ///
  /// The waiting states hold a CircularProgressIndicator, which animates for as long as
  /// it is on screen — so pumpAndSettle never settles and times out instead. Two frames
  /// is what the page actually needs: one for the rebuild, one for the post-frame
  /// callback the re-pair latch schedules.
  Future<void> settleFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// Pump the real page and drive it to the state a finished flash leaves behind.
  ///
  /// `isInstalled` lives on FirmwareMixin and is normally set by the DFU success
  /// callback; setting it directly is what stands in for a flash, since nothing else
  /// on this screen can be reached without one.
  Future<void> pumpInstalledScreen(
    WidgetTester tester,
    FakeDeviceProvider provider, {
    PostFlashPhase phase = PostFlashPhase.idle,
    NavigatorObserver? observer,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<DeviceProvider>.value(
        value: provider,
        child: MaterialApp(
          navigatorObservers: [if (observer != null) observer],
          home: FirmwareUpdate(device: device),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // isInstalled and postFlashPhase both live on FirmwareMixin and are normally set by
    // the DFU success callback and the rediscovery loop it arms. Setting them directly
    // is what stands in for a flash, since nothing on this screen can be reached
    // without one. `idle` is the default because it is what the loop-less paths read —
    // iOS, and the frame before the loop is armed.
    final state = tester.state(find.byType(FirmwareUpdate)) as FirmwareMixin;
    state.isInstalled = true;
    state.postFlashPhase = phase;
    tester.element(find.byType(FirmwareUpdate)).markNeedsBuild();
    await settleFrames(tester);

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

    testWidgets('a link still up when the flash lands is not read as a re-pair', (tester) async {
      // _releasePairingOnSuccess runs unawaited and isInstalled flips in the same
      // synchronous block, so the first frame of this screen can be drawn over the
      // pre-DFU link — native's retry ladder keeps re-establishing it during the
      // flash, which is what the release exists to stop. Reading that as "re-paired"
      // would congratulate the user on a pairing that is about to be wiped.
      final provider = FakeDeviceProvider()..isConnected = true;
      await pumpInstalledScreen(tester, provider);

      expect(find.text('Paired again'), findsNothing, reason: 'nothing has been re-paired yet');
      expect(find.text('You need to pair again'), findsOneWidget);
    });

    testWidgets('the re-pair registers once the old link has gone first', (tester) async {
      final provider = FakeDeviceProvider()..isConnected = true;
      await pumpInstalledScreen(tester, provider);

      provider.dropLink(); // the release lands
      await tester.pumpAndSettle();
      provider.reconnect(); // and the user accepts the pairing request
      await tester.pumpAndSettle();

      expect(find.text('Paired again'), findsOneWidget);
      expect(find.text('You need to pair again'), findsNothing);
    });

    testWidgets('Done keeps the fallback while only the old link is up', (tester) async {
      // The consequential half: Done skipping the scan list is not recoverable on its
      // own, because this page's dispose cancels the post-flash rediscovery loop with
      // it — a user sent straight home has nothing left trying to reconnect.
      final observer = _RecordingObserver();
      final provider = FakeDeviceProvider()..isConnected = true;

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
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));

      expect(observer.pushedPages(builderContext), [isA<RecordingsPage>(), isA<FindDevicesPage>()]);

      await tester.pumpWidget(const SizedBox());
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

  group('waiting for the Omi instead of handing the user a scan list', () {
    testWidgets('offers no Done while the app is still looking', (tester) async {
      // The defect: Done was the loudest thing on the screen from the first frame, and
      // tapping it disposed the page — which cancels the very rediscovery loop that was
      // about to finish the job. Waiting has to be the default action, not the one you
      // have to know not to tap out of.
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting);

      expect(find.text('Done'), findsNothing, reason: 'there is nothing to be done yet');
      expect(find.text('Waiting for your Omi...'), findsOneWidget);
      expect(find.text('Pair manually instead'), findsOneWidget, reason: 'a disabled primary with no escape is a trap');
    });

    testWidgets('names the pairing request once the device has been heard', (tester) async {
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.connecting);

      expect(find.textContaining('Accept the pairing request if your phone asks'), findsOneWidget);
      expect(find.text('Pairing...'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
    });

    testWidgets('the escape hatch goes exactly where Done used to', (tester) async {
      // This is what makes it safe to make waiting the default: leaving early still
      // reaches the page that can complete a re-pair by hand, rather than a dead end.
      final observer = _RecordingObserver();
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting, observer: observer);

      final builderContext = tester.element(find.byType(FirmwareUpdate));
      observer.pushed.clear();
      await tester.ensureVisible(find.text('Pair manually instead'));
      await tester.tap(find.text('Pair manually instead'));

      expect(observer.pushedPages(builderContext), [isA<RecordingsPage>(), isA<FindDevicesPage>()]);
      expect(provider.firmwareStateReset, isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a back press does not leave the re-pair with nothing running', (tester) async {
      // A plain pop goes to Device Settings — a page about a device that is not paired
      // right now — and takes the loop with it, since dispose cancels it. Back while
      // waiting means "I do not want to wait", and the answer to that is the device
      // list. The AppBar button has to agree with the system gesture, which is why it
      // goes through maybePop rather than pop.
      final observer = _RecordingObserver();
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting, observer: observer);

      final builderContext = tester.element(find.byType(FirmwareUpdate));
      observer.pushed.clear();
      await tester.tap(find.byTooltip('Back'));

      expect(observer.pushedPages(builderContext), [isA<RecordingsPage>(), isA<FindDevicesPage>()],
          reason: 'back must reach the manual re-pair, not pop to a page that cannot do it');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back goes back again once the re-pair has landed', (tester) async {
      // The counterpart to the redirect above, and the reason the latch has to repaint
      // the whole page and not just its Consumer: `canPop` is evaluated in build(),
      // which a provider notification does not re-run, while the guard inside
      // onPopInvokedWithResult reads the latch live. Left stale, those two disagree —
      // the route refuses to pop AND the handler declines to redirect — so back does
      // nothing whatsoever for a user who is already connected. Which is why this has to
      // watch the route actually go: a pushed-routes assertion sees nothing in either
      // case and passes over the bug.
      final navigatorKey = GlobalKey<NavigatorState>();
      final provider = FakeDeviceProvider();
      await tester.pumpWidget(
        ChangeNotifierProvider<DeviceProvider>.value(
          value: provider,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: Text('the page they came from')),
          ),
        ),
      );
      navigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => FirmwareUpdate(device: device)));
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(FirmwareUpdate)) as FirmwareMixin;
      state.isInstalled = true;
      state.postFlashPhase = PostFlashPhase.waiting;
      tester.element(find.byType(FirmwareUpdate)).markNeedsBuild();
      await settleFrames(tester);

      provider.reconnect();
      await settleFrames(tester);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.byType(FirmwareUpdate), findsNothing, reason: 'a connected user pressing back is just going back');
      expect(find.text('the page they came from'), findsOneWidget);
    });

    testWidgets('a reconnect during the wait turns the wait into Done', (tester) async {
      final observer = _RecordingObserver();
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting, observer: observer);

      provider.reconnect(); // the user accepted the system pairing dialog
      await settleFrames(tester);

      expect(find.text('Paired again'), findsOneWidget);
      expect(find.text('Waiting for your Omi...'), findsNothing);
      expect(find.text('Pair manually instead'), findsNothing, reason: 'nothing left to pair');

      final builderContext = tester.element(find.byType(FirmwareUpdate));
      observer.pushed.clear();
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));

      expect(observer.pushedPages(builderContext), [isA<RecordingsPage>()]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the re-pair does not unblock background sync before setup has finished', (tester) async {
      // Tempting to clear isFirmwareUpdateInProgress here: the flash is over, and the
      // user may now sit on this screen for minutes with background sync blocked. It
      // costs more than it saves. _onDeviceConnected flips isConnected — which is what
      // closes this latch — early, and the deferred GATT recycleConnection() that drops
      // Android's stale attribute table runs at the END of setup, yielding to any sync
      // in flight. A sync started in between (the native alarm fires whatever the
      // foreground state, and prepareDFU does not cancel it) costs this connect the one
      // refresh a flash makes necessary. It clears when the user leaves instead.
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting);
      expect(provider.firmwareStateReset, isFalse);

      provider.reconnect();
      await settleFrames(tester);

      expect(find.text('Paired again'), findsOneWidget, reason: 'the latch still closes');
      expect(provider.firmwareStateReset, isFalse, reason: 'setup is still running on this very link');
    });

    testWidgets('the GATT-cache recycle does not walk the screen backwards', (tester) async {
      // The commonest path of all: a flash that changes the firmware revision changes
      // the GATT fingerprint, so setup recycles the link to drop Android's stale
      // attribute cache — a soft disconnect and a fresh connect, seconds after the
      // re-pair. Read live, that walks a user who is now being asked to WAIT for this
      // signal back to "waiting for your Omi". The pairing happened; a deliberate
      // recycle is not its undoing.
      final observer = _RecordingObserver();
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting, observer: observer);

      provider.reconnect();
      await settleFrames(tester);
      provider.dropLink(); // recycleConnection soft-disconnects
      await settleFrames(tester);

      expect(find.text('Paired again'), findsOneWidget, reason: 'the re-pair is not undone by a deliberate recycle');
      expect(find.text('You need to pair again'), findsNothing);

      final builderContext = tester.element(find.byType(FirmwareUpdate));
      observer.pushed.clear();
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));

      expect(observer.pushedPages(builderContext), [isA<RecordingsPage>()],
          reason: 'Done must not push a scan list at a user who is paired');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an expired window offers another search, not a dead end', (tester) async {
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.timedOut);

      expect(find.text('Search again'), findsOneWidget);
      expect(find.text('Could not find your Omi'), findsOneWidget);
      expect(find.text('Pair manually instead'), findsOneWidget);
      expect(find.textContaining('has not come back on its own yet'), findsOneWidget);
      expect(find.text('You need to pair again'), findsNothing,
          reason: 'the instructions describe a wait that is over');
    });

    testWidgets('iOS, where nothing re-pairs on its own, keeps the original screen', (tester) async {
      // The phase carries this, not a platform test: iOS never arms a loop (there is no
      // programmatic bond removal to arm one for), so it reads idle — and so does the
      // sliver of a frame on Android before the release runs, which is the honest answer
      // for that frame too.
      final provider = FakeDeviceProvider();
      await pumpInstalledScreen(tester, provider);

      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Pair manually instead'), findsNothing, reason: 'Done already is the manual route');
      expect(find.text('You need to pair again'), findsOneWidget);
      expect(find.textContaining('Tap Done below'), findsOneWidget);
    });
  });

  group('the version the device reports back', () {
    testWidgets('is shown when it is news', (tester) async {
      final provider = FakeDeviceProvider()
        ..pairedDevice =
            BtDevice(id: device.id, name: 'Omi', type: DeviceType.omi, rssi: 0, firmwareRevision: 'oo-3.1.0');
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting);

      provider.reconnect();
      await settleFrames(tester);

      expect(find.text('Now running oo-3.1.0'), findsOneWidget);
    });

    testWidgets('is silent when the read could be the pre-flash one', (tester) async {
      // getDeviceInfo() falls back to the device it was handed when the DIS read fails,
      // and on a reconnect that device can come from the stored btDevice pref — which
      // still carries the version we just flashed over. Rendering that would claim the
      // update did not take, in the one place a user looks to check that it did.
      final provider = FakeDeviceProvider()..pairedDevice = device; // same revision as before the flash
      await pumpInstalledScreen(tester, provider, phase: PostFlashPhase.waiting);

      provider.reconnect();
      await settleFrames(tester);

      expect(find.textContaining('Now running'), findsNothing);
      expect(find.text('Paired again'), findsOneWidget, reason: 'the re-pair itself is still reported');
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
