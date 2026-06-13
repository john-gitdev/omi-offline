import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:flutter/widgets.dart';

import 'package:flutter_archive/flutter_archive.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/logger.dart';

// --- Skeleton classes for missing dependencies ---

class Manifest {
  final List<ManifestFile> files;
  Manifest({required this.files});
  factory Manifest.fromJson(Map<String, dynamic> json) {
    return Manifest(
      files: (json['files'] as List).map((e) => ManifestFile.fromJson(e)).toList(),
    );
  }
}

class ManifestFile {
  final String file;
  final int image;
  ManifestFile({required this.file, required this.image});
  factory ManifestFile.fromJson(Map<String, dynamic> json) {
    return ManifestFile(
      file: json['file'],
      image: int.tryParse(json['image_index']?.toString() ?? '0') ?? 0,
    );
  }
}

// Mocked API calls since they are missing in omi-offline
Future<Map<String, dynamic>> getLatestFirmwareVersion({
  required String deviceModelNumber,
  required String firmwareRevision,
  required String hardwareRevision,
  required String manufacturerName,
}) async {
  // TODO: Implement actual API call to fetch latest firmware
  return {};
}

Future<Map<String, dynamic>> getStableFirmwareVersion({required String deviceModelNumber}) async {
  // TODO: Implement actual API call to fetch stable firmware
  return {};
}

// --- End of skeletons ---

