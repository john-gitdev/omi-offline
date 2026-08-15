import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/settings/button_config_page.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/logger.dart';
import 'package:provider/provider.dart';

class OfflineAudioSettingsPage extends StatefulWidget {
  final bool flashManualMode;

  const OfflineAudioSettingsPage({
    super.key,
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
  late int _vadMinSpeechSeconds;

  static const List<(String, double)> _kSpeechSensitivityOptions = [
    ('Sensitive', 0.3),
    ('Balanced', 0.5),
    ('Strict', 0.65),
  ];

  static double _snapToSensitivity(double v) =>
      _kSpeechSensitivityOptions.map((o) => o.$2).reduce((a, b) => (a - v).abs() < (b - v).abs() ? a : b);

  bool _isDirty = false;
  bool _isIgnoringBatteryOptimizations = true;

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
    _loadModeFields(_manualMode);
    if (Platform.isAndroid) _checkBatteryOptimization();
  }

  @override
  void dispose() {
    _flashController.dispose();
    super.dispose();
  }

  void _loadModeFields(bool manual) {
    final p = SharedPreferencesUtil();
    if (manual) {
      // Manual mode pins everything except Max Conversation Length: VAD off
      // (firmware-side AAD only), no speech/duration filtering, no discard.
      // The session-end marker is the only boundary signal.
      _vadEnabled = false;
      _vadSpeechThreshold = 0.5;
      _vadMinSpeechSeconds = 0;
      // Any value ≤ 10 collapses to a 0-ms inter-bin gap threshold
      // (max(0, vadSplitSeconds×1000 − firmwareVadHoldMs) where VAD-hold is
      // 10 s), so any positive gap between bins splits. Defensive backup in
      // case the session-end marker fails to land (e.g. SD queue full).
      _vadSplitSeconds = 0;
      _vadMaxConversationMinutes = p.manualModeVadMaxConversationMinutes;
    } else {
      _vadEnabled = p.autoModeVadEnabled;
      _vadSpeechThreshold = _snapToSensitivity(p.autoModeVadSpeechThreshold);
      _vadMinSpeechSeconds = p.autoModeVadMinSpeechSeconds;
      _vadSplitSeconds = p.autoModeVadSplitSeconds;
      _vadMaxConversationMinutes = p.autoModeVadMaxConversationMinutes;
    }
  }

  void _saveModeSnapshot(bool manual) {
    final p = SharedPreferencesUtil();
    if (manual) {
      // Only Max Conversation Length is user-tunable in manual mode.
      p.manualModeVadMaxConversationMinutes = _vadMaxConversationMinutes;
    } else {
      p.autoModeVadEnabled = _vadEnabled;
      p.autoModeVadSpeechThreshold = _vadSpeechThreshold;
      p.autoModeVadMinSpeechSeconds = _vadMinSpeechSeconds;
      p.autoModeVadSplitSeconds = _vadSplitSeconds;
      p.autoModeVadMaxConversationMinutes = _vadMaxConversationMinutes;
    }
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  Future<void> _checkBatteryOptimization() async {
    final v = await Permission.ignoreBatteryOptimizations.isGranted;
    if (mounted) setState(() => _isIgnoringBatteryOptimizations = v);
  }

  /// Returns whether anything was saved. False only when a requested mode switch
  /// couldn't be applied — see below.
  Future<bool> _saveSettings() async {
    final prefs = SharedPreferencesUtil();
    if (_manualMode != prefs.manualMode) {
      // False means the Omi never adopted the mode — it dropped in the window
      // between tapping the toggle and saving, or it did not confirm the write.
      // Writing the mode-dependent prefs anyway would leave the app cutting audio
      // by the new mode's rules while `manualMode` and the device both still say
      // the old one, and with no switch recorded there is no history entry to
      // protect the backlog either. Leave everything as it was and keep the page
      // dirty so the save can be retried.
      if (!await context.read<DeviceProvider>().setManualMode(_manualMode)) {
        Logger.debug('OfflineAudioSettings: mode switch did not take — settings left unchanged.');
        return false;
      }
    }
    prefs.vadEnabled = _vadEnabled;
    prefs.vadSpeechThreshold = _vadSpeechThreshold;
    prefs.vadMinSpeechSeconds = _vadMinSpeechSeconds;
    prefs.vadSplitSeconds = _vadSplitSeconds;
    prefs.vadMaxConversationMinutes = _vadMaxConversationMinutes;
    _saveModeSnapshot(_manualMode);

    if (mounted) setState(() => _isDirty = false);
    return true;
  }

  Future<void> _saveAndPop() async {
    final modeChanged = _manualMode != SharedPreferencesUtil().manualMode;
    final saved = await _saveSettings();
    if (!mounted) return;
    if (!saved) {
      // Stay put rather than popping: the page is still dirty and the edits are
      // still here, so the user can retry once the Omi reconnects. Popping would
      // discard them silently — and silently is how the mode and the processing
      // settings drifted apart in the first place.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't reach your Omi — recording mode unchanged and nothing was saved.")),
      );
      return;
    }
    // Each mode has its own button mapping; nudge the user to review the one
    // that just became active — but only if it actually did.
    if (modeChanged) await _promptReviewButtonConfig(_manualMode);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _promptReviewButtonConfig(bool manual) async {
    final modeLabel = manual ? 'Manual' : 'Auto';
    final review = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: Text('Switched to $modeLabel mode', style: const TextStyle(color: Colors.white)),
        content: Text(
          'Your button actions for $modeLabel mode are now active on the device. '
          'Want to review or change them?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Review')),
        ],
      ),
    );
    if (review == true && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ButtonConfigPage()));
    }
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
                  // Battery optimization warning — only shown on Android when not exempt
                  if (Platform.isAndroid && !_isIgnoringBatteryOptimizations) ...[
                    _BatteryOptimizationCard(onFix: () async {
                      await Permission.ignoreBatteryOptimizations.request();
                      await Future<void>.delayed(const Duration(milliseconds: 500));
                      _checkBatteryOptimization();
                    }),
                    const SizedBox(height: 20),
                  ],
                  // Automatic Mode toggle — requires device connection to change
                  AnimatedBuilder(
                    animation: _flashAnimation,
                    builder: (context, child) {
                      final t = _flashAnimation.value;
                      final autoMode = !_manualMode;
                      final baseBorder = autoMode
                          ? Colors.deepPurpleAccent.withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.05);
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: autoMode ? const Color(0xFF2C1F4A) : const Color(0xFF1C1C1E),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Color.lerp(baseBorder, Colors.deepPurpleAccent, t)!),
                          boxShadow: t > 0
                              ? [
                                  BoxShadow(
                                      color: Colors.deepPurpleAccent.withValues(alpha: 0.35 * t),
                                      blurRadius: 14 * t,
                                      spreadRadius: 1 * t)
                                ]
                              : null,
                        ),
                        child: child,
                      );
                    },
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Automatic Recording Mode',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        !isConnected
                            ? 'Connect device to change mode.'
                            : _manualMode
                                ? 'Double-tap to start recording. Double-tap again to stop. Turn off Voice Activity Detection below for unfiltered capture.'
                                : 'Automatic VAD-based recording. Double-tap marks a timestamp.',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                      ),
                      value: !_manualMode,
                      onChanged: isConnected
                          ? (value) {
                              _saveModeSnapshot(_manualMode);
                              final newManual = !value;
                              setState(() {
                                _manualMode = newManual;
                                _loadModeFields(newManual);
                              });
                              _markDirty();
                            }
                          : null,
                      activeThumbColor: Colors.deepPurpleAccent,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // VAD toggle + Speech Sensitivity (auto mode only)
                  if (!_manualMode) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
                        onChanged: (value) async {
                          if (value) {
                            final skipConfirm = SharedPreferencesUtil().sileroVadSkipConfirm;
                            if (!skipConfirm) {
                              bool doNotShowAgain = false;
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => StatefulBuilder(
                                  builder: (ctx, setDialogState) => AlertDialog(
                                    backgroundColor: const Color(0xFF1C1C1E),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    title: const Text(
                                      'Enable Voice Activity Detection?',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Silero VAD classifies each audio frame as speech or silence. It uses more battery and takes longer to process than the default AAD mode.',
                                          style: TextStyle(color: Colors.white70, fontSize: 14),
                                        ),
                                        const SizedBox(height: 16),
                                        GestureDetector(
                                          onTap: () => setDialogState(() => doNotShowAgain = !doNotShowAgain),
                                          child: Row(
                                            children: [
                                              SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: Checkbox(
                                                  value: doNotShowAgain,
                                                  onChanged: (v) => setDialogState(() => doNotShowAgain = v ?? false),
                                                  activeColor: Colors.deepPurpleAccent,
                                                  side: const BorderSide(color: Colors.grey),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              const Text(
                                                "Don't show again",
                                                style: TextStyle(color: Colors.grey, fontSize: 13),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.of(ctx).pop(false),
                                        child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.of(ctx).pop(true),
                                        child: const Text('Yes', style: TextStyle(color: Colors.deepPurpleAccent)),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                              if (confirm != true) return;
                              if (doNotShowAgain) SharedPreferencesUtil().sileroVadSkipConfirm = true;
                            }
                          }
                          setState(() => _vadEnabled = value);
                          _markDirty();
                        },
                        activeThumbColor: Colors.deepPurpleAccent,
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
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
                  ], // end !_manualMode

                  // Silence to End Conversation (hidden in manual mode — pinned to 0,
                  // which disables the per-frame silence split and collapses the
                  // inter-bin gap threshold to 0; see _loadModeFields)
                  if (!_manualMode)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
                                items: [30, 60, 120, 300, 600].map((sec) {
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
                  if (!_manualMode) const SizedBox(height: 16),

                  // Maximum Conversation Length
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
                              items: [0, 30, 60, 120, 180].map((mins) {
                                return DropdownMenuItem(
                                  value: mins,
                                  child: Text(mins == 0
                                      ? 'No Limit'
                                      : mins >= 60
                                          ? '${mins ~/ 60}h'
                                          : '${mins}m'),
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
                          _vadMaxConversationMinutes == 0
                              ? 'Recordings grow until silence ends them — no time cap.'
                              : 'Forces a cut if a conversation reaches this duration, even without silence.',
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

class _BatteryOptimizationCard extends StatelessWidget {
  final VoidCallback onFix;
  const _BatteryOptimizationCard({required this.onFix});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.battery_alert, color: Colors.redAccent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Background processing may be killed',
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 3),
                Text(
                  'Battery optimization is active. Android can stop processing when the screen turns off. '
                  'Tap Fix, then select \"Don\'t optimize\" to allow background operation.',
                  style: TextStyle(color: Colors.red.shade300, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onFix,
            style: TextButton.styleFrom(
              backgroundColor: Colors.redAccent.withValues(alpha: 0.18),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child:
                const Text('Fix', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
