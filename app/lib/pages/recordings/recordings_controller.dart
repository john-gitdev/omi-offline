import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/services/devices/errors.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:omi/pages/recordings/integration_upload_manager.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:omi/utils/audio/sync_notification.dart';
import 'package:omi/models/integration_upload_types.dart';

// Re-export the upload value types so existing importers of this file (batch_card,
// integration_status_section, recording_player_page) keep working unchanged. The
// definitions now live in models/integration_upload_types.dart.
export 'package:omi/models/integration_upload_types.dart';

class RecordingsController extends ChangeNotifier implements IWalSyncProgressListener {
  final RecordingsManager _manager = RecordingsManager();
  final _prefs = SharedPreferencesUtil();

  late final List<PassthroughIntegration> _integrations = PassthroughIntegration.getIntegrations(_prefs);

  /// Owns the per-integration upload lanes and upload-status derivation. All its
  /// platform/state touchpoints are injected here so the manager itself stays
  /// plugin-free and unit-testable.
  late final IntegrationUploadManager _uploads = IntegrationUploadManager(
    integrations: _integrations,
    prefs: _prefs,
    batchesProvider: () => _batches,
    isDisposed: () => _isDisposed,
    isPipelineIdle: () => _spState == SyncProcessState.idle,
    notifyUi: notifyListeners,
    acquireWake: _acquireWake,
    releaseWake: _releaseWake,
    showUploadNotification: (text) => unawaited(SyncNotification.uploading(text)),
    settleNotification: _settleNotification,
    setPendingSnack: (msg) => _pendingSnackMessage = msg,
    checkOnWifi: () async => (await Connectivity().checkConnectivity()).contains(ConnectivityResult.wifi),
    convertToPassthrough: _convertToPassthrough,
  );

  List<Batch> _batches = [];
  List<Batch> get batches => _batches;

  List<MarkerConversation> _markerConversations = [];
  List<MarkerConversation> get markerConversations => _markerConversations;

  bool _isLoading = true;
  bool get isLoading => _isLoading;

  SyncProcessState _spState = SyncProcessState.idle;
  SyncProcessState get spState => _spState;

  /// True while a sync/process/stop is actively running. The post-completion
  /// "Completed" banner (successUi) is a SETTLED state, not a busy one, so it is
  /// deliberately excluded — callers (e.g. Recover Discard) treat it as actionable.
  /// Used to gate actions and surface a "try again in a moment" hint.
  bool get isPipelineBusy {
    const busy = {SyncProcessState.syncing, SyncProcessState.processing, SyncProcessState.stopping};
    return busy.contains(_spState) || RecordingsManager.isProcessingAny;
  }

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
  /// the row/player "uploading" spinner. Delegated to the upload manager.
  Set<String> get uploadingFiles => _uploads.uploadingFiles;

  String _lastHpKey = '';

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

