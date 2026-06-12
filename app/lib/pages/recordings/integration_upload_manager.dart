import 'dart:async';

import 'package:omi/backend/preferences.dart';
import 'package:omi/models/integration_upload_types.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/omi_api_client.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/time_utils.dart';

/// One integration's independent upload lane. Lanes drain concurrently (a
/// dedicated [IntegrationUploadManager._pumpLane] future each), but each lane
/// runs its own jobs strictly one at a time — so every integration's server
/// only ever sees a single upload, while a slow/503ing Omi lane never blocks a
/// fast HeyPocket lane. In-memory only (rebuilt by the next sweep after an
/// app-kill).
class _UploadLane {
  final List<UploadJob> manual = [];
  final List<UploadJob> auto = [];

  /// The job whose upload() is currently awaited (null between jobs / paused).
  UploadJob? current;

  /// Re-entrancy guard — true while this lane's drain loop is running.
  bool draining = false;

  /// Completed / failed counts for this run. Held after the lane empties (so its
  /// notification line can read "8/8 done") until *every* lane is idle, then
  /// reset together so the aggregate total doesn't lurch.
  int done = 0;
  int failed = 0;

  /// Server-busy (503) backoff: lane paused until this time, then re-pumped.
  DateTime? busyUntil;

  bool get isEmpty => manual.isEmpty && auto.isEmpty;
  bool get isActive => current != null || !isEmpty;
  bool get isPausedBusy => busyUntil != null && busyUntil!.isAfter(DateTime.now());
}

/// Owns the per-integration upload lanes and the upload-status derivation that
/// used to live inside RecordingsController. All controller-/platform-facing
/// concerns (wakelock, notifications, connectivity, UI notify, passthrough
/// conversion, the current batch list and pipeline-idle state) are injected so
/// this unit is testable without Flutter plugins.
class IntegrationUploadManager {
  IntegrationUploadManager({
    required List<PassthroughIntegration> integrations,
    required SharedPreferencesUtil prefs,
    required List<Batch> Function() batchesProvider,
    required bool Function() isDisposed,
    required bool Function() isPipelineIdle,
    required void Function() notifyUi,
    required void Function(String reason) acquireWake,
    required void Function(String reason) releaseWake,
    required void Function(String text) showUploadNotification,
    required void Function() settleNotification,
    required void Function(String message) setPendingSnack,
    required Future<bool> Function() checkOnWifi,
    required Future<void> Function(Conversation conversation) convertToPassthrough,
  })  : _integrations = integrations,
        _prefs = prefs,
        _batchesProvider = batchesProvider,
        _isDisposed = isDisposed,
        _isPipelineIdle = isPipelineIdle,
        _notifyUi = notifyUi,
        _acquireWake = acquireWake,
        _releaseWake = releaseWake,
        _showUploadNotification = showUploadNotification,
        _settleNotification = settleNotification,
        _setPendingSnack = setPendingSnack,
        _checkOnWifi = checkOnWifi,
        _convertToPassthrough = convertToPassthrough;

  final List<PassthroughIntegration> _integrations;
  final SharedPreferencesUtil _prefs;
  final List<Batch> Function() _batchesProvider;
  final bool Function() _isDisposed;
  final bool Function() _isPipelineIdle;
  final void Function() _notifyUi;
  final void Function(String reason) _acquireWake;
  final void Function(String reason) _releaseWake;
  final void Function(String text) _showUploadNotification;
  final void Function() _settleNotification;
  final void Function(String message) _setPendingSnack;
  final Future<bool> Function() _checkOnWifi;
  final Future<void> Function(Conversation conversation) _convertToPassthrough;

  /// Upload keys of every recording with an upload in flight or queued.
  final Set<String> _syncingKeys = {};

  // Per-integration upload lanes, keyed by integration name. Each drains
  // concurrently but strictly sequentially within itself, so every server sees
  // one-at-a-time while a slow Omi lane can't block a fast HeyPocket lane. In
  // tap order within a lane (manual ahead of auto). In-memory only: on app-kill,
  // auto-eligible jobs self-heal via the next sweep; _syncingKeys gates dedup
  // against the in-flight job.
  final Map<String, _UploadLane> _lanes = {};
  _UploadLane _lane(String name) => _lanes.putIfAbsent(name, () => _UploadLane());
  bool get _anyLaneActive => _lanes.values.any((l) => l.isActive);

