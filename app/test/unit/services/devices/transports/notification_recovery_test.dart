import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const address = 'recovery-test';
  const service = '30295780-4301-eabd-2904-2849adfeae43';
  const characteristic = '30295781-4301-eabd-2904-2849adfeae43';
  late NativeBleTransport transport;
  late int subscriptions;
  late int disconnects;
  late int unmanages;
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
    disconnects = 0;
    unmanages = 0;
    subscribe = () async => <Object?>[null];
    mock('manageDevice', (_) async => <Object?>[null]);
    mock('unmanageDevice', (_) async {
      unmanages++;
      return <Object?>[null];
    });
    mock('disconnectPeripheral', (_) async {
      disconnects++;
      return <Object?>[null];
    });
    mock('unsubscribeCharacteristic', (_) async => <Object?>[null]);
    mock('subscribeCharacteristic', (_) {
      subscriptions++;
      return subscribe();
    });
    transport = NativeBleTransport(address);
  });

  tearDown(() async {
    await transport.dispose();
    for (final method in [
      'manageDevice',
      'unmanageDevice',
      'subscribeCharacteristic',
      'disconnectPeripheral',
      'unsubscribeCharacteristic'
    ]) {
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

  test('native future remains authoritative past the former Dart timeout', () async {
    await connect();
    fakeAsync((clock) {
      final native = Completer<Object?>();
      subscribe = () => native.future;
      var completions = 0;
      stream().then((_) => completions++);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 11));
      transport.refreshCharacteristicStream(service, characteristic).then((_) => completions++);
      clock.flushMicrotasks();
      expect(subscriptions, 1);
      expect(completions, 0);
      native.complete(<Object?>[null]);
      clock.flushMicrotasks();
      expect(completions, 2);
      stream();
      clock.flushMicrotasks();
      expect(subscriptions, 1);
    });
  });

  test('failed automatic restore reports disconnection and requests native recovery once', () async {
    await connect();
    await stream();
    final states = <DeviceTransportState>[];
    final listener = transport.connectionStateStream.listen(states.add);
    BleBridge.instance.onPeripheralDisconnected(address, 'link_loss');
    subscribe = () async => <Object?>['notification-subscription', 'descriptor rejected', null];
    BleBridge.instance.onDeviceReady(address, [
      BleService(uuid: service, characteristicUuids: [characteristic])
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(states.last, DeviceTransportState.disconnected);
    expect(disconnects, 1);
    expect(unmanages, 0, reason: 'native must retain reconnect ownership');
    await listener.cancel();
  });

  test('explicit teardown after auto reconnect forgets prior subscription intent', () async {
    await connect();
    await stream();
    BleBridge.instance.onPeripheralDisconnected(address, 'link_loss');
    await connect();
    await stream();
    expect(subscriptions, 2);
    await transport.disconnect();
    await connect();
    await Future<void>.delayed(Duration.zero);
    expect(subscriptions, 2);
    expect(unmanages, 1);
  });

  test('late failed restore cannot disconnect a newer healthy generation', () async {
    await connect();
    await stream();
    BleBridge.instance.onPeripheralDisconnected(address, 'link_loss');
    final oldNative = Completer<Object?>();
    subscribe = () => oldNative.future;
    await connect();
    await Future<void>.delayed(Duration.zero);
    BleBridge.instance.onPeripheralDisconnected(address, 'link_loss');
    subscribe = () async => <Object?>[null];
    await connect();
    await stream();
    oldNative.complete(<Object?>['notification-subscription', 'old descriptor rejected', null]);
    await Future<void>.delayed(Duration.zero);
    await stream();
    expect(disconnects, 0);
    expect(subscriptions, 3);
  });

  test('explicit teardown during link loss still unmanages and clears restore intent', () async {
    await connect();
    await stream();
    BleBridge.instance.onPeripheralDisconnected(address, 'link_loss');
    await transport.disconnect();
    await connect();
    expect(subscriptions, 1);
    expect(unmanages, 1);
  });

  test('abandoned failed subscription is not resurrected on reconnect', () async {
    await connect();
    subscribe = () async => <Object?>['notification-subscription', 'descriptor rejected', null];
    await expectLater(stream(), throwsA(isA<PlatformException>()));
    BleBridge.instance.onPeripheralDisconnected(address, 'link_loss');
    subscribe = () async => <Object?>[null];
    await connect();
    await Future<void>.delayed(Duration.zero);
    expect(subscriptions, 1);
  });

  test('failed refresh preserves an existing stream listener for retry', () async {
    await connect();
    final received = <List<int>>[];
    final listener = (await stream()).listen(received.add);
    subscribe = () async => <Object?>['notification-subscription', 'descriptor rejected', null];
    await expectLater(
        transport.refreshCharacteristicStream(service, characteristic), throwsA(isA<PlatformException>()));
    subscribe = () async => <Object?>[null];
    await transport.refreshCharacteristicStream(service, characteristic);
    BleBridge.instance.onCharacteristicValueUpdated(address, service, characteristic, Uint8List.fromList([3, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(received, [
      [3, 0]
    ]);
    await listener.cancel();
  });
}
