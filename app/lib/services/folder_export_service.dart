import 'package:flutter/services.dart';

/// Why a folder operation failed, as `FolderExportChannel.kt` names it.
enum FolderExportError {
  /// The grant is gone, or the folder itself is — deleted, or on an SD card that is not
  /// mounted. Not the recording's fault.
  noAccess,

  /// The recording was deleted before the copy began.
  sourceGone,

  /// The copy being renamed is no longer in the folder (the user removed it there).
  gone,

  /// The folder's provider cannot rename files, so a copy cannot follow a re-file.
  unsupported,

  /// No screen to show the folder picker on.
  noUi,

  other,
}

class FolderExportException implements Exception {
  final FolderExportError kind;
  final String message;
  const FolderExportException(this.kind, this.message);

  @override
  String toString() => message;
}

class PickedFolder {
  /// A persisted `content://` tree URI.
  final String treeUri;

  /// The folder's name, for display.
  final String label;
  const PickedFolder(this.treeUri, this.label);
}

/// The folder operations Save to Folder needs. An interface so the integration can be
/// driven in tests without the platform channel.
abstract class FolderExportBackend {
  /// Shows the system folder picker and keeps access to the folder chosen. Null when the
  /// user backs out.
  Future<PickedFolder?> pickFolder();

  Future<void> releaseFolder(String treeUri);

  Future<bool> hasAccess(String treeUri);

  /// Copies [sourcePath] into the folder as [name] — or `name (2)` and so on when that name
  /// is taken — and returns the copy's document URI. The copy is written under a hidden
  /// name and renamed once complete. Nothing already in the folder is ever deleted.
  Future<String> copyInto(String treeUri, String sourcePath, String name, String mimeType);

  /// Renames a copy, returning its new document URI (a rename can change it).
  Future<String> rename(String treeUri, String docUri, String name);
}

class ChannelFolderExportBackend implements FolderExportBackend {
  static const _channel = MethodChannel('com.omi.offline/folderExport');

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      final kind = switch (e.code) {
        'NO_ACCESS' => FolderExportError.noAccess,
        'SOURCE_GONE' => FolderExportError.sourceGone,
        'GONE' => FolderExportError.gone,
        'UNSUPPORTED' => FolderExportError.unsupported,
        'NO_UI' => FolderExportError.noUi,
        _ => FolderExportError.other,
      };
      throw FolderExportException(kind, e.message ?? e.code);
    }
  }

  @override
  Future<PickedFolder?> pickFolder() async {
    final result = await _invoke<Map<Object?, Object?>>('pickFolder');
    if (result == null) return null;
    return PickedFolder(result['treeUri'] as String, result['label'] as String);
  }

  @override
  Future<void> releaseFolder(String treeUri) => _invoke<void>('releaseFolder', {'treeUri': treeUri});

  @override
  Future<bool> hasAccess(String treeUri) async => await _invoke<bool>('hasAccess', {'treeUri': treeUri}) ?? false;

  @override
  Future<String> copyInto(String treeUri, String sourcePath, String name, String mimeType) async {
    final uri = await _invoke<String>('copyInto', {
      'treeUri': treeUri,
      'sourcePath': sourcePath,
      'name': name,
      'mimeType': mimeType,
    });
    return uri!;
  }

  @override
  Future<String> rename(String treeUri, String docUri, String name) async {
    final uri = await _invoke<String>('rename', {'treeUri': treeUri, 'docUri': docUri, 'name': name});
    return uri!;
  }
}