  // The Omi Cloud server-busy (503) backoff, mirroring OmiPassthroughIntegration's
  // internal _busyBackoff — used to set a lane's busyUntil for the visible pause.
  static const Duration _busyBackoff = Duration(minutes: 5);

  /// True while at least one lane has an upload in flight (drives the
  /// processing-vs-upload notification arbitration in the controller).
  bool get hasInFlightUpload => _lanes.values.any((l) => l.current != null);

  /// Upload keys of every recording with an upload in flight or queued — drives
  /// the row/player "uploading" spinner. Derived from each lane's in-flight job
  /// plus its queues so it stays in lockstep with the workers.
  Set<String> get uploadingFiles {
    final keys = <String>{};
    void add(Conversation c) {
      final k = c.uploadKey;
      if (k != null) keys.add(k);
    }

    for (final lane in _lanes.values) {
      if (lane.current != null) add(lane.current!.conversation);
      for (final j in lane.manual) {
        add(j.conversation);
      }
      for (final j in lane.auto) {
        add(j.conversation);
      }
    }
    return keys;
  }

  /// Enqueues an upload of [conversation] to [integration] on that integration's
  /// lane, unless it's already in flight or already queued (dedup by
  /// [UploadJob.key]). Manual jobs drain ahead of auto within the lane. Does NOT
  /// start the lane — callers call [pumpAllLanes] after enqueuing a batch.
  void _enqueueUpload(PassthroughIntegration integration, Conversation conversation,
      {bool force = false, bool manual = false}) {
    final key = '${integration.name}_${conversation.file.path}';
    if (_syncingKeys.contains(key)) return; // currently uploading
    final lane = _lane(integration.name);
    if (lane.manual.any((j) => j.key == key) || lane.auto.any((j) => j.key == key)) return; // already queued
    (manual ? lane.manual : lane.auto).add(UploadJob(integration, conversation, force: force, manual: manual));
  }

  /// Drops every *queued* (not in-flight) job for [integrationName] from its lane
  /// and returns how many were removed. Shared by the disable-integration actions
  /// and the per-lane fail-fast path. Dropped jobs stay not-delivered: auto ones
  /// re-enqueue on the next sweep; manual ones revert to "Ready to Upload".
  int _purgeQueuedFor(String integrationName) {
    final lane = _lanes[integrationName];
    if (lane == null) return 0;
    final before = lane.manual.length + lane.auto.length;
    lane.manual.clear();
    lane.auto.clear();
    return before;
  }

  /// Kicks every lane that has work. Used by the auto sweep, the manual upload
  /// entry points, the connectivity listener (wifi returned), and busy resume.
  void pumpAllLanes() {
    for (final name in _lanes.keys.toList()) {
      unawaited(_pumpLane(name));
    }
  }

  /// Holds the wakelock while an upload is actually **in flight** — auto or
  /// manual — so a backgrounded / swiped-away upload still completes; releases it
  /// between jobs and while a lane is merely queued or wifi-parked.
  void _refreshUploadHold() {
    final inFlight = _lanes.values.any((l) => l.current != null);
    if (inFlight) {
      _acquireWake('upload');
    } else {
      _releaseWake('upload');
    }
  }

