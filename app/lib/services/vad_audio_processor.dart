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

class VadAudioProcessor {
  // Silero VAD session + LSTM state (reset on gap detection)
  final OrtSession? _session;
  Float32List _h = Float32List(2 * 1 * 64); // LSTM hidden state
  Float32List _c = Float32List(2 * 1 * 64); // LSTM cell state
  final List<double> _pcmWindow = []; // accumulates samples toward 512-window

  // Opus decoder
  final SimpleOpusDecoder? _decoder;
  final String? _outputDir;

  // Per-conversation accumulation — FrameRef disk-pointers only, no Opus in RAM
  List<FrameRef> _currentRefs = [];
  int _speechFrameCount = 0;         // speech frames in current chunk
  int _skippedFramesInRecording = 0; // non-speech frames in current chunk (keeps timestamps correct)
  DateTime? _recordingStartTime;
  DateTime? _lastSegmentEndTime;

  // VAD state counters
  int _consecutiveSilenceFrames = 0;
  int _hangoverFrames = 0;           // frames remaining in hangover
  int _currentChunkDurationMs = 0;   // total frames accumulated (for max-cap)

  // Settings — cached at construction time for the lifetime of one processAll pass
  final double _speechThreshold;
  final int _hangoverFrameCount;
  final int _silenceDurationToSplitMs;
  final int _minSpeechMs;
  final int _preSpeechBufferMs;
  final int _gapThresholdMs;

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 20; // 20 ms per Opus frame
  static const int _vadWindowSamples = 512; // Silero VAD input size
  static const int _maxChunkMs = 30 * 60 * 1000; // 30-minute hard cap

  static Future<VadAudioProcessor> create({String? outputDir, SimpleOpusDecoder? decoder}) async {
    OrtEnv.instance.init();
    OrtSession? session;
    try {
      final data = await rootBundle.load('assets/models/silero_vad.onnx');
      final sessionOptions = OrtSessionOptions();
      session = OrtSession.fromBuffer(data.buffer.asUint8List(), sessionOptions);
    } catch (e) {
      Logger.error('VadAudioProcessor: Failed to load Silero VAD model, amplitude fallback active: $e');
    }
    return VadAudioProcessor._(outputDir: outputDir, decoder: decoder, session: session);
  }

  VadAudioProcessor._({String? outputDir, SimpleOpusDecoder? decoder, OrtSession? session})
      : _session = session,
        _decoder = decoder ?? (Platform.isIOS || Platform.isAndroid
            ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
            : null),
        _outputDir = outputDir,
        _speechThreshold = SharedPreferencesUtil().vadSpeechThreshold,
        _hangoverFrameCount = (SharedPreferencesUtil().vadHangoverSeconds * 1000).round() ~/ frameDurationMs,
        _silenceDurationToSplitMs = SharedPreferencesUtil().vadSplitSeconds * 1000,
        _minSpeechMs = SharedPreferencesUtil().vadMinSpeechSeconds * 1000,
        _preSpeechBufferMs = (SharedPreferencesUtil().vadPreSpeechSeconds * 1000).round(),
        _gapThresholdMs = SharedPreferencesUtil().vadGapSeconds * 1000;

  void destroy() {
    _decoder?.destroy();
    _session?.release();
  }

  bool get isCapturing => _currentRefs.isNotEmpty && _speechFrameCount > 0;

  bool _runVad(List<double> samples512) {
    if (_session == null) {
      // Amplitude fallback when model didn't load.
      return samples512.any((s) => s.abs() > _speechThreshold);
    }
    final input = Float32List.fromList(samples512);
    final sr    = Int64List.fromList([sampleRate]);

    final inputs = {
      'input': OrtValueTensor.createTensorWithDataList(input, [1, _vadWindowSamples]),
      'sr':    OrtValueTensor.createTensorWithDataList(sr, [1]),
      'h':     OrtValueTensor.createTensorWithDataList(_h, [2, 1, 64]),
      'c':     OrtValueTensor.createTensorWithDataList(_c, [2, 1, 64]),
    };

    final runOptions = OrtRunOptions();
    final outputs = _session!.run(runOptions, inputs);
    final prob = (outputs[0]!.value as List<List<List<double>>>)[0][0][0];

    _h = _flattenF32(outputs[1]!.value);
    _c = _flattenF32(outputs[2]!.value);
    for (final o in outputs) { o?.release(); }
    runOptions.release();

    return prob > _speechThreshold;
  }

