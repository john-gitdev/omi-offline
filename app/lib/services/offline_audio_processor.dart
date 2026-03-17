import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/utils/logger.dart';

class OfflineAudioProcessor {
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int preSpeechBufferMs = 1000; // 1 second

  // Opus frame is typically 20ms
  static const int frameDurationMs = 20;

  // Asymmetric noise floor tracking: slow to rise (avoid loud transients suppressing speech),
  // slow to fall (preserve sensitivity after leaving a noisy environment).
  // Rise is intentionally conservative — biased toward keeping more audio.
  static const double _noiseFloorAlphaRise = 0.995; // ~10s to adapt upward
  static const double _noiseFloorAlphaFall = 0.98;  // ~2s to adapt downward

  final SimpleOpusDecoder? _decoder;

  List<Uint8List> _currentRecordingFrames = [];
  int _consecutiveSilenceFrames = 0;

  // SNR-based VAD state
  double _noiseFloorDbfs = -40.0;
  int _hangoverFrames = 0;
  int _speechFrameCount = 0;
  int _noiseFloorInitFrames = 50; // first ~1s: fast convergence without alpha

  // For time tracking
  DateTime? _recordingStartTime;
  final String? _outputDir;

  // Cached settings for the duration of this processor instance (batch)
  final double _snrMarginDb;
  final int _hangoverFrameCount;
  final int _silenceDurationToSplitMs;
  final int _minSpeechMs;
  final int _preSpeechBufferMs;
  final int _gapThresholdMs;

  OfflineAudioProcessor({String? outputDir, SimpleOpusDecoder? decoder})
      : _decoder = decoder ??
            (Platform.isIOS || Platform.isAndroid
                ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
                : null),
        _outputDir = outputDir,
        _snrMarginDb = SharedPreferencesUtil().offlineSnrMarginDb,
        _hangoverFrameCount = max(0, (SharedPreferencesUtil().offlineHangoverSeconds * 1000).round() ~/ frameDurationMs),
        _silenceDurationToSplitMs = SharedPreferencesUtil().offlineSplitSeconds * 1000,
        _minSpeechMs = SharedPreferencesUtil().offlineMinSpeechSeconds * 1000,
        _preSpeechBufferMs = (SharedPreferencesUtil().offlinePreSpeechSeconds * 1000).round(),
        _gapThresholdMs = SharedPreferencesUtil().offlineGapSeconds * 1000;

  void destroy() {
    _decoder?.destroy();
  }

  /// True when there is an in-progress conversation with accumulated speech.
  /// Checking _speechFrameCount > 0 is critical: after the silence threshold
  /// fires, _currentRecordingFrames is refilled with trailing silence frames
  /// as a pre-speech buffer for the next conversation, but _speechFrameCount
  /// is reset to 0. Without this guard, hasOngoingRecording would return true
  /// for those silence-only frames, preventing lastSafeToDeleteIndex from
  /// advancing and causing background deletion to stall.
  bool get hasOngoingRecording => _currentRecordingFrames.isNotEmpty && _speechFrameCount > 0;

  double _calculateDecibels(Int16List pcmData) {
    if (pcmData.isEmpty) return -100.0; // Minimum representable dBFS

    double sumSquares = 0.0;
    for (int sample in pcmData) {
      sumSquares += sample * sample;
    }

    double rms = sqrt(sumSquares / pcmData.length);
    if (rms == 0) return -100.0;

    // Convert RMS to dBFS (decibels relative to full scale)
    // 16-bit PCM has a maximum absolute value of 32768
    double dbfs = 20 * log(rms / 32768) / ln10;
    return dbfs;
  }

