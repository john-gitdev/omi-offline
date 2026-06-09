import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/time_utils.dart';

/// Parsed metadata for a single processed recording (M4A or WAV).
class Conversation {
  final File file;
  final DateTime startTime;
  final Duration duration;
  final String? uploadKey;
  final int? sessionId;
  final int? startUptime;
  // True when the audio was uploaded to an integration and the local file was
  // deleted. Only the .meta sidecar remains; the conversation cannot be played.
  final bool passthrough;
  final bool forceSynced;
  // True iff VAD ended this recording at the max-duration cap (vadMaxConversationMinutes)
  // rather than because of detected silence. pruneConsumedBins uses this to decide whether
  // raw bin files extending past rec_end may be safely deleted (silence-ended) or must be
  // preserved (cap-ended, since bin tail may hold the post-cap continuation).
  //
  // Defaults to true so that old recordings whose .meta predates the flag are treated
  // conservatively (no aggressive pruning past rec_end).
  final bool capEnded;
  final bool? isSilero;
  final List<String> relativeBins;

  const Conversation({
    required this.file,
    required this.startTime,
    required this.duration,
    this.uploadKey,
    this.sessionId,
    this.startUptime,
    this.passthrough = false,
    this.forceSynced = false,
    this.capEnded = true,
    this.isSilero,
    this.relativeBins = const [],
  });

  DateTime get endTime => startTime.add(duration);

  /// True when this recording was saved with an unknown timestamp (device had no RTC sync).
  bool get isUnknown {
    final name = file.path.split('/').last;
    return name.startsWith('unknown_') || name.startsWith('session_');
  }

  int get fileSizeBytes {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Parses start time from the filename (`recording_<millis>.m4a` or `.wav`) and
  /// reads duration from the `.meta` sidecar if present, otherwise falls back to
  /// WAV file size calculation.
  static Conversation fromFile(File file) {
    final name = file.path.split('/').last;
    final nameNoExt = name.split('.').first;
    final parts = nameNoExt.split('_');

    // Format: recording_<ts> or recording_<ts>_draft
    int? millis;
    if (parts.length >= 2) {
      // Find the first part that is a long numeric timestamp (e.g. seconds or millis)
      for (final p in parts) {
        final val = int.tryParse(p);
        if (val != null && val > 0) {
          millis = val;
          break;
        }
      }
    }

    DateTime startTime;
    if (millis != null && millis > 0) {
      startTime = DateTime.fromMillisecondsSinceEpoch(millis);
    } else {
      try {
        startTime = file.lastModifiedSync();
      } catch (_) {
        startTime = DateTime.now();
      }
    }

    // Try .meta sidecar for authoritative duration
    final basePath = file.path.contains('.') ? file.path.substring(0, file.path.lastIndexOf('.')) : file.path;
    final metaFile = File('$basePath.meta');
    if (metaFile.existsSync()) {
      try {
        final metaBytes = metaFile.readAsBytesSync();
        if (metaBytes.length >= 8) {
          final bd = ByteData.sublistView(metaBytes);
          final durationMs = bd.getUint32(4, Endian.little);

          int? sessionId;
          int? startUptime;
          if (metaBytes.length >= 416) {
            sessionId = bd.getUint32(408, Endian.little);
            startUptime = bd.getUint32(412, Endian.little);
          }

          String? uploadKey;
          bool passthrough = false;
          bool forceSynced = false;
          // Default true so recordings whose .meta predates the capEnded byte are treated
          // conservatively by pruneConsumedBins (no aggressive prune past rec_end).
          bool capEnded = true;
          bool? isSilero;
          List<String> relativeBins = const [];
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(metaBytes, 417, 417 + keyLen);
              } catch (_) {
                uploadKey = null;
              }
              final flagOffset = 417 + keyLen;
              if (metaBytes.length > flagOffset) {
                passthrough = (metaBytes[flagOffset] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 1) {
                forceSynced = (metaBytes[flagOffset + 1] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 2) {
                capEnded = (metaBytes[flagOffset + 2] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 3) {
                isSilero = (metaBytes[flagOffset + 3] & 0x01) != 0;
              }

              final binsOffset = flagOffset + (isSilero != null ? 4 : 3);
              if (metaBytes.length >= binsOffset + 4) {
                final binsLen = bd.getUint32(binsOffset, Endian.little);
                if (metaBytes.length >= binsOffset + 4 + binsLen) {
                  try {
                    final binsJson = utf8.decode(metaBytes.sublist(binsOffset + 4, binsOffset + 4 + binsLen));
                    relativeBins = (jsonDecode(binsJson) as List)
                        .cast<String>()
                        .map((p) => p.split('/raw_segments/').last)
                        .toList();
                  } catch (_) {}
                }
              }
            }
          }
          // Fall back to filename (without extension) as upload key for recordings
          // processed before the upload key was written to the .meta sidecar.
          final effectiveKey = uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
            file: file,
            startTime: startTime,
            duration: Duration(milliseconds: durationMs),
            uploadKey: effectiveKey,
            sessionId: sessionId,
            startUptime: startUptime,
            passthrough: passthrough,
            forceSynced: forceSynced,
            capEnded: capEnded,
            isSilero: isSilero,
            relativeBins: relativeBins,
          );
        }
      } catch (_) {
        // Fall through to size-based estimate
      }
    }

    // Size-based duration estimate
    // For WAV: 16kHz 16-bit mono = 32000 bytes/sec
    // For M4A/OGG: We use ~32kbps (4000 bytes/sec)
    final path = file.path.toLowerCase();
    final isWav = path.endsWith('.wav');
    final isM4a = path.endsWith('.m4a');
    final isOgg = path.endsWith('.ogg');

    int fileSize = 0;
    try {
      fileSize = file.lengthSync();
    } catch (_) {}

    int durationMs = 0;
    if (isWav && fileSize > 44) {
      durationMs = ((fileSize - 44) / 32000.0 * 1000).round();
    } else if ((isM4a || isOgg) && fileSize > 0) {
      // Rough estimate for compressed audio to allow marker resolution
      durationMs = (fileSize / 4000.0 * 1000).round();
    }

    final fallbackKey = file.path.split('/').last.split('.').first;
    return Conversation(
      file: file,
      startTime: startTime,
      duration: Duration(milliseconds: durationMs),
      uploadKey: fallbackKey,
    );
  }

  /// Builds a passthrough Conversation from a standalone .meta file (no audio file).
  /// Returns null if the meta file does not have the passthrough flag set or cannot be parsed.
  static Future<Conversation?> fromMetaOnly(File metaFile) async {
    try {
      final metaBytes = await metaFile.readAsBytes();
      if (metaBytes.length < 8) return null;

      final bd = ByteData.sublistView(metaBytes);
      final durationMs = bd.getUint32(4, Endian.little);
      if (durationMs == 0) return null;

      int? sessionId;
      int? startUptime;
      if (metaBytes.length >= 416) {
        sessionId = bd.getUint32(408, Endian.little);
        startUptime = bd.getUint32(412, Endian.little);
      }

      String? uploadKey;
      bool passthrough = false;
      bool forceSynced = false;
      bool capEnded = true; // see Conversation.capEnded — default conservative
      bool? isSilero;
      if (metaBytes.length >= 417) {
        final keyLen = metaBytes[416];
        if (417 + keyLen <= metaBytes.length) {
          try {
            uploadKey = String.fromCharCodes(metaBytes, 417, 417 + keyLen);
          } catch (_) {}
          final flagOffset = 417 + keyLen;
          if (metaBytes.length > flagOffset) {
            passthrough = (metaBytes[flagOffset] & 0x01) != 0;
          }
          if (metaBytes.length > flagOffset + 1) {
            forceSynced = (metaBytes[flagOffset + 1] & 0x01) != 0;
          }
          if (metaBytes.length > flagOffset + 2) {
            capEnded = (metaBytes[flagOffset + 2] & 0x01) != 0;
          }
          if (metaBytes.length > flagOffset + 3) {
            isSilero = (metaBytes[flagOffset + 3] & 0x01) != 0;
          }
        }
      }

      if (!passthrough) return null;

      // Reconstruct the virtual audio path from the meta filename.
      final metaName = metaFile.path.split('/').last;
      final baseName = metaName.contains('.') ? metaName.substring(0, metaName.lastIndexOf('.')) : metaName;
      final virtualAudioFile = File('${metaFile.parent.path}/$baseName.m4a');

      final millisStr = baseName.contains('_') ? baseName.split('_').last : null;
      final millis = millisStr != null ? int.tryParse(millisStr) : null;
      final startTime =
          millis != null && millis > 0 ? DateTime.fromMillisecondsSinceEpoch(millis) : await metaFile.lastModified();

      return Conversation(
        file: virtualAudioFile,
        startTime: startTime,
        duration: Duration(milliseconds: durationMs),
        uploadKey: uploadKey,
        sessionId: sessionId,
        startUptime: startUptime,
        passthrough: true,
        forceSynced: forceSynced,
        capEnded: capEnded,
        isSilero: isSilero,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parses start time from the filename (`recording_<millis>.m4a` or `.wav`) and
  /// reads duration from the `.meta` sidecar if present, otherwise falls back to
  /// WAV file size calculation. Asynchronous version.
  static Future<Conversation> fromFileAsync(File file) async {
    final name = file.path.split('/').last;
    final millisStr = name.contains('_') ? name.split('_').last.split('.').first : null;
    final millis = millisStr != null ? int.tryParse(millisStr) : null;
    DateTime startTime;
    if (millis != null && millis > 0) {
      startTime = DateTime.fromMillisecondsSinceEpoch(millis);
    } else {
      try {
        startTime = await file.lastModified();
      } catch (_) {
        startTime = DateTime.now();
      }
    }

    // Try .meta sidecar for authoritative duration
    final basePath = file.path.contains('.') ? file.path.substring(0, file.path.lastIndexOf('.')) : file.path;
    final metaFile = File('$basePath.meta');
    if (await metaFile.exists()) {
      try {
        final metaBytes = await metaFile.readAsBytes();
        if (metaBytes.length >= 8) {
          final bd = ByteData.sublistView(metaBytes);
          final durationMs = bd.getUint32(4, Endian.little);

          int? sessionId;
          int? startUptime;
          if (metaBytes.length >= 416) {
            sessionId = bd.getUint32(408, Endian.little);
            startUptime = bd.getUint32(412, Endian.little);
          }

          String? uploadKey;
          bool passthrough = false;
          bool forceSynced = false;
          // Default true so recordings whose .meta predates the capEnded byte are treated
          // conservatively by pruneConsumedBins (no aggressive prune past rec_end).
          bool capEnded = true;
          bool? isSilero;
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(metaBytes, 417, 417 + keyLen);
              } catch (_) {
                uploadKey = null;
              }
              final flagOffset = 417 + keyLen;
              if (metaBytes.length > flagOffset) {
                passthrough = (metaBytes[flagOffset] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 1) {
                forceSynced = (metaBytes[flagOffset + 1] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 2) {
                capEnded = (metaBytes[flagOffset + 2] & 0x01) != 0;
              }
              if (metaBytes.length > flagOffset + 3) {
                isSilero = (metaBytes[flagOffset + 3] & 0x01) != 0;
              }
            }
          }
          // Fall back to filename (without extension) as upload key for recordings
          // processed before the upload key was written to the .meta sidecar.
          final effectiveKey = uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
            file: file,
            startTime: startTime,
            duration: Duration(milliseconds: durationMs),
            uploadKey: effectiveKey,
            sessionId: sessionId,
            startUptime: startUptime,
            passthrough: passthrough,
            forceSynced: forceSynced,
            capEnded: capEnded,
            isSilero: isSilero,
          );
        }
      } catch (_) {
        // Fall through to size-based estimate
      }
    }

    // Size-based duration estimate — only valid for WAV files.
    // For M4A/OGG/other formats without a .meta sidecar, return 0 to avoid a wildly wrong duration.
    final isWav = file.path.endsWith('.wav');
    int fileSize = 0;
    try {
      fileSize = await file.length();
    } catch (_) {}
    final pcmBytes = isWav && fileSize > 44 ? fileSize - 44 : 0;
    final durationMs = (pcmBytes / 32000.0 * 1000).round();
    final fallbackKey = file.path.split('/').last.split('.').first;
    return Conversation(
      file: file,
      startTime: startTime,
      duration: Duration(milliseconds: durationMs),
      uploadKey: fallbackKey,
    );
  }

  String get timeRangeLabel {
    // Show inclusive end: subtract 1s so a 30-min segment displays as HH:MM–HH:29, not HH:MM–HH:30.
    // We use the actual end time to determine the label, not a duration added to a truncated start.
    final end = startTime.add(duration);
    final inclusiveEnd = duration.inSeconds > 0 ? end.subtract(const Duration(seconds: 1)) : end;
    return '${fmtHourMin(startTime)} – ${fmtHourMin(inclusiveEnd)}';
  }

  String get durationLabel {
    final totalSecs = (duration.inMilliseconds / 1000).round();
    final mins = totalSecs ~/ 60;
    final secs = totalSecs % 60;
    return mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
  }

  String get sizeLabel {
    if (passthrough) return '';
    final bytes = fileSizeBytes;
    String size;
    if (bytes >= 1024 * 1024) {
      size = '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      size = '${(bytes / 1024).toStringAsFixed(0)} KB';
    } else {
      size = '$bytes B';
    }
    if (isSilero == true) return '$size  ·  VAD';
    if (isSilero == false) return '$size  ·  AAD';
    return size;
  }
}

class Batch {
  final String dateString;
  final DateTime date;
  final List<File> rawSegments;
  final List<Conversation> draftRecordings;
  final List<Conversation> finalizedRecordings;
  final List<DateTime> markerTimestamps;
  final List<DiscardRecord> discards;

  Batch({
    required this.dateString,
    required this.date,
    required this.rawSegments,
    required this.draftRecordings,
    required this.finalizedRecordings,
    this.markerTimestamps = const [],
    this.discards = const [],
  });
}

/// One stretch of audio that VAD silently dropped, surfaced in the recordings
/// list as a greyed-out "ghost" row so the user can see what was lost and try
/// to recover it. Source of truth is `recordings/<date>/discards.jsonl`.
class DiscardRecord {
  final DateTime startTime;
  final DateTime endTime;
  final String reason;
  final double maxVoiceProb;
  final List<String> relativeBins;
  final File sourceJsonl;

  const DiscardRecord({
    required this.startTime,
    required this.endTime,
    required this.reason,
    required this.maxVoiceProb,
    required this.relativeBins,
    required this.sourceJsonl,
  });

  Duration get duration => endTime.difference(startTime);
  DateTime get expiresAt => endTime.add(RecordingsManager.discardRetentionWindow);
  bool get isNoise => reason.contains('noise');

  /// Stable identity for UI keys/comparisons: source file + startMs + bins hash.
  String get id => '${sourceJsonl.path}:${startTime.millisecondsSinceEpoch}:${relativeBins.join(",")}';
}

/// A marker conversation: a device button tap and the segment(s) it was tagged to.
/// [segments] is empty when the backing m4a has not yet been produced (pending).
class MarkerConversation {
  final DateTime markerTime;
  final File? segment; // null = pending (no m4a produced yet)
  final int markerOffsetMs; // ms from segment start to the button press
  final int cropStartMs; // user-adjustable crop start, default 0
  final int cropEndMs; // user-adjustable crop end, default = segment duration
  final File edlFile;
  final bool userSaved;

  const MarkerConversation({
    required this.markerTime,
    required this.edlFile,
    this.segment,
    this.markerOffsetMs = 0,
    this.cropStartMs = 0,
    this.cropEndMs = 0,
    this.userSaved = false,
  });

  bool get isPending => segment == null;
  String get markerTimeLabel => fmtHourMin(markerTime);

  String get timeRangeLabel {
    if (segment == null) return '';
    return Conversation.fromFile(segment!).timeRangeLabel;
  }
}

// =============================================================================
// Background isolate for VAD/audio processing
// =============================================================================

/// Parameters sent to the background processing isolate. All fields must be
/// sendable across isolate boundaries (primitives, Uint8List, SendPort, etc.).
class _IsolateParams {
  final SendPort sendPort;
  final RootIsolateToken rootIsolateToken;
  // Filesystem path to the Silero VAD ONNX model. Pre-copied from rootBundle
  // on the main isolate because flutter_onnxruntime's createSessionFromAsset
  // touches ServicesBinding.instance, which is unavailable in a background
  // isolate (only BackgroundIsolateBinaryMessenger is initialised there).
  final String? sileroModelPath;
  final ProcessingSettings settings;
  final String tempProcessingPath;
  final List<String> segmentPaths;
  final List<int> segmentFileSizes; // used for accurate processing ETA
  final List<int> segmentStartTimesMs; // milliseconds since epoch
  final List<int> segmentStartUptimesMs; // milliseconds since epoch (raw device uptime)
  final List<int?> segmentSessionIds;
  final List<bool> segmentDerivedFlags;
  final bool backgroundMode;
  // Forwarded so DebugLogManager can write to the log file from this isolate;
  // SharedPreferences isn't initialised here so it can't read the pref itself.
  final bool devLogsEnabled;
  // Checkpoint fields — null/empty means fresh run (no prior state to restore).
  final Map<String, dynamic>? checkpointState;
  final int checkpointResumeIndex;
  final String? checkpointPath;
  final List<String> checkpointPendingDeletes;

