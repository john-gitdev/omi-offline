import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
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
import 'package:omi/pages/settings/widgets/diagnostics_widgets.dart';
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
  // Poll-start reference for the READ-fallback staleness check when no notification
  // has ever arrived (small-MTU link). Set in _startDropPolling, cleared on stop.
  Duration? _dropPollStartElapsed;
  // Pending (subscribed, no notification yet): the firmware pushes immediately on
  // subscribe, so a short window is enough — if nothing arrives the CCCD write
  // failed and we re-subscribe. Established: allow gaps up to the timeout, which
  // must exceed the firmware's 15 s idle heartbeat.
  static const _dropPendingTimeout = Duration(seconds: 6);
  static const _dropSilenceTimeout = Duration(seconds: 35);
  // Notify path considered stale after this long with no notification (measured from
  // the last real notification, or poll-start if none ever arrived). Sits above the
  // 15 s idle notify cadence so a healthy idle stream never trips it. On a link whose
  // MTU can't fit the 76 B notification the firmware can't push at all (-EMSGSIZE); a
  // plain READ (ATT read-blob, not MTU-bounded) is the fallback. See _dropTick /
  // _readDropStatsFallback.
  static const _dropReadFallbackAfter = Duration(seconds: 20);
  // Serializes subscribe vs teardown so an async teardown's BLE unsubscribe can't
  // land on a freshly re-subscribed stream (fast Show-Diagnostics off/on).
  final Mutex _dropMutex = Mutex();
  // _dropClock.elapsed when _dropStats was last replaced, by either the notify or the
  // READ path. Drives the freshness pill. Monotonic for the same reason the
  // subscription watchdog is: a backward wall-clock adjustment (NTP/DST/manual) would
  // otherwise make stale data read as fresh — the one thing the pill exists to catch.
  Duration? _lastStatsElapsed;
  // Bumped whenever the subscription intent is invalidated (teardown / stop) so an
  // in-flight subscribe or a stale onClosed can't act on a superseded generation.
  int _dropSubGen = 0;
  // Latest counter snapshot. Deliberately not cleared on a device change: only one Omi
  // is ever paired and connected, so there is no switch for it to survive (see "One Omi
  // at a time" in CLAUDE.md). A reconnect re-subscribes and overwrites it.
  DeviceDropStats? _dropStats;
  // Active storage backend read once per subscription (0=LittleFS, 1=ring). null
  // until read, or when the firmware predates the status_flags field.
  int? _storageBackend;
  // Snapshot used to render "since baseline" deltas; null = show absolute totals.
  DeviceDropStats? _dropBaseline;
  // True once we've attempted to restore the persisted baseline this polling session.
  bool _baselineRestored = false;
  // View selector for the counter rows once a baseline exists. Taking a baseline
  // used to be a one-way door — the persisted snapshot was re-restored on every
  // entry, so the device's lifetime totals became permanently unreachable in the
  // UI. This flips the view without touching the stored baseline.
  bool _showLifetime = false;
  // Active event-log category filter; null = show all.
  DiagEventCategory? _eventFilter;

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
    // Diagnostics poll only runs when the user opts in via the Diagnostics switch
    // (which also gates the on-device event log — see _setDiagnosticsEnabled). Logs
    // poll only runs when Save Debug Logs is on.
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
    // The timer establishes (and, if it drops, re-establishes) the notify
    // subscription; once subscribed, notifications — not the timer — drive the UI.
    // A subscribe during an active transfer can lose the CCCD-write race, so the tick
    // retries until it lands. The tick also runs the READ-fallback for links whose
    // MTU can't carry the notification (see _dropTick).
    _dropPollStartElapsed = _dropClock.elapsed;
    _dropPollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _dropTick());
    unawaited(_dropTick());
  }

  void _stopDropPolling() {
    _dropPollTimer?.cancel();
    _dropPollTimer = null;
    unawaited(_teardownDropSubscription());
    _dropStats = null;
    _lastStatsElapsed = null;
    _dropBaseline = null;
    _dropPollStartElapsed = null;
    _connFailBaseline = null;
    _estabFailBaseline = null;
    _baselineRestored = false;
  }

  /// One poll tick: keep the notify subscription alive, then — if notifications
  /// aren't arriving — fall back to a direct READ. On a link whose MTU can't fit the
  /// 76 B notification the firmware can't push at all (-EMSGSIZE), but a plain READ
  /// (not MTU-bounded) still works, so the card keeps updating.
  Future<void> _dropTick() async {
    await _ensureDropSubscription();
    if (!mounted) return;
    // Reference is the last real notification, or poll-start if none ever arrived
    // (small-MTU link, where no notification is coming). The threshold sits above the
    // 15 s idle notify cadence so a healthy idle stream never triggers a redundant read.
    final ref = _lastDropNotifyElapsed ?? _dropPollStartElapsed;
    if (ref != null && _dropClock.elapsed - ref > _dropReadFallbackAfter) {
      await _readDropStatsFallback();
    }
    // Rebuild every tick even when no new data arrived, so the freshness pill ages
    // honestly. Without this a link that goes silent leaves the card showing frozen
    // counters under a stale "live" badge — the exact failure the pill exists to
    // expose. Cheap: this page is a debug screen and the tick is 2 s.
    // mounted, not just the timer: _readDropStatsFallback awaits a BLE read, and the
    // page can be closed during it. dispose() cancels the timer but the field stays
    // non-null, so the timer check alone does not prove the State is still alive.
    if (mounted && _dropPollTimer != null) setState(() {});
  }

  /// Direct READ of the drop counters (0x0062), the MTU-agnostic fallback when the
  /// notify path can't deliver. getDropStats() serializes the read against storage
  /// commands inside the connection (non-blocking: it returns null while a transfer
  /// holds the storage mutex), so the read can't race the sync stream (Error 133 on
  /// Android) — even if a sync starts right after this call — and two ticks can't read
  /// concurrently. Does not touch _lastDropNotifyElapsed, so the notify watchdog keeps
  /// trying to re-establish notifications (they resume if the MTU later negotiates up).
  Future<void> _readDropStatsFallback() async {
    if (!mounted) return;
    final conn = _dropConn;
    if (conn == null) return;
    final gen = _dropSubGen;
    DeviceDropStats? stats;
    try {
      stats = await conn.getDropStats();
    } catch (_) {
      return; // Transient BLE error — the next tick retries.
    }
    final s = stats;
    if (s == null || !mounted || gen != _dropSubGen) return;
    _lastStatsElapsed = _dropClock.elapsed;
    setState(() => _dropStats = s);
    _tryRestoreBaseline(s);
    _realignConnFailBaselines(s);
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Processing in progress — please wait until it finishes.')));
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
        'DebugTools: syncAll complete — result=${result == null ? 'null (nothing to sync)' : 'SyncLocalFilesResponse'}',
      );
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

  // One-shot read of the active storage backend, serialized against storage
  // transfers. A raw GATT read on the storage characteristic during a sync races the
  // storage notify stream and can drop the link (Error 133), so take the storage
  // lock and re-check sync state under it. No-op once resolved or while a sync holds
  // the path; _ensureDropSubscription retries it on later ticks until it resolves.
  Future<void> _readStorageBackendIfIdle(DeviceConnection conn) async {
    if (_storageBackend != null) return;
    if (ServiceManager.instance().wal.getSyncs().isSyncing) return;
    try {
      await conn.acquireStorageLock('diagBackendRead');
      try {
        // Re-check under the lock: a sync could have started while we waited for it.
        if (!mounted || ServiceManager.instance().wal.getSyncs().isSyncing) return;
        final stats = await conn.getStorageFileStats();
        if (mounted && stats?.storageBackend != null) {
          setState(() => _storageBackend = stats!.storageBackend);
        }
      } finally {
        conn.releaseStorageLock();
      }
    } catch (_) {
      // Best-effort — retried on a later tick.
    }
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
    // No dev.id comparison here on purpose: with one paired Omi the live subscription
    // can only belong to the connected device, and a disconnect closes the stream —
    // which drops the sub and fails _dropSubHealthy — so a dead link cannot survive
    // this check either.
    if (_dropSubHealthy) {
      // Sub already healthy — but retry the one-shot backend read here so a read
      // skipped earlier (device was mid-sync) still resolves instead of staying "—".
      final healthyConn = _dropConn;
      if (_storageBackend == null && healthyConn != null) {
        unawaited(_readStorageBackendIfIdle(healthyConn));
      }
      return;
    }
    await _dropMutex.acquire();
    try {
      // Re-check under the lock — a teardown/subscribe may have run while we waited.
      if (_dropSubHealthy) return;
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
          _lastStatsElapsed = _dropClock.elapsed;
          setState(() => _dropStats = stats);
          _tryRestoreBaseline(stats);
          _realignConnFailBaselines(stats);
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
      // Read the active storage backend once, serialized with storage transfers via
      // _readStorageBackendIfIdle (see there). Retried by later ticks until resolved.
      await _readStorageBackendIfIdle(conn);
    } catch (_) {
      // Transient BLE error — retry on the next tick.
    } finally {
      _dropMutex.release();
    }
  }

  /// Pull a BLE connect-fail baseline down to a reading that has fallen below it.
  ///
  /// A reading under the baseline means the baseline can no longer describe a "since
  /// when" — but NOT, on its own, that the device was wiped. The firmware persists these
  /// two counters on a coalesced 10 s delayed work item (transport.c
  /// CONN_FAIL_PERSIST_DELAY_MS), so an ordinary reboot inside that window re-seeds from
  /// flash BELOW a value the app already read live and may have been baselined at. No
  /// re-flash involved. Treating that as a wipe and discarding the baseline would throw
  /// away a perfectly good one the user set moments earlier.
  ///
  /// Re-anchoring to the current reading covers every cause without having to tell them
  /// apart: a persistence rollback moves the baseline down by the handful of failures
  /// that never reached flash; a wipe, re-flash or replacement unit moves it to ~0, so
  /// the delta becomes the whole count since that event, which is what the user wants to
  /// see anyway. It is also self-correcting where a discard was not — the baseline can
  /// never sit above the counter, so nothing renders negative, and nothing resurrects
  /// when the count climbs back past where the old baseline used to be.
  ///
  /// Runs on every reading, because [_tryRestoreBaseline] is latched to the first one and
  /// cannot see a rollback or wipe that lands while the page is already open. It is also
  /// the single owner of this rule: the restore path deliberately does no clamping of its
  /// own and leaves the correction to the call that follows it.
  void _realignConnFailBaselines(DeviceDropStats stats) {
    final connBase = _connFailBaseline;
    final estabBase = _estabFailBaseline;
    final connLow = connBase != null && stats.failedConnCount < connBase;
    final estabLow = estabBase != null && stats.estabFailCount < estabBase;
    if (!connLow && !estabLow) return;
    final prefs = SharedPreferencesUtil();
    if (connLow) unawaited(prefs.saveInt(_kBaselineConnFail, stats.failedConnCount));
    if (estabLow) unawaited(prefs.saveInt(_kBaselineEstabFail, stats.estabFailCount));
    setState(() {
      if (connLow) _connFailBaseline = stats.failedConnCount;
      if (estabLow) _estabFailBaseline = stats.estabFailCount;
    });
  }

  void _tryRestoreBaseline(DeviceDropStats stats) {
    if (_baselineRestored) return;
    _baselineRestored = true;
    final prefs = SharedPreferencesUtil();
    // Sweep the device-id-suffixed baselines from when this screen keyed them per
    // device. Their value isn't carried forward — same call as the pre-JSON baseline
    // below: a baseline is display-only, so the user re-taps once if they still want
    // one, and that beats guessing which suffixed key was the current device's.
    unawaited(prefs.clearLegacyPerDeviceBaselines());

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

    // BLE connect-fail baselines: SURVIVE reboot (firmware counters are flash-persisted),
    // so unlike the SD baseline above there is nothing to discard on a restart. Restored
    // as saved, with no backwards check of their own — a reading below the baseline is
    // handled by _realignConnFailBaselines, which every caller runs immediately after
    // this and which corrects the saved value rather than dropping it. Keeping the rule
    // in one place is deliberate: the earlier copy here inferred "wiped" from a backwards
    // reading and deleted a valid baseline whenever a reboot beat the firmware's 10 s
    // persist window.
    final savedConnFail = prefs.getInt(_kBaselineConnFail, defaultValue: -1);
    if (savedConnFail >= 0) {
      setState(() => _connFailBaseline = savedConnFail);
    }

    final savedEstabFail = prefs.getInt(_kBaselineEstabFail, defaultValue: -1);
    if (savedEstabFail >= 0) {
      setState(() => _estabFailBaseline = savedEstabFail);
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
    // Marking a baseline implies you want to watch what happens next, so switch the
    // view to the delta. The lifetime totals stay one tap away.
    _showLifetime = false;
    _snapshotDropBaseline();
    _snapshotConnFailBaseline();
    // SD-queue peak depth is intentionally not reset: it's the firmware's monotonic
    // since-boot high-water mark, so a "reset" would snap straight back on the next
    // reading. It's labelled "(since boot)" and excluded from the baseline.
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
    // Null it too: the field means "polling is active", which after dispose it is not.
    _dropPollTimer = null;
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
    messenger.showSnackBar(
      SnackBar(content: Text(value ? 'Enabling companion pairing…' : 'Disabling companion pairing…')),
    );

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

  /// The Diagnostics switch: app-side counter polling, and nothing else.
  ///
  /// It deliberately does NOT drive the on-device event log. That gate is a BLE write
  /// which can be refused mid-sync, resets to off whenever the device reboots, and is
  /// re-pushed independently by DeviceProvider on connect — so a switch owning both
  /// halves has to keep a local bool in agreement with a remote one over a link that
  /// drops, which is where every reliability bug on this page came from. The event log
  /// keeps its own switch beside this one, where its state is only its own.
  void _setDiagnosticsEnabled(bool val) {
    SharedPreferencesUtil().showSdWriteDrops = val;
    if (val) {
      _startDropPolling();
    } else {
      _stopDropPolling();
    }
    setState(() {});
  }

  /// The event log's capture control (0x0064). Writes the pref, pushes, and says so
  /// when the push couldn't land — DeviceProvider re-pushes on the next connect. No
  /// local mirror of the device's gate, so there is nothing to drift.
  void _setEventCaptureEnabled(bool val, DeviceProvider devProvider) {
    SharedPreferencesUtil().diagLogEnabled = val;
    setState(() {});
    unawaited(
      _runDiagLogAction(() async {
        if (!await devProvider.pushDiagLogEnabled()) {
          // Cause-neutral: the write can also fail because the link dropped or the
          // characteristic errored, and naming a sync as the reason sends a developer
          // looking in the wrong place.
          _reportDiagLogResult('Saved — the device could not be updated just now; it applies on the next connect.');
          return;
        }
        // Pull immediately on enable so a bench session starts from a known state.
        if (val) await devProvider.pullDiagLog();
      }),
    );
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
              _buildDiagnosticsCard(),
              const SizedBox(height: 12),
              // Sits with the Diagnostics card rather than down in Options: the
              // app-side log and the device-side counters/events are read together
              // when chasing a fault, and it was the one switch people had to
              // scroll past every destructive button to reach.
              _buildDebugLogsCard(),
              const SizedBox(height: 28),
              const DebugSectionHeader('Actions'),
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
              const SizedBox(height: 28),
              const DebugSectionHeader('Options'),
              ..._buildOptionRows(),
            ],
          ),
        ),
      ),
    );
  }

  /// The page's persistent switches, grouped at the bottom. They used to be
  /// interleaved with the readouts and the destructive actions, which put a
  /// wakelock toggle and a "delete everything" button in the same visual rhythm.
  /// Each one owns whatever expands beneath it (the adjustment archive controls).
  /// The debug-log switch is the exception — it sits with the Diagnostics card
  /// instead, see [_buildDebugLogsCard].
  List<Widget> _buildOptionRows() {
    return [
      // Companion Device Pairing (Android) — default ON. A troubleshooting toggle
      // for the rare OEM where registering as a system companion makes Bluetooth
      // reconnection worse; lives here in Debug Tools so it stays reachable when the
      // device won't connect. Applies immediately via _setCompanionDevicePairing
      // (reconnect on off, system chooser on on).
      if (Platform.isAndroid) ...[
        _optionCard(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Companion Device Pairing',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
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
        const SizedBox(height: 12),
      ],
      _optionCard(
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Keep Screen On',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            'Holds a wakelock while the app is open so the screen never sleeps.',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          ),
          value: SharedPreferencesUtil().keepScreenOn,
          onChanged: (val) async {
            SharedPreferencesUtil().keepScreenOn = val;
            await WakelockPlus.toggle(enable: val);
            setState(() {});
          },
          activeThumbColor: Colors.deepPurpleAccent,
        ),
      ),
      const SizedBox(height: 12),
      _buildAdjustmentModeSection(),
    ];
  }

  /// The app-side debug log: its switch, the live log window, and the share/clear
  /// actions. Rendered directly under the Diagnostics card (not with the other
  /// option switches) so all three logs — device counters, device events, app log —
  /// read as one block.
  Widget _buildDebugLogsCard() {
    return _optionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Save Debug Logs to File',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Persists info/debug logs to a file on your device. '
              'Leave on to capture BLE connection outages automatically, as they happen.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
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
          ),
          if (SharedPreferencesUtil().devLogsToFileEnabled) ...[
            const SizedBox(height: 12),
            _buildLogWindow(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _shareDebugLogs,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.deepPurpleAccent, width: 1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      'Share Logs',
                      style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
                    ),
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
                      side: const BorderSide(color: Colors.white24, width: 1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      'Clear Logs',
                      style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _optionCard({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(16)),
        child: child,
      );

  Future<void> _shareDebugLogs() async {
    final files = await DebugLogManager.listLogFiles();
    if (files.isEmpty) {
      if (mounted) setState(() => _statusMessage = 'No log files available to share');
      return;
    }
    // Name the shared file `omi_offline_debug_<date>.log` — lowercase, underscored,
    // no spaces/apostrophes, so it's easy to work with on upload/save targets.
    // Derived from the on-disk basename (`omi_debug_YYYYMMDD.log`) so the date
    // matches exactly.
    final logName = files.first.uri.pathSegments.last;

    String appVersion = 'unknown';
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = packageInfo.version;
    } catch (_) {}

    if (!mounted) return;
    final fwVersion = context.read<DeviceProvider>().connectedDevice?.firmwareRevision ?? 'unknown';
    final os = Platform.operatingSystem;

    final datePart = logName.replaceFirst('omi_debug_', '');
    final shareName = '${os}_${appVersion}_${fwVersion}_omi_offline_debug_$datePart';
    // Name the XFile (not just the share `subject`) so the name lands on targets
    // that use the file's own name, not the title.
    final xFile = XFile(files.first.path, name: shareName);
    // Use `subject` (share-sheet/email title metadata), not `text`: a `text`
    // argument is shared as a SEPARATE item alongside the file, so iOS upload/save
    // targets materialize a second phantom file containing the label string.
    await SharePlus.instance.share(ShareParams(files: [xFile], subject: shareName));
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

    // Styled as an option card, not a readout panel: since the toggles were grouped
    // it sits beside Keep Screen On / Save Debug Logs, and the panel styling made it
    // read as a different kind of control.
    return _optionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            title: const Text(
              'Adjustment Mode',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Copies all raw bins into an isolated folder for safe reprocessing.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
            value: on,
            onChanged: _onAdjustmentModeToggled,
            activeThumbColor: Colors.deepPurpleAccent,
            contentPadding: EdgeInsets.zero,
          ),
          if (on) ...[
            const SizedBox(height: 4),
            DiagStatRow('Enabled at', enabledAtLabel),
            DiagStatRow('Bins in adjustment folder', _adjustmentBinCount.toString()),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _copyAdjustmentBinsForReprocessing,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.deepPurpleAccent, width: 1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size(double.infinity, 0),
              ),
              child: const Text(
                'Copy Bins for Reprocessing',
                style: TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
              ),
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
              child: const Text(
                'Reprocess All from Segments',
                style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold),
              ),
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
      Logger.info(
        'Adjustment: copied $copied bin(s) adjustment_mode_segments → raw_segments'
        '${failed > 0 ? ' ($failed failed)' : ''} — sync/process to reprocess',
      );
      await _refreshAdjustmentBinCount();
      _reportCopyResult(
        copied == 0
            ? 'No bins copied — adjustment folder is empty.'
            : 'Copied $copied bin(s) to raw_segments${failed > 0 ? ' · $failed failed' : ''}. Run Sync/Process to reprocess.',
      );
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
  }

  /// The merged Diagnostics card: firmware counters and the on-device event log in
  /// one place, under a switch each. Every state (off, no device, reading, populated)
  /// renders inside the same [DiagCard] shell, so the page no longer jumps several
  /// hundred pixels the moment counters arrive.
  Widget _buildDiagnosticsCard() {
    final enabled = SharedPreferencesUtil().showSdWriteDrops;
    final devProvider = Provider.of<DeviceProvider>(context);
    // Gated on the live connection as well as the capability: the capability is only
    // ever set on connect and never cleared, so without this the switch and the group
    // outlived the link — showing the last session's records as current and offering
    // Pull/Clear/capture controls that silently do nothing, since every one of them
    // needs a connection.
    final showEvents = devProvider.isConnected && devProvider.diagLogSupported;
    return DiagCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The card's two switches first, then the actions that act on both of them,
          // then the readings each switch produces. Event capture is deliberately NOT
          // behind the counters switch: routing it there would leave it unreachable to
          // turn OFF without first turning counter polling back on, and an independent
          // control you can only reach via another one is not independent.
          _buildDiagnosticsHeader(enabled),
          if (showEvents) ...[const SizedBox(height: 10), _buildEventCaptureSwitch(devProvider)],
          if (enabled) ...[
            _buildBaselineActions(),
            const SizedBox(height: 12),
            _buildDiagnosticsBody(),
          ],
          if (showEvents) ...[const SizedBox(height: 6), _buildEventsGroup(devProvider, _dropStats)],
        ],
      ),
    );
  }

  /// The on-device event log's capture gate (0x0064), rendered as a peer of the
  /// Diagnostics switch rather than a pill on the Events group header — the two are
  /// separate instruments, and the pill read as a filter chip rather than a control.
  ///
  /// Keeps its no-local-mirror property: the label reports the pref (what the app
  /// asked for), never a guess at the device's gate, which resets on every reboot and
  /// is re-pushed by DeviceProvider on connect.
  Widget _buildEventCaptureSwitch(DeviceProvider devProvider) {
    final capturing = SharedPreferencesUtil().diagLogEnabled;
    return Row(
      children: [
        const FaIcon(FontAwesomeIcons.listUl, size: 14, color: Colors.white70),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Event Capture',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                capturing ? 'Device event log requested on.' : 'Off — the device is asked not to record events.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
            ],
          ),
        ),
        Switch(
          value: capturing,
          onChanged: _diagLogBusy ? null : (val) => _setEventCaptureEnabled(val, devProvider),
          activeThumbColor: Colors.deepPurpleAccent,
        ),
      ],
    );
  }

  Widget _buildDiagnosticsHeader(bool enabled) {
    return Row(
      children: [
        const FaIcon(FontAwesomeIcons.waveSquare, size: 14, color: Colors.white70),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Diagnostics',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              // Describes only what this switch does, which is entirely app-side. It
              // makes no claim about the device — the Events group speaks for the
              // event log, and every past wording bug here was this line trying to
              // report state it had no way to know.
              Text(
                enabled ? 'Device counters polled every 2 s.' : 'Off — counters are not polled.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
            ],
          ),
        ),
        Switch(value: enabled, onChanged: _setDiagnosticsEnabled, activeThumbColor: Colors.deepPurpleAccent),
      ],
    );
  }

  Widget _diagPlaceholder(String message) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const FaIcon(FontAwesomeIcons.circleNotch, size: 12, color: Colors.white38),
            const SizedBox(width: 8),
            Text(message, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      );

  Widget _buildDiagnosticsBody() {
    final devProvider = Provider.of<DeviceProvider>(context);
    if (!devProvider.isConnected || devProvider.connectedDevice == null) {
      return _diagPlaceholder('Waiting for device connection…');
    }
    final stats = _dropStats;
    if (stats == null) return _diagPlaceholder('Reading counters…');

    // Every firmware counter here resets to 0 on device reboot, so "Mark baseline"
    // baselines them uniformly: show the value since the last mark, clamped at 0 so a
    // stale baseline never renders a negative. The Lifetime segment bypasses the
    // baseline without discarding it. (The connect-fail counters survive reboot and
    // carry their own int baselines.)
    final baseline = _showLifetime ? null : _dropBaseline;
    final connBaseline = _showLifetime ? null : _connFailBaseline;
    final estabBaseline = _showLifetime ? null : _estabFailBaseline;
    int rel(int current, int Function(DeviceDropStats b) pick) =>
        baseline == null ? current : (current - pick(baseline)).clamp(0, current);

    final blocks = rel(stats.blockDrops, (b) => b.blockDrops);
    final frames = rel(stats.streamFrameDrops, (b) => b.streamFrameDrops);
    final codec = rel(stats.codecFrameDrops, (b) => b.codecFrameDrops);
    final boot = rel(stats.bootFrameDrops, (b) => b.bootFrameDrops);
    final writeFair = rel(stats.writeFairActivations, (b) => b.writeFairActivations);
    final prioStarts = rel(stats.priorityRecordStarts, (b) => b.priorityRecordStarts);
    final prioStops = rel(stats.priorityRecordStops, (b) => b.priorityRecordStops);
    final markerDrops = rel(stats.markerWriteDrops, (b) => b.markerWriteDrops);
    final emptyRot = rel(stats.emptyBinRotations, (b) => b.emptyBinRotations);
    final seEmits = rel(stats.sessionEndMarkerEmits, (b) => b.sessionEndMarkerEmits);
    final pauseSaves = rel(stats.markerPauseGateSaves, (b) => b.markerPauseGateSaves);
    // Defensive only. _realignConnFailBaselines pulls the baseline down to any reading
    // that falls below it, so by the time a build sees the pair they agree — but it
    // corrects via setState, and this keeps the intervening build from rendering a
    // negative count. Do NOT grow this into the actual rule: evaluated per build it
    // cannot latch anything, and it has no way to write the correction back, so the
    // baseline would silently return the moment a post-wipe counter climbed past it.
    // Falling back to the lifetime value rather than clamping to 0 keeps the number
    // non-negative AND gets the row its "(lifetime)" label and exemption from the
    // verdict, which is what a delta with nothing left to subtract from actually is.
    final connBaselineUsable = connBaseline != null && stats.failedConnCount >= connBaseline;
    final estabBaselineUsable = estabBaseline != null && stats.estabFailCount >= estabBaseline;
    final connFails = connBaselineUsable ? stats.failedConnCount - connBaseline : stats.failedConnCount;
    final estabFails = estabBaselineUsable ? stats.estabFailCount - estabBaseline : stats.estabFailCount;
    // Unlike every other counter here, these two are persisted to the Omi's flash and
    // re-seeded at boot (transport.c app_settings_get_conn_fail), so without a baseline
    // the number on screen is a lifetime odometer covering every boot the device has
    // ever had. The firmware's own note is explicit that only their MOVEMENT
    // discriminates and "a nonzero absolute value says nothing about the outage in front
    // of you" — an establishment failure is an ordinary RF event (the nRF7002 shares this
    // board), so a handful accumulates on any healthy Omi. Rendering that as a red fault
    // meant a used device permanently reported "N BLE connect failures" with nothing
    // wrong. They count as a fault only once a baseline makes them a delta. The trade-off
    // is deliberate: on a device that has never been baselined a genuine burst now reads
    // as plain info rather than red, which is the honest rendering of a number that
    // cannot distinguish the two.
    final connFailsAreDelta = connBaselineUsable;
    final estabFailsAreDelta = estabBaselineUsable;
    final connFailsFault = connFails > 0 && connFailsAreDelta;
    final estabFailsFault = estabFails > 0 && estabFailsAreDelta;

    // Peak depth is the firmware's monotonic since-boot high-water mark, not an
    // incremental counter, so it is never delta-subtracted and never baselined (a
    // reset would snap straight back on the next reading).
    final peak = stats.msgqPeakDepth;
    final peakHot = peak >= (stats.sdQueueMax * 0.8).round();

    // Peak thread stack usage vs the configured stack sizes (firmware constants,
    // oo-2.7.2+: codec_stack=23096). Gauges, shown raw.
    //
    // sd_worker is 12288 in production but (12288 - DIAG_LOG_RING_BYTES) = 10240 on a
    // CONFIG_OMI_DIAG_LOG build, which carves the diag-event ring out of that stack.
    // That macro is also the only thing that sets OmiFeatures.diagLog, so
    // diagLogSupported is an exact proxy for which size is compiled in. Hardcoding the
    // production 12288 understated the fill on every dev build and — worse — put the
    // 85% warn line at 10445 B, above the entire 10240 B stack, so it could not fire.
    // Keep in sync with the firmware or the fill fraction is wrong.
    final int sdWorkerStackSize = devProvider.diagLogSupported ? 12288 - 2048 : 12288;
    const int codecStackSize = 23096;
    String stackLabel(int used, int size) =>
        used == 0 ? '—' : '${(used / 1024).toStringAsFixed(1)} / ${(size / 1024).toStringAsFixed(1)} KB';
    final sdStackHot = stats.sdWorkerStackUsed > sdWorkerStackSize * 0.85;
    final codecStackHot = stats.codecStackUsed > codecStackSize * 0.85;

    // Ring-backend SD health. Parsed and written to the debug log since the ring
    // backend landed, but never shown here: on the ring these are the two readings
    // that separate "the NAND stalled" from "the NAND rejected the write". Reported
    // by the firmware as since-boot and absent from the baseline snapshot, so they
    // are shown raw in both views.
    final isRing = _storageBackend == 1;
    // 1000 ms is just under the point where one slow op first becomes capable of costing
    // audio, so below it the warn has nothing to warn about. A single op is one
    // RING_FLUSH_CHUNK_SECTORS chunk (4 KB), and chunks never come alone: a full-stage
    // flush issues ten of them back-to-back, during which the worker drains no audio.
    // Ingest is ~10 of the 440 B blocks per second (20 ms Opus frames, 32 kbps VBR, + the
    // 4 B inline header), so the 120-deep sd_msgq holds ~12 s of stall before it drops a
    // block, putting the harm point near 12 s / 10 chunks = 1200 ms. Rounded DOWN to 1000
    // deliberately: VBR frame sizes vary, and at the fast end of ingest (~11.6 blocks/s)
    // the queue only holds ~10.3 s, which drags the harm point to ~1030 — so 1000 holds
    // across the plausible range where 1200 assumes the favourable end of it, and it
    // leaves some lead time, which is what a warn is for. The earlier 500 ms line flagged
    // runs using under half the headroom, which is real but not actionable, and since this
    // is a since-boot MAXIMUM that never decays, one tail event latched the warn until
    // reboot. What actually reports lost audio is blockDrops / ringIoErrors; this row only
    // attributes it.
    final ringSlow = stats.ringMaxIoMs >= 1000;
    final ringErrs = stats.ringIoErrors;

    // "Since baseline" is derived from the block-drop count rising, not from the
    // drop's uptime: a reboot that a zero-counter baseline can't flag resets the
    // device uptime below the captured value, which an uptime comparison would
    // misread as "before the baseline" — hiding a genuine post-baseline drop as
    // "never" while the count row shows it. Keying off the same delta keeps the two
    // rows consistent.
    final sinceMs = stats.msSinceLastBlockDrop;
    final noDropSinceBaseline = baseline != null && blocks == 0;
    final lastDropLabel = (sinceMs == null || noDropSinceBaseline) ? 'never' : '${_formatDuration(sinceMs)} ago';

    // Per-group flags, in the terse form the collapsed header shows. Each list drives
    // both whether its group is clear (empty) and what it says when collapsed while
    // NOT clear — deriving both from one list is what stops a hand-collapsed group
    // advertising "no drops" over a live fault.
    final sdFlags = <String>[
      if (blocks > 0) '$blocks blocks',
      if (frames > 0) '$frames frames',
      if (codec > 0) '$codec codec',
      if (boot > 0) '$boot boot',
      if (peakHot) 'queue $peak/${stats.sdQueueMax}',
      if (isRing && ringErrs > 0) '$ringErrs IO errors',
      if (isRing && ringSlow) '${stats.ringMaxIoMs} ms op',
    ];
    final markerFlags = <String>[
      if (markerDrops > 0) '$markerDrops marker drops',
      if (emptyRot > 0) '$emptyRot empty rotations',
      if (prioStarts > prioStops) 'left open',
      if (prioStops > 0 && seEmits == 0) 'no session-end',
    ];
    final memoryFlags = <String>[if (sdStackHot) 'SD worker stack high', if (codecStackHot) 'codec stack high'];
    final bleFlags = <String>[
      if (connFailsFault) '$connFails connect fail${connFails == 1 ? '' : 's'}',
      if (estabFailsFault) '$estabFails at establishment',
    ];

    // The verdict. Twenty rows of mostly-zero used to leave "is anything wrong?" as
    // an exercise for the reader; problems are faults that lost audio or a link,
    // watches are things that are merely worth an eye.
    final problems = <String>[];
    if (blocks > 0) problems.add('$blocks block drop${blocks == 1 ? '' : 's'}');
    if (frames > 0) problems.add('$frames frame drop${frames == 1 ? '' : 's'}');
    if (codec > 0) problems.add('$codec codec drop${codec == 1 ? '' : 's'}');
    if (markerDrops > 0) problems.add('$markerDrops marker write drop${markerDrops == 1 ? '' : 's'}');
    if (isRing && ringErrs > 0) problems.add('$ringErrs NAND IO error${ringErrs == 1 ? '' : 's'}');
    if (connFailsFault || estabFailsFault) {
      final n = (connFailsFault ? connFails : 0) + (estabFailsFault ? estabFails : 0);
      problems.add('$n BLE connect failure${n == 1 ? '' : 's'}');
    }
    final watches = <String>[];
    if (boot > 0) watches.add('$boot boot-window drop${boot == 1 ? '' : 's'}');
    if (emptyRot > 0) watches.add('$emptyRot empty bin rotation${emptyRot == 1 ? '' : 's'}');
    if (prioStarts > prioStops) watches.add('priority recording left open');
    if (prioStops > 0 && seEmits == 0) watches.add('stop with no session-end marker');
    if (peakHot) watches.add('SD queue near its limit');
    if (sdStackHot || codecStackHot) watches.add('thread stack near ceiling');
    if (isRing && ringSlow) watches.add('slow SD op (${stats.ringMaxIoMs} ms)');
    // The event log is part of this card, so it has to count toward the card's
    // verdict: without this the banner read "All clear" over a red advertising-fail
    // or wedged-mic entry sitting a few rows below it.
    final eventLevels =
        devProvider.diagLogSupported ? devProvider.diagLogRecords.map(diagEventLevel).toList() : const <DiagLevel>[];
    final eventFaults = eventLevels.where((l) => l == DiagLevel.bad).length;
    final eventWarns = eventLevels.where((l) => l == DiagLevel.warn).length;
    if (eventFaults > 0) problems.add('$eventFaults event fault${eventFaults == 1 ? '' : 's'}');
    if (eventWarns > 0) watches.add('$eventWarns event warning${eventWarns == 1 ? '' : 's'}');

    final uptime = _formatDuration(stats.currentUptimeMs);
    final DiagLevel verdict =
        problems.isNotEmpty ? DiagLevel.bad : (watches.isNotEmpty ? DiagLevel.warn : DiagLevel.ok);
    final String headline;
    final String detail;
    if (problems.isNotEmpty) {
      headline = '${problems.length} issue${problems.length == 1 ? '' : 's'} · up $uptime';
      detail = problems.join(' · ');
    } else if (watches.isNotEmpty) {
      headline = '${watches.length} to watch · up $uptime';
      detail = watches.join(' · ');
    } else {
      headline = 'All clear · up $uptime';
      detail = 'No drops, no marker loss, no BLE failures.';
    }

    // Freshness. The notify subscription, the READ fallback and the staleness
    // watchdog were all invisible: a link that went quiet left the card showing
    // frozen numbers with nothing to say so. This reports which path is feeding the
    // card and how old its data is.
    final lastNotify = _lastDropNotifyElapsed;
    // Monotonic, not DateTime.now() - stats.readAt: a backward wall-clock adjustment
    // would make frozen data read as fresh, which is precisely what this is here to
    // catch. Same reasoning as the subscription watchdog above.
    final dataAge = _lastStatsElapsed == null ? null : _dropClock.elapsed - _lastStatsElapsed!;
    final String freshLabel;
    final DiagLevel freshLevel;
    if (lastNotify != null && _dropClock.elapsed - lastNotify < _dropSilenceTimeout) {
      freshLabel = 'live';
      freshLevel = DiagLevel.ok;
    } else if (dataAge != null && dataAge < _dropSilenceTimeout) {
      freshLabel = 'polling';
      freshLevel = DiagLevel.info;
    } else {
      freshLabel = dataAge == null ? 'stale' : 'stale ${_formatDuration(dataAge.inMilliseconds)}';
      freshLevel = DiagLevel.warn;
    }

    final hasBaseline = _dropBaseline != null || _connFailBaseline != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DiagStatusBanner(
          level: verdict,
          headline: headline,
          detail: detail,
          freshness: freshLabel,
          freshnessLevel: freshLevel,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            // Which audio backend the firmware mounted this boot. "—" when unknown
            // (firmware predates the status_flags byte, or it hasn't been read yet).
            DiagPill(text: isRing ? 'Ring' : (_storageBackend == 0 ? 'LittleFS' : 'backend —')),
            const Spacer(),
            // Taking a baseline is reversible now: the stored snapshot is untouched,
            // these only choose which view the rows render.
            if (hasBaseline) ...[
              DiagPill(
                text: 'Since baseline',
                selected: !_showLifetime,
                onTap: () => setState(() => _showLifetime = false),
              ),
              const SizedBox(width: 6),
              DiagPill(text: 'Lifetime', selected: _showLifetime, onTap: () => setState(() => _showLifetime = true)),
            ],
          ],
        ),
        const SizedBox(height: 4),
        DiagGroup(
          key: const ValueKey('diag-sd'),
          title: 'SD write path',
          allClear: sdFlags.isEmpty,
          clearSummary: 'no drops · queue $peak/${stats.sdQueueMax}',
          alertSummary: _alertSummary(sdFlags),
          rows: [
            DiagStatRow('440 B blocks dropped', '$blocks', level: blocks > 0 ? DiagLevel.bad : DiagLevel.info),
            DiagStatRow(
              'Audio frames dropped (SD queue)',
              '$frames',
              level: frames > 0 ? DiagLevel.bad : DiagLevel.info,
            ),
            DiagStatRow(
              'Audio dropped pre-encode (codec)',
              '$codec',
              level: codec > 0 ? DiagLevel.bad : DiagLevel.info,
            ),
            DiagStatRow('Boot-window frame drops', '$boot', level: boot > 0 ? DiagLevel.warn : DiagLevel.info),
            DiagStatRow('Last block drop', lastDropLabel, level: blocks > 0 ? DiagLevel.warn : DiagLevel.info),
            DiagGaugeRow(
              label: 'SD queue peak (since boot)',
              used: peak,
              total: stats.sdQueueMax,
              valueLabel: '$peak / ${stats.sdQueueMax}',
              level: peakHot ? DiagLevel.warn : DiagLevel.info,
            ),
            // The read-vs-write arbiter engaging, not a fault.
            DiagStatRow('Write-fairness activations', '$writeFair'),
            if (isRing)
              DiagStatRow(
                'Slowest SD op (since boot)',
                '${stats.ringMaxIoMs} ms (${stats.ringMaxIoOp})',
                level: ringSlow ? DiagLevel.warn : DiagLevel.info,
              ),
            if (isRing)
              DiagStatRow('NAND IO errors', '$ringErrs', level: ringErrs > 0 ? DiagLevel.bad : DiagLevel.info),
          ],
        ),
        DiagGroup(
          key: const ValueKey('diag-markers'),
          title: 'Recording markers',
          allClear: markerFlags.isEmpty,
          clearSummary:
              (prioStarts == 0 && prioStops == 0) ? 'no activity' : '$prioStarts started · $prioStops stopped',
          alertSummary: _alertSummary(markerFlags),
          rows: [
            DiagStatRow('Priority recordings started', '$prioStarts'),
            DiagStatRow(
              'Priority recordings stopped',
              '$prioStops',
              level: prioStarts > prioStops ? DiagLevel.warn : DiagLevel.info,
            ),
            DiagStatRow(
              'Marker writes dropped',
              '$markerDrops',
              level: markerDrops > 0 ? DiagLevel.bad : DiagLevel.info,
            ),
            DiagStatRow('Empty bin rotations', '$emptyRot', level: emptyRot > 0 ? DiagLevel.warn : DiagLevel.info),
            // Flagged when a priority stop happened but no session-end marker was
            // emitted — the finalize path never firing, the exact failure these
            // counters exist to catch. "Kept at the pause gate" is a rescue, not a
            // loss, so it is never highlighted.
            DiagStatRow(
              'Session-end marker emits',
              '$seEmits',
              level: prioStops > 0 && seEmits == 0 ? DiagLevel.warn : DiagLevel.info,
            ),
            DiagStatRow('Markers kept at SD pause gate', '$pauseSaves'),
          ],
        ),
        DiagGroup(
          key: const ValueKey('diag-memory'),
          title: 'Memory',
          allClear: memoryFlags.isEmpty,
          clearSummary: stats.sdWorkerStackUsed == 0 ? 'not reported' : 'headroom ok',
          alertSummary: _alertSummary(memoryFlags),
          rows: [
            // Read after a heavy session (an allocator scan is the SD worker's deepest
            // path; busy encoding is the codec's) so the high-water reflects the worst
            // case. A big gap below the configured size means reclaimable RAM; a full
            // bar means overflow risk — do NOT trim.
            DiagGaugeRow(
              label: 'SD worker stack',
              used: stats.sdWorkerStackUsed,
              total: sdWorkerStackSize,
              valueLabel: stackLabel(stats.sdWorkerStackUsed, sdWorkerStackSize),
              level: sdStackHot ? DiagLevel.warn : DiagLevel.info,
            ),
            DiagGaugeRow(
              label: 'Codec stack',
              used: stats.codecStackUsed,
              total: codecStackSize,
              valueLabel: stackLabel(stats.codecStackUsed, codecStackSize),
              level: codecStackHot ? DiagLevel.warn : DiagLevel.info,
            ),
          ],
        ),
        DiagGroup(
          key: const ValueKey('diag-ble'),
          title: 'BLE link',
          allClear: bleFlags.isEmpty,
          clearSummary: 'no failures',
          alertSummary: _alertSummary(bleFlags),
          rows: [
            // "Died at establishment" is the one that identifies a "visible but
            // unconnectable" outage — if the phone logs 0x3e while this stays 0, the
            // Omi never heard the connect requests and the phone is at fault. See
            // NOTES.md "BLE: advertising but won't connect".
            // Both survive reboot, so the label says which span the number covers —
            // without it a lifetime total reads as "this happened on this run".
            DiagStatRow(
              connFailsAreDelta ? 'Connect failures' : 'Connect failures (lifetime)',
              '$connFails',
              level: connFailsFault ? DiagLevel.bad : DiagLevel.info,
            ),
            DiagStatRow(
              estabFailsAreDelta ? 'Died at establishment (0x3e)' : 'Died at establishment (0x3e, lifetime)',
              '$estabFails',
              level: estabFailsFault ? DiagLevel.bad : DiagLevel.info,
            ),
            // Contextual, not a fault of its own: it describes whichever failure the
            // rows above are reporting, so it only appears alongside one — and it is
            // gated on the displayed deltas, so a baseline that zeroed both hides it.
            if (connFails > 0 || estabFails > 0)
              DiagStatRow('Last fail adv mode', stats.lastFailedConnDuringSlowAdv ? 'slow (1 s)' : 'fast'),
          ],
        ),
      ],
    );
  }

  /// The baseline / snapshot actions, sitting directly under the card's two switches:
  /// both act on everything below them (Copy snapshot includes the event log), so they
  /// read as the card's controls rather than as a footer to the last group.
  ///
  /// Both need a counter read to have landed — `_copyDiagnosticsSnapshot` and
  /// `_snapshotDropBaseline` bail on a null `_dropStats` — so they are disabled, not
  /// silently inert, until one has.
  Widget _buildBaselineActions() {
    final hasBaseline = _dropBaseline != null || _connFailBaseline != null;
    final ready = _dropStats != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: ready ? _resetAllDiagnostics : null,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: ready ? Colors.white24 : Colors.white10, width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  'Mark baseline',
                  style: TextStyle(color: ready ? Colors.white70 : Colors.white24, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: ready ? _copyDiagnosticsSnapshot : null,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: ready ? Colors.deepPurpleAccent : Colors.deepPurpleAccent.withValues(alpha: 0.3),
                    width: 1,
                  ),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  'Copy snapshot',
                  style: TextStyle(
                    color: ready ? Colors.deepPurpleAccent : Colors.deepPurpleAccent.withValues(alpha: 0.4),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            hasBaseline
                ? 'Counters read as a delta from the marked baseline. Nothing was cleared on the device — switch to '
                    'Lifetime for its own totals. Since-boot gauges (queue peak, stacks, uptime) stay live in both views.'
                : 'Mark baseline snapshots the current values so the drop and failure counters read 0 from now on. '
                    'Display only — the device keeps its own totals until it reboots.',
            style: const TextStyle(color: Colors.white38, fontSize: 11, height: 1.3),
          ),
        ),
      ],
    );
  }

  /// Copies a plain-text diagnostics snapshot to the clipboard. Reporting a problem
  /// used to mean screenshotting twenty rows; this is the same key=value shape the
  /// debug log already records, so a pasted snapshot and a shared log line up.
  ///
  /// Deliberately reports the device's LIFETIME values, not the baseline-relative
  /// view — a bug report wants what the firmware actually counted.
  Future<void> _copyDiagnosticsSnapshot() async {
    final stats = _dropStats;
    if (stats == null) return;
    String appVersion = 'unknown';
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    if (!mounted) return;
    final devProvider = context.read<DeviceProvider>();
    final fw = devProvider.connectedDevice?.firmwareRevision ?? 'unknown';
    final backend = _storageBackend == 1 ? 'ring' : (_storageBackend == 0 ? 'littlefs' : 'unknown');

    final b = StringBuffer()
      ..writeln('omi diagnostics — app $appVersion / fw $fw / backend $backend')
      ..writeln('captured ${DateTime.now().toIso8601String()} · device up ${_formatDuration(stats.currentUptimeMs)}')
      ..writeln(
        'sd: blocks=${stats.blockDrops} frames=${stats.streamFrameDrops} '
        'codec=${stats.codecFrameDrops} boot=${stats.bootFrameDrops} '
        // When the last block drop happened. The "Last block drop" row is derived
        // from it, and it is the one piece of when-did-this-happen evidence the rest
        // of the snapshot cannot reconstruct. -1 = none since boot.
        'lastDropUptimeMs=${stats.lastBlockDropUptimeMs} '
        'msSinceLastDrop=${stats.msSinceLastBlockDrop ?? -1}',
      )
      ..writeln('queue: peak=${stats.msgqPeakDepth}/${stats.sdQueueMax} writeFair=${stats.writeFairActivations}')
      ..writeln(
        'markers: starts=${stats.priorityRecordStarts} stops=${stats.priorityRecordStops} '
        'drops=${stats.markerWriteDrops} emptyRot=${stats.emptyBinRotations} '
        'seEmits=${stats.sessionEndMarkerEmits} pauseSaves=${stats.markerPauseGateSaves}',
      )
      ..writeln('stacks: sdWorker=${stats.sdWorkerStackUsed}B codec=${stats.codecStackUsed}B')
      ..writeln('ring: maxIo=${stats.ringMaxIoMs}ms(${stats.ringMaxIoOp}) ioErrors=${stats.ringIoErrors}')
      // Mic liveness and capture duty. silentFor answers "is the mic delivering right
      // now" directly — frames arrive every 100 ms, so anything past a few seconds is
      // a parked or stopped mic, and it needs no cross-referencing against event
      // timestamps. duty is voiced time over uptime: how much of the day the VAD is
      // holding a recording open, i.e. what the auto threshold costs.
      ..writeln(
        'mic: silentFor=${stats.micSilentForMs == null ? "n/a" : "${stats.micSilentForMs}ms"} '
        'voiced=${stats.voicedMs}ms '
        'duty=${stats.captureDutyFraction == null ? "n/a" : "${(stats.captureDutyFraction! * 100).toStringAsFixed(1)}%"}',
      )
      ..writeln(
        // "(lifetime)" is load-bearing: every other counter in this snapshot is
        // since-boot and the header states the uptime, so these two read as having
        // happened on this run when they in fact survive reboot and total every boot
        // the device has had.
        'ble: connFail=${stats.failedConnCount} estab0x3e=${stats.estabFailCount} (lifetime) '
        'lastAdv=${stats.lastFailedConnDuringSlowAdv ? 'slow' : 'fast'}',
      );

    // Always emitted, even with nothing held: "held=0 dropped=12" is itself the
    // finding (the ring overflowed while the phone was away), and skipping the line
    // when records was empty threw that away. capture= records whether the log was
    // even switched on, so a silent snapshot is not misread as a quiet device.
    final records = devProvider.diagLogRecords;
    // capture= is the DEVICE's gate, not the app's preference. They diverge whenever
    // the 0x0064 push is skipped (a sync holds the storage lock) or fails, and the
    // divergence is exactly what makes an empty log unreadable: pref-true + gate-off
    // looks identical to a device with nothing to report.
    final gate = devProvider.diagLogGateOnDevice;
    final gateAge = devProvider.diagLogGatePushedAt == null
        ? 'never'
        : '${DateTime.now().difference(devProvider.diagLogGatePushedAt!).inSeconds}s ago';
    b.writeln(
      'events: capture=${gate ?? "unknown"} (pref=${SharedPreferencesUtil().diagLogEnabled}, confirmed $gateAge) '
      'supported=${devProvider.diagLogSupported} '
      'held=${records.length} dropped=${devProvider.diagLogDroppedCount} (oldest first)',
    );
    for (final r in records) {
      b.writeln('  $r');
    }

    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnostics snapshot copied to clipboard')));
  }

  bool _diagLogBusy = false;

  Future<void> _runDiagLogAction(Future<void> Function() action) async {
    if (_diagLogBusy) return;
    setState(() => _diagLogBusy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _diagLogBusy = false);
    }
  }

  /// Snackbar feedback for a diag-log action (e.g. a toggle that couldn't reach the
  /// device while a sync held the storage lock), so the result is never silent.
  void _reportDiagLogResult(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 4)));
  }

  /// The on-device diagnostic event log, folded into the Diagnostics card as one
  /// more group. It timestamps and contextualises the same health events the
  /// counters above only total, so reading the two side by side is the whole point —
  /// they used to be separate cards behind separate switches, which meant a bench
  /// session routinely ran with half the instrumentation off.
  ///
  /// Self-hides unless the connected firmware advertises the capability
  /// (OMI_FEATURE_DIAG_LOG, bit 12). The log is drained + acked on connect when
  /// enabled; this surfaces the latest batch and allows an on-demand pull or clear.
  Widget _buildEventsGroup(DeviceProvider devProvider, DeviceDropStats? stats) {
    final records = devProvider.diagLogRecords;
    final dropped = devProvider.diagLogDroppedCount;

    // Only offer filters for categories actually present, so there are no dead chips.
    final categories = records.map(diagEventCategory).toSet().toList()..sort((a, b) => a.index.compareTo(b.index));
    // Resolved locally rather than by mutating _eventFilter: a drain can empty the
    // category the filter points at, and rewriting state during build is a trap.
    final activeFilter = (_eventFilter != null && categories.contains(_eventFilter)) ? _eventFilter : null;
    final filtered = activeFilter == null ? records : records.where((r) => diagEventCategory(r) == activeFilter);
    // Newest first, capped — the device ring holds 128 but a drain concatenates batches.
    final display = filtered.toList().reversed.take(200).toList();
    final worst = diagWorst(records.map(diagEventLevel));

    final meta = StringBuffer('${records.length} held');
    if (dropped > 0) meta.write(' · $dropped dropped');
    final pulledAt = devProvider.diagLogLastPulledAt;
    if (pulledAt != null) meta.write(' · pulled ${_hhmm(pulledAt)}');

    final capturing = SharedPreferencesUtil().diagLogEnabled;
    return DiagGroup(
      // Keyed like its siblings: it renders in two different slots (beside the loading
      // placeholder, then after the counter groups), and without a key Flutter rebuilds
      // its State across that move, discarding a hand-applied collapse.
      key: const ValueKey('diag-events'),
      title: 'Events (${records.length})',
      allClear: records.isEmpty && dropped == 0,
      // Still reports the capture state while collapsed — with capture off the group
      // is empty and folded, and "nothing captured" there would read as a quiet
      // device. The switch itself lives at the top of the card.
      clearSummary: capturing ? 'nothing captured' : 'capture off',
      trailing: categories.length > 1
          ? Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                DiagPill(text: 'All', selected: activeFilter == null, onTap: () => setState(() => _eventFilter = null)),
                for (final c in categories)
                  DiagPill(text: c.label, selected: activeFilter == c, onTap: () => setState(() => _eventFilter = c)),
              ],
            )
          : null,
      rows: [
        Row(
          children: [
            Expanded(
              child: Text(meta.toString(), style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ),
            // Overflow means events happened while the phone was away and were never
            // captured — worth knowing before drawing conclusions from what's here.
            if (dropped > 0)
              const DiagPill(text: 'ring overflow', level: DiagLevel.warn)
            else if (worst == DiagLevel.bad || worst == DiagLevel.warn)
              DiagPill(text: worst == DiagLevel.bad ? 'faults' : 'warnings', level: worst),
          ],
        ),
        const SizedBox(height: 8),
        if (display.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('No events match this filter.', style: TextStyle(color: Colors.white38, fontSize: 12)),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: display.length,
              itemBuilder: (context, i) {
                final r = display[i];
                // Anchor the device's uptime clock to phone time using the same read
                // that produced the counters, so an event can be lined up against the
                // app-side debug log above. Skipped when the record post-dates the
                // read (a notification can land between batches), which would
                // otherwise render a wall clock in the future.
                //
                // Also absent when the counters switch is off, since nothing is reading
                // uptime — events then show device uptime only, which is what this log
                // showed everywhere before this change. Deliberately NOT solved by
                // retaining the last anchor across the switch being off: an anchor from
                // before a reboot maps the new boot's uptimes to confidently wrong wall
                // clocks, and a wrong timestamp in a diagnostics tool is worse than an
                // absent one.
                final wall = stats != null && stats.currentUptimeMs >= r.uptimeMs
                    ? stats.readAt.subtract(Duration(milliseconds: stats.currentUptimeMs - r.uptimeMs))
                    : null;
                return DiagEventRow(record: r, uptimeLabel: '@${_formatDuration(r.uptimeMs)}', wallClock: wall);
              },
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _diagLogBusy ? null : () => _runDiagLogAction(() => devProvider.pullDiagLog()),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.deepPurpleAccent, width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: Text(
                  _diagLogBusy ? 'Working…' : 'Pull now',
                  style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _diagLogBusy ? null : () => _runDiagLogAction(() => devProvider.clearDiagLog()),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24, width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: const Text(
                  'Clear',
                  style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Collapsed-header summary for a group that has active flags.
  ///
  /// Capped rather than left to ellipsis: the header updates live while collapsed, so
  /// a group folded by hand still reports what it holds — but a long list would push
  /// a newly-appeared flag off the end invisibly. Saying "+2 more" keeps the header
  /// honest without re-expanding the group behind the user's back, which during a
  /// drop burst would mean fighting them open every 2 s.
  static String _alertSummary(List<String> flags) =>
      flags.length <= 2 ? flags.join(' · ') : '${flags.take(2).join(' · ')} +${flags.length - 2} more';

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
