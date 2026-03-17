import 'dart:io';
import 'package:flutter/services.dart';

/// Platform channel contract for slicing an audio file at given timestamps.
///
/// Native implementations:
///   iOS    — ios/Runner/AudioSlicerPlugin.swift  (AVAssetExportSession + CMTimeRange)
///   Android — android/app/src/.../AudioSlicerPlugin.kt (MediaExtractor + MediaMuxer)
///
/// Each generated slice file is named `recording_<epochMs>.m4a` and a `.meta`
/// waveform sidecar is generated alongside it (same format as
/// OfflineAudioProcessor._saveRecording).
class AudioSlicer {
  static const MethodChannel _channel = MethodChannel('com.omi.offline/audioSlicer');

  /// Slices [inputPath] at each timestamp in [splitTimestampsMs] (milliseconds
  /// from the start of the file) and writes the resulting segments to [outputDir].
  ///
  /// Returns the absolute paths of the generated slice files, in order.
  ///
  /// [startEpochMs] is the UTC epoch millisecond timestamp of the first sample
  /// in [inputPath].  It is used to derive the `recording_<epochMs>` filename
  /// for each slice.
  static Future<List<String>> slice({
    required String inputPath,
    required List<int> splitTimestampsMs,
    required String outputDir,
    required int startEpochMs,
  }) async {
    if (splitTimestampsMs.isEmpty) {
      // No splits — the whole file is one segment; just return the input path
      return [inputPath];
    }

    try {
      final result = await _channel.invokeMethod<List<dynamic>>('slice', {
        'inputPath': inputPath,
        'splitTimestampsMs': splitTimestampsMs,
        'outputDir': outputDir,
        'startEpochMs': startEpochMs,
      });
      return (result ?? []).cast<String>();
    } on PlatformException catch (e) {
      throw Exception('AudioSlicer.slice failed: ${e.message}');
    }
  }

  /// Convenience: given a list of [splitPoints] (Durations from the recording
  /// start) and the recording's UTC start time, compute the millisecond
  /// timestamps for the platform channel call.
  static List<int> durationsToMs(List<Duration> splitPoints) {
    return splitPoints.map((d) => d.inMilliseconds).toList();
  }
}

// ---------------------------------------------------------------------------
// TODO: Native implementations
//
// iOS — ios/Runner/AudioSlicerPlugin.swift
//   Register with registrar.addMethodCallDelegate(AudioSlicerPlugin(), channel: channel)
//   For each interval between consecutive split timestamps (including 0 → first
//   split and last split → end):
//     let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
//     let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
//     exportSession.timeRange = CMTimeRangeMake(start: CMTime(seconds: startSec, …),
//                                               duration: CMTime(seconds: durationSec, …))
//     exportSession.outputURL = URL(fileURLWithPath: outputPath)
//     exportSession.outputFileType = .m4a
//     await exportSession.export()
//   After slicing, generate a .meta waveform sidecar for each output file.
//
// Android — android/app/src/main/kotlin/…/AudioSlicerPlugin.kt
//   For each interval:
//     val extractor = MediaExtractor()
//     extractor.setDataSource(inputPath)
//     val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
//     Copy samples in [startUs, endUs) from extractor → muxer.
//   After slicing, generate a .meta waveform sidecar.
// ---------------------------------------------------------------------------
