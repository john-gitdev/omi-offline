import 'dart:io';

void main() async {
  // Test 1: exists then delete
  final tempDir1 = Directory.systemTemp.createTempSync('test_perf1_');
  for (int i = 0; i < 1000; i++) {
    File('${tempDir1.path}/file_$i.txt').writeAsStringSync('test');
  }

  final sw1 = Stopwatch()..start();
  for (int i = 0; i < 1000; i++) {
    final file = File('${tempDir1.path}/file_$i.txt');
    if (await file.exists()) {
      await file.delete();
    }
  }
  sw1.stop();
  print('exists + delete (exists): ${sw1.elapsedMilliseconds} ms');

  // Test 2: try catch delete
  final tempDir2 = Directory.systemTemp.createTempSync('test_perf2_');
  for (int i = 0; i < 1000; i++) {
    File('${tempDir2.path}/file_$i.txt').writeAsStringSync('test');
  }

  final sw2 = Stopwatch()..start();
  for (int i = 0; i < 1000; i++) {
    final file = File('${tempDir2.path}/file_$i.txt');
    try {
      await file.delete();
    } catch (_) {}
  }
  sw2.stop();
  print('try catch delete (exists): ${sw2.elapsedMilliseconds} ms');

  // Test 3: exists then delete (not exists)
  final sw3 = Stopwatch()..start();
  for (int i = 0; i < 1000; i++) {
    final file = File('${tempDir1.path}/file_$i.txt');
    if (await file.exists()) {
      await file.delete();
    }
  }
  sw3.stop();
  print('exists + delete (not exists): ${sw3.elapsedMilliseconds} ms');

  // Test 4: try catch delete (not exists)
  final sw4 = Stopwatch()..start();
  for (int i = 0; i < 1000; i++) {
    final file = File('${tempDir2.path}/file_$i.txt');
    try {
      await file.delete();
    } catch (_) {}
  }
  sw4.stop();
  print('try catch delete (not exists): ${sw4.elapsedMilliseconds} ms');

  tempDir1.deleteSync(recursive: true);
  tempDir2.deleteSync(recursive: true);
}
