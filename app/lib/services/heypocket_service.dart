import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:omi/services/recordings_manager.dart';
import 'package:path/path.dart' as p;

class HeyPocketService {
  static const _base = 'https://public.heypocketai.com/api/v1';

  /// Returns true if API key is valid (GET /recordings/list-recordings → 200).
  static Future<bool> testConnection(String apiKey) async {
    try {
      final res = await http
          .get(Uri.parse('$_base/public/recordings'), headers: {'Authorization': 'Bearer $apiKey'})
          .timeout(const Duration(seconds: 8));
      return res.statusCode >= 200 && res.statusCode < 300;
    } on TimeoutException {
      throw HeyPocketException(0, 'Connection timed out — check your network');
    } on SocketException {
      throw HeyPocketException(0, 'No network connection');
    } catch (e) {
      throw HeyPocketException(0, 'Connection failed');
    }
  }

  static String _mimeType(String path) =>
      path.endsWith('.wav') ? 'audio/wav' : 'audio/mp4';

  static String _title(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return 'Recording – ${months[dt.month - 1]} ${dt.day}, ${dt.year} $h:$m $ampm';
  }

  /// RFC3339 timestamp preserving local timezone offset (e.g. 2024-03-16T19:23:00-07:00).
  static String _rfc3339(DateTime dt) {
    final offset = dt.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final base = dt.toIso8601String().split('.').first;
    return '$base$sign$hh:$mm';
  }

  /// Two-step upload:
  ///   1. POST /public/recordings/upload-url → extract upload_url from response data
  ///   2. PUT presigned URL streaming file bytes
  static Future<void> uploadRecording(String apiKey, Conversation rec) async {
    try {
      final contentType = _mimeType(rec.file.path);

      // Step 1: get presigned URL
      final postRes = await http
          .post(
            Uri.parse('$_base/public/recordings/upload-url'),
            headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'title': _title(rec.startTime),
              'file_name': p.basename(rec.file.path),
              'content_type': contentType,
              'duration': rec.duration.inSeconds,
              'recording_at': _rfc3339(rec.startTime),
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (postRes.statusCode != 200) {
        throw HeyPocketException(postRes.statusCode, _errorMessage(postRes.statusCode));
      }

      final body = jsonDecode(postRes.body);
      final data = body is Map ? body['data'] : null;
      final url = data is Map ? data['upload_url'] : null;
      if (url is! String || url.isEmpty) throw HeyPocketException(500, 'Invalid upload URL');
      final uri = Uri.tryParse(url);
      if (uri == null) throw HeyPocketException(500, 'Invalid upload URL');

      // Step 2: stream PUT file to presigned URL
      final fileLength = await rec.file.length();
      final request = http.StreamedRequest('PUT', uri)
        ..headers['Content-Type'] = contentType
        ..contentLength = fileLength;

      Object? streamError;
      final pipeFuture = rec.file.openRead().pipe(request.sink).catchError((e) {
        streamError = e;
        request.sink.close();
      });

      final streamedRes = await request.send();
      await pipeFuture.timeout(const Duration(seconds: 60));

      if (streamError != null) throw HeyPocketException(0, 'File read failed during upload');
      if (streamedRes.statusCode != 200 && streamedRes.statusCode != 204) {
        throw HeyPocketException(streamedRes.statusCode, _errorMessage(streamedRes.statusCode));
      }
    } on HeyPocketException {
      rethrow;
    } on TimeoutException {
      throw HeyPocketException(0, 'Connection timed out — check your network');
    } on SocketException {
      throw HeyPocketException(0, 'No network connection');
    } catch (e) {
      throw HeyPocketException(0, 'Upload failed');
    }
  }

  static String _errorMessage(int code) => switch (code) {
        400 => 'Bad request — check file format',
        401 => 'Unauthorized — check your API key',
        _ => 'HeyPocket server error — try again later',
      };
}

class HeyPocketException implements Exception {
  final int statusCode;
  final String message;
  const HeyPocketException(this.statusCode, this.message);

  @override
  String toString() => 'HeyPocketException($statusCode): $message';
}
