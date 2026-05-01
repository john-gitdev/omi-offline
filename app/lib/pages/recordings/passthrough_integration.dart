import 'dart:io';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';

abstract class PassthroughIntegration {
  bool isEnabled(Conversation c);
  Future<bool> hasDelivered(Conversation c, File binFile);
}

class HeyPocketPassthroughIntegration implements PassthroughIntegration {
  final SharedPreferencesUtil _prefs;
  HeyPocketPassthroughIntegration(this._prefs);

  @override
  bool isEnabled(Conversation c) =>
      _prefs.heypocketEnabled && _prefs.heypocketApiKey.isNotEmpty && c.uploadKey != null;

  @override
  Future<bool> hasDelivered(Conversation c, File binFile) async => _prefs.isUploadedToHeypocket(c.uploadKey!);
}

class OmiPassthroughIntegration implements PassthroughIntegration {
  final SharedPreferencesUtil _prefs;
  OmiPassthroughIntegration(this._prefs);

  @override
  bool isEnabled(Conversation c) => _prefs.omiSyncEnabled && _prefs.omiRefreshToken.isNotEmpty;

  @override
  Future<bool> hasDelivered(Conversation c, File binFile) async => !await binFile.exists();
}
