import 'dart:async';

class Mutex {
  final List<Completer<void>> _waiters = [];
  bool _held = false;

  bool get isLocked => _held;

  Future<void> acquire() async {
    if (!_held) {
      _held = true;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  /// Tries to acquire the mutex, giving up after [timeout]. Returns true on
  /// success, false on timeout. Safe under concurrent release(): on timeout
  /// the waiter is removed from the queue, so a later release() won't hand
  /// the lock to an abandoned caller.
  Future<bool> tryAcquire({required Duration timeout}) async {
    if (!_held) {
      _held = true;
      return true;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    try {
      await waiter.future.timeout(timeout);
      return true;
    } on TimeoutException {
      // If we're still in the queue, release() never reached us — just leave.
      // Otherwise release() already handed us the lock; release it for the next.
      if (_waiters.remove(waiter)) {
        return false;
      }
      release();
      return false;
    }
  }

  void release() {
    if (!_held) return;
    if (_waiters.isNotEmpty) {
      // Hand the lock directly to the next waiter — don't drop _held, which
      // would let a fresh acquire() barge ahead of queued waiters.
      _waiters.removeAt(0).complete();
    } else {
      _held = false;
    }
  }
}
