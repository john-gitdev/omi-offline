import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:omi/utils/logger.dart';

/// Dart wrapper for the native AAC encoder platform channel.
///
/// Call [startEncoder] to begin a session, feed PCM bytes via [encodeChunk] in
/// batches, then call [finishEncoder] to flush and write the final M4A file.
///
/// All methods throw [PlatformException] on native errors — callers should
/// catch and fall back to WAV to ensure recordings are never lost.
class AacEncoder {
  static const _channel = MethodChannel('com.omi.offline/aacEncoder');

  /// Opens a new encoding session targeting [outputPath] (must end in `.m4a`).
  /// Returns an opaque session ID string to pass to subsequent calls.
  static Future<String> startEncoder(int sampleRate, String outputPath, {int bitrate = 32000}) async {
    final sessionId = await _channel.invokeMethod<String>('startEncoder', {
      'sampleRate': sampleRate,
      'outputPath': outputPath,
      'bitrate': bitrate,
    });
    return sessionId!;
  }

  /// Feed a batch of raw 16-bit little-endian PCM bytes to the encoder.
  static Future<void> encodeChunk(String sessionId, Uint8List pcmBytes) async {
    await _channel.invokeMethod<void>('encodeChunk', {
      'sessionId': sessionId,
      'pcmBytes': pcmBytes,
    });
  }

  /// Finalize the encoder: flush, close the file, and rename temp→final.
  static Future<void> finishEncoder(String sessionId) async {
    await _channel.invokeMethod<void>('finishEncoder', {
      'sessionId': sessionId,
    });
  }
}
