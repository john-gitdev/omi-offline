import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

  const Conversation({
    required this.file,
    required this.startTime,
    required this.duration,
    this.uploadKey,
  });

  DateTime get endTime => startTime.add(duration);

  /// True when this recording was saved with an unknown timestamp (device had no RTC sync).
  bool get isUnknown => file.path.split('/').last.startsWith('unknown_');

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
          String? uploadKey;
          if (metaBytes.length >= 409) {
            final keyLen = metaBytes[408];
            if (409 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(
                  metaBytes.sublist(409, 409 + keyLen),
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
          String? uploadKey;
          if (metaBytes.length >= 409) {
            final keyLen = metaBytes[408];
            if (409 + keyLen <= metaBytes.length) {
              try {
                uploadKey = String.fromCharCodes(
                  metaBytes.sublist(409, 409 + keyLen),
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
  final List<Conversation> finalizedRecordings;
  final List<DateTime> markerTimestamps;

  Batch({
    required this.dateString,
    required this.date,
    required this.rawSegments,
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

      await processor.processSegmentFile(
        file,
        startTime,
        isDerivedTimestamp: isDerived,
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

    if (params.backgroundMode) {
      await processor.flushOnlyCompleted();
    } else {
      await processor.flushRemaining();
    }

    params.sendPort.send({'type': 'move'});

    // Final pass: release any files still held only in the rolling pre-buffer.
    // In force mode, no further marker lookbacks will occur so forceAll is safe.
    // In background mode, respect the buffer so the next run can pick up mid-session.
    final finalSafe = processor.consumeSafeToDeletePaths(
      forceAll: !params.backgroundMode && !cancelled,
    );
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

      // Sort DeviceSession folders by ID (e.g. "100", "101")
      deviceSessionFolders.sort((a, b) {
        final aId = int.tryParse(a.path.split('/').last) ?? 0;
        final bId = int.tryParse(b.path.split('/').last) ?? 0;
        return aId.compareTo(bId);
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
              final utc = int.tryParse(line.trim());
              if (utc != null) {
                final date = DateTime.fromMillisecondsSinceEpoch(utc * 1000);
                final dateString =
                    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
                markersByDate.putIfAbsent(dateString, () => []).add(date);
              }
            }
          } catch (e) {
            Logger.error(
              "RecordingsManager: Failed to read markers for DeviceSession $deviceSessionIdStr: $e",
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

      batches.add(
        Batch(
          dateString: dateStr,
          date: date,
          rawSegments: raw,
          finalizedRecordings: processedByDate[dateStr] ?? <Conversation>[],
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
            if (millis != null && millis > 0) {
              await _deleteOverlappingRecordings(liveDir, fileName, millis);
            }
            onRecordingFinalized?.call();
            notifyRecordingsChanged();
          } else if (fileName.endsWith('.wav') || fileName.endsWith('.ogg')) {
            if (millis != null && millis > 0) {
              await _deleteOverlappingRecordings(liveDir, fileName, millis);
            }
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

      // Pre-compute segment timestamps on the main isolate (lastModifiedSync is unavailable in a
      // background isolate without platform channels).
      const kMinValidEpoch = 946684800;
      final segmentStartTimesMs = <int>[];
      final segmentDerivedFlags = <bool>[];
      final segmentFileSizes = <int>[];
      for (final file in allSegments) {
        segmentFileSizes.add(file.lengthSync());
        final stem = file.path.split('/').last.split('.').first;
        final timerStart = int.tryParse(stem.split('_').first);
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
              if (_cancelRequested) _activeIsolateControlPort?.send('cancel');
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
      onProgress(1.0, Duration.zero);
    } finally {
      _isProcessingAny = false;
      processingProgress.value = 0.0;
      SharedPreferencesUtil().extractionInProgress = false;
    }
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
    final recordings = <({File file, int startMs, int endMs, int durationMs})>[];
    for (final entity in await liveDir.list().toList()) {
      if (entity is! File || (!entity.path.endsWith('.m4a') && !entity.path.endsWith('.ogg'))) continue;
      final name = entity.path.split('/').last;
      final startMs = int.tryParse(
        name.contains('_') ? name.split('_').last.split('.').first : '',
      );
      if (startMs == null || startMs <= 0) continue;
      final metaFile = File(
        '${entity.path.substring(0, entity.path.lastIndexOf('.'))}.meta',
      );
      if (!await metaFile.exists()) continue;
      try {
        final bd = ByteData.sublistView(await metaFile.readAsBytes());
        if (bd.lengthInBytes < 8) continue;
        final durationMs = bd.getUint32(4, Endian.little);
        if (durationMs <= 0) continue;
        recordings.add((
          file: entity,
          startMs: startMs,
          endMs: startMs + durationMs,
          durationMs: durationMs,
        ));
      } catch (_) {}
    }
    recordings.sort((a, b) => a.startMs.compareTo(b.startMs));

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
      // produced from the audio around that time. Markers whose audio hasn't been
      // processed yet stay pending until a future sync+process run covers that range.
      final matchIdx = recordings.indexWhere(
        (r) => markerMs >= r.startMs && markerMs < r.endMs,
      );

      if (matchIdx >= 0) {
        final rec = recordings[matchIdx];
        final segmentFilename = rec.file.path.split('/').last;
        final markerOffsetMs = markerMs - rec.startMs;
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

  /// Removes recordings in [liveDir] that overlap in time with the newly placed
  /// [newFileName] (which starts at [newStartMs]). Reads duration from the
  /// `.meta` sidecar, which must already be in [liveDir] before this is called.
  /// Overlapping old recordings are deleted (audio + meta + bin sidecar).
  static Future<void> _deleteOverlappingRecordings(Directory liveDir, String newFileName, int newStartMs) async {
    final baseName = newFileName.contains('.') ? newFileName.substring(0, newFileName.lastIndexOf('.')) : newFileName;
    final newMetaFile = File('${liveDir.path}/$baseName.meta');
    if (!await newMetaFile.exists()) return;

    int newDurationMs;
    try {
      final bd = ByteData.sublistView(await newMetaFile.readAsBytes());
      if (bd.lengthInBytes < 8) return;
      newDurationMs = bd.getUint32(4, Endian.little);
    } catch (_) {
      return;
    }
    if (newDurationMs <= 0) return;
    final newEndMs = newStartMs + newDurationMs;

    final entities = await liveDir.list().toList();
    for (final entity in entities) {
      if (entity is! File) continue;
      final name = entity.path.split('/').last;
      if (name == newFileName) continue;
      if (!name.endsWith('.m4a') && !name.endsWith('.wav') && !name.endsWith('.ogg')) continue;

      final parts = name.split('_');
      final existStartMs = parts.length >= 2 ? int.tryParse(parts.last.split('.').first) : null;
      if (existStartMs == null || existStartMs <= 0) continue;

      final existBase = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      final existMetaFile = File('${liveDir.path}/$existBase.meta');
      if (!await existMetaFile.exists()) continue;

      int existDurationMs;
      try {
        final bd = ByteData.sublistView(await existMetaFile.readAsBytes());
        if (bd.lengthInBytes < 8) continue;
        existDurationMs = bd.getUint32(4, Endian.little);
      } catch (_) {
        continue;
      }
      if (existDurationMs <= 0) continue;
      final existEndMs = existStartMs + existDurationMs;

      final overlaps = existStartMs < newEndMs && existEndMs > newStartMs;
      if (!overlaps) continue;

      Logger.debug(
        'RecordingsManager: Removing overlapping recording $name '
        '(${existStartMs}–${existEndMs}) conflicts with new $newFileName (${newStartMs}–${newEndMs})',
      );
      try {
        await entity.delete();
      } catch (_) {}
      try {
        await existMetaFile.delete();
      } catch (_) {}
      try {
        final ts = existBase.split('_').last;
        final binFile = File('${liveDir.path}/recording_fs320_$ts.bin');
        if (await binFile.exists()) await binFile.delete();
      } catch (_) {}
    }
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
