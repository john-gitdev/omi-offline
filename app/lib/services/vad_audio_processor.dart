import 'dart:io';
import 'dart:typed_data';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:omi/utils/logger.dart';

enum VadState { idle, recording }

/// Processor for amplitude-driven recording mode (replacing VAD temporarily).
///
/// Chunks recordings based on audio activity rather than wall-clock boundaries.
class VadAudioProcessor {
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 20;

  final SimpleOpusDecoder? _decoder;
  final String? _outputDir;

  VadState _state = VadState.idle;
  List<FrameRef> _currentRefs = [];
  DateTime? _recordingStartTime;
  DateTime? _lastSegmentEndTime;

  int _continuousSilenceMs = 0;
  static const int _silenceThresholdMs = 120000; // 2 minutes
  static const double _amplitudeThreshold = 0.05;

  VadAudioProcessor._({String? outputDir, SimpleOpusDecoder? decoder})
      : _decoder = decoder ??
            (Platform.isIOS || Platform.isAndroid
                ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
                : null),
        _outputDir = outputDir;

  static Future<VadAudioProcessor> create({String? outputDir, SimpleOpusDecoder? decoder}) async {
    final processor = VadAudioProcessor._(outputDir: outputDir, decoder: decoder);
    return processor;
  }

  void destroy() {
    _decoder?.destroy();
  }

  bool get isCapturing => _state == VadState.recording;

  Future<List<String>> processSegmentFile(File segmentFile, DateTime fallbackStartTime) async {
    final List<String> savedFiles = [];
    final DateTime segmentStartTime = fallbackStartTime;

    final bytes = await segmentFile.readAsBytes();
    if (bytes.isEmpty) return savedFiles;

    final byteData = ByteData.sublistView(bytes);

    if (_state == VadState.recording && _lastSegmentEndTime != null) {
      final gapMs = segmentStartTime.difference(_lastSegmentEndTime!).inMilliseconds;
      if (gapMs > 2000) {
        Logger.debug('VadAudioProcessor: Large gap of ${gapMs}ms detected — forcing chunk cut.');
        final filePath = await _flushRecording();
        if (filePath != null) savedFiles.add(filePath);
      }
    }

    int offset = 0;
    int frameIndex = 0;

    while (offset < bytes.length) {
      if (offset + 4 > bytes.length) break;

      final frameLength = byteData.getUint16(offset, Endian.little);

      if (offset + 4 + frameLength > bytes.length) break;

      final frameOffset = offset + 4;
      final opusBytes = bytes.sublist(frameOffset, frameOffset + frameLength);

      final ref = FrameRef(
        segmentFile: segmentFile,
        byteOffset: offset,
        frameLength: frameLength,
      );

      Int16List? pcmData;
      try {
        pcmData = _decoder?.decode(input: opusBytes);
      } catch (e) {
        // Skip
      }

      bool isSpeech = false;
      if (pcmData != null) {
        // Amplitude fallback simulating VAD
        double maxVolume = 0;
        for (int i = 0; i < pcmData.length; i++) {
           double vol = (pcmData[i] / 32768.0).abs();
           if (vol > maxVolume) maxVolume = vol;
        }
        isSpeech = maxVolume > _amplitudeThreshold;
      }

      final frameTime = segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));

      if (_state == VadState.idle) {
        if (isSpeech) {
          _state = VadState.recording;
          _recordingStartTime = frameTime;
          _currentRefs = [ref];
          _continuousSilenceMs = 0;
          Logger.debug('VadAudioProcessor: Speech detected, started recording at $_recordingStartTime');
        }
      } else {
        _currentRefs.add(ref);

        if (isSpeech) {
          _continuousSilenceMs = 0;
        } else {
          _continuousSilenceMs += frameDurationMs;
        }

        if (_continuousSilenceMs >= _silenceThresholdMs) {
          Logger.debug('VadAudioProcessor: Silence threshold reached, cutting chunk.');
          final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
          if (filePath != null) savedFiles.add(filePath);

          _state = VadState.idle;
          _currentRefs = [];
          _continuousSilenceMs = 0;
          _recordingStartTime = null;
        }
      }

      offset += 4 + frameLength;
      frameIndex++;
    }

    _lastSegmentEndTime = segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
    return savedFiles;
  }

  Future<String?> flushRemaining() async {
    if (_currentRefs.isNotEmpty) {
      Logger.debug('VadAudioProcessor: Flushing remaining buffer.');
      return await _flushRecording();
    }
    return null;
  }

  Future<String?> flushOnlyCompleted() async {
    // Only flush if we're actively capturing, but don't close the interval
    // so we can append to it on the next run. Wait, for VAD, this logic might
    // be different than FixedInterval because chunks are state-driven.
    // For now we just return null and don't reset the VAD state if we don't want to cut.
    return null;
  }

  Future<String?> _flushRecording() async {
      if (_currentRefs.isEmpty || _recordingStartTime == null) return null;
      final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);

      _state = VadState.idle;
      _currentRefs = [];
      _continuousSilenceMs = 0;
      _recordingStartTime = null;

      return filePath;
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
    if (_decoder != null) {
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
            final decoded = _decoder?.decode(input: opusBytes);
            if (decoded != null) {
              decodedSegments.add(decoded.buffer.asUint8List());
            }
          } catch (e) {
            // Skip corrupt frame
          }
        }
      } finally {
        await currentRaf?.close();
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
