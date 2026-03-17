import 'package:omi/services/audio/deepgram_transcription_service.dart';

/// Identifies conversation boundaries within a list of [WordTimestamp]s by
/// finding inter-word gaps that exceed [gapThreshold].
///
/// Returns a list of split points as [Duration]s from the beginning of the
/// audio window.  Each split point is the mid-point of the detected gap,
/// which gives the slicer a clean boundary to cut.
class TranscriptionSplitter {
  /// Finds conversation split points in [words].
  ///
  /// [gapThreshold] — minimum silence between words to count as a boundary.
  ///
  /// Returns an empty list when [words] is empty or no gaps are found (i.e.
  /// the entire audio is one conversation).
  static List<Duration> findSplitPoints(
    List<WordTimestamp> words,
    Duration gapThreshold,
  ) {
    if (words.length < 2) return [];

    final splitPoints = <Duration>[];
    final thresholdSecs = gapThreshold.inMilliseconds / 1000.0;

    for (int i = 1; i < words.length; i++) {
      final gap = words[i].start - words[i - 1].end;
      if (gap >= thresholdSecs) {
        // Cut at the midpoint of the silence so we don't clip either word
        final midSecs = words[i - 1].end + gap / 2;
        splitPoints.add(Duration(milliseconds: (midSecs * 1000).round()));
      }
    }

    return splitPoints;
  }

  /// Given [splitPoints] and a list of [words], returns the words that belong
  /// to conversation [index] (0-based).
  ///
  /// Useful for building per-conversation transcripts after splitting.
  static List<WordTimestamp> wordsForSegment(
    List<WordTimestamp> words,
    List<Duration> splitPoints,
    int index,
  ) {
    final startSecs = index == 0 ? 0.0 : splitPoints[index - 1].inMilliseconds / 1000.0;
    final endSecs = index < splitPoints.length ? splitPoints[index].inMilliseconds / 1000.0 : double.infinity;

    return words.where((w) => w.start >= startSecs && w.end <= endSecs).toList();
  }

  /// Builds a full-text string from [words] by joining word strings with spaces.
  static String wordsToText(List<WordTimestamp> words) {
    return words.map((w) => w.word).join(' ').trim();
  }
}
