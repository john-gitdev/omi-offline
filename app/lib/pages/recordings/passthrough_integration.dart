import 'dart:async';
import 'dart:io';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/heypocket_service.dart';
import 'package:omi/services/omi_api_client.dart';

abstract class PassthroughIntegration {
  String get name;

  /// Eligible for *auto*-upload of [c]: configured, the Enabled toggle on, and
  /// [c] recorded after the auto-upload time cutoff. Used only by the
  /// background auto-upload sweep.
  bool isEnabled(Conversation c);

  /// Available for a *manual* (explicit user-tap) upload of [c]: configured and
  /// the Enabled toggle on, applicable to [c] — but WITHOUT the auto-upload
  /// time cutoff that [isEnabled] applies. An explicit upload should work on
  /// recordings made before auto-upload was switched on. Source-data existence
  /// (e.g. Omi's passthrough .bin) is NOT checked here so a delivered recording
  /// whose source was later pruned still reports as delivered; a missing source
  /// surfaces as a clear error from [upload] instead.
  bool isAvailableFor(Conversation c);

  bool get isConfigured;
  bool get isAutoUploadEnabled;
  bool hasDelivered(Conversation c);
  Future<void> upload(Conversation c);
  bool isFailed(Conversation c);

  /// Maximum number of concurrent auto-uploads allowed for this service.
  int get concurrencyLimit;

  /// The unique key used to track retry counts for this integration.
  String getRetryKey(Conversation c);

  static List<PassthroughIntegration> getIntegrations(SharedPreferencesUtil prefs) => [
        HeyPocketPassthroughIntegration(prefs),
        OmiPassthroughIntegration(prefs),
        // Add new integrations here.
      ];

  static bool hasAnyConfigured(SharedPreferencesUtil prefs) {
    final integrations = getIntegrations(prefs);
    for (final i in integrations) {
      if (i.isConfigured) return true;
    }
    return false;
  }

  static String getBinPath(Conversation c) {
    final ts = c.file.path.split('/').last.split('_').last.split('.').first;
    return '${c.file.parent.path}/recording_fs320_$ts.bin';
  }
}

class HeyPocketPassthroughIntegration implements PassthroughIntegration {
  final SharedPreferencesUtil _prefs;
  HeyPocketPassthroughIntegration(this._prefs);

  @override
  String get name => 'HeyPocket';

  @override
  int get concurrencyLimit => 3;

  @override
  String getRetryKey(Conversation c) => c.uploadKey!;

  @override
  bool isEnabled(Conversation c) {
    if (!_prefs.heypocketEnabled || !isConfigured || c.uploadKey == null) return false;
    final keySetAt = _prefs.heypocketKeySetAt;
    final keySetTime = keySetAt > 0 ? DateTime.fromMillisecondsSinceEpoch(keySetAt) : null;
    if (keySetTime != null && c.startTime.isBefore(keySetTime)) return false;
    return true;
  }

  @override
  bool isAvailableFor(Conversation c) => isConfigured && c.uploadKey != null;

  @override
  bool get isConfigured => _prefs.heypocketEnabled && _prefs.heypocketApiKey.isNotEmpty;

  @override
  bool get isAutoUploadEnabled => _prefs.heypocketAutoUpload;

  @override
  bool hasDelivered(Conversation c) => _prefs.isUploadedToHeypocket(c.uploadKey!);

  @override
  bool isFailed(Conversation c) => _prefs.getAutoUploadRetries(c.uploadKey!) >= 3;

  @override
  Future<void> upload(Conversation c) async {
    final uploadKey = c.uploadKey!;
    try {
      await HeyPocketService.uploadRecording(_prefs.heypocketApiKey, c);
      await _prefs.markUploadedToHeypocket(uploadKey);
      await _prefs.clearAutoUploadRetry(uploadKey);
    } catch (e) {
      if (e is HeyPocketException && e.statusCode == 401) {
        _prefs.heypocketEnabled = false;
      }
      rethrow;
    }
  }
}

class OmiPassthroughIntegration implements PassthroughIntegration {
  final SharedPreferencesUtil _prefs;
  OmiPassthroughIntegration(this._prefs);

  @override
  String get name => 'Omi Cloud';

  @override
  int get concurrencyLimit => 1;

  @override
  String getRetryKey(Conversation c) => PassthroughIntegration.getBinPath(c);

  @override
  bool isEnabled(Conversation c) {
    if (!_prefs.omiEnabled || !isConfigured) return false;
    final autoSyncAt = _prefs.omiAutoUploadAt;
    final autoSyncTime = autoSyncAt > 0 ? DateTime.fromMillisecondsSinceEpoch(autoSyncAt) : null;
    if (autoSyncTime != null && c.startTime.isBefore(autoSyncTime)) return false;
    return true;
  }

  @override
  bool isAvailableFor(Conversation c) => isConfigured;

  @override
  bool get isConfigured => _prefs.omiEnabled && _prefs.omiRefreshToken.isNotEmpty;

  @override
  bool get isAutoUploadEnabled => _prefs.omiAutoUpload;

  @override
  bool hasDelivered(Conversation c) {
    return _prefs.isOmiSynced(PassthroughIntegration.getBinPath(c));
  }

  @override
  bool isFailed(Conversation c) {
    return _prefs.getAutoUploadRetries(PassthroughIntegration.getBinPath(c)) >= 3;
  }

  @override
  Future<void> upload(Conversation c) async {
    final binPath = PassthroughIntegration.getBinPath(c);
    final binFile = File(binPath);
    if (!binFile.existsSync()) {
      throw Exception('no Omi upload file for this recording — it was processed before Omi sync was enabled');
    }

    try {
      final result = await OmiApiClient.syncLocalFiles([binFile]);
      if (result != null && result.success) {
        await _prefs.markOmiSynced(binPath);
        await _prefs.clearAutoUploadRetry(binPath);
        unawaited(OmiApiClient.traceSyncResult(result));
      } else {
        throw Exception('Omi upload failed: ${result?.status}');
      }
    } catch (e) {
      if (e is OmiSyncException && e.isAuthError) {
        _prefs.omiEnabled = false;
      }
      rethrow;
    }
  }
}
