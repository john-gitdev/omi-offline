import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/pages/recordings/recordings_types.dart';

class SyncProcessCard extends StatelessWidget {
  final SyncCardData data;

  /// Called when the action button is tapped in idle/resume/error states.
  final VoidCallback? onActionTap;

  /// Called when the cancel button is tapped in syncing/processing states.
  final VoidCallback? onCancelTap;

  /// Called when the success banner is dismissed.
  final VoidCallback? onDismissTap;

  const SyncProcessCard({
    super.key,
    required this.data,
    this.onActionTap,
    this.onCancelTap,
    this.onDismissTap,
  });

  @override
  Widget build(BuildContext context) {
    // Idle: no card. The ambient "Last synced …" line now lives directly under
    // the Conversations header (see LastSyncedLabel); live progress replaces
    // this slot the moment a sync/process run starts.
    if (data.state == SyncProcessState.idle) {
      return const SizedBox.shrink();
    }

    return Container(
      // Bottom margin 0: the 16px gap down to the next block (the recordings
      // list, or the AccumulatingBanner when it co-occurs) is owned below —
      // either the ListView's top padding or AccumulatingBanner's top margin —
      // so the status-card→recording-card gap matches the inter-day gap (16).
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    final String mainText;
    final String subText;
    final Color iconBg;
    final Widget iconChild;
    VoidCallback? onIconTap;
    String tooltipText = '';
    bool showProgress = false;
    double? progressValue;
    Color progressColor = Colors.deepPurpleAccent;

    switch (data.state) {
      case SyncProcessState.idle:
        mainText = 'Sync and Process Now';
        subText = 'Syncs files from device and prepares conversations';
        iconBg = Colors.deepPurpleAccent;
        iconChild = const FaIcon(
          FontAwesomeIcons.rotate,
          color: Colors.white,
          size: 16,
        );
        onIconTap = onActionTap;
        tooltipText = 'Start sync';

      case SyncProcessState.syncing:
        mainText = data.isForcePipeline ? 'Force Sync...' : 'Syncing segments';
        final speedStr = data.syncSpeed > 0 ? '  ·  ${data.syncSpeed.toStringAsFixed(1)} KB/s' : '';
        subText = data.totalCount > 0
            ? '${data.syncedCount} of ${data.totalCount} segments synced$speedStr'
            : (data.isForcePipeline ? 'Rotating segment…' : 'Scanning device…');
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = onCancelTap;
        tooltipText = 'Cancel sync';
        showProgress = true;
        progressValue = data.totalCount > 0 ? (data.syncedCount / data.totalCount).clamp(0.0, 1.0) : null;

      case SyncProcessState.processing:
        mainText = 'Preparing conversations';
        // Mirror the notification logic: show "Calculating…" until the total is
        // known (totalMinutes == 0 during the async byte-count) so the card never
        // flashes "< 1 min" for a large backlog.
        subText = data.isTranscoding
            ? 'Converting to ${data.audioSaveFormat}'
            : (data.totalMinutes == 0 || data.minutesRemaining < 0
                ? 'Calculating…'
                : (data.minutesRemaining >= 1
                    ? '~${data.minutesRemaining.ceil()} min of audio to process'
                    : '< 1 min of audio to process'));
        iconBg = Colors.deepPurpleAccent;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = onCancelTap;
        tooltipText = 'Cancel processing';
        showProgress = true;
        progressValue = data.processingProgress;

      case SyncProcessState.stopping:
        mainText = 'Stopping…';
        // lastActiveStage is controller-owned and drives notify, so this stays
        // reactive — it reflects whichever stage was running when cancel landed.
        subText = data.lastActiveStage == 'syncing' ? 'Transferring current file…' : 'Finishing current step';
        iconBg = Colors.grey.shade700;
        iconChild = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        );
        onIconTap = null;
        tooltipText = 'Stopping';
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
        onIconTap = onActionTap;
        tooltipText = 'Resume';

      case SyncProcessState.error:
        mainText = data.lastActiveStage == 'processing' ? 'Processing failed' : 'Sync failed';
        subText = 'Tap to retry';
        iconBg = Colors.redAccent;
        iconChild = const FaIcon(
          FontAwesomeIcons.circleExclamation,
          color: Colors.white,
          size: 16,
        );
        onIconTap = onActionTap;
        tooltipText = 'Retry';

      case SyncProcessState.successUi:
        mainText = 'Conversations ready';
        subText = 'Sync and processing complete';
        iconBg = Colors.green.shade600;
        iconChild = const FaIcon(
          FontAwesomeIcons.circleCheck,
          color: Colors.white,
          size: 16,
        );
        onIconTap = onDismissTap;
        tooltipText = 'Dismiss';
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
            Tooltip(
              message: tooltipText,
              child: Semantics(
                button: true,
                label: tooltipText,
                child: Material(
                  color: iconBg,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onIconTap,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Center(child: iconChild),
                    ),
                  ),
                ),
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

/// Ambient "Last synced …" line shown directly under the Conversations header.
/// Owns a minute-ticker so the relative label ("5m ago") stays fresh even when
/// nothing else rebuilds the page. Renders nothing until the first sync stamps
/// [lastSyncStatusMs].
class LastSyncedLabel extends StatefulWidget {
  final int lastSyncStatusMs;

  const LastSyncedLabel({super.key, required this.lastSyncStatusMs});

  @override
  State<LastSyncedLabel> createState() => _LastSyncedLabelState();
}

class _LastSyncedLabelState extends State<LastSyncedLabel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(LastSyncedLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Start/stop as the pref crosses 0 (e.g. a background sync landing the
    // first-ever timestamp while the page sits idle).
    if ((widget.lastSyncStatusMs > 0) != (oldWidget.lastSyncStatusMs > 0)) {
      _syncTicker();
    }
  }

  /// Only run the minute-ticker while there's a timestamp to keep fresh. Before
  /// the first-ever sync the widget renders nothing, so a timer would just wake
  /// the app every minute for no visible change.
  void _syncTicker() {
    if (widget.lastSyncStatusMs > 0) {
      _ticker ??= Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _relativeLabel(int ms) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.isNegative || diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lastSyncStatusMs <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 13, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(
            'Last synced ${_relativeLabel(widget.lastSyncStatusMs)}',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
