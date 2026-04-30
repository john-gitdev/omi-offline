import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/pages/recordings/recording_player_page.dart';

class UploadIconButton extends StatelessWidget {
  final String? uploadKey;
  final bool apiKeyEmpty;
  final bool isUploading;
  final bool isUploaded;
  final bool adjustmentMode;
  final VoidCallback? onTap;

  const UploadIconButton({
    super.key,
    required this.uploadKey,
    required this.apiKeyEmpty,
    required this.isUploading,
    required this.isUploaded,
    required this.adjustmentMode,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (apiKeyEmpty) return const SizedBox.shrink();
    if (adjustmentMode) {
      return IconButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        icon: Icon(Icons.cloud_off, color: Colors.grey.shade700, size: 18),
        tooltip: 'Uploads paused in Adjustment Mode',
        onPressed: onTap,
      );
    }
    if (uploadKey == null) {
      return IconButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        icon: Icon(Icons.cloud_off, color: Colors.grey.shade600, size: 18),
        tooltip: 'Upload key unavailable',
        onPressed: onTap,
      );
    }
    if (isUploading) {
      return IconButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        icon: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.deepPurpleAccent),
        ),
        tooltip: 'Uploading to HeyPocket',
        onPressed: null,
      );
    }
    if (isUploaded) {
      return IconButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(),
        icon: const Icon(Icons.cloud_done, color: Colors.green, size: 18),
        tooltip: 'Re-upload to HeyPocket',
        onPressed: onTap,
      );
    }
    return IconButton(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      constraints: const BoxConstraints(),
      icon: const Icon(Icons.cloud_upload, color: Colors.redAccent, size: 18),
      tooltip: 'Upload to HeyPocket',
      onPressed: onTap,
    );
  }
}

class MarkerSubEntry extends StatelessWidget {
  final MarkerConversation mc;
  final void Function()? onTap;
  final void Function()? onLongPress;

  const MarkerSubEntry({super.key, required this.mc, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: mc.isPending ? null : onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, top: 6, bottom: 6, right: 4),
        child: Row(
          children: [
            FaIcon(
              FontAwesomeIcons.solidBookmark,
              color: mc.isPending ? Colors.grey.shade600 : Colors.amber,
              size: 11,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mc.isPending ? 'Processing…' : mc.timeRangeLabel,
                    style: TextStyle(
                      color: mc.isPending ? Colors.grey.shade600 : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    'marker at ${mc.markerTimeLabel}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (!mc.isPending && mc.userSaved) ...[
              const FaIcon(FontAwesomeIcons.circleCheck, color: Colors.green, size: 12),
              const SizedBox(width: 6),
            ],
            if (!mc.isPending) FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade700, size: 12),
          ],
        ),
      ),
    );
  }
}

class ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final List<MarkerConversation> markers;
  final Widget uploadIcon;
  final void Function(MarkerConversation) onMarkerTap;
  final void Function(Conversation) onConversationTap;
  final void Function(Conversation) onDeleteConversation;
  final void Function(MarkerConversation) onDeleteMarkerConversation;

  const ConversationTile({
    super.key,
    required this.conversation,
    required this.markers,
    required this.uploadIcon,
    required this.onMarkerTap,
    required this.onConversationTap,
    required this.onDeleteConversation,
    required this.onDeleteMarkerConversation,
  });

  @override
  Widget build(BuildContext context) {
    final sortedMarkers = [...markers]..sort((a, b) => a.markerTime.compareTo(b.markerTime));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onConversationTap(conversation),
          onLongPress: () => onDeleteConversation(conversation),
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
                        conversation.timeRangeLabel,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${conversation.durationLabel}  ·  ${conversation.sizeLabel}',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (markers.isNotEmpty) ...[
                  const FaIcon(FontAwesomeIcons.solidBookmark, color: Colors.amber, size: 13),
                  const SizedBox(width: 8),
                ],
                uploadIcon,
                FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade600, size: 14),
              ],
            ),
          ),
        ),
        ...sortedMarkers.map((mc) =>
            MarkerSubEntry(mc: mc, onTap: () => onMarkerTap(mc), onLongPress: () => onDeleteMarkerConversation(mc))),
      ],
    );
  }
}

class BatchCard extends StatelessWidget {
  final Batch batch;
  final Map<String, List<MarkerConversation>> markerMap;
  final bool adjustmentMode;
  final String heypocketApiKey;
  final bool Function(String) isUploaded;
  final bool Function(String) isUploading;
  final void Function(Conversation) onUploadTap;
  final void Function(Conversation) onConversationTap;
  final void Function(MarkerConversation) onMarkerTap;
  final void Function(List<Conversation>) onExportAll;
  final VoidCallback onDeleteDay;
  final VoidCallback onReprocessDay;
  final void Function(Conversation) onDeleteConversation;
  final void Function(MarkerConversation) onDeleteMarkerConversation;

  const BatchCard({
    super.key,
    required this.batch,
    required this.markerMap,
    required this.adjustmentMode,
    required this.heypocketApiKey,
    required this.isUploaded,
    required this.isUploading,
    required this.onUploadTap,
    required this.onConversationTap,
    required this.onMarkerTap,
    required this.onExportAll,
    required this.onDeleteDay,
    required this.onReprocessDay,
    required this.onDeleteConversation,
    required this.onDeleteMarkerConversation,
  });

  @override
  Widget build(BuildContext context) {
    final conversations = [...batch.finalizedRecordings]..sort((a, b) => b.startTime.compareTo(a.startTime));
    final minFilterSeconds = SharedPreferencesUtil().filterMinDurationSeconds;
    final filtered = minFilterSeconds > 0
        ? conversations.where((c) => c.duration.inSeconds >= minFilterSeconds).toList()
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
            Text(
              batch.dateString,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...filtered.map((c) {
              final fileKey = c.file.path.split('/').last;
              final markers = markerMap[fileKey] ?? [];
              final uploadKey = c.uploadKey;
              return ConversationTile(
                conversation: c,
                markers: markers,
                onConversationTap: onConversationTap,
                onDeleteConversation: onDeleteConversation,
                onDeleteMarkerConversation: onDeleteMarkerConversation,
                uploadIcon: UploadIconButton(
                  uploadKey: uploadKey,
                  apiKeyEmpty: heypocketApiKey.isEmpty,
                  isUploading: uploadKey != null && isUploading(uploadKey),
                  isUploaded: uploadKey != null && isUploaded(uploadKey),
                  adjustmentMode: adjustmentMode,
                  onTap: () => onUploadTap(c),
                ),
                onMarkerTap: onMarkerTap,
              );
            }),
            const SizedBox(height: 4),
            const Divider(color: Color(0xFF2C2C2E), height: 1),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  key: Key('export_all_${batch.dateString}'),
                  onPressed: () => onExportAll(filtered),
                  icon: FaIcon(FontAwesomeIcons.shareFromSquare, size: 13, color: Colors.grey.shade400),
                  label: Text('Export All', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                ),
                if (adjustmentMode && batch.rawSegments.isNotEmpty)
                  TextButton.icon(
                    key: Key('reprocess_day_${batch.dateString}'),
                    onPressed: onReprocessDay,
                    icon: const FaIcon(FontAwesomeIcons.rotateRight, size: 13, color: Colors.deepPurpleAccent),
                    label: const Text('Reprocess Day', style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 13)),
                  )
                else
                  TextButton.icon(
                    key: Key('delete_day_${batch.dateString}'),
                    onPressed: onDeleteDay,
                    icon: FaIcon(FontAwesomeIcons.trashCan, size: 13, color: Colors.red.shade400),
                    label: Text('Delete Day', style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
