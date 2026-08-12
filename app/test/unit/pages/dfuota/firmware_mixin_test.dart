import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/pages/dfuota/firmware_mixin.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/services.dart';

/// What happens between "the flash succeeded" and "the Omi is paired again" — the
/// behaviour this PR is named after, and the half no screen shows.
///
/// Two guarantees are under test, and both are ordering guarantees, which is why
/// they need driving rather than reading:
///
/// 1. **Release before wipe.** The phone clears its key the instant mcumgr reports
///    success; the device clears its own on the next boot, seconds later. A connect
///    made in between forces a pairing the firmware must refuse, so the reconnect
///    ladder has to be stopped *first*. Swap the two calls and nothing fails except
///    on a real device, intermittently.
/// 2. **Reconnect on a sighting, not a timer.** Nothing may connect until the device
///    has actually been heard advertising, because that is the first moment it has
///    booted, run `transport_start()` and freed its key slot.
///
/// The scan runs against the **real** DeviceService and the real discoverer: only the
/// platform channels underneath are mocked, and peripherals are delivered the way
/// native delivers them, through [BleBridge]. So what these assert is the actual
/// discover-then-connect sequence, not a re-description of it.
class _MixinHost extends StatefulWidget {
  const _MixinHost();

  @override
  State<_MixinHost> createState() => _MixinHostState();
}

