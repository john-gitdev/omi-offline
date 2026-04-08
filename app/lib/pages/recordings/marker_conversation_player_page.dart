import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/other/time_utils.dart';

enum _DragMode { none, left, right, seek }

class MarkerConversationPlayerPage extends StatefulWidget {
  final MarkerConversation markerConversation;

  const MarkerConversationPlayerPage({super.key, required this.markerConversation});

  @override
  State<MarkerConversationPlayerPage> createState() => _MarkerConversationPlayerPageState();
}

class _MarkerConversationPlayerPageState extends State<MarkerConversationPlayerPage> {
  final AudioPlayer _player = AudioPlayer();

  late File _segment;
  late Duration _markerOffset;
  late Duration _cropStart;
  late Duration _cropEnd;
  Duration _totalDuration = Duration.zero;

  List<double> _waveform = [];
  bool _loadingWaveform = true;
  bool _loadingAudio = true;

  Duration _position = Duration.zero;
  bool _isPlaying = false;
  double _speed = 1.0;

  _DragMode _dragMode = _DragMode.none;
  late bool _userSaved;

  static const double _kHandleHitSlop = 24.0;

  @override
  void initState() {
    super.initState();
    _segment = widget.markerConversation.segment!;
    _markerOffset = Duration(milliseconds: widget.markerConversation.markerOffsetMs);
    _cropStart = Duration(milliseconds: widget.markerConversation.cropStartMs);
    _cropEnd = Duration(milliseconds: widget.markerConversation.cropEndMs);
    _userSaved = widget.markerConversation.userSaved;
    _init();
  }

  Future<void> _init() async {
    await Future.wait([_loadWaveform(), _setupAudio()]);
    await _player.seek(_markerOffset);
  }

  // ── Waveform ───────────────────────────────────────────────────────────────

  Future<void> _loadWaveform() async {
    final bars = _readMetaWaveform(_segment);
    if (mounted)
      setState(() {
        _waveform = bars;
        _loadingWaveform = false;
      });
  }

  List<double> _readMetaWaveform(File seg) {
    try {
      final base = seg.path.substring(0, seg.path.lastIndexOf('.'));
      final meta = File('$base.meta');
      if (!meta.existsSync()) return List.filled(200, 0.05);
      final bytes = meta.readAsBytesSync();
      if (bytes.length < 408) return List.filled(200, 0.05);
      final bd = ByteData.sublistView(bytes);
      return List.generate(200, (i) => bd.getUint16(8 + i * 2, Endian.little) / 65535.0);
    } catch (_) {
      return List.filled(200, 0.05);
    }
  }

  // ── Audio setup ────────────────────────────────────────────────────────────

