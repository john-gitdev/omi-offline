import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class RecordingsController extends ChangeNotifier implements IWalSyncProgressListener {
  final RecordingsManager _manager = RecordingsManager();
  final _prefs = SharedPreferencesUtil();

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

  double _minutesRemaining = 0.0;
  double get minutesRemaining => _minutesRemaining;

  double _totalMinutes = 0.0;
  double get totalMinutes => _totalMinutes;

  int _markerCount = 0;
  int get markerCount => _markerCount;

  double _syncSpeed = 0.0;
  double get syncSpeed => _syncSpeed;

  double _accumulatedMinutes = 0.0;
  double get accumulatedMinutes => _accumulatedMinutes;

  String _lastCompletedStage = 'none';
  String get lastCompletedStage => _lastCompletedStage;

  String _lastActiveStage = 'syncing';
  String get lastActiveStage => _lastActiveStage;

  final Set<String> _uploadingFiles = {};
  Set<String> get uploadingFiles => _uploadingFiles;

  int _autoUploadActive = 0;
  String _lastHpKey = '';

  String? _pendingSnackMessage;
  String? consumePendingSnack() {
    final msg = _pendingSnackMessage;
    _pendingSnackMessage = null;
    return msg;
  }

  Timer? _pollTimer;
  bool _isUserTriggered = false;
  Completer<void>? _pipelineCompleter;

  bool _isForcePipeline = false;
  bool get isForcePipeline => _isForcePipeline;

  bool _forceSyncOnCooldown = false;
  bool get forceSyncOnCooldown => _forceSyncOnCooldown;

  Timer? _forceSyncCooldownTimer;

  static const _kSpState = 'sp_state';
  static const _kSpSyncedCount = 'sp_synced_count';
  static const _kSpTotalCount = 'sp_total_count';
  static const _kSpMinutesRemaining = 'sp_minutes_remaining';
  static const _kSpMarkerCount = 'sp_marker_count';
  static const _kSpLastCompleted = 'sp_last_completed_stage';
  static const _kSpLastActive = 'sp_last_active_stage';

  bool _isDisposed = false;

  void init() {
    _lastHpKey = _prefs.heypocketApiKey;
    _restoreState();
    _loadBatches();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(this);
    RecordingsManager.recordingsChangeNotifier.addListener(_onRecordingsChanged);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    _forceSyncCooldownTimer?.cancel();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(null);
    RecordingsManager.recordingsChangeNotifier.removeListener(_onRecordingsChanged);
    super.dispose();
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
    _markerCount = _prefs.getInt(_kSpMarkerCount);
    _lastCompletedStage = _prefs.getString(_kSpLastCompleted, defaultValue: 'none');
    _lastActiveStage = _prefs.getString(_kSpLastActive, defaultValue: 'syncing');

    if (_spState == SyncProcessState.idle) {
      final syncs = ServiceManager.instance().wal.getSyncs();
      if (syncs.isSyncing) {
        _spState = SyncProcessState.syncing;
        _totalCount = syncs.estimatedTotalSegments;
      } else if (RecordingsManager.isProcessingAny) {
        _spState = SyncProcessState.processing;
      }
    }
    notifyListeners();
  }

  void _poll() {
    if (_isDisposed) return;

    final syncs = ServiceManager.instance().wal.getSyncs();
    final serviceIsSyncing = syncs.isSyncing;
    final serviceIsProcessing = RecordingsManager.isProcessingAny;

    if (_spState == SyncProcessState.stopping) {
      if (!serviceIsSyncing && !serviceIsProcessing) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      }
      _pollHeyPocket();
      return;
    }

    if (!_isUserTriggered) {
      if (serviceIsSyncing && _spState == SyncProcessState.idle) {
        _spState = SyncProcessState.syncing;
        _totalCount = syncs.estimatedTotalSegments;
        _syncedCount = 0;
        _syncSpeed = 0.0;
        notifyListeners();
      }

      if (serviceIsProcessing && _spState == SyncProcessState.idle) {
        _spState = SyncProcessState.processing;
        notifyListeners();
      }

      if (!serviceIsSyncing && _spState == SyncProcessState.syncing) {
        if (serviceIsProcessing) {
          unawaited(
            reloadBatchesSilently().then((_) async {
              if (_isDisposed) return;
              final processable = _batches.expand((b) => b.rawSegments).toList();
              final lengths = await Future.wait(processable.map((f) => f.length().catchError((_) => 0)));
              final totalBytes = lengths.fold(0, (s, len) => s + len);
              if (_isDisposed) return;
              _spState = SyncProcessState.processing;
              _totalMinutes = totalBytes / 252000.0;
              _minutesRemaining = _totalMinutes;
              _syncedCount = 0;
              _syncSpeed = 0.0;
              notifyListeners();
            }),
          );
        } else {
          _spState = SyncProcessState.idle;
          _syncedCount = 0;
          _totalCount = 0;
          _syncSpeed = 0.0;
          notifyListeners();
          unawaited(reloadBatchesSilently());
        }
      }

      if (!serviceIsProcessing && _spState == SyncProcessState.processing) {
        _spState = SyncProcessState.idle;
        _minutesRemaining = 0;
        _totalMinutes = 0;
        notifyListeners();
        _loadBatches();
      }
    }

    _pollHeyPocket();
  }

  void _pollHeyPocket() {
    final currentKey = _prefs.heypocketApiKey;
    if (currentKey != _lastHpKey) {
      _lastHpKey = currentKey;
      notifyListeners();
      if (currentKey.isNotEmpty) tryAutoUploadNext();
    }
  }

  void _transitionTo(SyncProcessState newState) {
    if (_isDisposed) return;
    _spState = newState;
    notifyListeners();

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
    Logger.error('RecordingsController: Pipeline error [$activeStage]: $message');
    _spState = SyncProcessState.error;
    notifyListeners();
    _prefs.saveString(_kSpState, 'error');
    _prefs.saveString(_kSpLastActive, activeStage);
    _pipelineCompleter?.complete();
    _pipelineCompleter = null;
  }

  void _persistProgress() {
    _prefs.saveInt(_kSpSyncedCount, _syncedCount);
    _prefs.saveInt(_kSpTotalCount, _totalCount);
    _prefs.saveDouble(_kSpMinutesRemaining, _minutesRemaining);
    _prefs.saveInt(_kSpMarkerCount, _markerCount);
  }

  @override
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase}) {
    if (_isDisposed) return;
    _syncSpeed = speedKBps ?? 0.0;
    
    final currentEstimated = ServiceManager.instance().wal.getSyncs().recordingsCount;
    if (_totalCount <= 0 && currentEstimated > 0) {
      _totalCount = currentEstimated;
      Logger.debug('RecordingsController: Backfilled totalCount from service: $_totalCount');
    }

    if (_totalCount > 0) {
      _syncedCount = (percentage * _totalCount).round().clamp(0, _totalCount);
    } else {
      _syncedCount = 0;
    }
    notifyListeners();
  }

  Future<void> startPipeline() async {
    if (_spState != SyncProcessState.idle) return;
    _poll();
    if (_spState != SyncProcessState.idle) return;
    
    _pipelineCompleter = Completer<void>();
    unawaited(_runPipeline());
    return _pipelineCompleter?.future;
  }

  Future<void> startForcePipeline() async {
    if (_spState != SyncProcessState.idle) return;
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
    _isUserTriggered = true;
    _isForcePipeline = true;
    _lastActiveStage = 'syncing';
    _transitionTo(SyncProcessState.syncing);

    final syncs = ServiceManager.instance().wal.getSyncs();
    _totalCount = 0;
    _syncedCount = 0;
    _syncSpeed = 0.0;
    notifyListeners();
    _persistProgress();
    WakelockPlus.enable();

    try {
      await syncs.rotateAndSync(progress: this);
    } catch (e) {
      _isUserTriggered = false;
      _isForcePipeline = false;
      WakelockPlus.disable();
      if (_spState == SyncProcessState.stopping) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      } else {
        _transitionToError('syncing', e.toString());
      }
      return;
    }
    WakelockPlus.disable();

    if (_spState == SyncProcessState.stopping) {
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
    
    _markerCount = _batches.fold(0, (sum, b) => sum + b.markerTimestamps.length);
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
    _isUserTriggered = true;
    _lastActiveStage = 'syncing';
    _transitionTo(SyncProcessState.syncing);

    await Future.delayed(const Duration(seconds: 1));

    final syncs = ServiceManager.instance().wal.getSyncs();
    final estimatedTotal = syncs.estimatedTotalSegments;
    Logger.debug('RecordingsController: _runPipeline start — estimatedTotalSegments=$estimatedTotal');
    
    _totalCount = estimatedTotal;
    _syncedCount = 0;
    _syncSpeed = 0.0;
    notifyListeners();
    _persistProgress();
    WakelockPlus.enable();

    try {
      final result = await syncs.syncAll(progress: this);
      if (result == null) {
        _isUserTriggered = false;
        WakelockPlus.disable();
        _transitionTo(SyncProcessState.idle);
        return;
      }
    } catch (e) {
      _isUserTriggered = false;
      WakelockPlus.disable();
      if (_spState == SyncProcessState.stopping) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      } else {
        _transitionToError('syncing', e.toString());
      }
      return;
    }
    WakelockPlus.disable();

    if (_spState == SyncProcessState.stopping) {
      _transitionTo(SyncProcessState.idle);
      unawaited(reloadBatchesSilently());
      return;
    }

    _syncedCount = _totalCount;
    _lastCompletedStage = 'syncing';
    notifyListeners();
    
    _prefs.saveString(_kSpLastCompleted, 'syncing');
    await reloadBatchesSilently();
    
    _markerCount = _batches.fold(0, (sum, b) => sum + b.markerTimestamps.length);
    notifyListeners();
    _persistProgress();

    await _runProcessing();
    _isUserTriggered = false;
  }

  Future<void> _runProcessing() async {
    _lastActiveStage = 'processing';
    _transitionTo(SyncProcessState.processing);

    final activeBatches = _batches.where((b) => b.rawSegments.isNotEmpty).toList();
    if (activeBatches.isEmpty) {
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
    notifyListeners();
    _persistProgress();

    WakelockPlus.enable();
    try {
      await _manager.processAll(
        activeBatches,
        (progress) {
          if (!_isDisposed) {
            _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(0.0, _totalMinutes);
            notifyListeners();
          }
        },
        backgroundMode: backgroundMode,
        onRecordingFinalized: () {
          unawaited(reloadBatchesSilently());
        },
      );
    } catch (e) {
      WakelockPlus.disable();
      if (_spState == SyncProcessState.stopping) {
        _transitionTo(SyncProcessState.idle);
        unawaited(reloadBatchesSilently());
      } else {
        _transitionToError('processing', e.toString());
      }
      return;
    }
    WakelockPlus.disable();

    if (_spState == SyncProcessState.stopping) {
      _transitionTo(SyncProcessState.idle);
      unawaited(reloadBatchesSilently());
      return;
    }

    _minutesRemaining = 0;
    _lastCompletedStage = 'processing';
    notifyListeners();
    
    _persistProgress();
    await reloadBatchesSilently();
    await _finishSuccess();
  }

  Future<void> _finishSuccess() async {
    _isForcePipeline = false;
    _transitionTo(SyncProcessState.successUi);
    await Future.delayed(const Duration(milliseconds: 10000));
    if (_isDisposed) return;
    
    _lastCompletedStage = 'none';
    _syncedCount = 0;
    _totalCount = 0;
    _markerCount = 0;
    _minutesRemaining = 0;
    _totalMinutes = 0;
    notifyListeners();
    
    _prefs.saveString(_kSpLastCompleted, 'none');
    _persistProgress();
    _transitionTo(SyncProcessState.idle);
    _loadBatches();
  }

  void cancelPipeline() {
    if (_spState != SyncProcessState.syncing && _spState != SyncProcessState.processing) return;
    Logger.debug('RecordingsController: Cancel confirmed — cancelling sync + processing.');
    _transitionTo(SyncProcessState.stopping);
    ServiceManager.instance().wal.getSyncs().cancelSync();
    RecordingsManager.cancelProcessing();
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
        _isLoading = false;
        _accumulatedMinutes = _computeAccumulatedMinutes(_batches);
        notifyListeners();
        tryAutoUploadNext();
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
        _accumulatedMinutes = _computeAccumulatedMinutes(_batches);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> deleteDay(Batch batch) async {
    await _manager.deleteDay(batch);
    await _loadBatches();
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
        try { return sum + f.lengthSync(); } catch (_) { return sum; }
      });
      
      _totalMinutes = totalBytes / 252000.0;
      _minutesRemaining = _totalMinutes;
      notifyListeners();
      
      WakelockPlus.enable();
      try {
        await _manager.processAll(unprocessed, (progress) {
          if (!_isDisposed) {
            _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(0.0, _totalMinutes);
            notifyListeners();
          }
        }, backgroundMode: false);
      } catch (e) {
        WakelockPlus.disable();
        _transitionToError('processing', e.toString());
        return;
      }
      WakelockPlus.disable();
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
    
    await RecordingsManager.reprocessDay(batch);
    await _loadBatches();

    final freshBatch = _batches.where((b) => b.dateString == batch.dateString && b.rawSegments.isNotEmpty).toList();
    if (freshBatch.isEmpty) return;

    final totalBytes = freshBatch.expand((b) => b.rawSegments).fold(0, (sum, f) {
      try { return sum + f.lengthSync(); } catch (_) { return sum; }
    });
    
    _lastActiveStage = 'processing';
    _totalMinutes = totalBytes / 252000.0;
    _minutesRemaining = _totalMinutes;
    _transitionTo(SyncProcessState.processing);
    notifyListeners();
    
    WakelockPlus.enable();
    try {
      await _manager.processAll(
        freshBatch,
        (progress) {
          if (!_isDisposed) {
            _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(0.0, _totalMinutes);
            notifyListeners();
          }
        },
        backgroundMode: false,
        onRecordingFinalized: () { unawaited(reloadBatchesSilently()); },
      );
    } catch (e) {
      WakelockPlus.disable();
      _transitionToError('processing', e.toString());
      return;
    }
    WakelockPlus.disable();
    await reloadBatchesSilently();
    await _finishSuccess();
  }

  void tryAutoUploadNext() {
    if (!_prefs.heypocketEnabled || _prefs.heypocketApiKey.isEmpty) return;
    final apiKey = _prefs.heypocketApiKey;
    final keySetAt = _prefs.heypocketKeySetAt;
    final keySetTime = keySetAt > 0 ? DateTime.fromMillisecondsSinceEpoch(keySetAt) : null;
    
    for (final batch in _batches) {
      for (final conversation in batch.finalizedRecordings) {
        if (_autoUploadActive >= 3) continue;
        if (keySetTime != null && conversation.startTime.isBefore(keySetTime)) continue;
        final uploadKey = conversation.uploadKey;
        if (uploadKey == null) continue;
        if (_prefs.isUploadedToHeypocket(uploadKey)) continue;
        if (_uploadingFiles.contains(uploadKey)) continue;
        if (conversation.duration == Duration.zero || conversation.fileSizeBytes == 0) continue;

        _uploadingFiles.add(uploadKey);
        _autoUploadActive++;

        unawaited(
          HeyPocketService.uploadRecording(apiKey, conversation)
              .then((_) async {
                await _prefs.markUploadedToHeypocket(uploadKey);
              })
              .catchError((e) {
                if (e is HeyPocketException && e.statusCode == 401) {
                  _prefs.heypocketEnabled = false;
                  _pendingSnackMessage = 'HeyPocket: API key revoked — update it in Integrations';
                }
                Logger.error('HeyPocket auto-upload failed: $e');
              })
              .whenComplete(() {
                _uploadingFiles.remove(uploadKey);
                _autoUploadActive--;
                if (!_isDisposed) {
                  notifyListeners();
                  WidgetsBinding.instance.addPostFrameCallback((_) => tryAutoUploadNext());
                }
              }),
        );
      }
    }
    if (!_isDisposed) notifyListeners();
  }

  Future<void> uploadConversation(Conversation conversation) async {
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) throw Exception('Upload key unavailable');
    if (_uploadingFiles.contains(uploadKey)) return;

    final apiKey = _prefs.heypocketApiKey;
    _uploadingFiles.add(uploadKey);
    notifyListeners();

    try {
      await HeyPocketService.uploadRecording(apiKey, conversation);
      await _prefs.markUploadedToHeypocket(uploadKey);
    } finally {
      _uploadingFiles.remove(uploadKey);
      notifyListeners();
    }
  }

  static double _computeAccumulatedMinutes(List<Batch> batches) {
    final totalBytes = batches.expand((b) => b.rawSegments).fold<int>(0, (sum, f) {
      try {
        return sum + f.lengthSync();
      } catch (_) {
        return sum;
      }
    });
    return totalBytes / 252000.0;
  }
}
