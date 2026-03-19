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

  test('getDailyBatches identifies and groups chunks correctly', () async {
    // Create mock structure:
    // raw_segments/100/0.bin (modified 2026-03-11)
    // raw_segments/100/1.bin (modified 2026-03-11)
    // raw_segments/101/0.bin (modified 2026-03-12)
    
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final session100Dir = Directory(p.join(rawDir.path, '100'))..createSync(recursive: true);
    final session101Dir = Directory(p.join(rawDir.path, '101'))..createSync(recursive: true);
    
    final file1 = File(p.join(session100Dir.path, '0.bin'))..writeAsBytesSync([0]);
    final file2 = File(p.join(session100Dir.path, '1.bin'))..writeAsBytesSync([0]);
    final file3 = File(p.join(session101Dir.path, '0.bin'))..writeAsBytesSync([0]);
    
    // Set modification times
    file1.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    file2.setLastModifiedSync(DateTime(2026, 3, 11, 11));
    file3.setLastModifiedSync(DateTime(2026, 3, 12, 10));
    
    final manager = RecordingsManager();
    final batches = await manager.getDailyBatches();
    
    expect(batches.length, 2);
    expect(batches[0].dateString, '2026-03-12');
    expect(batches[0].rawSegments.length, 1);
    expect(batches[1].dateString, '2026-03-11');
    expect(batches[1].rawSegments.length, 2);
  });

  test('getDailyBatches sorts chunks by filename within a day', () async {
    final rawDir = Directory(p.join(tempDir.path, 'raw_segments'));
    final session100Dir = Directory(p.join(rawDir.path, '100'))..createSync(recursive: true);
    
    // Create files in reverse order
    final file2 = File(p.join(session100Dir.path, 'chunk_1.bin'))..writeAsBytesSync([0]);
    final file1 = File(p.join(session100Dir.path, 'chunk_0.bin'))..writeAsBytesSync([0]);
    
    file1.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    file2.setLastModifiedSync(DateTime(2026, 3, 11, 10));
    
    final manager = RecordingsManager();
    final batches = await manager.getDailyBatches();
    
    expect(batches[0].rawSegments[0].path.endsWith('chunk_0.bin'), true);
    expect(batches[0].rawSegments[1].path.endsWith('chunk_1.bin'), true);
  });
}
