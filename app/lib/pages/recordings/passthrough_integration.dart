import 'dart:async';
import 'dart:io';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/omi_api_client.dart';
import 'package:omi/utils/logger.dart';

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
  Future<void> upload(Conversation c, {void Function()? onProgress});
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

  static List<PassthroughIntegration> getIntegrations(SharedPreferencesUtil prefs) => [
        HeyPocketPassthroughIntegration(prefs),
        OmiPassthroughIntegration(prefs),
        // Add new integrations here.
      ];

  static bool hasAnyConfigured(SharedPreferencesUtil prefs) {
    final integrations = getIntegrations(prefs);
    for (final i in integrations) {
      if (i.isConfigured) return true;
    }
    return false;
  }

  static String getBinPath(Conversation c) {
    final ts = c.file.path.split('/').last.split('_').last.split('.').first;
    return '${c.file.parent.path}/recording_fs320_$ts.bin';
  }
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
  Future<void> upload(Conversation c, {void Function()? onProgress}) async {
    // HeyPocket uploads the recording in a single request — no chunk progress.
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
  Future<void> upload(Conversation c, {void Function()? onProgress}) async {
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
        final segmentKey = '$binPath#$i';
        if (_prefs.isOmiSegmentSynced(segmentKey)) continue;

        final existingJobId = _prefs.getOmiSegmentJobId(segmentKey);
        final outcome = await OmiApiClient.syncSegment(segments[i], existingJobId: existingJobId);

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
