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

      // Now simulate success
      BleBridge.instance.onDeviceReady('test-uuid', []);
      await connectFuture;
      expect(completed, isTrue);
    });
  });
}
