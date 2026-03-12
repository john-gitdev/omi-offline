import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:collection/collection.dart';

// UUIDs
const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const String batteryLevelCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

const String audioServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
const String audioCharacteristicFormatUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';

const String omiServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
const String audioDataStreamCharacteristicUuid = '19b10001-e8f2-537e-4f6c-d104768a1214';
const String audioCodecCharacteristicUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';

const String buttonServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
const String buttonTriggerCharacteristicUuid = '23ba7925-0000-1000-7450-346eac492e92';

const String settingsServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
const String settingsDimRatioCharacteristicUuid = '19b10011-e8f2-537e-4f6c-d104768a1214';
const String settingsMicGainCharacteristicUuid = '19b10012-e8f2-537e-4f6c-d104768a1214';

const String featuresServiceUuid = '19b10020-e8f2-537e-4f6c-d104768a1214';
const String featuresCharacteristicUuid = '19b10021-e8f2-537e-4f6c-d104768a1214';

const String timeSyncServiceUuid = '19b10030-e8f2-537e-4f6c-d104768a1214';
const String timeSyncWriteCharacteristicUuid = '19b10031-e8f2-537e-4f6c-d104768a1214';

const String speakerDataStreamServiceUuid = '19b10040-e8f2-537e-4f6c-d104768a1214';
const String speakerDataStreamCharacteristicUuid = '19b10041-e8f2-537e-4f6c-d104768a1214';

const String storageDataStreamServiceUuid = '30295780-4301-eabd-2904-2849adfeae43';
const String storageReadControlCharacteristicUuid = '30295782-4301-eabd-2904-2849adfeae43';
const String storageDataStreamCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';
const String storageFullCharacteristicUuid = '30295784-4301-eabd-2904-2849adfeae43';
const String storageDataCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';

BluetoothCharacteristic? getCharacteristicByUuid(BluetoothService service, String uuid) {
  return service.characteristics.firstWhereOrNull(
    (characteristic) => characteristic.uuid.str128.toLowerCase() == uuid.toLowerCase(),
  );
}
