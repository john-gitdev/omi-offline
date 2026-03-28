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

/// Processor for fixed-interval recording mode.
///
/// Cuts recordings at wall-clock boundaries that fall 1 second before each
/// interval multiple (i.e. :29:59/:59:59 for 30-min, :59:59 for 1hr, etc.).
/// The -1 second offset ensures the last cut of any day lands at 23:59:59 and
/// never spills into the following day.
///
/// Boundary formula (where _intervalMs = intervalMinutes * 60000):
///   nextBoundary = ceil((epochMs + 1000) / _intervalMs) * _intervalMs - 1000
///
/// Example — 30-min, recording started 10:15am:
///   first cut  → 10:29:59
///   subsequent → 10:59:59, 11:29:59, 11:59:59, …
class FixedIntervalAudioProcessor {
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 20; // each Opus frame is 20 ms

  // 1 second before each interval boundary so 23:59:59 is always the last cut.
  static const int _boundaryOffsetMs = 1000;

  final SimpleOpusDecoder? _decoder;
  final String? _outputDir;
  final int _intervalMs;
  final int _gapThresholdMs;

  List<FrameRef> _currentRefs = [];
  DateTime? _recordingStartTime;
  int _nextBoundaryMs = 0; // 0 = not yet initialised
  DateTime? _lastSegmentEndTime; // for gap detection

