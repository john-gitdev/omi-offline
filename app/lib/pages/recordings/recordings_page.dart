import 'dart:async';

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
import 'package:omi/widgets/dialog.dart';
import 'package:omi/widgets/battery_status_indicator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ─── State machine ──────────────────────────────────────────────────────────
enum SyncProcessState { idle, syncing, processing, stopping, resume, error, successUi }

// ─── Page ───────────────────────────────────────────────────────────────────
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> implements IWalSyncProgressListener {
  final RecordingsManager _manager = RecordingsManager();
  final _prefs = SharedPreferencesUtil();

  // ─── Batch data ────────────────────────────────────────────────────────────
  List<Batch> _batches = [];
  bool _isLoading = true;

  // ─── Unified sync+process state ────────────────────────────────────────────
  SyncProcessState _spState = SyncProcessState.idle;
  int _syncedCount = 0;
  int _totalCount = 0;
  double _minutesRemaining = 0.0;
  double _totalMinutes = 0.0;
  int _markerCount = 0;
  double _syncSpeed = 0.0;
  String _lastCompletedStage = 'none'; // "none" | "syncing" | "processing"
  String _lastActiveStage = 'syncing'; // "syncing" | "processing"
  // ─── Filter state ──────────────────────────────────────────────────────────
  bool _filterEnabled = SharedPreferencesUtil().recordingsFilterEnabled;
  int _filterMinutes = SharedPreferencesUtil().recordingsFilterMinutes;

  // ─── HeyPocket upload state ────────────────────────────────────────────────
  final Set<String> _uploadingFiles = {};
  int _autoUploadActive = 0;
  String _lastHpKey = '';

  Timer? _pollTimer;
  bool _isUserTriggered = false; // true while user-initiated pipeline is running
  Completer<void>? _pipelineCompleter; // completed when the pipeline reaches a terminal state

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
    RecordingsManager.recordingsChangeNotifier.addListener(_onRecordingsChanged);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  void _onRecordingsChanged() {
    if (mounted) {
      _restoreState();
      _loadBatches();
    }
  }

  void _restoreState() {
    final saved = _prefs.getString(_kSpState, defaultValue: 'idle');
    const incompleteStates = {'syncing', 'processing', 'stopping'};
    if (incompleteStates.contains(saved)) {
      _spState = SyncProcessState.resume;
      _prefs.saveString(_kSpState, 'resume');
    } else if (saved == 'error') {
      _spState = SyncProcessState.error;
    }
    _syncedCount = _prefs.getInt(_kSpSyncedCount);
    _totalCount = _prefs.getInt(_kSpTotalCount);
    _minutesRemaining = _prefs.getDouble(_kSpMinutesRemaining);
    _markerCount = _prefs.getInt(_kSpMarkerCount);
    _lastCompletedStage = _prefs.getString(_kSpLastCompleted, defaultValue: 'none');
    _lastActiveStage = _prefs.getString(_kSpLastActive, defaultValue: 'syncing');

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
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(null);
    RecordingsManager.recordingsChangeNotifier.removeListener(_onRecordingsChanged);
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

      // ── Background sync finished ─────────────────────────────────────────
      if (!serviceIsSyncing && _spState == SyncProcessState.syncing) {
        if (serviceIsProcessing) {
          // Background processing auto-started after sync — show it.
          unawaited(_reloadBatchesSilently().then((_) {
            if (!mounted) return;
            final allRaw = _batches.expand((b) => b.rawSegments).toList();
            final processable = RecordingsManager.excludeNewestSegmentPerSession(allRaw);
            final totalBytes = processable.fold(0, (s, f) {
              try {
                return s + f.lengthSync();
              } catch (_) {
                return s;
              }
            });
            setState(() {
              _spState = SyncProcessState.processing;
              _totalMinutes = totalBytes / 252000.0; // segment on-disk: 4-byte prefix + ~80 B Opus = ~84 B/frame × 50 fps × 60 s
              _minutesRemaining = _totalMinutes;
              _syncedCount = 0;
              _syncSpeed = 0.0;
            });
          }));
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
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase}) {
    if (!mounted) return;
    setState(() {
      _syncSpeed = speedKBps ?? 0.0;
      // If _totalCount was 0 at pipeline start (WAL list wasn't populated yet),
      // backfill it from estimatedTotalSegments now that syncAll has refreshed _wals.
      if (_totalCount == 0) {
        _totalCount = ServiceManager.instance().wal.getSyncs().estimatedTotalSegments;
      }
      if (_totalCount > 0) {
        _syncedCount = (percentage * _totalCount).round().clamp(0, _totalCount);
      } else {
        _syncedCount++;
      }
    });
  }

  // ─── Pipeline entry points ─────────────────────────────────────────────────
  void _startPipeline() {
    if (_spState != SyncProcessState.idle) return;
    unawaited(_runPipeline());
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

    final syncs = ServiceManager.instance().wal.getSyncs();
    final estimatedTotal = syncs.estimatedTotalSegments;
    Logger.debug('RecordingsPage: _runPipeline start — estimatedTotalSegments=$estimatedTotal');
    setState(() {
      _totalCount = estimatedTotal;
      _syncedCount = 0;
      _syncSpeed = 0.0;
    });
    _persistProgress();
    WakelockPlus.enable();

    try {
      await syncs.syncAll(progress: this);
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
      _markerCount = _batches.fold(0, (sum, b) => sum + b.markerTimestamps.length);
    });
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

    // Compute total audio minutes from processable (non-live) segments
    final allRaw = activeBatches.expand((b) => b.rawSegments).toList();
    final processable = RecordingsManager.excludeNewestSegmentPerSession(allRaw);
    final totalBytes = processable.fold(0, (sum, f) {
      try {
        return sum + f.lengthSync();
      } catch (_) {
        return sum;
      }
    });
    final totalMin = totalBytes / 252000.0; // segment on-disk: 4-byte prefix + ~80 B Opus = ~84 B/frame × 50 fps × 60 s
    setState(() {
      _totalMinutes = totalMin;
      _minutesRemaining = totalMin;
    });
    _persistProgress();

    WakelockPlus.enable();
    try {
      await _manager.processAll(activeBatches, (progress) {
        if (mounted) {
          setState(() {
            _minutesRemaining = (_totalMinutes * (1.0 - progress)).clamp(0.0, _totalMinutes);
          });
        }
      });
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
    _transitionTo(SyncProcessState.successUi);
    await Future.delayed(const Duration(milliseconds: 5000));
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
    if (_spState != SyncProcessState.syncing && _spState != SyncProcessState.processing) return;
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
    _transitionTo(SyncProcessState.stopping);
    if (wasState == SyncProcessState.syncing) {
      ServiceManager.instance().wal.getSyncs().cancelSync();
    } else {
      RecordingsManager.cancelProcessing();
    }
  }

  // ─── Batch loading ─────────────────────────────────────────────────────────
  Future<void> _loadBatches() async {
    setState(() => _isLoading = true);
    try {
      final batches = await _manager.getBatches();
      if (mounted) {
        setState(() {
          _batches = batches;
          _isLoading = false;
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
      final batches = await _manager.getBatches();
      if (mounted) setState(() => _batches = batches);
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
        'This will permanently delete all processed conversations for ${batch.dateString}. This cannot be undone.',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) return;
    try {
      await _manager.deleteDay(batch);
      await _loadBatches();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Error deleting day: $e')));
      }
    }
  }

  Future<void> _exportAll(Batch batch, List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    final files = conversations.map((r) => XFile(r.file.path)).toList();
    await SharePlus.instance.share(ShareParams(files: files, subject: 'Conversations – ${batch.dateString}'));
  }

  // ─── Filter sheet ──────────────────────────────────────────────────────────
  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('Filter by Duration', style: TextStyle(color: Colors.white)),
                  value: _filterEnabled,
                  activeThumbColor: Colors.deepPurpleAccent,
                  onChanged: (v) {
                    setModalState(() => _filterEnabled = v);
                    setState(() => _filterEnabled = v);
                    SharedPreferencesUtil().recordingsFilterEnabled = v;
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text('Min duration:', style: TextStyle(color: Colors.grey.shade400)),
                      const Spacer(),
                      Text('$_filterMinutes min',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Slider(
                  min: 0,
                  max: 60,
                  divisions: 60,
                  value: _filterMinutes.toDouble(),
                  activeColor: Colors.deepPurpleAccent,
                  inactiveColor: Colors.grey.shade700,
                  onChanged: _filterEnabled
                      ? (v) {
                          setModalState(() => _filterMinutes = v.round());
                          setState(() => _filterMinutes = v.round());
                          SharedPreferencesUtil().recordingsFilterMinutes = v.round();
                        }
                      : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ─── HeyPocket ─────────────────────────────────────────────────────────────
  void _tryAutoUploadNext() {
    if (!_prefs.heypocketEnabled || _prefs.heypocketApiKey.isEmpty) return;
    final apiKey = _prefs.heypocketApiKey;
    final keySetAt = _prefs.heypocketKeySetAt;
    final keySetTime = keySetAt > 0 ? DateTime.fromMillisecondsSinceEpoch(keySetAt) : null;
    for (final batch in _batches) {
      for (final file in batch.finalizedRecordings) {
        if (_autoUploadActive >= 2) return;
        final conversation = Conversation.fromFile(file);
        if (keySetTime != null && conversation.startTime.isBefore(keySetTime)) continue;
        if (_filterEnabled && conversation.duration < Duration(minutes: _filterMinutes)) continue;
        final uploadKey = conversation.uploadKey;
        if (uploadKey == null) continue;
        if (_prefs.isUploadedToHeypocket(uploadKey)) continue;
        if (_uploadingFiles.contains(uploadKey)) continue;
        _uploadingFiles.add(uploadKey);
        _autoUploadActive++;
        if (mounted) setState(() {});
        unawaited(
          HeyPocketService.uploadRecording(apiKey, conversation).then((_) {
            _prefs.markUploadedToHeypocket(uploadKey);
          }).catchError((e) {
            debugPrint('HeyPocket auto-upload failed: $e');
          }).whenComplete(() {
            _uploadingFiles.remove(uploadKey);
            _autoUploadActive--;
            if (mounted) {
              setState(() {});
              WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoUploadNext());
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
        const SnackBar(content: Text('Upload key unavailable — please reconnect your device and try again.')),
      );
      return;
    }
    if (_uploadingFiles.contains(uploadKey)) return;

    final alreadyUploaded = _prefs.isUploadedToHeypocket(uploadKey);
    final title = alreadyUploaded ? 'Re-upload Conversation' : 'Upload Conversation';
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
      HeyPocketService.uploadRecording(apiKey, conversation).then((_) {
        _prefs.markUploadedToHeypocket(uploadKey);
      }).catchError((e) {
        if (e is HeyPocketException) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('HeyPocket ${e.statusCode}: ${e.message}')),
            );
          }
        }
        debugPrint('HeyPocket upload failed: $e');
      }).whenComplete(() {
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
          const SnackBar(content: Text('Upload key unavailable — please reconnect your device and try again.')),
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
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.deepPurpleAccent),
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
        iconChild = const FaIcon(FontAwesomeIcons.rotate, color: Colors.white, size: 16);
        onIconTap = _startPipeline;

      case SyncProcessState.syncing:
        mainText = 'Syncing segments';
        final speedStr = _syncSpeed > 0 ? '  ·  ${_syncSpeed.toStringAsFixed(1)} KB/s' : '';
        subText = _totalCount > 0 ? '$_syncedCount of $_totalCount segments synced$speedStr' : 'Scanning device…';
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = () => unawaited(_showCancelModal());
        showProgress = true;
        progressValue = _totalCount > 0 ? (_syncedCount / _totalCount).clamp(0.0, 1.0) : null;

      case SyncProcessState.processing:
        mainText = 'Preparing conversations';
        final minStr = _minutesRemaining >= 1
            ? '${_minutesRemaining.ceil()} min of audio remaining'
            : '< 1 min of audio remaining';
        subText = '$minStr  ·  $_markerCount marker${_markerCount != 1 ? 's' : ''}';
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = () => unawaited(_showCancelModal());
        showProgress = true;
        progressValue = _totalMinutes > 0 ? (1.0 - _minutesRemaining / _totalMinutes).clamp(0.0, 1.0) : null;

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
        iconChild = const FaIcon(FontAwesomeIcons.rotate, color: Colors.white, size: 16);
        onIconTap = _resumePipeline;

      case SyncProcessState.error:
        mainText = _lastActiveStage == 'processing' ? 'Processing failed' : 'Sync failed';
        subText = 'Tap to retry';
        iconBg = Colors.redAccent;
        iconChild = const FaIcon(FontAwesomeIcons.circleExclamation, color: Colors.white, size: 16);
        onIconTap = _retryFromError;

      case SyncProcessState.successUi:
        mainText = 'Conversations ready';
        subText = 'Sync and processing complete';
        iconBg = Colors.green.shade600;
        iconChild = const FaIcon(FontAwesomeIcons.circleCheck, color: Colors.white, size: 16);
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
                  Text(mainText, style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subText, style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onIconTap,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
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

  // ─── Batch card ────────────────────────────────────────────────────────────
  Widget _buildBatchCard(Batch batch) {
    final allConversations = batch.finalizedRecordings.map(Conversation.fromFile).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final minDuration = Duration(minutes: _filterMinutes);
    final conversations = (_filterEnabled && _filterMinutes > 0)
        ? allConversations.where((r) => r.duration >= minDuration).toList()
        : allConversations;

    return Card(
      color: const Color(0xFF1C1C1E),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  batch.dateString,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (batch.markerTimestamps.isNotEmpty)
                  Row(
                    children: [
                      const FaIcon(FontAwesomeIcons.solidBookmark, color: Colors.amber, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        '${batch.markerTimestamps.length}',
                        style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (conversations.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text('No processed conversations yet.', style: TextStyle(color: Colors.grey.shade500)),
              )
            else ...[
              ...conversations.map((conversation) => _buildConversationTile(conversation)),
              const SizedBox(height: 4),
              const Divider(color: Color(0xFF2C2C2E), height: 1),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    key: Key('export_all_${batch.dateString}'),
                    onPressed: () => _exportAll(batch, conversations),
                    icon: FaIcon(FontAwesomeIcons.shareFromSquare, size: 13, color: Colors.grey.shade400),
                    label: Text('Export All', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                  ),
                  TextButton.icon(
                    key: Key('delete_day_${batch.dateString}'),
                    onPressed: () {
                      if (SharedPreferencesUtil().offlineAdjustmentMode) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Delete Day is disabled while adjustment mode is on.')),
                        );
                        return;
                      }
                      _deleteDay(batch);
                    },
                    icon: FaIcon(FontAwesomeIcons.trashCan,
                        size: 13,
                        color:
                            SharedPreferencesUtil().offlineAdjustmentMode ? Colors.grey.shade700 : Colors.red.shade400),
                    label: Text('Delete Day',
                        style: TextStyle(
                            color: SharedPreferencesUtil().offlineAdjustmentMode
                                ? Colors.grey.shade700
                                : Colors.red.shade400,
                            fontSize: 13)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(Conversation conversation) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ConversationPlayerPage(conversation: conversation)),
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
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${conversation.durationLabel}  ·  ${conversation.sizeLabel}',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            ),
            _buildUploadIcon(conversation),
            FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade600, size: 14),
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
          const FaIcon(FontAwesomeIcons.circleExclamation, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Device Storage $percentage% Full - Sync Now',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
            title: const Text('Daily Conversations', style: TextStyle(color: Colors.white)),
            backgroundColor: const Color(0xFF0D0D0D),
            actions: [
              if (!deviceProvider.isConnected)
                IconButton(
                  icon: const FaIcon(FontAwesomeIcons.bluetooth, color: Colors.grey, size: 20),
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
              IconButton(
                icon: FaIcon(
                  FontAwesomeIcons.filter,
                  color: _filterEnabled ? Colors.deepPurpleAccent : Colors.white,
                  size: 20,
                ),
                onPressed: _showFilterSheet,
              ),
              IconButton(
                icon: const FaIcon(FontAwesomeIcons.gear, color: Colors.white, size: 20),
                onPressed: () => SettingsDrawer.show(context),
              ),
            ],
          ),
          body: Column(
            children: [
              _buildStorageWarning(deviceProvider.storageFullPercentage),
              _buildSyncProcessCard(),
              if (_filterEnabled && _filterMinutes > 0)
                Container(
                  width: double.infinity,
                  color: Colors.deepPurpleAccent.withValues(alpha: 0.15),
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                  child: Text(
                    'Showing conversations \u2265 $_filterMinutes min',
                    style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 12),
                  ),
                ),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
                    : Builder(builder: (context) {
                        final minDuration = Duration(minutes: _filterMinutes);
                        final visibleBatches = (_filterEnabled && _filterMinutes > 0)
                            ? _batches.where((b) {
                                return b.finalizedRecordings
                                    .any((f) => Conversation.fromFile(f).duration >= minDuration);
                              }).toList()
                            : _batches.where((b) => b.finalizedRecordings.isNotEmpty).toList();
                        return RefreshIndicator(
                          color: Colors.deepPurpleAccent,
                          onRefresh: () {
                            if (_spState != SyncProcessState.idle) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Sync already in progress')),
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
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    const SizedBox(height: 100),
                                    Center(
                                      child: Column(
                                        children: [
                                          const Text(
                                            'No conversations found.\nSwipe down to sync device.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(color: Colors.grey, fontSize: 16),
                                          ),
                                          if (deviceProvider.isConnected) ...[
                                            const SizedBox(height: 32),
                                            ElevatedButton.icon(
                                              onPressed: _spState == SyncProcessState.idle ? _startPipeline : null,
                                              icon: const FaIcon(FontAwesomeIcons.rotate, size: 16),
                                              label: const Text('Sync and Process'),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.deepPurpleAccent,
                                                foregroundColor: Colors.white,
                                              ),
                                            ),
                                          ] else ...[
                                            const SizedBox(height: 32),
                                            ElevatedButton(
                                              onPressed: () => Navigator.of(context).push(
                                                MaterialPageRoute(builder: (c) => const FindDevicesPage()),
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.deepPurpleAccent,
                                                foregroundColor: Colors.white,
                                              ),
                                              child: const Text('Connect Omi'),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                )
                              : ListView.builder(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.all(16),
                                  itemCount: visibleBatches.length,
                                  itemBuilder: (context, index) => _buildBatchCard(visibleBatches[index]),
                                ),
                        );
                      }),
              ),
            ],
          ),
        );
      },
    );
  }
}
