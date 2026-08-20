import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';
import 'package:omi/pages/recordings/integration_status_section.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/pages/recordings/recordings_controller.dart' show RecordingsController, UploadStatus;
import 'package:omi/pages/recordings/waveform_utils.dart';

class ConversationPlayerPage extends StatefulWidget {
  final Conversation conversation;
  final RecordingsController controller;

  const ConversationPlayerPage({super.key, required this.conversation, required this.controller});

  @override
  State<ConversationPlayerPage> createState() => _ConversationPlayerPageState();
}

class _ConversationPlayerPageState extends State<ConversationPlayerPage> {
  final AudioPlayer _player = AudioPlayer();
  final _prefs = SharedPreferencesUtil();
  List<double> _waveform = [];
  bool _loadingWaveform = true;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  bool _isPlaying = false;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playerStateSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _waveform = await _computeWaveform(widget.conversation.file);
    if (mounted) setState(() => _loadingWaveform = false);

    await _player.setFilePath(widget.conversation.file.path);
    final dur = _player.duration ?? widget.conversation.duration;
    if (mounted) setState(() => _total = dur);

    _positionSub = _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _durationSub = _player.durationStream.listen((dur) {
      if (dur != null && mounted) setState(() => _total = dur);
    });
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing && state.processingState != ProcessingState.completed;
        });
      }
    });
  }

  Future<List<double>> _computeWaveform(File file) async {
    try {
      // Check for .meta sidecar (written alongside .m4a files)
      final basePath = file.path.contains('.') ? file.path.substring(0, file.path.lastIndexOf('.')) : file.path;
      final metaFile = File('$basePath.meta');
      if (await metaFile.exists()) {
        final metaBytes = await metaFile.readAsBytes();
        if (metaBytes.length >= 408) {
          final bd = ByteData.sublistView(metaBytes);
          const barCount = 200;
          final amplitudes = <double>[];
          for (int i = 0; i < barCount; i++) {
            final peak = bd.getUint16(8 + i * 2, Endian.little);
            amplitudes.add(peak / 65535.0);
          }
          return normalizeAmplitudes(amplitudes);
        }
      }

      // Legacy WAV fallback: parse raw PCM from byte 44
      final bytes = await file.readAsBytes();
      if (bytes.length <= 44) return [];

      final pcm = Int16List.sublistView(bytes, 44);
      const barCount = 200;
      final samplesPerBar = max(1, pcm.length ~/ barCount);
      final List<double> amplitudes = [];

      for (int i = 0; i < barCount; i++) {
        final start = i * samplesPerBar;
        if (start >= pcm.length) {
          amplitudes.add(0.05);
          continue;
        }
        final end = min(start + samplesPerBar, pcm.length);
        int maxAbs = 0;
        for (int j = start; j < end; j++) {
          final abs = pcm[j].abs();
          if (abs > maxAbs) maxAbs = abs;
        }
        amplitudes.add(maxAbs / 32768.0);
      }
      return normalizeAmplitudes(amplitudes);
    } catch (_) {
      return [];
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > _total
            ? _total
            : target;
    await _player.seek(clamped);
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  Future<void> _assignDate() async {
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
    );
    if (!mounted || date == null) return;

    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (!mounted || time == null) return;

    final newStart = DateTime(date.year, date.month, date.day, time.hour, time.minute);

    try {
      await _player.stop();
      await RecordingsManager.promoteSessionToDate(widget.conversation, newStart);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to assign date.')));
      }
      return;
    }

    RecordingsManager.notifyRecordingsChanged();
    if (mounted) Navigator.of(context).pop();
  }

  /// Puts a phone-corrected recording back where the Omi filed it.
  ///
  /// Offered only when the `.meta` says the phone moved this recording (flag byte [3]
  /// bit 0x20). That gate is the safety property: a timestamp the Omi assigned and the
  /// phone agreed with is never re-datable from here, so the arrow can only ever undo
  /// the app's own work, never a genuine device timestamp.
  Future<void> _revertClockCorrection() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text('Undo date correction', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This recording was re-dated using your phone\'s clock, because the Omi could not '
          'tell what time it was. Undoing puts this recording — and everything else the Omi '
          'recorded in the same session — back to the time the Omi itself recorded, and stops '
          'the app correcting that session again.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Undo', style: TextStyle(color: Colors.amber)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _player.stop();
      await RecordingsManager.revertClockCorrection(widget.conversation);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to undo the date correction.')),
        );
      }
      return;
    }
    // Pop rather than rebuild: the file this page is playing has been renamed out from
    // under it, so the conversation this widget holds no longer names anything on disk.
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _export() async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(widget.conversation.file.path)],
        subject: 'Conversation ${widget.conversation.timeRangeLabel}',
      ),
    );
  }

  /// App-bar upload indicator: a non-interactive summary of the aggregate
  /// upload state. The per-integration detail and actions live in the
  /// Integrations section in the body, so this no longer has a tap action.
  /// Wrapped in a [ListenableBuilder] so it tracks uploads driven from there.
  Widget _buildUploadAction() {
    if (!PassthroughIntegration.hasAnyConfigured(_prefs)) return const SizedBox.shrink();
    final uploadKey = widget.conversation.uploadKey;
    if (uploadKey == null) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (widget.controller.uploadingFiles.contains(uploadKey)) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child:
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          );
        }
        final status = widget.controller.uploadStatus(widget.conversation);
        final color = switch (status) {
          UploadStatus.all => Colors.green,
          UploadStatus.partial => Colors.amber,
          UploadStatus.failed => Colors.orange,
          UploadStatus.none => Colors.redAccent,
          UploadStatus.unavailable => Colors.grey.shade600,
        };
        final tooltip = switch (status) {
          UploadStatus.all => 'Uploaded to all integrations',
          UploadStatus.partial => 'Some integrations pending',
          UploadStatus.failed => 'Upload failed — see Integrations below',
          UploadStatus.none => 'Not uploaded — see Integrations below',
          UploadStatus.unavailable => 'No uploadable file for this recording',
        };
        final icon = switch (status) {
          UploadStatus.all => Icons.cloud_done,
          UploadStatus.failed => Icons.error_outline,
          UploadStatus.unavailable => Icons.cloud_off,
          _ => Icons.cloud_upload,
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Tooltip(message: tooltip, child: Icon(icon, color: color, size: 22)),
        );
      },
    );
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progressRatio =
        _total.inMilliseconds > 0 ? (_position.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        title: Text(
          widget.conversation.timeRangeLabel,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: [
          if (widget.conversation.isUnknown)
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.calendarDays, color: Colors.amber, size: 20),
              onPressed: _assignDate,
              tooltip: 'Assign date',
            ),
          if (widget.conversation.clockCorrected)
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.clockRotateLeft, color: Colors.amber, size: 20),
              onPressed: _revertClockCorrection,
              tooltip: 'Undo date correction',
            ),
          _buildUploadAction(),
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.trashCan, color: Colors.redAccent, size: 20),
            tooltip: 'Delete conversation',
            onPressed: () async {
              bool? confirm = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  backgroundColor: Colors.grey.shade900,
                  title: const Text('Delete Conversation', style: TextStyle(color: Colors.white)),
                  content: const Text('This will permanently delete this conversation. This cannot be undone.',
                      style: TextStyle(color: Colors.white70)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(c).pop(false),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(c).pop(true),
                      child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await _player.stop();
                await RecordingsManager.deleteConversation(widget.conversation);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Deleted conversation from ${widget.conversation.timeRangeLabel}')),
                  );
                  Navigator.of(context).pop();
                }
              }
            },
          ),
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.shareFromSquare, color: Colors.white, size: 20),
            onPressed: _export,
            tooltip: 'Export',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Metadata
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(widget.conversation.durationLabel,
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
                    const SizedBox(width: 16),
                    Container(width: 1, height: 14, color: Colors.grey.shade700),
                    const SizedBox(width: 16),
                    Text(widget.conversation.sizeLabel, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
                  ],
                ),
                const SizedBox(height: 48),

                // Waveform
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: SizedBox(
                    height: 120,
                    child: _loadingWaveform
                        ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent, strokeWidth: 2))
                        : _waveform.isEmpty
                            ? Center(
                                child: Text('Waveform unavailable',
                                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                              )
                            : LayoutBuilder(
                                builder: (ctx, constraints) => GestureDetector(
                                  onTapDown: (d) {
                                    final ratio = (d.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                                    _player.seek(Duration(milliseconds: (ratio * _total.inMilliseconds).round()));
                                  },
                                  onHorizontalDragUpdate: (d) {
                                    final ratio = (d.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
                                    _player.seek(Duration(milliseconds: (ratio * _total.inMilliseconds).round()));
                                  },
                                  child: CustomPaint(
                                    painter: _WaveformPainter(amplitudes: _waveform, progress: progressRatio),
                                    size: Size(constraints.maxWidth, 120),
                                  ),
                                ),
                              ),
                  ),
                ),

                const SizedBox(height: 16),

                // Time labels
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(_position), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                    Text(_fmt(_total), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 4),

                // Progress slider
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: Colors.deepPurpleAccent,
                    inactiveTrackColor: Colors.grey.shade800,
                    thumbColor: Colors.deepPurpleAccent,
                    overlayColor: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    value: progressRatio,
                    onChanged: (v) {
                      _player.seek(Duration(milliseconds: (v * _total.inMilliseconds).round()));
                    },
                  ),
                ),

                const SizedBox(height: 32),

                // Transport controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _SeekButton(
                        icon: FontAwesomeIcons.rotateLeft,
                        seconds: 30,
                        isForward: false,
                        onTap: () => _seekRelative(-30)),
                    const SizedBox(width: 40),
                    Semantics(
                      button: true,
                      label: _isPlaying ? 'Pause' : 'Play',
                      child: Tooltip(
                        message: _isPlaying ? 'Pause' : 'Play',
                        child: Material(
                          color: Colors.deepPurpleAccent,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: _togglePlay,
                            child: SizedBox(
                              width: 72,
                              height: 72,
                              child: Center(
                                child: FaIcon(
                                  _isPlaying ? FontAwesomeIcons.pause : FontAwesomeIcons.play,
                                  color: Colors.white,
                                  size: 26,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 40),
                    _SeekButton(
                        icon: FontAwesomeIcons.rotateRight,
                        seconds: 30,
                        isForward: true,
                        onTap: () => _seekRelative(30)),
                  ],
                ),

                const SizedBox(height: 36),

                // Per-integration upload status + actions (uses the blank space
                // below the controls; replaces the old tap-to-open sheet).
                SizedBox(
                  width: double.infinity,
                  child: IntegrationStatusList(controller: widget.controller, conversation: widget.conversation),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SeekButton extends StatelessWidget {
  final IconData icon;
  final int seconds;
  final bool isForward;
  final VoidCallback onTap;

  const _SeekButton({required this.icon, required this.seconds, required this.isForward, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = 'Seek ${isForward ? 'forward' : 'backward'} ${seconds.abs()} seconds';
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FaIcon(icon, color: Colors.grey.shade300, size: 32),
                  const SizedBox(height: 5),
                  Text(
                    '${seconds}s',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final double progress;

  const _WaveformPainter({required this.amplitudes, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty) return;

    final playedPaint = Paint()
      ..color = Colors.deepPurpleAccent
      ..strokeCap = StrokeCap.round;
    final unplayedPaint = Paint()
      ..color = const Color(0xFF3A3A3C)
      ..strokeCap = StrokeCap.round;

    final barCount = amplitudes.length;
    final spacing = size.width / barCount;
    final barWidth = spacing * 0.55;
    final playedUpTo = (progress * barCount).floor();

    for (int i = 0; i < barCount; i++) {
      final x = i * spacing + spacing / 2;
      final amplitude = amplitudes[i].clamp(0.04, 1.0);
      final barHeight = amplitude * size.height;
      final top = (size.height - barHeight) / 2;
      final paint = i < playedUpTo ? playedPaint : unplayedPaint;
      paint.strokeWidth = barWidth;
      canvas.drawLine(Offset(x, top), Offset(x, top + barHeight), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.progress != progress || old.amplitudes != amplitudes;
}