mixin FirmwareMixin<T extends StatefulWidget> on State<T> {
  Map latestFirmwareDetails = {};
  bool isDownloading = false;
  bool isDownloaded = false;
  int downloadProgress = 0;
  bool isInstalling = false;
  bool isInstalled = false;
  int installProgress = 0;
  bool isLegacySecureDFU = true;
  List<String> otaUpdateSteps = [];
  final mcumgr.FirmwareUpdateManagerFactory? managerFactory = mcumgr.FirmwareUpdateManagerFactory();
  mcumgr.FirmwareUpdateManager? _mcuUpdateManager;

  /// Process ZIP file and return firmware image list
  Future<List<mcumgr.Image>> processZipFile(Uint8List zipFileData) async {
    // Create temporary directory
    final prefix = 'firmware_${Uuid().v4()}';
    final systemTempDir = await getTemporaryDirectory();
    final tempDir = Directory('${systemTempDir.path}/$prefix');
    await tempDir.create();

    try {
      // Write ZIP data to temporary file
      final firmwareFile = File('${tempDir.path}/firmware.zip');
      await firmwareFile.writeAsBytes(zipFileData);

      // Create destination directory for extraction
      final destinationDir = Directory('${tempDir.path}/firmware');
      await destinationDir.create();

      // Extract ZIP file
      await ZipFile.extractToDirectory(zipFile: firmwareFile, destinationDir: destinationDir);

      // Read and parse manifest.json
      final manifestFile = File('${destinationDir.path}/manifest.json');
      if (!await manifestFile.exists()) {
        throw Exception('manifest.json not found in firmware ZIP');
      }
      final manifestString = await manifestFile.readAsString();
      final manifestJson = json.decode(manifestString);
      final manifest = Manifest.fromJson(manifestJson);

      // Process firmware files
      final List<mcumgr.Image> firmwareImages = [];
      for (final file in manifest.files) {
        final firmwareFile = File('${destinationDir.path}/${file.file}');
        final firmwareFileData = await firmwareFile.readAsBytes();
        final image = mcumgr.Image(image: file.image, data: firmwareFileData);
        firmwareImages.add(image);
      }

      return firmwareImages;
    } catch (e) {
      throw Exception('Failed to process ZIP file: $e');
    } finally {
      // Cleanup: Delete temporary directory
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Future<void> startDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    if (isLegacySecureDFU) {
      return startLegacyDfu(btDevice, fileInAssets: fileInAssets, zipFilePath: zipFilePath);
    }
    return startMCUDfu(btDevice, fileInAssets: fileInAssets, zipFilePath: zipFilePath);
  }

  Future<void> killMcuUpdateManager() async {
    if (_mcuUpdateManager != null) {
      try {
        await _mcuUpdateManager!.kill();
      } catch (e) {
        Logger.debug('Error killing update manager: $e');
      }
      _mcuUpdateManager = null;
    }
  }

  Future<void> startMCUDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    setState(() {
      isInstalling = true;
    });
    await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
    await Future.delayed(const Duration(seconds: 2));

    String firmwareFile = zipFilePath ?? '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
    final file = File(firmwareFile);
    if (!await file.exists()) {
      Logger.debug('Firmware file not found: $firmwareFile');
      if (mounted) {
        setState(() {
          isInstalling = false;
        });
      }
      return;
    }
    final bytes = await file.readAsBytes();
    const configuration = mcumgr.FirmwareUpgradeConfiguration(
      estimatedSwapTime: Duration(seconds: 0),
      eraseAppSettings: false,
      pipelineDepth: 1,
    );

    await killMcuUpdateManager();
    final updateManager = await managerFactory!.getUpdateManager(btDevice.id);
    _mcuUpdateManager = updateManager;
    final images = await processZipFile(bytes);

    final updateStream = updateManager.setup();

    updateStream.listen((state) {
      if (state == mcumgr.FirmwareUpgradeState.success) {
        Logger.debug('update success');
        killMcuUpdateManager();
        ServiceManager.instance().device.forgetDevice(btDevice.id);
        setState(() {
          isInstalling = false;
          isInstalled = true;
        });
      } else {
        Logger.debug('update state: $state');
      }
    });

    updateManager.progressStream.listen((progress) {
      Logger.debug('progress: $progress');
      setState(() {
        installProgress = (progress.bytesSent / progress.imageSize * 100).round();
      });
    });

    updateManager.logger.logMessageStream
        .where((log) => log.level.rawValue > 1) // Filter debug messages
        .listen((log) {
      Logger.debug('dfu log: ${log.message}');
    });

    await updateManager.update(images, configuration: configuration);
  }

  Future<void> startLegacyDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    setState(() {
      isInstalling = true;
    });
    await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
    await Future.delayed(const Duration(seconds: 2));
    String firmwareFile = zipFilePath ?? '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
    NordicDfu dfu = NordicDfu();
    await dfu.startDfu(
      btDevice.id,
      firmwareFile,
      fileInAsset: fileInAssets,
      numberOfPackets: 8,
      enableUnsafeExperimentalButtonlessServiceInSecureDfu: true,
      iosSpecialParameter: const IosSpecialParameter(
        packetReceiptNotificationParameter: 8,
        forceScanningForNewAddressInLegacyDfu: true,
        connectionTimeout: 60,
      ),
      androidSpecialParameter: const AndroidSpecialParameter(packetReceiptNotificationsEnabled: true, rebootTime: 1000),
      onProgressChanged: (deviceAddress, percent, speed, avgSpeed, currentPart, partsTotal) {
        Logger.debug('deviceAddress: $deviceAddress, percent: $percent');
        setState(() {
          installProgress = percent.toInt();
        });
      },
      onError: (deviceAddress, error, errorType, message) {
        Logger.debug('deviceAddress: $deviceAddress, error: $error, errorType: $errorType, message: $message');
        setState(() {
          isInstalling = false;
        });
        // Reset firmware update state on error
        final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
        deviceProvider.resetFirmwareUpdateState();
      },
      onDeviceConnecting: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDeviceConnecting'),
      onDeviceConnected: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDeviceConnected'),
      onDfuProcessStarting: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDfuProcessStarting'),
      onDfuProcessStarted: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onDfuProcessStarted'),
      onEnablingDfuMode: (deviceAddress) => Logger.debug('deviceAddress: $deviceAddress, onEnablingDfuMode'),
      onFirmwareValidating: (deviceAddress) => Logger.debug('address: $deviceAddress, onFirmwareValidating'),
      onDfuCompleted: (deviceAddress) {
        Logger.debug('deviceAddress: $deviceAddress, onDfuCompleted');
        ServiceManager.instance().device.forgetDevice(btDevice.id);
        setState(() {
          isInstalling = false;
          isInstalled = true;
        });
      },
    );
  }

  Future<String?> extractVersionFromZipPath(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final zip = archive.ZipDecoder().decodeBytes(bytes);
      for (final file in zip.files) {
        if (!file.isFile || file.name != 'version.txt') continue;
        return utf8.decode(file.content).trim();
      }
    } catch (e) {
      Logger.debug('Failed to read version.txt from zip: $e');
    }
    return null;
  }

  Future getLatestVersion({
    required String deviceModelNumber,
    required String firmwareRevision,
    required String hardwareRevision,
    required String manufacturerName,
  }) async {
    latestFirmwareDetails = await getLatestFirmwareVersion(
      deviceModelNumber: deviceModelNumber,
      firmwareRevision: firmwareRevision,
      hardwareRevision: hardwareRevision,
      manufacturerName: manufacturerName,
    );
    if (latestFirmwareDetails['ota_update_steps'] != null) {
      otaUpdateSteps = List<String>.from(latestFirmwareDetails['ota_update_steps']);
    }
    if (latestFirmwareDetails['is_legacy_secure_dfu'] != null) {
      isLegacySecureDFU = latestFirmwareDetails['is_legacy_secure_dfu'];
    }
  }

  Future getStableVersion({required String deviceModelNumber}) async {
    latestFirmwareDetails = await getStableFirmwareVersion(deviceModelNumber: deviceModelNumber);
    if (latestFirmwareDetails['ota_update_steps'] != null) {
      otaUpdateSteps = List<String>.from(latestFirmwareDetails['ota_update_steps']);
    }
    if (latestFirmwareDetails['is_legacy_secure_dfu'] != null) {
      isLegacySecureDFU = latestFirmwareDetails['is_legacy_secure_dfu'];
    }
  }

  Future<(String, bool)> shouldUpdateFirmware({required String currentFirmware}) async {
    // Basic version comparison logic
    if (latestFirmwareDetails.isEmpty || latestFirmwareDetails['version'] == null) {
      return ('Your device is up to date.', false);
    }
    String latest = latestFirmwareDetails['version'];
    if (latest != currentFirmware) {
      return ('A new firmware version is available: $latest', true);
    }
    return ('Your device is up to date.', false);
  }

  Future downloadFirmware() async {
    final zipUrl = latestFirmwareDetails['zip_url'];
    if (zipUrl == null) {
      Logger.debug('Error: zip_url is null in latestFirmwareDetails');
      setState(() {
        isDownloading = false;
      });
      // Reset firmware update state on error
      final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
      deviceProvider.resetFirmwareUpdateState();
      return;
    }

    String dir = (await getApplicationDocumentsDirectory()).path;

    setState(() {
      isDownloading = true;
      isDownloaded = false;
      downloadProgress = 0;
    });

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(zipUrl));
      final response = await client.send(request);
      final int? totalBytes = response.contentLength;

      List<int> bytes = [];
      int downloaded = 0;

      await for (var chunk in response.stream) {
        bytes.addAll(chunk);
        downloaded += chunk.length;
        if (totalBytes != null && totalBytes > 0) {
          setState(() {
            downloadProgress = (downloaded / totalBytes * 100).toInt();
          });
        }
      }

      File file = File('$dir/firmware.zip');
      await file.writeAsBytes(bytes);

      setState(() {
        isDownloading = false;
        isDownloaded = true;
        downloadProgress = 100;
      });
      client.close();
    } catch (e) {
      Logger.debug('Download error: $e');
      if (mounted) {
        setState(() {
          isDownloading = false;
        });
      }
      final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
      deviceProvider.resetFirmwareUpdateState();
    }
  }
}
