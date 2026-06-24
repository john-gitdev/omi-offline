import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/frame_ref.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:omi/utils/logger.dart';

// Re-export the VAD value types so existing importers of this file
// (recordings_manager, recordings_controller) keep working unchanged. The
// definitions now live in services/vad/vad_types.dart.
export 'package:omi/services/vad/vad_types.dart';

class VadAudioProcessor {
  // Native batch runner (Android-only); null when unavailable (iOS/desktop/tests).
  final VadBatchRunnerChannel? _batchRunner;

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
  // Sample buffer feeding the VAD windower — index-based, never reallocated.
  // Drained inline at exactly _vadWindowSamples (see processSegmentFile), so it
  // never holds more than one window regardless of decoded frame size. Sized at
  // _vadWindowSamples is sufficient; the extra headroom is defensive only.
  final Float32List _pcmBuffer = Float32List(_vadWindowSamples * 2);
  int _pcmBufferLen = 0;

  // --- Two-pass batch buffers (Android batch runner path) ---
  // Accumulated 512-sample windows for the next runVadBatch call.
  final List<Float32List> _batchWindows = [];
  // For each window in _batchWindows, the index into _batchDeferredFrames of
  // the audio frame during which this window completed. Used in Pass 2 to map
  // window probs back to the frame that triggered them.
  final List<int> _batchWindowFrameIndices = [];
  // Deferred per-frame metadata accumulated in Pass 1. Replayed in Pass 2
  // after runVadBatch returns the probabilities.
  final List<_DeferredFrame> _batchDeferredFrames = [];
  // True when the native batch runner's LSTM state must be zeroed before the
  // next runVadBatch call (set at every conversation boundary / state reset).
  bool _batchResetPending = true;

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

  // AAD-mode resume-split flood guard. A clock-anchor mismatch (firmware UTC in
  // a 0xFFFFFFFD marker diverging from the frame timeline) can make EVERY resume
  // marker read as a huge forward gap, splitting the stream into a flood of
  // sub-second junk recordings (observed: 3482× one-frame recordings in ~1 min).
  // Only a concern when Silero is unavailable (AAD mode) — in Silero mode the
  // app's own silence detection governs splits, not the markers. Once we see a
  // RUN of consecutive tiny splits we latch into coalesce mode: further resume
  // markers become no-ops (stitch on the real frame timeline) until a real
  // boundary clears the latch in flushRemaining. A lone short recording still
  // splits — only a sustained flood is coalesced.
  int _consecutiveTinyAadSplits = 0;
  bool _aadFloodActive = false;
  static const int _aadFloodSplitFloorMs = 1000; // a split closing < this much audio is "tiny"
  static const int _aadFloodRunThreshold = 3; // coalesce once this many tiny splits occur in a row

  // App-side silence-split tracking. _silenceRunMs is the length of the current
  // unbroken run of non-speech frames (reset to 0 on any speech frame). Reset on
  // every conversation boundary (see _resetState and the inline resets in the
  // gap-split / max-cap paths).
  int _silenceRunMs = 0;

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

  // Muted-interval tracking. Opened by a 0xFFFFFFFA mute-on marker (which also
  // finalizes the in-progress recording, like session-end), closed by a
  // 0xFFFFFFF9 mute-off marker or — if the device powered off while muted — by
  // the next session change. A closed interval is emitted as a "muted" discard
  // (ghost row). Persisted across runs so an interval that spans a sync survives.
  bool _muted = false;
  int? _muteStartMs;

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

  // Mirrors FORCE_WAKE_HOLD_MS in firmware/omi/src/aad.c. After a button-tap
  // marker the firmware force-wakes and keeps recording for this many ms; the
  // app suppresses splits and forces speech for the same span so a tap's audio
  // is never split away from it. MUST stay equal to the firmware constant — if
  // they drift, the app's protection window won't line up with the audio the
  // firmware actually forced on.
  static const int _markerProtectionWindowMs = 50000;

  /// Creates a processor in the main isolate, reading settings from SharedPreferences.
  static Future<VadAudioProcessor> create({String? outputDir, SimpleOpusDecoder? decoder}) async {
    final settings = ProcessingSettings.fromPrefs();
    OrtSession? session;
    if (settings.vadEnabled) {
      try {
        session = await OnnxRuntime()
            .createSessionFromAsset('assets/models/silero_vad.onnx', options: await buildSileroSessionOptions());
        Logger.debug('VadAudioProcessor: Silero session — inputs=${session.inputNames} outputs=${session.outputNames}');
      } catch (e) {
        Logger.error('VadAudioProcessor: Failed to load Silero VAD model, AAD mode active: $e');
      }
    }
    Logger.debug(
        'VadAudioProcessor: init — ${session != null ? 'Silero VAD loaded' : 'AAD mode${settings.vadEnabled ? ' (model unavailable)' : ''}'}');
    return VadAudioProcessor._(outputDir: outputDir, decoder: decoder, session: session, settings: settings);
  }

  /// Tuned ONNX session options for the Silero VAD graph, shared by every
  /// session-creation site (main isolate + background isolate).
  ///
  /// Silero is a tiny recurrent model invoked once per 512-sample / 32 ms
  /// window — ~112k inferences per recorded hour. The per-call cost is fixed
  /// overhead plus small sequential compute, not parallelisable work, so:
  ///   - interOpNumThreads = 1: the graph is a single sequential chain;
  ///     inter-op threads only add thread-pool sync overhead.
  ///   - intraOpNumThreads = 1: for a model this small the fork/join cost of a
  ///     multi-thread intra-op region exceeds the compute it saves. (This is
  ///     the one knob worth A/B-profiling per device if save time regresses.)
  ///   - XNNPACK when present: faster ARM CPU kernels for the conv/matmul ops,
  ///     deterministic, with CPU fallback. Queried at runtime because the
  ///     shipped ORT build may not bundle it.
  // VAD ONNX tuning knobs — consts so they can be A/B'd by rebuilding and
  // re-reading the provider/timing log. The `run` ms in the timing summary is
  // the dial to watch when changing these. See NOTES.md "VAD perf".
  static const int _vadIntraOpThreads = 1; // A/B done: 2 gave no real compute win (thermal confound) — see NOTES
  static const int _vadInterOpThreads = 1;

