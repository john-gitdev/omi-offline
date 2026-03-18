import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/manual_recording_extractor.dart';
import 'package:omi/services/offline_audio_processor.dart';
import 'package:omi/utils/logger.dart';

/// Parsed metadata for a single processed recording (M4A or WAV).
class RecordingInfo {
  final File file;
  final DateTime startTime;
  final Duration duration;
  final String? uploadKey;

  const RecordingInfo({required this.file, required this.startTime, required this.duration, this.uploadKey});

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
  static RecordingInfo fromFile(File file) {
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
          return RecordingInfo(
              file: file, startTime: startTime, duration: Duration(milliseconds: durationMs), uploadKey: effectiveKey);
        }
      } catch (_) {
        // Fall through to size-based estimate
      }
    }

    // WAV fallback: duration from file size (44-byte header + PCM at 16 kHz mono 16-bit)
    int fileSize = 0;
    try {
      fileSize = file.lengthSync();
    } catch (_) {}
    final pcmBytes = fileSize > 44 ? fileSize - 44 : 0;
    final durationMs = (pcmBytes / 32000.0 * 1000).round();
    final fallbackKey = file.path.split('/').last.split('.').first;
    return RecordingInfo(
        file: file, startTime: startTime, duration: Duration(milliseconds: durationMs), uploadKey: fallbackKey);
  }

  String get timeRangeLabel {
    String fmt(DateTime dt) => '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '${fmt(startTime)} – ${fmt(endTime)}';
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

class DailyBatch {
  final String dateString;
  final DateTime date;
  final List<File> rawChunks;
  final List<File> processedRecordings;
  final List<DateTime> starredTimestamps;

  DailyBatch({
    required this.dateString,
    required this.date,
    required this.rawChunks,
    required this.processedRecordings,
    this.starredTimestamps = const [],
  });
}

class RecordingsManager {
  static final RecordingsManager _instance = RecordingsManager._internal();
  factory RecordingsManager() => _instance;
  RecordingsManager._internal();

  static bool _isProcessingAny = false;
  static bool get isProcessingAny => _isProcessingAny;

  static bool _cancelRequested = false;
  static void cancelProcessing() => _cancelRequested = true;

  Future<List<DailyBatch>> getDailyBatches() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawChunksDir = Directory('${directory.path}/raw_chunks');
    final recordingsDir = Directory('${directory.path}/recordings');

    Map<String, List<File>> rawChunksByDate = {};
    Map<String, List<File>> processedByDate = {};
    Map<String, List<DateTime>> starsByDate = {};

    // Process raw chunks (Now they are in Session Folders!)
    if (await rawChunksDir.exists()) {
      final sessionFolders = rawChunksDir.listSync().whereType<Directory>().toList();

      // Sort session folders by ID (e.g. "100", "101")
      sessionFolders.sort((a, b) {
        final aId = int.tryParse(a.path.split('/').last) ?? 0;
        final bId = int.tryParse(b.path.split('/').last) ?? 0;
        return aId.compareTo(bId);
      });

      for (var folder in sessionFolders) {
        final sessionIdStr = folder.path.split('/').last;

        // Skip hidden folders or system folders if any
        if (sessionIdStr.startsWith('.')) continue;

        // 1. Process Stars
        final starFile = File('${folder.path}/stars.txt');
        if (await starFile.exists()) {
          try {
            final content = await starFile.readAsLines();
            for (var line in content) {
              final utc = int.tryParse(line.trim());
              if (utc != null) {
                final date = DateTime.fromMillisecondsSinceEpoch(utc * 1000);
                final dateString =
                    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
                starsByDate.putIfAbsent(dateString, () => []).add(date);
              }
            }
          } catch (e) {
            Logger.error("RecordingsManager: Failed to read stars for session $sessionIdStr: $e");
          }
        }

        // 2. Process chunks
        final files = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.bin')).toList();

        for (var file in files) {
          final date = file.lastModifiedSync();
          final dateString =
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          rawChunksByDate.putIfAbsent(dateString, () => []).add(file);
        }
      }
    }

    // Process already processed recordings
    if (await recordingsDir.exists()) {
      final dateFolders = recordingsDir.listSync().whereType<Directory>();
      for (var folder in dateFolders) {
        final dateString = folder.path.split('/').last;
        final files = folder
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.m4a') || f.path.endsWith('.wav'))
            .toList();
        processedByDate[dateString] = files;
      }
    }

    // Merge keys
    final allDates = {...rawChunksByDate.keys, ...processedByDate.keys}.toList();
    List<DailyBatch> batches = [];

    for (var dateStr in allDates) {
      final parts = dateStr.split('-');
      final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));

      final raw = rawChunksByDate[dateStr] ?? [];
      // Sort raw chunks by name (which is chunkIndex)
      raw.sort((a, b) => a.path.split('/').last.compareTo(b.path.split('/').last));

      batches.add(DailyBatch(
        dateString: dateStr,
        date: date,
        rawChunks: raw,
        processedRecordings: processedByDate[dateStr] ?? [],
        starredTimestamps: starsByDate[dateStr] ?? [],
      ));
    }

    batches.sort((a, b) => b.date.compareTo(a.date));
    return batches;
  }

  /// Reprocesses or processes a specific day's raw chunks.
  /// Uses a temporary folder to ensure processing is atomic.
  ///
  /// In [backgroundMode]:
  /// - Does not call [flushRemaining]; only fully-completed conversations are written.
  /// - Deletes only chunks whose conversations closed cleanly (up to [lastSafeToDeleteIndex]).
  /// - Skips the 50 ms UI-yield delay.
  Future<void> processDay(DailyBatch batch, Function(double progress) onProgress, {bool backgroundMode = false}) async {
    if (batch.rawChunks.isEmpty) return;
    if (_isProcessingAny) {
      throw Exception("Another processing task is already in progress.");
    }

    _isProcessingAny = true;
    _cancelRequested = false;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final dateString = batch.dateString;
      final liveRecordingsPath = '${directory.path}/recordings/$dateString';
      final tempProcessingPath = '${directory.path}/processing_temp/$dateString';

      // 1. Clear any leftover temp processing folder
      final tempDir = Directory(tempProcessingPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);

      // In adjustment mode, wipe existing processed recordings before reprocessing
      // so old conversations don't accumulate alongside the new ones.
      if (SharedPreferencesUtil().offlineAdjustmentMode) {
        final liveDir = Directory(liveRecordingsPath);
        if (await liveDir.exists()) {
          await liveDir.delete(recursive: true);
          Logger.debug('RecordingsManager: Cleared existing recordings for $dateString (adjustment mode)');
        }
      }

      // 2. Route to automatic (VAD) or manual (star-marker) processing.
      // Both paths write output files to tempProcessingPath; the move-to-live
      // block below runs for both.
      int lastSafeToDeleteIndex = -1;
      final isManualMode = SharedPreferencesUtil().offlineRecordingMode == 'manual';

      try {
        if (isManualMode) {
          // Manual mode: star-marker extraction via ManualRecordingExtractor.
          // Produces recordings only for conversations the user explicitly starred.
          // Always keeps a 2hr rolling buffer of raw chunks for future star markers.
          final extractor = ManualRecordingExtractor();
          try {
            final result = await extractor.process(batch, tempProcessingPath, forceFlush: !backgroundMode);
            lastSafeToDeleteIndex = result.lastSafeChunkIndex;
            Logger.debug(
                'RecordingsManager: Manual mode extracted ${result.savedPaths.length} conversations for $dateString');
          } finally {
            extractor.destroy();
          }
        } else {
          // Automatic mode: continuous VAD via OfflineAudioProcessor.
          final processor = OfflineAudioProcessor(outputDir: tempProcessingPath);
          try {
            // 3. Process each raw chunk sequentially
            for (int i = 0; i < batch.rawChunks.length; i++) {
              final file = batch.rawChunks[i];
              // Get session ID from folder name
              final sessionIdStr = file.parent.path.split('/').last;
              int? sessionId = int.tryParse(sessionIdStr);

              // Parse chunkIndex from filename: stored as {sessionId}_{chunkIndex}.bin
              final chunkFileName = file.path.split('/').last.replaceAll('.bin', '');
              final chunkIndexStr = chunkFileName.contains('_') ? chunkFileName.split('_').last : null;
              final chunkIndex = chunkIndexStr != null ? int.tryParse(chunkIndexStr) : null;

              DateTime chunkStartTime;
              if (sessionId != null && chunkIndex != null) {
                final anchorUtc =
                    SharedPreferencesUtil().getInt('anchor_utc_${sessionId}_$chunkIndex', defaultValue: 0);
                final anchorUptime =
                    SharedPreferencesUtil().getInt('anchor_uptime_${sessionId}_$chunkIndex', defaultValue: 0);
                if (anchorUtc > 0) {
                  chunkStartTime = DateTime.fromMillisecondsSinceEpoch(anchorUtc * 1000);
                } else if (anchorUptime > 0) {
                  // No RTC lock at record time — back-calculate from session-level anchor
                  final sessionAnchorUtc = SharedPreferencesUtil().getInt('anchor_utc_$sessionId', defaultValue: 0);
                  final sessionAnchorUptime =
                      SharedPreferencesUtil().getInt('anchor_uptime_$sessionId', defaultValue: 0);
                  if (sessionAnchorUtc > 0 && sessionAnchorUptime > 0) {
                    final realUtcSecs = sessionAnchorUtc - ((sessionAnchorUptime - anchorUptime) ~/ 1000);
                    chunkStartTime = DateTime.fromMillisecondsSinceEpoch(realUtcSecs * 1000);
                  } else {
                    chunkStartTime = file.lastModifiedSync();
                  }
                } else {
                  chunkStartTime = file.lastModifiedSync();
                }
              } else {
                chunkStartTime = file.lastModifiedSync();
              }

              if (_cancelRequested) {
                Logger.debug("RecordingsManager: Processing cancelled by user at chunk $i.");
                break;
              }

              await processor.processChunkFile(file, chunkStartTime, sessionId: sessionId);

              if (backgroundMode && !processor.hasOngoingRecording) {
                lastSafeToDeleteIndex = i;
              }

              onProgress((i + 1) / batch.rawChunks.length);
              // Yield to the UI to keep it responsive (skipped in background mode)
              if (!backgroundMode) await Future.delayed(const Duration(milliseconds: 50));
            }

            // 4. Flush buffer
            if (backgroundMode) {
              await processor.flushOnlyCompleted(); // keep in-progress tail
            } else {
              await processor.flushRemaining();
            }
          } finally {
            processor.destroy();
          }
        }

        // 5. Move new recordings into the live folder.
        // We APPEND rather than replace so that recordings from a previous sync
        // (already processed and stored in liveDir) are preserved.  Each sync
        // only downloads data the device hasn't sent before, so the generated
        // filenames will be distinct timestamps and won't collide.
        final liveDir = Directory(liveRecordingsPath);
        final newFiles = tempDir.listSync().whereType<File>().toList();
        Logger.debug(
            "RecordingsManager: Processing complete for $dateString. Found ${newFiles.length} recordings in temp.");

        await liveDir.create(recursive: true);

        // Move files from temp to live
        for (var file in newFiles) {
          final fileName = file.path.split('/').last;
          final dest = '$liveRecordingsPath/$fileName';
          // If a file with the same name already exists (re-process of identical
          // data), overwrite it rather than failing.
          final destFile = File(dest);
          if (await destFile.exists()) await destFile.delete();

          // When placing a new .m4a, remove any legacy .wav with the same timestamp
          // prefix to avoid both formats coexisting after re-processing.
          if (fileName.endsWith('.m4a')) {
            final tsPrefix = fileName.replaceAll('.m4a', '');
            final legacyWav = File('$liveRecordingsPath/$tsPrefix.wav');
            if (await legacyWav.exists()) await legacyWav.delete();
          }

          await file.rename(dest);
        }

        // Final flush and a small delay to ensure FS is ready
        await Future.delayed(const Duration(milliseconds: 200));

        // Cleanup temp dir
        Logger.debug("RecordingsManager: Moved ${newFiles.length} recordings to live folder for $dateString.");
        await tempDir.delete(recursive: true);
      } catch (e) {
        Logger.error("RecordingsManager: Processing failed for $dateString: $e");
        // Keep old recordings intact
        rethrow;
      }

      // 6. Raw chunk deletion
      // Manual mode always uses lastSafeToDeleteIndex (same as background mode path)
      // because the extractor manages its own rolling buffer and returns a precise boundary.
      if (backgroundMode || isManualMode) {
        // Delete only chunks belonging to fully-completed conversations.
        // If adjustment mode is ON, keep everything for re-processing.
        if (!SharedPreferencesUtil().offlineAdjustmentMode && lastSafeToDeleteIndex >= 0) {
          Set<String> sessionFoldersToDelete = {};
          for (int i = 0; i <= lastSafeToDeleteIndex; i++) {
            final file = batch.rawChunks[i];
            if (await file.exists()) {
              final sessionIdStr = file.parent.path.split('/').last;
              final sessionId = int.tryParse(sessionIdStr) ?? -1;
              Logger.debug("RecordingsManager: [bg] Deleting completed raw chunk: ${file.path}");
              await file.delete();
              sessionFoldersToDelete.add(file.parent.path);
              SharedPreferencesUtil().remove('anchor_utc_$sessionId');
              SharedPreferencesUtil().remove('anchor_uptime_$sessionId');
            }
          }
          for (var folderPath in sessionFoldersToDelete) {
            final folder = Directory(folderPath);
            if (await folder.exists()) {
              try {
                if ((await folder.list().isEmpty)) {
                  await folder.delete();
                }
              } catch (e) {
                // Ignore if folder is not empty or cannot be deleted
              }
            }
          }
        }
      } else {
        // 6. Check adjustment mode. If OFF, delete the raw chunks.
        // Note: processed recordings (.wav) are kept until the user explicitly deletes
        // the day via deleteDay(). Raw chunks are separate from processed recordings.
        if (!SharedPreferencesUtil().offlineAdjustmentMode) {
          Set<String> sessionFoldersToDelete = {};
          final latestSyncedSessionId = SharedPreferencesUtil().latestSyncedSessionId;

          for (var file in batch.rawChunks) {
            if (await file.exists()) {
              final sessionIdStr = file.parent.path.split('/').last;
              final sessionId = int.tryParse(sessionIdStr) ?? -1;

              // Delete if it's an old session OR if it's the latest session but we've successfully processed it.
              // We only keep it if sessionId > latestSyncedSessionId (which shouldn't happen for synced chunks).
              if (sessionId <= latestSyncedSessionId) {
                Logger.debug("RecordingsManager: Deleting successfully processed raw chunk: ${file.path}");
                await file.delete();
                sessionFoldersToDelete.add(file.parent.path);

                // Cleanup SharedPreferences anchors
                SharedPreferencesUtil().remove('anchor_utc_$sessionId');
                SharedPreferencesUtil().remove('anchor_uptime_$sessionId');
              } else {
                Logger.debug("RecordingsManager: Keeping raw chunk for session $sessionId as it might be ongoing.");
              }
            }
          }

          for (var folderPath in sessionFoldersToDelete) {
            final folder = Directory(folderPath);
            if (await folder.exists()) {
              try {
                if ((await folder.list().isEmpty)) {
                  await folder.delete();
                }
              } catch (e) {
                // Ignore if folder is not empty or cannot be deleted
              }
            }
          }
        }
      }
    } finally {
      _isProcessingAny = false;
    }
  }

  /// Processes all batches as one continuous audio stream.
  ///
  /// Chunks are sorted by (sessionId, chunkIndex) across all batches so a
  /// recording that spans midnight is never artificially cut. Output files are
  /// moved into `recordings/<date>/` based on each recording's actual start
  /// timestamp, not the batch date they were grouped under.
  Future<void> processAll(List<DailyBatch> batches, Function(double progress) onProgress,
      {bool backgroundMode = false}) async {
    final activeBatches = batches.where((b) => b.rawChunks.isNotEmpty).toList();
    if (activeBatches.isEmpty) return;
    if (_isProcessingAny) throw Exception("Another processing task is already in progress.");

    _isProcessingAny = true;
    _cancelRequested = false;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final tempProcessingPath = '${directory.path}/processing_temp/combined';
      final tempDir = Directory(tempProcessingPath);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      await tempDir.create(recursive: true);

      // Combine chunks from all batches, sorted by (sessionId, chunkIndex).
      final allChunks = activeBatches.expand((b) => b.rawChunks).toList();
      allChunks.sort((a, b) {
        final ap = a.path.split('/').last.replaceAll('.bin', '').split('_');
        final bp = b.path.split('/').last.replaceAll('.bin', '').split('_');
        final as_ = int.tryParse(ap[0]) ?? 0;
        final bs_ = int.tryParse(bp[0]) ?? 0;
        if (as_ != bs_) return as_.compareTo(bs_);
        return (int.tryParse(ap.length > 1 ? ap[1] : '0') ?? 0)
            .compareTo(int.tryParse(bp.length > 1 ? bp[1] : '0') ?? 0);
      });

      if (SharedPreferencesUtil().offlineAdjustmentMode) {
        for (final batch in activeBatches) {
          final liveDir = Directory('${directory.path}/recordings/${batch.dateString}');
          if (await liveDir.exists()) {
            await liveDir.delete(recursive: true);
            Logger.debug('RecordingsManager: Cleared existing recordings for ${batch.dateString} (adjustment mode)');
          }
        }
      }

      int lastSafeToDeleteIndex = -1;
      final isManualMode = SharedPreferencesUtil().offlineRecordingMode == 'manual';

      try {
        if (isManualMode) {
          final combinedBatch = DailyBatch(
            dateString: activeBatches.last.dateString, // oldest date
            date: activeBatches.last.date,
            rawChunks: allChunks,
            processedRecordings: const [],
            starredTimestamps: (activeBatches.expand((b) => b.starredTimestamps).toList()..sort()),
          );
          final extractor = ManualRecordingExtractor();
          try {
            final result = await extractor.process(combinedBatch, tempProcessingPath, forceFlush: !backgroundMode);
            lastSafeToDeleteIndex = result.lastSafeChunkIndex;
            Logger.debug(
                'RecordingsManager: Manual mode extracted ${result.savedPaths.length} conversations (combined)');
          } finally {
            extractor.destroy();
          }
        } else {
          final processor = OfflineAudioProcessor(outputDir: tempProcessingPath);
          try {
            for (int i = 0; i < allChunks.length; i++) {
              final file = allChunks[i];
              final sessionIdStr = file.parent.path.split('/').last;
              final sessionId = int.tryParse(sessionIdStr);
              final chunkFileName = file.path.split('/').last.replaceAll('.bin', '');
              final chunkIndexStr = chunkFileName.contains('_') ? chunkFileName.split('_').last : null;
              final chunkIndex = chunkIndexStr != null ? int.tryParse(chunkIndexStr) : null;

              DateTime chunkStartTime;
              if (sessionId != null && chunkIndex != null) {
                final anchorUtc =
                    SharedPreferencesUtil().getInt('anchor_utc_${sessionId}_$chunkIndex', defaultValue: 0);
                final anchorUptime =
                    SharedPreferencesUtil().getInt('anchor_uptime_${sessionId}_$chunkIndex', defaultValue: 0);
                if (anchorUtc > 0) {
                  chunkStartTime = DateTime.fromMillisecondsSinceEpoch(anchorUtc * 1000);
                } else if (anchorUptime > 0) {
                  final sessionAnchorUtc = SharedPreferencesUtil().getInt('anchor_utc_$sessionId', defaultValue: 0);
                  final sessionAnchorUptime =
                      SharedPreferencesUtil().getInt('anchor_uptime_$sessionId', defaultValue: 0);
                  if (sessionAnchorUtc > 0 && sessionAnchorUptime > 0) {
                    final realUtcSecs = sessionAnchorUtc - ((sessionAnchorUptime - anchorUptime) ~/ 1000);
                    chunkStartTime = DateTime.fromMillisecondsSinceEpoch(realUtcSecs * 1000);
                  } else {
                    chunkStartTime = file.lastModifiedSync();
                  }
                } else {
                  chunkStartTime = file.lastModifiedSync();
                }
              } else {
                chunkStartTime = file.lastModifiedSync();
              }

              if (_cancelRequested) {
                Logger.debug("RecordingsManager: Processing cancelled at chunk $i.");
                break;
              }

              await processor.processChunkFile(file, chunkStartTime, sessionId: sessionId);

              if (backgroundMode && !processor.hasOngoingRecording) {
                lastSafeToDeleteIndex = i;
              }

              onProgress((i + 1) / allChunks.length);
              if (!backgroundMode) await Future.delayed(const Duration(milliseconds: 50));
            }

            if (backgroundMode) {
              await processor.flushOnlyCompleted();
            } else {
              await processor.flushRemaining();
            }
          } finally {
            processor.destroy();
          }
        }

        // Move output files to live folders based on each recording's actual start date.
        final newFiles = tempDir.listSync().whereType<File>().toList();
        Logger.debug("RecordingsManager: Combined processing complete. ${newFiles.length} recordings produced.");
        for (final file in newFiles) {
          final fileName = file.path.split('/').last;
          final parts = fileName.split('_');
          final millis = parts.length >= 2 ? int.tryParse(parts.last.split('.').first) : null;
          final dateStr =
              (millis != null && millis > 0) ? _dateStringFromMillis(millis) : activeBatches.last.dateString;
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          final destFile = File(dest);
          if (await destFile.exists()) await destFile.delete();
          if (fileName.endsWith('.m4a')) {
            final legacyWav = File('${liveDir.path}/${fileName.replaceAll('.m4a', '')}.wav');
            if (await legacyWav.exists()) await legacyWav.delete();
          }
          await file.rename(dest);
        }

        await Future.delayed(const Duration(milliseconds: 200));
        await tempDir.delete(recursive: true);
      } catch (e) {
        Logger.error("RecordingsManager: Combined processing failed: $e");
        rethrow;
      }

      // Raw chunk deletion — same rules as processDay.
      if (backgroundMode || isManualMode) {
        if (!SharedPreferencesUtil().offlineAdjustmentMode && lastSafeToDeleteIndex >= 0) {
          final sessionFolders = <String>{};
          for (int i = 0; i <= lastSafeToDeleteIndex; i++) {
            final file = allChunks[i];
            if (await file.exists()) {
              final sessionId = int.tryParse(file.parent.path.split('/').last) ?? -1;
              Logger.debug("RecordingsManager: [bg] Deleting completed raw chunk: ${file.path}");
              await file.delete();
              sessionFolders.add(file.parent.path);
              SharedPreferencesUtil().remove('anchor_utc_$sessionId');
              SharedPreferencesUtil().remove('anchor_uptime_$sessionId');
            }
          }
          for (final folderPath in sessionFolders) {
            final folder = Directory(folderPath);
            if (await folder.exists()) {
              try {
                if (await folder.list().isEmpty) await folder.delete();
              } catch (_) {}
            }
          }
        }
      } else {
        if (!SharedPreferencesUtil().offlineAdjustmentMode) {
          final sessionFolders = <String>{};
          final latestSyncedSessionId = SharedPreferencesUtil().latestSyncedSessionId;
          for (final file in allChunks) {
            if (await file.exists()) {
              final sessionId = int.tryParse(file.parent.path.split('/').last) ?? -1;
              if (sessionId <= latestSyncedSessionId) {
                Logger.debug("RecordingsManager: Deleting successfully processed raw chunk: ${file.path}");
                await file.delete();
                sessionFolders.add(file.parent.path);
                SharedPreferencesUtil().remove('anchor_utc_$sessionId');
                SharedPreferencesUtil().remove('anchor_uptime_$sessionId');
              } else {
                Logger.debug("RecordingsManager: Keeping raw chunk for session $sessionId (may be ongoing).");
              }
            }
          }
          for (final folderPath in sessionFolders) {
            final folder = Directory(folderPath);
            if (await folder.exists()) {
              try {
                if (await folder.list().isEmpty) await folder.delete();
              } catch (_) {}
            }
          }
        }
      }
    } finally {
      _isProcessingAny = false;
    }
  }

  static String _dateStringFromMillis(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  /// Background auto-process: processes all batches as one continuous stream.
  /// Skips the newest chunk per session (may still be written by firmware).
  /// Safe to call from a background timer; no-op if a manual process is running.
  static Future<void> processAllCompletedSessions() async {
    if (_isProcessingAny) return;
    final manager = RecordingsManager();
    final batches = await manager.getDailyBatches();
    final safeBatches = batches
        .map((batch) {
          if (batch.rawChunks.isEmpty) return batch;
          final safeChunks = excludeNewestChunkPerSession(batch.rawChunks);
          return DailyBatch(
            dateString: batch.dateString,
            date: batch.date,
            rawChunks: safeChunks,
            processedRecordings: batch.processedRecordings,
            starredTimestamps: batch.starredTimestamps,
          );
        })
        .where((b) => b.rawChunks.isNotEmpty)
        .toList();
    if (safeBatches.isEmpty) return;
    try {
      await manager.processAll(safeBatches, (_) {}, backgroundMode: true);
    } catch (e) {
      Logger.error('RecordingsManager: Background processAllCompletedSessions error: $e');
    }
  }

  /// Force-process all batches including the newest chunk per session.
  /// Used by the debug Force Process button — same as pressing the Process button
  /// on each batch but operates across all days at once.
  /// No-op if a process is already running.
  static Future<void> forceProcessAll() async {
    if (_isProcessingAny) return;
    final manager = RecordingsManager();
    final batches = await manager.getDailyBatches();
    final activeBatches = batches.where((b) => b.rawChunks.isNotEmpty).toList();
    if (activeBatches.isEmpty) return;
    try {
      await manager.processAll(activeBatches, (_) {}, backgroundMode: false);
    } catch (e) {
      Logger.error('RecordingsManager: forceProcessAll error: $e');
    }
  }

  /// Returns [chunks] with the highest chunkIndex file excluded per session.
  /// Files are named `{sessionId}_{chunkIndex}.bin`; the last chunk per session
  /// may still be actively written by the firmware, so we skip it.
  static List<File> excludeNewestChunkPerSession(List<File> chunks) {
    final Map<String, List<File>> bySession = {};
    for (final f in chunks) {
      final name = f.path.split('/').last;
      final sessionId = name.split('_').first;
      bySession.putIfAbsent(sessionId, () => []).add(f);
    }
    final result = <File>[];
    for (final sessionChunks in bySession.values) {
      // Sort by chunkIndex numerically, then drop the last (highest) one.
      sessionChunks.sort((a, b) {
        final aParts = a.path.split('/').last.replaceAll('.bin', '').split('_');
        final bParts = b.path.split('/').last.replaceAll('.bin', '').split('_');
        final aChunk = int.tryParse(aParts.length > 1 ? aParts[1] : '0') ?? 0;
        final bChunk = int.tryParse(bParts.length > 1 ? bParts[1] : '0') ?? 0;
        return aChunk.compareTo(bChunk);
      });
      result.addAll(sessionChunks.take(sessionChunks.length - 1));
    }
    // Re-sort numerically by (sessionId, chunkIndex).
    result.sort((a, b) {
      final aParts = a.path.split('/').last.replaceAll('.bin', '').split('_');
      final bParts = b.path.split('/').last.replaceAll('.bin', '').split('_');
      final aSession = int.tryParse(aParts[0]) ?? 0;
      final bSession = int.tryParse(bParts[0]) ?? 0;
      if (aSession != bSession) return aSession.compareTo(bSession);
      final aChunk = int.tryParse(aParts.length > 1 ? aParts[1] : '0') ?? 0;
      final bChunk = int.tryParse(bParts.length > 1 ? bParts[1] : '0') ?? 0;
      return aChunk.compareTo(bChunk);
    });
    return result;
  }

  /// Deletes orphaned `.tmp.m4a` files left by interrupted encoding sessions.
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

  /// Deletes all processed recordings (.m4a/.wav) and their .meta sidecars for a
  /// day, plus any remaining raw chunks and their session folders.
  /// Safe to call while nothing is playing.
  Future<void> deleteDay(DailyBatch batch) async {
    final directory = await getApplicationDocumentsDirectory();

    // 1. Delete processed recordings folder (contains .m4a, .wav, .meta files)
    final recordingsDir = Directory('${directory.path}/recordings/${batch.dateString}');
    if (await recordingsDir.exists()) {
      await recordingsDir.delete(recursive: true);
      Logger.debug('RecordingsManager: Deleted processed recordings for ${batch.dateString}');
    }

    // 2. Delete raw chunks only when adjustment mode is OFF.
    //    In adjustment mode the user may want to re-process, so keep the chunks.
    if (!SharedPreferencesUtil().offlineAdjustmentMode) {
      final Set<String> sessionFolderPaths = {};
      for (var file in batch.rawChunks) {
        if (await file.exists()) {
          final sessionIdStr = file.parent.path.split('/').last;
          final sessionId = int.tryParse(sessionIdStr) ?? -1;
          await file.delete();
          sessionFolderPaths.add(file.parent.path);
          SharedPreferencesUtil().remove('anchor_utc_$sessionId');
          SharedPreferencesUtil().remove('anchor_uptime_$sessionId');
        }
      }

      // 3. Remove now-empty session folders
      for (var folderPath in sessionFolderPaths) {
        final folder = Directory(folderPath);
        if (await folder.exists() && await folder.list().isEmpty) {
          await folder.delete();
        }
      }
    }
  }
}
