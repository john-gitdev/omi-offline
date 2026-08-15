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

/// Shown when the most recent VAD-wanted processing run fell back to firmware
/// AAD because Silero failed to load. In AAD mode every frame counts as speech,
/// so silence-splitting happens device-side only — a silent fallback can spray
/// hundreds of tiny junk recordings. The flag auto-clears once Silero loads
/// again, so the banner disappears on the next healthy run.
class VadFallbackBanner extends StatelessWidget {
  final bool active;
  const VadFallbackBanner({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.orange.shade900,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: const Row(
        children: [
          FaIcon(FontAwesomeIcons.triangleExclamation, color: Colors.white, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Voice detection unavailable — using device fallback. Recordings may be split oddly until '
              'the next sync recovers it.',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
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
        spState == SyncProcessState.stopping) {
      return const SizedBox.shrink();
    }

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
      // Bottom margin 16 = the day-gap down to the recordings list (a fixed
      // margin in the page Column, outside the scroll view, so it persists while
      // scrolling). Top 0: when the SyncProcessCard sits above us its own 16px
      // bottom margin already spaces the two cards a day-gap apart (the ~10s
      // successUi+draft window); when we're alone the header's bottom padding
      // spaces us.
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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

/// Shown when the app adopted a recording mode from the Omi that differs from the
/// one the user chose — a replacement device, or one whose settings were reset.
///
/// A banner rather than a dialog on purpose: a replacement Omi connects during
/// pairing, and a modal would land on top of that. Nothing is broken while this
/// is up — the app and the Omi agree, they just agree on something the user did
/// not pick — so it stays dismissible and out of the way.
class RecordingModeMismatchBanner extends StatelessWidget {
  final bool active;

  /// The mode now in force, i.e. the one adopted from the Omi.
  final bool manual;
  final VoidCallback onReview;
  final VoidCallback onDismiss;

  const RecordingModeMismatchBanner({
    super.key,
    required this.active,
    required this.manual,
    required this.onReview,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.indigo.shade900,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        children: [
          const FaIcon(FontAwesomeIcons.circleInfo, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'This Omi is set to ${manual ? "Manual" : "Automatic"} recording, which is not what you chose. '
              'Your settings now match the device.',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: onReview,
            child: const Text('Review', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, color: Colors.white70, size: 18),
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}
