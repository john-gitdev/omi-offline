import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/vad_audio_processor.dart';
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

  const Conversation({
    required this.file,
    required this.startTime,
    required this.duration,
    this.uploadKey,
    this.sessionId,
    this.startUptime,
    this.passthrough = false,
    this.forceSynced = false,
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
    final basePath = file.path.contains('.')
        ? file.path.substring(0, file.path.lastIndexOf('.'))
        : file.path;
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
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                // ⚡ Bolt: Use positional arguments for fromCharCodes to prevent copying memory
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
            }
          }
          // Fall back to filename (without extension) as upload key for recordings
          // processed before the upload key was written to the .meta sidecar.
          final effectiveKey =
              uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
            file: file,
            startTime: startTime,
            duration: Duration(milliseconds: durationMs),
            uploadKey: effectiveKey,
            sessionId: sessionId,
            startUptime: startUptime,
            passthrough: passthrough,
            forceSynced: forceSynced,
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
      if (metaBytes.length >= 417) {
        final keyLen = metaBytes[416];
        if (417 + keyLen <= metaBytes.length) {
          try {
            // ⚡ Bolt: Use positional arguments for fromCharCodes to prevent copying memory
            uploadKey = String.fromCharCodes(metaBytes, 417, 417 + keyLen);
          } catch (_) {}
          final flagOffset = 417 + keyLen;
          if (metaBytes.length > flagOffset) {
            passthrough = (metaBytes[flagOffset] & 0x01) != 0;
          }
          if (metaBytes.length > flagOffset + 1) {
            forceSynced = (metaBytes[flagOffset + 1] & 0x01) != 0;
          }
        }
      }

      if (!passthrough) return null;

      // Reconstruct the virtual audio path from the meta filename.
      final metaName = metaFile.path.split('/').last;
      final baseName = metaName.contains('.')
          ? metaName.substring(0, metaName.lastIndexOf('.'))
          : metaName;
      final virtualAudioFile = File('${metaFile.parent.path}/$baseName.m4a');

      final millisStr = baseName.contains('_')
          ? baseName.split('_').last
          : null;
      final millis = millisStr != null ? int.tryParse(millisStr) : null;
      final startTime = millis != null && millis > 0
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : await metaFile.lastModified();

      return Conversation(
        file: virtualAudioFile,
        startTime: startTime,
        duration: Duration(milliseconds: durationMs),
        uploadKey: uploadKey,
        sessionId: sessionId,
        startUptime: startUptime,
        passthrough: true,
        forceSynced: forceSynced,
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
    final millisStr = name.contains('_')
        ? name.split('_').last.split('.').first
        : null;
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
    final basePath = file.path.contains('.')
        ? file.path.substring(0, file.path.lastIndexOf('.'))
        : file.path;
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
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                // ⚡ Bolt: Use positional arguments for fromCharCodes to prevent copying memory
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
            }
          }
          // Fall back to filename (without extension) as upload key for recordings
          // processed before the upload key was written to the .meta sidecar.
          final effectiveKey =
              uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
            file: file,
            startTime: startTime,
            duration: Duration(milliseconds: durationMs),
            uploadKey: effectiveKey,
            sessionId: sessionId,
            startUptime: startUptime,
            passthrough: passthrough,
            forceSynced: forceSynced,
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
    final inclusiveEnd = duration.inSeconds > 0
        ? end.subtract(const Duration(seconds: 1))
        : end;
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
    if (bytes >= 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
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
  DateTime get expiresAt =>
      endTime.add(RecordingsManager.discardRetentionWindow);
  bool get isNoise => reason.contains('noise');

  /// Stable identity for UI keys/comparisons: source file + startMs + bins hash.
  String get id =>
      '${sourceJsonl.path}:${startTime.millisecondsSinceEpoch}:${relativeBins.join(",")}';
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
  final Uint8List?
  modelBytes; // Silero VAD ONNX model, pre-loaded on main isolate
  final ProcessingSettings settings;
  final String tempProcessingPath;
  final List<String> segmentPaths;
  final List<int> segmentFileSizes; // used for accurate processing ETA
  final List<int> segmentStartTimesMs; // milliseconds since epoch
  final List<int>
  segmentStartUptimesMs; // milliseconds since epoch (raw device uptime)
  final List<int?> segmentSessionIds;
  final List<bool> segmentDerivedFlags;
  final bool backgroundMode;

  const _IsolateParams({
    required this.sendPort,
    required this.rootIsolateToken,
    required this.modelBytes,
    required this.settings,
    required this.tempProcessingPath,
    required this.segmentPaths,
    required this.segmentFileSizes,
    required this.segmentStartTimesMs,
    required this.segmentStartUptimesMs,
    required this.segmentSessionIds,
    required this.segmentDerivedFlags,
    required this.backgroundMode,
  });
}

