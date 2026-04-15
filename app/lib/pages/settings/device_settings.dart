import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/settings/firmware/firmware_update.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/utils/device.dart';
import 'sync_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:file_picker/file_picker.dart';

class DeviceSettings extends StatefulWidget {
  const DeviceSettings({super.key});

  @override
  State<DeviceSettings> createState() => _DeviceSettingsState();
}

class _DeviceSettingsState extends State<DeviceSettings> {
  bool _hasDimmingFeature = false;
  bool _isDimRatioLoaded = false;
  double _dimRatio = 50.0; // Default fallback

  bool _hasMicGainFeature = false;
  bool _isMicGainLoaded = false;
  double _micGain = 0.0; // Default 0dB

  Timer? _micGainDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkFeaturesAndLoadSettings();
    });
  }

  @override
  void dispose() {
    _micGainDebounce?.cancel();
    super.dispose();
  }

  Future<void> _checkFeaturesAndLoadSettings() async {
    final provider = context.read<DeviceProvider>();
    final connectedDevice = provider.connectedDevice;
    if (connectedDevice == null) return;

    final connection = await ServiceManager.instance().device.ensureConnection(connectedDevice.id);
    if (connection == null) return;

    final deviceInfo = await connection.performGetDeviceInfo(connection);

    if (mounted) {
      setState(() {
        _hasDimmingFeature = OmiFeatures.hasFeature(deviceInfo.features, OmiFeatures.ledDimming);
        _hasMicGainFeature = OmiFeatures.hasFeature(deviceInfo.features, OmiFeatures.micGain);
      });

      if (_hasDimmingFeature) {
        _loadDimRatio();
      }
      if (_hasMicGainFeature) {
        _loadMicGain();
      }
    }
  }

  Future<void> _loadDimRatio() async {
    final provider = context.read<DeviceProvider>();
    final connectedDevice = provider.connectedDevice;
    if (connectedDevice == null) return;

    final connection = await ServiceManager.instance().device.ensureConnection(connectedDevice.id);
    if (connection == null) return;

    final ratio = await connection.getDimRatio();
    if (ratio != null && mounted) {
      setState(() {
        _dimRatio = ratio.toDouble();
        _isDimRatioLoaded = true;
      });
    } else {
      if (mounted) setState(() => _isDimRatioLoaded = true);
    }
  }

  Future<void> _updateDimRatio(double ratio) async {
    final provider = context.read<DeviceProvider>();
    final connectedDevice = provider.connectedDevice;
    if (connectedDevice == null) return;

    final connection = await ServiceManager.instance().device.ensureConnection(connectedDevice.id);
    if (connection == null) return;

    await connection.setDimRatio(ratio.toInt());
    if (mounted) {
      setState(() {
        _dimRatio = ratio;
      });
    }
  }

  Future<void> _loadMicGain() async {
    final provider = context.read<DeviceProvider>();
    final connectedDevice = provider.connectedDevice;
    if (connectedDevice == null) return;

    final connection = await ServiceManager.instance().device.ensureConnection(connectedDevice.id);
    if (connection == null) return;

    final gainLevel = await connection.getMicGain();
    if (gainLevel != null && mounted) {
      setState(() {
        _micGain = gainLevel.toDouble();
        _isMicGainLoaded = true;
      });
    } else {
      if (mounted) setState(() => _isMicGainLoaded = true);
    }
  }

  Future<void> _updateMicGain(double gainLevel) async {
    final provider = context.read<DeviceProvider>();
    final connectedDevice = provider.connectedDevice;
    if (connectedDevice == null) return;

    final connection = await ServiceManager.instance().device.ensureConnection(connectedDevice.id);
    if (connection == null) return;

    await connection.setMicGain(gainLevel.toInt());
    if (mounted) {
      setState(() {
        _micGain = gainLevel;
      });
    }
  }

  Widget _buildProfileStyleItem({
    required IconData icon,
    required String title,
    String? chipValue,
    String? copyValue,
    VoidCallback? onTap,
    bool showChevron = true,
    Color? iconColor,
    Color? titleColor,
    Color? chipColor,
    Color? chipTextColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Padding(
                padding: const EdgeInsets.only(left: 2, top: 1),
                child: FaIcon(icon, color: iconColor ?? const Color(0xFF8E8E93), size: 20),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: titleColor ?? Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
              ),
            ),
            if (chipValue != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: chipColor ?? const Color(0xFF2A2A2E),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  chipValue,
                  style: TextStyle(
                    color: chipTextColor ?? Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (showChevron) const SizedBox(width: 8),
            ],
            if (showChevron) const Icon(Icons.chevron_right, color: Color(0xFF3C3C43), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5),
      ),
    );
  }

  Widget _buildDeviceInfoSection(BtDevice? device, DeviceProvider provider) {
    String truncateValue(String? value) {
      if (value == null) return 'Unknown';
      if (value.length > 12) {
        return '${value.substring(0, 5)}•••${value.substring(value.length - 4)}';
      }
      return value;
    }

    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.microchip,
            title: 'Product Name',
            chipValue: device?.name ?? 'Omi CV1',
            copyValue: device?.name ?? 'Omi CV1',
            showChevron: false,
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.hashtag,
            title: 'Model Number',
            chipValue: device?.modelNumber ?? 'Unknown',
            copyValue: device?.modelNumber ?? 'Unknown',
            showChevron: false,
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.fingerprint,
            title: 'Device ID',
            chipValue: truncateValue(device?.id),
            copyValue: device?.id,
            showChevron: false,
          ),
        ],
      ),
    );
  }

  Widget _buildHardwareInfoSection(BtDevice? device) {
    final provider = context.read<DeviceProvider>();
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.batteryHalf,
            title: 'Battery',
            chipValue: provider.batteryLevel > 0 ? '${provider.batteryLevel}%' : 'Unknown',
            showChevron: false,
            chipColor: provider.batteryLevel > 20 ? const Color(0xFF1A3D2E) : const Color(0xFF3D2A2A),
            chipTextColor: provider.batteryLevel > 20 ? const Color(0xFF4ADE80) : const Color(0xFFF87171),
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.industry,
            title: 'Manufacturer',
            chipValue: device?.manufacturerName ?? 'Unknown',
            copyValue: device?.manufacturerName ?? 'Unknown',
            showChevron: false,
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.download,
            title: 'Firmware Update',
            chipValue: device?.firmwareRevision ?? 'oo-1.0.9',
            copyValue: device?.firmwareRevision ?? 'oo-1.0.9',
            showChevron: true,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => FirmwareUpdate(
                    device: provider.pairedDevice,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1, color: Color(0xFF3C3C43)),
          _buildProfileStyleItem(
            icon: FontAwesomeIcons.microchip,
            title: 'Flash Custom Firmware',
            showChevron: true,
            onTap: () async {
              FilePickerResult? result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['zip'],
              );

              if (result != null && result.files.single.path != null) {
                String? selectedFilePath = result.files.single.path;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => FirmwareUpdate(
                      device: provider.pairedDevice,
                      zipFilePath: selectedFilePath,
                    ),
                  ),
                );
              }
            },
          ),
          if (provider.storageStats != null && provider.storageStats!.freeBytes > 0) ...[
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.microchip,
              title: 'Storage Free Space',
              chipValue: '${(provider.storageStats!.freeBytes / 1024 / 1024).toStringAsFixed(1)} MB',
              showChevron: false,
            ),
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.fileAudio,
              title: 'File Count',
              chipValue: '${provider.storageStats!.fileCount}',
              showChevron: false,
            ),
          ],
        ],
      ),
    );
  }

  void _showBrightnessSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
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
                    const Text(
                      'LED Brightness',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 24),
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.grey.shade800,
                        thumbColor: Colors.white,
                        overlayColor: Colors.white.withOpacity(0.1),
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12, elevation: 2),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
                        trackHeight: 6,
                      ),
                      child: Slider(
                        value: _dimRatio,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        label: '${_dimRatio.round()}%',
                        onChanged: (value) {
                          setSheetState(() => _dimRatio = value);
                          setState(() => _dimRatio = value);
                        },
                        onChangeEnd: _updateDimRatio,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Dim', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                        Text('Bright', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      ],
                    ),
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
                        Text(
                          'Mic Gain',
                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
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
                        overlayColor: Colors.white.withOpacity(0.1),
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
                          child: _buildPresetButton('Loud', 6, currentLevel, () {
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white.withOpacity(0.1) : const Color(0xFF2A2A2E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? Colors.white.withOpacity(0.5) : Colors.transparent, width: 1),
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
    );
  }

  String _getMicGainLabel(int level) {
    const labels = ['Mute', '-20dB', '-10dB', '+0dB', '+6dB', '+10dB', '+20dB', '+30dB', '+40dB'];
    return level >= 0 && level < labels.length ? labels[level] : '';
  }

  Widget _buildCustomizationSection() {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
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
            if (_isDimRatioLoaded && _hasDimmingFeature == true) const Divider(height: 1, color: Color(0xFF3C3C43)),
            _buildProfileStyleItem(
              icon: FontAwesomeIcons.microphone,
              title: 'Mic Gain',
              chipValue: _getMicGainLabel(_micGain.round()),
              onTap: _showMicGainSheet,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionsSection(DeviceProvider provider) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          if (provider.isConnected) ...[
            const Divider(height: 1, color: Color(0xFF3C3C43)),
            GestureDetector(
              onTap: () async {
                await SharedPreferencesUtil().btDeviceSet(BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0));
                SharedPreferencesUtil().deviceName = '';
                final pairedDeviceId = provider.pairedDevice!.id;
                // Use forgetDevice() to explicitly clear associations
                await ServiceManager.instance().device.forgetDevice(pairedDeviceId);

                // Explicitly tell native to stop managing this device (PR 6200 alignment)
                if (provider.pairedDevice != null) {
                  final BleHostApi hostApi = BleHostApi();
                  await hostApi.unmanageDevice(provider.pairedDevice!.id);
                }

                // Cancel any in-progress sync immediately.
                final walSync = ServiceManager.instance().wal.getSyncs();
                walSync.cancelSync();
                walSync.setDevice(null);
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
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: FaIcon(FontAwesomeIcons.linkSlash, color: Colors.redAccent, size: 20),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Unpair Device',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 17, fontWeight: FontWeight.w400),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDisconnectedOverlay() {
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
            child: Center(child: FaIcon(FontAwesomeIcons.linkSlash, color: Colors.grey.shade500, size: 24)),
          ),
          const SizedBox(height: 20),
          Text(
            'Device Not Connected',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect your Omi device to access\ndevice settings and customization',
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
            ),
            title: Text(
              'Device Settings',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
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
                  _buildDisconnectedOverlay(),
                  const SizedBox(height: 32),
                ],
                if (provider.isConnected) ...[
                  if (_isDimRatioLoaded && _hasDimmingFeature == true ||
                      _isMicGainLoaded && _hasMicGainFeature == true) ...[
                    const SizedBox(height: 16),
                    _buildSectionHeader('Customization'),
                    _buildCustomizationSection(),
                  ],
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