  /// Processes a list of Opus frames.
  /// Returns a list of saved file paths if any recordings were completed during this chunk.
  Future<List<String>> processFrames(List<Uint8List> opusFrames, DateTime fallbackStartTime, {int? sessionId}) async {
    List<String> savedFiles = [];

    // 1. Scan for the first 255 metadata packet to get exact timing
    DateTime chunkStartTime = fallbackStartTime;

    if (sessionId != null) {
      for (var frame in opusFrames) {
        if (frame.length == 255) {
          try {
            var byteData = ByteData.sublistView(frame);
            var utcTime = byteData.getUint32(0, Endian.little);
            var uptimeMs = byteData.getUint32(4, Endian.little);

            if (utcTime > 0) {
              chunkStartTime = DateTime.fromMillisecondsSinceEpoch(utcTime * 1000);
            } else {
              // Lookup anchor
              final anchorUtc = SharedPreferencesUtil().getInt('anchor_utc_$sessionId', defaultValue: 0);
              final anchorUptime = SharedPreferencesUtil().getInt('anchor_uptime_$sessionId', defaultValue: 0);

              if (anchorUtc > 0 && anchorUptime > 0) {
                final realUtcSecs = anchorUtc - ((anchorUptime - uptimeMs) ~/ 1000);
                chunkStartTime = DateTime.fromMillisecondsSinceEpoch(realUtcSecs * 1000);
              }
            }
            break; // Found the precise time, stop scanning
          } catch (e) {
            Logger.error("OfflineAudioProcessor: Error parsing metadata packet: $e");
            // skip corrupt
          }
        }
      }
    }

    if (_currentRecordingFrames.isNotEmpty && _recordingStartTime != null) {
      final expectedStartTime =
          _recordingStartTime!.add(Duration(milliseconds: _currentRecordingFrames.length * frameDurationMs));
      final gapMs = chunkStartTime.difference(expectedStartTime).inMilliseconds.abs();

      // If there is a gap, force a split (e.g., device was turned off)
      if (gapMs > _gapThresholdMs) {
        final filePath = await flushRemaining();
        if (filePath != null) {
          savedFiles.add(filePath);
        }
      }
    }

    if (_currentRecordingFrames.isEmpty) {
      _recordingStartTime = chunkStartTime;
    }

    int _frameIndex = 0;
    for (var frame in opusFrames) {
      // Skip the metadata packets during actual audio processing
      if (frame.length == 255) continue;

      if (_frameIndex++ % 50 == 0) await Future.delayed(Duration.zero);

      Int16List pcmData;
      try {
        if (_decoder == null) continue;
        pcmData = _decoder!.decode(input: frame);
      } catch (e) {
        // Skip corrupt or invalid Opus frames
        continue;
      }

      final dbfs = _calculateDecibels(pcmData);

      // 1. Fast convergence during initial frames — clamps downward with a +3 dB guard
      //    so early speech frames don't drive the floor too low
      if (_noiseFloorInitFrames > 0) {
        _noiseFloorDbfs = min(_noiseFloorDbfs, dbfs + 3);
        _noiseFloorInitFrames--;
      }

      // 2. SNR speech test
      final bool rawSpeech = dbfs > _noiseFloorDbfs + _snrMarginDb;

      // 3. Asymmetric noise floor adaptation during silence:
      //    - Rise slowly on louder frames (conservative — avoids transients suppressing speech)
      //    - Fall slowly on quieter frames (recovers sensitivity after leaving noisy environment)
      if (!rawSpeech) {
        if (dbfs > _noiseFloorDbfs) {
          _noiseFloorDbfs = _noiseFloorAlphaRise * _noiseFloorDbfs + (1 - _noiseFloorAlphaRise) * dbfs;
        } else {
          _noiseFloorDbfs = _noiseFloorAlphaFall * _noiseFloorDbfs + (1 - _noiseFloorAlphaFall) * dbfs;
        }
      }

      // 4. Hangover smoothing
      bool activeSpeech;
      if (rawSpeech) {
        _hangoverFrames = _hangoverFrameCount;
        activeSpeech = true;
      } else if (_hangoverFrames > 0) {
        _hangoverFrames--;
        activeSpeech = true;
      } else {
        activeSpeech = false;
      }

      // 5. Update counters
      if (!activeSpeech) {
        _consecutiveSilenceFrames++;
      } else {
        _consecutiveSilenceFrames = 0;
        _speechFrameCount++;
      }

      _currentRecordingFrames.add(frame);

      final silenceDurationMs = _consecutiveSilenceFrames * frameDurationMs;

      if (silenceDurationMs >= _silenceDurationToSplitMs) {
        final framesToKeep = _currentRecordingFrames.length - _consecutiveSilenceFrames;

        if (framesToKeep > 0) {
          final recordingFrames = _currentRecordingFrames.sublist(0, framesToKeep);

          if (_speechFrameCount * frameDurationMs >= _minSpeechMs) {
            final filePath = await _saveRecording(recordingFrames, _recordingStartTime!);
            savedFiles.add(filePath);
          }
        }

        final preSpeechFramesCount = _preSpeechBufferMs ~/ frameDurationMs;
        final bufferToKeep = min(preSpeechFramesCount, _consecutiveSilenceFrames);

        if (_recordingStartTime != null) {
          final int elapsedMs = (_currentRecordingFrames.length - bufferToKeep) * frameDurationMs;
          _recordingStartTime = _recordingStartTime!.add(Duration(milliseconds: elapsedMs));
        } else {
          _recordingStartTime = chunkStartTime;
        }

        _currentRecordingFrames = _currentRecordingFrames.sublist(_currentRecordingFrames.length - bufferToKeep);
        _speechFrameCount = 0;
        _hangoverFrames = 0;
        _consecutiveSilenceFrames = bufferToKeep;
      }
    }

    if (opusFrames.isNotEmpty) {
      Logger.debug("OfflineAudioProcessor: Processed ${opusFrames.length} frames. "
          "Speech: $_speechFrameCount, NoiseFloor: ${_noiseFloorDbfs.toStringAsFixed(1)} dB, Margin: $_snrMarginDb dB");
    }

    return savedFiles;
  }

