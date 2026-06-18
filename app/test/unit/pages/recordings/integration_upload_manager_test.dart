import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/integration_upload_types.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/pages/recordings/integration_upload_manager.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fully controllable PassthroughIntegration for driving the manager without
/// any real network/plugin. Tracks upload() calls (order + concurrency) and lets
/// each test pick the upload outcome: deliver (default), throw, 503-backoff, or
/// pending (no-op).
class FakeIntegration implements PassthroughIntegration {
  FakeIntegration(this.name, {this.configured = true, this.autoUpload = false});

  @override
  final String name;
  bool configured;
  bool autoUpload;
  bool availableByDefault = true;
  bool enabledByDefault = false;
  int concurrency = 1;

  final Set<String> _delivered = {};
  final Set<String> _backingOff = {};
  final Set<String> _available = {};
  final Set<String> _enabled = {};
  final Set<String> _failed = {};

  /// Recorded upload() invocations, in call order.
  final List<Conversation> uploadCalls = [];
  int inFlight = 0;
  int maxObservedInFlight = 0;

  /// Per-call behavior. If null, upload() delivers immediately.
  Future<void> Function(Conversation c)? onUpload;

  void deliver(Conversation c) => _delivered.add(c.uploadKey!);
  void backOff(Conversation c) => _backingOff.add(c.uploadKey!);
  void markFailed(Conversation c) => _failed.add(c.uploadKey!);
  void setAvailable(Conversation c, bool v) => v ? _available.add(c.uploadKey!) : _available.remove(c.uploadKey!);
  void setEnabled(Conversation c) => _enabled.add(c.uploadKey!);

  @override
  int get concurrencyLimit => concurrency;
  @override
  String getRetryKey(Conversation c) => c.uploadKey ?? c.file.path;
  @override
  bool isEnabled(Conversation c) => configured && (enabledByDefault || _enabled.contains(c.uploadKey));
  @override
  bool isAvailableFor(Conversation c) => configured && (availableByDefault || _available.contains(c.uploadKey));
  @override
  bool get isConfigured => configured;
  @override
  bool get isAutoUploadEnabled => autoUpload;
  @override
  bool hasDelivered(Conversation c) => _delivered.contains(c.uploadKey);
  @override
  bool isFailed(Conversation c) => _failed.contains(c.uploadKey);
  @override
  (int, int)? segmentProgress(Conversation c) => null;
  @override
  bool isBackingOff(Conversation c) => _backingOff.contains(c.uploadKey);
  @override
  DateTime? backingOffUntil(Conversation c) =>
      _backingOff.contains(c.uploadKey) ? DateTime.now().add(const Duration(minutes: 5)) : null;

  /// Exposes the cancel callback the manager passed into the most recent (or
  /// in-flight) upload, so tests can assert the lane signalled cancellation.
  bool Function()? lastIsCancelled;

