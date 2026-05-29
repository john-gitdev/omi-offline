import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:omi/utils/audio/foreground.dart';

enum UploadStatus { none, partial, all, failed }

class UploadFailure {
  final String integration;
  final Object error;
  UploadFailure(this.integration, this.error);
}

class RecordingsController extends ChangeNotifier implements IWalSyncProgressListener {
  final RecordingsManager _manager = RecordingsManager();
  final _prefs = SharedPreferencesUtil();

  late final List<PassthroughIntegration> _integrations = [
    HeyPocketPassthroughIntegration(_prefs),
    OmiPassthroughIntegration(_prefs),
    // Add new integrations here.
  ];

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

  double _accumulatedMinutes = 0.0;
  double get accumulatedMinutes => _accumulatedMinutes;

  // Count of raw .bin files still waiting to be processed into the accumulated
  // draft (not yet finalized and not VAD-discarded). Surfaced in the banner so
  // the user can see there is synced audio that isn't reflected in the draft.
  int _unprocessedBinCount = 0;
  int get unprocessedBinCount => _unprocessedBinCount;

  String _lastCompletedStage = 'none';
  String get lastCompletedStage => _lastCompletedStage;

  String _lastActiveStage = 'syncing';
  String get lastActiveStage => _lastActiveStage;

  final Set<String> _uploadingFiles = {};
  Set<String> get uploadingFiles => _uploadingFiles;

  int _autoUploadActive = 0;
  String _lastHpKey = '';

  final Set<String> _syncingBinFiles = {};

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
  // syncing: per-packet progress fires ~50 Hz during a healthy transfer; the
  // only no-signal windows are list/delete/settle gaps (seconds). 60s of total
  // silence means the transfer is genuinely dead.
  static const _syncingStallTimeout = Duration(seconds: 60);
  // stopping: after a user cancel, teardown should be quick. The underlying
  // BLE awaits are timeout-bounded (≤65s) and acquireStorageLock has its own
  // 10s timeout, so force-clearing here is safe — a re-wedge surfaces as a
  // bounded error on the next sync, not a silent hang.
  static const _stoppingStallTimeout = Duration(seconds: 12);

  AppLifecycleState? _lastLifecycleState;

  /// Releases the foreground wakelock unless the user has pinned the screen on
  /// via the debug "Keep Screen On" toggle, in which case it stays held.
  void _releaseWakelock() {
    if (_prefs.keepScreenOn) return;
    WakelockPlus.disable();
  }

  void _throttledUpdate({bool force = false}) {
    if (_isDisposed) return;
    final now = DateTime.now();
    final state = WidgetsBinding.instance.lifecycleState;
    final isForeground = state == null || state == AppLifecycleState.resumed;
    final throttleMs = isForeground ? 1000 : 2000;

    if (!force && now.difference(_lastUiUpdate).inMilliseconds < throttleMs) return;
    _lastUiUpdate = now;
    _updateForegroundProgress();
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
    RecordingsManager.isTranscoding.addListener(_onTranscodingChanged);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    _forceSyncCooldownTimer?.cancel();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(null);
    RecordingsManager.recordingsChangeNotifier.removeListener(_onRecordingsChanged);
    RecordingsManager.processingProgress.removeListener(_onProgressChanged);
    RecordingsManager.isTranscoding.removeListener(_onTranscodingChanged);
    super.dispose();
  }

  void _onTranscodingChanged() {
    if (_isDisposed) return;
    _isTranscoding = RecordingsManager.isTranscoding.value;
    notifyListeners();
  }

  void _onProgressChanged() {
    if (_isDisposed) return;
    _lastProgressAt = DateTime.now();
    final progress = RecordingsManager.processingProgress.value;
    _processingProgress = progress;
    if (_spState == SyncProcessState.processing) {
      if (_totalMinutes > 0) {
        _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(0.0, _totalMinutes);
      }
      _throttledUpdate();
    }
  }