  /// One integration's sequential upload worker. Drains its manual queue then its
  /// auto queue, one job at a time. Lanes run concurrently (a [_pumpLane] future
  /// each), so a slow/503ing Omi lane never blocks a fast HeyPocket lane; within a
  /// lane it's strictly one-at-a-time, so each server only ever sees one upload.
  /// Re-entrant calls for the same lane are coalesced by [lane.draining]. Parks
  /// (jobs stay queued) when "Upload on Wifi Only" is on and wifi is unavailable,
  /// and pauses on a 503 until the lane's backoff passes.
  Future<void> _pumpLane(String name) async {
    final lane = _lane(name);
    if (_isDisposed() || lane.draining || lane.isPausedBusy) return;
    lane.draining = true;
    try {
      while (!_isDisposed() && !lane.isEmpty) {
        // Wifi gate before committing to a job. Fail closed: if we can't confirm
        // wifi, park rather than upload over cellular. The connectivity listener
        // re-pumps on the next change.
        if (_prefs.uploadOnWifiOnly) {
          try {
            if (!await _checkOnWifi()) break; // parked
          } catch (e) {
            Logger.error('_pumpLane($name): connectivity check failed ($e) — parking lane');
            break;
          }
        }

        final job = lane.manual.isNotEmpty ? lane.manual.removeAt(0) : lane.auto.removeAt(0);
        final integration = job.integration;
        final conversation = job.conversation;
        final retryKey = integration.getRetryKey(conversation);

        // Re-validate at dequeue — state drifts between enqueue and run.
        if (!job.force && integration.hasDelivered(conversation)) continue; // delivered by another path
        if (!job.manual && integration.isBackingOff(conversation)) continue; // auto honors backoff; manual overrides

        lane.current = job;
        _syncingKeys.add(job.key);
        _refreshUploadHold(); // hold the wakelock while this upload is in flight
        // Persist an up-front failure marker so an app-kill mid-upload reads
        // "failed" rather than reverting to "pending". Cleared by upload() on success.
        unawaited(_prefs.setAutoUploadLastFailureAt(retryKey));
        _updateUploadNotification();
        if (!_isDisposed()) _notifyUi();

        bool delivered = false;
        bool busy = false;
        try {
          await integration.upload(conversation, onProgress: _notifyChunkProgress);
          if (integration.hasDelivered(conversation)) {
            delivered = true;
            if (_prefs.passthroughMode) await _convertToPassthrough(conversation);
          } else if (integration.isBackingOff(conversation)) {
            // Server busy (503): pause the whole lane and resume this recording
            // first once the backoff passes. Not a failure — don't spend retries.
            busy = true;
            lane.busyUntil = DateTime.now().add(_busyBackoff);
            (job.manual ? lane.manual : lane.auto).insert(0, job);
            _scheduleLaneResume(name);
          }
          // else: pending (job still running server-side) — neither delivered nor
          // failed; re-derived on the next sweep. Fall through.
        } catch (e) {
          // Only auto jobs spend the retry budget; a manual failure just stamps
          // the timestamp (surfaced as "failed" via _integrationState).
          if (!job.manual) unawaited(_prefs.incrementAutoUploadRetry(retryKey));
          unawaited(_prefs.setAutoUploadLastFailureAt(retryKey));
          lane.failed++;
          if (e is HeyPocketException && e.statusCode == 401) {
            _setPendingSnack('HeyPocket: API key revoked — update it in Integrations');
          } else if (e is OmiSyncException && e.isAuthError) {
            _setPendingSnack('Omi sync: credentials invalid — update them in Integrations');
          } else {
            Logger.error('Upload failed (${integration.name}): $e');
          }
          // Fail fast for this lane: a failure usually means the integration/server
          // is unhealthy, so drop its remaining queued jobs instead of hammering it.
          // Other lanes are untouched. Dropped jobs aren't lost (auto re-enqueues on
          // the next sweep; manual reverts to "Ready to Upload").
          final dropped = _purgeQueuedFor(integration.name);
          if (dropped > 0) {
            Logger.debug('Upload: ${integration.name} failed — dropped $dropped remaining queued job(s)');
          }
        } finally {
          lane.current = null;
          _syncingKeys.remove(job.key);
          if (delivered) lane.done++;
          _refreshUploadHold(); // release the in-flight hold (re-acquired by the next job)
          if (!_isDisposed()) {
            _updateUploadNotification();
            _notifyUi();
          }
        }

        if (busy) break; // lane paused; a timer re-pumps it after the backoff
      }
    } finally {
      lane.draining = false;
    }

    _finalizeIfAllIdle();
  }

  /// Schedules a re-pump of [name]'s lane once its 503 backoff elapses.
  void _scheduleLaneResume(String name) {
    final until = _lanes[name]?.busyUntil;
    if (until == null) return;
    final delay = until.difference(DateTime.now());
    Timer(delay.isNegative ? Duration.zero : delay + const Duration(seconds: 1), () {
      if (!_isDisposed()) unawaited(_pumpLane(name));
    });
  }

