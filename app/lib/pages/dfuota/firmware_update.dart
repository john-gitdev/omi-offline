import 'dart:async';
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

  /// The stack this screen leaves behind when the user goes, bottom first.
  ///
  /// Home is always the base: the update reset the pairing, so keeping the screens
  /// the user came in through would leave them pointed at a device that no longer
  /// answers on the old key. The scan list goes on top only while the re-pair has
  /// *not* happened — once it has, that page is one the user cannot act on (every
  /// route into it is gated on being disconnected, and it closes itself on connect),
  /// so pushing it would only make them dismiss it.
  ///
  /// Reached by every exit — Done, the manual escape hatch, and an intercepted back
  /// press — through [_FirmwareUpdateState._leaveUpdateScreen]. Split out from them so
  /// the branch can be asserted without standing up either destination page.
  @visibleForTesting
  static List<Widget> postUpdateDestinations({required bool isReconnected}) => [
        const RecordingsPage(),
        if (!isReconnected) const FindDevicesPage(),
      ];

  @override
  State<FirmwareUpdate> createState() => _FirmwareUpdateState();
}

class _FirmwareUpdateState extends State<FirmwareUpdate> with FirmwareMixin {
  bool shouldUpdate = false;
  String updateMessage = '';
  bool isLoading = false;

  // Store reference to provider for safe disposal
  DeviceProvider? _deviceProvider;

  // Latches for [_hasRepaired] — set there and nowhere else. The first records the
  // pre-DFU link being seen down; the second records the re-pair, once and for good.
  bool _preFlashLinkGone = false;
  bool _repairLatched = false;

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

  /// Whether `isConnected` can be read as *re-paired*, rather than as the tail of the
  /// link the flash has just invalidated.
  ///
  /// The connection state alone cannot answer that. The success callback kicks off
  /// `releasePairingOnSuccess` unawaited and flips `isInstalled` in the same
  /// synchronous block, so this screen's first frame is drawn before the release has
  /// closed anything — and the disconnect it causes reaches the provider a debounce
  /// later again. Native's own retry ladder may also have re-established the pre-DFU
  /// link during the flash, which is the whole reason the release exists. Read bare,
  /// such a link announces "Paired again" over a pairing that is seconds from being
  /// wiped, and Done then drops the Find Devices fallback — while this page's dispose
  /// cancels the rediscovery loop on the way out, so nothing is left trying to
  /// reconnect at all.
  ///
  /// So require the transition, not the state: the old link has to be seen down
  /// before a live one counts as the new one. Nothing needs to arrive for that in the
  /// ordinary case — the device rebooted during the flash, so `isConnected` is
  /// already false when this screen first builds and the latch closes on that frame.
  ///
  /// Latching from inside build is safe here because neither latch can affect the
  /// frame it runs in: `_preFlashLinkGone` is only set on the branch that returns
  /// false, and `_repairLatched` only on the branch that returns true — in both cases
  /// what an unlatched read would have returned anyway. They change later frames only,
  /// and every later frame comes from a provider notification that rebuilds this
  /// Consumer regardless. It also fails in the recoverable direction — a disconnect
  /// that never reaches Dart at all (`unmanageDevice` no-ops for a device already
  /// unmanaged) leaves the latch open, which keeps the instructions and the fallback
  /// up.
  ///
  /// **And once observed, the re-pair never un-observes.** `isConnected` is expected to
  /// flap moments after the re-pair, by design and on the commonest path of all: a
  /// flash that changes the firmware revision changes the GATT fingerprint, so setup's
  /// deferred block calls `recycleConnection()` (DeviceProvider) to drop Android's
  /// stale attribute cache — a soft disconnect, up to a 5 s wait, then a fresh link.
  /// Read live, that walks the screen back from "Paired again" to "waiting for your
  /// Omi" and then forward again, in front of a user who is now being asked to wait
  /// here for exactly that signal. The pairing did happen; a deliberate recycle is not
  /// its undoing, so the latch is one-way.
  bool _hasRepaired(bool isConnected) {
    if (_repairLatched) return true;
    if (!isConnected) {
      _preFlashLinkGone = true;
      return false;
    }
    if (!_preFlashLinkGone) return false;
    _repairLatched = true;
    _onRepairLatched();
    return true;
  }

