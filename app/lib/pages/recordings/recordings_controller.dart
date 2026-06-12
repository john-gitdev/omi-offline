import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/omi_api_client.dart';
import 'package:omi/services/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:omi/utils/audio/sync_notification.dart';
import 'package:omi/utils/other/time_utils.dart';

enum UploadStatus { none, partial, all, failed, unavailable }

/// Per-integration upload state for one recording, surfaced in the detail sheet.
enum IntegrationUploadState {
  /// Upload in flight right now.
  uploading,

  /// Confirmed delivered to this integration.
  delivered,

  /// Available but the last attempt failed — either a manual upload failed, or
  /// the auto-upload retry budget is exhausted.
  failed,

  /// Available, not delivered, no upload in flight — actionable.
  pending,

  /// Enqueued for upload, waiting its turn behind the single sequential worker.
  /// Not actionable — it's already on its way.
  queued,

  /// This integration cannot upload this recording at all (e.g. Omi with no
  /// processing-time .bin, or HeyPocket with the audio file gone).
  unavailable,
}

class IntegrationStatus {
  final String name;
  final IntegrationUploadState state;

  /// When [state] is `failed`, the time of the most recent failed attempt (for
  /// the "Last Upload Failed at" label). Null otherwise or if no time recorded.
  final DateTime? failedAt;

  /// For chunked integrations (Omi Cloud), how many segments have been delivered
  /// and the total — drives the "X/Total chunks" label so a partial/failed-midway
  /// upload shows its progress. Null for single-shot integrations or ≤1 chunk.
  final int? deliveredSegments;
  final int? totalSegments;

  const IntegrationStatus(this.name, this.state, {this.failedAt, this.deliveredSegments, this.totalSegments});

  bool get isActionable => state == IntegrationUploadState.pending || state == IntegrationUploadState.failed;
}

class UploadFailure {
  final String integration;
  final Object error;
  UploadFailure(this.integration, this.error);
}

/// One enqueued upload: a specific [conversation] to a specific [integration].
/// Drained one at a time within that integration's lane ([_UploadLane], via
/// [RecordingsController._pumpLane]) so we never fan parallel jobs at a server.
/// [force] re-uploads an already-delivered recording; [manual] jobs (explicit
/// user taps) are drained ahead of auto-sweep jobs and ignore server backoff.
class UploadJob {
  final PassthroughIntegration integration;
  final Conversation conversation;
  final bool force;
  final bool manual;
  UploadJob(this.integration, this.conversation, {this.force = false, this.manual = false});

  /// Matches the `_syncingKeys` registry so in-flight and queued jobs dedup
  /// against each other across every entry point.
  String get key => '${integration.name}_${conversation.file.path}';
}

/// One integration's independent upload lane. Lanes drain concurrently (a
/// dedicated [RecordingsController._pumpLane] future each), but each lane runs
/// its own jobs strictly one at a time — so every integration's server only ever
/// sees a single upload, while a slow/503ing Omi lane never blocks a fast
/// HeyPocket lane. In-memory only (rebuilt by the next sweep after an app-kill).
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

class RecordingsController extends ChangeNotifier implements IWalSyncProgressListener {
  final RecordingsManager _manager = RecordingsManager();
  final _prefs = SharedPreferencesUtil();

  late final List<PassthroughIntegration> _integrations = PassthroughIntegration.getIntegrations(_prefs);

  List<Batch> _batches = [];
  List<Batch> get batches => _batches;

  List<MarkerConversation> _markerConversations = [];
  List<MarkerConversation> get markerConversations => _markerConversations;

  bool _isLoading = true;
  bool get isLoading => _isLoading;

  SyncProcessState _spState = SyncProcessState.idle;
  SyncProcessState get spState => _spState;

  int _syncedCount = 0;
  int get syncedCount => _syncedCount;

  int _totalCount = 0;
  int get totalCount => _totalCount;

  double _minutesRemaining = -1.0;
  double get minutesRemaining => _minutesRemaining;

  double _processingProgress = 0.0;
  double get processingProgress => _processingProgress;

  bool _isTranscoding = false;
  bool get isTranscoding => _isTranscoding;

  double _totalMinutes = 0.0;
  double get totalMinutes => _totalMinutes;

  int _markerCount = 0;
  int get markerCount => _markerCount;

  double _syncSpeed = 0.0;
  double get syncSpeed => _syncSpeed;

  // Raw .bin audio still waiting to be decoded (excludes finalized + discarded
  // bins). The banner shows this as "~N min to process" whenever it's non-zero.
  double _toProcessMinutes = 0.0;
  double get toProcessMinutes => _toProcessMinutes;

  // Duration already folded into open draft recordings. Shown in the banner as
  // "accumulated" only when there is no raw audio left to process.
  double _draftMinutes = 0.0;
  double get draftMinutes => _draftMinutes;

  // Estimated wall-clock end of the open draft, derived from the most recent
  // bin (UTC timerStart + size-estimated duration). Null when there is no draft
  // or no dated bin to anchor it — the banner/dialog then omit the time and just
  // offer to finalize early. Surfaced in the accumulating banner / confirm dialog.
  DateTime? _draftEndTime;
  DateTime? get draftEndTime => _draftEndTime;

  // Count of raw .bin files behind _toProcessMinutes, shown alongside it.
  int _unprocessedBinCount = 0;
  int get unprocessedBinCount => _unprocessedBinCount;

  String _lastCompletedStage = 'none';
  String get lastCompletedStage => _lastCompletedStage;

  String _lastActiveStage = 'syncing';
  String get lastActiveStage => _lastActiveStage;

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

  String _lastHpKey = '';

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

  // Reasons currently holding the CPU wakelock ('pipeline', 'upload'). The
  // wakelock stays enabled while the set is non-empty (or Keep Screen On is on);
  // routing both the sync pipeline and uploads through this keeps them from
  // clobbering each other's hold.
  final Set<String> _wakeReasons = {};

  // Connectivity stream subscription that unparks wifi-gated lanes when wifi
  // returns. Null until init().
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  String? _pendingSnackMessage;
  String? consumePendingSnack() {
    final msg = _pendingSnackMessage;
    _pendingSnackMessage = null;
    return msg;
  }

  Timer? _pollTimer;
  bool _isUserTriggered = false;
  Completer<void>? _pipelineCompleter;

  // Bumped by the stall watchdog when it force-recovers. A pipeline runner
  // parked on a wedged BLE await (rotateAndSync/syncAll/processAll) can outlive
  // the recovery; when it finally unwinds it must NOT run its normal
  // post-await transitions (which would pop a spurious error banner or clobber
  // a freshly-started sync). Each runner snapshots this at entry and bails if
  // it changed across an await.
  int _pipelineGeneration = 0;

  bool _isForcePipeline = false;
  bool get isForcePipeline => _isForcePipeline;

  // When the user cancels mid-sync they pick whether to process what already
  // downloaded (true) or stop everything (false). Disconnects never set this —
  // they always auto-process via the non-`stopping` paths. Read once by the
  // sync runner's stopping branch, reset at the start of each pipeline run.
  bool _processAfterCancel = false;

  bool _forceSyncOnCooldown = false;
  bool get forceSyncOnCooldown => _forceSyncOnCooldown;

  Timer? _forceSyncCooldownTimer;

  static const _kSpState = 'sp_state';
  static const _kSpSyncedCount = 'sp_synced_count';
  static const _kSpTotalCount = 'sp_total_count';
  static const _kSpMinutesRemaining = 'sp_minutes_remaining';
  static const _kSpProcessingProgress = 'sp_processing_progress';
  static const _kSpMarkerCount = 'sp_marker_count';
  static const _kSpLastCompleted = 'sp_last_completed_stage';
  static const _kSpLastActive = 'sp_last_active_stage';

