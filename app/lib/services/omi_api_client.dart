import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';
import 'package:opus_dart/opus_dart.dart';

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

  List<String> get allConversationIds =>
      {...newConversationIds, ...updatedConversationIds}.toList();

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
    Logger.debug('OmiApiClient: Token expired or expiring soon (${(remainingMs / 1000).round()}s remaining), refreshing...');

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
      Logger.error('OmiApiClient: Token refresh response missing id_token. Keys: ${body.keys.toList()}');
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
  }

  /// Uploads [binFiles] to /v2/sync-local-files. Throws [OmiSyncException] on failure.
  static Future<OmiSyncResult?> syncLocalFiles(List<File> binFiles) async {
    if (!isSignedIn) {
      Logger.debug('OmiApiClient: Not signed in, skipping sync');
      return null;
    }

    await refreshTokenIfNeeded();
    final token = await SharedPreferencesUtil().omiIdToken;
    if (token.isEmpty) throw const OmiSyncException('No Omi ID token available');

    final isFallback = SharedPreferencesUtil().omiConnectedViaFallback;

    if (!isFallback) {
      // OAuth path: decode OpusFS320 → PCM16 length-prefixed bytes.
      return await _syncOAuthPcm16(binFiles, token);
    }

    // Web-fallback path: upload raw .bin files with no platform header.
    final fileSizes = <String, int>{};
    for (final f in binFiles) {
      final size = await f.length();
      fileSizes[f.uri.pathSegments.last] = size;
    }
    Logger.debug('OmiApiClient: Uploading ${binFiles.length} file(s) [fallback]: $fileSizes');

    final headers = {'Authorization': 'Bearer $token'};

    var res = await _doUpload(_syncUrlV2, binFiles, fileSizes, headers);
    var usedUrl = _syncUrlV2;

    if (res.statusCode == 404 || res.statusCode == 405) {
      Logger.debug('OmiApiClient: v2 endpoint not found (HTTP ${res.statusCode}), falling back to v1');
      res = await _doUpload(_syncUrlV1, binFiles, fileSizes, headers);
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
      final extraHeaders = headers.containsKey('X-App-Platform') ? {'X-App-Platform': headers['X-App-Platform']!} : <String, String>{};
      if (jobId != null) return await _pollJob(usedUrl, jobId, pollAfterMs, extraHeaders);
    }

    return _parseSyncResult(res.statusCode, responseBody);
  }

  static Future<OmiSyncResult?> _syncOAuthPcm16(List<File> binFiles, String token) async {
    Logger.debug('\n=================== ID TOKEN FOR TEST SCRIPT ===================\n$token\n================================================================');
    
    final namedBytes = <(String, Uint8List)>[];
    for (final f in binFiles) {
      final (bytes, filename) = await _convertBinToPcm16(f);
      if (bytes.isEmpty) {
        Logger.error('OmiApiClient: PCM16 conversion produced empty output for ${f.path}');
        continue;
      }
      namedBytes.add((filename, bytes));
      Logger.debug('OmiApiClient: Converted ${f.uri.pathSegments.last} → $filename (${bytes.length} bytes)');
    }
    if (namedBytes.isEmpty) throw const OmiSyncException('PCM16 conversion failed for all files');

    final headers = {
      'Authorization': 'Bearer $token',
      'X-App-Platform': 'android-ambient-companion',
    };

    Logger.debug('OmiApiClient: Uploading ${namedBytes.length} PCM16 file(s) [oauth]');
    var res = await _doUploadBytes(_syncUrlV2, namedBytes, headers);
    var usedUrl = _syncUrlV2;

    if (res.statusCode == 404 || res.statusCode == 405) {
      Logger.debug('OmiApiClient: v2 not found (${res.statusCode}), falling back to v1 [oauth]');
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
      final extraHeaders = headers.containsKey('X-App-Platform') ? {'X-App-Platform': headers['X-App-Platform']!} : <String, String>{};
      if (jobId != null) return await _pollJob(usedUrl, jobId, pollAfterMs, extraHeaders);
    }

    return _parseSyncResult(res.statusCode, responseBody);
  }

  static String _pcm16Filename(File binFile) {
    // Extract millisecond timestamp from "recording_fs320_<ms>.bin" and convert to seconds.
    final name = binFile.uri.pathSegments.last;
    final msStr = name.replaceFirst('recording_fs320_', '').replaceFirst('.bin', '');
    final msTs = int.tryParse(msStr) ?? 0;
    var tsSeconds = msTs ~/ 1000;

    // Mirror AmbientSyncFilenames.safeBackendTimestampSeconds:
    // clamp to >= 2024-01-01 and <= now - 30s.
    const minValidSeconds = 1704067200; // 2024-01-01T00:00:00Z
    final latestSafe = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 30;
    final safeFloor = latestSafe > minValidSeconds ? latestSafe : minValidSeconds;
    if (tsSeconds < minValidSeconds) tsSeconds = safeFloor;
    if (tsSeconds > latestSafe) tsSeconds = latestSafe;

    // fs960 = 960 samples/chunk (3 × OpusFS320 frames grouped), matching ambient companion format.
    return 'audio_phone_pcm16_16000_1_fs960_$tsSeconds.bin';
  }

  /// Decodes an OpusFS320 .bin file to length-prefixed PCM16 bytes for OAuth upload.
  /// Returns (pcm16Bytes, newFilename).
  static Future<(Uint8List, String)> _convertBinToPcm16(File binFile) async {
    final bytes = await binFile.readAsBytes();
    final byteData = ByteData.sublistView(bytes);
    final output = BytesBuilder();
    final decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);

    // Collect all decoded PCM16 frames, then group into 960-sample chunks (3 × 320)
    // to match the ambient companion's fs960 format the server expects.
    final decodedFrames = <Uint8List>[];
    try {
      int offset = 0;
      while (offset + 4 <= bytes.length) {
        final frameLength = byteData.getUint32(offset, Endian.little);

        if (frameLength == 0 || frameLength == 0xFFFFFFFF) { offset += 4; continue; }
        if (frameLength == 0xFFFFFFFB) { offset += 36; continue; }
        if (frameLength == 0xFFFFFFFE) { offset += 20; continue; }
        if (frameLength == 0xFFFFFFFD) { offset += 16; continue; }
        if (frameLength > 0xFFFF00) { offset += 4; continue; }

        if (offset + 4 + frameLength > bytes.length) break;

        final opusBytes = Uint8List.sublistView(bytes, offset + 4, offset + 4 + frameLength);
        offset += 4 + frameLength;

        try {
          final pcm = decoder.decode(input: opusBytes);
          decodedFrames.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
        } catch (_) {}
      }
    } finally {
      decoder.destroy();
    }

    // Group frames into ~3200 byte chunks (5 frames * 640 bytes).
    // This closely matches the hardware buffer chunk size produced by the Android native AudioRecord.
    for (var i = 0; i < decodedFrames.length; i += 5) {
      final chunk = BytesBuilder();
      for (var j = i; j < i + 5 && j < decodedFrames.length; j++) {
        chunk.add(decodedFrames[j]);
      }
      final chunkBytes = chunk.toBytes();
      final lenBytes = Uint8List(4);
      ByteData.sublistView(lenBytes).setUint32(0, chunkBytes.length, Endian.little);
      output.add(lenBytes);
      output.add(chunkBytes);
    }

    final filename = _pcm16Filename(binFile);
    return (output.toBytes(), filename);
  }

  static Future<http.Response> _doUpload(
    String url,
    List<File> binFiles,
    Map<String, int> fileSizes,
    Map<String, String> headers,
  ) async {
    final request = http.MultipartRequest('POST', Uri.parse(url))
      ..headers.addAll(headers);
    for (final f in binFiles) {
      request.files.add(http.MultipartFile(
        'files',
        f.openRead(),
        fileSizes[f.uri.pathSegments.last]!,
        filename: f.uri.pathSegments.last,
        contentType: MediaType('application', 'octet-stream'),
      ));
    }

    try {
      final streamed = await request.send().timeout(const Duration(seconds: 120));
      return http.Response.fromStream(streamed);
    } on SocketException {
      throw const OmiSyncException('No network connection');
    }
  }

  static Future<http.Response> _doUploadBytes(
    String url,
    List<(String filename, Uint8List bytes)> files,
    Map<String, String> headers,
  ) async {
    // Some strict backends fail to parse Dart's standard multipart boundaries.
    // We construct the multipart body manually to exactly match the working Kotlin client.
    final (filename, bytes) = files.first;
    final boundary = 'omiAmbient${DateTime.now().millisecondsSinceEpoch}';
    
    final bodyBuilder = BytesBuilder();
    bodyBuilder.add(utf8.encode('--$boundary\r\n'));
    bodyBuilder.add(utf8.encode('Content-Disposition: form-data; name="files"; filename="$filename"\r\n'));
    bodyBuilder.add(utf8.encode('Content-Type: application/octet-stream\r\n\r\n'));
    bodyBuilder.add(bytes);
    bodyBuilder.add(utf8.encode('\r\n--$boundary--\r\n'));
    
    final requestHeaders = Map<String, String>.from(headers);
    requestHeaders['Content-Type'] = 'multipart/form-data; boundary=$boundary';
    requestHeaders['Content-Length'] = bodyBuilder.length.toString();

    try {
      final res = await http.post(
        Uri.parse(url),
        headers: requestHeaders,
        body: bodyBuilder.toBytes(),
      ).timeout(const Duration(seconds: 120));
      return res;
    } on SocketException {
      throw const OmiSyncException('No network connection');
    }
  }

  static Future<OmiSyncResult> _pollJob(String baseUrl, String jobId, int initialDelayMs, [Map<String, String>? extraHeaders]) async {
    await Future.delayed(Duration(milliseconds: initialDelayMs));

    const maxAttempts = 80;
    var delayMs = 3000;
    for (var i = 0; i < maxAttempts; i++) {
      await refreshTokenIfNeeded();
      final token = await SharedPreferencesUtil().omiIdToken;
      
      final headers = {'Authorization': 'Bearer $token'};
      if (extraHeaders != null) {
        headers.addAll(extraHeaders);
      }

      final http.Response res;
      try {
        res = await http
            .get(Uri.parse('$baseUrl/$jobId'), headers: headers)
            .timeout(const Duration(seconds: 15));
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
      return OmiSyncResult(
        success: httpStatus >= 200 && httpStatus < 300,
        status: 'parse_error',
        error: e.toString(),
      );
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
        final res = await http.get(
          Uri.parse('$_conversationUrl/${Uri.encodeComponent(id)}?include_transcript=true'),
          headers: headers,
        ).timeout(const Duration(seconds: 15));

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
      final res = await http.get(
        Uri.parse(_speechProfileUrl),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

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
