import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
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
    if (RecordingsManager.isProcessingAny) { _showProcessingSnackbar(); return; }
    setState(() {
      _isSyncing = true;
      _progress = 0.0;
      _statusMessage = 'Connecting to device...';
    });

    try {
      // Call syncAll on the sync service (SdcardWalSync)
      final result = await ServiceManager.instance().wal.getSyncs().syncAll(progress: this);

      setState(() {
        if (result == null) {
          _statusMessage = 'All synced! No new recordings found.';
        } else {
          _statusMessage = 'Sync Complete. Raw chunks downloaded.';
        }
        _isSyncing = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Sync Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _forceSync() async {
    if (RecordingsManager.isProcessingAny) { _showProcessingSnackbar(); return; }
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
    if (confirm != true) return;

    setState(() {
      _isSyncing = true;
      _progress = 0.0;
      _statusMessage = 'Forcing re-sync from beginning...';
    });

    try {
      await ServiceManager.instance().wal.getSyncs().syncAll(progress: this, force: true);
      setState(() {
        _statusMessage = 'Re-sync Complete.';
        _isSyncing = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Re-sync Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _deleteAllPending() async {
    if (RecordingsManager.isProcessingAny) { _showProcessingSnackbar(); return; }
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
    if (confirm != true) return;

    setState(() {
      _isSyncing = true;
      _statusMessage = 'Deleting all data from device...';
    });

    try {
      await ServiceManager.instance().wal.getSyncs().deleteAllPendingWals();
      setState(() {
        _statusMessage = 'Delete Complete. Device storage cleared.';
        _isSyncing = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Delete Error: $e';
        _isSyncing = false;
      });
    }
  }

  Future<void> _cancelSync() async {
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
        title: const Text('Download Recordings'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const FaIcon(FontAwesomeIcons.download, size: 64, color: Colors.deepPurpleAccent),
              const SizedBox(height: 32),
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
                  onPressed: RecordingsManager.cancelProcessing,
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
                ElevatedButton(
                  onPressed: _startSync,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurpleAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  child: const Text('Start Download', style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _forceSync,
                  icon: const FaIcon(FontAwesomeIcons.arrowsRotate, size: 14, color: Colors.grey),
                  label: const Text('Force Re-scan Device', style: TextStyle(color: Colors.grey, fontSize: 14)),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _deleteAllPending,
                  icon: const FaIcon(FontAwesomeIcons.trashCan, size: 14, color: Colors.redAccent),
                  label: const Text('Delete All from Device', style: TextStyle(color: Colors.redAccent, fontSize: 14)),
                ),
                const SizedBox(height: 16),
                Text(
                  'This will download all raw recordings directly from your Omi device to your phone via Bluetooth/WiFi.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
