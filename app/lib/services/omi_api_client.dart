import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';

class OmiApiClient {
  static const _tokenUrl = 'https://securetoken.googleapis.com/v1/token';
  static const _syncUrl = 'https://api.omi.me/v2/sync-local-files';

  /// Refreshes the Firebase ID token if it expires within 60 seconds.
  /// No-op if the token is still valid. Throws [OmiSyncException] on failure.
  static Future<void> refreshTokenIfNeeded() async {
    final prefs = SharedPreferencesUtil();
    final expiry = prefs.omiTokenExpiry;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (expiry - now > 60 * 1000) return;

    final refreshToken = prefs.omiRefreshToken;
    final apiKey = prefs.omiFirebaseApiKey;
    if (refreshToken.isEmpty || apiKey.isEmpty) {
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
      throw OmiSyncException('Token refresh failed (${res.statusCode})');
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final idToken = body['id_token'] as String?;
    final expiresIn = int.tryParse(body['expires_in']?.toString() ?? '') ?? 3600;
    if (idToken == null || idToken.isEmpty) {
      throw const OmiSyncException('Token refresh returned no id_token');
    }

    prefs.omiIdToken = idToken;
    prefs.omiTokenExpiry = now + expiresIn * 1000;
    Logger.debug('OmiApiClient: Token refreshed, expires in ${expiresIn}s');
  }

  /// Uploads [binFiles] to /v2/sync-local-files. Returns the job_id from the 202 response.
  static Future<String> syncLocalFiles(List<File> binFiles) async {
    await refreshTokenIfNeeded();
    final token = SharedPreferencesUtil().omiIdToken;
    if (token.isEmpty) throw const OmiSyncException('No Omi ID token available');

    final request = http.MultipartRequest('POST', Uri.parse(_syncUrl))
      ..headers['Authorization'] = 'Bearer $token';
    for (final f in binFiles) {
      request.files.add(await http.MultipartFile.fromPath('files', f.path));
    }

    final http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(seconds: 30));
    } on SocketException {
      throw const OmiSyncException('No network connection');
    }

    final responseBody = await streamed.stream.bytesToString();
    if (streamed.statusCode != 202) {
      throw OmiSyncException('Sync upload failed (${streamed.statusCode})');
    }

    final body = jsonDecode(responseBody) as Map<String, dynamic>;
    final jobId = body['job_id'] as String?;
    if (jobId == null || jobId.isEmpty) throw const OmiSyncException('No job_id in sync response');
    Logger.debug('OmiApiClient: Sync job started — $jobId');
    return jobId;
  }

  /// Polls /v2/sync-local-files/{jobId} with exponential backoff until a terminal status is reached.
  /// Returns true on completed/partial_failure. Throws [OmiSyncException] on failure or timeout.
  static Future<bool> pollSyncJob(String jobId) async {
    final token = SharedPreferencesUtil().omiIdToken;
    const delays = [2, 4, 8, 16, 30];
    for (final delaySec in delays) {
      await Future.delayed(Duration(seconds: delaySec));
      final http.Response res;
      try {
        res = await http
            .get(
              Uri.parse('$_syncUrl/$jobId'),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 10));
      } on SocketException {
        continue; // retry on transient network error
      }

      if (res.statusCode == 404) throw const OmiSyncException('Sync job expired');
      if (res.statusCode == 403) throw const OmiSyncException('Unauthorized — check credentials');
      if (res.statusCode != 200) continue;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final status = body['status'] as String?;
      Logger.debug('OmiApiClient: Poll $jobId — status=$status');
      if (status == 'completed' || status == 'partial_failure') return true;
      if (status == 'failed') throw OmiSyncException('Sync job failed: ${body['error']}');
    }
    throw const OmiSyncException('Sync job timed out after 60s of polling');
  }

  /// Verifies credentials by attempting a token refresh. Returns true if successful.
  static Future<bool> testConnection() async {
    try {
      // Force a refresh regardless of expiry so we can validate the credentials.
      SharedPreferencesUtil().omiTokenExpiry = 0;
      await refreshTokenIfNeeded();
      return true;
    } catch (_) {
      return false;
    }
  }
}

class OmiSyncException implements Exception {
  final String message;
  const OmiSyncException(this.message);
  @override
  String toString() => 'OmiSyncException: $message';
}
