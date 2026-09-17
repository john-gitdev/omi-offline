import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/folder_export_service.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/omi_api_client.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

abstract class PassthroughIntegration {
  String get name;

  /// Eligible for *auto*-upload of [c]: configured, the Enabled toggle on, and
  /// [c] recorded after the auto-upload time cutoff. Used only by the
  /// background auto-upload sweep.
  bool isEnabled(Conversation c);

  /// Available for a *manual* (explicit user-tap) upload of [c]: configured, the
  /// Enabled toggle on, and the source data this integration uploads actually
  /// exists for [c] — but WITHOUT the auto-upload time cutoff that [isEnabled]
  /// applies (an explicit upload works on recordings made before auto-upload was
  /// switched on). Source requirements are integration-specific: HeyPocket needs
  /// the recording's audio file; Omi needs the processing-time .bin (only created
  /// while Omi sync is enabled, so pre-enable recordings are never available).
  /// Drives both the manual upload action and the upload-status icon; when no
  /// integration is available for a recording it shows as unavailable.
  bool isAvailableFor(Conversation c);

  bool get isConfigured;
  bool get isAutoUploadEnabled;
  bool hasDelivered(Conversation c);

  /// Uploads [c]. [onProgress] (if given) is invoked after each unit of upload
  /// progress so the UI can refresh — used by chunked integrations to update the
  /// "delivered/total chunks" count live as each segment lands.
  ///
  /// [isCancelled] (if given) is polled at safe checkpoints; when it returns true
  /// the upload bails early without delivering and without throwing — the user
  /// disabled the integration or its auto-upload mid-flight. A chunked integration
  /// stops between chunks (and between server polls); a single-shot one can only
  /// bail before its request begins.
  Future<void> upload(Conversation c, {void Function()? onProgress, bool Function()? isCancelled});
  bool isFailed(Conversation c);

  /// Upload progress in serially-uploaded chunks, for integrations that split a
  /// recording into multiple segments (Omi Cloud). Returns `(delivered, total)`,
  /// or null when this integration uploads in a single shot or the recording is
  /// ≤1 chunk (nothing meaningful to show).
  (int delivered, int total)? segmentProgress(Conversation c);

  /// Whether an auto-upload of [c] should be skipped for now because the server
  /// asked us to back off (a recent 503/overload). Manual uploads ignore this.
  /// Always false for integrations without server-driven backoff.
  bool isBackingOff(Conversation c);

  /// When the current server-driven backoff for [c] elapses, or null if [c] is
  /// not backing off. Lets the upload worker pause its lane until the real
  /// (exponential) backoff passes rather than a fixed window. Null for
  /// integrations without server-driven backoff.
  DateTime? backingOffUntil(Conversation c);

  /// Maximum number of concurrent auto-uploads allowed for this service.
  int get concurrencyLimit;

  /// The unique key used to track retry counts for this integration.
  String getRetryKey(Conversation c);

  /// False for an integration that never leaves the phone. "Upload on Wifi Only" holds
  /// back only the ones that send something over the network.
  bool get requiresNetwork;

  /// Brings what this integration has already delivered in line with [recordings] — the
  /// finished recordings as the auto-upload sweep sees them, i.e. after any re-file. Run
  /// by every sweep that is not held back, whether or not auto-upload is on. Never throws.
  Future<void> reconcile(List<Conversation> recordings);

  static List<PassthroughIntegration> getIntegrations(SharedPreferencesUtil prefs) => [
        HeyPocketPassthroughIntegration(prefs),
        OmiPassthroughIntegration(prefs),
        FolderExportIntegration(prefs),
        // Add new integrations here.
      ];

  static bool hasAnyConfigured(SharedPreferencesUtil prefs) {
    final integrations = getIntegrations(prefs);
    for (final i in integrations) {
      if (i.isConfigured) return true;
    }
    return false;
  }

  /// One definition with the writer that renames it (RecordingsManager.omiBinPathFor):
  /// Omi's upload state is keyed by this path, so reader and writer must agree exactly.
  static String getBinPath(Conversation c) => RecordingsManager.omiBinPathFor(c.file);
}

