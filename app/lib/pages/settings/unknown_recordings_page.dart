import 'package:flutter/material.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/pages/recordings/batch_card.dart'; // Contains ConversationTile
import 'package:omi/pages/recordings/recording_player_page.dart';
import 'dart:io';

class UnknownRecordingsPage extends StatefulWidget {
  const UnknownRecordingsPage({super.key});

  @override
  State<UnknownRecordingsPage> createState() => _UnknownRecordingsPageState();
}

class _UnknownRecordingsPageState extends State<UnknownRecordingsPage> {
  List<Conversation> _unknownConversations = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
    RecordingsManager.recordingsChangeNotifier.addListener(_loadData);
  }

  @override
  void dispose() {
    RecordingsManager.recordingsChangeNotifier.removeListener(_loadData);
    super.dispose();
  }

  Future<void> _loadData() async {
    final batches = await RecordingsManager().getBatches();
    final unknown = batches
        .expand((b) => b.finalizedRecordings)
        .where((c) => c.isUnknown)
        .toList();

    // Sort descending by their derived start times
    unknown.sort((a, b) => b.startTime.compareTo(a.startTime));

    if (mounted) {
      setState(() {
        _unknownConversations = unknown;
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDateAndRename(Conversation conversation) async {
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
    );
    if (date == null) return;

    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return;

    final newStartTime = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );

    final newTimestamp = newStartTime.millisecondsSinceEpoch;

    // Move .m4a and .meta files
    final parentDir = conversation.file.parent.parent.path;
    final dateString = '${newStartTime.year}-${newStartTime.month.toString().padLeft(2, '0')}-${newStartTime.day.toString().padLeft(2, '0')}';
    final targetDir = Directory('$parentDir/$dateString');
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final newM4aPath = '${targetDir.path}/recording_$newTimestamp.m4a';
    final newMetaPath = '${targetDir.path}/recording_$newTimestamp.meta';

    try {
      await conversation.file.rename(newM4aPath);

      final basePath = conversation.file.path.contains('.')
          ? conversation.file.path.substring(0, conversation.file.path.lastIndexOf('.'))
          : conversation.file.path;
      final metaFile = File('$basePath.meta');
      if (await metaFile.exists()) {
        await metaFile.rename(newMetaPath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to rename file.')));
      }
    }

    RecordingsManager.notifyRecordingsChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      appBar: AppBar(
        title: const Text('Unknown Timestamps'),
        backgroundColor: Theme.of(context).colorScheme.primary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressBinding())
          : _unknownConversations.isEmpty
              ? const Center(
                  child: Text('No recordings with unknown timestamps.',
                      style: TextStyle(color: Colors.white70)))
              : ListView.builder(
                  itemCount: _unknownConversations.length,
                  padding: const EdgeInsets.all(16.0),
                  itemBuilder: (context, index) {
                    final conv = _unknownConversations[index];
                    return Card(
                      color: Colors.grey[900],
                      margin: const EdgeInsets.only(bottom: 8.0),
                      child: ListTile(
                        title: Text('Unknown Date (${conv.durationLabel})', style: const TextStyle(color: Colors.white)),
                        subtitle: Text('Tap to set a valid date and time.', style: const TextStyle(color: Colors.white54)),
                        trailing: IconButton(
                          icon: const Icon(Icons.play_circle_fill, color: Colors.white),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ConversationPlayerPage(conversation: conv),
                              ),
                            );
                          },
                        ),
                        onTap: () => _pickDateAndRename(conv),
                      ),
                    );
                  },
                ),
    );
  }
}
class CircularProgressBinding extends StatelessWidget {
  const CircularProgressBinding({super.key});

  @override
  Widget build(BuildContext context) {
    return const CircularProgressIndicator(
      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
    );
  }
}