class _MixinHostState extends State<_MixinHost> with FirmwareMixin<_MixinHost> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const device = 'AA:BB:CC:DD:EE:FF';
  final btDevice = BtDevice(id: device, name: 'Omi', type: DeviceType.omi, rssi: 0);

  /// Every host call the paths under test make, in the order they were made. The
  /// order is the point — see guarantee 1 above.
  late List<String> hostCalls;

  /// Set when the peripheral should be reported to whoever is scanning. Flipping it
  /// mid-test is how "the device is still rebooting" becomes "the device is back".
  late bool deviceIsAdvertising;

  /// Makes `unmanageDevice` fail, to check the wipe is not skipped with it.
  late bool failRelease;

  /// Arguments of the last `manageDevice`, so the *shape* of the reconnect can be
  /// asserted and not merely that one happened.
  late Object? manageDeviceArgs;

  int scansStarted() => hostCalls.where((call) => call == 'startScan').length;

  BasicMessageChannel<Object?> hostChannel(String method) => BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.omi_pigeon.BleHostApi.$method',
        BleHostApi.pigeonChannelCodec,
      );

  void mockHost(String method, Future<Object?> Function(Object? message) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(hostChannel(method), handler);
  }

  // Pigeon reads a reply of length > 1 as an error and anything shorter as success.
  const ok = <Object?>[null];
  const boom = <Object?>['release_failed', 'unmanageDevice blew up', null];

  const mockedMethods = ['unmanageDevice', 'removeBond', 'startScan', 'stopScan', 'manageDevice'];

  setUp(() async {
    hostCalls = [];
    deviceIsAdvertising = false;
    failRelease = false;
    manageDeviceArgs = null;

    for (final method in ['unmanageDevice', 'removeBond', 'stopScan']) {
      mockHost(method, (message) async {
        hostCalls.add(method);
        if (method == 'unmanageDevice' && failRelease) return boom;
        return ok;
      });
    }
    mockHost('manageDevice', (message) async {
      hostCalls.add('manageDevice');
      manageDeviceArgs = message;
      return ok;
    });
    // Native reports what it hears through BleBridge, and the discoverer installs its
    // collector before it asks for a scan — so answering from inside startScan is the
    // same route a real advertisement takes.
    mockHost('startScan', (message) async {
      hostCalls.add('startScan');
      if (deviceIsAdvertising) {
        BleBridge.instance.peripheralDiscoveredCallback?.call(
          BlePeripheral(uuid: device, name: 'Omi', rssi: -50, serviceUuids: const []),
        );
      }
      return ok;
    });

    try {
      await ServiceManager.init();
    } catch (_) {
      // Already initialised by an earlier test in this file.
    }
    // discover() refuses to run unless the service is ready; start() only sets that
    // status, so this stands the real service up without any native traffic.
    ServiceManager.instance().device.start();
    ServiceManager.instance().device.clearDiscoveredDevices();
  });

  tearDown(() async {
    // The DeviceService is a process-wide singleton, so a test that reaches the
    // connect leaves a DeviceConnection behind — and _connectToDevice reuses a
    // non-null one rather than building a fresh transport, which would silently make
    // the next test's connect a no-op. Torn down here, while the host mocks are still
    // installed to answer it.
    await ServiceManager.instance().device.forgetDevice(device);
    for (final method in mockedMethods) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(hostChannel(method), null);
    }
  });

  Future<_MixinHostState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: _MixinHost()));
    return tester.state<_MixinHostState>(find.byType(_MixinHost));
  }

  /// The release is gated on the platform, and a host test runs on neither mobile
  /// one. Reset inside the body rather than in tearDown: flutter_test asserts the
  /// foundation debug variables are clear before tearDown gets a turn.
  Future<void> runOn(TargetPlatform platform, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// One scan (5 s) plus the gap that follows it (2 s), with room to spare.
  const scanCycle = Duration(seconds: 8);

  /// Long enough for the transport's 75 s device-ready backstop to expire, so a test
  /// that reaches the connect does not end with its timer still pending.
  const connectBackstop = Duration(seconds: 90);

  /// Run the loop to a stop: a cancel, then enough pumping for the scan that was
  /// already running to finish and the loop to notice.
  Future<void> settleLoop(WidgetTester tester, _MixinHostState state) async {
    state.cancelPostFlashReconnect();
    await tester.pump(scanCycle);
    await tester.pump(scanCycle);
  }

  group('releasing the pairing after a successful flash', () {
    testWidgets('releases the device before wiping the phone bond', (tester) async {
      await runOn(TargetPlatform.android, () async {
        final state = await pumpHost(tester);

        unawaited(state.releasePairingOnSuccess(btDevice));
        await tester.pump();
        await tester.pump();
        await settleLoop(tester, state);

        expect(hostCalls, contains('unmanageDevice'), reason: 'the release must happen');
        expect(hostCalls, contains('removeBond'), reason: 'the wipe must happen');
        expect(
          hostCalls.indexOf('unmanageDevice'),
          lessThan(hostCalls.indexOf('removeBond')),
          reason: 'wiping first leaves native reconnecting into a pairing the device must refuse',
        );
      });
    });

    testWidgets('wipes the bond even when the release fails', (tester) async {
      // Deliberate: this fails toward "device slot free, phone possibly stale", which
      // Forget Device clears. Skipping the wipe fails the other way, which nothing on
      // the phone can.
      await runOn(TargetPlatform.android, () async {
        failRelease = true;
        final state = await pumpHost(tester);

        unawaited(state.releasePairingOnSuccess(btDevice));
        await tester.pump();
        await tester.pump();
        await tester.pump(scanCycle);

        expect(hostCalls, contains('removeBond'));
        // And the rediscovery loop still runs. A failed release means native's ladder
        // was never stopped, which is damage already done — scanning cannot add to it,
        // since the only connect this makes is after a sighting, i.e. a device that has
        // finished booting. Gating the loop here would just hand the user a manual tap
        // that makes the identical ensureConnection call.
        expect(scansStarted(), greaterThan(0), reason: 'a failed release must not also cost the automatic re-pair');
        await settleLoop(tester, state);
      });
    });

    testWidgets('the release arms the rediscovery loop', (tester) async {
      // Ties the two halves together: without this the order test above would still
      // pass on a release that never re-armed anything, leaving the user to re-pair by
      // hand — which is the state this PR set out to remove.
      await runOn(TargetPlatform.android, () async {
        final state = await pumpHost(tester);

        unawaited(state.releasePairingOnSuccess(btDevice));
        await tester.pump();
        await tester.pump();
        await tester.pump(scanCycle);

        expect(scansStarted(), greaterThan(0));
        await settleLoop(tester, state);
      });
    });

    testWidgets('does nothing at all off Android', (tester) async {
      // iOS has no programmatic bond removal; there the device still frees its own
      // slot, which is the half the phone cannot undo.
      await runOn(TargetPlatform.iOS, () async {
        final state = await pumpHost(tester);

        await state.releasePairingOnSuccess(btDevice);
        await tester.pump(scanCycle);

        expect(hostCalls, isEmpty, reason: 'no release, no wipe, and no scan loop either');
      });
    });
  });

  group('reconnecting once the device is back on the air', () {
    testWidgets('does not connect while the device is still away', (tester) async {
      final state = await pumpHost(tester);

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);

      expect(scansStarted(), greaterThan(1), reason: 'it should keep looking rather than give up after one scan');
      expect(hostCalls, isNot(contains('manageDevice')),
          reason: 'connecting before the reboot finishes forces a pairing the device must refuse');

      await settleLoop(tester, state);
    });

    testWidgets('connects as soon as it hears the device', (tester) async {
      final state = await pumpHost(tester);

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(scanCycle);
      expect(hostCalls, isNot(contains('manageDevice')), reason: 'nothing has been heard yet');

      // The device finished rebooting and is advertising again.
      deviceIsAdvertising = true;
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);

      expect(hostCalls, contains('manageDevice'));
      await tester.pump(connectBackstop);
    });

    testWidgets('the connect it makes is the one the device list makes', (tester) async {
      // requiresBond: true is what re-pairs. A plain connect would try to reuse a key
      // that no longer exists on either side.
      deviceIsAdvertising = true;
      final state = await pumpHost(tester);

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);

      expect(manageDeviceArgs, <Object?>[device, true]);
      await tester.pump(connectBackstop);
    });

    testWidgets('leaving the page stops it looking', (tester) async {
      final state = await pumpHost(tester);

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(scanCycle);
      final scansBeforeCancel = scansStarted();

      await settleLoop(tester, state);
      await tester.pump(scanCycle);

      expect(scansStarted(), scansBeforeCancel, reason: 'a cancelled loop must not start another scan');
      expect(hostCalls, isNot(contains('manageDevice')));
    });

    testWidgets('a sighting arriving after the cancel is not acted on', (tester) async {
      // The flag cannot abort a scan already running, so the scan straddling the cancel
      // still returns the device. Reconnecting out of it would be reconnecting behind
      // the back of a user who has left the screen.
      final state = await pumpHost(tester);
      deviceIsAdvertising = true;

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(const Duration(seconds: 1)); // mid-scan
      await settleLoop(tester, state);
      await tester.pump(scanCycle);

      expect(scansStarted(), 1, reason: 'the straddling scan is the only one');
      expect(hostCalls, isNot(contains('manageDevice')));
    });

    testWidgets('the window bounds the loop', (tester) async {
      // Expiring is not a failure — it hands the re-pair back to Find Devices, which is
      // where Done lands the user anyway. The window is injectable so the bound can be
      // asserted without a two-minute test; the default is what ships.
      final state = await pumpHost(tester);

      unawaited(state.reconnectWhenDeviceReturns(btDevice, window: const Duration(milliseconds: 1)));
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);
      final scansAfterExpiry = scansStarted();

      await tester.pump(scanCycle);
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);

      expect(scansAfterExpiry, lessThanOrEqualTo(2),
          reason: 'the deadline gates the next scan, so the overshoot is the one already running');
      expect(scansStarted(), scansAfterExpiry, reason: 'an expired window must stop the loop, not slow it');
      expect(hostCalls, isNot(contains('manageDevice')));
    });
  });
}
