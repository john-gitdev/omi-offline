import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/file.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:path/path.dart' as p;

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('file_utils_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('FileUtils.saveAudioBytesToTempFile', () {
    test('saves bytes with correct length-prefixed format and filename', () async {
      final List<List<int>> segments = [
        [1, 2, 3],
        [4, 5]
      ];
      const int timerStart = 12345;
      const int frameSize = 80;

      final file = await FileUtils.saveAudioBytesToTempFile(segments, timerStart, frameSize);

      expect(file.existsSync(), isTrue);
      expect(p.basename(file.path), 'audio_fs80_12345.bin');

      final bytes = await file.readAsBytes();
      // Segment 1: length 3 (4 bytes) + [1, 2, 3] (3 bytes) = 7 bytes
      // Segment 2: length 2 (4 bytes) + [4, 5] (2 bytes) = 6 bytes
      // Total: 13 bytes
      expect(bytes.length, 13);

      final data = ByteData.view(bytes.buffer);
      expect(data.getUint32(0, Endian.little), 3);
      expect(bytes.sublist(4, 7), [1, 2, 3]);
      expect(data.getUint32(7, Endian.little), 2);
      expect(bytes.sublist(11, 13), [4, 5]);
    });
  });

  group('FileUtils.convertPcmToWavFile', () {
    test('converts PCM to WAV and saves to file', () async {
      final pcmBytes = Uint8List.fromList([0, 0, 1, 0, 2, 0]); // 3 samples of 16-bit PCM
      const int sampleRate = 16000;
      const int channels = 1;

      final file = await FileUtils.convertPcmToWavFile(pcmBytes, sampleRate, channels);

      expect(file.existsSync(), isTrue);
      expect(p.extension(file.path), '.wav');
      expect(p.basename(file.path), startsWith('recording_'));

      final bytes = await file.readAsBytes();
      expect(bytes.length, 44 + pcmBytes.length);
      expect(bytes.sublist(0, 4), utf8.encode('RIFF'));
      expect(bytes.sublist(8, 12), utf8.encode('WAVE'));
    });

    test('rethrows error on failure', () async {
      // Since WavBytes.fromPcm currently doesn't seem to throw on common inputs,
      // we can try to force an error if possible, or just note it.
      // Looking at WavBytes.fromPcm, it doesn't do much validation.

      // However, if we mock getTemporaryDirectory to fail, it should rethrow.
      mockPathProvider.tempPath = null;

      expect(() => FileUtils.convertPcmToWavFile(Uint8List(0), 16000, 1), throwsA(anything));
    });
  });
}
