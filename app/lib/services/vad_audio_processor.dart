import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:omi/utils/logger.dart';

import "package:meta/meta.dart";

/// All VAD/processing settings captured from SharedPreferences in the main isolate
/// before spawning the processing isolate. All fields are primitives — safe to send
/// across isolate boundaries.
class ProcessingSettings {
  final bool vadEnabled;
  final double speechThreshold;
  final int silenceDurationToSplitMs;
  final int minDurationMs;
  final bool discardShort;
  final int maxChunkMs;
  final String deviceId; // used to generate upload key in .meta sidecar
  final bool convertOpusToM4a;
  final bool omiSyncEnabled;

  const ProcessingSettings({
    required this.vadEnabled,
    required this.speechThreshold,
    required this.silenceDurationToSplitMs,
    required this.minDurationMs,
    required this.discardShort,
    required this.maxChunkMs,
    required this.deviceId,
    required this.convertOpusToM4a,
    required this.omiSyncEnabled,
  });

  factory ProcessingSettings.fromPrefs() {
    final p = SharedPreferencesUtil();
    return ProcessingSettings(
      vadEnabled: p.vadEnabled,
      speechThreshold: p.vadSpeechThreshold,
      silenceDurationToSplitMs: p.vadSplitSeconds * 1000,
      minDurationMs: p.filterMinDurationSeconds * 1000,
      discardShort: p.discardShortRecordings,
      maxChunkMs: p.vadMaxConversationMinutes * 60 * 1000,
      deviceId: p.btDevice.id,
      convertOpusToM4a: p.convertOpusToM4a,
      omiSyncEnabled: p.omiSyncEnabled,
    );
  }
}

class VadAudioProcessor {
  // Silero VAD session + LSTM state (reset on gap detection)
  OrtSession? _session;
  Float32List _h = Float32List(2 * 1 * 64); // LSTM hidden state
  Float32List _c = Float32List(2 * 1 * 64); // LSTM cell state
  final List<double> _pcmWindow = []; // accumulates samples toward 512-window

  // Opus decoder
  final SimpleOpusDecoder? _decoder;
  final String? _outputDir;

  // Per-conversation accumulation — FrameRef disk-pointers only, no Opus in RAM.
  // Can also contain Duration objects representing silence gaps to be padded.
  List<Object> _currentRefs = [];
  int _speechFrameCount = 0; // speech frames in current conversation
  DateTime? _recordingStartTime;
  DateTime? _lastSegmentEndTime;
  bool _isDerivedTimestamp = false; // true when segment had no valid device RTC timestamp
  int? _currentSessionId;
  int? _currentStartUptime;

  // VAD state counters
  int _currentChunkDurationMs = 0; // total frames accumulated (for max-cap)

  /// True after a [flushRemaining] call where the short-recording discard guard
  /// fired (refs were non-empty but below the duration threshold). False if the
  /// guard did not fire (either no refs, or proceeded to save). Test-only.
  @visibleForTesting
  bool discardGuardFiredOnLastFlush = false;

  // Marker-forced recording state
  bool _forcedByMarker = false;

  // Tracks segment files that have been fully processed. Used by consumeSafeToDeletePaths()
  // to determine which files are no longer referenced by any internal buffer.
  final Set<String> _processedFiles = {};

  // Settings — cached at construction time for the lifetime of one processAll pass
  final double _speechThreshold;
  final int _silenceDurationToSplitMs;
  final int _minDurationMs;
  final bool _discardShort;
  final int _maxChunkMs;
  final String _deviceId;
  final bool _convertOpusToM4a;
  final bool _omiSyncEnabled;

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 20; // 20 ms per Opus frame
  static const int _vadWindowSamples = 512; // Silero VAD input size

