import 'dart:io';

/// Lightweight pointer to an Opus frame stored in a .bin chunk file.
/// No Opus bytes are held in memory — they are read from disk at encode time.
class FrameRef {
  final File chunkFile;
  final int byteOffset; // position of the 4-byte length prefix in the file
  final int frameLength; // Opus payload length (not including the 4-byte prefix)

  const FrameRef({
    required this.chunkFile,
    required this.byteOffset,
    required this.frameLength,
  });
}
