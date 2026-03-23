class StorageFile {
  /// 0-based position in the firmware's sorted file list (oldest-first).
  /// Used as the file index in CMD_READ_FILE / CMD_DELETE_FILE.
  final int index;

  /// UTC epoch seconds parsed from the hex filename (e.g. "67890abc.txt" → 0x67890abc).
  /// 0 for TMP files that have not yet been renamed after time sync.
  final int timestamp;

  /// File size in bytes as reported by the firmware.
  final int size;

  const StorageFile({required this.index, required this.timestamp, required this.size});

  @override
  String toString() => 'StorageFile(index=$index, ts=$timestamp, size=$size)';
}
