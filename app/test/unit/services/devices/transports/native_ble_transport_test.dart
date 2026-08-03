import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NativeBleTransport connect', () {
    late NativeBleTransport transport;

    setUp(() {
      transport = NativeBleTransport('test-uuid');
    });

    tearDown(() async {
      await transport.dispose();
    });

    test('handles manageDevice error', () async {
      bool manageDeviceCalled = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.omi_pigeon.BleHostApi.manageDevice',
          BleHostApi.pigeonChannelCodec,
        ),
        (message) async {
          manageDeviceCalled = true;
          throw PlatformException(code: 'ERROR', message: 'Simulated connection failure');
        },
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.omi_pigeon.BleHostApi.unmanageDevice',
          BleHostApi.pigeonChannelCodec,
        ),
        (message) async {
          return <Object?>[null];
        },
      );

      final states = <DeviceTransportState>[];
      final subscription = transport.connectionStateStream.listen(states.add);

      bool exceptionCaught = false;

      // Because the code completes the completer with an error AND rethrows, we need to handle the rethrown error.
      // And the unawaited future of completer.completeError causes an uncaught error in Dart zone unless handled.
      // So we will use a zone.
      await runZonedGuarded(
        () async {
          try {
            await transport.connect();
          } catch (e) {
            if (e is PlatformException) {
              exceptionCaught = true;
              expect(e.code, 'ERROR');
              expect(e.message, 'Simulated connection failure');
            } else {
              rethrow;
            }
          }
        },
        (error, stack) {
          if (error is PlatformException) {
            exceptionCaught = true;
            expect(error.code, 'ERROR');
            expect(error.message, 'Simulated connection failure');
          } else {
            throw error;
          }
        },
      );

      expect(exceptionCaught, isTrue, reason: 'Expected PlatformException to be thrown');
      expect(manageDeviceCalled, isTrue);

      // Let broadcast stream deliver events
      await Future.delayed(const Duration(milliseconds: 10));

      expect(states, [DeviceTransportState.connecting, DeviceTransportState.disconnected]);

      await subscription.cancel();
    });

    test('ignores transient GATT errors during connect', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.omi_pigeon.BleHostApi.manageDevice',
          BleHostApi.pigeonChannelCodec,
        ),
        (message) async {
          return <Object?>[null];
        },
      );

      final connectFuture = transport.connect();

      // Simulate status 133
      BleBridge.instance.onPeripheralDisconnected('test-uuid', 'gatt_status_133');
      await Future.delayed(Duration.zero);

      // Simulate status -1 (timeout)
      BleBridge.instance.onPeripheralDisconnected('test-uuid', 'gatt_status_-1');
      await Future.delayed(Duration.zero);

      bool completed = false;
      connectFuture.then((_) => completed = true);

      await Future.delayed(const Duration(milliseconds: 100));
      expect(completed, isFalse, reason: 'Connect future should still be pending after transient errors');

      // Now simulate success. The service list must be non-empty: a ready carrying zero
      // services is rejected as an unusable link (see the empty-table guard below).
      BleBridge.instance.onDeviceReady('test-uuid', [_service()]);
      await connectFuture;
      expect(completed, isTrue);
    });

    test('rejects a device-ready that carries no services', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.omi_pigeon.BleHostApi.manageDevice',
          BleHostApi.pigeonChannelCodec,
        ),
        (message) async => <Object?>[null],
      );

      final states = <DeviceTransportState>[];
      final subscription = transport.connectionStateStream.listen(states.add);

      // Native can fire ready in the window between STATE_CONNECTED and
      // onServicesDiscovered, when gatt.services is still empty. Latching that as
      // connected strands the session: reads short-circuit to [] (capabilities read as 0)
      // and connect() early-returns forever, so only a force-close recovers.
      await runZonedGuarded(
        () async {
          final connectFuture = transport.connect();
          await Future.delayed(Duration.zero);
          BleBridge.instance.onDeviceReady('test-uuid', []);
          try {
            await connectFuture;
            fail('connect() should not succeed on an empty service table');
          } catch (_) {}
        },
        (error, stack) {},
      );

      await Future.delayed(const Duration(milliseconds: 10));
      expect(states, isNot(contains(DeviceTransportState.connected)));
      expect(states.last, DeviceTransportState.disconnected);

      await subscription.cancel();
    });

    test('accepts a later device-ready once the real service table arrives', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        const BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.omi_pigeon.BleHostApi.manageDevice',
          BleHostApi.pigeonChannelCodec,
        ),
        (message) async => <Object?>[null],
      );

      final states = <DeviceTransportState>[];
      final subscription = transport.connectionStateStream.listen(states.add);

      final connectFuture = transport.connect();
      await Future.delayed(Duration.zero);

      // The discovery that lands moments after the (dropped) empty ready is what counts.
      BleBridge.instance.onDeviceReady('test-uuid', [_service()]);

      await connectFuture;
      await Future.delayed(const Duration(milliseconds: 10));
      expect(states.last, DeviceTransportState.connected);

      await subscription.cancel();
    });
  });
}

/// A minimal non-empty service table — the shape native delivers post-discovery.
BleService _service() => BleService(
      uuid: '19b10010-e8f2-537e-4f6c-d104768a1214',
      characteristicUuids: const ['19b10013-e8f2-537e-4f6c-d104768a1214'],
    );