  /// Once no lane has work in flight or queued, reset the per-run counters
  /// together (so the aggregate total doesn't lurch as one lane finishes before
  /// another) and settle the notification back to idle.
  void _finalizeIfAllIdle() {
    if (_isDisposed() || _anyLaneActive) return;
    final hadProgress = _lanes.values.any((l) => l.done > 0 || l.failed > 0);
    for (final l in _lanes.values) {
      l.done = 0;
      l.failed = 0;
      l.busyUntil = null;
    }
    if (hadProgress && _isPipelineIdle()) _settleNotification();
  }

  /// Composes and pushes the aggregated upload notification: a one-line summary
  /// (shown collapsed) followed by a per-active-integration line (shown expanded
  /// via the native BigTextStyle). Only while the sync/process pipeline is idle
  /// (it owns the notification when active). Android-only (no-ops on iOS).
  void _updateUploadNotification() {
    if (!_isPipelineIdle()) return;

    int totalDone = 0, total = 0, totalFailed = 0;
    final lines = <String>[];
    for (final entry in _lanes.entries) {
      final lane = entry.value;
      final remaining = lane.manual.length + lane.auto.length + (lane.current != null ? 1 : 0);
      // Skip lanes with nothing to report this run.
      if (remaining == 0 && lane.done == 0 && lane.failed == 0) continue;
      totalDone += lane.done;
      totalFailed += lane.failed;
      total += lane.done + lane.failed + remaining;
      lines.add(_laneNotificationLine(entry.key, lane));
    }
    if (lines.isEmpty) return;

    final failedSuffix = totalFailed > 0 ? ' · $totalFailed failed' : '';
    // First line is the collapsed summary; the per-integration lines expand below.
    final text = (['Uploading $totalDone of $total$failedSuffix', ...lines]).join('\n');
    _showUploadNotification(text);
  }

  /// One integration's status line for the expanded notification.
  String _laneNotificationLine(String name, _UploadLane lane) {
    final delivered = lane.done;
    final laneTotal = lane.done + lane.failed + (lane.current != null ? 1 : 0) + lane.manual.length + lane.auto.length;
    if (lane.isPausedBusy) {
      return '$name — server busy, retry ${fmtHourMin(lane.busyUntil!)} ($delivered/$laneTotal)';
    }
    if (lane.current != null) {
      final prog = lane.current!.integration.segmentProgress(lane.current!.conversation);
      final chunk = prog != null ? ' (chunk ${prog.$1 + 1}/${prog.$2})' : '';
      return '$name — uploading $delivered/$laneTotal$chunk';
    }
    if (lane.isEmpty) {
      return lane.failed > 0
          ? '$name — $delivered/$laneTotal done · ${lane.failed} failed'
          : '$name — $delivered/$laneTotal done';
    }
    return '$name — $delivered/$laneTotal queued';
  }

  /// Producer for the auto-upload sweep: enqueues every auto-eligible recording
  /// (respecting the auto-upload toggle, time cutoff, delivery, server backoff,
  /// and the retry budget), then kicks the single sequential worker. No longer
  /// uploads directly — the worker is the sole consumer.
  void tryAutoUploadAll() {
    final minDuration = _prefs.filterMinDurationSeconds;

    for (final batch in _batchesProvider().reversed) {
      final sortedConversations = [...batch.finalizedRecordings]..sort((a, b) => a.startTime.compareTo(b.startTime));
      for (final conversation in sortedConversations) {
        if (conversation.passthrough) continue;
        if (conversation.duration.inSeconds < minDuration) continue;
        if (conversation.duration == Duration.zero || conversation.fileSizeBytes == 0) continue;

        for (final integration in _integrations) {
          if (!integration.isAutoUploadEnabled || !integration.isEnabled(conversation)) continue;
          if (integration.hasDelivered(conversation)) continue;
          // Server asked us to back off (recent 503) — skip until the window passes.
          if (integration.isBackingOff(conversation)) continue;
          // Retry budget exhausted for this recording.
          if (_prefs.getAutoUploadRetries(integration.getRetryKey(conversation)) >= 3) continue;

          _enqueueUpload(integration, conversation, force: false, manual: false);
        }
      }
    }
    pumpAllLanes();
    if (!_isDisposed()) _notifyUi();
  }

