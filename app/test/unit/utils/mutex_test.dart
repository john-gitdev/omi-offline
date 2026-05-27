import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/mutex.dart';

void main() {
  group('Mutex', () {
    test('acquire block and release unblocks', () async {
      final mutex = Mutex();

      var count = 0;
      final futures = <Future<void>>[];

      final completer1 = Completer<void>();
      final completer2 = Completer<void>();

      // First acquire doesn't block
      futures.add(
        mutex.acquire().then((_) {
          count++;
          completer1.complete();
        }),
      );

      await completer1.future;
      expect(count, 1);

      // Second acquire should block because first hasn't released
      futures.add(
        mutex.acquire().then((_) {
          count++;
          completer2.complete();
        }),
      );

      // Wait a bit to ensure it doesn't run
      await Future.delayed(const Duration(milliseconds: 50));
      expect(count, 1); // still 1

      // Release first lock
      mutex.release();

      // Now second acquire should complete
      await completer2.future;
      expect(count, 2);

      // Release second lock
      mutex.release();

      await Future.wait(futures);
    });

    test('multiple acquires resolve in order', () async {
      final mutex = Mutex();
      final order = <int>[];
      final completer = Completer<void>();

      Future<void> runTask(int id, int delayMs) async {
        await mutex.acquire();
        // Simulate work
        await Future.delayed(Duration(milliseconds: delayMs));
        order.add(id);
        mutex.release();

        if (id == 3) {
          completer.complete();
        }
      }

      // Start tasks concurrently
      runTask(1, 100);
      runTask(2, 50);
      runTask(3, 10);

      await completer.future;

      // Tasks should execute sequentially despite different delays
      expect(order, [1, 2, 3]);
    });

    test('release without acquire does not throw', () {
      final mutex = Mutex();
      expect(() => mutex.release(), returnsNormally);
    });

    test('releasing more times than acquired does not break subsequent acquires', () async {
      final mutex = Mutex();

      await mutex.acquire();
      mutex.release();
      mutex.release(); // Extra release

      bool acquired = false;
      await mutex.acquire().then((_) => acquired = true);

      expect(acquired, isTrue);
      mutex.release();
    });
  });
}