  Future<void> _setupAudio() async {
    await _player.setAudioSource(AudioSource.file(_segment.path), initialPosition: _cropStart);

    _totalDuration = Duration(milliseconds: _readSegmentDurationMs(_segment));
    if (mounted) setState(() => _loadingAudio = false);

    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
      // Soft stop at _cropEnd
      if (pos >= _cropEnd && _isPlaying) _player.pause();
    });
    _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing && state.processingState != ProcessingState.completed;
        });
      }
    });
  }

  int _readSegmentDurationMs(File seg) {
    try {
      final base = seg.path.substring(0, seg.path.lastIndexOf('.'));
      final meta = File('$base.meta');
      if (!meta.existsSync()) return 0;
      final bytes = meta.readAsBytesSync();
      if (bytes.length < 8) return 0;
      return ByteData.sublistView(bytes).getUint32(4, Endian.little);
    } catch (_) {
      return 0;
    }
  }

  Future<void> _saveEdl() async {
    final edlData = {
      'markerTimestampMs': widget.markerConversation.markerTime.millisecondsSinceEpoch,
      'segmentFilename': _segment.path.split('/').last,
      'markerOffsetMs': _markerOffset.inMilliseconds,
      'cropStartMs': _cropStart.inMilliseconds,
      'cropEndMs': _cropEnd.inMilliseconds,
      'userSaved': _userSaved,
    };
    await widget.markerConversation.edlFile.writeAsString(jsonEncode(edlData));
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  String get _liveTimeRangeLabel {
    final name = _segment.path.split('/').last;
    final part = name.contains('_') ? name.split('_').last.split('.').first : null;
    final firstMs = part != null ? int.tryParse(part) : 0;
    final origin = DateTime.fromMillisecondsSinceEpoch(firstMs ?? 0);
    return '${fmtHourMin(origin.add(_cropStart))} – ${fmtHourMin(origin.add(_cropEnd))}';
  }

  Future<void> _saveConversation() async {
    setState(() => _userSaved = true);
    await _saveEdl();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved'),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFF1C1C1E),
        ),
      );
    }
  }

  // ── Playback controls ──────────────────────────────────────────────────────

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_position >= _visibleEnd) await _player.seek(_visibleStart);
      await _player.play();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    await _player.seek(target.isNegative ? Duration.zero : target);
  }

  Future<void> _setSpeed(double speed) async {
    await _player.setSpeed(speed);
    setState(() => _speed = speed);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  double get _markerRatio {
    if (_totalDuration.inMilliseconds == 0) return 0;
    final firstMs = _parseSegmentMillis(_segments.first) ?? 0;
    final markerMs = widget.markerConversation.markerTime.millisecondsSinceEpoch;
    final offsetMs = markerMs - firstMs;
    return (offsetMs / _totalDuration.inMilliseconds).clamp(0.0, 1.0);
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final totalMs = _totalDuration.inMilliseconds;
    final progressRatio = totalMs > 0 ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    final visibleStartRatio = totalMs > 0 ? (_cropStart.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    final visibleEndRatio = totalMs > 0 ? (_cropEnd.inMilliseconds / totalMs).clamp(0.0, 1.0) : 1.0;
    final markerOffsetRatio = totalMs > 0 ? (_markerOffset.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        elevation: 0,
        title: Text(
          'marker at ${widget.markerConversation.markerTimeLabel}',
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: FaIcon(
              _userSaved ? FontAwesomeIcons.circleCheck : FontAwesomeIcons.floppyDisk,
              size: 20,
              color: _userSaved ? Colors.green : Colors.grey.shade400,
            ),
            onPressed: _userSaved ? null : _saveConversation,
            tooltip: _userSaved ? 'Saved' : 'Save',
          ),
        ],
      ),
      body: _loadingAudio
          ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Time range label (live — updates during crop drag)
                  Text(
                    _liveTimeRangeLabel,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  ),
                  const SizedBox(height: 32),

                  // Waveform
                  SizedBox(
                    height: 100,
                    child: _loadingWaveform
                        ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent, strokeWidth: 2))
                        : LayoutBuilder(
                            builder: (ctx, constraints) {
                              final width = constraints.maxWidth;
                              final tMs = _totalDuration.inMilliseconds.toDouble();
                              return GestureDetector(
                                onTapDown: (d) {
                                  if (tMs == 0) return;
                                  final r = (d.localPosition.dx / width).clamp(0.0, 1.0);
                                  _player.seek(Duration(milliseconds: (r * tMs).round()));
                                },
                                onHorizontalDragStart: (d) {
                                  if (tMs == 0) return;
                                  final x = d.localPosition.dx;
                                  final vsX = (_cropStart.inMilliseconds / tMs) * width;
                                  final veX = (_cropEnd.inMilliseconds / tMs) * width;
                                  if ((x - vsX).abs() < _kHandleHitSlop) {
                                    setState(() => _dragMode = _DragMode.left);
                                  } else if ((x - veX).abs() < _kHandleHitSlop) {
                                    setState(() => _dragMode = _DragMode.right);
                                  } else {
                                    setState(() => _dragMode = _DragMode.seek);
                                  }
                                },
                                onHorizontalDragUpdate: (d) {
                                  if (tMs == 0) return;
                                  final r = (d.localPosition.dx / width).clamp(0.0, 1.0);
                                  final ms = (r * tMs).round();
                                  if (_dragMode == _DragMode.left) {
                                    final newStart = Duration(milliseconds: ms);
                                    const minWindow = Duration(seconds: 5);
                                    if (newStart >= Duration.zero && newStart < _cropEnd - minWindow) {
                                      setState(() => _cropStart = newStart);
                                    }
                                  } else if (_dragMode == _DragMode.right) {
                                    final newEnd = Duration(milliseconds: ms);
                                    const minWindow = Duration(seconds: 5);
                                    if (newEnd <= _totalDuration && newEnd > _cropStart + minWindow) {
                                      setState(() => _cropEnd = newEnd);
                                    }
                                  } else {
                                    _player.seek(Duration(milliseconds: ms));
                                  }
                                },
                                onHorizontalDragEnd: (_) async {
                                  if (_dragMode == _DragMode.left || _dragMode == _DragMode.right) {
                                    if (_position < _cropStart || _position > _cropEnd) {
                                      await _player.seek(_cropStart);
                                    }
                                    await _saveEdl();
                                  }
                                  if (mounted) setState(() => _dragMode = _DragMode.none);
                                },
                                child: CustomPaint(
                                  painter: _MarkerWaveformPainter(
                                    amplitudes: _waveform,
                                    progress: progressRatio,
                                    visibleStartRatio: visibleStartRatio,
                                    visibleEndRatio: visibleEndRatio,
                                    markerRatio: markerOffsetRatio,
                                    activeDragMode: _dragMode,
                                  ),
                                  size: Size(width, 100),
                                ),
                              );
                            },
                          ),
                  ),

                  const SizedBox(height: 12),

                  // Time labels
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(_position), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                      Text(_fmt(_totalDuration), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
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
                        _player.seek(Duration(milliseconds: (v * totalMs).round()));
                      },
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Transport controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _SeekBtn(icon: FontAwesomeIcons.rotateLeft, seconds: 30, onTap: () => _seekRelative(-30)),
                      const SizedBox(width: 40),
                      GestureDetector(
                        onTap: _togglePlay,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(color: Colors.deepPurpleAccent, shape: BoxShape.circle),
                          child: Center(
                            child: FaIcon(
                              _isPlaying ? FontAwesomeIcons.pause : FontAwesomeIcons.play,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 40),
                      _SeekBtn(icon: FontAwesomeIcons.rotateRight, seconds: 30, onTap: () => _seekRelative(30)),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Speed selector
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [1.0, 1.5, 2.0].map((s) {
                      final selected = _speed == s;
                      return GestureDetector(
                        onTap: () => _setSpeed(s),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected ? Colors.deepPurpleAccent : const Color(0xFF2C2C2E),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            s == 1.0
                                ? '1×'
                                : s == 1.5
                                    ? '1.5×'
                                    : '2×',
                            style: TextStyle(
                              color: selected ? Colors.white : Colors.grey.shade400,
                              fontSize: 13,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 32),

                ],
              ),
            ),
    );
  }
}

