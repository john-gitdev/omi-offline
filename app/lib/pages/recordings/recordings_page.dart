import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:omi/utils/logger.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/pages/settings/settings_drawer.dart';
import 'package:omi/pages/settings/find_devices_page.dart';
import 'package:omi/pages/settings/device_settings.dart';
import 'package:omi/pages/recordings/recording_player_page.dart';
import 'package:omi/pages/recordings/marker_conversation_player_page.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:omi/widgets/battery_status_indicator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ─── State machine ──────────────────────────────────────────────────────────
enum SyncProcessState {
  idle,
  syncing,
  processing,
  stopping,
  resume,
  error,
  successUi,
}

// ─── Page ───────────────────────────────────────────────────────────────────
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage>
    implements IWalSyncProgressListener {
  final RecordingsManager _manager = RecordingsManager();
  final _prefs = SharedPreferencesUtil();

  // ─── Batch data ────────────────────────────────────────────────────────────
  List<Batch> _batches = [];
  List<MarkerConversation> _markerConversations = [];
  bool _isLoading = true;
  bool _showMarkersOnly = false;
  int _minFilterSeconds = 0; // 0 = no filter

  // ─── Unified sync+process state ────────────────────────────────────────────
  SyncProcessState _spState = SyncProcessState.idle;
  int _syncedCount = 0;
  int _totalCount = 0;
  double _minutesRemaining = 0.0;
  double _totalMinutes = 0.0;
  int _markerCount = 0;
  double _syncSpeed = 0.0;
  double _accumulatedMinutes =
      0.0; // raw audio on disk not yet turned into a recording
  String _lastCompletedStage = 'none'; // "none" | "syncing" | "processing"
  String _lastActiveStage = 'syncing'; // "syncing" | "processing"
  // ─── HeyPocket upload state ────────────────────────────────────────────────
  final Set<String> _uploadingFiles = {};
  int _autoUploadActive = 0;
  String _lastHpKey = '';

  Timer? _pollTimer;
  bool _isUserTriggered =
      false; // true while user-initiated pipeline is running
  Completer<void>?
  _pipelineCompleter; // completed when the pipeline reaches a terminal state

  // ─── Force sync state ──────────────────────────────────────────────────────
  bool _isForcePipeline =
      false; // true while a force-sync-initiated pipeline is running
  bool _forceSyncOnCooldown =
      false; // true for 1 min after the button is pressed
  Timer? _forceSyncCooldownTimer;

  // ─── Persistence keys ──────────────────────────────────────────────────────
  static const _kSpState = 'sp_state';
  static const _kSpSyncedCount = 'sp_synced_count';
  static const _kSpTotalCount = 'sp_total_count';
  static const _kSpMinutesRemaining = 'sp_minutes_remaining';
  static const _kSpMarkerCount = 'sp_marker_count';
  static const _kSpLastCompleted = 'sp_last_completed_stage';
  static const _kSpLastActive = 'sp_last_active_stage';

  // ─── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _lastHpKey = _prefs.heypocketApiKey;
    _restoreState();
    _loadBatches();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(this);
    RecordingsManager.recordingsChangeNotifier.addListener(
      _onRecordingsChanged,
    );
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _poll(),
    );
  }

  void _onRecordingsChanged() {
    if (mounted) {
      _restoreState();
      _loadBatches();
    }
  }

  void _restoreState() {
    final saved = _prefs.getString(_kSpState, defaultValue: 'idle');
    // Disable auto-resume for debugging as requested.
    if (saved == 'error') {
      _spState = SyncProcessState.error;
    } else {
      _spState = SyncProcessState.idle;
    }
    _syncedCount = _prefs.getInt(_kSpSyncedCount);
    _totalCount = _prefs.getInt(_kSpTotalCount);
    _minutesRemaining = _prefs.getDouble(_kSpMinutesRemaining);
    _markerCount = _prefs.getInt(_kSpMarkerCount);
    _lastCompletedStage = _prefs.getString(
      _kSpLastCompleted,
      defaultValue: 'none',
    );
    _lastActiveStage = _prefs.getString(
      _kSpLastActive,
      defaultValue: 'syncing',
    );

    // Cold-start: if a background job is already running when the page opens,
    // reflect it immediately rather than waiting for the first poll tick.
    if (_spState == SyncProcessState.idle) {
      final syncs = ServiceManager.instance().wal.getSyncs();
      if (syncs.isSyncing) {
        _spState = SyncProcessState.syncing;
        _totalCount = syncs.estimatedTotalSegments;
      } else if (RecordingsManager.isProcessingAny) {
        _spState = SyncProcessState.processing;
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _forceSyncCooldownTimer?.cancel();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(null);
    RecordingsManager.recordingsChangeNotifier.removeListener(
      _onRecordingsChanged,
    );
    super.dispose();
  }

  // ─── Poll ──────────────────────────────────────────────────────────────────
  void _poll() {
    if (!mounted) return;

    final syncs = ServiceManager.instance().wal.getSyncs();
    final serviceIsSyncing = syncs.isSyncing;
    final serviceIsProcessing = RecordingsManager.isProcessingAny;

    // Safety net: STOPPING → IDLE once underlying ops stop.
    if (_spState == SyncProcessState.stopping) {
      if (!serviceIsSyncing && !serviceIsProcessing) {
        _transitionTo(SyncProcessState.idle);
        unawaited(_reloadBatchesSilently());
      }
      _pollHeyPocket();
      return;
    }

    if (!_isUserTriggered) {
      // ── Background sync started ──────────────────────────────────────────
      if (serviceIsSyncing && _spState == SyncProcessState.idle) {
        setState(() {
          _spState = SyncProcessState.syncing;
          _totalCount = syncs.estimatedTotalSegments;
          _syncedCount = 0;
          _syncSpeed = 0.0;
        });
      }

      // ── Background processing started (without prior sync) ──────────────
      if (serviceIsProcessing && _spState == SyncProcessState.idle) {
        setState(() => _spState = SyncProcessState.processing);
      }

      // ── Background sync finished ─────────────────────────────────────────
      if (!serviceIsSyncing && _spState == SyncProcessState.syncing) {
        if (serviceIsProcessing) {
          // Background processing auto-started after sync — show it.
          unawaited(
            _reloadBatchesSilently().then((_) async {
              if (!mounted) return;
              final allRaw = _batches.expand((b) => b.rawSegments).toList();
              final processable =
                  RecordingsManager.excludeNewestSegmentPerSession(allRaw);
              final lengths = await Future.wait(
                processable.map((f) => f.length().catchError((_) => 0)),
              );
              final totalBytes = lengths.fold(0, (s, len) => s + len);
              if (!mounted) return;
              setState(() {
                _spState = SyncProcessState.processing;
                _totalMinutes =
                    totalBytes /
                    252000.0; // segment on-disk: 4-byte prefix + ~80 B Opus = ~84 B/frame × 50 fps × 60 s
                _minutesRemaining = _totalMinutes;
                _syncedCount = 0;
                _syncSpeed = 0.0;
              });
            }),
          );
        } else {
          setState(() {
            _spState = SyncProcessState.idle;
            _syncedCount = 0;
            _totalCount = 0;
            _syncSpeed = 0.0;
          });
          unawaited(_reloadBatchesSilently());
        }
      }

      // ── Background processing finished ───────────────────────────────────
      if (!serviceIsProcessing && _spState == SyncProcessState.processing) {
        setState(() {
          _spState = SyncProcessState.idle;
          _minutesRemaining = 0;
          _totalMinutes = 0;
        });
        _loadBatches();
      }
    }

    _pollHeyPocket();
  }

  void _pollHeyPocket() {
    final currentKey = _prefs.heypocketApiKey;
    if (currentKey != _lastHpKey) {
      _lastHpKey = currentKey;
      setState(() {});
      if (currentKey.isNotEmpty) _tryAutoUploadNext();
    }
  }

  // ─── State transitions ─────────────────────────────────────────────────────
  void _transitionTo(SyncProcessState newState) {
    if (!mounted) return;
    setState(() => _spState = newState);
    // Don't persist transient SUCCESS_UI; it reverts to idle automatically.
    if (newState != SyncProcessState.successUi) {
      _prefs.saveString(_kSpState, newState.name);
    }
    _prefs.saveString(_kSpLastCompleted, _lastCompletedStage);
    _prefs.saveString(_kSpLastActive, _lastActiveStage);
    // Complete the refresh-indicator future when the pipeline reaches a terminal state.
    if (newState == SyncProcessState.idle ||
        newState == SyncProcessState.error ||
        newState == SyncProcessState.successUi) {
      _pipelineCompleter?.complete();
      _pipelineCompleter = null;
    }
  }

  void _transitionToError(String activeStage, String message) {
    if (!mounted) return;
    _isForcePipeline = false;
    _lastActiveStage = activeStage;
    Logger.error('RecordingsPage: Pipeline error [$activeStage]: $message');
    setState(() => _spState = SyncProcessState.error);
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

  // ─── IWalSyncProgressListener ──────────────────────────────────────────────
  @override
  void onWalSyncedProgress(
    double percentage, {
    double? speedKBps,
    SyncPhase? phase,
  }) {
    if (!mounted) return;
    setState(() {
      _syncSpeed = speedKBps ?? 0.0;
      // If _totalCount is 0 or mismatched (WAL list wasn't populated yet),
      // refresh it from estimatedTotalSegments now that syncAll/listFiles has progressed.
      final currentEstimated = ServiceManager.instance().wal
          .getSyncs()
          .recordingsCount;
      if (_totalCount <= 0 && currentEstimated > 0) {
        _totalCount = currentEstimated;
        Logger.debug(
          'RecordingsPage: Backfilled totalCount from service: $_totalCount',
        );
      }

      if (_totalCount > 0) {
        _syncedCount = (percentage * _totalCount).round().clamp(0, _totalCount);
      } else {
        _syncedCount = 0;
      }
    });
  }

  // ─── Pipeline entry points ─────────────────────────────────────────────────
  void _startPipeline() {
    if (_spState != SyncProcessState.idle) return;
    _poll(); // flush any background ops the 500ms timer hasn't caught yet
    if (_spState != SyncProcessState.idle) return;
    unawaited(_runPipeline());
  }

  Future<void> _forceSyncButtonPressed() async {
    if (_spState != SyncProcessState.idle) return;
    if (_forceSyncOnCooldown) return;

    final skipConfirm = _prefs.forceSyncSkipConfirm;
    if (!skipConfirm) {
      bool doNotShowAgain = false;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            title: const Text(
              'Force Sync',
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This will close the current recording segment and immediately sync all available data, including recordings shorter than the usual minimum.',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () =>
                      setDialogState(() => doNotShowAgain = !doNotShowAgain),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: doNotShowAgain,
                          onChanged: (v) =>
                              setDialogState(() => doNotShowAgain = v ?? false),
                          activeColor: Colors.deepPurpleAccent,
                          side: const BorderSide(color: Colors.grey),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Don\'t show again',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text(
                  'Yes',
                  style: TextStyle(color: Colors.deepPurpleAccent),
                ),
              ),
            ],
          ),
        ),
      );
      if (confirm != true) return;
      if (doNotShowAgain) _prefs.forceSyncSkipConfirm = true;
    }

    // Start cooldown the moment the user confirms
    setState(() => _forceSyncOnCooldown = true);
    _forceSyncCooldownTimer?.cancel();
    _forceSyncCooldownTimer = Timer(const Duration(minutes: 1), () {
      if (mounted) setState(() => _forceSyncOnCooldown = false);
    });

    unawaited(_runForcePipeline());
  }

  Future<void> _runForcePipeline() async {
    _isUserTriggered = true;
    _isForcePipeline = true;
    _lastActiveStage = 'syncing';
    _transitionTo(SyncProcessState.syncing);

    final syncs = ServiceManager.instance().wal.getSyncs();
    setState(() {
      _totalCount =
          0; // will be backfilled by onWalSyncedProgress after rotation+list
      _syncedCount = 0;
      _syncSpeed = 0.0;
    });
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
        unawaited(_reloadBatchesSilently());
      } else {
        _transitionToError('syncing', e.toString());
      }
      return;
    }
    WakelockPlus.disable();

    if (_spState == SyncProcessState.stopping) {
      _isForcePipeline = false;
      _transitionTo(SyncProcessState.idle);
      unawaited(_reloadBatchesSilently());
      return;
    }

    setState(() {
      _syncedCount = _totalCount;
      _lastCompletedStage = 'syncing';
    });
    _prefs.saveString(_kSpLastCompleted, 'syncing');
    await _reloadBatchesSilently();
    setState(() {
      _markerCount = _batches.fold(
        0,
        (sum, b) => sum + b.markerTimestamps.length,
      );
    });
    _persistProgress();

    await _runProcessing();
    _isUserTriggered = false;
  }

  void _resumePipeline() {
    if (_spState != SyncProcessState.resume) return;
    if (_lastCompletedStage == 'syncing') {
      unawaited(_runProcessing());
    } else {
      unawaited(_runPipeline());
    }
  }

  void _retryFromError() {
    if (_spState != SyncProcessState.error) return;
    if (_lastActiveStage == 'processing' && _lastCompletedStage == 'syncing') {
      unawaited(_runProcessing());
    } else {
      unawaited(_runPipeline());
    }
  }

  // ─── Pipeline stages ───────────────────────────────────────────────────────
  Future<void> _runPipeline() async {
    _isUserTriggered = true;
    _lastActiveStage = 'syncing';
    _transitionTo(SyncProcessState.syncing);

    // Give the firmware 1s to settle its internal file list cache before we start requesting reads
    await Future.delayed(const Duration(seconds: 1));

    final syncs = ServiceManager.instance().wal.getSyncs();
    final estimatedTotal = syncs.estimatedTotalSegments;
    Logger.debug(
      'RecordingsPage: _runPipeline start — estimatedTotalSegments=$estimatedTotal',
    );
    setState(() {
      _totalCount = estimatedTotal;
      _syncedCount = 0;
      _syncSpeed = 0.0;
    });
    _persistProgress();
    WakelockPlus.enable();

    try {
      final result = await syncs.syncAll(progress: this);
      if (result == null) {
        // Background sync was already running — our call was a no-op.
        // Don't fall through to processing; let the background pipeline finish.
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
        unawaited(_reloadBatchesSilently());
      } else {
        _transitionToError('syncing', e.toString());
      }
      return;
    }
    WakelockPlus.disable();

    if (_spState == SyncProcessState.stopping) {
      _transitionTo(SyncProcessState.idle);
      unawaited(_reloadBatchesSilently());
      return;
    }

    // Sync complete — mark and gather markers
    setState(() {
      _syncedCount = _totalCount;
      _lastCompletedStage = 'syncing';
    });
    _prefs.saveString(_kSpLastCompleted, 'syncing');
    await _reloadBatchesSilently();
    setState(() {
      _markerCount = _batches.fold(
        0,
        (sum, b) => sum + b.markerTimestamps.length,
      );
    });
    _persistProgress();

    await _runProcessing();
    _isUserTriggered = false;
  }

  Future<void> _runProcessing() async {
    _lastActiveStage = 'processing';
    _transitionTo(SyncProcessState.processing);

    final activeBatches = _batches
        .where((b) => b.rawSegments.isNotEmpty)
        .toList();
    if (activeBatches.isEmpty) {
      await _finishSuccess();
      return;
    }

    // Thunderbolt (force): flush everything including in-progress interval.
    // Swipe (non-force): only process completed 30-min intervals, skip newest segment
    // per DeviceSession (may still be written by firmware) — same behaviour as background auto-sync.
    final List<Batch> batchesToProcess;
    final bool backgroundMode;
    if (_isForcePipeline) {
      batchesToProcess = activeBatches;
      backgroundMode = false;
    } else {
      batchesToProcess = activeBatches
          .map((batch) {
            final safe = RecordingsManager.excludeNewestSegmentPerSession(
              batch.rawSegments,
            );
            return Batch(
              dateString: batch.dateString,
              date: batch.date,
              rawSegments: safe,
              finalizedRecordings: batch.finalizedRecordings,
              markerTimestamps: batch.markerTimestamps,
            );
          })
          .where((b) => b.rawSegments.isNotEmpty)
          .toList();
      backgroundMode = true;
    }

    if (batchesToProcess.isEmpty) {
      await _finishSuccess();
      return;
    }

    // Compute total audio minutes from segments to be processed.
    final allRaw = batchesToProcess.expand((b) => b.rawSegments).toList();
    final totalBytes = allRaw.fold(0, (sum, f) {
      try {
        return sum + f.lengthSync();
      } catch (_) {
        return sum;
      }
    });
    final totalMin = totalBytes / 252000.0; // ~84 B/frame × 50 fps × 60 s
    setState(() {
      _totalMinutes = totalMin;
      _minutesRemaining = totalMin;
    });
    _persistProgress();

    WakelockPlus.enable();
    try {
      await _manager.processAll(
        batchesToProcess,
        (progress) {
          if (mounted) {
            setState(() {
              _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(
                0.0,
                _totalMinutes,
              );
            });
          }
        },
        backgroundMode: backgroundMode,
        onRecordingFinalized: () {
          unawaited(_reloadBatchesSilently());
        },
      );
    } catch (e) {
      WakelockPlus.disable();
      if (_spState == SyncProcessState.stopping) {
        _transitionTo(SyncProcessState.idle);
        unawaited(_reloadBatchesSilently());
      } else {
        _transitionToError('processing', e.toString());
      }
      return;
    }
    WakelockPlus.disable();

    if (_spState == SyncProcessState.stopping) {
      _transitionTo(SyncProcessState.idle);
      unawaited(_reloadBatchesSilently());
      return;
    }

    setState(() {
      _minutesRemaining = 0;
      _lastCompletedStage = 'processing';
    });
    _persistProgress();
    await _reloadBatchesSilently();
    await _finishSuccess();
  }

  Future<void> _finishSuccess() async {
    _isForcePipeline = false;
    _transitionTo(SyncProcessState.successUi);
    await Future.delayed(const Duration(milliseconds: 10000));
    if (!mounted) return;
    setState(() {
      _lastCompletedStage = 'none';
      _syncedCount = 0;
      _totalCount = 0;
      _markerCount = 0;
      _minutesRemaining = 0;
      _totalMinutes = 0;
    });
    _prefs.saveString(_kSpLastCompleted, 'none');
    _persistProgress();
    _transitionTo(SyncProcessState.idle);
    _loadBatches();
  }

  // ─── Cancel modal ──────────────────────────────────────────────────────────
  Future<void> _showCancelModal() async {
    if (_spState != SyncProcessState.syncing &&
        _spState != SyncProcessState.processing)
      return;
    final wasState = _spState;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Cancel sync and processing?',
        'Progress will pause and can be resumed later.',
        confirmText: 'Stop',
      ),
    );
    if (confirm != true) return;
    Logger.debug(
      'RecordingsPage: Cancel confirmed (was $wasState) — cancelling sync + processing.',
    );
    _transitionTo(SyncProcessState.stopping);
    ServiceManager.instance().wal.getSyncs().cancelSync();
    RecordingsManager.cancelProcessing();
  }

  // ─── Batch loading ─────────────────────────────────────────────────────────
  Future<void> _loadBatches() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _manager.getBatches(),
        _manager.getMarkerConversations(),
      ]);
      if (mounted) {
        setState(() {
          _batches = results[0] as List<Batch>;
          _markerConversations = results[1] as List<MarkerConversation>;
          _isLoading = false;
          _accumulatedMinutes = _computeAccumulatedMinutes(_batches);
        });
        _tryAutoUploadNext();
      }
    } catch (e) {
      Logger.error('RecordingsPage: Failed to load batches: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _reloadBatchesSilently() async {
    try {
      final results = await Future.wait([
        _manager.getBatches(),
        _manager.getMarkerConversations(),
      ]);
      if (mounted) {
        setState(() {
          _batches = results[0] as List<Batch>;
          _markerConversations = results[1] as List<MarkerConversation>;
          _accumulatedMinutes = _computeAccumulatedMinutes(_batches);
        });
      }
    } catch (_) {}
  }

  // ─── Delete / export ───────────────────────────────────────────────────────
  Future<void> _deleteDay(Batch batch) async {
    final messenger = ScaffoldMessenger.of(context);
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Delete Day',
        'This will permanently delete all processed recordings for ${batch.dateString}. This cannot be undone.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      await _manager.deleteDay(batch);
      await _loadBatches();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error deleting day: $e')),
        );
      }
    }
  }

  Future<void> _runAdjustmentCleanup() async {
    if (_spState != SyncProcessState.idle) return;
    final daysWithBins = _batches.where((b) => b.rawSegments.isNotEmpty).toList();
    if (daysWithBins.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Clean up raw audio?',
        'Raw audio files from ${daysWithBins.length} ${daysWithBins.length == 1 ? 'day' : 'days'} are still on disk. '
            'Unprocessed days will be processed first, then all raw files will be permanently deleted. '
            'This cannot be undone.',
        confirmText: 'Process & Delete',
      ),
    );
    if (confirm != true) return;

    _lastActiveStage = 'processing';
    _transitionTo(SyncProcessState.processing);

    // Process days that have bins but no recordings yet.
    final unprocessed = daysWithBins.where((b) => b.finalizedRecordings.isEmpty).toList();
    if (unprocessed.isNotEmpty) {
      final totalBytes = unprocessed.expand((b) => b.rawSegments).fold(0, (sum, f) {
        try { return sum + f.lengthSync(); } catch (_) { return sum; }
      });
      setState(() {
        _totalMinutes = totalBytes / 252000.0;
        _minutesRemaining = _totalMinutes;
      });
      WakelockPlus.enable();
      try {
        await _manager.processAll(unprocessed, (progress) {
          if (mounted) setState(() => _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(0.0, _totalMinutes));
        }, backgroundMode: false);
      } catch (e) {
        WakelockPlus.disable();
        _transitionToError('processing', e.toString());
        return;
      }
      WakelockPlus.disable();
    }

    // Delete all remaining bins (including already-processed days).
    await RecordingsManager.deleteAllRawSegments();
    _prefs.adjustmentModeWasEnabled = false;

    setState(() { _minutesRemaining = 0; _lastCompletedStage = 'processing'; });
    _persistProgress();
    await _reloadBatchesSilently();
    await _finishSuccess();
  }

  Future<void> _reprocessDay(Batch batch) async {
    final messenger = ScaffoldMessenger.of(context);
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Reprocess Day',
        'This will delete all processed recordings for ${batch.dateString} and reprocess from raw audio using your current VAD settings.',
        confirmText: 'Reprocess',
      ),
    );
    if (confirm != true) return;
    try {
      await RecordingsManager.reprocessDay(batch, (_) {});
      await _loadBatches();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error reprocessing day: $e')),
        );
      }
    }
  }

  Future<void> _exportAll(Batch batch, List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    final files = conversations.map((r) => XFile(r.file.path)).toList();
    await SharePlus.instance.share(
      ShareParams(files: files, subject: 'Conversations – ${batch.dateString}'),
    );
  }

  // ─── HeyPocket ─────────────────────────────────────────────────────────────
  void _tryAutoUploadNext() {
    if (!_prefs.heypocketEnabled || _prefs.heypocketApiKey.isEmpty) return;
    final apiKey = _prefs.heypocketApiKey;
    final keySetAt = _prefs.heypocketKeySetAt;
    final keySetTime = keySetAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(keySetAt)
        : null;
    for (final batch in _batches) {
      for (final conversation in batch.finalizedRecordings) {
        if (_autoUploadActive >= 2) return;
        if (keySetTime != null && conversation.startTime.isBefore(keySetTime))
          continue;
        final uploadKey = conversation.uploadKey;
        if (uploadKey == null) continue;
        if (_prefs.isUploadedToHeypocket(uploadKey)) continue;
        if (_uploadingFiles.contains(uploadKey)) continue;
        _uploadingFiles.add(uploadKey);
        _autoUploadActive++;
        if (mounted) setState(() {});
        unawaited(
          HeyPocketService.uploadRecording(apiKey, conversation)
              .then((_) async {
                await _prefs.markUploadedToHeypocket(uploadKey);
              })
              .catchError((e) {
                Logger.error('HeyPocket auto-upload failed: $e');
              })
              .whenComplete(() {
                _uploadingFiles.remove(uploadKey);
                _autoUploadActive--;
                if (mounted) {
                  setState(() {});
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _tryAutoUploadNext(),
                  );
                }
              }),
        );
      }
    }
  }

  Future<void> _handleUploadTap(Conversation conversation) async {
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Upload key unavailable — please reconnect your device and try again.',
          ),
        ),
      );
      return;
    }
    if (_uploadingFiles.contains(uploadKey)) return;

    final alreadyUploaded = _prefs.isUploadedToHeypocket(uploadKey);
    final title = alreadyUploaded
        ? 'Re-upload Conversation'
        : 'Upload Conversation';
    final content = alreadyUploaded
        ? 'This conversation was already uploaded to HeyPocket. Upload again? (It may create a duplicate.)'
        : 'Upload this conversation to HeyPocket?';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        title,
        content,
        confirmText: 'Upload',
      ),
    );
    if (confirm != true) return;

    final apiKey = _prefs.heypocketApiKey;
    _uploadingFiles.add(uploadKey);
    setState(() {});
    unawaited(
      HeyPocketService.uploadRecording(apiKey, conversation)
          .then((_) {
            _prefs.markUploadedToHeypocket(uploadKey);
          })
          .catchError((e) {
            if (e is HeyPocketException) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('HeyPocket ${e.statusCode}: ${e.message}'),
                  ),
                );
              }
            }
            Logger.error('HeyPocket upload failed: $e');
          })
          .whenComplete(() {
            _uploadingFiles.remove(uploadKey);
            if (mounted) setState(() {});
          }),
    );
  }

  Widget _buildUploadIcon(Conversation conversation) {
    if (_prefs.heypocketApiKey.isEmpty) return const SizedBox.shrink();
    final uploadKey = conversation.uploadKey;
    if (uploadKey == null) {
      return IconButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        icon: Icon(Icons.cloud_off, color: Colors.grey.shade600, size: 18),
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Upload key unavailable — please reconnect your device and try again.',
            ),
          ),
        ),
      );
    }
    if (_uploadingFiles.contains(uploadKey)) {
      return IconButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        icon: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: Colors.deepPurpleAccent,
          ),
        ),
        onPressed: null,
      );
    }
    if (_prefs.isUploadedToHeypocket(uploadKey)) {
      return IconButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        icon: const Icon(Icons.cloud_done, color: Colors.green, size: 18),
        onPressed: () => _handleUploadTap(conversation),
      );
    }
    return IconButton(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      constraints: const BoxConstraints(),
      icon: const Icon(Icons.cloud_upload, color: Colors.redAccent, size: 18),
      onPressed: () => _handleUploadTap(conversation),
    );
  }

  // ─── Accumulating progress banner ─────────────────────────────────────────
  static double _computeAccumulatedMinutes(List<Batch> batches) {
    final totalBytes = batches.expand((b) => b.rawSegments).fold<int>(0, (
      sum,
      f,
    ) {
      try {
        return sum + f.lengthSync();
      } catch (_) {
        return sum;
      }
    });
    return totalBytes / 252000.0; // 84 B/frame × 50 fps × 60 s
  }

  Widget _buildAccumulatingBanner() {
    // Hide while actively syncing/processing (the sync card already covers this)
    // and when there's less than half a minute accumulated (not worth showing).
    if (_spState == SyncProcessState.syncing ||
        _spState == SyncProcessState.processing ||
        _spState == SyncProcessState.stopping)
      return const SizedBox.shrink();
    if (_accumulatedMinutes < 0.5) return const SizedBox.shrink();

    final int accMin = _accumulatedMinutes.floor();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Conversation in progress',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$accMin ${accMin == 1 ? 'minute' : 'minutes'} accumulated',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: FaIcon(
                    FontAwesomeIcons.hourglassHalf,
                    color: Colors.deepPurpleAccent,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Duration filter sheet ─────────────────────────────────────────────────
  void _showFilterSheet() {
    const options = [0, 30, 60, 120, 300, 600];
    const labels = ['Off', '30s', '1m', '2m', '5m', '10m'];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Hide conversations shorter than',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(options.length, (i) {
                  final selected = _minFilterSeconds == options[i];
                  return GestureDetector(
                    onTap: () {
                      setState(() => _minFilterSeconds = options[i]);
                      Navigator.of(ctx).pop();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? Colors.deepPurpleAccent : const Color(0xFF2C2C2E),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.grey.shade300,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Adjustment mode cleanup banner ────────────────────────────────────────
  Widget _buildAdjustmentCleanupBanner() {
    if (_prefs.adjustmentMode) return const SizedBox.shrink();
    if (!_prefs.adjustmentModeWasEnabled) return const SizedBox.shrink();
    if (_spState != SyncProcessState.idle) return const SizedBox.shrink();
    final pendingDays = _batches.where((b) => b.rawSegments.isNotEmpty).length;
    if (pendingDays == 0) return const SizedBox.shrink();

    return GestureDetector(
      onTap: _runAdjustmentCleanup,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.3), width: 1),
        ),
        child: Row(
          children: [
            const FaIcon(FontAwesomeIcons.triangleExclamation, color: Colors.orange, size: 16),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Raw audio pending cleanup',
                    style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w500, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$pendingDays ${pendingDays == 1 ? 'day' : 'days'} of raw files still on disk. Tap to process & delete.',
                    style: TextStyle(color: Colors.orange.shade300, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Unified status card ───────────────────────────────────────────────────
  Widget _buildSyncProcessCard() {
    if (_spState == SyncProcessState.idle) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _buildCardContent(),
    );
  }

  Widget _buildCardContent() {
    final String mainText;
    final String subText;
    final Color iconBg;
    final Widget iconChild;
    VoidCallback? onIconTap;
    bool showProgress = false;
    double? progressValue;
    Color progressColor = Colors.deepPurpleAccent;

    switch (_spState) {
      case SyncProcessState.idle:
        mainText = 'Sync and Process Now';
        subText = 'Syncs files from device and prepares conversations';
        iconBg = Colors.deepPurpleAccent;
        iconChild = const FaIcon(
          FontAwesomeIcons.rotate,
          color: Colors.white,
          size: 16,
        );
        onIconTap = _startPipeline;

      case SyncProcessState.syncing:
        mainText = _isForcePipeline ? 'Force Sync...' : 'Syncing segments';
        final speedStr = _syncSpeed > 0
            ? '  ·  ${_syncSpeed.toStringAsFixed(1)} KB/s'
            : '';
        subText = _totalCount > 0
            ? '$_syncedCount of $_totalCount segments synced$speedStr'
            : (_isForcePipeline ? 'Rotating segment…' : 'Scanning device…');
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = () => unawaited(_showCancelModal());
        showProgress = true;
        progressValue = _totalCount > 0
            ? (_syncedCount / _totalCount).clamp(0.0, 1.0)
            : null;

      case SyncProcessState.processing:
        mainText = 'Preparing conversations';
        final minStr = _minutesRemaining >= 1
            ? '${_minutesRemaining.ceil()} min of audio remaining'
            : '< 1 min of audio remaining';
        subText = minStr;
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = () => unawaited(_showCancelModal());
        showProgress = true;
        progressValue = _totalMinutes > 0
            ? (1.0 - _minutesRemaining / _totalMinutes).clamp(0.0, 1.0)
            : null;

      case SyncProcessState.stopping:
        mainText = 'Stopping…';
        subText = 'Finishing current step';
        iconBg = Colors.grey.shade700;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = null;
        showProgress = true;
        progressValue = null;
        progressColor = Colors.grey.shade600;

      case SyncProcessState.resume:
        mainText = 'Resume Sync and Processing';
        subText = 'Last run didn\'t finish';
        iconBg = Colors.amber.shade700;
        iconChild = const FaIcon(
          FontAwesomeIcons.rotate,
          color: Colors.white,
          size: 16,
        );
        onIconTap = _resumePipeline;

      case SyncProcessState.error:
        mainText = _lastActiveStage == 'processing'
            ? 'Processing failed'
            : 'Sync failed';
        subText = 'Tap to retry';
        iconBg = Colors.redAccent;
        iconChild = const FaIcon(
          FontAwesomeIcons.circleExclamation,
          color: Colors.white,
          size: 16,
        );
        onIconTap = _retryFromError;

      case SyncProcessState.successUi:
        mainText = 'Conversations ready';
        subText = 'Sync and processing complete';
        iconBg = Colors.green.shade600;
        iconChild = const FaIcon(
          FontAwesomeIcons.circleCheck,
          color: Colors.white,
          size: 16,
        );
        onIconTap = null;
        showProgress = true;
        progressValue = 1.0;
        progressColor = Colors.green;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mainText,
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subText,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onIconTap,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconBg,
                  shape: BoxShape.circle,
                ),
                child: Center(child: iconChild),
              ),
            ),
          ],
        ),
        if (showProgress) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progressValue,
            backgroundColor: Colors.grey.shade800,
            color: progressColor,
          ),
        ],
      ],
    );
  }

  // ─── Marker helpers ────────────────────────────────────────────────────────
  /// Maps m4a filename → list of MarkerConversations whose marker time falls within that file.
  /// A marker only appears under the single conversation that contains its timestamp,
  /// even if its visible window spans multiple segments.
  Map<String, List<MarkerConversation>> _buildMarkerMap() {
    final map = <String, List<MarkerConversation>>{};
    for (final mc in _markerConversations) {
      if (mc.segment == null) continue; // pending — no segment to key on
      final key = mc.segment!.path.split('/').last;
      map.putIfAbsent(key, () => []).add(mc);
    }
    return map;
  }

  /// Groups _markerConversations by YYYY-MM-DD, preserving sort order (newest first).
  Map<String, List<MarkerConversation>> _groupMarkersByDate() {
    final map = <String, List<MarkerConversation>>{};
    for (final mc in _markerConversations) {
      final dt = mc.markerTime;
      final dateStr =
          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      map.putIfAbsent(dateStr, () => []).add(mc);
    }
    return map;
  }

  Future<void> _openMarkerConversation(MarkerConversation mc) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MarkerConversationPlayerPage(markerConversation: mc),
      ),
    );
    await _reloadBatchesSilently();
  }

  // ─── Default mode: batch card ──────────────────────────────────────────────
  Widget _buildBatchCard(
    Batch batch,
    Map<String, List<MarkerConversation>> markerMap,
  ) {
    final conversations = [...batch.finalizedRecordings]
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final filtered = _minFilterSeconds > 0
        ? conversations.where((c) => c.duration.inSeconds >= _minFilterSeconds).toList()
        : conversations;
    if (filtered.isEmpty) return const SizedBox.shrink();

    return Card(
      color: const Color(0xFF1C1C1E),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              batch.dateString,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...filtered.map(
              (c) => _buildConversationTile(
                c,
                markerMap[c.file.path.split('/').last] ?? [],
              ),
            ),
            const SizedBox(height: 4),
            const Divider(color: Color(0xFF2C2C2E), height: 1),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  key: Key('export_all_${batch.dateString}'),
                  onPressed: () => _exportAll(batch, filtered),
                  icon: FaIcon(
                    FontAwesomeIcons.shareFromSquare,
                    size: 13,
                    color: Colors.grey.shade400,
                  ),
                  label: Text(
                    'Export All',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                ),
                if (_prefs.adjustmentMode && batch.rawSegments.isNotEmpty)
                  TextButton.icon(
                    key: Key('reprocess_day_${batch.dateString}'),
                    onPressed: () => _reprocessDay(batch),
                    icon: FaIcon(
                      FontAwesomeIcons.rotateRight,
                      size: 13,
                      color: Colors.deepPurpleAccent,
                    ),
                    label: const Text(
                      'Reprocess Day',
                      style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 13),
                    ),
                  )
                else
                  TextButton.icon(
                    key: Key('delete_day_${batch.dateString}'),
                    onPressed: () => _deleteDay(batch),
                    icon: FaIcon(
                      FontAwesomeIcons.trashCan,
                      size: 13,
                      color: Colors.red.shade400,
                    ),
                    label: Text(
                      'Delete Day',
                      style: TextStyle(color: Colors.red.shade400, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(
    Conversation conversation,
    List<MarkerConversation> markers,
  ) {
    // Sort markers by time ascending so sub-entries read chronologically.
    final sortedMarkers = [...markers]
      ..sort((a, b) => a.markerTime.compareTo(b.markerTime));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  ConversationPlayerPage(conversation: conversation),
            ),
          ),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.timeRangeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${conversation.durationLabel}  ·  ${conversation.sizeLabel}',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (markers.isNotEmpty) ...[
                  const FaIcon(
                    FontAwesomeIcons.solidBookmark,
                    color: Colors.amber,
                    size: 13,
                  ),
                  const SizedBox(width: 8),
                ],
                _buildUploadIcon(conversation),
                FaIcon(
                  FontAwesomeIcons.chevronRight,
                  color: Colors.grey.shade600,
                  size: 14,
                ),
              ],
            ),
          ),
        ),
        // Sub-entries: one per marker, indented, tap → marker player
        ...sortedMarkers.map((mc) => _buildMarkerSubEntry(mc)),
      ],
    );
  }

  Widget _buildMarkerSubEntry(MarkerConversation mc) {
    return InkWell(
      onTap: mc.isPending ? null : () => _openMarkerConversation(mc),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 6, bottom: 6, right: 4),
        child: Row(
          children: [
            FaIcon(
              FontAwesomeIcons.solidBookmark,
              color: mc.isPending ? Colors.grey.shade600 : Colors.amber,
              size: 11,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mc.isPending ? 'Processing…' : mc.timeRangeLabel,
                    style: TextStyle(
                      color: mc.isPending ? Colors.grey.shade600 : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    'marker at ${mc.markerTimeLabel}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (!mc.isPending && mc.userSaved) ...[
              const FaIcon(
                FontAwesomeIcons.circleCheck,
                color: Colors.green,
                size: 12,
              ),
              const SizedBox(width: 6),
            ],
            if (!mc.isPending)
              FaIcon(
                FontAwesomeIcons.chevronRight,
                color: Colors.grey.shade700,
                size: 12,
              ),
          ],
        ),
      ),
    );
  }

  // ─── Marker mode: day card ─────────────────────────────────────────────────
  Widget _buildMarkerDayCard(String dateStr, List<MarkerConversation> markers) {
    // Sort ascending by markerTime so they read chronologically within the day.
    final sorted = [...markers]
      ..sort((a, b) => a.markerTime.compareTo(b.markerTime));
    return Card(
      color: const Color(0xFF1C1C1E),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dateStr,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...sorted.map(_buildMarkerTile),
          ],
        ),
      ),
    );
  }

  Widget _buildMarkerTile(MarkerConversation mc) {
    return InkWell(
      onTap: mc.isPending ? null : () => _openMarkerConversation(mc),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            FaIcon(
              FontAwesomeIcons.solidBookmark,
              color: mc.isPending ? Colors.grey.shade600 : Colors.amber,
              size: 14,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mc.isPending ? 'Processing…' : mc.timeRangeLabel,
                    style: TextStyle(
                      color: mc.isPending ? Colors.grey.shade600 : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'marker at ${mc.markerTimeLabel}',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!mc.isPending && mc.userSaved) ...[
              const FaIcon(
                FontAwesomeIcons.circleCheck,
                color: Colors.green,
                size: 14,
              ),
              const SizedBox(width: 8),
            ],
            if (!mc.isPending)
              FaIcon(
                FontAwesomeIcons.chevronRight,
                color: Colors.grey.shade600,
                size: 14,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStorageWarning(int percentage) {
    if (percentage < 90) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.red.shade900,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        children: [
          const FaIcon(
            FontAwesomeIcons.circleExclamation,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Device Storage $percentage% Full - Sync Now',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceProvider>(
      builder: (context, deviceProvider, child) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D0D0D),
          appBar: AppBar(
            title: const Text(
              'Daily Conversations',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: const Color(0xFF0D0D0D),
            actions: [
              if (!deviceProvider.isConnected)
                IconButton(
                  icon: const FaIcon(
                    FontAwesomeIcons.bluetooth,
                    color: Colors.grey,
                    size: 20,
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (c) => const FindDevicesPage()),
                  ),
                )
              else
                BatteryStatusIndicator(
                  batteryLevel: deviceProvider.batteryLevel,
                  isCharging: deviceProvider.isCharging,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (c) => const DeviceSettings()),
                  ),
                ),
              if (_markerConversations.isNotEmpty)
                IconButton(
                  icon: FaIcon(
                    _showMarkersOnly
                        ? FontAwesomeIcons.solidBookmark
                        : FontAwesomeIcons.bookmark,
                    color: _showMarkersOnly ? Colors.amber : Colors.white,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _showMarkersOnly = !_showMarkersOnly),
                ),
              IconButton(
                icon: FaIcon(
                  FontAwesomeIcons.filter,
                  color: _minFilterSeconds > 0 ? Colors.deepPurpleAccent : Colors.white,
                  size: 18,
                ),
                onPressed: _showFilterSheet,
              ),
              // Force sync button — disabled when syncing is in progress or on cooldown
              IconButton(
                icon: FaIcon(
                  FontAwesomeIcons.boltLightning,
                  color:
                      (deviceProvider.isConnected &&
                          _spState == SyncProcessState.idle &&
                          !_forceSyncOnCooldown)
                      ? Colors.white
                      : Colors.grey.shade700,
                  size: 20,
                ),
                onPressed:
                    (deviceProvider.isConnected &&
                        _spState == SyncProcessState.idle &&
                        !_forceSyncOnCooldown)
                    ? _forceSyncButtonPressed
                    : null,
              ),
              IconButton(
                icon: const FaIcon(
                  FontAwesomeIcons.gear,
                  color: Colors.white,
                  size: 20,
                ),
                onPressed: () => SettingsDrawer.show(context),
              ),
            ],
          ),
          body: Column(
            children: [
              _buildStorageWarning(deviceProvider.storageFullPercentage),
              _buildSyncProcessCard(),
              _buildAccumulatingBanner(),
              _buildAdjustmentCleanupBanner(),
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Colors.deepPurpleAccent,
                        ),
                      )
                    : Builder(
                        builder: (context) {
                          // ── Marker mode ──────────────────────────────────────
                          if (_showMarkersOnly) {
                            final byDate = _groupMarkersByDate();
                            final dates = byDate.keys.toList()
                              ..sort((a, b) => b.compareTo(a));
                            return RefreshIndicator(
                              color: Colors.deepPurpleAccent,
                              onRefresh: () async {},
                              child: dates.isEmpty
                                  ? ListView(
                                      physics:
                                          const AlwaysScrollableScrollPhysics(),
                                      children: [
                                        const SizedBox(height: 100),
                                        Center(
                                          child: Text(
                                            'No marked recordings yet.\nPress the button on your Omi to tag a moment.',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.grey,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : ListView.builder(
                                      physics:
                                          const AlwaysScrollableScrollPhysics(),
                                      padding: const EdgeInsets.all(16),
                                      itemCount: dates.length,
                                      itemBuilder: (context, index) =>
                                          _buildMarkerDayCard(
                                            dates[index],
                                            byDate[dates[index]]!,
                                          ),
                                    ),
                            );
                          }

                          // ── Default mode ─────────────────────────────────────
                          final markerMap = _buildMarkerMap();
                          final visibleBatches = _batches
                              .where((b) => b.finalizedRecordings.isNotEmpty)
                              .toList();
                          return RefreshIndicator(
                            color: Colors.deepPurpleAccent,
                            onRefresh: () {
                              if (_spState != SyncProcessState.idle) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Sync already in progress'),
                                  ),
                                );
                                return Future.value();
                              }
                              final completer = Completer<void>();
                              _pipelineCompleter = completer;
                              _startPipeline();
                              return completer.future;
                            },
                            child: visibleBatches.isEmpty
                                ? ListView(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    children: [
                                      const SizedBox(height: 100),
                                      Center(
                                        child: Column(
                                          children: [
                                            const Text(
                                              'No conversations found.\nSwipe down to sync device.',
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: Colors.grey,
                                                fontSize: 16,
                                              ),
                                            ),
                                            if (deviceProvider.isConnected) ...[
                                              const SizedBox(height: 32),
                                              ElevatedButton.icon(
                                                onPressed:
                                                    _spState ==
                                                        SyncProcessState.idle
                                                    ? _startPipeline
                                                    : null,
                                                icon: const FaIcon(
                                                  FontAwesomeIcons.rotate,
                                                  size: 16,
                                                ),
                                                label: const Text(
                                                  'Sync and Process',
                                                ),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      Colors.deepPurpleAccent,
                                                  foregroundColor: Colors.white,
                                                ),
                                              ),
                                            ] else ...[
                                              const SizedBox(height: 32),
                                              ElevatedButton(
                                                onPressed: () =>
                                                    Navigator.of(context).push(
                                                      MaterialPageRoute(
                                                        builder: (c) =>
                                                            const FindDevicesPage(),
                                                      ),
                                                    ),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      Colors.deepPurpleAccent,
                                                  foregroundColor: Colors.white,
                                                ),
                                                child: const Text(
                                                  'Connect Omi',
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  )
                                : ListView.builder(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.all(16),
                                    itemCount: visibleBatches.length,
                                    itemBuilder: (context, index) =>
                                        _buildBatchCard(
                                          visibleBatches[index],
                                          markerMap,
                                        ),
                                  ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
