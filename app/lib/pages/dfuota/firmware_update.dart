import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/dfuota/firmware_mixin.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/widgets/dialog.dart';

class FirmwareUpdate extends StatefulWidget {
  final BtDevice? device;
  final bool isRollback;
  final String? localZipPath;

  const FirmwareUpdate({super.key, this.device, this.isRollback = false, this.localZipPath});

  @override
  State<FirmwareUpdate> createState() => _FirmwareUpdateState();
}

class _FirmwareUpdateState extends State<FirmwareUpdate> with FirmwareMixin {
  bool shouldUpdate = false;
  String updateMessage = '';
  bool isLoading = false;

  // Android-only: after a *successful* flash, clear the phone's BLE bond so a
  // pairing the OTA resets doesn't strand the reconnect (the fresh re-pair
  // re-keys the omi too). A failed flash leaves the pairing untouched. Mirrors
  // the pref; hidden on iOS (no programmatic bond removal there).
  bool _wipeBonds = SharedPreferencesUtil().wipeBondsOnFirmwareUpdate;

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

      if (widget.localZipPath != null) {
        // Offline / Local file update flow
        final zipVersion = await extractVersionFromZipPath(widget.localZipPath!);
        if (mounted) {
          setState(() {
            shouldUpdate = true;
            updateMessage = 'Local firmware file ready to flash.';
            latestFirmwareDetails = {
              'version': zipVersion ?? 'Local File',
              'is_legacy_secure_dfu': false, // Ensure we use MCUmgr (Zephyr SMP)
            };
            isLegacySecureDFU = false;
            isLoading = false;
          });
        }
      } else if (widget.isRollback) {
        await getStableVersion(deviceModelNumber: device.modelNumber ?? 'Unknown');
        if (mounted) {
          setState(() {
            shouldUpdate = latestFirmwareDetails.isNotEmpty && latestFirmwareDetails['version'] != null;
            updateMessage = shouldUpdate ? '' : 'No stable firmware found';
            isLoading = false;
          });
        }
      } else {
        await getLatestVersion(
          deviceModelNumber: device.modelNumber ?? 'Unknown',
          firmwareRevision: device.firmwareRevision ?? 'Unknown',
          hardwareRevision: device.hardwareRevision ?? 'Unknown',
          manufacturerName: device.manufacturerName ?? 'Unknown',
        );
        var result = await shouldUpdateFirmware(currentFirmware: widget.device!.firmwareRevision ?? 'Unknown');
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
    // Backstop: release the OTA screen/CPU wakelocks in case a terminal DFU
    // callback didn't fire (e.g. an MCU update failure has no explicit handler).
    releaseUpdateWakelocks();
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
    final statusText = isDownloading ? 'Downloading firmware...' : 'Installing firmware...';

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
                    'Do not turn off your device or close the app during the update.',
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
                  'Firmware updated!',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please restart your ${widget.device?.name ?? "Omi device"} to complete the update.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.grey.shade400, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildRepairInstructions(),
        const SizedBox(height: 24),
        // Done button — Material+InkWell so the tap shows a ripple inside the rounded corners.
        Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
                deviceProvider.resetFirmwareUpdateState();
                routeToPage(context, const RecordingsPage(), replace: true);
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: const Center(
                  child: Text(
                    'Done',
                    style: TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRepairStep(int number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(color: Color(0xFF2A2A2E), shape: BoxShape.circle),
            child: Center(
              child: Text(
                '$number',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.grey.shade300, fontSize: 14, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  // Shown after a successful update: an OTA can reset the device's BLE pairing, so if
  // the firmware bond no longer matches the phone's, the device won't reconnect until
  // the old pairing is cleared on BOTH sides. Phrased conditionally — most updates do
  // not need this, and iOS can't clear the bond programmatically anyway.
  Widget _buildRepairInstructions() {
    final phoneStep = Platform.isIOS
        ? 'On your phone: open Settings → Bluetooth, tap the ⓘ next to your Omi, and choose "Forget This Device".'
        : 'On your phone: open Bluetooth settings, find your Omi, and choose Forget / Unpair.';
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A2E)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                FaIcon(FontAwesomeIcons.key, color: Color(0xFF8E8E93), size: 16),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Trouble reconnecting after the update?',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'An update can reset the device\'s pairing. If your Omi won\'t reconnect, clear the old '
              'pairing on both sides, then reconnect:',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 16),
            _buildRepairStep(
                1, 'On your Omi: tap the button 5 times, holding the last tap for 10 seconds, to clear its pairing.'),
            _buildRepairStep(2, phoneStep),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateSection() {
    dynamic changelogData = latestFirmwareDetails['changelog'];
    bool hasChangelog = changelogData != null && changelogData is List && (List<String>.from(changelogData)).isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Error banner shown after a failed/stalled install attempt; the update
        // button below lets the user retry.
        if (installErrorMessage != null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF3D2A2A),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF5A2D2D)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const FaIcon(FontAwesomeIcons.circleExclamation, color: Color(0xFFFF6B6B), size: 18),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      installErrorMessage!,
                      style: TextStyle(color: Colors.red.shade200, fontSize: 14, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        // Up to date status (only when not needing update)
        if (!shouldUpdate) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Row(
              children: [
                Text(
                  widget.isRollback ? 'Your device is already on stable firmware.' : 'Your device is up to date.',
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
                label: 'Current version',
                version: widget.device!.firmwareRevision ?? 'Unknown',
                chipColor: shouldUpdate ? const Color(0xFF3D2A2A) : null,
              ),
              if (shouldUpdate && latestFirmwareDetails['version'] != null) ...[
                const Divider(height: 1, color: Color(0xFF3C3C43)),
                _buildVersionItem(
                  icon: FontAwesomeIcons.cloudArrowDown,
                  label: 'Update to',
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
          _buildSectionHeader('What\'s new'),
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
          // Android-only: clear the pairing on both sides during the flash so
          // the device reconnects cleanly afterward. iOS can't remove a bond
          // programmatically, so the toggle is hidden there.
          if (Platform.isAndroid) ...[
            Container(
              decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(14)),
              child: SwitchListTile(
                value: _wipeBonds,
                onChanged: (v) {
                  setState(() => _wipeBonds = v);
                  SharedPreferencesUtil().wipeBondsOnFirmwareUpdate = v;
                },
                title: const Text('Reset pairing after update',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                subtitle: Text(
                  'After a successful update, resets the Bluetooth pairing so your Omi reconnects cleanly '
                  '(you may need to reconnect once). A failed update leaves the pairing untouched.',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13, height: 1.3),
                ),
                activeThumbColor: const Color(0xFF4ADE80),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
            ),
            const SizedBox(height: 16),
          ],
          // Update button
          GestureDetector(
            onTap: () async {
              // Capture the provider before the confirm-dialog await so it isn't
              // referenced via `context` across an async gap.
              final deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
              var targetVersion = latestFirmwareDetails['version']?.toString() ?? '';
              if (targetVersion.startsWith('3.0.17')) {
                var confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => getDialog(
                    context,
                    () => Navigator.of(ctx).pop(false),
                    () => Navigator.of(ctx).pop(true),
                    'Firmware Warning',
                    'This update will format your device memory. Please make sure all your recordings are synced before proceeding.',
                    confirmText: 'Continue Anyway',
                    cancelText: 'Cancel',
                  ),
                );
                if (confirmed != true) return;
              }

              deviceProvider.setFirmwareUpdateInProgress(true);

              final wipeBonds = Platform.isAndroid && _wipeBonds;
              if (widget.localZipPath != null) {
                await startDfu(widget.device!, zipFilePath: widget.localZipPath, wipeBonds: wipeBonds);
              } else {
                await downloadFirmware();
                await startDfu(widget.device!, wipeBonds: wipeBonds);
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

        // Help link removed since Intercom is missing
      ],
    );
  }

  Widget _buildLoadingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(
          widget.isRollback ? 'Stable Firmware' : 'Checking for updates...',
          subtitle: 'Please wait',
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
                    widget.isRollback ? 'Fetching stable firmware...' : 'Checking firmware version...',
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
                  tooltip: 'Back',
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