  void cancelPendingOmiUploads() {
    final dropped = _purgeQueuedFor('Omi Cloud');
    final inFlight = _syncingKeys.where((k) => k.startsWith('Omi Cloud_')).length;
    _syncingKeys.removeWhere((k) => k.startsWith('Omi Cloud_'));
    Logger.debug('IntegrationUploadManager: Omi Cloud disabled — dropped $dropped queued, cleared $inFlight in-flight');
    if (!_isDisposed()) _notifyUi();
  }

  void cancelPendingHeyPocketUploads() {
    final dropped = _purgeQueuedFor('HeyPocket');
    Logger.debug(
        'IntegrationUploadManager: HeyPocket disabled — dropped $dropped queued; in-flight will drain and stop');
    if (!_isDisposed()) _notifyUi();
  }

  Future<List<UploadFailure>> uploadConversation(Conversation conversation, {bool force = false}) async {
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) throw Exception('Upload key unavailable');

    // Validate wifi up-front so a manual tap gets instant feedback rather than a
    // job that silently parks. Once enqueued, async upload failures surface via
    // the reactive row state, not a returned failure.
    if (_prefs.uploadOnWifiOnly) {
      if (!await _checkOnWifi()) {
        throw Exception('WiFi required for upload — connect to WiFi or disable "Upload on Wifi Only" in App Settings');
      }
    }

    // Manual upload bypasses the auto-upload time cutoff (isEnabled): an explicit
    // tap should upload even recordings made before auto-upload was switched on.
    // A missing source (e.g. Omi's pruned .bin) is filtered by isAvailableFor.
    var enqueued = 0;
    for (final integration in _integrations) {
      if (!integration.isAvailableFor(conversation)) continue;
      if (!force && integration.hasDelivered(conversation)) continue;
      _enqueueUpload(integration, conversation, force: force, manual: true);
      enqueued++;
    }

