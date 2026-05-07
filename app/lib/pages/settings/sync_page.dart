import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/widgets/dialog.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> implements IWalSyncProgressListener {
  bool _isSyncing = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  String _statusMessage = 'Ready to sync';
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final processing = RecordingsManager.isProcessingAny;
      if (processing != _isProcessing) setState(() => _isProcessing = processing);
    });
    // Do NOT call start() here. start() fires getMissingWals() asynchronously and
    // overwrites _wals via .then(), which races with syncAll() between the moment it
    // takes its local `wals` snapshot and when it sets _isSyncing = true.
    // _wals is already populated by setDevice() when the device connected, and
    // syncAll() refreshes it internally if empty.
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
        setState(() => _statusMessage = 'Connecting to device...');
        await deviceProvider.scanAndConnectToDevice();
        setState(() => _statusMessage = 'Syncing segments...');
      }

      Logger.debug('DebugTools: Calling syncAll()');
      final result = await ServiceManager.instance().wal.getSyncs().syncAll(progress: this);
      Logger.debug(
          'DebugTools: syncAll complete — result=${result == null ? 'null (nothing to sync)' : 'SyncLocalFilesResponse'}');
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
        setState(() => _statusMessage = 'Connecting to device...');
        await deviceProvider.scanAndConnectToDevice();
        setState(() => _statusMessage = 'Rotating segment and syncing...');
      }

      Logger.debug('DebugTools: Calling rotateAndSync()');
      await ServiceManager.instance().wal.getSyncs().rotateAndSync(progress: this);
      Logger.debug('DebugTools: Force sync complete');
      setState(() {
        _statusMessage = 'Force Sync Complete.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: Force sync error — $e');
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

      setState(() {
        _statusMessage = 'Delete Complete. Device storage cleared.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: deleteAllPendingWals error — $e');
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

      setState(() {
        _statusMessage = 'Delete Complete. Phone segments cleared.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: _deleteAllSegments error — $e');
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

      setState(() {
        _statusMessage = 'Delete Complete. Phone conversations cleared.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: _deleteAllConversations error — $e');
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
        'This will permanently delete marker EDL files that have no matching recording (pending or orphaned), and remove their entries from markers.txt so they are not re-created. This cannot be undone. Continue?',
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

      // Remove the corresponding marker timestamps from every markers.txt so the
      // deleted EDLs don't get re-created on the next processing cycle.
      if (problematic.isNotEmpty) {
        final markerSecondsToRemove =
            problematic.map((mc) => mc.markerTime.millisecondsSinceEpoch ~/ 1000).toSet();
        final appDir = await getApplicationDocumentsDirectory();
        final rawSegmentsDir = Directory('${appDir.path}/raw_segments');
        if (await rawSegmentsDir.exists()) {
          final sessionFolders = (await rawSegmentsDir.list().toList()).whereType<Directory>().toList();
          for (final folder in sessionFolders) {
            final markerFile = File('${folder.path}/markers.txt');
            if (!await markerFile.exists()) continue;
            try {
              final lines = await markerFile.readAsLines();
              final filtered = lines.where((line) {
                final utc = int.tryParse(line.split(',')[0].trim());
                return utc == null || !markerSecondsToRemove.contains(utc);
              }).toList();
              if (filtered.length < lines.length) {
                if (filtered.isEmpty) {
                  await markerFile.delete();
                } else {
                  await markerFile.writeAsString('${filtered.join('\n')}\n');
                }
                Logger.debug(
                  'DebugTools: Removed ${lines.length - filtered.length} marker(s) from ${markerFile.path}',
                );
              }
            } catch (e) {
              Logger.error('DebugTools: Failed to clean markers.txt in ${folder.path}: $e');
            }
          }
        }
      }

      RecordingsManager.notifyRecordingsChanged();
      setState(() {
        _statusMessage =
            problematic.isEmpty ? 'No problematic EDLs found.' : 'Deleted ${problematic.length} problematic EDL(s).';
      });
    } catch (e) {
      Logger.error('DebugTools: _deleteProblematicEdls error — $e');
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

  @override
  void dispose() {
    _pollTimer?.cancel();
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
              const SizedBox(height: 24),
              Consumer<DeviceProvider>(
                builder: (context, deviceProvider, _) {
                  return _CrashLogSection(
                    logs: deviceProvider.crashLogs,
                    onClear: () => deviceProvider.clearCrashLogs(),
                  );
                },
              ),
              const SizedBox(height: 16),
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
                  description: 'Permanently deletes raw segment files stored on this phone.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllSegments,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Delete Phone Conversations',
                  description: 'Permanently deletes finalized recordings and conversations.',
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
}

class _CrashLogSection extends StatelessWidget {
  final List<DeviceCrashLog> logs;
  final VoidCallback onClear;

  const _CrashLogSection({required this.logs, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const FaIcon(FontAwesomeIcons.triangleExclamation, size: 13, color: Colors.amber),
            const SizedBox(width: 8),
            const Text('Device Crash Log',
                style: TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('${logs.length} entr${logs.length == 1 ? 'y' : 'ies'}',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        if (logs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No diagnostics yet — connect the device to read.',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else
          ...logs.map((log) => _CrashLogRow(log: log)),
        if (logs.isNotEmpty) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onClear,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FaIcon(FontAwesomeIcons.trashCan, size: 12, color: Colors.grey),
                  SizedBox(width: 8),
                  Text('Clear Crash Log', style: TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),
          ),
        ],
        const Divider(color: Color(0xFF2C2C2E), height: 32),
      ],
    );
  }
}

class _CrashLogRow extends StatelessWidget {
  final DeviceCrashLog log;

  const _CrashLogRow({required this.log});

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('MMM d, HH:mm').format(log.connectedAt);
    final color = log.isCrash ? Colors.redAccent : Colors.white70;
    final icon = log.isCrash ? FontAwesomeIcons.circleExclamation : FontAwesomeIcons.circleCheck;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(10),
          border: log.isCrash ? Border.all(color: Colors.redAccent.withOpacity(0.4)) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FaIcon(icon, size: 13, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(log.causeLabel, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text('${log.isCrash ? 'crashed after' : 'session'} ${log.uptimeStr} · read at $timeStr',
                      style: const TextStyle(color: Colors.grey, fontSize: 11)),
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
