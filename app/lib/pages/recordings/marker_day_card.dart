import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/services/recordings_manager.dart';

class MarkerTile extends StatelessWidget {
  final MarkerConversation mc;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const MarkerTile({super.key, required this.mc, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    // Pending markers (no backing segment) still need a long-press affordance
    // so the user can delete them — otherwise orphan EDLs accumulate forever
    // with no in-UI cleanup path (NEW1/C1).
    return InkWell(
      onTap: mc.isPending ? null : onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            FaIcon(
              FontAwesomeIcons.solidBookmark,
              color: mc.isPending ? Colors.grey.shade600 : Colors.amber,
              size: 14,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mc.isPending ? 'No audio attached' : mc.timeRangeLabel,
                    style: TextStyle(
                      color: mc.isPending ? Colors.grey.shade600 : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Marker at ${mc.markerTimeLabel}',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!mc.isPending && mc.userSaved) ...[
              const FaIcon(FontAwesomeIcons.circleCheck, color: Colors.green, size: 14),
              const SizedBox(width: 8),
            ],
            if (!mc.isPending) FaIcon(FontAwesomeIcons.chevronRight, color: Colors.grey.shade600, size: 14),
          ],
        ),
      ),
    );
  }
}

class MarkerDayCard extends StatelessWidget {
  final String dateStr;
  final List<MarkerConversation> markers;
  final void Function(MarkerConversation) onMarkerTap;
  final void Function(MarkerConversation) onDeleteMarkerConversation;

  const MarkerDayCard({
    super.key,
    required this.dateStr,
    required this.markers,
    required this.onMarkerTap,
    required this.onDeleteMarkerConversation,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = [...markers]..sort((a, b) => b.markerTime.compareTo(a.markerTime));
    return Card(
      color: const Color(0xFF1C1C1E),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 48,
              alignment: Alignment.centerLeft,
              child: Text(
                dateStr,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            ...sorted.map((mc) => MarkerTile(mc: mc, onTap: () => onMarkerTap(mc), onLongPress: () => onDeleteMarkerConversation(mc))),
          ],
        ),
      ),
    );
  }
}