  Float32List _flattenF32(dynamic nested) {
    final flat = <double>[];
    void recurse(dynamic v) {
      if (v is List) { for (final e in v) recurse(e); }
      else if (v is double) flat.add(v);
      else if (v is num)   flat.add(v.toDouble());
    }
    recurse(nested);
    return Float32List.fromList(flat);
  }

  Future<List<String>> processSegmentFile(File segmentFile, DateTime segmentStartTime) async {
    final savedFiles = <String>[];

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

      while (offset < fileLength) {
        if (offset + 4 > fileLength) break;

        final frameLength = byteData.getUint32(offset, Endian.little);

        if (frameLength == 0 || frameLength == 0xFFFFFFFF) {
          offset += 4;
          continue;
        }

        if (offset + 4 + frameLength > fileLength) {
          Logger.error('VadAudioProcessor: Incomplete frame at offset $offset in ${segmentFile.path}');
          break;
        }

        final opusBytes = bytes.sublist(offset + 4, offset + 4 + frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (_) {}

        bool isSpeech = false;
        if (pcmData != null) {
          for (int s = 0; s < pcmData.length; s++) {
            _pcmWindow.add(pcmData[s] / 32768.0);
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

        if (effectiveSpeech) {
          _speechFrameCount++;
          _consecutiveSilenceFrames = 0;
          _currentRefs.add(FrameRef(
            segmentFile: segmentFile,
            byteOffset: offset,
            frameLength: frameLength,
          ));
          _currentChunkDurationMs += frameDurationMs;
        } else {
          _consecutiveSilenceFrames++;
          _currentRefs.add(FrameRef(
            segmentFile: segmentFile,
            byteOffset: offset,
            frameLength: frameLength,
          ));
          _currentChunkDurationMs += frameDurationMs;
        }

        final silenceMs = _consecutiveSilenceFrames * frameDurationMs;
        if (silenceMs >= _silenceDurationToSplitMs) {
          if (_speechFrameCount * frameDurationMs >= _minSpeechMs) {
            final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
            if (filePath != null) savedFiles.add(filePath);
          }
          final preSpeechFrames = _preSpeechBufferMs ~/ frameDurationMs;
          final bufferToKeep = min(preSpeechFrames, _consecutiveSilenceFrames);
          _currentRefs = _currentRefs.sublist(_currentRefs.length - bufferToKeep);
          _speechFrameCount = 0;
          _skippedFramesInRecording = 0;
          _hangoverFrames = 0;
          _consecutiveSilenceFrames = 0;
          _currentChunkDurationMs = 0;
          _recordingStartTime = segmentStartTime.add(
            Duration(milliseconds: frameIndex * frameDurationMs)
          ).subtract(Duration(milliseconds: bufferToKeep * frameDurationMs));
        } else if (_currentChunkDurationMs >= _maxChunkMs) {
          Logger.debug('VadAudioProcessor: Max chunk duration — forcing cut.');
          final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
          if (filePath != null) savedFiles.add(filePath);
          _currentRefs = [];
          _speechFrameCount = 0;
          _skippedFramesInRecording = 0;
          _hangoverFrames = 0;
          _consecutiveSilenceFrames = 0;
          _currentChunkDurationMs = 0;
          _recordingStartTime = segmentStartTime.add(
            Duration(milliseconds: (frameIndex + 1) * frameDurationMs)
          );
        }

        offset += 4 + frameLength;
        frameIndex++;
        totalFrameCount++;
      }

      _lastSegmentEndTime = segmentStartTime.add(Duration(milliseconds: totalFrameCount * frameDurationMs));
    } catch (e) {
      Logger.error('VadAudioProcessor: processSegmentFile error: $e');
    }

    return savedFiles;
  }

  Future<String?> flushRemaining() async {
    if (_currentRefs.isEmpty || _speechFrameCount * frameDurationMs < _minSpeechMs) {
      _resetState();
      return null;
    }
    final path = await _saveRecording(_currentRefs, _recordingStartTime!);
    _resetState();
    return path;
  }

  Future<String?> flushOnlyCompleted() async => null;

  void _resetState() {
    _currentRefs = [];
    _speechFrameCount = 0;
    _skippedFramesInRecording = 0;
    _hangoverFrames = 0;
    _consecutiveSilenceFrames = 0;
    _currentChunkDurationMs = 0;
    _recordingStartTime = null;
  }

  Future<String?> _saveRecording(List<FrameRef> refs, DateTime startTime) async {
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = startTime.millisecondsSinceEpoch;

    String dateFolderPath;
    if (_outputDir != null) {
      dateFolderPath = _outputDir!;
    } else {
      final dateString =
          '${startTime.year}-${startTime.month.toString().padLeft(2, '0')}-${startTime.day.toString().padLeft(2, '0')}';
      dateFolderPath = '${directory.path}/recordings/$dateString';
    }

    final dateFolder = Directory(dateFolderPath);
    if (!await dateFolder.exists()) {
      await dateFolder.create(recursive: true);
    }

    if (refs.length < 5) {
      return await _saveWav(refs, dateFolderPath, timestamp);
    }

    final m4aPath = '${dateFolder.path}/recording_$timestamp.m4a';

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
      return await _saveWav(refs, dateFolderPath, timestamp);
    }

    Future<void> flushBatch() async {
      if (batchBuffer.isEmpty) return;
      final bytes = batchBuffer.toBytes();
      batchBuffer.clear();
      batchFrameCount = 0;
      hasEncodedAnyFrames = true;
      await AacEncoder.encodeBuffer(sessionId!, Uint8List.fromList(bytes));
    }

    String? currentFilePath;
    RandomAccessFile? currentRaf;
    int nextExpectedOffset = -1;

    try {
      for (var i = 0; i < refs.length; i++) {
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        final ref = refs[i];

        if (ref.segmentFile.path != currentFilePath) {
          await currentRaf?.close();
          currentRaf = await ref.segmentFile.open(mode: FileMode.read);
          currentFilePath = ref.segmentFile.path;
          nextExpectedOffset = -1;
        }

        final frameDataOffset = ref.byteOffset + 4;
        if (nextExpectedOffset != frameDataOffset) {
          await currentRaf!.setPosition(frameDataOffset);
        }

        final opusBytes = Uint8List.fromList(await currentRaf!.read(ref.frameLength));
        nextExpectedOffset = frameDataOffset + ref.frameLength;

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
      final corruptFile = File('${dateFolder.path}/recording_$timestamp.m4a');
      try {
        if (await corruptFile.exists()) await corruptFile.delete();
      } catch (_) {}
      return await _saveWav(refs, dateFolderPath, timestamp);
    } finally {
      await currentRaf?.close();
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
    final metaPath = '${dateFolder.path}/recording_$timestamp.meta';
    final List<int> metaOut = [...metaBytes.buffer.asUint8List()];
    final rawId = SharedPreferencesUtil().btDevice.id;
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

  Future<String> _saveWav(List<FrameRef> refs, String dateFolderPath, int timestamp) async {
    final wavPath = '$dateFolderPath/recording_$timestamp.wav';
    final wavFile = File(wavPath);
    final IOSink sink = wavFile.openWrite();

    String? currentFilePath;
    RandomAccessFile? currentRaf;
    int nextExpectedOffset = -1;

    final List<Uint8List> decodedSegments = [];
    final wavDecoder =
        Platform.isIOS || Platform.isAndroid ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels) : null;
    if (wavDecoder != null) {
      try {
        for (var i = 0; i < refs.length; i++) {
          if (i % 50 == 0) await Future.delayed(Duration.zero);

          final ref = refs[i];

          if (ref.segmentFile.path != currentFilePath) {
            await currentRaf?.close();
            currentRaf = await ref.segmentFile.open(mode: FileMode.read);
            currentFilePath = ref.segmentFile.path;
            nextExpectedOffset = -1;
          }

          final frameDataOffset = ref.byteOffset + 4;
          if (nextExpectedOffset != frameDataOffset) {
            await currentRaf!.setPosition(frameDataOffset);
          }

          final opusBytes = Uint8List.fromList(await currentRaf!.read(ref.frameLength));
          nextExpectedOffset = frameDataOffset + ref.frameLength;

          try {
            final decoded = wavDecoder.decode(input: opusBytes);
            decodedSegments.add(decoded.buffer.asUint8List());
          } catch (e) {
            // Skip corrupt frame
          }
        }
      } finally {
        await currentRaf?.close();
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
