import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';

class OmiSyncResult {
  final bool success;
  final String status;
  final List<String> newConversationIds;
  final List<String> updatedConversationIds;
  final int successfulSegments;
  final int failedSegments;
  final String? error;

  OmiSyncResult({
    required this.success,
    required this.status,
    this.newConversationIds = const [],
    this.updatedConversationIds = const [],
    this.successfulSegments = 0,
    this.failedSegments = 0,
    this.error,
  });

  List<String> get allConversationIds => {...newConversationIds, ...updatedConversationIds}.toList();

  @override
  String toString() =>
      'OmiSyncResult(success: $success, status: $status, new: ${newConversationIds.length}, updated: ${updatedConversationIds.length}, okSeg: $successfulSegments, failSeg: $failedSegments)';
}

class OmiApiClient {
  static const _tokenUrl = 'https://securetoken.googleapis.com/v1/token';
  static const _syncUrlV2 = 'https://api.omi.me/v2/sync-local-files';
  static const _syncUrlV1 = 'https://api.omi.me/v1/sync-local-files';
  static const _speechProfileUrl = 'https://api.omi.me/v3/speech-profile';
  static const _conversationUrl = 'https://api.omi.me/v1/dev/user/conversations';

  static bool get isSignedIn {
    final prefs = SharedPreferencesUtil();
    return prefs.omiRefreshToken.isNotEmpty;
  }

  static Future<void> signOut() async {
    final prefs = SharedPreferencesUtil();
    await prefs.setOmiIdToken('');
    prefs.omiTokenExpiry = 0;
    await prefs.setOmiRefreshToken('');
    Logger.debug('OmiApiClient: Signed out, cleared tokens');
  }

