import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'firmware_mixin.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/widgets/dialog.dart';
import 'firmware_update_dialog.dart';

class FirmwareUpdate extends StatefulWidget {
  final BtDevice? device;
  final bool isRollback;
  final String? zipFilePath;

  const FirmwareUpdate({super.key, this.device, this.isRollback = false, this.zipFilePath});

  @override
  State<FirmwareUpdate> createState() => _FirmwareUpdateState();
}

class _FirmwareUpdateState extends State<FirmwareUpdate> with FirmwareMixin {
  bool shouldUpdate = false;
  String updateMessage = '';
  bool isLoading = false;

  // Store reference to provider for safe disposal
  DeviceProvider? _deviceProvider;

  @override
  void initState() {
    var device = widget.device!;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      Provider.of<DeviceProvider>(context, listen: false).setOnFirmwareUpdatePage(true);
      setState(() {
        isLoading = true;
      });

      if (widget.zipFilePath != null) {
        if (mounted) {
          setState(() {
            shouldUpdate = true;
            updateMessage = 'Custom firmware selected';
            isLoading = false;
          });
        }
      } else if (widget.isRollback) {
        await getStableVersion(deviceModelNumber: device.modelNumber ?? '');
        if (mounted) {
          setState(() {
            shouldUpdate = latestFirmwareDetails.isNotEmpty && latestFirmwareDetails['version'] != null;
            updateMessage = shouldUpdate ? '' : 'No stable firmware found';
            isLoading = false;
          });
        }
      } else {
        await getLatestVersion(
          deviceModelNumber: device.modelNumber ?? '',
          firmwareRevision: device.firmwareRevision ?? '',
          hardwareRevision: device.hardwareRevision ?? '',
          manufacturerName: device.manufacturerName ?? '',
        );
        var result = await shouldUpdateFirmware(currentFirmware: widget.device!.firmwareRevision ?? '');
        if (mounted) {
          setState(() {
            shouldUpdate = result.$2;
            updateMessage = result.$1;
            isLoading = false;
          });
        }
      }
    });
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
  }

  @override
  void dispose() {
    killMcuUpdateManager();
    final provider = _deviceProvider;
    if (provider != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        provider.setOnFirmwareUpdatePage(false);
        provider.resetFirmwareUpdateState();
      });
    }
    super.dispose();
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

  Widget _buildVersionItem({
    required IconData icon,
    required String label,
    required String version,
    Color? iconColor,
    Color? chipColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: SizedBox(
              width: 24,
              height: 24,
              child: FaIcon(icon, color: iconColor ?? const Color(0xFF8E8E93), size: 18),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w400),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: chipColor ?? const Color(0xFF2A2A2E),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Text(
              version,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressSection() {
    final progress = isInstalling ? installProgress : downloadProgress;
    final statusText = isDownloading ? 'Downloading Firmware...' : 'Installing Firmware...';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                // Progress circle
                SizedBox(
                  width: 120,
                  height: 120,
                  child: Stack(
                    children: [
                      SizedBox(
                        width: 120,
                        height: 120,
                        child: CircularProgressIndicator(
                          value: progress / 100,
                          strokeWidth: 8,
                          backgroundColor: const Color(0xFF2A2A2E),
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                      Center(
                        child: Text(
                          '$progress%',
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  statusText,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Warning card
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF2A2215),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF4A3D1A)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const FaIcon(FontAwesomeIcons.triangleExclamation, color: Color(0xFFFFB800), size: 18),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Do not close the app or disconnect your device during the update process.',
                    style: TextStyle(color: Colors.orange.shade200, fontSize: 14, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(color: const Color(0xFF1A3D2E), borderRadius: BorderRadius.circular(40)),
                  child: const Center(child: FaIcon(FontAwesomeIcons.check, color: Color(0xFF4ADE80), size: 32)),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Firmware Updated',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your device will now restart. Please wait a few seconds before reconnecting.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.grey.shade400, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // Done button
        GestureDetector(
          onTap: () {
            final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
            deviceProvider.resetFirmwareUpdateState();
            Navigator.of(context).pop(); // Just pop back
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: const Center(
              child: Text(
                'Done',
                style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUpdateSection() {
    dynamic changelogData = latestFirmwareDetails['changelog'];
    bool hasChangelog = changelogData != null && changelogData is List && (List<String>.from(changelogData)).isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Up to date status (only when not needing update)
        if (!shouldUpdate) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Row(
              children: [
                Text(
                  widget.isRollback ? 'Already on Stable Firmware' : 'Your Device Is Up to Date',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                ),
                const SizedBox(width: 8),
                const FaIcon(FontAwesomeIcons.circleCheck, color: Color(0xFF4ADE80), size: 14),
              ],
            ),
          ),
        ],
        // Version cards
        Container(
          decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
          child: Column(
            children: [
              _buildVersionItem(
                icon: FontAwesomeIcons.microchip,
                label: 'Current Version',
                version: widget.device!.firmwareRevision ?? 'Unknown',
                chipColor: shouldUpdate ? const Color(0xFF3D2A2A) : null,
              ),
              if (shouldUpdate && widget.zipFilePath != null) ...[
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildVersionItem(
                  icon: FontAwesomeIcons.cloudArrowDown,
                  label: 'Custom Version',
                  version: widget.zipFilePath!.split('/').last,
                  chipColor: const Color(0xFF1A3D2E),
                ),
              ] else if (shouldUpdate && latestFirmwareDetails['version'] != null) ...[
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildVersionItem(
                  icon: FontAwesomeIcons.cloudArrowDown,
                  label: 'Latest Version',
                  version: '${latestFirmwareDetails['version']}',
                  chipColor: const Color(0xFF1A3D2E),
                ),
              ],
            ],
          ),
        ),

        // Changelog
        if (hasChangelog) ...[
          const SizedBox(height: 24),
          _buildSectionHeader('What\'s New'),
          Container(
            decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...(List<String>.from(changelogData)).map(
                    (change) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            margin: const EdgeInsets.only(top: 6),
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade500,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              change,
                              style: TextStyle(color: Colors.grey.shade300, fontSize: 15, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(height: 24),

        // Action buttons
        if (shouldUpdate) ...[
          // Update button
          GestureDetector(
            onTap: () async {
              var targetVersion = latestFirmwareDetails['version']?.toString() ?? '';
              if (targetVersion.startsWith('3.0.17')) {
                var confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => getDialog(
                    context,
                    () => Navigator.of(ctx).pop(false),
                    () => Navigator.of(ctx).pop(true),
                    'Important Warning',
                    'This firmware will reformat your SD card and erase all stored recordings. Please make sure you have synced everything before proceeding.',
                  ),
                );
                if (confirmed != true) return;
              }

              final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
              deviceProvider.setFirmwareUpdateInProgress(true);

              if (widget.zipFilePath != null) {
                await startDfu(widget.device!, zipFilePath: widget.zipFilePath);
              } else if (otaUpdateSteps.isEmpty) {
                await downloadFirmware();
                await startDfu(widget.device!);
              } else {
                showFirmwareUpdateSheet(
                  context: context,
                  steps: otaUpdateSteps,
                  onUpdateStart: () async {
                    await downloadFirmware();
                    await startDfu(widget.device!);
                  },
                );
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const FaIcon(FontAwesomeIcons.download, color: Colors.black, size: 16),
                  const SizedBox(width: 10),
                  Text(
                    widget.isRollback
                        ? 'Install Stable Firmware'
                        : widget.zipFilePath != null
                            ? 'Install Custom Firmware'
                            : otaUpdateSteps.isEmpty
                                ? 'Install Update'
                                : 'Update Now',
                    style: const TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ],

        // Help link
        if (!shouldUpdate) ...[
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () async {
              // await IntercomManager.instance.displayFirmwareUpdateArticle();
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(14)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FaIcon(FontAwesomeIcons.circleQuestion, color: Colors.grey.shade400, size: 16),
                  const SizedBox(width: 10),
                  Text(
                    'Update Guide',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLoadingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          widget.isRollback ? 'Stable Firmware' : 'Checking for Updates',
          subtitle: 'Please Wait',
        ),
        Container(
          decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Center(
              child: Column(
                children: [
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    widget.isRollback ? 'Fetching Stable Firmware...' : 'Checking firmware version...',
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !isDownloading && !isInstalling,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          elevation: 0,
          leading: (isDownloading || isInstalling)
              ? const SizedBox()
              : IconButton(
                  icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
          title: Text(
            widget.isRollback ? 'Stable Firmware' : 'Firmware Update',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: isLoading
                ? _buildLoadingSection()
                : isDownloading || isInstalling
                    ? _buildProgressSection()
                    : isInstalled
                        ? _buildSuccessSection()
                        : _buildUpdateSection(),
          ),
        ),
      ),
    );
  }
}
