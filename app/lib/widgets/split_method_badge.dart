import 'package:flutter/material.dart';
import 'package:omi/services/recordings_manager.dart';

/// A small pill badge indicating how a recording was split.
///
/// - [SplitMethod.deepgram] → purple "Deepgram" pill
/// - [SplitMethod.vad]      → grey "VAD" pill
class SplitMethodBadge extends StatelessWidget {
  final SplitMethod method;

  const SplitMethodBadge({super.key, required this.method});

  @override
  Widget build(BuildContext context) {
    final isDeepgram = method == SplitMethod.deepgram;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDeepgram
            ? Colors.deepPurpleAccent.withValues(alpha: 0.18)
            : Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isDeepgram ? 'Deepgram' : 'VAD',
        style: TextStyle(
          color: isDeepgram ? Colors.deepPurpleAccent : Colors.grey.shade500,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