  /// Refreshes the Firebase ID token if it expires within 60 seconds.
  /// No-op if the token is still valid. Throws [OmiSyncException] on failure.
  static Future<void> refreshTokenIfNeeded() async {
    final prefs = SharedPreferencesUtil();
    final expiry = prefs.omiTokenExpiry;
    final now = DateTime.now().millisecondsSinceEpoch;
    final remainingMs = expiry - now;
    if (remainingMs > 60 * 1000) {
      Logger.debug('OmiApiClient: Token still valid, expires in ${(remainingMs / 1000).round()}s');
      return;
    }
    Logger.debug(
      'OmiApiClient: Token expired or expiring soon (${(remainingMs / 1000).round()}s remaining), refreshing...',
    );

    final refreshToken = prefs.omiRefreshToken;
    final apiKey = prefs.omiFirebaseApiKey;
    if (refreshToken.isEmpty || apiKey.isEmpty) {
      Logger.error('OmiApiClient: refreshToken empty=${refreshToken.isEmpty}, apiKey empty=${apiKey.isEmpty}');
      throw const OmiSyncException('Omi credentials not configured');
    }

    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$_tokenUrl?key=${Uri.encodeComponent(apiKey)}'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'grant_type=refresh_token&refresh_token=${Uri.encodeComponent(refreshToken)}',
          )
          .timeout(const Duration(seconds: 10));
    } on SocketException {
      throw const OmiSyncException('No network connection');
    }

    if (res.statusCode != 200) {
      Logger.error('OmiApiClient: Token refresh HTTP ${res.statusCode}: ${res.body}');
      throw OmiSyncException('Token refresh failed (${res.statusCode})', isAuthError: true);
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final idToken = body['id_token'] as String?;
    final expiresIn = int.tryParse(body['expires_in']?.toString() ?? '') ?? 3600;
    if (idToken == null || idToken.isEmpty) {
      Logger.error('OmiApiClient: Token refresh response missing id_token.');
      throw const OmiSyncException('Token refresh returned no id_token');
    }

    await prefs.setOmiIdToken(idToken);
    prefs.omiTokenExpiry = now + expiresIn * 1000;

    // Google can rotate the refresh token on each exchange — persist the new one.
    final newRefreshToken = body['refresh_token'] as String?;
    if (newRefreshToken != null && newRefreshToken.isNotEmpty && newRefreshToken != refreshToken) {
      await prefs.setOmiRefreshToken(newRefreshToken);
    }

    Logger.debug('OmiApiClient: Token refreshed, expires in ${expiresIn}s');
    unawaited(prefs.clearAllAutoUploadRetries());
  }

  /// Uploads [binFiles] to /v2/sync-local-files in the official device format:
  /// `audio_<mac>_opus_fs320_16000_1_fs320_<ts_sec>.bin` containing length-prefixed
  /// Opus frames (app-side marker frames stripped). Throws [OmiSyncException] on failure.
  static Future<OmiSyncResult?> syncLocalFiles(List<File> binFiles) async {
    if (!isSignedIn) {
      Logger.debug('OmiApiClient: Not signed in, skipping sync');
      return null;
    }

    await refreshTokenIfNeeded();
    final token = await SharedPreferencesUtil().omiIdToken;
    if (token.isEmpty) throw const OmiSyncException('No Omi ID token available');

    final mac = _deviceMacForFilename();

    final namedBytes = <(String, Uint8List)>[];
    for (final f in binFiles) {
      final bytes = await _readOpusFrames(f);
      if (bytes.isEmpty) {
        Logger.error('OmiApiClient: No Opus frames found in ${f.path}');
        continue;
      }
      final filename = _opusFilename(f, mac);
      namedBytes.add((filename, bytes));
      Logger.debug('OmiApiClient: Prepared ${f.uri.pathSegments.last} → $filename (${bytes.length} bytes)');
    }
    if (namedBytes.isEmpty) throw const OmiSyncException('No upload payload available');

    final headers = {'Authorization': 'Bearer $token'};

    var res = await _doUploadBytes(_syncUrlV2, namedBytes, headers);
    var usedUrl = _syncUrlV2;

    if (res.statusCode == 404 || res.statusCode == 405) {
      Logger.debug('OmiApiClient: v2 not found (${res.statusCode}), falling back to v1');
      res = await _doUploadBytes(_syncUrlV1, namedBytes, headers);
      usedUrl = _syncUrlV1;
    }

    final responseBody = res.body;
    Logger.debug('OmiApiClient: Upload response ${res.statusCode}: $responseBody');

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final isAuth = res.statusCode == 401 || res.statusCode == 403;
      throw OmiSyncException('Sync upload failed (${res.statusCode})', isAuthError: isAuth);
    }

    if (res.statusCode == 202) {
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      final jobId = json['job_id'] as String?;
      final pollAfterMs = (json['poll_after_ms'] as int?) ?? 3000;
      if (jobId != null) return await _pollJob(usedUrl, jobId, pollAfterMs);
    }

    return _parseSyncResult(res.statusCode, responseBody);
  }

  static String _deviceMacForFilename() {
    final raw = SharedPreferencesUtil().btDevice.id;
    final cleaned = raw.replaceAll(':', '').replaceAll('-', '').toLowerCase();
    // Fallback so an empty/unknown MAC still produces a parseable filename.
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }

  static String _opusFilename(File binFile, String mac) {
    // Extract millisecond timestamp from "recording_fs320_<ms>.bin" and convert to seconds.
    final name = binFile.uri.pathSegments.last;
    final tsStr = name.replaceFirst('recording_fs320_', '').replaceFirst('.bin', '');
    final parsed = int.tryParse(tsStr) ?? 0;
    var tsSeconds = parsed > 1000000000000 ? parsed ~/ 1000 : parsed;

    // Server requires >= 2024-01-01 and <= now - 30s.
    const minValidSeconds = 1704067200;
    final latestSafe = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 30;
    final safeFloor = latestSafe > minValidSeconds ? latestSafe : minValidSeconds;
    if (tsSeconds < minValidSeconds) tsSeconds = safeFloor;
    if (tsSeconds > latestSafe) tsSeconds = latestSafe;

    return 'audio_${mac}_opus_fs320_16000_1_fs320_$tsSeconds.bin';
  }

  /// Reads a .bin and returns only length-prefixed Opus frames, defensively skipping
  /// app-side marker frames (0xFFFFFFFE/FD/FB) and zero/sentinel slots.
  static Future<Uint8List> _readOpusFrames(File binFile) async {
    final bytes = await binFile.readAsBytes();
    final byteData = ByteData.sublistView(bytes);
    final output = BytesBuilder();

    int offset = 0;
    while (offset + 4 <= bytes.length) {
      final frameLength = byteData.getUint32(offset, Endian.little);

      if (frameLength == 0 || frameLength == 0xFFFFFFFF) {
        offset += 4;
        continue;
      }
      if (frameLength == 0xFFFFFFFB) {
        offset += 36;
        continue;
      }
      if (frameLength == 0xFFFFFFFE) {
        offset += 20;
        continue;
      }
      if (frameLength == 0xFFFFFFFD) {
        offset += 16;
        continue;
      }
      if (frameLength > 0xFFFF00) {
        offset += 4;
        continue;
      }

      if (offset + 4 + frameLength > bytes.length) break;

      output.add(Uint8List.sublistView(bytes, offset, offset + 4 + frameLength));
      offset += 4 + frameLength;
    }

    return output.takeBytes();
  }

  static Future<http.Response> _doUploadBytes(
    String url,
    List<(String filename, Uint8List bytes)> files,
    Map<String, String> headers,
  ) async {
    final request = http.MultipartRequest('POST', Uri.parse(url))..headers.addAll(headers);
    for (final (filename, bytes) in files) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'files',
          bytes,
          filename: filename,
          contentType: MediaType('application', 'octet-stream'),
        ),
      );
    }

    try {
      final streamed = await request.send().timeout(const Duration(seconds: 120));
      return http.Response.fromStream(streamed);
    } on SocketException {
      throw const OmiSyncException('No network connection');
    }
  }

  static Future<OmiSyncResult> _pollJob(String baseUrl, String jobId, int initialDelayMs) async {
    await Future.delayed(Duration(milliseconds: initialDelayMs));

    const maxAttempts = 80;
    var delayMs = 3000;
    for (var i = 0; i < maxAttempts; i++) {
      await refreshTokenIfNeeded();
      final token = await SharedPreferencesUtil().omiIdToken;

      final headers = {'Authorization': 'Bearer $token'};

      final http.Response res;
      try {
        res = await http.get(Uri.parse('$baseUrl/$jobId'), headers: headers).timeout(const Duration(seconds: 15));
      } on SocketException {
        throw const OmiSyncException('No network connection');
      }

      Logger.debug('OmiApiClient: Job $jobId poll ${res.statusCode}: ${res.body}');

      if (res.statusCode == 401 || res.statusCode == 403) {
        throw OmiSyncException('Job poll auth error (${res.statusCode})', isAuthError: true);
      }

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final bodyJson = jsonDecode(res.body) as Map<String, dynamic>;
        final status = bodyJson['status'] as String?;
        if (status == 'completed' || status == 'partial_failure') {
          return _parseSyncResult(res.statusCode, res.body);
        }
        if (status == 'failed') {
          final err = bodyJson['error'] ?? bodyJson['message'] ?? 'unknown error';
          return OmiSyncResult(success: false, status: 'failed', error: err.toString());
        }
        delayMs = (bodyJson['poll_after_ms'] as int?) ?? delayMs;
      }

      await Future.delayed(Duration(milliseconds: delayMs));
    }

    throw const OmiSyncException('Omi job timed out after polling');
  }

  static OmiSyncResult _parseSyncResult(int httpStatus, String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final status = json['status']?.toString() ?? 'completed';
      final success = httpStatus >= 200 && httpStatus < 300 && status != 'failed';

      List<String> parseIds(dynamic val) {
        if (val is List) return val.map((e) => e.toString()).toList();
        return [];
      }

      return OmiSyncResult(
        success: success,
        status: status,
        newConversationIds: parseIds(json['new_memories']),
        updatedConversationIds: parseIds(json['updated_memories']),
        successfulSegments: json['successful_segments'] as int? ?? 0,
        failedSegments: json['failed_segments'] as int? ?? 0,
      );
    } catch (e) {
      return OmiSyncResult(success: httpStatus >= 200 && httpStatus < 300, status: 'parse_error', error: e.toString());
    }
  }

  /// Verifies a conversation was actually created on the server and checks its metadata.
  static Future<void> traceSyncResult(OmiSyncResult result) async {
    if (!result.success || result.allConversationIds.isEmpty) return;

    try {
      await refreshTokenIfNeeded();
      final token = await SharedPreferencesUtil().omiIdToken;
      final headers = {'Authorization': 'Bearer $token'};

      for (final id in result.allConversationIds.take(3)) {
        final res = await http
            .get(Uri.parse('$_conversationUrl/${Uri.encodeComponent(id)}?include_transcript=true'), headers: headers)
            .timeout(const Duration(seconds: 15));

        if (res.statusCode == 200) {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          final segments = (json['transcript_segments'] as List?)?.length ?? 0;
          final title = (json['structured'] as Map?)?['title'] ?? 'No Title';
          final discarded = json['discarded'] == true;
          Logger.debug('OmiApiClient: Trace result for $id: "$title", segments: $segments, discarded: $discarded');
        } else {
          Logger.error('OmiApiClient: Trace failed for $id (HTTP ${res.statusCode})');
        }
      }
    } catch (e) {
      Logger.error('OmiApiClient: Trace error: $e');
    }
  }

  /// Refreshes the user's speech profile status from the server.
  static Future<bool?> refreshSpeechProfileStatus() async {
    if (!isSignedIn) return null;

    try {
      await refreshTokenIfNeeded();
      final token = await SharedPreferencesUtil().omiIdToken;
      final res = await http.get(Uri.parse(_speechProfileUrl),
          headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        Logger.error('OmiApiClient: Speech profile check HTTP ${res.statusCode}: ${res.body}');
        return null;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final hasProfile = body['has_profile'] == true;

      final prefs = SharedPreferencesUtil();
      prefs.omiHasSpeechProfile = hasProfile;
      prefs.omiSpeechProfileCheckedAtMs = DateTime.now().millisecondsSinceEpoch;

      Logger.debug('OmiApiClient: Speech profile checked: $hasProfile');
      return hasProfile;
    } catch (e) {
      Logger.error('OmiApiClient: Speech profile check error: $e');
      return null;
    }
  }

  /// Verifies credentials by attempting a token refresh with the supplied values.
  /// Does not read from or write to saved preferences, so callers can test
  /// unsaved credentials without overwriting the working ones.
  static Future<bool> testConnection({required String refreshToken, required String apiKey}) async {
    if (refreshToken.isEmpty || apiKey.isEmpty) return false;
    try {
      final res = await http
          .post(
            Uri.parse('$_tokenUrl?key=${Uri.encodeComponent(apiKey)}'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'grant_type=refresh_token&refresh_token=${Uri.encodeComponent(refreshToken)}',
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

class OmiSyncException implements Exception {
  final String message;
  final bool isAuthError;
  const OmiSyncException(this.message, {this.isAuthError = false});
  @override
  String toString() => 'OmiSyncException: $message';
}
