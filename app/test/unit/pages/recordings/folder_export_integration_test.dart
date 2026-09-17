import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/integration_upload_types.dart';
import 'package:omi/pages/recordings/integration_upload_manager.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:omi/services/folder_export_service.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A folder in memory: document uri -> name. Behaves the way FolderExportChannel.kt
/// reports: NO_ACCESS when [access] is off, SOURCE_GONE for a missing source, GONE when
/// renaming a document that is not there, and a rename changing the uri. There is no
/// delete: the integration has no way to remove a copy, by design.
class FakeFolder implements FolderExportBackend {
  final Map<String, String> files = {};
  final List<String> calls = [];

  /// Document uri -> the MIME type it was created with.
  final Map<String, String> mimeTypes = {};
  bool access = true;
  int _next = 0;

  /// When set, a copy waits on it after checking its source, as a long copy would.
  Completer<void>? copyGate;

  /// When set, a rename waits on it before answering.
  Completer<void>? renameGate;

  /// False models a provider without FLAG_SUPPORTS_RENAME.
  bool canRename = true;

  FolderExportException _noAccess() => const FolderExportException(FolderExportError.noAccess, 'no access');

  @override
  Future<PickedFolder?> pickFolder() async => null;

  @override
  Future<void> releaseFolder(String treeUri) async => calls.add('release $treeUri');

  @override
  Future<bool> hasAccess(String treeUri) async => access;

  @override
  Future<String> copyInto(String treeUri, String sourcePath, String name, String mimeType) async {
    calls.add('copy $name');
    if (!access) throw _noAccess();
    if (!File(sourcePath).existsSync()) {
      throw const FolderExportException(FolderExportError.sourceGone, 'source gone');
    }
    if (copyGate != null) await copyGate!.future;
    final uri = 'doc${_next++}';
    files[uri] = name;
    mimeTypes[uri] = mimeType;
    return uri;
  }

  @override
  Future<String> rename(String treeUri, String docUri, String name) async {
    calls.add('rename $name');
    if (renameGate != null) await renameGate!.future;
    if (!access) throw _noAccess();
    if (!files.containsKey(docUri)) throw const FolderExportException(FolderExportError.gone, 'gone');
    if (!canRename) throw const FolderExportException(FolderExportError.unsupported, 'cannot rename');
    files.remove(docUri);
    final uri = 'doc${_next++}';
    files[uri] = name;
    return uri;
  }
}

