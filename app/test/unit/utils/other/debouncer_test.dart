import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/other/debouncer.dart';

void main() {
  group('Debouncer', () {
    test('fires the action once after the delay elapses', () {
      fakeAsync((async) {
        var calls = 0;
        final d = Debouncer(delay: const Duration(milliseconds: 100));
        d.run(() => calls++);

        async.elapse(const Duration(milliseconds: 99));
        expect(calls, 0, reason: 'must not fire before the delay');

        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 1, reason: 'fires exactly at the delay boundary');

        async.elapse(const Duration(seconds: 1));
        expect(calls, 1, reason: 'does not fire again on its own');
      });
    });

    test('rapid re-runs collapse to a single trailing call with the LAST action', () {
      fakeAsync((async) {
        final fired = <int>[];
        final d = Debouncer(delay: const Duration(milliseconds: 100));

        d.run(() => fired.add(1));
        async.elapse(const Duration(milliseconds: 50));
        d.run(() => fired.add(2)); // resets the timer
        async.elapse(const Duration(milliseconds: 50));
        d.run(() => fired.add(3)); // resets again
        async.elapse(const Duration(milliseconds: 100));

        expect(fired, [3], reason: 'only the last queued action runs, exactly once');
      });
    });

    test('cancel() prevents a pending action from firing', () {
      fakeAsync((async) {
        var calls = 0;
        final d = Debouncer(delay: const Duration(milliseconds: 100));
        d.run(() => calls++);
        async.elapse(const Duration(milliseconds: 50));
        d.cancel();
        async.elapse(const Duration(seconds: 1));
        expect(calls, 0);
      });
    });

    test('with a null delay the action never fires (disabled debouncer)', () {
      fakeAsync((async) {
        var calls = 0;
        final d = Debouncer(); // delay == null
        d.run(() => calls++);
        async.elapse(const Duration(seconds: 5));
        expect(calls, 0);
      });
    });

    test('a fresh run after one fired schedules another independent call', () {
      fakeAsync((async) {
        var calls = 0;
        final d = Debouncer(delay: const Duration(milliseconds: 100));
        d.run(() => calls++);
        async.elapse(const Duration(milliseconds: 100));
        expect(calls, 1);

        d.run(() => calls++);
        async.elapse(const Duration(milliseconds: 100));
        expect(calls, 2);
      });
    });
  });
}
