import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:provider/provider.dart';
import 'package:omi/providers/device_provider.dart';

class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({super.key});

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  late bool _maximizeBattery;
  late int _backgroundSyncIntervalMinutes;
  late bool _use24HourTime;
  late bool _adjustmentMode;
  late String _audioSaveFormat;
  late int _keepRecordingsDays;

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _maximizeBattery = SharedPreferencesUtil().maximizeBattery;
    _backgroundSyncIntervalMinutes = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    _use24HourTime = SharedPreferencesUtil().use24HourTime;
    _adjustmentMode = SharedPreferencesUtil().adjustmentMode;
    _audioSaveFormat = SharedPreferencesUtil().audioSaveFormat;
    _keepRecordingsDays = SharedPreferencesUtil().keepRecordingsDays;
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  Future<void> _saveSettings() async {
    final prefs = SharedPreferencesUtil();
    prefs.maximizeBattery = _maximizeBattery;
    prefs.backgroundSyncIntervalMinutes = _backgroundSyncIntervalMinutes;
    if (context.mounted) {
      Provider.of<DeviceProvider>(context, listen: false).restartBackgroundSyncTimer();
    }
    prefs.use24HourTime = _use24HourTime;
    final prevAdjustmentMode = prefs.adjustmentMode;
    prefs.adjustmentMode = _adjustmentMode;
    if (_adjustmentMode) prefs.adjustmentModeWasEnabled = true;
    prefs.audioSaveFormat = _audioSaveFormat;
    prefs.keepRecordingsDays = _keepRecordingsDays;

    if (prevAdjustmentMode != _adjustmentMode) RecordingsManager.notifyRecordingsChanged();

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
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Maximize Battery', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  subtitle: Text('Disconnects Bluetooth after a sync completes to maximize battery life.', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                  value: _maximizeBattery,
                  onChanged: (value) {
                    setState(() => _maximizeBattery = value);
                    _markDirty();
                  },
                  activeColor: Colors.deepPurpleAccent,
                ),
              ),
              const SizedBox(height: 16),

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
                          style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Time Format',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        DropdownButton<bool>(
                          value: _use24HourTime,
                          dropdownColor: const Color(0xFF2C2C2E),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                          underline: const SizedBox(),
                          style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                          items: const [
                            DropdownMenuItem(value: false, child: Text('AM/PM')),
                            DropdownMenuItem(value: true, child: Text('24-Hour')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _use24HourTime = value);
                              _markDirty();
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Display recording times in 24-hour format or 12-hour AM/PM.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                  ],
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
                          style: const TextStyle(color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                          items: [
                            const DropdownMenuItem(value: 'm4a', child: Text('M4A (AAC)')),
                            if (!Platform.isIOS)
                              const DropdownMenuItem(value: 'ogg', child: Text('OGG (Opus)')),
                            const DropdownMenuItem(value: 'wav', child: Text('WAV (PCM)')),
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
                          : _audioSaveFormat == 'ogg'
                              ? 'OGG provides the smallest file size by saving the original Opus stream (Android only).'
                              : 'WAV provides uncompressed, lossless PCM audio but results in very large file sizes.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
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
                          'Keep Recordings For',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        DropdownButton<int>(
                          value: _keepRecordingsDays,
                          dropdownColor: const Color(0xFF1C1C1E),
                          underline: const SizedBox(),
                          icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                          style: const TextStyle(color: Colors.white, fontSize: 16),
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
                                  title: const Text('Enable Delete After Upload?', style: TextStyle(color: Colors.white)),
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

              // Adjustment Mode
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
                          'Adjustment Mode',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Switch(
                          value: _adjustmentMode,
                          activeThumbColor: Colors.deepPurpleAccent,
                          onChanged: (value) async {
                            if (value) {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  backgroundColor: const Color(0xFF1C1C1E),
                                  title: const Text('Enable Adjustment Mode?', style: TextStyle(color: Colors.white)),
                                  content: const Text(
                                    'Raw audio is kept on disk so you can reprocess days with different settings.\n\n'
                                    'Uploads to HeyPocket and other integrations are paused while adjustment mode is on — '
                                    'recordings may still change before you\'re done. '
                                    'They resume automatically once you turn it off.',
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
                            setState(() => _adjustmentMode = value);
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Raw audio files are kept on disk after processing. Use this when tweaking VAD settings — each day shows a Reprocess button to regenerate recordings from scratch.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