class HeyPocketPassthroughIntegration implements PassthroughIntegration {
  final SharedPreferencesUtil _prefs;
  HeyPocketPassthroughIntegration(this._prefs);

  @override
  String get name => 'HeyPocket';

  @override
  int get concurrencyLimit => 3;

  @override
  String getRetryKey(Conversation c) => c.uploadKey!;

  @override
  bool get requiresNetwork => true;

  // Keyed by the .meta upload key, which a re-file does not change: nothing to keep up.
  @override
  Future<void> reconcile(List<Conversation> recordings) async {}

  @override
  bool isEnabled(Conversation c) {
    if (!_prefs.heypocketEnabled || !isConfigured || c.uploadKey == null) return false;
    final enabledAt = _prefs.heypocketKeySetAt;
    // Fail closed: with no recorded auto-upload-enabled time we never auto-upload
    // (manual upload via isAvailableFor still works). A zero/legacy timestamp must
    // not sweep up recordings made before the Auto-Upload toggle was switched on.
    if (enabledAt <= 0) return false;
    if (c.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(enabledAt))) return false;
    return true;
  }

  // HeyPocket uploads the recording's audio file (wav/m4a/ogg), so any recording
  // whose audio still exists can be uploaded manually — independent of when
  // auto-upload was enabled.
  @override
  bool isAvailableFor(Conversation c) => isConfigured && c.uploadKey != null && c.file.existsSync();

  @override
  bool get isConfigured => _prefs.heypocketEnabled && _prefs.heypocketApiKey.isNotEmpty;

  @override
  bool get isAutoUploadEnabled => _prefs.heypocketAutoUpload;

  @override
  bool hasDelivered(Conversation c) => c.uploadKey != null && _prefs.isUploadedToHeypocket(c.uploadKey!);

  @override
  bool isFailed(Conversation c) => _prefs.getAutoUploadRetries(c.uploadKey!) >= 3;

  @override
  Future<void> upload(Conversation c, {void Function()? onProgress, bool Function()? isCancelled}) async {
    // HeyPocket uploads the recording in a single request — no chunk progress and
    // no mid-flight cancellation point, so we can only bail before it starts.
    if (isCancelled?.call() ?? false) return;
    final uploadKey = c.uploadKey!;
    try {
      await HeyPocketService.uploadRecording(_prefs.heypocketApiKey, c);
      await _prefs.markUploadedToHeypocket(uploadKey);
      await _prefs.clearAutoUploadRetry(uploadKey);
    } catch (e) {
      if (e is HeyPocketException && e.statusCode == 401) {
        _prefs.heypocketEnabled = false;
      }
      rethrow;
    }
  }

  @override
  (int, int)? segmentProgress(Conversation c) => null;

  @override
  bool isBackingOff(Conversation c) => false;

  @override
  DateTime? backingOffUntil(Conversation c) => null;
}

class OmiPassthroughIntegration implements PassthroughIntegration {
  final SharedPreferencesUtil _prefs;
  OmiPassthroughIntegration(this._prefs);

  @override
  String get name => 'Omi Cloud';

  @override
  int get concurrencyLimit => 1;

  @override
  String getRetryKey(Conversation c) => PassthroughIntegration.getBinPath(c);

  @override
  bool get requiresNetwork => true;

  // Its path-keyed state is moved by the re-file itself (promoteSessionToDate).
  @override
  Future<void> reconcile(List<Conversation> recordings) async {}

