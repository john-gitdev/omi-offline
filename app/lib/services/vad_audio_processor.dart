import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:omi/utils/logger.dart';

import "package:meta/meta.dart";

/// All VAD/processing settings captured from SharedPreferences in the main isolate
/// before spawning the processing isolate. All fields are primitives — safe to send
/// across isolate boundaries.
class ProcessingSettings {
  final double speechThreshold;
  final int hangoverFrameCount;
  final int silenceDurationToSplitMs;
  final int minSpeechMs;
  final int preSpeechBufferMs;
  final int gapThresholdMs;
  final int maxChunkMs;
  final int markerLookbackMs;
  final int maxRollingFrames;
  final String deviceId; // used to generate upload key in .meta sidecar

  const ProcessingSettings({
    required this.speechThreshold,
    required this.hangoverFrameCount,
    required this.silenceDurationToSplitMs,
    required this.minSpeechMs,
    required this.preSpeechBufferMs,
    required this.gapThresholdMs,
    required this.maxChunkMs,
    required this.markerLookbackMs,
    required this.maxRollingFrames,
    required this.deviceId,
  });

  factory ProcessingSettings.fromPrefs() {
    final p = SharedPreferencesUtil();
    const frameDurationMs = VadAudioProcessor.frameDurationMs;
    return ProcessingSettings(
      speechThreshold: p.vadSpeechThreshold,
      hangoverFrameCount: (p.vadHangoverSeconds * 1000).round() ~/ frameDurationMs,
      silenceDurationToSplitMs: p.vadSplitSeconds * 1000,
      minSpeechMs: p.vadMinSpeechSeconds * 1000,
      preSpeechBufferMs: (p.vadPreSpeechSeconds * 1000).round(),
      gapThresholdMs: p.vadGapSeconds * 1000,
      maxChunkMs: p.vadMaxConversationMinutes * 60 * 1000,
      markerLookbackMs: p.markerLookbackSeconds * 1000,
      maxRollingFrames: p.markerLookbackSeconds * 1000 ~/ frameDurationMs,
      deviceId: p.btDevice.id,
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

  // Per-conversation accumulation — FrameRef disk-pointers only, no Opus in RAM
  List<FrameRef> _currentRefs = [];
  int _speechFrameCount = 0; // speech frames in current conversation
  DateTime? _recordingStartTime;
  DateTime? _lastSegmentEndTime;
  bool _isDerivedTimestamp = false; // true when segment had no valid device RTC timestamp

  // VAD state counters
  int _consecutiveSilenceFrames = 0;
  int _hangoverFrames = 0; // frames remaining in hangover
  int _currentChunkDurationMs = 0; // total frames accumulated (for max-cap)

  // Marker-forced recording state
  bool _forcedByMarker = false;
  DateTime? _lastSplitTime; // wall time of the most recent silence split

  // Rolling pre-buffer for marker lookback — receives every audio frame regardless of VAD state,
  // never reset by splits. Sized to markerLookbackSeconds.
  final ListQueue<FrameRef> _rbRefs = ListQueue();
  final ListQueue<DateTime> _rbTimes = ListQueue();
  final int _maxRollingFrames;
  final int _markerLookbackMs;

  // Settings — cached at construction time for the lifetime of one processAll pass
  final double _speechThreshold;
  final int _hangoverFrameCount;
  final int _silenceDurationToSplitMs;
  final int _minSpeechMs;
  final int _preSpeechBufferMs;
  final int _gapThresholdMs;
  final int _maxChunkMs;
  final String _deviceId;

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 20; // 20 ms per Opus frame
  static const int _vadWindowSamples = 512; // Silero VAD input size

  /// Creates a processor in the main isolate, reading settings from SharedPreferences.
  static Future<VadAudioProcessor> create({String? outputDir, SimpleOpusDecoder? decoder}) async {
    final settings = ProcessingSettings.fromPrefs();
    try {
      OrtEnv.instance.init();
    } catch (e) {
      Logger.error("VadAudioProcessor: Failed to init OrtEnv: $e");
    }
    OrtSession? session;
    try {
      final data = await rootBundle.load('assets/models/silero_vad.onnx');
      final sessionOptions = OrtSessionOptions();
      session = OrtSession.fromBuffer(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), sessionOptions);
    } catch (e) {
      Logger.error('VadAudioProcessor: Failed to load Silero VAD model, amplitude fallback active: $e');
    }
    Logger.debug(
        'VadAudioProcessor: init — ${session != null ? 'Silero VAD loaded' : 'amplitude fallback active (threshold=${settings.speechThreshold})'}');
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

  VadAudioProcessor._({String? outputDir, SimpleOpusDecoder? decoder, OrtSession? session, required ProcessingSettings settings})
      : _session = session,
        _decoder = decoder ??
            (Platform.isIOS || Platform.isAndroid
                ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
                : null),
        _outputDir = outputDir,
        _speechThreshold = settings.speechThreshold,
        _hangoverFrameCount = settings.hangoverFrameCount,
        _silenceDurationToSplitMs = settings.silenceDurationToSplitMs,
        _minSpeechMs = settings.minSpeechMs,
        _preSpeechBufferMs = settings.preSpeechBufferMs,
        _gapThresholdMs = settings.gapThresholdMs,
        _maxChunkMs = settings.maxChunkMs,
        _markerLookbackMs = settings.markerLookbackMs,
        _maxRollingFrames = settings.maxRollingFrames,
        _deviceId = settings.deviceId;

  void destroy() {
    _decoder?.destroy();
    _session?.release();
  }

  bool get isCapturing => (_currentRefs.isNotEmpty && _speechFrameCount > 0) || _forcedByMarker;

  bool _runVad(List<double> samples512) {
    if (_session == null) {
      // Amplitude fallback when model didn't load or was disabled after a failure.
      return samples512.any((s) => s.abs() > _speechThreshold);
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
      Logger.error(
          'VadAudioProcessor: Silero inference failed ($e) — disabling model, switching to amplitude fallback');
      _session = null;
      return samples512.any((s) => s.abs() > _speechThreshold);
    } finally {
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
      {bool isDerivedTimestamp = false}) async {
    final savedFiles = <String>[];
    _isDerivedTimestamp = isDerivedTimestamp;

    try {
      if (!await segmentFile.exists()) return [];
      final bytes = await segmentFile.readAsBytes();
      final fileLength = bytes.length;
      if (fileLength == 0) return [];
      final byteData = ByteData.sublistView(bytes);

      if (_currentRefs.isNotEmpty && _lastSegmentEndTime != null) {
        final gapMs = segmentStartTime.difference(_lastSegmentEndTime!).inMilliseconds;
        if (gapMs > _gapThresholdMs) {
          _h = Float32List(2 * 1 * 64);
          _c = Float32List(2 * 1 * 64);
          _pcmWindow.clear();
          final filePath = await flushRemaining();
          if (filePath != null) savedFiles.add(filePath);
        }
      }

      if (_currentRefs.isEmpty) {
        _recordingStartTime = segmentStartTime;
      }

      int offset = 0;
      int frameIndex = 0;
      int totalFrameCount = 0;
      int segmentSpeechFrames = 0;
      double segmentMaxAmp = 0.0;

      while (offset < fileLength) {
        if (offset + 4 > fileLength) break;

        final frameLength = byteData.getUint32(offset, Endian.little);

        // Skip null/sentinel words.
        if (frameLength == 0 || frameLength == 0xFFFFFFFF) {
          offset += 4;
          continue;
        }

        // Marker packet (0xFFFFFFFE = button-tap marker, 20 bytes: 4-byte header + 16-byte payload).
        // Payload layout: [0..3] UTC epoch seconds (u32 LE), [4..7] uptime ms, [8..11] session id.
        if (frameLength == 0xFFFFFFFE) {
          if (offset + 8 <= fileLength) {
            final markerUtcSeconds = byteData.getUint32(offset + 4, Endian.little);
            const kMinValidMarkerEpoch = 946684800;
            if (markerUtcSeconds > kMinValidMarkerEpoch) {
              final markerFrameTime = segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
              if (isCapturing) {
                // Marker fired inside an active conversation — prevent the trailing silence from
                // splitting the recording at the tap point. The recording continues to the next
                // natural silence threshold.
                _consecutiveSilenceFrames = 0;
                Logger.debug(
                    'VadAudioProcessor: Marker at $markerFrameTime — in active conversation, silence counter reset.');
              } else {
                // Marker fired during silence — force a lookback recording.
                final msSinceLastSplit = _lastSplitTime != null
                    ? markerFrameTime.difference(_lastSplitTime!).inMilliseconds
                    : _markerLookbackMs;
                final actualLookbackMs = min(msSinceLastSplit, _markerLookbackMs);
                final actualLookbackFrames = actualLookbackMs ~/ frameDurationMs;

                final rbRefsList = _rbRefs.toList();
                final rbTimesList = _rbTimes.toList();
                final startIdx = (rbRefsList.length - actualLookbackFrames).clamp(0, rbRefsList.length);

                _currentRefs = rbRefsList.sublist(startIdx);
                _recordingStartTime = startIdx < rbTimesList.length ? rbTimesList[startIdx] : markerFrameTime;
                _speechFrameCount = 0;
                _hangoverFrames = 0;
                _consecutiveSilenceFrames = 0;
                _currentChunkDurationMs = _currentRefs.length * frameDurationMs;
                _forcedByMarker = true;
                Logger.debug('VadAudioProcessor: Marker at $markerFrameTime — forced lookback recording '
                    '(${actualLookbackMs}ms, ${_currentRefs.length} frames).');
              }
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

        final opusBytes = bytes.sublist(offset + 4, offset + 4 + frameLength);

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

        bool effectiveSpeech = false;
        if (isSpeech) {
          _hangoverFrames = _hangoverFrameCount;
          effectiveSpeech = true;
        } else if (_hangoverFrames > 0) {
          _hangoverFrames--;
          effectiveSpeech = true;
        }

        final frameRef = FrameRef(segmentFile: segmentFile, byteOffset: offset, frameLength: frameLength);
        if (effectiveSpeech) {
          _speechFrameCount++;
          segmentSpeechFrames++;
          _consecutiveSilenceFrames = 0;
          _currentRefs.add(frameRef);
          _currentChunkDurationMs += frameDurationMs;
        } else {
          _consecutiveSilenceFrames++;
          _currentRefs.add(frameRef);
          _currentChunkDurationMs += frameDurationMs;
        }

        // Rolling pre-buffer — every audio frame, independent of VAD state and splits.
        final frameTime = segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
        _rbRefs.addLast(frameRef);
        _rbTimes.addLast(frameTime);
        if (_rbRefs.length > _maxRollingFrames) {
          _rbRefs.removeFirst();
          _rbTimes.removeFirst();
        }

        final silenceMs = _consecutiveSilenceFrames * frameDurationMs;
        if (silenceMs >= _silenceDurationToSplitMs) {
          if (_speechFrameCount * frameDurationMs >= _minSpeechMs || _forcedByMarker) {
            final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
            if (filePath != null) savedFiles.add(filePath);
          }
          _lastSplitTime = segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
          _forcedByMarker = false;
          final preSpeechFrames = _preSpeechBufferMs ~/ frameDurationMs;
          final bufferToKeep = min(preSpeechFrames, _consecutiveSilenceFrames);
          _currentRefs = _currentRefs.sublist(_currentRefs.length - bufferToKeep);
          _speechFrameCount = 0;
          _hangoverFrames = 0;
          _consecutiveSilenceFrames = 0;
          _currentChunkDurationMs = 0;
          _recordingStartTime = segmentStartTime
              .add(Duration(milliseconds: frameIndex * frameDurationMs))
              .subtract(Duration(milliseconds: bufferToKeep * frameDurationMs));
        } else if (_currentChunkDurationMs >= _maxChunkMs) {
          Logger.debug('VadAudioProcessor: Max conversation duration — forcing cut.');
          final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
          if (filePath != null) savedFiles.add(filePath);
          _lastSplitTime = segmentStartTime.add(Duration(milliseconds: (frameIndex + 1) * frameDurationMs));
          _forcedByMarker = false;
          _currentRefs = [];
          _speechFrameCount = 0;
          _hangoverFrames = 0;
          _consecutiveSilenceFrames = 0;
          _currentChunkDurationMs = 0;
          _recordingStartTime = segmentStartTime.add(Duration(milliseconds: (frameIndex + 1) * frameDurationMs));
        }

        offset += 4 + ((frameLength + 3) & ~3); // advance past 4-byte-aligned frame (matches SD card wire format)
        frameIndex++;
        totalFrameCount++;
      }

      _lastSegmentEndTime = segmentStartTime.add(Duration(milliseconds: totalFrameCount * frameDurationMs));
      Logger.debug('VadAudioProcessor: ${segmentFile.path.split('/').last} — '
          '$totalFrameCount frames, $segmentSpeechFrames speech this seg / $_speechFrameCount total, maxAmp=${segmentMaxAmp.toStringAsFixed(4)}');
    } catch (e) {
      Logger.error('VadAudioProcessor: processSegmentFile error: $e');
    }

    return savedFiles;
  }

  Future<String?> flushRemaining() async {
    if (_currentRefs.isEmpty || (_speechFrameCount * frameDurationMs < _minSpeechMs && !_forcedByMarker)) {
      if (_currentRefs.isNotEmpty) {
        Logger.debug(
          'VadAudioProcessor: flushRemaining discarding ${_currentRefs.length} frames '
          '(${_speechFrameCount * frameDurationMs}ms speech < ${_minSpeechMs}ms minimum)',
        );
      }
      _resetState();
      return null;
    }
    final path = await _saveRecording(_currentRefs, _recordingStartTime!);
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

  void _resetState() {
    _currentRefs = [];
    _speechFrameCount = 0;
    _hangoverFrames = 0;
    _consecutiveSilenceFrames = 0;
    _currentChunkDurationMs = 0;
    _recordingStartTime = null;
    _forcedByMarker = false;
  }

  @visibleForTesting
  Future<String?> saveRecordingTest(List<FrameRef> refs, DateTime startTime, {bool isDerivedTimestamp = false}) =>
      _saveRecording(refs, startTime, isDerivedTimestamp: isDerivedTimestamp);

  Future<String?> _saveRecording(List<FrameRef> refs, DateTime startTime, {bool? isDerivedTimestamp}) async {
    final derived = isDerivedTimestamp ?? _isDerivedTimestamp;
    final prefix = derived ? 'unknown' : 'recording';
    final timestamp = startTime.millisecondsSinceEpoch;

    String dateFolderPath;
    if (_outputDir != null) {
      dateFolderPath = _outputDir!;
    } else {
      final directory = await getApplicationDocumentsDirectory();
      final dateString =
          '${startTime.year}-${startTime.month.toString().padLeft(2, '0')}-${startTime.day.toString().padLeft(2, '0')}';
      dateFolderPath = '${directory.path}/recordings/$dateString';
    }

    final dateFolder = Directory(dateFolderPath);
    if (!await dateFolder.exists()) {
      await dateFolder.create(recursive: true);
    }

    if (refs.length < 5) {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix);
    }

    final m4aPath = '${dateFolder.path}/${prefix}_$timestamp.m4a';

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
    bool aacFailed = false;
    bool hasEncodedAnyFrames = false;

    try {
      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
    } on Exception catch (e) {
      Logger.error('VadAudioProcessor: AAC startEncoder failed, falling back to WAV: $e');
      aacFailed = true;
    }

    if (aacFailed) {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix);
    }

    Future<void> flushBatch() async {
      if (batchBuffer.isEmpty) return;
      final bytes = batchBuffer.takeBytes();
      batchFrameCount = 0;
      hasEncodedAnyFrames = true;
      await AacEncoder.encodeBuffer(sessionId!, bytes);
    }

    String? currentFilePath;
    Uint8List? currentFileBytes;

    try {
      for (var i = 0; i < refs.length; i++) {
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        final ref = refs[i];

        if (ref.segmentFile.path != currentFilePath) {
          // Note: reading the entire file into memory is a tradeoff (avoids thousands of native file seek/read calls).
          // Segment files are typically small enough (a few MBs) to make this safe and dramatically faster.
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
        }

        if (currentFileBytes == null) continue;

        final frameDataOffset = ref.byteOffset + 4;
        final opusBytes = currentFileBytes.sublist(frameDataOffset, frameDataOffset + ref.frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (e) {
          continue;
        }

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
        }
      }

      await flushBatch();

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
      final corruptFile = File('${dateFolder.path}/${prefix}_$timestamp.m4a');
      try {
        if (await corruptFile.exists()) await corruptFile.delete();
      } catch (_) {}
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix);
    }

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
    final metaBytes = ByteData(408);
    metaBytes.setUint32(0, totalSamples, Endian.little);
    metaBytes.setUint32(4, durationMs, Endian.little);
    for (int i = 0; i < waveformBuckets; i++) {
      final peak16 = (finalAmplitudes[i] * 65535.0).round().clamp(0, 65535);
      metaBytes.setUint16(8 + i * 2, peak16, Endian.little);
    }
    final metaPath = '${dateFolder.path}/${prefix}_$timestamp.meta';
    final List<int> metaOut = [...metaBytes.buffer.asUint8List()];
    final rawId = _deviceId;
    if (rawId.isNotEmpty) {
      final deviceId = rawId.replaceAll(':', '').toUpperCase();
      if (deviceId.length >= 6) {
        final mac6 = deviceId.substring(0, 6);
        final uploadKey = '${mac6}_recording_$timestamp.m4a';
        final keyBytes = uploadKey.codeUnits;
        final truncatedKey = keyBytes.length > 255 ? keyBytes.sublist(0, 255) : keyBytes;
        metaOut.add(truncatedKey.length);
        metaOut.addAll(truncatedKey);
      }
    }
    await File(metaPath).writeAsBytes(metaOut);

    Logger.debug('VadAudioProcessor: Saved recording (${refs.length} frames, ${durationMs}ms) '
        'starting at $startTime to $m4aPath');
    return m4aPath;
  }

  Future<String> _saveWav(List<FrameRef> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording'}) async {
    final wavPath = '$dateFolderPath/${prefix}_$timestamp.wav';
    final wavFile = File(wavPath);
    final IOSink sink = wavFile.openWrite();

    String? currentFilePath;
    Uint8List? currentFileBytes;

    final List<Uint8List> decodedSegments = [];
    final wavDecoder =
        Platform.isIOS || Platform.isAndroid ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels) : null;
    if (wavDecoder != null) {
      try {
        for (var i = 0; i < refs.length; i++) {
          if (i % 50 == 0) await Future.delayed(Duration.zero);

          final ref = refs[i];

          if (ref.segmentFile.path != currentFilePath) {
            currentFileBytes = await ref.segmentFile.readAsBytes();
            currentFilePath = ref.segmentFile.path;
          }

          if (currentFileBytes == null) continue;

          final frameDataOffset = ref.byteOffset + 4;
          final opusBytes = currentFileBytes.sublist(frameDataOffset, frameDataOffset + ref.frameLength);

          try {
            final decoded = wavDecoder.decode(input: opusBytes);
            decodedSegments.add(decoded.buffer.asUint8List());
          } catch (e) {
            // Skip corrupt frame
          }
        }
      } finally {
        wavDecoder.destroy();
      }
    }

    final int totalPcmBytes = decodedSegments.fold(0, (sum, segment) => sum + segment.length);

    final header = ByteData(44);
    // RIFF
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, 36 + totalPcmBytes, Endian.little);
    // WAVE
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    // fmt
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little); // chunk size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little); // byte rate
    header.setUint16(32, channels * 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    // data
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, totalPcmBytes, Endian.little);

    sink.add(header.buffer.asUint8List());
    for (final segment in decodedSegments) {
      sink.add(segment);
    }
    await sink.close();

    Logger.debug('VadAudioProcessor: Saved WAV fallback to $wavPath');
    return wavPath;
  }
}
