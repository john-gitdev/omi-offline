import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_audio/return_code.dart';
import 'package:omi/backend/preferences.dart';

class OfflineAudioProcessor {
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int preSpeechBufferMs = 1000; // 1 second

  // Opus frame is typically 20ms
  static const int frameDurationMs = 20;

  final SimpleOpusDecoder _decoder;

  List<Uint8List> _currentRecordingFrames = [];
  int _consecutiveSilenceFrames = 0;

  // For time tracking
  DateTime? _recordingStartTime;

  // Cached settings for the duration of this processor instance (batch)
  final double _silenceThresholdDbfs;
  final int _silenceDurationToSplitMs;
  final int _minSpeechMs;

  OfflineAudioProcessor()
      : _decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels),
        _silenceThresholdDbfs = SharedPreferencesUtil().offlineSilenceThreshold,
        _silenceDurationToSplitMs = SharedPreferencesUtil().offlineSplitSeconds * 1000,
        _minSpeechMs = SharedPreferencesUtil().offlineMinSpeechSeconds * 1000;

  void destroy() {
    _decoder.destroy();
  }

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
  Future<List<String>> processFrames(List<Uint8List> opusFrames, DateTime chunkStartTime) async {
    List<String> savedFiles = [];

    if (_currentRecordingFrames.isNotEmpty && _recordingStartTime != null) {
      final expectedStartTime =
          _recordingStartTime!.add(Duration(milliseconds: _currentRecordingFrames.length * frameDurationMs));
      final gapMs = chunkStartTime.difference(expectedStartTime).inMilliseconds.abs();

      // If there is a gap of more than 10 seconds, force a split (e.g., device was turned off)
      if (gapMs > 10000) {
        final filePath = await flushRemaining();
        if (filePath != null) {
          savedFiles.add(filePath);
        }
        // State is cleared by flushRemaining, so the new chunk will start fresh
      }
    }

    if (_currentRecordingFrames.isEmpty) {
      _recordingStartTime = chunkStartTime;
    }

    for (var frame in opusFrames) {
      final pcmData = _decoder.decode(input: frame);
      final dbfs = _calculateDecibels(pcmData);

      if (dbfs < _silenceThresholdDbfs) {
        _consecutiveSilenceFrames++;
      } else {
        _consecutiveSilenceFrames = 0;
      }

      _currentRecordingFrames.add(frame);

      final silenceDurationMs = _consecutiveSilenceFrames * frameDurationMs;

      if (silenceDurationMs >= _silenceDurationToSplitMs) {
        // We hit the silence split mark.
        // We want to discard the final trailing silence (which is _consecutiveSilenceFrames long)
        final framesToKeep = _currentRecordingFrames.length - _consecutiveSilenceFrames;

        if (framesToKeep > 0) {
          final recordingFrames = _currentRecordingFrames.sublist(0, framesToKeep);

          int maxConsecutiveSpeechFrames = 0;
          int currentConsecutiveSpeechFrames = 0;

          final tempDecoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
          for (var rFrame in recordingFrames) {
            final rPcmData = tempDecoder.decode(input: rFrame);
            final rDbfs = _calculateDecibels(rPcmData);

            if (rDbfs >= _silenceThresholdDbfs) {
              currentConsecutiveSpeechFrames++;
              if (currentConsecutiveSpeechFrames > maxConsecutiveSpeechFrames) {
                maxConsecutiveSpeechFrames = currentConsecutiveSpeechFrames;
              }
            } else {
              currentConsecutiveSpeechFrames = 0;
            }
          }
          tempDecoder.destroy();

          final longestSpeechRunMs = maxConsecutiveSpeechFrames * frameDurationMs;

          // If there was at least ONE consecutive run of speech that met the minimum threshold, keep the whole file
          if (longestSpeechRunMs >= _minSpeechMs) {
            final filePath = await _saveRecording(recordingFrames, _recordingStartTime!);
            savedFiles.add(filePath);
          }
        }

        // Start new recording, keeping a small pre-speech buffer of silence (e.g. 1 second)
        const preSpeechFramesCount = preSpeechBufferMs ~/ frameDurationMs;
        final bufferToKeep = min(preSpeechFramesCount, _consecutiveSilenceFrames);

        _currentRecordingFrames = _currentRecordingFrames.sublist(_currentRecordingFrames.length - bufferToKeep);
        _consecutiveSilenceFrames = bufferToKeep;

        // Calculate the exact time the new buffer starts.
        // It starts exactly (framesToKeep * 20ms) after the original _recordingStartTime,
        // minus the pre-speech buffer we just kept.
        if (_recordingStartTime != null) {
          final int elapsedMs = framesToKeep * frameDurationMs;
          _recordingStartTime = _recordingStartTime!.add(Duration(milliseconds: elapsedMs));
        } else {
          _recordingStartTime = chunkStartTime;
        }
      }
    }

    return savedFiles;
  }

  /// Call this when the connection/sync is completely done to flush the final recording
  Future<String?> flushRemaining() async {
    if (_currentRecordingFrames.isEmpty) return null;

    final framesToKeep = max(0, _currentRecordingFrames.length - _consecutiveSilenceFrames);

    if (framesToKeep > 0) {
      final recordingFrames = _currentRecordingFrames.sublist(0, framesToKeep);

      int maxConsecutiveSpeechFrames = 0;
      int currentConsecutiveSpeechFrames = 0;

      final tempDecoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
      for (var rFrame in recordingFrames) {
        final rPcmData = tempDecoder.decode(input: rFrame);
        final rDbfs = _calculateDecibels(rPcmData);

        if (rDbfs >= _silenceThresholdDbfs) {
          currentConsecutiveSpeechFrames++;
          if (currentConsecutiveSpeechFrames > maxConsecutiveSpeechFrames) {
            maxConsecutiveSpeechFrames = currentConsecutiveSpeechFrames;
          }
        } else {
          currentConsecutiveSpeechFrames = 0;
        }
      }
      tempDecoder.destroy();

      final longestSpeechRunMs = maxConsecutiveSpeechFrames * frameDurationMs;

      // If there was at least ONE consecutive run of speech that met the minimum threshold, keep the whole file
      if (longestSpeechRunMs >= _minSpeechMs) {
        final filePath = await _saveRecording(recordingFrames, _recordingStartTime ?? DateTime.now());
        _currentRecordingFrames.clear();
        _consecutiveSilenceFrames = 0;
        return filePath;
      }
    }

    _currentRecordingFrames.clear();
    _consecutiveSilenceFrames = 0;
    return null;
  }

  Future<String> _saveRecording(List<Uint8List> frames, DateTime startTime) async {
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = startTime.millisecondsSinceEpoch;

    // Create date-specific recordings folder
    final dateString = '${startTime.year}-${startTime.month.toString().padLeft(2, '0')}-${startTime.day.toString().padLeft(2, '0')}';
    final dateFolder = Directory('${directory.path}/recordings/$dateString');
    if (!await dateFolder.exists()) {
      await dateFolder.create(recursive: true);
    }

    final wavPath = '${dateFolder.path}/recording_$timestamp.wav';
    final aacPath = '${dateFolder.path}/recording_$timestamp.aac';

    // We decode the opus frames to save as WAV
    final pcmData = <int>[];

    final tempDecoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
    for (var frame in frames) {
      try {
        final decoded = tempDecoder.decode(input: frame);
        pcmData.addAll(decoded);
      } catch (e) {
        // Skip bad frames
      }
    }
    tempDecoder.destroy();

    await _writeWavFile(wavPath, Int16List.fromList(pcmData));

    // Convert WAV to AAC using FFmpegKit
    final session = await FFmpegKit.execute('-i $wavPath -c:a aac -b:a 64k $aacPath');
    final returnCode = await session.getReturnCode();

    // Delete the intermediate WAV file to save space
    final wavFile = File(wavPath);
    if (await wavFile.exists()) {
      await wavFile.delete();
    }

    if (ReturnCode.isSuccess(returnCode)) {
      return aacPath;
    } else {
      return aacPath;
    }
  }
  Future<void> _writeWavFile(String path, Int16List pcmData) async {
    final file = File(path);
    const channels = 1;
    const sampleRate = 16000;
    const byteRate = sampleRate * channels * 2;

    final header = ByteData(44);

    // "RIFF"
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);

    // File size
    header.setUint32(4, 36 + pcmData.lengthInBytes, Endian.little);

    // "WAVE"
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);

    // "fmt "
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);

    // fmt chunk size
    header.setUint32(16, 16, Endian.little);

    // format tag (PCM)
    header.setUint16(20, 1, Endian.little);

    // channels
    header.setUint16(22, channels, Endian.little);

    // sample rate
    header.setUint32(24, sampleRate, Endian.little);

    // byte rate
    header.setUint32(28, byteRate, Endian.little);

    // block align
    header.setUint16(32, channels * 2, Endian.little);

    // bits per sample
    header.setUint16(34, 16, Endian.little);

    // "data"
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);

    // data chunk size
    header.setUint32(40, pcmData.lengthInBytes, Endian.little);

    final bytes = BytesBuilder();
    bytes.add(header.buffer.asUint8List());
    bytes.add(pcmData.buffer.asUint8List());

    await file.writeAsBytes(bytes.toBytes());
  }
}
