import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/mutex.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/pages/settings/widgets/debug_button.dart';
import 'package:omi/pages/settings/widgets/diagnostic_log_row.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:share_plus/share_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
  // Live drop-counter notifications (0x0062). The firmware pushes these while
  // subscribed, so counters keep updating during a sync — a GATT read would race
  // the sync stream (Error 133 on Android).
  StreamSubscription<List<int>>? _dropStatsSub;
  // Connection we subscribed on, kept so we can unsubscribe at the BLE layer
  // (CCCD=0) on teardown even from dispose(), where we can't await a fresh lookup.
  DeviceConnection? _dropConn;
  // Liveness tracking. The native subscribe (CCCD write) is fire-and-forget, so a
  // live-but-silent stream (failed write, or a link recycled onto a new controller)
  // can't be detected any other way.
  // Tracked against a monotonic clock (_dropClock), NOT DateTime.now(): a backward
  // wall-clock adjustment (NTP/DST/manual) would otherwise make a dead stream look
  // freshly-active and defeat the stale-subscription watchdog.
  // _dropSubscribedElapsed: _dropClock.elapsed when the sub was established.
  // _lastDropNotifyElapsed: _dropClock.elapsed at the last notification (null = none yet).
  final Stopwatch _dropClock = Stopwatch()..start();
  Duration? _dropSubscribedElapsed;
  Duration? _lastDropNotifyElapsed;
  // Pending (subscribed, no notification yet): the firmware pushes immediately on
  // subscribe, so a short window is enough — if nothing arrives the CCCD write
  // failed and we re-subscribe. Established: allow gaps up to the timeout, which
  // must exceed the firmware's 15 s idle heartbeat.
  static const _dropPendingTimeout = Duration(seconds: 6);
  static const _dropSilenceTimeout = Duration(seconds: 35);
  // Serializes subscribe vs teardown so an async teardown's BLE unsubscribe can't
  // land on a freshly re-subscribed stream (fast Show-Diagnostics off/on).
  final Mutex _dropMutex = Mutex();
  // Bumped whenever the subscription intent is invalidated (teardown / stop) so an
  // in-flight subscribe or a stale onClosed can't act on a superseded generation.
  int _dropSubGen = 0;
  DeviceDropStats? _dropStats;
  // Snapshot used to render "since baseline" deltas; null = show absolute totals.
  DeviceDropStats? _dropBaseline;
  // SD-queue peak depth is a monotonic since-boot high-water mark in firmware, so
  // it can't be delta-subtracted like the cumulative counters. Instead we keep our
  // own high-water mark of the values seen since the last "Zero all counters" tap:
  // reset it to 0 and let it re-climb from the next reading upward.
  int _peakSinceReset = 0;
  // True once we've attempted to restore the persisted baseline this polling session.
  bool _baselineRestored = false;

  // Full boot-relative baseline snapshot (all counters that reset to 0 on device
  // reboot), stored as JSON so a "reset diagnostics" tap survives an app restart.
  static const _kBaselineJson = 'drop_baseline_json';
  static const _kBaselineConnFail = 'conn_fail_baseline';
  static const _kBaselineEstabFail = 'estab_fail_baseline';
  // Superseded pre-JSON baseline keys, removed once on upgrade (see _tryRestoreBaseline).
  static const _kLegacyBaselineBlocks = 'drop_baseline_blocks';
  static const _kLegacyBaselineKeys = [
    _kLegacyBaselineBlocks,
    'drop_baseline_frames',
    'drop_baseline_boot',
    'drop_baseline_codec',
  ];
  // BLE connect-fail baselines (app-side). Unlike _dropBaseline they survive a
  // device reboot, because the firmware counters are flash-persisted.
  int? _connFailBaseline;
  int? _estabFailBaseline;
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
    // The timer's only job is to establish (and, if it drops, re-establish) the
    // notify subscription; once subscribed, notifications — not the timer — drive
    // the UI. A subscribe during an active transfer can lose the CCCD-write race,
    // so the tick retries until it lands.
    _dropPollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _ensureDropSubscription());
    unawaited(_ensureDropSubscription());
  }

  void _stopDropPolling() {
    _dropPollTimer?.cancel();
    _dropPollTimer = null;
    unawaited(_teardownDropSubscription());
    _dropStats = null;
    _dropBaseline = null;
    _peakSinceReset = 0;
    _connFailBaseline = null;
    _estabFailBaseline = null;
    _baselineRestored = false;
  }

  /// Cancel the Dart sub and stop the device pushing (CCCD=0). Assumes the caller
  /// already holds [_dropMutex].
  Future<void> _dropTeardownLocked() async {
    final sub = _dropStatsSub;
    final conn = _dropConn;
    _dropStatsSub = null;
    _dropConn = null;
    _dropSubscribedElapsed = null;
    _lastDropNotifyElapsed = null;
    await sub?.cancel();
    // Write CCCD=0 so the firmware stops pushing, and drop the transport's stream
    // controller so a later re-subscribe issues a fresh CCCD write. Best-effort;
    // a real disconnect also unsubscribes, and it no-ops on a recycled connection.
    await conn?.unsubscribeDropStats();
  }

  /// Teardown for stop()/dispose(). Bumps the generation synchronously (so a
  /// fire-and-forget call invalidates in-flight work immediately), then serializes
  /// the actual cancel/unsubscribe behind [_dropMutex] so it can't interleave with
  /// a concurrent re-subscribe.
  Future<void> _teardownDropSubscription() async {
    _dropSubGen++;
    await _dropMutex.acquire();
    try {
      await _dropTeardownLocked();
    } finally {
      _dropMutex.release();
    }
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
      if (!mounted) return;
      final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
      if (!deviceProvider.isConnected) {
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

  // Normal (non-forcing) process: the exact pass that runs automatically after a
  // real sync — decode + VAD, skips already-covered bins, and leaves the
  // in-progress recording open as a draft until it ends naturally. Pairs with
  // "Sync Omi Segments" to make this page a self-contained sync→process harness.
  Future<void> _process() async {
    Logger.debug('DebugTools: Process Omi Segments tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Process blocked — processing already running');
      _showProcessingSnackbar();
      return;
    }
    setState(() => _statusMessage = 'Processing segments...');
    try {
      Logger.debug('DebugTools: Calling RecordingsManager.processAllCompletedSessions()');
      await RecordingsManager.processAllCompletedSessions();
      Logger.debug('DebugTools: processAllCompletedSessions complete');
      if (mounted) setState(() => _statusMessage = 'Process complete.');
    } catch (e) {
      Logger.error('DebugTools: processAllCompletedSessions error — $e');
      if (mounted) setState(() => _statusMessage = 'Process error: $e');
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
        'This will permanently delete ALL raw segment files AND discarded (recoverable) segments stored on this '
            'phone — any pending recoveries are lost. This action cannot be undone. Continue?',
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
      Logger.debug('DebugTools: Deleting raw_segments + discarded_segments directories');
      final directory = await getApplicationDocumentsDirectory();
      for (final base in ['raw_segments', RecordingsManager.discardedSegmentsDirName]) {
        final segmentsDir = Directory('${directory.path}/$base');
        if (await segmentsDir.exists()) {
          await segmentsDir.delete(recursive: true);
        }
      }
      Logger.debug('DebugTools: raw_segments + discarded_segments deleted');

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

  // Healthy = we have a subscription that is actually delivering. The native
  // subscribe is fire-and-forget, so a subscription object alone doesn't prove
  // notifications flow: while pending (subscribed, no notification yet) we allow
  // only a short window before re-subscribing; once established, gaps up to the
  // silence timeout are fine.
  bool get _dropSubHealthy {
    if (_dropStatsSub == null) return false;
    final now = _dropClock.elapsed;
    final last = _lastDropNotifyElapsed;
    if (last != null) return now - last < _dropSilenceTimeout;
    final since = _dropSubscribedElapsed;
    return since != null && now - since < _dropPendingTimeout;
  }

  Future<void> _ensureDropSubscription() async {
    // Healthy subscription — notifications drive _dropStats directly. isLocked skips
    // ticks while a subscribe/teardown is already running (acquire sets it
    // synchronously on the uncontended path, so this guard is race-free).
    if (_dropMutex.isLocked) return;
    if (!mounted) return;
    final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
    final dev = deviceProvider.connectedDevice;
    if (dev == null) return;
    // Fast path only if the live subscription belongs to the *currently* connected
    // device. A device switch while this page stays mounted must tear down and
    // re-subscribe; otherwise the card keeps showing the previous device's counters.
    if (_dropSubHealthy && _dropConn?.device.id == dev.id) return;
    await _dropMutex.acquire();
    try {
      // Re-check under the lock — a teardown/subscribe may have run while we waited.
      if (_dropSubHealthy && _dropConn?.device.id == dev.id) return;
      // Tear down any dead/silent subscription first (awaited, under the lock) so the
      // transport's stream controller is gone before we re-subscribe — otherwise
      // getCharacteristicStream reuses the stale controller and skips the CCCD write.
      if (_dropStatsSub != null || _dropConn != null) await _dropTeardownLocked();
      final gen = _dropSubGen;
      final conn = await ServiceManager.instance().device.ensureConnection(dev.id);
      // Bail if the connection died, the widget went away, or stop()/another
      // teardown superseded this attempt while we awaited.
      if (conn == null || !mounted || gen != _dropSubGen) return;
      final sub = await conn.getDropStatsListener(
        onDropStats: (stats) {
          if (!mounted || gen != _dropSubGen) return;
          _lastDropNotifyElapsed = _dropClock.elapsed;
          setState(() {
            _dropStats = stats;
            if (stats.msgqPeakDepth > _peakSinceReset) _peakSinceReset = stats.msgqPeakDepth;
          });
          _tryRestoreBaseline(stats);
        },
        // Stream closed (disconnect) — the transport re-subscribes on reconnect
        // via a new controller this sub isn't attached to, so drop it and let the
        // next tick re-establish. Ignored if a newer generation already took over.
        onClosed: () {
          if (gen != _dropSubGen) return;
          _dropStatsSub = null;
          _dropSubscribedElapsed = null;
          _lastDropNotifyElapsed = null;
        },
      );
      if (!mounted || gen != _dropSubGen) {
        // stop()/dispose ran while we awaited; its teardown found nothing because we
        // hadn't stored the sub/conn yet. Tear down what we just created via the
        // connection — this cancels the Dart sub AND writes CCCD=0 / drops the
        // controller — or the device keeps notifying to a listener-less stream.
        await conn.unsubscribeDropStats();
        return;
      }
      // Subscribe writes the CCCD; during a transfer that write can lose the race
      // (Error 133) and return null — retry next tick. Mark it pending (not yet
      // notified); the pending-timeout watchdog re-subscribes if the CCCD write
      // silently failed and no notification ever arrives.
      if (sub != null) {
        _dropStatsSub = sub;
        _dropConn = conn;
        _dropSubscribedElapsed = _dropClock.elapsed;
        _lastDropNotifyElapsed = null;
      }
    } catch (_) {
      // Transient BLE error — retry on the next tick.
    } finally {
      _dropMutex.release();
    }
  }

  void _tryRestoreBaseline(DeviceDropStats stats) {
    if (_baselineRestored) return;
    _baselineRestored = true;
    final prefs = SharedPreferencesUtil();

    // SD-drop / lifecycle baseline: app-side, covers every boot-relative counter
    // (all of them reset to 0 when the device reboots). Discarded on reboot —
    // detected by a counter having dropped below the baseline (the only thing that
    // can move one backwards), which the saved baseline would otherwise
    // over-subtract. Uptime is intentionally not used for this: it wraps every
    // ~49.7 days on the firmware's uint32-ms clock, which is not a reboot.
    final savedJson = prefs.getString(_kBaselineJson);
    if (savedJson.isNotEmpty) {
      final saved = DeviceDropStats.fromBaselineJson(savedJson);
      if (saved == null || stats.looksRebootedFrom(saved)) {
        unawaited(prefs.remove(_kBaselineJson));
      } else {
        setState(() => _dropBaseline = saved);
      }
    } else if (prefs.getInt(_kLegacyBaselineBlocks, defaultValue: -1) >= 0) {
      // One-time cleanup of the pre-JSON four-key baseline, now superseded by the
      // single JSON snapshot. Its value isn't carried forward: it covered only 4 of
      // the counters, and a partial baseline is exactly the confusing half-reset
      // this screen moved away from — the user re-taps once if they still want it.
      for (final k in _kLegacyBaselineKeys) {
        unawaited(prefs.remove(k));
      }
    }

    // BLE connect-fail baselines: SURVIVE reboot (firmware counters are flash-
    // persisted). Only discard if a counter went backwards — i.e. the device's
    // flash was wiped / re-flashed below the saved baseline.
    final savedConnFail = prefs.getInt(_kBaselineConnFail, defaultValue: -1);
    if (savedConnFail >= 0) {
      if (stats.failedConnCount < savedConnFail) {
        unawaited(prefs.remove(_kBaselineConnFail));
      } else {
        setState(() => _connFailBaseline = savedConnFail);
      }
    }

    final savedEstabFail = prefs.getInt(_kBaselineEstabFail, defaultValue: -1);
    if (savedEstabFail >= 0) {
      if (stats.estabFailCount < savedEstabFail) {
        unawaited(prefs.remove(_kBaselineEstabFail));
      } else {
        setState(() => _estabFailBaseline = savedEstabFail);
      }
    }
  }

  void _snapshotDropBaseline() {
    final stats = _dropStats;
    if (stats == null) return;
    unawaited(SharedPreferencesUtil().saveString(_kBaselineJson, stats.toBaselineJson()));
    setState(() => _dropBaseline = stats);
  }

  void _snapshotConnFailBaseline() {
    final stats = _dropStats;
    if (stats == null) return;
    final prefs = SharedPreferencesUtil();
    unawaited(prefs.saveInt(_kBaselineConnFail, stats.failedConnCount));
    unawaited(prefs.saveInt(_kBaselineEstabFail, stats.estabFailCount));
    setState(() {
      _connFailBaseline = stats.failedConnCount;
      _estabFailBaseline = stats.estabFailCount;
    });
  }

  /// Baseline every diagnostic counter on the card in one tap so they all read 0
  /// from now on: the SD-drop counters, the write-path and Priority-Recording
  /// lifecycle counters, and the BLE connect-fail counters. Display-only — the
  /// firmware keeps its own running totals; this only moves the app's subtraction
  /// baseline. Device uptime is intentionally left live.
  void _resetAllDiagnostics() {
    _snapshotDropBaseline();
    _snapshotConnFailBaseline();
    // Peak depth has no baseline to subtract — zero our high-water mark so it
    // re-climbs from the next reading (the next value > 0), not from the old peak.
    setState(() => _peakSinceReset = 0);
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
    // Cancel the Dart sub and tell the device to stop pushing (CCCD=0); can't await
    // in dispose, so fire-and-forget — the generation bump runs synchronously.
    unawaited(_teardownDropSubscription());
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

  // Companion Device Pairing applies immediately — it has side effects (a
  // disconnect/reconnect, and the system pairing chooser when enabling), so it sits
  // outside any save/discard flow. OFF: reconnect so native manageDevice clears the
  // association now. ON: disconnect (so the Omi advertises), pop the system companion
  // chooser, then reconnect. Both directions need the disconnect first —
  // ensureConnection(force) is a no-op while connected (so manageDevice wouldn't re-run),
  // and a connected Omi (MAX_CONN=1) isn't advertising for the chooser to find.
  Future<void> _setCompanionDevicePairing(bool value) async {
    SharedPreferencesUtil().companionDeviceEnabled = value;
    setState(() {});

    final deviceId = SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) return; // no paired device — applies on next connect

    final deviceService = ServiceManager.instance().device;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(value ? 'Enabling companion pairing…' : 'Disabling companion pairing…'),
    ));

    try {
      await deviceService.disconnectDevice(isManual: true);

      if (value && !(await deviceService.hasCompanionDeviceAssociation())) {
        final addr = await deviceService.requestCompanionDeviceAssociation(deviceId);
        if (addr.isEmpty) {
          // Chooser cancelled — revert so the toggle reflects reality.
          SharedPreferencesUtil().companionDeviceEnabled = false;
          if (mounted) setState(() {});
        }
      }

      // Reconnect: native manageDevice clears the association when off, no-op when on.
      await deviceService.ensureConnection(deviceId, force: true);
    } catch (e) {
      Logger.error('SyncPage: companion pairing toggle failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FaIcon(FontAwesomeIcons.triangleExclamation, size: 14, color: Colors.amber),
            SizedBox(width: 8),
            Text('Debug Tools', style: TextStyle(color: Colors.amber)),
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
              // Companion Device Pairing (Android) — default ON. A troubleshooting toggle
              // for the rare OEM where registering as a system companion makes Bluetooth
              // reconnection worse; lives here in Debug Tools so it stays reachable when the
              // device won't connect. Applies immediately via _setCompanionDevicePairing
              // (reconnect on off, system chooser on on).
              if (Platform.isAndroid) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Companion Device Pairing',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      SharedPreferencesUtil().companionDeviceEnabled
                          ? 'On (recommended) — lets the app fix a stuck Bluetooth connection on its own, instead of you having to toggle phone Bluetooth. Turn off only if reconnecting gets worse with this on.'
                          : "Off — the app connects without registering as a system companion. Turn on (recommended) to help it recover from stuck Bluetooth connections; it'll reconnect and show a pairing dialog.",
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                    value: SharedPreferencesUtil().companionDeviceEnabled,
                    onChanged: (value) => _setCompanionDevicePairing(value),
                    activeThumbColor: Colors.deepPurpleAccent,
                  ),
                ),
                const SizedBox(height: 16),
              ],
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
                  activeThumbColor: Colors.deepPurpleAccent,
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
                  subtitle: Text(
                      'Persists info/debug logs to a file on your device. '
                      'Leave on to capture BLE connection outages automatically, as they happen.',
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
                  activeThumbColor: Colors.deepPurpleAccent,
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

                          String appVersion = 'unknown';
                          try {
                            final packageInfo = await PackageInfo.fromPlatform();
                            appVersion = packageInfo.version;
                          } catch (_) {}

                          final fwVersion =
                              context.read<DeviceProvider>().connectedDevice?.firmwareRevision ?? 'unknown';
                          final os = Platform.operatingSystem;

                          final datePart = logName.replaceFirst('omi_debug_', '');
                          final shareName = '${os}_${appVersion}_${fwVersion}_omi_offline_debug_$datePart';
                          // Name the XFile (not just the share `subject`) so the name lands on
                          // targets that use the file's own name, not the title.
                          final xFile = XFile(files.first.path, name: shareName);
                          // Use `subject` (share-sheet/email title metadata), not `text`:
                          // a `text` argument is shared as a SEPARATE item alongside the
                          // file, so iOS upload/save targets materialize a second phantom
                          // file containing the label string.
                          await SharePlus.instance.share(ShareParams(files: [xFile], subject: shareName));
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
                  activeThumbColor: Colors.deepPurpleAccent,
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
                  label: 'Process Omi Segments',
                  description:
                      'Decode and process downloaded segments the normal way — leaves the in-progress recording open until it ends.',
                  icon: FontAwesomeIcons.gear,
                  onTap: _isProcessing ? null : _process,
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
            activeThumbColor: Colors.deepPurpleAccent,
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
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _reprocessAllFromSegments,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.orangeAccent, width: 1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size(double.infinity, 0),
              ),
              child: const Text('Reprocess All from Segments',
                  style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
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
    setState(() => _statusMessage = 'Copying adjustment bins…');
    Logger.debug('Adjustment: copy-for-reprocessing started');
    int copied = 0;
    int failed = 0;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final adjDir = Directory('${directory.path}/adjustment_mode_segments');
      final rawDir = Directory('${directory.path}/raw_segments');
      if (!await adjDir.exists()) {
        Logger.debug('Adjustment: no adjustment_mode_segments folder — nothing to copy');
        _reportCopyResult('No adjustment bins found to copy.');
        return;
      }
      await for (final file in adjDir.list(recursive: true)) {
        if (file is! File || !file.path.endsWith('.bin')) continue;
        final relPath = file.path.substring(adjDir.path.length + 1);
        final destPath = '${rawDir.path}/$relPath';
        try {
          final destFile = File(destPath);
          if (!await destFile.parent.exists()) await destFile.parent.create(recursive: true);
          await file.copy(destPath);
          copied++;
        } catch (e) {
          failed++;
          Logger.error('Adjustment: failed to copy ${file.path} → $destPath: $e');
        }
      }
      Logger.info('Adjustment: copied $copied bin(s) adjustment_mode_segments → raw_segments'
          '${failed > 0 ? ' ($failed failed)' : ''} — sync/process to reprocess');
      await _refreshAdjustmentBinCount();
      _reportCopyResult(copied == 0
          ? 'No bins copied — adjustment folder is empty.'
          : 'Copied $copied bin(s) to raw_segments${failed > 0 ? ' · $failed failed' : ''}. Run Sync/Process to reprocess.');
    } catch (e) {
      Logger.error('Adjustment: copy-for-reprocessing failed: $e');
      _reportCopyResult('Copy failed: $e');
    }
  }

  /// Adjustment-mode re-derive: reprocess EVERY retained segment, rebuilding all
  /// recordings (including finalized ones) from their raw bins. This is the
  /// destructive intent the routine Force Process button no longer has — gated
  /// behind a confirm so it's never a surprise.
  Future<void> _reprocessAllFromSegments() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        c,
        () => Navigator.of(c).pop(false),
        () => Navigator.of(c).pop(true),
        'Reprocess all from segments?',
        'This re-runs voice detection on every retained segment and REBUILDS all recordings — including '
            'finalized ones, whose boundaries may change or merge/split differently. Use this only to re-cut '
            'from saved bins.',
        confirmText: 'Reprocess',
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _statusMessage = 'Reprocessing all from segments…');
    Logger.info('Adjustment: reprocess-all-from-segments requested');
    try {
      await RecordingsManager.forceProcessAll(reprocessCovered: true);
      _reportCopyResult('Reprocessed all segments — recordings rebuilt from raw bins.');
    } catch (e) {
      Logger.error('Adjustment: reprocess-all-from-segments failed: $e');
      _reportCopyResult('Reprocess failed: $e');
    }
  }

  /// Surfaces a copy-bins result both inline (status line) and as a snackbar so
  /// the action always gives visible feedback.
  void _reportCopyResult(String message) {
    if (!mounted) return;
    setState(() => _statusMessage = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
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

    // Every firmware counter here resets to 0 on device reboot, so "Reset all
    // diagnostics" baselines them uniformly: show the value since the last reset,
    // clamped at 0 so a stale baseline never renders a negative. (The connect-fail
    // counters survive reboot and carry their own int baselines below.)
    final baseline = _dropBaseline;
    int rel(int current, int Function(DeviceDropStats b) pick) =>
        baseline == null ? current : (current - pick(baseline)).clamp(0, current);

    final blocks = rel(stats.blockDrops, (b) => b.blockDrops);
    final frames = rel(stats.streamFrameDrops, (b) => b.streamFrameDrops);
    final codec = rel(stats.codecFrameDrops, (b) => b.codecFrameDrops);
    final boot = rel(stats.bootFrameDrops, (b) => b.bootFrameDrops);
    // Peak depth is a monotonic high-water mark, not an incremental counter, so it
    // can't be delta-subtracted. Show our own high-water mark since the last reset:
    // "Zero all counters" sets it to 0 and it re-climbs from the next reading up.
    final peak = _peakSinceReset;
    final writeFair = rel(stats.writeFairActivations, (b) => b.writeFairActivations);
    final prioStarts = rel(stats.priorityRecordStarts, (b) => b.priorityRecordStarts);
    final prioStops = rel(stats.priorityRecordStops, (b) => b.priorityRecordStops);
    final markerDrops = rel(stats.markerWriteDrops, (b) => b.markerWriteDrops);
    final emptyRot = rel(stats.emptyBinRotations, (b) => b.emptyBinRotations);
    final seEmits = rel(stats.sessionEndMarkerEmits, (b) => b.sessionEndMarkerEmits);
    final pauseSaves = rel(stats.markerPauseGateSaves, (b) => b.markerPauseGateSaves);
    // Peak thread stack usage vs the configured stack sizes (firmware constants:
    // SD_WORKER_STACK_SIZE=16384, codec_stack=19000). Gauges, shown raw. Large unused
    // headroom = the stack is over-provisioned and can be trimmed to reclaim RAM.
    // Highlighted only when usage is close to the ceiling (>85% = overflow risk).
    const int sdWorkerStackSize = 16384;
    const int codecStackSize = 19000;
    String stackLabel(int used, int size) =>
        used == 0 ? '—' : '${(used / 1024).toStringAsFixed(1)} / ${(size / 1024).toStringAsFixed(1)} KB';
    final sdStackHot = stats.sdWorkerStackUsed > sdWorkerStackSize * 0.85;
    final codecStackHot = stats.codecStackUsed > codecStackSize * 0.85;
    final hasFreshDrops = blocks > 0 || frames > 0 || codec > 0;
    final connFails = _connFailBaseline == null ? stats.failedConnCount : (stats.failedConnCount - _connFailBaseline!);
    final estabFails = _estabFailBaseline == null ? stats.estabFailCount : (stats.estabFailCount - _estabFailBaseline!);

    final color = hasFreshDrops ? Colors.amber : Colors.white70;

    String lastDropLabel;
    final sinceMs = stats.msSinceLastBlockDrop;
    // "Since reset" is derived from the block-drop count rising (blocks > 0), not
    // the drop's uptime: a reboot that a zero-counter baseline can't flag (see
    // looksRebootedFrom) resets the device uptime below the captured value, which
    // an uptime comparison would misread as "before reset" — hiding a genuine
    // post-reset drop as "never" while the count row shows it. Keying off the same
    // delta keeps the two rows consistent.
    final noDropSinceReset = baseline != null && blocks == 0;
    if (sinceMs == null || noDropSinceReset) {
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
          // Write-path headroom. Peak depth is a high-water mark, so after a reset it
          // reads 0 until the queue climbs past where it stood at the reset, then shows
          // that live peak out of the firmware's queue limit (stats.sdQueueMax — 120 on
          // oo-2.6.2+, 100 on older firmware); near the limit means the write path is
          // riding the drop edge. Fairness activations just show the read-vs-write
          // arbiter engaging — not a fault.
          _dropStatRow('SD queue peak depth', '$peak / ${stats.sdQueueMax}', peak >= (stats.sdQueueMax * 0.8).round()),
          _dropStatRow('Write-fairness activations', writeFair.toString(), false),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(color: Color(0xFF2C2C2E), height: 1),
          ),
          // Priority Recording lifecycle (0x0062, since reset). starts > stops means
          // a recording was left open; marker-write drops and empty-bin rotations are
          // the on-device fingerprint of a lost Priority Recording (0xFFFFFFF8 marker
          // + audio dropped at the rotate). Amber when a start has no matching stop or
          // either loss counter is nonzero.
          _dropStatRow('Priority recordings started', prioStarts.toString(), false),
          _dropStatRow('Priority recordings stopped', prioStops.toString(), prioStarts > prioStops),
          _dropStatRow('Marker writes dropped', markerDrops.toString(), markerDrops > 0),
          _dropStatRow('Empty bin rotations', emptyRot.toString(), emptyRot > 0),
          // Confirms the stop marker (0xFFFFFFFC) is written, not lost: "Session-end
          // marker emits" is how many times the firmware finalize path fired; "Markers
          // kept at SD pause gate" is how many marker blocks were written through a
          // pause instead of dropped (before oo-2.5.9 these were the silent loss). Both
          // moving with recordings finalizing = the fix working; emits flat means the
          // finalize path never fired. Kept is a rescue, so it is not highlighted.
          // Amber when a priority stop happened but no session-end marker was emitted
          // (stops > 0, emits == 0) — that's the finalize path never firing, the exact
          // failure these counters exist to catch.
          _dropStatRow('Session-end marker emits', seEmits.toString(), prioStops > 0 && seEmits == 0),
          _dropStatRow('Markers kept at SD pause gate', pauseSaves.toString(), false),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(color: Color(0xFF2C2C2E), height: 1),
          ),
          // Peak thread stack usage (0x0062). Read after a heavy session (an allocator
          // scan is the SD worker's deepest path; busy encoding is the codec's) so the
          // high-water reflects the worst case. Big gap below the configured size means
          // reclaimable RAM; amber = riding the ceiling (overflow risk, do NOT trim).
          _dropStatRow('SD worker stack', stackLabel(stats.sdWorkerStackUsed, sdWorkerStackSize), sdStackHot),
          _dropStatRow('Codec stack', stackLabel(stats.codecStackUsed, codecStackSize), codecStackHot),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(color: Color(0xFF2C2C2E), height: 1),
          ),
          // BLE connect failures. The firmware counters are persisted across
          // reboots; these baselines are too, unlike the SD-drop baseline.
          // "Died at establishment" is the one that identifies a "visible but
          // unconnectable" outage — if the phone logs 0x3e while this stays 0,
          // the Omi never heard the connect requests and the phone is at fault.
          // See NOTES.md "BLE: advertising but won't connect".
          _dropStatRow('BLE connect failures', connFails.toString(), connFails > 0),
          _dropStatRow('Died at establishment (0x3e)', estabFails.toString(), estabFails > 0),
          // Gated on the since-reset deltas, not the lifetime totals: the adv mode
          // describes whichever failure the two rows above are reporting. Keying it on
          // the totals kept the row visible (and red) after a reset that zeroed both.
          if (connFails > 0 || estabFails > 0)
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
              child: const Text('Zero all counters (display only)',
                  style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Snapshots the current values as a baseline so every counter above reads 0 from now. '
              'Nothing is cleared on the device — it keeps its own totals until it reboots.',
              style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.3),
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
