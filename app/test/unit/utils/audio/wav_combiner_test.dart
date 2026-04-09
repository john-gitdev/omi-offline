import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/audio/wav_combiner.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// Create a mock path provider plugin
class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async {
    return Directory.systemTemp.path;
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('wav_combiner_test');
    PathProviderPlatform.instance = MockPathProviderPlatform();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Uint8List createMockWavData({
    int sampleRate = 16000,
    int channels = 1,
    int bitsPerSample = 16,
    int dataSize = 100,
  }) {
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final fileSize = 36 + dataSize;

    final header = ByteData(44);

    // RIFF
    header.setUint8(0, 'R'.codeUnitAt(0));
    header.setUint8(1, 'I'.codeUnitAt(0));
    header.setUint8(2, 'F'.codeUnitAt(0));
    header.setUint8(3, 'F'.codeUnitAt(0));

    // File size
    header.setUint32(4, fileSize, Endian.little);

    // WAVE
    header.setUint8(8, 'W'.codeUnitAt(0));
    header.setUint8(9, 'A'.codeUnitAt(0));
    header.setUint8(10, 'V'.codeUnitAt(0));
    header.setUint8(11, 'E'.codeUnitAt(0));

    // fmt
    header.setUint8(12, 'f'.codeUnitAt(0));
    header.setUint8(13, 'm'.codeUnitAt(0));
    header.setUint8(14, 't'.codeUnitAt(0));
    header.setUint8(15, ' '.codeUnitAt(0));

    // Subchunk1Size
    header.setUint32(16, 16, Endian.little);

    // AudioFormat (PCM = 1)
    header.setUint16(20, 1, Endian.little);

    // NumChannels
    header.setUint16(22, channels, Endian.little);

    // SampleRate
    header.setUint32(24, sampleRate, Endian.little);

    // ByteRate
    header.setUint32(28, byteRate, Endian.little);

    // BlockAlign
    header.setUint16(32, blockAlign, Endian.little);

    // BitsPerSample
    header.setUint16(34, bitsPerSample, Endian.little);

    // data
    header.setUint8(36, 'd'.codeUnitAt(0));
    header.setUint8(37, 'a'.codeUnitAt(0));
    header.setUint8(38, 't'.codeUnitAt(0));
    header.setUint8(39, 'a'.codeUnitAt(0));

    // Subchunk2Size
    header.setUint32(40, dataSize, Endian.little);

    final data = Uint8List(dataSize);
    for (int i = 0; i < dataSize; i++) {
      data[i] = i % 256;
    }

    final combined = Uint8List(44 + dataSize);
    combined.setAll(0, header.buffer.asUint8List());
    combined.setAll(44, data);
    return combined;
  }

  File createWavFile(String filename, Uint8List data) {
    final file = File('${tempDir.path}/$filename');
    file.writeAsBytesSync(data);
    return file;
  }

  group('WavCombiner.getMetadata', () {
    test('extracts correct metadata from valid WAV', () async {
      final data = createMockWavData(
        sampleRate: 8000,
        channels: 2,
        bitsPerSample: 8,
        dataSize: 50,
      );
      final file = createWavFile('valid.wav', data);

      final metadata = await WavCombiner.getMetadata(file);

      expect(metadata.sampleRate, 8000);
      expect(metadata.channels, 2);
      expect(metadata.bitsPerSample, 8);
      expect(metadata.dataSize, 50);
    });

    test('throws exception for file smaller than 44 bytes', () async {
      final file = createWavFile('small.wav', Uint8List(40));
      expect(
        () => WavCombiner.getMetadata(file),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('too small'))),
      );
    });