  static Future<OrtSessionOptions> buildSileroSessionOptions() async {
    List<OrtProvider>? providers;
    List<OrtProvider> available = const [];
    try {
      available = await OnnxRuntime().getAvailableProviders();
      if (available.contains(OrtProvider.XNNPACK)) {
        providers = const [OrtProvider.XNNPACK, OrtProvider.CPU];
      }
    } catch (_) {
      // Provider probe failed — leave providers null so ORT uses its default.
    }
    // One-time line per session: confirms whether XNNPACK was actually
    // available (else we silently ran default CPU) and records the thread
    // config so each test's log is self-documenting.
    Logger.debug('VadAudioProcessor: ORT providers available=$available '
        'requested=${providers ?? "(ORT default CPU)"} '
        'intraOp=$_vadIntraOpThreads interOp=$_vadInterOpThreads');
    return OrtSessionOptions(
      intraOpNumThreads: _vadIntraOpThreads,
      interOpNumThreads: _vadInterOpThreads,
      providers: providers,
    );
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
    VadBatchRunnerChannel? batchRunner,
  }) : this._(
            outputDir: outputDir,
            decoder: decoder,
            session: session,
            settings: settings,
            onLiveness: onLiveness,
            isCancelled: isCancelled,
            batchRunner: batchRunner);

  VadAudioProcessor._(
      {String? outputDir,
      SimpleOpusDecoder? decoder,
      OrtSession? session,
      required ProcessingSettings settings,
      void Function()? onLiveness,
      bool Function()? isCancelled,
      VadBatchRunnerChannel? batchRunner})
      : _session = session,
        _batchRunner = batchRunner,
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
        _maxChunkMs = settings.maxChunkMs,
        _deviceId = settings.deviceId,
        _audioSaveFormat = settings.audioSaveFormat,
        _omiEnabled = settings.omiEnabled;

  /// Whether the native batch runner is available for this processor instance.
  /// When true, processSegmentFile uses the two-pass batched VAD path.
  bool get _useBatchRunner => _batchRunner != null && _batchRunner!.available && _session != null;

  Future<void> destroy() async {
    _decoder?.destroy();
    final s = _session;
    _session = null;
    await s?.close();
    // ignore: unawaited_futures, discarded_futures
    _cachedStateValue?.dispose();
    _cachedStateValue = null;
    // ignore: unawaited_futures, discarded_futures
    _cachedSrValue?.dispose();
    _cachedSrValue = null;
  }

  /// Serializes all conversation and VAD model state to a JSON-compatible map
  /// for checkpointing between isolate runs. Returns null when there is nothing
  /// to save (empty refs and empty PCM buffer — processor is between conversations).
  Future<Map<String, dynamic>?> serializeState() async {
    if (_currentRefs.isEmpty && _pcmBufferLen == 0) return null;
    final refs = <Map<String, dynamic>>[];
    for (final item in _currentRefs) {
      if (item is FrameRef) {
        refs.add({'t': 'f', 'p': item.segmentFile.path, 'o': item.byteOffset, 'l': item.frameLength});
      } else if (item is Duration) {
        refs.add({'t': 's', 'ms': item.inMilliseconds});
      }
    }
    List<double>? vadStateFloats;
    if (_cachedStateValue != null) {
      try {
        vadStateFloats = (await _cachedStateValue!.asFlattenedList()).cast<double>();
      } catch (_) {}
    }
    return {
      'refs': refs,
      'sfc': _speechFrameCount,
      'rst': _recordingStartTime?.millisecondsSinceEpoch,
      'lse': _lastSegmentEndTime?.millisecondsSinceEpoch,
      'idt': _isDerivedTimestamp,
      'csi': _currentSessionId,
      'csu': _currentStartUptime,
      'cfu': _currentFrameUptimeMs,
      'lit': _lastImuTicks,
      'ccd': _currentChunkDurationMs,
      'srm': _silenceRunMs,
      'cmv': _currentMaxVoiceProb,
      'fbm': _forcedByMarker,
      'mpu': _markerProtectedUntilMs,
      'sep': _sessionEndPendingResume,
      'mtd': _muted,
      'mts': _muteStartMs,
      'pm': _pendingMarkers.map((m) => {'ms': m.markerMs, 'o': m.offsetAtMarkerMs}).toList(),
      'vs': vadStateFloats,
      'vc': _vadContext.toList(),
      'pb': List<double>.generate(_pcmBufferLen, (i) => _pcmBuffer[i]),
      'pbl': _pcmBufferLen,
    };
  }

  /// Restores conversation and VAD model state from a previously serialized map.
  /// Called at the start of a resumed processing run to pick up where the
  /// prior (cancelled or backgrounded) run left off.
  Future<void> restoreState(Map<String, dynamic> s) async {
    _currentRefs = [];
    for (final item in (s['refs'] as List).cast<Map<String, dynamic>>()) {
      if (item['t'] == 'f') {
        _currentRefs.add(FrameRef(
            segmentFile: File(item['p'] as String), byteOffset: item['o'] as int, frameLength: item['l'] as int));
      } else if (item['t'] == 's') {
        _currentRefs.add(Duration(milliseconds: item['ms'] as int));
      }
    }
    // Register restored refs in _processedFiles so consumeSafeToDeletePaths()
    // can return their segment paths once the conversation ends and refs are cleared.
    for (final item in _currentRefs) {
      if (item is FrameRef) _processedFiles.add(item.segmentFile.path);
    }
    _speechFrameCount = s['sfc'] as int;
    final rstMs = s['rst'] as int?;
    _recordingStartTime = rstMs != null ? DateTime.fromMillisecondsSinceEpoch(rstMs, isUtc: true) : null;
    final lseMs = s['lse'] as int?;
    _lastSegmentEndTime = lseMs != null ? DateTime.fromMillisecondsSinceEpoch(lseMs, isUtc: true) : null;
    _isDerivedTimestamp = s['idt'] as bool;
    _currentSessionId = s['csi'] as int?;
    _currentStartUptime = s['csu'] as int?;
    _currentFrameUptimeMs = s['cfu'] as int?;
    _lastImuTicks = s['lit'] as int?;
    _currentChunkDurationMs = s['ccd'] as int;
    _silenceRunMs = s['srm'] as int;
    _currentMaxVoiceProb = (s['cmv'] as num).toDouble();
    _forcedByMarker = s['fbm'] as bool;
    _markerProtectedUntilMs = s['mpu'] as int?;
    _sessionEndPendingResume = s['sep'] as bool;
    _muted = (s['mtd'] as bool?) ?? false;
    _muteStartMs = s['mts'] as int?;
    _pendingMarkers.clear();
    for (final m in (s['pm'] as List).cast<Map<String, dynamic>>()) {
      _pendingMarkers.add((markerMs: m['ms'] as int, offsetAtMarkerMs: m['o'] as int));
    }
    final vsRaw = s['vs'] as List?;
    if (vsRaw != null && _session != null) {
      final vsFloats = Float32List.fromList(vsRaw.cast<num>().map((n) => n.toDouble()).toList());
      _cachedStateValue?.dispose();
      _cachedStateValue = await OrtValue.fromList(vsFloats, [2, 1, 128]);
    }
    final vcRaw = (s['vc'] as List).cast<num>();
    for (int i = 0; i < _vadContextSamples && i < vcRaw.length; i++) {
      _vadContext[i] = vcRaw[i].toDouble();
    }
    final pbRaw = (s['pb'] as List).cast<num>();
    _pcmBufferLen = s['pbl'] as int;
    for (int i = 0; i < _pcmBufferLen && i < pbRaw.length; i++) {
      _pcmBuffer[i] = pbRaw[i].toDouble();
    }
  }

  bool get isCapturing => (_currentRefs.isNotEmpty && _speechFrameCount > 0) || _forcedByMarker;

  /// The wall-clock (epoch ms) the marker guaranteed-save window extends to, or
  /// null when no window is active. Exposed for tests that verify a hard boundary
  /// (mute / manual-stop) ends the window rather than leaking it past unmute.
  @visibleForTesting
  int? get markerProtectedUntilMs => _markerProtectedUntilMs;

  // VAD timing instrumentation (debug-log only; gated by the dev-logs pref via
  // Logger.debug). Accumulates wall-clock across each inference's three awaited
  // platform-channel steps and emits an average every _vadTimingLogInterval
  // runs. `create` and `read` do ~zero native compute, so their time is a proxy
  // for the per-call channel-hop floor; `run` is that hop plus the actual ONNX
  // compute. If create+read ≈ run, the platform channel dominates (→ a native
  // batch runner, lever #2, is the real win); if run ≫ create+read, compute
  // dominates (→ XNNPACK/quantisation matter more). Flip the const to false to
  // compile the Stopwatch out entirely.
  static const bool _vadTimingEnabled = true;
  static const int _vadTimingLogInterval = 2000; // ~64 s of audio per summary
  int _vadRunCount = 0;
  int _vadCreateUs = 0;
  int _vadRunUs = 0;
  int _vadReadUs = 0;

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
    final sw = _vadTimingEnabled ? (Stopwatch()..start()) : null;
    final inputTensor = await OrtValue.fromList(_windowedInputBuffer, [1, _vadContextSamples + _vadWindowSamples]);
    if (sw != null) {
      _vadCreateUs += sw.elapsedMicroseconds;
      sw.reset();
    }

    final inputs = <String, OrtValue>{
      'input': inputTensor,
      'state': _cachedStateValue!,
      'sr': _cachedSrValue!,
    };

    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run(inputs);
      if (sw != null) {
        _vadRunUs += sw.elapsedMicroseconds;
        sw.reset();
      }
      // Silero v5+ ONNX outputs: 'output' (prob), 'stateN' (recurrent state).
      final prob = ((await outputs['output']!.asFlattenedList()).cast<double>())[0];
      if (sw != null) {
        _vadReadUs += sw.elapsedMicroseconds;
        if (++_vadRunCount % _vadTimingLogInterval == 0) {
          final n = _vadRunCount;
          Logger.debug('VadAudioProcessor: VAD per-inference avg over $n runs — '
              'create ${(_vadCreateUs / n / 1000).toStringAsFixed(3)}ms, '
              'run ${(_vadRunUs / n / 1000).toStringAsFixed(3)}ms, '
              'read ${(_vadReadUs / n / 1000).toStringAsFixed(3)}ms '
              '(channel floor ≈ create+read ${((_vadCreateUs + _vadReadUs) / n / 1000).toStringAsFixed(3)}ms)');
        }
      }
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

  /// [byteRanges], when set, restricts decoding to the listed DISJOINT
  /// `[startByte, endByte)` slices of the bin (sorted, non-overlapping) instead
  /// of the whole file — frames in the gaps between slices are skipped, not
  /// decoded. Used by Recover Discard to re-derive ONLY the discarded
  /// stretch(es), never the un-discarded audio that shares the bin (the slice
  /// starts mid-bin, so the caller supplies the correct anchor [segmentStartTime]
  /// and the bin header is NOT used to re-anchor). Null/empty ⇒ whole-file
  /// (unchanged).
  Future<List<String>> processSegmentFile(File segmentFile, DateTime segmentStartTime,
      {int startUptimeMs = 0, bool isDerivedTimestamp = false, int? sessionId, List<List<int>>? byteRanges}) async {
    final List<List<int>> sliceRanges = byteRanges ?? const [];
    final bool sliced = sliceRanges.isNotEmpty;
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

        if (sliced) {
          // Byte-slice recover: the slice starts mid-bin, so the header's start
          // time is NOT this slice's start — keep the caller's anchor. Still
          // adopt the bin's session id for the recovered recording's meta.
          sessionId = sessionIdInHeader;
        } else if (utcStartMs > 946684800000) {
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

        // If we were muted (mute-on seen, no mute-off) and the session changed,
        // the device powered off while muted — `is_muted` never survives a reboot,
        // so the new session is effectively the unmute. Close the muted interval
        // at the new session's start (an upper bound on the unmute time).
        if (_muted && sessionChanged) {
          _emitMutedDiscard(segmentStartTime.millisecondsSinceEpoch);
        }

        // A session change means a brand-new recording session — the device
        // rebooted (or started a fresh session) and CHOSE to record again (its
        // persisted threshold governs that, not us). Any manual-stop (0xFFFFFFFC)
        // or mute-on (0xFFFFFFFA) skip latched in the PREVIOUS session is stale,
        // so clear it; otherwise the new session's frames are silently dropped at
        // the per-frame skip below. (`_currentSessionId` is persisted across runs,
        // so this also catches a reboot that happened between sync passes.)
        if (sessionChanged && _sessionEndPendingResume) {
          Logger.debug('VadAudioProcessor: New session after stop/mute — honoring its audio '
              '(was $_currentSessionId, now $sessionId).');
          _sessionEndPendingResume = false;
        }

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
          // TWO-PASS: flush any deferred batch before the inter-file split.
          if (_useBatchRunner && _batchDeferredFrames.isNotEmpty) {
            segmentSpeechFrames =
                await _flushVadBatch(savedFiles: savedFiles, segmentSpeechFrames: segmentSpeechFrames);
          }
          await _flushPartialWindow();
          _cachedStateValue?.dispose();
          _cachedStateValue = null;
          _vadContext.fillRange(0, _vadContextSamples, 0.0);
          _batchResetPending = true;
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
          // Never pad during a byte-slice recover: consecutive firmware bins carry
          // no real inter-file gap, so any "gap" here is an anchor artifact — the
          // recovered clip must stay equal to the recorded frames (== audioMs).
          if (!sliced && _currentRefs.isNotEmpty && !isClockJump && (gapMs >= 10000 || imuGapMatches)) {
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

      // Byte-slice recover: decode only the discarded slices. Start at the first
      // slice (past the header) and stop after the last; frames in the gaps
      // between slices belong to recordings that already own them and must not
      // be re-derived here.
      int rangeIdx = 0;
      if (sliced) offset = sliceRanges.first[0];
      final int decodeUntil =
          sliced ? (sliceRanges.last[1] < fileLength ? sliceRanges.last[1] : fileLength) : fileLength;

      if (sliced) {
        final spanBytes = sliceRanges.fold<int>(0, (s, r) => s + (r[1] - r[0]));
        Logger.debug('VadAudioProcessor: byte-slice recover ${segmentFile.path.split('/').last} — '
            '${sliceRanges.length} interval(s), decoding $spanBytes of $fileLength B, ranges=$sliceRanges');
      }

      while (offset < decodeUntil) {
        // Jump the read head over the gap between disjoint recover slices so the
        // un-discarded audio sitting between two noise stretches is skipped.
        if (sliced) {
          while (rangeIdx < sliceRanges.length && offset >= sliceRanges[rangeIdx][1]) {
            rangeIdx++;
          }
          if (rangeIdx >= sliceRanges.length) break;
          if (offset < sliceRanges[rangeIdx][0]) offset = sliceRanges[rangeIdx][0];
        }
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
            if (markerUtcMs > 946684800000) {
              // Always use the marker's own RTC for the protection window. This
              // ensures that if a marker wakes the device after a long silence,
              // the subsequent VAD-resume packet (which will have a similar UTC)
              // is correctly caught by the protection window, even if the audio
              // timeline is currently stale (drifts from RTC) and markerFrameTime
              // was capped by the drift limit.
              _markerProtectedUntilMs = markerUtcMs + _markerProtectionWindowMs;
            } else if (markerMs > 946684800000) {
              // Fallback for pre-time-sync devices: use the derived wall-clock.
              _markerProtectedUntilMs = markerMs + _markerProtectionWindowMs;
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
            // TWO-PASS: flush any deferred batch before finalizing.
            if (_useBatchRunner && _batchDeferredFrames.isNotEmpty) {
              segmentSpeechFrames =
                  await _flushVadBatch(savedFiles: savedFiles, segmentSpeechFrames: segmentSpeechFrames);
            }
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
            // Manual-mode stop is a hard end, not a silence/file split: the
            // protected recording is finalized and the tap consumed, so the
            // guaranteed-save window is done. Clear it so a tap-then-stop-then-
            // restart inside the original 50 s doesn't force-promote noise.
            _markerProtectedUntilMs = null;
            _pcmBufferLen = 0;
            _cachedStateValue?.dispose();
            _cachedStateValue = null;
            _vadContext.fillRange(0, _vadContextSamples, 0.0);
            _batchResetPending = true;
          }
          offset += 20;
          continue;
        }

        // Mute-on marker (0xFFFFFFFA, 20 bytes). Finalize the current recording at
        // this boundary (like session-end) and open a muted interval — nothing
        // records until the matching mute-off or a new session.
        if (frameLength == 0xFFFFFFFA) {
          if (offset + 20 <= fileLength) {
            final markerUtcMs = byteData.getUint64(offset + 4, Endian.little);
            final muteMs = markerUtcMs > 946684800000 ? markerUtcMs : lastFrameWallTime.millisecondsSinceEpoch;
            // TWO-PASS: flush any deferred batch before finalizing.
            if (_useBatchRunner && _batchDeferredFrames.isNotEmpty) {
              segmentSpeechFrames =
                  await _flushVadBatch(savedFiles: savedFiles, segmentSpeechFrames: segmentSpeechFrames);
            }
            if (_currentRefs.isNotEmpty) {
              _forcedByMarker = true;
              final filePath = await flushRemaining(isDraft: false);
              if (filePath != null) savedFiles.add(filePath);
            } else {
              _emitOrphanMarkers();
            }
            _muted = true;
            _muteStartMs = muteMs;
            _sessionEndPendingResume = true;
            // The mute boundary closed and saved the marker-protected recording
            // and consumed its tap, so the guaranteed-save window has nothing left
            // to guard. Clear it (matching _emitOrphanMarkers) so a quick unmute
            // inside the original 50 s doesn't force-promote marker-less noise.
            // (Silence/file-split self-expiry still relies on _resetState keeping it.)
            _markerProtectedUntilMs = null;
            _pcmBufferLen = 0;
            _cachedStateValue?.dispose();
            _cachedStateValue = null;
            _vadContext.fillRange(0, _vadContextSamples, 0.0);
            _batchResetPending = true;
            Logger.debug('VadAudioProcessor: Mute-on marker — muted interval opened at $muteMs.');
          }
          offset += 20;
          continue;
        }

        // Mute-off marker (0xFFFFFFF9, 20 bytes). Close the muted interval and
        // emit it as a "muted" ghost row.
        if (frameLength == 0xFFFFFFF9) {
          _sessionEndPendingResume = false;
          if (offset + 20 <= fileLength) {
            final markerUtcMs = byteData.getUint64(offset + 4, Endian.little);
            final endMs = markerUtcMs > 946684800000 ? markerUtcMs : lastFrameWallTime.millisecondsSinceEpoch;
            _emitMutedDiscard(endMs);
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

            final bool withinMarkerWindow =
                _markerProtectedUntilMs != null && newResumeTime.millisecondsSinceEpoch <= _markerProtectedUntilMs!;

            final bool wouldSplit =
                !withinMarkerWindow && gapMs >= max(0, _silenceDurationToSplitMs - _firmwareVadHoldMs) && !isClockJump;

            // AAD flood guard: a bogus large gap (clock-anchor mismatch) on every
            // resume marker would spray a flood of tiny junk recordings. While
            // Silero is unavailable, latch into coalesce mode after a run of tiny
            // splits so further resume markers stitch onto one recording instead
            // of splitting (no pad, no re-anchor — see below).
            final bool floodCoalesce = wouldSplit &&
                _session == null &&
                aadFloodStep(closingMs: _currentChunkDurationMs, hasRefs: _currentRefs.isNotEmpty);

            if (wouldSplit && !floodCoalesce) {
              // Gap exceeds threshold — flush current recording, start new conversation.
              // TWO-PASS: flush any deferred batch before the split decision.
              if (_useBatchRunner && _batchDeferredFrames.isNotEmpty) {
                segmentSpeechFrames =
                    await _flushVadBatch(savedFiles: savedFiles, segmentSpeechFrames: segmentSpeechFrames);
              }
              await _flushPartialWindow();
              final speechMs = _speechFrameCount * frameDurationMs;
              final bool tooShortSpeech =
                  _session != null && _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

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
              _recordingStartTime = newResumeTime;
              _pcmBufferLen = 0;
              // ignore: unawaited_futures, discarded_futures
              _cachedStateValue?.dispose();
              _cachedStateValue = null;
              _vadContext.fillRange(0, _vadContextSamples, 0.0);
              _batchResetPending = true;
              Logger.debug('VadAudioProcessor: VAD resume — gap ${gapMs}ms >= threshold, new conversation.');
            } else {
              // Gap within threshold or clock jump — stitch, padding with silence so playback reflects real timing.
              // In flood-coalesce the gap is bogus (that's the pathology), so never pad it.
              // In a byte-slice recover the discard's recorded duration excluded this
              // padding, so re-deriving it must not pad either — otherwise a 24 s
              // discard recovers as minutes of phantom silence.
              if (!floodCoalesce && !sliced && _currentRefs.isNotEmpty && gapMs > 0 && !isClockJump) {
                _currentRefs.add(Duration(milliseconds: gapMs));
                _currentChunkDurationMs += gapMs;
              }
              Logger.debug('VadAudioProcessor: VAD resume — gap ${gapMs}ms '
                  '${floodCoalesce ? "(AAD flood — coalescing)" : isClockJump ? "(CLOCK JUMP)" : "< threshold"}, stitching.');
            }

            // Update anchors for subsequent frame calculations. In flood-coalesce
            // the resume time is bogus, so keep the existing real frame timeline.
            if (!floodCoalesce) {
              vadResumeTime = newResumeTime;
              vadResumeFrameIndex = frameIndex;
            }
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

        // In AAD mode (no Silero session), every frame is speech by definition —
        // counting only window-boundary frames (~12.5% of Opus frames) would
        // severely undercount speechMs and trigger false noise discards.
        bool isSpeech = _session == null;
        if (pcmData != null) {
          for (int s = 0; s < pcmData.length; s++) {
            final sample = pcmData[s] / 32768.0;
            if (sample.abs() > segmentMaxAmp) segmentMaxAmp = sample.abs();
            if (_session != null) {
              _pcmBuffer[_pcmBufferLen++] = sample;
              // Drain the moment a full window is buffered. Doing this inline —
              // rather than appending the whole frame then draining — keeps
              // _pcmBufferLen bounded at _vadWindowSamples no matter how many
              // samples the decoder returned, so an oversized frame can never
              // overrun the fixed buffer.
              if (_pcmBufferLen == _vadWindowSamples) {
                if (_useBatchRunner) {
                  // TWO-PASS: collect window into batch buffer; defer VAD to Pass 2.
                  final windowCopy = Float32List(_vadWindowSamples);
                  windowCopy.setAll(0, Float32List.sublistView(_pcmBuffer, 0, _vadWindowSamples));
                  _batchWindows.add(windowCopy);
                  _batchWindowFrameIndices.add(_batchDeferredFrames.length);
                } else {
                  // SINGLE-PASS (fallback): run VAD inline per window.
                  // Zero-copy view: _runVad copies it into its pre-allocated input
                  // buffer synchronously before any await, so resetting the length
                  // below is safe even though the view aliases _pcmBuffer.
                  if (await _runVad(Float32List.sublistView(_pcmBuffer, 0, _vadWindowSamples))) isSpeech = true;
                }
                _pcmBufferLen = 0;
              }
            }
          }
        }

        // Align with firmware: force speech status if within marker protection window
        if (_markerProtectedUntilMs != null && lastFrameWallTime.millisecondsSinceEpoch <= _markerProtectedUntilMs!) {
          isSpeech = true;
        }

        final frameRef = FrameRef(segmentFile: segmentFile, byteOffset: offset, frameLength: frameLength);

        // Compute accurate wall-clock time for this frame using VAD-resume anchor if available.
        final frameTime = (vadResumeTime != null && vadResumeFrameIndex != null)
            ? vadResumeTime.add(Duration(milliseconds: (frameIndex - vadResumeFrameIndex) * frameDurationMs))
            : segmentStartTime.add(Duration(milliseconds: frameIndex * frameDurationMs));
        lastFrameWallTime = frameTime;
        if (_currentFrameUptimeMs != null) _currentFrameUptimeMs = _currentFrameUptimeMs! + frameDurationMs;

        if (_useBatchRunner) {
          // TWO-PASS: defer verdict — accumulate frame metadata for Pass 2 replay.
          _batchDeferredFrames.add(_DeferredFrame(
            ref: frameRef,
            frameTime: frameTime,
            markerProtected: isSpeech, // includes AAD-mode and marker-protected speech
          ));

          // DYNAMIC BATCH LIMIT: Flush early to prevent MethodChannel OOMs on
          // continuous background noise (limit to 120s of audio / 6000 frames per batch).
          if (_batchDeferredFrames.length >= 6000) {
            segmentSpeechFrames = await _flushVadBatch(
              savedFiles: savedFiles,
              segmentSpeechFrames: segmentSpeechFrames,
            );
          }
        } else {
          // SINGLE-PASS: apply verdict inline (original path).
          final verdictResult = await _applyVadVerdict(
            isSpeech: isSpeech,
            frameRef: frameRef,
            frameTime: frameTime,
            savedFiles: savedFiles,
            segmentSpeechFrames: segmentSpeechFrames,
          );
          segmentSpeechFrames = verdictResult.segmentSpeechFrames;
          if (verdictResult.splitFired) {
            offset += 4 + ((frameLength + 3) & ~3);
            frameIndex++;
            totalFrameCount++;
            continue;
          }
        }

        offset += 4 + ((frameLength + 3) & ~3); // advance past 4-byte-aligned frame (matches SD card wire format)
        frameIndex++;
        totalFrameCount++;
      }

      // TWO-PASS: flush any remaining batch at segment end.
      if (_batchDeferredFrames.isNotEmpty) {
        segmentSpeechFrames = await _flushVadBatch(savedFiles: savedFiles, segmentSpeechFrames: segmentSpeechFrames);
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
  /// [_silenceDurationToSplitMs] of continuous non-speech. The entire buffer —
  /// including the trailing silence that triggered the split — is saved as the
  /// conversation (or discarded if the speech is below the minimum). Pure-silence
  /// runs with no speech yet are trashed wholesale so the buffer can't grow
  /// unbounded. Leaves state reset so the next speech frame starts a fresh
  /// conversation.
  Future<void> _splitOnSilence(List<String> savedFiles) async {
    await _flushPartialWindow();
    if (_speechFrameCount > 0) {
      final speechMs = _speechFrameCount * frameDurationMs;
      final tooShort = _session != null && _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;
      if (tooShort) {
        final rec = _buildDiscardRecord('noise_silence_split');
        if (rec != null) _pendingDiscards.add(rec);
        _emitOrphanMarkers();
        Logger.debug('VadAudioProcessor: Silence split — discarding ${speechMs}ms low-speech chunk.');
      } else {
        final filePath = await _saveRecording(_currentRefs, _recordingStartTime!);
        if (filePath == null) {
          _emitOrphanMarkers();
        } else {
          savedFiles.add(filePath);
        }
        Logger.debug(
            'VadAudioProcessor: Silence split — saved ${_currentChunkDurationMs}ms recording (including trailing silence).');
      }
    } else {
      // No speech yet — the whole buffer is silence. Trash it (bins recoverable).
      final rec = _buildDiscardRecord('silence_only');
      if (rec != null) _pendingDiscards.add(rec);
      _emitOrphanMarkers();
      Logger.debug('VadAudioProcessor: Trashing ${_currentChunkDurationMs}ms of speechless silence.');
    }

    _resetState();
  }

  /// One AAD-flood-guard transition for a resume-split decision. Called only
  /// when a split would otherwise fire and Silero is unavailable. [closingMs] is
  /// the duration of the recording the split would close; [hasRefs] whether any
  /// audio is buffered. Counts consecutive tiny (< [_aadFloodSplitFloorMs])
  /// splits and, once [_aadFloodRunThreshold] occur in a row, latches flood mode
  /// and returns true so the caller coalesces instead of splitting. A lone short
  /// recording (run not reached) still splits. The latch clears at the next real
  /// boundary via [_resetState].
  @visibleForTesting
  bool aadFloodStep({required int closingMs, required bool hasRefs}) {
    if (!_aadFloodActive) {
      if (hasRefs && closingMs < _aadFloodSplitFloorMs) {
        if (++_consecutiveTinyAadSplits >= _aadFloodRunThreshold) {
          _aadFloodActive = true;
          Logger.error('VadAudioProcessor: AAD resume-split flood detected '
              '($_consecutiveTinyAadSplits consecutive <${_aadFloodSplitFloorMs}ms splits, Silero '
              'unavailable) — coalescing further resume markers onto one recording until the next boundary.');
        }
      } else {
        _consecutiveTinyAadSplits = 0;
      }
    }
    return _aadFloodActive;
  }

  @visibleForTesting
  bool get aadFloodActive => _aadFloodActive;

  @visibleForTesting
  void resetStateForTest() => _resetState();

  Future<String?> flushRemaining({bool isDraft = false}) async {
    await _flushPartialWindow();
    final speechMs = _speechFrameCount * frameDurationMs;
    final bool tooShortSpeech = _session != null && _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

    if (_currentRefs.isEmpty || tooShortSpeech) {
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
    // A real conversation boundary (flushRemaining / silence split) ends any AAD
    // flood, so clear the latch — the next conversation splits normally. The
    // early tiny splits that build the run use inline resets (not _resetState),
    // so the counter survives those and only clears at a genuine boundary.
    _consecutiveTinyAadSplits = 0;
    _aadFloodActive = false;
    // Reset VAD model state so the next conversation starts with a clean LSTM.
    // Not resetting these contaminates the first few VAD decisions of the new
    // conversation with the previous conversation's recurrent state.
    _pcmBufferLen = 0;
    // ignore: unawaited_futures, discarded_futures
    _cachedStateValue?.dispose();
    _cachedStateValue = null;
    _vadContext.fillRange(0, _vadContextSamples, 0.0);
    _batchResetPending = true;
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
  /// VAD pass at a conversation boundary so the tail window contributes to
  /// [_currentMaxVoiceProb] (surfaced in discard records) and the VAD recurrent
  /// state stays consistent. The speech verdict itself is not consumed — the
  /// full buffer is saved regardless of where the last speech frame landed.
  ///
  /// Must be called — with the current LSTM state intact — immediately before
  /// any [_resetState] call or inline state reset. Is a no-op when the buffer
  /// is empty or no Silero session is loaded (AAD mode), and is skipped during
  /// batch replay (the native runner's LSTM state has already advanced past
  /// this point, so it can't be evaluated with the correct recurrent context).
  Future<void> _flushPartialWindow() async {
    if (_pcmBufferLen == 0) return;
    if (_isReplayingBatch) return;
    if (_session == null) return;

    final padded = Float32List(_vadWindowSamples);
    padded.setRange(0, _pcmBufferLen, _pcmBuffer);
    // Remainder is already zero — Float32List default.
    if (_useBatchRunner) {
      try {
        final probs = await _batchRunner!.runVadBatch(padded, resetStateFirst: _batchResetPending);
        _batchResetPending = false;
        if (probs.isNotEmpty && probs[0] > _currentMaxVoiceProb) _currentMaxVoiceProb = probs[0];
      } catch (e) {
        // Per-window fallback (see _flushVadBatch): score this single padded window
        // through the independent Dart _session instead of disabling VAD for the
        // rest of the run. This is exactly what the single-pass path does below.
        // _runVad updates _currentMaxVoiceProb internally.
        Logger.error('VadAudioProcessor: _flushPartialWindow batch runner failed ($e) — per-window fallback');
        await _runVad(padded);
        _batchResetPending = true;
      }
    } else {
      // _runVad updates _currentMaxVoiceProb internally.
      await _runVad(padded);
    }
  }

  /// Unified verdict application — the single place where per-frame speech /
  /// silence tracking, silence-split, and max-cap logic lives.
  ///
  /// Called inline by the single-pass fallback path (iOS / desktop / tests) and
  /// in the Pass-2 replay loop by the batched Android path. Both paths supply
  /// the same inputs; only *when* the VAD probability was computed differs.
  ///
  /// Returns [_VadVerdictResult] so the caller can update local counters and
  /// react to splits (the single-pass path needs to `continue` the while loop).
  Future<_VadVerdictResult> _applyVadVerdict({
    required bool isSpeech,
    required FrameRef frameRef,
    required DateTime frameTime,
    required List<String> savedFiles,
    required int segmentSpeechFrames,
  }) async {
    bool splitFired = false;

    if (isSpeech) {
      _speechFrameCount++;
      segmentSpeechFrames++;
      _silenceRunMs = 0;
    } else {
      _silenceRunMs += frameDurationMs;
    }
    _currentRefs.add(frameRef);
    _currentChunkDurationMs += frameDurationMs;

    // Anchor a fresh conversation to THIS frame's wall-clock time. After an
    // in-stream silence split, _splitOnSilence resets _recordingStartTime to
    // null mid-file; anchoring to segmentStartTime / vadResumeTime here would
    // back-date the new conversation to the start of the file (or the resume
    // point), stacking it on top of the chunk just split off and producing
    // overlapping records with identical timestamps. frameTime is the correct
    // per-frame wall clock and advances monotonically across splits.
    _recordingStartTime ??= frameTime;

    // App-side silence split. The firmware only emits a 0xFFFFFFFD gap once
    // its own AAD has gone quiet long enough; in a continuous-audio
    // environment that gap may never reach the split threshold, so the
    // whole stream stitches into one unbounded conversation that never
    // finalizes. Independently cut here once the Silero VAD has seen
    // _silenceDurationToSplitMs of continuous non-speech.
    if (_silenceRunMs >= _silenceDurationToSplitMs) {
      await _splitOnSilence(savedFiles);
      splitFired = true;
      return _VadVerdictResult(segmentSpeechFrames: segmentSpeechFrames, splitFired: splitFired);
    }

    // Max conversation duration cap (0 / disabled by default).
    if (_currentChunkDurationMs >= _maxChunkMs) {
      Logger.debug('VadAudioProcessor: Max conversation duration — forcing cut.');
      await _flushPartialWindow();
      final speechMs = _speechFrameCount * frameDurationMs;
      final bool tooShortSpeech = _session != null && _minSpeechMs > 0 && speechMs < _minSpeechMs && !_forcedByMarker;

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
      _recordingStartTime = cutTime;
      if (!_isReplayingBatch) {
        _pcmBufferLen = 0;
      }
      // ignore: unawaited_futures, discarded_futures
      _cachedStateValue?.dispose();
      _cachedStateValue = null;
      _vadContext.fillRange(0, _vadContextSamples, 0.0);
      _batchResetPending = true;
    }

    return _VadVerdictResult(segmentSpeechFrames: segmentSpeechFrames, splitFired: splitFired);
  }

  bool _isReplayingBatch = false;

  /// Pass 2 of the batched VAD path: sends all accumulated windows to the
  /// native batch runner in one call, then replays the returned probabilities
  /// against the deferred frame metadata via [_applyVadVerdict].
  ///
  /// Called at segment-end and at every state-reset boundary (session-end,
  /// VAD-resume gap split, inter-file split) so a batch never spans a
  /// conversation boundary.
  Future<int> _flushVadBatch({
    required List<String> savedFiles,
    required int segmentSpeechFrames,
  }) async {
    if (_batchDeferredFrames.isEmpty) return segmentSpeechFrames;

    _isReplayingBatch = true;
    try {
      // If the model was disabled (e.g. from a prior ML failure), AAD mode is active.
      // Treat all deferred frames as speech to avoid data loss.
      final bool aadMode = _session == null;
      final frameSpeechFlags = List<bool>.filled(_batchDeferredFrames.length, aadMode);

      if (!aadMode && _batchWindows.isNotEmpty && _batchRunner != null && _batchRunner!.available) {
        try {
          final stopwatch = Stopwatch()..start();
          final samples = Float32List(_batchWindows.length * _vadWindowSamples);
          int offset = 0;
          for (final w in _batchWindows) {
            samples.setAll(offset, w);
            offset += _vadWindowSamples;
          }
          final probs = await _batchRunner!.runVadBatch(samples, resetStateFirst: _batchResetPending);
          stopwatch.stop();
          Logger.debug(
              'VadAudioProcessor: batch runner evaluated ${probs.length} windows (${samples.length} samples) in ${stopwatch.elapsedMilliseconds}ms.');

          _batchResetPending = false;
          // Map each window's prob back to the frame that triggered it.
          for (int w = 0; w < probs.length && w < _batchWindowFrameIndices.length; w++) {
            final prob = probs[w];
            if (prob > _currentMaxVoiceProb) _currentMaxVoiceProb = prob;
            if (prob > _speechThreshold) {
              frameSpeechFlags[_batchWindowFrameIndices[w]] = true;
            }
          }
        } catch (e) {
          // The native batch channel failed (e.g. a transient timeout or channel
          // hiccup). Rather than disabling VAD for the rest of the run, fall back to
          // per-window inference for THIS batch only and keep the runner + session
          // alive for subsequent batches. _runVad scores through the Dart-side
          // _session, which is independent of the native batch channel; it tracks
          // _currentMaxVoiceProb and, if that session is *also* broken, nulls itself
          // and returns true (AAD) — so the keep-everything safety net is preserved
          // for the both-broken worst case. _runVad re-inits its LSTM state lazily
          // (cold-start) and then carries it window-to-window like single-pass mode.
          Logger.error('VadAudioProcessor: batch runner failed ($e) — per-window fallback for this batch');
          for (int w = 0; w < _batchWindows.length && w < _batchWindowFrameIndices.length; w++) {
            if (await _runVad(_batchWindows[w])) {
              frameSpeechFlags[_batchWindowFrameIndices[w]] = true;
            }
          }
          // The native runner (if it recovers next batch) never saw this batch's
          // audio, so force a clean state reset rather than letting it resume from
          // stale state — a bounded cold-start beats content-dependent drift.
          _batchResetPending = true;
        }
      }

      // Replay verdicts in frame order through the shared _applyVadVerdict.
      //
      // KNOWN DIVERGENCE FROM THE SINGLE-PASS PATH (intentional, accepted):
      // the whole batch was scored by the native runner in one continuous-state
      // pass, so if a verdict below fires an in-batch boundary (silence-split or
      // max-cap), the frames *after* that boundary in this same batch were already
      // scored with the pre-boundary LSTM state — the single-pass path would have
      // zeroed the state at the cut. Effect is sub-100 ms: a silence-split only
      // fires after _silenceDurationToSplitMs of quiet, so the carried-over state
      // is silence-saturated, and only the first ~1-3 windows of the next
      // conversation are slightly under-scored before Silero re-converges. A kept
      // conversation needs _minSpeechMs (default 3 s) anyway, so those boundary
      // frames don't change the outcome. _batchResetPending is set true at the
      // boundary so the *next* runVadBatch call correctly starts from zeroed state.
      for (int f = 0; f < _batchDeferredFrames.length; f++) {
        final df = _batchDeferredFrames[f];
        // isSpeech = marker-protected (set during Pass 1) OR VAD detected speech
        final isSpeech = df.markerProtected || frameSpeechFlags[f];
        final verdictResult = await _applyVadVerdict(
          isSpeech: isSpeech,
          frameRef: df.ref,
          frameTime: df.frameTime,
          savedFiles: savedFiles,
          segmentSpeechFrames: segmentSpeechFrames,
        );
        segmentSpeechFrames = verdictResult.segmentSpeechFrames;
        // splitFired is handled inside _applyVadVerdict (calls _splitOnSilence
        // or resets state); no outer loop to `continue` from here.
      }

      return segmentSpeechFrames;
    } finally {
      _isReplayingBatch = false;
      // Clear batch buffers for the next batch boundary.
      _batchDeferredFrames.clear();
      _batchWindows.clear();
      _batchWindowFrameIndices.clear();
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
      bins.add(relBinPath(item.segmentFile.path));
    }
    return bins;
  }

  /// The `<folder>/<file>.bin` tail used to reference a source bin in a
  /// recording's `.meta` (and discards). The path-keyed consumers resolve it
  /// under `<docs>/raw_segments/<rel>` OR `<docs>/discarded_segments/<rel>` (a
  /// fully-processed discard bin is relocated to the latter, and Recover feeds
  /// it back through the processor from there), so the tail must be exactly the
  /// part after whichever of those two folders the path sits under.
  ///
  /// Prefers the substring after the LAST `/raw_segments/` or
  /// `/discarded_segments/` (handles `\` on the off chance the platform uses it,
  /// and an unexpectedly nested path). If the ref somehow isn't under either
  /// folder, falls back to the last two path components rather than dropping the
  /// ref — dropping it produced an EMPTY bin list, which silently made the
  /// recording un-mergeable ("lists no source segments"). A best-effort tail at
  /// least keeps the reference and surfaces the real location in the diagnostic.
  @visibleForTesting
  static String relBinPath(String path) {
    final norm = path.replaceAll('\\', '/');
    // A bin claimed by a discard is relocated to `discarded_segments/`; Recover
    // feeds it back through the processor from there, so accept either folder.
    for (final marker in const ['/raw_segments/', '/discarded_segments/']) {
      final i = norm.lastIndexOf(marker);
      if (i >= 0) return norm.substring(i + marker.length);
    }
    final comps = norm.split('/').where((c) => c.isNotEmpty).toList();
    return comps.length >= 2 ? '${comps[comps.length - 2]}/${comps.last}' : norm;
  }

  /// The device session id derived from the bins a recording owns — bins are
  /// named `<timerStart>_<sessionId>.bin`, so the session of the audio is
  /// authoritative. Returns the first parseable non-zero id, or null if none.
  /// Used to stamp a consistent session id in the `.meta` even when the runtime
  /// `_currentSessionId` was reset across a stitch (which used to write 0 there,
  /// hiding the recording from the orphan-bin sweep).
  @visibleForTesting
  static int? sessionIdFromRefs(Iterable<Object> refs) {
    for (final r in refs) {
      if (r is! FrameRef) continue;
      final file = relBinPath(r.segmentFile.path).split('/').last; // <timerStart>_<sessionId>.bin
      final base = file.contains('.') ? file.substring(0, file.indexOf('.')) : file;
      final parts = base.split('_');
      if (parts.length >= 2) {
        final sid = int.tryParse(parts[1]);
        if (sid != null && sid != 0) return sid;
      }
    }
    return null;
  }

  Map<String, dynamic>? _buildDiscardRecord(String reason) =>
      _buildDiscardRecordFor(_currentRefs, _recordingStartTime, _currentChunkDurationMs, reason);

  /// Closes the open muted interval at [endMs] and queues it as a "muted" discard
  /// (ghost row). Has no bins — nothing recorded while muted — so it is not
  /// recoverable, only deletable. No-op if no interval is open or the span is empty.
  void _emitMutedDiscard(int endMs) {
    final startMs = _muteStartMs;
    _muted = false;
    _muteStartMs = null;
    if (startMs == null || endMs <= startMs) return;
    _pendingDiscards.add({
      'startMs': startMs,
      'endMs': endMs,
      'reason': 'muted',
      'maxVoiceProb': 0.0,
      'relativeBins': <String>[],
    });
    Logger.debug('VadAudioProcessor: Muted interval $startMs–$endMs emitted as ghost.');
  }

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
    // Byte span each bin contributed to this discard, keyed by the same <rel>
    // tail as relativeBins. Lets Recover reprocess ONLY the discarded slice
    // instead of the whole ~5-min bin — which, when the bin straddles a neighbor
    // recording (the routine case), would re-derive that neighbor's audio into
    // an overlapping/oversized recovered recording. relativeBins stays a bare
    // path list, so every path-keyed consumer (prune, protect, sweep) is
    // unaffected; only Recover reads binRanges, and only when present.
    final binRanges = <String, List<int>>{};
    int frameCount = 0; // ACTUAL recorded frames (excludes device-asleep gap padding)
    for (final item in refs) {
      if (item is! FrameRef) continue;
      final rel = relBinPath(item.segmentFile.path);
      if (!relativeBins.contains(rel)) continue;
      frameCount++;
      final start = item.byteOffset;
      final end = item.byteOffset + 4 + ((item.frameLength + 3) & ~3); // 4-byte length prefix + aligned payload
      final cur = binRanges[rel];
      if (cur == null) {
        binRanges[rel] = [start, end];
      } else {
        if (start < cur[0]) cur[0] = start;
        if (end > cur[1]) cur[1] = end;
      }
    }
    return {
      'startMs': startTime.millisecondsSinceEpoch,
      'endMs': startTime.millisecondsSinceEpoch + durationMs,
      // Recorded-audio duration: frame count × frame duration. This is what
      // Recover produces (decoded frames, no synthetic gap padding) and what the
      // UI shows, so a discard's displayed length matches its recovered clip.
      'audioMs': frameCount * frameDurationMs,
      'reason': reason,
      'maxVoiceProb': _currentMaxVoiceProb,
      'relativeBins': relativeBins.toList(),
      'binRanges': binRanges,
    };
  }

  /// Test seam for [_buildDiscardRecordFor] — lets a test assert exactly which
  /// bins (and, once byte-range ownership lands, which sub-bin spans) a discard
  /// claims, without driving a full decode pass.
  @visibleForTesting
  Map<String, dynamic>? buildDiscardRecordForTest(List<Object> refs, DateTime? startTime, int durationMs, String reason,
          {Set<String>? excludeBins}) =>
      _buildDiscardRecordFor(refs, startTime, durationMs, reason, excludeBins: excludeBins);

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

          // Waveform for silence — O(buckets) not O(samples).
          final totalNow = currentWindowSamples + silenceSamples;
          dynamicPeaks.addAll(List.filled(totalNow ~/ windowSize, 0.0));
          currentWindowSamples = totalNow % windowSize;
          batchFrameCount += (ms / frameDurationMs).ceil();
          if (batchFrameCount >= batchFrames) await flushBatch();
          continue;
        }

        final ref = item as FrameRef;
        totalFrameRefs++;
        // Yield every 500 frames instead of 50 — readAsBytes() already yields on
        // file transitions; the finer cadence is pure overhead in a dedicated isolate.
        if (i % 500 == 0) await Future.delayed(Duration.zero);

        if (ref.segmentFile.path != currentFilePath) {
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
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
          await flushBatch(); // encodeBuffer's MethodChannel round-trip already yields
        }
      }

      await flushBatch();

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
        prefix: prefix, extension: 'm4a', suffix: suffix, capEnded: capEnded, isSilero: _session != null);

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
      {required String prefix,
      required String extension,
      String suffix = '',
      bool capEnded = false,
      required bool isSilero}) async {
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
    // Stamp the session id consistently with the bins this recording owns. The
    // runtime _currentSessionId can be null/0 after a stitch/resume; fall back to
    // the authoritative id parsed from the bin filenames so the .meta is never 0
    // when the audio plainly belongs to a session (keeps the orphan-bin sweep
    // and any session-keyed logic honest).
    final sessionIdForMeta =
        (_currentSessionId != null && _currentSessionId != 0) ? _currentSessionId! : (sessionIdFromRefs(refs) ?? 0);
    metaBytes.setUint32(408, sessionIdForMeta, Endian.little);
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
    metaOut.add(isSilero ? 1 : 0); // isSilero

    // Append relative bins used for this recording (binary length + JSON).
    // Use relBinPath() so a ref whose path doesn't contain a literal
    // '/raw_segments/' (or uses backslashes) still maps to a bin entry rather
    // than being silently dropped — an empty relativeBins makes a recording show
    // "lists no source segments".
    final relativeBins = refs.whereType<FrameRef>().map((r) => relBinPath(r.segmentFile.path)).toSet().toList()..sort();
    final frameRefCount = refs.whereType<FrameRef>().length;
    if (frameRefCount > 0 && relativeBins.isEmpty) {
      Logger.error('VadAudioProcessor: BINS-EMPTY — wrote 0 relativeBins despite $frameRefCount frame ref(s) for '
          '${prefix}_$timestamp$suffix. First ref path: ${refs.whereType<FrameRef>().first.segmentFile.path}');
    } else {
      Logger.debug('VadAudioProcessor: meta bins=${relativeBins.length} (refs=$frameRefCount) for '
          '${prefix}_$timestamp$suffix → ${relativeBins.join(', ')}');
    }
    final binsJson = jsonEncode(relativeBins);
    final binsBytes = utf8.encode(binsJson);
    final binsLen = ByteData(4)..setUint32(0, binsBytes.length, Endian.little);
    metaOut.addAll(binsLen.buffer.asUint8List());
    metaOut.addAll(binsBytes);

    await File(metaPath).writeAsBytes(metaOut);
  }

  Future<String?> _saveWav(List<Object> refs, String dateFolderPath, int timestamp,
      {String prefix = 'recording', String suffix = '', bool capEnded = false}) async {
    final wavPath = '$dateFolderPath/${prefix}_$timestamp$suffix.wav';

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

    // Pre-count samples so the WAV header can be written first, eliminating the
    // two-pass raw→WAV copy (saves 2× file-size of disk I/O). Each Opus frame at
    // 16 kHz / 20 ms decodes to exactly 320 samples — fixed by codec config.
    int estimatedSamples = 0;
    for (final item in refs) {
      if (item is Duration) {
        estimatedSamples += (item.inMilliseconds * sampleRate) ~/ 1000;
      } else {
        estimatedSamples += frameDurationMs * sampleRate ~/ 1000; // 320
      }
    }

    final wavFile = File('$wavPath.tmp');
    final sink = wavFile.openWrite();
    sink.add(_generateWavHeader(estimatedSamples * 2, sampleRate, 1));

    try {
      String? currentFilePath;
      Uint8List? currentFileBytes;
      for (var i = 0; i < refs.length; i++) {
        _onLiveness?.call();
        final item = refs[i];

        if (item is Duration) {
          final ms = item.inMilliseconds;
          final silenceSamples = (ms * sampleRate) ~/ 1000;
          sink.add(Uint8List(silenceSamples * 2)); // 16-bit mono zeros
          totalSamples += silenceSamples;
          // Replace per-sample loop with arithmetic — O(buckets) not O(samples).
          final totalNow = currentWindowSamples + silenceSamples;
          dynamicPeaks.addAll(List.filled(totalNow ~/ windowSize, 0.0));
          currentWindowSamples = totalNow % windowSize;
          continue;
        }

        final ref = item as FrameRef;
        totalFrameRefs++;
        // Yield every 500 frames instead of 50 — readAsBytes() already yields on
        // file transitions; the finer cadence is pure overhead in a dedicated isolate.
        if (i % 500 == 0) await Future.delayed(Duration.zero);

        if (ref.segmentFile.path != currentFilePath) {
          currentFileBytes = await ref.segmentFile.readAsBytes();
          currentFilePath = ref.segmentFile.path;
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

      // The header was written from a pre-count (320 samples/frame, no drops).
      // Dropped frames (readFail/decodeNull/decodeEmpty) or a frame that decodes
      // to ≠320 samples make the estimate diverge from the bytes actually written,
      // which would corrupt the WAV (data chunk over/under-declared). Patch the two
      // size fields with the real total. Skipped entirely in the common no-drop case.
      if (totalSamples != estimatedSamples) {
        final raf = await wavFile.open(mode: FileMode.append); // O_RDWR, no truncate
        try {
          final actualPcmBytes = totalSamples * 2;
          final patch = ByteData(4);
          patch.setUint32(0, 36 + actualPcmBytes, Endian.little); // RIFF chunk size @4
          await raf.setPosition(4);
          await raf.writeFrom(patch.buffer.asUint8List());
          patch.setUint32(0, actualPcmBytes, Endian.little); // data chunk size @40
          await raf.setPosition(40);
          await raf.writeFrom(patch.buffer.asUint8List());
        } finally {
          await raf.close();
        }
      }

      if (currentWindowSamples > 0) dynamicPeaks.add(currentWindowMax);

      await _saveMetadata(refs, dateFolderPath, timestamp, totalSamples, dynamicPeaks, waveformBuckets,
          prefix: prefix, extension: 'wav', suffix: suffix, capEnded: capEnded, isSilero: _session != null);

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
      if (await wavFile.exists()) await wavFile.delete();
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

/// Per-frame metadata accumulated during Pass 1 of the batched VAD path.
/// Replayed in Pass 2 after [runVadBatch] returns the window probabilities.
class _DeferredFrame {
  final FrameRef ref;
  final DateTime frameTime;

  /// True if this frame was already determined to be speech during Pass 1
  /// (AAD mode or marker protection). VAD speech from the batch is OR'd in
  /// during Pass 2.
  final bool markerProtected;

  const _DeferredFrame({
    required this.ref,
    required this.frameTime,
    required this.markerProtected,
  });
}

/// Result from [_applyVadVerdict] so the caller can update local counters
/// and react to splits.
class _VadVerdictResult {
  final int segmentSpeechFrames;
  final bool splitFired;

  const _VadVerdictResult({
    required this.segmentSpeechFrames,
    required this.splitFired,
  });
}
