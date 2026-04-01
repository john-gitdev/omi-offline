class StorageFile {
  final int index;
  final int timestamp;
  final int size;

  StorageFile({
    required this.index,
    required this.timestamp,
    required this.size,
  });

  @override
  String toString() {
    return 'StorageFile(index: $index, timestamp: $timestamp, size: $size)';
  }
}

class StorageFileStats {
  final int totalUsedBytes;
  final int fileCount;

  StorageFileStats({
    required this.totalUsedBytes,
    required this.fileCount,
  });
}
