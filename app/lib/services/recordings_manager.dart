import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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

  const Conversation({required this.file, required this.startTime, required this.duration, this.uploadKey});

  DateTime get endTime => startTime.add(duration);
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
                uploadKey = String.fromCharCodes(metaBytes.sublist(409, 409 + keyLen));
              } catch (_) {
                uploadKey = null;
              }
            }
          }
          final effectiveKey = uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
              file: file, startTime: startTime, duration: Duration(milliseconds: durationMs), uploadKey: effectiveKey);
        }
      } catch (_) {
        // Fall through to size-based estimate
      }
    }

    // Size-based duration estimate
    final isWav = file.path.endsWith('.wav');
    int fileSize = 0;
    try {
      fileSize = await file.length();
    } catch (_) {}
    final pcmBytes = isWav && fileSize > 44 ? fileSize - 44 : 0;
    final durationMs = (pcmBytes / 32000.0 * 1000).round();
    final fallbackKey = file.path.split('/').last.split('.').first;
    return Conversation(
        file: file, startTime: startTime, duration: Duration(milliseconds: durationMs), uploadKey: fallbackKey);
  }

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
                uploadKey = String.fromCharCodes(metaBytes.sublist(409, 409 + keyLen));
              } catch (_) {
                uploadKey = null;
              }
            }
          }
          // Fall back to filename (without extension) as upload key for recordings
          // processed before the upload key was written to the .meta sidecar.
          final effectiveKey = uploadKey ?? file.path.split('/').last.split('.').first;
          return Conversation(
              file: file, startTime: startTime, duration: Duration(milliseconds: durationMs), uploadKey: effectiveKey);
        }
      } catch (_) {
        // Fall through to size-based estimate
      }
    }

    // Size-based duration estimate — only valid for WAV files.
    // For M4A/other formats without a .meta sidecar, return 0 to avoid a wildly wrong duration.
    final isWav = file.path.endsWith('.wav');
    int fileSize = 0;
    try {
      fileSize = file.lengthSync();
    } catch (_) {}
    final pcmBytes = isWav && fileSize > 44 ? fileSize - 44 : 0;
    final durationMs = (pcmBytes / 32000.0 * 1000).round();
    final fallbackKey = file.path.split('/').last.split('.').first;
    return Conversation(
        file: file, startTime: startTime, duration: Duration(milliseconds: durationMs), uploadKey: fallbackKey);
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

class RecordingsManager {
  static final RecordingsManager _instance = RecordingsManager._internal();
  factory RecordingsManager() => _instance;
  RecordingsManager._internal();

  static bool _isProcessingAny = false;
  static bool get isProcessingAny => _isProcessingAny;

  static bool _cancelRequested = false;
  static void cancelProcessing() => _cancelRequested = true;

  /// Global notification system to alert UI pages when the recordings folder
  /// has been modified (deleted, reprocessed, etc.).
  static final ValueNotifier<int> recordingsChangeNotifier = ValueNotifier(0);
  static void notifyRecordingsChanged() => recordingsChangeNotifier.value++;

  /// Call on app startup to clean up incomplete extraction from a previous crash.
  /// If the persisted extraction-in-progress flag is set, the temp directory is
  /// removed (its partial output would cause duplicates) and the flag is cleared.
  /// Raw segments are intentionally left intact so processing can be retried.
  static Future<void> cleanUpIncompleteExtraction() async {
    final prefs = SharedPreferencesUtil();
    if (!prefs.extractionInProgress) return;

    Logger.debug('RecordingsManager: Detected incomplete extraction from previous run — cleaning up temp dir.');
    try {
      final directory = await getApplicationDocumentsDirectory();
      final tempDir = Directory('${directory.path}/processing_temp');
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
        Logger.debug('RecordingsManager: Removed leftover processing_temp directory.');
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
      final deviceSessionFolders = await rawSegmentsDir.list().where((e) => e is Directory).cast<Directory>().toList();

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
            Logger.error("RecordingsManager: Failed to read markers for DeviceSession $deviceSessionIdStr: $e");
          }
        }

        // 2. Process segments
        final files = await folder.list().where((e) => e is File && e.path.endsWith('.bin')).cast<File>().toList();

