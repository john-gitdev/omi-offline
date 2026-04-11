import 'dart:io';

void main() {
  final paths = [
    '/data/user/0/com.example.app/app_flutter/sessions/12345/1680000000_1.bin',
    '/data/user/0/com.example.app/app_flutter/sessions/12345/1680000001.bin',
    '1680000002_0.bin',
    '1680000003.bin'
  ];

  // Baseline
  final sw1 = Stopwatch()..start();
  int sum1 = 0;
  for (int j = 0; j < 1000000; j++) {
    for (int i = 0; i < paths.length; i++) {
      final pathStr = paths[i];
      final stem = pathStr.split('/').last.split('.').first;
      final timerStart = int.tryParse(stem.split('_').first);
      sum1 += timerStart ?? 0;
    }
  }
  sw1.stop();
  print('Baseline: ${sw1.elapsedMilliseconds} ms (Sum: $sum1)');

  // Extract from string directly without splits
  final sw3 = Stopwatch()..start();
  int sum3 = 0;
  for (int j = 0; j < 1000000; j++) {
    for (int i = 0; i < paths.length; i++) {
      final pathStr = paths[i];
      int startIdx = pathStr.lastIndexOf('/') + 1;
      int dotIdx = pathStr.indexOf('.', startIdx);
      int endIdx = dotIdx == -1 ? pathStr.length : dotIdx;
      int underscoreIdx = pathStr.indexOf('_', startIdx);
      if (underscoreIdx != -1 && underscoreIdx < endIdx) {
        endIdx = underscoreIdx;
      }
      final timerStart = int.tryParse(pathStr.substring(startIdx, endIdx));
      sum3 += timerStart ?? 0;
    }
  }
  sw3.stop();
  print('Extract from string directly: ${sw3.elapsedMilliseconds} ms (Sum: $sum3)');
}
