import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';
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
        BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.omi_pigeon.BleHostApi.manageDevice',
          BleHostApi.pigeonChannelCodec,
        ),
        (message) async {
          manageDeviceCalled = true;
          return <Object?>['ERROR', 'Simulated connection failure', null];
        },
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        BasicMessageChannel<Object?>(
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

      try {
        final future = transport.connect();
        await future;
      } catch (e) {
        if (e is PlatformException) {
          exceptionCaught = true;
          expect(e.code, 'ERROR');
          expect(e.message, 'Simulated connection failure');
        }
      }

      expect(exceptionCaught, isTrue, reason: 'Expected PlatformException to be thrown');
      expect(manageDeviceCalled, isTrue);

      // Let broadcast stream deliver events
      await Future.delayed(const Duration(milliseconds: 10));

      expect(states, [DeviceTransportState.connecting, DeviceTransportState.disconnected]);

      await subscription.cancel();
    });
  });
}
