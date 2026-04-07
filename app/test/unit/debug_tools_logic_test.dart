import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/recordings_manager.dart';

void main() {
  group('Debug Tools Logic Tests', () {
    test('excludeNewestSegmentPerSession logic excludes highest index ONLY if multiple files exist and recent files', () async {
      final tempDir = Directory.systemTemp.createTempSync('omi_test');

      try {
        final session1 = Directory('${tempDir.path}/1000');
        session1.createSync();
        final file1_0 = File('${session1.path}/1000_0.bin')..createSync();
        final file1_1 = File('${session1.path}/1000_1.bin')..createSync();
        final file1_2 = File('${session1.path}/1000_2.bin')..createSync(); // Should be excluded (highest index)

        final session2 = Directory('${tempDir.path}/2000');
        session2.createSync();
        final file2_0 = File('${session2.path}/2000_0.bin')..createSync(); // Single file in session -> Should be INCLUDED

        await Process.run('touch', ['-d', '1 hour ago', file1_0.path, file1_1.path, file1_2.path, file2_0.path]);

        final inputFiles = [file1_0, file1_1, file1_2, file2_0];
        final filteredFiles = RecordingsManager.excludeNewestSegmentPerSession(inputFiles);

        expect(filteredFiles.contains(file1_0), isTrue);
        expect(filteredFiles.contains(file1_1), isTrue);
        expect(filteredFiles.contains(file1_2), isFalse); // highest in session 1000
        expect(filteredFiles.contains(file2_0), isTrue); // only file in session 2000 (kept!)

        // Now test recency exclusion
        final file1_3 = File('${session1.path}/1000_3.bin')..createSync();
        await Process.run('touch', ['-d', '1 hour ago', file1_3.path]);
        await Process.run('touch', ['-d', 'now', file1_2.path]); // recent

        final inputFiles2 = [file1_0, file1_1, file1_2, file1_3];
        final filteredFiles2 = RecordingsManager.excludeNewestSegmentPerSession(inputFiles2);

        expect(filteredFiles2.contains(file1_0), isTrue);
        expect(filteredFiles2.contains(file1_1), isTrue);
        expect(filteredFiles2.contains(file1_2), isFalse, reason: 'Excluded due to recency');
        expect(filteredFiles2.contains(file1_3), isFalse, reason: 'Excluded due to highest index');

      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
