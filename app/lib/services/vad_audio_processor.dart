import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:omi/utils/logger.dart';

/// All VAD/processing settings captured from SharedPreferences in the main isolate
/// before spawning the processing isolate. All fields are primitives — safe to send
/// across isolate boundaries.
class ProcessingSettings {
  final bool vadEnabled;
  final double speechThreshold;
  final int silenceDurationToSplitMs;
  final int minDurationMs;
  final int minSpeechMs;
  final bool discardShort;
  final int maxChunkMs;
  final String deviceId; // used to generate upload key in .meta sidecar
  final String audioSaveFormat;
  final bool omiEnabled;

  const ProcessingSettings({
    required this.vadEnabled,
    required this.speechThreshold,
    required this.silenceDurationToSplitMs,
    required this.minDurationMs,
    required this.minSpeechMs,
    required this.discardShort,
    required this.maxChunkMs,
    required this.deviceId,
    required this.audioSaveFormat,
    required this.omiEnabled,
  });

  factory ProcessingSettings.fromPrefs() {
    final p = SharedPreferencesUtil();
    return ProcessingSettings(
      vadEnabled: p.vadEnabled,
      speechThreshold: p.vadSpeechThreshold,
      silenceDurationToSplitMs: p.vadSplitSeconds * 1000,
      minDurationMs: p.filterMinDurationSeconds * 1000,
      minSpeechMs: p.vadMinSpeechSeconds * 1000,
      discardShort: p.discardShortRecordings,
      maxChunkMs: p.vadMaxConversationMinutes * 60 * 1000,
      deviceId: p.btDevice.id,
      audioSaveFormat: p.audioSaveFormat,
      omiEnabled: p.omiEnabled,
    );
  }
}

class VadAudioProcessor {
  // Silero VAD session + LSTM state (reset on gap detection)
  OrtSession? _session;
  Float32List _h = Float32List(2 * 1 * 64); // LSTM hidden state
  Float32List _c = Float32List(2 * 1 * 64); // LSTM cell state
  final List<double> _pcmWindow = []; // accumulates samples toward 512-window

  // Opus decoder
  final SimpleOpusDecoder? _decoder;
  final String? _outputDir;

  // Per-conversation accumulation — FrameRef disk-pointers only, no Opus in RAM.
  // Can also contain Duration objects representing silence gaps to be padded.
  List<Object> _currentRefs = [];
  int _speechFrameCount = 0; // speech frames in current conversation
  DateTime? _recordingStartTime;
  DateTime? _lastSegmentEndTime;
  bool _isDerivedTimestamp = false; // true when segment had no valid device RTC timestamp
  int? _currentSessionId;
  int? _currentStartUptime;
  int? _currentFrameUptimeMs;
  int? _lastImuTicks;

  // VAD state counters
  int _currentChunkDurationMs = 0; // total frames accumulated (for max-cap)

  /// True after a [flushRemaining] call where the short-recording discard guard
  /// fired (refs were non-empty but below the duration threshold). False if the
  /// guard did not fire (either no refs, or proceeded to save). Test-only.
  @visibleForTesting
  bool discardGuardFiredOnLastFlush = false;

  @visibleForTesting
  int get currentChunkDurationMs => _currentChunkDurationMs;
  // Marker-forced recording state
  bool _forcedByMarker = false;

  // Tracks segment files that have been fully processed. Used by consumeSafeToDeletePaths()
  // to determine which files are no longer referenced by any internal buffer.
  final Set<String> _processedFiles = {};

  // Settings — cached at construction time for the lifetime of one processAll pass
  final double _speechThreshold;
  final int _silenceDurationToSplitMs;
  final int _minDurationMs;
  final int _minSpeechMs;
  final bool _discardShort;
  final int _maxChunkMs;
  final String _deviceId;
  final String _audioSaveFormat;
  final bool _omiEnabled;

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 20; // 20 ms per Opus frame
  static const int _vadWindowSamples = 512; // Silero VAD input size

