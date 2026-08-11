import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/dfuota/firmware_mixin.dart';
import 'package:omi/pages/recordings/recordings_page.dart';
import 'package:omi/pages/settings/find_devices_page.dart';
import 'package:omi/providers/device_provider.dart';
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
    cancelPostFlashReconnect();
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
                // The bundle holds one image per core (app + net), and the percentage
                // above now runs once across both. Naming the part explains why the
                // bar slows at the hand-off instead of leaving it looking stuck.
                if (isInstalling && installImageCount > 1) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Part ${installImageIndex + 1} of $installImageCount',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                  ),
                ],
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
    // Watched, not read once. The re-pair happens in the Android system pairing
    // dialog, which the user can accept while this very page is on screen — so the
    // reconnect arrives with nothing here having been tapped, and the section has to
    // repaint on the provider's word alone. Scoped to this section rather than the
    // whole page so a running install isn't rebuilt by every unrelated notification
    // the provider emits (battery, sync progress).
    //
    // Bare `isConnected`, not a match against widget.device.id: the app carries one
    // Omi at a time, and after a flash it is this one — the DFU does not change its
    // address.
    return Consumer<DeviceProvider>(
      builder: (context, deviceProvider, _) {
        final isReconnected = deviceProvider.isConnected;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              // Explicitly full width: the parent Column is crossAxisAlignment.start, so
              // without this the card shrink-wraps its content and sits narrower than the
              // repair-instructions card below it (whose Row/Expanded forces full width).
              width: double.infinity,
              decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration:
                          BoxDecoration(color: const Color(0xFF1A3D2E), borderRadius: BorderRadius.circular(40)),
                      child: const Center(child: FaIcon(FontAwesomeIcons.check, color: Color(0xFF4ADE80), size: 32)),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Firmware updated!',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isReconnected
                          ? 'Your ${widget.device?.name ?? "Omi device"} is paired again and connected.'
                          : 'Your ${widget.device?.name ?? "Omi device"} is restarting to finish the update.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, color: Colors.grey.shade400, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Once the pairing request has been accepted there is nothing left to
            // instruct — leaving "You need to pair again" up in front of a connected
            // device would be telling the user to redo what they just did.
            isReconnected ? _buildReconnectedNotice() : _buildRepairInstructions(),
            const SizedBox(height: 24),
            // Done button — Material+InkWell so the tap shows a ripple inside the rounded corners.
            Material(
              color: Colors.transparent,
              child: Ink(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    deviceProvider.resetFirmwareUpdateState();
                    // Reset to home first: replacing the whole stack with anything else
                    // would leave that page as root with nothing to pop back to. The
                    // navigator is captured up front because the stack reset unmounts
                    // this page's context.
                    final navigator = Navigator.of(context);
                    navigator.pushAndRemoveUntil(_pageRoute(const RecordingsPage()), (route) => false);
                    // The update cleared the pairing on both sides, so re-pairing is
                    // normally the next step — land the user on the scan list rather
                    // than on a home screen showing a device that can no longer
                    // connect. Unless it already happened: if the pairing request was
                    // accepted while this page was up, the scan list is a page the
                    // user cannot act on (every route into it is gated on being
                    // disconnected, and it closes itself on connect), so pushing it
                    // would only make them dismiss it. Home is the destination then.
                    if (!isReconnected) {
                      navigator.push(_pageRoute(const FindDevicesPage()));
                    }
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
      },
    );
  }

  /// Replaces the re-pair instructions once the device is back on the link — same
  /// slot, so the page doesn't reflow when the reconnect lands mid-read.
  Widget _buildReconnectedNotice() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A2E)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FaIcon(FontAwesomeIcons.circleCheck, color: Color(0xFF4ADE80), size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Paired again',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Nothing else to do — tap Done to get back to your recordings.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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

  /// Same platform-styled route `routeToPage` builds, but usable against a
  /// NavigatorState captured before the stack reset (see the Done button).
  Route<void> _pageRoute(Widget page) =>
      Platform.isIOS ? CupertinoPageRoute<void>(builder: (c) => page) : MaterialPageRoute<void>(builder: (c) => page);

  // Shown after a successful update. Every successful DFU clears the BLE pairing on
  // both sides — the device wipes its own key slot on the reboot that follows the
  // flash, and the app wipes the phone's (Android only; iOS has no programmatic bond
  // removal, so there the user has to clear it by hand, hence the extra step). So
  // re-pairing is not an "if something went wrong" fallback here, it is the normal
  // next step, and it is why Done opens the scan list.
  Widget _buildRepairInstructions() {
    // On Android the app waits for the Omi to start advertising again and then
    // reconnects on its own (FirmwareMixin._reconnectWhenDeviceReturns), so the
    // pairing request arrives without the user doing anything — the manual route is
    // the fallback for when that window expires. iOS cannot clear its own bond, so
    // there the user has to forget the device first and the manual route is the only
    // one.
    final steps = <String>[
      'Wait a few seconds for your Omi to finish restarting.',
      if (Platform.isIOS) ...[
        'On your phone: open Settings → Bluetooth, tap the ⓘ next to your Omi, and choose "Forget This Device".',
        'Tap Done below, then tap your Omi in the list to pair with it again.',
      ] else ...[
        'Accept the pairing request when it appears — your Omi reconnects on its own.',
        'If it doesn\'t appear, tap Done below and tap your Omi in the list to pair with it again.',
      ],
    ];
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
                    'You need to pair again',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              // Platform-split for the same reason the steps are: on Android the app
              // reconnects by itself once it hears the Omi advertising again, so
              // "it will not reconnect on its own" — true on iOS, where the bond can
              // only be cleared by hand — would contradict the step right below it.
              Platform.isIOS
                  ? 'The update cleared the Bluetooth pairing between your Omi and this phone, so it will not '
                      'reconnect on its own. Pair it again to finish:'
                  : 'The update cleared the Bluetooth pairing between your Omi and this phone. The app '
                      'reconnects as soon as your Omi is back, so all that is left is to accept the pairing '
                      'request:',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < steps.length; i++) _buildRepairStep(i + 1, steps[i]),
            Text(
              'Omi not in the list? Give it another few seconds and tap the refresh icon. If it still won\'t '
              'pair, tap the button on your Omi 5 times, holding the last tap for 10 seconds, to clear its '
              'pairing, then scan again.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13, height: 1.4),
            ),
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

              if (widget.localZipPath != null) {
                await startDfu(widget.device!, zipFilePath: widget.localZipPath);
              } else {
                await downloadFirmware();
                await startDfu(widget.device!);
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