  bool _isDisposed = false;
  bool _pendingProcessingTransition = false;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPollTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Pipeline-stall watchdog. The native BLE layer can leave a sync wedged
  // (e.g. the device stops streaming mid-file in the background and the link
  // dies before any timer fires), which strands the WAL service's isSyncing
  // flag set — so the controller never leaves `syncing`/`stopping` and the
  // banner sticks with no way to re-sync short of force-closing the app. This
  // watchdog force-recovers to idle when no progress has been seen for too
  // long. Anchored on _lastProgressAt, which is bumped on every sync-progress
  // callback (including the per-file fileDone tick that fires after each
  // delete) so a slow delete cycle never false-triggers.
  DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNotificationUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static const _notificationUpdateInterval = Duration(seconds: 5);
  // syncing: per-packet progress fires ~50 Hz during a healthy transfer; the
  // only no-signal windows are list/delete/settle gaps (seconds). 60s of total
  // silence means the transfer is genuinely dead.
  static const _syncingStallTimeout = Duration(seconds: 60);
  // stopping: after a user cancel, teardown should be quick. The underlying
  // BLE awaits are timeout-bounded (≤65s) and acquireStorageLock has its own
  // 10s timeout, so force-clearing here is safe — a re-wedge surfaces as a
  // bounded error on the next sync, not a silent hang.
  static const _stoppingStallTimeout = Duration(seconds: 12);
  // processing: the decode isolate emits heartbeats every 20s while active, but
  // Android can suspend background isolate threads independently of the main
  // thread — leaving polls running with no heartbeats arriving for several
  // minutes. Thermal throttling can also slow per-segment processing 5× (>100s
  // per 3 MB segment). 10 minutes gives ample headroom for both; a genuine
  // native deadlock still gets caught well within a user-visible delay.
  static const _processingStallTimeout = Duration(minutes: 10);

  AppLifecycleState? _lastLifecycleState;

  /// Acquire/release a named hold on the foreground CPU wakelock. The wakelock
  /// stays enabled while any reason is held (or "Keep Screen On" is pinned), so
  /// the sync pipeline and uploads never drop each other's hold.
  void _acquireWake(String reason) {
    _wakeReasons.add(reason);
    WakelockPlus.enable();
  }

  void _releaseWake(String reason) {
    _wakeReasons.remove(reason);
    if (_wakeReasons.isEmpty && !_prefs.keepScreenOn) WakelockPlus.disable();
  }

  /// Releases the sync pipeline's wakelock hold. Kept under its original name for
  /// the existing call sites; honors "Keep Screen On" and any other holder (e.g.
  /// an in-flight upload) via [_releaseWake].
  void _releaseWakelock() => _releaseWake('pipeline');

  /// Holds the wakelock while an upload is actually **in flight** — auto or
  /// manual — so a backgrounded / swiped-away upload still completes; releases it
  /// between jobs and while a lane is merely queued or wifi-parked (so a parked
  /// lane can't pin the CPU awake indefinitely). The hold is naturally bounded by
  /// each upload call's own network timeout (a hung Omi upload eventually returns).
  void _refreshUploadHold() {
    final inFlight = _lanes.values.any((l) => l.current != null);
    if (inFlight) {
      _acquireWake('upload');
    } else {
      _releaseWake('upload');
    }
  }

  void _throttledUpdate({bool force = false}) {
    if (_isDisposed) return;
    final now = DateTime.now();
    final state = WidgetsBinding.instance.lifecycleState;
    final isForeground = state == null || state == AppLifecycleState.resumed;
    final throttleMs = isForeground ? 1000 : 2000;

    if (!force && now.difference(_lastUiUpdate).inMilliseconds < throttleMs) return;
    _lastUiUpdate = now;
    _updateForegroundProgress(force: force);
    notifyListeners();
  }

  void init() {
    _lastHpKey = _prefs.heypocketApiKey;
    if (_prefs.keepScreenOn) WakelockPlus.enable();
    _restoreState();
    _loadBatches();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(this);
    RecordingsManager.recordingsChangeNotifier.addListener(_onRecordingsChanged);
    RecordingsManager.processingProgress.addListener(_onProgressChanged);
    RecordingsManager.processingLiveness.addListener(_onLivenessChanged);
    RecordingsManager.isTranscoding.addListener(_onTranscodingChanged);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
    // Unpark wifi-gated lanes when connectivity changes (e.g. wifi returns): a
    // lane parks rather than failing jobs when "Upload on Wifi Only" is on and
    // wifi drops, so something has to nudge it back to life.
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) {
      if (!_isDisposed) _pumpAllLanes();
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    _forceSyncCooldownTimer?.cancel();
    _connectivitySub?.cancel();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(null);
    RecordingsManager.recordingsChangeNotifier.removeListener(_onRecordingsChanged);
    RecordingsManager.processingProgress.removeListener(_onProgressChanged);
    RecordingsManager.processingLiveness.removeListener(_onLivenessChanged);
    RecordingsManager.isTranscoding.removeListener(_onTranscodingChanged);
    super.dispose();
  }

  void _onTranscodingChanged() {
    if (_isDisposed) return;
    _isTranscoding = RecordingsManager.isTranscoding.value;
    _throttledUpdate(force: true);
  }

  // Liveness ticks fire from inside the decode/save loops, so they advance even
  // within one long segment or save where the per-segment progress tick can't.
  // Anchoring the stall watchdog on them keeps a slow-but-alive run from being
  // force-killed, without affecting the displayed progress/ETA.
  void _onLivenessChanged() {
    if (_isDisposed) return;
    _lastProgressAt = DateTime.now();
  }

  void _onProgressChanged() {
    if (_isDisposed) return;
    _lastProgressAt = DateTime.now();
    final progress = RecordingsManager.processingProgress.value;
    _processingProgress = progress;
    if (_spState == SyncProcessState.processing) {
      if (_totalMinutes > 0) {
        _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(0.0, _totalMinutes);
        RecordingsManager.minutesRemaining = _minutesRemaining;
      }
      _throttledUpdate();
    }
  }