  @override
  bool isEnabled(Conversation c) {
    if (!_prefs.omiEnabled || !isConfigured) return false;
    final enabledAt = _prefs.omiAutoUploadAt;
    // Fail closed when no auto-upload-enabled time is recorded (see HeyPocket.isEnabled).
    if (enabledAt <= 0) return false;
    if (c.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(enabledAt))) return false;
    return true;
  }

  // Omi can only upload the processing-time fs320 .bin, which is written solely
  // while Omi sync is enabled. Recordings processed before then have no bin and
  // cannot be uploaded at all — manual or otherwise — so they are not available.
  @override
  bool isAvailableFor(Conversation c) => isConfigured && File(PassthroughIntegration.getBinPath(c)).existsSync();

  @override
  bool get isConfigured => _prefs.omiEnabled && _prefs.omiRefreshToken.isNotEmpty;

  @override
  bool get isAutoUploadEnabled => _prefs.omiAutoUpload;

  @override
  bool hasDelivered(Conversation c) {
    return _prefs.isOmiSynced(PassthroughIntegration.getBinPath(c));
  }

  @override
  bool isFailed(Conversation c) {
    return _prefs.getAutoUploadRetries(PassthroughIntegration.getBinPath(c)) >= 3;
  }

  /// Exponential backoff after the server reports it's busy/overloaded (a 503, or
  /// a 502/504 gateway timeout): 5m, 10m, 20m, 40m, capped at 60m, indexed by the
  /// consecutive-busy streak. A backend that's down for a while is polled
  /// progressively less often instead of every 5 min — and never given up on (the
  /// 3-strike give-up budget is reserved for genuine content/4xx failures). The
  /// next auto-upload sweep after the window elapses picks the recording back up.
  static const Duration _busyBackoffBase = Duration(minutes: 5);
  static const Duration _busyBackoffCap = Duration(minutes: 60);

  static Duration _busyBackoffFor(int streak) {
    // streak is 1 on the first busy: base, then doubling each consecutive busy.
    final shift = (streak - 1).clamp(0, 30);
    final ms = _busyBackoffBase.inMilliseconds << shift;
    final capMs = _busyBackoffCap.inMilliseconds;
    return Duration(milliseconds: (ms < 0 || ms > capMs) ? capMs : ms);
  }

  @override
  (int, int)? segmentProgress(Conversation c) {
    final binPath = PassthroughIntegration.getBinPath(c);
    final total = _prefs.getOmiSegmentTotal(binPath);
    if (total <= 1) return null; // single chunk: no per-chunk progress worth showing
    return (_prefs.omiSyncedSegmentCount(binPath), total);
  }

  @override
  bool isBackingOff(Conversation c) => backingOffUntil(c) != null;

  @override
  DateTime? backingOffUntil(Conversation c) {
    final until = _prefs.getOmiBackoffUntil(PassthroughIntegration.getBinPath(c));
    if (until <= DateTime.now().millisecondsSinceEpoch) return null;
    return DateTime.fromMillisecondsSinceEpoch(until);
  }

  @override
  Future<void> upload(Conversation c, {void Function()? onProgress, bool Function()? isCancelled}) async {
    final binPath = PassthroughIntegration.getBinPath(c);
    final binFile = File(binPath);
    if (!binFile.existsSync()) {
      throw Exception('no Omi upload file for this recording — it was processed before Omi sync was enabled');
    }

    final segments = await OmiApiClient.buildSegments(binFile);
    if (segments.isEmpty) throw Exception('Omi upload found no audio to send');
    // Record the chunk count so the UI can show "delivered/total" — kept across a
    // partial failure so a failed-midway upload reports how far it got.
    await _prefs.setOmiSegmentTotal(binPath, segments.length);
    onProgress?.call();

    // Upload one segment per request, serialized: the server runs a single Parakeet
    // transcription per job, and firing several in parallel 503s the STT backend.
    // Each delivered segment is recorded so a retry resumes from the first
    // undelivered chunk. A chunk whose job is still running (or whose poll budget
    // elapsed) stops the run as `pending` — NOT a failure: its job id is kept so
    // the next attempt reattaches and polls the same job rather than re-uploading
    // and adding a duplicate to the server's queue. Only a server `failed` verdict
    // re-uploads.
    OmiSyncResult? lastResult;
    try {
      for (var i = 0; i < segments.length; i++) {
        // Bail before starting (or re-attaching) the next chunk if the user
        // disabled the integration / its auto-upload mid-run. Already-delivered
        // chunks stay synced; the rest resume on a later run if re-enabled.
        if (isCancelled?.call() ?? false) return;
        final segmentKey = '$binPath#$i';
        if (_prefs.isOmiSegmentSynced(segmentKey)) continue;

        final existingJobId = _prefs.getOmiSegmentJobId(segmentKey);
        final outcome =
            await OmiApiClient.syncSegment(segments[i], existingJobId: existingJobId, isCancelled: isCancelled);

        switch (outcome.status) {
          case OmiJobStatus.completed:
            await _prefs.markOmiSegmentSynced(segmentKey);
            await _prefs.clearOmiSegmentJobId(segmentKey);
            await _prefs.clearOmiBusyStreak(binPath); // backend healthy again — reset backoff
            onProgress?.call();
            lastResult = outcome.result;
          case OmiJobStatus.pending:
            // Server still has the job in flight. Persist its id and stop without
            // failing — the recording stays "pending" and a later run reattaches.
            // Clear the up-front attempt marker so it reads pending, not failed.
            if (outcome.jobId != null) await _prefs.setOmiSegmentJobId(segmentKey, outcome.jobId!);
            await _prefs.clearAutoUploadRetry(binPath);
            return;
          case OmiJobStatus.busy:
            // Server overloaded or its gateway timed out (a 503, or a 502/504).
            // The chunk's job (if any) is dead, so drop its id and re-upload later
            // — but not now: set an exponential backoff (escalating with each
            // consecutive busy) so auto-upload leaves a struggling backend alone
            // for progressively longer. Not a failure; don't spend the give-up
            // budget, and clear the up-front failure marker.
            await _prefs.clearOmiSegmentJobId(segmentKey);
            await _prefs.clearAutoUploadRetry(binPath);
            await _prefs.incrementOmiBusyStreak(binPath);
            final streak = _prefs.getOmiBusyStreak(binPath);
            final backoff = _busyBackoffFor(streak);
            await _prefs.setOmiBackoffUntil(binPath, DateTime.now().add(backoff).millisecondsSinceEpoch);
            Logger.debug('Omi Cloud: server busy on segment ${i + 1}/${segments.length}; '
                'backing off ${backoff.inMinutes}m (streak $streak)');
            return;
          case OmiJobStatus.failed:
          case OmiJobStatus.gone:
            // Real server verdict — drop the stale job id so the retry re-uploads.
            await _prefs.clearOmiSegmentJobId(segmentKey);
            final detail = outcome.error ?? 'unknown error';
            throw Exception('Omi upload failed on segment ${i + 1}/${segments.length}: $detail');
        }
      }
    } catch (e) {
      if (e is OmiSyncException && e.isAuthError) {
        _prefs.omiEnabled = false;
      }
      rethrow;
    }

    // Every segment delivered — promote to a fully-synced recording and prune the
    // now-redundant per-segment markers (and any leftover job ids).
    await _prefs.markOmiSynced(binPath);
    await _prefs.clearOmiSegments(binPath);
    await _prefs.clearAutoUploadRetry(binPath);
    if (lastResult != null) unawaited(OmiApiClient.traceSyncResult(lastResult));
  }
}