    test('throws exception for missing RIFF header', () async {
      final data = createMockWavData();
      data[0] = 'B'.codeUnitAt(0); // Change RIFF to BIFF
      final file = createWavFile('bad_riff.wav', data);

      expect(
        () => WavCombiner.getMetadata(file),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('missing RIFF header'))),
      );
    });

    test('throws exception for missing WAVE header', () async {
      final data = createMockWavData();
      data[8] = 'C'.codeUnitAt(0); // Change WAVE to CAVE
      final file = createWavFile('bad_wave.wav', data);

      expect(
        () => WavCombiner.getMetadata(file),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('missing WAVE header'))),
      );
    });
  });

  group('WavCombiner.validateCompatibility', () {
    test('returns false for empty list', () async {
      expect(await WavCombiner.validateCompatibility([]), false);
    });

    test('returns true for single item', () async {
      final metadata = WavMetadata(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataSize: 100);
      expect(await WavCombiner.validateCompatibility([metadata]), true);
    });

    test('returns true for matching items', () async {
      final m1 = WavMetadata(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataSize: 100);
      final m2 = WavMetadata(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataSize: 200);
      expect(await WavCombiner.validateCompatibility([m1, m2]), true);
    });

    test('returns false for mismatched sample rates', () async {
      final m1 = WavMetadata(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataSize: 100);
      final m2 = WavMetadata(sampleRate: 8000, channels: 1, bitsPerSample: 16, dataSize: 100);
      expect(await WavCombiner.validateCompatibility([m1, m2]), false);
    });

    test('returns false for mismatched channels', () async {
      final m1 = WavMetadata(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataSize: 100);
      final m2 = WavMetadata(sampleRate: 16000, channels: 2, bitsPerSample: 16, dataSize: 100);
      expect(await WavCombiner.validateCompatibility([m1, m2]), false);
    });

    test('returns false for mismatched bits per sample', () async {
      final m1 = WavMetadata(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataSize: 100);
      final m2 = WavMetadata(sampleRate: 16000, channels: 1, bitsPerSample: 8, dataSize: 100);
      expect(await WavCombiner.validateCompatibility([m1, m2]), false);
    });
  });

  group('WavCombiner.combineWavFiles', () {
    test('throws exception for empty list', () async {
      expect(
        () => WavCombiner.combineWavFiles([], '${tempDir.path}/out.wav'),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('No WAV files'))),
      );
    });

    test('copies file when only one file is provided', () async {
      final data = createMockWavData();
      final file1 = createWavFile('single.wav', data);
      final outPath = '${tempDir.path}/out_single.wav';

      final outFile = await WavCombiner.combineWavFiles([file1], outPath);

      expect(outFile.path, outPath);
      expect(outFile.existsSync(), true);
      expect(outFile.readAsBytesSync(), data);
    });

    test('throws exception when files are incompatible', () async {
      final file1 = createWavFile('file1.wav', createMockWavData(sampleRate: 16000));
      final file2 = createWavFile('file2.wav', createMockWavData(sampleRate: 8000));
      final outPath = '${tempDir.path}/out_incompat.wav';

      expect(
        () => WavCombiner.combineWavFiles([file1, file2], outPath),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('incompatible formats'))),
      );
    });

    test('combines multiple valid files correctly', () async {
      final file1 = createWavFile('file1.wav', createMockWavData(dataSize: 100));
      final file2 = createWavFile('file2.wav', createMockWavData(dataSize: 200));
      final file3 = createWavFile('file3.wav', createMockWavData(dataSize: 50));

      final outPath = '${tempDir.path}/out_combined.wav';

      final outFile = await WavCombiner.combineWavFiles([file1, file2, file3], outPath);

      expect(outFile.existsSync(), true);

      final combinedMetadata = await WavCombiner.getMetadata(outFile);
      expect(combinedMetadata.sampleRate, 16000);
      expect(combinedMetadata.channels, 1);
      expect(combinedMetadata.bitsPerSample, 16);
      expect(combinedMetadata.dataSize, 350); // 100 + 200 + 50

      final combinedData = outFile.readAsBytesSync();
      expect(combinedData.length, 44 + 350);
    });
  });
}
