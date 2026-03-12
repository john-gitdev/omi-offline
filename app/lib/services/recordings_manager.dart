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

  DailyBatch({
    required this.dateString,
    required this.date,
    required this.rawChunks,
    required this.processedRecordings,
  });
}

class RecordingsManager {
  static final RecordingsManager _instance = RecordingsManager._internal();
  factory RecordingsManager() => _instance;
  RecordingsManager._internal();

  Future<List<DailyBatch>> getDailyBatches() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawChunksDir = Directory('${directory.path}/raw_chunks');
    final recordingsDir = Directory('${directory.path}/recordings');

    Map<String, DailyBatch> batchesMap = {};

    // Helper to get date from folder name YYYY-MM-DD
    DateTime? parseDate(String folderName) {
      try {
        final parts = folderName.split('-');
        if (parts.length == 3) {
          return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        }
      } catch (e) {
        // Ignored
      }
      return null;
    }

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

        // Try to determine the real date from the anchor
        final anchorUtc = SharedPreferencesUtil().getInt('anchor_utc_$sessionIdStr', defaultValue: 0);
        
        DateTime chunkDate;
        if (anchorUtc > 0) {
          chunkDate = DateTime.fromMillisecondsSinceEpoch(anchorUtc * 1000);
        } else {
          // Fallback if no anchor yet (or device still unsynced)
          chunkDate = DateTime.now(); // Should maybe be something else, but works for grouping
        }
        
        final dateString = '${chunkDate.year}-${chunkDate.month.toString().padLeft(2, '0')}-${chunkDate.day.toString().padLeft(2, '0')}';

        final chunks = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.bin')).toList();
        
        // Sort chunks by their index (e.g. "12345_1.bin", "12345_2.bin")
        chunks.sort((a, b) {
          final aName = a.path.split('/').last.replaceAll('.bin', '');
          final bName = b.path.split('/').last.replaceAll('.bin', '');
          final aIndex = int.tryParse(aName.split('_').last) ?? 0;
          final bIndex = int.tryParse(bName.split('_').last) ?? 0;
          return aIndex.compareTo(bIndex);
        });

        if (chunks.isNotEmpty) {
          if (batchesMap.containsKey(dateString)) {
            batchesMap[dateString]!.rawChunks.addAll(chunks);
          } else {
            batchesMap[dateString] = DailyBatch(
              dateString: dateString,
              date: chunkDate,
              rawChunks: chunks,
              processedRecordings: [],
            );
          }
        }
      }
    }

    // Process finalized recordings (These are still grouped cleanly in YYYY-MM-DD folders)
    if (await recordingsDir.exists()) {
      final dateFolders = recordingsDir.listSync().whereType<Directory>();
      for (var folder in dateFolders) {
        final dateString = folder.path.split('/').last;
        final date = parseDate(dateString);
        if (date != null) {
          final recordings = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.aac')).toList();
          recordings.sort((a, b) => b.path.compareTo(a.path)); // Newest first
          
          if (batchesMap.containsKey(dateString)) {
            batchesMap[dateString]!.processedRecordings.addAll(recordings);
          } else {
            batchesMap[dateString] = DailyBatch(
              dateString: dateString,
              date: date,
              rawChunks: [],
              processedRecordings: recordings,
            );
          }
        }
      }
    }

    final batches = batchesMap.values.toList();
    // Sort batches by date, newest first
    batches.sort((a, b) => b.date.compareTo(a.date));
    return batches;
  }

  /// Reprocesses or processes a specific day's raw chunks.
  /// If there are already processed recordings, they will be deleted first.
  Future<void> processDay(DailyBatch batch, Function(double progress) onProgress) async {
    if (batch.rawChunks.isEmpty) return;

    // 1. Delete existing processed recordings for this day
    for (var file in batch.processedRecordings) {
      if (await file.exists()) {
        await file.delete();
      }
    }

    // 2. Initialize the OfflineAudioProcessor
    final processor = OfflineAudioProcessor();

    // 3. Process each raw chunk sequentially
    for (int i = 0; i < batch.rawChunks.length; i++) {
      final file = batch.rawChunks[i];
      final bytes = await file.readAsBytes();
      
      // Get session ID from folder name
      final sessionIdStr = file.parent.path.split('/').last;
      int? sessionId = int.tryParse(sessionIdStr);
      
      // The exact chunk start time will be computed INSIDE processFrames by reading the 255 packet!
      // We just pass a fallback time here in case the chunk doesn't have one (very rare).
      DateTime chunkStartTime = file.lastModifiedSync();
      
      // Read frames from .bin file (Format: [4-byte length][frame data][4-byte length][frame data]...)
      List<Uint8List> frames = [];
      int offset = 0;
      while (offset < bytes.length) {
        if (offset + 4 > bytes.length) break;
        
        // Read 4-byte length (Little Endian)
        final lengthData = bytes.sublist(offset, offset + 4);
        final length = ByteData.sublistView(Uint8List.fromList(lengthData)).getUint32(0, Endian.little);
        offset += 4;
        
        if (offset + length > bytes.length) break;
        
        final frame = bytes.sublist(offset, offset + length);
        frames.add(frame);
        offset += length;
      }

      // Process frames (Pass sessionId so it can look up the correct anchor)
      await processor.processFrames(frames, chunkStartTime, sessionId: sessionId);

      // Report progress
      onProgress((i + 1) / batch.rawChunks.length);
    }

    // 4. Flush remaining buffer
    await processor.flushRemaining();
    processor.destroy();

    // 5. Check adjustment mode. If OFF, delete the raw chunks.
    if (!SharedPreferencesUtil().offlineAdjustmentMode) {
      Set<String> sessionFoldersToDelete = {};
      final latestSyncedSessionId = SharedPreferencesUtil().latestSyncedSessionId;
      
      for (var file in batch.rawChunks) {
        if (await file.exists()) {
          // Get session ID from folder name
          final sessionIdStr = file.parent.path.split('/').last;
          final sessionId = int.tryParse(sessionIdStr) ?? -1;

          // Only delete if it's NOT the latest session (which might be ongoing)
          if (sessionId < latestSyncedSessionId) {
            await file.delete();
            sessionFoldersToDelete.add(file.parent.path);
          } else {
            Logger.debug("RecordingsManager: Keeping raw chunk for session $sessionId as it might be ongoing.");
          }
        }
      }
      
      // Try to delete the empty session folders
      for (var folderPath in sessionFoldersToDelete) {
        final folder = Directory(folderPath);
        if (await folder.exists()) {
          try {
            // Check if folder is actually empty before deleting
            if ((await folder.list().isEmpty)) {
              await folder.delete();
            }
          } catch (e) {
            // Ignore if not empty
          }
        }
      }
    }
  }
}