void main() {
  late Directory tempDir;
  late FakeFolder folder;
  late SharedPreferencesUtil prefs;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    prefs = SharedPreferencesUtil();
    prefs.folderExportTreeUri = 'tree1';
    prefs.folderExportLabel = 'Omi';
    prefs.folderExportEnabled = true;
    FolderExportIntegration.resetForTest();
    folder = FakeFolder();
    tempDir = Directory.systemTemp.createTempSync('folder_export_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  FolderExportIntegration integration() => FolderExportIntegration(prefs, backend: folder);

  /// A finished recording on disk. [start] is local time, as the recordings list shows it.
  Conversation recording(String key, DateTime start, {bool onDisk = true, String ext = 'wav'}) {
    final file = File('${tempDir.path}/recording_${start.millisecondsSinceEpoch}.$ext');
    if (onDisk) file.writeAsBytesSync(List.filled(1024, 1));
    return Conversation(file: file, startTime: start, duration: const Duration(minutes: 3), uploadKey: key);
  }

  /// The same recording after a re-file: same upload key, new start and file name. [ext]
  /// changes the file's format too, as an M4A conversion between the two would.
  Conversation refiled(Conversation c, DateTime newStart, {String ext = 'wav'}) {
    final moved = c.file.renameSync('${tempDir.path}/recording_${newStart.millisecondsSinceEpoch}.$ext');
    return Conversation(file: moved, startTime: newStart, duration: c.duration, uploadKey: c.uploadKey);
  }

  group('copying', () {
    test('copies under a readable name, in local time, and counts as delivered', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();

      expect(folderExport.hasDelivered(c), false);
      await folderExport.upload(c);

      expect(folder.files.values, ['2026-09-16 14.32.05.wav']);
      expect(folderExport.hasDelivered(c), true);
    });

    test('an M4A recording is copied as .m4a', () async {
      final c = recording('k1.m4a', DateTime(2026, 9, 16, 14, 32, 5), ext: 'm4a');

      await integration().upload(c);

      expect(folder.files.values, ['2026-09-16 14.32.05.m4a']);
      expect(folder.mimeTypes.values, ['audio/mp4']);
    });

    test('a recording still awaiting its M4A conversion is copied as the WAV it is', () async {
      // In M4A mode the upload key already ends .m4a while the file on disk is still WAV.
      final c = recording('recording_1789569125000.m4a', DateTime(2026, 9, 16, 14, 32, 5));

      await integration().upload(c);

      expect(folder.files.values, ['2026-09-16 14.32.05.wav']);
      expect(folder.mimeTypes.values, ['audio/x-wav']);
    });

    test('saving again adds a copy beside the first, and a re-file renames only the newest', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();

      await folderExport.upload(c);
      await folderExport.upload(c);
      expect(folder.files, hasLength(2), reason: 'the first copy is the user\'s; it is not replaced');

      await folderExport.reconcile([refiled(c, DateTime(2026, 9, 16, 9, 41, 7))]);
      expect(folder.files.values, unorderedEquals(['2026-09-16 14.32.05.wav', '2026-09-16 09.41.07.wav']));
    });

    test('a copy in a folder since replaced does not count', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();
      await folderExport.upload(c);

      await folderExport.useFolder(const PickedFolder('tree2', 'Other'));

      expect(folderExport.hasDelivered(c), false, reason: 'the new folder gets its own copy');
      expect(folder.calls, contains('release tree1'));
    });

    test('a copy still being written when the folder changes is not counted in the new one', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();
      folder.copyGate = Completer<void>();

      final copying = folderExport.upload(c);
      await Future.delayed(Duration.zero); // writing into tree1
      final switching = folderExport.useFolder(const PickedFolder('tree2', 'Other'));
      folder.copyGate!.complete();
      await Future.wait([copying, switching]);

      expect(prefs.folderExportTreeUri, 'tree2');
      expect(folderExport.hasDelivered(c), false, reason: 'that copy is in tree1');
    });

    test('choosing the same folder again keeps what was copied', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();
      await folderExport.upload(c);

      await folderExport.useFolder(const PickedFolder('tree1', 'Omi'));

      expect(folderExport.hasDelivered(c), true);
      expect(folder.calls, isNot(contains('release tree1')));
    });

    test('an unreachable folder spends no retry and backs off', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();
      folder.access = false;

      await folderExport.upload(c);

      expect(folderExport.hasDelivered(c), false);
      expect(folderExport.isBackingOff(c), true);
      expect(prefs.getAutoUploadRetries(folderExport.getRetryKey(c)), 0);
    });

    test('a recording deleted before its copy began is skipped without a failure', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5), onDisk: false);
      final folderExport = integration();

      await folderExport.upload(c); // must not throw

      expect(folderExport.hasDelivered(c), false);
      expect(folder.files, isEmpty);
    });

    test('its retry key does not collide with HeyPocket\'s bare upload key', () {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      expect(integration().getRetryKey(c), isNot(HeyPocketPassthroughIntegration(prefs).getRetryKey(c)));
    });
  });

  group('re-files', () {
    test('a re-filed recording\'s copy is renamed to its new time', () async {
      final c = recording('k1', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);

      final moved = refiled(c, DateTime(2026, 9, 16, 9, 41, 7));
      await folderExport.reconcile([moved]);

      expect(folder.files.values, ['2026-09-16 09.41.07.wav']);
      expect(folderExport.hasDelivered(moved), true);
    });

    test('a copy renamed after its recording was converted to M4A keeps the format it holds', () async {
      // Copied while still WAV; the next run converts the recording, then corrects its date.
      final c = recording('k1.m4a', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);

      final moved = refiled(c, DateTime(2026, 9, 16, 9, 41, 7), ext: 'm4a');
      await folderExport.reconcile([moved]);

      expect(folder.files.values, ['2026-09-16 09.41.07.wav'], reason: 'the copy is still WAV audio');
    });

    test('an unchanged recording is never renamed', () async {
      final c = recording('k1', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);

      await folderExport.reconcile([c]);
      await folderExport.reconcile([c]);

      expect(folder.calls.where((call) => call.startsWith('rename')), isEmpty);
    });

    test('a rename that already happened is not repeated', () async {
      final c = recording('k1', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);
      final moved = refiled(c, DateTime(2026, 9, 16, 9, 41, 7));

      await folderExport.reconcile([moved]);
      await folderExport.reconcile([moved]);

      expect(folder.calls.where((call) => call.startsWith('rename')), hasLength(1));
    });

    test('a copy the user removed from the folder is not put back or renamed again', () async {
      final c = recording('k1', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);
      folder.files.clear(); // removed in a file manager

      final moved = refiled(c, DateTime(2026, 9, 16, 9, 41, 7));
      await folderExport.reconcile([moved]);
      await folderExport.reconcile([refiled(moved, DateTime(2026, 9, 16, 9, 42, 0))]);

      expect(folderExport.hasDelivered(moved), true, reason: 'still delivered, so no sweep copies it again');
      expect(folder.calls.where((call) => call.startsWith('rename')), hasLength(1));
    });

    test('a folder that cannot rename keeps the old name and is not asked again', () async {
      final c = recording('k1', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);
      folder.canRename = false;

      final moved = refiled(c, DateTime(2026, 9, 16, 9, 41, 7));
      await folderExport.reconcile([moved]);
      await folderExport.reconcile([moved]);

      expect(folder.calls.where((call) => call.startsWith('rename')), hasLength(1),
          reason: 'it would fail the same way on every sweep');
      expect(folder.files.values, ['2026-09-15 03.00.00.wav']);
      expect(folderExport.hasDelivered(moved), true);

      // A later re-file is still tried once, and still not repeated.
      await folderExport.reconcile([refiled(moved, DateTime(2026, 9, 16, 9, 42, 0))]);
      expect(folder.calls.where((call) => call.startsWith('rename')), hasLength(2));
    });

    test('an unreachable folder leaves the rename for the next sweep', () async {
      final c = recording('k1', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);
      final moved = refiled(c, DateTime(2026, 9, 16, 9, 41, 7));

      folder.access = false;
      await folderExport.reconcile([moved]);
      folder.access = true;
      await folderExport.reconcile([moved]);

      expect(folder.files.values, ['2026-09-16 09.41.07.wav']);
    });
  });

  group('deletes', () {
    test('deleting a recording leaves its copy; the app only forgets it', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();
      await folderExport.upload(c);

      c.file.deleteSync();
      folderExport.forgetCopiesOf([c]);

      expect(folder.files.values, ['2026-09-16 14.32.05.wav']);
      expect(folderExport.hasDelivered(c), false);
      expect(prefs.folderExportLedger, isEmpty);
    });

    test('forgetting one recording keeps the rest', () async {
      final a = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final b = recording('k2', DateTime(2026, 9, 16, 15, 0, 0));
      final folderExport = integration();
      await folderExport.upload(a);
      await folderExport.upload(b);

      folderExport.forgetCopiesOf([a]);

      expect(folderExport.hasDelivered(a), false);
      expect(folderExport.hasDelivered(b), true);
    });

    test('a rename in flight when its recording is deleted does not bring it back', () async {
      final c = recording('k1', DateTime(2026, 9, 15, 3, 0, 0));
      final folderExport = integration();
      await folderExport.upload(c);
      final moved = refiled(c, DateTime(2026, 9, 16, 9, 41, 7));
      folder.renameGate = Completer<void>();

      final renaming = folderExport.reconcile([moved]);
      await Future.delayed(Duration.zero); // waiting on the folder
      folderExport.forgetCopiesOf([moved]);
      folder.renameGate!.complete();
      await renaming;

      expect(prefs.folderExportLedger, isEmpty);
    });

    test('removing the folder gives access back and forgets every copy, deleting none', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();
      await folderExport.upload(c);

      await folderExport.removeFolder();

      expect(folder.calls, contains('release tree1'));
      expect(folder.files, isNotEmpty, reason: 'copies stay in the folder');
      expect(prefs.folderExportLedger, isEmpty);
      expect(folderExport.isConfigured, false);
    });
  });

  group('through the upload manager', () {
    IntegrationUploadManager manager(FolderExportIntegration folderExport, List<Batch> batches) =>
        IntegrationUploadManager(
          integrations: [folderExport],
          prefs: prefs,
          batchesProvider: () => batches,
          isDisposed: () => false,
          isPipelineIdle: () => true,
          isProcessing: () => false,
          notifyUi: () {},
          acquireWake: (_) {},
          releaseWake: (_) {},
          showUploadNotification: (_) {},
          settleNotification: () {},
          setPendingSnack: (_) {},
          checkOnWifi: () async => false,
          convertToPassthrough: (_) async {},
        );

    Batch batchOf(List<Conversation> finished) => Batch(
          dateString: '2026-09-16',
          date: DateTime(2026, 9, 16),
          rawSegments: const [],
          draftRecordings: const [],
          finalizedRecordings: finished,
        );

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }

    test('auto-save copies a new recording, off wifi, with "Upload on Wifi Only" on', () async {
      prefs.uploadOnWifiOnly = true;
      prefs.folderExportAutoUpload = true; // stamps the cutoff: now
      final c = recording('k1', DateTime.now().add(const Duration(minutes: 1)));
      final folderExport = integration();
      final m = manager(folderExport, [
        batchOf([c])
      ]);

      m.tryAutoUploadAll();
      await until(() => folderExport.hasDelivered(c));

      expect(folderExport.hasDelivered(c), true);
      expect(m.integrationStatuses(c).single.local, true);
    });

    test('an unreachable folder pauses the lane; the recording stays queued, not failed', () async {
      final c = recording('k1', DateTime(2026, 9, 16, 14, 32, 5));
      final folderExport = integration();
      final m = manager(folderExport, [
        batchOf([c])
      ]);
      folder.access = false;

      await m.uploadOne(c, FolderExportIntegration.integrationName);
      await until(() => folderExport.isBackingOff(c) && !m.hasInFlightUpload);

      expect(m.integrationStatuses(c).single.state, IntegrationUploadState.queued,
          reason: 'kept in the lane for when the folder is back');
      expect(prefs.getAutoUploadRetries(folderExport.getRetryKey(c)), 0);
      expect(folder.calls, ['copy 2026-09-16 14.32.05.wav'], reason: 'tried once, then waits out the backoff');
    });
  });
}
