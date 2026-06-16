import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/other/time_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:omi/pages/recordings/waveform_utils.dart';

enum _DragMode { none, left, right, seek }

class MarkerConversationPlayerPage extends StatefulWidget {
  final MarkerConversation markerConversation;

  const MarkerConversationPlayerPage({super.key, required this.markerConversation});

  @override
  State<MarkerConversationPlayerPage> createState() => _MarkerConversationPlayerPageState();
}

class _MarkerConversationPlayerPageState extends State<MarkerConversationPlayerPage> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  File? _segment;
  late Duration _markerOffset;
  late Duration _cropStart;
  late Duration _cropEnd;
  Duration _totalDuration = Duration.zero;

  List<double> _waveform = [];
  bool _loadingWaveform = true;
  bool _loadingAudio = true;
  bool _isExporting = false;

  Duration _position = Duration.zero;
  bool _isPlaying = false;

  _DragMode _dragMode = _DragMode.none;
  late bool _userSaved;
  bool _isCropMode = false;

  static const double _kHandleHitSlop = 24.0;

  @override
  void initState() {
    super.initState();
    // Pending markers can legitimately reach this page (e.g. deep links or
    // future entry points); guard against a null segment and fall back to a
    // read-only "no audio yet" state instead of crashing (B11).
    _segment = widget.markerConversation.segment;
    _markerOffset = Duration(milliseconds: widget.markerConversation.markerOffsetMs);
    _cropStart = Duration(milliseconds: widget.markerConversation.cropStartMs);
    _cropEnd = Duration(milliseconds: widget.markerConversation.cropEndMs);
    _userSaved = widget.markerConversation.userSaved;
    if (_segment == null) {
      _loadingAudio = false;
      _loadingWaveform = false;
      return;
    }
    _init();
  }

  Future<void> _init() async {
    final seg = _segment;
    if (seg == null) return;
    await Future.wait([_loadWaveform(seg), _setupAudio(seg)]);
    await _player.seek(_markerOffset);
  }

  // ── Waveform ───────────────────────────────────────────────────────────────

  Future<void> _loadWaveform(File seg) async {
    final bars = _readMetaWaveform(seg);
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
      final raw = List.generate(200, (i) => bd.getUint16(8 + i * 2, Endian.little) / 65535.0);
      return normalizeAmplitudes(raw);
    } catch (_) {
      return List.filled(200, 0.05);
    }
  }

  // ── Audio setup ────────────────────────────────────────────────────────────

  Future<void> _setupAudio(File seg) async {
    await _player.setAudioSource(AudioSource.file(seg.path), initialPosition: _cropStart);

    _totalDuration = Duration(milliseconds: _readSegmentDurationMs(seg));
    if (mounted) setState(() => _loadingAudio = false);

    _positionSub = _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
      // Soft stop at _cropEnd
      if (pos >= _cropEnd && _isPlaying) _player.pause();
    });
    _playerStateSub = _player.playerStateStream.listen((state) {
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
    final seg = _segment;
    if (seg == null) return;
    final edlData = {
      'markerTimestampMs': widget.markerConversation.markerTime.millisecondsSinceEpoch,
      'segmentFilename': seg.path.split('/').last,
      'markerOffsetMs': _markerOffset.inMilliseconds,
      'cropStartMs': _cropStart.inMilliseconds,
      'cropEndMs': _cropEnd.inMilliseconds,
      'userSaved': _userSaved,
    };
    // Atomic (tmp + rename) so a concurrent getMarkerConversations() refresh
    // never reads a half-written EDL, and an app kill mid-save can't corrupt it.
    await RecordingsManager.writeJsonAtomic(widget.markerConversation.edlFile, edlData);
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  /// Pulls the epoch-ms timestamp from a recording filename, tolerating both
  /// `recording_<ts>.<ext>` and `recording_<ts>_draft.<ext>` shapes (and any
  /// future trailing segment) by scanning components for the first plausible
  /// numeric epoch (B12).
  int _extractTimestampMsFromFilename(String filename) {
    final nameNoExt = filename.contains('.') ? filename.substring(0, filename.lastIndexOf('.')) : filename;
    for (final part in nameNoExt.split('_')) {
      final n = int.tryParse(part);
      if (n != null && n > 946684800000) return n;
    }
    return 0;
  }

  String get _liveTimeRangeLabel {
    final seg = _segment;
    if (seg == null) {
      // Orphan / pending marker: anchor the range label on the marker tap itself.
      final m = widget.markerConversation.markerTime;
      return '${fmtHourMin(m)} – ${fmtHourMin(m)}';
    }
    final firstMs = _extractTimestampMsFromFilename(seg.path.split('/').last);
    final origin = DateTime.fromMillisecondsSinceEpoch(firstMs);
    return '${fmtHourMin(origin.add(_cropStart))} – ${fmtHourMin(origin.add(_cropEnd))}';
  }

  Future<void> _saveConversation() async {
    setState(() {
      _userSaved = true;
      _isCropMode = false;
    });
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

  void _toggleCropMode() {
    if (_isCropMode) {
      _saveConversation();
    } else {
      setState(() {
        _isCropMode = true;
        _cropStart = Duration.zero;
        _cropEnd = _totalDuration;
      });
    }
  }

  Future<void> _exportConversation() async {
    final seg = _segment;
    if (seg == null || _isExporting) return;
    setState(() => _isExporting = true);

    try {
      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = seg.path.split('.').last;
      final outputPath = '${dir.path}/export_$timestamp.$extension';

      final startSec = _cropStart.inMilliseconds / 1000.0;
      final durationSec = (_cropEnd - _cropStart).inMilliseconds / 1000.0;

      // -ss is the start offset, -t is the duration
      // -c copy allows fast trimming without re-encoding
      final command = '-y -i "${seg.path}" -ss $startSec -t $durationSec -c copy "$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(outputPath)],
            subject: 'Conversation Export',
          ),
        );
      } else {
        final logs = await session.getLogs();
        throw Exception('FFmpeg failed: ${logs.last.getMessage()}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  // ── Playback controls ──────────────────────────────────────────────────────

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_position >= _cropEnd) await _player.seek(_cropStart);
      await _player.play();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    await _player.seek(target.isNegative ? Duration.zero : target);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _positionSub?.cancel();
    _playerStateSub?.cancel();
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

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // Discard changes logic: we just don't call _saveEdl()
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D0D),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0D0D),
          elevation: 0,
          title: Text(
            'Marker at ${widget.markerConversation.markerTimeLabel}',
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          actions: [
            if (_isExporting)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.trashCan, color: Colors.redAccent, size: 20),
              tooltip: 'Delete marker',
              onPressed: () async {
                bool? confirm = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    backgroundColor: Colors.grey.shade900,
                    title: const Text('Delete Marker', style: TextStyle(color: Colors.white)),
                    content: const Text('This will permanently delete this marker.',
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
                  await RecordingsManager.deleteMarkerConversation(widget.markerConversation);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Deleted Marker at ${widget.markerConversation.markerTimeLabel}')),
                    );
                    Navigator.of(context).pop();
                  }
                }
              },
            ),
            // Hide Export and Crop buttons when there's no audio attached —
            // tapping them was a no-op that misleadingly flipped _userSaved
            // in memory without persisting anything (E6).
            if (_segment != null)
              IconButton(
                icon: const FaIcon(FontAwesomeIcons.shareFromSquare, size: 20, color: Colors.white),
                onPressed: _exportConversation,
                tooltip: 'Export',
              ),
            if (_segment != null)
              IconButton(
                icon: FaIcon(
                  _isCropMode
                      ? FontAwesomeIcons.floppyDisk
                      : (_userSaved ? FontAwesomeIcons.circleCheck : FontAwesomeIcons.scissors),
                  size: 20,
                  color: _isCropMode ? Colors.amber : (_userSaved ? Colors.green : Colors.white),
                ),
                onPressed: _toggleCropMode,
                tooltip: _isCropMode ? 'Save' : (_userSaved ? 'Saved' : 'Crop'),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: _segment == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FaIcon(FontAwesomeIcons.solidBookmark, color: Colors.amber, size: 32),
                        const SizedBox(height: 16),
                        Text(
                          'Marker recorded at ${widget.markerConversation.markerTimeLabel}',
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No audio is attached to this marker. The surrounding audio was either silence or has not yet been processed.',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : _loadingAudio
                  ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent))
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 24),
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
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: SizedBox(
                              height: 100,
                              child: _loadingWaveform
                                  ? const Center(
                                      child: CircularProgressIndicator(color: Colors.deepPurpleAccent, strokeWidth: 2))
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
                                            if (_isCropMode) {
                                              final vsX = (_cropStart.inMilliseconds / tMs) * width;
                                              final veX = (_cropEnd.inMilliseconds / tMs) * width;
                                              if ((x - vsX).abs() < _kHandleHitSlop) {
                                                setState(() => _dragMode = _DragMode.left);
                                              } else if ((x - veX).abs() < _kHandleHitSlop) {
                                                setState(() => _dragMode = _DragMode.right);
                                              } else {
                                                setState(() => _dragMode = _DragMode.seek);
                                              }
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
                                              isCropMode: _isCropMode,
                                            ),
                                            size: Size(width, 100),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Time labels
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_fmt(_position), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                                Text(_fmt(_totalDuration), style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 4),

                          // Progress slider
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: SliderTheme(
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
                          ),
                          const SizedBox(height: 24),

                          // Transport controls
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _SeekBtn(
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
                              _SeekBtn(
                                  icon: FontAwesomeIcons.rotateRight,
                                  seconds: 30,
                                  isForward: true,
                                  onTap: () => _seekRelative(30)),
                            ],
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
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
  final bool isCropMode;

  const _MarkerWaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.visibleStartRatio,
    required this.visibleEndRatio,
    required this.markerRatio,
    required this.activeDragMode,
    required this.isCropMode,
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

      final inWindow = !isCropMode || (i >= visStartBar && i < visEndBar);
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

    if (isCropMode) {
      // Crop handles — vertical line + pill tab at top
      _drawHandle(canvas, size, visibleStartRatio * size.width, activeDragMode == _DragMode.left);
      _drawHandle(canvas, size, visibleEndRatio * size.width, activeDragMode == _DragMode.right);
    }
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
      old.activeDragMode != activeDragMode ||
      old.isCropMode != isCropMode;
}

// ── Seek button ───────────────────────────────────────────────────────────────

class _SeekBtn extends StatelessWidget {
  final IconData icon;
  final int seconds;
  final bool isForward;
  final VoidCallback onTap;

  const _SeekBtn({required this.icon, required this.seconds, required this.isForward, required this.onTap});

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
                  Text('${seconds}s',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
