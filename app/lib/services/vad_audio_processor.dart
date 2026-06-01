import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:omi/utils/logger.dart';

/// Thrown from inside [VadAudioProcessor]'s decode loop when the caller-supplied
/// `isCancelled` callback flips to true. The isolate entry catches this as a
/// clean abort (no error message, no draft flush) so the watchdog never has to
/// force-kill the isolate — an `Isolate.kill(immediate)` while parked in an
/// ONNX/Opus FFI call corrupts native state and takes the whole app down.
class VadProcessingCancelled implements Exception {
  const VadProcessingCancelled();
  @override
  String toString() => 'VadProcessingCancelled';
}

/// All VAD/processing settings captured from SharedPreferences in the main isolate
/// before spawning the processing isolate. All fields are primitives — safe to send
/// across isolate boundaries.
class ProcessingSettings {
  final bool vadEnabled;
  final double speechThreshold;
  final int silenceDurationToSplitMs;
  final int minDurationMs;
  final int minSpeechMs;
  final bool discardShort;
  final int maxChunkMs;
  final String deviceId; // used to generate upload key in .meta sidecar
  final String audioSaveFormat;
  final bool omiEnabled;

  const ProcessingSettings({
    required this.vadEnabled,
    required this.speechThreshold,
    required this.silenceDurationToSplitMs,
    required this.minDurationMs,
    required this.minSpeechMs,
    required this.discardShort,
    required this.maxChunkMs,
    required this.deviceId,
    required this.audioSaveFormat,
    required this.omiEnabled,
  });

  factory ProcessingSettings.fromPrefs() {
    final p = SharedPreferencesUtil();
    return ProcessingSettings(
      vadEnabled: p.vadEnabled,
      speechThreshold: p.vadSpeechThreshold,
      silenceDurationToSplitMs: p.vadSplitSeconds * 1000,
      minDurationMs: p.filterMinDurationSeconds * 1000,
      minSpeechMs: p.vadMinSpeechSeconds * 1000,
      discardShort: p.discardShortRecordings,
      maxChunkMs: p.vadMaxConversationMinutes == 0 ? 0x7FFFFFFFFFFFFFFF : p.vadMaxConversationMinutes * 60 * 1000,
      deviceId: p.btDevice.id,
      audioSaveFormat: p.audioSaveFormat,
      omiEnabled: p.omiEnabled,
    );
  }
}

class VadAudioProcessor {
  // Silero VAD session + persistent native state (reset on gap detection)
  OrtSession? _session;
  // Silero v5+ recurrent state kept as a live OrtValue so the LSTM weights
  // never make a round-trip through Dart between inference cycles. Null means
  // "use zero-initialised state" — set by _resetState and consumed lazily.
  OrtValue? _cachedStateValue;
  // SR tensor is constant for the processor's lifetime — created once, reused.
  OrtValue? _cachedSrValue;
  // Pre-allocated [context(64) | window(512)] input buffer — filled in-place
  // on every _runVad call, never reallocated.
  final Float32List _windowedInputBuffer = Float32List(_vadContextSamples + _vadWindowSamples);
  // Silero v5+ requires the last 64 samples of the prior window prepended
  // to each 512-sample input so the model has temporal continuity. Reset
  // alongside _cachedStateValue on any state-reset path.
  final Float32List _vadContext = Float32List(_vadContextSamples);
  // Ring-style sample buffer — index-based, never reallocated.
  final Float32List _pcmBuffer = Float32List(1024);
  int _pcmBufferLen = 0;

  // Opus decoder
  final SimpleOpusDecoder? _decoder;
  final String? _outputDir;

  // Optional liveness callback, invoked from the decode and save loops so an
  // external stall watchdog can distinguish a slow-but-progressing run (long
  // segment / large stitched save) from a genuine wedge. No-op when null.
  final void Function()? _onLiveness;

  // Optional cancel-check callback. Polled from inside the per-frame decode
  // loop in [processSegmentFile]; when it returns true the loop throws
  // [VadProcessingCancelled] so the caller can bail out within milliseconds
  // instead of waiting for the (potentially >12 s) current segment to finish.
  final bool Function()? _isCancelled;

  // Per-conversation accumulation — FrameRef disk-pointers only, no Opus in RAM.
  // Can also contain Duration objects representing silence gaps to be padded.
  List<Object> _currentRefs = [];
  int _speechFrameCount = 0; // speech frames in current conversation
  DateTime? _recordingStartTime;
  DateTime? _lastSegmentEndTime;
  bool _isDerivedTimestamp = false; // true when segment had no valid device RTC timestamp
  int? _currentSessionId;
  int? _currentStartUptime;
  int? _currentFrameUptimeMs;
  int? _lastImuTicks;

  // VAD state counters
  int _currentChunkDurationMs = 0; // total frames accumulated (for max-cap)

  // App-side silence-split tracking. _silenceRunMs is the length of the current
  // unbroken run of non-speech frames (reset to 0 on any speech frame). The
  // high-water marks record _currentRefs.length / _currentChunkDurationMs as of
  // the last speech frame, so a split can trim the trailing silence off the
  // saved recording. Reset on every conversation boundary (see _resetState and
  // the inline resets in the gap-split / max-cap paths).
  int _silenceRunMs = 0;
  int _lastSpeechRefCount = 0;
  int _lastSpeechChunkMs = 0;

  // Max Silero voice_prob observed during the current conversation. Surfaced in
  // discard records so the recovery UI can explain why VAD rejected the audio.
  // AAD mode (no Silero session) leaves this at 0.
  double _currentMaxVoiceProb = 0.0;

  // Discard records produced since the last consumePendingDiscards call.
  // Each entry: {startMs, endMs, reason, maxVoiceProb, relativeBins: [<sessionId>/<file>.bin, ...]}.
  // Drained by the isolate entry and forwarded to the main isolate for persistence.
  final List<Map<String, dynamic>> _pendingDiscards = [];

  /// True after a [flushRemaining] call where the short-recording discard guard
  /// fired (refs were non-empty but below the duration threshold). False if the
  /// guard did not fire (either no refs, or proceeded to save). Test-only.
  @visibleForTesting
  bool discardGuardFiredOnLastFlush = false;

  @visibleForTesting
  int get currentChunkDurationMs => _currentChunkDurationMs;

  @visibleForTesting
  int? get currentSessionId => _currentSessionId;
  // Marker-forced recording state
  bool _forcedByMarker = false;
  // Wall-clock timestamp (ms) after which normal gap-splitting resumes.
  // Set to markerTime + 50 s when a marker packet is processed.
  int? _markerProtectedUntilMs;
  // After a 0xFFFFFFFC session-end marker, drop audio frames until the next
  // 0xFFFFFFFD VAD-resume or 0xFFFFFFFE button-tap. Catches the 1-2 frame
  // race between button.c writing the marker and aad_set_threshold ending
  // the recording — without this, those stray frames would start a junk
  // sub-50 ms recording.
  bool _sessionEndPendingResume = false;

  // Markers accumulated since the last _saveRecording call, keyed by their
  // wall-clock timestamp and the recording offset at the time of the tap.
  final List<({int markerMs, int offsetAtMarkerMs})> _pendingMarkers = [];
  // EDL payload ready to be consumed by the isolate caller after each save.
  final List<Map<String, dynamic>> _pendingEdlData = [];

  // Tracks segment files that have been fully processed. Used by consumeSafeToDeletePaths()
  // to determine which files are no longer referenced by any internal buffer.
  final Set<String> _processedFiles = {};

  // Settings — cached at construction time for the lifetime of one processAll pass
  final double _speechThreshold;
  final int _silenceDurationToSplitMs;
  final int _minDurationMs;
  final int _minSpeechMs;
  final bool _discardShort;
  final int _maxChunkMs;
  final String _deviceId;
  final String _audioSaveFormat;
  final bool _omiEnabled;

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int frameDurationMs = 20; // 20 ms per Opus frame
  static const int _vadWindowSamples = 512; // Silero VAD input size
  static const int _vadContextSamples = 64; // Silero v5+ context-buffer size at 16 kHz
  // Mirrors CONFIG_OMI_VAD_HOLD_MS in firmware/omi/src/aad.c.
  // The firmware continues emitting audio for this many ms after the last voice frame,
  // so the gap the app observes is that much shorter than the user-perceived silence.
  static const int _firmwareVadHoldMs = 10000;