// ── Waveform painter ──────────────────────────────────────────────────────────

class _MarkerWaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final double progress;
  final double visibleStartRatio;
  final double visibleEndRatio;
  final double markerRatio;
  final _DragMode activeDragMode;

  const _MarkerWaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.visibleStartRatio,
    required this.visibleEndRatio,
    required this.markerRatio,
    required this.activeDragMode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty) return;

    final barCount = amplitudes.length;
    final spacing = size.width / barCount;
    final barWidth = spacing * 0.55;
    final playedUpTo = (progress * barCount).floor();
    final visStartBar = (visibleStartRatio * barCount).floor();
    final visEndBar = (visibleEndRatio * barCount).ceil();

    final playedInWindow = Paint()
      ..color = Colors.deepPurpleAccent
      ..strokeCap = StrokeCap.round;
    final unplayedInWindow = Paint()
      ..color = const Color(0xFF3A3A3C)
      ..strokeCap = StrokeCap.round;
    final outsideWindow = Paint()
      ..color = const Color(0xFF232323)
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < barCount; i++) {
      final x = i * spacing + spacing / 2;
      final amplitude = amplitudes[i].clamp(0.04, 1.0);
      final barHeight = amplitude * size.height;
      final top = (size.height - barHeight) / 2;

      final inWindow = i >= visStartBar && i < visEndBar;
      final Paint paint;
      if (!inWindow) {
        paint = outsideWindow;
      } else if (i < playedUpTo) {
        paint = playedInWindow;
      } else {
        paint = unplayedInWindow;
      }
      paint.strokeWidth = barWidth;
      canvas.drawLine(Offset(x, top), Offset(x, top + barHeight), paint);
    }

    // Marker position line (amber)
    final markerX = markerRatio * size.width;
    canvas.drawLine(
      Offset(markerX, 0),
      Offset(markerX, size.height),
      Paint()
        ..color = Colors.amber
        ..strokeWidth = 2,
    );

    // Crop handles — vertical line + pill tab at top
    _drawHandle(canvas, size, visibleStartRatio * size.width, activeDragMode == _DragMode.left);
    _drawHandle(canvas, size, visibleEndRatio * size.width, activeDragMode == _DragMode.right);
  }

  void _drawHandle(Canvas canvas, Size size, double x, bool isActive) {
    final color = isActive ? Colors.white : const Color(0xFF8E8E93);
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 1.5,
    );
    // Small pill tab at top to indicate draggability
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, 8), width: 10, height: 16),
        const Radius.circular(3),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_MarkerWaveformPainter old) =>
      old.progress != progress ||
      old.amplitudes != amplitudes ||
      old.visibleStartRatio != visibleStartRatio ||
      old.visibleEndRatio != visibleEndRatio ||
      old.activeDragMode != activeDragMode;
}

// ── Seek button ───────────────────────────────────────────────────────────────

class _SeekBtn extends StatelessWidget {
  final IconData icon;
  final int seconds;
  final VoidCallback onTap;

  const _SeekBtn({required this.icon, required this.seconds, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(icon, color: Colors.grey.shade300, size: 32),
          const SizedBox(height: 5),
          Text('${seconds}s', style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

