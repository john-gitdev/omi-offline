import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
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
      throw OmiSyncException('Token refresh failed (${res.statusCode})', isAuthError: true);
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final idToken = body['id_token'] as String?;
    final expiresIn = int.tryParse(body['expires_in']?.toString() ?? '') ?? 3600;
    if (idToken == null || idToken.isEmpty) {
      throw const OmiSyncException('Token refresh returned no id_token');
    }

    prefs.omiIdToken = idToken;
    prefs.omiTokenExpiry = now + expiresIn * 1000;

    // Google can rotate the refresh token on each exchange — persist the new one.
    final newRefreshToken = body['refresh_token'] as String?;
    if (newRefreshToken != null && newRefreshToken.isNotEmpty && newRefreshToken != refreshToken) {
      await prefs.setOmiRefreshToken(newRefreshToken);
    }

    Logger.debug('OmiApiClient: Token refreshed, expires in ${expiresIn}s');
  }

  /// Uploads [binFiles] to /v2/sync-local-files. Throws [OmiSyncException] on failure.
  static Future<void> syncLocalFiles(List<File> binFiles) async {
    await refreshTokenIfNeeded();
    final token = SharedPreferencesUtil().omiIdToken;
    if (token.isEmpty) throw const OmiSyncException('No Omi ID token available');

    final request = http.MultipartRequest('POST', Uri.parse(_syncUrl))
      ..headers['Authorization'] = 'Bearer $token';
    for (final f in binFiles) {
      request.files.add(http.MultipartFile(
        'files',
        f.openRead(),
        await f.length(),
        filename: f.uri.pathSegments.last,
        contentType: MediaType('application', 'octet-stream'),
      ));
    }

    final http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(seconds: 120));
    } on SocketException {
      throw const OmiSyncException('No network connection');
    }

    // Drain the response body regardless of status.
    await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      final isAuth = streamed.statusCode == 401 || streamed.statusCode == 403;
      throw OmiSyncException(
        'Sync upload failed (${streamed.statusCode})',
        isAuthError: isAuth,
      );
    }

    Logger.debug('OmiApiClient: Sync accepted (${streamed.statusCode})');
  }

  /// Verifies credentials by attempting a token refresh with the supplied values.
  /// Does not read from or write to saved preferences, so callers can test
  /// unsaved credentials without overwriting the working ones.
  static Future<bool> testConnection({
    required String refreshToken,
    required String apiKey,
  }) async {
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
