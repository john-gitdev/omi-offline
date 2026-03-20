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
  }

  String _formatSeconds(double seconds) {
    final int whole = seconds.toInt();
    final bool hasHalf = (seconds - whole) >= 0.4;
    if (!hasHalf) return _formatTime(whole);
    if (whole == 0) return '0.5 sec';
    return '$whole.5 sec';
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
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        leading: IconButton(
          icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Recording Settings',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                    _saveSettings();
                  },
                ),
                const SizedBox(width: 12),
                _ModeOption(
                  label: 'Manual',
                  selected: _recordingMode == 'manual',
                  onTap: () {
                    setState(() => _recordingMode = 'manual');
                    _saveSettings();
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_recordingMode == 'automatic')
              Text(
                'All audio is continuously processed and split by silence detection.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              )
            else ...[
              Text(
                'Only conversations you marked with a double-press on your Omi will be saved.',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                'The Conversation Split Threshold below controls how much silence is used to find the edges of your marked conversation.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
            const SizedBox(height: 32),
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
                          setState(() {
                            _autoSyncEnabled = value;
                          });
                          _saveSettings();
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
                setState(() {
                  _snrMarginDb = value;
                });
                _saveSettings();
              },
            ),
            // Hangover Duration slider hidden — hardcoded to 0.5s default (offlineHangoverSeconds).
            // Users found it confusing alongside the conversation split threshold.
            // To restore: uncomment this block and the _hangoverSeconds field/init/save above.
            // const SizedBox(height: 32),
            // const Text(
            //   'Hangover Duration',
            //   style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
            // ),
            // const SizedBox(height: 8),
            // Text(
            //   'How long to continue treating audio as speech after the signal drops below threshold. Prevents pauses and breaths from splitting recordings. (Current: ${_formatSeconds(_hangoverSeconds)})',
            //   style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            // ),
            // const SizedBox(height: 12),
            // Slider(
            //   value: _hangoverSeconds,
            //   min: 0,
            //   max: 5,
            //   divisions: 10,
            //   activeColor: Colors.deepPurpleAccent,
            //   inactiveColor: const Color(0xFF3C3C43),
            //   onChanged: (value) {
            //     setState(() {
            //       _hangoverSeconds = value;
            //     });
            //     _saveSettings();
            //   },
            // ),
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
              max: 600.0, // 10 minutes
              divisions: 114, // Steps of 5 seconds
              activeColor: Colors.deepPurpleAccent,
              inactiveColor: const Color(0xFF3C3C43),
              onChanged: (value) {
                setState(() {
                  _splitSeconds = value.toInt();
                });
                _saveSettings();
              },
            ),
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
              divisions: 30, // Steps of 1 second
              activeColor: Colors.deepPurpleAccent,
              inactiveColor: const Color(0xFF3C3C43),
              onChanged: (value) {
                setState(() {
                  _minSpeechSeconds = value.toInt();
                });
                _saveSettings();
              },
            ),
            // Pre-Speech Buffer slider hidden — hardcoded to 1.0s default (offlinePreSpeechSeconds).
            // To restore: uncomment this block and the _preSpeechSeconds field/init/save above.
            // const SizedBox(height: 32),
            // const Text(
            //   'Pre-Speech Buffer',
            //   style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
            // ),
            // const SizedBox(height: 8),
            // Text(
            //   'Audio kept before detected speech to avoid clipping the start of utterances. (Current: ${_formatSeconds(_preSpeechSeconds)})',
            //   style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            // ),
            // const SizedBox(height: 12),
            // Slider(
            //   value: _preSpeechSeconds,
            //   min: 0.0,
            //   max: 5.0,
            //   divisions: 10,
            //   activeColor: Colors.deepPurpleAccent,
            //   inactiveColor: const Color(0xFF3C3C43),
            //   onChanged: (value) {
            //     setState(() {
            //       _preSpeechSeconds = value;
            //     });
            //     _saveSettings();
            //   },
            // ),
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
                setState(() {
                  _gapSeconds = value.toInt();
                });
                _saveSettings();
              },
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _adjustmentMode ? Colors.deepPurpleAccent : Colors.transparent),
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
                          setState(() {
                            _adjustmentMode = value;
                          });
                          _saveSettings();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'When enabled, raw audio segments are NOT deleted after processing. This allows you to fine-tune these sliders and reprocess your audio until you find the perfect settings. Turning this off will delete all raw segments after they are processed.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                ],
              ),
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