  const _IsolateParams({
    required this.sendPort,
    required this.rootIsolateToken,
    required this.sileroModelPath,
    required this.settings,
    required this.tempProcessingPath,
    required this.segmentPaths,
    required this.segmentFileSizes,
    required this.segmentStartTimesMs,
    required this.segmentStartUptimesMs,
    required this.segmentSessionIds,
    required this.segmentDerivedFlags,
    required this.backgroundMode,
    required this.devLogsEnabled,
    this.checkpointState,
    this.checkpointResumeIndex = 0,
    this.checkpointPath,
    this.checkpointPendingDeletes = const [],
  });
}

/// Background isolate entry point for VAD + Opus decode + AAC encode.
/// Runs entirely off the Android main/platform thread, eliminating the
/// ForegroundServiceDidNotStartInTimeException caused by ONNX inference
/// blocking the platform thread.
Future<void> _processingIsolateEntry(_IsolateParams params) async {
  // Allow platform channel calls (AacEncoder MethodChannel, opus_flutter.load(),
  // flutter_onnxruntime asset loader) from this isolate.
  BackgroundIsolateBinaryMessenger.ensureInitialized(params.rootIsolateToken);

  // SharedPreferences isn't initialised in this isolate, so DebugLogManager
  // would otherwise treat logging as disabled and drop every line. Forward the
  // real pref from the main isolate so VAD/processing logs reach the file.
  DebugLogManager.enabledOverride = params.devLogsEnabled;

  // Send back a control port so the main isolate can forward cancel requests.
  final controlPort = ReceivePort();
  params.sendPort.send({'type': 'control_port', 'port': controlPort.sendPort});

  bool cancelled = false;
  controlPort.listen((msg) {
    if (msg == 'cancel') cancelled = true;
  });

  // Initialise Opus (each isolate has its own FFI state; must call initOpus before any decoder).
  if (Platform.isIOS || Platform.isAndroid) {
    try {
      initOpus(await opus_flutter.load());
    } catch (e) {
      // If Opus fails to load, decoder creation below will also fail and we fall back to null.
    }
  }

  OrtSession? session;
  if (params.settings.vadEnabled && params.sileroModelPath != null) {
    try {
      session = await OnnxRuntime()
          .createSession(params.sileroModelPath!, options: await VadAudioProcessor.buildSileroSessionOptions());
      Logger.debug(
          'RecordingsManager isolate: Silero session — inputs=${session.inputNames} outputs=${session.outputNames}');
    } catch (e) {
      Logger.error('RecordingsManager isolate: Silero session load failed ($e) — AAD mode active.');
    }
  }

  SimpleOpusDecoder? decoder;
  if (Platform.isIOS || Platform.isAndroid) {
    try {
      decoder = SimpleOpusDecoder(
        sampleRate: VadAudioProcessor.sampleRate,
        channels: VadAudioProcessor.channels,
      );
    } catch (e) {
      // Opus failed to load — decoder stays null, WAV fallback will be used.
    }
  }

  // Initialise the native VAD batch runner (Android-only). Uses the same
  // materialized model file that the ORT session was loaded from. On non-Android
  // platforms, init is a no-op and available stays false.
  final batchRunner = VadBatchRunnerChannel(isolateSendPort: params.sendPort);
  if (params.settings.vadEnabled && params.sileroModelPath != null && session != null) {
    await batchRunner.init(params.sileroModelPath!);
  }

  // Liveness: VadAudioProcessor bumps this counter from inside its decode/save
  // loops, so it advances even within a single long segment or save. The timer
  // below forwards a 'heartbeat' to the main isolate only when the count
  // actually moved — a truly wedged loop sends nothing, so the stall watchdog
  // still catches a genuine hang.
  int livenessTick = 0;
  final processor = VadAudioProcessor.fromSettings(
    settings: params.settings,
    outputDir: params.tempProcessingPath,
    session: session,
    decoder: decoder,
    onLiveness: () => livenessTick++,
    // Threaded into the per-frame decode loop so cooperative cancel takes
    // effect within milliseconds instead of waiting for the current (possibly
    // >12 s) segment to finish — otherwise the controller's stoppingStallTimeout
    // fires and force-kills the isolate, which crashes the app from inside an
    // ONNX/Opus FFI call.
    isCancelled: () => cancelled,
    batchRunner: batchRunner,
  );

  int lastSeenLivenessTick = -1;
  final heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
    if (livenessTick != lastSeenLivenessTick) {
      lastSeenLivenessTick = livenessTick;
      params.sendPort.send({'type': 'heartbeat'});
    }
  });

  final runStopwatch = Stopwatch()..start();
  Logger.debug(
      'RecordingsManager isolate: processing run started — ${params.segmentPaths.length} segment(s), backgroundMode=${params.backgroundMode}');

  try {
    if (params.checkpointState != null) {
      await processor.restoreState(params.checkpointState!);
      Logger.debug(
          'RecordingsManager isolate: restored checkpoint state, resuming from segment ${params.checkpointResumeIndex}/${params.segmentPaths.length}.');
    }
    // Re-send pending deletes from the prior run — delete handler checks existence first so this is idempotent.
    if (params.checkpointPendingDeletes.isNotEmpty) {
      params.sendPort.send({'type': 'delete_segments', 'paths': params.checkpointPendingDeletes});
    }
    final checkpointPendingDeletes = List<String>.from(params.checkpointPendingDeletes);

    // Checkpoint serialization cost scales with the in-flight conversation's ref
    // count (uncapped by default), so writing every segment can rival decode time
    // on long sessions. Throttle to one write per interval — a cancel between
    // writes just reprocesses the few segments since the last checkpoint, which
    // is cheap. Initialised so the first eligible segment always writes.
    const checkpointMinIntervalMs = 5000;
    int lastCheckpointMs = -checkpointMinIntervalMs;
    // Deletes are held here until a checkpoint that excludes them from the live
    // ref-state is durably written (see below) — so a throttled-away checkpoint
    // can never leave the resume state pointing at a file already gone from disk.
    final pendingDeleteBatch = <String>[];

    for (int i = params.checkpointResumeIndex; i < params.segmentPaths.length; i++) {
      if (cancelled) {
        break;
      }

      final file = File(params.segmentPaths[i]);
      final startTime = DateTime.fromMillisecondsSinceEpoch(
        params.segmentStartTimesMs[i],
      );
      final startUptimeMs = params.segmentStartUptimesMs[i];
      final isDerived = params.segmentDerivedFlags[i];
      final sessionId = params.segmentSessionIds[i];

      final fileStopwatch = Stopwatch()..start();
      try {
        await processor.processSegmentFile(
          file,
          startTime,
          startUptimeMs: startUptimeMs,
          isDerivedTimestamp: isDerived,
          sessionId: sessionId,
        );
      } on VadProcessingCancelled {
        // Cooperative cancel landed inside the per-frame loop; bail out of the
        // segment-iteration loop. Don't emit progress for the half-finished
        // segment — the bin file is left on disk and reprocessed next run.
        cancelled = true;
        fileStopwatch.stop();
        Logger.debug('RecordingsManager isolate: segment ${i + 1}/${params.segmentPaths.length} '
            'cancelled mid-decode after ${fileStopwatch.elapsedMilliseconds}ms');
        break;
      }
      fileStopwatch.stop();
      Logger.debug('RecordingsManager isolate: segment ${i + 1}/${params.segmentPaths.length} '
          '(${params.segmentFileSizes[i]} B) processed in ${fileStopwatch.elapsedMilliseconds}ms');

      final edlData = processor.consumePendingEdlData();
      if (edlData.isNotEmpty) {
        params.sendPort.send({'type': 'marker_edl', 'items': edlData});
      }

      // Emit discard records before delete_segments so the main isolate can
      // register protected bin paths before considering them for deletion.
      final discards = processor.consumePendingDiscards();
      if (discards.isNotEmpty) {
        params.sendPort.send({'type': 'discard_records', 'items': discards});
      }

      // Ask the main isolate to move any completed recordings out of temp.
      params.sendPort.send({'type': 'move'});

      // Segment files that are fully processed and no longer referenced by any
      // buffer become safe to delete — but hold them; they're only sent once a
      // checkpoint excluding them is durably written, below.
      pendingDeleteBatch.addAll(processor.consumeSafeToDeletePaths());

      params.sendPort.send({
        'type': 'progress',
        'processed_bytes': params.segmentFileSizes[i],
        'index': i,
        'total': params.segmentPaths.length,
      });

      // Write a checkpoint when the throttle interval has elapsed, OR force one
      // whenever deletes are pending — the persisted ref-state must be committed
      // before any source bin leaves disk, otherwise a resume could reference a
      // deleted file. Deletes only occur at conversation boundaries, so the
      // common (no-delete) segments are genuinely throttled.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (params.checkpointPath != null &&
          (pendingDeleteBatch.isNotEmpty || nowMs - lastCheckpointMs >= checkpointMinIntervalMs)) {
        try {
          final cpState = await processor.serializeState();
          await File(params.checkpointPath!).writeAsString(jsonEncode({
            'lastIndex': i,
            'paths': params.segmentPaths,
            'state': cpState,
            'pendingDeletes': [...checkpointPendingDeletes, ...pendingDeleteBatch],
          }));
          lastCheckpointMs = nowMs;
          // Checkpoint is durable → safe to release the held deletes now.
          checkpointPendingDeletes.addAll(pendingDeleteBatch);
          if (pendingDeleteBatch.isNotEmpty) {
            params.sendPort.send({'type': 'delete_segments', 'paths': pendingDeleteBatch.toList()});
            pendingDeleteBatch.clear();
          }
        } catch (e) {
          // Write failed — keep the deletes held; the next checkpoint retries.
          Logger.error('RecordingsManager isolate: checkpoint write failed ($e)');
        }
      }

      if (params.backgroundMode) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    // Skip the draft flush on cancel — flushRemaining triggers another save
    // pass (potentially several seconds), and we already broke out specifically
    // to make the cancel responsive. Any unfinalised state stays in-memory only
    // and is rebuilt from disk on the next run.
    if (!cancelled) {
      // Always flush the remaining audio at the end of a run.
      // In both background and foreground modes, we save it as a '_draft' file
      // so it can be stitched with future syncs or finalized later.
      await processor.flushRemaining(isDraft: true);

      final flushEdlData = processor.consumePendingEdlData();
      if (flushEdlData.isNotEmpty) {
        params.sendPort.send({'type': 'marker_edl', 'items': flushEdlData});
      }

      final flushDiscards = processor.consumePendingDiscards();
      if (flushDiscards.isNotEmpty) {
        params.sendPort.send({'type': 'discard_records', 'items': flushDiscards});
      }

      params.sendPort.send({'type': 'move'});

      // On clean completion the checkpoint is deleted, so consistency between it
      // and on-disk files no longer matters — flush any deletes still held from
      // a failed checkpoint write alongside the run's final safe-to-delete set.
      final finalSafe = processor.consumeSafeToDeletePaths()..addAll(pendingDeleteBatch);
      pendingDeleteBatch.clear();
      if (finalSafe.isNotEmpty) {
        params.sendPort.send({
          'type': 'delete_segments',
          'paths': finalSafe.toList(),
        });
      }
    }

    runStopwatch.stop();
    final totalBytes = params.segmentFileSizes.fold<int>(0, (a, b) => a + b);
    Logger.debug('RecordingsManager isolate: processing run ${cancelled ? 'cancelled' : 'finished'} — '
        '${params.segmentPaths.length} segment(s), $totalBytes B in ${runStopwatch.elapsedMilliseconds}ms');

    params.sendPort.send({'type': 'done', 'cancelled': cancelled});
  } catch (e, st) {
    params.sendPort.send({'type': 'error', 'message': '$e\n$st'});
  } finally {
    heartbeatTimer.cancel();
    await batchRunner.dispose();
    await processor.destroy();
    controlPort.close();
  }
}

// =============================================================================

class RecordingsManager {
  static final RecordingsManager _instance = RecordingsManager._internal();
  factory RecordingsManager() => _instance;
  RecordingsManager._internal();

  static bool _isProcessingAny = false;
  static bool get isProcessingAny => _isProcessingAny;

  /// Global progress of the current processing task (0.0 to 1.0).
  static final ValueNotifier<double> processingProgress = ValueNotifier(0.0);

  /// Minutes of audio remaining to process. Updated by RecordingsController;
  /// -1 means unknown (calculating). Read by notification paths in both
  /// foreground and background to show consistent progress text.
  static double minutesRemaining = -1.0;

  /// Bumped on each isolate liveness heartbeat — emitted while the decode/save
  /// loops are actively advancing, so it ticks even within a single long
  /// segment or a multi-hour stitched-recording save where the per-segment
  /// [processingProgress] tick can't. The pipeline-stall watchdog anchors on
  /// this so a healthy-but-slow run isn't force-killed as a wedge.
  static final ValueNotifier<int> processingLiveness = ValueNotifier(0);

  /// True when a WAV file is being transcoded to M4A.
  static final ValueNotifier<bool> isTranscoding = ValueNotifier(false);

  /// True when the "Conversations ready" success notification is being displayed.
  /// Used to prevent the background idle-notification heartbeat from clobbering
  /// the success message before its 10s display window elapses.
  static final ValueNotifier<bool> isSuccessNotificationActive = ValueNotifier(false);

  static bool _cancelRequested = false;
  static SendPort? _activeIsolateControlPort;
  static Isolate? _activeIsolate;

  /// Cooperative cancel: ask the decode isolate to stop at the next checkpoint.
  /// The isolate's control port listener flips its local `cancelled` flag,
  /// which is polled from inside the per-frame decode loop in
  /// [VadAudioProcessor] — so cancel takes effect within milliseconds even
  /// mid-segment. Falls back to [forceResetProcessing] only for a genuine
  /// wedge (native deadlock that ignores the flag check too).
  static void cancelProcessing() {
    _cancelRequested = true;
    _activeIsolateControlPort?.send('cancel');
  }

  /// Last-resort recovery for a wedged processing run. A hung isolate never
  /// reads the cooperative 'cancel', so `processAll`'s `finally` never runs and
  /// [_isProcessingAny] stays stuck true — stranding the UI in `processing`.
  /// Killing the isolate fires its `onExit`, which closes the receive port,
  /// ends `processAll`'s `await for`, and lets it unwind and clear the flag
  /// naturally. No-op when no isolate is active.
  ///
  /// DANGER: `Isolate.kill(immediate)` while the isolate is parked in an
  /// ONNX/Opus FFI call can corrupt process-level native state and crash the
  /// whole app, so we use `beforeNextEvent` — it lets any in-flight native call
  /// finish before the kill, dodging the FFI-corruption crash.
  ///
  /// The hard truth this method can't escape: `beforeNextEvent` AND cooperative
  /// 'cancel' BOTH require the isolate to return to its event loop —
  /// `beforeNextEvent` to schedule the kill, the cancel message to even be read
  /// off the port. A genuine native deadlock (a synchronous FFI call that never
  /// returns) services neither, so this method cannot actually reap that case;
  /// the zombie isolate and its native resources leak until the OS reclaims the
  /// process. `immediate` is the only priority that could kill such an isolate,
  /// but at the cost of likely native-heap corruption — strictly worse than a
  /// leaked isolate. We accept the leak: the per-frame cancel check in
  /// [VadAudioProcessor] makes cooperative cancel land within milliseconds for
  /// every realistic wedge, so a true unrecoverable native deadlock is the only
  /// scenario that reaches here unhandled, and there is no clean kill for it
  /// inside Dart's shared-process isolate model (only OS process isolation
  /// would give a corruption-free hard kill). What this method DOES guarantee is
  /// that `_activeIsolate` is cleared so the controller's state machine recovers
  /// to idle even when the underlying isolate can't be reaped.
  static void forceResetProcessing() {
    _cancelRequested = true;
    _activeIsolateControlPort?.send('cancel'); // best-effort, in case it's only slow
    final isolate = _activeIsolate;
    if (isolate != null) {
      Logger.warning('RecordingsManager: force-killing wedged processing isolate');
      isolate.kill(priority: Isolate.beforeNextEvent);
      _activeIsolate = null;
    }
  }

  /// Global notification system to alert UI pages when the recordings folder
  /// has been modified (deleted, reprocessed, etc.).
  static final ValueNotifier<int> recordingsChangeNotifier = ValueNotifier(0);
  static void notifyRecordingsChanged() => recordingsChangeNotifier.value++;

  /// Call on app startup to clean up incomplete extraction from a previous crash.
  /// If the persisted extraction-in-progress flag is set, any fully-written m4a/wav
  /// files in the temp directory are rescued to their live recordings/<date>/ folders
  /// first, then the temp directory is removed and the flag is cleared.
  /// Raw segments are intentionally left intact so processing can be retried.
  static Future<void> cleanUpIncompleteExtraction() async {
    final prefs = SharedPreferencesUtil();
    if (!prefs.extractionInProgress) return;

    Logger.debug(
      'RecordingsManager: Detected incomplete extraction from previous run — rescuing completed files.',
    );
    try {
      final directory = await getApplicationDocumentsDirectory();
      final tempDir = Directory('${directory.path}/processing_temp');
      if (await tempDir.exists()) {
        // Rescue any fully-written recordings before deleting the temp dir.
        // This covers the race where the crash happened between _saveRecording()
        // writing the m4a and moveTempFilesToLive() renaming it.
        // Move .meta sidecars first so they are in place when the audio file lands.
        final allEntities = await tempDir.list(recursive: true).where((e) => e is File).cast<File>().toList();
        allEntities.sort((a, b) {
          final aIsMeta = a.path.endsWith('.meta') ? 0 : 1;
          final bIsMeta = b.path.endsWith('.meta') ? 0 : 1;
          return aIsMeta.compareTo(bIsMeta);
        });
        for (final file in allEntities) {
          final fileName = file.path.split('/').last;
          if (!fileName.endsWith('.m4a') &&
              !fileName.endsWith('.wav') &&
              !fileName.endsWith('.ogg') &&
              !fileName.endsWith('.meta')) continue;
          final parts = fileName.split('_');
          var millis = parts.length >= 2 ? int.tryParse(parts.last.split('.').first) : null;
          if (millis == null || millis <= 0) continue;
          final dateStr = _dateStringFromMillis(millis);
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          try {
            await file.rename(dest);
            Logger.debug(
              'RecordingsManager: Rescued $fileName → recordings/$dateStr/',
            );
          } catch (e) {
            Logger.error('RecordingsManager: Failed to rescue $fileName: $e');
          }
        }
        await tempDir.delete(recursive: true);
        Logger.debug(
          'RecordingsManager: Removed leftover processing_temp directory.',
        );
      }
    } catch (e) {
      Logger.error('RecordingsManager: Failed to clean up processing_temp: $e');
    } finally {
      prefs.extractionInProgress = false;
    }
  }