/// One copy Save to Folder made, in the current folder: where it went, what it was named,
/// and the recording start it was named for — which is what
/// [FolderExportIntegration.reconcile] compares, so a time-zone change on its own never
/// renames anything. No folder is recorded: changing or removing the folder clears the
/// ledger, under the same lock every copy holds, so no entry outlives its folder.
class _FolderCopy {
  final String uri;
  final String name;
  final int startMs;

  /// The user removed the copy from the folder. It still counts as delivered, so it is not
  /// put back; "Save again" makes a new one.
  final bool gone;

  const _FolderCopy({
    required this.uri,
    required this.name,
    required this.startMs,
    this.gone = false,
  });

  Map<String, Object> toJson() => {'uri': uri, 'name': name, 'startMs': startMs, if (gone) 'gone': true};

  static _FolderCopy? fromJson(Object? json) {
    if (json is! Map) return null;
    final uri = json['uri'], name = json['name'], startMs = json['startMs'];
    if (uri is! String || name is! String || startMs is! int) return null;
    return _FolderCopy(uri: uri, name: name, startMs: startMs, gone: json['gone'] == true);
  }
}

/// Save to Folder: copies each finished recording's audio into a folder the user picked,
/// named for when it was recorded — `2026-09-16 14.32.05.m4a`. Nothing leaves the phone,
/// so "Upload on Wifi Only" does not apply.
///
/// A copy follows its recording:
/// - **Re-files.** When the app corrects a recording's start, [reconcile] renames the copy
///   on the next sweep. Pulled, not pushed: what was copied is keyed by the `.meta` upload
///   key, which a re-file does not change, so nothing has to hook the rename, and one missed
///   while the app was killed is picked up the next time.
/// - **Deletes the user makes** ([deleteCopiesOf], called from the delete actions only).
///   Retention, passthrough and a stitch also remove audio from the phone, and none of them
///   touches the folder: a folder that outlives the app's own retention is much of the point.
///
/// Residual: a finished recording a later stitch absorbs keeps its copy, and the merged
/// recording is copied under its own name, so that audio is in the folder twice — the same
/// duplicate the other integrations accept.
class FolderExportIntegration implements PassthroughIntegration {
  FolderExportIntegration(this._prefs, {FolderExportBackend? backend}) : _backend = backend ?? defaultBackend;

