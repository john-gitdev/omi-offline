import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/audio/aac_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.omi.offline/aacEncoder');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      MethodCall methodCall,
    ) async {
      log.add(methodCall);
      switch (methodCall.method) {
        case 'startEncoder':
          return 'test-session-id';
        case 'encodeBuffer':
          return null;
        case 'finishEncoder':
          return null;
        default:
          return null;
      }
    });
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('AacEncoder', () {
    test('startEncoder calls native method with correct arguments', () async {
      final String sessionId = await AacEncoder.startEncoder(16000, '/path/to/output.m4a', bitrate: 64000);

      expect(sessionId, 'test-session-id');
      expect(log, hasLength(1));
      expect(log.first.method, 'startEncoder');
      expect(log.first.arguments, {'sampleRate': 16000, 'outputPath': '/path/to/output.m4a', 'bitrate': 64000});
    });

    test('encodeBuffer calls native method with correct arguments', () async {
      final Uint8List dummyBytes = Uint8List.fromList([1, 2, 3, 4]);
      await AacEncoder.encodeBuffer('test-session-id', dummyBytes);

      expect(log, hasLength(1));
      expect(log.first.method, 'encodeBuffer');
      expect(log.first.arguments, {'sessionId': 'test-session-id', 'pcmBytes': dummyBytes});
    });

    test('finishEncoder calls native method with correct arguments', () async {
      await AacEncoder.finishEncoder('test-session-id');

      expect(log, hasLength(1));
      expect(log.first.method, 'finishEncoder');
      expect(log.first.arguments, {'sessionId': 'test-session-id'});
    });
  });
}
