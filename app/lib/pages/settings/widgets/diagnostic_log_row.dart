import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// One row in the sync page's diagnostic log window.
class DiagnosticLogRow extends StatelessWidget {
  final Map<String, dynamic> log;

  const DiagnosticLogRow({super.key, required this.log});

  @override
  Widget build(BuildContext context) {
    final level = (log['level'] as String?) ?? 'INFO';
    final message = (log['message'] as String?) ?? '';
    final type = (log['type'] as String?) ?? '';
    final ts = (log['timestamp'] as String?) ?? (log['ts'] as String?) ?? '';

    final color = level == 'ERROR' ? Colors.redAccent : Colors.white70;
    final icon = level == 'ERROR'
        ? FontAwesomeIcons.circleXmark
        : (level == 'WARN' ? FontAwesomeIcons.circleExclamation : FontAwesomeIcons.circleInfo);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FaIcon(icon, size: 12, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.isNotEmpty ? message : type,
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (ts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(ts, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
