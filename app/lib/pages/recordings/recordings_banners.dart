import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:omi/backend/preferences.dart';
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

/// Shown while the connected device's mic is muted (double-tap-hold or app
/// toggle). Mirrors the OS notification's "Muted since H:MM" line.
class MutedBanner extends StatelessWidget {
  final bool isMuted;
  final DateTime? since;
  const MutedBanner({super.key, required this.isMuted, this.since});

  @override
  Widget build(BuildContext context) {
    if (!isMuted) return const SizedBox.shrink();
    final s = since;
    final text = s != null
        ? 'Omi is Muted since ${DateFormat(SharedPreferencesUtil().use24HourTime ? 'HH:mm' : 'h:mm a').format(s.toLocal())}'
        : 'Omi is Muted';
    return Container(
      width: double.infinity,
      color: Colors.red.shade900,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        children: [
          const FaIcon(FontAwesomeIcons.microphoneSlash, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
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
  final double toProcessMinutes;
  final double draftMinutes;
  final int unprocessedBinCount;
  final DateTime? draftEndTime;
  final VoidCallback? onTap;
  const AccumulatingBanner({
    super.key,
    required this.spState,
    required this.toProcessMinutes,
    this.draftMinutes = 0.0,
    this.unprocessedBinCount = 0,
    this.draftEndTime,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (spState == SyncProcessState.syncing ||
        spState == SyncProcessState.processing ||
        spState == SyncProcessState.stopping) return const SizedBox.shrink();

    const double minShown = 1.0 / 60.0; // ~1 second
    final bool hasToProcess = toProcessMinutes >= minShown;
    final bool hasDraft = draftMinutes >= minShown;
    if (!hasToProcess && !hasDraft) return const SizedBox.shrink();

    // Show raw audio still waiting to be decoded; only when there's none left
    // do we fall back to the open draft's accumulated duration.
    final String title;
    final String label;
    if (hasToProcess) {
      final mins = toProcessMinutes.ceil();
      title = 'Audio to process';
      final binsLabel =
          unprocessedBinCount > 0 ? ' · $unprocessedBinCount ${unprocessedBinCount == 1 ? 'bin' : 'bins'}' : '';
      label = '~$mins ${mins == 1 ? 'minute' : 'minutes'} to process$binsLabel';
    } else {
      title = 'Conversation in progress';
      final end = draftEndTime;
      label = end != null
          ? 'Captured through ~${DateFormat(SharedPreferencesUtil().use24HourTime ? 'HH:mm' : 'h:mm a').format(end)}'
          : 'Tap to finalize early';
    }

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
                  title,
                  style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: 'Process accumulated audio',
            child: Semantics(
              button: true,
              label: 'Process accumulated audio',
              child: Material(
                color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
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
