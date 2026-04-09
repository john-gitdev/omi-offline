import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/audio_player_utils.dart';

void main() {
  test('Benchmark inefficient List iteration', () async {
    // Generate some mock data
    final dataSize = 100000;
    final List<int> mockData = List.generate(dataSize, (index) => index % 256);

    // Simulate current behavior
    final stopwatch = Stopwatch()..start();
    List<int> data = [];
    for (int i = 0; i < mockData.length; i++) {
      var frame = mockData[i];
      data.addAll(Uint32List.fromList([frame]).buffer.asUint8List());
    }
    stopwatch.stop();
    print('Current method took: ${stopwatch.elapsedMilliseconds} ms');

    // Test optimized behavior
    final stopwatch2 = Stopwatch()..start();

    // To properly optimize it, we see: `Uint32List.fromList([frame]).buffer.asUint8List()`
    // This converts each integer to a 4-byte little-endian byte array, then adds to list.
    // Let's create an optimized version here to benchmark.
    final builder = BytesBuilder(copy: false);
    for (int i = 0; i < mockData.length; i++) {
      var frame = mockData[i];
      // Fast conversion of int to 4 bytes
      // If `frame` is guaranteed to fit in byte, the original code is weirdly casting it to 4 bytes.
      // Wait, let's look at Wal.data definition. `List<int>? data`.
      // Uint32List.fromList([frame]) creates a 4-byte sequence for each frame.

      builder.add(Uint32List.fromList([frame]).buffer.asUint8List());
    }
    stopwatch2.stop();
    print('Builder method took: ${stopwatch2.elapsedMilliseconds} ms');

    // An even better way
    final stopwatch3 = Stopwatch()..start();
    final optimizedData = Uint32List.fromList(mockData).buffer.asUint8List();
    stopwatch3.stop();
    print('Fully optimized method took: ${stopwatch3.elapsedMilliseconds} ms');

    // Verify equality
    expect(data.length, optimizedData.length);
    for (int i = 0; i < data.length; i++) {
      if (data[i] != optimizedData[i]) {
        print("Mismatch at $i: ${data[i]} != ${optimizedData[i]}");
        break;
      }
    }
  });
}
