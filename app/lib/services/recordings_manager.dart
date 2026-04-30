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

  const Conversation({
    required this.file,
    required this.startTime,
    required this.duration,
    this.uploadKey,
    this.sessionId,
    this.startUptime,
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
    final millisStr = name.contains('_') ? name.split('_').last.split('.').first : null;
    final millis = millisStr != null ? int.tryParse(millisStr) : null;
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
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(
                  metaBytes.sublist(417, 417 + keyLen),
                );
              } catch (_) {
                uploadKey = null;
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
      fileSize = file.lengthSync();
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
          if (metaBytes.length >= 417) {
            final keyLen = metaBytes[416];
            if (417 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(
                  metaBytes.sublist(417, 417 + keyLen),
                );
              } catch (_) {
                uploadKey = null;
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
    // Round start to nearest minute so near-boundary starts (e.g. 11:59:47) display cleanly.
    final rounded = roundToMinute(startTime);
    // Show inclusive end: subtract 1s so a 30-min segment displays as HH:MM–HH:29, not HH:MM–HH:30.
    final inclusiveEnd = rounded.add(duration).subtract(const Duration(seconds: 1));
    return '${fmtHourMin(rounded)} – ${fmtHourMin(inclusiveEnd)}';
  }

  String get durationLabel {
    final mins = duration.inMinutes;
    final secs = duration.inSeconds % 60;
    return mins > 0 ? '${mins}m ${secs}s' : '${secs}s';
  }

  String get sizeLabel {
    final bytes = fileSizeBytes;
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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

  Batch({
    required this.dateString,
    required this.date,
    required this.rawSegments,
    required this.draftRecordings,
    required this.finalizedRecordings,
    this.markerTimestamps = const [],
  });
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
  final Uint8List? modelBytes; // Silero VAD ONNX model, pre-loaded on main isolate
  final ProcessingSettings settings;
  final String tempProcessingPath;
  final List<String> segmentPaths;
  final List<int> segmentFileSizes; // used for accurate processing ETA
  final List<int> segmentStartTimesMs; // milliseconds since epoch
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
    // Non-fatal: amplitude fallback will be used.
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
      final isDerived = params.segmentDerivedFlags[i];
      final sessionId = params.segmentSessionIds[i];

      await processor.processSegmentFile(
        file,
        startTime,
        isDerivedTimestamp: isDerived,
        sessionId: sessionId,
      );

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
    }

    // Always flush the remaining audio at the end of a run.
    // In both background and foreground modes, we save it as a '_draft' file
    // so it can be stitched with future syncs or finalized later.
    await processor.flushRemaining(isDraft: true);

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
          final millis = parts.length >= 2 ? int.tryParse(parts.last.split('.').first) : null;
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
    Map<String, List<DateTime>> markersByDate = {};

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
        
        final aId = aName.startsWith('session_') ? int.tryParse(aIdStr, radix: 16) : int.tryParse(aIdStr);
        final bId = bName.startsWith('session_') ? int.tryParse(bIdStr, radix: 16) : int.tryParse(bIdStr);
        
        return (aId ?? 0).compareTo(bId ?? 0);
      });

      for (var folder in deviceSessionFolders) {
        final deviceSessionIdStr = folder.path.split('/').last;

        // Skip hidden folders or system folders if any
        if (deviceSessionIdStr.startsWith('.')) continue;

        // 1. Process markers
        final markerFile = File('${folder.path}/markers.txt');
        if (await markerFile.exists()) {
          try {
            final content = await markerFile.readAsLines();
            for (var line in content) {
              final parts = line.split(',');
              final utc = int.tryParse(parts[0].trim());
              if (utc != null) {
                final date = DateTime.fromMillisecondsSinceEpoch(utc * 1000);
                final dateString =
                    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
                markersByDate.putIfAbsent(dateString, () => []).add(date);
              }
            }
          } catch (e) {
            Logger.error(
              "RecordingsManager: Failed to read markers for session $deviceSessionIdStr: $e",
            );
          }
        }

        // 2. Process segments
        final folderEntities = await folder.list().toList();
        final files = folderEntities.whereType<File>().where((f) => f.path.endsWith('.bin')).toList();

        await Future.wait(
          files.map((file) async {
            final date = await file.lastModified();
            final dateString =
                '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
            rawSegmentsByDate.putIfAbsent(dateString, () => []).add(file);
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
              (f) => f.path.endsWith('.m4a') || f.path.endsWith('.wav') || f.path.endsWith('.ogg'),
            )
            .toList();

        final conversations = await Future.wait(
          files.map((f) => Conversation.fromFileAsync(f)),
        );
        processedByDate[dateString] = conversations;
      }
    }

    // Merge keys
    final allDates = {
      ...rawSegmentsByDate.keys,
      ...processedByDate.keys,
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
      // Sort raw segments numerically by their filename (segmentIndex) to avoid
      // string-order bugs like "100_10.bin" sorting before "100_2.bin".
      raw.sort((a, b) {
        final nameA = a.path.split('/').last.split('.').first;
        final nameB = b.path.split('/').last.split('.').first;
        final numA = int.tryParse(nameA.split('_').last) ?? 0;
        final numB = int.tryParse(nameB.split('_').last) ?? 0;
        final prefixCmp = nameA.split('_').first.compareTo(nameB.split('_').first);
        return prefixCmp != 0 ? prefixCmp : numA.compareTo(numB);
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
          markerTimestamps: markersByDate[dateStr] ?? [],
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
  }) async {
    final activeBatches = batches.where((b) => b.rawSegments.isNotEmpty).toList();
    if (activeBatches.isEmpty) return;
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
          final parts = fileName.split('_');
          final millis = parts.length >= 2 ? int.tryParse(parts.last.split('.').first) : null;
          final dateStr =
              (millis != null && millis > 0) ? _dateStringFromMillis(millis) : activeBatches.last.dateString;
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          try {
            await File(dest).delete();
          } on FileSystemException catch (_) {}
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

      // Combine segments from all batches, sorted by (deviceSessionId, segmentIndex).
      final allSegments = activeBatches.expand((b) => b.rawSegments).toList();
      allSegments.sort((a, b) {
        final ap = a.path.split('/').last.replaceAll('.bin', '').split('_');
        final bp = b.path.split('/').last.replaceAll('.bin', '').split('_');
        final as_ = int.tryParse(ap[0]) ?? 0;
        final bs_ = int.tryParse(bp[0]) ?? 0;
        if (as_ != bs_) return as_.compareTo(bs_);
        return (int.tryParse(ap.length > 1 ? ap[1] : '0') ?? 0).compareTo(
          int.tryParse(bp.length > 1 ? bp[1] : '0') ?? 0,
        );
      });

      // Pre-compute segment timestamps and session IDs on the main isolate.
      const kMinValidEpoch = 946684800;
      final segmentStartTimesMs = <int>[];
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
          segmentDerivedFlags.add(false);
        } else {
          segmentStartTimesMs.add(
            file.lastModifiedSync().millisecondsSinceEpoch,
          );
          segmentDerivedFlags.add(true);
        }
      }

      // Pre-load the ONNX model on the main isolate (rootBundle requires main isolate).
      Uint8List? modelBytes;
      try {
        final data = await rootBundle.load('assets/models/silero_vad.onnx');
        modelBytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } catch (e) {
        Logger.error(
          'RecordingsManager: Failed to pre-load VAD model ($e) — amplitude fallback active.',
        );
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
            settings: ProcessingSettings.fromPrefs(),
            tempProcessingPath: tempProcessingPath,
            segmentPaths: allSegments.map((f) => f.path).toList(),
            segmentFileSizes: segmentFileSizes,
            segmentStartTimesMs: segmentStartTimesMs,
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

        await for (final msg in receivePort) {
          if (msg is! Map) continue;
          switch (msg['type'] as String) {
            case 'control_port':
              _activeIsolateControlPort = msg['port'] as SendPort;
              // Forward a pending cancel if the user already called cancelProcessing().
              if (_cancelRequested) {
                _activeIsolateControlPort?.send('cancel');
              }
            case 'move':
              await moveTempFilesToLive();
            case 'delete_segments':
              if (!SharedPreferencesUtil().adjustmentMode) {
                final paths = (msg['paths'] as List).cast<String>();
                for (final path in paths) {
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
              receivePort.close();
            case 'error':
              isolateDone = true;
              receivePort.close();
              throw Exception(msg['message']);
          }
        }

        _activeIsolateControlPort = null;

        await Future.delayed(const Duration(milliseconds: 200));
        if (await tempDir.exists()) await tempDir.delete(recursive: true);

        // Resolve marker conversations for each date that has markers.
        // Must run after temp→live move so the m4a files are in place.
        for (final batch in activeBatches) {
          if (batch.markerTimestamps.isEmpty) continue;
          final liveDir = '${directory.path}/recordings/${batch.dateString}';
          await _resolveMarkerConversations(liveDir, batch.markerTimestamps);
        }
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

      // Phase 3: Post-Sync Stitch Pass
      // After processing is complete, look for drafts and stitch them if within threshold.
      await _stitchDraftRecordings(finalizeAll: finalizeDrafts);

      onProgress(1.0, Duration.zero);
    } finally {
      _isProcessingAny = false;
      processingProgress.value = 0.0;
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

    final dateFolders = (await recordingsDir.list().toList()).whereType<Directory>().toList();
    for (final folder in dateFolders) {
      bool scanNeeded = true;
      while (scanNeeded) {
        scanNeeded = false;
        final entities = (await folder.list().toList()).whereType<File>().toList();
        final draftFiles = entities.where((f) => f.path.contains('_draft.') && !f.path.endsWith('.meta')).toList();

        if (draftFiles.isEmpty) break;

        // Sort files in this folder chronologically to find what comes after each draft.
        final allAudioFiles = entities
            .where((f) {
              final p = f.path;
              return (p.endsWith('.m4a') || p.endsWith('.wav') || p.endsWith('.ogg')) && !p.contains('.tmp');
            })
            .toList()
            ..sort((a, b) {
              final tsA = _extractTimestamp(a.path);
              final tsB = _extractTimestamp(b.path);
              return tsA.compareTo(tsB);
            });

        for (final draftFile in draftFiles) {
          final draftTs = _extractTimestamp(draftFile.path);
          final draftExt = draftFile.path.split('.').last;
          final draftMeta = File(draftFile.path.replaceAll('.$draftExt', '.meta'));

          if (!await draftMeta.exists()) {
            // No meta, can't stitch accurately. Finalize it.
            await _finalizeDraft(draftFile);
            scanNeeded = true;
            break;
          }

          // Get draft duration from meta
          final metaBytes = await draftMeta.readAsBytes();
          if (metaBytes.length < 8) {
            await _finalizeDraft(draftFile);
            scanNeeded = true;
            break;
          }
          final durationMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
          final draftEndTs = draftTs + durationMs;

          // Find the next chronological file
          final currentIndex = allAudioFiles.indexWhere((f) => f.path == draftFile.path);
          if (currentIndex == -1 || currentIndex == allAudioFiles.length - 1) {
            // No next file in this folder.
            if (finalizeAll) {
              await _finalizeDraft(draftFile);
              scanNeeded = true;
              break;
            }
            continue;
          }

          final nextFile = allAudioFiles[currentIndex + 1];
          final nextTs = _extractTimestamp(nextFile.path);
          final gapMs = nextTs - draftEndTs;

          if (gapMs > 0 && gapMs <= thresholdMs) {
            Logger.debug('RecordingsManager: Stitching draft $draftTs with next $nextTs (gap=${gapMs}ms)');
            final success = await _performStitch(draftFile, nextFile, gapMs);
            if (success) {
              // After stitching, we need to re-scan this folder.
              scanNeeded = true;
              break;
            }
          } else {
            // Gap too large or next file is in the past (shouldn't happen). Finalize.
            await _finalizeDraft(draftFile);
            scanNeeded = true;
            break;
          }
        }
      }
    }
  }

  int _extractTimestamp(String path) {
    final name = path.split('/').last;
    final parts = name.split('_');
    if (parts.length < 2) return 0;
    // timestamp is usually the last part before extension
    final tsPart = parts[parts.length - 1].split('.').first;
    return int.tryParse(tsPart) ?? 0;
  }

  Future<void> _finalizeDraft(File file) async {
    final path = file.path;
    if (!path.contains('_draft.')) return;
    final newPath = path.replaceAll('_draft.', '.');
    final metaPath = path.replaceAll(RegExp(r'\.(m4a|wav|ogg)$'), '.meta');
    final newMetaPath = metaPath.replaceAll('_draft.', '.');

    try {
      if (await File(newPath).exists()) await File(newPath).delete();
      await file.rename(newPath);
      if (await File(metaPath).exists()) {
        if (await File(newMetaPath).exists()) await File(newMetaPath).delete();
        await File(metaPath).rename(newMetaPath);
      }
      Logger.debug('RecordingsManager: Finalized draft ${file.path}');
    } catch (e) {
      Logger.error('RecordingsManager: Failed to finalize draft $path: $e');
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
    final nextMeta = File(nextFile.path.replaceAll('.ogg', '.meta'));
    if (await nextMeta.exists()) await nextMeta.delete();

    return true;
  }

  Future<bool> _stitchWav(File draftFile, File nextFile, int gapMs) async {
    // Read draft, skip header to get PCM.
    final draftBytes = await draftFile.readAsBytes();
    final nextBytes = await nextFile.readAsBytes();

    if (draftBytes.length < 44 || nextBytes.length < 44) return false;

    final sampleRate = 16000;
    final channels = 1;
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
    final nextMeta = File(nextFile.path.replaceAll('.wav', '.meta'));
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
    final draftMeta = File(draftFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta'));
    final nextMeta = File(nextFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta'));
    if (!await draftMeta.exists() || !await nextMeta.exists()) return;

    final dBytes = await draftMeta.readAsBytes();
    final nBytes = await nextMeta.readAsBytes();
    if (dBytes.length < 408 || nBytes.length < 408) return;

    final dMeta = ByteData.sublistView(dBytes);
    final nMeta = ByteData.sublistView(nBytes);

    final sampleRate = 16000;
    final dSamples = dMeta.getUint32(0, Endian.little);
    final gapSamples = (gapMs * sampleRate) ~/ 1000;
    final nSamples = nMeta.getUint32(0, Endian.little);
    final totalSamples = dSamples + gapSamples + nSamples;
    final totalDurationMs = (totalSamples * 1000) ~/ sampleRate;

    final outMeta = ByteData(416); // Corrected to 416 bytes to include SID and startUptime
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
      outMeta.setUint32(408, dMeta.getUint32(408, Endian.little), Endian.little);
      outMeta.setUint32(412, dMeta.getUint32(412, Endian.little), Endian.little);
    }

    // Keep the upload key from the draft (or update it? Draft keys are temporary).
    // Actually, draft keys should probably be ignored.
    final outBytes = outMeta.buffer.asUint8List().toList();
    if (dBytes.length > 416) {
      outBytes.addAll(dBytes.sublist(416));
    }
    await draftMeta.writeAsBytes(outBytes);
  }

  /// Writes EDL sidecars for all markers in [markerTimestamps] into [liveRecordingsDirPath].
  /// Idempotent: skips EDLs that already exist with non-empty segments.
  /// Resolves previously-pending EDLs (empty segments) when the backing m4a is now available.
  static Future<void> _resolveMarkerConversations(
    String liveRecordingsDirPath,
    List<DateTime> markerTimestamps,
  ) async {
    final liveDir = Directory(liveRecordingsDirPath);
    if (!await liveDir.exists() || markerTimestamps.isEmpty) return;

    // Build sorted list of (file, startMs, endMs) from m4a/ogg + .meta pairs.
    final recordings = <({File file, int startMs, int endMs, int durationMs, int? sessionId, int? startUptime})>[];
    for (final entity in await liveDir.list().toList()) {
      if (entity is! File || (!entity.path.endsWith('.m4a') && !entity.path.endsWith('.ogg'))) continue;
      
      final conv = Conversation.fromFile(entity);
      if (conv.duration.inMilliseconds <= 0) continue;

      recordings.add((
        file: entity,
        startMs: conv.startTime.millisecondsSinceEpoch,
        endMs: conv.endTime.millisecondsSinceEpoch,
        durationMs: conv.duration.inMilliseconds,
        sessionId: conv.sessionId,
        startUptime: conv.startUptime,
      ));
    }
    recordings.sort((a, b) => a.startMs.compareTo(b.startMs));

    // Also read markers.txt if it exists to get the uptime/sessionId for each marker.
    // If the file is just timestamps (legacy), we'll have only markerTimestamps.
    final markerFile = File('$liveRecordingsDirPath/../markers.txt'); // Look in raw_segments session folder?
    // Wait, liveDir is recordings/date/. raw_segments is in a different sibling tree.
    // markers.txt is passed in markerTimestamps.
    // For now we rely on the markerMs (timestamp).

    for (final markerTime in markerTimestamps) {
      final markerMs = markerTime.millisecondsSinceEpoch;
      final edlFile = File('$liveRecordingsDirPath/marker_$markerMs.edl');

      // Skip already-resolved EDLs.
      if (await edlFile.exists()) {
        try {
          final existing = jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
          if ((existing['segmentFilename'] as String?)?.isNotEmpty == true) continue;
        } catch (_) {}
      }

      // Strict containment only: marker must fall within a recording that was actually
      // produced from the audio around that time.
      int matchIdx = recordings.indexWhere(
        (r) => markerMs >= r.startMs && markerMs < r.endMs,
      );

      // If no time match, and this is an "unknown" recording (Dec 1969/Jan 1970), 
      // we could try matching by sessionId, but we'd need the SID from the marker.
      // Since markerTimestamps only contains DateTime, we'll implement that in a future
      // update when we pass MarkerInfo objects.
      // For now, relative positioning logic below handles the "unknown" case if a time match occurred.

      if (matchIdx >= 0) {
        final rec = recordings[matchIdx];
        final segmentFilename = rec.file.path.split('/').last;
        
        int markerOffsetMs = markerMs - rec.startMs;

        // Relative positioning for unknown sessions (markerMs is uptime, startUptime is uptime)
        if (rec.startUptime != null && rec.startUptime! > 0 && markerMs < 946684800000) {
          markerOffsetMs = markerMs - (rec.startUptime! * 1000);
        }

        final edlData = {
          'markerTimestampMs': markerMs,
          'segmentFilename': segmentFilename,
          'markerOffsetMs': markerOffsetMs,
          'cropStartMs': 0,
          'cropEndMs': rec.durationMs,
          'userSaved': false,
        };
        await edlFile.writeAsString(jsonEncode(edlData));
        Logger.debug(
          'RecordingsManager: Wrote EDL for marker at $markerTime → $segmentFilename',
        );
      } else {
        // ... (Pending EDL logic)
        final edlData = {
          'markerTimestampMs': markerMs,
          'segmentFilename': null,
          'markerOffsetMs': 0,
          'cropStartMs': 0,
          'cropEndMs': 0,
          'userSaved': false,
        };
        await edlFile.writeAsString(jsonEncode(edlData));
        Logger.debug(
          'RecordingsManager: Wrote PENDING EDL for marker at $markerTime',
        );
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

    final resultsNested = await Future.wait(
      dateFolders.map((dateFolder) async {
        final edlFiles = await dateFolder
            .list()
            .where(
              (e) => e is File && e.path.split('/').last.startsWith('marker_') && e.path.endsWith('.edl'),
            )
            .cast<File>()
            .toList();

        final markerFutures = edlFiles.map((edlFile) async {
          try {
            final json = jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
            final markerMs = json['markerTimestampMs'] as int;
            final segmentFilename = json['segmentFilename'] as String?;
            final markerOffsetMs = json['markerOffsetMs'] as int? ?? 0;
            final cropStartMs = json['cropStartMs'] as int? ?? 0;
            final cropEndMs = json['cropEndMs'] as int? ?? 0;
            final userSaved = json['userSaved'] as bool? ?? false;

            File? segmentFile;
            if (segmentFilename != null && segmentFilename.isNotEmpty) {
              final f = File('${dateFolder.path}/$segmentFilename');
              if (await f.exists()) segmentFile = f;
            }

            return MarkerConversation(
              markerTime: DateTime.fromMillisecondsSinceEpoch(markerMs),
              segment: segmentFile,
              markerOffsetMs: markerOffsetMs,
              cropStartMs: cropStartMs,
              cropEndMs: cropEndMs,
              edlFile: edlFile,
              userSaved: userSaved,
            );
          } catch (e) {
            Logger.error(
              'RecordingsManager: Failed to parse EDL ${edlFile.path}: $e',
            );
            return null;
          }
        });

        return await Future.wait(markerFutures);
      }),
    );

    final result = resultsNested.expand((list) => list).whereType<MarkerConversation>().toList();

    result.sort((a, b) => b.markerTime.compareTo(a.markerTime));
    return result;
  }

  /// Derives the date-folder name (YYYY-MM-DD) from epoch milliseconds.
  ///
  /// **Convention**: all date folders use the *local* timezone so that
  /// recordings appear under the date the user experienced them.  Session IDs
  /// and device markers use UTC internally, but folder placement is always
  /// local.  A recording that starts before midnight local time and ends after
  /// midnight is placed under the *start* date.
  static String _dateStringFromMillis(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

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
          (b) => !SharedPreferencesUtil().adjustmentMode || b.finalizedRecordings.isEmpty,
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
        .where((b) => b.rawSegments.isNotEmpty)
        .where(
          (b) => !SharedPreferencesUtil().adjustmentMode || b.finalizedRecordings.isEmpty,
        )
        .toList();
    if (activeBatches.isEmpty) return;
    try {
      await manager.processAll(
        activeBatches,
        (_, __) {},
        backgroundMode: false,
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
    final key = conversation.uploadKey;
    if (key != null) {
      await SharedPreferencesUtil().removeUploadedFromHeypocket({key});
    }
    final file = conversation.file;
    if (await file.exists()) {
      await file.delete();
    }
    final metaPath = '${file.path.substring(0, file.path.lastIndexOf('.'))}.meta';
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
    Logger.debug('RecordingsManager: Deleted conversation ${file.path}');
  }

  /// Deletes a marker conversation.
  static Future<void> deleteMarkerConversation(MarkerConversation mc) async {
    if (await mc.edlFile.exists()) {
      await mc.edlFile.delete();
      Logger.debug('RecordingsManager: Deleted marker conversation ${mc.edlFile.path}');
    }
  }

  /// Deletes processed recordings (.m4a/.wav/.meta/.bin) for a day.
  /// Raw segments are intentionally preserved.
  /// Safe to call while nothing is playing.
  Future<void> deleteDay(Batch batch) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory(
      '${directory.path}/recordings/${batch.dateString}',
    );
    if (await recordingsDir.exists()) {
      await recordingsDir.delete(recursive: true);
      Logger.debug(
        'RecordingsManager: Deleted processed recordings for ${batch.dateString}',
      );
    }
  }

  /// Deletes processed recordings for [batch] so the day can be reprocessed
  /// on the next swipe or force sync with current VAD settings.
  static Future<void> reprocessDay(Batch batch) async {
    if (_isProcessingAny) return;
    final manager = RecordingsManager();
    await manager.deleteDay(batch);
    notifyRecordingsChanged();
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
        final newBaseStartMs = (baseUptime * 1000) + rtcOffsetMs;
        final newBaseStartSecs = newBaseStartMs ~/ 1000;
        final targetFolder = Directory('${rawSegmentsDir.path}/$newBaseStartSecs');
        
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

        // 5. Update markers.txt inside the promoted raw folder
        final markerFile = File('${targetFolder.path}/markers.txt');
        if (await markerFile.exists()) {
          final lines = await markerFile.readAsLines();
          final List<String> newLines = [];
          for (final line in lines) {
            final parts = line.split(',');
            if (parts.isNotEmpty) {
              final oldUtc = int.tryParse(parts[0]) ?? 0;
              final newUtc = oldUtc + (rtcOffsetMs ~/ 1000);
              parts[0] = newUtc.toString();
              newLines.add(parts.join(','));
            }
          }
          await markerFile.writeAsString(newLines.map((l) => '$l\n').join(''));
        }

        // 6. Update .bin filenames in the promoted raw folder to match new UTC base
        // Format: {uptime}_{sessionId}.bin -> {newUtc}_{sessionId}.bin
        await for (final entity in targetFolder.list()) {
          if (entity is File && entity.path.endsWith('.bin')) {
            final name = entity.path.split('/').last;
            final parts = name.split('_');
            final uptime = int.tryParse(parts[0]) ?? 0;
            if (uptime < 946684800) {
              final newUtc = uptime + (rtcOffsetMs ~/ 1000);
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

  /// Deletes all raw .bin segment files and their parent device-session folders.
  /// Called after adjustment mode is turned off and any pending processing is done.
  static Future<void> deleteAllRawSegments() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawSegmentsDir = Directory('${directory.path}/raw_segments');
    if (await rawSegmentsDir.exists()) {
      await rawSegmentsDir.delete(recursive: true);
      Logger.debug(
        'RecordingsManager: Deleted all raw segments after adjustment mode exit',
      );
    }
  }
}
