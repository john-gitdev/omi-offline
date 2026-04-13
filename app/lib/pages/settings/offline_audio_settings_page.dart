import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/omi_api_client.dart';

class OfflineAudioSettingsPage extends StatefulWidget {
  const OfflineAudioSettingsPage({super.key});

  @override
  State<OfflineAudioSettingsPage> createState() => _OfflineAudioSettingsPageState();
}

class _OfflineAudioSettingsPageState extends State<OfflineAudioSettingsPage> {
  late bool _autoSyncEnabled;
  late bool _use24HourTime;
  late bool _adjustmentMode;
  late bool _convertOpusToM4a;
  late bool _omiSyncEnabled;
  bool _omiTestingConnection = false;
  bool? _omiTestResult;

  final _omiIdTokenController = TextEditingController();
  final _omiRefreshTokenController = TextEditingController();
  final _omiFirebaseApiKeyController = TextEditingController();

  late double _vadSpeechThreshold;
  late int _vadSplitSeconds;
  late int _vadMinSpeechSeconds;
  late double _vadHangoverSeconds;
  late double _vadPreSpeechSeconds;
  late int _vadGapSeconds;
  late int _vadMaxConversationMinutes;
  late int _markerLookbackSeconds;

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _autoSyncEnabled = SharedPreferencesUtil().autoSyncEnabled;
    _use24HourTime = SharedPreferencesUtil().use24HourTime;
    _adjustmentMode = SharedPreferencesUtil().adjustmentMode;
    _convertOpusToM4a = SharedPreferencesUtil().convertOpusToM4a;
    _omiSyncEnabled = SharedPreferencesUtil().omiSyncEnabled;
    _omiIdTokenController.text = SharedPreferencesUtil().omiIdToken;
    _omiRefreshTokenController.text = SharedPreferencesUtil().omiRefreshToken;
    _omiFirebaseApiKeyController.text = SharedPreferencesUtil().omiFirebaseApiKey;

