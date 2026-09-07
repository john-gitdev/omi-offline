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

  // unsubscribeCharacteristic is not part of anything under test: it is reached only by
  // tearDown's forgetDevice, and only in the one test that drives the link all the way
  // to connected. Unmocked, pigeon throws a channel error there — after the test body
  // has passed — which the runner reports as a failure of a test that had already
  // succeeded.
  const mockedMethods = [
    'unmanageDevice',
    'removeBond',
    'startScan',
    'stopScan',
    'manageDevice',
    'unsubscribeCharacteristic',
  ];

  setUp(() async {
    hostCalls = [];
    deviceIsAdvertising = false;
    failRelease = false;
    manageDeviceArgs = null;

    for (final method in ['unmanageDevice', 'removeBond', 'stopScan', 'unsubscribeCharacteristic']) {
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
    //
    // Timed out because a test that fails an expectation never reaches its settleLoop,
    // so its rediscovery loop is still holding DeviceService's mutex — on a FAKE timer
    // that nothing here will ever advance, since tearDown runs outside the test's async
    // zone. forgetDevice wants the same mutex, and without this bound the whole run
    // hangs on the first failed assertion instead of reporting it. Five real seconds,
    // then move on: the next test is already compromised by the leftover connection,
    // but a reported failure beats a silent hang.
    await ServiceManager.instance().device.forgetDevice(device).timeout(
          const Duration(seconds: 5),
          onTimeout: () => debugPrint('tearDown: forgetDevice timed out — a loop from a failed test still holds it'),
        );
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

  /// Run the loop to a stop: a cancel, then enough pumping for whatever was already
  /// in flight to finish and the loop to notice.
  ///
  /// **Every test that arms a loop must end with this**, including the ones that reach
  /// the connect. The loop holds DeviceService's mutex for the duration of an
  /// `ensureConnection`, and tearDown's `forgetDevice` takes the same lock — but
  /// tearDown does no pumping, so a connect still waiting on the transport's 75 s
  /// device-ready backstop can never expire and the two deadlock, hanging the run
  /// rather than failing it. Hence the connectBackstop pump before the scan pumps: it
  /// unwinds a connect first, then the scan behind it. The cancel goes first so the
  /// loop stops at the check it makes as soon as the connect returns, instead of
  /// starting the next scan.
  /// Pump until [condition] holds, or give up after [steps] one-second frames.
  ///
  /// Returns whether the condition was ever seen, so a caller can assert on that rather
  /// than on wherever a fixed pump happened to stop — a single coarse `pump(90s)` runs
  /// the whole scan/connect/gap cycle past the state being asserted, and a step count
  /// sized by hand lands a microtask short of it.
  ///
  /// **The runAsync turn is load-bearing.** A SECOND pigeon call on a channel does not
  /// get its reply delivered inside the fake-async zone: it sits pending across any
  /// number of pumps and only completes once the zone is torn down. So a test that
  /// drives two connects sees the second `manageDevice` never happen, which looks
  /// exactly like the code failing to retry. Verified against a scratch test that made
  /// two bare `ensureConnection(force: true)` calls with nothing else involved: pumps
  /// alone stalled it, one real-async turn resolved it. Harness only — on a device the
  /// replies come off the platform thread and there is no fake zone.
  Future<bool> pumpUntil(WidgetTester tester, bool Function() condition, {int steps = 100}) async {
    for (var i = 0; i < steps; i++) {
      if (condition()) return true;
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    }
    return condition();
  }

  Future<void> settleLoop(WidgetTester tester, _MixinHostState state) async {
    state.cancelPostFlashReconnect();
    await tester.pump(connectBackstop);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
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
      await settleLoop(tester, state);
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
      await settleLoop(tester, state);
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

    testWidgets('a connect that does not take is not the end of it', (tester) async {
      // The transport's device-ready backstop expires with no native answer, so
      // ensureConnection answers null — an explicit failure, and the commonest cause on
      // a real phone is a pairing request the user has not answered yet. Stopping there
      // would leave the screen waiting on a connect that is already over, so the loop
      // goes back to looking and the next sighting re-issues the request.
      final state = await pumpHost(tester);
      deviceIsAdvertising = true;

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(scanCycle);
      final connectsAfterFirst = hostCalls.where((call) => call == 'manageDevice').length;
      expect(connectsAfterFirst, greaterThan(0), reason: 'the first sighting must connect');
      expect(state.postFlashPhase, PostFlashPhase.connecting);

      // Stepped, and watched for the transition rather than read at the end: the whole
      // cycle — the connect giving up, the gap, the next scan, the next connect — fits
      // inside a single coarse pump, so a read afterwards only shows wherever that
      // landed. What has to be observed is that the phase passes back THROUGH waiting:
      // a failed connect must not leave the screen sitting on "Pairing...".
      var sawWaitingAgain = false;
      final reconnected = await pumpUntil(tester, () {
        if (state.postFlashPhase == PostFlashPhase.waiting) sawWaitingAgain = true;
        return hostCalls.where((call) => call == 'manageDevice').length > connectsAfterFirst;
      });

      expect(sawWaitingAgain, isTrue, reason: 'a failed connect is not a paired device — go back to looking');
      expect(state.postFlashPhase, isNot(PostFlashPhase.reconnecting),
          reason: 'a null connection must never be reported as a live one');
      expect(reconnected, isTrue, reason: 'the next sighting has to re-issue the pairing request');

      await settleLoop(tester, state);
    });
  });

  group('the phase the screen waits on', () {
    testWidgets('is armed synchronously, before the release has done anything', (tester) async {
      // The DFU success callback calls releasePairingOnSuccess unawaited and flips
      // isInstalled in the same block, so the success screen's FIRST frame is drawn from
      // there. A phase still reading idle on that frame is what the page renders as "no
      // automatic re-pair is coming, do it by hand" — the iOS state — so arming it after
      // the two host calls would show that and then take it away.
      await runOn(TargetPlatform.android, () async {
        final state = await pumpHost(tester);

        unawaited(state.releasePairingOnSuccess(btDevice));

        expect(state.postFlashPhase, PostFlashPhase.waiting,
            reason: 'no pump, no await: this is the frame the success screen is built on');
        await settleLoop(tester, state);
      });
    });

    testWidgets('stays idle off Android, where nothing re-pairs on its own', (tester) async {
      await runOn(TargetPlatform.iOS, () async {
        final state = await pumpHost(tester);

        await state.releasePairingOnSuccess(btDevice);
        await tester.pump(scanCycle);

        expect(state.postFlashPhase, PostFlashPhase.idle,
            reason: 'iOS cannot clear its own bond, so the screen must ask for a manual re-pair');
      });
    });

    testWidgets('walks waiting -> connecting -> reconnecting as the device comes back', (tester) async {
      final state = await pumpHost(tester);

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(const Duration(seconds: 1)); // mid-scan
      expect(state.postFlashPhase, PostFlashPhase.waiting);

      deviceIsAdvertising = true;
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);
      expect(state.postFlashPhase, PostFlashPhase.connecting,
          reason: 'the device was heard and the pairing request is in flight');

      // Native answers device-ready, which is what makes the connect return a live
      // connection rather than expiring on the backstop. Delivered through BleBridge,
      // the same entry point native calls — and carrying a service, because the
      // transport deliberately DROPS a ready with an empty table (an empty one is never
      // a usable link; see _handleDeviceReady).
      BleBridge.instance.onDeviceReady(device, [
        BleService(uuid: '19b10010-e8f2-537e-4f6c-d104768a1214', characteristicUuids: const []),
      ]);
      final reachedReconnecting =
          await pumpUntil(tester, () => state.postFlashPhase == PostFlashPhase.reconnecting, steps: 10);

      expect(reachedReconnecting, isTrue);
      await settleLoop(tester, state);
    });

    testWidgets('reports the expiry, and a cancel is not an expiry', (tester) async {
      // The two exits share the same `while`, and they mean opposite things: an expiry
      // is the screen's cue to offer another search, while a cancel is the page going
      // away (or the re-pair having landed by another route) and must leave the screen
      // exactly as it was.
      final expired = await pumpHost(tester);
      unawaited(expired.reconnectWhenDeviceReturns(btDevice, window: const Duration(milliseconds: 1)));
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);
      expect(expired.postFlashPhase, PostFlashPhase.timedOut);

      // Cancelled DURING THE GAP, deliberately. The loop has two ways out and they must
      // be told apart at the right one: a cancel caught by the check inside the body
      // returns before the post-loop line is ever reached, so it cannot see whether that
      // line is guarded. Only a cancel that lands while the loop is parked between scans
      // — after the body's own check has passed — leaves via the `while` condition,
      // which is the exit the expiry also uses and therefore the one that has to
      // distinguish them. The scan is 5 s and the gap 2 s, so t=6 is inside it.
      final cancelled = await pumpHost(tester);
      unawaited(cancelled.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(const Duration(seconds: 6));
      cancelled.cancelPostFlashReconnect();
      await tester.pump(const Duration(seconds: 4));

      expect(cancelled.postFlashPhase, PostFlashPhase.waiting,
          reason: 'a cancelled loop has not given up — nobody is left to offer a retry to');
      await settleLoop(tester, cancelled);
    });
  });

  group('searching again after the window expires', () {
    testWidgets('re-arms the loop the expiry left cancelled-shaped', (tester) async {
      final state = await pumpHost(tester);

      unawaited(state.reconnectWhenDeviceReturns(btDevice, window: const Duration(milliseconds: 1)));
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);
      final scansAtExpiry = scansStarted();
      expect(state.postFlashPhase, PostFlashPhase.timedOut);

      unawaited(state.retryPostFlashReconnect(btDevice));
      await tester.pump(scanCycle);

      expect(scansStarted(), greaterThan(scansAtExpiry), reason: 'Search again has to actually scan again');
      expect(state.postFlashPhase, PostFlashPhase.waiting);

      await settleLoop(tester, state);
    });

    testWidgets('cannot resurrect a loop the page cancelled on its way out', (tester) async {
      // The cancel flag is one-shot and cannot abort a scan already in flight, so
      // clearing it under a running loop would put a screen the user has left back to
      // reconnecting behind their back. Refusing costs nothing: the only real caller is
      // a button shown exclusively in the timedOut state, where no loop is running.
      final state = await pumpHost(tester);
      deviceIsAdvertising = true;

      unawaited(state.reconnectWhenDeviceReturns(btDevice));
      await tester.pump(const Duration(seconds: 1)); // mid-scan
      state.cancelPostFlashReconnect();
      unawaited(state.retryPostFlashReconnect(btDevice));
      await tester.pump(scanCycle);
      await tester.pump(scanCycle);

      expect(scansStarted(), 1, reason: 'the straddling scan is the only one');
      expect(hostCalls, isNot(contains('manageDevice')));

      await settleLoop(tester, state);
    });
  });
}
