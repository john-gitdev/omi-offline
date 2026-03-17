import 'dart:typed_data';

/// Finds a safe frame-boundary split index for very long audio windows
/// (> 2 hours) so they can be sent to Deepgram in two segments.
///
/// Each Opus frame is exactly 20 ms, so duration is determined purely by
/// frame count — no decoding is required.
///
/// Deepgram's pre-recorded endpoint supports up to 2 hours per request.
class SmartBoundaryFinder {
  static const int _frameMs = 20;
  static const int _maxDurationMs = 2 * 60 * 60 * 1000; // 2 hours

  /// Returns the index of the frame that starts the second segment.
  ///
  /// The split is placed at exactly [_maxDurationMs] worth of frames.
  /// If [frames] fits within the limit, returns [frames.length] (no split needed).
  static int findSplitFrameIndex(List<Uint8List> frames) {
    final maxFrames = _maxDurationMs ~/ _frameMs; // 360 000 frames = 2 hours
    if (frames.length <= maxFrames) return frames.length;
    return maxFrames;
  }

  /// Returns true when [frames] exceeds the 2-hour Deepgram limit.
  static bool needsSplit(List<Uint8List> frames) {
    return frames.length > (_maxDurationMs ~/ _frameMs);
  }

  /// Splits [frames] into segments each fitting within the 2-hour limit.
  /// Returns a list of sub-lists; for typical sync windows this returns a
  /// single-element list.
  static List<List<Uint8List>> split(List<Uint8List> frames) {
    final maxFrames = _maxDurationMs ~/ _frameMs;
    final result = <List<Uint8List>>[];
    int offset = 0;
    while (offset < frames.length) {
      final end = (offset + maxFrames).clamp(0, frames.length);
      result.add(frames.sublist(offset, end));
      offset = end;
    }
    return result;
  }

  /// Duration of [frames] in milliseconds.
  static int durationMs(List<Uint8List> frames) => frames.length * _frameMs;
}
