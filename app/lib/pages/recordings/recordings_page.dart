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
import 'package:wakelock_plus/wakelock_plus.dart';

class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> implements IWalSyncProgressListener {
  final RecordingsManager _manager = RecordingsManager();

  List<DailyBatch> _batches = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  bool _syncUserTriggered = false;
  double _syncProgress = 0.0;
  double _syncSpeed = 0.0;
  int _syncRecordingsCount = 0;

  final _prefs = SharedPreferencesUtil();

  // Filter state
  bool _filterEnabled = SharedPreferencesUtil().recordingsFilterEnabled;
  int _filterMinutes = SharedPreferencesUtil().recordingsFilterMinutes;

  // HeyPocket upload state
  final Set<String> _uploadingFiles = {};
  int _autoUploadActive = 0;
  String _lastHpKey = '';

  // Processing state
  String? _processingDateString;
  double _processingProgress = 0.0;
  bool _cancelPending = false;

  Timer? _syncPollTimer;
  bool _wasProcessing = false;
  bool _isAnyProcessing = false;

  @override
  void initState() {
    super.initState();
    _lastHpKey = _prefs.heypocketApiKey;
    _loadBatches();
    final syncService = ServiceManager.instance().wal.getSyncs();
    syncService.setGlobalProgressListener(this);
    _syncPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollSyncState());
  }

  @override
  void dispose() {
    _syncPollTimer?.cancel();
    ServiceManager.instance().wal.getSyncs().setGlobalProgressListener(null);
    super.dispose();
  }

  void _pollSyncState() {
    if (!mounted) return;
    final syncs = ServiceManager.instance().wal.getSyncs();
    final serviceIsSyncing = syncs.isSyncing;
    if (serviceIsSyncing && !_isSyncing) {
      // External sync started (DeviceProvider triggered it)
      setState(() => _isSyncing = true);
    } else if (!serviceIsSyncing && _isSyncing && !_syncUserTriggered) {
      // External sync finished — don't reload yet, processing may follow
      setState(() {
        _isSyncing = false;
        _syncProgress = 0.0;
        _syncSpeed = 0.0;
      });
    }

    // Track background processing state and reload when it finishes
    final isProcessing = RecordingsManager.isProcessingAny;
    if (isProcessing != _isAnyProcessing) {
      setState(() => _isAnyProcessing = isProcessing);
    }
    if (_wasProcessing && !isProcessing && !_isLoading) {
      _loadBatches();
    }
    _wasProcessing = isProcessing;

    // Refresh upload icons if HeyPocket key was set from integrations page
    final currentKey = _prefs.heypocketApiKey;
    if (currentKey != _lastHpKey) {
      _lastHpKey = currentKey;
      setState(() {});
      if (currentKey.isNotEmpty) _tryAutoUploadNext();
    }
  }

  Future<void> _loadBatches() async {
    setState(() => _isLoading = true);
    try {
      final batches = await _manager.getDailyBatches();
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

  @override
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase}) {
    if (mounted) {
      setState(() {
        _syncProgress = percentage.clamp(0.0, 0.99);
        _syncSpeed = speedKBps ?? 0.0;
        _syncRecordingsCount = ServiceManager.instance().wal.getSyncs().estimatedTotalChunks;
      });
    }
  }

  Future<void> _handleSync() async {
    if (RecordingsManager.isProcessingAny) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Processing in progress — sync will be available when done.')),
      );
      return;
    }
    await _performSync(force: false);
  }

  Future<void> _handleForceSync() async {
    await _performSync(force: true);
  }

  Future<void> _performSync({bool force = false}) async {
    if (_isSyncing || RecordingsManager.isProcessingAny) return;

    setState(() {
      _isSyncing = true;
      _syncUserTriggered = true;
      _syncProgress = 0.0;
      _syncSpeed = 0.0;
      _syncRecordingsCount = ServiceManager.instance().wal.getSyncs().estimatedTotalChunks;
    });
    WakelockPlus.enable();

    SyncLocalFilesResponse? result;
    try {
      final syncService = ServiceManager.instance().wal.getSyncs();
      result = await syncService.syncAll(progress: this, force: force);

      if (mounted) {
        if (result != null && (result.newConversationIds.isNotEmpty || result.updatedConversationIds.isNotEmpty)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Sync complete! New recordings found.")),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Sync complete. No new data.")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Sync failed: $e")),
        );
      }
    } finally {
      WakelockPlus.disable();
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncUserTriggered = false;
        });
        await _loadBatches();

        // Auto-process after sync — background mode (flush only completed, keep open recording).
        // _processBatch handles the large-batch dialog and skips if another process is running.
        for (var batch in _batches) {
          if (batch.rawChunks.isNotEmpty) {
            await _processBatch(batch, backgroundMode: true);
          }
        }
      }
    }
  }

  Future<void> _processBatch(DailyBatch batch, {bool backgroundMode = false}) async {
    if (RecordingsManager.isProcessingAny || _isSyncing) {
      if (_isSyncing) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync in progress — processing will be available when sync finishes.')),
        );
      }
      return;
    }

    if (batch.rawChunks.length > 60) {
      bool? confirm = await showDialog<bool>(
        context: context,
        builder: (c) => getDialog(
          context,
          () => Navigator.of(context).pop(false),
          () => Navigator.of(context).pop(true),
          "Large Batch",
          "This day has over ${batch.rawChunks.length} minutes of unprocessed audio. Processing might take a few minutes. Continue?",
          confirmText: "Start",
        ),
      );
      if (confirm != true) return;
    }

    setState(() {
      _processingDateString = batch.dateString;
      _processingProgress = 0.0;
      _cancelPending = false;
      // In adjustment mode, wipe existing recordings from view immediately
      // so the user sees them gone rather than zeroed-out placeholders.
      if (SharedPreferencesUtil().offlineAdjustmentMode) {
        final idx = _batches.indexWhere((b) => b.dateString == batch.dateString);
        if (idx >= 0) {
          final b = _batches[idx];
          _batches[idx] = DailyBatch(
            dateString: b.dateString,
            date: b.date,
            rawChunks: b.rawChunks,
            processedRecordings: [],
            starredTimestamps: b.starredTimestamps,
          );
        }
      }
    });
    WakelockPlus.enable();

    try {
      await _manager.processDay(batch, (progress) {
        // Cap at 95% — the final flush/save/move can take significant time
        // after the frame loop completes. The spinner clearing signals "done".
        if (mounted) setState(() => _processingProgress = (progress * 0.95).clamp(0.0, 0.95));
      }, backgroundMode: backgroundMode);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error processing day: $e')),
        );
      }
    } finally {
      WakelockPlus.disable();
      if (mounted) {
        setState(() {
          _processingDateString = null;
          _processingProgress = 0.0;
          _cancelPending = false;
        });
        _loadBatches();
      }
    }
  }

  Future<void> _deleteDay(DailyBatch batch) async {
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
        messenger.showSnackBar(SnackBar(content: Text('Error deleting day: $e')));
      }
    }
  }

  Future<void> _exportAll(DailyBatch batch, List<RecordingInfo> visibleRecordings) async {
    if (visibleRecordings.isEmpty) return;
    final files = visibleRecordings.map((r) => XFile(r.file.path)).toList();
    await SharePlus.instance.share(ShareParams(files: files, subject: 'Recordings – ${batch.dateString}'));
  }

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
                      Text('$_filterMinutes min', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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

  void _tryAutoUploadNext() {
    if (!_prefs.heypocketEnabled || _prefs.heypocketApiKey.isEmpty) return;
    final apiKey = _prefs.heypocketApiKey;
    final keySetAt = _prefs.heypocketKeySetAt;
    final keySetTime = keySetAt > 0 ? DateTime.fromMillisecondsSinceEpoch(keySetAt) : null;
    for (final batch in _batches) {
      for (final file in batch.processedRecordings) {
        if (_autoUploadActive >= 2) return;
        final rec = RecordingInfo.fromFile(file);
        // Only auto-upload recordings created after the API key was configured.
        if (keySetTime != null && rec.startTime.isBefore(keySetTime)) continue;
        if (_filterEnabled && rec.duration < Duration(minutes: _filterMinutes)) continue;
        final uploadKey = rec.uploadKey;
        if (uploadKey == null) continue;
        if (_prefs.isUploadedToHeypocket(uploadKey)) continue;
        if (_uploadingFiles.contains(uploadKey)) continue;
        _uploadingFiles.add(uploadKey);
        _autoUploadActive++;
        if (mounted) setState(() {});
        unawaited(
          HeyPocketService.uploadRecording(apiKey, rec)
              .then((_) {
                _prefs.markUploadedToHeypocket(uploadKey);
              })
              .catchError((e) {
                debugPrint('HeyPocket auto-upload failed: $e');
              })
              .whenComplete(() {
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

  Future<void> _handleUploadTap(RecordingInfo rec) async {
    final uploadKey = rec.uploadKey;
    if (uploadKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload key unavailable — please reconnect your device and try again.')),
      );
      return;
    }
    if (_uploadingFiles.contains(uploadKey)) return;

    final alreadyUploaded = _prefs.isUploadedToHeypocket(uploadKey);
    final title = alreadyUploaded ? 'Re-upload Recording' : 'Upload Recording';
    final content = alreadyUploaded
        ? 'This recording was already uploaded to HeyPocket. Upload again? (It may create a duplicate.)'
        : 'Upload this recording to HeyPocket?';

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
      HeyPocketService.uploadRecording(apiKey, rec)
          .then((_) {
            _prefs.markUploadedToHeypocket(uploadKey);
          })
          .catchError((e) {
            if (e is HeyPocketException) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('HeyPocket ${e.statusCode}: ${e.message}')),
                );
              }
            }
            debugPrint('HeyPocket upload failed: $e');
          })
          .whenComplete(() {
            _uploadingFiles.remove(uploadKey);
            if (mounted) setState(() {});
          }),
    );
  }

  Widget _buildUploadIcon(RecordingInfo rec) {
    if (_prefs.heypocketApiKey.isEmpty) return const SizedBox.shrink();
    final uploadKey = rec.uploadKey;
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
        onPressed: () => _handleUploadTap(rec),
      );
    }
    return IconButton(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      constraints: const BoxConstraints(),
      icon: const Icon(Icons.cloud_upload, color: Colors.redAccent, size: 18),
      onPressed: () => _handleUploadTap(rec),
    );
  }

  Widget _buildStatusBanner() {
    if (!_isSyncing && !_isAnyProcessing) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _isSyncing ? _buildSyncContent() : _buildProcessingContent(),
    );
  }

  Widget _buildSyncContent() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Syncing recordings...', style: TextStyle(color: Colors.grey.shade400)),
                const SizedBox(height: 2),
                Text('${_syncSpeed.toStringAsFixed(1)} KB/s · $_syncRecordingsCount chunks',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
              ],
            ),
            ElevatedButton(
              onPressed: () => ServiceManager.instance().wal.getSyncs().cancelSync(),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                minimumSize: const Size(40, 40),
                padding: const EdgeInsets.all(10),
              ),
              child: const FaIcon(FontAwesomeIcons.circleXmark, size: 16),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: LinearProgressIndicator(
                value: _syncProgress,
                backgroundColor: Colors.grey.shade800,
                color: Colors.deepPurpleAccent,
              ),
            ),
            const SizedBox(width: 12),
            Text('${(_syncProgress * 100).toInt()}%',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  Widget _buildProcessingContent() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _processingDateString != null ? 'Processing $_processingDateString...' : 'Processing recordings...',
                  style: TextStyle(color: Colors.grey.shade400),
                ),
                const SizedBox(height: 2),
                Text('Processing in progress', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
              ],
            ),
            ElevatedButton(
              onPressed: _cancelPending
                  ? null
                  : () {
                      setState(() => _cancelPending = true);
                      RecordingsManager.cancelProcessing();
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                minimumSize: const Size(40, 40),
                padding: const EdgeInsets.all(10),
              ),
              child: _cancelPending
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const FaIcon(FontAwesomeIcons.circleXmark, size: 16),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: LinearProgressIndicator(
                value: _processingDateString != null ? _processingProgress : null,
                backgroundColor: Colors.grey.shade800,
                color: Colors.deepPurpleAccent,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _processingDateString != null ? '${(_processingProgress * 100).toInt()}%' : '...',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBatchCard(DailyBatch batch) {
    final isProcessingThisBatch = _processingDateString == batch.dateString;
    final isButtonDisabled = _isAnyProcessing || isProcessingThisBatch;
    final allRecordings = batch.processedRecordings.map(RecordingInfo.fromFile).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final minDuration = Duration(minutes: _filterMinutes);
    final recordings = (_filterEnabled && _filterMinutes > 0)
        ? allRecordings.where((r) => r.duration >= minDuration).toList()
        : allRecordings;

    return Card(
      color: const Color(0xFF1C1C1E),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  batch.dateString,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (batch.starredTimestamps.isNotEmpty)
                  Row(
                    children: [
                      const FaIcon(FontAwesomeIcons.solidStar, color: Colors.amber, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        '${batch.starredTimestamps.length}',
                        style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Raw chunks / process button
            if (batch.rawChunks.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '~${batch.rawChunks.length} min open recording',
                              style: TextStyle(color: Colors.grey.shade400),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Tap \u2699 to save and close',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                            ),
                          ],
                        ),
                        ElevatedButton(
                          onPressed: isProcessingThisBatch
                              ? (_cancelPending
                                  ? null
                                  : () {
                                      setState(() => _cancelPending = true);
                                      RecordingsManager.cancelProcessing();
                                    })
                              : (isButtonDisabled ? null : () => _processBatch(batch)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isProcessingThisBatch ? Colors.redAccent : Colors.deepPurpleAccent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(40, 40),
                            padding: const EdgeInsets.all(10),
                          ),
                          child: isProcessingThisBatch
                              ? (_cancelPending
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                    )
                                  : const FaIcon(FontAwesomeIcons.circleXmark, size: 16))
                              : const FaIcon(FontAwesomeIcons.gears, size: 16),
                        ),
                      ],
                    ),
                    if (isProcessingThisBatch) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: _processingProgress,
                              backgroundColor: Colors.grey.shade800,
                              color: Colors.deepPurpleAccent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '${(_processingProgress * 100).toInt()}%',
                            style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Processed recordings list
            if (recordings.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text('No processed recordings yet.', style: TextStyle(color: Colors.grey.shade500)),
              )
            else ...[
              ...recordings.map((rec) => _buildRecordingTile(rec)),
              const SizedBox(height: 4),
              const Divider(color: Color(0xFF2C2C2E), height: 1),
              const SizedBox(height: 4),

              // Action row: Export All + Delete Day
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    key: Key('export_all_${batch.dateString}'),
                    onPressed: () => _exportAll(batch, recordings),
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

  Widget _buildRecordingTile(RecordingInfo rec) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RecordingPlayerPage(recording: rec)),
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
                    rec.timeRangeLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${rec.durationLabel}  ·  ${rec.sizeLabel}',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            ),
            _buildUploadIcon(rec),
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

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceProvider>(
      builder: (context, deviceProvider, child) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D0D0D),
          appBar: AppBar(
            title: const Text('Daily Recordings', style: TextStyle(color: Colors.white)),
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
                IconButton(
                  icon: const FaIcon(FontAwesomeIcons.bluetooth, color: Colors.blueAccent, size: 20),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (c) => const DeviceSettings()),
                  ),
                ),
              IconButton(
                icon: FaIcon(
                  FontAwesomeIcons.sliders,
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
              _buildStatusBanner(),
              if (_filterEnabled && _filterMinutes > 0)
                Container(
                  width: double.infinity,
                  color: Colors.deepPurpleAccent.withValues(alpha: 0.15),
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                  child: Text(
                    'Showing recordings \u2265 $_filterMinutes min',
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
                                if (b.rawChunks.isNotEmpty) return true;
                                return b.processedRecordings
                                    .any((f) => RecordingInfo.fromFile(f).duration >= minDuration);
                              }).toList()
                            : _batches;
                        return RefreshIndicator(
                        color: Colors.deepPurpleAccent,
                        onRefresh: _handleSync,
                        child: visibleBatches.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  const SizedBox(height: 100),
                                  Center(
                                    child: Column(
                                      children: [
                                        const Text(
                                          'No recordings found.\nSwipe down to sync device.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.grey, fontSize: 16),
                                        ),
                                        if (deviceProvider.isConnected) ...[
                                          const SizedBox(height: 32),
                                          ElevatedButton.icon(
                                            onPressed: _isSyncing ? null : _handleForceSync,
                                            icon: const FaIcon(FontAwesomeIcons.rotate, size: 16),
                                            label: const Text("Sync All From Device"),
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
                                            child: const Text("Connect Omi"),
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