  final SharedPreferencesUtil _prefs;
  final FolderExportBackend _backend;

  static const integrationName = 'Folder';

  static FolderExportBackend defaultBackend = ChannelFolderExportBackend();

  /// Every folder operation, one at a time, across instances — the controller's and the
  /// player page's. A delete has to wait for a copy of the same recording that is still
  /// being written, and a rename must never run against a copy being replaced.
  static Mutex _lock = Mutex();

  /// Set when the folder cannot be reached at all. The lane pauses until then, rather than
  /// spending every recording's retries on something that is not their fault.
  static DateTime? _unavailableUntil;
  static const _unavailableRetry = Duration(minutes: 5);

  @visibleForTesting
  static void resetForTest() {
    _lock = Mutex();
    _unavailableUntil = null;
  }

  @override
  String get name => integrationName;

  @override
  int get concurrencyLimit => 1;

  @override
  bool get requiresNetwork => false;

  // Prefixed: HeyPocket's retry key is the bare upload key.
  @override
  String getRetryKey(Conversation c) => 'folder_${c.uploadKey ?? c.file.path}';

  @override
  bool get isConfigured => _prefs.folderExportEnabled && _prefs.folderExportTreeUri.isNotEmpty;

  @override
  bool get isAutoUploadEnabled => _prefs.folderExportAutoUpload;

  @override
  bool isEnabled(Conversation c) {
    if (!isConfigured || c.uploadKey == null) return false;
    final enabledAt = _prefs.folderExportAutoUploadAt;
    // Fail closed when no auto-save time is recorded (see HeyPocket.isEnabled).
    if (enabledAt <= 0) return false;
    return !c.startTime.isBefore(DateTime.fromMillisecondsSinceEpoch(enabledAt));
  }

  @override
  bool isAvailableFor(Conversation c) => isConfigured && c.uploadKey != null && c.file.existsSync();

  @override
  bool hasDelivered(Conversation c) => c.uploadKey != null && _readLedger().containsKey(c.uploadKey);

  @override
  bool isFailed(Conversation c) => _prefs.getAutoUploadRetries(getRetryKey(c)) >= 3;

  @override
  (int, int)? segmentProgress(Conversation c) => null;

  @override
  bool isBackingOff(Conversation c) => backingOffUntil(c) != null;

  @override
  DateTime? backingOffUntil(Conversation c) {
    final until = _unavailableUntil;
    return until != null && until.isAfter(DateTime.now()) ? until : null;
  }

  /// Appended to a delete confirmation, so the user knows the folder copies go too.
  static String deleteNotice(SharedPreferencesUtil prefs) {
    if (prefs.folderExportTreeUri.isEmpty) return '';
    final label = prefs.folderExportLabel;
    return ' Copies saved to ${label.isEmpty ? 'your export folder' : '"$label"'} are deleted too.';
  }

