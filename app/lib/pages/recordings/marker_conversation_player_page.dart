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

  // Mutable playback state — updated on extend
  late List<File> _segments;
  late Duration _visibleStart;
  late Duration _visibleEnd;
  Duration _totalDuration = Duration.zero;

  List<double> _waveform = [];
  bool _loadingWaveform = true;
  bool _loadingAudio = true;

  Duration _position = Duration.zero;
  bool _isPlaying = false;
  double _speed = 1.0;

  bool _canExtendLeft = false;
  bool _canExtendRight = false;
  bool _isExtending = false;

  _DragMode _dragMode = _DragMode.none;
  late bool _userSaved;

  static const double _kHandleHitSlop = 24.0;

  @override
  void initState() {
    super.initState();
    _segments = List.of(widget.markerConversation.segments);
    _visibleStart = widget.markerConversation.visibleStart;
    _visibleEnd = widget.markerConversation.visibleEnd;
    _userSaved = widget.markerConversation.userSaved;
    _init();
  }

  Future<void> _init() async {
    await Future.wait([_loadWaveform(), _setupAudio()]);
    await _checkExtendability();
  }

  // ── Waveform ───────────────────────────────────────────────────────────────

  Future<void> _loadWaveform() async {
    final bars = <double>[];
    for (final seg in _segments) {
      bars.addAll(_readMetaWaveform(seg));
    }
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
    final source = _buildSource();
    await _player.setAudioSource(source, initialPosition: _visibleStart);

    _totalDuration = _computeTotalDuration();
    if (mounted) setState(() => _loadingAudio = false);

    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
      // Soft stop at visibleEnd
      if (pos >= _visibleEnd && _isPlaying) _player.pause();
    });
    _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing && state.processingState != ProcessingState.completed;
        });
      }
    });
  }

  AudioSource _buildSource() {
    if (_segments.length == 1) return AudioSource.file(_segments[0].path);
    return ConcatenatingAudioSource(
      children: _segments.map((f) => AudioSource.file(f.path)).toList(),
    );
  }

  Duration _computeTotalDuration() {
    int total = 0;
    for (final seg in _segments) {
      total += _readSegmentDurationMs(seg);
    }
    return Duration(milliseconds: total);
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

  static int? _parseSegmentMillis(File f) {
    final name = f.path.split('/').last;
    final part = name.contains('_') ? name.split('_').last.split('.').first : null;
    return part != null ? int.tryParse(part) : null;
  }

  // ── Extend ─────────────────────────────────────────────────────────────────

  Future<void> _checkExtendability() async {
    final left = await _findAdjacentSegment(left: true);
    final right = await _findAdjacentSegment(left: false);
    if (mounted)
      setState(() {
        _canExtendLeft = left != null;
        _canExtendRight = right != null;
      });
  }

  Future<File?> _findAdjacentSegment({required bool left}) async {
    final dateFolder = widget.markerConversation.edlFile.parent;
    final all = dateFolder.listSync().whereType<File>().where((f) => f.path.endsWith('.m4a')).toList()
      ..sort((a, b) => (_parseSegmentMillis(a) ?? 0).compareTo(_parseSegmentMillis(b) ?? 0));

    if (left) {
      final firstMs = _parseSegmentMillis(_segments.first) ?? 0;
      final idx = all.indexWhere((f) => (_parseSegmentMillis(f) ?? 0) == firstMs);
      return idx > 0 ? all[idx - 1] : null;
    } else {
      final lastMs = _parseSegmentMillis(_segments.last) ?? 0;
      final idx = all.indexWhere((f) => (_parseSegmentMillis(f) ?? 0) == lastMs);
      return (idx >= 0 && idx < all.length - 1) ? all[idx + 1] : null;
    }
  }

  Future<void> _extendLeft() async {
    if (_isExtending) return;
    final prev = await _findAdjacentSegment(left: true);
    if (prev == null) return;

    setState(() => _isExtending = true);
    try {
      final prevMs = _readSegmentDurationMs(prev);
      final prevDuration = Duration(milliseconds: prevMs);
      final savedPosition = _position;

      setState(() {
        _segments = [prev, ..._segments];
        // Shift both crop points right by prevDuration to preserve absolute times.
        _visibleStart = _visibleStart + prevDuration;
        _visibleEnd = _visibleEnd + prevDuration;
      });

      await _saveEdl();
      await _reloadAudio(seekTo: savedPosition + prevDuration);
      await _loadWaveform();
      await _checkExtendability();
    } finally {
      if (mounted) setState(() => _isExtending = false);
    }
  }

  Future<void> _extendRight() async {
    if (_isExtending) return;
    final next = await _findAdjacentSegment(left: false);
    if (next == null) return;

    setState(() => _isExtending = true);
    try {
      final nextMs = _readSegmentDurationMs(next);
      final savedPosition = _position;

      setState(() {
        _segments = [..._segments, next];
        // Expand visibleEnd to include the new segment.
        _visibleEnd = _visibleEnd + Duration(milliseconds: nextMs);
      });

      await _saveEdl();
      await _reloadAudio(seekTo: savedPosition);
      await _loadWaveform();
      await _checkExtendability();
    } finally {
      if (mounted) setState(() => _isExtending = false);
    }
  }

  Future<void> _reloadAudio({required Duration seekTo}) async {
    await _player.setAudioSource(_buildSource(), initialPosition: seekTo);
    _totalDuration = _computeTotalDuration();
    if (mounted) setState(() {});
  }

  Future<void> _saveEdl() async {
    final edlData = {
      'markerTimestampMs': widget.markerConversation.markerTime.millisecondsSinceEpoch,
      'segments': _segments.map((f) => f.path.split('/').last).toList(),
      'visibleStartMs': _visibleStart.inMilliseconds,
      'visibleEndMs': _visibleEnd.inMilliseconds,
      'userSaved': _userSaved,
    };
    await widget.markerConversation.edlFile.writeAsString(jsonEncode(edlData));
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  String get _liveTimeRangeLabel {
    if (_segments.isEmpty) return widget.markerConversation.timeRangeLabel;
    final firstMs = _parseSegmentMillis(_segments.first) ?? 0;
    final origin = DateTime.fromMillisecondsSinceEpoch(firstMs);
    return '${fmtHourMin(origin.add(_visibleStart))} – ${fmtHourMin(origin.add(_visibleEnd))}';
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
    final visibleStartRatio = totalMs > 0 ? (_visibleStart.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    final visibleEndRatio = totalMs > 0 ? (_visibleEnd.inMilliseconds / totalMs).clamp(0.0, 1.0) : 1.0;

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
                                  final vsX = (_visibleStart.inMilliseconds / tMs) * width;
                                  final veX = (_visibleEnd.inMilliseconds / tMs) * width;
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
                                    const minWindow = Duration(seconds: 30);
                                    if (newStart >= Duration.zero && newStart < _visibleEnd - minWindow) {
                                      setState(() => _visibleStart = newStart);
                                    }
                                  } else if (_dragMode == _DragMode.right) {
                                    final newEnd = Duration(milliseconds: ms);
                                    const minWindow = Duration(seconds: 30);
                                    if (newEnd <= _totalDuration && newEnd > _visibleStart + minWindow) {
                                      setState(() => _visibleEnd = newEnd);
                                    }
                                  } else {
                                    _player.seek(Duration(milliseconds: ms));
                                  }
                                },
                                onHorizontalDragEnd: (_) async {
                                  if (_dragMode == _DragMode.left || _dragMode == _DragMode.right) {
                                    if (_position < _visibleStart || _position > _visibleEnd) {
                                      await _player.seek(_visibleStart);
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
                                    markerRatio: _markerRatio,
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

                  // Extend buttons
                  if (_canExtendLeft || _canExtendRight)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_canExtendLeft)
                          _ExtendButton(
                            label: '← Extend',
                            loading: _isExtending,
                            onTap: _extendLeft,
                          ),
                        if (_canExtendLeft && _canExtendRight) const SizedBox(width: 16),
                        if (_canExtendRight)
                          _ExtendButton(
                            label: 'Extend →',
                            loading: _isExtending,
                            onTap: _extendRight,
                          ),
                      ],
                    ),
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

// ── Extend button ─────────────────────────────────────────────────────────────

class _ExtendButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback onTap;

  const _ExtendButton({required this.label, required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.deepPurpleAccent),
              )
            : Text(label, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
      ),
    );
  }
}