  @override
  Future<void> upload(Conversation c, {void Function()? onProgress, bool Function()? isCancelled}) async {
    uploadCalls.add(c);
    lastIsCancelled = isCancelled;
    inFlight++;
    if (inFlight > maxObservedInFlight) maxObservedInFlight = inFlight;
    try {
      if (onUpload != null) {
        await onUpload!(c);
      } else if (isCancelled?.call() ?? false) {
        return; // cancelled before/while running — do not deliver
      } else {
        deliver(c);
      }
    } finally {
      inFlight--;
    }
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    tempDir = Directory.systemTemp.createTempSync('upload_mgr_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Conversation conv(String key, {Duration dur = const Duration(minutes: 5), String? path}) => Conversation(
        file: File(path ?? '/tmp/recording_$key.wav'),
        startTime: DateTime(2026, 1, 1),
        duration: dur,
        uploadKey: key,
      );

  IntegrationUploadManager makeManager(
    List<PassthroughIntegration> integrations, {
    List<Batch> Function()? batchesProvider,
    bool Function()? isPipelineIdle,
  }) {
    return IntegrationUploadManager(
      integrations: integrations,
      prefs: SharedPreferencesUtil(),
      batchesProvider: batchesProvider ?? () => const [],
      isDisposed: () => false,
      isPipelineIdle: isPipelineIdle ?? () => true,
      notifyUi: () {},
      acquireWake: (_) {},
      releaseWake: (_) {},
      showUploadNotification: (_) {},
      settleNotification: () {},
      setPendingSnack: (_) {},
      checkOnWifi: () async => true,
      convertToPassthrough: (_) async {},
    );
  }

  /// Pumps the event loop until no upload is in flight or queued, or a bounded
  /// number of iterations elapses (so a wedged test fails fast rather than hangs).
  Future<void> settle(IntegrationUploadManager m) async {
    for (var i = 0; i < 200 && m.uploadingFiles.isNotEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 1));
    }
  }

  group('manual upload', () {
    test('uploads to every available integration', () async {
      final a = FakeIntegration('A');
      final b = FakeIntegration('B');
      final m = makeManager([a, b]);

      final failures = await m.uploadConversation(conv('k1'));
      await settle(m);

      expect(failures, isEmpty);
      expect(a.uploadCalls.length, 1);
      expect(b.uploadCalls.length, 1);
      expect(a.hasDelivered(conv('k1')), true);
      expect(b.hasDelivered(conv('k1')), true);
    });

    test('returns a failure when no integration is available', () async {
      final a = FakeIntegration('A')..availableByDefault = false;
      final m = makeManager([a]);

      final failures = await m.uploadConversation(conv('k1'));

      expect(failures.length, 1);
      expect(a.uploadCalls, isEmpty);
    });

    test('skips an integration that already delivered (unless forced)', () async {
      final a = FakeIntegration('A');
      final c = conv('k1');
      a.deliver(c);
      final m = makeManager([a]);

      final failures = await m.uploadConversation(c);
      await settle(m);

      // Nothing left to upload → reported as "no integrations enabled".
      expect(failures.length, 1);
      expect(a.uploadCalls, isEmpty);
    });

    test('force re-uploads an already-delivered recording', () async {
      final a = FakeIntegration('A');
      final c = conv('k1');
      a.deliver(c);
      final m = makeManager([a]);

      await m.uploadConversation(c, force: true);
      await settle(m);

      expect(a.uploadCalls.length, 1);
    });

    test('uploadOne targets only the named integration', () async {
      final a = FakeIntegration('A');
      final b = FakeIntegration('B');
      final m = makeManager([a, b]);

      await m.uploadOne(conv('k1'), 'A');
      await settle(m);

      expect(a.uploadCalls.length, 1);
      expect(b.uploadCalls, isEmpty);
    });

    test('uploadOne on an unknown integration returns a failure', () async {
      final a = FakeIntegration('A');
      final m = makeManager([a]);

      final failures = await m.uploadOne(conv('k1'), 'Nope');

      expect(failures.length, 1);
      expect(a.uploadCalls, isEmpty);
    });
  });

  group('lane scheduling', () {
    test('dedup: a second enqueue of the same in-flight job is ignored', () async {
      final gate = Completer<void>();
      final a = FakeIntegration('A');
      a.onUpload = (c) async {
        await gate.future;
        a.deliver(c);
      };
      final m = makeManager([a]);
      final c = conv('k1');

      await m.uploadConversation(c); // dequeued + in flight (gated)
      await m.uploadConversation(c); // same key — must dedup against in-flight
      gate.complete();
      await settle(m);

      expect(a.uploadCalls.length, 1);
    });

    test('within a lane, jobs run strictly one at a time', () async {
      final a = FakeIntegration('A');
      a.onUpload = (c) async {
        await Future.delayed(const Duration(milliseconds: 10));
        a.deliver(c);
      };
      final m = makeManager([a]);

      await m.uploadConversation(conv('k1'));
      await m.uploadConversation(conv('k2'));
      await settle(m);

      expect(a.uploadCalls.length, 2);
      expect(a.maxObservedInFlight, 1, reason: 'a single integration must never run two uploads at once');
    });

    test('different integrations upload concurrently', () async {
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      final a = FakeIntegration('A');
      final b = FakeIntegration('B');
      a.onUpload = (c) async {
        await gateA.future;
        a.deliver(c);
      };
      b.onUpload = (c) async {
        await gateB.future;
        b.deliver(c);
      };
      final m = makeManager([a, b]);

      await m.uploadConversation(conv('k1')); // enqueues to both lanes, both pump
      await Future.delayed(const Duration(milliseconds: 5));

      // Both lanes should have an upload in flight at the same time.
      expect(a.inFlight, 1);
      expect(b.inFlight, 1);

      gateA.complete();
      gateB.complete();
      await settle(m);
      expect(a.hasDelivered(conv('k1')), true);
      expect(b.hasDelivered(conv('k1')), true);
    });

    test('a failure fails-fast: remaining queued jobs in the lane are dropped', () async {
      final gate = Completer<void>();
      final a = FakeIntegration('A')
        ..onUpload = ((c) async {
          await gate.future;
          throw Exception('boom');
        });
      final m = makeManager([a]);

      await m.uploadConversation(conv('k1')); // in flight (gated), will throw
      await m.uploadConversation(conv('k2')); // queued behind it
      gate.complete();
      await settle(m);

      expect(a.uploadCalls.length, 1, reason: 'k2 must be purged after k1 fails, never uploaded');
      expect(a.uploadCalls.first.uploadKey, 'k1');
    });

    test('a 503 backoff re-queues the job and pauses the lane (no delivery)', () async {
      final a = FakeIntegration('A');
      a.onUpload = (c) async => a.backOff(c); // 503: back off, don't deliver
      final m = makeManager([a]);
      final c = conv('k1');

      await m.uploadConversation(c);
      await settle(m);

      expect(a.uploadCalls.length, 1);
      expect(a.hasDelivered(c), false, reason: '503 is not a delivery');
      expect(m.uploadingFiles.contains('k1'), true, reason: 'the job is re-queued for a later resume');
    });

    test('delivered-by-another-path is re-validated and skipped at dequeue', () async {
      final gate = Completer<void>();
      final a = FakeIntegration('A');
      a.onUpload = (c) async {
        await gate.future;
        a.deliver(c);
      };
      final m = makeManager([a]);
      final c1 = conv('k1');
      final c2 = conv('k2');

      await m.uploadConversation(c1); // in flight (gated)
      await m.uploadConversation(c2); // queued
      a.deliver(c2); // some other path delivers k2 before its turn
      gate.complete();
      await settle(m);

      // k1 uploaded; k2 dequeued but skipped because it was already delivered.
      expect(a.uploadCalls.map((c) => c.uploadKey), ['k1']);
    });
  });

  group('cancel actions', () {
    test('cancelHeyPocketUploads purges queued HeyPocket jobs', () async {
      final gate = Completer<void>();
      final hp = FakeIntegration('HeyPocket');
      hp.onUpload = (c) async {
        await gate.future;
        hp.deliver(c);
      };
      final m = makeManager([hp]);

      await m.uploadConversation(conv('k1')); // in flight (gated)
      await m.uploadConversation(conv('k2')); // queued
      expect(m.uploadingFiles, containsAll(<String>{'k1', 'k2'}));

      m.cancelHeyPocketUploads();
      gate.complete();
      await settle(m);

      // k2 was queued → dropped. k1 was already mid-request → drains (single-shot,
      // can't be aborted once started).
      expect(hp.uploadCalls.map((c) => c.uploadKey), ['k1']);
    });

    test('cancelOmiUploads aborts the in-flight chunked upload and drops the queue', () async {
      // A chunked (Omi-style) upload polls isCancelled and bails mid-run.
      final omi = FakeIntegration('Omi Cloud');
      omi.onUpload = (c) async {
        // Simulate chunk-by-chunk work that checks the cancel signal between
        // chunks; bail without delivering once cancellation is requested.
        for (var i = 0; i < 50; i++) {
          if (omi.lastIsCancelled?.call() ?? false) return;
          await Future.delayed(const Duration(milliseconds: 1));
        }
        omi.deliver(c);
      };
      final m = makeManager([omi]);

      await m.uploadConversation(conv('k1')); // in flight (chunking)
      await m.uploadConversation(conv('k2')); // queued
      expect(m.uploadingFiles, containsAll(<String>{'k1', 'k2'}));

      m.cancelOmiUploads();
      await settle(m);

      // k1 started but bailed without delivering; k2 was dropped before it ran.
      expect(omi.uploadCalls.map((c) => c.uploadKey), ['k1']);
      expect(omi.hasDelivered(conv('k1')), false, reason: 'in-flight upload was cancelled, not delivered');
      expect(m.uploadingFiles, isEmpty);
    });

    test('a cancelled upload is not recorded as failed', () async {
      final omi = FakeIntegration('Omi Cloud');
      omi.onUpload = (c) async {
        for (var i = 0; i < 50; i++) {
          if (omi.lastIsCancelled?.call() ?? false) return;
          await Future.delayed(const Duration(milliseconds: 1));
        }
        omi.deliver(c);
      };
      final m = makeManager([omi]);
      final c = conv('k1');

      await m.uploadConversation(c);
      m.cancelOmiUploads();
      await settle(m);

      // Reverts to pending (not delivered, not failed) so it can upload later.
      expect(m.integrationStatuses(c).single.state, IntegrationUploadState.pending);
    });

    test('lane uploads normally again after a cancel', () async {
      final omi = FakeIntegration('Omi Cloud');
      omi.onUpload = (c) async {
        for (var i = 0; i < 50; i++) {
          if (omi.lastIsCancelled?.call() ?? false) return;
          await Future.delayed(const Duration(milliseconds: 1));
        }
        omi.deliver(c);
      };
      final m = makeManager([omi]);

      await m.uploadConversation(conv('k1'));
      m.cancelOmiUploads();
      await settle(m);
      expect(omi.hasDelivered(conv('k1')), false);

      // Re-enable path: a fresh upload after the cancel drains and delivers.
      omi.onUpload = (c) async => omi.deliver(c);
      await m.uploadConversation(conv('k2'));
      await settle(m);
      expect(omi.hasDelivered(conv('k2')), true, reason: 'cancelRequested must reset after the worker exits');
    });

    // Builds an on-disk, auto-eligible recording + batch for the auto sweep.
    Batch autoBatch(String key, {required Directory dir}) {
      final f = File('${dir.path}/recording_$key.wav')..writeAsBytesSync(List.filled(2048, 0));
      final c =
          Conversation(file: f, startTime: DateTime(2026, 1, 1), duration: const Duration(minutes: 5), uploadKey: key);
      return Batch(
        dateString: '2026-01-01',
        date: DateTime(2026, 1, 1),
        rawSegments: const [],
        draftRecordings: const [],
        finalizedRecordings: [c],
      );
    }

    test('auto-only cancel drops queued auto jobs but keeps an in-flight manual upload', () async {
      final gate = Completer<void>();
      final omi = FakeIntegration('Omi Cloud', autoUpload: true)..enabledByDefault = true;
      omi.onUpload = (c) async {
        await gate.future;
        omi.deliver(c);
      };
      final m = makeManager([omi], batchesProvider: () => [autoBatch('auto', dir: tempDir)]);

      await m.uploadConversation(conv('manual')); // manual drains first → in flight (gated)
      m.tryAutoUploadAll(); // auto job queued behind it
      expect(m.uploadingFiles, containsAll(<String>{'manual', 'auto'}));

      m.cancelOmiUploads(autoOnly: true); // drop the queued auto job; keep the manual one
      gate.complete();
      await settle(m);

      expect(omi.uploadCalls.map((c) => c.uploadKey), ['manual'], reason: 'auto job dropped, manual ran');
      expect(omi.hasDelivered(conv('manual')), true);
    });

    test('auto-only cancel does not interrupt an in-flight manual upload', () async {
      final omi = FakeIntegration('Omi Cloud');
      omi.onUpload = (c) async {
        for (var i = 0; i < 50; i++) {
          if (omi.lastIsCancelled?.call() ?? false) return;
          await Future.delayed(const Duration(milliseconds: 1));
        }
        omi.deliver(c);
      };
      final m = makeManager([omi]);

      await m.uploadConversation(conv('m1')); // manual, in flight (chunking)
      m.cancelOmiUploads(autoOnly: true);
      await settle(m);

      expect(omi.hasDelivered(conv('m1')), true, reason: 'auto-only cancel must leave a manual upload running');
    });

    test('activeUploadCountFor counts in-flight + queued for the integration', () async {
      final gate = Completer<void>();
      final a = FakeIntegration('Omi Cloud');
      a.onUpload = (c) async {
        await gate.future;
        a.deliver(c);
      };
      final m = makeManager([a]);

      expect(m.activeUploadCountFor('Omi Cloud'), 0);
      await m.uploadConversation(conv('k1')); // in flight (gated)
      await m.uploadConversation(conv('k2')); // queued
      await m.uploadConversation(conv('k3')); // queued
      expect(m.activeUploadCountFor('Omi Cloud'), 3);

      gate.complete();
      await settle(m);
      expect(m.activeUploadCountFor('Omi Cloud'), 0);
    });

    test('isCancellableUpload is true for in-flight/queued, false otherwise', () async {
      final gate = Completer<void>();
      final a = FakeIntegration('Omi Cloud');
      a.onUpload = (c) async {
        await gate.future;
        a.deliver(c);
      };
      final m = makeManager([a]);

      // Nothing active yet → not cancellable (the phantom-uploading no-op case).
      expect(m.isCancellableUpload(conv('k1'), 'Omi Cloud'), false);
      expect(m.isCancellableUpload(conv('k1'), 'Nonexistent'), false);

      await m.uploadConversation(conv('k1')); // in flight (gated)
      await m.uploadConversation(conv('k2')); // queued
      expect(m.isCancellableUpload(conv('k1'), 'Omi Cloud'), true, reason: 'in flight');
      expect(m.isCancellableUpload(conv('k2'), 'Omi Cloud'), true, reason: 'queued');
      expect(m.isCancellableUpload(conv('k3'), 'Omi Cloud'), false, reason: 'never enqueued');

      gate.complete();
      await settle(m);
      // Delivered → no in-flight/queued job left to cancel.
      expect(m.isCancellableUpload(conv('k1'), 'Omi Cloud'), false);
    });

    test('isCancellingUpload is true from cancel request until the job bails', () async {
      final a = FakeIntegration('Omi Cloud');
      a.onUpload = (c) async {
        for (var i = 0; i < 100; i++) {
          if (a.lastIsCancelled?.call() ?? false) return;
          await Future.delayed(const Duration(milliseconds: 1));
        }
        a.deliver(c);
      };
      final m = makeManager([a]);

      await m.uploadConversation(conv('k1')); // in flight (chunking)
      expect(m.isCancellingUpload(conv('k1'), 'Omi Cloud'), false, reason: 'no cancel requested yet');

      m.cancelUpload(conv('k1'), 'Omi Cloud');
      expect(m.isCancellingUpload(conv('k1'), 'Omi Cloud'), true, reason: 'cancel pending, still winding down');

      await settle(m);
      expect(m.isCancellingUpload(conv('k1'), 'Omi Cloud'), false, reason: 'job bailed — nothing in flight');
      expect(a.hasDelivered(conv('k1')), false);
    });

    test('cancelUpload drops just the named recording, leaving the rest queued', () async {
      final gate = Completer<void>();
      final a = FakeIntegration('Omi Cloud');
      a.onUpload = (c) async {
        await gate.future;
        a.deliver(c);
      };
      final m = makeManager([a]);

      await m.uploadConversation(conv('k1')); // in flight (gated)
      await m.uploadConversation(conv('k2')); // queued
      await m.uploadConversation(conv('k3')); // queued

      m.cancelUpload(conv('k2'), 'Omi Cloud'); // pull k2 out of the queue
      expect(m.uploadingFiles, containsAll(<String>{'k1', 'k3'}));
      expect(m.uploadingFiles.contains('k2'), false);

      gate.complete();
      await settle(m);

      // k1 (in flight) and k3 (still queued) ran; k2 was cancelled.
      expect(a.uploadCalls.map((c) => c.uploadKey), ['k1', 'k3']);
    });

    test('cancelUpload aborts the in-flight job but keeps draining the queue', () async {
      final a = FakeIntegration('Omi Cloud');
      a.onUpload = (c) async {
        // k1 chunk-loops (cancellable); k2/k3 deliver immediately.
        if (c.uploadKey == 'k1') {
          for (var i = 0; i < 100; i++) {
            if (a.lastIsCancelled?.call() ?? false) return;
            await Future.delayed(const Duration(milliseconds: 1));
          }
        }
        a.deliver(c);
      };
      final m = makeManager([a]);

      await m.uploadConversation(conv('k1')); // in flight (chunking)
      await m.uploadConversation(conv('k2')); // queued
      await m.uploadConversation(conv('k3')); // queued

      m.cancelUpload(conv('k1'), 'Omi Cloud'); // bail just the in-flight one
      await settle(m);

      expect(a.hasDelivered(conv('k1')), false, reason: 'in-flight job aborted');
      expect(a.hasDelivered(conv('k2')), true, reason: 'queue keeps draining');
      expect(a.hasDelivered(conv('k3')), true);
    });

    test('cancelAllUploadsFor clears the whole lane', () async {
      final gate = Completer<void>();
      final a = FakeIntegration('Omi Cloud');
      a.onUpload = (c) async {
        for (var i = 0; i < 50; i++) {
          if (a.lastIsCancelled?.call() ?? false) return;
          await Future.delayed(const Duration(milliseconds: 1));
        }
        await gate.future;
        a.deliver(c);
      };
      final m = makeManager([a]);

      await m.uploadConversation(conv('k1')); // in flight (chunking)
      await m.uploadConversation(conv('k2')); // queued
      await m.uploadConversation(conv('k3')); // queued

      m.cancelAllUploadsFor('Omi Cloud');
      await settle(m);

      expect(a.uploadCalls.map((c) => c.uploadKey), ['k1'], reason: 'k2/k3 dropped, k1 aborted');
      expect(a.hasDelivered(conv('k1')), false);
      expect(m.uploadingFiles, isEmpty);
    });

    test('auto-only cancel aborts an in-flight auto upload', () async {
      final omi = FakeIntegration('Omi Cloud', autoUpload: true)..enabledByDefault = true;
      omi.onUpload = (c) async {
        for (var i = 0; i < 50; i++) {
          if (omi.lastIsCancelled?.call() ?? false) return;
          await Future.delayed(const Duration(milliseconds: 1));
        }
        omi.deliver(c);
      };
      final m = makeManager([omi], batchesProvider: () => [autoBatch('a1', dir: tempDir)]);

      m.tryAutoUploadAll();
      await Future.delayed(const Duration(milliseconds: 5)); // let the auto job reach in-flight
      expect(m.uploadingFiles.contains('a1'), true);

      m.cancelOmiUploads(autoOnly: true);
      await settle(m);

      expect(omi.hasDelivered(conv('a1')), false, reason: 'in-flight auto upload is cancelled by auto-only cancel');
    });
  });

  group('status derivation', () {
    // uploadStatus's "any configured" guard consults the real integration
    // factory via prefs, so configure HeyPocket in prefs to pass the guard; the
    // per-integration states still come from the injected fakes.
    setUp(() async {
      final prefs = SharedPreferencesUtil();
      prefs.heypocketEnabled = true;
      await prefs.setHeypocketApiKey('x');
    });

    test('delivered across all → UploadStatus.all / isUploaded', () {
      final a = FakeIntegration('A');
      final c = conv('k1');
      a.deliver(c);
      final m = makeManager([a]);

      expect(m.uploadStatus(c), UploadStatus.all);
      expect(m.isUploaded(c), true);
      final statuses = m.integrationStatuses(c);
      expect(statuses.single.state, IntegrationUploadState.delivered);
    });

    test('fresh available recording → pending, none delivered', () {
      final a = FakeIntegration('A');
      final m = makeManager([a]);
      final c = conv('k1');

      expect(m.integrationStatuses(c).single.state, IntegrationUploadState.pending);
      expect(m.uploadStatus(c), UploadStatus.none);
      expect(m.actionableIntegrationCount(c), 1);
    });

    test('unavailable integrations are excluded from the aggregate', () {
      final a = FakeIntegration('A')..availableByDefault = false; // not available for k1
      final b = FakeIntegration('B'); // available, delivered
      final c = conv('k1');
      b.deliver(c);
      final m = makeManager([a, b]);

      final byName = {for (final s in m.integrationStatuses(c)) s.name: s.state};
      expect(byName['A'], IntegrationUploadState.unavailable);
      expect(byName['B'], IntegrationUploadState.delivered);
      // The unavailable one is ignored; every relevant one delivered → all.
      expect(m.uploadStatus(c), UploadStatus.all);
    });

    test('exhausted manual failure surfaces as failed', () {
      final a = FakeIntegration('A');
      final c = conv('k1');
      a.markFailed(c); // isFailed → true, and not auto-eligible → failed (not retrying)
      final m = makeManager([a]);

      expect(m.integrationStatuses(c).single.state, IntegrationUploadState.failed);
      expect(m.uploadStatus(c), UploadStatus.failed);
      expect(m.actionableIntegrationCount(c), 1);
    });

    test('unconfigured integrations are not reported at all', () {
      final a = FakeIntegration('A', configured: false);
      final m = makeManager([a]);

      expect(m.integrationStatuses(conv('k1')), isEmpty);
    });
  });

  group('auto-upload sweep', () {
    test('enqueues only auto-eligible, available, undelivered recordings', () async {
      // a is auto-enabled; b is not. Only a should upload.
      final a = FakeIntegration('A', autoUpload: true)..enabledByDefault = true;
      final b = FakeIntegration('B', autoUpload: false);

      // Real on-disk file so fileSizeBytes > 0 (the sweep skips empty recordings).
      final f = File('${tempDir.path}/recording_900.wav')..writeAsBytesSync(List.filled(2048, 0));
      final c = Conversation(
        file: f,
        startTime: DateTime(2026, 1, 1),
        duration: const Duration(minutes: 5),
        uploadKey: 'k1',
      );
      final batch = Batch(
        dateString: '2026-01-01',
        date: DateTime(2026, 1, 1),
        rawSegments: const [],
        draftRecordings: const [],
        finalizedRecordings: [c],
      );

      final m = makeManager([a, b], batchesProvider: () => [batch]);
      m.tryAutoUploadAll();
      await settle(m);

      expect(a.uploadCalls.length, 1);
      expect(b.uploadCalls, isEmpty, reason: 'auto-upload-disabled integration is never swept');
    });

    test('passthrough and zero-duration recordings are skipped by the sweep', () async {
      final a = FakeIntegration('A', autoUpload: true)..enabledByDefault = true;
      final f = File('${tempDir.path}/recording_901.wav')..writeAsBytesSync(List.filled(2048, 0));
      final passthrough = Conversation(
        file: f,
        startTime: DateTime(2026, 1, 1),
        duration: const Duration(minutes: 5),
        uploadKey: 'k1',
        passthrough: true,
      );
      final batch = Batch(
        dateString: '2026-01-01',
        date: DateTime(2026, 1, 1),
        rawSegments: const [],
        draftRecordings: const [],
        finalizedRecordings: [passthrough],
      );

      final m = makeManager([a], batchesProvider: () => [batch]);
      m.tryAutoUploadAll();
      await settle(m);

      expect(a.uploadCalls, isEmpty);
    });
  });
}
