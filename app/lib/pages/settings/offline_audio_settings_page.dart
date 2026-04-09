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
  late bool _use24HourTime;
  late bool _adjustmentMode;

  late double _vadSpeechThreshold;
  late int _vadSplitSeconds;
  late int _vadMinSpeechSeconds;
  late double _vadHangoverSeconds;
  late double _vadPreSpeechSeconds;
  late int _vadGapSeconds;
  late int _vadMaxConversationMinutes;

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _autoSyncEnabled = SharedPreferencesUtil().autoSyncEnabled;
    _use24HourTime = SharedPreferencesUtil().use24HourTime;
    _adjustmentMode = SharedPreferencesUtil().adjustmentMode;

    _vadSpeechThreshold = SharedPreferencesUtil().vadSpeechThreshold;
    _vadSplitSeconds = SharedPreferencesUtil().vadSplitSeconds;
    _vadMinSpeechSeconds = SharedPreferencesUtil().vadMinSpeechSeconds;
    _vadHangoverSeconds = SharedPreferencesUtil().vadHangoverSeconds;
    _vadPreSpeechSeconds = SharedPreferencesUtil().vadPreSpeechSeconds;
    _vadGapSeconds = SharedPreferencesUtil().vadGapSeconds;
    _vadMaxConversationMinutes = SharedPreferencesUtil().vadMaxConversationMinutes;
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  void _saveSettings() {
    SharedPreferencesUtil().autoSyncEnabled = _autoSyncEnabled;
    SharedPreferencesUtil().use24HourTime = _use24HourTime;
    SharedPreferencesUtil().adjustmentMode = _adjustmentMode;
    if (_adjustmentMode) SharedPreferencesUtil().adjustmentModeWasEnabled = true;

    SharedPreferencesUtil().vadSpeechThreshold = _vadSpeechThreshold;
    SharedPreferencesUtil().vadSplitSeconds = _vadSplitSeconds;
    SharedPreferencesUtil().vadMinSpeechSeconds = _vadMinSpeechSeconds;
    SharedPreferencesUtil().vadHangoverSeconds = _vadHangoverSeconds;
    SharedPreferencesUtil().vadPreSpeechSeconds = _vadPreSpeechSeconds;
    SharedPreferencesUtil().vadGapSeconds = _vadGapSeconds;
    SharedPreferencesUtil().vadMaxConversationMinutes = _vadMaxConversationMinutes;

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
              // Auto Sync toggle
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
                      'When enabled, your Omi will automatically connect, sync, and process recordings every 30 minutes.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Time format toggle
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
                        Row(
                          children: [
                            Text(
                              _use24HourTime ? '24hr' : 'AM/PM',
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                            ),
                            const SizedBox(width: 8),
                            Switch(
                              value: _use24HourTime,
                              activeThumbColor: Colors.deepPurpleAccent,
                              onChanged: (value) {
                                setState(() => _use24HourTime = value);
                                _markDirty();
                              },
                            ),
                          ],
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
                          onChanged: (value) {
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
              const SizedBox(height: 32),

              // Conversation Detection
              const Text(
                'Conversation Detection',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),

              // Speech Sensitivity
              const Text(
                'Speech Sensitivity',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Lower = more sensitive (picks up quiet speech). Higher = stricter (ignores background noise).',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              Slider(
                value: _vadSpeechThreshold,
                min: 0.1,
                max: 0.9,
                divisions: 16,
                label: '${(_vadSpeechThreshold * 100).round()}%',
                activeColor: Colors.deepPurpleAccent,
                onChanged: (value) {
                  setState(() => _vadSpeechThreshold = value);
                  _markDirty();
                },
              ),
              const SizedBox(height: 16),

              // Silence to End Conversation
              const Text(
                'Silence to End Conversation',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'How long you need to be quiet before a new conversation begins.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final sec in [30, 60, 120, 300])
                      Container(
                        width: 80,
                        margin: const EdgeInsets.only(right: 8),
                        child: _WindowOption(
                          label: sec < 60 ? '${sec}s' : '${sec ~/ 60} min',
                          selected: _vadSplitSeconds == sec,
                          onTap: () {
                            setState(() => _vadSplitSeconds = sec);
                            _markDirty();
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Minimum Conversation Length
              const Text(
                'Minimum Conversation Length',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Speech segments shorter than this are discarded. Increase to filter out brief accidental sounds.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final sec in [3, 5, 10, 30])
                    _WindowOption(
                      label: '${sec}s',
                      selected: _vadMinSpeechSeconds == sec,
                      onTap: () {
                        setState(() => _vadMinSpeechSeconds = sec);
                        _markDirty();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 24),

              // Speech Holdover
              const Text(
                'Speech Holdover',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'How long to keep recording after speech stops, to avoid cutting off the end of sentences.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final sec in [0.0, 0.5, 1.0, 2.0])
                    _WindowOption(
                      label: '${sec}s',
                      selected: _vadHangoverSeconds == sec,
                      onTap: () {
                        setState(() => _vadHangoverSeconds = sec);
                        _markDirty();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 24),

              // Pre-Speech Buffer
              const Text(
                'Pre-Speech Buffer',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Audio captured before speech is detected, so the first word is never clipped.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final sec in [0.0, 0.5, 1.0, 2.0])
                    _WindowOption(
                      label: '${sec}s',
                      selected: _vadPreSpeechSeconds == sec,
                      onTap: () {
                        setState(() => _vadPreSpeechSeconds = sec);
                        _markDirty();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 24),

              // Segment Gap Threshold
              const Text(
                'Segment Gap Threshold',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Speech segments closer together than this are merged into one conversation. Increase to join nearby exchanges; decrease to keep them separate.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final sec in [10, 30, 60, 120])
                    _WindowOption(
                      label: '${sec}s',
                      selected: _vadGapSeconds == sec,
                      onTap: () {
                        setState(() => _vadGapSeconds = sec);
                        _markDirty();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 32),

              // Maximum Conversation Length
              const Text(
                'Max Conversation Length',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Text(
                'Forces a cut if a conversation reaches this duration, even without silence.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final mins in [30, 60, 120, 180])
                    _WindowOption(
                      label: mins >= 60 ? '${mins ~/ 60}h' : '${mins}m',
                      selected: _vadMaxConversationMinutes == mins,
                      onTap: () {
                        setState(() => _vadMaxConversationMinutes = mins);
                        _markDirty();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 32),

              // Info box
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
                        'Audio is processed locally using Silero voice activity detection. Each continuous conversation is saved as its own M4A file. Tap the button on your Omi to tag a moment.',
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

class _WindowOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _WindowOption({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 8),
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
