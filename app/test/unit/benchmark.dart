import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:path/path.dart' as p;

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('recordings_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('benchmark getBatches', () async {
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'))..createSync();

    // Create large mock dataset
    print('creating files');
    for (int i = 0; i < 50; i++) {
      final sessionDir = Directory(p.join(rawDir.path, '$i'))..createSync();
      for (int j = 0; j < 50; j++) {
        File(p.join(sessionDir.path, '${i}_${j}.bin')).writeAsBytesSync([0]);
      }
    }

    final recordingsDir = Directory(p.join(tempDir.path, 'recordings'))..createSync();
    for (int i = 1; i <= 30; i++) {
      final dateStr = '2023-10-${i.toString().padLeft(2, "0")}';
      final dateDir = Directory(p.join(recordingsDir.path, dateStr))..createSync();
      for (int j = 0; j < 50; j++) {
        File(p.join(dateDir.path, 'rec_${j}.m4a')).writeAsBytesSync([0]);
      }
    }

    print('running getBatches...');
    final manager = RecordingsManager();
    final stopwatch = Stopwatch()..start();

    for (int i = 0; i < 5; i++) {
      await manager.getBatches();
    }

    stopwatch.stop();
    print('5 iterations took: ${stopwatch.elapsedMilliseconds} ms');
    print('Average: ${stopwatch.elapsedMilliseconds / 5} ms');
  });
}
