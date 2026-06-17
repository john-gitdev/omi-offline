import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:provider/provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/logger.dart';

class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({super.key});

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  late int _backgroundSyncIntervalMinutes;
  late bool _use24HourTime;
  late String _audioSaveFormat;
  late int _keepRecordingsDays;
  late bool _uploadOnWifiOnly;
  late int _filterMinDurationSeconds;
  late bool _companionDeviceEnabled;

  static const List<int> _kShortRecordingOptions = [0, 10, 30, 60, 120, 300, 600, 1800];

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _backgroundSyncIntervalMinutes = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    _use24HourTime = SharedPreferencesUtil().use24HourTime;
    _audioSaveFormat = SharedPreferencesUtil().audioSaveFormat;
    _keepRecordingsDays = SharedPreferencesUtil().keepRecordingsDays;
    _uploadOnWifiOnly = SharedPreferencesUtil().uploadOnWifiOnly;
    _filterMinDurationSeconds = SharedPreferencesUtil().filterMinDurationSeconds;
    _companionDeviceEnabled = SharedPreferencesUtil().companionDeviceEnabled;
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  static String _formatShortDuration(int seconds) {
    if (seconds == 0) return 'Off';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    return '${seconds ~/ 3600}h';
  }

  Future<void> _handleCleanUp() async {
    final controller = context.read<RecordingsController>();
    final count = controller.countShortRecordings(_filterMinDurationSeconds);
    if (count == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No recordings found matching the current filter.')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete short recordings?', style: TextStyle(color: Colors.white)),
        content: Text(
          'This will permanently delete $count short recording${count == 1 ? '' : 's'} and "ghost" records shorter than ${_formatShortDuration(_filterMinDurationSeconds)}. This cannot be undone.',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete All', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await controller.deleteShortRecordings(_filterMinDurationSeconds);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted $count short recording${count == 1 ? '' : 's'}.')),
        );
      }
    }
  }

  // Companion Device Pairing applies immediately — it has side effects (a
  // disconnect/reconnect, and the system pairing chooser when enabling), so it sits
  // outside the page's save/discard flow. OFF: reconnect so native manageDevice clears
  // the association now. ON: disconnect (so the Omi advertises), pop the system
  // companion chooser, then reconnect. Both directions need the disconnect first —
  // ensureConnection(force) is a no-op while connected (so manageDevice wouldn't re-run),
  // and a connected Omi (MAX_CONN=1) isn't advertising for the chooser to find.
  Future<void> _setCompanionDevicePairing(bool value) async {
    setState(() => _companionDeviceEnabled = value);
    SharedPreferencesUtil().companionDeviceEnabled = value;

    final deviceId = SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) return; // no paired device — applies on next connect

    final deviceService = ServiceManager.instance().device;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(value ? 'Enabling companion pairing…' : 'Disabling companion pairing…'),
    ));

    try {
      await deviceService.disconnectDevice(isManual: true);

      if (value && !(await deviceService.hasCompanionDeviceAssociation())) {
        final addr = await deviceService.requestCompanionDeviceAssociation(deviceId);
        if (addr.isEmpty) {
          // Chooser cancelled — revert so the toggle reflects reality.
          SharedPreferencesUtil().companionDeviceEnabled = false;
          if (mounted) setState(() => _companionDeviceEnabled = false);
        }
      }

      // Reconnect: native manageDevice clears the association when off, no-op when on.
      await deviceService.ensureConnection(deviceId, force: true);
    } catch (e) {
      Logger.error('AppSettings: companion pairing toggle failed: $e');
    }
  }

  Future<void> _saveSettings() async {
    final prefs = SharedPreferencesUtil();
    prefs.backgroundSyncIntervalMinutes = _backgroundSyncIntervalMinutes;
    if (context.mounted) {
      Provider.of<DeviceProvider>(context, listen: false).restartBackgroundSyncTimer();
    }
    prefs.use24HourTime = _use24HourTime;
    prefs.audioSaveFormat = _audioSaveFormat;
    prefs.keepRecordingsDays = _keepRecordingsDays;
    prefs.uploadOnWifiOnly = _uploadOnWifiOnly;
    prefs.filterMinDurationSeconds = _filterMinDurationSeconds;

    if (mounted) setState(() => _isDirty = false);
  }

  Future<void> _saveAndPop() async {
    await _saveSettings();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _handleBack() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Discard changes?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Your changes have not been saved.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing', style: TextStyle(color: Colors.deepPurpleAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _isDirty = false);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(Future.microtask(_handleBack));
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          elevation: 0,
          leading: IconButton(
            icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
            onPressed: _handleBack,
            tooltip: 'Back',
          ),
          title: const Text(
            'App Settings',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          centerTitle: true,
          actions: [
            if (_isDirty)
              TextButton(
                onPressed: _saveAndPop,
                child: const Text(
                  'Save',
                  style: TextStyle(color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Auto Sync Interval
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Auto Sync Interval',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        DropdownButton<int>(
                          value: _backgroundSyncIntervalMinutes,
                          dropdownColor: const Color(0xFF2C2C2E),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          underline: const SizedBox(),
                          style: const TextStyle(
                              color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                          items: const [
                            DropdownMenuItem(value: 15, child: Text('15 Minutes')),
                            DropdownMenuItem(value: 30, child: Text('30 Minutes')),
                            DropdownMenuItem(value: 60, child: Text('1 Hour')),
                            DropdownMenuItem(value: -1, child: Text('Manual Only')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _backgroundSyncIntervalMinutes = value);
                              _markDirty();
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Shorter intervals reduce the risk of data loss but increase battery drain on your Omi device and phone.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                    Consumer<DeviceProvider>(
                      builder: (context, provider, _) {
                        if (provider.nextSyncTime == null || _backgroundSyncIntervalMinutes <= 0) {
                          return const SizedBox.shrink();
                        }
                        final time = DateFormat(SharedPreferencesUtil().use24HourTime ? 'HH:mm' : 'h:mm a')
                            .format(provider.nextSyncTime!.toLocal());
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              const Icon(Icons.timer_outlined, color: Colors.deepPurpleAccent, size: 14),
                              const SizedBox(width: 6),
                              Text(
                                'Next sync at $time',
                                style: const TextStyle(
                                    color: Colors.deepPurpleAccent, fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Upload on Wifi Only
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Upload on Wifi Only',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    'Restrict recording uploads to WiFi connections only (saves mobile data).',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                  value: _uploadOnWifiOnly,
                  onChanged: (value) {
                    if (value && !PassthroughIntegration.hasAnyConfigured(SharedPreferencesUtil())) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('There are no integrations enabled'),
                          backgroundColor: Colors.redAccent,
                        ),
                      );
                      return;
                    }
                    setState(() => _uploadOnWifiOnly = value);
                    _markDirty();
                  },
                  activeColor: Colors.deepPurpleAccent,
                ),
              ),
              const SizedBox(height: 16),

              // Save File Format As
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Save File Format As',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        DropdownButton<String>(
                          value: _audioSaveFormat,
                          dropdownColor: const Color(0xFF2C2C2E),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          underline: const SizedBox(),
                          style: const TextStyle(
                              color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                          items: const [
                            DropdownMenuItem(value: 'm4a', child: Text('M4A (AAC)')),
                            DropdownMenuItem(value: 'wav', child: Text('WAV (PCM)')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _audioSaveFormat = value);
                              _markDirty();
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _audioSaveFormat == 'm4a'
                          ? 'M4A provides maximum compatibility for cloud services and mobile players.'
                          : 'WAV provides uncompressed, lossless PCM audio but results in very large file sizes.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Short Recordings
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Short Recordings',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        DropdownButton<int>(
                          value: _filterMinDurationSeconds,
                          dropdownColor: const Color(0xFF2C2C2E),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          underline: const SizedBox(),
                          style: TextStyle(
                            color: _filterMinDurationSeconds > 0 ? Colors.deepPurpleAccent : Colors.grey.shade500,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                          items: _kShortRecordingOptions.map((sec) {
                            return DropdownMenuItem(
                              value: sec,
                              child: Text(_formatShortDuration(sec)),
                            );
                          }).toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _filterMinDurationSeconds = value);
                              _markDirty();
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _filterMinDurationSeconds == 0
                          ? 'All recordings are kept and shown regardless of length.'
                          : 'Recordings shorter than ${_formatShortDuration(_filterMinDurationSeconds)} are hidden from the main list and skipped by integrations.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                    if (_filterMinDurationSeconds > 0) ...[
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _handleCleanUp,
                          icon: const FaIcon(FontAwesomeIcons.trashCan, size: 14),
                          label: const Text('Clean Up Short Recordings'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: BorderSide(color: Colors.redAccent.withOpacity(0.5)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Keep Recordings For
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Recording Retention',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        DropdownButton<int>(
                          value: _keepRecordingsDays,
                          dropdownColor: const Color(0xFF2C2C2E),
                          underline: const SizedBox(),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          style: const TextStyle(
                              color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                          items: const [
                            DropdownMenuItem(value: -1, child: Text('Always Keep')),
                            DropdownMenuItem(value: 3, child: Text('3 Days')),
                            DropdownMenuItem(value: 7, child: Text('7 Days')),
                            DropdownMenuItem(value: 0, child: Text('Delete After Upload')),
                          ],
                          onChanged: (value) async {
                            if (value == null) return;
                            if (value == 0) {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  backgroundColor: const Color(0xFF1C1C1E),
                                  title:
                                      const Text('Enable Delete After Upload?', style: TextStyle(color: Colors.white)),
                                  content: const Text(
                                    'Recordings will be sent to your integrations and deleted from your device after a successful upload.',
                                    style: TextStyle(color: Colors.white70, fontSize: 14),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(c).pop(false),
                                      child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.of(c).pop(true),
                                      child: const Text('Enable', style: TextStyle(color: Colors.deepPurpleAccent)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm != true) return;
                            }
                            setState(() => _keepRecordingsDays = value);
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _keepRecordingsDays == -1
                          ? 'Audio recordings are kept on your device permanently.'
                          : _keepRecordingsDays == 0
                              ? 'Audio is sent to your integrations and deleted locally after a successful upload.'
                              : 'Audio recordings older than $_keepRecordingsDays days will be automatically deleted from your device.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Time Format
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('24-Hour Time',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    _use24HourTime ? 'Times shown in 24-hour format.' : 'Times shown in AM/PM format.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                  value: _use24HourTime,
                  onChanged: (value) {
                    setState(() => _use24HourTime = value);
                    _markDirty();
                  },
                  activeColor: Colors.deepPurpleAccent,
                ),
              ),

              // Companion Device Pairing (Android only) — troubleshooting toggle for OEM
              // Bluetooth connection contention (the "toggle phone Bluetooth to reconnect"
              // wedge). Lives here (not Device Settings) so it stays reachable when the
              // device won't connect. Default off; applies immediately via
              // _setCompanionDevicePairing (reconnect on off, system chooser on on).
              if (Platform.isAndroid) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Companion Device Pairing',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      _companionDeviceEnabled
                          ? 'Registers the Omi as an Android system companion. If you often have to toggle phone Bluetooth to reconnect (common on OnePlus/Oppo/Realme), turn this off.'
                          : 'Off — the app connects by address + bond, no companion association. Turning it on reconnects and opens the system pairing dialog.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                    value: _companionDeviceEnabled,
                    onChanged: (value) => _setCompanionDevicePairing(value),
                    activeColor: Colors.deepPurpleAccent,
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