/// Background isolate entry point for VAD + Opus decode + AAC encode.
/// Runs entirely off the Android main/platform thread, eliminating the
/// ForegroundServiceDidNotStartInTimeException caused by onnxruntime FFI
/// blocking the platform thread during inference.
Future<void> _processingIsolateEntry(_IsolateParams params) async {
  // Allow platform channel calls (AacEncoder MethodChannel, opus_flutter.load()) from this isolate.
  BackgroundIsolateBinaryMessenger.ensureInitialized(params.rootIsolateToken);

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

  // Initialise ONNX Runtime (FFI — safe in any isolate).
  try {
    OrtEnv.instance.init();
  } catch (e) {
    // Non-fatal: AAD mode, all audio treated as speech.
  }

  OrtSession? session;
  if (params.modelBytes != null) {
    try {
      final opts = OrtSessionOptions();
      session = OrtSession.fromBuffer(params.modelBytes!, opts);
    } catch (e) {
      // Amplitude fallback active.
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

  final processor = VadAudioProcessor.fromSettings(
    settings: params.settings,
    outputDir: params.tempProcessingPath,
    session: session,
    decoder: decoder,
  );

  try {
    for (int i = 0; i < params.segmentPaths.length; i++) {
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

      await processor.processSegmentFile(
        file,
        startTime,
        startUptimeMs: startUptimeMs,
        isDerivedTimestamp: isDerived,
        sessionId: sessionId,
      );

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

      // Delete segment files that are fully processed and no longer referenced by any buffer.
      final safeToDelete = processor.consumeSafeToDeletePaths();
      if (safeToDelete.isNotEmpty) {
        params.sendPort.send({
          'type': 'delete_segments',
          'paths': safeToDelete.toList(),
        });
      }

      params.sendPort.send({
        'type': 'progress',
        'processed_bytes': params.segmentFileSizes[i],
        'index': i,
        'total': params.segmentPaths.length,
      });

      if (params.backgroundMode) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

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

    final finalSafe = processor.consumeSafeToDeletePaths();
    if (finalSafe.isNotEmpty) {
      params.sendPort.send({
        'type': 'delete_segments',
        'paths': finalSafe.toList(),
      });
    }

    params.sendPort.send({'type': 'done'});
  } catch (e, st) {
    params.sendPort.send({'type': 'error', 'message': '$e\n$st'});
  } finally {
    processor.destroy();
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

  /// True when a WAV file is being transcoded to M4A.
  static final ValueNotifier<bool> isTranscoding = ValueNotifier(false);

  static bool _cancelRequested = false;
  static SendPort? _activeIsolateControlPort;

  static void cancelProcessing() {
    _cancelRequested = true;
    _activeIsolateControlPort?.send('cancel');
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
        final allEntities = await tempDir
            .list(recursive: true)
            .where((e) => e is File)
            .cast<File>()
            .toList();
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
              !fileName.endsWith('.meta'))
            continue;
          final parts = fileName.split('_');
          var millis = parts.length >= 2
              ? int.tryParse(parts.last.split('.').first)
              : null;
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
      final deviceSessionFolders = deviceSessionEntities
          .whereType<Directory>()
          .toList();

      // Sort session folders by timestamp ID (e.g. "1713892490", "unknown_101", "session_AABBCCDD")
      deviceSessionFolders.sort((a, b) {
        final aName = a.path.split('/').last;
        final bName = b.path.split('/').last;
        final aIdStr = aName
            .replaceFirst('unknown_', '')
            .replaceFirst('session_', '');
        final bIdStr = bName
            .replaceFirst('unknown_', '')
            .replaceFirst('session_', '');

        final aId = aName.startsWith('session_')
            ? int.tryParse(aIdStr, radix: 16)
            : int.tryParse(aIdStr);
        final bId = bName.startsWith('session_')
            ? int.tryParse(bIdStr, radix: 16)
            : int.tryParse(bIdStr);

        return (aId ?? 0).compareTo(bId ?? 0);
      });

      for (var folder in deviceSessionFolders) {
        final deviceSessionIdStr = folder.path.split('/').last;

        // Skip hidden folders or system folders if any
        if (deviceSessionIdStr.startsWith('.')) continue;

        // Process segments
        final folderEntities = await folder.list().toList();
        final files = folderEntities
            .whereType<File>()
            .where((f) => f.path.endsWith('.bin'))
            .toList();

        await Future.wait(
          files.map((file) async {
            DateTime date;
            try {
              final name = file.path.split('/').last;
              final tsStr = name.split('_').first;
              final ts = int.tryParse(tsStr);
              if (ts != null && ts > 0) {
                // If timestamp is uptime (very small), use lastModified as fallback for date grouping.
                if (ts < 1000000000) {
                  date = await file.lastModified();
                } else {
                  // Assume milliseconds
                  date = DateTime.fromMillisecondsSinceEpoch(ts);
                }
              } else {
                date = await file.lastModified();
              }
            } catch (_) {
              date = await file.lastModified();
            }
            rawSegmentsByDate.putIfAbsent(fmtDate(date), () => []).add(file);
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
                  (f.path.endsWith('.m4a') ||
                      f.path.endsWith('.wav') ||
                      f.path.endsWith('.ogg')) &&
                  !f.path.endsWith('.tmp.m4a'),
            )
            .toList();

        final conversations = await Future.wait(
          files.map((f) => Conversation.fromFileAsync(f)),
        );

        // Also pick up passthrough conversations: .meta files with no matching audio file.
        final audioBasenames = files.map((f) {
          final name = f.path.split('/').last;
          return name.contains('.')
              ? name.substring(0, name.lastIndexOf('.'))
              : name;
        }).toSet();
        final metaFiles = folderEntities
            .whereType<File>()
            .where((f) => f.path.endsWith('.meta'))
            .toList();
        final passthroughConvs = <Conversation>[];
        for (final meta in metaFiles) {
          final metaName = meta.path.split('/').last;
          final baseName = metaName.contains('.')
              ? metaName.substring(0, metaName.lastIndexOf('.'))
              : metaName;
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
      final finalized = allConversations
          .where((c) => !c.file.path.contains('_draft.'))
          .toList();
      final drafts = allConversations
          .where((c) => c.file.path.contains('_draft.'))
          .toList();

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
    final activeBatches = batches
        .where((b) => b.rawSegments.isNotEmpty)
        .toList();
    final hasDrafts = batches.any((b) => b.draftRecordings.isNotEmpty);

    if (activeBatches.isEmpty && !(finalizeDrafts && hasDrafts)) return;
    if (_isProcessingAny)
      throw Exception("Another processing task is already in progress.");

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
        final entities =
            folderEntities.whereType<File>().where((f) {
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
            }).toList()..sort((a, b) {
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
            final tsStr = parts.contains('draft')
                ? parts[parts.length - 2]
                : parts.last;
            millis = int.tryParse(tsStr);
          }

          final dateStr = (millis != null && millis > 946684800000)
              ? _dateStringFromMillis(millis)
              : activeBatches.last.dateString;
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          try {
            await File(dest).delete();
          } on FileSystemException catch (_) {}

          // If we are moving a draft, delete any existing finalized version.
          // If we are moving a finalized file, delete any existing draft version.
          // Only do this for audio files to avoid deleting the meta we just moved (since meta comes first).
          final isAudio =
              fileName.endsWith('.m4a') ||
              fileName.endsWith('.wav') ||
              fileName.endsWith('.ogg');
          if (isAudio) {
            try {
              if (fileName.contains('_draft')) {
                await File(dest.replaceAll('_draft', '')).delete();
                await File(
                  dest.replaceAll(RegExp(r'_draft\.(m4a|wav|ogg)$'), '.meta'),
                ).delete();
              } else {
                await File(
                  dest.replaceAllMapped(
                    RegExp(r'\.(m4a|wav|ogg)$'),
                    (m) => '_draft${m[0]}',
                  ),
                ).delete();
                await File(
                  dest.replaceAll(RegExp(r'\.(m4a|wav|ogg)$'), '_draft.meta'),
                ).delete();
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
            segmentStartUptimesMs.add(
              0,
            ); // Hardware syncs RTC -> uptime in filename is lost
            segmentDerivedFlags.add(false);
          } else {
            segmentStartTimesMs.add(
              file.lastModifiedSync().toUtc().millisecondsSinceEpoch,
            );
            segmentStartUptimesMs.add((timerStart ?? 0) * 1000);
            segmentDerivedFlags.add(true);
          }
        }

        // Pre-load the ONNX model on the main isolate (rootBundle requires main isolate).
        // Skipped when VAD is disabled — isolate will run in AAD mode.
        Uint8List? modelBytes;
        final effectiveVadEnabled =
            settingsOverride?.vadEnabled ?? SharedPreferencesUtil().vadEnabled;
        if (effectiveVadEnabled) {
          try {
            final data = await rootBundle.load('assets/models/silero_vad.onnx');
            modelBytes = data.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
          } catch (e) {
            Logger.error(
              'RecordingsManager: Failed to pre-load VAD model ($e) — AAD mode active.',
            );
          }
        }

        final Set<String> deletedSegmentFolders = {};

        try {
          final receivePort = ReceivePort();
          final exitPort = ReceivePort();
          bool isolateDone = false;

          final startTime = DateTime.now();
          int processedBytes = 0;

          await Isolate.spawn(
            _processingIsolateEntry,
            _IsolateParams(
              sendPort: receivePort.sendPort,
              rootIsolateToken: RootIsolateToken.instance!,
              modelBytes: modelBytes,
              settings: settingsOverride ?? ProcessingSettings.fromPrefs(),
              tempProcessingPath: tempProcessingPath,
              segmentPaths: allSegments.map((f) => f.path).toList(),
              segmentFileSizes: segmentFileSizes,
              segmentStartTimesMs: segmentStartTimesMs,
              segmentStartUptimesMs: segmentStartUptimesMs,
              segmentSessionIds: segmentSessionIds,
              segmentDerivedFlags: segmentDerivedFlags,
              backgroundMode: backgroundMode,
            ),
            onExit: exitPort.sendPort,
          );

          // If the isolate dies without sending 'done'/'error', close receivePort so we don't hang.
          exitPort.listen((_) {
            if (!isolateDone) receivePort.close();
            exitPort.close();
          });

          final List<Map<String, dynamic>> pendingEdls = [];
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
              case 'marker_edl':
                pendingEdls.addAll(
                  (msg['items'] as List).cast<Map<String, dynamic>>(),
                );
              case 'discard_records':
                final items = (msg['items'] as List)
                    .cast<Map<String, dynamic>>();
                for (final rec in items) {
                  await _persistDiscardRecord(directory.path, rec);
                  for (final rel
                      in (rec['relativeBins'] as List).cast<String>()) {
                    discardProtectedPaths.add(
                      '${directory.path}/raw_segments/$rel',
                    );
                  }
                }
              case 'move':
                await moveTempFilesToLive();
              case 'delete_segments':
                if (!SharedPreferencesUtil().adjustmentMode) {
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
                }
              case 'progress':
                final segmentBytes = msg['processed_bytes'] as int;
                processedBytes += segmentBytes;
                final index = msg['index'] as int;
                final totalSegments = msg['total'] as int;

                final progressVal = rawTotalBytes > 0
                    ? processedBytes / rawTotalBytes
                    : ((index + 1) / totalSegments);
                final progress = (progressVal * 0.9).clamp(0.0, 0.9);

                Duration? eta;
                if (progressVal >= 0.05 && processedBytes > 0) {
                  final elapsed = DateTime.now().difference(startTime);
                  final remainingBytes = rawTotalBytes - processedBytes;
                  final etaMs =
                      (elapsed.inMilliseconds * remainingBytes) ~/
                      processedBytes;
                  eta = Duration(milliseconds: etaMs);
                }
                processingProgress.value = progressVal;
                onProgress(progress, eta);
              case 'done':
                isolateDone = true;
                receivePort.close();
              case 'error':
                isolateDone = true;
                receivePort.close();
                throw Exception(msg['message']);
            }
          }

          _activeIsolateControlPort = null;

          // Write EDL sidecar files for any markers emitted during processing.
          for (final edl in pendingEdls) {
            final filename = edl['filename'] as String;
            final markerMs = edl['markerMs'] as int;
            final offsetMs = edl['offsetMs'] as int;
            final durationMs = edl['durationMs'] as int;
            final nameNoExt = filename.contains('.')
                ? filename.substring(0, filename.lastIndexOf('.'))
                : filename;
            final parts = nameNoExt.split('_');
            final tsStr = parts.contains('draft')
                ? parts[parts.length - 2]
                : parts.last;
            final millis = int.tryParse(tsStr);
            final dateStr = (millis != null && millis > 946684800000)
                ? _dateStringFromMillis(millis)
                : _dateStringFromMillis(markerMs);
            final liveDir = Directory('${directory.path}/recordings/$dateStr');
            await liveDir.create(recursive: true);
            final edlFile = File('${liveDir.path}/marker_$markerMs.edl');
            if (!await edlFile.exists()) {
              await edlFile.writeAsString(
                jsonEncode({
                  'markerTimestampMs': markerMs,
                  'segmentFilename': filename,
                  'markerOffsetMs': offsetMs,
                  'cropStartMs': 0,
                  'cropEndMs': durationMs,
                  'userSaved': false,
                }),
              );
              Logger.debug(
                'RecordingsManager: Wrote EDL marker_$markerMs.edl → $filename at ${offsetMs}ms',
              );
            }
          }

          await Future.delayed(const Duration(milliseconds: 200));
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        } catch (e) {
          _activeIsolateControlPort = null;
          Logger.error("RecordingsManager: Combined processing failed: $e");
          rethrow;
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
      processingProgress.value = 0.0;
      isTranscoding.value = false;
      SharedPreferencesUtil().extractionInProgress = false;
    }
  }

  /// Scans for draft recordings across all dates and stitches them with subsequent
  /// recordings if the gap is within the 2-minute threshold.
  Future<void> _stitchDraftRecordings({bool finalizeAll = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;

    final splitSeconds = SharedPreferencesUtil().vadSplitSeconds;
    final thresholdMs = splitSeconds * 1000;

    final dateFolders = (await recordingsDir.list().toList())
        .whereType<Directory>()
        .toList();
    for (final folder in dateFolders) {
      bool scanNeeded = true;
      while (scanNeeded) {
        scanNeeded = false;
        final entities = (await folder.list().toList())
            .whereType<File>()
            .toList();
        final draftFiles = entities
            .where(
              (f) => f.path.contains('_draft.') && !f.path.endsWith('.meta'),
            )
            .toList();

        if (draftFiles.isEmpty) break;

        // Sort files in this folder chronologically to find what comes after each draft.
        final allAudioFiles =
            entities.where((f) {
              final p = f.path;
              return (p.endsWith('.m4a') ||
                      p.endsWith('.wav') ||
                      p.endsWith('.ogg')) &&
                  !p.contains('.tmp');
            }).toList()..sort((a, b) {
              final tsA = _extractTimestamp(a.path);
              final tsB = _extractTimestamp(b.path);
              return tsA.compareTo(tsB);
            });

        for (final draftFile in draftFiles) {
          final draftTs = _extractTimestamp(draftFile.path);
          final draftExt = draftFile.path.split('.').last;
          final draftMeta = File(
            draftFile.path.replaceAllMapped(
              RegExp(r'\.' + draftExt + r'$'),
              (_) => '.meta',
            ),
          );

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
          final durationMs = ByteData.sublistView(
            metaBytes,
          ).getUint32(4, Endian.little);
          final draftEndTs = draftTs + durationMs;

          // Find the next chronological file
          final currentIndex = allAudioFiles.indexWhere(
            (f) => f.path == draftFile.path,
          );
          if (currentIndex == -1 || currentIndex == allAudioFiles.length - 1) {
            // No next file in this folder.
            if (finalizeAll) {
              // Manual user trigger (Force Process) always finalizes immediately.
              await _finalizeDraft(draftFile, isForceSynced: true);
              scanNeeded = true;
              break;
            }
            continue;
          }

          final nextFile = allAudioFiles[currentIndex + 1];
          final nextTs = _extractTimestamp(nextFile.path);
          final nextExt = nextFile.path.split('.').last;
          final nextMeta = File(
            nextFile.path.replaceAllMapped(
              RegExp(r'\.' + nextExt + r'$'),
              (_) => '.meta',
            ),
          );

          int gapMs = nextTs - draftEndTs;

          if (gapMs >= 0 && gapMs <= thresholdMs) {
            // Check for clock jump using hardware uptime if both have meta files
            bool isClockJump = false;
            if (await nextMeta.exists()) {
              try {
                final nextMetaBytes = await nextMeta.readAsBytes();
                if (metaBytes.length >= 416 && nextMetaBytes.length >= 416) {
                  final draftSessionId = ByteData.sublistView(
                    metaBytes,
                  ).getUint32(408, Endian.little);
                  final nextSessionId = ByteData.sublistView(
                    nextMetaBytes,
                  ).getUint32(408, Endian.little);
                  final draftUptimeSec = ByteData.sublistView(
                    metaBytes,
                  ).getUint32(412, Endian.little);
                  final nextUptimeSec = ByteData.sublistView(
                    nextMetaBytes,
                  ).getUint32(412, Endian.little);

                  if (draftSessionId == nextSessionId &&
                      draftUptimeSec > 0 &&
                      nextUptimeSec > draftUptimeSec) {
                    final draftDurationMs = durationMs;
                    final uptimeGapMs =
                        (nextUptimeSec * 1000) -
                        ((draftUptimeSec * 1000) + draftDurationMs);
                    if (uptimeGapMs.abs() < 5000 && gapMs.abs() > 10000) {
                      isClockJump = true;
                    }
                  }
                }
              } catch (_) {}
            }

            // If it's a clock jump or a very small gap (under 10s AAD tail), stitch without padding.
            if (isClockJump || gapMs < 10000) {
              gapMs = 0;
            }

            Logger.debug(
              'RecordingsManager: Stitching draft $draftTs with next $nextTs (gap=${gapMs}ms${isClockJump ? ", CLOCK JUMP" : ""})',
            );
            final success = await _performStitch(draftFile, nextFile, gapMs);
            if (success) {
              // After stitching, we need to re-scan this folder.
              scanNeeded = true;
              break;
            }
          } else {
            // Gap too large or next file is in the past (shouldn't happen). Finalize.
            await _finalizeDraft(draftFile, isForceSynced: false);
            scanNeeded = true;
            break;
          }
        }
      }
    }
  }

  int _extractTimestamp(String path) {
    final name = path.split('/').last;
    final nameNoExt = name.split('.').first;
    final parts = nameNoExt.split('_');
    if (parts.length < 2) return 0;

    // Format: recording_<ts> or recording_<ts>_draft
    final tsStr = parts.contains('draft')
        ? parts[parts.length - 2]
        : parts.last;
    return int.tryParse(tsStr) ?? 0;
  }

  /// Returns true if [draftFile] is referenced by a marker EDL whose 50-second
  /// protection window has not yet expired, meaning we should hold off finalizing.
  Future<bool> _isDraftInMarkerWindow(
    File draftFile,
    List<FileSystemEntity> entities,
  ) async {
    final draftFilename = draftFile.path.split('/').last;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final entity in entities) {
      if (entity is! File || !entity.path.endsWith('.edl')) continue;
      try {
        final content = await entity.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        if ((json['segmentFilename'] as String?) == draftFilename) {
          final markerMs = json['markerTimestampMs'] as int? ?? 0;
          if (markerMs > 0 && nowMs < markerMs + 50000) return true;
        }
      } catch (_) {}
    }
    return false;
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
        if (await File(finalAudioPath).exists())
          await File(finalAudioPath).delete();

        final success = await _transcodeWavToM4a(file, finalAudioPath);
        if (success) {
          await file.delete();
          transcoded = true;
        } else {
          finalAudioPath = path.replaceAll('_draft.', '.');
          if (await File(finalAudioPath).exists())
            await File(finalAudioPath).delete();
          await file.rename(finalAudioPath);
        }
      } else {
        finalAudioPath = path.replaceAll('_draft.', '.');
        if (await File(finalAudioPath).exists())
          await File(finalAudioPath).delete();
        await file.rename(finalAudioPath);
      }

      final newFilename = finalAudioPath.split('/').last;
      final newMetaPath = metaPath.replaceAll('_draft.', '.');

      if (await File(metaPath).exists()) {
        final bytes = await File(metaPath).readAsBytes();
        var outBytes = bytes;

        // 1. Update flags (passthrough, forceSynced)
        if (bytes.length >= 417) {
          final keyLen = bytes[416];
          final flagOffset = 417 + keyLen;
          if (bytes.length <= flagOffset + 1) {
            // Re-allocate to ensure space for both flags
            final newBytes = Uint8List(flagOffset + 2);
            newBytes.setRange(0, bytes.length, bytes);
            newBytes[flagOffset] = 0; // passthrough
            newBytes[flagOffset + 1] = isForceSynced ? 1 : 0; // forceSynced
            outBytes = newBytes;
          } else {
            outBytes[flagOffset + 1] = isForceSynced ? 1 : 0;
          }
        }

        // 2. Update uploadKey extension if transcoded
        if (transcoded) {
          final keyLen = outBytes[416];
          // ⚡ Bolt: Use positional arguments for fromCharCodes to prevent copying memory
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
          finalDurationMs = ByteData.sublistView(
            metaBytes,
          ).getUint32(4, Endian.little);
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
                if (finalDurationMs != null)
                  json['cropEndMs'] = finalDurationMs;
                await entity.writeAsString(jsonEncode(json));
                Logger.debug(
                  'RecordingsManager: Updated EDL ${entity.path} for finalized draft',
                );
              }
            } catch (e) {
              Logger.error(
                'RecordingsManager: Failed to update EDL ${entity.path}: $e',
              );
            }
          }
        }
      }

      Logger.debug(
        'RecordingsManager: Finalized draft $path -> $finalAudioPath',
      );
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
      final pcmBytes = bytes.sublist(44);

      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
      const chunkSize = 4096;
      for (int i = 0; i < pcmBytes.length; i += chunkSize) {
        final end = (i + chunkSize > pcmBytes.length)
            ? pcmBytes.length
            : i + chunkSize;
        await AacEncoder.encodeBuffer(sessionId, pcmBytes.sublist(i, end));
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

    final sink = await draftFile.open(mode: FileMode.append);
    await sink.writeFrom(nextBytes);
    await sink.close();

    // Update Meta
    await _mergeMeta(draftFile, nextFile, gapMs);

    // Delete next
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

    const sampleRate = 16000;
    const channels = 1;
    final silenceSamples = (gapMs * sampleRate) ~/ 1000;
    final silenceBytes = Uint8List(silenceSamples * channels * 2);

    final combinedPcm = BytesBuilder();
    combinedPcm.add(draftBytes.sublist(44));
    combinedPcm.add(silenceBytes);
    combinedPcm.add(nextBytes.sublist(44));

    final totalPcmBytes = combinedPcm.length;
    final header = _generateWavHeader(totalPcmBytes, sampleRate, channels);

    final outSink = draftFile.openWrite();
    outSink.add(header);
    outSink.add(combinedPcm.takeBytes());
    await outSink.close();

    // Update Meta
    await _mergeMeta(draftFile, nextFile, gapMs);

    // Delete next
    await nextFile.delete();
    final nextMeta = File(nextFile.path.replaceAll(RegExp(r'\.wav$'), '.meta'));
    if (await nextMeta.exists()) await nextMeta.delete();

    return true;
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

  Future<void> _mergeMeta(File draftFile, File nextFile, int gapMs) async {
    final draftMeta = File(
      draftFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta'),
    );
    final nextMeta = File(
      nextFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta'),
    );
    if (!await draftMeta.exists() || !await nextMeta.exists()) return;

    final dBytes = await draftMeta.readAsBytes();
    final nBytes = await nextMeta.readAsBytes();
    if (dBytes.length < 408 || nBytes.length < 408) return;

    final dMeta = ByteData.sublistView(dBytes);
    final nMeta = ByteData.sublistView(nBytes);

    const sampleRate = 16000;
    final dSamples = dMeta.getUint32(0, Endian.little);
    final gapSamples = (gapMs * sampleRate) ~/ 1000;
    final nSamples = nMeta.getUint32(0, Endian.little);
    final totalSamples = dSamples + gapSamples + nSamples;
    final totalDurationMs = (totalSamples * 1000) ~/ sampleRate;

    final outMeta = ByteData(
      416,
    ); // Corrected to 416 bytes to include SID and startUptime
    outMeta.setUint32(0, totalSamples, Endian.little);
    outMeta.setUint32(4, totalDurationMs, Endian.little);

    // Merge peaks (very roughly)
    for (int i = 0; i < 200; i++) {
      final p1 = dMeta.getUint16(8 + i * 2, Endian.little);
      final p2 = nMeta.getUint16(8 + i * 2, Endian.little);
      outMeta.setUint16(8 + i * 2, max(p1, p2), Endian.little);
    }

    // Preserve sessionId and startUptime from the original draft
    if (dBytes.length >= 416) {
      outMeta.setUint32(
        408,
        dMeta.getUint32(408, Endian.little),
        Endian.little,
      );
      outMeta.setUint32(
        412,
        dMeta.getUint32(412, Endian.little),
        Endian.little,
      );
    }

    // Keep the upload key from the draft (or update it? Draft keys are temporary).
    // Actually, draft keys should probably be ignored.
    final outBytes = outMeta.buffer.asUint8List().toList();
    if (dBytes.length > 416) {
      outBytes.addAll(dBytes.sublist(416));
    }
    await draftMeta.writeAsBytes(outBytes);
  }

  static String fmtDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
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

    // Step 1: Rapidly scan all date folders for EDL files
    final List<MarkerConversation> allConversations = [];
    for (final dateFolder in dateFolders) {
      final edlFiles = await dateFolder
          .list()
          .where(
            (e) =>
                e is File &&
                e.path.split('/').last.startsWith('marker_') &&
                e.path.endsWith('.edl'),
          )
          .cast<File>()
          .toList();

      for (final edlFile in edlFiles) {
        try {
          final json =
              jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
          final markerMs = json['markerTimestampMs'] as int;
          final segmentFilename = json['segmentFilename'] as String?;

          File? segmentFile;
          if (segmentFilename != null && segmentFilename.isNotEmpty) {
            if (segmentFilename.contains('_draft.')) continue;
            final localFile = File('${dateFolder.path}/$segmentFilename');
            if (await localFile.exists()) {
              segmentFile = localFile;
            } else {
              // Resiliency: if audio was misplaced (bug in moveTempFilesToLive), search other folders.
              for (final otherFolder in dateFolders) {
                if (otherFolder.path == dateFolder.path) continue;
                final otherFile = File('${otherFolder.path}/$segmentFilename');
                if (await otherFile.exists()) {
                  segmentFile = otherFile;
                  break;
                }
              }
            }
          }

          allConversations.add(
            MarkerConversation(
              markerTime: DateTime.fromMillisecondsSinceEpoch(markerMs),
              segment: segmentFile,
              markerOffsetMs: json['markerOffsetMs'] as int? ?? 0,
              cropStartMs: json['cropStartMs'] as int? ?? 0,
              cropEndMs: json['cropEndMs'] as int? ?? 0,
              edlFile: edlFile,
              userSaved: json['userSaved'] as bool? ?? false,
            ),
          );
        } catch (e) {
          Logger.error(
            'RecordingsManager: Failed to parse EDL ${edlFile.path}: $e',
          );
        }
      }
    }

    // Step 2: Deduplicate by markerMs within 2s window.
    final List<MarkerConversation> deduped = [];
    for (final mc in allConversations) {
      final ms = mc.markerTime.millisecondsSinceEpoch;
      int existingIdx = -1;
      for (int i = 0; i < deduped.length; i++) {
        if ((deduped[i].markerTime.millisecondsSinceEpoch - ms).abs() <= 2000) {
          existingIdx = i;
          break;
        }
      }

      if (existingIdx == -1) {
        deduped.add(mc);
      } else {
        final existing = deduped[existingIdx];
        if (existing.isPending && !mc.isPending) {
          // Replace pending with resolved
          deduped[existingIdx] = mc;
        } else if (existing.isPending &&
            mc.isPending &&
            existing.edlFile.path != mc.edlFile.path) {
          // KEEP BOTH if they are distinct pending files, even if close in time.
          // This allows the cleanup tool to find and delete all problematic files.
          deduped.add(mc);
        }
      }
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
  static String _dateStringFromMillis(int millis) =>
      fmtDate(DateTime.fromMillisecondsSinceEpoch(millis).toLocal());

  /// Background auto-process: processes all batches as one continuous stream.
  /// Skips the newest segment per DeviceSession (may still be written by firmware).
  /// Safe to call from a background timer; no-op if a marker process is running.
  static Future<void> processAllCompletedSessions() async {
    if (_isProcessingAny) return;
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    final activeBatches = batches
        .where((b) => b.rawSegments.isNotEmpty)
        .where(
          (b) =>
              !SharedPreferencesUtil().adjustmentMode ||
              b.finalizedRecordings.isEmpty,
        )
        .toList();
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
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    final activeBatches = batches
        .where((b) => b.rawSegments.isNotEmpty || b.draftRecordings.isNotEmpty)
        .where(
          (b) =>
              !SharedPreferencesUtil().adjustmentMode ||
              b.finalizedRecordings.isEmpty,
        )
        .toList();
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
      if (entity is File &&
          (entity.path.endsWith('.tmp.m4a') ||
              entity.path.endsWith('.ogg.tmp'))) {
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
  static Future<void> deleteConversations(
    List<Conversation> conversations,
  ) async {
    if (conversations.isEmpty) return;

    // Group conversations by directory to minimize directory listings for EDL cleanup
    final Map<String, List<Conversation>> byDir = {};
    for (final c in conversations) {
      final dir = c.file.parent.path;
      byDir.putIfAbsent(dir, () => []).add(c);
    }

    for (final dirPath in byDir.keys) {
      final convsInDir = byDir[dirPath]!;
      final filenames = convsInDir
          .map((c) => c.file.path.split('/').last)
          .toSet();

      // 1. Delete audio, meta, bin files
      for (final c in convsInDir) {
        final key = c.uploadKey;
        if (key != null) {
          await SharedPreferencesUtil().removeUploadedFromHeypocket({key});
        }
        final file = c.file;
        if (await file.exists()) {
          await file.delete();
        }
        final metaPath =
            '${file.path.substring(0, file.path.lastIndexOf('.'))}.meta';
        final metaFile = File(metaPath);
        if (await metaFile.exists()) {
          await metaFile.delete();
        }
        try {
          final ts = file.path.split('/').last.split('_').last.split('.').first;
          final binPath = '${file.parent.path}/recording_fs320_$ts.bin';
          final binFile = File(binPath);
          if (await binFile.exists()) {
            await binFile.delete();
          }
        } catch (_) {}
      }

      // 2. Delete EDL files for all deleted conversations in this directory at once
      try {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          final dirEntities = await dir.list().toList();
          for (final entity in dirEntities) {
            if (entity is! File || !entity.path.endsWith('.edl')) continue;
            try {
              final json =
                  jsonDecode(await entity.readAsString())
                      as Map<String, dynamic>;
              if (filenames.contains(json['segmentFilename'])) {
                await entity.delete();
              }
            } catch (_) {}
          }
        }
      } catch (e) {
        Logger.error(
          'RecordingsManager: Failed to cleanup EDLs in $dirPath: $e',
        );
      }
    }
  }

  /// Deletes a marker conversation.
  static Future<void> deleteMarkerConversation(MarkerConversation mc) async {
    if (await mc.edlFile.exists()) {
      await mc.edlFile.delete();
      Logger.debug(
        'RecordingsManager: Deleted marker conversation ${mc.edlFile.path}',
      );
    }
  }

  /// Deletes processed recordings (.m4a/.wav/.meta/.bin) for a day.
  /// If [onlyReprocessable] is true, only recordings with matching raw segments
  /// in the raw_segments/ directory are deleted.
  /// Safe to call while nothing is playing.
  Future<void> deleteDay(Batch batch, {bool onlyReprocessable = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory(
      '${directory.path}/recordings/${batch.dateString}',
    );

    // Drop any discard records for this day and their protected bins so the
    // ghosts disappear immediately rather than surviving until the next sweep.
    // The full directory delete below would handle discards.jsonl in the
    // !onlyReprocessable path, but the raw_segments bins live elsewhere and
    // need explicit cleanup either way.
    for (final d in batch.discards) {
      await removeDiscardRecord(d, deleteBins: true);
    }

    if (!await recordingsDir.exists()) return;

    final availableSessionIds = batch.rawSegments
        .map((f) {
          final name = f.path.split('/').last.split('.').first;
          return int.tryParse(name.split('_').first);
        })
        .whereType<int>()
        .toSet();

    if (!onlyReprocessable) {
      await recordingsDir.delete(recursive: true);
      Logger.debug(
        'RecordingsManager: Deleted processed recordings for ${batch.dateString}',
      );
    } else {
      // Surgical delete: only remove finalized recordings and drafts that
      // belong to a session for which we still have raw data.
      final allToProcess = [
        ...batch.finalizedRecordings,
        ...batch.draftRecordings,
      ];
      final dirEntities = await recordingsDir.list().toList();
      final edlFiles = dirEntities
          .whereType<File>()
          .where((f) => f.path.endsWith('.edl'))
          .toList();
      int deletedCount = 0;
      for (final conv in allToProcess) {
        if (conv.sessionId != null &&
            availableSessionIds.contains(conv.sessionId)) {
          final audioFilename = conv.file.path.split('/').last;
          if (await conv.file.exists()) await conv.file.delete();
          final metaFile = File(
            '${conv.file.path.substring(0, conv.file.path.lastIndexOf('.'))}.meta',
          );
          if (await metaFile.exists()) await metaFile.delete();

          // Also delete any raw .bin files that might have been moved into the
          // recordings folder (some pipelines do this for portability).
          final ts = conv.file.path
              .split('/')
              .last
              .split('_')
              .last
              .split('.')
              .first;
          final recordingsBin = File(
            '${conv.file.parent.path}/recording_fs320_$ts.bin',
          );
          if (await recordingsBin.exists()) await recordingsBin.delete();

          // Delete EDL files referencing this recording so the re-resolver can
          // recreate them after reprocessing. Without this, stale EDL files with
          // a non-empty segmentFilename cause the re-resolver to skip the marker
          // as already-resolved, leaving it permanently broken.
          for (final edl in edlFiles) {
            try {
              final json =
                  jsonDecode(await edl.readAsString()) as Map<String, dynamic>;
              if (json['segmentFilename'] == audioFilename) await edl.delete();
            } catch (_) {}
          }

          deletedCount++;
        }
      }
      Logger.debug(
        'RecordingsManager: Surgical delete for ${batch.dateString} — removed $deletedCount reprocessable recordings',
      );

      // If directory is now empty (or only contains orphaned files we don't know about), delete it.
      try {
        if (await recordingsDir.list().isEmpty) await recordingsDir.delete();
      } catch (_) {}
    }
  }

  /// Deletes processed recordings for [batch] so the day can be reprocessed
  /// on the next swipe or force sync with current VAD settings.
  static Future<void> reprocessDay(Batch batch) async {
    if (_isProcessingAny) return;
    final manager = RecordingsManager();
    await manager.deleteDay(batch, onlyReprocessable: true);
    notifyRecordingsChanged();
  }

  /// Batch-updates the starting timestamp for an entire hardware session.
  ///
  /// This renames and moves all processed recordings, .meta sidecars, .bin raw syncs,
  /// and .edl markers belonging to the same sessionId.
  static Future<void> promoteSessionToDate(
    Conversation base,
    DateTime newStartTime,
  ) async {
    final sessionId = base.sessionId;
    final startUptime = base.startUptime;
    if (startUptime == null || startUptime == 0) {
      throw Exception(
        'Cannot promote session: startUptime is missing or zero.',
      );
    }

    final rtcOffsetMs =
        newStartTime.millisecondsSinceEpoch - (startUptime * 1000);
    final directory = await getApplicationDocumentsDirectory();

    // 1. Identify all affected finalized recordings across all date folders.
    final List<Conversation> sessionConversations = [];
    final recordingsDir = Directory('${directory.path}/recordings');
    if (await recordingsDir.exists()) {
      final dateFolders = (await recordingsDir.list().toList())
          .whereType<Directory>()
          .toList();
      for (final folder in dateFolders) {
        final audioFiles = await folder
            .list()
            .where(
              (e) =>
                  e is File &&
                  (e.path.endsWith('.m4a') ||
                      e.path.endsWith('.wav') ||
                      e.path.endsWith('.ogg')),
            )
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
      final convUptime =
          conv.startUptime ?? (conv.startTime.millisecondsSinceEpoch ~/ 1000);
      final newConvStartMs = (convUptime * 1000) + rtcOffsetMs;
      final newDateStr = _dateStringFromMillis(newConvStartMs);
      final targetDir = Directory('${directory.path}/recordings/$newDateStr');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final extension = conv.file.path.split('.').last;
      final newAudioPath =
          '${targetDir.path}/recording_$newConvStartMs.$extension';
      final newMetaPath = '${targetDir.path}/recording_$newConvStartMs.meta';

      final basePath = conv.file.path.substring(
        0,
        conv.file.path.lastIndexOf('.'),
      );
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
          .where(
            (e) =>
                e is File &&
                e.path.split('/').last.startsWith('marker_') &&
                e.path.endsWith('.edl'),
          )
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
            final newEdlFile = File(
              '${targetDir.path}/marker_$newMarkerMs.edl',
            );
            await newEdlFile.writeAsString(jsonEncode(updatedJson));
          }
        } catch (e) {
          Logger.error(
            'RecordingsManager: Failed to migrate EDL ${edlFile.path}: $e',
          );
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
        final targetFolder = Directory(
          '${rawSegmentsDir.path}/$newBaseStartMs',
        );

        if (await targetFolder.exists()) {
          // Merge contents if target already exists (unlikely but safe)
          await for (final entity in sourceFolder.list()) {
            if (entity is File) {
              await entity.rename(
                '${targetFolder.path}/${entity.path.split('/').last}',
              );
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
  /// sweep reclaims them. Adjustment Mode pauses the sweep entirely.
  static const Duration discardRetentionWindow = Duration(hours: 48);

  /// Appends one JSONL record to `recordings/<date>/discards.jsonl`. The date
  /// folder is derived from the record's startMs in local time.
  static Future<void> _persistDiscardRecord(
    String docsPath,
    Map<String, dynamic> rec,
  ) async {
    final dateStr = _dateStringFromMillis(rec['startMs'] as int);
    final dir = Directory('$docsPath/recordings/$dateStr');
    await dir.create(recursive: true);
    final file = File('${dir.path}/discards.jsonl');
    await file.writeAsString(
      '${jsonEncode(rec)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Walks all `recordings/<date>/discards.jsonl` files and returns parsed
  /// records grouped by their containing file. Malformed lines are skipped.
  static Future<List<({File jsonl, List<Map<String, dynamic>> records})>>
  _readAllDiscardRecords() async {
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
          Logger.error(
            'RecordingsManager: Skipping malformed discard line in ${jsonl.path}: $e',
          );
        }
      }
      out.add((jsonl: jsonl, records: records));
    }
    return out;
  }

  /// Parses `recordings/<dateString>/discards.jsonl` into [DiscardRecord]s.
  /// Returns an empty list if the file does not exist. Malformed lines are
  /// skipped with a warning.
  static Future<List<DiscardRecord>> getDiscardsForDate(
    String dateString,
  ) async {
    final directory = await getApplicationDocumentsDirectory();
    final jsonl = File(
      '${directory.path}/recordings/$dateString/discards.jsonl',
    );
    if (!await jsonl.exists()) return const [];
    final out = <DiscardRecord>[];
    for (final line in (await jsonl.readAsString()).split('\n')) {
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        out.add(
          DiscardRecord(
            startTime: DateTime.fromMillisecondsSinceEpoch(m['startMs'] as int),
            endTime: DateTime.fromMillisecondsSinceEpoch(m['endMs'] as int),
            reason: m['reason'] as String,
            maxVoiceProb: (m['maxVoiceProb'] as num).toDouble(),
            relativeBins: (m['relativeBins'] as List).cast<String>(),
            sourceJsonl: jsonl,
          ),
        );
      } catch (e) {
        Logger.error(
          'RecordingsManager: skipping malformed discard line in ${jsonl.path}: $e',
        );
      }
    }
    out.sort((a, b) => a.startTime.compareTo(b.startTime));
    return out;
  }

  /// Deletes a discard record (and optionally its referenced bins) atomically.
  /// Rewrites the source jsonl with all other records preserved. If the jsonl
  /// becomes empty it is removed.
  static Future<void> removeDiscardRecord(
    DiscardRecord d, {
    required bool deleteBins,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    if (deleteBins) {
      for (final rel in d.relativeBins) {
        final binFile = File('${directory.path}/raw_segments/$rel');
        if (await binFile.exists()) {
          try {
            await binFile.delete();
          } catch (e) {
            Logger.error(
              'RecordingsManager: removeDiscardRecord delete bin failed: $e',
            );
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
        if (m['startMs'] == targetMs && m['endMs'] == targetEndMs) continue;
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
    final cutoffMs = DateTime.now()
        .subtract(discardRetentionWindow)
        .millisecondsSinceEpoch;
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
  /// Adjustment Mode is on (which keeps all bins indefinitely) or when a
  /// processing run is already in flight (to avoid racing the per-segment
  /// delete handler). Bins still claimed by any in-window record across any
  /// day's jsonl are preserved.
  static Future<void> runRecoverySweep() async {
    if (SharedPreferencesUtil().adjustmentMode) return;
    if (_isProcessingAny) return;
    final directory = await getApplicationDocumentsDirectory();
    final cutoffMs = DateTime.now()
        .subtract(discardRetentionWindow)
        .millisecondsSinceEpoch;

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
          Logger.debug(
            'RecordingsManager: RecoverySweep deleted expired bin $path',
          );
        } catch (e) {
          Logger.error(
            'RecordingsManager: RecoverySweep failed to delete $path: $e',
          );
        }
      }
      if (activeRecords.isEmpty) {
        try {
          await group.jsonl.delete();
        } catch (_) {}
      } else if (activeRecords.length != group.records.length) {
        await group.jsonl.writeAsString(
          '${activeRecords.map(jsonEncode).join('\n')}\n',
          flush: true,
        );
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

  /// Deletes raw .bin segment files and parent device-session folders, except
  /// bins still protected by an in-window discard record. Called after
  /// adjustment mode is turned off and any pending processing is done.
  static Future<void> deleteAllRawSegments() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawSegmentsDir = Directory('${directory.path}/raw_segments');
    if (!await rawSegmentsDir.exists()) return;

    final protected = await activeDiscardProtectedPaths();
    if (protected.isEmpty) {
      await rawSegmentsDir.delete(recursive: true);
      Logger.debug(
        'RecordingsManager: Deleted all raw segments after adjustment mode exit',
      );
      return;
    }

    int kept = 0;
    int deleted = 0;
    await for (final entity in rawSegmentsDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      if (protected.contains(entity.path)) {
        kept++;
        continue;
      }
      try {
        await entity.delete();
        deleted++;
      } catch (_) {}
    }
    await for (final entity in rawSegmentsDir.list()) {
      if (entity is! Directory) continue;
      try {
        if (await entity.list().isEmpty) await entity.delete();
      } catch (_) {}
    }
    Logger.debug(
      'RecordingsManager: AM-exit cleanup — deleted $deleted bins, preserved $kept for recovery (48h window)',
    );
  }
}
