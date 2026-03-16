import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
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

  // Processing state
  String? _processingDateString;
  double _processingProgress = 0.0;

  Timer? _syncPollTimer;
  bool _wasProcessing = false;
  bool _isAnyProcessing = false;

  @override
  void initState() {
    super.initState();
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
    final serviceIsSyncing = ServiceManager.instance().wal.getSyncs().isSyncing;
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
    if (_wasProcessing && !isProcessing) {
      _loadBatches();
    }
    _wasProcessing = isProcessing;
  }

  Future<void> _loadBatches() async {
    setState(() => _isLoading = true);
    final batches = await _manager.getDailyBatches();
    if (mounted) {
      setState(() {
        _batches = batches;
        _isLoading = false;
      });
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

        // Auto-process days that have raw chunks, but only when sync fully completed.
        // Skipping on partial transfer avoids processing truncated data that will be
        // re-downloaded and overwritten on the next sync.
        final syncWasComplete = result != null && !result.isPartial;
        if (syncWasComplete) {
          for (var batch in _batches) {
            if (batch.rawChunks.isNotEmpty) {
              await _processBatch(batch);
            }
          }
        }
      }
    }
  }

  Future<void> _processBatch(DailyBatch batch) async {
    if (RecordingsManager.isProcessingAny || _isSyncing) return;

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
    });
    WakelockPlus.enable();

    try {
      await _manager.processDay(batch, (progress) {
        if (mounted) setState(() => _processingProgress = progress);
      });
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

  Future<void> _exportAll(DailyBatch batch) async {
    if (batch.processedRecordings.isEmpty) return;
    final files = batch.processedRecordings.map((f) => XFile(f.path)).toList();
    await SharePlus.instance.share(ShareParams(files: files, subject: 'Recordings – ${batch.dateString}'));
  }

  Widget _buildSyncStatus() {
    if (!_isSyncing) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurpleAccent),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Syncing Recordings...',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
              Text('${_syncSpeed.toStringAsFixed(1)} KB/s',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => ServiceManager.instance().wal.getSyncs().cancelSync(),
                child: FaIcon(FontAwesomeIcons.circleXmark, color: Colors.grey.shade600, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _syncProgress,
              minHeight: 6,
              backgroundColor: Colors.grey.shade800,
              color: Colors.deepPurpleAccent,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$_syncRecordingsCount Chunks to Sync', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              Text('${(_syncProgress * 100).toInt()}%',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBatchCard(DailyBatch batch) {
    final isProcessingThisBatch = _processingDateString == batch.dateString;
    // Show spinner only for the batch being manually processed; disable button for all when any processing is active
    final isProcessing = isProcessingThisBatch;
    final isButtonDisabled = _isAnyProcessing || isProcessingThisBatch;
    final recordings = batch.processedRecordings.map(RecordingInfo.fromFile).toList();

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
                        Text(
                          '~${batch.rawChunks.length} min unprocessed',
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                        ElevatedButton(
                          onPressed: isButtonDisabled ? null : () => _processBatch(batch),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurpleAccent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(40, 40),
                            padding: const EdgeInsets.all(10),
                          ),
                          child: isProcessing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const FaIcon(FontAwesomeIcons.gears, size: 16),
                        ),
                      ],
                    ),
                    if (isProcessing) ...[
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
                    onPressed: () => _exportAll(batch),
                    icon: FaIcon(FontAwesomeIcons.shareFromSquare, size: 13, color: Colors.grey.shade400),
                    label: Text('Export All', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                  ),
                  TextButton.icon(
                    key: Key('delete_day_${batch.dateString}'),
                    onPressed: () => _deleteDay(batch),
                    icon: FaIcon(FontAwesomeIcons.trashCan, size: 13, color: Colors.red.shade400),
                    label: Text('Delete Day', style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
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
                icon: const FaIcon(FontAwesomeIcons.gear, color: Colors.white, size: 20),
                onPressed: () => SettingsDrawer.show(context),
              ),
            ],
          ),
          body: Column(
            children: [
              _buildStorageWarning(deviceProvider.storageFullPercentage),
              _buildSyncStatus(),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
                    : RefreshIndicator(
                        color: Colors.deepPurpleAccent,
                        onRefresh: _handleSync,
                        child: _batches.isEmpty
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
                                itemCount: _batches.length,
                                itemBuilder: (context, index) => _buildBatchCard(_batches[index]),
                              ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
