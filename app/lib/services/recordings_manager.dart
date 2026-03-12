import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/offline_audio_processor.dart';
import 'package:omi/utils/logger.dart';

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
        
        // Skip the unsynced folder
        if (sessionIdStr == 'unsynced') continue;

        // 1. Process Stars
        final starFile = File('${folder.path}/stars.txt');
        if (await starFile.exists()) {
          try {
            final content = await starFile.readAsLines();
            for (var line in content) {
              final utc = int.tryParse(line.trim());
              if (utc != null) {
                final date = DateTime.fromMillisecondsSinceEpoch(utc * 1000);
                final dateString = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
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
          final dateString = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          rawChunksByDate.putIfAbsent(dateString, () => []).add(file);
        }
      }
    }

    // Process already processed recordings
    if (await recordingsDir.exists()) {
      final dateFolders = recordingsDir.listSync().whereType<Directory>();
      for (var folder in dateFolders) {
        final dateString = folder.path.split('/').last;
        final files = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.aac')).toList();
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
  Future<void> processDay(DailyBatch batch, Function(double progress) onProgress) async {
    if (batch.rawChunks.isEmpty) return;
    if (_isProcessingAny) {
      throw Exception("Another processing task is already in progress.");
    }

    _isProcessingAny = true;

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

      // 2. Initialize the OfflineAudioProcessor with temp folder
      final processor = OfflineAudioProcessor(outputDir: tempProcessingPath);

      try {
        // 3. Process each raw chunk sequentially
        for (int i = 0; i < batch.rawChunks.length; i++) {
          final file = batch.rawChunks[i];
          final bytes = await file.readAsBytes();

          // Get session ID from folder name
          final sessionIdStr = file.parent.path.split('/').last;
          int? sessionId = int.tryParse(sessionIdStr);

          DateTime chunkStartTime = file.lastModifiedSync();

          // Read frames from .bin file
          List<Uint8List> frames = [];
          int offset = 0;
          while (offset < bytes.length) {
            if (offset + 4 > bytes.length) break;
            final length = ByteData.sublistView(Uint8List.fromList(bytes.sublist(offset, offset + 4))).getUint32(0, Endian.little);
            offset += 4;
            if (offset + length > bytes.length) break;
            frames.add(bytes.sublist(offset, offset + length));
            offset += length;
          }

          await processor.processFrames(frames, chunkStartTime, sessionId: sessionId);
          onProgress((i + 1) / batch.rawChunks.length);
        }

        // 4. Flush remaining buffer
        await processor.flushRemaining();
        processor.destroy();

        // 5. ATOMIC SWAP: Success! Replace live recordings with temp ones
        final liveDir = Directory(liveRecordingsPath);
        if (await liveDir.exists()) {
          await liveDir.delete(recursive: true);
        }
        await liveDir.create(recursive: true);

        // Move files from temp to live
        final newFiles = tempDir.listSync().whereType<File>();
        for (var file in newFiles) {
          final fileName = file.path.split('/').last;
          await file.rename('$liveRecordingsPath/$fileName');
        }
        
        // Cleanup temp dir
        await tempDir.delete(recursive: true);

      } catch (e) {
        Logger.error("RecordingsManager: Processing failed for $dateString: $e");
        processor.destroy();
        // Keep old recordings intact
        rethrow;
      }

      // 6. Check adjustment mode. If OFF, delete the raw chunks.
      if (!SharedPreferencesUtil().offlineAdjustmentMode) {
        Set<String> sessionFoldersToDelete = {};
        final latestSyncedSessionId = SharedPreferencesUtil().latestSyncedSessionId;

        for (var file in batch.rawChunks) {
          if (await file.exists()) {
            final sessionIdStr = file.parent.path.split('/').last;
            final sessionId = int.tryParse(sessionIdStr) ?? -1;

            if (sessionId < latestSyncedSessionId) {
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
    } finally {
      _isProcessingAny = false;
    }
  }
}
