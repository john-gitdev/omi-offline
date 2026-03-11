import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';

class OfflineAudioSettingsPage extends StatefulWidget {
  const OfflineAudioSettingsPage({super.key});

  @override
  State<OfflineAudioSettingsPage> createState() => _OfflineAudioSettingsPageState();
}

class _OfflineAudioSettingsPageState extends State<OfflineAudioSettingsPage> {
  late double _silenceThreshold;
  late int _splitSeconds;
  late int _minSpeechSeconds;
  late bool _adjustmentMode;

  @override
  void initState() {
    super.initState();
    _silenceThreshold = SharedPreferencesUtil().offlineSilenceThreshold;
    _splitSeconds = SharedPreferencesUtil().offlineSplitSeconds;
    _minSpeechSeconds = SharedPreferencesUtil().offlineMinSpeechSeconds;
    _adjustmentMode = SharedPreferencesUtil().offlineAdjustmentMode;
  }

  void _saveSettings() {
    SharedPreferencesUtil().offlineSilenceThreshold = _silenceThreshold;
    SharedPreferencesUtil().offlineSplitSeconds = _splitSeconds;
    SharedPreferencesUtil().offlineMinSpeechSeconds = _minSpeechSeconds;
    SharedPreferencesUtil().offlineAdjustmentMode = _adjustmentMode;
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
          'Offline Audio Settings',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
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
                    'When enabled, raw audio chunks are NOT deleted after processing. This allows you to fine-tune these sliders and reprocess your audio until you find the perfect settings. Turning this off will delete all raw chunks after they are processed.',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Silence Threshold (dBFS)',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              'Sets the decibel level required to trigger the end of a silence period. -100 is absolute silence. (Current: ${_silenceThreshold.toStringAsFixed(1)} dBFS)',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Slider(
              value: _silenceThreshold,
              min: -100.0,
              max: 0.0,
              divisions: 100,
              activeColor: Colors.deepPurpleAccent,
              inactiveColor: const Color(0xFF3C3C43),
              onChanged: (value) {
                setState(() {
                  _silenceThreshold = value;
                });
                _saveSettings();
              },
            ),
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
                      'All recordings are processed locally and saved as heavily compressed AAC audio files to maximize storage.',
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
