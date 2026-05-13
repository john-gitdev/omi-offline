import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:provider/provider.dart';

class OfflineAudioSettingsPage extends StatefulWidget {
  final int Function(int minSeconds)? onCountShortRecordings;
  final Future<void> Function(int minSeconds)? onDeleteShortRecordings;
  final bool flashManualMode;

  const OfflineAudioSettingsPage({
    super.key,
    this.onCountShortRecordings,
    this.onDeleteShortRecordings,
    this.flashManualMode = false,
  });

  @override
  State<OfflineAudioSettingsPage> createState() => _OfflineAudioSettingsPageState();
}

class _OfflineAudioSettingsPageState extends State<OfflineAudioSettingsPage> with SingleTickerProviderStateMixin {
  late AnimationController _flashController;
  late Animation<double> _flashAnimation;
  late bool _manualMode;
  late bool _vadEnabled;

  late double _vadSpeechThreshold;
  late int _vadSplitSeconds;
  late int _vadMaxConversationMinutes;
  late int _filterMinDurationSeconds;
  late int _vadMinSpeechSeconds;
  late bool _discardShortRecordings;

  static const List<int> _kShortRecordingOptions = [0, 10, 30, 60, 120, 300, 600, 1800];
  static const List<(String, double)> _kSpeechSensitivityOptions = [
    ('Sensitive', 0.3),
    ('Balanced', 0.5),
    ('Strict', 0.65),
  ];

  static double _snapToSensitivity(double v) =>
      _kSpeechSensitivityOptions.map((o) => o.$2).reduce((a, b) => (a - v).abs() < (b - v).abs() ? a : b);

  static String _formatShortDuration(int seconds) {
    if (seconds == 0) return 'Off';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    return '${seconds ~/ 3600}h';
  }

  bool _isDirty = false;

