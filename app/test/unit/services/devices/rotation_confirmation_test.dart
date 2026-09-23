import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/errors.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

class _RotationTransport extends DeviceTransport {
  final packets = StreamController<List<int>>.broadcast();
  final issued = Completer<void>();
  int writes = 0;
  bool failSubscription = false;
  bool failWrite = false;
  int refreshes = 0;

  @override
  Future<Stream<List<int>>> refreshCharacteristicStream(String service, String characteristic) async {
    refreshes++;
    return getCharacteristicStream(service, characteristic);
  }

  @override
  Future<Stream<List<int>>> getCharacteristicStream(String service, String characteristic) async {
    if (failSubscription) throw StateError('subscription rejected');
    return packets.stream;
  }

  @override
  Future<void> writeCharacteristic(String service, String characteristic, List<int> bytes) async {
    writes++;
    if (!issued.isCompleted) issued.complete();
    if (failWrite) throw StateError('write outcome unknown');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RotationTransport transport;
  late OmiDeviceConnection connection;

  setUp(() {
    transport = _RotationTransport();
    connection = OmiDeviceConnection(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50), transport,
        rotationConfirmationTimeout: const Duration(milliseconds: 50));
  });
  tearDown(() async {
    await transport.packets.close();
  });

  test('rotation confirmation timeout reports unknown after exactly one command', () async {
    await expectLater(connection.performRotateFile(), throwsA(isA<StorageRotationUnconfirmedException>()));
    expect(transport.writes, 1);
  });

  test('disconnect after issuing rotation reports unknown immediately', () async {
    final pending = connection.performRotateFile();
    final checked = expectLater(pending, throwsA(isA<StorageRotationUnconfirmedException>()));
    await transport.issued.future;
    await transport.packets.close();
    await checked;
    expect(transport.writes, 1);
  });

  test('disconnect before issuing rotation sends no command', () async {
    final pending = connection.performRotateFile();
    await Future<void>.delayed(Duration.zero);
    await transport.packets.close();
    await expectLater(pending, throwsA(isA<StorageRotationNotStartedException>()));
    expect(transport.writes, 0);
  });

  test('failed notification setup does not issue a rotation', () async {
    transport.failSubscription = true;
    await expectLater(connection.performRotateFile(), throwsA(isA<StorageRotationNotStartedException>()));
    expect(transport.writes, 0);
  });

  test('an ACK before the command cannot confirm rotation', () async {
    final pending = connection.performRotateFile();
    final checked = expectLater(pending, throwsA(isA<StorageRotationUnconfirmedException>()));
    await Future<void>.delayed(Duration.zero);
    transport.packets.add([3, 0]);
    await transport.issued.future;
    await transport.packets.close();
    await checked;
  });

  test('a confirmed rotation succeeds', () async {
    final pending = connection.performRotateFile();
    await transport.issued.future;
    transport.packets.add([3, 0]);
    expect(await pending, isTrue);
  });

  test('a failed write is conservatively unknown', () async {
    transport.failWrite = true;
    await expectLater(connection.performRotateFile(), throwsA(isA<StorageRotationUnconfirmedException>()));
  });

  test('disconnected rotation facade reports not started without a command', () async {
    await expectLater(connection.rotateFile(), throwsA(isA<StorageRotationNotStartedException>()));
    expect(transport.writes, 0);
  });

  test('explicit rotation rejection remains false rather than unknown', () async {
    final pending = connection.performRotateFile();
    await transport.issued.future;
    transport.packets.add([3, 1]);
    expect(await pending, isFalse);
  });

  for (final command in ['delete', 'stop', 'clear']) {
    Future<bool> run() => switch (command) {
          'delete' => connection.performDeleteFile(StorageFile(index: 0, timestamp: 1, size: 100)),
          'stop' => connection.performStopStorageSync(),
          _ => connection.performClearStorage(),
        };

    test('$command fails promptly when its reply stream closes', () async {
      final pending = run();
      await transport.issued.future;
      await transport.packets.close();
      expect(await pending.timeout(const Duration(milliseconds: 200)), isFalse);
      expect(transport.packets.hasListener, isFalse);
    });

    test('$command fails promptly on a stream error', () async {
      final pending = run();
      await transport.issued.future;
      transport.packets.addError(StateError('link failed'));
      expect(await pending.timeout(const Duration(milliseconds: 200)), isFalse);
      expect(transport.packets.hasListener, isFalse);
    });

    test('$command cancels its listener after a failed write', () async {
      transport.failWrite = true;
      expect(await run(), isFalse);
      expect(transport.packets.hasListener, isFalse);
    });

    test('$command still succeeds with a real ACK', () async {
      final pending = run();
      await transport.issued.future;
      transport.packets.add([3, 0]);
      expect(await pending, isTrue);
    });
  }

  test('listing ends as unanswered immediately when its stream closes', () async {
    final pending = connection.performListFiles();
    await transport.issued.future;
    await transport.packets.close();
    expect(await pending.timeout(const Duration(milliseconds: 200)), isNull);
  });

  test('listing does not send after disconnect during notification settle', () async {
    final pending = connection.performListFiles();
    await Future<void>.delayed(Duration.zero);
    await transport.packets.close();
    expect(await pending, isNull);
    expect(transport.writes, 0);
  });

  test('delete does not send after disconnect during notification settle', () async {
    final pending = connection.performDeleteFile(StorageFile(index: 0, timestamp: 1, size: 100));
    await Future<void>.delayed(Duration.zero);
    await transport.packets.close();
    expect(await pending, isFalse);
    expect(transport.writes, 0);
  });

  test('standalone delete, stop, clear and byte-stream acquisition revalidate notifications', () async {
    transport.failSubscription = true;
    expect(await connection.performDeleteFile(StorageFile(index: 0, timestamp: 1, size: 100)), isFalse);
    expect(await connection.performStopStorageSync(), isFalse);
    expect(await connection.performClearStorage(), isFalse);
    await expectLater(connection.getBleStorageBytesStream(), throwsStateError);
    expect(transport.refreshes, 4);
    expect(transport.writes, 0, reason: 'failed readiness must not issue storage commands');
  });
}