  /// Creates a processor in the main isolate, reading settings from SharedPreferences.
  static Future<VadAudioProcessor> create({String? outputDir, SimpleOpusDecoder? decoder}) async {
    final settings = ProcessingSettings.fromPrefs();
    OrtSession? session;
    if (settings.vadEnabled) {
      try {
        OrtEnv.instance.init();
      } catch (e) {
        Logger.error("VadAudioProcessor: Failed to init OrtEnv: $e");
      }
      try {
        final data = await rootBundle.load('assets/models/silero_vad.onnx');
        final sessionOptions = OrtSessionOptions();
        session = OrtSession.fromBuffer(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), sessionOptions);
      } catch (e) {
        Logger.error('VadAudioProcessor: Failed to load Silero VAD model, AAD mode active: $e');
      }
    }
    Logger.debug(
        'VadAudioProcessor: init — ${session != null ? 'Silero VAD loaded' : 'AAD mode${settings.vadEnabled ? ' (model unavailable)' : ''}'}');
    return VadAudioProcessor._(outputDir: outputDir, decoder: decoder, session: session, settings: settings);
  }

  /// Creates a processor from pre-captured settings — safe to call in a background isolate.
  /// The caller is responsible for initialising OrtEnv and creating [session] / [decoder] before
  /// calling this constructor.
  VadAudioProcessor.fromSettings({
    required ProcessingSettings settings,
    String? outputDir,
    OrtSession? session,
    SimpleOpusDecoder? decoder,
  }) : this._(outputDir: outputDir, decoder: decoder, session: session, settings: settings);

  VadAudioProcessor._(
      {String? outputDir, SimpleOpusDecoder? decoder, OrtSession? session, required ProcessingSettings settings})
      : _session = session,
        _decoder = decoder ??
            (Platform.isIOS || Platform.isAndroid
                ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
                : null),
        _outputDir = outputDir,
        _speechThreshold = settings.speechThreshold,
        _silenceDurationToSplitMs = settings.silenceDurationToSplitMs,
        _minDurationMs = settings.minDurationMs,
        _discardShort = settings.discardShort,
        _maxChunkMs = settings.maxChunkMs,
        _deviceId = settings.deviceId,
        _convertOpusToM4a = settings.convertOpusToM4a,
        _omiSyncEnabled = settings.omiSyncEnabled;

  void destroy() {
    _decoder?.destroy();
    _session?.release();
  }

  bool get isCapturing => (_currentRefs.isNotEmpty && _speechFrameCount > 0) || _forcedByMarker;

  bool _runVad(List<double> samples512) {
    if (_session == null) {
      // Hardware AAD mode — all audio treated as speech; splitting driven by firmware timestamps only.
      return true;
    }
    final input = Float32List.fromList(samples512);
    final sr = Int64List.fromList([sampleRate]);

    final inputs = {
      'input': OrtValueTensor.createTensorWithDataList(input, [1, _vadWindowSamples]),
      'sr': OrtValueTensor.createTensorWithDataList(sr, [1]),
      'h': OrtValueTensor.createTensorWithDataList(_h, [2, 1, 64]),
      'c': OrtValueTensor.createTensorWithDataList(_c, [2, 1, 64]),
    };

    OrtRunOptions? runOptions;
    List<OrtValue?>? outputs;
    try {
      runOptions = OrtRunOptions();
      outputs = _session!.run(runOptions, inputs);
      final prob = (outputs[0]!.value as List<List<double>>)[0][0];
      _h = _flattenF32(outputs[1]!.value);
      _c = _flattenF32(outputs[2]!.value);
      return prob > _speechThreshold;
    } catch (e) {
      Logger.error('VadAudioProcessor: Silero inference failed ($e) — disabling model, AAD mode active');
      _session = null;
      return true;
    } finally {
      for (final t in inputs.values) {
        t.release();
      }
      outputs?.forEach((o) => o?.release());
      runOptions?.release();
    }
  }

  Float32List _flattenF32(dynamic nested) {
    final flat = <double>[];
    void recurse(dynamic v) {
      if (v is List) {
        for (final e in v) recurse(e);
      } else if (v is double)
        flat.add(v);
      else if (v is num) flat.add(v.toDouble());
    }

    recurse(nested);
    return Float32List.fromList(flat);
  }

  Future<List<String>> processSegmentFile(File segmentFile, DateTime segmentStartTime,
      {bool isDerivedTimestamp = false, int? sessionId}) async {
    final savedFiles = <String>[];
    _isDerivedTimestamp = isDerivedTimestamp;

    // VAD-resume anchor: set when a 0xFFFFFFFD packet is encountered.
    // Recalibrates frame timestamps after a firmware-side silence gap.
    DateTime? vadResumeTime;
    int? vadResumeFrameIndex;

    // Wall-clock time of the last processed audio frame (updated each frame).
    DateTime lastFrameWallTime = segmentStartTime;

    try {
      if (!await segmentFile.exists()) return [];
      final bytes = await segmentFile.readAsBytes();
      final fileLength = bytes.length;
      if (fileLength == 0) return [];
      final byteData = ByteData.sublistView(bytes);

      if (_lastSegmentEndTime != null) {
        final gapMs = segmentStartTime.difference(_lastSegmentEndTime!).inMilliseconds;
        if (_currentRefs.isNotEmpty && gapMs > _silenceDurationToSplitMs) {
          Logger.debug(
            'VadAudioProcessor: Gap detected before ${segmentFile.path.split('/').last} — '
            'gapMs=$gapMs (threshold=${_silenceDurationToSplitMs}ms), '
            'lastEnd=$_lastSegmentEndTime segmentStart=$segmentStartTime — flushing.',
          );
          _h = Float32List(2 * 1 * 64);
          _c = Float32List(2 * 1 * 64);
          _pcmWindow.clear();
          final filePath = await flushRemaining();
          if (filePath != null) savedFiles.add(filePath);
        } else if (gapMs > 0 && gapMs <= _silenceDurationToSplitMs) {
          Logger.debug(
            'VadAudioProcessor: Small gap before ${segmentFile.path.split('/').last} — '
            'gapMs=$gapMs (within threshold, inserting silence).',
          );
          if (_currentRefs.isNotEmpty) {
            _currentRefs.add(Duration(milliseconds: gapMs));
            _currentChunkDurationMs += gapMs;
          }
        }
        // gapMs <= 0: sequential firmware files with no real gap — stitch seamlessly.
      }

      if (_currentRefs.isEmpty) {
        // Set the recording start to this bin's timestamp only on a genuine fresh start.
        // Preserve _recordingStartTime when it is already set to a time AT OR AFTER
        // _lastSegmentEndTime — that means a cap cut just fired and set it to cutTime,
        // which must not be overwritten with an earlier bin timestamp.
        final capJustFired = _recordingStartTime != null &&
            _lastSegmentEndTime != null &&
            !_recordingStartTime!.isBefore(_lastSegmentEndTime!);
        if (!capJustFired) {
          _recordingStartTime = segmentStartTime;
          _currentSessionId = sessionId;
          _currentStartUptime = isDerivedTimestamp ? segmentStartTime.millisecondsSinceEpoch ~/ 1000 : 0;
        }
      }

      int offset = 0;
      int frameIndex = 0;
      int totalFrameCount = 0;
      int segmentSpeechFrames = 0;
      double segmentMaxAmp = 0.0;

      while (offset < fileLength) {
        if (offset + 4 > fileLength) break;

        final frameLength = byteData.getUint32(offset, Endian.little);

        // Skip null/sentinel words.
        if (frameLength == 0 || frameLength == 0xFFFFFFFF) {
          offset += 4;
          continue;
        }

        // Marker packet (0xFFFFFFFE = button-tap marker, 20 bytes: 4-byte header + 16-byte payload).
        // Payload layout: [0..3] UTC epoch seconds (u32 LE), [4..7] uptime ms, [8..11] session id.
        if (frameLength == 0xFFFFFFFE) {
          if (offset + 8 <= fileLength) {
            final markerUtcSeconds = byteData.getUint32(offset + 4, Endian.little);
            const kMinValidMarkerEpoch = 946684800;
            if (markerUtcSeconds > kMinValidMarkerEpoch) {
              final markerFrameTime = DateTime.fromMillisecondsSinceEpoch(markerUtcSeconds * 1000, isUtc: true);
              if (isCapturing) {
                // Marker during active recording — continue, don't split.
                Logger.debug('VadAudioProcessor: Marker at $markerFrameTime — continuing active recording.');
              } else {
                // Marker while not recording — start immediately at this point.
                // Reset lastFrameWallTime to the tap so the next VAD-resume gap is measured
                // from the button press, not from whenever the previous conversation ended.
                lastFrameWallTime = markerFrameTime;
                _recordingStartTime = markerFrameTime;
                _speechFrameCount = 0;
                _currentChunkDurationMs = 0;
                _currentRefs = [];
                _forcedByMarker = true;
                Logger.debug('VadAudioProcessor: Marker at $markerFrameTime — starting recording immediately.');
              }
            }
          }
          offset += 20;
          continue;
        }

        // VAD-resume timestamp packet (0xFFFFFFFD): firmware writes this when AAD wakes
        // from silence. Used to decide stitch vs split and recalibrate frame timestamps.
        // Payload: [0..3] UTC epoch seconds (u32 LE), [4..7] uptime ms (u32 LE), [8..15] padding.
        if (frameLength == 0xFFFFFFFD) {
          if (offset + 8 <= fileLength) {
            final vadUtcSeconds = byteData.getUint32(offset + 4, Endian.little);
            const kMinValidEpoch = 946684800;
            if (vadUtcSeconds > kMinValidEpoch) {
              final newResumeTime = DateTime.fromMillisecondsSinceEpoch(vadUtcSeconds * 1000, isUtc: true);
              final gapMs = newResumeTime.difference(lastFrameWallTime).inMilliseconds;

              if (gapMs >= _silenceDurationToSplitMs) {
                // Gap exceeds threshold — flush current recording, start new conversation.
                if (_currentRefs.isNotEmpty &&
                    (!_discardShort || _currentChunkDurationMs >= _minDurationMs || _forcedByMarker)) {
                  final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
                  if (filePath != null) savedFiles.add(filePath);
                }
                _currentRefs = [];
                _speechFrameCount = 0;
                _currentChunkDurationMs = 0;
                _forcedByMarker = false;
                _recordingStartTime = newResumeTime;
                Logger.debug('VadAudioProcessor: VAD resume — gap ${gapMs}ms >= threshold, new conversation.');
              } else {
                // Gap within threshold — stitch, padding with silence so playback reflects real timing.
                if (_currentRefs.isNotEmpty && gapMs > 0) {
                  _currentRefs.add(Duration(milliseconds: gapMs));
                  _currentChunkDurationMs += gapMs;
                }
                Logger.debug('VadAudioProcessor: VAD resume — gap ${gapMs}ms < threshold, stitching with silence pad.');
              }

              // Update anchor for subsequent frame timestamp calculations.
              vadResumeTime = newResumeTime;
              vadResumeFrameIndex = frameIndex;
            }
          }
          offset += 20;
          continue;
        }

        if (offset + 4 + frameLength > fileLength) {
          Logger.debug('VadAudioProcessor: Incomplete frame at offset $offset in ${segmentFile.path}');
          break;
        }

        if (frameIndex % 50 == 0) await Future.delayed(Duration.zero);

        final opusBytes = Uint8List.sublistView(bytes, offset + 4, offset + 4 + frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (_) {}

        bool isSpeech = false;
        if (pcmData != null) {
          for (int s = 0; s < pcmData.length; s++) {
            final sample = pcmData[s] / 32768.0;
            _pcmWindow.add(sample);
            if (sample.abs() > segmentMaxAmp) segmentMaxAmp = sample.abs();
          }
          while (_pcmWindow.length >= 512) {
            final window = _pcmWindow.sublist(0, 512);
            _pcmWindow.removeRange(0, 512);
            if (_runVad(window)) isSpeech = true;
          }
        }

        final frameRef = FrameRef(segmentFile: segmentFile, byteOffset: offset, frameLength: frameLength);
        if (isSpeech) {
          _speechFrameCount++;
          segmentSpeechFrames++;
        }
        _currentRefs.add(frameRef);
        _currentChunkDurationMs += frameDurationMs;

        if (_recordingStartTime == null) {
          _recordingStartTime = (vadResumeTime != null && vadResumeFrameIndex != null)
              ? vadResumeTime!
              : segmentStartTime;
        }

        // Compute accurate wall-clock time for this frame using VAD-resume anchor if available.
        final frameTime = (vadResumeTime != null && vadResumeFrameIndex != null)
            ? vadResumeTime!.add(Duration(milliseconds: (frameIndex - vadResumeFrameIndex!) * frameDurationMs))
            : segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
        lastFrameWallTime = frameTime;

        // Silence-based splits are handled by 0xFFFFFFFD timestamp packets.
        // Only enforce the max conversation duration cap here.
        if (_currentChunkDurationMs >= _maxChunkMs) {
          Logger.debug('VadAudioProcessor: Max conversation duration — forcing cut.');
          final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
          if (filePath != null) savedFiles.add(filePath);
          final cutTime = _recordingStartTime!.add(Duration(milliseconds: _currentChunkDurationMs));
          _forcedByMarker = false;
          _currentRefs = [];
          _speechFrameCount = 0;
          _currentChunkDurationMs = 0;
          _recordingStartTime = cutTime;
        }

        offset += 4 + ((frameLength + 3) & ~3); // advance past 4-byte-aligned frame (matches SD card wire format)
        frameIndex++;
        totalFrameCount++;
      }

      _lastSegmentEndTime = lastFrameWallTime.add(const Duration(milliseconds: frameDurationMs));
      Logger.debug('VadAudioProcessor: ${segmentFile.path.split('/').last} — '
          '$totalFrameCount frames, $segmentSpeechFrames speech frames, maxAmp=${segmentMaxAmp.toStringAsFixed(4)}');
    } catch (e) {
      Logger.error('VadAudioProcessor: processSegmentFile error: $e');
    }

    _processedFiles.add(segmentFile.path);
    return savedFiles;
  }

  Future<String?> flushRemaining({bool isDraft = false}) async {
    if (_currentRefs.isEmpty || (_discardShort && _currentChunkDurationMs < _minDurationMs && !_forcedByMarker)) {
      discardGuardFiredOnLastFlush = _currentRefs.isNotEmpty;
      if (_currentRefs.isNotEmpty) {
        Logger.debug(
          'VadAudioProcessor: flushRemaining discarding ${_currentRefs.length} frames '
          '(${_currentChunkDurationMs}ms < ${_minDurationMs}ms minimum)',
        );
      }
      _resetState();
      return null;
    }
    discardGuardFiredOnLastFlush = false;
    final path = await _saveRecording(_currentRefs, _recordingStartTime!, isDraft: isDraft);
    _resetState();
    return path;
  }

  Future<String?> flushOnlyCompleted() async {
    if (isCapturing) {
      Logger.debug(
          'VadAudioProcessor: flushOnlyCompleted — capture in progress, skipping flush to allow continuation.');
      return null;
    }
    return flushRemaining();
  }

  /// Returns the set of segment file paths that have been fully processed and are
  /// no longer referenced by [_currentRefs].
  /// Each path is returned at most once. The caller may safely delete these files.
  Set<String> consumeSafeToDeletePaths() {
    final referenced = <String>{};
    for (final item in _currentRefs) {
      if (item is FrameRef) referenced.add(item.segmentFile.path);
    }
    final safe = _processedFiles.difference(referenced);
    _processedFiles.removeAll(safe);
    return safe;
  }

  void _resetState() {
    _currentRefs = [];
    _speechFrameCount = 0;
    _currentChunkDurationMs = 0;
    _recordingStartTime = null;
    _forcedByMarker = false;
  }

  @visibleForTesting
  Future<String?> saveRecordingTest(List<Object> refs, DateTime startTime, {bool isDerivedTimestamp = false}) =>
      _saveRecording(refs, startTime, isDerivedTimestamp: isDerivedTimestamp);

  Future<String?> _saveRecording(List<Object> refs, DateTime startTime,
      {bool? isDerivedTimestamp, bool isDraft = false}) async {
    final result = await _saveRecordingCore(refs, startTime, isDerivedTimestamp: isDerivedTimestamp, isDraft: isDraft);
    if (result != null && _omiSyncEnabled) {
      try {
        final dateFolderPath = File(result).parent.path;
        await _saveBin(refs, dateFolderPath, startTime.millisecondsSinceEpoch);
      } catch (e) {
        Logger.error('VadAudioProcessor: _saveBin failed: $e');
      }
    }
    return result;
  }

  /// Writes a raw Opus .bin file (4-byte LE length prefix + Opus bytes per frame) for upload
  /// to the Omi backend. Filename includes `_fs320_` so the server uses the correct 320-sample
  /// frame size (16 kHz × 20 ms) instead of its 160-sample default.
  Future<void> _saveBin(List<Object> refs, String dateFolderPath, int timestamp) async {
    final binPath = '$dateFolderPath/recording_fs320_$timestamp.bin';
    final sink = File(binPath).openWrite();
    try {
      String? currentFilePath;
      Uint8List? currentFileBytes;
      for (var i = 0; i < refs.length; i++) {
        final item = refs[i];
        if (item is! FrameRef) continue;

        if (i % 50 == 0) await Future.delayed(Duration.zero);
        if (item.segmentFile.path != currentFilePath) {
          currentFileBytes = await item.segmentFile.readAsBytes();
          currentFilePath = item.segmentFile.path;
          await Future.delayed(Duration.zero);
        }
        if (currentFileBytes == null) continue;
        // Write 4-byte length prefix + Opus packet as-is.
        sink.add(Uint8List.sublistView(currentFileBytes, item.byteOffset, item.byteOffset + 4 + item.frameLength));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    Logger.debug('VadAudioProcessor: Saved bin for Omi sync — $binPath');
  }

  Future<String?> _saveRecordingCore(List<Object> refs, DateTime startTime,
      {bool? isDerivedTimestamp, bool isDraft = false}) async {
    final derived = isDerivedTimestamp ?? _isDerivedTimestamp;
    final prefix = derived ? 'unknown' : 'recording';
    final timestamp = startTime.millisecondsSinceEpoch;
    // Append _draft if requested, but only for files with valid timestamps (not 'unknown_').
    final suffix = (isDraft && !derived) ? '_draft' : '';

    String dateFolderPath;
    if (_outputDir != null) {
      dateFolderPath = _outputDir!;
    } else {
      final directory = await getApplicationDocumentsDirectory();
      final dateString =
          '${startTime.year}-${startTime.month.toString().padLeft(2, '0')}-${startTime.day.toString().padLeft(2, '0')}';
      dateFolderPath = '${directory.path}/recordings/$dateString';
    }

    final dateFolder = Directory(dateFolderPath);
    if (!await dateFolder.exists()) {
      await dateFolder.create(recursive: true);
    }

    final frameRefCount = refs.whereType<FrameRef>().length;
    if (frameRefCount > 0 && frameRefCount < 5) {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }

    if (!_convertOpusToM4a) {
      if (Platform.isIOS) {
        return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
      } else {
        return await _saveOgg(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
      }
    }

    final m4aPath = '${dateFolder.path}/${prefix}_$timestamp$suffix.m4a';

    const waveformBuckets = 200;
    const windowSize = 800;
    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;

    const batchFrames = 15;
    final batchBuffer = BytesBuilder(copy: false);
    int totalSamples = 0;
    int batchFrameCount = 0;

    String? sessionId;
    bool aacFailed = false;
    bool hasEncodedAnyFrames = false;

    try {
      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
    } on Exception catch (e) {
      Logger.error('VadAudioProcessor: AAC startEncoder failed, falling back to WAV: $e');
      aacFailed = true;
    }

    if (aacFailed) {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix);
    }

    Future<void> flushBatch() async {
      if (batchBuffer.isEmpty) return;
      final bytes = batchBuffer.takeBytes();
      batchFrameCount = 0;
      hasEncodedAnyFrames = true;
      
      int offset = 0;
      while (offset < bytes.length) {
        final chunkLen = (bytes.length - offset > 16000) ? 16000 : bytes.length - offset;
        final chunk = Uint8List.sublistView(bytes, offset, offset + chunkLen);
        await AacEncoder.encodeBuffer(sessionId!, chunk);
        offset += chunkLen;
      }
    }

    String? currentFilePath;
    Uint8List? currentFileBytes;

    try {
      for (var i = 0; i < refs.length; i++) {
        final item = refs[i];

        if (item is Duration) {
          final pcmSamples = (item.inMilliseconds * sampleRate) ~/ 1000;
          final silenceBytes = Uint8List(pcmSamples * channels * 2);
          batchBuffer.add(silenceBytes);
          totalSamples += pcmSamples;

          for (int s = 0; s < pcmSamples; s++) {
            currentWindowSamples++;
            if (currentWindowSamples >= windowSize) {
              dynamicPeaks.add(0.0);
              currentWindowSamples = 0;
            }
          }

          if (batchBuffer.length > 32000) {
            await flushBatch();
          }
          continue;
        }

        final ref = item as FrameRef;
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        if (ref.segmentFile.path != currentFilePath) {
          // Note: reading the entire file into memory is a tradeoff (avoids thousands of native file seek/read calls).
          // Segment files are typically small enough (a few MBs) to make this safe and dramatically faster.
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
          await Future.delayed(Duration.zero);
        }

        if (currentFileBytes == null) continue;

        final frameDataOffset = ref.byteOffset + 4;
        final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (e) {
          continue;
        }

        if (pcmData == null) continue;

        for (int s = 0; s < pcmData.length; s++) {
          final amplitude = pcmData[s].abs() / 32768.0;
          if (amplitude > currentWindowMax) currentWindowMax = amplitude;
          currentWindowSamples++;
          if (currentWindowSamples >= windowSize) {
            dynamicPeaks.add(currentWindowMax);
            currentWindowMax = 0.0;
            currentWindowSamples = 0;
          }
        }
        totalSamples += pcmData.length;

        batchBuffer.add(pcmData.buffer.asUint8List(pcmData.offsetInBytes, pcmData.lengthInBytes));
        batchFrameCount++;

        if (batchFrameCount >= batchFrames) {
          await flushBatch();
          await Future.delayed(Duration.zero);
        }
      }

      await flushBatch();
      await Future.delayed(Duration.zero);

      if (currentWindowSamples > 0) {
        dynamicPeaks.add(currentWindowMax);
      }

      if (!hasEncodedAnyFrames) {
        Logger.debug('VadAudioProcessor: No frames encoded — discarding empty segment.');
        final emptyFile = File(m4aPath);
        if (await emptyFile.exists()) await emptyFile.delete();
        return null;
      }

      await AacEncoder.finishEncoder(sessionId!);
    } on Exception catch (e) {
      Logger.error('VadAudioProcessor: AAC encoding failed, falling back to WAV: $e');
      final corruptFile = File('${dateFolder.path}/${prefix}_$timestamp$suffix.m4a');
      try {
        if (await corruptFile.exists()) await corruptFile.delete();
      } catch (_) {}
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }

    await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
        prefix: prefix, extension: 'm4a', suffix: suffix);

    Logger.debug(
        'VadAudioProcessor: Saved recording (${refs.length} frames, ${((totalSamples * 1000) ~/ sampleRate)}ms) '
        'starting at $startTime to $m4aPath');
    return m4aPath;
  }

  Future<void> _saveMetadata(List<Object> refs, String dateFolderPath, int timestamp, int totalSamples,
      List<double> dynamicPeaks, int waveformBuckets,
      {required String prefix, required String extension, String suffix = ''}) async {
    final finalAmplitudes = List<double>.filled(waveformBuckets, 0.0);
    if (dynamicPeaks.isNotEmpty) {
      final double ratio = dynamicPeaks.length / waveformBuckets;
      for (int i = 0; i < waveformBuckets; i++) {
        final startIdx = (i * ratio).floor();
        final endIdx = ((i + 1) * ratio).ceil().clamp(0, dynamicPeaks.length);
        double peak = 0.0;
        for (int j = startIdx; j < endIdx; j++) {
          if (dynamicPeaks[j] > peak) peak = dynamicPeaks[j];
        }
        finalAmplitudes[i] = peak;
      }
    }

    final durationMs = (totalSamples * 1000) ~/ sampleRate;
    final metaBytes = ByteData(416); // Increased from 408 to 416
    metaBytes.setUint32(0, totalSamples, Endian.little);
    metaBytes.setUint32(4, durationMs, Endian.little);
    for (int i = 0; i < waveformBuckets; i++) {
      final peak16 = (finalAmplitudes[i] * 65535.0).round().clamp(0, 65535);
      metaBytes.setUint16(8 + i * 2, peak16, Endian.little);
    }
    // Add Session ID and Start Uptime at the end of the fixed header
    metaBytes.setUint32(408, _currentSessionId ?? 0, Endian.little);
    metaBytes.setUint32(412, _currentStartUptime ?? 0, Endian.little);

    final metaPath = '$dateFolderPath/${prefix}_$timestamp$suffix.meta';
    final List<int> metaOut = [...metaBytes.buffer.asUint8List()];
    final rawId = _deviceId;
    if (rawId.isNotEmpty) {
      final deviceId = rawId.replaceAll(':', '').toUpperCase();
      if (deviceId.length >= 6) {
        final mac6 = deviceId.substring(0, 6);
        final uploadKey = '${mac6}_recording_$timestamp$suffix.$extension';
        final keyBytes = uploadKey.codeUnits;
        final truncatedKey = keyBytes.length > 255 ? keyBytes.sublist(0, 255) : keyBytes;
        metaOut.add(truncatedKey.length);
        metaOut.addAll(truncatedKey);
      }
    }
    await File(metaPath).writeAsBytes(metaOut);
  }

  Future<String?> _saveOgg(List<Object> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording', String suffix = ''}) async {
    final oggPath = '$dateFolderPath/${prefix}_$timestamp$suffix.ogg';
    final tmpPath = '$oggPath.tmp';
    final oggFile = File(tmpPath);
    final IOSink sink = oggFile.openWrite();

    const waveformBuckets = 200;
    const windowSize = 800;

    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;
    int totalSamples = 0;

    // 1-byte 16kHz SILK mode Opus DTX (silence) frame
    final opusSilenceFrame = Uint8List.fromList([0x48]);

    int granulePos = 0;
    int lastFlushedGranulePos = 0;
    int pageSeqNum = 2;
    String? currentFilePath;
    Uint8List? currentFileBytes;
    final pagePackets = <Uint8List>[];

    bool renamed = false;
    try {
      final serial = Random().nextInt(0x7FFFFFFF);
      sink.add(_createOggPage(0, 0, serial, [_createOggOpusIdHeader()], isFirstPage: true));
      sink.add(_createOggPage(0, 1, serial, [_createOggOpusCommentHeader()]));

      for (var i = 0; i < refs.length; i++) {
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final durationSamples = (ms * sampleRate) ~/ 1000;
          final silenceFrames = (ms / frameDurationMs).round();
          
          for (int f = 0; f < silenceFrames; f++) {
            granulePos += 960; // 20ms at 48kHz
            pagePackets.add(opusSilenceFrame);

            if (pagePackets.length >= 40) {
              lastFlushedGranulePos = granulePos;
              sink.add(_createOggPage(granulePos, pageSeqNum++, serial, pagePackets.toList()));
              pagePackets.clear();
            }
          }
          
          // Still need to update waveform metadata for silence
          for (int s = 0; s < durationSamples; s++) {
            currentWindowSamples++;
            if (currentWindowSamples >= windowSize) {
              dynamicPeaks.add(0.0);
              currentWindowSamples = 0;
            }
          }
          totalSamples += durationSamples;

        } else {
          final ref = item as FrameRef;
          if (i % 50 == 0) await Future.delayed(Duration.zero);

          if (ref.segmentFile.path != currentFilePath) {
            currentFileBytes = await ref.segmentFile.readAsBytes();
            currentFilePath = ref.segmentFile.path;
            await Future.delayed(Duration.zero);
          }

          if (currentFileBytes == null) continue;

          final frameDataOffset = ref.byteOffset + 4;
          final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

          Int16List? pcmData;
          try {
            pcmData = _decoder?.decode(input: opusBytes);
          } catch (e) {
            continue;
          }
          if (pcmData != null) {
            for (int s = 0; s < pcmData.length; s++) {
              final amplitude = pcmData[s].abs() / 32768.0;
              if (amplitude > currentWindowMax) currentWindowMax = amplitude;
              currentWindowSamples++;
              if (currentWindowSamples >= windowSize) {
                dynamicPeaks.add(currentWindowMax);
                currentWindowMax = 0.0;
                currentWindowSamples = 0;
              }
            }
            totalSamples += pcmData.length;
          }

          granulePos += 960; // 20ms frame at 48kHz
          pagePackets.add(opusBytes);
        }

        if (pagePackets.length >= 40) { // 40 frames per page (~800ms)
          lastFlushedGranulePos = granulePos;
          sink.add(_createOggPage(granulePos, pageSeqNum++, serial, pagePackets.toList()));
          pagePackets.clear();
        }
      }

      // Final flush with EOS flag.
      // RFC 3533: "If a page contains no packets, its granule_position is the same as the
      // granule_position of the last page containing at least one packet."
      final finalGranulePos = pagePackets.isNotEmpty ? granulePos : lastFlushedGranulePos;
      sink.add(_createOggPage(finalGranulePos, pageSeqNum++, serial, pagePackets, isLastPage: true));

      await sink.close();
      await File(tmpPath).rename(oggPath);
      renamed = true;

      if (currentWindowSamples > 0) {
        dynamicPeaks.add(currentWindowMax);
      }

      final metaSamples = totalSamples > 0 ? totalSamples : granulePos;
      await _saveMetadata(refs, dateFolderPath, timestamp, metaSamples, dynamicPeaks, waveformBuckets,
          prefix: prefix, extension: 'ogg', suffix: suffix);

      Logger.debug('VadAudioProcessor: Saved OGG recording (${refs.length} items) starting at $timestamp$suffix to $oggPath');
      return oggPath;
    } catch (e) {
      Logger.error('VadAudioProcessor: OGG encoding failed, falling back to WAV: $e');
      try {
        await sink.close();
      } catch (_) {}
      final pathToClean = renamed ? oggPath : tmpPath;
      try {
        final f = File(pathToClean);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }
  }

  Uint8List _createOggOpusIdHeader() {
    final header = ByteData(19);
    header.setUint8(0, 0x4f); // 'O'
    header.setUint8(1, 0x70); // 'p'
    header.setUint8(2, 0x75); // 'u'
    header.setUint8(3, 0x73); // 's'
    header.setUint8(4, 0x48); // 'H'
    header.setUint8(5, 0x65); // 'e'
    header.setUint8(6, 0x61); // 'a'
    header.setUint8(7, 0x64); // 'd'
    header.setUint8(8, 1); // Version
    header.setUint8(9, channels);
    header.setUint16(10, 0, Endian.little); // Pre-skip
    header.setUint32(12, 48000, Endian.little); // Ogg Opus spec prefers 48kHz original rate
    header.setUint16(16, 0, Endian.little); // Output gain
    header.setUint8(18, 0); // Mapping family
    return header.buffer.asUint8List();
  }

  Uint8List _createOggOpusCommentHeader() {
    const vendor = 'Omi';
    final vendorBytes = utf8.encode(vendor);
    final header = ByteData(8 + 4 + vendorBytes.length + 4);
    header.setUint8(0, 0x4f); // 'O'
    header.setUint8(1, 0x70); // 'p'
    header.setUint8(2, 0x75); // 'u'
    header.setUint8(3, 0x73); // 's'
    header.setUint8(4, 0x54); // 'T'
    header.setUint8(5, 0x61); // 'a'
    header.setUint8(6, 0x67); // 'g'
    header.setUint8(7, 0x73); // 's'
    header.setUint32(8, vendorBytes.length, Endian.little);
    final list = header.buffer.asUint8List();
    list.setAll(12, vendorBytes);
    ByteData.view(list.buffer).setUint32(12 + vendorBytes.length, 0, Endian.little); // 0 comments
    return list;
  }

  Uint8List _createOggPage(int granulePos, int seqNum, int serial, List<Uint8List> packets,
      {bool isFirstPage = false, bool isLastPage = false}) {
    int segmentCount = 0;
    for (final p in packets) {
      segmentCount += (p.length / 255).floor() + 1;
    }

    final header = ByteData(27 + segmentCount);
    header.setUint8(0, 0x4f); // 'O'
    header.setUint8(1, 0x67); // 'g'
    header.setUint8(2, 0x67); // 'g'
    header.setUint8(3, 0x53); // 'S'
    header.setUint8(4, 0); // Version
    int headerType = 0;
    if (isFirstPage) headerType |= 0x02;
    if (isLastPage) headerType |= 0x04;
    header.setUint8(5, headerType);
    header.setUint64(6, granulePos, Endian.little);
    header.setUint32(14, serial, Endian.little);
    header.setUint32(18, seqNum, Endian.little);
    header.setUint32(22, 0, Endian.little); // CRC placeholder
    header.setUint8(26, segmentCount);

    int pos = 27;
    for (final p in packets) {
      int remaining = p.length;
      while (remaining >= 255) {
        header.setUint8(pos++, 255);
        remaining -= 255;
      }
      header.setUint8(pos++, remaining);
    }

    final page = BytesBuilder(copy: false);
    page.add(header.buffer.asUint8List());
    for (final p in packets) {
      page.add(p);
    }

    final pageBytes = page.takeBytes();
    final crc = _computeOggCrc(pageBytes);
    ByteData.view(pageBytes.buffer, pageBytes.offsetInBytes, pageBytes.lengthInBytes).setUint32(22, crc, Endian.little);
    return pageBytes;
  }

  static const List<int> _crcTable = [
    0x00000000,
    0x04c11db7,
    0x09823b6e,
    0x0d4326d9,
    0x130476dc,
    0x17c56b6b,
    0x1a864db2,
    0x1e475005,
    0x2608edb8,
    0x22c9f00f,
    0x2f8ad6d6,
    0x2b4bcb61,
    0x350c9b64,
    0x31cd86d3,
    0x3c8ea00a,
    0x384fbdbd,
    0x4c11db70,
    0x48d0c6c7,
    0x4593e01e,
    0x4152fda9,
    0x5f15adac,
    0x5bd4b01b,
    0x569796c2,
    0x52568b75,
    0x6a1936c8,
    0x6ed82b7f,
    0x639b0da6,
    0x675a1011,
    0x791d4014,
    0x7ddc5da3,
    0x709f7b7a,
    0x745e66cd,
    0x9823b6e0,
    0x9ce2ab57,
    0x91a18d8e,
    0x95609039,
    0x8b27c03c,
    0x8fe6dd8b,
    0x82a5fb52,
    0x8664e6e5,
    0xbe2b5b58,
    0xbaea46ef,
    0xb7a96036,
    0xb3687d81,
    0xad2f2d84,
    0xa9ee3033,
    0xa4ad16ea,
    0xa06c0b5d,
    0xd4326d90,
    0xd0f37027,
    0xddb056fe,
    0xd9714b49,
    0xc7361b4c,
    0xc3f706fb,
    0xceb42022,
    0xca753d95,
    0xf23a8028,
    0xf6fb9d9f,
    0xfbb8bb46,
    0xff79a6f1,
    0xe13ef6f4,
    0xe5ffeb43,
    0xe8bccd9a,
    0xec7dd02d,
    0x34867077,
    0x30476dc0,
    0x3d044b19,
    0x39c556ae,
    0x278206ab,
    0x23431b1c,
    0x2e003dc5,
    0x2ac12072,
    0x128e9dcf,
    0x164f8078,
    0x1b0ca6a1,
    0x1fcdbb16,
    0x018aeb13,
    0x054bf6a4,
    0x0808d07d,
    0x0cc9cdca,
    0x7897ab07,
    0x7c56b6b0,
    0x71159069,
    0x75d48dde,
    0x6b93dddb,
    0x6f52c06c,
    0x6211e6b5,
    0x66d0fb02,
    0x5e9f46bf,
    0x5a5e5b08,
    0x571d7dd1,
    0x53dc6066,
    0x4d9b3063,
    0x495a2dd4,
    0x44190b0d,
    0x40d816ba,
    0xaca5c697,
    0xa864db20,
    0xa527fdf9,
    0xa1e6e04e,
    0xbfa1b04b,
    0xbb60adfc,
    0xb6238b25,
    0xb2e29692,
    0x8aad2b2f,
    0x8e6c3698,
    0x832f1041,
    0x87ee0df6,
    0x99a95df3,
    0x9d684044,
    0x902b669d,
    0x94ea7b2a,
    0xe0b41de7,
    0xe4750050,
    0xe9362689,
    0xedf73b3e,
    0xf3b06b3b,
    0xf771768c,
    0xfa325055,
    0xfef34de2,
    0xc6bcf05f,
    0xc27dede8,
    0xcf3ecb31,
    0xcbffd686,
    0xd5b88683,
    0xd1799b34,
    0xdc3abded,
    0xd8fba05a,
    0x690ce0ee,
    0x6dcdfd59,
    0x608edb80,
    0x644fc637,
    0x7a089632,
    0x7ec98b85,
    0x738aad5c,
    0x774bb0eb,
    0x4f040d56,
    0x4bc510e1,
    0x46863638,
    0x42472b8f,
    0x5c007b8a,
    0x58c1663d,
    0x558240e4,
    0x51435d53,
    0x251d3b9e,
    0x21dc2629,
    0x2c9f00f0,
    0x285e1d47,
    0x36194d42,
    0x32d850f5,
    0x3f9b762c,
    0x3b5a6b9b,
    0x0315d626,
    0x07d4cb91,
    0x0a97ed48,
    0x0e56f0ff,
    0x1011a0fa,
    0x14d0bd4d,
    0x19939b94,
    0x1d528623,
    0xf12f560e,
    0xf5ee4bb9,
    0xf8ad6d60,
    0xfc6c70d7,
    0xe22b20d2,
    0xe6ea3d65,
    0xeba91bbc,
    0xef68060b,
    0xd727bbb6,
    0xd3e6a601,
    0xdea580d8,
    0xda649d6f,
    0xc423cd6a,
    0xc0e2d0dd,
    0xcd11f604,
    0xc9d0ebb3,
    0xbd3e8d7e,
    0xb9ff90c9,
    0xb4bcb610,
    0xb07daba7,
    0xae3afba2,
    0xaafbe615,
    0xa7b8c0cc,
    0xa379dd7b,
    0x9b3660c6,
    0x9ff77d71,
    0x92b45ba8,
    0x9675461f,
    0x8832161a,
    0x8cf30bad,
    0x81b02d74,
    0x857130c3,
    0x5d8a9099,
    0x594b8d2e,
    0x5408abf7,
    0x50c9b640,
    0x4e8ee645,
    0x4a4ffbf2,
    0x470cdd2b,
    0x43cd309c,
    0x7b827d21,
    0x7f436096,
    0x7200464f,
    0x76c15bf8,
    0x68860bfd,
    0x6c47164a,
    0x61043093,
    0x65c52d24,
    0x119b4be9,
    0x155a565e,
    0x18197087,
    0x1cd86d30,
    0x029f3d35,
    0x065e2082,
    0x0b1d065b,
    0x0fdc1bec,
    0x3793a651,
    0x3352bbe6,
    0x3e119d3f,
    0x3ad08088,
    0x2497d08d,
    0x2056cd3a,
    0x2d15ebe3,
    0x29d4f654,
    0xc5a92679,
    0xc1683bce,
    0xcc2b1d17,
    0xc8ea00a0,
    0xd6ad50a5,
    0xd26c4d12,
    0xdf2f6bcb,
    0xdbee767c,
    0xe3a1cbc1,
    0xe760d676,
    0xea23f0af,
    0xeee2ed18,
    0xf0a5bd1d,
    0xf464a0aa,
    0xf9278673,
    0xfde69bc4,
    0x89b8fd09,
    0x8d79e0be,
    0x803ac667,
    0x84fbdbd0,
    0x9abc8bd5,
    0x9e7d9662,
    0x933eb0bb,
    0x97ffad0c,
    0xafb010b1,
    0xab710d06,
    0xa6322bdf,
    0xa2f33668,
    0xbcb4666d,
    0xb8757bda,
    0xb5365d03,
    0xb1f740b4
  ];

  int _computeOggCrc(Uint8List data) {
    int crc = 0;
    for (int i = 0; i < data.length; i++) {
      crc = ((crc << 8) ^ _crcTable[((crc >> 24) ^ data[i]) & 0xff]) & 0xffffffff;
    }
    return crc;
  }

  Future<String> _saveWav(List<Object> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording', String suffix = ''}) async {
    final wavPath = '$dateFolderPath/${prefix}_$timestamp$suffix.wav';
    final wavFile = File(wavPath);
    final IOSink sink = wavFile.openWrite();

    String? currentFilePath;
    Uint8List? currentFileBytes;

    final List<Uint8List> decodedSegments = [];
    final wavDecoder =
        Platform.isIOS || Platform.isAndroid ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels) : null;
    if (wavDecoder != null) {
      try {
        for (var i = 0; i < refs.length; i++) {
          final item = refs[i];

          if (item is Duration) {
            final pcmSamples = (item.inMilliseconds * sampleRate) ~/ 1000;
            final silenceBytes = Uint8List(pcmSamples * channels * 2); // 16-bit PCM
            decodedSegments.add(silenceBytes);
            continue;
          }

          final ref = item as FrameRef;
          if (i % 50 == 0) await Future.delayed(Duration.zero);

          if (ref.segmentFile.path != currentFilePath) {
            currentFileBytes = await ref.segmentFile.readAsBytes();
            currentFilePath = ref.segmentFile.path;
          }

          if (currentFileBytes == null) continue;

          final frameDataOffset = ref.byteOffset + 4;
          final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

          try {
            final decoded = wavDecoder.decode(input: opusBytes);
            decodedSegments.add(decoded.buffer.asUint8List());
          } catch (e) {
            // Skip corrupt frame
          }
        }
      } finally {
        wavDecoder.destroy();
      }
    }

    final int totalPcmBytes = decodedSegments.fold(0, (sum, segment) => sum + segment.length);

    final header = ByteData(44);
    // RIFF
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, 36 + totalPcmBytes, Endian.little);
    // WAVE
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    // fmt
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little); // chunk size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little); // byte rate
    header.setUint16(32, channels * 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    // data
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, totalPcmBytes, Endian.little);

    sink.add(header.buffer.asUint8List());
    for (final segment in decodedSegments) {
      sink.add(segment);
    }
    await sink.close();

    // Compute waveform peaks from the decoded PCM we already have in memory.
    const waveformBuckets = 200;
    const windowSize = 800;
    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;
    for (final segment in decodedSegments) {
      final pcm = Int16List.sublistView(segment);
      for (int j = 0; j < pcm.length; j++) {
        final amplitude = pcm[j].abs() / 32768.0;
        if (amplitude > currentWindowMax) currentWindowMax = amplitude;
        currentWindowSamples++;
        if (currentWindowSamples >= windowSize) {
          dynamicPeaks.add(currentWindowMax);
          currentWindowMax = 0.0;
          currentWindowSamples = 0;
        }
      }
    }
    if (currentWindowSamples > 0) dynamicPeaks.add(currentWindowMax);

    await _saveMetadata(refs, dateFolderPath, timestamp, totalPcmBytes ~/ (channels * 2), dynamicPeaks, waveformBuckets,
        prefix: prefix, extension: 'wav', suffix: suffix);

    Logger.debug('VadAudioProcessor: Saved WAV recording to $wavPath');
    return wavPath;
  }
}