  void _updateForegroundProgress() {
    if (_spState == SyncProcessState.syncing) {
      final percent = _totalCount > 0 ? (_syncedCount / _totalCount * 100).toStringAsFixed(0) : '0';
      ForegroundUtil.updateNotification(
        text: 'Syncing recordings — $_syncedCount of $_totalCount segments ($percent%)',
      );
    } else if (_spState == SyncProcessState.processing) {
      final mins = _minutesRemaining.ceil();
      final text =
          mins > 0 ? 'Processing recordings — $mins min of audio left' : 'Processing recordings — <1 min of audio left';
      ForegroundUtil.updateNotification(text: text);
    }
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
        _totalCount = syncs.estimatedTotalSegments;
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

    if (isBackground && now.difference(_lastPollTime).inSeconds < 2) {
      return;
    }
    _lastPollTime = now;

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

    if (!_isUserTriggered) {
      if (serviceIsSyncing && (_spState == SyncProcessState.idle || _spState == SyncProcessState.processing)) {
        _spState = SyncProcessState.syncing;
        _lastProgressAt = now;
        _totalCount = syncs.estimatedTotalSegments;
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
            final processable = _batches.expand((b) => b.rawSegments).toList();
            final lengths = await Future.wait(processable.map((f) => f.length().catchError((_) => 0)));
            final totalBytes = lengths.fold(0, (s, len) => s + len);
            if (_isDisposed) return;
            _spState = SyncProcessState.processing;
            _totalMinutes = totalBytes / 252000.0;
            _minutesRemaining =
                (_totalMinutes * (1.0 - RecordingsManager.processingProgress.value)).clamp(0.0, _totalMinutes);
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
              final processable = _batches.expand((b) => b.rawSegments).toList();
              final lengths = await Future.wait(processable.map((f) => f.length().catchError((_) => 0)));
              final totalBytes = lengths.fold(0, (s, len) => s + len);
              if (_isDisposed) return;
              _spState = SyncProcessState.processing;
              _totalMinutes = totalBytes / 252000.0;
              _minutesRemaining =
                  (_totalMinutes * (1.0 - RecordingsManager.processingProgress.value)).clamp(0.0, _totalMinutes);
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
      if (currentKey.isNotEmpty) tryAutoUploadNext();
    }
  }

  void _transitionTo(SyncProcessState newState) {
    if (_isDisposed) return;
    _spState = newState;
    // Anchor the stall watchdog on entry to any active phase so it measures
    // time-since-progress, not time-since-app-start.
    if (newState == SyncProcessState.syncing || newState == SyncProcessState.stopping) {
      _lastProgressAt = DateTime.now();
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

    final currentEstimated = ServiceManager.instance().wal.getSyncs().recordingsCount;
    if (_totalCount <= 0 && currentEstimated > 0) {
      _totalCount = currentEstimated;
      Logger.debug(
        'RecordingsController: Backfilled totalCount from service: $_totalCount',
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
    _lastActiveStage = 'syncing';

    _totalCount = 0;
    _syncedCount = 0;
    _syncSpeed = 0.0;
    _transitionTo(SyncProcessState.syncing);

    final syncs = ServiceManager.instance().wal.getSyncs();
    notifyListeners();
    _persistProgress();
    WakelockPlus.enable();
    if (!await ForegroundUtil.isRunningService) {
      await ForegroundUtil.startForegroundTask(text: 'Syncing recordings — preparing...');
    } else {
      await ForegroundUtil.updateNotification(text: 'Syncing recordings — preparing...');
    }

    try {
      await syncs.rotateAndSync(progress: this);
    } catch (e) {
      if (gen != _pipelineGeneration) return; // watchdog already recovered
      _isUserTriggered = false;
      _isForcePipeline = false;
      _releaseWakelock();
      await ForegroundUtil.stopForegroundTask();
      if (_spState == SyncProcessState.stopping) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      } else {
        _transitionToError('syncing', e.toString());
      }
      return;
    }
    if (gen != _pipelineGeneration) return; // watchdog already recovered

    if (_spState == SyncProcessState.stopping) {
      _releaseWakelock();
      await ForegroundUtil.stopForegroundTask();
      _isForcePipeline = false;
      _transitionTo(SyncProcessState.idle);
      unawaited(reloadBatchesSilently());
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
    _lastActiveStage = 'syncing';

    final syncs = ServiceManager.instance().wal.getSyncs();
    _totalCount = syncs.estimatedTotalSegments;
    _syncedCount = 0;
    _syncSpeed = 0.0;

    _transitionTo(SyncProcessState.syncing);

    await Future.delayed(const Duration(seconds: 1));

    Logger.debug(
      'RecordingsController: _runPipeline start — estimatedTotalSegments=$_totalCount',
    );

    notifyListeners();
    _persistProgress();
    WakelockPlus.enable();
    if (!await ForegroundUtil.isRunningService) {
      await ForegroundUtil.startForegroundTask(text: 'Syncing recordings — preparing...');
    } else {
      await ForegroundUtil.updateNotification(text: 'Syncing recordings — preparing...');
    }

    try {
      final result = await syncs.syncAll(progress: this);
      if (result == null) {
        Logger.debug('RecordingsController: syncAll returned null (no new segments)');
      }
    } catch (e) {
      if (gen != _pipelineGeneration) return; // watchdog already recovered
      _isUserTriggered = false;
      _releaseWakelock();
      await ForegroundUtil.stopForegroundTask();
      if (_spState == SyncProcessState.stopping) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      } else {
        _transitionToError('syncing', e.toString());
      }
      return;
    }
    if (gen != _pipelineGeneration) return; // watchdog already recovered

    if (_spState == SyncProcessState.stopping) {
      _releaseWakelock();
      await ForegroundUtil.stopForegroundTask();
      _transitionTo(SyncProcessState.idle);
      unawaited(reloadBatchesSilently());
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

  Future<void> _runProcessing() async {
    final int gen = _pipelineGeneration;
    _lastActiveStage = 'processing';

    _totalMinutes = 0.0;
    _minutesRemaining = 0.0;
    _processingProgress = 0.0;

    _transitionTo(SyncProcessState.processing);

    final activeBatches = _batches.where((b) => b.rawSegments.isNotEmpty).toList();
    final hasDrafts = _batches.any((b) => b.draftRecordings.isNotEmpty);
    final hasMarkers = _batches.any((b) => b.markerTimestamps.isNotEmpty);

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
    _processingProgress = 0.0;
    notifyListeners();
    _persistProgress();

    WakelockPlus.enable();
    await ForegroundUtil.startForegroundTask(text: 'Processing recordings — preparing...');
    try {
      await _manager.processAll(
        _batches,
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
      await ForegroundUtil.stopForegroundTask();
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
      await ForegroundUtil.stopForegroundTask();
      _transitionTo(SyncProcessState.idle);
      unawaited(reloadBatchesSilently());
      return;
    }

    _releaseWakelock();
    await ForegroundUtil.stopForegroundTask();

    _minutesRemaining = 0;
    _lastCompletedStage = 'processing';
    notifyListeners();

    _persistProgress();
    await reloadBatchesSilently();
    _prefs.lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
    await _finishSuccess();
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
  }

  Future<void> _finishSuccess() async {
    _isForcePipeline = false;
    _transitionTo(SyncProcessState.successUi);
    await Future.delayed(const Duration(milliseconds: 10000));
    if (_isDisposed || _spState != SyncProcessState.successUi) return;

    dismissSuccess();
  }

  void cancelPipeline() {
    if (_spState != SyncProcessState.syncing && _spState != SyncProcessState.processing) return;
    Logger.debug(
      'RecordingsController: Cancel confirmed — cancelling sync + processing.',
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
    RecordingsManager.cancelProcessing();

    _isUserTriggered = false;
    _isForcePipeline = false;
    _syncedCount = 0;
    _totalCount = 0;
    _syncSpeed = 0.0;
    _minutesRemaining = 0;
    _processingProgress = 0.0;
    _totalMinutes = 0;
    _releaseWakelock();
    unawaited(ForegroundUtil.stopForegroundTask());
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
        final acc = _computeAccumulated(_batches);
        _accumulatedMinutes = acc.minutes;
        _unprocessedBinCount = acc.unprocessedBins;
        _checkCleanupFlag();
        notifyListeners();
        tryAutoUploadNext();
        tryAutoSyncNext();
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

        final acc = _computeAccumulated(_batches);
        _accumulatedMinutes = acc.minutes;
        _unprocessedBinCount = acc.unprocessedBins;
        _checkCleanupFlag();
        notifyListeners();
      }
    } catch (_) {}
  }

  void _checkCleanupFlag() {
    if (!_prefs.adjustmentMode && _prefs.adjustmentModeWasEnabled && _batches.every((b) => b.rawSegments.isEmpty)) {
      _prefs.adjustmentModeWasEnabled = false;
    }
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

  Future<void> deleteConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    final keys = conversations.map((c) => c.uploadKey).whereType<String>().toSet();
    await _prefs.removeUploadedFromHeypocket(keys);
    await _prefs.removeOmiSynced(_binPathsForConversations(conversations));
    final touchedSessionIds = conversations.map((c) => c.sessionId).whereType<int>().toSet();
    await RecordingsManager.deleteConversations(conversations);
    await _loadBatches();
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
        await _loadBatches();
      }
    }
  }

  int countShortRecordings(int minSeconds) =>
      _batches.expand((b) => b.finalizedRecordings).where((c) => c.duration.inSeconds < minSeconds).length;

  Future<void> deleteShortRecordings(int minSeconds) async {
    final toDelete =
        _batches.expand((b) => b.finalizedRecordings).where((c) => c.duration.inSeconds < minSeconds).toList();
    await deleteConversations(toDelete);
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

  Future<void> runAdjustmentCleanup() async {
    if (_spState != SyncProcessState.idle) return;
    final daysWithBins = _batches.where((b) => b.rawSegments.isNotEmpty).toList();
    if (daysWithBins.isEmpty) return;

    _lastActiveStage = 'processing';
    _transitionTo(SyncProcessState.processing);

    final unprocessed = daysWithBins.where((b) => b.finalizedRecordings.isEmpty).toList();
    if (unprocessed.isNotEmpty) {
      final totalBytes = unprocessed.expand((b) => b.rawSegments).fold(0, (sum, f) {
        try {
          return sum + f.lengthSync();
        } catch (_) {
          return sum;
        }
      });

      _totalMinutes = totalBytes / 252000.0;
      _minutesRemaining = _totalMinutes;
      _processingProgress = 0.0;
      notifyListeners();

      WakelockPlus.enable();
      await ForegroundUtil.startForegroundTask(text: 'Cleaning up recordings...');
      try {
        await _manager.processAll(unprocessed, (_, __) {}, backgroundMode: false);
      } catch (e) {
        _releaseWakelock();
        await ForegroundUtil.stopForegroundTask();
        _transitionToError('processing', e.toString());
        return;
      }
      _releaseWakelock();
      await ForegroundUtil.stopForegroundTask();
    }

    await RecordingsManager.deleteAllRawSegments();
    _prefs.adjustmentModeWasEnabled = false;

    _minutesRemaining = 0;
    _lastCompletedStage = 'processing';
    notifyListeners();

    _persistProgress();
    await reloadBatchesSilently();
    await _finishSuccess();
  }

  Future<void> reprocessDay(Batch batch) async {
    if (_spState != SyncProcessState.idle) return;

    // Surgical flag cleanup: only remove flags for recordings that belong to a
    // session for which we still have raw data (and thus will be deleted by reprocessDay).
    final availableSessionIds = batch.rawSegments
        .map((f) {
          final name = f.path.split('/').last.split('.').first;
          return int.tryParse(name.split('_').first);
        })
        .whereType<int>()
        .toSet();

    final reprocessable =
        batch.finalizedRecordings.where((c) => c.sessionId != null && availableSessionIds.contains(c.sessionId));

    final keys = reprocessable.map((c) => c.uploadKey).whereType<String>().toSet();
    await _prefs.removeUploadedFromHeypocket(keys);
    await _prefs.removeOmiSynced(_binPathsForConversations(reprocessable.toList()));

    await RecordingsManager.reprocessDay(batch);
    await _loadBatches();

    final freshBatch = _batches
        .where(
          (b) => b.dateString == batch.dateString && b.rawSegments.isNotEmpty,
        )
        .toList();
    if (freshBatch.isEmpty) return;

    final totalBytes = freshBatch.expand((b) => b.rawSegments).fold(0, (sum, f) {
      try {
        return sum + f.lengthSync();
      } catch (_) {
        return sum;
      }
    });

    _lastActiveStage = 'processing';
    _totalMinutes = totalBytes / 252000.0;
    _minutesRemaining = _totalMinutes;
    _processingProgress = 0.0;
    _transitionTo(SyncProcessState.processing);
    notifyListeners();

    WakelockPlus.enable();
    await ForegroundUtil.startForegroundTask(text: 'Reprocessing day...');
    try {
      await _manager.processAll(
        freshBatch,
        (_, __) {}, // global progress listener handles this
        backgroundMode: false,
        onRecordingFinalized: () {
          unawaited(reloadBatchesSilently());
        },
      );
    } catch (e) {
      _releaseWakelock();
      await ForegroundUtil.stopForegroundTask();
      _transitionToError('processing', e.toString());
      return;
    }
    _releaseWakelock();
    await ForegroundUtil.stopForegroundTask();
    await reloadBatchesSilently();
    await _finishSuccess();
  }

  /// Re-runs processing on the bins referenced by [d] with VAD bypassed so
  /// every frame is kept as one m4a. On success the discard record is
  /// removed and the recording appears in the day card; the user opens it
  /// in the player to decide whether it's worth keeping.
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
      discardShort: false,
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

  void tryAutoUploadNext() {
    if (_prefs.adjustmentMode && !_prefs.allowUploadDuringAdjustment) return;
    if (!_prefs.heypocketEnabled || _prefs.heypocketApiKey.isEmpty || !_prefs.heypocketAutoUpload) return;
    final apiKey = _prefs.heypocketApiKey;
    final keySetAt = _prefs.heypocketKeySetAt;
    final keySetTime = keySetAt > 0 ? DateTime.fromMillisecondsSinceEpoch(keySetAt) : null;
    final minDuration = _prefs.filterMinDurationSeconds;

    for (final batch in _batches) {
      for (final conversation in batch.finalizedRecordings) {
        if (_autoUploadActive >= 3) continue;
        if (conversation.passthrough) continue;
        if (keySetTime != null && conversation.startTime.isBefore(keySetTime)) continue;
        if (conversation.duration.inSeconds < minDuration) continue;
        final uploadKey = conversation.uploadKey;
        if (uploadKey == null) continue;
        if (_prefs.isUploadedToHeypocket(uploadKey)) continue;
        if (_prefs.getAutoUploadRetries(uploadKey) >= 3) continue;
        if (_uploadingFiles.contains(uploadKey)) continue;
        if (conversation.duration == Duration.zero || conversation.fileSizeBytes == 0) continue;

        _uploadingFiles.add(uploadKey);
        _autoUploadActive++;

        final isPassthrough = _prefs.passthroughMode;
        unawaited(
          HeyPocketService.uploadRecording(apiKey, conversation).then((_) async {
            await _prefs.markUploadedToHeypocket(uploadKey);
            await _prefs.clearAutoUploadRetry(uploadKey);
            if (isPassthrough) await _convertToPassthrough(conversation);
          }).catchError((e) {
            if (e is HeyPocketException && e.statusCode == 401) {
              _prefs.heypocketEnabled = false;
              _pendingSnackMessage = 'HeyPocket: API key revoked — update it in Integrations';
            } else {
              unawaited(_prefs.incrementAutoUploadRetry(uploadKey));
            }
            Logger.error('HeyPocket auto-upload failed: $e');
          }).whenComplete(() {
            _uploadingFiles.remove(uploadKey);
            _autoUploadActive--;
            if (!_isDisposed) {
              notifyListeners();
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => tryAutoUploadNext(),
              );
            }
          }),
        );
      }
    }
    if (!_isDisposed) notifyListeners();
  }

  Future<bool> _allIntegrationsDelivered(Conversation c, File binFile) async {
    for (final integration in _integrations) {
      if (integration.isEnabled(c)) {
        if (!await integration.hasDelivered(c, binFile)) {
          Logger.debug('Passthrough blocked by ${integration.runtimeType}');
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

      final ts = audioFileName.split('_').last.split('.').first;
      final binFile = File('$fileDir/recording_fs320_$ts.bin');

      if (!await _allIntegrationsDelivered(conversation, binFile)) return;

      // All enabled integrations have confirmed — safe to stamp and delete.
      final bytes = await metaFile.readAsBytes();
      bool alreadyPassthrough = false;
      if (bytes.length >= 417) {
        final keyLen = bytes[416];
        final flagOffset = 417 + keyLen;
        if (bytes.length > flagOffset) {
          alreadyPassthrough = (bytes[flagOffset] & 0x01) != 0;
        }
      }
      if (!alreadyPassthrough) {
        await metaFile.writeAsBytes([...bytes, 0x01]);
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
    final count = _syncingBinFiles.length;
    _syncingBinFiles.clear();
    Logger.debug('RecordingsController: Omi Cloud disabled — cleared $count in-progress sync(s)');
  }

  void cancelPendingHeyPocketUploads() {
    final count = _autoUploadActive;
    Logger.debug('RecordingsController: HeyPocket disabled — $count auto-upload(s) will drain and stop');
  }

  void tryAutoSyncNext() {
    if (_prefs.adjustmentMode && !_prefs.allowUploadDuringAdjustment) return;
    if (!_prefs.omiEnabled || _prefs.omiRefreshToken.isEmpty || !_prefs.omiAutoUpload) return;
    final minDuration = _prefs.filterMinDurationSeconds;

    for (final batch in _batches) {
      for (final conversation in batch.finalizedRecordings) {
        if (conversation.passthrough) continue;
        if (conversation.duration.inSeconds < minDuration) continue;
        final ts = conversation.file.path.split('/').last.split('_').last.split('.').first;
        final binPath = '${conversation.file.parent.path}/recording_fs320_$ts.bin';
        if (_prefs.isOmiSynced(binPath)) continue;
        if (_prefs.getAutoUploadRetries(binPath) >= 3) continue;
        if (_syncingBinFiles.contains(binPath)) continue;
        final binFile = File(binPath);
        if (!binFile.existsSync()) {
          Logger.debug('OmiAutoSync: bin missing for ${conversation.file.path.split('/').last}');
          continue;
        }

        Logger.debug('OmiAutoSync: uploading $binPath (${binFile.lengthSync()} bytes)');
        _syncingBinFiles.add(binPath);
        final isPassthrough = _prefs.passthroughMode;
        unawaited(
          OmiApiClient.syncLocalFiles([binFile]).then((result) async {
            if (result != null && result.success) {
              Logger.debug('OmiAutoSync: marked synced $binPath');
              await _prefs.markOmiSynced(binPath);
              await _prefs.clearAutoUploadRetry(binPath);
              if (isPassthrough) await _convertToPassthrough(conversation);
              unawaited(OmiApiClient.traceSyncResult(result));
            } else {
              Logger.error('OmiAutoSync: result success=false for $binPath: ${result?.status}');
              unawaited(_prefs.incrementAutoUploadRetry(binPath));
            }
          }).catchError((e) {
            if (e is OmiSyncException && e.isAuthError) {
              _prefs.omiEnabled = false;
              _pendingSnackMessage = 'Omi sync: credentials invalid — update them in Integrations';
            } else {
              unawaited(_prefs.incrementAutoUploadRetry(binPath));
            }
            Logger.error('Omi sync failed for $binPath: $e');
          }).whenComplete(() {
            _syncingBinFiles.remove(binPath);
            if (!_isDisposed) {
              WidgetsBinding.instance.addPostFrameCallback((_) => tryAutoSyncNext());
            }
          }),
        );
        return; // one at a time
      }
    }
  }

  Future<List<UploadFailure>> uploadConversation(Conversation conversation, {bool force = false}) async {
    if (_prefs.adjustmentMode && !_prefs.allowUploadDuringAdjustment) {
      throw Exception('Uploads paused — turn off Adjustment Mode first');
    }
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) throw Exception('Upload key unavailable');
    if (_uploadingFiles.contains(uploadKey)) return [];

    _uploadingFiles.add(uploadKey);
    notifyListeners();

    final List<UploadFailure> failures = [];

    try {
      final List<Future<void>> uploads = [];

      // HeyPocket
      if (_prefs.heypocketEnabled && _prefs.heypocketApiKey.isNotEmpty) {
        if (force || !_prefs.isUploadedToHeypocket(uploadKey)) {
          uploads.add(HeyPocketService.uploadRecording(_prefs.heypocketApiKey, conversation).then((_) {
            unawaited(_prefs.clearAutoUploadRetry(uploadKey));
            return _prefs.markUploadedToHeypocket(uploadKey);
          }).catchError((e) {
            Logger.error('HeyPocket manual upload failed: $e');
            failures.add(UploadFailure('HeyPocket', e));
          }));
        }
      }

      // Omi Cloud
      if (_prefs.omiEnabled && _prefs.omiRefreshToken.isNotEmpty) {
        final ts = conversation.file.path.split('/').last.split('_').last.split('.').first;
        final binPath = '${conversation.file.parent.path}/recording_fs320_$ts.bin';
        final binFile = File(binPath);
        final binExists = binFile.existsSync();
        final alreadySynced = _prefs.isOmiSynced(binPath);
        Logger.debug(
          'OmiUpload: binPath=$binPath exists=$binExists alreadySynced=$alreadySynced force=$force',
        );
        if (binExists && (force || !alreadySynced)) {
          Logger.debug('OmiUpload: starting upload (${binFile.lengthSync()} bytes)');
          uploads.add(OmiApiClient.syncLocalFiles([binFile]).then((result) async {
            if (result != null && result.success) {
              Logger.debug('OmiUpload: success, marking synced');
              await _prefs.clearAutoUploadRetry(binPath);
              await _prefs.markOmiSynced(binPath);
              unawaited(OmiApiClient.traceSyncResult(result));
            } else {
              throw Exception('Omi upload failed: ${result?.status}');
            }
          }).catchError((e) {
            Logger.error('Omi manual sync failed for $binPath: $e');
            failures.add(UploadFailure('Omi Cloud', e));
          }));
        } else if (!binExists) {
          Logger.error('OmiUpload: bin file missing — nothing to upload for ${conversation.file.path}');
          failures.add(UploadFailure('Omi Cloud', Exception('Binary file not found: $binPath')));
        }
      }

      if (uploads.isEmpty) {
        failures.add(UploadFailure('Integrations', Exception('No integrations enabled for upload')));
      } else {
        await Future.wait(uploads);
        if (failures.isEmpty && _prefs.passthroughMode) await _convertToPassthrough(conversation);
      }

      return failures;
    } finally {
      _uploadingFiles.remove(uploadKey);
      notifyListeners();
    }
  }

  UploadStatus uploadStatus(Conversation c) {
    final ts = c.file.path.split('/').last.split('_').last.split('.').first;
    final binPath = '${c.file.parent.path}/recording_fs320_$ts.bin';

    final hpEnabled = _prefs.heypocketEnabled && _prefs.heypocketApiKey.isNotEmpty && c.uploadKey != null;
    final omiEnabled = _prefs.omiEnabled && _prefs.omiRefreshToken.isNotEmpty;

    if (!hpEnabled && !omiEnabled) return UploadStatus.none;

    final hpDone = hpEnabled && _prefs.isUploadedToHeypocket(c.uploadKey!);
    final omiDone = omiEnabled && _prefs.isOmiSynced(binPath);
    final doneCnt = (hpDone ? 1 : 0) + (omiDone ? 1 : 0);
    final enabledCnt = (hpEnabled ? 1 : 0) + (omiEnabled ? 1 : 0);

    if (doneCnt == enabledCnt) return UploadStatus.all;

    final hpFailed = hpEnabled && !hpDone && _prefs.getAutoUploadRetries(c.uploadKey!) >= 3;
    final omiFailed = omiEnabled && !omiDone && _prefs.getAutoUploadRetries(binPath) >= 3;
    if (hpFailed || omiFailed) return UploadStatus.failed;

    if (doneCnt == 0) return UploadStatus.none;
    return UploadStatus.partial;
  }

  bool isUploaded(Conversation c) => uploadStatus(c) == UploadStatus.all;

  static Iterable<String> _binPathsForConversations(List<Conversation> conversations) => conversations.map((c) {
        final ts = c.file.path.split('/').last.split('_').last.split('.').first;
        return '${c.file.parent.path}/recording_fs320_$ts.bin';
      });

  ({double minutes, int unprocessedBins}) _computeAccumulated(List<Batch> batches) {
    final finalizedSessionIds =
        batches.expand((b) => b.finalizedRecordings).map((c) => c.sessionId).whereType<int>().toSet();

    // Bins that VAD has already examined and rejected (still on disk for the
    // 48h recovery window). They are no longer "waiting to finalize", so the
    // banner must not count them.
    final discardedRelBins = batches.expand((b) => b.discards).expand((d) => d.relativeBins).toSet();

    final Map<int, int> sessionRawBytes = {};
    int unknownRawBytes = 0;

    // Raw bins still on disk that aren't yet folded into the accumulated draft
    // (in normal mode, bins are deleted once processed into a draft, so any
    // remaining pending bin is genuinely unprocessed).
    int unprocessedBins = 0;

    for (final f in batches.expand((b) => b.rawSegments)) {
      final name = f.path.split('/').last;
      final parts = name.split('_');
      int? sid;
      if (parts.length > 1) {
        sid = int.tryParse(parts[1].split('.').first);
      }

      // If session is already finalized, its raw segments don't count towards "accumulated"
      if (sid != null && finalizedSessionIds.contains(sid)) continue;

      final pathParts = f.path.split('/raw_segments/');
      if (pathParts.length == 2 && discardedRelBins.contains(pathParts.last)) continue;

      try {
        final len = f.lengthSync();
        unprocessedBins++;
        if (sid != null) {
          sessionRawBytes[sid] = (sessionRawBytes[sid] ?? 0) + len;
        } else {
          unknownRawBytes += len;
        }
      } catch (_) {}
    }

    double totalMinutes = (unknownRawBytes / 252000.0);

    final Map<int, int> draftDurations = {};
    for (final c in batches.expand((b) => b.draftRecordings)) {
      if (c.sessionId != null) {
        draftDurations[c.sessionId!] = c.duration.inMilliseconds;
      } else {
        totalMinutes += (c.duration.inMilliseconds / 60000.0);
      }
    }

    final allPendingSids = {...sessionRawBytes.keys, ...draftDurations.keys};
    for (final sid in allPendingSids) {
      final rawMin = (sessionRawBytes[sid] ?? 0) / 252000.0;
      final draftMin = (draftDurations[sid] ?? 0) / 60000.0;

      if (_prefs.adjustmentMode) {
        // In adjustment mode, we take the max of raw vs draft to avoid double-counting
        // the same audio that exists both as a .bin and as a .m4a draft.
        totalMinutes += (rawMin > draftMin ? rawMin : draftMin);
      } else {
        // In normal mode, segments are deleted once processed into a draft,
        // so they are disjoint and should be summed.
        totalMinutes += (rawMin + draftMin);
      }
    }

    return (minutes: totalMinutes, unprocessedBins: unprocessedBins);
  }
}
