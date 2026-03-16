import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:omi/services/recordings_manager.dart';

class RecordingPlayerPage extends StatefulWidget {
  final RecordingInfo recording;

  const RecordingPlayerPage({super.key, required this.recording});

  @override
  State<RecordingPlayerPage> createState() => _RecordingPlayerPageState();
}

class _RecordingPlayerPageState extends State<RecordingPlayerPage> {
  final AudioPlayer _player = AudioPlayer();
  List<double> _waveform = [];
  bool _loadingWaveform = true;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _waveform = await _computeWaveform(widget.recording.file);
    if (mounted) setState(() => _loadingWaveform = false);

    await _player.setFilePath(widget.recording.file.path);
    final dur = _player.duration ?? widget.recording.duration;
    if (mounted) setState(() => _total = dur);

    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (dur != null && mounted) setState(() => _total = dur);
    });
    _player.playerStateStream.listen((state) {
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
      final basePath = file.path.contains('.')
          ? file.path.substring(0, file.path.lastIndexOf('.'))
          : file.path;
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
          return amplitudes;
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
      return amplitudes;
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

  Future<void> _export() async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(widget.recording.file.path)],
        subject: 'Recording ${widget.recording.timeRangeLabel}',
      ),
    );
  }

  @override
  void dispose() {
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
          widget.recording.timeRangeLabel,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.shareFromSquare, color: Colors.white, size: 20),
            onPressed: _export,
            tooltip: 'Export',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Metadata
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(widget.recording.durationLabel, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
                const SizedBox(width: 16),
                Container(width: 1, height: 14, color: Colors.grey.shade700),
                const SizedBox(width: 16),
                Text(widget.recording.sizeLabel, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 48),

            // Waveform
            SizedBox(
              height: 120,
              child: _loadingWaveform
                  ? const Center(child: CircularProgressIndicator(color: Colors.deepPurpleAccent, strokeWidth: 2))
                  : _waveform.isEmpty
                      ? Center(
                          child:
                              Text('Waveform unavailable', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
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
                _SeekButton(icon: FontAwesomeIcons.rotateLeft, seconds: 30, onTap: () => _seekRelative(-30)),
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
                _SeekButton(icon: FontAwesomeIcons.rotateRight, seconds: 30, onTap: () => _seekRelative(30)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SeekButton extends StatelessWidget {
  final IconData icon;
  final int seconds;
  final VoidCallback onTap;

  const _SeekButton({required this.icon, required this.seconds, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
