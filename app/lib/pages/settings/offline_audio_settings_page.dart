import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';

class OfflineAudioSettingsPage extends StatefulWidget {
  const OfflineAudioSettingsPage({super.key});

  @override
  State<OfflineAudioSettingsPage> createState() => _OfflineAudioSettingsPageState();
}

class _OfflineAudioSettingsPageState extends State<OfflineAudioSettingsPage> {
  late bool _autoSyncEnabled;
  late int _fixedIntervalMinutes;

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _autoSyncEnabled = SharedPreferencesUtil().autoSyncEnabled;
    _fixedIntervalMinutes = SharedPreferencesUtil().offlineFixedIntervalMinutes;
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  void _saveSettings() {
    SharedPreferencesUtil().autoSyncEnabled = _autoSyncEnabled;
    SharedPreferencesUtil().offlineFixedIntervalMinutes = _fixedIntervalMinutes;
    setState(() => _isDirty = false);
  }

  void _saveAndPop() {
    _saveSettings();
    Navigator.of(context).pop();
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
          ),
          title: const Text(
            'Recording Settings',
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
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Auto Sync',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Switch(
                          value: _autoSyncEnabled,
                          activeThumbColor: Colors.deepPurpleAccent,
                          onChanged: (value) {
                            setState(() => _autoSyncEnabled = value);
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'When enabled, your Omi will automatically try to connect, sync, and process segments every 30 minutes.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Recording Interval',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Text(
                'Audio is saved at fixed wall-clock intervals. The first interval runs from when recording starts to the next boundary, then cuts repeat at the selected interval.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _IntervalOption(
                    label: '30 min',
                    value: 30,
                    selected: _fixedIntervalMinutes == 30,
                    onTap: () {
                      setState(() => _fixedIntervalMinutes = 30);
                      _markDirty();
                    },
                  ),
                  const SizedBox(width: 10),
                  _IntervalOption(
                    label: '1 hour',
                    value: 60,
                    selected: _fixedIntervalMinutes == 60,
                    onTap: () {
                      setState(() => _fixedIntervalMinutes = 60);
                      _markDirty();
                    },
                  ),
                  const SizedBox(width: 10),
                  _IntervalOption(
                    label: '2 hours',
                    value: 120,
                    selected: _fixedIntervalMinutes == 120,
                    onTap: () {
                      setState(() => _fixedIntervalMinutes = 120);
                      _markDirty();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const FaIcon(FontAwesomeIcons.circleInfo, size: 20, color: Colors.blueAccent),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'All recordings are processed locally on-device and saved as AAC (M4A) audio files.',
                        style: TextStyle(color: Colors.grey.shade300, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntervalOption extends StatelessWidget {
  final String label;
  final int value;
  final bool selected;
  final VoidCallback onTap;

  const _IntervalOption({required this.label, required this.value, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? Colors.deepPurpleAccent : Colors.transparent, width: 1.5),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.deepPurpleAccent : Colors.grey.shade400,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