  /// No-op: completed conversations are already written by [processFrames].
  /// Background callers use this instead of [flushRemaining] to avoid
  /// force-writing the in-progress tail.
  Future<List<String>> flushOnlyCompleted() async => [];

  Future<String?> flushRemaining() async {
    if (_currentRecordingFrames.isEmpty) return null;

    final framesToKeep = max(0, _currentRecordingFrames.length - _consecutiveSilenceFrames);

    String? filePath;
    if (framesToKeep > 0) {
      final recordingFrames = _currentRecordingFrames.sublist(0, framesToKeep);

      if (_speechFrameCount * frameDurationMs >= _minSpeechMs) {
        filePath = await _saveRecording(recordingFrames, _recordingStartTime ?? DateTime.now());
        Logger.debug("OfflineAudioProcessor: Flushed remaining buffer.");
      }
    }

    _currentRecordingFrames.clear();
    _consecutiveSilenceFrames = 0;
    _speechFrameCount = 0;
    _hangoverFrames = 0;
    return filePath;
  }

  Future<String> _saveRecording(List<Uint8List> frames, DateTime startTime) async {
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

    // Short recording (<100 ms) → write WAV fallback (AAC encoders may misbehave)
    if (frames.length < 5) {
      return await _saveWav(frames, dateFolderPath, timestamp);
    }

    final m4aPath = '${dateFolder.path}/recording_$timestamp.m4a';

    // Waveform: 200 fixed-size buckets of 800 samples (~50 ms at 16 kHz)
    const waveformBuckets = 200;
    const bucketSize = 800;
    final peakAmplitudes = List<double>.filled(waveformBuckets, 0.0);

    // Batch size: 15 Opus frames × 320 samples × 2 bytes = 9600 bytes
    const batchFrames = 15;
    final batchBuffer = BytesBuilder(copy: false);
    int totalSamples = 0;
    int batchFrameCount = 0;

    String? sessionId;
    bool aacFailed = false;

    try {
      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
    } on PlatformException catch (e) {
      Logger.error('OfflineAudioProcessor: AAC startEncoder failed, falling back to WAV: $e');
      aacFailed = true;
    }

    if (aacFailed) {
      return await _saveWav(frames, dateFolderPath, timestamp);
    }

    Future<void> flushBatch() async {
      if (batchBuffer.isEmpty) return;
      final bytes = batchBuffer.toBytes();
      batchBuffer.clear();
      batchFrameCount = 0;
      await AacEncoder.encodeChunk(sessionId!, Uint8List.fromList(bytes));
    }

    try {
      for (var i = 0; i < frames.length; i++) {
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        Int16List pcmData;
        try {
          if (_decoder == null) continue;
          pcmData = _decoder!.decode(input: frames[i]);
        } catch (e) {
          continue;
        }

        // Update waveform buckets
        for (int s = 0; s < pcmData.length; s++) {
          final bucketIndex = min(waveformBuckets - 1, (totalSamples + s) ~/ bucketSize);
          final amplitude = pcmData[s].abs() / 32768.0;
          if (amplitude > peakAmplitudes[bucketIndex]) {
            peakAmplitudes[bucketIndex] = amplitude;
          }
        }
        totalSamples += pcmData.length;

        // Accumulate raw PCM bytes into batch
        batchBuffer.add(pcmData.buffer.asUint8List(pcmData.offsetInBytes, pcmData.lengthInBytes));
        batchFrameCount++;

        if (batchFrameCount >= batchFrames) {
          await flushBatch();
        }
      }

      // Flush remaining batch
      await flushBatch();

      await AacEncoder.finishEncoder(sessionId!);
    } on PlatformException catch (e) {
      Logger.error('OfflineAudioProcessor: AAC encoding failed, falling back to WAV: $e');
      // Clean up partial temp file
      final tmpFile = File('${dateFolder.path}/recording_$timestamp.tmp.m4a');
      if (await tmpFile.exists()) await tmpFile.delete();
      return await _saveWav(frames, dateFolderPath, timestamp);
    }

    // Write .meta sidecar (408 bytes base + optional upload key)
    final durationMs = (totalSamples * 1000) ~/ sampleRate;
    final metaBytes = ByteData(408);
    metaBytes.setUint32(0, totalSamples, Endian.little);
    metaBytes.setUint32(4, durationMs, Endian.little);
    for (int i = 0; i < waveformBuckets; i++) {
      final peak16 = (peakAmplitudes[i] * 65535.0).round().clamp(0, 65535);
      metaBytes.setUint16(8 + i * 2, peak16, Endian.little);
    }
    final metaPath = '${dateFolder.path}/recording_$timestamp.meta';
    final List<int> metaOut = [...metaBytes.buffer.asUint8List()];
    final deviceId = SharedPreferencesUtil().btDevice.id.replaceAll(':', '').toUpperCase();
    if (deviceId.length >= 6) {
      final mac6 = deviceId.substring(0, 6);
      final uploadKey = '${mac6}_recording_$timestamp.m4a';
      final keyBytes = uploadKey.codeUnits;
      if (keyBytes.length <= 255) {
        metaOut.add(keyBytes.length);
        metaOut.addAll(keyBytes);
      }
    }
    await File(metaPath).writeAsBytes(metaOut);

    Logger.debug(
        "OfflineAudioProcessor: Saved recording (${frames.length} frames, ${durationMs}ms) starting at $startTime to $m4aPath");
    return m4aPath;
  }

