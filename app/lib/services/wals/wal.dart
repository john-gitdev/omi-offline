const segmentDurationSeconds = 60;
const flushIntervalInSeconds = 90;
const sdcardSegmentDurationSecs = 60;
const newFrameSize = 80;

enum WalStorage {
  local,
  sdcard,
}

enum WalStatus {
  miss,
  syncing,
  synced,
  corrupted,
}

enum SyncMethod {
  ble,
}

class Wal {
  final int channel;
  final String device;
  final int fileNum;
  int walOffset;
  final int storageTotalBytes;
  final int timerStart;
  final int? sessionId;
  WalStorage storage;

  WalStatus status;
  bool isSyncing;
  // Number of consecutive sync attempts that ended with fewer bytes received than
  // the device advertised in CMD_LIST_FILES (an incomplete/empty read). Used by the
  // fast-path completeness guard to retry a short read instead of deleting the
  // device-side file, and to eventually give up on a genuinely unreadable ("poison")
  // file so it doesn't block the head-of-line forever. Reset to 0 on a full transfer.
  int syncFailCount;
  DateTime? syncStartedAt;
  int? syncEtaSeconds;
  double? syncSpeedKBps;
  SyncMethod syncMethod;

  // Placeholder fields for compatibility with existing UI/Utils
  String? filePath;
  List<int>? data;
  int? sampleRate;
  String? deviceModel;

  Wal({
    required this.channel,
    required this.device,
    required this.fileNum,
    required this.walOffset,
    required this.storageTotalBytes,
    required this.timerStart,
    required this.storage,
    this.sessionId,
    this.status = WalStatus.miss,
    this.isSyncing = false,
    this.syncFailCount = 0,
    this.syncMethod = SyncMethod.ble,
    this.filePath,
    this.data,
    this.sampleRate,
    this.deviceModel,
  });

  // id is stable: keyed on timerStart (the file's Unix timestamp from firmware) so it
  // survives array-index shifts when earlier files are deleted between reconnects.
  // fileNum shifts after deletions but timerStart does not — matching on fileNum caused
  // partial-resume bookmarks to be applied to the wrong file after a disconnect mid-sync.
  // Falls back to fileNum for the rare case where timerStart is 0 (legacy persisted data).
  String get id => timerStart > 0 ? '$device-$timerStart' : '$device-$fileNum';

  String getSegmentFileNameByTimestamp(int timerStart, {int? sessionId}) {
    if (sessionId != null) {
      return '${timerStart}_$sessionId.bin';
    }
    return '${timerStart}_0.bin';
  }

  String getFileName() {
    return getSegmentFileNameByTimestamp(timerStart, sessionId: sessionId);
  }

  /// True while the device advertised more bytes for this file than have landed
  /// in the local bin — i.e. the transfer is mid-flight or ended short and the
  /// completeness guard left it `miss` for a resumed read on the next sync.
  ///
  /// The bin on disk is a PREFIX of the real recording, so it must not be
  /// decoded or pruned: the processing pass deletes every bin it consumes, and
  /// a deleted bin makes the resume append the tail to an empty file. Mirrors
  /// the guard's condition in SDCardWalSyncImpl._syncAllLocked.
  bool get isIncompleteTransfer => storageTotalBytes > 0 && walOffset < storageTotalBytes;

  /// Path of this WAL's bin relative to `raw_segments/`, matching the folder
  /// rule the download path uses (pre-time-sync files land under
  /// `session_<sessionId>/`). Same shape as the keys in
  /// [RecordingsManager.discardedRelBinPaths].
  String get relativeBinPath {
    final folder = timerStart < 946684800 ? 'session_$sessionId' : '$timerStart';
    return '$folder/${getFileName()}';
  }

  String? getFilePath() {
    return filePath;
  }

  Map<String, dynamic> toJson() {
    return {
      'channel': channel,
      'device': device,
      'fileNum': fileNum,
      'storageOffset': walOffset,
      'storageTotalBytes': storageTotalBytes,
      'timerStart': timerStart,
      'sessionId': sessionId,
      'storage': storage.name,
      'status': status.name,
      'syncFailCount': syncFailCount,
      'filePath': filePath,
      'sampleRate': sampleRate,
      'deviceModel': deviceModel,
    };
  }

  static List<Wal> fromJsonList(List<dynamic> jsonList) {
    return jsonList.map((j) => Wal.fromJson(j)).toList();
  }

  factory Wal.fromJson(Map<String, dynamic> json) {
    return Wal(
      channel: json['channel'] ?? 1,
      device: json['device'] ?? '',
      fileNum: json['fileNum'] ?? 0,
      walOffset: json['storageOffset'] ?? 0,
      storageTotalBytes: json['storageTotalBytes'] ?? 0,
      timerStart: json['timerStart'] ?? 0,
      sessionId: json['sessionId'],
      storage: WalStorage.values.firstWhere((e) => e.name == json['storage'], orElse: () => WalStorage.local),
      status: WalStatus.values.firstWhere((e) => e.name == json['status'], orElse: () => WalStatus.miss),
      syncFailCount: json['syncFailCount'] ?? 0,
      filePath: json['filePath'],
      sampleRate: json['sampleRate'],
      deviceModel: json['deviceModel'],
    );
  }

  Wal copyWith({
    int? channel,
    String? device,
    int? fileNum,
    int? walOffset,
    int? storageTotalBytes,
    int? timerStart,
    int? sessionId,
    WalStorage? storage,
    WalStatus? status,
    bool? isSyncing,
    int? syncFailCount,
    SyncMethod? syncMethod,
    String? filePath,
    List<int>? data,
    int? sampleRate,
    String? deviceModel,
  }) {
    return Wal(
      channel: channel ?? this.channel,
      device: device ?? this.device,
      fileNum: fileNum ?? this.fileNum,
      walOffset: walOffset ?? this.walOffset,
      storageTotalBytes: storageTotalBytes ?? this.storageTotalBytes,
      timerStart: timerStart ?? this.timerStart,
      sessionId: sessionId ?? this.sessionId,
      storage: storage ?? this.storage,
      status: status ?? this.status,
      isSyncing: isSyncing ?? this.isSyncing,
      syncFailCount: syncFailCount ?? this.syncFailCount,
      syncMethod: syncMethod ?? this.syncMethod,
      filePath: filePath ?? this.filePath,
      data: data ?? this.data,
      sampleRate: sampleRate ?? this.sampleRate,
      deviceModel: deviceModel ?? this.deviceModel,
    );
  }
}
