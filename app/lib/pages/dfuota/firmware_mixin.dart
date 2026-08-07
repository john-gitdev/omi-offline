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
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
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

  // A DFU bundle for the nRF5340 carries two images (app core + net core), and the
  // uploader reports bytesSent/imageSize for whichever one it is on. Reported raw,
  // that ran the bar 0→100 twice under one "Installing firmware…" label, so the page
  // looked like it was installing the firmware a second time. These fold the
  // per-image reports into one monotonic percentage over the whole flash, and let the
  // page name the part being written. See [_applyDfuProgress].
  int installImageIndex = 0; // 0-based index of the image currently uploading
  int installImageCount = 1;
  int _dfuTotalBytes = 0;
  int _dfuCompletedBytes = 0; // bytes belonging to images already finished
  int _dfuLastBytesSent = 0;
  int _dfuLastImageSize = 0;
  bool isLegacySecureDFU = true;
  List<String> otaUpdateSteps = [];
  final mcumgr.FirmwareUpdateManagerFactory? managerFactory = mcumgr.FirmwareUpdateManagerFactory();
  mcumgr.FirmwareUpdateManager? _mcuUpdateManager;

  // MCU/SMP DFU failure recovery. Unlike the legacy Nordic DFU path (which has an
  // onError callback), the mcumgr state stream surfaces failures by emitting a
  // stream *error*, and a wedged SMP connection can emit neither progress nor an
  // error at all — so without these the UI can sit forever on "Installing
  // firmware… 0%". `installErrorMessage` is surfaced by the update page.
  Timer? _dfuStallTimer;
  static const Duration _dfuStallTimeout = Duration(seconds: 45);
  bool _dfuTerminated = false;
  String? installErrorMessage;

  /// Process ZIP file and return firmware image list
  Future<List<mcumgr.Image>> processZipFile(Uint8List zipFileData) async {
    // Create temporary directory
    final prefix = 'firmware_${const Uuid().v4()}';
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

  /// An OTA must not be interrupted by the screen sleeping: if the display
  /// auto-locks the app drops to the background and iOS suspends the BLE
  /// transfer mid-flash — which can brick the device. Hold the screen awake for
  /// the whole install (and grab the iOS background-task assertion / Android
  /// CPU wakelock), mirroring the sync pipeline's wakelock handling.
  void _acquireUpdateWakelocks() {
    WakelockPlus.enable();
    if (Platform.isAndroid || Platform.isIOS) BleHostApi().acquireProcessingWakeLock();
  }

  /// Idempotent; safe to call when nothing is held. Called from each terminal
  /// DFU callback and again from the page's dispose() as a backstop.
  void releaseUpdateWakelocks() {
    // Honor "Keep Screen On" like RecordingsController, so leaving the update
    // page doesn't override a screen-on the user pinned. The iOS background
    // task is separate from the screen, so always release it.
    if (!SharedPreferencesUtil().keepScreenOn) WakelockPlus.disable();
    if (Platform.isAndroid || Platform.isIOS) BleHostApi().releaseProcessingWakeLock();
  }

  Future<void> startDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    _acquireUpdateWakelocks();
    // Stop any in-flight storage sync before the flash: it shares the storage
    // characteristic, and prepareDFU cancels sync again shortly, but bounding the
    // wait here keeps a live transfer from overlapping the handover.
    await ServiceManager.instance().wal.getSyncs().cancelAndWait();
    if (isLegacySecureDFU) {
      return startLegacyDfu(btDevice, fileInAssets: fileInAssets, zipFilePath: zipFilePath);
    }
    return startMCUDfu(btDevice, fileInAssets: fileInAssets, zipFilePath: zipFilePath);
  }

  /// On a SUCCESSFUL flash, clear the phone's stored bond so the next reconnect
  /// re-pairs cleanly. Only called from the success callbacks — a failed flash
  /// never reaches here and leaves the pairing untouched.
  ///
  /// Unconditional on Android, with no pre-flash handshake and nothing to opt
  /// into. The device arms its own wipe from the mcumgr DFU_PENDING hook, so both
  /// sides act on the same physical event (an image finished transferring) rather
  /// than on a command whose ACK the app has to interpret. That is what retired
  /// the old `_postDfuArmWriteOk` gate: there is no longer any device state being
  /// inferred from a write result.
  ///
  /// Wiping is right even when the version did not change. A flash rewrites the
  /// MCUboot primary slot regardless, and a bond it corrupts cannot be recovered
  /// from the phone — the firmware pins CONFIG_BT_MAX_PAIRED=1 and leaves
  /// CONFIG_BT_SMP_ALLOW_UNAUTH_OVERWRITE unset, so update_keys_check() refuses a
  /// fresh Just Works pairing while a key slot is occupied, whether the key in it
  /// is valid or corrupt. Skipping the wipe on a same-version reflash would
  /// therefore skip exactly the recovery flash a user performs *because* pairing
  /// is already broken.
  ///
  /// iOS has no programmatic bond removal, so this is Android-only; there the
  /// device still frees its own slot, which is the half that cannot be undone
  /// from the phone.
  ///
  /// Not gated on the DFU transport. The legacy Nordic path would be a genuine
  /// hazard — it goes over the Nordic DFU service rather than mcumgr SMP, so
  /// `DFU_PENDING` never fires and the device could not arm its own wipe — but
  /// it has no live caller: `getLatestFirmwareVersion` / `getStableFirmwareVersion`
  /// are mocked stubs returning `{}`, so `shouldUpdateFirmware` reports no update
  /// and the button that calls `startDfu` is never rendered. The only path that
  /// reaches a flash is the local zip, which sets `isLegacySecureDFU = false`.
  /// Add the gate if those stubs are ever implemented; until then it would be a
  /// guard on an unreachable branch.
  Future<void> _wipePhoneBondOnSuccess(BtDevice btDevice) async {
    if (!Platform.isAndroid) return;
    try {
      await BleHostApi().removeBond(btDevice.id);
    } catch (e) {
      Logger.debug('Post-update phone bond wipe failed: $e');
    }
  }

  Future<void> killMcuUpdateManager() async {
    // Every DFU teardown path funnels through here (success, failure, page
    // dispose, and the pre-flight kill before a fresh attempt), so cancel the
    // stall watchdog here to guarantee no stray timer outlives the manager.
    _dfuStallTimer?.cancel();
    _dfuStallTimer = null;
    if (_mcuUpdateManager != null) {
      try {
        await _mcuUpdateManager!.kill();
      } catch (e) {
        Logger.debug('Error killing update manager: $e');
      }
      _mcuUpdateManager = null;
    }
  }

  /// (Re)arm the stall watchdog. Reset on every progress/state event; if nothing
  /// advances for [_dfuStallTimeout] the update is force-failed so the UI never
  /// sits forever on "Installing firmware… 0%" when the SMP transfer wedges
  /// (e.g. the BLE link is still busy from a just-cancelled sync).
  void _armDfuStallWatchdog() {
    _dfuStallTimer?.cancel();
    _dfuStallTimer = Timer(_dfuStallTimeout, () {
      Logger.debug('DFU stalled: no progress for ${_dfuStallTimeout.inSeconds}s');
      _handleDfuFailure('Firmware update stalled. Please try again.');
    });
  }

  /// Terminal failure path for the MCU DFU — mirrors startLegacyDfu's onError.
  /// Idempotent: the state-stream error and the stall watchdog can both fire.
  void _handleDfuFailure(String message) {
    if (_dfuTerminated) return;
    _dfuTerminated = true;
    killMcuUpdateManager(); // also cancels the stall watchdog
    releaseUpdateWakelocks();
    // A failed flash deliberately leaves the pairing untouched — no bond wipe here.
    if (!mounted) return;
    setState(() {
      isInstalling = false;
      installErrorMessage = message;
    });
    Provider.of<DeviceProvider>(context, listen: false).resetFirmwareUpdateState();
  }

  /// Folds the uploader's per-image progress into one monotonic 0–100 %.
  ///
  /// A drop in `bytesSent` is the only signal the bridge gives that it moved on to
  /// the next image, so bank the finished one there and add the running one on top.
  /// Safe if a platform ever reports cumulative bytes against the bundle total
  /// instead: nothing regresses, so the banked total stays 0 and the fraction is
  /// already the overall one. Falls back to the reported image size when the bundle
  /// total is unknown, which just restores the old per-image behaviour.
  void _applyDfuProgress(int bytesSent, int imageSize) {
    if (bytesSent < _dfuLastBytesSent) {
      _dfuCompletedBytes += _dfuLastImageSize;
      if (installImageIndex + 1 < installImageCount) installImageIndex++;
    }
    _dfuLastBytesSent = bytesSent;
    _dfuLastImageSize = imageSize;
    final total = _dfuTotalBytes > 0 ? _dfuTotalBytes : imageSize;
    if (total <= 0) return;
    installProgress = (((_dfuCompletedBytes + bytesSent) / total) * 100).round().clamp(0, 100);
  }

  Future<void> startMCUDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    _dfuTerminated = false;
    setState(() {
      isInstalling = true;
      installErrorMessage = null;
    });
    await Provider.of<DeviceProvider>(context, listen: false).prepareDFU();
    await Future.delayed(const Duration(seconds: 2));

    String firmwareFile = zipFilePath ?? '${(await getApplicationDocumentsDirectory()).path}/firmware.zip';
    final file = File(firmwareFile);
    if (!await file.exists()) {
      Logger.debug('Firmware file not found: $firmwareFile');
      _handleDfuFailure('Firmware file not found. Please try again.');
      return;
    }
    final bytes = await file.readAsBytes();
    const configuration = mcumgr.FirmwareUpgradeConfiguration(
      estimatedSwapTime: Duration(seconds: 0),
      eraseAppSettings: false,
      pipelineDepth: 1,
    );

    await killMcuUpdateManager();
    final mcumgr.FirmwareUpdateManager updateManager;
    final List<mcumgr.Image> images;
    try {
      updateManager = await managerFactory!.getUpdateManager(btDevice.id);
      _mcuUpdateManager = updateManager;
      images = await processZipFile(bytes);
    } catch (e) {
      Logger.debug('DFU setup failed: $e');
      _handleDfuFailure('Could not start the update. Please try again.');
      return;
    }

    // Reset the multi-image progress fold for this attempt (a retry re-enters here).
    installImageIndex = 0;
    installImageCount = images.length;
    _dfuTotalBytes = images.fold<int>(0, (sum, image) => sum + image.data.length);
    _dfuCompletedBytes = 0;
    _dfuLastBytesSent = 0;
    _dfuLastImageSize = 0;
    installProgress = 0;
    // Repaint on its own: the card is already on screen showing the failed attempt's
    // percentage, and the first progress event is several seconds away. Deliberately
    // NOT an early return when unmounted — the flash must proceed exactly as before.
    if (mounted) setState(() {});

    final updateStream = updateManager.setup();

    updateStream.listen((state) {
      // Once this attempt has ended (success or _handleDfuFailure), ignore any
      // event still queued behind it: the state/progress streams and the
      // watchdog timer are independent async sources, so a success event can
      // arrive after teardown began (it must not resurrect the success screen)
      // and stray state events must not re-arm a dead watchdog timer.
      if (_dfuTerminated) return;
      if (state == mcumgr.FirmwareUpgradeState.success) {
        _dfuTerminated = true; // success is terminal
        Logger.debug('update success');
        killMcuUpdateManager(); // also cancels the stall watchdog
        releaseUpdateWakelocks();
        _wipePhoneBondOnSuccess(btDevice);
        if (mounted) {
          setState(() {
            isInstalling = false;
            isInstalled = true;
          });
        }
      } else {
        Logger.debug('update state: $state');
        _armDfuStallWatchdog(); // advancing through stages resets the watchdog
      }
    }, onError: (Object e) {
      // mcumgr surfaces DFU failures as a stream error (see DeviceUpdateManager).
      Logger.debug('update error: $e');
      _handleDfuFailure('Firmware update failed. Please try again.');
    });

    updateManager.progressStream.listen((progress) {
      if (_dfuTerminated) return;
      Logger.debug('progress: $progress');
      _armDfuStallWatchdog();
      if (mounted) {
        setState(() => _applyDfuProgress(progress.bytesSent, progress.imageSize));
      }
    });

    updateManager.logger.logMessageStream
        .where((log) => log.level.rawValue > 1) // Filter debug messages
        .listen((log) {
      Logger.debug('dfu log: ${log.message}');
    });

    // Arm before kicking off the transfer: the initial SMP connect/setup is the
    // most common place to wedge with progress stuck at 0%.
    _armDfuStallWatchdog();
    try {
      await updateManager.update(images, configuration: configuration);
    } catch (e) {
      Logger.debug('DFU update kickoff failed: $e');
      _handleDfuFailure('Firmware update failed. Please try again.');
    }
  }

  Future<void> startLegacyDfu(BtDevice btDevice, {bool fileInAssets = false, String? zipFilePath}) async {
    setState(() {
      isInstalling = true;
      installImageIndex = 0;
      installImageCount = 1;
      installProgress = 0;
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
        Logger.debug('deviceAddress: $deviceAddress, percent: $percent, part: $currentPart/$partsTotal');
        setState(() {
          // Same one-bar-for-the-whole-flash rule as the MCU path, using the part
          // indices Nordic hands us directly.
          final parts = partsTotal > 0 ? partsTotal : 1;
          installImageCount = parts;
          installImageIndex = (currentPart - 1).clamp(0, parts - 1);
          installProgress = (((installImageIndex * 100 + percent) / parts).round()).clamp(0, 100);
        });
      },
      onError: (deviceAddress, error, errorType, message) {
        Logger.debug('deviceAddress: $deviceAddress, error: $error, errorType: $errorType, message: $message');
        releaseUpdateWakelocks();
        // A failed flash deliberately leaves the pairing untouched — no bond wipe here.
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
        releaseUpdateWakelocks();
        _wipePhoneBondOnSuccess(btDevice);
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
    // Capture the provider before any async gap so the error-path cleanup below
    // never references `context` across an await (use_build_context_synchronously).
    final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
    final zipUrl = latestFirmwareDetails['zip_url'];
    if (zipUrl == null) {
      Logger.debug('Error: zip_url is null in latestFirmwareDetails');
      setState(() {
        isDownloading = false;
      });
      // Reset firmware update state on error
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
      deviceProvider.resetFirmwareUpdateState();
    }
  }
}