    _vadSpeechThreshold = SharedPreferencesUtil().vadSpeechThreshold;
    _vadSplitSeconds = SharedPreferencesUtil().vadSplitSeconds;
    _vadMinSpeechSeconds = SharedPreferencesUtil().vadMinSpeechSeconds;
    _vadHangoverSeconds = SharedPreferencesUtil().vadHangoverSeconds;
    _vadPreSpeechSeconds = SharedPreferencesUtil().vadPreSpeechSeconds;
    _vadGapSeconds = SharedPreferencesUtil().vadGapSeconds;
    _vadMaxConversationMinutes = SharedPreferencesUtil().vadMaxConversationMinutes;
    _markerLookbackSeconds = SharedPreferencesUtil().markerLookbackSeconds;
  }

  @override
  void dispose() {
    _omiIdTokenController.dispose();
    _omiRefreshTokenController.dispose();
    _omiFirebaseApiKeyController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  Future<void> _saveSettings() async {
    final prefs = SharedPreferencesUtil();
    prefs.autoSyncEnabled = _autoSyncEnabled;
    prefs.use24HourTime = _use24HourTime;
    prefs.adjustmentMode = _adjustmentMode;
    if (_adjustmentMode) prefs.adjustmentModeWasEnabled = true;
    prefs.convertOpusToM4a = _convertOpusToM4a;

    prefs.vadSpeechThreshold = _vadSpeechThreshold;
    prefs.vadSplitSeconds = _vadSplitSeconds;
    prefs.vadMinSpeechSeconds = _vadMinSpeechSeconds;
    prefs.vadHangoverSeconds = _vadHangoverSeconds;
    prefs.vadPreSpeechSeconds = _vadPreSpeechSeconds;
    prefs.vadGapSeconds = _vadGapSeconds;
    prefs.vadMaxConversationMinutes = _vadMaxConversationMinutes;
    prefs.markerLookbackSeconds = _markerLookbackSeconds;

    prefs.omiSyncEnabled = _omiSyncEnabled;
    prefs.omiIdToken = _omiIdTokenController.text.trim();
    await prefs.setOmiRefreshToken(_omiRefreshTokenController.text.trim());
    await prefs.setOmiFirebaseApiKey(_omiFirebaseApiKeyController.text.trim());

    setState(() => _isDirty = false);
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
                          onChanged: (value) async {
                            if (value) {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  backgroundColor: const Color(0xFF1C1C1E),
                                  title: const Text('Enable Adjustment Mode?',
                                      style: TextStyle(color: Colors.white)),
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
                                      child: const Text('Enable',
                                          style: TextStyle(color: Colors.deepPurpleAccent)),
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
              const SizedBox(height: 16),

              // Convert to M4A toggle
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
                          'Convert to M4A',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        Switch(
                          value: _convertOpusToM4a,
                          activeThumbColor: Colors.deepPurpleAccent,
                          onChanged: (value) {
                            setState(() => _convertOpusToM4a = value);
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'When enabled, recordings are converted to M4A for maximum compatibility. When disabled, they are saved in the original Opus format (using OGG on Android or WAV on iOS).',
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
                            setState(() {
                              _vadSplitSeconds = sec;
                              if (_markerLookbackSeconds > sec) _markerLookbackSeconds = sec;
                            });
                            _markDirty();
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Button Tap Lookback
              const Text(
                'Button Tap Lookback',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'How far back to include audio when the button is tapped outside of an active conversation.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final sec in [30, 60, 120, 300].where((s) => s <= _vadSplitSeconds))
                      Container(
                        width: 80,
                        margin: const EdgeInsets.only(right: 8),
                        child: _WindowOption(
                          label: sec < 60 ? '${sec}s' : '${sec ~/ 60} min',
                          selected: _markerLookbackSeconds == sec,
                          onTap: () {
                            setState(() => _markerLookbackSeconds = sec);
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
                'Max allowed time gap between audio segments before forcing a split. Bridges brief gaps caused by the device being turned off or restarting.',
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

              // Omi Server Sync
              const Text(
                'Omi Server Sync',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),
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
                          'Sync to Omi Cloud',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        Switch(
                          value: _omiSyncEnabled,
                          activeThumbColor: Colors.deepPurpleAccent,
                          onChanged: (value) {
                            setState(() => _omiSyncEnabled = value);
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                    Text(
                      'Upload processed recordings to your official Omi account so they appear in the Omi app.',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    _OmiTokenField(
                      label: 'ID Token',
                      hint: 'Firebase ID token (eyJhbG…)',
                      controller: _omiIdTokenController,
                      onChanged: (_) => _markDirty(),
                    ),
                    const SizedBox(height: 12),
                    _OmiTokenField(
                      label: 'Refresh Token',
                      hint: 'Firebase refresh token',
                      controller: _omiRefreshTokenController,
                      onChanged: (_) => _markDirty(),
                    ),
                    const SizedBox(height: 12),
                    _OmiTokenField(
                      label: 'Firebase API Key',
                      hint: 'AIzaSy…',
                      controller: _omiFirebaseApiKeyController,
                      onChanged: (_) => _markDirty(),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _omiTestingConnection
                                ? null
                                : () async {
                                    await _saveSettings();
                                    setState(() {
                                      _omiTestingConnection = true;
                                      _omiTestResult = null;
                                    });
                                    final ok = await OmiApiClient.testConnection();
                                    if (mounted) {
                                      setState(() {
                                        _omiTestingConnection = false;
                                        _omiTestResult = ok;
                                      });
                                    }
                                  },
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.deepPurpleAccent),
                              foregroundColor: Colors.deepPurpleAccent,
                            ),
                            child: _omiTestingConnection
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurpleAccent),
                                  )
                                : const Text('Test Connection'),
                          ),
                        ),
                        if (_omiTestResult != null) ...[
                          const SizedBox(width: 12),
                          Icon(
                            _omiTestResult! ? Icons.check_circle : Icons.error,
                            color: _omiTestResult! ? Colors.green : Colors.redAccent,
                            size: 22,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _omiTestResult! ? 'Connected' : 'Failed',
                            style: TextStyle(
                              color: _omiTestResult! ? Colors.green : Colors.redAccent,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Extract tokens from app.omi.me developer tools: Application → Local Storage → firebase:authUser.',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                  ],
                ),
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

class _OmiTokenField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  const _OmiTokenField({required this.label, required this.hint, required this.controller, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          onChanged: onChanged,
          style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
          maxLines: 1,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            filled: true,
            fillColor: const Color(0xFF2C2C2E),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
      ],
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