  void _updateForegroundProgress({bool force = false}) {
    if (_spState != SyncProcessState.syncing && _spState != SyncProcessState.processing) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastNotificationUpdate) < _notificationUpdateInterval) return;
    _lastNotificationUpdate = now;

    if (_spState == SyncProcessState.syncing) {
      SyncNotification.syncing(syncingNotificationText(_syncedCount, _totalCount));
    } else {
      SyncNotification.processing(processingNotificationText());
    }
  }

  static String syncingNotificationText(int synced, int total) {
    if (total == 0) return 'Preparing...';
    final pct = '${(total > 0 ? (synced / total * 100) : 0).toInt()}%';
    return '$synced of $total segments ($pct)';
  }

  static String processingNotificationText() {
    final progress = RecordingsManager.processingProgress.value;
    if (progress >= 1.0) return 'Finishing...';
    final pct = '${(progress * 100).toInt()}%';
    final mins = RecordingsManager.minutesRemaining;
    if (mins < 0) return progress == 0.0 ? 'Preparing...' : 'Calculating… ($pct)';
    if (mins >= 1) return '~${mins.ceil()} min of audio to process ($pct)';
    return '< 1 min of audio to process ($pct)';
  }

  void _onRecordingsChanged() {
    if (_isDisposed) return;
    // Don't clobber live pipeline state — _restoreState only knows 'error' or 'idle'.
    // If the pipeline is active, just reload the batch list.
    const _activePipelineStates = {
      SyncProcessState.syncing,
      SyncProcessState.processing,
      SyncProcessState.stopping,
      SyncProcessState.successUi,
    };
    if (_activePipelineStates.contains(_spState)) {
      unawaited(reloadBatchesSilently());
      return;
    }
    _restoreState();
    _loadBatches();
  }

  void _restoreState() {
    final saved = _prefs.getString(_kSpState, defaultValue: 'idle');
    if (saved == 'error') {
      _spState = SyncProcessState.error;
    } else {
      _spState = SyncProcessState.idle;
    }
    _syncedCount = _prefs.getInt(_kSpSyncedCount);
    _totalCount = _prefs.getInt(_kSpTotalCount);
    _minutesRemaining = _prefs.getDouble(_kSpMinutesRemaining);
    _processingProgress = _prefs.getDouble(_kSpProcessingProgress);
    _markerCount = _prefs.getInt(_kSpMarkerCount);
    _lastCompletedStage = _prefs.getString(
      _kSpLastCompleted,
      defaultValue: 'none',
    );
    _lastActiveStage = _prefs.getString(
      _kSpLastActive,
      defaultValue: 'syncing',
    );

    if (_spState == SyncProcessState.idle) {
      final syncs = ServiceManager.instance().wal.getSyncs();
      if (syncs.isSyncing) {
        _spState = SyncProcessState.syncing;
        // Anchor the stall watchdog, else the first poll would measure against
        // epoch 0 and instantly false-recover a healthy in-flight sync.
        _lastProgressAt = DateTime.now();
        _totalCount = 0; // real count arrives via onWalSyncedProgress once device query completes
      } else if (RecordingsManager.isProcessingAny) {
        _spState = SyncProcessState.processing;
        _isTranscoding = RecordingsManager.isTranscoding.value;
      }
    }
    _throttledUpdate(force: true);
  }

  void _poll() {
    if (_isDisposed) return;

    final state = WidgetsBinding.instance.lifecycleState;
    final isBackground = state != null && state != AppLifecycleState.resumed;
    final now = DateTime.now();

    // Re-assert keep-screen-on after returning to the foreground; Android can
    // drop the wakelock while the app is backgrounded.
    if (state != _lastLifecycleState) {
      if (state == AppLifecycleState.resumed && _prefs.keepScreenOn) {
        WakelockPlus.enable();
      }
      _lastLifecycleState = state;
    }

    final previousPollTime = _lastPollTime;
    if (isBackground && now.difference(previousPollTime).inSeconds < 2) {
      return;
    }
    _lastPollTime = now;

    // The poll timer fires every 0.5–2 s while the process runs; a gap much
    // larger than that means the OS suspended us (Doze / background limits).
    // On wake the elapsed wall-clock makes a healthy-but-frozen pipeline look
    // stalled, so re-anchor the stall watchdog across the gap before the checks
    // below — otherwise the first post-wake poll force-kills a run that was
    // merely parked, discarding minutes of decode and restarting the backlog.
    if (now.difference(previousPollTime) > const Duration(seconds: 10)) {
      _lastProgressAt = now;
    }

    final syncs = ServiceManager.instance().wal.getSyncs();
    final serviceIsSyncing = syncs.isSyncing;
    final serviceIsProcessing = RecordingsManager.isProcessingAny;

    if (_spState == SyncProcessState.stopping) {
      if (!serviceIsSyncing && !serviceIsProcessing) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      } else if (now.difference(_lastProgressAt) > _stoppingStallTimeout) {
        _forceRecoverStuckPipeline(
          'cancel did not clear within ${_stoppingStallTimeout.inSeconds}s',
          serviceIsSyncing,
          serviceIsProcessing,
        );
      }
      _pollHeyPocket();
      return;
    }

    // Stall watchdog: a wedged native transfer leaves serviceIsSyncing stuck
    // true with no further progress, stranding the banner in `syncing`. Runs
    // regardless of _isUserTriggered so both auto- and force-syncs recover.
    if (_spState == SyncProcessState.syncing &&
        serviceIsSyncing &&
        now.difference(_lastProgressAt) > _syncingStallTimeout) {
      _forceRecoverStuckPipeline(
        'no sync progress for ${_syncingStallTimeout.inSeconds}s',
        serviceIsSyncing,
        serviceIsProcessing,
      );
      return;
    }

    // Processing-stall watchdog: a wedged decode isolate (native deadlock /
    // infinite loop) never exits, so `processAll` never unwinds and
    // isProcessingAny stays stuck true — leaving the banner spinning with no way
    // out. Like the syncing watchdog, runs regardless of _isUserTriggered so
    // both foreground-pipeline and background-driven processing recover.
    // _forceRecoverStuckPipeline kills the isolate so the flag actually clears
    // (a plain cancel wouldn't, for a hang). Skipped during transcode, where
    // progress legitimately pauses.
    if (_spState == SyncProcessState.processing &&
        serviceIsProcessing &&
        !_isTranscoding &&
        now.difference(_lastProgressAt) > _processingStallTimeout) {
      _forceRecoverStuckPipeline(
        'no processing progress for ${_processingStallTimeout.inMinutes}m',
        serviceIsSyncing,
        serviceIsProcessing,
      );
      return;
    }

    if (!_isUserTriggered) {
      if (serviceIsSyncing && (_spState == SyncProcessState.idle || _spState == SyncProcessState.processing)) {
        _spState = SyncProcessState.syncing;
        _lastProgressAt = now;
        _totalCount = 0; // real count arrives via onWalSyncedProgress once device query completes
        _syncedCount = 0;
        _syncSpeed = 0.0;
        _throttledUpdate(force: true);
      }

      if (serviceIsProcessing && _spState == SyncProcessState.idle && !_pendingProcessingTransition) {
        _pendingProcessingTransition = true;
        unawaited(
          reloadBatchesSilently().then((_) async {
            _pendingProcessingTransition = false;
            if (_isDisposed) return;
            final discarded = await RecordingsManager.discardedRelBinPaths();
            final covered = await RecordingsManager.coveredBinPaths(_batches.expand((b) => b.rawSegments).toList());
            final processable =
                _batches.expand((b) => b.rawSegments).where((f) => _isProcessableBin(f, discarded, covered)).toList();
            final lengths = await Future.wait(processable.map((f) => f.length().catchError((_) => 0)));
            final totalBytes = lengths.fold(0, (s, len) => s + len);
            if (_isDisposed) return;
            _spState = SyncProcessState.processing;
            // Anchor the processing-stall watchdog so it measures since this
            // promotion, not since app start / last sync tick.
            _lastProgressAt = DateTime.now();
            _totalMinutes = totalBytes / 252000.0;
            _minutesRemaining =
                (_totalMinutes * (1.0 - RecordingsManager.processingProgress.value)).clamp(0.0, _totalMinutes);
            RecordingsManager.minutesRemaining = _minutesRemaining;
            _processingProgress = RecordingsManager.processingProgress.value;
            _throttledUpdate(force: true);
          }),
        );
      }

      if (!serviceIsSyncing && _spState == SyncProcessState.syncing) {
        if (serviceIsProcessing && !_pendingProcessingTransition) {
          _pendingProcessingTransition = true;
          unawaited(
            reloadBatchesSilently().then((_) async {
              _pendingProcessingTransition = false;
              if (_isDisposed) return;
              final discarded = await RecordingsManager.discardedRelBinPaths();
              final covered = await RecordingsManager.coveredBinPaths(_batches.expand((b) => b.rawSegments).toList());
              final processable =
                  _batches.expand((b) => b.rawSegments).where((f) => _isProcessableBin(f, discarded, covered)).toList();
              final lengths = await Future.wait(processable.map((f) => f.length().catchError((_) => 0)));
              final totalBytes = lengths.fold(0, (s, len) => s + len);
              if (_isDisposed) return;
              _spState = SyncProcessState.processing;
              // Anchor the processing-stall watchdog (see sibling promotion above).
              _lastProgressAt = DateTime.now();
              _totalMinutes = totalBytes / 252000.0;
              _minutesRemaining =
                  (_totalMinutes * (1.0 - RecordingsManager.processingProgress.value)).clamp(0.0, _totalMinutes);
              RecordingsManager.minutesRemaining = _minutesRemaining;
              _processingProgress = RecordingsManager.processingProgress.value;
              _syncedCount = 0;
              _syncSpeed = 0.0;
              _throttledUpdate(force: true);
            }),
          );
        } else {
          _spState = SyncProcessState.idle;
          _syncedCount = 0;
          _totalCount = 0;
          _syncSpeed = 0.0;
          _throttledUpdate(force: true);
          unawaited(reloadBatchesSilently());
        }
      }

      if (!serviceIsProcessing && _spState == SyncProcessState.processing) {
        _spState = SyncProcessState.idle;
        _minutesRemaining = 0;
        RecordingsManager.minutesRemaining = -1.0;
        _processingProgress = 0.0;
        _totalMinutes = 0;
        _throttledUpdate(force: true);
        _loadBatches();
      }
    }

    _pollHeyPocket();
  }

  void _pollHeyPocket() {
    final currentKey = _prefs.heypocketApiKey;
    if (currentKey != _lastHpKey) {
      _lastHpKey = currentKey;
      _throttledUpdate(force: true);
      if (currentKey.isNotEmpty) tryAutoUploadAll();
    }
  }

  void _transitionTo(SyncProcessState newState) {
    if (_isDisposed) return;
    _spState = newState;
    // Anchor the stall watchdog on entry to any active phase so it measures
    // time-since-progress, not time-since-app-start.
    if (newState == SyncProcessState.syncing ||
        newState == SyncProcessState.stopping ||
        newState == SyncProcessState.processing) {
      _lastProgressAt = DateTime.now();
      _lastNotificationUpdate = DateTime.fromMillisecondsSinceEpoch(0); // force immediate notification on phase entry
    }
    _throttledUpdate(force: true);

    if (newState != SyncProcessState.successUi) {
      _prefs.saveString(_kSpState, newState.name);
    }
    _prefs.saveString(_kSpLastCompleted, _lastCompletedStage);
    _prefs.saveString(_kSpLastActive, _lastActiveStage);

    if (newState == SyncProcessState.idle ||
        newState == SyncProcessState.error ||
        newState == SyncProcessState.successUi) {
      _pipelineCompleter?.complete();
      _pipelineCompleter = null;
    }
  }

  void _transitionToError(String activeStage, String message) {
    if (_isDisposed) return;
    _isForcePipeline = false;
    _lastActiveStage = activeStage;
    Logger.error(
      'RecordingsController: Pipeline error [$activeStage]: $message',
    );
    _spState = SyncProcessState.error;
    _throttledUpdate(force: true);
    _prefs.saveString(_kSpState, 'error');
    _prefs.saveString(_kSpLastActive, activeStage);
    _pipelineCompleter?.complete();
    _pipelineCompleter = null;
  }

  void _persistProgress() {
    _prefs.saveInt(_kSpSyncedCount, _syncedCount);
    _prefs.saveInt(_kSpTotalCount, _totalCount);
    _prefs.saveDouble(_kSpMinutesRemaining, _minutesRemaining);
    _prefs.saveDouble(_kSpProcessingProgress, _processingProgress);
    _prefs.saveInt(_kSpMarkerCount, _markerCount);
  }

  @override
  void onWalSyncedProgress(
    double percentage, {
    double? speedKBps,
    SyncPhase? phase,
  }) {
    if (_isDisposed) return;
    _lastProgressAt = DateTime.now();
    _syncSpeed = speedKBps ?? 0.0;

    final currentEstimated = ServiceManager.instance().wal.getSyncs().estimatedTotalSegments;
    if (currentEstimated > _totalCount) {
      _totalCount = currentEstimated;
      Logger.debug(
        'RecordingsController: Updated totalCount from service: $_totalCount',
      );
    }

    if (_totalCount > 0) {
      _syncedCount = (percentage * _totalCount).round().clamp(0, _totalCount);
    } else {
      _syncedCount = 0;
    }
    _throttledUpdate();
  }

  Future<void> startPipeline() async {
    if (_spState != SyncProcessState.idle) return;
    _poll();
    if (_spState != SyncProcessState.idle) return;

    _pipelineCompleter = Completer<void>();
    unawaited(_runPipeline());
    return _pipelineCompleter?.future;
  }

  Future<void> startProcessingWithoutSync() async {
    const activeStates = {SyncProcessState.syncing, SyncProcessState.processing, SyncProcessState.stopping};
    if (activeStates.contains(_spState)) return;
    _poll();
    if (activeStates.contains(_spState)) return;

    _pipelineCompleter = Completer<void>();
    _isForcePipeline = false;
    _isUserTriggered = true;
    unawaited(_runProcessing().whenComplete(() => _isUserTriggered = false));
    return _pipelineCompleter?.future;
  }

  Future<void> startForceProcessingWithoutSync() async {
    const activeStates = {SyncProcessState.syncing, SyncProcessState.processing, SyncProcessState.stopping};
    if (activeStates.contains(_spState)) return;
    _poll();
    if (activeStates.contains(_spState)) return;

    _pipelineCompleter = Completer<void>();
    _isForcePipeline = true;
    _isUserTriggered = true;
    unawaited(
      _runProcessing().whenComplete(() {
        _isUserTriggered = false;
        _isForcePipeline = false;
      }),
    );
    return _pipelineCompleter?.future;
  }

  Future<void> startForcePipeline() async {
    if (_spState != SyncProcessState.idle && _spState != SyncProcessState.error) return;
    if (_forceSyncOnCooldown) return;

    _forceSyncOnCooldown = true;
    notifyListeners();

    _forceSyncCooldownTimer?.cancel();
    _forceSyncCooldownTimer = Timer(const Duration(minutes: 1), () {
      if (!_isDisposed) {
        _forceSyncOnCooldown = false;
        notifyListeners();
      }
    });

    _pipelineCompleter = Completer<void>();
    unawaited(_runForcePipeline());
    return _pipelineCompleter?.future;
  }

  Future<void> _runForcePipeline() async {
    final int gen = _pipelineGeneration;
    _isUserTriggered = true;
    _isForcePipeline = true;
    _processAfterCancel = false;
    _lastActiveStage = 'syncing';

    _totalCount = 0;
    _syncedCount = 0;
    _syncSpeed = 0.0;
    _transitionTo(SyncProcessState.syncing);

    _acquireWake('pipeline');
    await SyncNotification.preparingSync();

    final syncs = ServiceManager.instance().wal.getSyncs();
    notifyListeners();
    _persistProgress();

    SyncLocalFilesResponse? result;
    try {
      result = await syncs.rotateAndSync(progress: this);
      _prefs.lastSyncPartial = result?.isPartial ?? false;
    } catch (e) {
      if (gen != _pipelineGeneration) return; // watchdog already recovered
      if (_spState == SyncProcessState.stopping) {
        // User cancelled — honor the choice they made in the cancel dialog.
        await _resolveUserCancel();
      } else {
        // Disconnect or rotation/sync failure — auto-process the bins already
        // on disk (the helper drops to draft mode so an interrupted Force Sync
        // won't finalize the trailing partial bin and delete its source); a
        // genuine failure with nothing downloaded still surfaces as an error.
        await _processBinsAfterInterruptedSync(errorIfEmpty: e.toString());
      }
      return;
    }
    if (gen != _pipelineGeneration) return; // watchdog already recovered

    if (_spState == SyncProcessState.stopping) {
      // User cancelled the force sync — honor the dialog choice.
      await _resolveUserCancel();
      return;
    }

    if (result?.isPartial == true) {
      // The transfer was interrupted (e.g. a BLE drop mid-file) but unwound
      // without throwing, so the trailing bin is partial. Drop out of force
      // mode for the processing pass: finalizing that partial draft here would
      // prune its source bin and break resume on the next sync — the same
      // invariant _processBinsAfterInterruptedSync guards on the throw/cancel
      // paths. A clean Force Sync (isPartial false) still finalizes drafts.
      _isForcePipeline = false;
    }

    _syncedCount = _totalCount;
    _lastCompletedStage = 'syncing';
    notifyListeners();

    _prefs.saveString(_kSpLastCompleted, 'syncing');
    await reloadBatchesSilently();

    _markerCount = _batches.fold(
      0,
      (sum, b) => sum + b.markerTimestamps.length,
    );
    notifyListeners();
    _persistProgress();

    await _runProcessing();
    _isUserTriggered = false;
  }

  void resumePipeline() {
    if (_spState != SyncProcessState.resume) return;
    if (_lastCompletedStage == 'syncing') {
      _isUserTriggered = true;
      unawaited(_runProcessing().whenComplete(() => _isUserTriggered = false));
    } else {
      unawaited(_runPipeline()); // _runPipeline manages _isUserTriggered itself
    }
  }

  void retryFromError() {
    if (_spState != SyncProcessState.error) return;
    if (_lastActiveStage == 'processing' && _lastCompletedStage == 'syncing') {
      _isUserTriggered = true;
      unawaited(_runProcessing().whenComplete(() => _isUserTriggered = false));
    } else {
      unawaited(_runPipeline()); // _runPipeline manages _isUserTriggered itself
    }
  }

  Future<void> _runPipeline() async {
    final int gen = _pipelineGeneration;
    _isUserTriggered = true;
    _processAfterCancel = false;
    _lastActiveStage = 'syncing';

    final syncs = ServiceManager.instance().wal.getSyncs();
    _totalCount = 0; // real count arrives via onWalSyncedProgress once device query completes
    _syncedCount = 0;
    _syncSpeed = 0.0;

    _transitionTo(SyncProcessState.syncing);

    _acquireWake('pipeline');
    await SyncNotification.preparingSync();

    await Future.delayed(const Duration(seconds: 1));

    Logger.debug('RecordingsController: _runPipeline start');

    notifyListeners();
    _persistProgress();

    try {
      final result = await syncs.syncAll(progress: this);
      _prefs.lastSyncPartial = result?.isPartial ?? false;
      if (result == null) {
        Logger.debug('RecordingsController: syncAll returned null (no new segments)');
      }
    } catch (e) {
      if (gen != _pipelineGeneration) return; // watchdog already recovered
      if (_spState == SyncProcessState.stopping) {
        // User cancelled — honor the choice they made in the cancel dialog.
        await _resolveUserCancel();
      } else {
        // Disconnect or sync failure — auto-process bins already on disk; a
        // genuine failure with nothing downloaded still surfaces as an error.
        await _processBinsAfterInterruptedSync(errorIfEmpty: e.toString());
      }
      return;
    }
    if (gen != _pipelineGeneration) return; // watchdog already recovered

    if (_spState == SyncProcessState.stopping) {
      // User cancelled the download — honor the dialog choice.
      await _resolveUserCancel();
      return;
    }

    _syncedCount = _totalCount;
    _lastCompletedStage = 'syncing';
    notifyListeners();

    _prefs.saveString(_kSpLastCompleted, 'syncing');
    await reloadBatchesSilently();

    _markerCount = _batches.fold(
      0,
      (sum, b) => sum + b.markerTimestamps.length,
    );
    notifyListeners();
    _persistProgress();

    await _runProcessing();
    _isUserTriggered = false;
  }

  /// True unless [f] is a raw bin that already has a discard record or (if
  /// [covered] is provided) is already covered by an existing recording.
  /// Mirrors the pipeline's filters so the displayed "minutes to process" and
  /// processing promotions match what will actually be processed.
  static bool _isProcessableBin(File f, Set<String> discarded, [Set<String>? covered]) {
    if (covered != null && covered.contains(f.path)) return false;
    final parts = f.path.split('/raw_segments/');
    return parts.length != 2 || !discarded.contains(parts.last);
  }

  Future<void> _runProcessing() async {
    final int gen = _pipelineGeneration;
    _lastActiveStage = 'processing';

    _totalMinutes = 0.0;
    _minutesRemaining = 0.0;
    _processingProgress = 0.0;

    _transitionTo(SyncProcessState.processing);

    _acquireWake('pipeline');
    await SyncNotification.preparingProcessing();

    final allBins = _batches.expand((b) => b.rawSegments).toList();
    // Always-on idempotency guard: skip bins already covered by a recording so we
    // don't re-decode audio that already has an output file (and can't duplicate
    // it).
    final Set<String> coveredBins = await RecordingsManager.coveredBinPaths(allBins);
    final discardedBins = await RecordingsManager.discardedRelBinPaths();

    final processableBatches = _batches.map((b) {
      final filtered = b.rawSegments.where((f) => _isProcessableBin(f, discardedBins, coveredBins)).toList();
      if (filtered.length == b.rawSegments.length) return b;
      return Batch(
        dateString: b.dateString,
        date: b.date,
        rawSegments: filtered,
        draftRecordings: b.draftRecordings,
        finalizedRecordings: b.finalizedRecordings,
        markerTimestamps: b.markerTimestamps,
        discards: b.discards,
      );
    }).toList();

    final activeBatches = processableBatches.where((b) => b.rawSegments.isNotEmpty).toList();
    final hasDrafts = processableBatches.any((b) => b.draftRecordings.isNotEmpty);
    final hasMarkers = processableBatches.any((b) => b.markerTimestamps.isNotEmpty);

    if (activeBatches.isEmpty && !(_isForcePipeline && hasDrafts) && !hasMarkers) {
      _prefs.lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
      await _finishSuccess();
      return;
    }

    final bool backgroundMode = !_isForcePipeline;

    final allRaw = activeBatches.expand((b) => b.rawSegments).toList();
    final totalBytes = allRaw.fold(0, (sum, f) {
      try {
        return sum + f.lengthSync();
      } catch (_) {
        return sum;
      }
    });
    final totalMin = totalBytes / 252000.0;

    _totalMinutes = totalMin;
    _minutesRemaining = totalMin;
    // Keep the static in lockstep with the instance: the notification text
    // (processingNotificationText) reads RecordingsManager.minutesRemaining,
    // while the card reads the instance _minutesRemaining. _runProcessing's
    // estimate filters out covered/discarded bins, so without this the
    // notification would keep showing the earlier inflated (_poll-set) value
    // until the first progress tick — card and notification visibly disagree.
    RecordingsManager.minutesRemaining = totalMin;
    _processingProgress = 0.0;
    notifyListeners();
    _persistProgress();

    _updateForegroundProgress(
        force: true); // overwrite "preparing..." with the actual minutes now that totalMinutes is known
    try {
      await _manager.processAll(
        processableBatches,
        (_, __) {}, // global progress listener handles this
        backgroundMode: backgroundMode,
        finalizeDrafts: _isForcePipeline,
        onRecordingFinalized: () {
          unawaited(reloadBatchesSilently());
        },
      );
    } catch (e) {
      if (gen != _pipelineGeneration) return; // watchdog already recovered
      _releaseWakelock();
      if (_isAppForeground()) {
        _settleNotification();
      }
      if (_spState == SyncProcessState.stopping) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      } else {
        _transitionToError('processing', e.toString());
      }
      return;
    }
    if (gen != _pipelineGeneration) return; // watchdog already recovered

    if (_spState == SyncProcessState.stopping) {
      _releaseWakelock();
      if (_isAppForeground()) {
        _settleNotification();
      }
      _transitionTo(SyncProcessState.idle);
      unawaited(reloadBatchesSilently());
      return;
    }

    _releaseWakelock();

    _minutesRemaining = 0;
    _lastCompletedStage = 'processing';
    notifyListeners();

    _persistProgress();
    await RecordingsManager.pruneConsumedBins();
    await reloadBatchesSilently();
    _prefs.lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
    await _finishSuccess();
  }

  /// Resolves a user cancel once the sync has unwound: continue into processing
  /// the segments already on disk, or stop everything, per the choice captured
  /// in the cancel dialog ([_processAfterCancel]). Disconnects never reach here
  /// — they auto-process via the non-`stopping` paths.
  Future<void> _resolveUserCancel() async {
    if (_processAfterCancel) {
      await _processBinsAfterInterruptedSync();
    } else {
      await _settleCancelledToIdle();
    }
  }

  /// Tears the pipeline down to idle after a "stop everything" cancel, leaving
  /// downloaded segments on disk for the next sync. Mirrors the normal exit
  /// cleanup (wakelock, foreground task, state).
  Future<void> _settleCancelledToIdle() async {
    _isUserTriggered = false;
    _isForcePipeline = false;
    _releaseWakelock();
    if (_isAppForeground()) {
      _settleNotification();
    }
    _transitionTo(SyncProcessState.idle);
    unawaited(reloadBatchesSilently());
  }

  /// Falls through from an interrupted sync — a "process downloaded" cancel or
  /// a setup-phase failure (no connection, listFiles disconnect, storage full,
  /// rotation failure) — into processing the bins that already reached disk,
  /// instead of dropping straight to idle/error and leaving them for the next
  /// sync.
  ///
  /// Always processes in draft/background mode. An interrupted sync downloads
  /// oldest-first and deletes each whole file immediately, so the only possibly
  /// incomplete bin is the trailing one. Finalizing drafts here (Force Sync
  /// behaviour) would promote that partial and let bin-pruning delete its
  /// source, breaking resume — the exact failure the draft-flush invariant
  /// guards against — so `_isForcePipeline` is cleared up front.
  ///
  /// Transitions to `processing` synchronously before the first await: the
  /// `_poll` timer would otherwise observe `stopping`/`syncing` with the WAL
  /// service no longer syncing and yank the state to idle during the reload
  /// below. [errorIfEmpty] is the failure message for the throw path; with
  /// nothing on disk to process we surface it as an error rather than a
  /// misleading success (null = clean cancel, which settles back to idle).
  Future<void> _processBinsAfterInterruptedSync({String? errorIfEmpty}) async {
    if (_isDisposed) return;
    _isForcePipeline = false;
    _lastActiveStage = 'processing';
    _transitionTo(SyncProcessState.processing);
    _syncedCount = _totalCount;
    _lastCompletedStage = 'syncing';
    _prefs.saveString(_kSpLastCompleted, 'syncing');
    _prefs.lastSyncPartial = true;
    await reloadBatchesSilently();

    final hasBins = _batches.any((b) => b.rawSegments.isNotEmpty);
    final hasMarkers = _batches.any((b) => b.markerTimestamps.isNotEmpty);
    if (!hasBins && !hasMarkers) {
      _isUserTriggered = false;
      _releaseWakelock();
      if (_isAppForeground()) {
        _settleNotification();
      }
      if (errorIfEmpty != null) {
        _transitionToError('syncing', errorIfEmpty);
      } else {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      }
      return;
    }

    _markerCount = _batches.fold(0, (sum, b) => sum + b.markerTimestamps.length);
    notifyListeners();
    _persistProgress();
    await _runProcessing();
    _isUserTriggered = false;
  }

  void dismissSuccess() {
    if (_spState != SyncProcessState.successUi) return;

    _lastCompletedStage = 'none';
    _syncedCount = 0;
    _totalCount = 0;
    _markerCount = 0;
    _minutesRemaining = 0;
    _processingProgress = 0.0;
    _totalMinutes = 0;
    notifyListeners();

    _prefs.saveString(_kSpLastCompleted, 'none');
    _persistProgress();
    _transitionTo(SyncProcessState.idle);
    _loadBatches();
    if (_isAppForeground()) {
      _settleNotification();
    }
  }

  Future<void> _finishSuccess() async {
    _isForcePipeline = false;
    _transitionTo(SyncProcessState.successUi);
    RecordingsManager.isSuccessNotificationActive.value = true;
    unawaited(SyncNotification.complete());
    await Future.delayed(const Duration(milliseconds: 10000));
    RecordingsManager.isSuccessNotificationActive.value = false;
    if (_isDisposed || _spState != SyncProcessState.successUi) return;

    dismissSuccess();
  }

  bool _isAppForeground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Settle the single notification after a foreground pipeline ends. With
  /// auto-sync on, revert to the idle "Next sync / Last Sync" line; in Manual
  /// Only the service isn't persistent, so release Dart ownership and let native
  /// resume connection-state text (no redundant line).
  void _settleNotification() {
    if (_prefs.backgroundSyncIntervalMinutes > 0) {
      unawaited(SyncNotification.idle());
    } else {
      unawaited(SyncNotification.clear());
    }
  }

  /// [processDownloaded] only applies when cancelling during the syncing phase:
  /// true continues into processing the segments already on disk, false stops
  /// everything and settles to idle. It is irrelevant when cancelling during
  /// processing (the download is already done) — pass false there.
  void cancelPipeline({bool processDownloaded = false}) {
    if (_spState != SyncProcessState.syncing && _spState != SyncProcessState.processing) return;
    // If the sync finished while the cancel dialog was open, the pipeline has
    // already advanced to processing — a "process downloaded" request is now
    // being satisfied, so don't tear that processing down. ("Stop everything"
    // still stops it.)
    if (processDownloaded && _spState == SyncProcessState.processing) return;
    _processAfterCancel = processDownloaded;
    Logger.debug(
      'RecordingsController: Cancel confirmed — '
      '${processDownloaded ? 'will process downloaded segments' : 'stopping everything'}.',
    );
    _transitionTo(SyncProcessState.stopping);
    ServiceManager.instance().wal.getSyncs().cancelSync();
    RecordingsManager.cancelProcessing();
  }

  /// Last-resort recovery when the pipeline is wedged: the native BLE transfer
  /// can stall with the WAL service's isSyncing flag stuck set, so the normal
  /// completion path never runs and the UI is stranded in `syncing`/`stopping`
  /// with no escape but force-closing the app. Triggered by the stall watchdog
  /// in [_poll]. Mirrors the normal exit cleanup (wakelock, foreground task,
  /// idle state) and self-instruments the wedge so a recurrence is diagnosable.
  void _forceRecoverStuckPipeline(String reason, bool serviceIsSyncing, bool serviceIsProcessing) {
    final ageMs = DateTime.now().difference(_lastProgressAt).inMilliseconds;
    Logger.warning('RecordingsController: pipeline watchdog force-recovery — $reason '
        '(state=${_spState.name}, isSyncing=$serviceIsSyncing, isProcessing=$serviceIsProcessing, '
        'sinceProgress=${ageMs}ms, lifecycle=${WidgetsBinding.instance.lifecycleState})');

    // Invalidate any pipeline runner still parked on the wedged await so it
    // bails instead of running its post-await transitions over our recovery.
    _pipelineGeneration++;

    final syncs = ServiceManager.instance().wal.getSyncs();
    try {
      syncs.cancelSync();
    } catch (_) {}
    // stop() resets the WAL sync state (clears isSyncing). The wedged native op
    // may still hold the storage lock until it unwinds, but acquireStorageLock
    // has a 10s timeout, so the next sync surfaces a bounded error rather than
    // deadlocking.
    unawaited(syncs.stop().catchError((_) {}));
    // Kill (not just cooperatively cancel) any processing isolate: a wedged
    // isolate never reads the cancel, so only a kill lets processAll unwind and
    // clear isProcessingAny — without that, the next _poll re-promotes straight
    // back to `processing` and the banner bounces back.
    RecordingsManager.forceResetProcessing();

    _isUserTriggered = false;
    _isForcePipeline = false;
    _syncedCount = 0;
    _totalCount = 0;
    _syncSpeed = 0.0;
    _minutesRemaining = 0;
    _processingProgress = 0.0;
    _totalMinutes = 0;
    _releaseWakelock();
    // Keep the foreground service running on a processing-stall recovery so the
    // OS protection stays in place. If the isolate was merely OS-throttled, the
    // process would otherwise be killed the moment the notification disappears,
    // turning a recoverable stall into a full process kill. Sync-stall recovery
    // always stops the service (no ongoing work to protect).
    if (!serviceIsProcessing || serviceIsSyncing) {
      _settleNotification();
    }
    _transitionTo(SyncProcessState.idle);
    unawaited(reloadBatchesSilently());
  }

  Future<void> _loadBatches() async {
    _isLoading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _manager.getBatches(),
        _manager.getMarkerConversations(),
      ]);
      if (!_isDisposed) {
        _batches = results[0] as List<Batch>;
        _markerConversations = results[1] as List<MarkerConversation>;

        if (await _enforceRetentionPolicy()) {
          _batches = await _manager.getBatches();
          _markerConversations = await _manager.getMarkerConversations();
        }

        _isLoading = false;
        final rawSegments = _batches.expand((b) => b.rawSegments).toList();
        final acc = _computeAccumulated(
          _batches,
          await RecordingsManager.discardedRelBinPaths(),
          await RecordingsManager.coveredBinPaths(rawSegments),
        );
        _toProcessMinutes = acc.toProcessMinutes;
        _draftMinutes = acc.draftMinutes;
        _unprocessedBinCount = acc.unprocessedBins;
        _draftEndTime = acc.draftEndTime;
        notifyListeners();
        tryAutoUploadAll();
      }
    } catch (e) {
      Logger.error('RecordingsController: Failed to load batches: $e');
      if (!_isDisposed) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> reloadBatchesSilently() async {
    try {
      final results = await Future.wait([
        _manager.getBatches(),
        _manager.getMarkerConversations(),
      ]);
      if (!_isDisposed) {
        _batches = results[0] as List<Batch>;
        _markerConversations = results[1] as List<MarkerConversation>;

        if (await _enforceRetentionPolicy()) {
          _batches = await _manager.getBatches();
          _markerConversations = await _manager.getMarkerConversations();
        }

        final rawSegments = _batches.expand((b) => b.rawSegments).toList();
        final acc = _computeAccumulated(
          _batches,
          await RecordingsManager.discardedRelBinPaths(),
          await RecordingsManager.coveredBinPaths(rawSegments),
        );
        _toProcessMinutes = acc.toProcessMinutes;
        _draftMinutes = acc.draftMinutes;
        _unprocessedBinCount = acc.unprocessedBins;
        _draftEndTime = acc.draftEndTime;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> deleteDay(Batch batch) async {
    final keys = batch.finalizedRecordings.map((c) => c.uploadKey).whereType<String>().toSet();
    await _prefs.removeUploadedFromHeypocket(keys);
    await _prefs.removeOmiSynced(_binPathsForConversations(batch.finalizedRecordings));
    await _manager.deleteDay(batch);
    await _loadBatches();
  }

  Future<void> deleteConversation(Conversation conversation) async {
    await deleteConversations([conversation]);
  }

  Future<void> deleteDiscards(List<DiscardRecord> discards, {bool reload = true}) async {
    if (discards.isEmpty) return;
    for (final d in discards) {
      await RecordingsManager.removeDiscardRecord(d, deleteBins: true);
    }
    if (reload) await _loadBatches();
  }

  Future<void> deleteConversations(List<Conversation> conversations, {bool reload = true}) async {
    if (conversations.isEmpty) return;
    final keys = conversations.map((c) => c.uploadKey).whereType<String>().toSet();
    await _prefs.removeUploadedFromHeypocket(keys);
    await _prefs.removeOmiSynced(_binPathsForConversations(conversations));
    final touchedSessionIds = conversations.map((c) => c.sessionId).whereType<int>().toSet();
    await RecordingsManager.deleteConversations(conversations);
    if (reload) await _loadBatches();
    // If a session has no remaining finalized/draft recording, its raw bins
    // would silently reprocess on the next sync and resurrect what we just
    // deleted. Wipe them, bypassing the 48h discard hold.
    if (touchedSessionIds.isNotEmpty) {
      final liveSessionIds = _batches
          .expand((b) => [...b.finalizedRecordings, ...b.draftRecordings])
          .map((c) => c.sessionId)
          .whereType<int>()
          .toSet();
      final orphaned = touchedSessionIds.difference(liveSessionIds);
      if (orphaned.isNotEmpty) {
        await RecordingsManager.deleteBinsForSessions(orphaned);
        if (reload) await _loadBatches();
      }
    }
  }

  int countShortRecordings(int minSeconds) {
    final finalized =
        _batches.expand((b) => b.finalizedRecordings).where((c) => c.duration.inSeconds < minSeconds).length;
    final discards = _batches.expand((b) => b.discards).where((d) => d.duration.inSeconds < minSeconds).length;
    return finalized + discards;
  }

  Future<void> deleteShortRecordings(int minSeconds) async {
    final finalizedToDelete =
        _batches.expand((b) => b.finalizedRecordings).where((c) => c.duration.inSeconds < minSeconds).toList();
    final discardsToDelete =
        _batches.expand((b) => b.discards).where((d) => d.duration.inSeconds < minSeconds).toList();

    if (finalizedToDelete.isEmpty && discardsToDelete.isEmpty) return;

    // Delete both sets, but only reload once at the very end.
    await deleteConversations(finalizedToDelete, reload: false);
    await deleteDiscards(discardsToDelete, reload: false);
    await _loadBatches();
  }

  Future<void> deleteMarkerConversation(MarkerConversation mc) async {
    await RecordingsManager.deleteMarkerConversation(mc);
    await _loadBatches();
  }

  Future<bool> _enforceRetentionPolicy() async {
    final days = _prefs.keepRecordingsDays;
    if (days <= 0) return false;

    final cutoff = DateTime.now().subtract(Duration(days: days));
    final toDelete = _batches.expand((b) => b.finalizedRecordings).where((c) => c.startTime.isBefore(cutoff)).toList();

    if (toDelete.isNotEmpty) {
      Logger.debug('Retention: deleting ${toDelete.length} recordings older than $days days');
      await _prefs.removeOmiSynced(_binPathsForConversations(toDelete));
      await RecordingsManager.deleteConversations(toDelete);
      return true;
    }
    return false;
  }

  /// Re-runs processing on the bins referenced by [d] with VAD bypassed so
  /// every frame is kept as one audio file (WAV by default). On success the
  /// discard record is removed and the recording appears in the day card; the
  /// user opens it in the player to decide whether it's worth keeping.
  Future<void> recoverDiscard(DiscardRecord d) async {
    if (_spState != SyncProcessState.idle) return;
    if (RecordingsManager.isProcessingAny) return;
    final directory = await getApplicationDocumentsDirectory();
    final bins = <File>[];
    for (final rel in d.relativeBins) {
      final f = File('${directory.path}/raw_segments/$rel');
      if (await f.exists()) bins.add(f);
    }
    if (bins.isEmpty) {
      // Bins were already swept or deleted — drop the orphan record and reload.
      await RecordingsManager.removeDiscardRecord(d, deleteBins: false);
      await _loadBatches();
      return;
    }
    bins.sort((a, b) => a.path.split('/').last.compareTo(b.path.split('/').last));

    final dateStr = _dateString(d.startTime);
    final syntheticBatch = Batch(
      dateString: dateStr,
      date: DateTime(d.startTime.year, d.startTime.month, d.startTime.day),
      rawSegments: bins,
      draftRecordings: const [],
      finalizedRecordings: const [],
    );

    final override = ProcessingSettings(
      vadEnabled: false,
      speechThreshold: 0.0,
      silenceDurationToSplitMs: 0x7FFFFFFF,
      minDurationMs: 0,
      minSpeechMs: 0,
      maxChunkMs: 0x7FFFFFFFFFFFFFFF,
      deviceId: _prefs.btDevice.id,
      audioSaveFormat: _prefs.audioSaveFormat,
      omiEnabled: false,
    );

    _lastActiveStage = 'processing';
    _transitionTo(SyncProcessState.processing);
    try {
      await _manager.processAll(
        [syntheticBatch],
        (_, __) {},
        backgroundMode: false,
        settingsOverride: override,
      );
    } catch (e) {
      _transitionToError('processing', e.toString());
      return;
    }
    // Bins are deleted by processAll's safe-to-delete pass; remove the stale
    // jsonl entry so the ghost disappears.
    await RecordingsManager.removeDiscardRecord(d, deleteBins: false);
    await _loadBatches();
    await _finishSuccess();
  }

  /// Drops [d] and its bins immediately. Used when the user decides the
  /// audio isn't worth recovering.
  Future<void> deleteDiscard(DiscardRecord d) async {
    await RecordingsManager.removeDiscardRecord(d, deleteBins: true);
    await _loadBatches();
  }

  String _dateString(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Enqueues an upload of [conversation] to [integration] on that integration's
  /// lane, unless it's already in flight or already queued (dedup by
  /// [UploadJob.key]). Manual jobs drain ahead of auto within the lane. Does NOT
  /// start the lane — callers call [_pumpAllLanes] after enqueuing a batch.
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
  void _pumpAllLanes() {
    for (final name in _lanes.keys.toList()) {
      unawaited(_pumpLane(name));
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
    if (_isDisposed || lane.draining || lane.isPausedBusy) return;
    lane.draining = true;
    try {
      while (!_isDisposed && !lane.isEmpty) {
        // Wifi gate before committing to a job. Fail closed: if we can't confirm
        // wifi, park rather than upload over cellular. The connectivity listener
        // re-pumps on the next change.
        if (_prefs.uploadOnWifiOnly) {
          try {
            final connectivity = await Connectivity().checkConnectivity();
            if (!connectivity.contains(ConnectivityResult.wifi)) break; // parked
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
        if (!_isDisposed) notifyListeners();

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
            _pendingSnackMessage = 'HeyPocket: API key revoked — update it in Integrations';
          } else if (e is OmiSyncException && e.isAuthError) {
            _pendingSnackMessage = 'Omi sync: credentials invalid — update them in Integrations';
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
          if (!_isDisposed) {
            _updateUploadNotification();
            notifyListeners();
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
      if (!_isDisposed) unawaited(_pumpLane(name));
    });
  }

  /// Once no lane has work in flight or queued, reset the per-run counters
  /// together (so the aggregate total doesn't lurch as one lane finishes before
  /// another) and settle the notification back to idle.
  void _finalizeIfAllIdle() {
    if (_isDisposed || _anyLaneActive) return;
    final hadProgress = _lanes.values.any((l) => l.done > 0 || l.failed > 0);
    for (final l in _lanes.values) {
      l.done = 0;
      l.failed = 0;
      l.busyUntil = null;
    }
    if (hadProgress && _spState == SyncProcessState.idle) _settleNotification();
  }

  /// Composes and pushes the aggregated upload notification: a one-line summary
  /// (shown collapsed) followed by a per-active-integration line (shown expanded
  /// via the native BigTextStyle). Only while the sync/process pipeline is idle
  /// (it owns the notification when active). Android-only (no-ops on iOS).
  void _updateUploadNotification() {
    if (_spState != SyncProcessState.idle) return;

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
    unawaited(SyncNotification.uploading(text));
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

    for (final batch in _batches.reversed) {
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
    _pumpAllLanes();
    if (!_isDisposed) notifyListeners();
  }

  Future<bool> _allIntegrationsDelivered(Conversation c) async {
    for (final integration in _integrations) {
      if (integration.isAvailableFor(c)) {
        if (!integration.hasDelivered(c)) {
          Logger.debug('Passthrough blocked by ${integration.name}');
          return false;
        }
      }
    }
    return true;
  }

  /// After a successful upload in passthrough mode, appends the passthrough flag
  /// to the .meta sidecar and deletes the local audio and associated sidecar files.
  /// Deletion only proceeds once every enabled integration has confirmed delivery.
  Future<void> _convertToPassthrough(Conversation conversation) async {
    try {
      final filePath = conversation.file.path;
      final fileDir = conversation.file.parent.path;
      final audioFileName = filePath.split('/').last;
      final basePath = filePath.contains('.') ? filePath.substring(0, filePath.lastIndexOf('.')) : filePath;
      final metaFile = File('$basePath.meta');

      // Guard: without a .meta sidecar the conversation would vanish entirely
      // from the list after audio deletion. Bail out to preserve the recording.
      if (!await metaFile.exists()) {
        Logger.error('Passthrough: Aborting — no .meta sidecar found for $filePath');
        return;
      }

      if (!await _allIntegrationsDelivered(conversation)) return;

      // All enabled integrations have confirmed — safe to stamp and delete.
      // The passthrough flag lives at flagOffset = 417 + keyLen (byte [0] of the
      // flag block), NOT at EOF. A finalized .meta has more bytes after it
      // (forceSynced/capEnded/isSilero + the bins-JSON tail), so appending a byte
      // would land past the bins JSON where no reader looks — the flag would stay 0
      // and fromMetaOnly() would drop the (now audio-less) recording entirely.
      // Set it in place; only extend when a degenerate short meta lacks the slot.
      final bytes = await metaFile.readAsBytes();
      if (bytes.length >= 417) {
        final keyLen = bytes[416];
        final flagOffset = 417 + keyLen;
        final alreadyPassthrough = flagOffset < bytes.length && (bytes[flagOffset] & 0x01) != 0;
        if (!alreadyPassthrough) {
          if (flagOffset < bytes.length) {
            final out = Uint8List.fromList(bytes);
            out[flagOffset] |= 0x01;
            await metaFile.writeAsBytes(out);
          } else {
            // Short meta with no flag slot yet — pad up to and including it.
            final out = Uint8List(flagOffset + 1)..setRange(0, bytes.length, bytes);
            out[flagOffset] = 0x01;
            await metaFile.writeAsBytes(out);
          }
        }
      }

      // Delete the processed audio file.
      if (await conversation.file.exists()) await conversation.file.delete();

      // Delete any EDL (marker) files whose segmentFilename points to this recording.
      // Markers are meaningless without playable audio; leaving them causes the
      // markers view to show "Processing…" indefinitely.
      try {
        final edlFiles = await Directory(fileDir)
            .list()
            .where((e) => e is File && e.path.split('/').last.startsWith('marker_') && e.path.endsWith('.edl'))
            .cast<File>()
            .toList();
        for (final edl in edlFiles) {
          try {
            final json = jsonDecode(await edl.readAsString()) as Map<String, dynamic>;
            if (json['segmentFilename'] == audioFileName) await edl.delete();
          } catch (_) {}
        }
      } catch (_) {}

      RecordingsManager.notifyRecordingsChanged();
    } catch (e) {
      Logger.error('Passthrough: Failed to convert conversation: $e');
    }
  }

  void cancelPendingOmiUploads() {
    final dropped = _purgeQueuedFor('Omi Cloud');
    final inFlight = _syncingKeys.where((k) => k.startsWith('Omi Cloud_')).length;
    _syncingKeys.removeWhere((k) => k.startsWith('Omi Cloud_'));
    Logger.debug('RecordingsController: Omi Cloud disabled — dropped $dropped queued, cleared $inFlight in-flight');
    if (!_isDisposed) notifyListeners();
  }

  void cancelPendingHeyPocketUploads() {
    final dropped = _purgeQueuedFor('HeyPocket');
    Logger.debug('RecordingsController: HeyPocket disabled — dropped $dropped queued; in-flight will drain and stop');
    if (!_isDisposed) notifyListeners();
  }

  Future<List<UploadFailure>> uploadConversation(Conversation conversation, {bool force = false}) async {
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) throw Exception('Upload key unavailable');

    // Validate wifi up-front so a manual tap gets instant feedback rather than a
    // job that silently parks. Once enqueued, async upload failures surface via
    // the reactive row state, not a returned failure.
    if (_prefs.uploadOnWifiOnly) {
      final connectivity = await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.wifi)) {
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
    _pumpAllLanes();
    notifyListeners();
    return [];
  }

  /// Per-integration upload status for [c] across all *configured* integrations,
  /// for the detail sheet and the row badge. Both the aggregate [uploadStatus]
  /// and [actionableIntegrationCount] derive from this so the row icon, badge,
  /// and sheet never disagree.
  /// Passed to [PassthroughIntegration.upload] so each delivered chunk repaints
  /// the integration rows with the new "X/Total chunks" count live.
  void _notifyChunkProgress() {
    if (!_isDisposed) notifyListeners();
  }

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
        final connectivity = await Connectivity().checkConnectivity();
        if (!connectivity.contains(ConnectivityResult.wifi)) {
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
    _pumpAllLanes();
    notifyListeners();
    return [];
  }

  static Iterable<String> _binPathsForConversations(List<Conversation> conversations) => conversations.map((c) {
        final ts = c.file.path.split('/').last.split('_').last.split('.').first;
        return '${c.file.parent.path}/recording_fs320_$ts.bin';
      });

  /// Splits pending audio into figures for the banner:
  ///  - [toProcessMinutes] / [unprocessedBins]: raw `.bin` audio still waiting
  ///    to be decoded, and how many bin files that is.
  ///  - [draftMinutes]: duration already folded into open draft recordings.
  ///
  /// The "to process" set mirrors exactly what [RecordingsManager.processAll]
  /// will decode: every raw bin on disk EXCEPT those VAD already rejected
  /// (discarded) and those already covered by an existing recording.
  ///
  /// [discardedRelBins] MUST be the global persisted set from
  /// [RecordingsManager.discardedRelBinPaths]. [coveredBins] are those identified
  /// by [RecordingsManager.coveredBinPaths].
  ({double toProcessMinutes, double draftMinutes, int unprocessedBins, DateTime? draftEndTime}) _computeAccumulated(
      List<Batch> batches, Set<String> discardedRelBins, Set<String> coveredBins) {
    int rawBytes = 0;
    int unprocessedBinsCount = 0;
    for (final f in batches.expand((b) => b.rawSegments)) {
      if (!_isProcessableBin(f, discardedRelBins, coveredBins)) continue;

      try {
        rawBytes += f.lengthSync();
        unprocessedBinsCount++;
      } catch (_) {}
    }

    // The "Conversation in progress" banner reflects the accumulated `_draft`
    // files already combined on disk (the banner renders this branch only when
    // there is no raw audio left to process — see AccumulatingBanner). Its
    // duration is the sum of the drafts' decoded length.
    int draftMs = 0;
    DateTime? latestDraftEnd;
    for (final c in batches.expand((b) => b.draftRecordings)) {
      draftMs += c.duration.inMilliseconds;
      if (latestDraftEnd == null || c.endTime.isAfter(latestDraftEnd)) {
        latestDraftEnd = c.endTime;
      }
    }

    // "Captured through" is the draft's own end (startTime + decoded duration) —
    // the draft file is the source of truth for how far the in-progress audio
    // reaches. We must NOT derive this from leftover raw bins: once the draft's
    // bins are pruned after a processing pass, the only bin still on disk can be
    // an unrelated stale discard from much earlier (e.g. a 4:50 AM "below minimum
    // speech" segment), which would make the banner read a time *earlier* than
    // the audio actually captured. The decoded duration can overshoot wall-clock
    // when an inter-file gap is padded with silence, so clamp to now — captured
    // audio never reaches into the future.
    DateTime? draftEndTime;
    if (latestDraftEnd != null) {
      final now = DateTime.now();
      draftEndTime = latestDraftEnd.isAfter(now) ? now : latestDraftEnd;
    }

    return (
      toProcessMinutes: rawBytes / 252000.0,
      draftMinutes: draftMs / 60000.0,
      unprocessedBins: unprocessedBinsCount,
      draftEndTime: draftEndTime,
    );
  }
}
