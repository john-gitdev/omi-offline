import 'package:omi/backend/schema/bt_device/bt_device.dart';

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
  final BleAudioCodec codec;
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
  int? seconds;
  int? sampleRate;
  String? deviceModel;
  int estimatedSegments;

  Wal({
    required this.codec,
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
    this.seconds,
    this.sampleRate,
    this.deviceModel,
    this.estimatedSegments = 0,
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

  String? getFilePath() {
    return filePath;
  }

  int getFrameSize() {
    return codec.getFrameSize();
  }

  static BleAudioCodec mapNameToCodec(String name) {
    switch (name.toLowerCase()) {
      case 'pcm8':
        return BleAudioCodec.pcm8;
      case 'pcm16':
        return BleAudioCodec.pcm16;
      case 'mulaw8':
        return BleAudioCodec.mulaw8;
      case 'mulaw16':
        return BleAudioCodec.mulaw16;
      case 'opus':
        return BleAudioCodec.opus;
      case 'opusfs320':
        return BleAudioCodec.opusFS320;
      default:
        return BleAudioCodec.unknown;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'codec': codec.name,
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
      'seconds': seconds,
      'sampleRate': sampleRate,
      'deviceModel': deviceModel,
      'estimatedSegments': estimatedSegments,
    };
  }

  static List<Wal> fromJsonList(List<dynamic> jsonList) {
    return jsonList.map((j) => Wal.fromJson(j)).toList();
  }

  factory Wal.fromJson(Map<String, dynamic> json) {
    return Wal(
      codec: mapNameToCodec(json['codec'] ?? 'pcm8'),
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
      seconds: json['seconds'],
      sampleRate: json['sampleRate'],
      deviceModel: json['deviceModel'],
      estimatedSegments: json['estimatedSegments'] ?? 0,
    );
  }

  Wal copyWith({
    BleAudioCodec? codec,
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
    int? seconds,
    int? sampleRate,
    String? deviceModel,
    int? estimatedSegments,
  }) {
    return Wal(
      codec: codec ?? this.codec,
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
      seconds: seconds ?? this.seconds,
      sampleRate: sampleRate ?? this.sampleRate,
      deviceModel: deviceModel ?? this.deviceModel,
      estimatedSegments: estimatedSegments ?? this.estimatedSegments,
    );
  }
}