        for (var file in files) {
          final date = await file.lastModified();
          final dateString =
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          rawSegmentsByDate.putIfAbsent(dateString, () => []).add(file);
        }
      }
    }

    // Process already processed recordings
    if (await recordingsDir.exists()) {
      final dateFolders = await recordingsDir.list().where((e) => e is Directory).cast<Directory>().toList();
      for (var folder in dateFolders) {
        final dateString = folder.path.split('/').last;
        final files = await folder
            .list()
            .where((e) => e is File && (e.path.endsWith('.m4a') || e.path.endsWith('.wav')))
            .cast<File>()
            .toList();
        final conversations = await Future.wait(files.map((f) => Conversation.fromFileAsync(f)));
        processedByDate[dateString] = conversations.cast<Conversation>();
      }
    }

    // Merge keys
    final allDates = {...rawSegmentsByDate.keys, ...processedByDate.keys}.toList();
    List<Batch> batches = [];

    for (var dateStr in allDates) {
      final parts = dateStr.split('-');
      final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));

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

      batches.add(Batch(
        dateString: dateStr,
        date: date,
        rawSegments: raw,
        finalizedRecordings: processedByDate[dateStr] ?? <Conversation>[],
        markerTimestamps: markersByDate[dateStr] ?? [],
      ));
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
  Future<void> processAll(List<Batch> batches, Function(double progress) onProgress,
      {bool backgroundMode = false, VoidCallback? onRecordingFinalized}) async {
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
          Logger.error('RecordingsManager: Disk space probe failed ($e). '
              'Skipping processing to preserve raw segments.');
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
        final entities = tempDir.listSync().whereType<File>().toList()
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
            final legacyWav = File('${liveDir.path}/${fileName.replaceAll('.m4a', '')}.wav');
            try {
              await legacyWav.delete();
            } on FileSystemException catch (_) {}
            onRecordingFinalized?.call();
            notifyRecordingsChanged();
          } else if (fileName.endsWith('.wav')) {
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
        return (int.tryParse(ap.length > 1 ? ap[1] : '0') ?? 0)
            .compareTo(int.tryParse(bp.length > 1 ? bp[1] : '0') ?? 0);
      });

      int lastSafeToDeleteIndex = -1;

      try {
        final processor = await VadAudioProcessor.create(outputDir: tempProcessingPath);
        try {
          for (int i = 0; i < allSegments.length; i++) {
            final file = allSegments[i];
            final stem = file.path.split('/').last.split('.').first;
            final timerStart = int.tryParse(stem.split('_').first);
            const kMinValidEpoch = 946684800;
            final segmentStartTime = timerStart != null && timerStart > kMinValidEpoch
                ? DateTime.fromMillisecondsSinceEpoch(timerStart * 1000)
                : file.lastModifiedSync();

            if (_cancelRequested) {
              Logger.debug("RecordingsManager: Processing cancelled at segment $i.");
              break;
            }

            await processor.processSegmentFile(file, segmentStartTime);
            await moveTempFilesToLive();

            if (backgroundMode && !processor.isCapturing) {
              lastSafeToDeleteIndex = i;
            }

            onProgress(((i + 1) / allSegments.length) * 0.9);
            if (!backgroundMode) await Future.delayed(const Duration(milliseconds: 50));
          }

          if (backgroundMode) {
            await processor.flushOnlyCompleted();
          } else {
            await processor.flushRemaining();
            // All intervals are now closed — every segment is safe to delete.
            lastSafeToDeleteIndex = allSegments.length - 1;
          }
          await moveTempFilesToLive();
        } finally {
          processor.destroy();
        }

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
        Logger.error("RecordingsManager: Combined processing failed: $e");
        rethrow;
      }

      // Raw segment deletion — only delete segments belonging to fully-completed intervals.
      if (lastSafeToDeleteIndex >= 0) {
        final deviceSessionFolders = <String>{};
        for (int i = 0; i <= lastSafeToDeleteIndex; i++) {
          final file = allSegments[i];
          if (await file.exists()) {
            Logger.debug("RecordingsManager: Deleting completed raw segment: ${file.path}");
            await file.delete();
            deviceSessionFolders.add(file.parent.path);
          }
        }
        for (final folderPath in deviceSessionFolders) {
          final folder = Directory(folderPath);
          if (await folder.exists()) {
            try {
              if (await folder.list().isEmpty) await folder.delete();
            } catch (_) {}
          }
        }
      }
      onProgress(1.0);
    } finally {
      _isProcessingAny = false;
      SharedPreferencesUtil().extractionInProgress = false;
    }
  }

  /// Writes EDL sidecars for all markers in [markerTimestamps] into [liveRecordingsDirPath].
  /// Idempotent: skips EDLs that already exist with non-empty segments.
  /// Resolves previously-pending EDLs (empty segments) when the backing m4a is now available.
  static Future<void> _resolveMarkerConversations(String liveRecordingsDirPath, List<DateTime> markerTimestamps) async {
    final liveDir = Directory(liveRecordingsDirPath);
    if (!await liveDir.exists() || markerTimestamps.isEmpty) return;

    // Build sorted list of (file, startMs, endMs) from m4a + .meta pairs.
    final recordings = <({File file, int startMs, int endMs, int durationMs})>[];
    for (final entity in await liveDir.list().toList()) {
      if (entity is! File || !entity.path.endsWith('.m4a')) continue;
      final name = entity.path.split('/').last;
      final startMs = int.tryParse(name.contains('_') ? name.split('_').last.split('.').first : '');
      if (startMs == null || startMs <= 0) continue;
      final metaFile = File('${entity.path.substring(0, entity.path.lastIndexOf('.'))}.meta');
      if (!await metaFile.exists()) continue;
      try {
        final bd = ByteData.sublistView(await metaFile.readAsBytes());
        if (bd.lengthInBytes < 8) continue;
        final durationMs = bd.getUint32(4, Endian.little);
        if (durationMs <= 0) continue;
        recordings.add((file: entity, startMs: startMs, endMs: startMs + durationMs, durationMs: durationMs));
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

      // 1. Exact containment: marker fired while this recording was active.
      int matchIdx = recordings.indexWhere((r) => markerMs >= r.startMs && markerMs < r.endMs);

      // 2. Prior conversation: marker fired during silence after this recording ended.
      if (matchIdx < 0) {
        for (int i = recordings.length - 1; i >= 0; i--) {
          if (recordings[i].endMs <= markerMs) {
            matchIdx = i;
            break;
          }
        }
      }

      if (matchIdx >= 0) {
        final rec = recordings[matchIdx];
        final segmentFilename = rec.file.path.split('/').last;
        // If prior match, offset points to the end of the conversation
        final markerOffsetMs = markerMs < rec.endMs ? markerMs - rec.startMs : rec.durationMs;
        final edlData = {
          'markerTimestampMs': markerMs,
          'segmentFilename': segmentFilename,
          'markerOffsetMs': markerOffsetMs,
          'cropStartMs': 0,
          'cropEndMs': rec.durationMs,
          'userSaved': false,
        };
        await edlFile.writeAsString(jsonEncode(edlData));
        Logger.debug('RecordingsManager: Wrote EDL for marker at $markerTime → $segmentFilename');
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
        Logger.debug('RecordingsManager: Wrote PENDING EDL for marker at $markerTime');
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

    final result = <MarkerConversation>[];

    for (final entity in await recordingsDir.list().toList()) {
      if (entity is! Directory) continue;
      final dateFolder = entity;

      final edlFiles = await dateFolder
          .list()
          .where((e) => e is File && e.path.split('/').last.startsWith('marker_') && e.path.endsWith('.edl'))
          .cast<File>()
          .toList();

      for (final edlFile in edlFiles) {
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

          result.add(MarkerConversation(
            markerTime: DateTime.fromMillisecondsSinceEpoch(markerMs),
            segment: segmentFile,
            markerOffsetMs: markerOffsetMs,
            cropStartMs: cropStartMs,
            cropEndMs: cropEndMs,
            edlFile: edlFile,
            userSaved: userSaved,
          ));
        } catch (e) {
          Logger.error('RecordingsManager: Failed to parse EDL ${edlFile.path}: $e');
        }
      }
    }

    result.sort((a, b) => b.markerTime.compareTo(a.markerTime));
    return result;
  }

  static int? _parseRecordingMillis(File file) {
    final name = file.path.split('/').last;
    final millisStr = name.contains('_') ? name.split('_').last.split('.').first : null;
    return millisStr != null ? int.tryParse(millisStr) : null;
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
    await enforceRetentionPolicy();
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    final safeBatches = batches
        .map((batch) {
          if (batch.rawSegments.isEmpty) return batch;
          final safeSegments = excludeNewestSegmentPerSession(batch.rawSegments);
          return Batch(
            dateString: batch.dateString,
            date: batch.date,
            rawSegments: safeSegments,
            finalizedRecordings: batch.finalizedRecordings,
            markerTimestamps: batch.markerTimestamps,
          );
        })
        .where((b) => b.rawSegments.isNotEmpty)
        .toList();
    if (safeBatches.isEmpty) return;
    try {
      await manager.processAll(safeBatches, (_) {}, backgroundMode: true);
    } catch (e) {
      Logger.error('RecordingsManager: Background processAllCompletedSessions error: $e');
    }
  }

  /// Force-process all batches including the newest segment per DeviceSession.
  /// Used by the debug Force Process button — same as pressing the Process button
  /// on each batch but operates across all days at once.
  /// No-op if a process is already running.
  static Future<void> forceProcessAll() async {
    if (_isProcessingAny) return;
    await enforceRetentionPolicy();
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    final activeBatches = batches.where((b) => b.rawSegments.isNotEmpty).toList();
    if (activeBatches.isEmpty) return;
    try {
      await manager.processAll(activeBatches, (_) {}, backgroundMode: false);
    } catch (e) {
      Logger.error('RecordingsManager: forceProcessAll error: $e');
    }
  }

  /// Returns [segments] with the highest segmentIndex file excluded per DeviceSession.
  /// Files are named `{deviceSessionId}_{segmentIndex}.bin`; the last segment per DeviceSession
  /// may still be actively written by the firmware, so we skip it.
  static List<File> excludeNewestSegmentPerSession(List<File> segments) {
    // Also exclude any segment modified within the last 5 seconds to avoid
    // processing a file that is still being written to by the sync layer.
    final recencyCutoff = DateTime.now().subtract(const Duration(seconds: 5));
    final Map<String, List<File>> byDeviceSession = {};
    for (final f in segments) {
      try {
        if (f.lastModifiedSync().isAfter(recencyCutoff)) continue;
      } catch (_) {
        continue; // File may have been deleted
      }
      final name = f.path.split('/').last;
      final deviceSessionId = name.split('_').first;
      byDeviceSession.putIfAbsent(deviceSessionId, () => []).add(f);
    }
    final result = <File>[];
    for (final deviceSessionSegments in byDeviceSession.values) {
      // Sort by segmentIndex numerically, then drop the last (highest) one.
      deviceSessionSegments.sort((a, b) {
        final aParts = a.path.split('/').last.replaceAll('.bin', '').split('_');
        final bParts = b.path.split('/').last.replaceAll('.bin', '').split('_');
        final aSegment = int.tryParse(aParts.length > 1 ? aParts[1] : '0') ?? 0;
        final bSegment = int.tryParse(bParts.length > 1 ? bParts[1] : '0') ?? 0;
        return aSegment.compareTo(bSegment);
      });
      // Only exclude the newest segment when a session has 2+ segments.
      // Single-segment sessions are completed SD-card file transfers — safe to process.
      // Very-recently-written files are already filtered by the recency cutoff above.
      if (deviceSessionSegments.length > 1) {
        result.addAll(deviceSessionSegments.take(deviceSessionSegments.length - 1));
      } else {
        result.addAll(deviceSessionSegments);
      }
    }
    // Re-sort numerically by (deviceSessionId, segmentIndex).
    result.sort((a, b) {
      final aParts = a.path.split('/').last.replaceAll('.bin', '').split('_');
      final bParts = b.path.split('/').last.replaceAll('.bin', '').split('_');
      final aSession = int.tryParse(aParts[0]) ?? 0;
      final bSession = int.tryParse(bParts[0]) ?? 0;
      if (aSession != bSession) return aSession.compareTo(bSession);
      final aSegment = int.tryParse(aParts.length > 1 ? aParts[1] : '0') ?? 0;
      final bSegment = int.tryParse(bParts.length > 1 ? bParts[1] : '0') ?? 0;
      return aSegment.compareTo(bSegment);
    });
    return result;
  }

  /// Deletes `recordings/<date>/` folders older than [recordingRetentionDays] days.
  /// Called at the start of each processing run so storage stays bounded automatically.
  static Future<void> enforceRetentionPolicy() async {
    final retentionDays = SharedPreferencesUtil().recordingRetentionDays;
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!recordingsDir.existsSync()) return;

    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    for (final entity in recordingsDir.listSync()) {
      if (entity is! Directory) continue;
      final parts = entity.path.split('/').last.split('-');
      if (parts.length != 3) continue;
      try {
        final folderDate = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        if (folderDate.isBefore(cutoff)) {
          await entity.delete(recursive: true);
          Logger.debug('RecordingsManager: Deleted recordings older than $retentionDays days: ${entity.path}');
        }
      } catch (_) {
        continue;
      }
    }
  }

  /// Deletes orphaned `.tmp.m4a` files left by interrupted encoding runs.
  /// Call once at app startup before processing begins.
  static Future<void> cleanupOrphanedTempFiles() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;
    await for (final entity in recordingsDir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.tmp.m4a')) {
        try {
          await entity.delete();
          Logger.debug('RecordingsManager: Deleted orphaned temp file ${entity.path}');
        } catch (e) {
          Logger.error('RecordingsManager: Failed to delete orphaned temp file ${entity.path}: $e');
        }
      }
    }
  }

  /// Deletes processed recordings (.m4a/.wav/.meta) for a day.
  /// Raw segments are intentionally preserved — they feed the "Building next
  /// recording" accumulating banner and will be re-processed on the next sync
  /// to complete the current 30-minute interval.
  /// Safe to call while nothing is playing.
  Future<void> deleteDay(Batch batch) async {
    final directory = await getApplicationDocumentsDirectory();

    // Delete processed recordings folder (contains .m4a, .wav, .meta files).
    // Raw segments are left intact so the in-progress interval can still complete.
    final recordingsDir = Directory('${directory.path}/recordings/${batch.dateString}');
    if (await recordingsDir.exists()) {
      await recordingsDir.delete(recursive: true);
      Logger.debug('RecordingsManager: Deleted processed recordings for ${batch.dateString}');
    }
  }
}
