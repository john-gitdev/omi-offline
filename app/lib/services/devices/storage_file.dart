class StorageFile {
  final int index;
  final int timestamp;
  final int size;
  final int? sessionId;

  StorageFile({
    required this.index,
    required this.timestamp,
    required this.size,
    this.sessionId,
  });

  @override
  String toString() {
    return 'StorageFile(index: $index, timestamp: $timestamp, size: $size, sessionId: $sessionId)';
  }
}

class StorageFileStats {
  final int totalUsedBytes;
  final int fileCount;
  final int freeBytes;

  /// Active storage backend, from the storage status read (low byte of
  /// status_flags): 0 = LittleFS, 1 = ring. null when the firmware predates the
  /// field (payload shorter than 16 bytes).
  final int? storageBackend;

  StorageFileStats({
    required this.totalUsedBytes,
    required this.fileCount,
    required this.freeBytes,
    this.storageBackend,
  });
}