  /// Creates a processor in the main isolate, reading settings from SharedPreferences.
  static Future<VadAudioProcessor> create({String? outputDir, SimpleOpusDecoder? decoder}) async {
    final settings = ProcessingSettings.fromPrefs();
    OrtSession? session;
    if (settings.vadEnabled) {
      try {
        OrtEnv.instance.init();
      } catch (e) {
        Logger.error("VadAudioProcessor: Failed to init OrtEnv: $e");
      }
      try {
        final data = await rootBundle.load('assets/models/silero_vad.onnx');
        final sessionOptions = OrtSessionOptions();
        session =
            OrtSession.fromBuffer(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), sessionOptions);
      } catch (e) {
        Logger.error('VadAudioProcessor: Failed to load Silero VAD model, AAD mode active: $e');
      }
    }
    Logger.debug(
        'VadAudioProcessor: init — ${session != null ? 'Silero VAD loaded' : 'AAD mode${settings.vadEnabled ? ' (model unavailable)' : ''}'}');
    return VadAudioProcessor._(outputDir: outputDir, decoder: decoder, session: session, settings: settings);
  }

  /// Creates a processor from pre-captured settings — safe to call in a background isolate.
  /// The caller is responsible for initialising OrtEnv and creating [session] / [decoder] before
  /// calling this constructor.
  VadAudioProcessor.fromSettings({
    required ProcessingSettings settings,
    String? outputDir,
    OrtSession? session,
    SimpleOpusDecoder? decoder,
  }) : this._(outputDir: outputDir, decoder: decoder, session: session, settings: settings);

  VadAudioProcessor._(
      {String? outputDir, SimpleOpusDecoder? decoder, OrtSession? session, required ProcessingSettings settings})
      : _session = session,
        _decoder = decoder ??
            (Platform.isIOS || Platform.isAndroid
                ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
                : null),
        _outputDir = outputDir,
        _speechThreshold = settings.speechThreshold,
        _silenceDurationToSplitMs = settings.silenceDurationToSplitMs,
        _minDurationMs = settings.minDurationMs,
        _minSpeechMs = settings.minSpeechMs,
        _discardShort = settings.discardShort,
        _maxChunkMs = settings.maxChunkMs,
        _deviceId = settings.deviceId,
        _audioSaveFormat = settings.audioSaveFormat,
        _omiEnabled = settings.omiEnabled;

  void destroy() {
    _decoder?.destroy();
    _session?.release();
  }

  bool get isCapturing => (_currentRefs.isNotEmpty && _speechFrameCount > 0) || _forcedByMarker;

  bool _runVad(List<double> samples512) {
    if (_session == null) {
      // Hardware AAD mode — all audio treated as speech; splitting driven by firmware timestamps only.
      return true;
    }
    final input = Float32List.fromList(samples512);
    final sr = Int64List.fromList([sampleRate]);

    final inputs = {
      'input': OrtValueTensor.createTensorWithDataList(input, [1, _vadWindowSamples]),
      'sr': OrtValueTensor.createTensorWithDataList(sr, [1]),
      'h': OrtValueTensor.createTensorWithDataList(_h, [2, 1, 64]),
      'c': OrtValueTensor.createTensorWithDataList(_c, [2, 1, 64]),
    };

    OrtRunOptions? runOptions;
    List<OrtValue?>? outputs;
    try {
      runOptions = OrtRunOptions();
      outputs = _session!.run(runOptions, inputs);
      final prob = (outputs[0]!.value as List<List<double>>)[0][0];
      _h = _flattenF32(outputs[1]!.value);
      _c = _flattenF32(outputs[2]!.value);
      return prob > _speechThreshold;
    } catch (e) {
      Logger.error('VadAudioProcessor: Silero inference failed ($e) — disabling model, AAD mode active');
      _session = null;
      return true;
    } finally {
      for (final t in inputs.values) {
        t.release();
      }
      outputs?.forEach((o) => o?.release());
      runOptions?.release();
    }
  }

  Float32List _flattenF32(dynamic nested) {
    final flat = <double>[];
    void recurse(dynamic v) {
      if (v is List) {
        for (final e in v) recurse(e);
      } else if (v is double)
        flat.add(v);
      else if (v is num) flat.add(v.toDouble());
    }

    recurse(nested);
    return Float32List.fromList(flat);
  }

  Future<List<String>> processSegmentFile(File segmentFile, DateTime segmentStartTime,
      {int startUptimeMs = 0, bool isDerivedTimestamp = false, int? sessionId}) async {
    final savedFiles = <String>[];
    _isDerivedTimestamp = isDerivedTimestamp;

    // VAD-resume anchor: set when a 0xFFFFFFFD packet is encountered.
    // Recalibrates frame timestamps after a firmware-side silence gap.
    DateTime? vadResumeTime;
    int? vadResumeFrameIndex;

    // Wall-clock time of the last processed audio frame (updated each frame).
    DateTime lastFrameWallTime = segmentStartTime;
    int? currentImuTicks;

    try {
      if (!await segmentFile.exists()) return [];
      final bytes = await segmentFile.readAsBytes();
      final fileLength = bytes.length;
      if (fileLength == 0) return [];
      final byteData = ByteData.sublistView(bytes);

      int offset = 0;
      int frameIndex = 0;
      int totalFrameCount = 0;
      int segmentSpeechFrames = 0;
      double segmentMaxAmp = 0.0;

      // FIRST PASS: Peek for metadata header at offset 0
      if (fileLength >= 36 && byteData.getUint32(0, Endian.little) == 0xFFFFFFFB) {
        final utcStartMs = byteData.getUint64(8, Endian.little);
        final uptimeStartMs = byteData.getUint64(16, Endian.little);
        currentImuTicks = byteData.getUint32(24, Endian.little);
        final sessionIdInHeader = byteData.getUint32(28, Endian.little);

        if (utcStartMs > 946684800000) {
          segmentStartTime = DateTime.fromMillisecondsSinceEpoch(utcStartMs, isUtc: true);
          startUptimeMs = uptimeStartMs.toInt();
          sessionId = sessionIdInHeader;
          lastFrameWallTime = segmentStartTime;
          _isDerivedTimestamp = false;
        }
      }

      if (_lastSegmentEndTime != null) {
        final gapMs = segmentStartTime.difference(_lastSegmentEndTime!).inMilliseconds;
        final sessionChanged = _currentSessionId != null && sessionId != null && _currentSessionId != sessionId;

        // Better isClockJump detection using uptime if available.
        // If uptime gap matches audio duration (small gap) but UTC gap is large, it's a clock sync.
        int uptimeGapMs = 0;
        bool hasUptime = _currentFrameUptimeMs != null && startUptimeMs > 0;
        if (hasUptime) {
          uptimeGapMs = (startUptimeMs - _currentFrameUptimeMs!).abs();
        }

        // IMU Bridge: Check if the gap can be explained by IMU ticks even if session changed.
        bool imuGapMatches = false;
        if (sessionChanged && _lastImuTicks != null && currentImuTicks != null) {
          final int tickDelta = (currentImuTicks! - _lastImuTicks!) & 0x00FFFFFF;
          final int imuGapMs = (tickDelta * 6.4).toInt();
          final gapDiff = (gapMs - imuGapMs).abs();
          if (gapDiff < 5000) {
            imuGapMatches = true;
            Logger.debug('VadAudioProcessor: IMU Bridge matched gap of ${imuGapMs}ms across reboot.');
          }
        }

        final bool isClockJump = !sessionChanged &&
            (hasUptime ? (uptimeGapMs < 5000 && gapMs.abs() > 10000) : (gapMs.abs() > 10000));

        if (_currentRefs.isNotEmpty &&
            (sessionChanged && !imuGapMatches || (gapMs > _silenceDurationToSplitMs && !isClockJump))) {
          Logger.debug(
            'VadAudioProcessor: Split triggered before ${segmentFile.path.split('/').last} — '
            'sessionChanged=$sessionChanged, gapMs=$gapMs (threshold=${_silenceDurationToSplitMs}ms), '
            'lastEnd=${_lastSegmentEndTime?.toUtc()} segmentStart=${segmentStartTime.toUtc()} — flushing.',
          );
          _h = Float32List(2 * 1 * 64);
          _c = Float32List(2 * 1 * 64);
          _pcmWindow.clear();
          final filePath = await flushRemaining();
          if (filePath != null) savedFiles.add(filePath);
        } else if (gapMs > 10000 && gapMs <= _silenceDurationToSplitMs && !isClockJump) {
          Logger.debug(
            'VadAudioProcessor: Small gap before ${segmentFile.path.split('/').last} — '
            'gapMs=$gapMs (within threshold, inserting silence).',
          );
          if (_currentRefs.isNotEmpty) {
            _currentRefs.add(Duration(milliseconds: gapMs));
            _currentChunkDurationMs += gapMs;
          }
        }
        // gapMs <= 10000 or isClockJump: sequential firmware files or clock sync — stitch seamlessly.
      }

      if (_currentRefs.isEmpty) {
        // Set the recording start to this bin's timestamp only on a genuine fresh start.
        // Preserve _recordingStartTime when it is already set to a time AT OR AFTER
        // _lastSegmentEndTime — that means a cap cut just fired and set it to cutTime,
        // which must not be overwritten with an earlier bin timestamp.
        final capJustFired = _recordingStartTime != null &&
            _lastSegmentEndTime != null &&
            !_recordingStartTime!.isBefore(_lastSegmentEndTime!);
        if (!capJustFired) {
          _recordingStartTime = segmentStartTime;
          _currentSessionId = sessionId;
          _currentStartUptime = startUptimeMs ~/ 1000;
          _currentFrameUptimeMs = startUptimeMs;
        }
      }

      while (offset < fileLength) {
        if (offset + 4 > fileLength) break;

        final frameLength = byteData.getUint32(offset, Endian.little);

        // Skip null/sentinel words.
        if (frameLength == 0 || frameLength == 0xFFFFFFFF) {
          offset += 4;
          continue;
        }

        // Metadata header (0xFFFFFFFB, 36 bytes: 4-byte header + 4-byte len + 28-byte payload).
        // Handled in the peek pass above, just skip it here.
        if (frameLength == 0xFFFFFFFB) {
          offset += 36;
          continue;
        }

        // Marker packet (0xFFFFFFFE = button-tap marker, 20 bytes: 4-byte header + 16-byte payload).
        // Payload layout: [0..3] UTC epoch seconds (u32 LE), [4..7] uptime ms, [8..11] session id.
        if (frameLength == 0xFFFFFFFE) {
          if (offset + 12 <= fileLength) {
            final markerUtcSeconds = byteData.getUint32(offset + 4, Endian.little);
            final markerUptimeMs = byteData.getUint32(offset + 8, Endian.little);
            const kMinValidMarkerEpoch = 946684800;
            if (markerUtcSeconds > kMinValidMarkerEpoch) {
              final markerFrameTime = DateTime.fromMillisecondsSinceEpoch(markerUtcSeconds * 1000, isUtc: true);
              _forcedByMarker = true;
              if (_currentRefs.isEmpty) {
                // Start a new recording if we weren't already capturing (not even noise accumulation).
                lastFrameWallTime = markerFrameTime;
                _recordingStartTime = markerFrameTime;
                _speechFrameCount = 0;
                _currentChunkDurationMs = 0;
                _currentFrameUptimeMs = markerUptimeMs;
                Logger.debug('VadAudioProcessor: Marker at $markerFrameTime — starting new recording.');
              } else {
                Logger.debug('VadAudioProcessor: Marker at $markerFrameTime — protecting active recording.');
              }
            }
          }
          offset += 20;
          continue;
        }

        // VAD-resume timestamp packet (0xFFFFFFFD): firmware writes this when AAD wakes
        // from silence. Used to decide stitch vs split and recalibrate frame timestamps.
        // Payload: [0..3] UTC epoch seconds (u32 LE), [4..7] uptime ms (u32 LE), [8..15] padding.
        if (frameLength == 0xFFFFFFFD) {
          if (offset + 12 <= fileLength) {
            final vadUtcSeconds = byteData.getUint32(offset + 4, Endian.little);
            final vadUptimeMs = byteData.getUint32(offset + 8, Endian.little);
            const kMinValidEpoch = 946684800;
            if (vadUtcSeconds > kMinValidEpoch) {
              final newResumeTime = DateTime.fromMillisecondsSinceEpoch(vadUtcSeconds * 1000, isUtc: true);
              final lastFrameEndTime = lastFrameWallTime.add(const Duration(milliseconds: frameDurationMs));
              final gapMs = newResumeTime.difference(lastFrameEndTime).inMilliseconds;

              // Calculate uptime gap to distinguish clock jumps from silence.
              int uptimeGapMs = 0;
              if (_currentFrameUptimeMs != null) {
                uptimeGapMs = vadUptimeMs - (_currentFrameUptimeMs! + frameDurationMs);
              }
              // If uptime Gap matches frame count (small gap) but UTC gap is large, it's a clock sync.
              final bool isClockJump = uptimeGapMs.abs() < 5000 && gapMs.abs() > 10000;

              if (gapMs >= _silenceDurationToSplitMs && !isClockJump) {
                // Gap exceeds threshold — flush current recording, start new conversation.
                final speechMs = _speechFrameCount * frameDurationMs;
                final bool tooShortSpeech = _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

                if (_currentRefs.isNotEmpty &&
                    (!_discardShort || _currentChunkDurationMs >= _minDurationMs || _forcedByMarker) &&
                    !tooShortSpeech) {
                  final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
                  if (filePath != null) savedFiles.add(filePath);
                } else if (_currentRefs.isNotEmpty) {
                  Logger.debug(
                    'VadAudioProcessor: Discarding ${tooShortSpeech ? "noise" : "short"} conversation before split.',
                  );
                }
                _currentRefs = [];
                _speechFrameCount = 0;
                _currentChunkDurationMs = 0;
                _forcedByMarker = false;
                _recordingStartTime = newResumeTime;
                Logger.debug('VadAudioProcessor: VAD resume — gap ${gapMs}ms >= threshold, new conversation.');
              } else {
                // Gap within threshold or clock jump — stitch, padding with silence so playback reflects real timing.
                if (_currentRefs.isNotEmpty && gapMs > 0 && !isClockJump) {
                  _currentRefs.add(Duration(milliseconds: gapMs));
                  _currentChunkDurationMs += gapMs;
                }
                Logger.debug(
                    'VadAudioProcessor: VAD resume — gap ${gapMs}ms ${isClockJump ? "(CLOCK JUMP)" : "< threshold"}, stitching.');
              }

              // Update anchors for subsequent frame calculations.
              vadResumeTime = newResumeTime;
              vadResumeFrameIndex = frameIndex;
              _currentFrameUptimeMs = vadUptimeMs;
            }
          }
          offset += 20;
          continue;
        }

        if (offset + 4 + frameLength > fileLength) {
          Logger.debug('VadAudioProcessor: Incomplete frame at offset $offset in ${segmentFile.path}');
          break;
        }

        if (frameIndex % 50 == 0) await Future.delayed(Duration.zero);

        final opusBytes = Uint8List.sublistView(bytes, offset + 4, offset + 4 + frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (_) {}

        bool isSpeech = false;
        if (pcmData != null) {
          for (int s = 0; s < pcmData.length; s++) {
            final sample = pcmData[s] / 32768.0;
            _pcmWindow.add(sample);
            if (sample.abs() > segmentMaxAmp) segmentMaxAmp = sample.abs();
          }
          while (_pcmWindow.length >= 512) {
            final window = _pcmWindow.sublist(0, 512);
            _pcmWindow.removeRange(0, 512);
            if (_runVad(window)) isSpeech = true;
          }
        }

        final frameRef = FrameRef(segmentFile: segmentFile, byteOffset: offset, frameLength: frameLength);
        if (isSpeech) {
          _speechFrameCount++;
          segmentSpeechFrames++;
        }
        _currentRefs.add(frameRef);
        _currentChunkDurationMs += frameDurationMs;
        if (_currentFrameUptimeMs != null) _currentFrameUptimeMs = _currentFrameUptimeMs! + frameDurationMs;

        if (_recordingStartTime == null) {
          _recordingStartTime =
              (vadResumeTime != null && vadResumeFrameIndex != null) ? vadResumeTime : segmentStartTime;
        }

        // Compute accurate wall-clock time for this frame using VAD-resume anchor if available.
        final frameTime = (vadResumeTime != null && vadResumeFrameIndex != null)
            ? vadResumeTime.add(Duration(milliseconds: (frameIndex - vadResumeFrameIndex) * frameDurationMs))
            : segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
        lastFrameWallTime = frameTime;

        // Silence-based splits are handled by 0xFFFFFFFD timestamp packets.
        // Only enforce the max conversation duration cap here.
        if (_currentChunkDurationMs >= _maxChunkMs) {
          Logger.debug('VadAudioProcessor: Max conversation duration — forcing cut.');
          final speechMs = _speechFrameCount * frameDurationMs;
          final bool tooShortSpeech = _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

          if (!tooShortSpeech) {
            final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
            if (filePath != null) savedFiles.add(filePath);
          } else {
            Logger.debug('VadAudioProcessor: Discarding noise conversation during max-duration cut.');
          }
          final cutTime = _recordingStartTime!.add(Duration(milliseconds: _currentChunkDurationMs));
          _forcedByMarker = false;
          _currentRefs = [];
          _speechFrameCount = 0;
          _currentChunkDurationMs = 0;
          _recordingStartTime = cutTime;
        }

        offset += 4 + ((frameLength + 3) & ~3); // advance past 4-byte-aligned frame (matches SD card wire format)
        frameIndex++;
        totalFrameCount++;
      }

      _lastSegmentEndTime = lastFrameWallTime.add(const Duration(milliseconds: frameDurationMs));
      if (currentImuTicks != null) {
        final int segmentDurationMs = totalFrameCount * frameDurationMs;
        final int ticksPassed = (segmentDurationMs / 6.4).toInt();
        _lastImuTicks = (currentImuTicks! + ticksPassed) & 0x00FFFFFF;
      }
      Logger.debug('VadAudioProcessor: ${segmentFile.path.split('/').last} — '
          '$totalFrameCount frames, $segmentSpeechFrames speech frames, maxAmp=${segmentMaxAmp.toStringAsFixed(4)}');
    } catch (e) {
      Logger.error('VadAudioProcessor: processSegmentFile error: $e');
    }

    _processedFiles.add(segmentFile.path);
    return savedFiles;
  }

  Future<String?> flushRemaining({bool isDraft = false}) async {
    final speechMs = _speechFrameCount * frameDurationMs;
    final bool tooShortSpeech = _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

    if (_currentRefs.isEmpty ||
        (_discardShort && _currentChunkDurationMs < _minDurationMs && !_forcedByMarker) ||
        tooShortSpeech) {
      discardGuardFiredOnLastFlush = _currentRefs.isNotEmpty;
      if (_currentRefs.isNotEmpty) {
        final reason = tooShortSpeech
            ? "${speechMs}ms speech < ${_minSpeechMs}ms minimum"
            : "${_currentChunkDurationMs}ms < ${_minDurationMs}ms minimum";
        Logger.debug('VadAudioProcessor: flushRemaining discarding ${_currentRefs.length} frames ($reason)');
      }
      _resetState();
      return null;
    }
    discardGuardFiredOnLastFlush = false;
    final path = await _saveRecording(_currentRefs, _recordingStartTime!, isDraft: isDraft);
    _resetState();
    return path;
  }

  Future<String?> flushOnlyCompleted() async {
    if (isCapturing) {
      Logger.debug(
          'VadAudioProcessor: flushOnlyCompleted — capture in progress, skipping flush to allow continuation.');
      return null;
    }
    return flushRemaining();
  }

  /// Returns the set of segment file paths that have been fully processed and are
  /// no longer referenced by [_currentRefs].
  /// Each path is returned at most once. The caller may safely delete these files.
  Set<String> consumeSafeToDeletePaths() {
    final referenced = <String>{};
    for (final item in _currentRefs) {
      if (item is FrameRef) referenced.add(item.segmentFile.path);
    }
    final safe = _processedFiles.difference(referenced);
    _processedFiles.removeAll(safe);
    return safe;
  }

  void _resetState() {
    _currentRefs = [];
    _speechFrameCount = 0;
    _currentChunkDurationMs = 0;
    _recordingStartTime = null;
    _forcedByMarker = false;
  }

  @visibleForTesting
  Future<String?> saveRecordingTest(List<Object> refs, DateTime startTime, {bool isDerivedTimestamp = false}) =>
      _saveRecording(refs, startTime, isDerivedTimestamp: isDerivedTimestamp);

  Future<String?> _saveRecording(List<Object> refs, DateTime startTime,
      {bool? isDerivedTimestamp, bool isDraft = false}) async {
    final result = await _saveRecordingCore(refs, startTime, isDerivedTimestamp: isDerivedTimestamp, isDraft: isDraft);
    if (result != null && _omiEnabled) {
      try {
        final dateFolderPath = File(result).parent.path;
        await _saveBin(refs, dateFolderPath, startTime.millisecondsSinceEpoch);
      } catch (e) {
        Logger.error('VadAudioProcessor: _saveBin failed: $e');
      }
    }
    return result;
  }

  /// Writes a raw Opus .bin file (4-byte LE length prefix + Opus bytes per frame) for upload
  /// to the Omi backend. Filename includes `_fs320_` so the server uses the correct 320-sample
  /// frame size (16 kHz × 20 ms) instead of its 160-sample default.
  Future<void> _saveBin(List<Object> refs, String dateFolderPath, int timestamp) async {
    final binPath = '$dateFolderPath/recording_fs320_$timestamp.bin';
    final sink = File(binPath).openWrite();
    try {
      String? currentFilePath;
      Uint8List? currentFileBytes;
      for (var i = 0; i < refs.length; i++) {
        final item = refs[i];
        if (item is! FrameRef) continue;

        if (i % 50 == 0) await Future.delayed(Duration.zero);
        if (item.segmentFile.path != currentFilePath) {
          currentFileBytes = await item.segmentFile.readAsBytes();
          currentFilePath = item.segmentFile.path;
          await Future.delayed(Duration.zero);
        }
        if (currentFileBytes == null) continue;
        // Write 4-byte length prefix + Opus packet as-is.
        sink.add(Uint8List.sublistView(currentFileBytes, item.byteOffset, item.byteOffset + 4 + item.frameLength));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    Logger.debug('VadAudioProcessor: Saved bin for Omi sync — $binPath');
  }

  Future<String?> _saveRecordingCore(List<Object> refs, DateTime startTime,
      {bool? isDerivedTimestamp, bool isDraft = false}) async {
    final derived = isDerivedTimestamp ?? _isDerivedTimestamp;
    final prefix = derived ? 'unknown' : 'recording';
    final timestamp = startTime.millisecondsSinceEpoch;
    // Append _draft if requested, but only for files with valid timestamps (not 'unknown_').
    final suffix = (isDraft && !derived) ? '_draft' : '';

    String dateFolderPath;
    if (_outputDir != null) {
      dateFolderPath = _outputDir!;
    } else {
      final directory = await getApplicationDocumentsDirectory();
      final localStart = startTime.toLocal();
      final dateString =
          '${localStart.year}-${localStart.month.toString().padLeft(2, '0')}-${localStart.day.toString().padLeft(2, '0')}';
      dateFolderPath = '${directory.path}/recordings/$dateString';
    }

    final dateFolder = Directory(dateFolderPath);
    if (!await dateFolder.exists()) {
      await dateFolder.create(recursive: true);
    }

    final frameRefCount = refs.whereType<FrameRef>().length;
    if (frameRefCount > 0 && frameRefCount < 5) {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }

    if (_audioSaveFormat == 'wav') {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    } else if (_audioSaveFormat == 'ogg') {
      if (Platform.isIOS) {
        return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
      } else {
        return await _saveOgg(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
      }
    }

    final m4aPath = '${dateFolder.path}/${prefix}_$timestamp$suffix.m4a';

    const waveformBuckets = 200;
    const windowSize = 800;
    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;

    const batchFrames = 15;
    final batchBuffer = BytesBuilder(copy: false);
    int totalSamples = 0;
    int batchFrameCount = 0;

    String? sessionId;
    bool hasEncodedAnyFrames = false;

    try {
      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
    } on Exception catch (e) {
      Logger.error('VadAudioProcessor: AAC startEncoder failed, falling back to WAV: $e');
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }

    Future<void> flushBatch() async {
      if (batchFrameCount == 0) return;
      final chunk = batchBuffer.takeBytes();
      await AacEncoder.encodeBuffer(sessionId!, chunk);
      hasEncodedAnyFrames = true;
      batchFrameCount = 0;
    }

    try {
      String? currentFilePath;
      Uint8List? currentFileBytes;

      for (var i = 0; i < refs.length; i++) {
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final silenceSamples = (ms * sampleRate) ~/ 1000;
          final silenceBytes = Uint8List(silenceSamples * 2); // 16-bit mono

          batchBuffer.add(silenceBytes);
          totalSamples += silenceSamples;

          // Waveform for silence
          for (int s = 0; s < silenceSamples; s++) {
            currentWindowSamples++;
            if (currentWindowSamples >= windowSize) {
              dynamicPeaks.add(0.0);
              currentWindowSamples = 0;
            }
          }
          batchFrameCount += (ms / frameDurationMs).ceil();
          if (batchFrameCount >= batchFrames) await flushBatch();
          continue;
        }

        final ref = item as FrameRef;
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        if (ref.segmentFile.path != currentFilePath) {
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
          await Future.delayed(Duration.zero);
        }

        if (currentFileBytes == null) continue;

        final frameDataOffset = ref.byteOffset + 4;
        final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (_) {}

        if (pcmData == null) continue;

        for (int s = 0; s < pcmData.length; s++) {
          final amplitude = pcmData[s].abs() / 32768.0;
          if (amplitude > currentWindowMax) currentWindowMax = amplitude;
          currentWindowSamples++;
          if (currentWindowSamples >= windowSize) {
            dynamicPeaks.add(currentWindowMax);
            currentWindowMax = 0.0;
            currentWindowSamples = 0;
          }
        }
        totalSamples += pcmData.length;

        batchBuffer.add(pcmData.buffer.asUint8List(pcmData.offsetInBytes, pcmData.lengthInBytes));
        batchFrameCount++;

        if (batchFrameCount >= batchFrames) {
          await flushBatch();
          await Future.delayed(Duration.zero);
        }
      }

      await flushBatch();
      await Future.delayed(Duration.zero);

      if (currentWindowSamples > 0) {
        dynamicPeaks.add(currentWindowMax);
      }

      if (!hasEncodedAnyFrames) {
        Logger.debug('VadAudioProcessor: No frames encoded — discarding empty segment.');
        final emptyFile = File(m4aPath);
        if (await emptyFile.exists()) await emptyFile.delete();
        return null;
      }

      await AacEncoder.finishEncoder(sessionId!);
    } on Exception catch (e) {
      Logger.error('VadAudioProcessor: AAC encoding failed, falling back to WAV: $e');
      final corruptFile = File('${dateFolder.path}/${prefix}_$timestamp$suffix.m4a');
      try {
        if (await corruptFile.exists()) await corruptFile.delete();
      } catch (_) {}
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }

    await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
        prefix: prefix, extension: 'm4a', suffix: suffix);

    Logger.debug(
        'VadAudioProcessor: Saved recording (${refs.length} frames, ${((totalSamples * 1000) ~/ sampleRate)}ms) '
        'starting at $_recordingStartTime to $m4aPath');
    return m4aPath;
  }

  Future<void> _saveMetadata(List<Object> refs, String dateFolderPath, int timestamp, int totalSamples,
      List<double> dynamicPeaks, int waveformBuckets,
      {required String prefix, required String extension, String suffix = ''}) async {
    final finalAmplitudes = List<double>.filled(waveformBuckets, 0.0);
    if (dynamicPeaks.isNotEmpty) {
      final double ratio = dynamicPeaks.length / waveformBuckets;
      for (int i = 0; i < waveformBuckets; i++) {
        final startIdx = (i * ratio).floor();
        final endIdx = ((i + 1) * ratio).ceil().clamp(0, dynamicPeaks.length);
        double peak = 0.0;
        for (int j = startIdx; j < endIdx; j++) {
          if (dynamicPeaks[j] > peak) peak = dynamicPeaks[j];
        }
        finalAmplitudes[i] = peak;
      }
    }

    final durationMs = (totalSamples * 1000) ~/ sampleRate;
    final metaBytes = ByteData(416); // Increased from 408 to 416
    metaBytes.setUint32(0, totalSamples, Endian.little);
    metaBytes.setUint32(4, durationMs, Endian.little);
    for (int i = 0; i < waveformBuckets; i++) {
      final peak16 = (finalAmplitudes[i] * 65535.0).round().clamp(0, 65535);
      metaBytes.setUint16(8 + i * 2, peak16, Endian.little);
    }
    // Add Session ID and Start Uptime at the end of the fixed header
    metaBytes.setUint32(408, _currentSessionId ?? 0, Endian.little);
    metaBytes.setUint32(412, _currentStartUptime ?? 0, Endian.little);

    final metaPath = '$dateFolderPath/${prefix}_$timestamp$suffix.meta';
    final List<int> metaOut = [...metaBytes.buffer.asUint8List()];
    final rawId = _deviceId;
    if (rawId.isNotEmpty) {
      final deviceId = rawId.replaceAll(':', '').toUpperCase();
      if (deviceId.length >= 6) {
        final mac6 = deviceId.substring(0, 6);
        final uploadKey = '${mac6}_recording_$timestamp$suffix.$extension';
        final keyBytes = uploadKey.codeUnits;
        final truncatedKey = keyBytes.length > 255 ? keyBytes.sublist(0, 255) : keyBytes;
        metaOut.add(truncatedKey.length);
        metaOut.addAll(truncatedKey);
      }
    }
    await File(metaPath).writeAsBytes(metaOut);
  }

  Future<String?> _saveOgg(List<Object> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording', String suffix = ''}) async {
    final oggPath = '$dateFolderPath/${prefix}_$timestamp$suffix.ogg';
    final tmpPath = '$oggPath.tmp';
    final oggFile = File(tmpPath);
    final IOSink sink = oggFile.openWrite();

    const waveformBuckets = 200;
    const windowSize = 800;

    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;
    int totalSamples = 0;

    // 1-byte 16kHz SILK mode Opus DTX (silence) frame
    final opusSilenceFrame = Uint8List.fromList([0x48]);

    int granulePos = 0;
    int lastFlushedGranulePos = 0;
    int pageSeqNum = 2;
    String? currentFilePath;
    Uint8List? currentFileBytes;
    final pagePackets = <Uint8List>[];

    bool renamed = false;
    try {
      final serial = Random().nextInt(0x7FFFFFFF);
      sink.add(_createOggPage(0, 0, serial, [_createOggOpusIdHeader()], isFirstPage: true));
      sink.add(_createOggPage(0, 1, serial, [_createOggOpusCommentHeader()]));

      for (var i = 0; i < refs.length; i++) {
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final durationSamples = (ms * sampleRate) ~/ 1000;
          final silenceFrames = (ms / frameDurationMs).round();

          for (int f = 0; f < silenceFrames; f++) {
            granulePos += 960; // 20ms at 48kHz
            pagePackets.add(opusSilenceFrame);

            if (pagePackets.length >= 40) {
              lastFlushedGranulePos = granulePos;
              sink.add(_createOggPage(granulePos, pageSeqNum++, serial, pagePackets.toList()));
              pagePackets.clear();
            }
          }

          // Still need to update waveform metadata for silence
          for (int s = 0; s < durationSamples; s++) {
            currentWindowSamples++;
            if (currentWindowSamples >= windowSize) {
              dynamicPeaks.add(0.0);
              currentWindowSamples = 0;
            }
          }
          totalSamples += durationSamples;
        } else {
          final ref = item as FrameRef;
          if (i % 50 == 0) await Future.delayed(Duration.zero);

          if (ref.segmentFile.path != currentFilePath) {
            currentFileBytes = await ref.segmentFile.readAsBytes();
            currentFilePath = ref.segmentFile.path;
            await Future.delayed(Duration.zero);
          }

          if (currentFileBytes == null) continue;

          final frameDataOffset = ref.byteOffset + 4;
          final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

          Int16List? pcmData;
          try {
            pcmData = _decoder?.decode(input: opusBytes);
          } catch (e) {
            continue;
          }
          if (pcmData != null) {
            for (int s = 0; s < pcmData.length; s++) {
              final amplitude = pcmData[s].abs() / 32768.0;
              if (amplitude > currentWindowMax) currentWindowMax = amplitude;
              currentWindowSamples++;
              if (currentWindowSamples >= windowSize) {
                dynamicPeaks.add(currentWindowMax);
                currentWindowMax = 0.0;
                currentWindowSamples = 0;
              }
            }
            totalSamples += pcmData.length;
          }

          granulePos += 960; // 20ms frame at 48kHz
          pagePackets.add(opusBytes);
        }

        if (pagePackets.length >= 40) {
          // 40 frames per page (~800ms)
          lastFlushedGranulePos = granulePos;
          sink.add(_createOggPage(granulePos, pageSeqNum++, serial, pagePackets.toList()));
          pagePackets.clear();
        }
      }

      if (pagePackets.isNotEmpty) {
        sink.add(_createOggPage(granulePos, pageSeqNum++, serial, pagePackets, isLastPage: true));
      } else {
        // OGG needs at least one page with the EOS flag.
        sink.add(_createOggPage(granulePos, pageSeqNum++, serial, [], isLastPage: true));
      }

      await sink.flush();
      await sink.close();

      await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
          prefix: prefix, extension: 'ogg', suffix: suffix);

      await oggFile.rename(oggPath);
      renamed = true;
      Logger.debug(
          'VadAudioProcessor: Saved recording (${refs.length} frames, ${((totalSamples * 1000) ~/ sampleRate)}ms) '
          'starting at $_recordingStartTime to $oggPath');
      return oggPath;
    } catch (e) {
      Logger.error('VadAudioProcessor: _saveOgg failed: $e');
      if (!renamed && await oggFile.exists()) await oggFile.delete();
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }
  }

  Uint8List _createOggOpusIdHeader() {
    final header = ByteData(19);
    header.setUint8(0, 0x4F); // O
    header.setUint8(1, 0x70); // p
    header.setUint8(2, 0x75); // u
    header.setUint8(3, 0x73); // s
    header.setUint8(4, 0x48); // H
    header.setUint8(5, 0x65); // e
    header.setUint8(6, 0x61); // a
    header.setUint8(7, 0x64); // d
    header.setUint8(8, 0x01); // Version
    header.setUint8(9, channels);
    header.setUint16(10, 0, Endian.little); // Pre-skip
    header.setUint32(12, 48000, Endian.little); // Input sample rate
    header.setUint16(16, 0, Endian.little); // Output gain
    header.setUint8(18, 0x00); // Channel map
    return header.buffer.asUint8List();
  }

  Uint8List _createOggOpusCommentHeader() {
    const vendor = "Omi Offline";
    final vendorBytes = utf8.encode(vendor);
    final header = ByteData(8 + 4 + vendorBytes.length + 4);
    header.setUint8(0, 0x4F); // O
    header.setUint8(1, 0x70); // p
    header.setUint8(2, 0x75); // u
    header.setUint8(3, 0x73); // s
    header.setUint8(4, 0x54); // T
    header.setUint8(5, 0x61); // a
    header.setUint8(6, 0x67); // g
    header.setUint8(7, 0x73); // s
    header.setUint32(8, vendorBytes.length, Endian.little);
    for (int i = 0; i < vendorBytes.length; i++) {
      header.setUint8(12 + i, vendorBytes[i]);
    }
    header.setUint32(12 + vendorBytes.length, 0, Endian.little); // User comment count
    return header.buffer.asUint8List();
  }

  Uint8List _createOggPage(int granulePos, int pageSeqNum, int serial, List<Uint8List> packets,
      {bool isFirstPage = false, bool isLastPage = false}) {
    int pageHeaderSize = 27 + packets.length;
    int pageDataSize = packets.fold(0, (sum, p) => sum + p.length);
    final page = ByteData(pageHeaderSize + pageDataSize);

    page.setUint8(0, 0x4F); // O
    page.setUint8(1, 0x67); // g
    page.setUint8(2, 0x67); // g
    page.setUint8(3, 0x53); // S
    page.setUint8(4, 0x00); // Version
    int flags = 0;
    if (isFirstPage) flags |= 0x02;
    if (isLastPage) flags |= 0x04;
    page.setUint8(5, flags);
    page.setUint64(6, granulePos, Endian.little);
    page.setUint32(14, serial, Endian.little);
    page.setUint32(18, pageSeqNum, Endian.little);
    page.setUint32(22, 0, Endian.little); // Checksum (filled later)
    page.setUint8(26, packets.length);

    int offset = 27;
    for (var p in packets) {
      page.setUint8(offset++, p.length);
    }
    for (var p in packets) {
      for (int i = 0; i < p.length; i++) {
        page.setUint8(offset++, p[i]);
      }
    }

    // CRC-32 (Ogg variant)
    final crc = _computeOggCrc(page.buffer.asUint8List());
    page.setUint32(22, crc, Endian.little);

    return page.buffer.asUint8List();
  }

  int _computeOggCrc(Uint8List data) {
    int crc = 0;
    for (int i = 0; i < data.length; i++) {
      crc = (crc << 8) ^ _oggCrcTable[((crc >> 24) ^ data[i]) & 0xFF];
    }
    return crc & 0xFFFFFFFF;
  }

  static final List<int> _oggCrcTable = _generateOggCrcTable();
  static List<int> _generateOggCrcTable() {
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int r = i << 24;
      for (int j = 0; j < 8; j++) {
        if ((r & 0x80000000) != 0) {
          r = (r << 1) ^ 0x04c11db7;
        } else {
          r <<= 1;
        }
      }
      table[i] = r & 0xFFFFFFFF;
    }
    return table;
  }

  Future<String?> _saveWav(List<Object> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording', String suffix = ''}) async {
    final wavPath = '$dateFolderPath/${prefix}_$timestamp$suffix.wav';
    final rawPath = '$dateFolderPath/${prefix}_$timestamp$suffix.raw';
    final rawFile = File(rawPath);
    final sink = rawFile.openWrite();

    const waveformBuckets = 200;
    const windowSize = 800;

    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;
    int totalSamples = 0;

    try {
      String? currentFilePath;
      Uint8List? currentFileBytes;
      for (var i = 0; i < refs.length; i++) {
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final silenceSamples = (ms * sampleRate) ~/ 1000;
          final silenceBytes = Uint8List(silenceSamples * 2); // 16-bit mono
          sink.add(silenceBytes);
          totalSamples += silenceSamples;
          for (int s = 0; s < silenceSamples; s++) {
            currentWindowSamples++;
            if (currentWindowSamples >= windowSize) {
              dynamicPeaks.add(0.0);
              currentWindowSamples = 0;
            }
          }
          continue;
        }

        final ref = item as FrameRef;
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        if (ref.segmentFile.path != currentFilePath) {
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
          await Future.delayed(Duration.zero);
        }

        if (currentFileBytes == null) continue;

        final frameDataOffset = ref.byteOffset + 4;
        final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (_) {}

        if (pcmData == null) continue;

        for (int s = 0; s < pcmData.length; s++) {
          final amplitude = pcmData[s].abs() / 32768.0;
          if (amplitude > currentWindowMax) currentWindowMax = amplitude;
          currentWindowSamples++;
          if (currentWindowSamples >= windowSize) {
            dynamicPeaks.add(currentWindowMax);
            currentWindowMax = 0.0;
            currentWindowSamples = 0;
          }
        }
        totalSamples += pcmData.length;
        sink.add(pcmData.buffer.asUint8List(pcmData.offsetInBytes, pcmData.lengthInBytes));
      }

      await sink.flush();
      await sink.close();

      // Assemble final WAV with header + raw PCM stream
      final wavFile = File('$wavPath.tmp');
      final wavSink = wavFile.openWrite();
      try {
        final header = _generateWavHeader(totalSamples * 2, sampleRate, 1);
        wavSink.add(header);
        await wavSink.addStream(rawFile.openRead());
        await wavSink.flush();
      } finally {
        await wavSink.close();
      }

      await rawFile.delete();

      await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
          prefix: prefix, extension: 'wav', suffix: suffix);

      await wavFile.rename(wavPath);
      Logger.debug(
          'VadAudioProcessor: Saved recording (${refs.length} frames, ${((totalSamples * 1000) ~/ sampleRate)}ms) '
          'starting at $_recordingStartTime to $wavPath');
      return wavPath;
    } catch (e) {
      Logger.error('VadAudioProcessor: _saveWav failed: $e');
      if (await rawFile.exists()) await rawFile.delete();
      return null;
    }
  }

  Uint8List _generateWavHeader(int pcmBytes, int sampleRate, int channels) {
    final header = ByteData(44);
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, 36 + pcmBytes, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little);
    header.setUint16(32, channels * 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, pcmBytes, Endian.little);
    return header.buffer.asUint8List();
  }
}