  @override
  void initState() {
    super.initState();
    _flashController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
    _flashAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeIn)), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeOut)), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeIn)), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeOut)), weight: 1),
    ]).animate(_flashController);
    if (widget.flashManualMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted) _flashController.forward();
        });
      });
    }

    _manualMode = SharedPreferencesUtil().manualMode;
    _vadEnabled = SharedPreferencesUtil().vadEnabled;

    _vadSpeechThreshold = _snapToSensitivity(SharedPreferencesUtil().vadSpeechThreshold);
    _vadSplitSeconds = SharedPreferencesUtil().vadSplitSeconds;
    _vadMaxConversationMinutes = SharedPreferencesUtil().vadMaxConversationMinutes;
    _filterMinDurationSeconds = SharedPreferencesUtil().filterMinDurationSeconds;
    _vadMinSpeechSeconds = SharedPreferencesUtil().vadMinSpeechSeconds;
    _discardShortRecordings = SharedPreferencesUtil().discardShortRecordings;
  }

  @override
  void dispose() {
    _flashController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  Future<void> _handleCleanUp() async {
    final count = widget.onCountShortRecordings!(_filterMinDurationSeconds);
    final label = _formatShortDuration(_filterMinDurationSeconds);
    if (count == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No recordings to clean up.')),
        );
      }
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete short recordings?', style: TextStyle(color: Colors.white)),
        content: Text(
          '$count recording${count == 1 ? '' : 's'} shorter than $label will be permanently deleted and cannot be recovered.',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await widget.onDeleteShortRecordings!(_filterMinDurationSeconds);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted $count short recording${count == 1 ? '' : 's'}.')),
        );
      }
    }
  }

  Future<void> _saveSettings() async {
    final prefs = SharedPreferencesUtil();
    if (_manualMode != prefs.manualMode) {
      await context.read<DeviceProvider>().setManualMode(_manualMode);
    }
    prefs.vadEnabled = _vadEnabled;
    prefs.vadSpeechThreshold = _vadSpeechThreshold;
    prefs.vadMinSpeechSeconds = _vadMinSpeechSeconds;
    prefs.vadSplitSeconds = _vadSplitSeconds;
    prefs.vadMaxConversationMinutes = _vadMaxConversationMinutes;
    prefs.filterMinDurationSeconds = _filterMinDurationSeconds;
    prefs.discardShortRecordings = _discardShortRecordings;

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
          child: Builder(
            builder: (context) {
              final isConnected = context.watch<DeviceProvider>().isConnected;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Manual Mode toggle — requires device connection to change
                  AnimatedBuilder(
                    animation: _flashAnimation,
                    builder: (context, child) {
                      final t = _flashAnimation.value;
                      final baseBorder = _manualMode
                          ? Colors.deepPurpleAccent.withOpacity(0.4)
                          : Colors.white.withOpacity(0.05);
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _manualMode ? const Color(0xFF2C1F4A) : const Color(0xFF1C1C1E),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Color.lerp(baseBorder, Colors.deepPurpleAccent, t)!),
                          boxShadow: t > 0
                              ? [BoxShadow(color: Colors.deepPurpleAccent.withOpacity(0.35 * t), blurRadius: 14 * t, spreadRadius: 1 * t)]
                              : null,
                        ),
                        child: child,
                      );
                    },
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Manual Recording Mode',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        !isConnected
                            ? 'Connect device to change mode.'
                            : _manualMode
                                ? 'Double-tap to start recording. Double-tap again to stop. Turn off Voice Activity Detection below for unfiltered capture.'
                                : 'Automatic VAD-based recording. Double-tap marks a timestamp.',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                      ),
                      value: _manualMode,
                      onChanged: isConnected
                          ? (value) {
                              setState(() => _manualMode = value);
                              _markDirty();
                            }
                          : null,
                      activeColor: Colors.deepPurpleAccent,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // VAD toggle
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Voice Activity Detection',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        _vadEnabled
                            ? 'Silero VAD classifies each frame as speech or silence.'
                            : 'AAD mode — splits by firmware timestamps only.',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                      ),
                      value: _vadEnabled,
                      onChanged: (value) {
                        setState(() => _vadEnabled = value);
                        _markDirty();
                      },
                      activeColor: Colors.deepPurpleAccent,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Speech Sensitivity (Silero only)
                  if (_vadEnabled) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Speech Sensitivity',
                                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                              DropdownButton<double>(
                                value: _snapToSensitivity(_vadSpeechThreshold),
                                dropdownColor: const Color(0xFF2C2C2E),
                                icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                                underline: const SizedBox(),
                                style: const TextStyle(
                                    color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                                items: _kSpeechSensitivityOptions.map((option) {
                                  return DropdownMenuItem(
                                    value: option.$2,
                                    child: Text(option.$1),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _vadSpeechThreshold = value);
                                    _markDirty();
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Sensitive picks up quiet speech; Strict ignores background noise.',
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Minimum Speech Required',
                                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                              DropdownButton<int>(
                                value: _vadMinSpeechSeconds,
                                dropdownColor: const Color(0xFF2C2C2E),
                                icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                                underline: const SizedBox(),
                                style: const TextStyle(
                                    color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                                items: [0, 3, 10, 30].map((sec) {
                                  return DropdownMenuItem(
                                    value: sec,
                                    child: Text(sec == 0 ? 'Off' : '${sec}s'),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _vadMinSpeechSeconds = value);
                                    _markDirty();
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _vadMinSpeechSeconds == 0
                                ? 'All recordings with any detected speech are kept.'
                                : 'Recordings with less than ${_vadMinSpeechSeconds}s of actual speech will be discarded.',
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Silence to End Conversation
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Silence to End Conversation',
                              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            DropdownButton<int>(
                              value: _vadSplitSeconds,
                              dropdownColor: const Color(0xFF2C2C2E),
                              icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                              underline: const SizedBox(),
                              style: const TextStyle(
                                  color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                              items: [30, 60, 120, 300].map((sec) {
                                return DropdownMenuItem(
                                  value: sec,
                                  child: Text(sec < 60 ? '${sec}s' : '${sec ~/ 60} min'),
                                );
                              }).toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _vadSplitSeconds = value);
                                  _markDirty();
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'How long you need to be quiet before a new conversation begins.',
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
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
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
                              : _discardShortRecordings
                                  ? 'Recordings shorter than ${_formatShortDuration(_filterMinDurationSeconds)} are permanently deleted during processing.'
                                  : 'Recordings shorter than ${_formatShortDuration(_filterMinDurationSeconds)} are hidden from the main list and skipped by integrations.',
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  if (_filterMinDurationSeconds > 0) ...[
                    // Action for Short Recordings
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Action for Short Recordings',
                                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                              DropdownButton<bool>(
                                value: _discardShortRecordings,
                                dropdownColor: const Color(0xFF2C2C2E),
                                icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                                underline: const SizedBox(),
                                style: const TextStyle(
                                    color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                                items: const [
                                  DropdownMenuItem(
                                    value: false,
                                    child: Text('Hide'),
                                  ),
                                  DropdownMenuItem(
                                    value: true,
                                    child: Text('Delete'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _discardShortRecordings = value);
                                    _markDirty();
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _discardShortRecordings
                                ? 'Short recordings will be permanently deleted and cannot be recovered.'
                                : 'Short recordings will be hidden from the main list but remain on the device.',
                            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                          ),
                          if (_discardShortRecordings && widget.onCountShortRecordings != null) ...[
                            const SizedBox(height: 16),
                            GestureDetector(
                              onTap: _handleCleanUp,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2C2C2E),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                                ),
                                child: Center(
                                  child: Text(
                                    'Clean up existing short recordings',
                                    style: TextStyle(
                                        color: Colors.redAccent.shade100, fontSize: 14, fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),

                  // Maximum Conversation Length
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Max Conversation Length',
                              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            DropdownButton<int>(
                              value: _vadMaxConversationMinutes,
                              dropdownColor: const Color(0xFF2C2C2E),
                              icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                              underline: const SizedBox(),
                              style: const TextStyle(
                                  color: Colors.deepPurpleAccent, fontSize: 16, fontWeight: FontWeight.w500),
                              items: [30, 60, 120, 180].map((mins) {
                                return DropdownMenuItem(
                                  value: mins,
                                  child: Text(mins >= 60 ? '${mins ~/ 60}h' : '${mins}m'),
                                );
                              }).toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _vadMaxConversationMinutes = value);
                                  _markDirty();
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Forces a cut if a conversation reaches this duration, even without silence.',
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