  /// Creates a processor in the main isolate, reading settings from SharedPreferences.
  static Future<VadAudioProcessor> create({String? outputDir, SimpleOpusDecoder? decoder}) async {
    final settings = ProcessingSettings.fromPrefs();
    OrtSession? session;
    if (settings.vadEnabled) {
      try {
        session = await OnnxRuntime().createSessionFromAsset('assets/models/silero_vad.onnx');
        Logger.debug('VadAudioProcessor: Silero session — inputs=${session.inputNames} outputs=${session.outputNames}');
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
    void Function()? onLiveness,
    bool Function()? isCancelled,
  }) : this._(
            outputDir: outputDir,
            decoder: decoder,
            session: session,
            settings: settings,
            onLiveness: onLiveness,
            isCancelled: isCancelled);

  VadAudioProcessor._(
      {String? outputDir,
      SimpleOpusDecoder? decoder,
      OrtSession? session,
      required ProcessingSettings settings,
      void Function()? onLiveness,
      bool Function()? isCancelled})
      : _session = session,
        _onLiveness = onLiveness,
        _isCancelled = isCancelled,
        _decoder = decoder ??
            (Platform.isIOS || Platform.isAndroid
                ? SimpleOpusDecoder(sampleRate: sampleRate, channels: channels)
                : null),
        _outputDir = outputDir,
        _speechThreshold = settings.speechThreshold,
        _silenceDurationToSplitMs = settings.silenceDurationToSplitMs,
        _minDurationMs = settings.minDurationMs,
        _minSpeechMs = settings.minSpeechMs,
        _discardShort = settings.discardShort,
        _maxChunkMs = settings.maxChunkMs,
        _deviceId = settings.deviceId,
        _audioSaveFormat = settings.audioSaveFormat,
        _omiEnabled = settings.omiEnabled;

  void destroy() {
    _decoder?.destroy();
    final s = _session;
    _session = null;
    // ignore: unawaited_futures, discarded_futures
    s?.close();
    // ignore: unawaited_futures, discarded_futures
    _cachedStateValue?.dispose();
    _cachedStateValue = null;
    // ignore: unawaited_futures, discarded_futures
    _cachedSrValue?.dispose();
    _cachedSrValue = null;
  }

  bool get isCapturing => (_currentRefs.isNotEmpty && _speechFrameCount > 0) || _forcedByMarker;

  Future<bool> _runVad(Float32List samples512) async {
    final session = _session;
    if (session == null) {
      // Hardware AAD mode — all audio treated as speech; splitting driven by firmware timestamps only.
      return true;
    }

    // Fill pre-allocated [context(64) | window(512)] buffer — no heap allocation.
    _windowedInputBuffer.setRange(0, _vadContextSamples, _vadContext);
    _windowedInputBuffer.setRange(_vadContextSamples, _vadContextSamples + _vadWindowSamples, samples512);

    // SR tensor is constant — create once and keep alive for the processor's lifetime.
    _cachedSrValue ??= await OrtValue.fromList(Int64List.fromList([sampleRate]), []);

    // State tensor starts as zeros; after each inference the output stateN is
    // adopted directly — no Dart round-trip for the 256 LSTM floats.
    _cachedStateValue ??= await OrtValue.fromList(Float32List(2 * 1 * 128), [2, 1, 128]);

    // Only the input tensor is transient — allocate once per call.
    final inputTensor = await OrtValue.fromList(_windowedInputBuffer, [1, _vadContextSamples + _vadWindowSamples]);

    final inputs = <String, OrtValue>{
      'input': inputTensor,
      'state': _cachedStateValue!,
      'sr': _cachedSrValue!,
    };

    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run(inputs);
      // Silero v5+ ONNX outputs: 'output' (prob), 'stateN' (recurrent state).
      final prob = ((await outputs['output']!.asFlattenedList()).cast<double>())[0];
      // Swap state OrtValues: adopt the output, dispose the old input.
      // Keeps the LSTM state native-side; removes the 256-float Dart copy.
      final prevState = _cachedStateValue;
      _cachedStateValue = outputs['stateN'];
      outputs.remove('stateN'); // exclude from bulk disposal below
      // ignore: unawaited_futures, discarded_futures
      prevState?.dispose();
      // Update context buffer in-place — trailing 64 samples of this window.
      _vadContext.setRange(0, _vadContextSamples, samples512, _vadWindowSamples - _vadContextSamples);
      if (prob > _currentMaxVoiceProb) _currentMaxVoiceProb = prob;
      return prob > _speechThreshold;
    } catch (e) {
      Logger.error('VadAudioProcessor: Silero inference failed ($e) — disabling model, AAD mode active');
      _session = null;
      // ignore: unawaited_futures, discarded_futures
      session.close();
      return true;
    } finally {
      // ignore: unawaited_futures, discarded_futures
      inputTensor.dispose();
      if (outputs != null) {
        for (final o in outputs.values) {
          // ignore: unawaited_futures, discarded_futures
          o.dispose();
        }
      }
    }
  }

