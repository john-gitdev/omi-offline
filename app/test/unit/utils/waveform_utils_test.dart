import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:omi/utils/waveform_utils.dart';

void main() {
  group('WaveformUtils', () {
    late Directory tempDir;
    late File errorFile;
    late File validFile;

    void createDummyWav(String path) {
      final file = File(path);
      final bytes = BytesBuilder();

      bytes.add('RIFF'.codeUnits);
      bytes.add([36 + 100, 0, 0, 0]);
      bytes.add('WAVE'.codeUnits);

      bytes.add('fmt '.codeUnits);
      bytes.add([16, 0, 0, 0]);
      bytes.add([1, 0]);
      bytes.add([1, 0]);
      bytes.add([0x44, 0xAC, 0, 0]);
      bytes.add([0x88, 0x58, 0x01, 0]);
      bytes.add([2, 0]);
      bytes.add([16, 0]);

      bytes.add('data'.codeUnits);
      bytes.add([100, 0, 0, 0]);

      for (int i = 0; i < 50; i++) {
        bytes.add([0x40, 0x00]);
      }

      file.writeAsBytesSync(bytes.toBytes());
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('waveform_utils_test_');
      errorFile = File(p.join(tempDir.path, 'error_file.wav'));
      validFile = File(p.join(tempDir.path, 'test_valid.wav'));

      WaveformUtils.clearCache();
    });

    tearDown(() {
      if (!Platform.isWindows && errorFile.existsSync()) {
        try {
          Process.runSync('chmod', ['644', errorFile.path]);
        } catch (_) {}
      }
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('generateWaveform returns fallback on missing file', () async {
      final missingPath = p.join(tempDir.path, 'missing_file.wav');
      final waveform = await WaveformUtils.generateWaveform('missing_key', missingPath);
      expect(waveform, isEmpty);
    });

    test('generateWaveform returns fallback on file read error', () async {
      errorFile.writeAsStringSync('dummy');

      if (!Platform.isWindows) {
        Process.runSync('chmod', ['000', errorFile.path]);
      }

      final waveform = await WaveformUtils.generateWaveform('error_key', errorFile.path);
      expect(waveform, isEmpty);
    });

    test('generateWaveform handles null file path', () async {
      final waveform = await WaveformUtils.generateWaveform('null_key', null);
      expect(waveform, isEmpty);
    });

    test('generateWaveform returns cached waveform if available', () async {
      createDummyWav(validFile.path);

      final waveform1 = await WaveformUtils.generateWaveform('cache_key', validFile.path);
      expect(waveform1, isNotEmpty);

      // Request again with a missing file but the same key
      final missingPath = p.join(tempDir.path, 'missing_file2.wav');
      final waveform2 = await WaveformUtils.generateWaveform('cache_key', missingPath);
      expect(waveform2, equals(waveform1));
    });
  });
}
