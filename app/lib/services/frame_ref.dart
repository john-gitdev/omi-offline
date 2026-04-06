import 'dart:io';

/// Lightweight pointer to an Opus frame stored in a segment file.
/// No Opus bytes are held in memory — they are read from disk at encode time.
class FrameRef {
  final File? segmentFile;
  final int byteOffset; // position of the 4-byte length prefix in the file
  final int frameLength; // Opus payload length (not including the 4-byte prefix)
  final bool isSilent;

  const FrameRef({
    this.segmentFile,
    required this.byteOffset,
    required this.frameLength,
    this.isSilent = false,
  });

  factory FrameRef.silent() => const FrameRef(
        segmentFile: null,
        byteOffset: -1,
        frameLength: 0,
        isSilent: true,
      );
}