    if (enqueued == 0) {
      return [UploadFailure('Integrations', Exception('No integrations enabled for upload'))];
    }
    pumpAllLanes();
    _notifyUi();
    return [];
  }

  /// Passed to [PassthroughIntegration.upload] so each delivered chunk repaints
  /// the integration rows with the new "X/Total chunks" count live.
  void _notifyChunkProgress() {
    if (!_isDisposed()) _notifyUi();
  }

  /// Per-integration upload status for [c] across all *configured* integrations,
  /// for the detail sheet and the row badge. Both the aggregate [uploadStatus]
  /// and [actionableIntegrationCount] derive from this so the row icon, badge,
  /// and sheet never disagree.
  List<IntegrationStatus> integrationStatuses(Conversation c) {
    final result = <IntegrationStatus>[];
    for (final i in _integrations) {
      if (!i.isConfigured) continue;
      final state = _integrationState(i, c);
      DateTime? failedAt;
      if (state == IntegrationUploadState.failed) {
        final ms = _prefs.getAutoUploadLastFailureAt(i.getRetryKey(c));
        if (ms > 0) failedAt = DateTime.fromMillisecondsSinceEpoch(ms);
      }
      final progress = i.segmentProgress(c);
      result.add(IntegrationStatus(
        i.name,
        state,
        failedAt: failedAt,
        deliveredSegments: progress?.$1,
        totalSegments: progress?.$2,
      ));
    }
    return result;
  }

  IntegrationUploadState _integrationState(PassthroughIntegration i, Conversation c) {
    if (i.hasDelivered(c)) return IntegrationUploadState.delivered;
    final key = '${i.name}_${c.file.path}';
    if (_syncingKeys.contains(key)) return IntegrationUploadState.uploading;
    final lane = _lanes[i.name];
    if (lane != null && (lane.manual.any((j) => j.key == key) || lane.auto.any((j) => j.key == key))) {
      return IntegrationUploadState.queued;
    }
    if (!i.isAvailableFor(c)) return IntegrationUploadState.unavailable;

    final retryKey = i.getRetryKey(c);
    // Has any attempt failed? `isFailed` covers the auto retry-budget exhaustion;
    // the timestamp also covers a manual failure (which doesn't touch the retry
    // count). Without this a manual failure would stay stuck on "pending".
    final hasFailed = i.isFailed(c) || _prefs.getAutoUploadLastFailureAt(retryKey) > 0;
    if (!hasFailed) return IntegrationUploadState.pending;

    // Auto-upload retries immediately (no backoff) up to 3 times. While it still
    // has budget for this recording, surface the whole retry window as
    // "Uploading" rather than flickering to failed between the back-to-back
    // attempts. Only once retries are exhausted, or auto-upload won't handle this
    // recording (disabled, before the cutoff, or a manual-only failure), is it a
    // real failure.
    final autoWillRetry = i.isAutoUploadEnabled && i.isEnabled(c) && _prefs.getAutoUploadRetries(retryKey) < 3;
    return autoWillRetry ? IntegrationUploadState.uploading : IntegrationUploadState.failed;
  }

  /// How many applicable integrations still need attention for [c] — i.e. are
  /// `pending` or `failed` (see [IntegrationStatus.isActionable]). Drives the
  /// row badge count: shown only when >= 2, so the number reflects how many
  /// integrations remain to be addressed rather than the total configured.
  int actionableIntegrationCount(Conversation c) => integrationStatuses(c).where((s) => s.isActionable).length;

  UploadStatus uploadStatus(Conversation c) {
    if (!PassthroughIntegration.hasAnyConfigured(_prefs)) return UploadStatus.unavailable;

    // Aggregate the worst state that needs attention. Anything 'unavailable'
    // (an integration that can't take this recording) is ignored; if none
    // apply, the recording is unavailable rather than a red "tap to upload".
    final relevant = integrationStatuses(c).where((s) => s.state != IntegrationUploadState.unavailable).toList();
    if (relevant.isEmpty) return UploadStatus.unavailable;
    if (relevant.every((s) => s.state == IntegrationUploadState.delivered)) return UploadStatus.all;
    if (relevant.any((s) => s.state == IntegrationUploadState.failed)) return UploadStatus.failed;
    if (relevant.any((s) =>
        s.state == IntegrationUploadState.delivered ||
        s.state == IntegrationUploadState.uploading ||
        s.state == IntegrationUploadState.queued)) {
      return UploadStatus.partial; // in progress (delivered/uploading/queued) — don't prompt to act
    }
    return UploadStatus.none; // all pending, nothing delivered yet
  }

  bool isUploaded(Conversation c) => uploadStatus(c) == UploadStatus.all;

  /// Uploads [c] to a single integration by [integrationName] (the per-row
  /// action in the detail sheet). Tracks progress per-integration via
  /// [_syncingKeys] so only that sheet row spins. Returns failures (empty = ok).
  Future<List<UploadFailure>> uploadOne(Conversation c, String integrationName, {bool force = false}) async {
    PassthroughIntegration? integration;
    for (final i in _integrations) {
      if (i.name == integrationName) {
        integration = i;
        break;
      }
    }
    if (integration == null) return [UploadFailure(integrationName, Exception('Unknown integration'))];
    if (!integration.isAvailableFor(c)) {
      return [UploadFailure(integrationName, Exception('not available for this recording'))];
    }
    if (!force && integration.hasDelivered(c)) return [];

    // Validate wifi up-front so a manual tap gets instant feedback; once enqueued,
    // an async failure surfaces via the reactive row state. (Already in flight or
    // queued is a no-op — _enqueueUpload dedups.)
    if (_prefs.uploadOnWifiOnly) {
      try {
        if (!await _checkOnWifi()) {
          return [
            UploadFailure(integration.name,
                Exception('WiFi required — connect to WiFi or disable "Upload on Wifi Only" in App Settings'))
          ];
        }
      } catch (e) {
        return [UploadFailure(integration.name, Exception('Could not verify WiFi connection'))];
      }
    }

    _enqueueUpload(integration, c, force: force, manual: true);
    pumpAllLanes();
    _notifyUi();
    return [];
  }
}