  /// `2026-09-16 14.32.05.m4a`, in local time. Dots, not colons: SD cards, and most
  /// computers the folder is later copied to, reject a colon in a name.
  static String exportNameFor(Conversation c) {
    final t = c.startTime.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final ext = c.file.path.split('.').last;
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}.${two(t.second)}.$ext';
  }

  static String _mimeTypeFor(Conversation c) => switch (c.file.path.split('.').last.toLowerCase()) {
        'm4a' => 'audio/mp4',
        'wav' => 'audio/x-wav',
        'ogg' => 'audio/ogg',
        _ => 'application/octet-stream',
      };

  Map<String, _FolderCopy> _readLedger() {
    final raw = _prefs.folderExportLedger;
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final ledger = <String, _FolderCopy>{};
      for (final e in decoded.entries) {
        final copy = _FolderCopy.fromJson(e.value);
        if (copy != null) ledger[e.key] = copy;
      }
      return ledger;
    } catch (e) {
      Logger.error('Save to Folder: unreadable copy ledger ($e) — treating nothing as copied');
      return {};
    }
  }

  void _writeLedger(Map<String, _FolderCopy> ledger) => _prefs.folderExportLedger =
      ledger.isEmpty ? '' : jsonEncode({for (final e in ledger.entries) e.key: e.value.toJson()});

  @override
  Future<void> upload(Conversation c, {void Function()? onProgress, bool Function()? isCancelled}) async {
    if (isCancelled?.call() ?? false) return;
    final key = c.uploadKey;
    if (key == null) throw Exception('this recording has no upload key');
    await _lock.acquire();
    try {
      if (isCancelled?.call() ?? false) return; // cancelled while waiting its turn
      final tree = _prefs.folderExportTreeUri;
      if (tree.isEmpty) throw Exception('no folder chosen');
      final previous = _readLedger()[key];
      final name = exportNameFor(c);
      final String uri;
      try {
        uri = await _backend.copyInto(tree, c.file.path, name, _mimeTypeFor(c),
            replaceUri: previous != null && !previous.gone ? previous.uri : null);
      } on FolderExportException catch (e) {
        switch (e.kind) {
          case FolderExportError.noAccess:
            // Neither delivered nor failed: the manager reads the backoff and pauses the
            // lane, and the recording is tried again once it lifts.
            _unavailableUntil = DateTime.now().add(_unavailableRetry);
            await _prefs.clearAutoUploadRetry(getRetryKey(c));
            Logger.debug('Save to Folder: folder unreachable ($e) — retrying in ${_unavailableRetry.inMinutes}m');
            return;
          case FolderExportError.sourceGone:
            // Deleted, or folded into another recording, since it was queued.
            await _prefs.clearAutoUploadRetry(getRetryKey(c));
            return;
          default:
            rethrow;
        }
      }
      _unavailableUntil = null;
      final ledger = _readLedger();
      ledger[key] = _FolderCopy(uri: uri, name: name, startMs: c.startTime.millisecondsSinceEpoch);
      _writeLedger(ledger);
      await _prefs.clearAutoUploadRetry(getRetryKey(c));
      onProgress?.call();
    } finally {
      // A delete of this recording that arrived mid-copy is queued behind this lock, and
      // finds the copy just recorded.
      _lock.release();
    }
  }

  @override
  Future<void> reconcile(List<Conversation> recordings) async {
    if (_prefs.folderExportTreeUri.isEmpty) return;
    await _lock.acquire();
    try {
      final tree = _prefs.folderExportTreeUri;
      await _drainPendingDeletesHeld(tree);
      final ledger = _readLedger();
      for (final c in recordings) {
        final key = c.uploadKey;
        final copy = key == null ? null : ledger[key];
        if (key == null || copy == null || copy.gone) continue;
        final startMs = c.startTime.millisecondsSinceEpoch;
        if (copy.startMs == startMs) continue;
        final name = exportNameFor(c);
        try {
          final uri = await _backend.rename(tree, copy.uri, name);
          ledger[key] = _FolderCopy(uri: uri, name: name, startMs: startMs);
        } on FolderExportException catch (e) {
          if (e.kind == FolderExportError.noAccess) break; // the next sweep tries again
          if (e.kind != FolderExportError.gone) {
            Logger.error('Save to Folder: could not rename ${copy.name} to $name: $e');
            continue;
          }
          ledger[key] = _FolderCopy(uri: copy.uri, name: name, startMs: startMs, gone: true);
        }
        _writeLedger(ledger);
      }
    } catch (e) {
      Logger.error('Save to Folder: reconcile failed: $e');
    } finally {
      _lock.release();
    }
  }

  /// Deletes the folder copies of [conversations], which the user has just deleted in the
  /// app. Call it once they are gone from the phone, so a copy still queued finds nothing to
  /// copy.
  ///
  /// The recordings are marked before the first await, and the marks are persisted: a copy
  /// still being written is deleted as soon as it finishes, and a delete the folder refuses
  /// — an SD card that is not mounted — is retried by every later sweep.
  Future<void> deleteCopiesOf(Iterable<Conversation> conversations) async {
    if (_prefs.folderExportTreeUri.isEmpty) return;
    final keys = conversations.map((c) => c.uploadKey).whereType<String>();
    if (keys.isEmpty) return;
    _prefs.folderExportPendingDeletes = {..._prefs.folderExportPendingDeletes, ...keys}.toList();
    await _drainPendingDeletes();
  }

  Future<void> _drainPendingDeletes() async {
    await _lock.acquire();
    try {
      await _drainPendingDeletesHeld(_prefs.folderExportTreeUri);
    } catch (e) {
      Logger.error('Save to Folder: deleting copies failed: $e');
    } finally {
      _lock.release();
    }
  }

  /// Holding [_lock], so no copy is mid-write: a marked recording with no copy recorded
  /// never had one, and its mark can go.
  Future<void> _drainPendingDeletesHeld(String tree) async {
    final pending = _prefs.folderExportPendingDeletes;
    if (pending.isEmpty) return;
    final ledger = _readLedger();
    final kept = <String>[];
    var unreachable = false;
    for (final key in pending) {
      final copy = ledger[key];
      if (copy == null) continue;
      if (!copy.gone) {
        if (unreachable) {
          kept.add(key);
          continue;
        }
        try {
          await _backend.delete(tree, copy.uri);
        } on FolderExportException catch (e) {
          kept.add(key);
          if (e.kind == FolderExportError.noAccess) unreachable = true;
          Logger.error('Save to Folder: could not delete ${copy.name} — will retry: $e');
          continue;
        }
      }
      ledger.remove(key);
    }
    _writeLedger(ledger);
    // Marks added while this ran wait for the next drain.
    final added = _prefs.folderExportPendingDeletes.where((k) => !pending.contains(k));
    _prefs.folderExportPendingDeletes = [...kept, ...added];
  }

  /// Makes [folder] the export folder. A different folder starts fresh: copies already in
  /// the old one stay there, untouched, and access to it is given back. Choosing the same
  /// folder again keeps everything.
  Future<void> useFolder(PickedFolder folder) async {
    await _lock.acquire();
    try {
      final old = _prefs.folderExportTreeUri;
      if (old != folder.treeUri) {
        if (old.isNotEmpty) await _releaseQuietly(old);
        _prefs.folderExportLedger = '';
        _prefs.folderExportPendingDeletes = const [];
        await _prefs.clearAllAutoUploadRetries(keyPrefix: 'folder_');
      }
      _prefs.folderExportTreeUri = folder.treeUri;
      _prefs.folderExportLabel = folder.label;
      _prefs.folderExportEnabled = true;
      _unavailableUntil = null;
    } finally {
      _lock.release();
    }
  }

  /// Forgets the export folder. Copies already in it stay there.
  Future<void> removeFolder() async {
    await _lock.acquire();
    try {
      final old = _prefs.folderExportTreeUri;
      if (old.isNotEmpty) await _releaseQuietly(old);
      _prefs.folderExportTreeUri = '';
      _prefs.folderExportLabel = '';
      _prefs.folderExportEnabled = false;
      _prefs.folderExportLedger = '';
      _prefs.folderExportPendingDeletes = const [];
      await _prefs.clearAllAutoUploadRetries(keyPrefix: 'folder_');
      _unavailableUntil = null;
    } finally {
      _lock.release();
    }
  }

  Future<void> _releaseQuietly(String treeUri) async {
    try {
      await _backend.releaseFolder(treeUri);
    } catch (e) {
      Logger.error('Save to Folder: could not release access to the old folder: $e');
    }
  }
}
