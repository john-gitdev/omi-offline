import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/pages/recordings/recordings_page.dart'; // To access SyncProcessState

class AccumulatingBanner extends StatelessWidget {
  final SyncProcessState spState;
  final double accumulatedMinutes;

  const AccumulatingBanner({
    super.key,
    required this.spState,
    required this.accumulatedMinutes,
  });

  @override
  Widget build(BuildContext context) {
    if (spState == SyncProcessState.syncing ||
        spState == SyncProcessState.processing ||
        spState == SyncProcessState.stopping) {
      return const SizedBox.shrink();
    }
    if (accumulatedMinutes < 1.0) return const SizedBox.shrink();

    final int accMin = accumulatedMinutes.floor();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Conversation in progress',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$accMin ${accMin == 1 ? 'minute' : 'minutes'} accumulated',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: FaIcon(
                    FontAwesomeIcons.hourglassHalf,
                    color: Colors.deepPurpleAccent,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
