import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:omi/services/wals.dart';
import 'package:omi/utils/logger.dart';

class WalFileManager {
  static const String _walFileName = 'wals.json';
  static const String _walBackupFileName = 'wals_backup.json';

  static File? _walFile;
  static File? _walBackupFile;

  static Future<void> init() async {
    final directory =
        Platform.isMacOS ? await getApplicationSupportDirectory() : await getApplicationDocumentsDirectory();
    _walFile = File('${directory.path}/$_walFileName');
    _walBackupFile = File('${directory.path}/$_walBackupFileName');
  }

  static Future<List<Wal>> loadWals() async {
    if (_walFile == null) {
      await init();
    }

    if (_walFile == null || !_walFile!.existsSync()) {
      Logger.debug('WAL file does not exist, returning empty list');
      return [];
    }

    final content = await _walFile!.readAsString();
    if (content.isEmpty) {
      Logger.debug('WAL file is empty, returning empty list');
      return [];
    }

    final jsonData = jsonDecode(content);
    if (jsonData is! Map<String, dynamic> || jsonData['wals'] is! List) {
      Logger.debug('Invalid WAL file format, returning empty list');
      return [];
    }

    final walsList = jsonData['wals'] as List;
    return Wal.fromJsonList(walsList);
  }

  static Future<bool> saveWals(List<Wal> wals) async {
    if (_walFile == null) {
      await init();
    }

    if (_walFile == null) {
      Logger.debug('WAL file is null, cannot save');
      return false;
    }

    await _createBackup();

    final jsonData = {
      'version': 1,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'wals': wals.map((wal) => wal.toJson()).toList(),
    };

    final jsonString = jsonEncode(jsonData);
    await _walFile!.writeAsString(jsonString);

    Logger.debug('Successfully saved ${wals.length} WALs to file');
    return true;
  }

  static Future<void> _createBackup() async {
    try {
      if (_walFile != null && _walFile!.existsSync() && _walBackupFile != null) {
        await _walFile!.copy(_walBackupFile!.path);
      }
    } on FileSystemException catch (e) {
      Logger.debug('WalFileManager: Failed to create backup: $e');
    }
  }

  static Future<void> clearAll() async {
    if (_walFile != null && _walFile!.existsSync()) {
      await _walFile!.delete();
    }
    if (_walBackupFile != null && _walBackupFile!.existsSync()) {
      await _walBackupFile!.delete();
    }
    Logger.debug('Cleared all WAL files');
  }

  static Future<Map<String, int>> getFileInfo() async {
    int mainFileSize = 0;
    int backupFileSize = 0;

    if (_walFile != null && _walFile!.existsSync()) {
      mainFileSize = await _walFile!.length();
    }

    if (_walBackupFile != null && _walBackupFile!.existsSync()) {
      backupFileSize = await _walBackupFile!.length();
    }

    return {
      'mainFileSize': mainFileSize,
      'backupFileSize': backupFileSize,
    };
  }
}
