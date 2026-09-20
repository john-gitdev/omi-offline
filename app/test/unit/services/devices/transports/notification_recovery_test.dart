import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const address = 'recovery-test';
  const service = '30295780-4301-eabd-2904-2849adfeae43';
  const characteristic = '30295781-4301-eabd-2904-2849adfeae43';
  late NativeBleTransport transport;
  late int subscriptions;
  late Future<Object?> Function() subscribe;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mock(String method, Future<Object?> Function(Object?) handler) {
    messenger.setMockDecodedMessageHandler<Object?>(
      BasicMessageChannel<Object?>('dev.flutter.pigeon.omi_pigeon.BleHostApi.$method', BleHostApi.pigeonChannelCodec),
      handler,
    );
  }

  Future<void> connect() async {
    final pending = transport.connect();
    await Future<void>.delayed(Duration.zero);
    BleBridge.instance.onDeviceReady(address, [
      BleService(uuid: service, characteristicUuids: [characteristic])
    ]);
    await pending;
  }

  Future<Stream<List<int>>> stream() => transport.getCharacteristicStream(service, characteristic);

  setUp(() {
    subscriptions = 0;
    subscribe = () async => <Object?>[null];
    mock('manageDevice', (_) async => <Object?>[null]);
    mock('unmanageDevice', (_) async => <Object?>[null]);
    mock('subscribeCharacteristic', (_) {
      subscriptions++;
      return subscribe();
    });
    transport = NativeBleTransport(address);
  });

  tearDown(() async {
    await transport.dispose();
    for (final method in ['manageDevice', 'unmanageDevice', 'subscribeCharacteristic']) {
      messenger.setMockDecodedMessageHandler<Object?>(
        BasicMessageChannel<Object?>('dev.flutter.pigeon.omi_pigeon.BleHostApi.$method', BleHostApi.pigeonChannelCodec),
        null,
      );
    }
  });

  test('notification stream waits for native completion and joins concurrent callers', () async {
    await connect();
    final native = Completer<Object?>();
    subscribe = () => native.future;
    var ready = false;
    final first = stream().then((_) => ready = true);
    final second = stream();
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    expect(subscriptions, 1);
    native.complete(<Object?>[null]);
    await first;
    await second;
    expect(ready, isTrue);
  });

  test('descriptor failure is propagated and a later caller retries', () async {
    await connect();
    subscribe = () async => <Object?>['notification-subscription', 'descriptor rejected', null];
    await expectLater(stream(), throwsA(isA<PlatformException>()));
    subscribe = () async => <Object?>[null];
    await stream();
    expect(subscriptions, 2);
  });

  test('a request while disconnected cannot poison the next explicit reconnect', () async {
    await connect();
    await stream();
    BleBridge.instance.onPeripheralDisconnected(address, 'bluetooth_off');
    await expectLater(stream(), throwsStateError);
    await connect();
    await stream();
    expect(subscriptions, 2);
  });

  test('late completion from the old connection cannot mark its subscription ready', () async {
    await connect();
    final oldNative = Completer<Object?>();
    subscribe = () => oldNative.future;
    final old = stream();
    final rejected = expectLater(old, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    BleBridge.instance.onPeripheralDisconnected(address, 'bluetooth_off');
    subscribe = () async => <Object?>[null];
    await connect();
    await stream();
    oldNative.complete(<Object?>[null]);
    await rejected;
    await stream();
    expect(subscriptions, 2, reason: 'old completion must not discard the new confirmed subscription');
  });

  test('listing refresh revalidates the descriptor while retaining existing listeners', () async {
    await connect();
    final received = <List<int>>[];
    final listener = (await stream()).listen(received.add);
    await transport.refreshCharacteristicStream(service, characteristic);
    BleBridge.instance.onCharacteristicValueUpdated(address, service, characteristic, Uint8List.fromList([3, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(subscriptions, 2);
    expect(received, [
      [3, 0]
    ]);
    await listener.cancel();
  });

  test('refresh joins an unfinished reconnect subscription instead of issuing duplicates', () async {
    await connect();
    final native = Completer<Object?>();
    subscribe = () => native.future;
    final first = stream();
    final refresh = transport.refreshCharacteristicStream(service, characteristic);
    await Future<void>.delayed(Duration.zero);
    expect(subscriptions, 1);
    native.complete(<Object?>[null]);
    await first;
    await refresh;
  });

  test('native auto reconnect restores notification delivery', () async {
    await connect();
    await stream();
    BleBridge.instance.onPeripheralDisconnected(address, 'link_loss');
    BleBridge.instance.onDeviceReady(address, [
      BleService(uuid: service, characteristicUuids: [characteristic])
    ]);
    await stream();
    expect(subscriptions, 2);
  });
}