  Future<List<String>> processSegmentFile(File segmentFile, DateTime segmentStartTime,
      {int startUptimeMs = 0, bool isDerivedTimestamp = false, int? sessionId}) async {
    final savedFiles = <String>[];

    // Only set _isDerivedTimestamp from the caller if it hasn't already been anchored
    // by a marker recalibration in this conversation.
    if (_recordingStartTime == null || _isDerivedTimestamp) {
      _isDerivedTimestamp = isDerivedTimestamp;
    }

    // VAD-resume anchor: set when a 0xFFFFFFFD packet is encountered.
    // Recalibrates frame timestamps after a firmware-side silence gap.
    DateTime? vadResumeTime;
    int? vadResumeFrameIndex;

    // Wall-clock time of the last processed audio frame (updated each frame).
    DateTime lastFrameWallTime = segmentStartTime;
    int? currentImuTicks;

    try {
      if (!await segmentFile.exists()) return [];
      final bytes = await segmentFile.readAsBytes();
      final fileLength = bytes.length;
      if (fileLength == 0) return [];
      final byteData = ByteData.sublistView(bytes);

      int offset = 0;
      int frameIndex = 0;
      int totalFrameCount = 0;
      int segmentSpeechFrames = 0;
      double segmentMaxAmp = 0.0;

      // FIRST PASS: Peek for metadata header at offset 0.
      // Firmware: RecordingHeader_v1_t in transport.h confirms utc_start_ms is uint64 milliseconds.
      if (fileLength >= 36 && byteData.getUint32(0, Endian.little) == 0xFFFFFFFB) {
        final utcStartMs = byteData.getUint64(8, Endian.little);
        final uptimeStartMs = byteData.getUint64(16, Endian.little);
        currentImuTicks = byteData.getUint32(24, Endian.little);
        final sessionIdInHeader = byteData.getUint32(28, Endian.little);

        if (utcStartMs > 946684800000) {
          segmentStartTime = DateTime.fromMillisecondsSinceEpoch(utcStartMs, isUtc: true);
          startUptimeMs = uptimeStartMs.toInt();
          sessionId = sessionIdInHeader;
          lastFrameWallTime = segmentStartTime;
          _isDerivedTimestamp = false;
        }
      }

      if (_lastSegmentEndTime != null) {
        final gapMs = segmentStartTime.difference(_lastSegmentEndTime!).inMilliseconds;
        final sessionChanged = _currentSessionId != null && sessionId != null && _currentSessionId != sessionId;

        // Better isClockJump detection using uptime if available.
        // If uptime gap matches audio duration (small gap) but UTC gap is large, it's a clock sync.
        int uptimeGapMs = 0;
        bool hasUptime = _currentFrameUptimeMs != null && startUptimeMs > 0;
        if (hasUptime) {
          uptimeGapMs = (startUptimeMs - _currentFrameUptimeMs!).abs();
        }

        // IMU Bridge: Check if the gap can be explained by IMU ticks even if session changed.
        bool imuGapMatches = false;
        if (sessionChanged && _lastImuTicks != null && currentImuTicks != null) {
          final int tickDelta = (currentImuTicks - _lastImuTicks!) & 0x00FFFFFF;
          final int imuGapMs = (tickDelta * 6.4).toInt();
          final gapDiff = (gapMs - imuGapMs).abs();
          if (gapDiff < 5000) {
            imuGapMatches = true;
            Logger.debug('VadAudioProcessor: IMU Bridge matched gap of ${imuGapMs}ms across reboot.');
          }
        }

        final bool isClockJump =
            !sessionChanged && (hasUptime ? (uptimeGapMs < 5000 && gapMs.abs() > 10000) : (gapMs.abs() > 10000));

        // Suppress splits while we're within 50 s of a marker tap.
        final bool withinMarkerWindow =
            _markerProtectedUntilMs != null && segmentStartTime.millisecondsSinceEpoch <= _markerProtectedUntilMs!;
        final bool splitTriggered = !withinMarkerWindow &&
            ((sessionChanged && !imuGapMatches) ||
                (gapMs > max(0, _silenceDurationToSplitMs - _firmwareVadHoldMs) && !isClockJump));

        if (_currentRefs.isNotEmpty && splitTriggered) {
          Logger.debug(
            'VadAudioProcessor: Split triggered before ${segmentFile.path.split('/').last} — '
            'sessionChanged=$sessionChanged, gapMs=$gapMs (threshold=${_silenceDurationToSplitMs - _firmwareVadHoldMs}ms effective), '
            'lastEnd=${_lastSegmentEndTime?.toUtc()} segmentStart=${segmentStartTime.toUtc()} — flushing.',
          );
          await _flushPartialWindow();
          _cachedStateValue?.dispose();
          _cachedStateValue = null;
          _vadContext.fillRange(0, _vadContextSamples, 0.0);
          _pcmBufferLen = 0;
          final filePath = await flushRemaining();
          if (filePath != null) savedFiles.add(filePath);
        } else if (_currentRefs.isNotEmpty && (_currentChunkDurationMs + gapMs) >= _maxChunkMs) {
          // INTER-FILE CUT: If this gap would push us over the 1hr/2hr limit, cut now.
          Logger.debug('VadAudioProcessor: Max duration reached during inter-file gap — forcing cut.');
          final filePath = await flushRemaining();
          if (filePath != null) savedFiles.add(filePath);
        } else {
          // STITCHING: Pad inter-file gaps with silence if it's not a clock jump
          // and either the gap is significant (>= 10s) OR it's an IMU bridge match.
          if (_currentRefs.isNotEmpty && !isClockJump && (gapMs >= 10000 || imuGapMatches)) {
            _currentRefs.add(Duration(milliseconds: gapMs));
            _currentChunkDurationMs += gapMs;
            Logger.debug('VadAudioProcessor: Padding inter-file gap of ${gapMs}ms');
          }
        }
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
          _currentStartUptime = startUptimeMs ~/ 1000;
          _currentFrameUptimeMs = startUptimeMs;
        }
      }

      while (offset < fileLength) {
        _onLiveness?.call();
        if (_isCancelled?.call() == true) {
          throw const VadProcessingCancelled();
        }
        if (offset + 4 > fileLength) break;

        final frameLength = byteData.getUint32(offset, Endian.little);

        // Skip null/sentinel words.
        if (frameLength == 0 || frameLength == 0xFFFFFFFF) {
          offset += 4;
          continue;
        }

        // Metadata header (0xFFFFFFFB, 36 bytes: 4-byte header + 4-byte len + 28-byte payload).
        // Handled in the peek pass above, just skip it here.
        if (frameLength == 0xFFFFFFFB) {
          offset += 36;
          continue;
        }

        // Marker packet (0xFFFFFFFE = button-tap marker, 20 bytes: 4-byte header + 16-byte payload).
        // Payload layout: [0..7] UTC epoch ms (u64 LE), [8..11] uptime ms, [12..15] session id.
        if (frameLength == 0xFFFFFFFE) {
          if (offset + 20 <= fileLength) {
            final markerUtcMs = byteData.getUint64(offset + 4, Endian.little);
            final markerUptimeMs = byteData.getUint32(offset + 12, Endian.little);

            // Pick the most trustworthy wall-clock for this marker:
            //   - Prefer derived audio wall time if the audio header was high-precision
            //     (non-derived) AND the marker's RTC roughly agrees (within 60 s).
            //   - Otherwise trust the marker's RTC (audio timestamp may be a stale
            //     mtime fallback or the device may have been asleep).
            DateTime markerFrameTime = lastFrameWallTime;
            if (markerUtcMs > 946684800000) {
              final markerRtc = DateTime.fromMillisecondsSinceEpoch(markerUtcMs, isUtc: true);
              if (_isDerivedTimestamp) {
                // Audio wall time is unreliable — always trust the marker RTC.
                markerFrameTime = markerRtc;
                Logger.debug('VadAudioProcessor: Using marker UTC (audio derived): $markerFrameTime');
              } else {
                final driftMs = markerRtc.difference(lastFrameWallTime).inMilliseconds.abs();
                if (driftMs > 60000) {
                  // Large drift between hardware RTC and audio timeline — prefer audio
                  // timeline since markerOffsetMs is computed against it. The marker
                  // UTC is logged but discarded as the wall-clock anchor.
                  Logger.debug(
                      'VadAudioProcessor: Marker RTC $markerRtc drifts ${driftMs}ms from audio timeline — using audio wall time $lastFrameWallTime');
                } else {
                  markerFrameTime = markerRtc;
                  Logger.debug('VadAudioProcessor: Using marker UTC: $markerFrameTime (drift ${driftMs}ms)');
                }
              }
            }

            final markerMs = markerFrameTime.millisecondsSinceEpoch;
            _forcedByMarker = true;
            if (markerMs > 946684800000) {
              _markerProtectedUntilMs = markerMs + 50000;
            }
            // Capture offset *after* deciding whether this marker starts a new
            // recording. Fresh start → offset 0 (matches _recordingStartTime).
            // Mid-recording → current chunk duration.
            final int offsetForMarker = _currentRefs.isEmpty ? 0 : _currentChunkDurationMs;
            if (markerMs > 946684800000) {
              _pendingMarkers.add((markerMs: markerMs, offsetAtMarkerMs: offsetForMarker));
              Logger.debug('VadAudioProcessor: Queued marker at $markerFrameTime (offset ${offsetForMarker}ms)');
            }
            if (_currentRefs.isEmpty) {
              lastFrameWallTime = markerFrameTime;
              _recordingStartTime = markerFrameTime;
              _speechFrameCount = 0;
              _currentChunkDurationMs = 0;
              _currentFrameUptimeMs = markerUptimeMs;
              _isDerivedTimestamp = false;
              Logger.debug('VadAudioProcessor: Marker at $markerFrameTime — starting new recording.');
            } else {
              // When the marker has a reliable UTC and our current timestamps are derived
              // (e.g. the VAD-resume packet wrote a corrupt UTC), recalibrate using the
              // marker as an anchor: start = markerTime - elapsed.
              if (_isDerivedTimestamp && markerMs > 946684800000) {
                final correctedStart = DateTime.fromMillisecondsSinceEpoch(
                  markerMs - _currentChunkDurationMs,
                  isUtc: true,
                );
                _recordingStartTime = correctedStart;
                lastFrameWallTime = markerFrameTime;
                _currentFrameUptimeMs = markerUptimeMs;
                _isDerivedTimestamp = false;
                Logger.debug(
                    'VadAudioProcessor: Marker at ${markerFrameTime.toLocal()} — recalibrated start to ${correctedStart.toLocal()} (offset ${_currentChunkDurationMs}ms).');
              } else {
                Logger.debug(
                    'VadAudioProcessor: Marker at ${markerFrameTime.toLocal()} — protecting active recording.');
              }
            }
          }
          offset += 20;
          // Button-tap means we're back in an active recording context; if the
          // session-end skip was somehow still latched (mode switch, stale
          // state), clear it so this tap's recording isn't dropped.
          _sessionEndPendingResume = false;
          continue;
        }

        // Session-end marker (0xFFFFFFFC, 20 bytes: 4-byte header + 16-byte payload).
        // Written by firmware on manual-mode stop double-tap. Finalize the current
        // recording at this exact boundary instead of holding it as a draft.
        // Payload layout matches the button-tap marker but is treated as a control
        // signal — no EDL bookmark is emitted.
        if (frameLength == 0xFFFFFFFC) {
          if (offset + 20 <= fileLength) {
            Logger.debug(
                'VadAudioProcessor: Session-end marker at $lastFrameWallTime — finalizing recording (refs=${_currentRefs.length}).');
            if (_currentRefs.isNotEmpty) {
              _forcedByMarker = true;
              final filePath = await flushRemaining(isDraft: false);
              if (filePath != null) savedFiles.add(filePath);
            } else {
              // No audio buffered for this session — still surface any pending
              // taps as orphans so they aren't lost.
              _emitOrphanMarkers();
            }
            _sessionEndPendingResume = true;
            _pcmBufferLen = 0;
            _cachedStateValue?.dispose();
            _cachedStateValue = null;
            _vadContext.fillRange(0, _vadContextSamples, 0.0);
          }
          offset += 20;
          continue;
        }

        // VAD-resume timestamp packet (0xFFFFFFFD): firmware writes this when AAD wakes
        // from silence. Used to decide stitch vs split and recalibrate frame timestamps.
        // Payload: [0..3] UTC epoch seconds (u32 LE), [4..7] uptime ms (u32 LE), [8..15] padding.
        if (frameLength == 0xFFFFFFFD) {
          // Resume signal — the user restarted recording, so any pending
          // session-end skip is cleared and subsequent frames are honored.
          _sessionEndPendingResume = false;
          if (offset + 12 <= fileLength) {
            final vadUtcSeconds = byteData.getUint32(offset + 4, Endian.little);
            final vadUptimeMs = byteData.getUint32(offset + 8, Endian.little);
            const kMinValidEpoch = 946684800;

            DateTime newResumeTime;
            if (vadUtcSeconds > kMinValidEpoch) {
              newResumeTime = DateTime.fromMillisecondsSinceEpoch(vadUtcSeconds * 1000, isUtc: true);
            } else {
              // Fallback: derive from uptime delta since last frame to maintain timeline continuity
              final int uptimeDeltaMs =
                  (_currentFrameUptimeMs != null) ? (vadUptimeMs - _currentFrameUptimeMs!) & 0xFFFFFFFF : 0;
              newResumeTime = lastFrameWallTime.add(Duration(milliseconds: uptimeDeltaMs));
            }

            final lastFrameEndTime = lastFrameWallTime.add(const Duration(milliseconds: frameDurationMs));
            int gapMs = newResumeTime.difference(lastFrameEndTime).inMilliseconds;
            if (gapMs < 0) gapMs = 0; // Prevent negative gaps from RTC sync jitter

            // Calculate uptime gap to distinguish clock jumps from silence.
            // Use modular arithmetic (masking to u32 range) to handle the ~49-day
            // firmware uptime wraparound correctly.
            int uptimeGapMs = 0;
            if (_currentFrameUptimeMs != null) {
              uptimeGapMs = (vadUptimeMs - (_currentFrameUptimeMs! + frameDurationMs)) & 0xFFFFFFFF;
              if (uptimeGapMs > 0x7FFFFFFF) uptimeGapMs -= 0x100000000; // sign-extend
            }
            // If uptime Gap matches frame count (small gap) but UTC gap is large, it's a clock sync.
            final bool isClockJump = uptimeGapMs.abs() < 5000 && gapMs.abs() > 10000;

            if (gapMs >= max(0, _silenceDurationToSplitMs - _firmwareVadHoldMs) && !isClockJump) {
              // Gap exceeds threshold — flush current recording, start new conversation.
              await _flushPartialWindow();
              final speechMs = _speechFrameCount * frameDurationMs;
              final bool tooShortSpeech = _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

              if (_currentRefs.isNotEmpty) {
                if (tooShortSpeech) {
                  final rec = _buildDiscardRecord('noise_pre_split');
                  if (rec != null) _pendingDiscards.add(rec);
                  // Surface any queued tap as an orphan instead of leaking it
                  // into the next conversation with a stale offset.
                  _emitOrphanMarkers();
                  Logger.debug('VadAudioProcessor: Discarding noise conversation before split.');
                } else {
                  final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
                  // Encoder failure leaves _pendingMarkers populated; surface as
                  // orphans rather than letting them leak into the next conv.
                  if (filePath == null) _emitOrphanMarkers();
                  if (filePath != null) savedFiles.add(filePath);
                }
              } else {
                // Marker queued, no audio buffered yet → still emit orphan so
                // the tap is preserved when this branch's in-place reset wipes
                // _currentChunkDurationMs.
                _emitOrphanMarkers();
              }

              final bool newConversationProtected =
                  _markerProtectedUntilMs != null && newResumeTime.millisecondsSinceEpoch <= _markerProtectedUntilMs!;
              _forcedByMarker = newConversationProtected;
              _currentRefs = [];
              _speechFrameCount = 0;
              _currentChunkDurationMs = 0;
              _silenceRunMs = 0;
              _lastSpeechRefCount = 0;
              _lastSpeechChunkMs = 0;
              _recordingStartTime = newResumeTime;
              _pcmBufferLen = 0;
              // ignore: unawaited_futures, discarded_futures
              _cachedStateValue?.dispose();
              _cachedStateValue = null;
              _vadContext.fillRange(0, _vadContextSamples, 0.0);
              Logger.debug('VadAudioProcessor: VAD resume — gap ${gapMs}ms >= threshold, new conversation.');
            } else {
              // Gap within threshold or clock jump — stitch, padding with silence so playback reflects real timing.
              if (_currentRefs.isNotEmpty && gapMs > 0 && !isClockJump) {
                _currentRefs.add(Duration(milliseconds: gapMs));
                _currentChunkDurationMs += gapMs;
              }
              Logger.debug(
                  'VadAudioProcessor: VAD resume — gap ${gapMs}ms ${isClockJump ? "(CLOCK JUMP)" : "< threshold"}, stitching.');
            }

            // Update anchors for subsequent frame calculations.
            vadResumeTime = newResumeTime;
            vadResumeFrameIndex = frameIndex;
            _currentFrameUptimeMs = vadUptimeMs;
          }
          offset += 20;
          continue;
        }

        if (offset + 4 + frameLength > fileLength) {
          Logger.debug('VadAudioProcessor: Incomplete frame at offset $offset in ${segmentFile.path}');
          break;
        }

        // Session-end skip: drop audio frames until a resume signal arrives.
        // Stray frames from the marker-write→threshold-flip race land here and
        // would otherwise start a junk recording.
        if (_sessionEndPendingResume) {
          offset += 4 + ((frameLength + 3) & ~3);
          continue;
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
            _pcmBuffer[_pcmBufferLen++] = sample;
            if (sample.abs() > segmentMaxAmp) segmentMaxAmp = sample.abs();
          }
          while (_pcmBufferLen >= _vadWindowSamples) {
            // Pass a zero-copy view into the buffer — _runVad copies into its
            // pre-allocated input buffer before any await, so the shift below
            // is safe even though this view aliases _pcmBuffer.
            if (await _runVad(Float32List.sublistView(_pcmBuffer, 0, _vadWindowSamples))) isSpeech = true;
            _pcmBuffer.setRange(0, _pcmBufferLen - _vadWindowSamples, _pcmBuffer, _vadWindowSamples);
            _pcmBufferLen -= _vadWindowSamples;
          }
        }

        // Align with firmware: force speech status if within marker protection window
        if (_markerProtectedUntilMs != null && lastFrameWallTime.millisecondsSinceEpoch <= _markerProtectedUntilMs!) {
          isSpeech = true;
        }

        final frameRef = FrameRef(segmentFile: segmentFile, byteOffset: offset, frameLength: frameLength);
        if (isSpeech) {
          _speechFrameCount++;
          segmentSpeechFrames++;
          _silenceRunMs = 0;
        } else {
          _silenceRunMs += frameDurationMs;
        }
        _currentRefs.add(frameRef);
        _currentChunkDurationMs += frameDurationMs;
        if (isSpeech) {
          // High-water mark of the conversation's last speech, used to trim the
          // trailing silence off the saved recording on an in-stream split.
          _lastSpeechRefCount = _currentRefs.length;
          _lastSpeechChunkMs = _currentChunkDurationMs;
        }
        if (_currentFrameUptimeMs != null) _currentFrameUptimeMs = _currentFrameUptimeMs! + frameDurationMs;

        // Compute accurate wall-clock time for this frame using VAD-resume anchor if available.
        final frameTime = (vadResumeTime != null && vadResumeFrameIndex != null)
            ? vadResumeTime.add(Duration(milliseconds: (frameIndex - vadResumeFrameIndex) * frameDurationMs))
            : segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
        lastFrameWallTime = frameTime;

        // Anchor a fresh conversation to THIS frame's wall-clock time. After an
        // in-stream silence split, _splitOnSilence resets _recordingStartTime to
        // null mid-file; anchoring to segmentStartTime / vadResumeTime here would
        // back-date the new conversation to the start of the file (or the resume
        // point), stacking it on top of the chunk just split off and producing
        // overlapping records with identical timestamps. frameTime is the correct
        // per-frame wall clock and advances monotonically across splits.
        if (_recordingStartTime == null) {
          _recordingStartTime = frameTime;
        }

        // App-side silence split. The firmware only emits a 0xFFFFFFFD gap once
        // its own AAD has gone quiet long enough; in a continuous-audio
        // environment that gap may never reach the split threshold, so the
        // whole stream stitches into one unbounded conversation that never
        // finalizes. Independently cut here once the Silero VAD has seen
        // _silenceDurationToSplitMs of continuous non-speech.
        if (_silenceRunMs >= _silenceDurationToSplitMs) {
          await _splitOnSilence(savedFiles);
          offset += 4 + ((frameLength + 3) & ~3);
          frameIndex++;
          totalFrameCount++;
          continue;
        }

        // Max conversation duration cap (0 / disabled by default).
        if (_currentChunkDurationMs >= _maxChunkMs) {
          Logger.debug('VadAudioProcessor: Max conversation duration — forcing cut.');
          await _flushPartialWindow();
          final speechMs = _speechFrameCount * frameDurationMs;
          final bool tooShortSpeech = _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

          if (!tooShortSpeech) {
            // capEnded=true: VAD cut here because the recording hit the max-duration cap,
            // not because of silence. The pruneConsumedBins guard reads this flag from
            // .meta so it knows NOT to delete bins whose wall-clock extends past rec_end
            // (those bins may contain the post-cap continuation of the conversation).
            final filePath = await _saveRecording(_currentRefs, _recordingStartTime!, capEnded: true);
            // Encoder failure path: preserve queued taps as orphans.
            if (filePath == null) _emitOrphanMarkers();
            if (filePath != null) savedFiles.add(filePath);
          } else {
            final rec = _buildDiscardRecord('noise_max_duration');
            if (rec != null) _pendingDiscards.add(rec);
            _emitOrphanMarkers();
            Logger.debug('VadAudioProcessor: Discarding noise conversation during max-duration cut.');
          }
          final cutTime = _recordingStartTime!.add(Duration(milliseconds: _currentChunkDurationMs));

          final bool newConversationProtected =
              _markerProtectedUntilMs != null && cutTime.millisecondsSinceEpoch <= _markerProtectedUntilMs!;
          _forcedByMarker = newConversationProtected;

          _currentRefs = [];
          _speechFrameCount = 0;
          _currentChunkDurationMs = 0;
          _silenceRunMs = 0;
          _lastSpeechRefCount = 0;
          _lastSpeechChunkMs = 0;
          _recordingStartTime = cutTime;
          _pcmBufferLen = 0;
          // ignore: unawaited_futures, discarded_futures
          _cachedStateValue?.dispose();
          _cachedStateValue = null;
          _vadContext.fillRange(0, _vadContextSamples, 0.0);
        }

        offset += 4 + ((frameLength + 3) & ~3); // advance past 4-byte-aligned frame (matches SD card wire format)
        frameIndex++;
        totalFrameCount++;
      }

