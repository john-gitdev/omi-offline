import 'dart:io';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/pages/recordings/recordings_types.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/utils/other/time_utils.dart';

class UploadIconButton extends StatelessWidget {
  final Conversation? conversation;
  final bool anyIntegrationEnabled;
  final bool isUploading;
  final UploadStatus uploadStatus;

  /// Number of integrations that still need attention for this recording
  /// (pending or failed); a count badge is overlaid on the icon when >= 2 so it
  /// reflects how many remain to be addressed, not the total configured. The
  /// badge color follows [uploadStatus]. The icon is a non-interactive indicator —
  /// taps fall through to the row, which opens the player where the
  /// per-integration detail and actions live.
  final int integrationCount;

  const UploadIconButton({
    super.key,
    required this.conversation,
    required this.anyIntegrationEnabled,
    required this.isUploading,
    required this.uploadStatus,
    this.integrationCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (!anyIntegrationEnabled) return const SizedBox.shrink();

    if (conversation == null) {
      return _indicator(Icons.cloud_off, Colors.grey.shade600, 'Upload key unavailable');
    }
    if (isUploading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.deepPurpleAccent),
        ),
      );
    }

    final (IconData icon, Color color, String tooltip) = switch (uploadStatus) {
      UploadStatus.all => (Icons.cloud_done, Colors.green, 'Uploaded to all integrations'),
      UploadStatus.partial => (Icons.cloud_upload, Colors.amber, 'Some integrations pending'),
      UploadStatus.failed => (Icons.error_outline, Colors.orange, 'Upload failed'),
      UploadStatus.unavailable => (Icons.cloud_off, Colors.grey.shade600, 'No uploadable file for this recording'),
      UploadStatus.none => (Icons.cloud_upload, Colors.redAccent, 'Not uploaded'),
    };
    return _indicator(icon, color, tooltip);
  }

  Widget _indicator(IconData icon, Color color, String tooltip) {
    final showBadge = integrationCount >= 2;
    final iconWidget = showBadge
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, color: color, size: 18),
              Positioned(
                right: -5,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 1),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: const Color(0xFF1C1C1E), width: 1),
                  ),
                  child: Text(
                    '$integrationCount',
                    style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold, height: 1.0),
                  ),
                ),
              ),
            ],
          )
        : Icon(icon, color: color, size: 18);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(message: tooltip, child: iconWidget),
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
              child: Text(
                mc.isPending ? 'Marker at ${mc.markerTimeLabel} (no audio)' : 'Marker at ${mc.markerTimeLabel}',
                style: TextStyle(
                  color: mc.isPending ? Colors.grey.shade600 : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
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

  bool _isAdjustmentMode() {
    if (conversation.relativeBins.isEmpty) return false;
    try {
      final docsPath = conversation.file.parent.parent.parent.path;
      for (final rel in conversation.relativeBins) {
        if (!File('$docsPath/adjustment_mode_segments/$rel').existsSync()) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sortedMarkers = [...markers]..sort((a, b) => a.markerTime.compareTo(b.markerTime));
    final isPassthrough = conversation.passthrough;
    final subtitle =
        isPassthrough ? conversation.durationLabel : '${conversation.durationLabel}  ·  ${conversation.sizeLabel}';
    final isAdj = _isAdjustmentMode();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: isPassthrough ? null : () => onConversationTap(conversation),
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
                      Row(
                        children: [
                          Text(
                            isAdj ? '${conversation.timeRangeLabel} | ADJ' : conversation.timeRangeLabel,
                            style: TextStyle(
                              color: isPassthrough ? Colors.grey.shade400 : Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (conversation.forceSynced) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.bolt, color: Colors.amber, size: 16),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (isPassthrough) ...[
                  Icon(Icons.send_rounded, size: 16, color: Colors.deepPurpleAccent.withValues(alpha: 0.8)),
                  const SizedBox(width: 6),
                ] else ...[
                  uploadIcon,
                  FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade600, size: 14),
                ],
              ],
            ),
          ),
        ),
        if (!isPassthrough)
          ...sortedMarkers.map((mc) =>
              MarkerSubEntry(mc: mc, onTap: () => onMarkerTap(mc), onLongPress: () => onDeleteMarkerConversation(mc))),
      ],
    );
  }
}

