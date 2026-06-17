import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
import 'package:omi/pages/settings/widgets/debug_button.dart';
import 'package:omi/pages/settings/widgets/diagnostic_log_row.dart';
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
  bool _dropsWaitingSync = false;
  // True once we've attempted to restore the persisted baseline this polling session.
  bool _baselineRestored = false;

  static const _kBaselineBlocks = 'drop_baseline_blocks';
  static const _kBaselineFrames = 'drop_baseline_frames';
  static const _kBaselineBoot = 'drop_baseline_boot';
  static const _kBaselineCodec = 'drop_baseline_codec';
  static const _kBaselineConnFail = 'conn_fail_baseline';
  // BLE connect-fail baseline (app-side). Unlike _dropBaseline it survives a
  // device reboot, because the firmware counter is flash-persisted.
  int? _connFailBaseline;
  List<Map<String, dynamic>> _recentLogs = const [];

  // Count of .bin files held in the isolated Adjustment Mode folder. Refreshed
  // on entering the Debug menu and after toggling Adjustment Mode.
  int _adjustmentBinCount = 0;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final processing = RecordingsManager.isProcessingAny;
      if (processing != _isProcessing) setState(() => _isProcessing = processing);
    });
    // Diagnostics poll only runs when the user opts in via the Show Diagnostics
    // toggle. Logs poll only runs when Save Diagnostic Logs is on.
    if (SharedPreferencesUtil().showSdWriteDrops) _startDropPolling();
    if (SharedPreferencesUtil().devLogsToFileEnabled) _startLogPolling();
    // Refresh the Adjustment Mode bin count whenever the Debug menu is opened.
    unawaited(_refreshAdjustmentBinCount());
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
    _connFailBaseline = null;
    _dropsUnsupported = false;
    _dropsWaitingSync = false;
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
      if (conn.isStorageBusy) {
        if (!_dropsWaitingSync) setState(() => _dropsWaitingSync = true);
        return;
      }
      if (_dropsWaitingSync) setState(() => _dropsWaitingSync = false);
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

    // SD-drop baseline: app-side, discarded when the device reboots (those
    // counters reset to 0 on reboot, so the saved baseline would over-subtract).
    final savedBlocks = prefs.getInt(_kBaselineBlocks, defaultValue: -1);
    if (savedBlocks >= 0) {
      final savedFrames = prefs.getInt(_kBaselineFrames, defaultValue: 0);
      final savedBoot = prefs.getInt(_kBaselineBoot, defaultValue: 0);
      final savedCodec = prefs.getInt(_kBaselineCodec, defaultValue: 0);
      if (stats.blockDrops < savedBlocks ||
          stats.streamFrameDrops < savedFrames ||
          stats.codecFrameDrops < savedCodec) {
        unawaited(prefs.remove(_kBaselineBlocks));
      } else {
        setState(() => _dropBaseline = DeviceDropStats(
              blockDrops: savedBlocks,
              lastBlockDropUptimeMs: 0,
              streamFrameDrops: savedFrames,
              bootFrameDrops: savedBoot,
              currentUptimeMs: 0,
              codecFrameDrops: savedCodec,
              readAt: DateTime.now(),
            ));
      }
    }

    // BLE connect-fail baseline: SURVIVES reboot (firmware counter is flash-
    // persisted). Only discard if the counter went backwards — i.e. the device's
    // flash was wiped / re-flashed below the saved baseline.
    final savedConnFail = prefs.getInt(_kBaselineConnFail, defaultValue: -1);
    if (savedConnFail >= 0) {
      if (stats.failedConnCount < savedConnFail) {
        unawaited(prefs.remove(_kBaselineConnFail));
      } else {
        setState(() => _connFailBaseline = savedConnFail);
      }
    }
  }

  void _snapshotDropBaseline() {
    final stats = _dropStats;
    if (stats == null) return;
    final prefs = SharedPreferencesUtil();
    unawaited(prefs.saveInt(_kBaselineBlocks, stats.blockDrops));
    unawaited(prefs.saveInt(_kBaselineFrames, stats.streamFrameDrops));
    unawaited(prefs.saveInt(_kBaselineBoot, stats.bootFrameDrops));
    unawaited(prefs.saveInt(_kBaselineCodec, stats.codecFrameDrops));
    setState(() => _dropBaseline = stats);
  }

  void _snapshotConnFailBaseline() {
    final stats = _dropStats;
    if (stats == null) return;
    unawaited(SharedPreferencesUtil().saveInt(_kBaselineConnFail, stats.failedConnCount));
    setState(() => _connFailBaseline = stats.failedConnCount);
  }

  /// Reset every diagnostic counter (SD-queue/block/codec drops + BLE connect
  /// failures) to a fresh baseline in one tap.
  void _resetAllDiagnostics() {
    _snapshotDropBaseline();
    _snapshotConnFailBaseline();
  }

  /// Counts `.bin` files in the isolated Adjustment Mode folder.
  Future<void> _refreshAdjustmentBinCount() async {
    int count = 0;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final adjDir = Directory('${directory.path}/adjustment_mode_segments');
      if (await adjDir.exists()) {
        await for (final e in adjDir.list(recursive: true)) {
          if (e is File && e.path.endsWith('.bin')) count++;
        }
      }
    } catch (_) {
      // Best-effort count — leave at 0 on any filesystem error.
    }
    if (mounted) setState(() => _adjustmentBinCount = count);
  }

  /// True if an in-progress recording (`*_draft.*`) exists on disk.
  Future<bool> _hasDraftInProgress() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final recDir = Directory('${directory.path}/recordings');
      if (!await recDir.exists()) return false;
      await for (final e in recDir.list(recursive: true)) {
        if (e is File && e.path.contains('_draft.')) return true;
      }
    } catch (_) {}
    return false;
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
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile(
                  title: const Text('Keep Screen On',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  subtitle: Text('Holds a wakelock while the app is open so the screen never sleeps.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                  value: SharedPreferencesUtil().keepScreenOn,
                  onChanged: (val) async {
                    SharedPreferencesUtil().keepScreenOn = val;
                    await WakelockPlus.toggle(enable: val);
                    setState(() {});
                  },
                  activeColor: Colors.deepPurpleAccent,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile(
                  title: const Text('Save Debug Logs to File',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  subtitle: Text('Persists info/debug logs to a file on your device.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
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
                  activeColor: Colors.deepPurpleAccent,
                  contentPadding: EdgeInsets.zero,
                ),
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
                          // Name the shared file `omi_offline_debug_<date>.log` — lowercase,
                          // underscored, no spaces/apostrophes, so it's easy to work with on
                          // upload/save targets. Derived from the on-disk basename
                          // (`omi_debug_YYYYMMDD.log`) so the date matches exactly.
                          final logName = files.first.uri.pathSegments.last;
                          final shareName = logName.replaceFirst('omi_debug_', 'omi_offline_debug_');
                          // Name the XFile (not just the share `subject`) so the name lands on
                          // targets that use the file's own name, not the title.
                          final xFile = XFile(files.first.path, name: shareName);
                          // Use `subject` (share-sheet/email title metadata), not `text`:
                          // a `text` argument is shared as a SEPARATE item alongside the
                          // file, so iOS upload/save targets materialize a second phantom
                          // file containing the label string.
                          await Share.shareXFiles([xFile], subject: shareName);
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
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile(
                  title: const Text('Show Diagnostics',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  subtitle: Text('Polls the device every 2 s for SD-card, codec and BLE drop counters. Off by default.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
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
                  activeColor: Colors.deepPurpleAccent,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (SharedPreferencesUtil().showSdWriteDrops) ...[
                const SizedBox(height: 16),
                _buildDropStatsSection(),
              ],
              const SizedBox(height: 16),
              _buildAdjustmentModeSection(),
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
                DebugButton(
                  label: 'Sync Omi Segments',
                  description: 'Download any pending raw segments from your Omi.',
                  icon: FontAwesomeIcons.arrowDown,
                  onTap: _startSync,
                ),
                const SizedBox(height: 12),
                DebugButton(
                  label: 'Force Sync Omi',
                  description:
                      'Seals the current recording on the device and syncs everything, including the current session.',
                  icon: FontAwesomeIcons.arrowsRotate,
                  onTap: _forceSync,
                ),
                const SizedBox(height: 12),
                DebugButton(
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
                DebugButton(
                  label: 'Delete Omi Segments',
                  description:
                      'Permanently deletes raw segments from your Omi. The device immediately starts a new recording file.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllPending,
                ),
                const SizedBox(height: 12),
                DebugButton(
                  label: 'Delete Phone Segments',
                  description:
                      'Permanently deletes raw, undecoded segment files downloaded to this phone. Decoded recordings and drafts are kept.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllSegments,
                ),
                const SizedBox(height: 12),
                DebugButton(
                  label: 'Delete Phone Conversations',
                  description:
                      'Permanently deletes decoded recordings on this phone — finalized conversations and in-progress drafts.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllConversations,
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
              itemBuilder: (context, i) => DiagnosticLogRow(log: _recentLogs[i]),
            ),
    );
  }

  Widget _buildAdjustmentModeSection() {
    final on = SharedPreferencesUtil().adjustmentMode;
    final enabledAtMs = SharedPreferencesUtil().adjustmentModeEnabledAt;
    final enabledAtLabel =
        enabledAtMs > 0 ? DateFormat('MMM d, h:mm a').format(DateTime.fromMillisecondsSinceEpoch(enabledAtMs)) : '—';

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
          SwitchListTile(
            title: const Text('Adjustment Mode',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            subtitle: Text('Copies all raw bins into an isolated folder for safe reprocessing.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
            value: on,
            onChanged: _onAdjustmentModeToggled,
            activeColor: Colors.deepPurpleAccent,
            contentPadding: EdgeInsets.zero,
          ),
          if (on) ...[
            const SizedBox(height: 4),
            _dropStatRow('Enabled at', enabledAtLabel, false),
            _dropStatRow('Bins in adjustment folder', _adjustmentBinCount.toString(), false),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _copyAdjustmentBinsForReprocessing,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.deepPurpleAccent, width: 1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size(double.infinity, 0),
              ),
              child: const Text('Copy Bins for Reprocessing',
                  style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold)),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _onAdjustmentModeToggled(bool val) async {
    final prefs = SharedPreferencesUtil();
    if (val) {
      // If a recording is in progress, confirm finalizing it before entering AM —
      // turning on Adjustment Mode promotes the in-progress draft to a conversation.
      final hasDraft = await _hasDraftInProgress();
      if (hasDraft) {
        if (!mounted) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (c) => getDialog(
            context,
            () => Navigator.of(context).pop(false),
            () => Navigator.of(context).pop(true),
            'Finalize Current Recording?',
            'You have a recording in progress. Turning on Adjustment Mode will finalize it into a conversation. Continue?',
            confirmText: 'Finalize & Continue',
          ),
        );
        if (confirm != true) return; // leave the toggle off
      }
      prefs.adjustmentMode = true;
      prefs.adjustmentModeEnabledAt = DateTime.now().millisecondsSinceEpoch;
      if (mounted) setState(() {});
      await _refreshAdjustmentBinCount();
      // forceProcessAll finalizes the in-progress draft; the lighter
      // processAllCompletedSessions leaves drafts untouched when there are none.
      if (hasDraft) {
        await RecordingsManager.forceProcessAll();
      } else {
        await RecordingsManager.processAllCompletedSessions();
      }
      return;
    }

    // Turning OFF wipes the isolated copy of raw bins. Confirm first when there's
    // actually an archive to lose; leave the toggle ON (driven by the pref) if the
    // user cancels.
    final directory = await getApplicationDocumentsDirectory();
    final adjDir = Directory('${directory.path}/adjustment_mode_segments');
    final hasArchive = await adjDir.exists();
    if (hasArchive) {
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (c) => getDialog(
          context,
          () => Navigator.of(context).pop(false),
          () => Navigator.of(context).pop(true),
          'Turn Off Adjustment Mode',
          'This deletes the isolated copy of raw bins kept for reprocessing. This cannot be undone. Continue?',
          confirmText: 'Turn Off',
        ),
      );
      if (confirm != true) return;
    }

    prefs.adjustmentMode = false;
    prefs.adjustmentModeEnabledAt = 0;
    if (mounted) setState(() {});
    if (hasArchive) {
      await adjDir.delete(recursive: true);
    }
    await _refreshAdjustmentBinCount();
  }

  Future<void> _copyAdjustmentBinsForReprocessing() async {
    setState(() => _statusMessage = 'Copying adjustment bins...');
    final directory = await getApplicationDocumentsDirectory();
    final adjDir = Directory('${directory.path}/adjustment_mode_segments');
    final rawDir = Directory('${directory.path}/raw_segments');
    if (await adjDir.exists()) {
      await for (final file in adjDir.list(recursive: true)) {
        if (file is File) {
          final relPath = file.path.substring(adjDir.path.length + 1);
          final destPath = '${rawDir.path}/$relPath';
          final destFile = File(destPath);
          if (!await destFile.parent.exists()) {
            await destFile.parent.create(recursive: true);
          }
          await file.copy(destPath);
        }
      }
      if (mounted) setState(() => _statusMessage = 'Adjustment bins copied to raw_segments');
    } else {
      if (mounted) setState(() => _statusMessage = 'No adjustment bins found.');
    }
  }

  Widget _buildDropStatsSection() {
    final devProvider = Provider.of<DeviceProvider>(context);
    if (!devProvider.isConnected || devProvider.connectedDevice == null) {
      return const Row(
        children: [
          FaIcon(FontAwesomeIcons.circleNotch, size: 13, color: Colors.white38),
          SizedBox(width: 8),
          Text('Waiting for device connection…', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );
    }

    if (_dropsUnsupported) {
      return const Row(
        children: [
          FaIcon(FontAwesomeIcons.circleInfo, size: 13, color: Colors.white38),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Diagnostics unavailable (older firmware).',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      );
    }
    final stats = _dropStats;
    if (stats == null) {
      final waitLabel = _dropsWaitingSync ? 'Waiting for sync to complete…' : 'Reading drop counters…';
      return Row(
        children: [
          const FaIcon(FontAwesomeIcons.circleNotch, size: 13, color: Colors.white38),
          const SizedBox(width: 8),
          Text(waitLabel, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );
    }

    final baseline = _dropBaseline;
    final blocks = baseline == null ? stats.blockDrops : (stats.blockDrops - baseline.blockDrops);
    final frames = baseline == null ? stats.streamFrameDrops : (stats.streamFrameDrops - baseline.streamFrameDrops);
    final codec = baseline == null ? stats.codecFrameDrops : (stats.codecFrameDrops - baseline.codecFrameDrops);
    final boot = stats.bootFrameDrops; // boot drops are fixed at boot; baseline doesn't apply
    final hasFreshDrops = blocks > 0 || frames > 0 || codec > 0;
    final connFails = _connFailBaseline == null ? stats.failedConnCount : (stats.failedConnCount - _connFailBaseline!);

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
                (baseline == null && _connFailBaseline == null) ? 'Diagnostics' : 'Diagnostics (since reset)',
                style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _dropStatRow('440 B blocks dropped', blocks.toString(), hasFreshDrops),
          _dropStatRow('Audio frames dropped (SD queue)', frames.toString(), hasFreshDrops),
          _dropStatRow('Audio dropped pre-encode (codec)', codec.toString(), codec > 0),
          _dropStatRow('Boot-window frame drops', boot.toString(), false),
          _dropStatRow('Last block drop', lastDropLabel, hasFreshDrops),
          _dropStatRow('Device uptime', _formatDuration(stats.currentUptimeMs), false),
          // Write-path headroom (since boot; not baseline-adjusted). Peak depth
          // near the queue limit (100) means the write path is riding the drop
          // edge; a low peak means plenty of headroom. Fairness activations just
          // show the read-vs-write arbiter engaging — informational, not a fault.
          _dropStatRow('SD queue peak depth', '${stats.msgqPeakDepth} / 100', stats.msgqPeakDepth >= 80),
          _dropStatRow('Write-fairness activations', stats.writeFairActivations.toString(), false),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(color: Color(0xFF2C2C2E), height: 1),
          ),
          // BLE connect-establishment failures. The firmware counter is
          // persisted across reboots; this baseline ("Reset BLE") is too, unlike
          // the SD-drop baseline. See NOTES.md "BLE: advertising but won't connect".
          _dropStatRow('BLE connect failures', connFails.toString(), connFails > 0),
          if (stats.failedConnCount > 0)
            _dropStatRow('Last fail adv mode', stats.lastFailedConnDuringSlowAdv ? 'slow (1s)' : 'fast', true),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _resetAllDiagnostics,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.amber, width: 1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Reset all diagnostics',
                  style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
            ),
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
