import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:omi/utils/logger.dart';

/// Dart wrapper for the native VadBatchRunner method channel (Android + iOS).
///
/// Collapses the per-window Dart↔native platform-channel round-trips by sending
/// N×512-sample windows in one call and receiving N probabilities back. The
/// native side keeps the OrtSession, LSTM state, SR tensor, and 64-sample
/// context entirely in Kotlin — no Dart-side OrtValue management.
///
/// On platforms without the native runner (desktop, web, tests), [available] is
/// false and the caller falls back to the per-window `_runVad` path unchanged.
class VadBatchRunnerChannel {
  static const _channel = MethodChannel('com.omi.offline/vadBatchRunner');

  /// If provided, this instance lives in a background isolate and will bounce
  /// method channel requests to the main isolate via this port.
  final SendPort? isolateSendPort;

  VadBatchRunnerChannel({this.isolateSendPort});

  /// True when the native batch runner is available and initialised.
  bool _initialised = false;

  /// Whether the native batch runner is available and initialised. False on
  /// platforms with no native handler (desktop, web, tests).
  bool get available => _initialised;

  /// Initialise the native ORT session from [modelPath] (a filesystem path to
  /// silero_vad.onnx, not a Flutter asset key).
  ///
  /// No-op on non-Android platforms. On Android, catches channel exceptions
  /// gracefully — a missing channel handler (e.g. in tests or if the Activity
  /// was not configured) just means [available] stays false.
  Future<void> init(String modelPath) async {
    // Native runner exists on Android (VadBatchRunner.kt) and iOS
    // (VadBatchRunner.swift). On other platforms (desktop, web, tests) there is no
    // handler, so skip — the caller falls back to the per-window path. A missing
    // handler on a supported platform is also caught below (MissingPluginException).
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      if (isolateSendPort != null) {
        final replyPort = ReceivePort();
        isolateSendPort!.send({
          'type': 'vad_batch_init',
          'modelPath': modelPath,
          'replyPort': replyPort.sendPort,
        });
        final response = await replyPort.first.timeout(const Duration(seconds: 10));
        replyPort.close();
        if (response != 'ok') throw Exception(response);
      } else {
        await _channel.invokeMethod('init', {'modelPath': modelPath});
      }
      _initialised = true;
      Logger.debug('VadBatchRunnerChannel: init OK — native batch runner available');
    } on MissingPluginException {
      _initialised = false;
      Logger.debug('VadBatchRunnerChannel: channel not registered — per-window fallback');
    } catch (e) {
      _initialised = false;
      Logger.error('VadBatchRunnerChannel: init failed ($e) — per-window fallback');
    }
  }

  /// Run VAD inference on [samples] (N × 512 raw 16 kHz float32 samples, no
  /// context — native owns it). Returns N probabilities in order.
  ///
  /// [resetStateFirst]: true at a conversation boundary — zeros LSTM state and
  /// clears the 64-sample context before running.
  ///
  /// Throws on error (caller should fall back to per-window path).
  Future<Float32List> runVadBatch(Float32List samples, {bool resetStateFirst = false}) async {
    final Float32List? result;
    if (isolateSendPort != null) {
      final replyPort = ReceivePort();
      isolateSendPort!.send({
        'type': 'vad_batch_run',
        'samples': samples,
        'resetStateFirst': resetStateFirst,
        'replyPort': replyPort.sendPort,
      });
      final response = await replyPort.first.timeout(const Duration(seconds: 10));
      replyPort.close();
      if (response is String) throw Exception(response);
      result = response as Float32List?;
    } else {
      result = await _channel.invokeMethod<Float32List>('runVadBatch', {
        'samples': samples,
        'resetStateFirst': resetStateFirst,
      });
    }
    return result ?? Float32List(0);
  }

  /// Release the native ORT session and free all tensors.
  /// Safe to call multiple times or when not initialised.
  Future<void> dispose() async {
    if (!_initialised) return;
    try {
      if (isolateSendPort != null) {
        final replyPort = ReceivePort();
        isolateSendPort!.send({
          'type': 'vad_batch_dispose',
          'replyPort': replyPort.sendPort,
        });
        final response = await replyPort.first.timeout(const Duration(seconds: 10));
        replyPort.close();
        if (response != 'ok') throw Exception(response.toString());
      } else {
        await _channel.invokeMethod('dispose');
      }
      Logger.debug('VadBatchRunnerChannel: disposed');
    } catch (e) {
      Logger.error('VadBatchRunnerChannel: dispose error ($e)');
    } finally {
      _initialised = false;
    }
  }
}
