import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';

/// Parameters sent to the background processing isolate. All fields must be
/// sendable across isolate boundaries (primitives, Uint8List, SendPort, etc.).
class IsolateParams {
  final SendPort sendPort;
  final RootIsolateToken rootIsolateToken;
  // Filesystem path to the Silero VAD ONNX model. Pre-copied from rootBundle
  // on the main isolate because flutter_onnxruntime's createSessionFromAsset
  // touches ServicesBinding.instance, which is unavailable in a background
  // isolate (only BackgroundIsolateBinaryMessenger is initialised there).
  final String? sileroModelPath;
  final ProcessingSettings settings;
  final String tempProcessingPath;
  final List<String> segmentPaths;
  final List<int> segmentFileSizes; // used for accurate processing ETA
  final List<int> segmentStartTimesMs; // milliseconds since epoch
  final List<int> segmentStartUptimesMs; // milliseconds since epoch (raw device uptime)
  final List<int?> segmentSessionIds;
  final List<bool> segmentDerivedFlags;
  // Optional list of DISJOINT `[startByte, endByte)` slices per segment
  // (null ⇒ whole file). Set only by Recover Discard so it re-derives just the
  // discarded byte spans, skipping un-discarded audio in between; every other
  // caller passes all-null. Parallel to [segmentPaths].
  final List<List<List<int>>?> segmentByteRanges;
  final bool backgroundMode;
  // Recover Discard only: flush the end-of-run remainder as a FINALIZED recording
  // instead of a `_draft`. A recovered discard is a complete, self-contained clip
  // (one VAD-off pass over a fixed slice, no future bins to continue into), so it
  // must NOT enter the draft-stitch path — otherwise it gets merged into whatever
  // finalized recording happens to abut it. Every other caller leaves this false.
  final bool finalizeRemainingDirectly;
  // Forwarded so DebugLogManager can write to the log file from this isolate;
  // SharedPreferences isn't initialised here so it can't read the pref itself.
  final bool devLogsEnabled;
  // Checkpoint fields — null/empty means fresh run (no prior state to restore).
  final Map<String, dynamic>? checkpointState;
  final int checkpointResumeIndex;
  final String? checkpointPath;
  final List<String> checkpointPendingDeletes;
  // Priority-latch sentinel path. Survives clean run completion / a shifted
  // segment list (unlike the checkpoint), so a Priority Recording that spans a
  // sync boundary keeps force-capturing on the next run. Null disables the latch
  // (Recover Discard passes null).
  final String? priorityStatePath;

  const IsolateParams({
    required this.sendPort,
    required this.rootIsolateToken,
    required this.sileroModelPath,
    required this.settings,
    required this.tempProcessingPath,
    required this.segmentPaths,
    required this.segmentFileSizes,
    required this.segmentStartTimesMs,
    required this.segmentStartUptimesMs,
    required this.segmentSessionIds,
    required this.segmentDerivedFlags,
    required this.segmentByteRanges,
    required this.backgroundMode,
    this.finalizeRemainingDirectly = false,
    required this.devLogsEnabled,
    this.checkpointState,
    this.checkpointResumeIndex = 0,
    this.checkpointPath,
    this.checkpointPendingDeletes = const [],
    this.priorityStatePath,
  });
}

