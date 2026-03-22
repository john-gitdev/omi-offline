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
  late double _snrMarginDb;
  late double _hangoverSeconds;
  late int _splitSeconds;
  late int _minSpeechSeconds;
  late double _preSpeechSeconds;
  late int _gapSeconds;
  late bool _adjustmentMode;
  late String _recordingMode;
  late bool _autoSyncEnabled;
  late int _fixedIntervalMinutes;
  late int _markerLookbackMinutes;

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _snrMarginDb = SharedPreferencesUtil().offlineSnrMarginDb;
    _hangoverSeconds = SharedPreferencesUtil().offlineHangoverSeconds;
    _splitSeconds = SharedPreferencesUtil().offlineSplitSeconds;
    _minSpeechSeconds = SharedPreferencesUtil().offlineMinSpeechSeconds;
    _preSpeechSeconds = SharedPreferencesUtil().offlinePreSpeechSeconds;
    _gapSeconds = SharedPreferencesUtil().offlineGapSeconds;
    _adjustmentMode = SharedPreferencesUtil().offlineAdjustmentMode;
    _recordingMode = SharedPreferencesUtil().offlineRecordingMode;
    _autoSyncEnabled = SharedPreferencesUtil().autoSyncEnabled;
    _fixedIntervalMinutes = SharedPreferencesUtil().offlineFixedIntervalMinutes;
    _markerLookbackMinutes = SharedPreferencesUtil().markerLookbackMinutes;
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  void _saveSettings() {
    SharedPreferencesUtil().offlineSnrMarginDb = _snrMarginDb;
    SharedPreferencesUtil().offlineHangoverSeconds = _hangoverSeconds;
    SharedPreferencesUtil().offlineSplitSeconds = _splitSeconds;
    SharedPreferencesUtil().offlineMinSpeechSeconds = _minSpeechSeconds;
    SharedPreferencesUtil().offlinePreSpeechSeconds = _preSpeechSeconds;
    SharedPreferencesUtil().offlineGapSeconds = _gapSeconds;
    SharedPreferencesUtil().offlineAdjustmentMode = _adjustmentMode;
    SharedPreferencesUtil().offlineRecordingMode = _recordingMode;
    SharedPreferencesUtil().autoSyncEnabled = _autoSyncEnabled;
    SharedPreferencesUtil().offlineFixedIntervalMinutes = _fixedIntervalMinutes;
    SharedPreferencesUtil().markerLookbackMinutes = _markerLookbackMinutes;
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

  String _formatTime(int totalSeconds) {
    int minutes = totalSeconds ~/ 60;
    int seconds = totalSeconds % 60;
    if (minutes > 0 && seconds > 0) {
      return '$minutes min $seconds sec';
    } else if (minutes > 0) {
      return '$minutes min';
    } else {
      return '$seconds sec';
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
                'Recording Mode',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _ModeOption(
                    label: 'Automatic',
                    selected: _recordingMode == 'automatic',
                    onTap: () {
                      setState(() => _recordingMode = 'automatic');
                      _markDirty();
                    },
                  ),
                  const SizedBox(width: 8),
                  _ModeOption(
                    label: 'Marker',
                    selected: _recordingMode == 'marker',
                    onTap: () {
                      setState(() => _recordingMode = 'marker');
                      _markDirty();
                    },
                  ),
                  const SizedBox(width: 8),
                  _ModeOption(
                    label: 'Fixed',
                    selected: _recordingMode == 'fixed',
                    onTap: () {
                      setState(() => _recordingMode = 'fixed');
                      _markDirty();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_recordingMode == 'automatic') ...[
                Text(
                  'All audio is continuously processed and split by silence detection.',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Adjustment Mode',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Keep raw segments so you can reprocess\nwith different settings.',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                      ],
                    ),
                    Switch(
                      value: _adjustmentMode,
                      activeThumbColor: Colors.deepPurpleAccent,
                      onChanged: (value) {
                        setState(() => _adjustmentMode = value);
                        _markDirty();
                      },
                    ),
                  ],
                ),
              ] else if (_recordingMode == 'marker') ...[
                Text(
                  'Only conversations you marked with a double-press on your Omi will be saved.',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  'The Conversation Split Threshold below controls how much silence is used to find the edges of your marked conversation.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Lookback Window',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                Text(
                  'How far back before a marker to search for the conversation start.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _IntervalOption(
                      label: '15 min',
                      value: 15,
                      selected: _markerLookbackMinutes == 15,
                      onTap: () {
                        setState(() => _markerLookbackMinutes = 15);
                        _markDirty();
                      },
                    ),
                    const SizedBox(width: 8),
                    _IntervalOption(
                      label: '30 min',
                      value: 30,
                      selected: _markerLookbackMinutes == 30,
                      onTap: () {
                        setState(() => _markerLookbackMinutes = 30);
                        _markDirty();
                      },
                    ),
                    const SizedBox(width: 8),
                    _IntervalOption(
                      label: '1 hour',
                      value: 60,
                      selected: _markerLookbackMinutes == 60,
                      onTap: () {
                        setState(() => _markerLookbackMinutes = 60);
                        _markDirty();
                      },
                    ),
                    const SizedBox(width: 8),
                    _IntervalOption(
                      label: '2 hours',
                      value: 120,
                      selected: _markerLookbackMinutes == 120,
                      onTap: () {
                        setState(() => _markerLookbackMinutes = 120);
                        _markDirty();
                      },
                    ),
                  ],
                ),
              ] else ...[
                Text(
                  'Audio is saved at fixed wall-clock intervals. The first clip runs from when recording starts to the next boundary, then cuts repeat at the selected interval.',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Interval',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 10),
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
              ],
              if (_recordingMode == 'automatic' || _recordingMode == 'marker') ...[
                const SizedBox(height: 32),
                const Text(
                  'Speech Sensitivity (SNR Margin)',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  'How much louder than background noise your voice must be to count as speech. Higher = only loud, clear speech passes through. Lower = more sensitive, but may pick up background noise. Recommended: 8–12 dB. (Current: ${_snrMarginDb.toStringAsFixed(0)} dB)',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Slider(
                  value: _snrMarginDb,
                  min: 3.0,
                  max: 20.0,
                  divisions: 17,
                  activeColor: Colors.deepPurpleAccent,
                  inactiveColor: const Color(0xFF3C3C43),
                  onChanged: (value) {
                    setState(() => _snrMarginDb = value);
                    _markDirty();
                  },
                ),
              ],
              if (_recordingMode == 'automatic' || _recordingMode == 'marker') ...[
                const SizedBox(height: 32),
                const Text(
                  'Conversation Split Threshold',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  'The duration of continuous silence required to trigger a split and save the previous recording. (Current: ${_formatTime(_splitSeconds)})',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Slider(
                  value: _splitSeconds.toDouble(),
                  min: 30.0,
                  max: 600.0,
                  divisions: 114,
                  activeColor: Colors.deepPurpleAccent,
                  inactiveColor: const Color(0xFF3C3C43),
                  onChanged: (value) {
                    setState(() => _splitSeconds = value.toInt());
                    _markDirty();
                  },
                ),
              ],
              if (_recordingMode == 'automatic') ...[
                const SizedBox(height: 32),
                const Text(
                  'Minimum Speech Threshold',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  'Recordings shorter than this duration (excluding silence) will be discarded. (Current: ${_formatTime(_minSpeechSeconds)})',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Slider(
                  value: _minSpeechSeconds.toDouble(),
                  min: 0.0,
                  max: 30.0,
                  divisions: 30,
                  activeColor: Colors.deepPurpleAccent,
                  inactiveColor: const Color(0xFF3C3C43),
                  onChanged: (value) {
                    setState(() => _minSpeechSeconds = value.toInt());
                    _markDirty();
                  },
                ),
              ],
              if (_recordingMode == 'automatic' || _recordingMode == 'fixed') ...[
                const SizedBox(height: 32),
                const Text(
                  'Gap Threshold',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  'If a time gap between segments exceeds this duration, recordings are force-split (e.g. device was off). (Current: ${_formatTime(_gapSeconds)})',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Slider(
                  value: _gapSeconds.toDouble(),
                  min: 5.0,
                  max: 60.0,
                  divisions: 11,
                  activeColor: Colors.deepPurpleAccent,
                  inactiveColor: const Color(0xFF3C3C43),
                  onChanged: (value) {
                    setState(() => _gapSeconds = value.toInt());
                    _markDirty();
                  },
                ),
              ],
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

class _ModeOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeOption({required this.label, required this.selected, required this.onTap});

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
