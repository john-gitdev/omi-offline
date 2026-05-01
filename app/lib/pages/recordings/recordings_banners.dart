import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/pages/recordings/recordings_types.dart';

class StorageWarningBanner extends StatelessWidget {
  final int percentage;
  const StorageWarningBanner({super.key, required this.percentage});

  @override
  Widget build(BuildContext context) {
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
}

class AccumulatingBanner extends StatelessWidget {
  final SyncProcessState spState;
  final double accumulatedMinutes;
  final VoidCallback? onTap;
  const AccumulatingBanner({super.key, required this.spState, required this.accumulatedMinutes, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (spState == SyncProcessState.syncing ||
        spState == SyncProcessState.processing ||
        spState == SyncProcessState.stopping) return const SizedBox.shrink();
    if (accumulatedMinutes < 1.0) return const SizedBox.shrink();

    final int accMin = accumulatedMinutes.floor();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Conversation in progress',
                  style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  '$accMin ${accMin == 1 ? 'minute' : 'minutes'} accumulated',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            button: true,
            label: 'View conversation in progress',
            child: Tooltip(
              message: 'View conversation in progress',
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: Ink(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: InkWell(
                    onTap: onTap,
                    child: const Center(
                      child: FaIcon(FontAwesomeIcons.hourglassHalf, color: Colors.deepPurpleAccent, size: 16),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AdjustmentCleanupBanner extends StatelessWidget {
  final bool adjustmentMode;
  final bool adjustmentModeWasEnabled;
  final SyncProcessState spState;
  final int pendingDays;
  final VoidCallback onTap;

  const AdjustmentCleanupBanner({
    super.key,
    required this.adjustmentMode,
    required this.adjustmentModeWasEnabled,
    required this.spState,
    required this.pendingDays,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (adjustmentMode) return const SizedBox.shrink();
    if (!adjustmentModeWasEnabled) return const SizedBox.shrink();
    if (spState != SyncProcessState.idle) return const SizedBox.shrink();
    if (pendingDays == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Semantics(
        button: true,
        label: 'Clean up raw audio',
        child: Tooltip(
          message: 'Clean up raw audio',
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3), width: 1),
              ),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const FaIcon(FontAwesomeIcons.triangleExclamation, color: Colors.orange, size: 16),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Raw audio pending cleanup',
                              style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w500, fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$pendingDays ${pendingDays == 1 ? 'day' : 'days'} of raw files still on disk. Tap to process & delete.',
                              style: TextStyle(color: Colors.orange.shade300, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
