import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/frame_ref.dart';
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
  static const double _noiseFloorAlphaFall = 0.98; // ~2s to adapt downward

  final SimpleOpusDecoder? _decoder;

  // FrameRef disk-pointer accumulation — no Opus bytes held in memory.
  List<FrameRef> _currentRecordingRefs = [];
  int _consecutiveSilenceFrames = 0;

  // SNR-based VAD state
  double _noiseFloorDbfs = -40.0;
  int _hangoverFrames = 0;
  int _speechFrameCount = 0;
  int _skippedFrameCount = 0;
  int _skippedFramesInRecording = 0; // skipped frames in current recording — keeps timestamps accurate
  int _noiseFloorInitFrames = 50; // first ~1s: fast convergence without alpha
  int _noiseFloorStaleFrames = 0;
  static const int _maxNoiseFloorStaleFrames = 250; // ~5 seconds at 50fps

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
        _snrMarginDb = SharedPreferencesUtil().vadSnrMarginDb,
        _hangoverFrameCount =
            max(0, (SharedPreferencesUtil().offlineHangoverSeconds * 1000).round() ~/ frameDurationMs),
        _silenceDurationToSplitMs = SharedPreferencesUtil().vadSplitSeconds * 1000,
        _minSpeechMs = SharedPreferencesUtil().vadMinSpeechSeconds * 1000,
        _preSpeechBufferMs = (SharedPreferencesUtil().vadPreSpeechSeconds * 1000).round(),
        _gapThresholdMs = SharedPreferencesUtil().vadGapSeconds * 1000;

  void destroy() {
    _decoder?.destroy();
  }

  /// True when there is an in-progress conversation with accumulated speech.
  /// Checking _speechFrameCount > 0 is critical: after the silence threshold
  /// fires, _currentRecordingRefs is refilled with trailing silence frames
  /// as a pre-speech buffer for the next conversation, but _speechFrameCount
  /// is reset to 0. Without this guard, isCapturing would return true
  /// for those silence-only frames, preventing lastSafeToDeleteIndex from
  /// advancing and causing background deletion to stall.
  bool get isCapturing => _currentRecordingRefs.isNotEmpty && _speechFrameCount > 0;

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

  /// Processes a single .bin segment file.
  ///
  /// Reads the file, parses frame offsets, runs SNR VAD on decoded PCM,
  /// and stores [FrameRef] disk-pointers instead of Opus bytes.
  /// Completed conversations are encoded to M4A immediately.
  ///
  /// Returns a list of saved file paths for any recordings completed during
  /// this segment.
  Future<List<String>> processSegmentFile(File segmentFile, DateTime fallbackStartTime) async {
    final List<String> savedFiles = [];
    final DateTime segmentStartTime = fallbackStartTime;

    // Read file bytes (one segment at a time, ~240 KB — GC'd after this call returns).
    // Bytes are used for VAD decoding; only lightweight FrameRef structs persist.
    final bytes = await segmentFile.readAsBytes();
    if (bytes.isEmpty) return savedFiles;

    final byteData = ByteData.sublistView(bytes);

    // 1. Gap detection — force-split if device was off between segments
    if (_currentRecordingRefs.isNotEmpty && _recordingStartTime != null) {
      final expectedStartTime = _recordingStartTime!
          .add(Duration(milliseconds: (_currentRecordingRefs.length + _skippedFramesInRecording) * frameDurationMs));
      final gapMs = segmentStartTime.difference(expectedStartTime).inMilliseconds.abs();
      if (gapMs > _gapThresholdMs) {
        final filePath = await flushRemaining();
        if (filePath != null) savedFiles.add(filePath);
      }
    }

    if (_currentRecordingRefs.isEmpty) {
      _recordingStartTime = segmentStartTime;
    }

    // 3. Process audio frames — store FrameRefs, run VAD on decoded PCM
    int off = 0;
    int frameIndex = 0;
    while (off + 4 <= bytes.length) {
      final len = byteData.getUint32(off, Endian.little);
      if (len > 4000) {
        // Sanity check: Opus frames should never exceed ~4000 bytes
        Logger.warning('OfflineAudioProcessor: Skipping corrupt frame with length $len at offset $off');
        off += 4; // Skip just the length field and try to find next valid frame
        _skippedFrameCount++;
        _skippedFramesInRecording++;
        continue;
      }
      if (off + 4 + len > bytes.length) break;

      final byteOffset = off; // position of 4-byte length prefix — used in FrameRef
      off += 4;

      final opusFrame = bytes.sublist(off, off + len);
      off += len;

      if (frameIndex++ % 50 == 0) await Future.delayed(Duration.zero);

      Int16List pcmData;
      try {
        if (_decoder == null) continue;
        pcmData = _decoder!.decode(input: Uint8List.fromList(opusFrame));
      } catch (e) {
        // Skip corrupt or invalid Opus frames
        _skippedFrameCount++;
        _skippedFramesInRecording++;
        continue;
      }

      final dbfs = _calculateDecibels(pcmData);

      // Fast convergence during initial frames — clamps downward with a +3 dB guard
      if (_noiseFloorInitFrames > 0) {
        _noiseFloorDbfs = min(_noiseFloorDbfs, dbfs + 3);
        _noiseFloorInitFrames--;
      }

      // SNR speech test
      final bool rawSpeech = dbfs > _noiseFloorDbfs + _snrMarginDb;

      // Asymmetric noise floor adaptation during silence
      if (!rawSpeech) {
        _noiseFloorStaleFrames = 0;
        if (dbfs > _noiseFloorDbfs) {
          _noiseFloorDbfs = _noiseFloorAlphaRise * _noiseFloorDbfs + (1 - _noiseFloorAlphaRise) * dbfs;
        } else {
          _noiseFloorDbfs = _noiseFloorAlphaFall * _noiseFloorDbfs + (1 - _noiseFloorAlphaFall) * dbfs;
        }
      } else {
        _noiseFloorStaleFrames++;
        // If noise floor seems stuck (everything looks like speech for too long), force adapt
        if (_noiseFloorStaleFrames > _maxNoiseFloorStaleFrames) {
          _noiseFloorDbfs = _noiseFloorAlphaRise * _noiseFloorDbfs + (1 - _noiseFloorAlphaRise) * dbfs;
          _noiseFloorStaleFrames = 0;
        }
      }

      // Hangover smoothing
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

      // Update counters
      if (!activeSpeech) {
        _consecutiveSilenceFrames++;
      } else {
        _consecutiveSilenceFrames = 0;
        _speechFrameCount++;
      }

      // Store disk pointer — no Opus bytes held in memory
      _currentRecordingRefs.add(FrameRef(segmentFile: segmentFile, byteOffset: byteOffset, frameLength: len));

      final silenceDurationMs = _consecutiveSilenceFrames * frameDurationMs;

      if (silenceDurationMs >= _silenceDurationToSplitMs) {
        final framesToKeep = _currentRecordingRefs.length - _consecutiveSilenceFrames;

        if (framesToKeep > 0) {
          final recordingRefs = _currentRecordingRefs.sublist(0, framesToKeep);
          if (_speechFrameCount * frameDurationMs >= _minSpeechMs) {
            final filePath = await _saveRecording(recordingRefs, _recordingStartTime!);
            if (filePath != null) savedFiles.add(filePath);
          }
        }

        final preSpeechFramesCount = _preSpeechBufferMs ~/ frameDurationMs;
        final bufferToKeep = min(preSpeechFramesCount, _consecutiveSilenceFrames);

        if (_recordingStartTime != null) {
          final int elapsedMs = (_currentRecordingRefs.length + _skippedFramesInRecording - bufferToKeep) * frameDurationMs;
          _recordingStartTime = _recordingStartTime!.add(Duration(milliseconds: elapsedMs));
        } else {
          _recordingStartTime = segmentStartTime;
        }

        _currentRecordingRefs = _currentRecordingRefs.sublist(_currentRecordingRefs.length - bufferToKeep);
        _speechFrameCount = 0;
        _hangoverFrames = 0;
        _consecutiveSilenceFrames = bufferToKeep;
        _skippedFramesInRecording = 0;
        // Reset fast-convergence so the new recording re-anchors to the current noise floor.
        _noiseFloorInitFrames = 50;
      }
    }

    if (_skippedFrameCount > 0) {
      Logger.warning('OfflineAudioProcessor: Skipped $_skippedFrameCount corrupt Opus frames');
    }

    if (bytes.isNotEmpty) {
      Logger.debug("OfflineAudioProcessor: Processed segment (${frameIndex} audio frames). "
          "Speech: $_speechFrameCount, NoiseFloor: ${_noiseFloorDbfs.toStringAsFixed(1)} dB, Margin: $_snrMarginDb dB");
    }

    return savedFiles;
  }

  /// No-op: completed conversations are already written by [processSegmentFile].
  /// Background callers use this instead of [flushRemaining] to avoid
  /// force-writing the in-progress tail.
  Future<List<String>> flushOnlyCompleted() async => [];

  Future<String?> flushRemaining() async {
    if (_currentRecordingRefs.isEmpty) return null;

    final framesToKeep = max(0, _currentRecordingRefs.length - _consecutiveSilenceFrames);

    String? filePath;
    if (framesToKeep > 0) {
      final refs = _currentRecordingRefs.sublist(0, framesToKeep);
      if (_speechFrameCount * frameDurationMs >= _minSpeechMs) {
        filePath = await _saveRecording(refs, _recordingStartTime ?? DateTime.now());
        Logger.debug("OfflineAudioProcessor: Flushed remaining buffer.");
      }
    }

    _currentRecordingRefs.clear();
    _consecutiveSilenceFrames = 0;
    _speechFrameCount = 0;
    _hangoverFrames = 0;
    _skippedFramesInRecording = 0;
    return filePath;
  }

  /// Encodes a list of [FrameRef]s to M4A (with WAV fallback).
  ///
  /// Reads Opus bytes sequentially from source .bin files via [RandomAccessFile].
  /// Only one decoded PCM frame is held in memory at a time.
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

    // Short recording (<5 frames ~100ms) → write WAV fallback
    if (refs.length < 5) {
      return await _saveWav(refs, dateFolderPath, timestamp);
    }

    final m4aPath = '${dateFolder.path}/recording_$timestamp.m4a';

    // Waveform: Accumulate peaks in small windows, downsample at the end
    const waveformBuckets = 200;
    const windowSize = 800; // ~50ms windows
    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;

    // Batch size: 15 Opus frames × 320 samples × 2 bytes = 9600 bytes
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
      Logger.error('OfflineAudioProcessor: AAC startEncoder failed, falling back to WAV: $e');
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

    // Sequential file reads — open each source file once, seek only when needed
    String? currentFilePath;
    RandomAccessFile? currentRaf;
    int nextExpectedOffset = -1;
    // Fresh decoder for the save pass — avoids stale state from the VAD pass.
    final saveDecoder = Platform.isIOS || Platform.isAndroid
        ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
        : null;

    try {
      for (var i = 0; i < refs.length; i++) {
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        final ref = refs[i];

        // Open new file if different from current
        if (ref.segmentFile.path != currentFilePath) {
          await currentRaf?.close();
          currentRaf = await ref.segmentFile.open(mode: FileMode.read);
          currentFilePath = ref.segmentFile.path;
          nextExpectedOffset = -1;
        }

        // Seek to frame payload — skip 4-byte length prefix
        final frameDataOffset = ref.byteOffset + 4;
        if (nextExpectedOffset != frameDataOffset) {
          await currentRaf!.setPosition(frameDataOffset);
        }

        final opusBytes = Uint8List.fromList(await currentRaf!.read(ref.frameLength));
        nextExpectedOffset = frameDataOffset + ref.frameLength;

        Int16List pcmData;
        try {
          if (saveDecoder == null) continue;
          pcmData = saveDecoder.decode(input: opusBytes);
        } catch (e) {
          continue;
        }

        // Update dynamic waveform peaks
        for (int s = 0; s < pcmData.length; s++) {
          final amplitude = pcmData[s].abs() / 32768.0;
          if (amplitude > currentWindowMax) {
            currentWindowMax = amplitude;
          }
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
        // Encoder was started but no PCM data was decoded — calling finishEncoder
        // would trigger "Stop() called but track not started" in MPEG4Writer.
        // Abandon cleanly: delete the empty file and return null.
        Logger.debug('OfflineAudioProcessor: No frames encoded — discarding empty segment.');
        final emptyFile = File(m4aPath);
        if (await emptyFile.exists()) await emptyFile.delete();
        return null;
      }

      await AacEncoder.finishEncoder(sessionId!);
    } on Exception catch (e) {
      Logger.error('OfflineAudioProcessor: AAC encoding failed, falling back to WAV: $e');
      // Delete the corrupt M4A file (not .tmp.m4a)
      final corruptFile = File('${dateFolder.path}/recording_$timestamp.m4a');
      try {
        if (await corruptFile.exists()) await corruptFile.delete();
      } catch (_) {}
      // Do not close currentRaf here — the finally block handles it.
      return await _saveWav(refs, dateFolderPath, timestamp);
    } finally {
      await currentRaf?.close();
      saveDecoder?.destroy();
    }

    // Downsample dynamic peaks to exactly 200 buckets
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

    // Write .meta sidecar (408 bytes base + optional upload key)
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

    Logger.debug(
        "OfflineAudioProcessor: Saved recording (${refs.length} frames, ${durationMs}ms) starting at $startTime to $m4aPath");
    return m4aPath;
  }

  /// WAV fallback used for very short recordings or when AAC encoder fails.
  Future<String> _saveWav(List<FrameRef> refs, String dateFolderPath, int timestamp) async {
    final wavPath = '$dateFolderPath/recording_$timestamp.wav';
    final wavFile = File(wavPath);
    final IOSink sink = wavFile.openWrite();

    String? currentFilePath;
    RandomAccessFile? currentRaf;
    int nextExpectedOffset = -1;

    final List<Uint8List> decodedSegments = [];
    // Fresh decoder for the WAV save pass — avoids stale state from the VAD pass.
    final wavDecoder = Platform.isIOS || Platform.isAndroid
        ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
        : null;
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
    for (var pcm in decodedSegments) {
      sink.add(pcm);
    }
    await sink.close();
    Logger.debug("OfflineAudioProcessor: Saved WAV fallback (${refs.length} frames) to $wavPath");
    return wavPath;
  }
}
