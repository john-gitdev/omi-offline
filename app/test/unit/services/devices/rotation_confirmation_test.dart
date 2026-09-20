import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/errors.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

class _RotationTransport extends DeviceTransport {
  final packets = StreamController<List<int>>.broadcast();
  final issued = Completer<void>();
  int writes = 0;
  bool failSubscription = false;
  bool failWrite = false;

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
    connection = OmiDeviceConnection(BtDevice(id: 'test', name: 'test', type: DeviceType.omi, rssi: -50), transport);
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
    expect(await pending, isFalse);
    expect(transport.writes, 0);
  });

  test('failed notification setup does not issue a rotation', () async {
    transport.failSubscription = true;
    expect(await connection.performRotateFile(), isFalse);
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
}