      _lastSegmentEndTime = lastFrameWallTime.add(const Duration(milliseconds: frameDurationMs));
      if (currentImuTicks != null) {
        final int segmentDurationMs = totalFrameCount * frameDurationMs;
        final int ticksPassed = (segmentDurationMs / 6.4).toInt();
        _lastImuTicks = (currentImuTicks + ticksPassed) & 0x00FFFFFF;
      }
      Logger.debug('VadAudioProcessor: ${segmentFile.path.split('/').last} — '
          '$totalFrameCount frames, $segmentSpeechFrames speech frames, maxAmp=${segmentMaxAmp.toStringAsFixed(4)}');
    } on VadProcessingCancelled {
      // Cooperative cancel from the isolate — propagate so the caller can bail
      // out cleanly without marking this segment as processed (we did not
      // finish it, and a future run must redo it).
      rethrow;
    } catch (e) {
      Logger.error('VadAudioProcessor: processSegmentFile error: $e');
    }

    _processedFiles.add(segmentFile.path);
    return savedFiles;
  }

  /// Cuts the current conversation when the Silero VAD has observed
  /// [_silenceDurationToSplitMs] of continuous non-speech. The speech is saved
  /// trimmed at the last speech frame (or discarded if below the speech
  /// minimum); the trailing silence is trashed but its bins are kept
  /// recoverable on disk (excluding any bin that also backs the saved
  /// recording). Pure-silence runs with no speech yet are trashed wholesale so
  /// the buffer can't grow unbounded. Leaves state reset so the next speech
  /// frame starts a fresh conversation.
  Future<void> _splitOnSilence(List<String> savedFiles) async {
    await _flushPartialWindow();
    if (_speechFrameCount > 0 && _lastSpeechRefCount > 0 && _lastSpeechRefCount <= _currentRefs.length) {
      final savedRefs = _currentRefs.sublist(0, _lastSpeechRefCount);
      final trailingSilence = _currentRefs.sublist(_lastSpeechRefCount);
      final savedBins = _binsOf(savedRefs);
      final silenceStart = _recordingStartTime!.add(Duration(milliseconds: _lastSpeechChunkMs));
      final trailingMs = _currentChunkDurationMs - _lastSpeechChunkMs;

      // Present only the speech portion to the save/discard + marker bookkeeping
      // (both read _currentRefs / _currentChunkDurationMs), so the trailing
      // silence is trimmed off the recording and the EDL durations stay honest.
      _currentRefs = savedRefs;
      _currentChunkDurationMs = _lastSpeechChunkMs;

      final speechMs = _speechFrameCount * frameDurationMs;
      final tooShort = _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;
      if (tooShort) {
        final rec = _buildDiscardRecord('noise_silence_split');
        if (rec != null) _pendingDiscards.add(rec);
        _emitOrphanMarkers();
        Logger.debug('VadAudioProcessor: Silence split — discarding ${speechMs}ms low-speech chunk.');
      } else {
        final filePath = await _saveRecording(savedRefs, _recordingStartTime!);
        if (filePath == null) {
          _emitOrphanMarkers();
        } else {
          savedFiles.add(filePath);
        }
        Logger.debug('VadAudioProcessor: Silence split — saved ${_lastSpeechChunkMs}ms speech, '
            'trimmed ${trailingMs}ms trailing silence.');
      }

      final silenceDiscard =
          _buildDiscardRecordFor(trailingSilence, silenceStart, trailingMs, 'silence_trimmed', excludeBins: savedBins);
      if (silenceDiscard != null) _pendingDiscards.add(silenceDiscard);
    } else {
      // No speech yet — the whole buffer is silence. Trash it (bins recoverable).
      final rec = _buildDiscardRecord('silence_only');
      if (rec != null) _pendingDiscards.add(rec);
      _emitOrphanMarkers();
      Logger.debug('VadAudioProcessor: Trashing ${_currentChunkDurationMs}ms of speechless silence.');
    }

    _resetState();
  }

  Future<String?> flushRemaining({bool isDraft = false}) async {
    await _flushPartialWindow();
    final speechMs = _speechFrameCount * frameDurationMs;
    final bool tooShortSpeech = _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

    if (_currentRefs.isEmpty ||
        (_discardShort && _currentChunkDurationMs < _minDurationMs && !_forcedByMarker) ||
        tooShortSpeech) {
      discardGuardFiredOnLastFlush = _currentRefs.isNotEmpty;
      if (_currentRefs.isNotEmpty) {
        final reason = tooShortSpeech
            ? "${speechMs}ms speech < ${_minSpeechMs}ms minimum"
            : "${_currentChunkDurationMs}ms < ${_minDurationMs}ms minimum";
        final rec = _buildDiscardRecord(tooShortSpeech ? 'flush_noise' : 'flush_too_short_duration');
        if (rec != null) _pendingDiscards.add(rec);
        Logger.debug('VadAudioProcessor: flushRemaining discarding ${_currentRefs.length} frames ($reason)');
      }
      // Emit any pending markers as orphan EDLs so a button-tap is never lost
      // even when the surrounding audio was discarded (or never arrived).
      _emitOrphanMarkers();
      _resetState();
      return null;
    }
    discardGuardFiredOnLastFlush = false;
    final path = await _saveRecording(_currentRefs, _recordingStartTime!, isDraft: isDraft);
    // _saveRecording consumes _pendingMarkers only when it returns a non-null
    // result. If encoding produced zero frames or failed, any queued taps are
    // still in _pendingMarkers; emit them as orphans before _resetState wipes
    // them silently.
    if (path == null) _emitOrphanMarkers();
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
    _forcedByMarker = false;
    // Preserve _markerProtectedUntilMs across reset — the 50 s window applies
    // to wall-clock time, so an inter-file split shouldn't drop protection
    // when the next bin starts within the window. It self-expires naturally
    // once audio wall time crosses it.
    _currentRefs = [];
    _speechFrameCount = 0;
    _currentChunkDurationMs = 0;
    _currentMaxVoiceProb = 0.0;
    _recordingStartTime = null;
    _silenceRunMs = 0;
    _lastSpeechRefCount = 0;
    _lastSpeechChunkMs = 0;
    // Reset VAD model state so the next conversation starts with a clean LSTM.
    // Not resetting these contaminates the first few VAD decisions of the new
    // conversation with the previous conversation's recurrent state.
    _pcmBufferLen = 0;
    // ignore: unawaited_futures, discarded_futures
    _cachedStateValue?.dispose();
    _cachedStateValue = null;
    _vadContext.fillRange(0, _vadContextSamples, 0.0);
    // Defensive clear: callers that discard MUST call _emitOrphanMarkers()
    // before _resetState() — otherwise the tap is lost silently. Anything
    // still in _pendingMarkers here is a bug in the caller; we wipe it so it
    // doesn't leak into the next conversation with a stale offset.
    if (_pendingMarkers.isNotEmpty) {
      Logger.error(
          'VadAudioProcessor: _resetState dropping ${_pendingMarkers.length} pending marker(s) — caller forgot _emitOrphanMarkers()');
      _pendingMarkers.clear();
    }
  }

  /// Zero-pads the partial sample buffer to 512 samples and runs one final
  /// VAD pass at a conversation boundary. If speech is detected in the tail,
  /// updates the high-water marks so [_splitOnSilence] trims at the correct
  /// frame rather than over-trimming by up to 1–2 frames (~32 ms).
  ///
  /// Must be called — with the current LSTM state intact — immediately before
  /// any [_resetState] call or inline state reset. Is a no-op when the buffer
  /// is empty or no Silero session is loaded (AAD mode).
  Future<void> _flushPartialWindow() async {
    if (_session == null || _pcmBufferLen == 0) return;
    final padded = Float32List(_vadWindowSamples);
    padded.setRange(0, _pcmBufferLen, _pcmBuffer);
    // Remainder is already zero — Float32List default.
    if (await _runVad(padded)) {
      _lastSpeechRefCount = _currentRefs.length;
      _lastSpeechChunkMs = _currentChunkDurationMs;
    }
  }

  /// Emits any queued button-tap markers as standalone EDL entries with no
  /// backing segment, so a tap is never lost when the surrounding audio
  /// is discarded by VAD/min-duration guards.
  ///
  /// Also clears `_markerProtectedUntilMs`: once a tap has been promoted to
  /// an orphan EDL, the 50 s protection window is no longer "guarding the
  /// real recording" — leaving it set would cause the next unrelated audio
  /// in the same minute to be force-promoted with no marker to link to.
  void _emitOrphanMarkers() {
    if (_pendingMarkers.isEmpty) return;
    for (final m in _pendingMarkers) {
      _pendingEdlData.add({
        'filename': '', // empty → marker has no backing segment
        'markerMs': m.markerMs,
        'offsetMs': 0,
        'durationMs': 0,
      });
    }
    _pendingMarkers.clear();
    _markerProtectedUntilMs = null;
  }

  /// Builds a discard record from the current conversation state. Caller is
  /// responsible for adding to [_pendingDiscards] and resetting state afterwards.
  // Maps refs → set of relative bin paths (the `raw_segments/...` tail).
  Set<String> _binsOf(Iterable<Object> refs) {
    final bins = <String>{};
    for (final item in refs) {
      if (item is! FrameRef) continue;
      // Path layout: <docs>/raw_segments/<sessionId>/<file>.bin → store relative tail.
      final segments = item.segmentFile.path.split('/raw_segments/');
      bins.add(segments.length == 2 ? segments.last : item.segmentFile.path);
    }
    return bins;
  }

  Map<String, dynamic>? _buildDiscardRecord(String reason) =>
      _buildDiscardRecordFor(_currentRefs, _recordingStartTime, _currentChunkDurationMs, reason);

  /// Builds a discard record for an explicit ref list / span so the referenced
  /// bins are preserved on disk for recovery. [excludeBins] drops any bin that
  /// is also kept alive by a saved recording — protecting such a bin would let
  /// it be re-gathered and re-decoded next run, duplicating the saved audio.
  /// Returns null when there is nothing left to protect.
  Map<String, dynamic>? _buildDiscardRecordFor(List<Object> refs, DateTime? startTime, int durationMs, String reason,
      {Set<String>? excludeBins}) {
    if (refs.isEmpty || startTime == null) return null;
    final relativeBins = _binsOf(refs);
    if (excludeBins != null) relativeBins.removeAll(excludeBins);
    if (relativeBins.isEmpty) return null;
    return {
      'startMs': startTime.millisecondsSinceEpoch,
      'endMs': startTime.millisecondsSinceEpoch + durationMs,
      'reason': reason,
      'maxVoiceProb': _currentMaxVoiceProb,
      'relativeBins': relativeBins.toList(),
    };
  }

  /// Drains and returns any discard records produced since the last call.
  List<Map<String, dynamic>> consumePendingDiscards() {
    if (_pendingDiscards.isEmpty) return const [];
    final result = List<Map<String, dynamic>>.from(_pendingDiscards);
    _pendingDiscards.clear();
    return result;
  }

  /// Drains and returns any EDL associations produced since the last call.
  /// Each entry: {filename, markerMs, offsetMs, durationMs}.
  List<Map<String, dynamic>> consumePendingEdlData() {
    if (_pendingEdlData.isEmpty) return const [];
    final result = List<Map<String, dynamic>>.from(_pendingEdlData);
    _pendingEdlData.clear();
    return result;
  }

  @visibleForTesting
  Future<String?> saveRecordingTest(List<Object> refs, DateTime startTime, {bool isDerivedTimestamp = false}) =>
      _saveRecording(refs, startTime, isDerivedTimestamp: isDerivedTimestamp);

  Future<String?> _saveRecording(List<Object> refs, DateTime startTime,
      {bool? isDerivedTimestamp, bool isDraft = false, bool capEnded = false}) async {
    final result = await _saveRecordingCore(refs, startTime,
        isDerivedTimestamp: isDerivedTimestamp, isDraft: isDraft, capEnded: capEnded);
    if (result != null) {
      if (_pendingMarkers.isNotEmpty) {
        final filename = result.split('/').last;
        // EDL cropEnd must be playable: cap wall-clock progress at the file's
        // actual encoded duration. If decode failures dropped frames silently,
        // _currentChunkDurationMs can exceed what's on disk.
        var durationMs = _currentChunkDurationMs;
        try {
          final base = result.contains('.') ? result.substring(0, result.lastIndexOf('.')) : result;
          final metaBytes = await File('$base.meta').readAsBytes();
          if (metaBytes.length >= 8) {
            final encodedMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
            if (encodedMs > 0 && encodedMs < durationMs) durationMs = encodedMs;
          }
        } catch (_) {}
        for (final m in _pendingMarkers) {
          _pendingEdlData.add({
            'filename': filename,
            'markerMs': m.markerMs,
            'offsetMs': m.offsetAtMarkerMs,
            'durationMs': durationMs,
          });
        }
        _pendingMarkers.clear();
      }
      if (_omiEnabled) {
        try {
          final dateFolderPath = File(result).parent.path;
          await _saveBin(refs, dateFolderPath, startTime.millisecondsSinceEpoch);
        } catch (e) {
          Logger.error('VadAudioProcessor: _saveBin failed: $e');
        }
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
        _onLiveness?.call();
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
      {bool? isDerivedTimestamp, bool isDraft = false, bool capEnded = false}) async {
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
      final localStart = startTime.toLocal();
      final dateString =
          '${localStart.year}-${localStart.month.toString().padLeft(2, '0')}-${localStart.day.toString().padLeft(2, '0')}';
      dateFolderPath = '${directory.path}/recordings/$dateString';
    }

    final dateFolder = Directory(dateFolderPath);
    if (!await dateFolder.exists()) {
      await dateFolder.create(recursive: true);
    }

    final frameRefCount = refs.whereType<FrameRef>().length;
    if (frameRefCount > 0 && frameRefCount < 5) {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix, capEnded: capEnded);
    }

    // Always use WAV for drafts if M4A is requested, as M4A doesn't support easy stitching.
    // The RecordingsManager will convert the finalized WAV to M4A during the promotion phase.
    if (_audioSaveFormat == 'wav' || (isDraft && _audioSaveFormat == 'm4a')) {
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix, capEnded: capEnded);
    } else if (_audioSaveFormat == 'ogg') {
      if (Platform.isIOS) {
        return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix, capEnded: capEnded);
      } else {
        return await _saveOgg(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix, capEnded: capEnded);
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
    bool hasEncodedAnyFrames = false;

    try {
      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
    } on Exception catch (e) {
      Logger.error('VadAudioProcessor: AAC startEncoder failed, falling back to WAV: $e');
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }

    Future<void> flushBatch() async {
      if (batchFrameCount == 0) return;
      final chunk = batchBuffer.takeBytes();

      // Split large chunks into smaller segments (e.g. 4KB) for the native encoder.
      // Silence gaps can produce massive buffers that exceed hardware MediaCodec capacity.
      const maxNativeChunkSize = 4096;
      for (int i = 0; i < chunk.length; i += maxNativeChunkSize) {
        final end = (i + maxNativeChunkSize > chunk.length) ? chunk.length : i + maxNativeChunkSize;
        // View, not copy: encodeBuffer marshals the bytes synchronously over the MethodChannel,
        // and `chunk` (from takeBytes()) is never mutated, so a shared-buffer view is safe here.
        await AacEncoder.encodeBuffer(sessionId!, Uint8List.sublistView(chunk, i, end));
      }

      hasEncodedAnyFrames = true;
      batchFrameCount = 0;
    }

    int totalFrameRefs = 0;
    int skippedReadFail = 0;
    int skippedDecodeNull = 0;
    int skippedDecodeEmpty = 0;

    try {
      String? currentFilePath;
      Uint8List? currentFileBytes;

      for (var i = 0; i < refs.length; i++) {
        _onLiveness?.call();
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final silenceSamples = (ms * sampleRate) ~/ 1000;
          final silenceBytes = Uint8List(silenceSamples * 2); // 16-bit mono

          batchBuffer.add(silenceBytes);
          totalSamples += silenceSamples;

          // Waveform for silence
          for (int s = 0; s < silenceSamples; s++) {
            currentWindowSamples++;
            if (currentWindowSamples >= windowSize) {
              dynamicPeaks.add(0.0);
              currentWindowSamples = 0;
            }
          }
          batchFrameCount += (ms / frameDurationMs).ceil();
          if (batchFrameCount >= batchFrames) await flushBatch();
          continue;
        }

        final ref = item as FrameRef;
        totalFrameRefs++;
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        if (ref.segmentFile.path != currentFilePath) {
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
          await Future.delayed(Duration.zero);
        }

        if (currentFileBytes == null) {
          skippedReadFail++;
          continue;
        }

        final frameDataOffset = ref.byteOffset + 4;
        final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (_) {}

        if (pcmData == null) {
          skippedDecodeNull++;
          continue;
        }
        if (pcmData.isEmpty) {
          skippedDecodeEmpty++;
          continue;
        }

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

      await AacEncoder.finishEncoder(sessionId);
    } on Exception catch (e) {
      Logger.error('VadAudioProcessor: AAC encoding failed, falling back to WAV: $e');
      final corruptFile = File('${dateFolder.path}/${prefix}_$timestamp$suffix.m4a');
      try {
        if (await corruptFile.exists()) await corruptFile.delete();
      } catch (_) {}
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix, capEnded: capEnded);
    }

    await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
        prefix: prefix, extension: 'm4a', suffix: suffix, capEnded: capEnded);

    final totalSkipped = skippedReadFail + skippedDecodeNull + skippedDecodeEmpty;
    if (totalFrameRefs > 0 && totalSkipped * 20 > totalFrameRefs) {
      Logger.error('VadAudioProcessor: $m4aPath dropped $totalSkipped/$totalFrameRefs frames '
          '(${(100 * totalSkipped / totalFrameRefs).toStringAsFixed(1)}%): '
          'readFail=$skippedReadFail decodeNull=$skippedDecodeNull decodeEmpty=$skippedDecodeEmpty — '
          'wallClock=${_currentChunkDurationMs}ms encoded=${(totalSamples * 1000) ~/ sampleRate}ms');
    }

    Logger.debug(
        'VadAudioProcessor: Saved recording (${refs.length} frames, ${((totalSamples * 1000) ~/ sampleRate)}ms) '
        'starting at $_recordingStartTime to $m4aPath');
    return m4aPath;
  }

  Future<void> _saveMetadata(List<Object> refs, String dateFolderPath, int timestamp, int totalSamples,
      List<double> dynamicPeaks, int waveformBuckets,
      {required String prefix, required String extension, String suffix = '', bool capEnded = false}) async {
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
      } else {
        metaOut.add(0); // empty keyLen so the flag bytes still land at flagOffset = 417
      }
    } else {
      metaOut.add(0); // empty keyLen — keep flag bytes positioned at flagOffset = 417
    }
    // Three flag bytes at flagOffset = 417 + keyLen:
    //   [0] passthrough (set later by integrations layer, 0 on initial write)
    //   [1] forceSynced (set later by _finalizeDraft for manual-finalize cases, 0 on initial write)
    //   [2] capEnded    (set HERE — true iff VAD ended this recording at the max-duration cap)
    // pruneConsumedBins reads byte [2] to decide whether bins extending past rec_end may be
    // safely deleted (silence-ended) or must be preserved (cap-ended).
    metaOut.add(0); // passthrough
    metaOut.add(0); // forceSynced
    metaOut.add(capEnded ? 1 : 0); // capEnded
    await File(metaPath).writeAsBytes(metaOut);
  }

  Future<String?> _saveOgg(List<Object> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording', String suffix = '', bool capEnded = false}) async {
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
        _onLiveness?.call();
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final durationSamples = (ms * sampleRate) ~/ 1000;
          final silenceFrames = (ms / frameDurationMs).round();

          for (int f = 0; f < silenceFrames; f++) {
            granulePos += 960; // 20ms at 48kHz
            pagePackets.add(opusSilenceFrame);

            if (pagePackets.length >= 40) {
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

        if (pagePackets.length >= 40) {
          // 40 frames per page (~800ms)
          sink.add(_createOggPage(granulePos, pageSeqNum++, serial, pagePackets.toList()));
          pagePackets.clear();
        }
      }

      if (pagePackets.isNotEmpty) {
        sink.add(_createOggPage(granulePos, pageSeqNum++, serial, pagePackets, isLastPage: true));
      } else {
        // OGG needs at least one page with the EOS flag.
        sink.add(_createOggPage(granulePos, pageSeqNum++, serial, [], isLastPage: true));
      }

      await sink.flush();
      await sink.close();

      await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
          prefix: prefix, extension: 'ogg', suffix: suffix, capEnded: capEnded);

      await oggFile.rename(oggPath);
      renamed = true;
      Logger.debug(
          'VadAudioProcessor: Saved recording (${refs.length} frames, ${((totalSamples * 1000) ~/ sampleRate)}ms) '
          'starting at $_recordingStartTime to $oggPath');
      return oggPath;
    } catch (e) {
      Logger.error('VadAudioProcessor: _saveOgg failed: $e');
      if (!renamed && await oggFile.exists()) await oggFile.delete();
      return await _saveWav(refs, dateFolderPath, timestamp, prefix: prefix, suffix: suffix);
    }
  }

  Uint8List _createOggOpusIdHeader() {
    final header = ByteData(19);
    header.setUint8(0, 0x4F); // O
    header.setUint8(1, 0x70); // p
    header.setUint8(2, 0x75); // u
    header.setUint8(3, 0x73); // s
    header.setUint8(4, 0x48); // H
    header.setUint8(5, 0x65); // e
    header.setUint8(6, 0x61); // a
    header.setUint8(7, 0x64); // d
    header.setUint8(8, 0x01); // Version
    header.setUint8(9, channels);
    header.setUint16(10, 0, Endian.little); // Pre-skip
    header.setUint32(12, 48000, Endian.little); // Input sample rate
    header.setUint16(16, 0, Endian.little); // Output gain
    header.setUint8(18, 0x00); // Channel map
    return header.buffer.asUint8List();
  }

  Uint8List _createOggOpusCommentHeader() {
    const vendor = "Omi Offline";
    final vendorBytes = utf8.encode(vendor);
    final header = ByteData(8 + 4 + vendorBytes.length + 4);
    header.setUint8(0, 0x4F); // O
    header.setUint8(1, 0x70); // p
    header.setUint8(2, 0x75); // u
    header.setUint8(3, 0x73); // s
    header.setUint8(4, 0x54); // T
    header.setUint8(5, 0x61); // a
    header.setUint8(6, 0x67); // g
    header.setUint8(7, 0x73); // s
    header.setUint32(8, vendorBytes.length, Endian.little);
    for (int i = 0; i < vendorBytes.length; i++) {
      header.setUint8(12 + i, vendorBytes[i]);
    }
    header.setUint32(12 + vendorBytes.length, 0, Endian.little); // User comment count
    return header.buffer.asUint8List();
  }

  Uint8List _createOggPage(int granulePos, int pageSeqNum, int serial, List<Uint8List> packets,
      {bool isFirstPage = false, bool isLastPage = false}) {
    int pageHeaderSize = 27 + packets.length;
    int pageDataSize = packets.fold(0, (sum, p) => sum + p.length);
    final page = ByteData(pageHeaderSize + pageDataSize);

    page.setUint8(0, 0x4F); // O
    page.setUint8(1, 0x67); // g
    page.setUint8(2, 0x67); // g
    page.setUint8(3, 0x53); // S
    page.setUint8(4, 0x00); // Version
    int flags = 0;
    if (isFirstPage) flags |= 0x02;
    if (isLastPage) flags |= 0x04;
    page.setUint8(5, flags);
    page.setUint64(6, granulePos, Endian.little);
    page.setUint32(14, serial, Endian.little);
    page.setUint32(18, pageSeqNum, Endian.little);
    page.setUint32(22, 0, Endian.little); // Checksum (filled later)
    page.setUint8(26, packets.length);

    int offset = 27;
    for (var p in packets) {
      page.setUint8(offset++, p.length);
    }
    for (var p in packets) {
      for (int i = 0; i < p.length; i++) {
        page.setUint8(offset++, p[i]);
      }
    }

    // CRC-32 (Ogg variant)
    final crc = _computeOggCrc(page.buffer.asUint8List());
    page.setUint32(22, crc, Endian.little);

    return page.buffer.asUint8List();
  }

  int _computeOggCrc(Uint8List data) {
    int crc = 0;
    for (int i = 0; i < data.length; i++) {
      crc = (crc << 8) ^ _oggCrcTable[((crc >> 24) ^ data[i]) & 0xFF];
    }
    return crc & 0xFFFFFFFF;
  }

  static final List<int> _oggCrcTable = _generateOggCrcTable();
  static List<int> _generateOggCrcTable() {
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int r = i << 24;
      for (int j = 0; j < 8; j++) {
        if ((r & 0x80000000) != 0) {
          r = (r << 1) ^ 0x04c11db7;
        } else {
          r <<= 1;
        }
      }
      table[i] = r & 0xFFFFFFFF;
    }
    return table;
  }

  Future<String?> _saveWav(List<Object> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording', String suffix = '', bool capEnded = false}) async {
    final wavPath = '$dateFolderPath/${prefix}_$timestamp$suffix.wav';
    final rawPath = '$dateFolderPath/${prefix}_$timestamp$suffix.raw';
    final rawFile = File(rawPath);
    final sink = rawFile.openWrite();

    const waveformBuckets = 200;
    const windowSize = 800;

    final dynamicPeaks = <double>[];
    double currentWindowMax = 0.0;
    int currentWindowSamples = 0;
    int totalSamples = 0;

    int totalFrameRefs = 0;
    int skippedReadFail = 0;
    int skippedDecodeNull = 0;
    int skippedDecodeEmpty = 0;

    try {
      String? currentFilePath;
      Uint8List? currentFileBytes;
      for (var i = 0; i < refs.length; i++) {
        _onLiveness?.call();
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final silenceSamples = (ms * sampleRate) ~/ 1000;
          final silenceBytes = Uint8List(silenceSamples * 2); // 16-bit mono
          sink.add(silenceBytes);
          totalSamples += silenceSamples;
          for (int s = 0; s < silenceSamples; s++) {
            currentWindowSamples++;
            if (currentWindowSamples >= windowSize) {
              dynamicPeaks.add(0.0);
              currentWindowSamples = 0;
            }
          }
          continue;
        }

        final ref = item as FrameRef;
        totalFrameRefs++;
        if (i % 50 == 0) await Future.delayed(Duration.zero);

        if (ref.segmentFile.path != currentFilePath) {
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
          await Future.delayed(Duration.zero);
        }

        if (currentFileBytes == null) {
          skippedReadFail++;
          continue;
        }

        final frameDataOffset = ref.byteOffset + 4;
        final opusBytes = Uint8List.sublistView(currentFileBytes, frameDataOffset, frameDataOffset + ref.frameLength);

        Int16List? pcmData;
        try {
          pcmData = _decoder?.decode(input: opusBytes);
        } catch (_) {}

        if (pcmData == null) {
          skippedDecodeNull++;
          continue;
        }
        if (pcmData.isEmpty) {
          skippedDecodeEmpty++;
          continue;
        }

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
        sink.add(pcmData.buffer.asUint8List(pcmData.offsetInBytes, pcmData.lengthInBytes));
      }

      await sink.flush();
      await sink.close();

      // Assemble final WAV with header + raw PCM stream
      final wavFile = File('$wavPath.tmp');
      final wavSink = wavFile.openWrite();
      try {
        final header = _generateWavHeader(totalSamples * 2, sampleRate, 1);
        wavSink.add(header);
        await wavSink.addStream(rawFile.openRead());
        await wavSink.flush();
      } finally {
        await wavSink.close();
      }

      await rawFile.delete();

      await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
          prefix: prefix, extension: 'wav', suffix: suffix, capEnded: capEnded);

      await wavFile.rename(wavPath);

      final totalSkipped = skippedReadFail + skippedDecodeNull + skippedDecodeEmpty;
      if (totalFrameRefs > 0 && totalSkipped * 20 > totalFrameRefs) {
        Logger.error('VadAudioProcessor: $wavPath dropped $totalSkipped/$totalFrameRefs frames '
            '(${(100 * totalSkipped / totalFrameRefs).toStringAsFixed(1)}%): '
            'readFail=$skippedReadFail decodeNull=$skippedDecodeNull decodeEmpty=$skippedDecodeEmpty — '
            'wallClock=${_currentChunkDurationMs}ms encoded=${(totalSamples * 1000) ~/ sampleRate}ms');
      }

      Logger.debug(
          'VadAudioProcessor: Saved recording (${refs.length} frames, ${((totalSamples * 1000) ~/ sampleRate)}ms) '
          'starting at $_recordingStartTime to $wavPath');
      return wavPath;
    } catch (e) {
      Logger.error('VadAudioProcessor: _saveWav failed: $e');
      if (await rawFile.exists()) await rawFile.delete();
      return null;
    }
  }

  Uint8List _generateWavHeader(int pcmBytes, int sampleRate, int channels) {
    final header = ByteData(44);
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, 36 + pcmBytes, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little);
    header.setUint16(32, channels * 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, pcmBytes, Endian.little);
    return header.buffer.asUint8List();
  }
}
