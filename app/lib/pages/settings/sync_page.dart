import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> implements IWalSyncProgressListener {
  static const int _logBufferSize = 50;
  static const double _logWindowHeight = 240.0;

  bool _isSyncing = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  String _statusMessage = 'Ready to sync';
  Timer? _pollTimer;
  Timer? _dropPollTimer;
  Timer? _logPollTimer;
  DeviceDropStats? _dropStats;
  // Snapshot used to render "since baseline" deltas; null = show absolute totals.
  DeviceDropStats? _dropBaseline;
  bool _dropsUnsupported = false;
  bool _dropsReading = false;
  // True once we've attempted to restore the persisted baseline this polling session.
  bool _baselineRestored = false;

  static const _kBaselineBlocks = 'drop_baseline_blocks';
  static const _kBaselineFrames = 'drop_baseline_frames';
  static const _kBaselineBoot = 'drop_baseline_boot';
  List<Map<String, dynamic>> _recentLogs = const [];

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final processing = RecordingsManager.isProcessingAny;
      if (processing != _isProcessing) setState(() => _isProcessing = processing);
    });
    // Drop-stats poll only runs when the user opts in via the Show SD Write
    // Drops toggle. Logs poll only runs when Save Diagnostic Logs is on.
    if (SharedPreferencesUtil().showSdWriteDrops) _startDropPolling();
    if (SharedPreferencesUtil().devLogsToFileEnabled) _startLogPolling();
    // Do NOT call start() here. start() fires getMissingWals() asynchronously and
    // overwrites _wals via .then(), which races with syncAll() between the moment it
    // takes its local `wals` snapshot and when it sets _isSyncing = true.
    // _wals is already populated by setDevice() when the device connected, and
    // syncAll() refreshes it internally if empty.
  }

  void _startDropPolling() {
    _dropPollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _refreshDropStats());
    unawaited(_refreshDropStats());
  }

  void _stopDropPolling() {
    _dropPollTimer?.cancel();
    _dropPollTimer = null;
    _dropStats = null;
    _dropBaseline = null;
    _dropsUnsupported = false;
    _baselineRestored = false;
  }

  void _startLogPolling() {
    _logPollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _refreshLogs());
    unawaited(_refreshLogs());
  }

  void _stopLogPolling() {
    _logPollTimer?.cancel();
    _logPollTimer = null;
    _recentLogs = const [];
  }

  Future<void> _refreshLogs() async {
    if (!mounted) return;
    final logs = await DebugLogManager.getRecentLogs(limit: _logBufferSize);
    if (!mounted) return;
    setState(() => _recentLogs = logs);
  }

  void _showProcessingSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Processing in progress — please wait until it finishes.')),
    );
  }

  Future<void> _startSync() async {
    Logger.debug('DebugTools: Sync Omi Segments tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Sync blocked — processing already running');
      _showProcessingSnackbar();
      return;
    }
    setState(() {
      _isSyncing = true;
      _progress = 0.0;
      _statusMessage = 'Connecting to device...';
    });

    try {
      final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
      if (!deviceProvider.isConnected) {
        if (!mounted) return;
        setState(() => _statusMessage = 'Connecting to device...');
        await deviceProvider.scanAndConnectToDevice();
        if (!mounted) return;
        setState(() => _statusMessage = 'Syncing segments...');
      }

      Logger.debug('DebugTools: Calling syncAll()');
      final result = await ServiceManager.instance().wal.getSyncs().syncAll(progress: this);
      deviceProvider.restartBackgroundSyncTimer();
      Logger.debug(
          'DebugTools: syncAll complete — result=${result == null ? 'null (nothing to sync)' : 'SyncLocalFilesResponse'}');
      if (!mounted) return;
      setState(() {
        if (result == null) {
          _statusMessage = 'All synced! No new segments found.';
        } else {
          _statusMessage = 'Sync Complete. Raw segments downloaded.';
        }
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: syncAll error — $e');
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Sync Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _forceSync() async {
    Logger.debug('DebugTools: Force Sync Omi tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Force sync blocked — processing already running');
      _showProcessingSnackbar();
      return;
    }
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Force Sync Omi',
        'This will close the current recording segment and sync all pending segments immediately, including recordings shorter than the usual minimum. Continue?',
        confirmText: 'Start',
      ),
    );
    if (confirm != true) {
      Logger.debug('DebugTools: Force sync cancelled by user');
      return;
    }

    setState(() {
      _isSyncing = true;
      _progress = 0.0;
      _statusMessage = 'Rotating segment and syncing...';
    });

    try {
      final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
      if (!deviceProvider.isConnected) {
        if (!mounted) return;
        setState(() => _statusMessage = 'Connecting to device...');
        await deviceProvider.scanAndConnectToDevice();
        if (!mounted) return;
        setState(() => _statusMessage = 'Rotating segment and syncing...');
      }

      Logger.debug('DebugTools: Calling rotateAndSync()');
      await ServiceManager.instance().wal.getSyncs().rotateAndSync(progress: this);
      deviceProvider.restartBackgroundSyncTimer();
      Logger.debug('DebugTools: Force sync complete');
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Force Sync Complete.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: Force sync error — $e');
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Force Sync Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _deleteAllPending() async {
    Logger.debug('DebugTools: Delete Omi Segments tapped');
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Delete Omi Segments',
        'This will permanently delete raw segments from your Omi. If a sync is running, it will be cancelled. This action cannot be undone. Continue?',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) {
      Logger.debug('DebugTools: Delete cancelled by user');
      return;
    }

    setState(() {
      _isSyncing = true;
      _statusMessage = 'Deleting segments from device...';
    });

    try {
      final syncs = ServiceManager.instance().wal.getSyncs();
      if (syncs.isSyncing) {
        Logger.debug('DebugTools: Cancelling active sync before deleting from device');
        syncs.cancelSync();
        await syncs.cancelFuture?.timeout(const Duration(seconds: 2), onTimeout: () {});
      }

      Logger.debug('DebugTools: Calling deleteAllPendingWals()');
      await syncs.deleteAllPendingWals();
      Logger.debug('DebugTools: deleteAllPendingWals complete');

      // Reset sync/processing progress state in preferences
      final prefs = SharedPreferencesUtil();
      await prefs.remove('sp_state');
      await prefs.remove('sp_synced_count');
      await prefs.remove('sp_total_count');
      await prefs.remove('sp_minutes_remaining');
      await prefs.remove('sp_marker_count');
      await prefs.remove('sp_last_completed_stage');
      await prefs.remove('sp_last_active_stage');

      // Notify UI listeners (like RecordingsPage) to refresh
      RecordingsManager.notifyRecordingsChanged();

      if (!mounted) return;
      setState(() {
        _statusMessage = 'Delete Complete. Device storage cleared.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: deleteAllPendingWals error — $e');
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Delete Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _deleteAllSegments() async {
    Logger.debug('DebugTools: Delete Phone Segments tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Delete Phone Segments blocked — processing running');
      _showProcessingSnackbar();
      return;
    }
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Delete Phone Segments',
        'This will permanently delete raw segment files stored on this phone. This action cannot be undone. Continue?',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) {
      Logger.debug('DebugTools: Delete Phone Segments cancelled by user');
      return;
    }
    setState(() {
      _isSyncing = true;
      _statusMessage = 'Deleting phone segments...';
    });
    try {
      Logger.debug('DebugTools: Deleting raw_segments directory');
      final directory = await getApplicationDocumentsDirectory();
      final segmentsDir = Directory('${directory.path}/raw_segments');
      if (await segmentsDir.exists()) {
        await segmentsDir.delete(recursive: true);
      }
      Logger.debug('DebugTools: raw_segments deleted');

      // Reset sync/processing progress state in preferences
      final prefs = SharedPreferencesUtil();
      await prefs.remove('sp_state');
      await prefs.remove('sp_synced_count');
      await prefs.remove('sp_total_count');
      await prefs.remove('sp_minutes_remaining');
      await prefs.remove('sp_marker_count');
      await prefs.remove('sp_last_completed_stage');
      await prefs.remove('sp_last_active_stage');

      // Notify UI listeners (like RecordingsPage) to refresh
      RecordingsManager.notifyRecordingsChanged();

      if (!mounted) return;
      setState(() {
        _statusMessage = 'Delete Complete. Phone segments cleared.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: _deleteAllSegments error — $e');
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Delete Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _deleteAllConversations() async {
    Logger.debug('DebugTools: Delete Phone Conversations tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Delete Phone Conversations blocked — processing running');
      _showProcessingSnackbar();
      return;
    }
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Delete Phone Conversations',
        'This will permanently delete finalized recordings and conversations on this phone, including any open conversation in progress. This action cannot be undone. Continue?',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) {
      Logger.debug('DebugTools: Delete Phone Conversations cancelled by user');
      return;
    }
    setState(() {
      _isSyncing = true;
      _statusMessage = 'Deleting phone conversations...';
    });
    try {
      final directory = await getApplicationDocumentsDirectory();

      final recordingsDir = Directory('${directory.path}/recordings');
      if (await recordingsDir.exists()) {
        Logger.debug('DebugTools: Deleting recordings directory');
        await recordingsDir.delete(recursive: true);
        Logger.debug('DebugTools: recordings directory deleted');
      }

      final tempDir = Directory('${directory.path}/processing_temp');
      if (await tempDir.exists()) {
        Logger.debug('DebugTools: Deleting processing_temp directory');
        await tempDir.delete(recursive: true);
        Logger.debug('DebugTools: processing_temp directory deleted');
      }

      // Reset sync/processing progress state in preferences
      final prefs = SharedPreferencesUtil();
      await prefs.remove('sp_state');
      await prefs.remove('sp_synced_count');
      await prefs.remove('sp_total_count');
      await prefs.remove('sp_minutes_remaining');
      await prefs.remove('sp_marker_count');
      await prefs.remove('sp_last_completed_stage');
      await prefs.remove('sp_last_active_stage');

      // Clear upload history to allow re-upload if re-processed
      prefs.heypocketUploadedFiles = [];
      await prefs.clearOmiSyncedFiles();

      // Notify UI listeners (like RecordingsPage) to refresh
      RecordingsManager.notifyRecordingsChanged();

      if (!mounted) return;
      setState(() {
        _statusMessage = 'Delete Complete. Phone conversations cleared.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: _deleteAllConversations error — $e');
      if (!mounted) return;
      setState(() {
        _statusMessage = 'Delete Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _deleteProblematicEdls() async {
    Logger.debug('DebugTools: Delete Problematic EDLs tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Delete Problematic EDLs blocked — processing running');
      _showProcessingSnackbar();
      return;
    }
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Delete Problematic EDLs',
        'This will permanently delete marker EDL files that have no matching recording (pending or orphaned). This cannot be undone. Continue?',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) {
      Logger.debug('DebugTools: Delete Problematic EDLs cancelled by user');
      return;
    }
    setState(() {
      _statusMessage = 'Scanning for problematic EDLs...';
    });
    try {
      final all = await RecordingsManager().getMarkerConversations();
      final problematic = all.where((mc) => mc.isPending).toList();
      Logger.debug('DebugTools: Found ${problematic.length} problematic EDL(s)');
      for (final mc in problematic) {
        if (await mc.edlFile.exists()) {
          await mc.edlFile.delete();
          Logger.debug('DebugTools: Deleted ${mc.edlFile.path}');
        }
      }

      RecordingsManager.notifyRecordingsChanged();
      if (!mounted) return;
      setState(() {
        _statusMessage =
            problematic.isEmpty ? 'No problematic EDLs found.' : 'Deleted ${problematic.length} problematic EDL(s).';
      });
    } catch (e) {
      Logger.error('DebugTools: _deleteProblematicEdls error — $e');
      if (!mounted) return;
      setState(() => _statusMessage = 'Delete Error: $e');
    }
  }

  Future<void> _cancelSync() async {
    Logger.debug('DebugTools: Cancel Download tapped');
    ServiceManager.instance().wal.getSyncs().cancelSync();
    setState(() {
      _isSyncing = false;
      _statusMessage = 'Sync Cancelled';
    });
  }

  Future<void> _refreshDropStats() async {
    if (_dropsUnsupported || _dropsReading) return;
    if (!mounted) return;
    final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
    final dev = deviceProvider.connectedDevice;
    if (dev == null) return;
    _dropsReading = true;
    try {
      final conn = await ServiceManager.instance().device.ensureConnection(dev.id);
      if (conn == null) return;
      // Skip during active file transfer — a GATT read racing with the notification
      // stream causes Error 133 on Android and drops the connection.
      if (conn.isStorageBusy) return;
      final stats = await conn.getDropStats();
      if (!mounted) return;
      if (stats == null) {
        setState(() => _dropsUnsupported = true);
      } else {
        setState(() => _dropStats = stats);
        _tryRestoreBaseline(stats);
      }
    } catch (_) {
      // Transient BLE errors are fine — try again on the next tick.
    } finally {
      _dropsReading = false;
    }
  }

  void _tryRestoreBaseline(DeviceDropStats stats) {
    if (_baselineRestored) return;
    _baselineRestored = true;
    final prefs = SharedPreferencesUtil();
    final savedBlocks = prefs.getInt(_kBaselineBlocks, defaultValue: -1);
    if (savedBlocks < 0) return; // no saved baseline
    final savedFrames = prefs.getInt(_kBaselineFrames, defaultValue: 0);
    final savedBoot = prefs.getInt(_kBaselineBoot, defaultValue: 0);
    // Device rebooted — counters reset below the saved baseline; discard it.
    if (stats.blockDrops < savedBlocks || stats.streamFrameDrops < savedFrames) {
      unawaited(prefs.remove(_kBaselineBlocks));
      return;
    }
    setState(() => _dropBaseline = DeviceDropStats(
          blockDrops: savedBlocks,
          lastBlockDropUptimeMs: 0,
          streamFrameDrops: savedFrames,
          bootFrameDrops: savedBoot,
          currentUptimeMs: 0,
          readAt: DateTime.now(),
        ));
  }

  void _snapshotDropBaseline() {
    final stats = _dropStats;
    if (stats == null) return;
    final prefs = SharedPreferencesUtil();
    unawaited(prefs.saveInt(_kBaselineBlocks, stats.blockDrops));
    unawaited(prefs.saveInt(_kBaselineFrames, stats.streamFrameDrops));
    unawaited(prefs.saveInt(_kBaselineBoot, stats.bootFrameDrops));
    setState(() => _dropBaseline = stats);
  }

  void _clearDropBaseline() {
    unawaited(SharedPreferencesUtil().remove(_kBaselineBlocks));
    setState(() => _dropBaseline = null);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _dropPollTimer?.cancel();
    _logPollTimer?.cancel();
    super.dispose();
  }

  @override
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase}) {
    if (mounted) {
      setState(() {
        _progress = percentage;
        _statusMessage = 'Downloading segments: ${(percentage * 100).toStringAsFixed(1)}% '
            '${speedKBps != null && speedKBps > 0 ? '(${speedKBps.toStringAsFixed(1)} KB/s)' : ''}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaIcon(FontAwesomeIcons.triangleExclamation, size: 14, color: Colors.amber),
            const SizedBox(width: 8),
            const Text('Debug Tools', style: TextStyle(color: Colors.amber)),
          ],
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              const FaIcon(FontAwesomeIcons.bug, size: 48, color: Colors.amber),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 24),
              SwitchListTile(
                title: const Text('Keep Screen On',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                subtitle: const Text('Holds a wakelock while the app is open so the screen never sleeps.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                value: SharedPreferencesUtil().keepScreenOn,
                onChanged: (val) async {
                  SharedPreferencesUtil().keepScreenOn = val;
                  await WakelockPlus.toggle(enable: val);
                  setState(() {});
                },
                activeColor: Colors.amber,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Allow Upload During Adjustment',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                subtitle: const Text('Integrations will remain active even when Adjustment Mode is enabled.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                value: SharedPreferencesUtil().allowUploadDuringAdjustment,
                onChanged: (val) {
                  setState(() {
                    SharedPreferencesUtil().allowUploadDuringAdjustment = val;
                  });
                },
                activeColor: Colors.amber,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Save Diagnostic Logs to File',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                subtitle: const Text('Persists info/debug logs to a file on your device.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                value: SharedPreferencesUtil().devLogsToFileEnabled,
                onChanged: (val) async {
                  if (val) {
                    await DebugLogManager.setEnabled(true);
                    _startLogPolling();
                  } else {
                    // Stop the 2 s poll before deleting so getRecentLogs can't
                    // recreate the file we're removing.
                    _stopLogPolling();
                    await DebugLogManager.setEnabled(false);
                  }
                  setState(() {});
                },
                activeColor: Colors.amber,
                contentPadding: EdgeInsets.zero,
              ),
              if (SharedPreferencesUtil().devLogsToFileEnabled) ...[
                const SizedBox(height: 12),
                _buildLogWindow(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          final files = await DebugLogManager.listLogFiles();
                          if (files.isEmpty) {
                            setState(() => _statusMessage = 'No log files available to share');
                            return;
                          }
                          final xFile = XFile(files.first.path);
                          await Share.shareXFiles([xFile], text: 'Omi Diagnostic Logs');
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Share Logs',
                            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await DebugLogManager.clear();
                          await _refreshLogs();
                          if (mounted) setState(() => _statusMessage = 'Diagnostic logs cleared');
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.amber, width: 1),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Clear Logs',
                            style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Show SD Write Drops',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                subtitle: const Text('Polls the device every 2 s for SD-card drop counters. Off by default.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                value: SharedPreferencesUtil().showSdWriteDrops,
                onChanged: (val) {
                  SharedPreferencesUtil().showSdWriteDrops = val;
                  if (val) {
                    _startDropPolling();
                  } else {
                    _stopDropPolling();
                  }
                  setState(() {});
                },
                activeColor: Colors.amber,
                contentPadding: EdgeInsets.zero,
              ),
              if (SharedPreferencesUtil().showSdWriteDrops) ...[
                const SizedBox(height: 12),
                _buildDropStatsSection(),
              ],
              const SizedBox(height: 24),
              const Divider(color: Color(0xFF2C2C2E), height: 1),
              const SizedBox(height: 24),
              if (_isProcessing) ...[
                const Text('Processing recordings...', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () {
                    Logger.debug('DebugTools: Cancel Processing tapped');
                    RecordingsManager.cancelProcessing();
                  },
                  icon: const FaIcon(FontAwesomeIcons.circleXmark, size: 14),
                  label: const Text('Cancel Processing'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                ),
                const SizedBox(height: 32),
              ],
              if (_isSyncing) ...[
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: Colors.grey.shade800,
                  color: Colors.deepPurpleAccent,
                  minHeight: 8,
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: _cancelSync,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  child: const Text('Cancel Download', style: TextStyle(color: Colors.white)),
                ),
              ] else ...[
                _DebugButton(
                  label: 'Sync Omi Segments',
                  description: 'Download any pending raw segments from your Omi.',
                  icon: FontAwesomeIcons.arrowDown,
                  onTap: _startSync,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Force Sync Omi',
                  description:
                      'Seals the current recording on the device and syncs everything, including the current session.',
                  icon: FontAwesomeIcons.arrowsRotate,
                  onTap: _forceSync,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Force Process Omi',
                  description: 'Process raw segments immediately, including the newest (may be incomplete).',
                  icon: FontAwesomeIcons.gears,
                  onTap: _isProcessing
                      ? null
                      : () async {
                          Logger.debug('DebugTools: Force Process Omi tapped');
                          if (RecordingsManager.isProcessingAny) {
                            Logger.debug('DebugTools: Force Process Omi blocked — processing already running');
                            _showProcessingSnackbar();
                            return;
                          }
                          setState(() => _statusMessage = 'Force processing segments...');
                          try {
                            Logger.debug('DebugTools: Calling RecordingsManager.forceProcessAll()');
                            await RecordingsManager.forceProcessAll();
                            Logger.debug('DebugTools: forceProcessAll complete');
                            if (mounted) setState(() => _statusMessage = 'Force process complete.');
                          } catch (e) {
                            Logger.error('DebugTools: forceProcessAll error — $e');
                            if (mounted) setState(() => _statusMessage = 'Force process error: $e');
                          }
                        },
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Delete Omi Segments',
                  description:
                      'Permanently deletes raw segments from your Omi. The device immediately starts a new recording file.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllPending,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Delete Phone Segments',
                  description:
                      'Permanently deletes raw, undecoded segment files downloaded to this phone. Decoded recordings and drafts are kept.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllSegments,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Delete Phone Conversations',
                  description:
                      'Permanently deletes decoded recordings on this phone — finalized conversations and in-progress drafts.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllConversations,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Delete Problematic EDLs',
                  description: 'Deletes marker EDL files with no matching recording (pending or orphaned).',
                  icon: FontAwesomeIcons.fileCircleXmark,
                  color: Colors.redAccent,
                  onTap: _deleteProblematicEdls,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogWindow() {
    // Fixed-height terminal-style scroll box. ListView with reverse:true lays
    // out the first element (the newest log, since _recentLogs is newest-first)
    // at the bottom; the box keeps the same height even when the buffer is
    // partially filled so it doesn't reflow as logs accumulate.
    return Container(
      height: _logWindowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2C2C2E)),
      ),
      child: _recentLogs.isEmpty
          ? const Center(
              child: Text('No logs yet.', style: TextStyle(color: Colors.white38, fontSize: 12)),
            )
          : ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _recentLogs.length,
              itemBuilder: (context, i) => _DiagnosticLogRow(log: _recentLogs[i]),
            ),
    );
  }

  Widget _buildDropStatsSection() {
    if (_dropsUnsupported) {
      return const Row(
        children: [
          FaIcon(FontAwesomeIcons.circleInfo, size: 13, color: Colors.white38),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'SD Write Drops unavailable (older firmware).',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      );
    }
    final stats = _dropStats;
    if (stats == null) {
      return const Row(
        children: [
          FaIcon(FontAwesomeIcons.circleNotch, size: 13, color: Colors.white38),
          SizedBox(width: 8),
          Text('Reading drop counters…', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );
    }

    final baseline = _dropBaseline;
    final blocks = baseline == null ? stats.blockDrops : (stats.blockDrops - baseline.blockDrops);
    final frames = baseline == null ? stats.streamFrameDrops : (stats.streamFrameDrops - baseline.streamFrameDrops);
    final boot = stats.bootFrameDrops; // boot drops are fixed at boot; baseline doesn't apply
    final hasFreshDrops = blocks > 0 || frames > 0;

    final color = hasFreshDrops ? Colors.amber : Colors.white70;

    String lastDropLabel;
    final sinceMs = stats.msSinceLastBlockDrop;
    if (sinceMs == null) {
      lastDropLabel = 'never';
    } else {
      lastDropLabel = '${_formatDuration(sinceMs)} ago';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2C2C2E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FaIcon(FontAwesomeIcons.solidHardDrive, size: 13, color: color),
              const SizedBox(width: 8),
              Text(
                baseline == null ? 'SD Write Drops' : 'SD Write Drops (since reset)',
                style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _dropStatRow('440 B blocks dropped', blocks.toString(), hasFreshDrops),
          _dropStatRow('Audio frames dropped (SD queue)', frames.toString(), hasFreshDrops),
          _dropStatRow('Boot-window frame drops', boot.toString(), false),
          _dropStatRow('Last block drop', lastDropLabel, hasFreshDrops),
          _dropStatRow('Device uptime', _formatDuration(stats.currentUptimeMs), false),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _snapshotDropBaseline,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.amber, width: 1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 12),
              minimumSize: const Size(double.infinity, 0),
            ),
            child: const Text('Reset to zero',
                style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _dropStatRow(String label, String value, bool emphasize) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          Text(
            value,
            style: TextStyle(
              color: emphasize ? Colors.amber : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    final s = ms ~/ 1000;
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final rs = s % 60;
    if (m < 60) return '${m}m ${rs}s';
    final h = m ~/ 60;
    final rm = m % 60;
    return '${h}h ${rm}m';
  }
}

class _DiagnosticLogRow extends StatelessWidget {
  final Map<String, dynamic> log;

  const _DiagnosticLogRow({required this.log});

  @override
  Widget build(BuildContext context) {
    final level = (log['level'] as String?) ?? 'INFO';
    final message = (log['message'] as String?) ?? '';
    final type = (log['type'] as String?) ?? '';
    final ts = (log['timestamp'] as String?) ?? (log['ts'] as String?) ?? '';

    final color = level == 'ERROR' ? Colors.redAccent : Colors.white70;
    final icon = level == 'ERROR'
        ? FontAwesomeIcons.circleXmark
        : (level == 'WARN' ? FontAwesomeIcons.circleExclamation : FontAwesomeIcons.circleInfo);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FaIcon(icon, size: 12, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.isNotEmpty ? message : type,
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (ts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(ts, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugButton extends StatelessWidget {
  final String label;
  final String description;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _DebugButton({
    required this.label,
    required this.description,
    required this.icon,
    this.color = Colors.deepPurpleAccent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.4 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
          ),
          child: Row(
            children: [
              FaIcon(icon, size: 16, color: color),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(description, style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
              ),
              const FaIcon(FontAwesomeIcons.chevronRight, size: 12, color: Color(0xFF3C3C43)),
            ],
          ),
        ),
      ),
    );
  }
}