  FixedIntervalAudioProcessor({String? outputDir, SimpleOpusDecoder? decoder})
      : _decoder = decoder ??
            (Platform.isIOS || Platform.isAndroid
                ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
                : null),
        _outputDir = outputDir,
        _intervalMs = SharedPreferencesUtil().offlineFixedIntervalMinutes * 60 * 1000,
        _gapThresholdMs = SharedPreferencesUtil().vadGapSeconds * 1000 {
    // Restore the boundary that was active when the previous run ended.
    // If nonzero, the next call to processSegmentFile will skip frames that
    // were already included in the last completed interval.
    // Sanity check: discard the persisted value if it is unreasonably old
    // (> 2× interval in the past) or in the future — both indicate stale/corrupt
    // state. Gap detection will handle a genuine long offline period correctly.
    final persisted = SharedPreferencesUtil().fixedModeNextBoundaryMs;
    if (persisted > 0) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final tooOld = persisted < nowMs - 2 * _intervalMs;
      final tooFuture = persisted > nowMs + _intervalMs;
      if (tooOld || tooFuture) {
        Logger.debug('FixedIntervalAudioProcessor: Discarding stale/corrupt persisted boundary '
            '${DateTime.fromMillisecondsSinceEpoch(persisted)} (now=${DateTime.fromMillisecondsSinceEpoch(nowMs)})');
        SharedPreferencesUtil().fixedModeNextBoundaryMs = 0;
      } else {
        _nextBoundaryMs = persisted;
        Logger.debug('FixedIntervalAudioProcessor: Restored persisted boundary '
            '${DateTime.fromMillisecondsSinceEpoch(persisted)}');
      }
    }
  }

  void destroy() {
    _decoder?.destroy();
  }

  /// True while frames are accumulating toward the next boundary.
  bool get isCapturing => _currentRefs.isNotEmpty;

  /// Computes the next boundary epoch (ms) at or after [epochMs].
  /// Boundaries sit 1 second before each interval multiple.
  int _computeNextBoundary(int epochMs) {
    final shifted = epochMs + _boundaryOffsetMs;
    final boundary = ((shifted / _intervalMs).ceil() * _intervalMs).toInt() - _boundaryOffsetMs;
    // If start is exactly on a boundary, advance by one full interval.
    return boundary <= epochMs ? boundary + _intervalMs : boundary;
  }

  /// Processes a single .bin segment file.
  ///
  /// Decodes the segment, emits a saved file each time a wall-clock boundary
  /// is crossed, and accumulates remaining frames for the next boundary.
  /// Returns a list of paths for any recordings saved during this call.
  Future<List<String>> processSegmentFile(File segmentFile, DateTime fallbackStartTime) async {
    final List<String> savedFiles = [];
    final DateTime segmentStartTime = fallbackStartTime;

    final bytes = await segmentFile.readAsBytes();
    if (bytes.isEmpty) return savedFiles;

    final byteData = ByteData.sublistView(bytes);

    // 1. Gap detection — if the device was offline long enough, flush the
    // current buffer as a partial interval and restart boundary tracking.
    if (_currentRefs.isNotEmpty && _lastSegmentEndTime != null) {
      final gapMs = segmentStartTime.difference(_lastSegmentEndTime!).inMilliseconds.abs();
      if (gapMs > _gapThresholdMs) {
        Logger.debug('FixedIntervalAudioProcessor: Gap of ${gapMs}ms detected — flushing partial interval.');
        final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
        if (filePath != null) savedFiles.add(filePath);
        _currentRefs = [];
        _nextBoundaryMs = 0;
        _recordingStartTime = null;
        SharedPreferencesUtil().fixedModeNextBoundaryMs = 0;
      }
    }

    // If we have a persisted boundary from a previous run and no frames
    // accumulated yet, this segment may straddle the already-completed boundary.
    // Compute how many leading frames to skip so we don't re-include audio that
    // was already saved in the previous interval.
    int framesToSkip = 0;
    if (_currentRefs.isEmpty && _nextBoundaryMs > 0) {
      final segmentStartMs = segmentStartTime.millisecondsSinceEpoch;
      if (segmentStartMs < _nextBoundaryMs) {
        framesToSkip = ((_nextBoundaryMs - segmentStartMs) / frameDurationMs).ceil();
        _recordingStartTime = DateTime.fromMillisecondsSinceEpoch(_nextBoundaryMs);
        Logger.debug('FixedIntervalAudioProcessor: Skipping $framesToSkip leading frames '
            '(already in previous interval). New interval starts at $_recordingStartTime');
      } else {
        // Segment starts at or after the boundary — no skip needed, compute fresh boundary.
        _recordingStartTime = segmentStartTime;
        _nextBoundaryMs = _computeNextBoundary(segmentStartMs);
      }
    }

    // Initialise start time and first boundary on first frame of a truly new interval.
    if (_currentRefs.isEmpty && _nextBoundaryMs == 0) {
      _recordingStartTime = segmentStartTime;
      _nextBoundaryMs = _computeNextBoundary(segmentStartTime.millisecondsSinceEpoch);
      Logger.debug(
          'FixedIntervalAudioProcessor: New interval started at $segmentStartTime, '
          'next boundary at ${DateTime.fromMillisecondsSinceEpoch(_nextBoundaryMs)}');
    }

    // 3. Walk frames.
    int off = 0;
    int frameIndex = 0;
    while (off + 4 <= bytes.length) {
      final len = byteData.getUint32(off, Endian.little);
      if (off + 4 + len > bytes.length) break;

      final byteOffset = off;
      off += 4;

      off += len;

      // Skip leading frames that were already included in the previous run's
      // last completed interval. frameIndex counts only non-metadata frames.
      if (frameIndex < framesToSkip) {
        frameIndex++;
        continue;
      }

      if (frameIndex++ % 50 == 0) await Future.delayed(Duration.zero);

      // Check boundary before accumulating this frame.
      // Use a while loop in case a long segment spans multiple boundaries.
      while (_currentRefs.isNotEmpty) {
        final frameEpochMs = _recordingStartTime!.millisecondsSinceEpoch + (_currentRefs.length * frameDurationMs);
        if (frameEpochMs < _nextBoundaryMs) break;

        // Emit interval up to (but not including) current frame — the frame at the
        // boundary belongs to the new interval.
        Logger.debug(
            'FixedIntervalAudioProcessor: Boundary reached at ${DateTime.fromMillisecondsSinceEpoch(_nextBoundaryMs)}, '
            'emitting ${_currentRefs.length} frames.');
        final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
        if (filePath != null) savedFiles.add(filePath);

        _recordingStartTime = DateTime.fromMillisecondsSinceEpoch(_nextBoundaryMs);
        _currentRefs = [];
        _nextBoundaryMs += _intervalMs;
        // Persist the new boundary so the next run can resume correctly.
        SharedPreferencesUtil().fixedModeNextBoundaryMs = _nextBoundaryMs;
      }

      _currentRefs.add(FrameRef(segmentFile: segmentFile, byteOffset: byteOffset, frameLength: len));
    }

    // Track when this segment ends for gap detection on the next call.
    _lastSegmentEndTime =
        _recordingStartTime!.add(Duration(milliseconds: _currentRefs.length * frameDurationMs));

    Logger.debug(
        'FixedIntervalAudioProcessor: Processed segment ($frameIndex frames). '
        'Accumulated ${_currentRefs.length} frames toward next boundary at '
        '${_nextBoundaryMs > 0 ? DateTime.fromMillisecondsSinceEpoch(_nextBoundaryMs) : "none"}.');

    return savedFiles;
  }

  /// No-op — completed intervals are written immediately by [processSegmentFile].
  /// Background callers use this instead of [flushRemaining] to avoid emitting
  /// a partial interval whose boundary hasn't been reached yet.
  Future<List<String>> flushOnlyCompleted() async => [];

  /// Flush any frames accumulated since the last boundary (partial interval).
  /// Call this at the end of a manual (foreground) sync to write the trailing interval.
  Future<String?> flushRemaining() async {
    if (_currentRefs.isEmpty) return null;
    final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
    _currentRefs = [];
    _nextBoundaryMs = 0;
    _recordingStartTime = null;
    _lastSegmentEndTime = null;
    // Partial interval fully written — no boundary to resume from next run.
    SharedPreferencesUtil().fixedModeNextBoundaryMs = 0;
    Logger.debug('FixedIntervalAudioProcessor: Flushed remaining buffer.');
    return filePath;
  }

  /// Encodes [refs] to M4A (with WAV fallback) and writes the .meta sidecar.
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
      Logger.error('FixedIntervalAudioProcessor: AAC startEncoder failed, falling back to WAV: $e');
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
    final saveDecoder = Platform.isIOS || Platform.isAndroid
        ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
        : null;

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

        Int16List pcmData;
        try {
          if (saveDecoder == null) continue;
          pcmData = saveDecoder.decode(input: opusBytes);
        } catch (e) {
          continue;
        }

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
        Logger.debug('FixedIntervalAudioProcessor: No frames encoded — discarding empty segment.');
        final emptyFile = File(m4aPath);
        if (await emptyFile.exists()) await emptyFile.delete();
        return null;
      }

      await AacEncoder.finishEncoder(sessionId!);
    } on Exception catch (e) {
      Logger.error('FixedIntervalAudioProcessor: AAC encoding failed, falling back to WAV: $e');
      // Delete the corrupt M4A file (not .tmp.m4a)
      final corruptFile = File('${dateFolder.path}/recording_$timestamp.m4a');
      try {
        if (await corruptFile.exists()) await corruptFile.delete();
      } catch (_) {}
      return await _saveWav(refs, dateFolderPath, timestamp);
    } finally {
      await currentRaf?.close();
      saveDecoder?.destroy();
    }

    // Downsample to 200 waveform buckets.
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

    // Write .meta sidecar (408 bytes base + optional upload key).
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
        'FixedIntervalAudioProcessor: Saved recording (${refs.length} frames, ${durationMs}ms) '
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
    // RIFF
    header.setUint8(0, 0x52); header.setUint8(1, 0x49); header.setUint8(2, 0x46); header.setUint8(3, 0x46);
    header.setUint32(4, 36 + totalPcmBytes, Endian.little);
    // WAVE
    header.setUint8(8, 0x57); header.setUint8(9, 0x41); header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    // fmt
    header.setUint8(12, 0x66); header.setUint8(13, 0x6D); header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little); // chunk size
    header.setUint16(20, 1, Endian.little);  // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little); // byte rate
    header.setUint16(32, channels * 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    // data
    header.setUint8(36, 0x64); header.setUint8(37, 0x61); header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, totalPcmBytes, Endian.little);

    sink.add(header.buffer.asUint8List());
    for (final segment in decodedSegments) {
      sink.add(segment);
    }
    await sink.close();

    Logger.debug('FixedIntervalAudioProcessor: Saved WAV fallback to $wavPath');
    return wavPath;
  }
}
