import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/ogg_opus_builder.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/logger.dart';

/// Represents a single word from a Deepgram response with its start/end
/// offset corrected to absolute time within the full recording window.
class WordTimestamp {
  final String word;
  final double start; // seconds from beginning of the full audio window
  final double end;
  final int speaker;

  const WordTimestamp({required this.word, required this.start, required this.end, required this.speaker});
}

/// Thrown when Deepgram returns HTTP 401 / 403.
class DeepgramAuthException implements Exception {
  final int statusCode;
  const DeepgramAuthException(this.statusCode);
  @override
  String toString() => 'DeepgramAuthException($statusCode)';
}

/// Thrown for non-auth HTTP errors (4xx/5xx).
class DeepgramApiException implements Exception {
  final int statusCode;
  final String body;
  const DeepgramApiException(this.statusCode, this.body);
  @override
  String toString() => 'DeepgramApiException($statusCode): $body';
}

/// Service that uploads Ogg/Opus audio to Deepgram's pre-recorded transcription
/// endpoint and returns word-level timestamps.
///
/// Audio is sent directly as `audio/ogg;codecs=opus` — no PCM decode or WAV
/// encoding is needed before upload.
class DeepgramTranscriptionService {
  static const String _baseUrl = 'https://api.deepgram.com/v1/listen';
  static const String _model = 'nova-3';

  /// Transcribes [opusFrames] (raw Opus packets, no length prefix) and returns
  /// word timestamps offset by [segmentOffset].
  ///
  /// [segmentOffset] is used when a long recording is split into multiple
  /// segments before upload; it shifts returned timestamps so they are relative
  /// to the beginning of the full audio window.
  static Future<List<WordTimestamp>> transcribeFrames(
    List<Uint8List> opusFrames,
    Duration segmentOffset, {
    String? apiKey,
  }) async {
    final key = apiKey ?? await SharedPreferencesUtil().readDeepgramApiKey();
    if (key.isEmpty) throw const DeepgramAuthException(0);

    final oggBytes = OggOpusBuilder.build(opusFrames);
    return _transcribeBytes(oggBytes, segmentOffset, key);
  }

  /// Lower-level variant that accepts already-encoded Ogg bytes.
  static Future<List<WordTimestamp>> transcribeOggBytes(
    Uint8List oggBytes,
    Duration segmentOffset, {
    String? apiKey,
  }) async {
    final key = apiKey ?? await SharedPreferencesUtil().readDeepgramApiKey();
    if (key.isEmpty) throw const DeepgramAuthException(0);
    return _transcribeBytes(oggBytes, segmentOffset, key);
  }

  static Future<List<WordTimestamp>> _transcribeBytes(
    Uint8List oggBytes,
    Duration segmentOffset,
    String apiKey,
  ) async {
    final uri = Uri.parse('$_baseUrl?model=$_model&diarize=true&punctuate=true&utterances=false&smart_format=true');
    final headers = {
      'Authorization': 'Token $apiKey',
      'Content-Type': 'audio/ogg;codecs=opus',
    };

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await http.post(uri, headers: headers, body: oggBytes);
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw DeepgramAuthException(response.statusCode);
        }
        if (response.statusCode != 200) {
          throw DeepgramApiException(response.statusCode, response.body);
        }
        return _parseResponse(response.body, segmentOffset);
      } on DeepgramAuthException {
        rethrow;
      } catch (e) {
        if (attempt == 1) rethrow;
        Logger.debug('DeepgramTranscriptionService: transient error, retrying in 2 s: $e');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    throw StateError('unreachable');
  }

  static List<WordTimestamp> _parseResponse(String jsonBody, Duration offset) {
    try {
      final json = jsonDecode(jsonBody) as Map<String, dynamic>;
      final channels = (json['results']?['channels'] as List<dynamic>?) ?? [];
      if (channels.isEmpty) return [];
      final alts = (channels[0]['alternatives'] as List<dynamic>?) ?? [];
      if (alts.isEmpty) return [];
      final words = (alts[0]['words'] as List<dynamic>?) ?? [];
      final offsetSecs = offset.inMilliseconds / 1000.0;
      return words.map((w) {
        final m = w as Map<String, dynamic>;
        return WordTimestamp(
          word: m['word'] as String? ?? '',
          start: ((m['start'] as num?)?.toDouble() ?? 0.0) + offsetSecs,
          end: ((m['end'] as num?)?.toDouble() ?? 0.0) + offsetSecs,
          speaker: m['speaker'] as int? ?? 0,
        );
      }).toList();
    } catch (e) {
      Logger.error('DeepgramTranscriptionService: Failed to parse response: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Overlap window calculation (per plan spec)
  // ---------------------------------------------------------------------------

  /// Returns the overlap duration to prepend to each sync window.
  ///
  /// | splitGapSeconds | overlapSeconds  |
  /// |-----------------|-----------------|
  /// | < 120 (2 min)   | 300 (fixed 5 min) |
  /// | ≥ 120           | splitGap + 300  |
  static Duration computeOverlap(int splitGapSeconds) {
    if (splitGapSeconds < 120) return const Duration(seconds: 300);
    return Duration(seconds: splitGapSeconds + 300);
  }

  // ---------------------------------------------------------------------------
  // Transcript → RecordingTranscript conversion helper
  // ---------------------------------------------------------------------------

  /// Converts a list of [WordTimestamp]s and the full transcript text into the
  /// [RecordingTranscript] model that is written to the `.transcript.json` sidecar.
  static RecordingTranscript toRecordingTranscript(List<WordTimestamp> words, String? fullText) {
    return RecordingTranscript(
      method: SplitMethod.deepgram,
      text: fullText,
      words: words
          .map((w) => TranscriptWord(word: w.word, start: w.start, end: w.end, speaker: w.speaker))
          .toList(),
    );
  }

  /// Writes a `.transcript.json` sidecar alongside [recordingFile].
  static Future<void> writeSidecar(File recordingFile, RecordingTranscript transcript) async {
    final basePath = recordingFile.path.contains('.')
        ? recordingFile.path.substring(0, recordingFile.path.lastIndexOf('.'))
        : recordingFile.path;
    final sidecar = File('$basePath.transcript.json');
    await sidecar.writeAsString(jsonEncode(transcript.toJson()));
  }
}
