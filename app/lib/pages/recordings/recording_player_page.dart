import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/widgets/split_method_badge.dart';

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

  RecordingTranscript? _transcript;
  bool _transcriptLoading = true;
  bool _transcriptExpanded = false;

  /// Index of the word currently being spoken, or -1 when not playing.
  int _activeWordIndex = -1;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Load waveform and transcript concurrently
    final results = await Future.wait([
      _computeWaveform(widget.recording.file),
      RecordingInfo.loadTranscript(widget.recording.file),
    ]);

    if (mounted) {
      setState(() {
        _waveform = results[0] as List<double>;
        _loadingWaveform = false;
        _transcript = results[1] as RecordingTranscript?;
        _transcriptLoading = false;
        // Auto-expand if transcript has words
        if (_transcript != null && _transcript!.words.isNotEmpty) {
          _transcriptExpanded = true;
        }
      });
    }

    await _player.setFilePath(widget.recording.file.path);
    final dur = _player.duration ?? widget.recording.duration;
    if (mounted) setState(() => _total = dur);

    _player.positionStream.listen((pos) {
      if (!mounted) return;
      final newIndex = _transcript != null && _transcript!.words.isNotEmpty
          ? _findActiveWordIndex(_transcript!.words, pos.inMilliseconds / 1000.0)
          : -1;
      setState(() {
        _position = pos;
        _activeWordIndex = newIndex;
      });
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

  /// Binary search for the word currently under the playhead.
  /// Returns -1 when the position falls outside all word spans.
  int _findActiveWordIndex(List<TranscriptWord> words, double positionSecs) {
    int lo = 0;
    int hi = words.length - 1;

    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final w = words[mid];
      if (positionSecs < w.start) {
        hi = mid - 1;
      } else if (positionSecs > w.end) {
        lo = mid + 1;
      } else {
        return mid; // position is within [start, end]
      }
    }
    return -1;
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

  Future<void> _exportAudio() async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(widget.recording.file.path)],
        subject: 'Recording ${widget.recording.timeRangeLabel}',
      ),
    );
  }

  Future<void> _exportTranscript() async {
    final transcript = _transcript;
    if (transcript == null || transcript.text == null) return;

    final dir = await getTemporaryDirectory();
    final ts = widget.recording.startTime.millisecondsSinceEpoch;
    final txtFile = File('${dir.path}/transcript_$ts.txt');
    await txtFile.writeAsString(transcript.text!);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(txtFile.path)],
        subject: 'Transcript ${widget.recording.timeRangeLabel}',
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
          // Export audio
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.shareFromSquare, color: Colors.white, size: 20),
            onPressed: _exportAudio,
            tooltip: 'Export Audio',
          ),
          // Export transcript (only shown when transcript with text is present)
          if (_transcript?.text != null)
            IconButton(
              key: const Key('export_transcript'),
              icon: const FaIcon(FontAwesomeIcons.fileLines, color: Colors.white, size: 20),
              onPressed: _exportTranscript,
              tooltip: 'Export Transcript',
            ),
        ],
      ),
      body: Column(
        children: [
          // Player section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Metadata row
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(widget.recording.durationLabel, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
                    const SizedBox(width: 16),
                    Container(width: 1, height: 14, color: Colors.grey.shade700),
                    const SizedBox(width: 16),
                    Text(widget.recording.sizeLabel, style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
                    if (widget.recording.splitMethod != null) ...[
                      const SizedBox(width: 16),
                      Container(width: 1, height: 14, color: Colors.grey.shade700),
                      const SizedBox(width: 16),
                      SplitMethodBadge(method: widget.recording.splitMethod!),
                    ],
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
                              child: Text(
                                'Waveform unavailable',
                                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                              ),
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
                        decoration:
                            const BoxDecoration(color: Colors.deepPurpleAccent, shape: BoxShape.circle),
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

          // Transcription panel
          if (!_transcriptLoading)
            Expanded(
              child: _TranscriptionPanel(
                transcript: _transcript,
                activeWordIndex: _activeWordIndex,
                expanded: _transcriptExpanded,
                onToggle: () => setState(() => _transcriptExpanded = !_transcriptExpanded),
                onWordTap: (word) {
                  _player.seek(Duration(milliseconds: (word.start * 1000).round()));
                },
              ),
            )
          else
            const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transcription panel
// ---------------------------------------------------------------------------

class _TranscriptionPanel extends StatefulWidget {
  final RecordingTranscript? transcript;
  final int activeWordIndex;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<TranscriptWord> onWordTap;

  const _TranscriptionPanel({
    required this.transcript,
    required this.activeWordIndex,
    required this.expanded,
    required this.onToggle,
    required this.onWordTap,
  });

  @override
  State<_TranscriptionPanel> createState() => _TranscriptionPanelState();
}

class _TranscriptionPanelState extends State<_TranscriptionPanel> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(_TranscriptionPanel old) {
    super.didUpdateWidget(old);
    // Auto-scroll to keep the active word visible
    if (widget.activeWordIndex != old.activeWordIndex && widget.activeWordIndex >= 0 && widget.expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
  }

  void _scrollToActive() {
    if (!_scrollController.hasClients) return;
    final words = widget.transcript?.words;
    if (words == null || widget.activeWordIndex >= words.length) return;
    // Each word chip is approximately 40px wide with 4px gap; rough estimate
    final estimatedOffset = widget.activeWordIndex * 44.0;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final target = estimatedOffset.clamp(0.0, maxScroll);
    _scrollController.animateTo(target, duration: const Duration(milliseconds: 100), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transcript = widget.transcript;
    final hasTranscript = transcript != null && transcript.words.isNotEmpty;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header bar — always visible, tap to expand/collapse
          GestureDetector(
            key: const Key('transcript_panel_toggle'),
            onTap: hasTranscript ? widget.onToggle : null,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const FaIcon(FontAwesomeIcons.alignLeft, color: Colors.deepPurpleAccent, size: 14),
                  const SizedBox(width: 10),
                  const Text(
                    'Transcription',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (!hasTranscript)
                    Text(
                      transcript == null ? 'Not available' : 'VAD — no transcript',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    )
                  else
                    FaIcon(
                      widget.expanded ? FontAwesomeIcons.chevronDown : FontAwesomeIcons.chevronUp,
                      color: Colors.grey.shade500,
                      size: 12,
                    ),
                ],
              ),
            ),
          ),

          if (hasTranscript && widget.expanded) ...[
            const Divider(color: Color(0xFF2C2C2E), height: 1),
            Expanded(
              child: _WordFlow(
                words: transcript.words,
                activeWordIndex: widget.activeWordIndex,
                scrollController: _scrollController,
                onWordTap: widget.onWordTap,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Renders the word list as a flowing wrap of tappable word chips.
/// Words are highlighted as the playhead moves through them.
class _WordFlow extends StatelessWidget {
  final List<TranscriptWord> words;
  final int activeWordIndex;
  final ScrollController scrollController;
  final ValueChanged<TranscriptWord> onWordTap;

  const _WordFlow({
    required this.words,
    required this.activeWordIndex,
    required this.scrollController,
    required this.onWordTap,
  });

  // Speaker colours — cycles through 4 muted tones.
  static const _speakerColors = [
    Color(0xFF7B68EE), // medium slate blue
    Color(0xFF48CFAD), // turquoise
    Color(0xFFFFCE54), // amber
    Color(0xFFFC6E51), // coral
  ];

  Color _speakerColor(int speaker) => _speakerColors[speaker % _speakerColors.length];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('transcript_scroll'),
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Wrap(
        spacing: 4,
        runSpacing: 6,
        children: List.generate(words.length, (i) {
          final word = words[i];
          final isActive = i == activeWordIndex;
          final color = _speakerColor(word.speaker);
          return GestureDetector(
            onTap: () => onWordTap(word),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              decoration: BoxDecoration(
                color: isActive ? color.withValues(alpha: 0.25) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                word.word,
                style: TextStyle(
                  color: isActive ? color : color.withValues(alpha: 0.7),
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Seek button
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Waveform painter
// ---------------------------------------------------------------------------

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
