import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
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
  final String? _outputDir;

  // Cached settings for the duration of this processor instance (batch)
  final double _silenceThresholdDbfs;
  final int _silenceDurationToSplitMs;
  final int _minSpeechMs;
  final int _preSpeechBufferMs;
  final int _gapThresholdMs;

  OfflineAudioProcessor({String? outputDir})
      : _decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels),
        _outputDir = outputDir,
        _silenceThresholdDbfs = SharedPreferencesUtil().offlineSilenceThreshold,
        _silenceDurationToSplitMs = SharedPreferencesUtil().offlineSplitSeconds * 1000,
        _minSpeechMs = SharedPreferencesUtil().offlineMinSpeechSeconds * 1000,
        _preSpeechBufferMs = SharedPreferencesUtil().offlinePreSpeechSeconds * 1000,
        _gapThresholdMs = SharedPreferencesUtil().offlineGapSeconds * 1000;

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
  Future<List<String>> processFrames(List<Uint8List> opusFrames, DateTime fallbackStartTime, {int? sessionId}) async {
    List<String> savedFiles = [];

    // 1. Scan for the first 255 metadata packet to get exact timing
    DateTime chunkStartTime = fallbackStartTime;
    
    if (sessionId != null) {
       for (var frame in opusFrames) {
          if (frame.length == 255) {
             try {
                // The frame itself doesn't have the size byte if it's already extracted, 
                // but let's assume the frame passed in is exactly 255 bytes long.
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
        // State is cleared by flushRemaining, so the new chunk will start fresh
      }
    }

    if (_currentRecordingFrames.isEmpty) {
      _recordingStartTime = chunkStartTime;
    }

    for (var frame in opusFrames) {
      // Skip the metadata packets during actual audio processing
      if (frame.length == 255) continue;

      Int16List pcmData;
      try {
        pcmData = _decoder.decode(input: frame);
      } catch (e) {
        // Skip corrupt or invalid Opus frames to prevent crashing the batch
        continue;
      }
      
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
            try {
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
            } catch (e) {
              // skip corrupt
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
        final preSpeechFramesCount = _preSpeechBufferMs ~/ frameDurationMs;
        final bufferToKeep = min(preSpeechFramesCount, _consecutiveSilenceFrames);

        // Calculate the exact time the new buffer starts.
        // It starts exactly (framesToKeep * 20ms) after the original _recordingStartTime,
        // minus the pre-speech buffer we just kept.
        if (_recordingStartTime != null) {
          final int elapsedMs = (framesToKeep - bufferToKeep) * frameDurationMs;
          _recordingStartTime = _recordingStartTime!.add(Duration(milliseconds: elapsedMs));
        } else {
          _recordingStartTime = chunkStartTime;
        }

        _currentRecordingFrames = _currentRecordingFrames.sublist(_currentRecordingFrames.length - bufferToKeep);
        _consecutiveSilenceFrames = bufferToKeep;
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
        try {
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
        } catch (e) {
          // skip
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

    // Determine target folder
    String dateFolderPath;
    if (_outputDir != null) {
      dateFolderPath = _outputDir!;
    } else {
      // Create date-specific recordings folder
      final dateString =
          '${startTime.year}-${startTime.month.toString().padLeft(2, '0')}-${startTime.day.toString().padLeft(2, '0')}';
      dateFolderPath = '${directory.path}/recordings/$dateString';
    }

    final dateFolder = Directory(dateFolderPath);
    if (!await dateFolder.exists()) {
      await dateFolder.create(recursive: true);
    }

    final wavPath = '${dateFolder.path}/recording_$timestamp.wav';
    final aacPath = '${dateFolder.path}/recording_$timestamp.aac';

    final wavFile = File(wavPath);
    final IOSink sink = wavFile.openWrite();

    // 1. Write Initial WAV Header (44 bytes)
    // We can calculate the total size because we know the frame count
    // 16000Hz * 20ms = 320 samples per frame. 2 bytes per sample.
    const int samplesPerFrame = (sampleRate * frameDurationMs) ~/ 1000;
    final int totalPcmBytes = frames.length * samplesPerFrame * 2;
    
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

    // 2. Decode and Stream PCM data
    final tempDecoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
    for (var frame in frames) {
      try {
        final decoded = tempDecoder.decode(input: frame);
        sink.add(decoded.buffer.asUint8List());
      } catch (e) {
        // Skip bad frames
      }
    }
    tempDecoder.destroy();
    await sink.close();

    // 3. Convert WAV to AAC using FFmpegKit
    final session = await FFmpegKit.execute('-i $wavPath -c:a aac -b:a 64k $aacPath');
    final returnCode = await session.getReturnCode();

    // 4. Delete the intermediate WAV file
    if (await wavFile.exists()) {
      await wavFile.delete();
    }

    return aacPath;
  }
}
