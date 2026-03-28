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
  WalStorage storage;

  WalStatus status;
  bool isSyncing;
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
    this.status = WalStatus.miss,
    this.isSyncing = false,
    this.syncMethod = SyncMethod.ble,
    this.filePath,
    this.data,
    this.seconds,
    this.sampleRate,
    this.deviceModel,
    this.estimatedSegments = 0,
  });

  // id is stable: storageOffset is always 0 at creation and must not be part of the key
  // because storageOffset is mutated during sync progress callbacks, which would silently
  // break deleteWal / removeWhere lookups that rely on id equality.
  String get id => '$device-$fileNum';

  String getSegmentFileNameByTimestamp(int timerStart) {
    return 'segment_$timerStart.bin';
  }

  String getFileName() {
    return getSegmentFileNameByTimestamp(timerStart);
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
      'storage': storage.name,
      'status': status.name,
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
      storage: WalStorage.values.firstWhere((e) => e.name == json['storage'], orElse: () => WalStorage.local),
      status: WalStatus.values.firstWhere((e) => e.name == json['status'], orElse: () => WalStatus.miss),
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
    WalStorage? storage,
    WalStatus? status,
    bool? isSyncing,
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
      storage: storage ?? this.storage,
      status: status ?? this.status,
      isSyncing: isSyncing ?? this.isSyncing,
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
