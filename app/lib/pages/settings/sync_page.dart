import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
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
    Logger.debug('DebugTools: Sync from Device tapped');
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
      Logger.debug('DebugTools: Calling syncAll(force: false)');
      final result = await ServiceManager.instance().wal.getSyncs().syncAll(progress: this);
      Logger.debug(
          'DebugTools: syncAll complete — result=${result == null ? 'null (nothing to sync)' : 'SyncLocalFilesResponse'}');
      setState(() {
        if (result == null) {
          _statusMessage = 'All synced! No new recordings found.';
        } else {
          _statusMessage = 'Sync Complete. Raw chunks downloaded.';
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
    Logger.debug('DebugTools: Force Re-scan Device tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Force re-scan blocked — processing already running');
      _showProcessingSnackbar();
      return;
    }
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Force Re-scan Device',
        'This will re-scan the device SD card from the beginning and download any recordings not yet on your phone. This may take a long time and use significant battery. Continue?',
        confirmText: 'Start',
      ),
    );
    if (confirm != true) {
      Logger.debug('DebugTools: Force re-scan cancelled by user');
      return;
    }

    setState(() {
      _isSyncing = true;
      _progress = 0.0;
      _statusMessage = 'Forcing re-sync from beginning...';
    });

    try {
      Logger.debug('DebugTools: Calling syncAll(force: true)');
      await ServiceManager.instance().wal.getSyncs().syncAll(progress: this, force: true);
      Logger.debug('DebugTools: Force re-scan complete');
      setState(() {
        _statusMessage = 'Re-sync Complete.';
        _isSyncing = false;
      });
    } catch (e) {
      Logger.error('DebugTools: Force re-scan error — $e');
      setState(() {
        _statusMessage = 'Re-sync Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _deleteAllPending() async {
    Logger.debug('DebugTools: Delete All from Device tapped');
    if (RecordingsManager.isProcessingAny) {
      Logger.debug('DebugTools: Delete blocked — processing already running');
      _showProcessingSnackbar();
      return;
    }
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        'Delete All Data',
        'This will permanently delete all raw recordings from your Omi device SD card. This action cannot be undone. Continue?',
        confirmText: 'Delete',
      ),
    );
    if (confirm != true) {
      Logger.debug('DebugTools: Delete cancelled by user');
      return;
    }

    setState(() {
      _isSyncing = true;
      _statusMessage = 'Deleting all data from device...';
    });

    try {
      Logger.debug('DebugTools: Calling deleteAllPendingWals()');
      await ServiceManager.instance().wal.getSyncs().deleteAllPendingWals();
      Logger.debug('DebugTools: deleteAllPendingWals complete');
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
        _statusMessage = 'Downloading chunks: ${(percentage * 100).toStringAsFixed(1)}% '
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
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const FaIcon(FontAwesomeIcons.bug, size: 48, color: Colors.amber),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 32),
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
                  label: 'Sync from Device',
                  description: 'Download raw recordings from your Omi via Bluetooth/WiFi.',
                  icon: FontAwesomeIcons.arrowDown,
                  onTap: _startSync,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Force Process All',
                  description: 'Process all raw chunks immediately, including the newest (may be incomplete).',
                  icon: FontAwesomeIcons.gears,
                  onTap: _isProcessing
                      ? null
                      : () async {
                          Logger.debug('DebugTools: Force Process All tapped');
                          if (RecordingsManager.isProcessingAny) {
                            Logger.debug('DebugTools: Force Process All blocked — processing already running');
                            _showProcessingSnackbar();
                            return;
                          }
                          setState(() => _statusMessage = 'Force processing all chunks...');
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
                  label: 'Force Re-scan Device',
                  description: 'Re-scans the SD card from the beginning and downloads any missing recordings.',
                  icon: FontAwesomeIcons.arrowsRotate,
                  onTap: _forceSync,
                ),
                const SizedBox(height: 12),
                _DebugButton(
                  label: 'Delete All from Device',
                  description: 'Permanently deletes all raw recordings from the Omi SD card.',
                  icon: FontAwesomeIcons.trashCan,
                  color: Colors.redAccent,
                  onTap: _deleteAllPending,
                ),
              ],
            ],
          ),
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
