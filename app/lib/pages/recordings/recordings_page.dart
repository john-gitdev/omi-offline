import 'dart:io';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/pages/settings/settings_drawer.dart';
import 'package:omi/pages/settings/find_devices_page.dart';
import 'package:just_audio/just_audio.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  final RecordingsManager _manager = RecordingsManager();
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  List<DailyBatch> _batches = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  String? _currentlyPlayingPath;
  bool _isPlaying = false;
  
  // Processing state
  String? _processingDateString;
  double _processingProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _loadBatches();
    
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing && state.processingState != ProcessingState.completed;
          if (state.processingState == ProcessingState.completed) {
            _currentlyPlayingPath = null;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
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

  Future<void> _handleSync() async {
    if (_isSyncing || RecordingsManager.isProcessingAny) return;
    
    setState(() {
      _isSyncing = true;
    });
    WakelockPlus.enable();

    try {
      final syncService = ServiceManager.instance().wal.getSyncs();
      syncService.start(); // Refresh missing WALs list
      final result = await syncService.syncAll();
      
      if (mounted) {
        if (result != null && (result.newConversationIds.isNotEmpty || result.updatedConversationIds.isNotEmpty)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sync complete! New recordings found.')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sync complete. No new data.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
        );
      }
    } finally {
      WakelockPlus.disable();
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
        _loadBatches();
      }
    }
  }

  Future<void> _processBatch(DailyBatch batch) async {
    if (RecordingsManager.isProcessingAny || _isSyncing) return;

    // Large batch warning (e.g. > 60 chunks = ~1 hour of audio)
    if (batch.rawChunks.length > 60) {
      bool? confirm = await showDialog<bool>(
        context: context,
        builder: (c) => getDialog(
          context,
          () => Navigator.of(context).pop(false),
          () => Navigator.of(context).pop(true),
          'Large Batch',
          'This day has over ${batch.rawChunks.length} raw chunks. Processing might take a few minutes. Continue?',
          confirmText: 'Start',
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
        if (mounted) {
          setState(() {
            _processingProgress = progress;
          });
        }
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

  Future<void> _togglePlay(File file) async {
    try {
      if (_currentlyPlayingPath == file.path && _isPlaying) {
        await _audioPlayer.pause();
      } else {
        if (_currentlyPlayingPath != file.path) {
          await _audioPlayer.setFilePath(file.path);
        }
        await _audioPlayer.play();
        setState(() {
          _currentlyPlayingPath = file.path;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing audio: $e')),
      );
    }
  }

  Widget _buildBatchCard(DailyBatch batch) {
    final isProcessing = _processingDateString == batch.dateString;

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
                          '${batch.rawChunks.length} Raw Chunks',
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                        ElevatedButton.icon(
                          onPressed: isProcessing ? null : () => _processBatch(batch),
                          icon: isProcessing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const FaIcon(FontAwesomeIcons.gears, size: 14),
                          label: Text(isProcessing ? 'Processing...' : 'Process Day'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepPurpleAccent,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    if (isProcessing) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _processingProgress,
                        backgroundColor: Colors.grey.shade800,
                        color: Colors.deepPurpleAccent,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            if (batch.processedRecordings.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text('No processed recordings yet.', style: TextStyle(color: Colors.grey.shade500)),
              )
            else
              ...batch.processedRecordings.map((file) {
                final fileName = file.path.split('/').last;
                final isThisPlaying = _currentlyPlayingPath == file.path && _isPlaying;
                
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: isThisPlaying ? Colors.deepPurpleAccent : Colors.grey.shade800,
                    child: IconButton(
                      icon: FaIcon(
                        isThisPlaying ? FontAwesomeIcons.pause : FontAwesomeIcons.play,
                        color: Colors.white,
                        size: 14,
                      ),
                      onPressed: () => _togglePlay(file),
                    ),
                  ),
                  title: Text(
                    fileName,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    'Processed AAC Audio',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                );
              }),
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
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (c) => const FindDevicesPage()),
                    );
                  },
                )
              else
                IconButton(
                  icon: const FaIcon(FontAwesomeIcons.bluetooth, color: Colors.blueAccent, size: 20),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (c) => const DeviceSettings()),
                    );
                  },
                ),
              IconButton(
                icon: const FaIcon(FontAwesomeIcons.gear, color: Colors.white, size: 20),
                onPressed: () {
                  SettingsDrawer.show(context);
                },
              ),
            ],
          ),
          body: Column(
            children: [
              _buildStorageWarning(deviceProvider.storageFullPercentage),
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
                                        if (!deviceProvider.isConnected) ...[
                                          const SizedBox(height: 32),
                                          ElevatedButton(
                                            onPressed: () {
                                              Navigator.of(context).push(
                                                MaterialPageRoute(builder: (c) => const FindDevicesPage()),
                                              );
                                            },
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
                                itemCount: _batches.length,
                                itemBuilder: (context, index) {
                                  return _buildBatchCard(_batches[index]);
                                },
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
