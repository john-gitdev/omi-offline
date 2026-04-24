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

  StorageFileStats({
    required this.totalUsedBytes,
    required this.fileCount,
    required this.freeBytes,
  });
}
