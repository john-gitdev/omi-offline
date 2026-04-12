import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:omi/utils/file.dart';
import 'package:omi/utils/audio/wav_bytes.dart';

class FakePathProviderPlatform extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath = Directory.systemTemp.path;

  @override
  Future<String?> getTemporaryPath() async {
    return tempPath;
  }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    PathProviderPlatform.instance = FakePathProviderPlatform();
  });

  group('FileUtils', () {
    test(
      'saveAudioBytesToTempFile correctly saves segment and writes proper headers',
      () async {
        // Arrange
        int timerStart = 12345;
        int frameSize = 512;
        List<List<int>> segment = [
          [1, 2, 3],
          [4, 5],
        ];

        // Act
        final file = await FileUtils.saveAudioBytesToTempFile(
          segment,
          timerStart,
          frameSize,
        );

        // Assert
        expect(file.existsSync(), isTrue);
        expect(file.path, contains('audio_fs512_12345.bin'));

        final bytes = await file.readAsBytes();

        // Expected logic format:
        // Frame 1: <length>|<data>
        // length = 3 -> Uint32 little endian (3, 0, 0, 0)
        // data = [1, 2, 3]
        // Frame 2: <length>|<data>
        // length = 2 -> Uint32 little endian (2, 0, 0, 0)
        // data = [4, 5]

        final expectedBytes = <int>[3, 0, 0, 0, 1, 2, 3, 2, 0, 0, 0, 4, 5];

        expect(bytes, equals(expectedBytes));

        // Cleanup
        if (file.existsSync()) {
          file.deleteSync();
        }
      },
    );

    test('rethrows error on failure for saveAudioBytesToTempFile', () async {
      PathProviderPlatform.instance = FakePathProviderPlatform()..tempPath = null;
      await expectLater(
        () async => await FileUtils.saveAudioBytesToTempFile([], 12345, 80),
        throwsA(anything),
      );
      // Restore platform instance for other tests
      PathProviderPlatform.instance = FakePathProviderPlatform();
    });

    test(
      'convertPcmToWavFile correctly creates WAV file from PCM data',
      () async {
        // Arrange
        final pcmBytes = Uint8List.fromList([10, 20, 30, 40]);
        final sampleRate = 16000;
        final channels = 1;

        // Act
        final file = await FileUtils.convertPcmToWavFile(
          pcmBytes,
          sampleRate,
          channels,
        );

        // Assert
        expect(file.existsSync(), isTrue);
        expect(file.path, endsWith('.wav'));
        expect(file.path, contains('recording_'));

        final bytes = await file.readAsBytes();

        // Verification:
        // A typical WAV header is 44 bytes.
        // Total size = 44 + pcmBytes.length = 48 bytes
        expect(bytes.length, equals(48));

        // Header check ("RIFF")
        expect(bytes[0], equals(0x52)); // R
        expect(bytes[1], equals(0x49)); // I
        expect(bytes[2], equals(0x46)); // F
        expect(bytes[3], equals(0x46)); // F

        // PCM data check (starts at index 44)
        expect(bytes.sublist(44), equals([10, 20, 30, 40]));

        // Cleanup
        if (file.existsSync()) {
          file.deleteSync();
        }
      },
    );

    test('convertPcmToWavFile rethrows error on failure', () async {
      PathProviderPlatform.instance = FakePathProviderPlatform()..tempPath = null;
      await expectLater(
        () async => await FileUtils.convertPcmToWavFile(Uint8List(0), 16000, 1),
        throwsA(anything),
      );
      // Restore platform instance for other tests
      PathProviderPlatform.instance = FakePathProviderPlatform();
    });
  });
}