  Future<List<Batch>> getBatches() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawSegmentsDir = Directory('${directory.path}/raw_segments');
    final recordingsDir = Directory('${directory.path}/recordings');

    Map<String, List<File>> rawSegmentsByDate = {};
    Map<String, List<Conversation>> processedByDate = {};

    // Process raw segments (now they are in DeviceSession folders)
    if (await rawSegmentsDir.exists()) {
      final deviceSessionEntities = await rawSegmentsDir.list().toList();
      final deviceSessionFolders = deviceSessionEntities.whereType<Directory>().toList();

      // Sort session folders by timestamp ID (e.g. "1713892490", "unknown_101", "session_AABBCCDD")
      deviceSessionFolders.sort((a, b) {
        final aName = a.path.split('/').last;
        final bName = b.path.split('/').last;
        final aIdStr = aName.replaceFirst('unknown_', '').replaceFirst('session_', '');
        final bIdStr = bName.replaceFirst('unknown_', '').replaceFirst('session_', '');

        // Folder ids are decimal (session_<sessionId>, unknown_<n>, or a raw timestamp).
        final aId = int.tryParse(aIdStr);
        final bId = int.tryParse(bIdStr);

        return (aId ?? 0).compareTo(bId ?? 0);
      });

      for (var folder in deviceSessionFolders) {
        final deviceSessionIdStr = folder.path.split('/').last;

        // Skip hidden folders or system folders if any
        if (deviceSessionIdStr.startsWith('.')) continue;

        // Process segments
        final folderEntities = await folder.list().toList();
        final files = folderEntities.whereType<File>().where((f) => f.path.endsWith('.bin')).toList();

        await Future.wait(
          files.map((file) async {
            String dateStr;
            try {
              final name = file.path.split('/').last;
              final tsStr = name.split('_').first;
              final ts = int.tryParse(tsStr);
              // The bin filename timestamp is epoch SECONDS (the WAL timerStart).
              // Convert to ms and group via the canonical local-date helper, so
              // raw bins land in the SAME date batch as their recordings and
              // discard records. (Previously read as ms — `fromMillisecondsSinceEpoch(ts)`
              // — so every UTC-stamped bin fell into a 1970 bucket, splitting it
              // from same-day recordings/discards.) Uptime ticks (pre-time-sync,
              // below kMinValidEpoch) and unparseable names fall back to mtime.
              if (ts != null && ts > 946684800) {
                dateStr = _dateStringFromMillis(ts * 1000);
              } else {
                dateStr = _dateStringFromMillis((await file.lastModified()).millisecondsSinceEpoch);
              }
            } catch (_) {
              dateStr = _dateStringFromMillis((await file.lastModified()).millisecondsSinceEpoch);
            }
            rawSegmentsByDate.putIfAbsent(dateStr, () => []).add(file);
          }),
        );
      }
    }

    // Process already processed recordings
    if (await recordingsDir.exists()) {
      final dateFolderEntities = await recordingsDir.list().toList();
      final dateFolders = dateFolderEntities.whereType<Directory>();
      for (var folder in dateFolders) {
        final dateString = folder.path.split('/').last;
        final folderEntities = await folder.list().toList();
        final files = folderEntities
            .whereType<File>()
            .where(
              (f) =>
                  (f.path.endsWith('.m4a') || f.path.endsWith('.wav') || f.path.endsWith('.ogg')) &&
                  !f.path.endsWith('.tmp.m4a'),
            )
            .toList();

        final conversations = await Future.wait(
          files.map((f) => Conversation.fromFileAsync(f)),
        );

        // Also pick up passthrough conversations: .meta files with no matching audio file.
        final audioBasenames = files.map((f) {
          final name = f.path.split('/').last;
          return name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
        }).toSet();
        final metaFiles = folderEntities.whereType<File>().where((f) => f.path.endsWith('.meta')).toList();
        final passthroughConvs = <Conversation>[];
        for (final meta in metaFiles) {
          final metaName = meta.path.split('/').last;
          final baseName = metaName.contains('.') ? metaName.substring(0, metaName.lastIndexOf('.')) : metaName;
          if (audioBasenames.contains(baseName)) continue;
          final c = await Conversation.fromMetaOnly(meta);
          if (c != null) passthroughConvs.add(c);
        }

        processedByDate[dateString] = [...conversations, ...passthroughConvs];
      }
    }

    // Discover dates with discard records — a day where ALL audio was rejected
    // produces no recording or raw bin, but still has a discards.jsonl we want
    // to render.
    final discardsByDate = <String, List<DiscardRecord>>{};
    if (await recordingsDir.exists()) {
      await for (final entity in recordingsDir.list()) {
        if (entity is! Directory) continue;
        final dateStr = entity.path.split('/').last;
        final loaded = await getDiscardsForDate(dateStr);
        if (loaded.isNotEmpty) discardsByDate[dateStr] = loaded;
      }
    }

    // Merge keys
    final allDates = {
      ...rawSegmentsByDate.keys,
      ...processedByDate.keys,
      ...discardsByDate.keys,
    }.toList();
    List<Batch> batches = [];

    for (var dateStr in allDates) {
      final parts = dateStr.split('-');
      final date = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );

      final raw = rawSegmentsByDate[dateStr] ?? [];
      // Sort raw segments chronologically by their filename. Since filenames are
      // zero-padded hex strings (timestamp_sessionId.bin), string order is correct.
      raw.sort((a, b) {
        final nameA = a.path.split('/').last;
        final nameB = b.path.split('/').last;
        return nameA.compareTo(nameB);
      });

      final allConversations = processedByDate[dateStr] ?? <Conversation>[];
      final finalized = allConversations.where((c) => !c.file.path.contains('_draft.')).toList();
      final drafts = allConversations.where((c) => c.file.path.contains('_draft.')).toList();

