import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'device_settings.dart';
import 'find_devices_page.dart';
import 'offline_audio_settings_page.dart';
import 'sync_page.dart';

class SettingsDrawer extends StatefulWidget {
  const SettingsDrawer({super.key});

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const SettingsDrawer(),
    );
  }
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  String? version;
  String? buildVersion;
  String? shortDeviceInfo;

  @override
  void initState() {
    super.initState();
    _loadAppAndDeviceInfo();
  }

  Future<String> _getShortDeviceInfo() async {
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        return '${androidInfo.brand} ${androidInfo.model} — Android ${androidInfo.version.release}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        return '${iosInfo.name} — iOS ${iosInfo.systemVersion}';
      } else {
        return 'Unknown Device';
      }
    } catch (e) {
      return 'Unknown Device';
    }
  }

  Future<void> _loadAppAndDeviceInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final shortDevice = await _getShortDeviceInfo();

      if (mounted) {
        setState(() {
          version = packageInfo.version;
          buildVersion = packageInfo.buildNumber.toString();
          shortDeviceInfo = shortDevice;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          shortDeviceInfo = 'Unknown Device';
        });
      }
    }
  }

  Widget _buildSettingsItem({
    required String title,
    required Widget icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 1),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: icon,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFF3C3C43),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionContainer({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: children,
      ),
    );
  }

  Widget _buildVersionInfoSection() {
    final displayText = buildVersion != null ? '${version ?? ""} ($buildVersion)' : (version ?? '');

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          displayText,
          style: const TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 13,
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: () async {
             await Clipboard.setData(ClipboardData(text: displayText));
             if (mounted) {
               ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
             }
          },
          child: const Icon(
            Icons.copy,
            size: 12,
            color: Color(0xFF8E8E93),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: const BoxDecoration(
        color: Color(0xFF000000),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 8),
            height: 4,
            width: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF3C3C43),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Stack(
              children: [
                const Center(
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Text(
                      'Done',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  _buildSectionContainer(
                    children: [
                      _buildSettingsItem(
                        title: 'Find Omi Devices',
                        icon: const FaIcon(FontAwesomeIcons.magnifyingGlass, color: Color(0xFF8E8E93), size: 20),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const FindDevicesPage(),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1, color: Color(0xFF3C3C43)),
                      _buildSettingsItem(
                        title: 'Sync Device',
                        icon: const FaIcon(FontAwesomeIcons.solidCloud, color: Color(0xFF8E8E93), size: 20),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const SyncPage(),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1, color: Color(0xFF3C3C43)),
                      _buildSettingsItem(
                        title: 'Offline Audio Processing',
                        icon: const FaIcon(FontAwesomeIcons.microphoneLines, color: Color(0xFF8E8E93), size: 20),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const OfflineAudioSettingsPage(),
                            ),
                          );
                        },
                      ),
                      Consumer<DeviceProvider>(
                        builder: (context, deviceProvider, child) {
                          if (!deviceProvider.isConnected) {
                            return const SizedBox.shrink();
                          }
                          return Column(
                            children: [
                              const Divider(height: 1, color: Color(0xFF3C3C43)),
                              _buildSettingsItem(
                                title: 'Device Settings',
                                icon: const FaIcon(FontAwesomeIcons.bluetooth, color: Color(0xFF8E8E93), size: 20),
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) => const DeviceSettings(),
                                    ),
                                  );
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  _buildVersionInfoSection(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
