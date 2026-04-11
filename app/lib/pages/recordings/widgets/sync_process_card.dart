import 'dart:async';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/pages/recordings/recordings_page.dart'; // To access SyncProcessState

class SyncProcessCard extends StatelessWidget {
  final SyncProcessState spState;
  final bool isForcePipeline;
  final double syncSpeed;
  final int totalCount;
  final int syncedCount;
  final double minutesRemaining;
  final double totalMinutes;
  final String lastActiveStage;

  final VoidCallback onStartPipeline;
  final VoidCallback onShowCancelModal;
  final VoidCallback onResumePipeline;
  final VoidCallback onRetryFromError;

  const SyncProcessCard({
    super.key,
    required this.spState,
    required this.isForcePipeline,
    required this.syncSpeed,
    required this.totalCount,
    required this.syncedCount,
    required this.minutesRemaining,
    required this.totalMinutes,
    required this.lastActiveStage,
    required this.onStartPipeline,
    required this.onShowCancelModal,
    required this.onResumePipeline,
    required this.onRetryFromError,
  });

  @override
  Widget build(BuildContext context) {
    if (spState == SyncProcessState.idle) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _buildCardContent(),
    );
  }

  Widget _buildCardContent() {
    final String mainText;
    final String subText;
    final Color iconBg;
    final Widget iconChild;
    VoidCallback? onIconTap;
    bool showProgress = false;
    double? progressValue;
    Color progressColor = Colors.deepPurpleAccent;

    switch (spState) {
      case SyncProcessState.idle:
        mainText = 'Sync and Process Now';
        subText = 'Syncs files from device and prepares conversations';
        iconBg = Colors.deepPurpleAccent;
        iconChild = const FaIcon(
          FontAwesomeIcons.rotate,
          color: Colors.white,
          size: 16,
        );
        onIconTap = onStartPipeline;

      case SyncProcessState.syncing:
        mainText = isForcePipeline ? 'Force Sync...' : 'Syncing segments';
        final speedStr = syncSpeed > 0
            ? '  ·  ${syncSpeed.toStringAsFixed(1)} KB/s'
            : '';
        subText = totalCount > 0
            ? '$syncedCount of $totalCount segments synced$speedStr'
            : (isForcePipeline ? 'Rotating segment…' : 'Scanning device…');
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = onShowCancelModal;
        showProgress = true;
        progressValue = totalCount > 0
            ? (syncedCount / totalCount).clamp(0.0, 1.0)
            : null;

      case SyncProcessState.processing:
        mainText = 'Preparing conversations';
        final minStr = minutesRemaining >= 1
            ? '${minutesRemaining.ceil()} min of audio remaining'
            : '< 1 min of audio remaining';
        subText = minStr;
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = onShowCancelModal;
        showProgress = true;
        progressValue = totalMinutes > 0
            ? (1.0 - minutesRemaining / totalMinutes).clamp(0.0, 1.0)
            : null;

      case SyncProcessState.stopping:
        mainText = 'Stopping…';
        subText = 'Finishing current step';
        iconBg = Colors.grey.shade700;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = null;
        showProgress = true;
        progressValue = null;
        progressColor = Colors.grey.shade600;

      case SyncProcessState.resume:
        mainText = 'Resume Sync and Processing';
        subText = 'Last run didn\'t finish';
        iconBg = Colors.amber.shade700;
        iconChild = const FaIcon(
          FontAwesomeIcons.rotate,
          color: Colors.white,
          size: 16,
        );
        onIconTap = onResumePipeline;

      case SyncProcessState.error:
        mainText = lastActiveStage == 'processing'
            ? 'Processing failed'
            : 'Sync failed';
        subText = 'Tap to retry';
        iconBg = Colors.redAccent;
        iconChild = const FaIcon(
          FontAwesomeIcons.circleExclamation,
          color: Colors.white,
          size: 16,
        );
        onIconTap = onRetryFromError;

      case SyncProcessState.successUi:
        mainText = 'Conversations ready';
        subText = 'Sync and processing complete';
        iconBg = Colors.green.shade600;
        iconChild = const FaIcon(
          FontAwesomeIcons.circleCheck,
          color: Colors.white,
          size: 16,
        );
        onIconTap = null;
        showProgress = true;
        progressValue = 1.0;
        progressColor = Colors.green;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mainText,
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subText,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onIconTap,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconBg,
                  shape: BoxShape.circle,
                ),
                child: Center(child: iconChild),
              ),
            ),
          ],
        ),
        if (showProgress) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progressValue,
            backgroundColor: Colors.grey.shade800,
            color: progressColor,
          ),
        ],
      ],
    );
  }
}
