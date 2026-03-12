import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/models.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';

class LimitlessDeviceConnection extends DeviceConnection {
  final _audioController = StreamController<List<int>>.broadcast();
  final _buttonController = StreamController<List<int>>.broadcast();

  LimitlessDeviceConnection(super.device, super.transport);

  @override
  Future<int> performRetrieveBatteryLevel() async => -1;

  @override
  Future<List<int>> performGetButtonState() async => [];

  @override
  Future<StreamSubscription<List<int>>?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    return _buttonController.stream.listen(onButtonReceived) as StreamSubscription<List<int>>;
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async => BleAudioCodec.opusFS320;

  @override
  Future<List<int>> performGetStorageList() async => [];

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset) async => false;

  @override
  Future<bool> performPlayToSpeakerHaptic(int level) async => false;

  @override
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection) async {
    return device;
  }
}
