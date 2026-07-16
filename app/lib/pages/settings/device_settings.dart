import 'package:omi/gen/pigeon_communicator.g.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/dfuota/firmware_update.dart';
import 'package:omi/utils/device.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/pages/settings/button_config_page.dart';
import 'package:omi/widgets/dialog.dart';

class DeviceSettings extends StatefulWidget {
  const DeviceSettings({super.key});

  @override
  State<DeviceSettings> createState() => _DeviceSettingsState();
}

class _DeviceSettingsState extends State<DeviceSettings> {
  double _dimRatio = 100.0;
  bool _isDimRatioLoaded = false;
  bool? _hasDimmingFeature;

  double _micGain = 5.0;
  bool _isMicGainLoaded = false;
  bool? _hasMicGainFeature;

  late double _vadThreshold;
  bool _isVadThresholdLoaded = false;
  bool? _hasVadThresholdFeature;

  late int _priorityRecordCap; // minutes; 0 = no cap
  bool _isPriorityCapLoaded = false;
  bool? _hasPriorityCapFeature;

  Timer? _debounce;
  Timer? _micGainDebounce;
  Timer? _vadThresholdDebounce;

  bool _isWiping = false;

  @override
  void initState() {
    _vadThreshold = SharedPreferencesUtil().autoVadThreshold.toDouble();
    _priorityRecordCap = SharedPreferencesUtil().priorityRecordMaxMinutes;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<DeviceProvider>();
      await provider.getDeviceInfo();
      // Battery level comes from the BLE notification listener set up on connect.
      // Calling updateBatteryLevel() would try to READ the detail characteristic,
      // which is notify-only (GATT_READ_NOT_PERMITTED). Skip it here.
      _loadInitialDimRatio();
      provider.refreshStorageStats();
    });
    super.initState();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _micGainDebounce?.cancel();
    _vadThresholdDebounce?.cancel();
    super.dispose();
  }

  void _loadInitialDimRatio() async {
    if (!mounted) return;
    final deviceProvider = context.read<DeviceProvider>();
    final pairedDevice = deviceProvider.pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      var connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
      if (connection != null) {
        var features = await connection.getFeatures();
        // Retry up to 2 more times if the first read fails (transient GATT error
        // on a degraded but still-connected link returns 0 instead of the real flags).
        for (int i = 0; i < 2 && features == 0 && mounted; i++) {
          await Future.delayed(const Duration(milliseconds: 600));
          features = await connection.getFeatures();
        }
        final hasDimming = OmiFeatures.hasFeature(features, OmiFeatures.ledDimming);
        final hasMicGain = OmiFeatures.hasFeature(features, OmiFeatures.micGain);
        final hasVadThreshold = OmiFeatures.hasFeature(features, OmiFeatures.vadThreshold);
        final hasPriorityCap = OmiFeatures.hasFeature(features, OmiFeatures.priorityRecordCap);

        if (!mounted) return;
        setState(() {
          _hasDimmingFeature = hasDimming;
          _hasMicGainFeature = hasMicGain;
          _hasVadThresholdFeature = hasVadThreshold;
          _hasPriorityCapFeature = hasPriorityCap;
        });

        if (!hasDimming) {
          setState(() {
            _isDimRatioLoaded = true;
          });
        } else {
          var ratio = await connection.getLedDimRatio();
          if (ratio != null && mounted) {
            setState(() {
              _dimRatio = ratio.toDouble();
              _isDimRatioLoaded = true;
            });
          } else if (mounted) {
            setState(() {
              _isDimRatioLoaded = true; // Loaded, but no value, use default
            });
          }
        }

        if (!hasMicGain) {
          setState(() {
            _isMicGainLoaded = true;
          });
        } else {
          var gain = await connection.getMicGain();
          if (gain != null && mounted) {
            setState(() {
              _micGain = gain.toDouble();
              _isMicGainLoaded = true;
            });
          } else if (mounted) {
            setState(() {
              _isMicGainLoaded = true; // Loaded, but no value, use default
            });
          }
        }

        if (!hasVadThreshold) {
          setState(() {
            _isVadThresholdLoaded = true;
          });
        } else {
          var threshold = await connection.getVadThreshold();
          if (threshold != null && mounted) {
            setState(() {
              _vadThreshold = threshold.toDouble();
              _isVadThresholdLoaded = true;
            });
          } else if (mounted) {
            setState(() {
              _isVadThresholdLoaded = true; // Loaded, but no value, use default
            });
          }
        }

        if (!hasPriorityCap) {
          setState(() {
            _isPriorityCapLoaded = true;
          });
        } else {
          var cap = await connection.getPriorityRecordCap();
          if (cap != null && mounted) {
            setState(() {
              _priorityRecordCap = cap;
              _isPriorityCapLoaded = true;
            });
          } else if (mounted) {
            setState(() {
              _isPriorityCapLoaded = true; // Loaded, but no value, use default
            });
          }
        }
      }
    }
  }

  void _updateDimRatio(double value) async {
    final deviceProvider = context.read<DeviceProvider>();
    final pairedDevice = deviceProvider.pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      var connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
      await connection?.setLedDimRatio(value.toInt());
    }
  }

  void _updateMicGain(double value) async {
    final deviceProvider = context.read<DeviceProvider>();
    final pairedDevice = deviceProvider.pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      var connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
      await connection?.setMicGain(value.toInt());
    }
  }

  void _updateVadThreshold(double value) async {
    SharedPreferencesUtil().autoVadThreshold = value.toInt();
    final deviceProvider = context.read<DeviceProvider>();
    final pairedDevice = deviceProvider.pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      var connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
      await connection?.setVadThreshold(value.toInt());
    }
  }

  void _updatePriorityCap(int minutes) async {
    SharedPreferencesUtil().priorityRecordMaxMinutes = minutes;
    setState(() => _priorityRecordCap = minutes);
    // Capture the messenger + provider before the async gap. The cap is armed
    // device-side at the start of a Priority Recording, so changing it never
    // affects one already in progress — surface that so it isn't surprising.
    final messenger = ScaffoldMessenger.of(context);
    final deviceProvider = context.read<DeviceProvider>();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('New cap applies to your next Priority Recording, not one already in progress.'),
      ),
    );
    final pairedDevice = deviceProvider.pairedDevice;
    if (pairedDevice != null && pairedDevice.id.isNotEmpty) {
      var connection = await ServiceManager.instance().device.ensureConnection(pairedDevice.id);
      await connection?.setPriorityRecordCap(minutes);
    }
  }

  Widget _buildSectionHeader(String title, {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
          ],
        ],
      ),
    );
  }

  Widget _buildProfileStyleItem({
    required IconData icon,
    required String title,
    String? chipValue,
    String? copyValue,
    VoidCallback? onTap,
    bool showChevron = true,
  }) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        children: [
          SizedBox(width: 24, height: 24, child: FaIcon(icon, color: const Color(0xFF8E8E93), size: 20)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
            ),
          ),
          if (chipValue != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: const Color(0xFF2A2A2E), borderRadius: BorderRadius.circular(100)),
              child: Text(
                chipValue,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
            if (showChevron) const SizedBox(width: 8),
          ],
          if (showChevron) const Icon(Icons.chevron_right, color: Color(0xFF3C3C43), size: 20),
        ],
      ),
    );

    if (copyValue != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: copyValue));
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$title copied to clipboard')));
          },
          child: content,
        ),
      );
    }

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, child: content),
      );
    }
    return content;
  }

  Widget _buildDeviceInfoSection(BtDevice? device, DeviceProvider provider) {
    final deviceId = device?.id ?? 'Unknown';

    String truncateId(String id) {
      if (id.length > 10) {
        return '${id.substring(0, 4)}•••${id.substring(id.length - 4)}';
      }
      return id;
    }

    return Material(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.batteryFull,
            title: 'Battery Level',
            chipValue: provider.batteryLevel >= 0 ? '${provider.batteryLevel}%' : '...',
            showChevron: false,
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.fingerprint,
            title: 'Device ID',
            chipValue: truncateId(deviceId),
            copyValue: deviceId,
            showChevron: false,
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.download,
            title: 'Firmware',
            chipValue: device?.firmwareRevision ?? 'oo-1.0.9',
            showChevron: true,
            onTap: () async {
              provider.setOnFirmwareUpdatePage(true);
              FilePickerResult? result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['zip'],
              );
              if (result != null && result.files.single.path != null) {
                if (mounted) {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (c) => FirmwareUpdate(
                      device: device,
                      localZipPath: result.files.single.path,
                    ),
                  ));
                }
              } else {
                provider.setOnFirmwareUpdatePage(false);
              }
            },
          ),
          // Gate on stats existing (not on freeBytes > 0): a full device reports
          // freeBytes == 0, and that is exactly when the user needs the wipe entry.
          if (provider.storageStats != null) ...[
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.microchip,
              title: 'Storage Free Space',
              chipValue:
                  _isWiping ? 'Wiping…' : '${(provider.storageStats!.freeBytes / 1024 / 1024).toStringAsFixed(1)} MB',
              showChevron: true,
              onTap: _isWiping ? null : () => _wipeDeviceStorage(provider),
            ),
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.fileAudio,
              title: 'File Count',
              // Current firmware already excludes the open recording from the stat,
              // so this equals the number of closed/syncable files — no extra -1.
              chipValue: '${provider.storageStats!.fileCount.clamp(0, 999)}',
              showChevron: false,
            ),
          ],
        ],
      ),
    );
  }

  /// Closes the active bin, deletes every recording on the Omi's SD card, and
  /// opens a fresh empty file — all atomically via CMD_CLEAR_STORAGE (0x14) on
  /// the firmware's storage thread (safer than a manual rotate-then-delete,
  /// which risks GATT 133). Mirrors the proven Debug Tools "Delete Omi
  /// Segments" flow so the recordings UI and sync-progress prefs stay coherent.
  Future<void> _wipeDeviceStorage(DeviceProvider provider) async {
    if (_isWiping) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        "Completely Wipe Omi's Recordings?",
        "This permanently erases all audio on the Omi device's SD card, including anything not yet synced to "
            'this phone. Recordings already saved on this phone are kept. This cannot be undone.',
        confirmText: 'Wipe',
      ),
    );
    if (confirm != true) return;

    setState(() => _isWiping = true);
    // Blocking progress dialog: CMD_CLEAR_STORAGE can take up to ~65 s, and it
    // also prevents a second tap from racing the storage lock.
    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (c) => const AlertDialog(
          backgroundColor: Color(0xFF1C1C1E),
          content: Row(
            children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 20),
              Expanded(child: Text('Wiping Omi storage…', style: TextStyle(color: Colors.white, fontSize: 16))),
            ],
          ),
        ),
      );
    }

    String message;
    try {
      final syncs = ServiceManager.instance().wal.getSyncs();
      if (syncs.isSyncing) {
        Logger.debug('DeviceSettings: cancelling active sync before wiping device storage');
      }
      await syncs.cancelAndWait();

      Logger.debug('DeviceSettings: wiping device storage via deleteAllPendingWals()');
      await syncs.deleteAllPendingWals();

      // Reset sync/processing progress state so the recordings page doesn't show
      // stale progress against a now-empty device.
      final prefs = SharedPreferencesUtil();
      await prefs.remove('sp_state');
      await prefs.remove('sp_synced_count');
      await prefs.remove('sp_total_count');
      await prefs.remove('sp_minutes_remaining');
      await prefs.remove('sp_marker_count');
      await prefs.remove('sp_last_completed_stage');
      await prefs.remove('sp_last_active_stage');

      RecordingsManager.notifyRecordingsChanged();
      await provider.refreshStorageStats();
      message = "Omi's recordings wiped.";
    } catch (e) {
      Logger.error('DeviceSettings: wipe device storage error — $e');
      message = 'Wipe failed: $e';
    } finally {
      if (mounted) setState(() => _isWiping = false);
    }

    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss the progress dialog
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildHardwareInfoSection(BtDevice? device) {
    final hardwareRevision = device?.hardwareRevision ?? 'XIAO';
    final modelNumber = device?.modelNumber ?? 'Omi CV1';
    final manufacturer = device?.manufacturerName ?? 'Based Hardware';

    return Material(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.gears,
            title: 'Hardware Revision',
            chipValue: hardwareRevision,
            copyValue: hardwareRevision,
            showChevron: false,
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.hashtag,
            title: 'Model Number',
            chipValue: modelNumber,
            copyValue: modelNumber,
            showChevron: false,
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.industry,
            title: 'Manufacturer',
            chipValue: manufacturer,
            copyValue: manufacturer,
            showChevron: false,
          ),
        ],
      ),
    );
  }

  void _showBrightnessSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(color: const Color(0xFF3C3C43), borderRadius: BorderRadius.circular(2)),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'LED Brightness',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${_dimRatio.round()}%',
                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.grey.shade800,
                        thumbColor: Colors.white,
                        overlayColor: Colors.white.withValues(alpha: 0.1),
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12, elevation: 2),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
                        trackHeight: 6,
                      ),
                      child: Slider(
                        value: _dimRatio,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        onChanged: (double value) {
                          setSheetState(() {});
                          setState(() {
                            _dimRatio = value;
                          });
                          _debounce?.cancel();
                          _debounce = Timer(const Duration(milliseconds: 300), () {
                            _updateDimRatio(value);
                          });
                        },
                        onChangeEnd: (double value) {
                          _debounce?.cancel();
                          _updateDimRatio(value);
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Off', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                        Text('Max', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showMicGainSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            String getGainLabel(int level) {
              const labels = ['Mute', '-20dB', '-10dB', '+0dB', '+6dB', '+10dB', '+20dB', '+30dB', '+40dB'];
              return level >= 0 && level < labels.length ? labels[level] : '';
            }

            String getGainDescription(int level) {
              const descriptions = [
                'Microphone is muted',
                'Very quiet - for loud environments',
                'Quiet - for moderate noise',
                'Neutral - balanced recording',
                'Slightly boosted - normal use',
                'Boosted - for quiet environments',
                'High - for distant or soft voices',
                'Very high - for very quiet sources',
                'Maximum - use with caution',
              ];
              return level >= 0 && level < descriptions.length ? descriptions[level] : '';
            }

            final currentLevel = _micGain.round();

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(color: const Color(0xFF3C3C43), borderRadius: BorderRadius.circular(2)),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Mic Gain',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          getGainLabel(currentLevel),
                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(getGainDescription(currentLevel), style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                    const SizedBox(height: 24),
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.grey.shade800,
                        thumbColor: Colors.white,
                        overlayColor: Colors.white.withValues(alpha: 0.1),
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12, elevation: 2),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
                        trackHeight: 6,
                      ),
                      child: Slider(
                        value: _micGain,
                        min: 0,
                        max: 8,
                        divisions: 8,
                        onChanged: (double value) {
                          setSheetState(() {});
                          setState(() {
                            _micGain = value;
                          });
                          _micGainDebounce?.cancel();
                          _micGainDebounce = Timer(const Duration(milliseconds: 300), () {
                            _updateMicGain(value);
                          });
                        },
                        onChangeEnd: (double value) {
                          _micGainDebounce?.cancel();
                          _updateMicGain(value);
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Mute', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                        Text('Max', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _buildPresetButton('Quiet', 2, currentLevel, () {
                            setSheetState(() {});
                            setState(() => _micGain = 2.0);
                            _updateMicGain(2.0);
                          }),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildPresetButton('Normal', 4, currentLevel, () {
                            setSheetState(() {});
                            setState(() => _micGain = 4.0);
                            _updateMicGain(4.0);
                          }),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildPresetButton('High', 6, currentLevel, () {
                            setSheetState(() {});
                            setState(() => _micGain = 6.0);
                            _updateMicGain(6.0);
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPresetButton(String label, int level, int currentLevel, VoidCallback onTap) {
    final isSelected = level == currentLevel;
    return Material(
      color: isSelected ? Colors.white.withValues(alpha: 0.1) : const Color(0xFF2A2A2E),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: isSelected ? Colors.white.withValues(alpha: 0.5) : Colors.transparent, width: 1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.grey.shade400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _getMicGainLabel(int level) {
    const labels = ['Mute', '-20dB', '-10dB', '+0dB', '+6dB', '+10dB', '+20dB', '+30dB', '+40dB'];
    return level >= 0 && level < labels.length ? labels[level] : '';
  }

  void _showVadThresholdSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final currentValue = _vadThreshold.round().clamp(0, 1000);
            final String label = currentValue == 0 ? 'Always On' : '$currentValue';

            void setValue(int raw) {
              setSheetState(() {});
              setState(() => _vadThreshold = raw.toDouble());
              _updateVadThreshold(raw.toDouble());
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(color: const Color(0xFF3C3C43), borderRadius: BorderRadius.circular(2)),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'AAD Sensitivity',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          label,
                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      currentValue == 0
                          ? 'Records everything, no silence skipping'
                          : 'Adjust how easily the device wakes up and starts recording.',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.grey.shade800,
                        thumbColor: Colors.white,
                        overlayColor: Colors.white.withValues(alpha: 0.1),
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12, elevation: 2),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
                        trackHeight: 6,
                      ),
                      child: Slider(
                        value: currentValue.toDouble(),
                        min: 0,
                        max: 1000,
                        divisions: 20,
                        onChanged: (double value) {
                          setSheetState(() {});
                          setState(() => _vadThreshold = value);
                          _vadThresholdDebounce?.cancel();
                          _vadThresholdDebounce = Timer(const Duration(milliseconds: 300), () {
                            _updateVadThreshold(_vadThreshold);
                          });
                        },
                        onChangeEnd: (double value) {
                          _vadThresholdDebounce?.cancel();
                          _updateVadThreshold(_vadThreshold);
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Always On', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                        Text('Max', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _buildPresetButton('-', -1, currentValue, () {
                            if (currentValue > 0) setValue((currentValue - 50).clamp(0, 1000));
                          }),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: _buildPresetButton('Default (250)', 250, currentValue, () => setValue(250)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildPresetButton('+', -1, currentValue, () {
                            if (currentValue < 1000) setValue((currentValue + 50).clamp(0, 1000));
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Preset durations for the Priority Recording safety cap (minutes; 0 = no cap).
  static const List<int> _priorityCapPresets = [30, 60, 120, 240, 480, 0];

  String _formatPriorityCap(int minutes) {
    if (minutes <= 0) return 'No cap';
    if (minutes < 60) return '${minutes}m';
    if (minutes % 60 == 0) return '${minutes ~/ 60}h';
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }

  void _showPriorityCapSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: const Color(0xFF3C3C43), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const Text(
                  'Priority Recording Cap',
                  style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  "A Priority Recording force-captures until you stop it. This safety cap auto-stops a "
                  "forgotten one so it can't drain the battery or fill the SD card.",
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
                const SizedBox(height: 16),
                ..._priorityCapPresets.map((minutes) {
                  final selected = _priorityRecordCap == minutes;
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        Navigator.pop(sheetContext);
                        if (minutes != _priorityRecordCap) _updatePriorityCap(minutes);
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              minutes == 0 ? 'No cap (battery / SD only)' : _formatPriorityCap(minutes),
                              style: TextStyle(
                                color: selected ? Colors.white : Colors.grey.shade300,
                                fontSize: 16,
                                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                            if (selected) const Icon(Icons.check, color: Colors.white, size: 20),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCustomizationSection() {
    return Material(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // LED Brightness
          if (_isDimRatioLoaded && _hasDimmingFeature == true) ...[
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.lightbulb,
              title: 'LED Brightness',
              chipValue: '${_dimRatio.round()}%',
              onTap: _showBrightnessSheet,
            ),
          ],
          // Mic Gain
          if (_isMicGainLoaded && _hasMicGainFeature == true) ...[
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.microphone,
              title: 'Mic Gain',
              chipValue: _getMicGainLabel(_micGain.round()),
              onTap: _showMicGainSheet,
            ),
          ],
          // AAD Sensitivity (hidden in manual mode — recording is tap-triggered, not voice-activated)
          if (_isVadThresholdLoaded && _hasVadThresholdFeature == true && !SharedPreferencesUtil().manualMode) ...[
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.earListen,
              title: 'AAD Sensitivity',
              chipValue: _vadThreshold <= 0 ? 'Always On' : '${_vadThreshold.round()}',
              onTap: _showVadThresholdSheet,
            ),
          ],
          // Priority Recording Cap (auto mode only — Priority Recording is an auto-mode action)
          if (_isPriorityCapLoaded && _hasPriorityCapFeature == true && !SharedPreferencesUtil().manualMode) ...[
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.stopwatch,
              title: 'Priority Recording Cap',
              chipValue: _formatPriorityCap(_priorityRecordCap),
              onTap: _showPriorityCapSheet,
            ),
          ],
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.handPointer,
            title: 'Button Configuration',
            chipValue: 'Customize',
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (c) => const ButtonConfigPage()));
            },
          ),
        ],
      ),
    );
  }

  /// Shared flow for the remote power commands (Reboot / Shutdown): confirm,
  /// stop any in-flight sync so the write doesn't race a live transfer on the
  /// shared storage characteristic, send [sendCommand] over the connection, and
  /// report the outcome. Keeps the two entry points from drifting.
  Future<void> _sendPowerCommand(
    DeviceProvider provider, {
    required String title,
    required String message,
    required String confirmText,
    required Future<bool> Function(DeviceConnection conn) sendCommand,
    required String successMsg,
  }) async {
    final pairedDeviceId = provider.pairedDevice?.id ?? SharedPreferencesUtil().btDevice.id;
    if (pairedDeviceId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(
        context,
        () => Navigator.of(context).pop(false),
        () => Navigator.of(context).pop(true),
        title,
        message,
        confirmText: confirmText,
      ),
    );
    if (confirmed != true) return;

    // The power-command write shares the storage characteristic with file
    // transfers, so stop any in-flight sync (and wait for it to unwind) first.
    await ServiceManager.instance().wal.getSyncs().cancelAndWait();

    bool ok = false;
    try {
      final connection = await ServiceManager.instance().device.ensureConnection(pairedDeviceId);
      ok = connection != null && await sendCommand(connection);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? successMsg : 'Could not reach your Omi — try again.')),
    );
  }

  /// Remote cold-reboot the Omi via CMD_REBOOT (0x16). The device ACKs, then
  /// restarts and drops the link for a few seconds; the native BLE layer
  /// auto-reconnects once it re-advertises. Useful to recover a wedged device
  /// without clearing the pairing (unlike Unpair).
  Future<void> _rebootDevice(DeviceProvider provider) => _sendPowerCommand(
        provider,
        title: 'Reboot Omi?',
        message: 'Restart your Omi now. It will disconnect for a few seconds and reconnect automatically. '
            'An in-progress recording not yet written to the SD card may lose its last few seconds.',
        confirmText: 'Reboot',
        sendCommand: (conn) => conn.sendRebootCommand(),
        successMsg: 'Rebooting your Omi…',
      );

  /// Remote power-off the Omi via CMD_POWER_OFF (0x17). The device ACKs, shuts
  /// down (ship mode) and stays off until a button press or charger wakes it —
  /// so, unlike Reboot, it does not reconnect on its own.
  Future<void> _shutdownDevice(DeviceProvider provider) => _sendPowerCommand(
        provider,
        title: 'Shut down Omi?',
        message: 'Power your Omi off now. It will disconnect and stay off until you turn it back on with the '
            "button — it won't reconnect on its own. An in-progress recording not yet written to the SD card "
            'may lose its last few seconds.',
        confirmText: 'Shut Down',
        sendCommand: (conn) => conn.sendShutdownCommand(),
        successMsg: 'Shutting down your Omi…',
      );

  Widget _buildActionsSection(DeviceProvider provider) {
    return Material(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (provider.isConnected) ...[
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            // Remote cold-reboot — recover a wedged device without unpairing.
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _rebootDevice(provider),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: FaIcon(FontAwesomeIcons.arrowsRotate, color: Colors.white70, size: 20),
                      ),
                      SizedBox(width: 16),
                      Text(
                        'Reboot Omi',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            // Remote power-off (ship mode) — stays off until a button/charger wake.
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _shutdownDevice(provider),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: FaIcon(FontAwesomeIcons.powerOff, color: Colors.white70, size: 20),
                      ),
                      SizedBox(width: 16),
                      Text(
                        'Shutdown Omi',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () async {
                  final pairedDeviceId = provider.pairedDevice?.id ?? SharedPreferencesUtil().btDevice.id;

                  // Cancel any in-progress sync immediately.
                  final walSync = ServiceManager.instance().wal.getSyncs();
                  walSync.cancelSync();
                  walSync.setDevice(null);

                  if (pairedDeviceId.isNotEmpty) {
                    // Use forgetDevice() to explicitly clear associations
                    await ServiceManager.instance().device.forgetDevice(pairedDeviceId);

                    // Explicitly tell native to stop managing this device
                    try {
                      final BleHostApi hostApi = BleHostApi();
                      await hostApi.unmanageDevice(pairedDeviceId);
                    } catch (_) {}
                  }

                  await SharedPreferencesUtil().btDeviceSet(BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0));
                  SharedPreferencesUtil().deviceName = '';

                  provider.setIsConnected(false);
                  await provider.setConnectedDevice(null);
                  provider.updateConnectingStatus(false);

                  if (mounted) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('Your Omi has been unpaired')));
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: FaIcon(FontAwesomeIcons.linkSlash, color: Colors.redAccent, size: 20),
                      ),
                      SizedBox(width: 16),
                      Text(
                        'Unpair Device',
                        style: TextStyle(color: Colors.redAccent, fontSize: 17, fontWeight: FontWeight.w400),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDisconnectedOverlay(bool isBluetoothEnabled) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(14)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: const Color(0xFF2A2A2E), borderRadius: BorderRadius.circular(16)),
            child: Center(
                child: FaIcon(!isBluetoothEnabled ? FontAwesomeIcons.bluetooth : FontAwesomeIcons.linkSlash,
                    color: Colors.grey.shade500, size: 24)),
          ),
          const SizedBox(height: 20),
          Text(
            !isBluetoothEnabled ? 'Bluetooth is Off' : 'Device Not Connected',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            !isBluetoothEnabled
                ? 'Please turn on Bluetooth to connect\nyour Omi device'
                : 'Connect your Omi device to access\ndevice settings and customization',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceHeader(BtDevice? device, bool isConnected) {
    return Center(
      child: Column(
        children: [
          const SizedBox(height: 20),
          Hero(
            tag: 'device_image',
            child: Image.asset(
              DeviceUtils.getDeviceImagePathWithState(isConnected: isConnected),
              width: 180,
              height: 180,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            device?.name ?? 'Omi CV1',
            style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isConnected ? Colors.greenAccent : Colors.redAccent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isConnected ? 'Connected' : 'Disconnected',
                style: TextStyle(
                  color: isConnected ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DeviceProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D0D0D),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0D0D0D),
            elevation: 0,
            leading: IconButton(
              icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
              onPressed: () => Navigator.of(context).pop(),
              tooltip: 'Back',
            ),
            title: const Text(
              'Device Settings',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            centerTitle: true,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDeviceHeader(provider.pairedDevice, provider.isConnected),
                if (!provider.isConnected) ...[
                  _buildDisconnectedOverlay(provider.isBluetoothEnabled),
                  const SizedBox(height: 32),
                ],
                if (provider.isConnected) ...[
                  const SizedBox(height: 16),
                  _buildSectionHeader('Customization'),
                  _buildCustomizationSection(),
                  const SizedBox(height: 32),
                  _buildSectionHeader('Device Info'),
                  _buildDeviceInfoSection(provider.pairedDevice, provider),
                  const SizedBox(height: 32),
                  _buildSectionHeader('Hardware'),
                  _buildHardwareInfoSection(provider.pairedDevice),
                  const SizedBox(height: 32),
                ],
                _buildActionsSection(provider),
                const SizedBox(height: 48),
              ],
            ),
          ),
        );
      },
    );
  }
}
