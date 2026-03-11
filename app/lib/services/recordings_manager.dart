import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/offline_audio_processor.dart';

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

    // Process raw chunks
    if (await rawChunksDir.exists()) {
      final dateFolders = rawChunksDir.listSync().whereType<Directory>();
      for (var folder in dateFolders) {
        final dateString = folder.path.split('/').last;
        final date = parseDate(dateString);
        if (date != null) {
          final chunks = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.bin')).toList();
          chunks.sort((a, b) => a.path.compareTo(b.path)); // Simple sort by name
          
          batchesMap[dateString] = DailyBatch(
            dateString: dateString,
            date: date,
            rawChunks: chunks,
            processedRecordings: [],
          );
        }
      }
    }

    // Process recordings
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
      
      // Parse timestamp from filename (assuming audio_limitless_opus_..._timestampMs.bin)
      // or simply fallback to file modified time if filename format is different.
      // Current format: audio_limitless_opus_16000_1_fs320_r{random}_{timestampMs}.bin
      DateTime chunkStartTime = file.lastModifiedSync();
      try {
        final name = file.path.split('/').last;
        final parts = name.replaceAll('.bin', '').split('_');
        final tsString = parts.last;
        final tsMs = int.parse(tsString);
        chunkStartTime = DateTime.fromMillisecondsSinceEpoch(tsMs);
      } catch (e) {
        // Keep fallback
      }

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

      // Process frames
      await processor.processFrames(frames, chunkStartTime);

      // Report progress
      onProgress((i + 1) / batch.rawChunks.length);
    }

    // 4. Flush remaining buffer
    await processor.flushRemaining();
    processor.destroy();

    // 5. Check adjustment mode. If OFF, delete the raw chunks.
    if (!SharedPreferencesUtil().offlineAdjustmentMode) {
      for (var file in batch.rawChunks) {
        if (await file.exists()) {
          await file.delete();
        }
      }
      
      // Try to delete the empty folder
      final directory = await getApplicationDocumentsDirectory();
      final dateFolder = Directory('${directory.path}/raw_chunks/${batch.dateString}');
      if (await dateFolder.exists()) {
        try {
          await dateFolder.delete();
        } catch (e) {
          // Ignore if not empty
        }
      }
    }
  }
}