class _Row {
  final Conversation? recording;
  final DiscardRecord? discard;
  _Row.recording(this.recording) : discard = null;
  _Row.ghost(this.discard) : recording = null;
  DateTime get startTime => recording?.startTime ?? discard!.startTime;
}

class GhostRow extends StatelessWidget {
  final DiscardRecord discard;
  final VoidCallback onTap;

  const GhostRow({super.key, required this.discard, required this.onTap});

  static String _durationLabel(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m';
    if (d.inMinutes > 0) return '${m}m';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final timeRange = '${fmtHourMin(discard.startTime)}–${fmtHourMin(discard.endTime)}';
    final dur = _durationLabel(discard.duration);
    final subLabel = discard.isNoise
        ? 'below minimum speech'
        : discard.reason == 'silence_only'
            ? 'no speech detected'
            : 'below minimum length';
    return InkWell(
      onTap: onTap,
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
                    timeRange,
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$subLabel  ·  $dur',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                ],
              ),
            ),
            FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade800, size: 12),
          ],
        ),
      ),
    );
  }
}

Future<void> showDiscardSheet(
  BuildContext context,
  DiscardRecord d, {
  required Future<void> Function(DiscardRecord) onRecover,
  required Future<void> Function(DiscardRecord) onDeleteNow,
}) async {
  final use24 = SharedPreferencesUtil().use24HourTime;
  String two(int n) => n.toString().padLeft(2, '0');
  String fmtTime(DateTime t) {
    if (use24) return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final h12 = t.hour == 0 ? 12 : (t.hour > 12 ? t.hour - 12 : t.hour);
    return '$h12:${two(t.minute)}:${two(t.second)} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  String fmtAbs(DateTime t) => '${t.year}-${two(t.month)}-${two(t.day)} ${fmtHourMin(t)}';
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1C1C1E),
    showDragHandle: true,
    builder: (sheetCtx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${fmtTime(d.startTime)} – ${fmtTime(d.endTime)}  ·  ${d.duration.inMinutes} min',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Raw audio retained until ${fmtAbs(d.expiresAt.toLocal())}',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurpleAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const FaIcon(FontAwesomeIcons.rotateLeft, size: 14),
              label: const Text('Recover to Recording'),
              onPressed: () async {
                Navigator.of(sheetCtx).pop();
                await onRecover(d);
              },
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade300,
                side: BorderSide(color: Colors.red.shade700.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const FaIcon(FontAwesomeIcons.trashCan, size: 13),
              label: const Text('Delete now'),
              onPressed: () async {
                Navigator.of(sheetCtx).pop();
                await onDeleteNow(d);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class BatchCard extends StatelessWidget {
  final Batch batch;
  final Map<String, List<MarkerConversation>> markerMap;
  final bool anyIntegrationEnabled;
  final RecordingFilterMode filterMode;
  final UploadStatus Function(Conversation) uploadStatus;
  final int Function(Conversation) uploadCount;
  final bool Function(String) isUploading;
  final void Function(Conversation) onConversationTap;
  final void Function(MarkerConversation) onMarkerTap;
  final void Function(List<Conversation>) onExportAll;
  final void Function(List<Conversation>, List<DiscardRecord>) onDeleteDay;
  final void Function(List<DiscardRecord>) onDeleteAllDiscards;
  final void Function(Conversation) onDeleteConversation;
  final void Function(MarkerConversation) onDeleteMarkerConversation;
  final Future<void> Function(DiscardRecord) onRecoverDiscard;
  final Future<void> Function(DiscardRecord) onDeleteDiscard;

  const BatchCard({
    super.key,
    required this.batch,
    required this.markerMap,
    required this.anyIntegrationEnabled,
    required this.filterMode,
    required this.uploadStatus,
    required this.uploadCount,
    required this.isUploading,
    required this.onConversationTap,
    required this.onMarkerTap,
    required this.onExportAll,
    required this.onDeleteDay,
    required this.onDeleteAllDiscards,
    required this.onDeleteConversation,
    required this.onDeleteMarkerConversation,
    required this.onRecoverDiscard,
    required this.onDeleteDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final conversations = [...batch.finalizedRecordings]..sort((a, b) => b.startTime.compareTo(a.startTime));
    final minFilterSeconds = SharedPreferencesUtil().filterMinDurationSeconds;
    final filtered = minFilterSeconds > 0
        ? switch (filterMode) {
            RecordingFilterMode.visible =>
              conversations.where((c) => c.duration.inSeconds >= minFilterSeconds).toList(),
            RecordingFilterMode.hidden => conversations.where((c) => c.duration.inSeconds < minFilterSeconds).toList(),
            RecordingFilterMode.all => conversations,
          }
        : conversations;
    // Apply the same filter to ghost rows so short discards land in the
    // hidden tab alongside short recordings instead of cluttering the
    // visible tab. With no minimum set, all discards show in all tabs.
    final discards = minFilterSeconds > 0
        ? switch (filterMode) {
            RecordingFilterMode.visible =>
              batch.discards.where((d) => d.duration.inSeconds >= minFilterSeconds).toList(),
            RecordingFilterMode.hidden => batch.discards.where((d) => d.duration.inSeconds < minFilterSeconds).toList(),
            RecordingFilterMode.all => [...batch.discards],
          }
        : [...batch.discards];
    if (filtered.isEmpty && discards.isEmpty) {
      return const SizedBox.shrink();
    }

    // Time-sorted (newest first) merge of recordings and ghosts.
    final items = <_Row>[
      for (final c in filtered) _Row.recording(c),
      for (final d in discards) _Row.ghost(d),
    ]..sort((a, b) => b.startTime.compareTo(a.startTime));

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
            ...items.map((r) {
              if (r.discard != null) {
                final d = r.discard!;
                return GhostRow(
                  key: ValueKey('ghost_${d.id}'),
                  discard: d,
                  onTap: () => showDiscardSheet(
                    context,
                    d,
                    onRecover: onRecoverDiscard,
                    onDeleteNow: onDeleteDiscard,
                  ),
                );
              }
              final c = r.recording!;
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
                  conversation: c,
                  anyIntegrationEnabled: anyIntegrationEnabled,
                  isUploading: uploadKey != null && isUploading(uploadKey),
                  uploadStatus: uploadStatus(c),
                  integrationCount: uploadCount(c),
                ),
                onMarkerTap: onMarkerTap,
              );
            }),
            const SizedBox(height: 4),
            const Divider(color: Color(0xFF2C2C2E), height: 1),
            const SizedBox(height: 4),
            OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.center,
              overflowSpacing: 4,
              children: [
                TextButton.icon(
                  key: Key('export_all_${batch.dateString}'),
                  onPressed: () => onExportAll(filtered),
                  icon: FaIcon(FontAwesomeIcons.shareFromSquare, size: 13, color: Colors.grey.shade400),
                  label: Text('Export All', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                ),
                if (discards.isNotEmpty)
                  TextButton.icon(
                    key: Key('delete_discards_${batch.dateString}'),
                    onPressed: () => onDeleteAllDiscards(discards),
                    icon: FaIcon(FontAwesomeIcons.ghost, size: 13, color: Colors.orange.shade300),
                    label: Text('Delete Discards', style: TextStyle(color: Colors.orange.shade300, fontSize: 13)),
                  ),
                TextButton.icon(
                  key: Key('delete_day_${batch.dateString}'),
                  onPressed: () => onDeleteDay(filtered, discards),
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