  // Whether the device was actually reached during the current run. A run that
  // attempts a device sync (_runPipeline / _runForcePipeline) resets this to
  // false and flips it true once the sync connects; a run that only processes
  // local bins (Force Process / resume / retry) leaves it true. When it stays
  // false — a manual sync while the Omi is out of range or Bluetooth is off —
  // the outcome is recorded as a skip (like the background auto-sync path)
  // instead of a completion, so the notification reads "Last Sync: Skipped" and
  // the "Last synced" clock (lastSyncCompletedMs) isn't bumped by a run that
  // pulled nothing from the device.
  bool _deviceReached = true;

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
      if (!_isDisposed) _uploads.pumpAllLanes();
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
    const activePipelineStates = {
      SyncProcessState.syncing,
      SyncProcessState.processing,
      SyncProcessState.stopping,
      SyncProcessState.successUi,
    };
    if (activePipelineStates.contains(_spState)) {
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
            final incomplete = await _incompleteBins();
            final processable = _batches
                .expand((b) => b.rawSegments)
                .where((f) => isProcessableBin(f, discarded, covered, incomplete))
                .toList();
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
              final incomplete = await _incompleteBins();
              final processable = _batches
                  .expand((b) => b.rawSegments)
                  .where((f) => isProcessableBin(f, discarded, covered, incomplete))
                  .toList();
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
    // Process-only run (no device sync) — it completes on its own merits.
    _deviceReached = true;
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
    // Process-only run (no device sync) — it completes on its own merits.
    _deviceReached = true;
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
    _deviceReached = false;
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
      _deviceReached = true;
      _prefs.lastSyncPartial = result?.isPartial ?? false;
    } catch (e) {
      // A connection-null throw means we never reached the device (out of range
      // / BT off); anything else means we connected but the transfer failed —
      // still a real (partial) sync, so keep _deviceReached false only for the
      // former.
      _deviceReached = e is! DeviceConnectionException;
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
      // without throwing, so the trailing bin is partial. Drop out of force mode
      // for the processing pass: finalizing here would promote a recording that
      // stops mid-audio and stamp it complete, when the rest of it is still on
      // the device. Kept as a draft it re-stitches with the resumed bytes.
      //
      // NB: what keeps the partial bin itself on disk is the incomplete-bin
      // filter in _runProcessing ([isProcessableBin]) — NOT draft mode. The
      // draft flush prunes its source bins too (consumeSafeToDeletePaths runs
      // after flushRemaining clears the refs), so draft-vs-finalize decides only
      // whether the recording is promoted. A clean Force Sync still finalizes.
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
      // The syncing stage already completed — resuming only processing.
      _deviceReached = true;
      unawaited(_runProcessing().whenComplete(() => _isUserTriggered = false));
    } else {
      unawaited(_runPipeline()); // _runPipeline manages _isUserTriggered itself
    }
  }

  void retryFromError() {
    if (_spState != SyncProcessState.error) return;
    if (_lastActiveStage == 'processing' && _lastCompletedStage == 'syncing') {
      _isUserTriggered = true;
      // The syncing stage already completed — retrying only processing.
      _deviceReached = true;
      unawaited(_runProcessing().whenComplete(() => _isUserTriggered = false));
    } else {
      unawaited(_runPipeline()); // _runPipeline manages _isUserTriggered itself
    }
  }

  Future<void> _runPipeline() async {
    final int gen = _pipelineGeneration;
    _isUserTriggered = true;
    _processAfterCancel = false;
    _deviceReached = false;
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
      _deviceReached = true;
      _prefs.lastSyncPartial = result?.isPartial ?? false;
      if (result == null) {
        Logger.debug('RecordingsController: syncAll returned null (no new segments)');
      }
    } catch (e) {
      // See _runForcePipeline: a connection-null throw = never reached the
      // device (skip); any other throw = connected but interrupted (partial).
      _deviceReached = e is! DeviceConnectionException;
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

  /// True unless [f] is a raw bin that already has a discard record, is still
  /// mid-transfer ([incomplete]), or (if [covered] is provided) is already
  /// covered by an existing recording. Mirrors the pipeline's filters so the
  /// displayed "minutes to process" and processing promotions match what will
  /// actually be processed.
  @visibleForTesting
  static bool isProcessableBin(File f, Set<String> discarded, [Set<String>? covered, Set<String>? incomplete]) {
    if (covered != null && covered.contains(f.path)) return false;
    final parts = f.path.split('/raw_segments/');
    if (parts.length != 2) return true;
    // An incompletely-transferred bin holds only a PREFIX of the recording.
    // Decoding it would cut a draft short of the real audio, and — because the
    // processing pass prunes every bin it consumes — delete the file the next
    // sync has to resume into. Leave it alone; it becomes processable once the
    // whole file has landed. See Wal.isIncompleteTransfer.
    if (incomplete != null && incomplete.contains(parts.last)) return false;
    return !discarded.contains(parts.last);
  }

  /// Bins still awaiting a resumed read — never safe to process or prune.
  ///
  /// [failClosed] governs what happens when the WAL state can't be read (a
  /// corrupt / half-written wals.json makes the sync layer throw). The pruning
  /// path (`_runProcessing`) passes true and rethrows: it must NOT prune when it
  /// can't tell which bins are still mid-download, or it re-opens the exact
  /// corruption this guards. Display/estimate call sites pass false — they only
  /// mis-size a "minutes to process" figure that self-corrects next cycle, so a
  /// transient read blip shouldn't stall them.
  static Future<Set<String>> _incompleteBins({bool failClosed = false}) async {
    try {
      return await ServiceManager.instance().wal.getSyncs().incompleteBinRelPaths();
    } catch (e) {
      Logger.error('RecordingsController: could not read incomplete-bin set: $e');
      if (failClosed) rethrow;
      return const {};
    }
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
    final Set<String> incompleteBins;
    try {
      // Fail closed: this pass PRUNES the bins it decodes, so an unreadable WAL
      // state must abort the run rather than let a mid-download bin be pruned.
      // wals.json is rewritten by every sync, so the next cycle self-heals.
      incompleteBins = await _incompleteBins(failClosed: true);
    } catch (e) {
      if (gen != _pipelineGeneration) return; // watchdog already recovered
      Logger.error('RecordingsController: skipping processing — incomplete-bin set unavailable: $e');
      _releaseWakelock();
      if (_isAppForeground()) _settleNotification();
      _transitionTo(SyncProcessState.idle);
      unawaited(reloadBatchesSilently());
      return;
    }

    final processableBatches = _batches.map((b) {
      final filtered =
          b.rawSegments.where((f) => isProcessableBin(f, discardedBins, coveredBins, incompleteBins)).toList();
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
      await _finishPipelineRun();
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
    await _finishPipelineRun();
  }

  /// Record the outcome of a finished pipeline run and settle the UI. When the
  /// device was reached this run, it's a real sync completion (Complete/Partial
  /// per [lastSyncPartial]) that stamps [lastSyncCompletedMs] and shows the
  /// success banner. When it was never reached — a manual sync while the Omi is
  /// out of range or Bluetooth is off — record a skip instead (mirroring the
  /// background auto-sync path): flag [lastSyncSkipped], stamp only
  /// [lastSyncStatusMs] so the notification reads "Last Sync: Skipped", leave
  /// [lastSyncCompletedMs] untouched (nothing was pulled), and settle straight
  /// to idle with no "complete" banner.
  Future<void> _finishPipelineRun() async {
    // Idempotent (Set-based) — the main processing path already released, but the
    // "nothing to process" early-return reaches here still holding it.
    _releaseWakelock();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_deviceReached) {
      _prefs.lastSyncSkipped = false;
      _prefs.lastSyncCompletedMs = now;
      _prefs.lastSyncStatusMs = now;
      await _finishSuccess();
      return;
    }
    _prefs.lastSyncSkipped = true;
    _prefs.lastSyncStatusMs = now;
    _isForcePipeline = false;
    _transitionTo(SyncProcessState.idle);
    if (_isAppForeground()) {
      _settleNotification();
    }
    unawaited(reloadBatchesSilently());
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
  /// behaviour) would promote a recording that stops mid-audio and stamp it
  /// complete while the rest is still on the device, so `_isForcePipeline` is
  /// cleared up front. The partial bin itself is held on disk by the
  /// incomplete-bin filter in [_runProcessing], not by draft mode.
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
      // Never reached the device (out of range / BT off) with nothing already on
      // disk: the intended outcome is a skip, not a sync error. The with-bins
      // path reaches _finishPipelineRun through _runProcessing and skips there;
      // do the same here so both cases read "Last Sync: Skipped" instead of one
      // skipping and the other popping an error banner.
      if (!_deviceReached) {
        await _finishPipelineRun();
        return;
      }
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
    // A syncing-phase stall is a transport wedge: the native link still reports
    // connected but GATT ops are dead (writes time out / return "Not found"), so the
    // pipeline can neither list nor read. Clearing our flags alone leaves that wedged
    // GATT in place — the next run just reports "no new segments" against it until a
    // write happens to throw. Recycle the connection (soft-disconnect → fresh GATT) so
    // the wedge actually clears. Processing-only stalls leave the link untouched.
    if (serviceIsSyncing) {
      unawaited(ServiceManager.instance().device.recycleConnection());
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
          await _incompleteBins(),
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
          await _incompleteBins(),
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
  Future<void> recoverDiscard(DiscardRecord d) => recoverDiscards([d]);

  /// Recovers each selected discard as its own standalone recording, then shows
  /// a SINGLE "Completed" banner at the end (rather than one ~10s banner per
  /// item). The busy-guard, list reload and banner-dismiss happen once for the
  /// whole batch; the per-item work runs in [_recoverDiscardCore].
  Future<void> recoverDiscards(List<DiscardRecord> ds) async {
    if (ds.isEmpty) return;
    // A just-finished sync/process leaves the "Completed" banner (successUi) up
    // for ~10s. That's a settled state, not a busy one — clear it so this runs
    // immediately instead of being silently dropped.
    if (_spState == SyncProcessState.successUi) dismissSuccess();
    if (isPipelineBusy) {
      Logger.debug('RecoverDiscard: SKIPPED — pipeline busy (spState=${_spState.name}, '
          'isProcessingAny=${RecordingsManager.isProcessingAny}).');
      return;
    }
    var anyRecovered = false;
    for (final d in ds) {
      // Defer the list reload: recovering N discards should refresh (and flash)
      // the list ONCE at the end, not once per item. Each core call still
      // removes its ghost's jsonl entry from disk, so the single reload below
      // reflects every removal.
      final recovered = await _recoverDiscardCore(d, reload: false);
      // A processAll failure leaves _spState at error — stop and keep that
      // banner, but still reload once so the ghosts already recovered this
      // batch disappear instead of lingering stale.
      if (_spState == SyncProcessState.error) {
        await _loadBatches();
        return;
      }
      anyRecovered = anyRecovered || recovered;
    }
    // Single reload for the whole batch (drops every recovered ghost / shows
    // every produced recording), then one success banner if anything recovered.
    await _loadBatches();
    if (anyRecovered) await _finishSuccess();
  }

  /// Recovers one discard. No busy-guard, no success banner — the caller owns
  /// those. Returns true if it produced a recording; false for an orphan (no
  /// bins) or a processAll failure (in which case _spState is left at error).
  /// Pass [reload] = false to skip the per-item list reload when recovering a
  /// batch — the caller reloads once at the end (avoids a flash per item).
  Future<bool> _recoverDiscardCore(DiscardRecord d, {bool reload = true}) async {
    final durMs = d.endTime.difference(d.startTime).inMilliseconds;
    Logger.debug('RecoverDiscard: requested — start=${d.startTime.toUtc()} reason=${d.reason} '
        'dur=${durMs}ms refBins=${d.relativeBins} ranges=${d.binRanges} spState=${_spState.name}');
    final directory = await getApplicationDocumentsDirectory();
    final bins = <File>[];
    // Maps each resolved absolute bin path back to its `<session>/<file>.bin`
    // tail, so binRanges/sibling lookups work regardless of whether the bin was
    // relocated to discarded_segments/ or is still in raw_segments/.
    final binRel = <String, String>{};
    final missing = <String>[];
    for (final rel in d.relativeBins) {
      final f = await RecordingsManager.resolveDiscardBin(directory.path, rel);
      if (await f.exists()) {
        bins.add(f);
        binRel[f.path] = rel;
      } else {
        missing.add(rel);
      }
    }
    if (missing.isNotEmpty) {
      Logger.debug('RecoverDiscard: WARNING — ${missing.length}/${d.relativeBins.length} '
          'referenced bin(s) missing on disk: $missing');
    }
    if (bins.isEmpty) {
      // Bins were already swept or deleted — drop the orphan record and reload.
      Logger.debug('RecoverDiscard: NO bins on disk — dropping ghost WITHOUT recovering audio '
          '(bins already deleted/swept; nothing to re-derive).');
      await RecordingsManager.removeDiscardRecord(d, deleteBins: false);
      if (reload) await _loadBatches();
      return false;
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
      priorityRecordCapMinutes: _prefs.priorityRecordMaxMinutes,
    );

    // Re-derive ONLY the discarded span, so recovery can't pull in the neighbor
    // recording sharing a ~5-min bin (the overlap bug). Slice every bin the
    // discard touches: the earliest bin's slice starts mid-bin so it anchors at
    // the discard's true start; later bins keep their bin-head time and stitch
    // onto the same recording. Requires every referenced bin present with a
    // recorded range — otherwise (a pruned bin, or a legacy record with no
    // ranges) fall back to the old whole-bin reprocess.
    final recoverSlices = <String, RecoverSlice>{};
    final allSliceable =
        bins.length == d.relativeBins.length && bins.every((f) => (d.binRanges[binRel[f.path]]?.isNotEmpty ?? false));
    if (allSliceable) {
      for (var i = 0; i < bins.length; i++) {
        final ranges = d.binRanges[binRel[bins[i].path]]!;
        recoverSlices[bins[i].path] = RecoverSlice(
          ranges: ranges,
          anchorMs: i == 0 ? d.startTime.millisecondsSinceEpoch : null,
        );
      }
      Logger.debug('RecoverDiscard: byte-slicing ${bins.length} bin(s), anchorMs='
          '${d.startTime.millisecondsSinceEpoch} — '
          '${recoverSlices.map((k, v) => MapEntry(k.split('/').last, v.ranges))}');
    } else {
      Logger.debug('RecoverDiscard: WHOLE-BIN fallback (a bin is missing or has no recorded '
          'byte range) — recovery decodes the entire bin(s) and MAY pull in neighbor audio. '
          'binsOnDisk=${bins.length} refBins=${d.relativeBins.length} ranges=${d.binRanges}');
    }

    // Protect bins that OTHER (sibling) discards still reference: two ghosts
    // routinely share one ~5-min bin (a head slice and a tail slice), and this
    // run consumes+deletes the bins it touches. Without this, recovering one
    // ghost deletes the shared bin and the sibling recovers as "NO bins on disk".
    final siblingRel = await RecordingsManager.discardedRelBinPathsExcludingSpan(
      d.startTime.millisecondsSinceEpoch,
      d.endTime.millisecondsSinceEpoch,
    );
    final protectedAbs = <String>{};
    for (final rel in siblingRel) {
      protectedAbs.add((await RecordingsManager.resolveDiscardBin(directory.path, rel)).path);
    }
    if (protectedAbs.isNotEmpty) {
      Logger.debug('RecoverDiscard: protecting ${protectedAbs.length} bin(s) referenced by sibling '
          'discard(s) from this run\'s delete sweep: ${siblingRel.toList()}');
    }

    _lastActiveStage = 'processing';
    _transitionTo(SyncProcessState.processing);
    try {
      await _manager.processAll(
        [syntheticBatch],
        (_, __) {},
        backgroundMode: false,
        settingsOverride: override,
        recoverSlices: recoverSlices,
        seedProtectedBinPaths: protectedAbs,
        // Finalize the recovered clip standalone — never as a draft that the
        // stitch pass would merge into an abutting recording.
        finalizeRemainingDirectly: true,
      );
    } catch (e) {
      Logger.debug('RecoverDiscard: processAll FAILED: $e');
      _transitionToError('processing', e.toString());
      return false;
    }
    // Bins are deleted by processAll's safe-to-delete pass; remove the stale
    // jsonl entry so the ghost disappears.
    await RecordingsManager.removeDiscardRecord(d, deleteBins: false);
    if (reload) await _loadBatches();
    Logger.debug('RecoverDiscard: DONE — processed ${bins.length} bin(s), ghost removed '
        '(start=${d.startTime.toUtc()}). Look for a recording near this time.');
    return true;
  }

  /// Drops [d] and its bins immediately. Used when the user decides the
  /// audio isn't worth recovering.
  Future<void> deleteDiscard(DiscardRecord d) async {
    await RecordingsManager.removeDiscardRecord(d, deleteBins: true);
    await _loadBatches();
  }

  String _dateString(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  // --- Upload subsystem (delegated to IntegrationUploadManager) -------------

  /// Enqueues every auto-eligible recording across all batches and kicks the
  /// per-integration upload workers.
  void tryAutoUploadAll() => _uploads.tryAutoUploadAll();

  /// Manual upload of [c] to every available integration. Returns failures
  /// (empty = ok). Throws if no upload key or wifi-gated without wifi.
  Future<List<UploadFailure>> uploadConversation(Conversation conversation, {bool force = false}) =>
      _uploads.uploadConversation(conversation, force: force);

  /// Manual upload of [c] to a single integration by name (per-row sheet action).
  Future<List<UploadFailure>> uploadOne(Conversation c, String integrationName, {bool force = false}) =>
      _uploads.uploadOne(c, integrationName, force: force);

  /// Per-integration upload status for [c] across all configured integrations.
  List<IntegrationStatus> integrationStatuses(Conversation c) => _uploads.integrationStatuses(c);

  /// Aggregate upload status for [c] (drives the row icon/badge).
  UploadStatus uploadStatus(Conversation c) => _uploads.uploadStatus(c);

  bool isUploaded(Conversation c) => _uploads.isUploaded(c);

  /// How many applicable integrations still need attention for [c].
  int actionableIntegrationCount(Conversation c) => _uploads.actionableIntegrationCount(c);

  void cancelOmiUploads({bool autoOnly = false}) => _uploads.cancelOmiUploads(autoOnly: autoOnly);

  void cancelHeyPocketUploads({bool autoOnly = false}) => _uploads.cancelHeyPocketUploads(autoOnly: autoOnly);

  /// Active uploads (in-flight + queued) for [integrationName] — see
  /// [IntegrationUploadManager.activeUploadCountFor].
  int activeUploadCountFor(String integrationName) => _uploads.activeUploadCountFor(integrationName);

  /// Whether [c]'s upload to [integrationName] is genuinely in-flight/queued and
  /// thus cancellable — see [IntegrationUploadManager.isCancellableUpload].
  bool isCancellableUpload(Conversation c, String integrationName) => _uploads.isCancellableUpload(c, integrationName);

  /// Whether [c]'s in-flight upload to [integrationName] has a cancel pending but
  /// hasn't bailed yet — see [IntegrationUploadManager.isCancellingUpload].
  bool isCancellingUpload(Conversation c, String integrationName) => _uploads.isCancellingUpload(c, integrationName);

  /// Cancels a single queued upload of [c] to [integrationName].
  void cancelUpload(Conversation c, String integrationName) => _uploads.cancelUpload(c, integrationName);

  /// Cancels every queued/in-flight upload for [integrationName].
  void cancelAllUploadsFor(String integrationName) => _uploads.cancelAllUploadsFor(integrationName);

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
  /// by [RecordingsManager.coveredBinPaths]. [incompleteBins] are those still
  /// awaiting a resumed read ([_incompleteBins]) — counting them here would
  /// promise minutes the pass deliberately leaves on disk.
  ({double toProcessMinutes, double draftMinutes, int unprocessedBins, DateTime? draftEndTime}) _computeAccumulated(
      List<Batch> batches, Set<String> discardedRelBins, Set<String> coveredBins,
      [Set<String>? incompleteBins]) {
    int rawBytes = 0;
    int unprocessedBinsCount = 0;
    for (final f in batches.expand((b) => b.rawSegments)) {
      if (!isProcessableBin(f, discardedRelBins, coveredBins, incompleteBins)) continue;

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
