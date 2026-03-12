import 'package:omi/backend/schema/bt_device/bt_device.dart';

const chunkSizeInSeconds = 60;
const flushIntervalInSeconds = 90;
const sdcardChunkSizeSecs = 60;
const newFrameSize = 80;

enum WalStorage {
  local,
  sdcard,
  flashPage,
}

enum WalStatus {
  miss,
  syncing,
  synced,
  corrupted,
}

enum SyncMethod {
  ble,
  wifi,
}

class Wal {
  final BleAudioCodec codec;
  final int channel;
  final String device;
  final int fileNum;
  final int storageOffset;
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
  WalStorage? originalStorage;

  Wal({
    required this.codec,
    required this.channel,
    required this.device,
    required this.fileNum,
    required this.storageOffset,
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
    this.originalStorage,
  });

  String get id => '$device-$fileNum-$storageOffset';

  String getFileNameByTimeStarts(int timerStart) {
    return 'chunk_$timerStart.bin';
  }

  String getFileName() {
    return getFileNameByTimeStarts(timerStart);
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
      'storageOffset': storageOffset,
      'storageTotalBytes': storageTotalBytes,
      'timerStart': timerStart,
      'storage': storage.name,
      'status': status.name,
      'filePath': filePath,
      'seconds': seconds,
      'sampleRate': sampleRate,
      'deviceModel': deviceModel,
      'originalStorage': originalStorage?.name,
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
      storageOffset: json['storageOffset'] ?? 0,
      storageTotalBytes: json['storageTotalBytes'] ?? 0,
      timerStart: json['timerStart'] ?? 0,
      storage: WalStorage.values.firstWhere((e) => e.name == json['storage'], orElse: () => WalStorage.local),
      status: WalStatus.values.firstWhere((e) => e.name == json['status'], orElse: () => WalStatus.miss),
      filePath: json['filePath'],
      seconds: json['seconds'],
      sampleRate: json['sampleRate'],
      deviceModel: json['deviceModel'],
      originalStorage: json['originalStorage'] != null 
          ? WalStorage.values.firstWhere((e) => e.name == json['originalStorage'], orElse: () => WalStorage.local)
          : null,
    );
  }

  Wal copyWith({
    BleAudioCodec? codec,
    int? channel,
    String? device,
    int? fileNum,
    int? storageOffset,
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
    WalStorage? originalStorage,
  }) {
    return Wal(
      codec: codec ?? this.codec,
      channel: channel ?? this.channel,
      device: device ?? this.device,
      fileNum: fileNum ?? this.fileNum,
      storageOffset: storageOffset ?? this.storageOffset,
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
      originalStorage: originalStorage ?? this.originalStorage,
    );
  }
}