  /// Fired once, on the frame the re-pair is first observed.
  ///
  /// **Stop looking.** The link is up; another scan can only disturb it, and the loop
  /// would otherwise keep going until its window expires (or issue a redundant connect
  /// on its next sighting) for a device that is already here. Safe to call from build:
  /// it is a bare field write with no notification behind it.
  ///
  /// **`isFirmwareUpdateInProgress` is deliberately NOT cleared here.** It gates
  /// background sync and `scanAndConnectToDevice`, and clearing it on the latch looks
  /// free — the flash is over, and the user may now sit on this screen for minutes with
  /// sync blocked. It is not free, because of *when* the latch closes.
  /// `_onDeviceConnected` flips `isConnected` early (right after `setConnectedDevice`),
  /// and everything that matters comes after: `wal.setDevice`, the GATT fingerprint,
  /// and then the deferred `recycleConnection()` that drops Android's stale attribute
  /// table — the refresh that exists precisely because a flash just changed the
  /// firmware. That deferred block yields to a sync in flight ("deferred, not
  /// dropped"), so a sync starting inside the setup window costs this connect its
  /// refresh. And two triggers can start one the moment the flag goes:
  /// `_onBackgroundSyncRequested` (the native alarm/WorkManager, which fires whatever
  /// the foreground state, and which `prepareDFU` does not cancel) and `onAppResumed`.
  /// Clearing it when the user LEAVES — dispose and `_leaveUpdateScreen`, as before —
  /// costs a few minutes of blocked background sync while they look at a success
  /// screen, which is the cheaper side by a wide margin.
  ///
  /// `_isOnFirmwareUpdatePage` likewise stays set until dispose: it is what exempts
  /// this link from `_handleDeviceConnected`'s background-drop guard and from the
  /// pause-disconnect, and the page is still up.
  ///
  /// **Repaint the page, not just this section.** The latch is read from inside the
  /// `Consumer`, which a provider notification rebuilds on its own — but
  /// [_backLeavesNothingReconnecting] is evaluated up in [build], which that
  /// notification does NOT re-run. Without a `setState` here `canPop` keeps the value it
  /// had before the re-pair, so back stays redirected to Find Devices for a user who is
  /// already connected, until some unrelated `setState` happens to rebuild the page.
  ///
  /// Deferred to a post-frame callback because the `setState` runs from inside a build.
  void _onRepairLatched() {
    cancelPostFlashReconnect();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Widget _buildSuccessSection() {
    // Watched, not read once. The re-pair happens in the Android system pairing
    // dialog, which the user can accept while this very page is on screen — so the
    // reconnect arrives with nothing here having been tapped, and the section has to
    // repaint on the provider's word alone. Scoped to this section rather than the
    // whole page so a running install isn't rebuilt by every unrelated notification
    // the provider emits (battery, sync progress).
    //
    // Not matched against widget.device.id: the app carries one Omi at a time, and
    // after a flash it is this one — the DFU does not change its address. What the
    // link state is matched against is *when* it came up; see [_hasRepaired].
    return Consumer<DeviceProvider>(
      builder: (context, deviceProvider, _) {
        final isReconnected = _hasRepaired(deviceProvider.isConnected);
        // The latch outranks the phase everywhere, in both directions. The loop can
        // still be mid-scan when the link comes up by another route (native's own
        // ladder, or a user tap in the system dialog arriving during a scan), and it
        // can equally have given up seconds before a slow pairing completes. What the
        // phase describes is what *we* are doing; only the latch says the Omi is back.
        //
        // Collapsed to `idle` rather than to a fourth flag, because that is what idle
        // already means everywhere else on this screen: there is nothing to wait for.
        final phase = isReconnected ? PostFlashPhase.idle : postFlashPhase;
        final isWatching = phase == PostFlashPhase.waiting ||
            phase == PostFlashPhase.connecting ||
            phase == PostFlashPhase.reconnecting;
        final hasGivenUp = phase == PostFlashPhase.timedOut;
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
                      _successSubtitle(isReconnected: isReconnected, phase: phase),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, color: Colors.grey.shade400, height: 1.4),
                    ),
                    // Only once the re-pair has landed, and only when the device tells
                    // us something new. See [_firmwareRevisionNowRunning].
                    if (isReconnected) ...[
                      if (_firmwareRevisionNowRunning(deviceProvider) case final revision?) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A3D2E),
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text(
                            'Now running $revision',
                            style: const TextStyle(color: Color(0xFF4ADE80), fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Once the pairing request has been accepted there is nothing left to
            // instruct — leaving "You need to pair again" up in front of a connected
            // device would be telling the user to redo what they just did. And once the
            // loop has given up, the instructions describe a wait that is over.
            if (isReconnected)
              _buildReconnectedNotice()
            else if (hasGivenUp)
              _buildSearchAgainNotice()
            else
              _buildRepairInstructions(isWatching: isWatching),
            const SizedBox(height: 24),
            _buildPrimaryAction(deviceProvider,
                phase: phase, isReconnected: isReconnected, isWatching: isWatching, hasGivenUp: hasGivenUp),
            // The escape hatch, and the reason waiting can be made the default without
            // trapping anyone: it is present in every state the loop can be in,
            // including a wedged one, and it goes exactly where Done used to.
            if (isWatching || hasGivenUp) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _leaveUpdateScreen(deviceProvider, isReconnected: false),
                child: Text(
                  'Pair manually instead',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// What the success card says under "Firmware updated!".
  ///
  /// [PostFlashPhase.idle] keeps the original wording: it is what iOS reads (no
  /// rediscovery loop is armed there) and what a not-yet-armed Android frame reads for
  /// the instant before [FirmwareMixin.releasePairingOnSuccess] runs.
  String _successSubtitle({required bool isReconnected, required PostFlashPhase phase}) {
    final name = widget.device?.name ?? 'Omi device';
    if (isReconnected) return 'Your $name is paired again and connected.';
    switch (phase) {
      case PostFlashPhase.waiting:
        return 'Your $name is restarting. Waiting for it to come back — you can stay on this screen.';
      case PostFlashPhase.connecting:
        return 'Found your $name. Accept the pairing request if your phone asks.';
      case PostFlashPhase.reconnecting:
        return 'Pairing with your $name...';
      case PostFlashPhase.timedOut:
        return 'Your $name has not come back on its own yet.';
      case PostFlashPhase.idle:
        return 'Your $name is restarting to finish the update.';
    }
  }

  /// The firmware revision to show as proof the flash took, or null to show nothing.
  ///
  /// Read from `pairedDevice`, which `_onDeviceConnected` refreshes from DIS on the
  /// re-paired link — deliberately not from `widget.device`, which is the pre-flash
  /// object this page was pushed with.
  ///
  /// **Silent unless it changed, because a stale read is indistinguishable from a
  /// current one.** `getDeviceInfo()` falls back to the device it was handed when the
  /// DIS read fails, and on a reconnect that device can have come from the stored
  /// `btDevice` pref — which still carries the version we just flashed OVER. Rendering
  /// that would claim the update did not take, in the one place a user looks to check
  /// that it did. A same-version reflash therefore shows nothing at all, which is the
  /// safe direction: the flash is already reported by the screen it is written on.
  String? _firmwareRevisionNowRunning(DeviceProvider deviceProvider) {
    final revision = deviceProvider.pairedDevice?.firmwareRevision;
    if (revision == null || revision.isEmpty) return null;
    if (revision == widget.device?.firmwareRevision) return null;
    return revision;
  }

  /// The one primary button, in its three shapes.
  ///
  /// Waiting is the only state with no primary action, and it is deliberately a
  /// disabled button rather than an absent one: the slot keeps its height, so the
  /// screen does not jump when the re-pair lands, and the label is where the wait
  /// reports itself. Nobody is stuck in it — "Pair manually instead" sits underneath in
  /// exactly the states this is disabled in.
  Widget _buildPrimaryAction(
    DeviceProvider deviceProvider, {
    required PostFlashPhase phase,
    required bool isReconnected,
    required bool isWatching,
    required bool hasGivenUp,
  }) {
    if (isWatching) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(14)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child:
                  CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.grey.shade500)),
            ),
            const SizedBox(width: 12),
            Text(
              // The caller's latch-aware phase, not the raw field: everything else on this
              // screen already defers to the latch, and reading the field here would be
              // the one place that could disagree with it.
              phase == PostFlashPhase.waiting ? 'Waiting for your Omi...' : 'Pairing...',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    final label = hasGivenUp ? 'Search again' : 'Done';
    // Material+InkWell so the tap shows a ripple inside the rounded corners.
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            if (hasGivenUp) {
              final device = widget.device;
              if (device != null) unawaited(retryPostFlashReconnect(device));
              return;
            }
            _leaveUpdateScreen(deviceProvider, isReconnected: isReconnected);
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                label,
                style: const TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Leave for [FirmwareUpdate.postUpdateDestinations]. The single exit: Done, the
  /// manual escape hatch, and an intercepted back press all come through here, so
  /// there is one description of where this screen lets go of the user.
  void _leaveUpdateScreen(DeviceProvider deviceProvider, {required bool isReconnected}) {
    deviceProvider.resetFirmwareUpdateState();
    // The navigator is captured up front because the stack reset below unmounts this
    // page's context.
    final navigator = Navigator.of(context);
    final destinations = FirmwareUpdate.postUpdateDestinations(isReconnected: isReconnected);
    // The first goes on as the new root — replacing the whole stack with a later one
    // would leave it with nothing to pop back to.
    navigator.pushAndRemoveUntil(_pageRoute(destinations.first), (route) => false);
    for (final destination in destinations.skip(1)) {
      navigator.push(_pageRoute(destination));
    }
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

  /// Replaces the re-pair instructions once the rediscovery window has expired: they
  /// describe a wait that is no longer happening, and their first step ("wait a few
  /// seconds") is the one thing that has demonstrably not worked.
  ///
  /// Expiring is not a failure of the update — the firmware is flashed and the device's
  /// key slot is free. It is a failure to *find* the device, which has ordinary causes
  /// (it is out of range, it went flat, the pairing request was dismissed), so the copy
  /// names those rather than implying the flash went wrong.
  Widget _buildSearchAgainNotice() {
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
                FaIcon(FontAwesomeIcons.magnifyingGlass, color: Color(0xFF8E8E93), size: 16),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Could not find your Omi',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The update itself is done. The app listened for a couple of minutes and your Omi did not come '
              'back on the air — it may be out of range, off, or waiting on a pairing request that was '
              'dismissed. Bring it close and search again.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              'Still nothing? Tap the button on your Omi 5 times, holding the last tap for 10 seconds, to '
              'clear its pairing, then pair manually.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13, height: 1.4),
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
  Widget _buildRepairInstructions({required bool isWatching}) {
    // [isWatching], not Platform.isAndroid: what decides whether there is anything to
    // wait for is whether a rediscovery loop is actually running, and that is exactly
    // what the phase reports. iOS never arms one (there is no programmatic bond removal
    // to arm it for), so it reads this as false and gets the manual route — and so does
    // the sliver of a frame on Android before releasePairingOnSuccess arms the loop,
    // which is the honest answer for that frame too.
    final steps = <String>[
      'Wait a few seconds for your Omi to finish restarting.',
      if (!isWatching) ...[
        if (Platform.isIOS)
          'On your phone: open Settings → Bluetooth, tap the ⓘ next to your Omi, and choose "Forget This Device".',
        'Tap Done below, then tap your Omi in the list to pair with it again.',
      ] else ...[
        'Accept the pairing request when it appears — your Omi reconnects on its own.',
        'Stay on this screen; it updates by itself the moment your Omi is back.',
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
              !isWatching
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
              isWatching
                  ? 'Rather do it yourself? "Pair manually instead" below opens the device list, where tapping '
                      'your Omi pairs it the same way.'
                  : 'Omi not in the list? Give it another few seconds and tap the refresh icon. If it still '
                      'won\'t pair, tap the button on your Omi 5 times, holding the last tap for 10 seconds, to '
                      'clear its pairing, then scan again.',
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

  /// Whether a back press should be redirected to the manual re-pair rather than
  /// popping.
  ///
  /// The plain pop goes back to Device Settings — a page about a device that, right
  /// now, is not paired with this phone — and takes the rediscovery loop down with it
  /// (dispose cancels it), leaving nothing at all trying to reconnect. That was
  /// tolerable while Done was the obvious action and back was the odd one out. It is
  /// not tolerable now that the screen asks the user to wait, because waiting is
  /// exactly when a back press means "I don't want to wait", and the answer to that is
  /// the device list, not a dead end.
  ///
  /// Narrow on purpose: only after a flash, only while the re-pair has not landed, and
  /// only when a loop was actually armed ([PostFlashPhase.idle] covers iOS and the
  /// pre-flash screen, where back keeps its ordinary meaning).
  bool get _backLeavesNothingReconnecting => isInstalled && !_repairLatched && postFlashPhase != PostFlashPhase.idle;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !isDownloading && !isInstalling && !_backLeavesNothingReconnecting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // A download/install in flight is a hard no — that block predates this and must
        // stay one, since leaving mid-flash can brick the device.
        if (!_backLeavesNothingReconnecting) return;
        final provider = _deviceProvider;
        if (provider != null) _leaveUpdateScreen(provider, isReconnected: false);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          elevation: 0,
          leading: (isDownloading || isInstalling)
              ? const SizedBox()
              // maybePop, not pop: only maybePop consults the route's pop disposition,
              // so a plain pop here would walk straight past the PopScope above and out
              // of the screen the wait depends on. The system back gesture already goes
              // through maybePop; this makes the button agree with it.
              : IconButton(
                  icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
                  onPressed: () => Navigator.maybePop(context),
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
