import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

void main() {
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('recordings_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('getBatches identifies and groups segments correctly', () async {
    // Create mock structure:
    // raw_segments/100/100_0.bin (modified 2026-03-11)
    // raw_segments/100/100_1.bin (modified 2026-03-11)
    // raw_segments/101/101_0.bin (modified 2026-03-12)
    
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final deviceSession100Dir = Directory(p.join(rawDir.path, '100'))..createSync(recursive: true);
    final deviceSession101Dir = Directory(p.join(rawDir.path, '101'))..createSync(recursive: true);
    
    final file1 = File(p.join(deviceSession100Dir.path, '100_0.bin'))..writeAsBytesSync([0]);
    final file2 = File(p.join(deviceSession100Dir.path, '100_1.bin'))..writeAsBytesSync([0]);
    final file3 = File(p.join(deviceSession101Dir.path, '101_0.bin'))..writeAsBytesSync([0]);
    
    // Set modification times
    file1.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    file2.setLastModifiedSync(DateTime(2026, 3, 11, 11));
    file3.setLastModifiedSync(DateTime(2026, 3, 12, 10));
    
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    
    expect(batches.length, 2);
    expect(batches[0].dateString, '2026-03-12');
    expect(batches[0].rawSegments.length, 1);
    expect(batches[1].dateString, '2026-03-11');
    expect(batches[1].rawSegments.length, 2);
  });

  test('getBatches sorts segments by filename within a day', () async {
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final deviceSession100Dir = Directory(p.join(rawDir.path, '100'))..createSync(recursive: true);
    
    // Create files in reverse order
    final file2 = File(p.join(deviceSession100Dir.path, '100_1.bin'))..writeAsBytesSync([0]);
    final file1 = File(p.join(deviceSession100Dir.path, '100_0.bin'))..writeAsBytesSync([0]);
    
    file1.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    file2.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    
    expect(batches[0].rawSegments[0].path.endsWith('100_0.bin'), true);
    expect(batches[0].rawSegments[1].path.endsWith('100_1.bin'), true);
  });

  test('excludeNewestSegmentPerSession logic correctly excludes newest segment', () async {
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final deviceSession100Dir = Directory(p.join(rawDir.path, '100'))..createSync(recursive: true);

    // Create multiple segments for session 100
    final file0 = File(p.join(deviceSession100Dir.path, '100_0.bin'))..writeAsBytesSync([0]);
    final file1 = File(p.join(deviceSession100Dir.path, '100_1.bin'))..writeAsBytesSync([0]);
    final file2 = File(p.join(deviceSession100Dir.path, '100_2.bin'))..writeAsBytesSync([0]);

    // Set old modification times to avoid recency cutoff
    final oldTime = DateTime.now().subtract(const Duration(minutes: 1));
    file0.setLastModifiedSync(oldTime);
    file1.setLastModifiedSync(oldTime);
    file2.setLastModifiedSync(oldTime);

    final segments = [file0, file1, file2];
    final safeSegments = await RecordingsManager.excludeNewestSegmentPerSession(segments);

    expect(safeSegments.length, 2);
    expect(safeSegments.any((f) => f.path.endsWith('100_0.bin')), true);
    expect(safeSegments.any((f) => f.path.endsWith('100_1.bin')), true);
    expect(safeSegments.any((f) => f.path.endsWith('100_2.bin')), false);
  });

  test('excludeNewestSegmentPerSession keeps single-segment sessions', () async {
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final deviceSession102Dir = Directory(p.join(rawDir.path, '102'))..createSync(recursive: true);

    final file0 = File(p.join(deviceSession102Dir.path, '102_0.bin'))..writeAsBytesSync([0]);
    file0.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 1)));

    final safeSegments = await RecordingsManager.excludeNewestSegmentPerSession([file0]);

    expect(safeSegments.length, 1);
    expect(safeSegments[0].path.endsWith('102_0.bin'), true);
  });

  test('excludeNewestSegmentPerSession filters by recency', () async {
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final deviceSession103Dir = Directory(p.join(rawDir.path, '103'))..createSync(recursive: true);

    final file0 = File(p.join(deviceSession103Dir.path, '103_0.bin'))..writeAsBytesSync([0]);
    // Set modification time to now (within 5s cutoff)
    file0.setLastModifiedSync(DateTime.now());

    final safeSegments = await RecordingsManager.excludeNewestSegmentPerSession([file0]);

    expect(safeSegments.isEmpty, true);
  });
}