/// Background isolate entry point for VAD + Opus decode + AAC encode.
/// Runs entirely off the Android main/platform thread, eliminating the
/// ForegroundServiceDidNotStartInTimeException caused by ONNX inference
/// blocking the platform thread.
Future<void> processingIsolateEntry(IsolateParams params) async {
  // Allow platform channel calls (AacEncoder MethodChannel, opus_flutter.load(),
  // flutter_onnxruntime asset loader) from this isolate.
  BackgroundIsolateBinaryMessenger.ensureInitialized(params.rootIsolateToken);

  // SharedPreferences isn't initialised in this isolate, so DebugLogManager
  // would otherwise treat logging as disabled and drop every line. Forward the
  // real pref from the main isolate so VAD/processing logs reach the file.
  DebugLogManager.enabledOverride = params.devLogsEnabled;

  // Send back a control port so the main isolate can forward cancel requests.
  final controlPort = ReceivePort();
  params.sendPort.send({'type': 'control_port', 'port': controlPort.sendPort});

  bool cancelled = false;
  controlPort.listen((msg) {
    if (msg == 'cancel') cancelled = true;
  });

  // Initialise Opus (each isolate has its own FFI state; must call initOpus before any decoder).
  if (Platform.isIOS || Platform.isAndroid) {
    try {
      initOpus(await opus_flutter.load());
    } catch (e) {
      // If Opus fails to load, decoder creation below will also fail and we fall back to null.
    }
  }

  OrtSession? session;
  if (params.settings.vadEnabled && params.sileroModelPath != null) {
    try {
      session = await OnnxRuntime()
          .createSession(params.sileroModelPath!, options: await VadAudioProcessor.buildSileroSessionOptions());
      Logger.debug(
          'RecordingsManager isolate: Silero session — inputs=${session.inputNames} outputs=${session.outputNames}');
    } catch (e) {
      Logger.error('RecordingsManager isolate: Silero session load failed ($e) — AAD mode active.');
    }
  }

  // Surface a silent VAD→AAD fallback to the UI. Only report when this run
  // actually wanted Silero (vadEnabled): manual-mode / merge runs legitimately
  // run AAD and must not raise the banner or clear a real warning. session==null
  // here means the model was missing or failed to load → AAD this run.
  if (params.settings.vadEnabled) {
    params.sendPort.send({'type': 'vad_status', 'fallback': session == null});
  }

  SimpleOpusDecoder? decoder;
  if (Platform.isIOS || Platform.isAndroid) {
    try {
      decoder = SimpleOpusDecoder(
        sampleRate: VadAudioProcessor.sampleRate,
        channels: VadAudioProcessor.channels,
      );
    } catch (e) {
      // Opus failed to load — decoder stays null, WAV fallback will be used.
    }
  }

  // Initialise the native VAD batch runner (Android-only). Uses the same
  // materialized model file that the ORT session was loaded from. On non-Android
  // platforms, init is a no-op and available stays false.
  final batchRunner = VadBatchRunnerChannel(isolateSendPort: params.sendPort);
  if (params.settings.vadEnabled && params.sileroModelPath != null && session != null) {
    await batchRunner.init(params.sileroModelPath!);
  }

  // Liveness: VadAudioProcessor bumps this counter from inside its decode/save
  // loops, so it advances even within a single long segment or save. The timer
  // below forwards a 'heartbeat' to the main isolate only when the count
  // actually moved — a truly wedged loop sends nothing, so the stall watchdog
  // still catches a genuine hang.
  int livenessTick = 0;
  final processor = VadAudioProcessor.fromSettings(
    settings: params.settings,
    outputDir: params.tempProcessingPath,
    session: session,
    decoder: decoder,
    onLiveness: () => livenessTick++,
    // Threaded into the per-frame decode loop so cooperative cancel takes
    // effect within milliseconds instead of waiting for the current (possibly
    // >12 s) segment to finish — otherwise the controller's stoppingStallTimeout
    // fires and force-kills the isolate, which crashes the app from inside an
    // ONNX/Opus FFI call.
    isCancelled: () => cancelled,
    batchRunner: batchRunner,
    priorityStatePath: params.priorityStatePath,
  );

  int lastSeenLivenessTick = -1;
  final heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
    if (livenessTick != lastSeenLivenessTick) {
      lastSeenLivenessTick = livenessTick;
      params.sendPort.send({'type': 'heartbeat'});
    }
  });

  final runStopwatch = Stopwatch()..start();
  Logger.debug(
      'RecordingsManager isolate: processing run started — ${params.segmentPaths.length} segment(s), backgroundMode=${params.backgroundMode}');

  try {
    if (params.checkpointState != null) {
      await processor.restoreState(params.checkpointState!);
      Logger.debug(
          'RecordingsManager isolate: restored checkpoint state, resuming from segment ${params.checkpointResumeIndex}/${params.segmentPaths.length}.');
    } else {
      // Restore the open-Priority-Recording latch ONLY when no checkpoint was
      // restored. A restored checkpoint is newer, authoritative state for its resume
      // position — it already reflects any 0xFFFFFFFC processed before the
      // interruption — so a stale sentinel must not override it. When there is no
      // checkpoint (clean completion) or its VAD state was discarded (shifted segment
      // list → checkpointState null), the sentinel bridges force-capture across the
      // sync boundary (e.g. a force-sync between RECORD_START and STOP).
      await processor.restorePriorityLatch();
    }
    // Re-send pending deletes from the prior run — delete handler checks existence first so this is idempotent.
    if (params.checkpointPendingDeletes.isNotEmpty) {
      params.sendPort.send({'type': 'delete_segments', 'paths': params.checkpointPendingDeletes});
    }
    final checkpointPendingDeletes = List<String>.from(params.checkpointPendingDeletes);

    // Checkpoint serialization cost scales with the in-flight conversation's ref
    // count (uncapped by default), so writing every segment can rival decode time
    // on long sessions. Throttle to one write per interval — a cancel between
    // writes just reprocesses the few segments since the last checkpoint, which
    // is cheap. Initialised so the first eligible segment always writes.
    const checkpointMinIntervalMs = 5000;
    int lastCheckpointMs = -checkpointMinIntervalMs;
    // Deletes are held here until a checkpoint that excludes them from the live
    // ref-state is durably written (see below) — so a throttled-away checkpoint
    // can never leave the resume state pointing at a file already gone from disk.
    final pendingDeleteBatch = <String>[];

    for (int i = params.checkpointResumeIndex; i < params.segmentPaths.length; i++) {
      if (cancelled) {
        break;
      }

      final file = File(params.segmentPaths[i]);
      final startTime = DateTime.fromMillisecondsSinceEpoch(
        params.segmentStartTimesMs[i],
      );
      final startUptimeMs = params.segmentStartUptimesMs[i];
      final isDerived = params.segmentDerivedFlags[i];
      final sessionId = params.segmentSessionIds[i];
      final byteRange = params.segmentByteRanges[i];

      final fileStopwatch = Stopwatch()..start();
      try {
        await processor.processSegmentFile(
          file,
          startTime,
          startUptimeMs: startUptimeMs,
          isDerivedTimestamp: isDerived,
          sessionId: sessionId,
          byteRanges: byteRange,
        );
      } on VadProcessingCancelled {
        // Cooperative cancel landed inside the per-frame loop; bail out of the
        // segment-iteration loop. Don't emit progress for the half-finished
        // segment — the bin file is left on disk and reprocessed next run.
        cancelled = true;
        fileStopwatch.stop();
        Logger.debug('RecordingsManager isolate: segment ${i + 1}/${params.segmentPaths.length} '
            'cancelled mid-decode after ${fileStopwatch.elapsedMilliseconds}ms');
        break;
      }
      fileStopwatch.stop();
      Logger.debug('RecordingsManager isolate: segment ${i + 1}/${params.segmentPaths.length} '
          '(${params.segmentFileSizes[i]} B) processed in ${fileStopwatch.elapsedMilliseconds}ms');

      final edlData = processor.consumePendingEdlData();
      if (edlData.isNotEmpty) {
        params.sendPort.send({'type': 'marker_edl', 'items': edlData});
      }

      // A 0xFFFFFFFC that arrived with no audio buffered closes a `_draft` an
      // earlier run left on disk. Only the main isolate owns the recordings
      // directory, so forward the boundary for it to stamp.
      final hardEnds = processor.consumePendingDraftHardEnds();
      if (hardEnds.isNotEmpty) {
        params.sendPort.send({'type': 'draft_hard_end', 'markerMs': hardEnds});
      }

      // Emit discard records before delete_segments so the main isolate can
      // register protected bin paths before considering them for deletion.
      final discards = processor.consumePendingDiscards();
      if (discards.isNotEmpty) {
        params.sendPort.send({'type': 'discard_records', 'items': discards});
      }

      // Ask the main isolate to move any completed recordings out of temp.
      params.sendPort.send({'type': 'move'});

      // Segment files that are fully processed and no longer referenced by any
      // buffer become safe to delete — but hold them; they're only sent once a
      // checkpoint excluding them is durably written, below.
      pendingDeleteBatch.addAll(processor.consumeSafeToDeletePaths());

      params.sendPort.send({
        'type': 'progress',
        'processed_bytes': params.segmentFileSizes[i],
        'index': i,
        'total': params.segmentPaths.length,
      });

      // Write a checkpoint when the throttle interval has elapsed, OR force one
      // whenever deletes are pending — the persisted ref-state must be committed
      // before any source bin leaves disk, otherwise a resume could reference a
      // deleted file. Deletes only occur at conversation boundaries, so the
      // common (no-delete) segments are genuinely throttled.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (params.checkpointPath != null &&
          // Don't advance the checkpoint onto a pinned, audio-less Priority
          // Recording marker bin: keep `lastIndex` before the marker so a resume
          // reprocesses the bin and re-enters force-capture instead of treating
          // the following forced audio as ordinary VAD. The marker bin is held
          // on disk (consumeSafeToDeletePaths) and any pending deletes stay held
          // (safe) until the next checkpoint once audio buffers.
          !processor.hasOpenPriorityWithoutAudio &&
          (pendingDeleteBatch.isNotEmpty || nowMs - lastCheckpointMs >= checkpointMinIntervalMs)) {
        try {
          final cpState = await processor.serializeState();
          await File(params.checkpointPath!).writeAsString(jsonEncode({
            'lastIndex': i,
            'paths': params.segmentPaths,
            'state': cpState,
            'pendingDeletes': [...checkpointPendingDeletes, ...pendingDeleteBatch],
          }));
          lastCheckpointMs = nowMs;
          // Checkpoint is durable → safe to release the held deletes now.
          checkpointPendingDeletes.addAll(pendingDeleteBatch);
          if (pendingDeleteBatch.isNotEmpty) {
            params.sendPort.send({'type': 'delete_segments', 'paths': pendingDeleteBatch.toList()});
            pendingDeleteBatch.clear();
          }
        } catch (e) {
          // Write failed — keep the deletes held; the next checkpoint retries.
          Logger.error('RecordingsManager isolate: checkpoint write failed ($e)');
        }
      }

      if (params.backgroundMode) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    // Skip the draft flush on cancel — flushRemaining triggers another save
    // pass (potentially several seconds), and we already broke out specifically
    // to make the cancel responsive. Any unfinalised state stays in-memory only
    // and is rebuilt from disk on the next run.
    if (!cancelled) {
      // Always flush the remaining audio at the end of a run. Normally as a
      // '_draft' so it can be stitched with future syncs or finalized later; for
      // Recover Discard, as a FINALIZED recording so the standalone recovered
      // clip isn't merged into an abutting recording by the draft-stitch pass.
      await processor.flushRemaining(isDraft: !params.finalizeRemainingDirectly);

      final flushEdlData = processor.consumePendingEdlData();
      if (flushEdlData.isNotEmpty) {
        params.sendPort.send({'type': 'marker_edl', 'items': flushEdlData});
      }

      final flushDiscards = processor.consumePendingDiscards();
      if (flushDiscards.isNotEmpty) {
        params.sendPort.send({'type': 'discard_records', 'items': flushDiscards});
      }

      params.sendPort.send({'type': 'move'});

      // On clean completion the checkpoint is deleted, so consistency between it
      // and on-disk files no longer matters — flush any deletes still held from
      // a failed checkpoint write alongside the run's final safe-to-delete set.
      final finalSafe = processor.consumeSafeToDeletePaths()..addAll(pendingDeleteBatch);
      pendingDeleteBatch.clear();
      if (finalSafe.isNotEmpty) {
        params.sendPort.send({
          'type': 'delete_segments',
          'paths': finalSafe.toList(),
        });
      }
    }

    runStopwatch.stop();
    final totalBytes = params.segmentFileSizes.fold<int>(0, (a, b) => a + b);
    Logger.debug('RecordingsManager isolate: processing run ${cancelled ? 'cancelled' : 'finished'} — '
        '${params.segmentPaths.length} segment(s), $totalBytes B in ${runStopwatch.elapsedMilliseconds}ms');

    params.sendPort.send({'type': 'done', 'cancelled': cancelled});
  } catch (e, st) {
    params.sendPort.send({'type': 'error', 'message': '$e\n$st'});
  } finally {
    heartbeatTimer.cancel();
    // Persist the priority latch on EVERY exit (clean / cancel / error):
    // _inPriorityRecording is the current truth and must outlive this isolate
    // (torn down after every run). In finally so an error thrown after the
    // 0xFFFFFFFC stop still clears the sentinel — otherwise the checkpoint is
    // deleted and the next run would restore a false open Priority Recording.
    // Runs before destroy(); the latch write is independent of the ORT session.
    await processor.persistPriorityLatch();
    await batchRunner.dispose();
    await processor.destroy();
    controlPort.close();
  }
}
