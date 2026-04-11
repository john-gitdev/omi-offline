import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/pages/recordings/recordings_page.dart'; // To access SyncProcessState

class AdjustmentCleanupBanner extends StatelessWidget {
  final bool adjustmentMode;
  final bool adjustmentModeWasEnabled;
  final SyncProcessState spState;
  final int pendingDays;
  final VoidCallback onRunAdjustmentCleanup;

  const AdjustmentCleanupBanner({
    super.key,
    required this.adjustmentMode,
    required this.adjustmentModeWasEnabled,
    required this.spState,
    required this.pendingDays,
    required this.onRunAdjustmentCleanup,
  });

  @override
  Widget build(BuildContext context) {
    if (adjustmentMode) return const SizedBox.shrink();
    if (!adjustmentModeWasEnabled) return const SizedBox.shrink();
    if (spState != SyncProcessState.idle) return const SizedBox.shrink();
    if (pendingDays == 0) return const SizedBox.shrink();

    return GestureDetector(
      onTap: onRunAdjustmentCleanup,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.orange.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            const FaIcon(
              FontAwesomeIcons.triangleExclamation,
              color: Colors.orange,
              size: 16,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Raw audio pending cleanup',
                    style: TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$pendingDays ${pendingDays == 1 ? 'day' : 'days'} of raw files still on disk. Tap to process & delete.',
                    style: TextStyle(
                      color: Colors.orange.shade300,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
