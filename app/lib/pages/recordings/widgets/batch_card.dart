import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/services/recordings_manager.dart';

class BatchCard extends StatelessWidget {
  final Batch batch;
  final Map<String, List<MarkerConversation>> markerMap;
  final int minFilterSeconds;
  final Set<String> uploadingFiles;

  final Function(Batch) onDeleteDay;
  final Function(Batch) onReprocessDay;
  final Function(Batch, List<Conversation>) onExportAll;
  final Widget Function(Conversation) buildUploadIcon;
  final Function(Conversation) onHandleUploadTap;
  final Function(MarkerConversation) onOpenMarkerConversation;
  final Function(BuildContext, Conversation, List<MarkerConversation>)
  onNavigateToRecording;

  const BatchCard({
    super.key,
    required this.batch,
    required this.markerMap,
    required this.minFilterSeconds,
    required this.uploadingFiles,
    required this.onDeleteDay,
    required this.onReprocessDay,
    required this.onExportAll,
    required this.buildUploadIcon,
    required this.onHandleUploadTap,
    required this.onOpenMarkerConversation,
    required this.onNavigateToRecording,
  });

  @override
  Widget build(BuildContext context) {
    final conversations = [...batch.finalizedRecordings]
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final filtered = minFilterSeconds > 0
        ? conversations
              .where((c) => c.duration.inSeconds >= minFilterSeconds)
              .toList()
        : conversations;
    if (filtered.isEmpty) return const SizedBox.shrink();

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
                  batch.dateStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const FaIcon(
                    FontAwesomeIcons.ellipsis,
                    color: Colors.white70,
                    size: 16,
                  ),
                  color: const Color(0xFF2C2C2E),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'export',
                      child: Text(
                        'Export All',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'reprocess',
                      child: Text(
                        'Reprocess Day',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete Day',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 'export') {
                      onExportAll(batch, filtered);
                    } else if (value == 'delete') {
                      onDeleteDay(batch);
                    } else if (value == 'reprocess') {
                      onReprocessDay(batch);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...filtered.map((c) => _buildConversationTile(context, c)),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(BuildContext context, Conversation c) {
    final markersInConv = markerMap[c.file.path.split('/').last] ?? [];

    // Sort markers within the conversation by time
    final sortedMarkers = [...markersInConv]
      ..sort((a, b) => a.markerTime.compareTo(b.markerTime));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onNavigateToRecording(context, c, sortedMarkers),
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
                        c.timeRangeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        c.durationLabel,
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                buildUploadIcon(c),
                const SizedBox(width: 12),
                FaIcon(
                  FontAwesomeIcons.chevronRight,
                  color: Colors.grey.shade600,
                  size: 14,
                ),
              ],
            ),
          ),
        ),
        if (sortedMarkers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 4, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: sortedMarkers
                  .map((mc) => _buildMarkerSubEntry(mc))
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildMarkerSubEntry(MarkerConversation mc) {
    return InkWell(
      onTap: mc.isPending ? null : () => onOpenMarkerConversation(mc),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          children: [
            FaIcon(
              FontAwesomeIcons.solidBookmark,
              color: mc.isPending ? Colors.grey.shade600 : Colors.amber,
              size: 12,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                mc.isPending
                    ? 'Processing marker…'
                    : 'Marker at ${mc.markerTimeLabel}',
                style: TextStyle(
                  color: mc.isPending
                      ? Colors.grey.shade600
                      : Colors.amber.shade100,
                  fontSize: 13,
                ),
              ),
            ),
            if (!mc.isPending && mc.userSaved) ...[
              const FaIcon(
                FontAwesomeIcons.circleCheck,
                color: Colors.green,
                size: 12,
              ),
              const SizedBox(width: 8),
            ],
            if (!mc.isPending)
              FaIcon(
                FontAwesomeIcons.chevronRight,
                color: Colors.grey.shade600,
                size: 10,
              ),
          ],
        ),
      ),
    );
  }
}