  /// WAV fallback used for very short recordings or when AAC encoder fails.
  Future<String> _saveWav(List<Uint8List> frames, String dateFolderPath, int timestamp) async {
    final wavPath = '$dateFolderPath/recording_$timestamp.wav';
    final wavFile = File(wavPath);
    final IOSink sink = wavFile.openWrite();

    final List<Uint8List> decodedChunks = [];
    if (_decoder != null) {
      for (var i = 0; i < frames.length; i++) {
        if (i % 50 == 0) await Future.delayed(Duration.zero);
        try {
          final decoded = _decoder!.decode(input: frames[i]);
          decodedChunks.add(decoded.buffer.asUint8List());
        } catch (e) {
          // Skip corrupt frame
        }
      }
    }

    final int totalPcmBytes = decodedChunks.fold(0, (sum, chunk) => sum + chunk.length);

    final header = ByteData(44);
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, 36 + totalPcmBytes, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); //
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
    header.setUint32(40, totalPcmBytes, Endian.little);

    sink.add(header.buffer.asUint8List());
    for (var pcm in decodedChunks) {
      sink.add(pcm);
    }
    await sink.close();
    Logger.debug("OfflineAudioProcessor: Saved WAV fallback (${frames.length} frames) to $wavPath");
    return wavPath;
  }
}