      batches.add(
        Batch(
          dateString: dateStr,
          date: date,
          rawSegments: raw,
          draftRecordings: drafts,
          finalizedRecordings: finalized,
          markerTimestamps: const [],
          discards: discardsByDate[dateStr] ?? const [],
        ),
      );
    }

    batches.sort((a, b) => b.date.compareTo(a.date));
    return batches;
  }

  /// Processes all batches as one continuous audio stream.
  ///
  /// Segments are sorted by (deviceSessionId, segmentIndex) across all batches so a
  /// recording that spans midnight is never artificially cut. Output files are
  /// moved into `recordings/<date>/` based on each recording's actual start
  /// timestamp, not the batch date they were grouped under.
  Future<void> processAll(
    List<Batch> batches,
    Function(double progress, Duration? eta) onProgress, {
    bool backgroundMode = false,
    bool finalizeDrafts = false,
    VoidCallback? onRecordingFinalized,
    ProcessingSettings? settingsOverride,
  }) async {
    // Strip bins that already produced a discard record. They stay on disk
    // for the 48 h recovery window, but re-running VAD on them just re-derives
    // the same outcome and appends a duplicate line to discards.jsonl every
    // cycle. Recover/Delete/sweep all remove the record, after which the bin
    // naturally re-enters the processing set. Uses the global persisted set
    // (see [discardedRelBinPaths]) so this strip and the "minutes to process"
    // estimate never disagree.
    //
    // Only strip in background mode when no settings override is provided.
    // Manual runs (Process button, Recover Discard) honor the
    // explicit set of bins provided.
    final discardedRelBins = (backgroundMode && settingsOverride == null) ? await discardedRelBinPaths() : const <String>{};
    if (discardedRelBins.isNotEmpty) {
      batches = batches.map((b) {
        final filtered = b.rawSegments.where((f) {
          final parts = f.path.split('/raw_segments/');
          return parts.length != 2 || !discardedRelBins.contains(parts.last);
        }).toList();
        if (filtered.length == b.rawSegments.length) return b;
        return Batch(
          dateString: b.dateString,
          date: b.date,
          rawSegments: filtered,
          draftRecordings: b.draftRecordings,
          finalizedRecordings: b.finalizedRecordings,
          markerTimestamps: b.markerTimestamps,
          discards: b.discards,
        );
      }).toList();
    }

    final activeBatches = batches.where((b) => b.rawSegments.isNotEmpty).toList();
    final hasDrafts = batches.any((b) => b.draftRecordings.isNotEmpty);

    if (activeBatches.isEmpty && !(finalizeDrafts && hasDrafts)) return;
    if (_isProcessingAny) throw Exception("Another processing task is already in progress.");

    _isProcessingAny = true;
    _cancelRequested = false;
    SharedPreferencesUtil().extractionInProgress = true;

    try {
      final directory = await getApplicationDocumentsDirectory();

      // Disk space guard — bail before processing if free space is critically low.
      final allRawFiles = activeBatches.expand((b) => b.rawSegments).toList();
      final rawTotalBytes = allRawFiles.fold<int>(0, (sum, f) {
        try {
          return sum + f.lengthSync();
        } catch (_) {
          return sum;
        }
      });
      minutesRemaining = rawTotalBytes / 252000.0;
      processingProgress.value = 0.0;
      if (rawTotalBytes > 50 * 1024 * 1024) {
        try {
          final probe = File('${directory.path}/.disk_probe');
          final sink = probe.openWrite();
          sink.add(Uint8List(1024 * 1024));
          await sink.flush();
          await sink.close();
          await probe.delete();
        } catch (e) {
          Logger.error(
            'RecordingsManager: Disk space probe failed ($e). '
            'Skipping processing to preserve raw segments.',
          );
          return;
        }
      }

      final tempProcessingPath = '${directory.path}/processing_temp/combined';
      final tempDir = Directory(tempProcessingPath);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      await tempDir.create(recursive: true);

      // Moves any completed recordings from tempDir to their live recordings/<date>/ folder
      // and fires onRecordingFinalized for each audio file moved.
      Future<void> moveTempFilesToLive() async {
        if (!await tempDir.exists()) return;
        // Move .meta sidecars before .m4a/.wav so the sidecar is always present
        // by the time onRecordingFinalized fires and the scan reads the file.
        final folderEntities = await tempDir.list().toList();
        final entities = folderEntities.whereType<File>().where((f) {
          final name = f.path.split('/').last;
          // Ignore temp files used during encoding to avoid race conditions
          // where the main isolate moves a file while the background isolate is still writing it.
          if (name.contains('.tmp')) return false;
          // Only move known finalized file types
          return name.endsWith('.m4a') ||
              name.endsWith('.wav') ||
              name.endsWith('.ogg') ||
              name.endsWith('.meta') ||
              name.endsWith('.bin');
        }).toList()
          ..sort((a, b) {
            final aIsMeta = a.path.endsWith('.meta') ? 0 : 1;
            final bIsMeta = b.path.endsWith('.meta') ? 0 : 1;
            return aIsMeta.compareTo(bIsMeta);
          });
        for (final entity in entities) {
          final fileName = entity.path.split('/').last;
          final nameNoExt = fileName.split('.').first;
          final parts = nameNoExt.split('_');

          // Format: recording_<ts> or recording_<ts>_draft
          int? millis;
          if (parts.length >= 2) {
            final tsStr = parts.contains('draft') ? parts[parts.length - 2] : parts.last;
            millis = int.tryParse(tsStr);
          }

          final dateStr =
              (millis != null && millis > 946684800000) ? _dateStringFromMillis(millis) : activeBatches.last.dateString;
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          try {
            await File(dest).delete();
          } on FileSystemException catch (_) {}

          // If we are moving a draft, delete any existing finalized version.
          // If we are moving a finalized file, delete any existing draft version.
          // Only do this for audio files to avoid deleting the meta we just moved (since meta comes first).
          final isAudio = fileName.endsWith('.m4a') || fileName.endsWith('.wav') || fileName.endsWith('.ogg');
          if (isAudio) {
            try {
              if (fileName.contains('_draft')) {
                await File(dest.replaceAll('_draft', '')).delete();
                await File(dest.replaceAll(RegExp(r'_draft\.(m4a|wav|ogg)$'), '.meta')).delete();
              } else {
                await File(dest.replaceAllMapped(RegExp(r'\.(m4a|wav|ogg)$'), (m) => '_draft${m[0]}')).delete();
                await File(dest.replaceAll(RegExp(r'\.(m4a|wav|ogg)$'), '_draft.meta')).delete();
              }
            } on FileSystemException catch (_) {}
          }

          await entity.rename(dest);
          if (fileName.endsWith('.m4a')) {
            final legacyWav = File(
              '${liveDir.path}/${fileName.replaceAll('.m4a', '')}.wav',
            );
            try {
              await legacyWav.delete();
            } on FileSystemException catch (_) {}
            onRecordingFinalized?.call();
            notifyRecordingsChanged();
          } else if (fileName.endsWith('.wav') || fileName.endsWith('.ogg')) {
            onRecordingFinalized?.call();
            notifyRecordingsChanged();
          }
        }
      }

      // Combine segments from all batches, sorted chronologically by timestamp.
      final allSegments = activeBatches.expand((b) => b.rawSegments).toList();

      if (allSegments.isNotEmpty) {
        allSegments.sort((a, b) {
          final nameA = a.path.split('/').last;
          final nameB = b.path.split('/').last;
          return nameA.compareTo(nameB);
        });

        // Pre-compute segment timestamps and session IDs on the main isolate.
        const kMinValidEpoch = 946684800;
        final segmentStartTimesMs = <int>[];
        final segmentStartUptimesMs = <int>[];
        final segmentSessionIds = <int?>[];
        final segmentDerivedFlags = <bool>[];
        final segmentFileSizes = <int>[];
        for (final file in allSegments) {
          segmentFileSizes.add(file.lengthSync());
          final stem = file.path.split('/').last.split('.').first;
          final parts = stem.split('_');
          final timerStart = int.tryParse(parts[0]);
          final sessionId = parts.length > 1 ? int.tryParse(parts[1]) : null;

          segmentSessionIds.add(sessionId);

          if (timerStart != null && timerStart > kMinValidEpoch) {
            segmentStartTimesMs.add(timerStart * 1000);
            segmentStartUptimesMs.add(0); // Hardware syncs RTC -> uptime in filename is lost
            segmentDerivedFlags.add(false);
          } else {
            segmentStartTimesMs.add(
              file.lastModifiedSync().toUtc().millisecondsSinceEpoch,
            );
            segmentStartUptimesMs.add((timerStart ?? 0) * 1000);
            segmentDerivedFlags.add(true);
          }
        }

        final Set<String> deletedSegmentFolders = {};

        // Pre-copy the Silero VAD model from rootBundle to a temp file on the
        // main isolate. flutter_onnxruntime's createSessionFromAsset uses
        // ServicesBinding.instance internally, which isn't available in a
        // background isolate — so the isolate loads from a filesystem path
        // via createSession(path) instead. Cached across runs.
        String? sileroModelPath;
        final effectiveVadEnabled = settingsOverride?.vadEnabled ?? SharedPreferencesUtil().vadEnabled;
        if (effectiveVadEnabled) {
          try {
            final dir = await getApplicationSupportDirectory();
            final cached = File('${dir.path}/silero_vad_v6.onnx');
            if (!await cached.exists()) {
              final data = await rootBundle.load('assets/models/silero_vad.onnx');
              await cached.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
            }
            sileroModelPath = cached.path;
          } catch (e) {
            Logger.error('RecordingsManager: Failed to cache Silero model ($e) — AAD mode in isolate.');
          }
        }

        Map<String, dynamic>? checkpointState;
        int checkpointResumeIndex = 0;
        List<String> checkpointPendingDeletes = [];
        final checkpointFile = File('${directory.path}/vad_checkpoint.json');
        try {
          if (await checkpointFile.exists()) {
            final content = await checkpointFile.readAsString();
            final data = jsonDecode(content) as Map<String, dynamic>;
            final savedPaths = (data['paths'] as List).cast<String>();
            final lastIndex = data['lastIndex'] as int;
            final currentPaths = allSegments.map((f) => f.path).toList();

            // Fast path: segment list identical up to lastIndex — full state restore.
            bool exactMatch = lastIndex >= 0 && lastIndex + 1 < currentPaths.length;
            if (exactMatch) {
              for (int k = 0; k <= lastIndex && k < savedPaths.length && k < currentPaths.length; k++) {
                if (currentPaths[k] != savedPaths[k]) {
                  exactMatch = false;
                  break;
                }
              }
            }

            if (exactMatch) {
              checkpointState = data['state'] as Map<String, dynamic>?;
              checkpointResumeIndex = lastIndex + 1;
              checkpointPendingDeletes = (data['pendingDeletes'] as List?)?.cast<String>() ?? [];
              Logger.debug(
                  'RecordingsManager: Resuming from checkpoint — skipping $checkpointResumeIndex/${currentPaths.length} segments.');
            } else {
              // Segment list shifted: new downloads were added or processed segments
              // were deleted from disk between runs. Find the first segment whose
              // timestamp is strictly later than the last completed segment so we
              // skip already-processed bins without requiring index alignment.
              // VAD state cannot be safely restored (preceding paths changed) but
              // the draft files on disk bridge the conversation gap.
              final lastCompletedPath = lastIndex >= 0 && lastIndex < savedPaths.length ? savedPaths[lastIndex] : null;
              final lastCompletedTs = lastCompletedPath != null
                  ? (int.tryParse(lastCompletedPath.split('/').last.split('_').first) ?? 0)
                  : 0;

              if (lastCompletedTs > 946684800) {
                // Epoch-seconds threshold avoids matching uptime-tick filenames.
                final resumeIdx = currentPaths.indexWhere((p) {
                  final ts = int.tryParse(p.split('/').last.split('_').first) ?? 0;
                  return ts > lastCompletedTs;
                });
                if (resumeIdx >= 0) {
                  checkpointResumeIndex = resumeIdx;
                  checkpointState = null; // fresh VAD state — drafts on disk bridge the gap
                  checkpointPendingDeletes = (data['pendingDeletes'] as List?)?.cast<String>() ?? [];
                  Logger.debug(
                      'RecordingsManager: Checkpoint shifted — resuming at $resumeIdx/${currentPaths.length} (ts>$lastCompletedTs), fresh state.');
                } else {
                  Logger.debug('RecordingsManager: Checkpoint segment list changed — starting fresh.');
                  await checkpointFile.delete();
                }
              } else {
                Logger.debug('RecordingsManager: Checkpoint segment list changed — starting fresh.');
                await checkpointFile.delete();
              }
            }
          }
        } catch (e) {
          Logger.error('RecordingsManager: Checkpoint load failed ($e) — starting fresh.');
          try {
            await checkpointFile.delete();
          } catch (_) {}
        }

        final mainBatchRunner = VadBatchRunnerChannel();
        bool success = false;
        try {
          final receivePort = ReceivePort();
          final exitPort = ReceivePort();
          bool isolateDone = false;

          final startTime = DateTime.now();
          int processedBytes = segmentFileSizes.sublist(0, checkpointResumeIndex).fold<int>(0, (a, b) => a + b);

          _activeIsolate = await Isolate.spawn(
            _processingIsolateEntry,
            _IsolateParams(
              sendPort: receivePort.sendPort,
              rootIsolateToken: RootIsolateToken.instance!,
              sileroModelPath: sileroModelPath,
              settings: settingsOverride ?? ProcessingSettings.fromPrefs(),
              tempProcessingPath: tempProcessingPath,
              segmentPaths: allSegments.map((f) => f.path).toList(),
              segmentFileSizes: segmentFileSizes,
              segmentStartTimesMs: segmentStartTimesMs,
              segmentStartUptimesMs: segmentStartUptimesMs,
              segmentSessionIds: segmentSessionIds,
              segmentDerivedFlags: segmentDerivedFlags,
              backgroundMode: backgroundMode,
              devLogsEnabled: SharedPreferencesUtil().devLogsToFileEnabled,
              checkpointState: checkpointState,
              checkpointResumeIndex: checkpointResumeIndex,
              checkpointPath: checkpointFile.path,
              checkpointPendingDeletes: checkpointPendingDeletes,
            ),
            onExit: exitPort.sendPort,
          );

          // If the isolate dies without sending 'done'/'error', close receivePort so we don't hang.
          exitPort.listen((_) {
            if (!isolateDone) receivePort.close();
            exitPort.close();
          });

          // Absolute bin paths that have been claimed by an in-flight discard
          // record this run. The delete_segments handler must skip these so the
          // recovery sweep (or AM) gets a chance to keep them around.
          final Set<String> discardProtectedPaths = {};

          await for (final msg in receivePort) {
            if (msg is! Map) continue;
            switch (msg['type'] as String) {
              case 'control_port':
                _activeIsolateControlPort = msg['port'] as SendPort;
                // Forward a pending cancel if the user already called cancelProcessing().
                if (_cancelRequested) {
                  _activeIsolateControlPort?.send('cancel');
                }
              case 'vad_batch_init':
                try {
                  await mainBatchRunner.init(msg['modelPath'] as String);
                  if (mainBatchRunner.available) {
                    (msg['replyPort'] as SendPort).send('ok');
                  } else {
                    (msg['replyPort'] as SendPort).send('plugin_missing');
                  }
                } catch (e) {
                  (msg['replyPort'] as SendPort).send(e.toString());
                }
              case 'vad_batch_run':
                try {
                  final result = await mainBatchRunner.runVadBatch(
                    msg['samples'] as Float32List,
                    resetStateFirst: msg['resetStateFirst'] as bool,
                  );
                  (msg['replyPort'] as SendPort).send(result);
                } catch (e) {
                  (msg['replyPort'] as SendPort).send(e.toString());
                }
              case 'vad_batch_dispose':
                try {
                  await mainBatchRunner.dispose();
                  if (msg['replyPort'] != null) {
                    (msg['replyPort'] as SendPort).send('ok');
                  }
                } catch (e) {
                  if (msg['replyPort'] != null) {
                    (msg['replyPort'] as SendPort).send(e.toString());
                  }
                }
              case 'heartbeat':
                // Liveness from the decode/save loops — re-anchors the stall
                // watchdog so a slow-but-progressing run isn't killed as a wedge.
                processingLiveness.value++;
              case 'marker_edl':
                // Persist EDLs eagerly so a mid-run isolate death does not
                // strand markers in memory only (B3). A throw from any single
                // _writeMarkerEdl must NOT escape the receivePort loop — that
                // would kill move/delete_segments/done for the rest of the
                // batch. Log per-EDL failure and continue (D7).
                final items = (msg['items'] as List).cast<Map<String, dynamic>>();
                for (final edl in items) {
                  try {
                    await _writeMarkerEdl(directory.path, edl);
                  } catch (e) {
                    Logger.error('RecordingsManager: _writeMarkerEdl failed for ${edl['markerMs']}: $e');
                  }
                }
              case 'discard_records':
                final items = (msg['items'] as List).cast<Map<String, dynamic>>();
                for (final rec in items) {
                  await _persistDiscardRecord(directory.path, rec);
                  for (final rel in (rec['relativeBins'] as List).cast<String>()) {
                    discardProtectedPaths.add('${directory.path}/raw_segments/$rel');
                  }
                }
                onRecordingFinalized?.call();
              case 'move':
                await moveTempFilesToLive();
              case 'delete_segments':
                final paths = (msg['paths'] as List).cast<String>();
                for (final path in paths) {
                  if (discardProtectedPaths.contains(path)) {
                    Logger.debug(
                      'RecordingsManager: Preserving raw segment for recovery: $path',
                    );
                    continue;
                  }
                  final f = File(path);
                  if (await f.exists()) {
                    Logger.debug(
                      'RecordingsManager: Deleting raw segment: $path',
                    );
                    await f.delete();
                    deletedSegmentFolders.add(f.parent.path);
                  }
                }
              case 'progress':
                final segmentBytes = msg['processed_bytes'] as int;
                processedBytes += segmentBytes;
                final index = msg['index'] as int;
                final totalSegments = msg['total'] as int;

                final progressVal = rawTotalBytes > 0 ? processedBytes / rawTotalBytes : ((index + 1) / totalSegments);
                final progress = (progressVal * 0.9).clamp(0.0, 0.9);

                Duration? eta;
                if (progressVal >= 0.05 && processedBytes > 0) {
                  final elapsed = DateTime.now().difference(startTime);
                  final remainingBytes = rawTotalBytes - processedBytes;
                  final etaMs = (elapsed.inMilliseconds * remainingBytes) ~/ processedBytes;
                  eta = Duration(milliseconds: etaMs);
                }
                processingProgress.value = progressVal;
                onProgress(progress, eta);
              case 'done':
                isolateDone = true;
                success = true;
                final wasCancelled = msg['cancelled'] as bool? ?? false;
                receivePort.close();
                // Checkpoint preserved on cancel so the next run can resume from it.
                if (!wasCancelled) {
                  try {
                    if (await checkpointFile.exists()) await checkpointFile.delete();
                  } catch (_) {}
                }
              case 'error':
                isolateDone = true;
                receivePort.close();
                try {
                  if (await checkpointFile.exists()) await checkpointFile.delete();
                } catch (_) {}
                throw Exception(msg['message']);
            }
          }

          _activeIsolateControlPort = null;

          if (!success) {
            throw Exception('Isolate died prematurely without reporting completion.');
          }

          await Future.delayed(const Duration(milliseconds: 200));
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        } catch (e) {
          Logger.error("RecordingsManager: Combined processing failed: $e");
          rethrow;
        } finally {
          _activeIsolateControlPort = null;
          await mainBatchRunner.dispose();
        }

        // Clean up any device-session folders that are now empty after progressive deletion.
        for (final folderPath in deletedSegmentFolders) {
          final folder = Directory(folderPath);
          if (await folder.exists()) {
            try {
              if (await folder.list().isEmpty) await folder.delete();
            } catch (_) {}
          }
        }
      }

      // Phase 3: Post-Sync Stitch Pass
      // After processing is complete, look for drafts and stitch them if within threshold.
      final isM4a = SharedPreferencesUtil().audioSaveFormat == 'm4a';
      if (isM4a) isTranscoding.value = true;
      try {
        await _stitchDraftRecordings(finalizeAll: finalizeDrafts);
      } finally {
        isTranscoding.value = false;
      }

      onProgress(1.0, Duration.zero);
    } finally {
      _isProcessingAny = false;
      _activeIsolate = null;
      _activeIsolateControlPort = null;
      processingProgress.value = 0.0;
      isTranscoding.value = false;
      SharedPreferencesUtil().extractionInProgress = false;
    }
  }

  /// Scans for draft recordings across all dates and stitches them with subsequent
  /// recordings if the gap is within the 2-minute threshold.
  ///
  /// The chronological-next lookup is **global across date folders** so a
  /// recording that crossed local midnight (draft in day-N folder, next in
  /// day-(N+1) folder, since `_saveRecordingCore` places files by their
  /// `startTime.toLocal()` date) gets stitched into a single recording
  /// instead of two split files. `_stitchOgg`/`_stitchWav` keep the draft's
  /// filename and folder, deleting nextFile wherever it lived.
  Future<void> _stitchDraftRecordings({bool finalizeAll = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;

    final splitSeconds = SharedPreferencesUtil().vadSplitSeconds;
    final thresholdMs = splitSeconds * 1000;

    bool scanNeeded = true;
    while (scanNeeded) {
      scanNeeded = false;

      final dateFolders = (await recordingsDir.list().toList()).whereType<Directory>().toList();

      // Build a single chronologically-sorted list of "events" (audio files and
      // ghost discards) across every date folder so the "next event after a
      // draft" lookup can cross day boundaries.
      final allAudioFiles = <File>[];
      for (final folder in dateFolders) {
        final entities = (await folder.list().toList()).whereType<File>().toList();
        allAudioFiles.addAll(entities.where((f) {
          final p = f.path;
          return (p.endsWith('.m4a') || p.endsWith('.wav') || p.endsWith('.ogg')) && !p.contains('.tmp');
        }));
      }

      // Load all discard records across all dates to build the unified timeline.
      final allDiscards = <DiscardRecord>[];
      for (final folder in dateFolders) {
        final dateStr = folder.path.split('/').last;
        final folderDiscards = await getDiscardsForDate(dateStr);
        allDiscards.addAll(folderDiscards);
      }

      final allEvents = [
        ...allAudioFiles.map((f) => (audio: f, discard: null as DiscardRecord?, timestamp: _extractTimestamp(f.path), durationMs: 0)),
        ...allDiscards.map((d) => (audio: null as File?, discard: d, timestamp: d.startTime.millisecondsSinceEpoch, durationMs: d.duration.inMilliseconds)),
      ];

      allEvents.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      final draftFiles = allAudioFiles.where((f) => f.path.contains('_draft.')).toList();
      if (draftFiles.isEmpty) break;

      for (final draftFile in draftFiles) {
        final draftTs = _extractTimestamp(draftFile.path);
        final draftExt = draftFile.path.split('.').last;
        final draftMeta = File(draftFile.path.replaceAllMapped(RegExp(r'\.' + draftExt + r'$'), (_) => '.meta'));

        if (!await draftMeta.exists()) {
          // No meta, can't stitch accurately. Finalize it.
          await _finalizeDraft(draftFile, isForceSynced: finalizeAll);
          scanNeeded = true;
          break;
        }

        // Get draft duration from meta
        final metaBytes = await draftMeta.readAsBytes();
        if (metaBytes.length < 8) {
          await _finalizeDraft(draftFile, isForceSynced: finalizeAll);
          scanNeeded = true;
          break;
        }
        final durationMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
        final draftEndTs = draftTs + durationMs;

        // Find the next chronological event across all folders.
        final currentIndex = allEvents.indexWhere((e) => e.audio?.path == draftFile.path);
        if (currentIndex == -1 || currentIndex == allEvents.length - 1) {
          // No next event anywhere.
          if (finalizeAll) {
            // Manual user trigger (Force Process) always finalizes immediately.
            await _finalizeDraft(draftFile, isForceSynced: true);
            scanNeeded = true;
            break;
          }
          continue;
        }

        // Look ahead and accumulate non-speech duration (gaps + ghosts)
        int accumulatedNonSpeechMs = 0;
        int currentPointerTs = draftEndTs;
        final intermediateEvents = <({File? audio, DiscardRecord? discard, int timestamp, int durationMs})>[];

        bool finalizeNow = false;
        File? audioToStitch;

        for (int i = currentIndex + 1; i < allEvents.length; i++) {
          final event = allEvents[i];
          final gap = event.timestamp - currentPointerTs;

          if (gap < 0) continue; // safety: ignore events that somehow overlap or precede

          if (accumulatedNonSpeechMs + gap >= thresholdMs) {
            finalizeNow = true;
            break;
          }

          accumulatedNonSpeechMs += gap;

          if (event.audio != null) {
            audioToStitch = event.audio;
            break;
          } else if (event.discard != null) {
            if (accumulatedNonSpeechMs + event.durationMs >= thresholdMs) {
              finalizeNow = true;
              break;
            }
            accumulatedNonSpeechMs += event.durationMs;
            currentPointerTs = event.timestamp + event.durationMs;
            intermediateEvents.add(event);
          }
        }

        if (finalizeNow) {
          Logger.debug(
              'RecordingsManager: Finalizing draft $draftTs — non-speech threshold (${thresholdMs}ms) exceeded.');
          await _finalizeDraft(draftFile, isForceSynced: false);
          scanNeeded = true;
          break;
        }

        if (audioToStitch != null) {
          // Found speech within threshold! Stitch all intermediate ghosts and then the speech file.
          int lastEndTs = draftEndTs;
          bool success = true;

          for (final inter in intermediateEvents) {
            final gap = inter.timestamp - lastEndTs;
            final interSuccess = await _stitchDiscard(draftFile, inter.discard!, gap);
            if (!interSuccess) {
              success = false;
              break;
            }
            lastEndTs = inter.timestamp + inter.durationMs;
          }

          if (success) {
            final finalGap = audioToStitch.path.contains('_draft.') ? 0 : (allEvents.firstWhere((e) => e.audio == audioToStitch).timestamp - lastEndTs);
            final int nextTs = allEvents.firstWhere((e) => e.audio == audioToStitch).timestamp;

            // Re-read meta since it may have been updated by _stitchDiscard
            final updatedMetaBytes = await draftMeta.readAsBytes();
            final updatedDurationMs = ByteData.sublistView(updatedMetaBytes).getUint32(4, Endian.little);
            final updatedEndTs = draftTs + updatedDurationMs;
            final gapToAudio = nextTs - updatedEndTs;

            // Clock jump check
            bool isClockJump = false;
            final nextMeta = File(audioToStitch.path.replaceAllMapped(RegExp(r'\.' + draftExt + r'$'), (_) => '.meta'));
            if (await nextMeta.exists()) {
              try {
                final nextMetaBytes = await nextMeta.readAsBytes();
                if (updatedMetaBytes.length >= 416 && nextMetaBytes.length >= 416) {
                  final dSid = ByteData.sublistView(updatedMetaBytes).getUint32(408, Endian.little);
                  final nSid = ByteData.sublistView(nextMetaBytes).getUint32(408, Endian.little);
                  final dUp = ByteData.sublistView(updatedMetaBytes).getUint32(412, Endian.little);
                  final nUp = ByteData.sublistView(nextMetaBytes).getUint32(412, Endian.little);

                  if (dSid == nSid && dUp > 0 && nUp > dUp) {
                    final uGap = (nUp * 1000) - ((dUp * 1000) + updatedDurationMs);
                    if (uGap.abs() < 5000 && gapToAudio.abs() > 10000) isClockJump = true;
                  }
                }
              } catch (_) {}
            }

            final gapMs = (isClockJump || gapToAudio < 10000) ? 0 : gapToAudio;
            Logger.debug('RecordingsManager: Stitching draft $draftTs with next ${audioToStitch.path.split('/').last} (gap=${gapMs}ms)');
            final finalSuccess = await _performStitch(draftFile, audioToStitch, gapMs);
            if (finalSuccess) {
              scanNeeded = true;
              break;
            }
          }
        }
      }
    }
  }

  /// Appends the audio from a [DiscardRecord] (ghost) into the [draftFile],
  /// preceded by [gapMs] of silence.
  Future<bool> _stitchDiscard(File draftFile, DiscardRecord ghost, int gapMs) async {
    final ext = draftFile.path.split('.').last;
    final directory = await getApplicationDocumentsDirectory();
    final rawDir = Directory('${directory.path}/raw_segments');

    try {
      // 1. Re-process the ghost bins into a temporary audio file of the same format
      final tempAudio = File('${draftFile.parent.path}/ghost_${ghost.startTime.millisecondsSinceEpoch}.tmp.$ext');
      if (await tempAudio.exists()) await tempAudio.delete();

      final decoder = SimpleOpusDecoder(
        sampleRate: 16000,
        channels: 1,
      );
      try {
        if (ext == 'wav') {
          final sink = await tempAudio.open(mode: FileMode.write);
          // Placeholder 44-byte WAV header, fixed up later by _stitchWav/_mergeMeta
          await sink.writeFrom(Uint8List(44));

          for (final relPath in ghost.relativeBins) {
            final bin = File('${rawDir.path}/$relPath');
            if (!await bin.exists()) continue;

            final bytes = await bin.readAsBytes();
            final byteData = ByteData.sublistView(bytes);
            int offset = 0;

            while (offset + 4 <= bytes.length) {
              final frameLen = byteData.getUint32(offset, Endian.little);
              if (frameLen == 0 || frameLen == 0xFFFFFFFF) {
                offset += 4; continue;
              }
              if (frameLen >= 0xFFFFFFFB) {
                offset += (frameLen == 0xFFFFFFFB ? 36 : 20); continue;
              }
              if (offset + 4 + frameLen > bytes.length) break;

              final opus = Uint8List.sublistView(bytes, offset + 4, offset + 4 + frameLen);
              try {
                final pcm = decoder.decode(input: opus);
                if (pcm != null) await sink.writeFrom(pcm.buffer.asUint8List());
              } catch (_) {}
              offset += 4 + ((frameLen + 3) & ~3);
            }
          }
          await sink.close();
        } else {
          // OGG/M4A: We don't have a high-level OGG/M4A encoder on the main isolate.
          // Fall back to silence-only stitching for these formats to maintain timeline.
          return await _stitchSilence(draftFile, gapMs + ghost.duration.inMilliseconds);
        }
      } finally {
        decoder.destroy();
      }

      if (await tempAudio.exists() && (await tempAudio.length()) > 44) {
        final success = await _performStitch(draftFile, tempAudio, gapMs);
        if (await tempAudio.exists()) await tempAudio.delete();
        return success;
      } else {
        return await _stitchSilence(draftFile, gapMs + ghost.duration.inMilliseconds);
      }
    } catch (e) {
      Logger.error('RecordingsManager: Ghost stitch failed ($e) — falling back to silence');
      return await _stitchSilence(draftFile, gapMs + ghost.duration.inMilliseconds);
    }
  }

  Future<bool> _stitchSilence(File draftFile, int durationMs) async {
    if (durationMs <= 0) return true;
    final ext = draftFile.path.split('.').last;
    if (ext != 'wav') {
      // For compressed formats, we just update the metadata duration;
      // chaining doesn't physically pad silence.
      await _mergeMeta(draftFile, null, durationMs);
      return true;
    }

    try {
      final sink = await draftFile.open(mode: FileMode.append);
      // 16kHz, 16-bit mono = 32000 bytes/sec
      final silenceBytes = Uint8List((durationMs * 32).toInt());
      await sink.writeFrom(silenceBytes);
      await sink.close();
      await _mergeMeta(draftFile, null, durationMs);
      return true;
    } catch (e) {
      Logger.error('RecordingsManager: Silence stitch failed: $e');
      return false;
    }
  }

  int _extractTimestamp(String path) {
    final name = path.split('/').last;
    final nameNoExt = name.split('.').first;
    final parts = nameNoExt.split('_');
    if (parts.length < 2) return 0;

    // Format: recording_<ts> or recording_<ts>_draft
    final tsStr = parts.contains('draft') ? parts[parts.length - 2] : parts.last;
    return int.tryParse(tsStr) ?? 0;
  }

  Future<void> _finalizeDraft(File file, {bool isForceSynced = false}) async {
    final path = file.path;
    if (!path.contains('_draft.')) return;
    final currentExt = path.split('.').last;
    final targetExt = SharedPreferencesUtil().audioSaveFormat;
    final oldFilename = path.split('/').last;

    final metaPath = path.replaceAll(RegExp(r'\.(m4a|wav|ogg)$'), '.meta');

    try {
      String finalAudioPath;
      bool transcoded = false;

      if (currentExt == 'wav' && targetExt == 'm4a') {
        // Transcode from WAV to M4A
        finalAudioPath = path.replaceAll('_draft.wav', '.m4a');
        if (await File(finalAudioPath).exists()) await File(finalAudioPath).delete();

        final success = await _transcodeWavToM4a(file, finalAudioPath);
        if (success) {
          await file.delete();
          transcoded = true;
        } else {
          finalAudioPath = path.replaceAll('_draft.', '.');
          if (await File(finalAudioPath).exists()) await File(finalAudioPath).delete();
          await file.rename(finalAudioPath);
        }
      } else {
        finalAudioPath = path.replaceAll('_draft.', '.');
        if (await File(finalAudioPath).exists()) await File(finalAudioPath).delete();
        await file.rename(finalAudioPath);
      }

      final newFilename = finalAudioPath.split('/').last;
      final newMetaPath = metaPath.replaceAll('_draft.', '.');

      if (await File(metaPath).exists()) {
        final bytes = await File(metaPath).readAsBytes();
        var outBytes = bytes;

        // 1. Update flags (passthrough, forceSynced, capEnded).
        // Layout at flagOffset: [0]=passthrough, [1]=forceSynced, [2]=capEnded.
        // capEnded is set by VAD when the recording was written; we preserve it across
        // draft promotion (Force Process / stitch fallback should not relabel a cap-end
        // recording as silence-end).
        if (bytes.length >= 417) {
          final keyLen = bytes[416];
          final flagOffset = 417 + keyLen;
          if (bytes.length < flagOffset + 3) {
            // Extend to fit all 3 flag bytes, preserving any existing earlier bytes.
            final existingPassthrough = (bytes.length > flagOffset) ? bytes[flagOffset] : 0;
            final existingCapEnded = (bytes.length > flagOffset + 2) ? bytes[flagOffset + 2] : 0;
            final newBytes = Uint8List(flagOffset + 3);
            newBytes.setRange(0, bytes.length, bytes);
            newBytes[flagOffset] = existingPassthrough;
            newBytes[flagOffset + 1] = isForceSynced ? 1 : 0;
            newBytes[flagOffset + 2] = existingCapEnded;
            outBytes = newBytes;
          } else {
            outBytes[flagOffset + 1] = isForceSynced ? 1 : 0;
            // capEnded byte preserved as-is at flagOffset + 2.
          }
        }

        // 2. Update uploadKey extension if transcoded
        if (transcoded) {
          final keyLen = outBytes[416];
          final key = String.fromCharCodes(outBytes, 417, 417 + keyLen);
          final newKey = key.replaceAll('.$currentExt', '.m4a');
          final newKeyBytes = Uint8List.fromList(newKey.codeUnits);

          final builder = BytesBuilder();
          builder.add(outBytes.sublist(0, 416));
          builder.addByte(newKeyBytes.length);
          builder.add(newKeyBytes);
          if (outBytes.length > 417 + keyLen) {
            builder.add(outBytes.sublist(417 + keyLen));
          }
          outBytes = builder.takeBytes();
        }

        if (await File(newMetaPath).exists()) await File(newMetaPath).delete();
        await File(newMetaPath).writeAsBytes(outBytes);
        await File(metaPath).delete();
      }

      // Update any .edl files that were pointing to this draft
      int? finalDurationMs;
      try {
        final metaBytes = await File(newMetaPath).readAsBytes();
        if (metaBytes.length >= 8) {
          finalDurationMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
        }
      } catch (_) {}

      final dir = file.parent;
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        for (final entity in entities) {
          if (entity is File && entity.path.endsWith('.edl')) {
            try {
              final content = await entity.readAsString();
              final json = jsonDecode(content) as Map<String, dynamic>;
              if (json['segmentFilename'] == oldFilename) {
                json['segmentFilename'] = newFilename;
                // Only overwrite cropEndMs when the user has NOT customized
                // the crop window. _reanchorMarkerEdls may have shifted
                // cropStart/End into a smaller user-saved range earlier in
                // this stitch chain; blindly resetting cropEndMs to full
                // duration destroys those edits (NEW2/C2).
                if (finalDurationMs != null) {
                  final userSaved = json['userSaved'] as bool? ?? false;
                  final cropStart = json['cropStartMs'] as int? ?? 0;
                  final cropEnd = json['cropEndMs'] as int? ?? 0;
                  final isDefaultCrop = !userSaved && cropStart == 0;
                  if (isDefaultCrop) {
                    json['cropEndMs'] = finalDurationMs;
                  } else if (cropEnd > finalDurationMs) {
                    // Preserve user crop but clamp to playable length.
                    json['cropEndMs'] = finalDurationMs;
                  }
                }
                await _writeJsonAtomic(entity, json);
                Logger.debug('RecordingsManager: Updated EDL ${entity.path} for finalized draft');
              }
            } catch (e) {
              Logger.error('RecordingsManager: Failed to update EDL ${entity.path}: $e');
            }
          }
        }
      }

      Logger.debug('RecordingsManager: Finalized draft $path -> $finalAudioPath');
    } catch (e) {
      Logger.error('RecordingsManager: Failed to finalize draft $path: $e');
    }
  }

  Future<bool> _transcodeWavToM4a(File wavFile, String m4aPath) async {
    String? sessionId;
    try {
      final bytes = await wavFile.readAsBytes();
      if (bytes.length < 44) return false;

      final data = ByteData.sublistView(bytes);
      final sampleRate = data.getUint32(24, Endian.little);
      // View past the 44-byte WAV header instead of deep-copying the entire PCM payload
      // (can be many MB for long recordings). `bytes` is read-only after readAsBytes().
      final pcmBytes = Uint8List.sublistView(bytes, 44);

      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
      const chunkSize = 4096;
      for (int i = 0; i < pcmBytes.length; i += chunkSize) {
        final end = (i + chunkSize > pcmBytes.length) ? pcmBytes.length : i + chunkSize;
        // View, not copy: encodeBuffer marshals synchronously over the MethodChannel.
        await AacEncoder.encodeBuffer(sessionId, Uint8List.sublistView(pcmBytes, i, end));
      }
      await AacEncoder.finishEncoder(sessionId);
      return true;
    } catch (e) {
      Logger.error('RecordingsManager: Transcoding failed: $e');
      if (sessionId != null) {
        try {
          await AacEncoder.finishEncoder(sessionId);
        } catch (_) {}
      }
      return false;
    }
  }

  Future<bool> _performStitch(File draftFile, File nextFile, int gapMs) async {
    final ext = draftFile.path.split('.').last;
    if (nextFile.path.split('.').last != ext) {
      // Cannot stitch different formats easily. Finalize.
      await _finalizeDraft(draftFile);
      return false;
    }

    try {
      if (ext == 'ogg') {
        return await _stitchOgg(draftFile, nextFile, gapMs);
      } else if (ext == 'wav') {
        return await _stitchWav(draftFile, nextFile, gapMs);
      } else if (ext == 'm4a') {
        // M4A stitching requires decode/re-encode which we can't do easily here.
        // Finalize and start fresh.
        await _finalizeDraft(draftFile);
        return false;
      }
    } catch (e) {
      Logger.error('RecordingsManager: Stitch failed: $e');
      await _finalizeDraft(draftFile);
    }
    return false;
  }

  Future<bool> _stitchOgg(File draftFile, File nextFile, int gapMs) async {
    // OGG Opus physical concatenation (bitstream chaining).
    // Note: Chaining is valid OGG but does not physically pad the gap with silence frames.
    // The .meta sidecar duration remains wall-clock accurate (including the gap).
    final nextBytes = await nextFile.readAsBytes();

    // Capture the draft's wall-clock duration *before* mutating either file so
    // we can re-anchor next-file markers to the combined timeline (B13). Bail
    // if meta is missing — without an accurate prefix duration, re-anchored
    // markers would land in the wrong half of the stitched file (D3).
    final int? draftDurationMsOrNull = await _readMetaDurationMs(draftFile);
    if (draftDurationMsOrNull == null) {
      Logger.error(
          'RecordingsManager: _stitchOgg aborting — missing/short meta for ${draftFile.path}; finalizing draft to preserve marker offsets');
      await _finalizeDraft(draftFile);
      return false;
    }
    final int draftDurationMs = draftDurationMsOrNull;

    final sink = await draftFile.open(mode: FileMode.append);
    await sink.writeFrom(nextBytes);
    await sink.close();

    // Update Meta
    await _mergeMeta(draftFile, nextFile, gapMs);

    // Re-anchor EDLs pointing at the soon-to-be-deleted next file to the draft
    // file, adding the draft's duration + gap to each markerOffsetMs (B6 + B13).
    final reanchorOk = await _reanchorMarkerEdls(
      fromFilename: nextFile.path.split('/').last,
      toFilename: draftFile.path.split('/').last,
      offsetShiftMs: draftDurationMs + gapMs,
      newDurationMs: await _readMetaDurationMs(draftFile),
      folders: [draftFile.parent, nextFile.parent],
    );

    if (!reanchorOk) {
      // Leave nextFile on disk so the user (or a retry) can recover the
      // un-reanchored markers (D2). The stitched audio is still good.
      Logger.error('RecordingsManager: _stitchOgg leaving ${nextFile.path} undeleted — re-anchor had errors');
      return true;
    }

    // Delete next (and merge Omi bin so the upload sends the full recording)
    await _stitchBinIfPresent(draftFile, nextFile);
    await nextFile.delete();
    final nextMeta = File(nextFile.path.replaceAll(RegExp(r'\.ogg$'), '.meta'));
    if (await nextMeta.exists()) await nextMeta.delete();

    return true;
  }

  Future<bool> _stitchWav(File draftFile, File nextFile, int gapMs) async {
    // Read draft, skip header to get PCM.
    final draftBytes = await draftFile.readAsBytes();
    final nextBytes = await nextFile.readAsBytes();

    if (draftBytes.length < 44 || nextBytes.length < 44) return false;

    final int? draftDurationMsOrNull = await _readMetaDurationMs(draftFile);
    if (draftDurationMsOrNull == null) {
      Logger.error(
          'RecordingsManager: _stitchWav aborting — missing/short meta for ${draftFile.path}; finalizing draft to preserve marker offsets');
      await _finalizeDraft(draftFile);
      return false;
    }
    final int draftDurationMs = draftDurationMsOrNull;

    const sampleRate = 16000;
    const channels = 1;
    final silenceSamples = (gapMs * sampleRate) ~/ 1000;
    final silenceBytes = Uint8List(silenceSamples * channels * 2);

    final combinedPcm = BytesBuilder();
    // Views past the WAV headers: BytesBuilder.add() copies (copy:true default), so the
    // prior sublist() was a redundant full-payload deep copy on top of that copy.
    combinedPcm.add(Uint8List.sublistView(draftBytes, 44));
    combinedPcm.add(silenceBytes);
    combinedPcm.add(Uint8List.sublistView(nextBytes, 44));

    final totalPcmBytes = combinedPcm.length;
    final header = _generateWavHeader(totalPcmBytes, sampleRate, channels);

    final outSink = draftFile.openWrite();
    outSink.add(header);
    outSink.add(combinedPcm.takeBytes());
    await outSink.close();

    // Update Meta
    await _mergeMeta(draftFile, nextFile, gapMs);

    final reanchorOk = await _reanchorMarkerEdls(
      fromFilename: nextFile.path.split('/').last,
      toFilename: draftFile.path.split('/').last,
      offsetShiftMs: draftDurationMs + gapMs,
      newDurationMs: await _readMetaDurationMs(draftFile),
      folders: [draftFile.parent, nextFile.parent],
    );

    if (!reanchorOk) {
      Logger.error('RecordingsManager: _stitchWav leaving ${nextFile.path} undeleted — re-anchor had errors');
      return true;
    }

    // Delete next (and merge Omi bin so the upload sends the full recording)
    await _stitchBinIfPresent(draftFile, nextFile);
    await nextFile.delete();
    final nextMeta = File(nextFile.path.replaceAll(RegExp(r'\.wav$'), '.meta'));
    if (await nextMeta.exists()) await nextMeta.delete();

    return true;
  }

  /// Appends [nextFile]'s raw Opus bin to [draftFile]'s bin, then deletes the next bin.
  /// No-op if either bin is absent (Omi disabled, or first run predates this fix).
  Future<void> _stitchBinIfPresent(File draftFile, File nextFile) async {
    final draftTs = _extractTimestamp(draftFile.path);
    final nextTs = _extractTimestamp(nextFile.path);
    if (draftTs == 0 || nextTs == 0) return;

    final draftBin = File('${draftFile.parent.path}/recording_fs320_$draftTs.bin');
    final nextBin = File('${nextFile.parent.path}/recording_fs320_$nextTs.bin');

    if (!await nextBin.exists() || !await draftBin.exists()) return;

    try {
      final nextBytes = await nextBin.readAsBytes();
      final sink = await draftBin.open(mode: FileMode.append);
      await sink.writeFrom(nextBytes);
      await sink.close();
      await nextBin.delete();
      Logger.debug('RecordingsManager: Stitched Omi bin $draftTs ← $nextTs (+${nextBytes.length} B)');
    } catch (e) {
      Logger.error('RecordingsManager: _stitchBinIfPresent failed: $e');
    }
  }

  /// Reads the `.meta` sidecar's 4-byte LE duration (offset 4). Returns null
  /// if the sidecar is missing or too short.
  Future<int?> _readMetaDurationMs(File audioFile) async {
    try {
      final base = audioFile.path.substring(0, audioFile.path.lastIndexOf('.'));
      final metaBytes = await File('$base.meta').readAsBytes();
      if (metaBytes.length < 8) return null;
      return ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
    } catch (_) {
      return null;
    }
  }

  /// Re-points any EDL in [folders] whose `segmentFilename == fromFilename`
  /// to [toFilename], shifting `markerOffsetMs` by [offsetShiftMs] (the
  /// draft's wall-clock duration + inter-file gap). Returns true iff every
  /// matching EDL was rewritten successfully — the caller should refuse to
  /// delete `fromFilename` if this returns false (D2).
  ///
  /// Crop bounds are shifted ONLY when the EDL was user-saved or had a
  /// non-default crop (NEW6/E5); for unset-default crops the shift would
  /// hide the entire stitched-in prefix from the player's visible window.
  ///
  /// Scans every folder in [folders] so cross-day-folder stitches don't
  /// orphan EDLs that live under the next file's date (NEW5/E3).
  Future<bool> _reanchorMarkerEdls({
    required String fromFilename,
    required String toFilename,
    required int offsetShiftMs,
    int? newDurationMs,
    required List<Directory> folders,
  }) async {
    bool allOk = true;
    final seenFolders = <String>{};
    for (final folder in folders) {
      if (!seenFolders.add(folder.path)) continue;
      if (!await folder.exists()) continue;
      final entities = await folder.list().toList();
      for (final entity in entities) {
        if (entity is! File || !entity.path.endsWith('.edl')) continue;
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        } catch (e) {
          Logger.error('RecordingsManager: Failed to read EDL ${entity.path} during reanchor: $e');
          continue; // not a target EDL by definition; safe to skip
        }
        if (json['segmentFilename'] != fromFilename) continue;
        try {
          final userSaved = json['userSaved'] as bool? ?? false;
          final origCropStart = json['cropStartMs'] as int? ?? 0;
          final origCropEnd = json['cropEndMs'] as int? ?? 0;
          // "Default" crop = start==0 and end is either 0 or the original
          // nextFile duration (the value _writeMarkerEdl sets at first write).
          // Only shift when the user actually committed an edit.
          final isDefaultCrop = !userSaved && origCropStart == 0;
          json['segmentFilename'] = toFilename;
          json['markerOffsetMs'] = (json['markerOffsetMs'] as int? ?? 0) + offsetShiftMs;
          if (!isDefaultCrop) {
            json['cropStartMs'] = origCropStart + offsetShiftMs;
            json['cropEndMs'] = origCropEnd + offsetShiftMs;
            if (newDurationMs != null && newDurationMs > 0) {
              if ((json['cropEndMs'] as int) > newDurationMs) json['cropEndMs'] = newDurationMs;
              if ((json['cropStartMs'] as int) > newDurationMs) json['cropStartMs'] = newDurationMs;
            }
          } else if (newDurationMs != null && newDurationMs > 0) {
            // Default crop covers the combined file end-to-end.
            json['cropStartMs'] = 0;
            json['cropEndMs'] = newDurationMs;
          }
          await _writeJsonAtomic(entity, json);
          Logger.debug(
              'RecordingsManager: Re-anchored EDL ${entity.path.split('/').last}: $fromFilename → $toFilename (+${offsetShiftMs}ms)${isDefaultCrop ? " [default crop]" : " [preserved crop]"}');
        } catch (e) {
          Logger.error('RecordingsManager: Failed to re-anchor EDL ${entity.path}: $e');
          allOk = false; // signal caller to leave nextFile in place for recovery
        }
      }
    }
    return allOk;
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

  Future<void> _mergeMeta(File draftFile, File? nextFile, int gapMs) async {
    final draftMetaPath = draftFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta');
    final draftMetaFile = File(draftMetaPath);
    if (!await draftMetaFile.exists()) return;

    final dBytes = await draftMetaFile.readAsBytes();
    if (dBytes.length < 8) return;

    final dMeta = ByteData.sublistView(dBytes);
    const sampleRate = 16000;
    final dSamples = dMeta.getUint32(0, Endian.little);
    final gapSamples = (gapMs * sampleRate) ~/ 1000;

    int nSamples = 0;
    Uint8List? nBytes;
    if (nextFile != null) {
      final nextMetaPath = nextFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta');
      final nextMetaFile = File(nextMetaPath);
      if (await nextMetaFile.exists()) {
        nBytes = await nextMetaFile.readAsBytes();
        if (nBytes.length >= 8) {
          nSamples = ByteData.sublistView(nBytes).getUint32(0, Endian.little);
        }
      }
    }

    final totalSamples = dSamples + gapSamples + nSamples;
    final totalDurationMs = (totalSamples * 1000) ~/ sampleRate;

    // We reuse the existing draft meta buffer to preserve all flags, keys, and bin refs.
    // Only the first 8 bytes (samples, duration) and potentially peaks are updated.
    final outBytes = Uint8List.fromList(dBytes);
    final outData = ByteData.view(outBytes.buffer);

    outData.setUint32(0, totalSamples, Endian.little);
    outData.setUint32(4, totalDurationMs, Endian.little);

    // Merge peaks if we have a next file with peaks
    if (nBytes != null && nBytes.length >= 408 && dBytes.length >= 408) {
      final nMeta = ByteData.sublistView(nBytes);
      for (int i = 0; i < 200; i++) {
        final p1 = dMeta.getUint16(8 + i * 2, Endian.little);
        final p2 = nMeta.getUint16(8 + i * 2, Endian.little);
        outData.setUint16(8 + i * 2, max(p1, p2), Endian.little);
      }
    }

    await draftMetaFile.writeAsBytes(outBytes, flush: true);
  }

  static String fmtDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  /// Atomically writes JSON to [target]: write to `<target>.tmp` then rename,
  /// so a concurrent reader never observes a truncated/partial file (NEW3/C5).
  Future<void> _writeJsonAtomic(File target, Object payload) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(target.path);
  }

  @visibleForTesting
  Future<void> writeMarkerEdlTest(String docsPath, Map<String, dynamic> edl) => _writeMarkerEdl(docsPath, edl);

  @visibleForTesting
  Future<bool> reanchorMarkerEdlsTest({
    required String fromFilename,
    required String toFilename,
    required int offsetShiftMs,
    int? newDurationMs,
    required List<Directory> folders,
  }) =>
      _reanchorMarkerEdls(
        fromFilename: fromFilename,
        toFilename: toFilename,
        offsetShiftMs: offsetShiftMs,
        newDurationMs: newDurationMs,
        folders: folders,
      );

  /// Persists one marker EDL sidecar. Called eagerly per `marker_edl`
  /// isolate message so an isolate crash mid-run still leaves the marker
  /// on disk.
  ///
  /// Collision policy when an EDL already exists at `marker_<ms>.edl`:
  ///   1. If existing EDL was user-saved (cropped or explicit Save),
  ///      preserve it untouched — just update its segmentFilename to track
  ///      the rename (B3). User edits never get orphaned to `_<n>.edl`.
  ///   2. Same markerMs + same segmentFilename → noop.
  ///   3. Otherwise the new write lands at `marker_<ms>_<n>.edl`.
  Future<void> _writeMarkerEdl(String docsPath, Map<String, dynamic> edl) async {
    final filename = (edl['filename'] as String?) ?? '';
    final markerMs = edl['markerMs'] as int;
    final offsetMs = edl['offsetMs'] as int;
    final durationMs = edl['durationMs'] as int;

    int? millis;
    if (filename.isNotEmpty) {
      final nameNoExt = filename.contains('.') ? filename.substring(0, filename.lastIndexOf('.')) : filename;
      final parts = nameNoExt.split('_');
      final tsStr = parts.contains('draft') ? parts[parts.length - 2] : parts.last;
      millis = int.tryParse(tsStr);
    }
    final dateStr =
        (millis != null && millis > 946684800000) ? _dateStringFromMillis(millis) : _dateStringFromMillis(markerMs);
    final liveDir = Directory('$docsPath/recordings/$dateStr');
    await liveDir.create(recursive: true);

    final payload = {
      'markerTimestampMs': markerMs,
      'segmentFilename': filename,
      'markerOffsetMs': offsetMs,
      'cropStartMs': 0,
      'cropEndMs': durationMs,
      'userSaved': false,
    };

    final File edlFile = File('${liveDir.path}/marker_$markerMs.edl');
    if (await edlFile.exists()) {
      try {
        final existing = jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
        final existingFilename = existing['segmentFilename'] as String? ?? '';
        if (existingFilename == filename) {
          // Same marker, same segment — preserve any user crop edits.
          return;
        }
        final userSaved = existing['userSaved'] as bool? ?? false;
        if (userSaved) {
          // User explicitly Saved → preserve their work. Re-point
          // segmentFilename + offsetMs to the new audio anchor but keep
          // cropStart/cropEnd and userSaved untouched. `userSaved` is the
          // only reliable signal: it's set exclusively by the player's
          // _saveConversation path, and any non-default crop the user
          // committed went through that same path.
          //
          // A `cropEndMs > 0` heuristic was tried earlier but matches
          // every default EDL (the isolate writes cropEndMs = encoded
          // duration), so it'd freeze stale cropEndMs values against the
          // new segment.
          existing['segmentFilename'] = filename;
          existing['markerOffsetMs'] = offsetMs;
          await _writeJsonAtomic(edlFile, existing);
          Logger.debug('RecordingsManager: Preserved user edits on marker_$markerMs.edl, re-pointed to $filename');
          return;
        }
      } catch (_) {
        // Corrupt/unparseable EDL — fall through and overwrite.
      }
      // No user edits to preserve: overwrite in place. Two physical taps
      // cannot share a UTC ms (firmware ms resolution, taps take much
      // longer than 1 ms), so the only way an EDL at this filename exists
      // is the same physical tap from a previous run; the new payload is
      // the authoritative one (B4/D1).
    }
    await _writeJsonAtomic(edlFile, payload);
    Logger.debug(
        'RecordingsManager: Wrote EDL ${edlFile.path.split('/').last} → ${filename.isEmpty ? "(orphan)" : filename} at ${offsetMs}ms');

    // If the audio file is from a different day than the tap, a previous run may
    // have written an orphan EDL into the markerMs date folder. Delete it now
    // that we have the real paired EDL in the correct folder.
    if (filename.isNotEmpty) {
      final orphanDateStr = _dateStringFromMillis(markerMs);
      if (orphanDateStr != dateStr) {
        final orphanFile = File('$docsPath/recordings/$orphanDateStr/marker_$markerMs.edl');
        if (await orphanFile.exists()) {
          try {
            final orphan = jsonDecode(await orphanFile.readAsString()) as Map<String, dynamic>;
            final orphanFilename = orphan['segmentFilename'] as String? ?? '';
            final orphanUserSaved = orphan['userSaved'] as bool? ?? false;
            if (orphanFilename.isEmpty && !orphanUserSaved) {
              await orphanFile.delete();
              Logger.debug('RecordingsManager: Deleted cross-midnight orphan marker_$markerMs.edl from $orphanDateStr');
            }
          } catch (_) {}
        }
      }
    }
  }

  /// Scans all `recordings/<date>/` folders for `marker_*.edl` files and
  /// returns a list of [MarkerConversation] sorted by markerTime descending.
  /// Pending conversations (no backing m4a yet) are included with [isPending] = true.
  Future<List<MarkerConversation>> getMarkerConversations() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return [];

    final entities = await recordingsDir.list().toList();
    final dateFolders = entities.whereType<Directory>().toList();

    // Build a one-shot filename → File index across all date folders so that
    // missing-segment recovery is O(1) per marker instead of O(folders) (B14).
    final Map<String, File> filenameIndex = {};
    for (final folder in dateFolders) {
      try {
        await for (final entity in folder.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          // First write wins — date folder placement is deterministic.
          filenameIndex.putIfAbsent(name, () => entity);
        }
      } catch (_) {}
    }

    // Step 1: Rapidly scan all date folders for EDL files
    final List<MarkerConversation> allConversations = [];
    for (final dateFolder in dateFolders) {
      final edlFiles = await dateFolder
          .list()
          .where((e) => e is File && e.uri.pathSegments.last.startsWith('marker_') && e.path.endsWith('.edl'))
          .cast<File>()
          .toList();

      for (final edlFile in edlFiles) {
        try {
          final json = jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
          final markerMs = json['markerTimestampMs'] as int;
          final segmentFilename = json['segmentFilename'] as String?;

          File? segmentFile;
          if (segmentFilename != null && segmentFilename.isNotEmpty) {
            // Resolve the segment from the index — also covers draft files so
            // markers in not-yet-finalized drafts show up as playable instead
            // of stuck "Processing…" (B4).
            segmentFile = filenameIndex[segmentFilename];
            if (segmentFile == null) {
              // Fall back: maybe the draft was finalized to a non-draft name.
              if (segmentFilename.contains('_draft.')) {
                final finalizedName = segmentFilename.replaceAll('_draft.', '.');
                segmentFile = filenameIndex[finalizedName];
              } else {
                // Or vice-versa: file is still a draft on disk.
                final draftName = segmentFilename.replaceAllMapped(RegExp(r'\.(m4a|wav|ogg)$'), (m) => '_draft${m[0]}');
                segmentFile = filenameIndex[draftName];
              }
            }
          }

          // Clamp cropEnd to the segment's actual encoded duration. Pre-0.12.0
          // EDLs stored wall-clock chunk duration which can exceed the playable
          // file length when frames were silently dropped during decode. The
          // in-memory MC always gets the clamped value; if the on-disk EDL
          // was over the encoded duration AND not user-saved (no risk of
          // overwriting user crop intent), persist the clamp back to disk
          // so the next load doesn't re-clamp (B9).
          int cropEndMs = json['cropEndMs'] as int? ?? 0;
          if (segmentFile != null) {
            try {
              final base = segmentFile.path.substring(0, segmentFile.path.lastIndexOf('.'));
              final metaBytes = await File('$base.meta').readAsBytes();
              if (metaBytes.length >= 8) {
                final encodedMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
                if (encodedMs > 0 && (cropEndMs == 0 || cropEndMs > encodedMs)) {
                  final originalOnDisk = cropEndMs;
                  cropEndMs = encodedMs;
                  final userSaved = json['userSaved'] as bool? ?? false;
                  if (!userSaved && originalOnDisk > encodedMs) {
                    json['cropEndMs'] = encodedMs;
                    try {
                      await _writeJsonAtomic(edlFile, json);
                      Logger.debug(
                          'RecordingsManager: Migrated EDL ${edlFile.path.split('/').last} cropEndMs ${originalOnDisk}→$encodedMs');
                    } catch (e) {
                      Logger.error('RecordingsManager: cropEnd migration write failed: $e');
                    }
                  }
                }
              }
            } catch (_) {}
          }

          allConversations.add(MarkerConversation(
            markerTime: DateTime.fromMillisecondsSinceEpoch(markerMs),
            segment: segmentFile,
            markerOffsetMs: json['markerOffsetMs'] as int? ?? 0,
            cropStartMs: json['cropStartMs'] as int? ?? 0,
            cropEndMs: cropEndMs,
            edlFile: edlFile,
            userSaved: json['userSaved'] as bool? ?? false,
          ));
        } catch (e) {
          Logger.error('RecordingsManager: Failed to parse EDL ${edlFile.path}: $e');
        }
      }
    }

    // Step 2: Group EDLs by exact markerMs and pick one canonical per ms.
    // Two physical button taps cannot share a UTC ms (firmware ms resolution,
    // taps take much longer than 1 ms), so any group of >1 here is a bug or
    // legacy data — pick the preferred (userSaved > non-pending > earliest
    // basename) and warn on the rest so testing surfaces them in logs.
    final Map<int, List<MarkerConversation>> byMs = {};
    for (final mc in allConversations) {
      byMs.putIfAbsent(mc.markerTime.millisecondsSinceEpoch, () => []).add(mc);
    }
    final List<MarkerConversation> deduped = [];
    for (final group in byMs.values) {
      if (group.length == 1) {
        deduped.add(group.first);
        continue;
      }
      group.sort((a, b) {
        final saveCmp = (b.userSaved ? 1 : 0) - (a.userSaved ? 1 : 0);
        if (saveCmp != 0) return saveCmp;
        final pendCmp = (a.isPending ? 1 : 0) - (b.isPending ? 1 : 0);
        if (pendCmp != 0) return pendCmp;
        return a.edlFile.path.split('/').last.compareTo(b.edlFile.path.split('/').last);
      });
      deduped.add(group[0]);
      Logger.error(
          'RecordingsManager: ${group.length} EDLs at markerMs=${group[0].markerTime.millisecondsSinceEpoch} — keeping ${group[0].edlFile.path.split('/').last}, dropping ${group.skip(1).map((m) => m.edlFile.path.split('/').last).join(", ")}');
    }

    deduped.sort((a, b) => b.markerTime.compareTo(a.markerTime));
    return deduped;
  }

  /// Derives the date-folder name (YYYY-MM-DD) from epoch milliseconds.
  ///
  /// **Convention**: all date folders use the *local* timezone so that
  /// recordings appear under the date the user experienced them.  Session IDs
  /// and device markers use UTC internally, but folder placement is always
  /// local.  A recording that starts before midnight local time and ends after
  /// midnight is placed under the *start* date.
  static String _dateStringFromMillis(int millis) => fmtDate(DateTime.fromMillisecondsSinceEpoch(millis).toLocal());

  /// Background auto-process: processes all batches as one continuous stream.
  /// Skips the newest segment per DeviceSession (may still be written by firmware).
  /// Safe to call from a background timer; no-op if a marker process is running.
  static Future<void> processAllCompletedSessions() async {
    if (_isProcessingAny) return;
    // Idempotency guard: drop any bins whose audio is already covered by an
    // existing recording on disk. Catches the kill-mid-cleanup case where a
    // previous run wrote the .wav but didn't get to delete its source bins
    // (the bug that produces near-duplicate recordings 0.5s apart).
    await pruneConsumedBins();
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    // Always-on idempotency guard: skip bins already fully covered by an existing
    // recording so a re-VAD can't mint a near-duplicate. Cheap here — pruneConsumedBins
    // (above) already deleted covered bins on the normal path, so the set is usually
    // empty; this acts as a final safety check.
    final Set<String> covered = await coveredBinPaths(batches.expand((b) => b.rawSegments).toList());
    final processableBatches = covered.isEmpty
        ? batches
        : batches.map((b) {
            final filtered = b.rawSegments.where((f) => !covered.contains(f.path)).toList();
            if (filtered.length == b.rawSegments.length) return b;
            return Batch(
              dateString: b.dateString,
              date: b.date,
              rawSegments: filtered,
              draftRecordings: b.draftRecordings,
              finalizedRecordings: b.finalizedRecordings,
              markerTimestamps: b.markerTimestamps,
              discards: b.discards,
            );
          }).toList();
    final activeBatches = processableBatches.where((b) => b.rawSegments.isNotEmpty).toList();
    if (activeBatches.isEmpty) return;
    try {
      await manager.processAll(activeBatches, (_, __) {}, backgroundMode: true);
    } catch (e) {
      Logger.error(
        'RecordingsManager: Background processAllCompletedSessions error: $e',
      );
    }
  }

  /// Force-process all batches including the newest segment per DeviceSession.
  /// Used by the debug Force Process button — same as pressing the Process button
  /// on each batch but operates across all days at once.
  /// No-op if a process is already running.
  static Future<void> forceProcessAll() async {
    if (_isProcessingAny) return;
    // Same idempotency guard as processAllCompletedSessions — see that method.
    await pruneConsumedBins();
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    final activeBatches = batches.where((b) => b.rawSegments.isNotEmpty || b.draftRecordings.isNotEmpty).toList();
    if (activeBatches.isEmpty) return;
    try {
      await manager.processAll(
        activeBatches,
        (_, __) {},
        backgroundMode: false,
        finalizeDrafts: true,
      );
    } catch (e) {
      Logger.error('RecordingsManager: forceProcessAll error: $e');
    }
  }

  /// Deletes orphaned `.tmp.m4a` files left by interrupted encoding runs.
  /// Call once at app startup before processing begins.
  static Future<void> cleanupOrphanedTempFiles() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;
    await for (final entity in recordingsDir.list(recursive: true)) {
      if (entity is File && (entity.path.endsWith('.tmp.m4a') || entity.path.endsWith('.ogg.tmp'))) {
        try {
          await entity.delete();
          Logger.debug(
            'RecordingsManager: Deleted orphaned temp file ${entity.path}',
          );
        } catch (e) {
          Logger.error(
            'RecordingsManager: Failed to delete orphaned temp file ${entity.path}: $e',
          );
        }
      }
    }
  }

  /// Deletes a single processed conversation and its associated meta/bin files.
  static Future<void> deleteConversation(Conversation conversation) async {
    await deleteConversations([conversation]);
  }

  /// Deletes multiple processed conversations and their associated meta/bin/marker files.
  /// Efficiently groups by directory to minimize directory listings for EDL cleanup.
  static Future<void> deleteConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) return;

    // Group conversations by directory to minimize directory listings for EDL cleanup
    final Map<String, List<Conversation>> byDir = {};
    for (final c in conversations) {
      final dir = c.file.parent.path;
      byDir.putIfAbsent(dir, () => []).add(c);
    }

    for (final dirPath in byDir.keys) {
      final convsInDir = byDir[dirPath]!;
      final filenames = convsInDir.map((c) => c.file.path.split('/').last).toSet();

      // 1. Delete audio, meta, bin files. Batch the SharedPreferences write so we
      // pay one disk sync instead of one per conversation, and run the per-conversation
      // file deletes concurrently (each touches disjoint paths).
      final keysToRemove = convsInDir.map((c) => c.uploadKey).whereType<String>().toSet();
      if (keysToRemove.isNotEmpty) {
        await SharedPreferencesUtil().removeUploadedFromHeypocket(keysToRemove);
      }
      await Future.wait(convsInDir.map((c) async {
        final file = c.file;
        // Drop the exists() probe and let delete() fail-soft — one syscall per file instead of two.
        try {
          await file.delete();
        } on FileSystemException catch (_) {}
        final metaPath = '${file.path.substring(0, file.path.lastIndexOf('.'))}.meta';
        final metaFile = File(metaPath);
        try {
          await metaFile.delete();
        } on FileSystemException catch (_) {}
        try {
          final ts = file.path.split('/').last.split('_').last.split('.').first;
          final binPath = '${file.parent.path}/recording_fs320_$ts.bin';
          final binFile = File(binPath);
          try {
            await binFile.delete();
          } on FileSystemException catch (_) {}
        } catch (_) {}
      }));

      // 2. Delete EDL files for all deleted conversations in this directory at once.
      // Reads + deletes run concurrently — each EDL is an independent JSON sidecar.
      try {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          final dirEntities = await dir.list().toList();
          await Future.wait(dirEntities.map((entity) async {
            if (entity is! File || !entity.path.endsWith('.edl')) return;
            try {
              final json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
              if (filenames.contains(json['segmentFilename'])) {
                await entity.delete();
              }
            } catch (_) {}
          }));
        }
      } catch (e) {
        Logger.error('RecordingsManager: Failed to cleanup EDLs in $dirPath: $e');
      }
    }
  }

  /// Deletes a marker conversation.
  static Future<void> deleteMarkerConversation(MarkerConversation mc) async {
    if (await mc.edlFile.exists()) {
      await mc.edlFile.delete();
      Logger.debug('RecordingsManager: Deleted marker conversation ${mc.edlFile.path}');
    }
  }

  /// Deletes processed recordings (.m4a/.wav/.meta/.bin) for a day.

  /// Safe to call while nothing is playing.
  Future<void> deleteDay(Batch batch) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory(
      '${directory.path}/recordings/${batch.dateString}',
    );

    // Drop discard records for this day. In the full-delete path, also delete
    // the referenced raw bins so they can't resurrect deleted recordings on the
    // next sync.
    for (final d in batch.discards) {
      await removeDiscardRecord(d, deleteBins: true);
    }

    // Wipe the day's raw .bin segments too, bypassing the 48h discard hold.
    // Without this, the next sync silently reprocesses them and resurrects
    // the recordings the user just deleted.
    final touchedSessionDirs = <Directory>{};
    int deletedBins = 0;
    for (final bin in batch.rawSegments) {
      try {
        if (await bin.exists()) {
          await bin.delete();
          deletedBins++;
        }
        touchedSessionDirs.add(bin.parent);
      } catch (e) {
        Logger.error('RecordingsManager: deleteDay failed to delete bin ${bin.path}: $e');
      }
    }
    for (final dir in touchedSessionDirs) {
      try {
        if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
      } catch (_) {}
    }
    if (deletedBins > 0) {
      Logger.debug(
        'RecordingsManager: Deleted $deletedBins raw bins for ${batch.dateString}',
      );
    }

    if (await recordingsDir.exists()) {
      await recordingsDir.delete(recursive: true);
      Logger.debug(
        'RecordingsManager: Deleted processed recordings for ${batch.dateString}',
      );
    }
  }

  /// Batch-updates the starting timestamp for an entire hardware session.
  ///
  /// This renames and moves all processed recordings, .meta sidecars, .bin raw syncs,
  /// and .edl markers belonging to the same sessionId.
  static Future<void> promoteSessionToDate(Conversation base, DateTime newStartTime) async {
    final sessionId = base.sessionId;
    final startUptime = base.startUptime;
    if (startUptime == null || startUptime == 0) {
      throw Exception('Cannot promote session: startUptime is missing or zero.');
    }

    final rtcOffsetMs = newStartTime.millisecondsSinceEpoch - (startUptime * 1000);
    final directory = await getApplicationDocumentsDirectory();

    // 1. Identify all affected finalized recordings across all date folders.
    final List<Conversation> sessionConversations = [];
    final recordingsDir = Directory('${directory.path}/recordings');
    if (await recordingsDir.exists()) {
      final dateFolders = (await recordingsDir.list().toList()).whereType<Directory>().toList();
      for (final folder in dateFolders) {
        final audioFiles = await folder
            .list()
            .where((e) => e is File && (e.path.endsWith('.m4a') || e.path.endsWith('.wav') || e.path.endsWith('.ogg')))
            .cast<File>()
            .toList();

        for (final file in audioFiles) {
          final conv = Conversation.fromFile(file);
          if (conv.sessionId == sessionId && sessionId != null) {
            sessionConversations.add(conv);
          } else if (file.path == base.file.path) {
            // Fallback for single-file promotion if sessionId is missing
            sessionConversations.add(conv);
          }
        }
      }
    }

    // 2. Perform renames and moves for processed recordings
    for (final conv in sessionConversations) {
      final convUptime = conv.startUptime ?? (conv.startTime.millisecondsSinceEpoch ~/ 1000);
      final newConvStartMs = (convUptime * 1000) + rtcOffsetMs;
      final newDateStr = _dateStringFromMillis(newConvStartMs);
      final targetDir = Directory('${directory.path}/recordings/$newDateStr');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final extension = conv.file.path.split('.').last;
      final newAudioPath = '${targetDir.path}/recording_$newConvStartMs.$extension';
      final newMetaPath = '${targetDir.path}/recording_$newConvStartMs.meta';

      final basePath = conv.file.path.substring(0, conv.file.path.lastIndexOf('.'));
      final metaFile = File('$basePath.meta');

      // Update .meta content with new UTC time if we were to be super thorough,
      // but fromFile relies on filename timestamp, so renaming the file is enough.

      if (await metaFile.exists()) await metaFile.rename(newMetaPath);
      await conv.file.rename(newAudioPath);

      // Handle legacy .bin sidecar if present
      final oldBinPath = '$basePath.bin';
      if (await File(oldBinPath).exists()) {
        final newBinPath = '${targetDir.path}/recording_$newConvStartMs.bin';
        await File(oldBinPath).rename(newBinPath);
      }

      // 3. Move and update .edl markers in the same date folder
      final parentDir = conv.file.parent;
      final markerFiles = await parentDir
          .list()
          .where((e) => e is File && e.path.split('/').last.startsWith('marker_') && e.path.endsWith('.edl'))
          .cast<File>()
          .toList();

      for (final edlFile in markerFiles) {
        try {
          final content = await edlFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final segmentFilename = json['segmentFilename'] as String?;
          if (segmentFilename == conv.file.path.split('/').last) {
            final oldMarkerMs = json['markerTimestampMs'] as int;
            // Marker uptime = oldMarkerMs (since it was Dec 1969/Jan 1970)
            final newMarkerMs = oldMarkerMs + rtcOffsetMs;

            final updatedJson = Map<String, dynamic>.from(json);
            updatedJson['markerTimestampMs'] = newMarkerMs;
            updatedJson['segmentFilename'] = newAudioPath.split('/').last;

            await edlFile.delete(); // Delete old EDL
            final newEdlFile = File('${targetDir.path}/marker_$newMarkerMs.edl');
            await newEdlFile.writeAsString(jsonEncode(updatedJson));
          }
        } catch (e) {
          Logger.error('RecordingsManager: Failed to migrate EDL ${edlFile.path}: $e');
        }
      }
    }

    // 4. Handle raw_segments folder migration
    final rawSegmentsDir = Directory('${directory.path}/raw_segments');
    if (await rawSegmentsDir.exists()) {
      final sessionFolderName = sessionId != null ? 'session_$sessionId' : null;
      final baseUptime = base.startUptime ?? 0;
      final oldUnknownFolderName = 'unknown_$baseUptime';

      Directory? sourceFolder;
      if (sessionFolderName != null) {
        final dir = Directory('${rawSegmentsDir.path}/$sessionFolderName');
        if (await dir.exists()) sourceFolder = dir;
      }
      if (sourceFolder == null) {
        final dir = Directory('${rawSegmentsDir.path}/$oldUnknownFolderName');
        if (await dir.exists()) sourceFolder = dir;
      }

      if (sourceFolder != null) {
        final newBaseStartMs = baseUptime + rtcOffsetMs;
        final targetFolder = Directory('${rawSegmentsDir.path}/$newBaseStartMs');

        if (await targetFolder.exists()) {
          // Merge contents if target already exists (unlikely but safe)
          await for (final entity in sourceFolder.list()) {
            if (entity is File) {
              await entity.rename('${targetFolder.path}/${entity.path.split('/').last}');
            }
          }
          await sourceFolder.delete(recursive: true);
        } else {
          await sourceFolder.rename(targetFolder.path);
        }

        // 5. Update .bin filenames in the promoted raw folder to match new UTC base
        // Format: {uptime}_{sessionId}.bin -> {newUtc}_{sessionId}.bin
        await for (final entity in targetFolder.list()) {
          if (entity is File && entity.path.endsWith('.bin')) {
            final name = entity.path.split('/').last;
            final parts = name.split('_');
            final uptime = int.tryParse(parts[0]) ?? 0;
            if (uptime < 946684800000) {
              final newUtc = uptime + rtcOffsetMs;
              final sid = parts.length > 1 ? parts[1] : '0.bin';
              final newName = '${newUtc}_$sid';
              await entity.rename('${targetFolder.path}/$newName');
            }
          }
        }
      }
    }

    notifyRecordingsChanged();
  }

  /// How long to retain raw bins for a noise/short discard before the recovery
  /// sweep reclaims them.
  static const Duration discardRetentionWindow = Duration(hours: 48);

  /// Consecutive discard records whose inter-record gap is within this tolerance
  /// are coalesced into a single entry by [getDiscardsForDate], so a long
  /// ambient-noise period surfaces as one row instead of dozens of back-to-back
  /// ~2-minute ghosts. Back-to-back chunks abut at ~0 gap (the next conversation
  /// is re-anchored to the frame right after a silence split); this window only
  /// needs to absorb RTC drift / inter-file rounding. It is far below the
  /// multi-minute gap a real saved recording or a device-idle (AAD-sleep) period
  /// introduces, so genuinely separate noise periods stay separate.
  static const Duration discardMergeGap = Duration(seconds: 30);

  /// Appends one JSONL record to `recordings/<date>/discards.jsonl`. The date
  /// folder is derived from the record's startMs in local time.
  static Future<void> _persistDiscardRecord(String docsPath, Map<String, dynamic> rec) async {
    final dateStr = _dateStringFromMillis(rec['startMs'] as int);
    final dir = Directory('$docsPath/recordings/$dateStr');
    await dir.create(recursive: true);
    final file = File('${dir.path}/discards.jsonl');
    await file.writeAsString('${jsonEncode(rec)}\n', mode: FileMode.append, flush: true);
  }

  /// Walks all `recordings/<date>/discards.jsonl` files and returns parsed
  /// records grouped by their containing file. Malformed lines are skipped.
  static Future<List<({File jsonl, List<Map<String, dynamic>> records})>> _readAllDiscardRecords() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return const [];
    final out = <({File jsonl, List<Map<String, dynamic>> records})>[];
    await for (final dayDir in recordingsDir.list()) {
      if (dayDir is! Directory) continue;
      final jsonl = File('${dayDir.path}/discards.jsonl');
      if (!await jsonl.exists()) continue;
      final records = <Map<String, dynamic>>[];
      for (final line in (await jsonl.readAsString()).split('\n')) {
        if (line.isEmpty) continue;
        try {
          records.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (e) {
          Logger.error('RecordingsManager: Skipping malformed discard line in ${jsonl.path}: $e');
        }
      }
      out.add((jsonl: jsonl, records: records));
    }
    return out;
  }

  /// Relative bin paths (`<session>/<file>.bin` tail) that already have a
  /// persisted discard record and are therefore NOT awaiting processing —
  /// shared by [processAll]'s reprocess-strip and the "minutes to process"
  /// estimate so the two never disagree.
  ///
  /// Reads the FULL persisted set rather than per-batch discards: a record is
  /// filed under its conversation's local-date folder, which routinely differs
  /// from the bin's own raw-segment batch (raw batches are keyed off the bin
  /// filename's timestamp, and callers pre-filter to rawSegments-bearing days),
  /// so a per-batch derivation drops cross-date records and the bins re-run VAD
  /// every sync cycle (inflating "minutes to process", never finalizing).
  /// `silence_trimmed` is excluded — recording-adjacent trailing silence that
  /// is not a reprocess guard. No longer generated since the June 2026 change
  /// that keeps trailing silence in the recording, but legacy discards.jsonl
  /// files may still contain it, so the guard stays for backward compatibility.
  ///
  static Future<Set<String>> discardedRelBinPaths() async {
    final out = <String>{};
    for (final group in await _readAllDiscardRecords()) {
      for (final rec in group.records) {
        if (rec['reason'] == 'silence_trimmed') continue;
        final bins = rec['relativeBins'];
        if (bins is List) out.addAll(bins.cast<String>());
      }
    }
    return out;
  }

  /// Parses `recordings/<dateString>/discards.jsonl` into [DiscardRecord]s.
  /// Returns an empty list if the file does not exist. Malformed lines are
  /// skipped with a warning.
  static Future<List<DiscardRecord>> getDiscardsForDate(String dateString) async {
    final directory = await getApplicationDocumentsDirectory();
    final jsonl = File('${directory.path}/recordings/$dateString/discards.jsonl');
    if (!await jsonl.exists()) return const [];
    final out = <DiscardRecord>[];
    final seen = <String>{};
    for (final line in (await jsonl.readAsString()).split('\n')) {
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        final rec = DiscardRecord(
          startTime: DateTime.fromMillisecondsSinceEpoch(m['startMs'] as int),
          endTime: DateTime.fromMillisecondsSinceEpoch(m['endMs'] as int),
          reason: m['reason'] as String,
          maxVoiceProb: (m['maxVoiceProb'] as num).toDouble(),
          relativeBins: (m['relativeBins'] as List).cast<String>(),
          sourceJsonl: jsonl,
        );
        if (rec.reason == 'silence_trimmed') continue;
        if (seen.add(rec.id)) out.add(rec);
      } catch (e) {
        Logger.error('RecordingsManager: skipping malformed discard line in ${jsonl.path}: $e');
      }
    }
    out.sort((a, b) => a.startTime.compareTo(b.startTime));
    return _coalesceDiscards(out);
  }

  /// Merges time-adjacent [DiscardRecord]s (input MUST be sorted by startTime)
  /// so a continuous noise/silence period reads as one entry. The merged record
  /// spans `[first.start, max(end)]`, unions the referenced bins, keeps the
  /// highest `maxVoiceProb`, and reports a noise reason if any constituent was
  /// noise (so the UI's noise-vs-too-short label stays accurate for the common
  /// ambient-noise case). Two records merge when the later one starts within
  /// [discardMergeGap] of the running end — overlaps included.
  static List<DiscardRecord> _coalesceDiscards(List<DiscardRecord> sorted) {
    if (sorted.length < 2) return sorted;
    final merged = <DiscardRecord>[];

    DateTime start = sorted.first.startTime;
    DateTime end = sorted.first.endTime;
    double maxProb = sorted.first.maxVoiceProb;
    final bins = <String>{...sorted.first.relativeBins};
    String reason = sorted.first.reason;
    bool noise = sorted.first.isNoise;
    File src = sorted.first.sourceJsonl;

    DiscardRecord build() => DiscardRecord(
          startTime: start,
          endTime: end,
          reason: reason,
          maxVoiceProb: maxProb,
          relativeBins: bins.toList()..sort(),
          sourceJsonl: src,
        );

    for (var i = 1; i < sorted.length; i++) {
      final r = sorted[i];
      if (r.startTime.difference(end) <= discardMergeGap) {
        if (r.endTime.isAfter(end)) end = r.endTime;
        if (r.maxVoiceProb > maxProb) maxProb = r.maxVoiceProb;
        bins.addAll(r.relativeBins);
        if (!noise && r.isNoise) {
          noise = true;
          reason = r.reason;
        }
      } else {
        merged.add(build());
        start = r.startTime;
        end = r.endTime;
        maxProb = r.maxVoiceProb;
        bins
          ..clear()
          ..addAll(r.relativeBins);
        reason = r.reason;
        noise = r.isNoise;
        src = r.sourceJsonl;
      }
    }
    merged.add(build());
    return merged;
  }

  /// Deletes a discard record (and optionally its referenced bins) atomically.
  /// Rewrites the source jsonl with all other records preserved. If the jsonl
  /// becomes empty it is removed.
  static Future<void> removeDiscardRecord(DiscardRecord d, {required bool deleteBins}) async {
    final directory = await getApplicationDocumentsDirectory();
    if (deleteBins) {
      for (final rel in d.relativeBins) {
        final binFile = File('${directory.path}/raw_segments/$rel');
        if (await binFile.exists()) {
          try {
            await binFile.delete();
          } catch (e) {
            Logger.error('RecordingsManager: removeDiscardRecord delete bin failed: $e');
          }
          final folder = binFile.parent;
          if (await folder.exists()) {
            try {
              if (await folder.list().isEmpty) await folder.delete();
            } catch (_) {}
          }
        }
      }
    }
    if (!await d.sourceJsonl.exists()) return;
    final keep = <String>[];
    final targetMs = d.startTime.millisecondsSinceEpoch;
    final targetEndMs = d.endTime.millisecondsSinceEpoch;
    for (final line in (await d.sourceJsonl.readAsString()).split('\n')) {
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        // Range match (not exact equality): a record surfaced by
        // getDiscardsForDate may be a coalesced span covering several jsonl
        // lines. Drop every constituent line whose [startMs,endMs] falls within
        // the (possibly merged) target span. A non-merged record matches exactly,
        // so this stays correct for single records too.
        final s = m['startMs'] as int;
        final e = m['endMs'] as int;
        if (s >= targetMs && e <= targetEndMs) continue;
      } catch (_) {
        // Keep malformed lines so we don't quietly destroy data we couldn't parse.
        keep.add(line);
        continue;
      }
      keep.add(line);
    }
    if (keep.isEmpty) {
      try {
        await d.sourceJsonl.delete();
      } catch (_) {}
    } else {
      await d.sourceJsonl.writeAsString('${keep.join('\n')}\n', flush: true);
    }
  }

  /// Returns absolute bin paths that are still protected by an in-window
  /// discard record. Used by AM-off cleanup to skip these files.
  static Future<Set<String>> activeDiscardProtectedPaths() async {
    final directory = await getApplicationDocumentsDirectory();
    final cutoffMs = DateTime.now().subtract(discardRetentionWindow).millisecondsSinceEpoch;
    final protected = <String>{};
    for (final group in await _readAllDiscardRecords()) {
      for (final rec in group.records) {
        if ((rec['endMs'] as int) < cutoffMs) continue;
        for (final rel in (rec['relativeBins'] as List).cast<String>()) {
          protected.add('${directory.path}/raw_segments/$rel');
        }
      }
    }
    return protected;
  }

  /// Reclaims expired discard records and their referenced bins. No-op when
  /// processing run is already in flight (to avoid racing the per-segment
  /// delete handler). Bins still claimed by any in-window record across any
  /// day's jsonl are preserved.
  static Future<void> runRecoverySweep() async {
    if (_isProcessingAny) return;
    final directory = await getApplicationDocumentsDirectory();
    final cutoffMs = DateTime.now().subtract(discardRetentionWindow).millisecondsSinceEpoch;

    final groups = await _readAllDiscardRecords();

    // First pass: collect every bin still protected by an in-window record,
    // across all day-jsonl files. An expired record's bin must not be deleted
    // if another active record (possibly in a different day file) references it.
    final globallyProtected = <String>{};
    for (final group in groups) {
      for (final rec in group.records) {
        if ((rec['endMs'] as int) < cutoffMs) continue;
        for (final rel in (rec['relativeBins'] as List).cast<String>()) {
          globallyProtected.add('${directory.path}/raw_segments/$rel');
        }
      }
    }

    for (final group in groups) {
      final activeRecords = <Map<String, dynamic>>[];
      final candidateDeletes = <String>{};
      for (final rec in group.records) {
        if ((rec['endMs'] as int) < cutoffMs) {
          for (final rel in (rec['relativeBins'] as List).cast<String>()) {
            candidateDeletes.add('${directory.path}/raw_segments/$rel');
          }
        } else {
          activeRecords.add(rec);
        }
      }
      candidateDeletes.removeAll(globallyProtected);
      for (final path in candidateDeletes) {
        final f = File(path);
        if (!await f.exists()) continue;
        try {
          await f.delete();
          Logger.debug('RecordingsManager: RecoverySweep deleted expired bin $path');
        } catch (e) {
          Logger.error('RecordingsManager: RecoverySweep failed to delete $path: $e');
        }
      }
      if (activeRecords.isEmpty) {
        try {
          await group.jsonl.delete();
        } catch (_) {}
      } else if (activeRecords.length != group.records.length) {
        await group.jsonl.writeAsString('${activeRecords.map(jsonEncode).join('\n')}\n', flush: true);
      }
    }

    // Drop any now-empty raw_segments/<session>/ folders.
    final rawDir = Directory('${directory.path}/raw_segments');
    if (await rawDir.exists()) {
      await for (final entity in rawDir.list()) {
        if (entity is! Directory) continue;
        try {
          if (await entity.list().isEmpty) await entity.delete();
        } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Coverage helpers — shared by pruneConsumedBins (normal mode, deletes) and
  // coveredBinPaths (read-only filter before the VAD run).
  // ---------------------------------------------------------------------------

  /// Builds merged `[startMs, endMs]` coverage intervals from every recording
  /// (finalized + drafts) on disk. See [pruneConsumedBins] for the coverage rule.
  static Future<List<List<int>>> _buildMergedCoverageIntervals() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return [];

    const int leftSlackMs = 10 * 60 * 1000;
    final int silenceSlackMs = SharedPreferencesUtil().vadSplitSeconds * 1000;

    final List<List<int>> intervals = [];
    await for (final dayFolder in recordingsDir.list()) {
      if (dayFolder is! Directory) continue;
      await for (final entity in dayFolder.list()) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!(path.endsWith('.wav') || path.endsWith('.m4a') || path.endsWith('.ogg'))) continue;
        if (path.endsWith('.tmp.m4a') || path.contains('.tmp.')) continue;
        final isDraft = path.contains('_draft.');
        final conv = Conversation.fromFile(entity);
        if (conv.isUnknown) continue;
        final recStartMs = conv.startTime.millisecondsSinceEpoch;
        if (recStartMs <= 0) continue;
        final recEndMs = recStartMs + conv.duration.inMilliseconds;
        final rightEdge = (conv.capEnded || isDraft) ? recEndMs : recEndMs + silenceSlackMs;
        intervals.add([recStartMs - leftSlackMs, rightEdge]);
      }
    }
    if (intervals.isEmpty) return [];

    intervals.sort((a, b) => a[0].compareTo(b[0]));
    final List<List<int>> merged = [intervals.first];
    for (int i = 1; i < intervals.length; i++) {
      final last = merged.last;
      final cur = intervals[i];
      if (cur[0] <= last[1]) {
        if (cur[1] > last[1]) last[1] = cur[1];
      } else {
        merged.add(cur);
      }
    }
    return merged;
  }

  /// Returns the subset of [candidates] whose `[binStart, binEnd]` is fully
  /// covered by an existing recording. Does not delete anything — used in
  /// skip bins that already have a recording.
  static Future<Set<String>> coveredBinPaths(List<File> candidates) async {
    if (candidates.isEmpty) return const {};
    final merged = await _buildMergedCoverageIntervals();
    if (merged.isEmpty) return const {};

    const double opusBytesPerMs = 4050 / 1000;
    const int binHeaderBytes = 36;

    final covered = <String>{};
    for (final bin in candidates) {
      final folderName = p.basename(bin.parent.path);
      if (folderName.startsWith('session_') || folderName.startsWith('unknown_') || folderName.startsWith('.'))
        continue;
      final binName = p.basename(bin.path);
      final parts = binName.split('.').first.split('_');
      if (parts.isEmpty) continue;
      final timerStart = int.tryParse(parts.first);
      if (timerStart == null || timerStart < 946684800) continue;
      int binSize;
      try {
        binSize = await bin.length();
      } catch (_) {
        continue;
      }
      if (binSize <= binHeaderBytes) continue;
      final binStartMs = timerStart * 1000;
      final binDurationMs = (((binSize - binHeaderBytes) / opusBytesPerMs)).ceil();
      final binEndMs = binStartMs + binDurationMs;
      for (final iv in merged) {
        if (binStartMs >= iv[0] && binEndMs <= iv[1]) {
          covered.add(bin.path);
          break;
        }
      }
    }
    return covered;
  }

  /// Deletes raw .bin segments whose wall-clock window is already fully covered
  /// by an existing recording. Idempotency guard against the mid-processing kill
  /// path where VAD wrote a `recording_<ts>.wav` but the app was killed (e.g. by
  /// an APK update) before the `delete_segments` IPC ran. Without this guard,
  /// the leftover bins re-VAD on next launch and produce a near-duplicate .wav
  /// with a slightly different VAD cut.
  ///
  /// Coverage rule per recording (finalized + drafts):
  ///   left edge  = recStart - FILE_ROTATION_INTERVAL_MS (a bin's leading silence
  ///                may have been trimmed by VAD; the bin can start up to one full
  ///                firmware rotation interval before the first detected speech)
  ///   right edge = capEnded ? recEnd                       (cap-ended: anything
  ///                                                         past rec_end is
  ///                                                         un-consumed audio)
  ///              : recEnd + vadSplitSeconds * 1000ms       (silence-ended: VAD
  ///                                                         observed this much
  ///                                                         silence past rec_end,
  ///                                                         so bin tail there is
  ///                                                         provably silence)
  ///
  /// Per-day coverage intervals are then merged (overlapping intervals collapse)
  /// so a bin spanning two back-to-back recordings is recognized as fully covered.
  ///
  /// A bin is deleted iff [binStart, binEnd] sits fully inside ONE merged
  /// coverage interval. Bins that extend past the right edge are preserved
  /// (this covers the cap-end case for the user's hour-long meeting recordings).
  ///
  /// use [coveredBinPaths] to skip them without deleting.
  ///
  /// Returns the number of bins deleted.
  static Future<int> pruneConsumedBins() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawDir = Directory('${directory.path}/raw_segments');
    if (!await rawDir.exists()) return 0;

    final merged = await _buildMergedCoverageIntervals();
    if (merged.isEmpty) return 0;

    // Opus on SD averages 81 B/frame × 50 fps. Used to derive bin duration
    // from file size (sufficient for overlap math — exact frame walk is overkill).
    const double opusBytesPerMs = 4050 / 1000;
    // Bin file metadata header: 0xFFFFFFFB marker + 4-byte length + 28-byte payload.
    const int binHeaderBytes = 36;

    int deletedCount = 0;
    final touchedFolders = <Directory>{};
    await for (final folder in rawDir.list()) {
      if (folder is! Directory) continue;
      final folderName = p.basename(folder.path);
      // session_<hex>/ holds pre-time-sync bins (uptime ticks, not UTC) — we
      // can't derive a wall-clock window for them, so leave them alone.
      if (folderName.startsWith('session_') || folderName.startsWith('unknown_') || folderName.startsWith('.')) {
        continue;
      }
      await for (final binEntity in folder.list()) {
        if (binEntity is! File || !binEntity.path.endsWith('.bin')) continue;
        final binName = p.basename(binEntity.path);
        final parts = binName.split('.').first.split('_');
        if (parts.isEmpty) continue;
        final timerStart = int.tryParse(parts.first);
        // 946684800 = 2000-01-01 epoch sec; smaller values are uptime ticks
        if (timerStart == null || timerStart < 946684800) continue;
        int binSize;
        try {
          binSize = await binEntity.length();
        } catch (_) {
          continue;
        }
        if (binSize <= binHeaderBytes) continue;
        final binStartMs = timerStart * 1000;
        // Use ceil so the bin-end estimate slightly overshoots — keeps the
        // "fully inside" check conservative (a bin we can't be 100% sure is
        // covered will survive).
        final binDurationMs = (((binSize - binHeaderBytes) / opusBytesPerMs)).ceil();
        final binEndMs = binStartMs + binDurationMs;

        bool covered = false;
        for (final iv in merged) {
          if (binStartMs >= iv[0] && binEndMs <= iv[1]) {
            covered = true;
            break;
          }
        }
        if (!covered) continue;

        try {
          await binEntity.delete();
          deletedCount++;
          touchedFolders.add(folder);
          Logger.debug('RecordingsManager: pruneConsumedBins deleted $binName (covered by recording window)');
        } catch (e) {
          Logger.error('RecordingsManager: pruneConsumedBins failed to delete ${binEntity.path}: $e');
        }
      }
    }

    // Drop any session folders that just emptied — keeps raw_segments/ tidy.
    for (final folder in touchedFolders) {
      try {
        if (await folder.exists() && await folder.list().isEmpty) {
          await folder.delete();
        }
      } catch (_) {}
    }

    return deletedCount;
  }

  /// Deletes raw .bin segments belonging to any of [sessionIds], bypassing the
  /// 48h discard hold. Used after deleting conversations from a tab so an
  /// emptied session does not silently reprocess on the next sync.
  static Future<int> deleteBinsForSessions(Set<int> sessionIds) async {
    if (sessionIds.isEmpty) return 0;
    final directory = await getApplicationDocumentsDirectory();
    final rawDir = Directory('${directory.path}/raw_segments');
    if (!await rawDir.exists()) return 0;

    int deleted = 0;
    final touchedFolders = <Directory>{};
    await for (final entity in rawDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      final name = entity.path.split('/').last;
      final parts = name.split('_');
      if (parts.length < 2) continue;
      final sid = int.tryParse(parts[1].split('.').first);
      if (sid == null || !sessionIds.contains(sid)) continue;
      try {
        await entity.delete();
        deleted++;
        touchedFolders.add(entity.parent);
      } catch (e) {
        Logger.error('RecordingsManager: deleteBinsForSessions failed for ${entity.path}: $e');
      }
    }
    for (final dir in touchedFolders) {
      try {
        if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
      } catch (_) {}
    }
    if (deleted > 0) {
      Logger.debug('RecordingsManager: Deleted $deleted bins for orphaned sessions ${sessionIds.toList()}');
    }
    return deleted;
  }

}
