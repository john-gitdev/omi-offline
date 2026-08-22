import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/device_clock_anchor.dart';
import 'package:omi/services/discard_store.dart';
import 'package:omi/services/recordings_isolate_worker.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/vad_audio_processor.dart';
import 'package:omi/services/vad_batch_runner_channel.dart';
import 'package:omi/utils/logger.dart';

// Re-export the recording domain models so existing importers of this file keep
// working without touching their import lists. The model definitions now live in
// models/recordings/recordings_models.dart.
export 'package:omi/models/recordings/recordings_models.dart';

/// One Recover-Discard slice passed to [RecordingsManager.processAll]: re-derive
/// only the listed DISJOINT `[startByte, endByte)` byte [ranges] of a bin,
/// skipping any un-discarded audio between them. Keyed by absolute bin path.
///
/// [anchorMs] overrides the segment's start time with the discard's true start.
/// It is set only on the FIRST bin of a multi-bin discard (whose slice begins
/// mid-bin); later bins leave it null and keep their bin-head timestamp, then
/// stitch onto the same recording — so a discard spanning several bins recovers
/// as one correctly-timed clip.
class RecoverSlice {
  final List<List<int>> ranges;
  final int? anchorMs;
  const RecoverSlice({required this.ranges, this.anchorMs});
}

class RecordingsManager {
  static final RecordingsManager _instance = RecordingsManager._internal();
  factory RecordingsManager() => _instance;
  RecordingsManager._internal();

  static bool _isProcessingAny = false;
  static bool get isProcessingAny => _isProcessingAny;

  /// Global progress of the current processing task (0.0 to 1.0).
  static final ValueNotifier<double> processingProgress = ValueNotifier(0.0);

  /// Minutes of audio remaining to process. Updated by RecordingsController;
  /// -1 means unknown (calculating). Read by notification paths in both
  /// foreground and background to show consistent progress text.
  static double minutesRemaining = -1.0;

  /// Bumped on each isolate liveness heartbeat — emitted while the decode/save
  /// loops are actively advancing, so it ticks even within a single long
  /// segment or a multi-hour stitched-recording save where the per-segment
  /// [processingProgress] tick can't. The pipeline-stall watchdog anchors on
  /// this so a healthy-but-slow run isn't force-killed as a wedge.
  static final ValueNotifier<int> processingLiveness = ValueNotifier(0);

  /// True when a WAV file is being transcoded to M4A.
  static final ValueNotifier<bool> isTranscoding = ValueNotifier(false);

  /// True when the "Conversations ready" success notification is being displayed.
  /// Used to prevent the background idle-notification heartbeat from clobbering
  /// the success message before its 10s display window elapses.
  static final ValueNotifier<bool> isSuccessNotificationActive = ValueNotifier(false);

  static bool _cancelRequested = false;
  static SendPort? _activeIsolateControlPort;
  static Isolate? _activeIsolate;

  /// Cooperative cancel: ask the decode isolate to stop at the next checkpoint.
  /// The isolate's control port listener flips its local `cancelled` flag,
  /// which is polled from inside the per-frame decode loop in
  /// [VadAudioProcessor] — so cancel takes effect within milliseconds even
  /// mid-segment. Falls back to [forceResetProcessing] only for a genuine
  /// wedge (native deadlock that ignores the flag check too).
  static void cancelProcessing() {
    _cancelRequested = true;
    _activeIsolateControlPort?.send('cancel');
  }

  /// Last-resort recovery for a wedged processing run. A hung isolate never
  /// reads the cooperative 'cancel', so `processAll`'s `finally` never runs and
  /// [_isProcessingAny] stays stuck true — stranding the UI in `processing`.
  /// Killing the isolate fires its `onExit`, which closes the receive port,
  /// ends `processAll`'s `await for`, and lets it unwind and clear the flag
  /// naturally. No-op when no isolate is active.
  ///
  /// DANGER: `Isolate.kill(immediate)` while the isolate is parked in an
  /// ONNX/Opus FFI call can corrupt process-level native state and crash the
  /// whole app, so we use `beforeNextEvent` — it lets any in-flight native call
  /// finish before the kill, dodging the FFI-corruption crash.
  ///
  /// The hard truth this method can't escape: `beforeNextEvent` AND cooperative
  /// 'cancel' BOTH require the isolate to return to its event loop —
  /// `beforeNextEvent` to schedule the kill, the cancel message to even be read
  /// off the port. A genuine native deadlock (a synchronous FFI call that never
  /// returns) services neither, so this method cannot actually reap that case;
  /// the zombie isolate and its native resources leak until the OS reclaims the
  /// process. `immediate` is the only priority that could kill such an isolate,
  /// but at the cost of likely native-heap corruption — strictly worse than a
  /// leaked isolate. We accept the leak: the per-frame cancel check in
  /// [VadAudioProcessor] makes cooperative cancel land within milliseconds for
  /// every realistic wedge, so a true unrecoverable native deadlock is the only
  /// scenario that reaches here unhandled, and there is no clean kill for it
  /// inside Dart's shared-process isolate model (only OS process isolation
  /// would give a corruption-free hard kill). What this method DOES guarantee is
  /// that `_activeIsolate` is cleared so the controller's state machine recovers
  /// to idle even when the underlying isolate can't be reaped.
  static void forceResetProcessing() {
    _cancelRequested = true;
    _activeIsolateControlPort?.send('cancel'); // best-effort, in case it's only slow
    final isolate = _activeIsolate;
    if (isolate != null) {
      Logger.warning('RecordingsManager: force-killing wedged processing isolate');
      isolate.kill(priority: Isolate.beforeNextEvent);
      _activeIsolate = null;
    }
  }

  /// Global notification system to alert UI pages when the recordings folder
  /// has been modified (deleted, reprocessed, etc.).
  static final ValueNotifier<int> recordingsChangeNotifier = ValueNotifier(0);
  static void notifyRecordingsChanged() => recordingsChangeNotifier.value++;

  /// Call on app startup to clean up incomplete extraction from a previous crash.
  /// If the persisted extraction-in-progress flag is set, any fully-written m4a/wav
  /// files in the temp directory are rescued to their live recordings/<date>/ folders
  /// first, then the temp directory is removed and the flag is cleared.
  /// Raw segments are intentionally left intact so processing can be retried.
  static Future<void> cleanUpIncompleteExtraction() async {
    final prefs = SharedPreferencesUtil();
    if (!prefs.extractionInProgress) return;

    Logger.debug(
      'RecordingsManager: Detected incomplete extraction from previous run — rescuing completed files.',
    );
    try {
      final directory = await getApplicationDocumentsDirectory();
      final tempDir = Directory('${directory.path}/processing_temp');
      if (await tempDir.exists()) {
        // Rescue any fully-written recordings before deleting the temp dir.
        // This covers the race where the crash happened between _saveRecording()
        // writing the m4a and moveTempFilesToLive() renaming it.
        // Move .meta sidecars first so they are in place when the audio file lands.
        final allEntities = await tempDir.list(recursive: true).where((e) => e is File).cast<File>().toList();
        allEntities.sort((a, b) {
          final aIsMeta = a.path.endsWith('.meta') ? 0 : 1;
          final bIsMeta = b.path.endsWith('.meta') ? 0 : 1;
          return aIsMeta.compareTo(bIsMeta);
        });
        for (final file in allEntities) {
          final fileName = file.path.split('/').last;
          if (!fileName.endsWith('.m4a') && !fileName.endsWith('.wav') && !fileName.endsWith('.meta')) continue;
          final parts = fileName.split('_');
          var millis = parts.length >= 2 ? int.tryParse(parts.last.split('.').first) : null;
          if (millis == null || millis <= 0) continue;
          final dateStr = _dateStringFromMillis(millis);
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          try {
            await file.rename(dest);
            Logger.debug(
              'RecordingsManager: Rescued $fileName → recordings/$dateStr/',
            );
          } catch (e) {
            Logger.error('RecordingsManager: Failed to rescue $fileName: $e');
          }
        }
        await tempDir.delete(recursive: true);
        Logger.debug(
          'RecordingsManager: Removed leftover processing_temp directory.',
        );
      }
    } catch (e) {
      Logger.error('RecordingsManager: Failed to clean up processing_temp: $e');
    } finally {
      prefs.extractionInProgress = false;
    }
  }

  Future<List<Batch>> getBatches() async {
    final directory = await getApplicationDocumentsDirectory();
    final rawSegmentsDir = Directory('${directory.path}/raw_segments');
    final recordingsDir = Directory('${directory.path}/recordings');

    Map<String, List<File>> rawSegmentsByDate = {};
    Map<String, List<Conversation>> processedByDate = {};

    // Process raw segments (now they are in DeviceSession folders)
    if (await rawSegmentsDir.exists()) {
      final deviceSessionEntities = await rawSegmentsDir.list().toList();
      final deviceSessionFolders = deviceSessionEntities.whereType<Directory>().toList();

      // Sort session folders by timestamp ID (e.g. "1713892490", "unknown_101", "session_AABBCCDD")
      deviceSessionFolders.sort((a, b) {
        final aName = a.path.split('/').last;
        final bName = b.path.split('/').last;
        final aIdStr = aName.replaceFirst('unknown_', '').replaceFirst('session_', '');
        final bIdStr = bName.replaceFirst('unknown_', '').replaceFirst('session_', '');

        // Folder ids are decimal (session_<sessionId>, unknown_<n>, or a raw timestamp).
        final aId = int.tryParse(aIdStr);
        final bId = int.tryParse(bIdStr);

        return (aId ?? 0).compareTo(bId ?? 0);
      });

      for (var folder in deviceSessionFolders) {
        final deviceSessionIdStr = folder.path.split('/').last;

        // Skip hidden folders or system folders if any
        if (deviceSessionIdStr.startsWith('.')) continue;

        // Process segments
        final folderEntities = await folder.list().toList();
        final files = folderEntities.whereType<File>().where((f) => f.path.endsWith('.bin')).toList();

        await Future.wait(
          files.map((file) async {
            String dateStr;
            try {
              final name = file.path.split('/').last;
              final tsStr = name.split('_').first;
              final ts = int.tryParse(tsStr);
              // The bin filename timestamp is epoch SECONDS (the WAL timerStart).
              // Convert to ms and group via the canonical local-date helper, so
              // raw bins land in the SAME date batch as their recordings and
              // discard records. (Previously read as ms — `fromMillisecondsSinceEpoch(ts)`
              // — so every UTC-stamped bin fell into a 1970 bucket, splitting it
              // from same-day recordings/discards.) Uptime ticks (pre-time-sync,
              // below kMinValidEpoch) and unparseable names fall back to mtime.
              if (ts != null && ts > 946684800) {
                dateStr = _dateStringFromMillis(ts * 1000);
              } else {
                dateStr = _dateStringFromMillis((await file.lastModified()).millisecondsSinceEpoch);
              }
            } catch (_) {
              dateStr = _dateStringFromMillis((await file.lastModified()).millisecondsSinceEpoch);
            }
            rawSegmentsByDate.putIfAbsent(dateStr, () => []).add(file);
          }),
        );
      }
    }

    // Process already processed recordings
    if (await recordingsDir.exists()) {
      final dateFolderEntities = await recordingsDir.list().toList();
      final dateFolders = dateFolderEntities.whereType<Directory>();
      for (var folder in dateFolders) {
        final dateString = folder.path.split('/').last;
        final folderEntities = await folder.list().toList();
        final files = folderEntities
            .whereType<File>()
            .where(
              (f) => (f.path.endsWith('.m4a') || f.path.endsWith('.wav')) && !f.path.endsWith('.tmp.m4a'),
            )
            .toList();

        final conversations = await Future.wait(
          files.map((f) => Conversation.fromFileAsync(f)),
        );

        // Also pick up passthrough conversations: .meta files with no matching audio file.
        final audioBasenames = files.map((f) {
          final name = f.path.split('/').last;
          return name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
        }).toSet();
        final metaFiles = folderEntities.whereType<File>().where((f) => f.path.endsWith('.meta')).toList();
        final passthroughConvs = <Conversation>[];
        for (final meta in metaFiles) {
          final metaName = meta.path.split('/').last;
          final baseName = metaName.contains('.') ? metaName.substring(0, metaName.lastIndexOf('.')) : metaName;
          if (audioBasenames.contains(baseName)) continue;
          final c = await Conversation.fromMetaOnly(meta);
          if (c != null) passthroughConvs.add(c);
        }

        processedByDate[dateString] = [...conversations, ...passthroughConvs];
      }
    }

    // Discover dates with discard records — a day where ALL audio was rejected
    // produces no recording or raw bin, but still has a discards.jsonl we want
    // to render.
    final discardsByDate = <String, List<DiscardRecord>>{};
    if (await recordingsDir.exists()) {
      await for (final entity in recordingsDir.list()) {
        if (entity is! Directory) continue;
        final dateStr = entity.path.split('/').last;
        final loaded = await getDiscardsForDate(dateStr);
        if (loaded.isNotEmpty) discardsByDate[dateStr] = loaded;
      }
    }

    // Merge keys
    final allDates = {
      ...rawSegmentsByDate.keys,
      ...processedByDate.keys,
      ...discardsByDate.keys,
    }.toList();
    List<Batch> batches = [];

    for (var dateStr in allDates) {
      final parts = dateStr.split('-');
      final date = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );

      final raw = rawSegmentsByDate[dateStr] ?? [];
      // Sort raw segments chronologically by their filename. Since filenames are
      // zero-padded hex strings (timestamp_sessionId.bin), string order is correct.
      raw.sort((a, b) {
        final nameA = a.path.split('/').last;
        final nameB = b.path.split('/').last;
        return nameA.compareTo(nameB);
      });

      final allConversations = processedByDate[dateStr] ?? <Conversation>[];
      final finalized = allConversations.where((c) => !c.file.path.contains('_draft.')).toList();
      final drafts = allConversations.where((c) => c.file.path.contains('_draft.')).toList();

      batches.add(
        Batch(
          dateString: dateStr,
          date: date,
          rawSegments: raw,
          draftRecordings: drafts,
          finalizedRecordings: finalized,
          markerTimestamps: const [],
          discards: discardsByDate[dateStr] ?? const [],
        ),
      );
    }

    batches.sort((a, b) => b.date.compareTo(a.date));
    return batches;
  }

  /// Returns [batches] with every raw segment whose `raw_segments/`-relative path
  /// is in [excludeRelBins] removed. Pure and synchronous so the processing-guard
  /// filters (discarded bins, mid-transfer bins) are unit-testable without spinning
  /// up an isolate. A path outside `raw_segments/` is always kept (defensive). Rebuilds
  /// only the batches that actually change; identity-returns the rest.
  @visibleForTesting
  static List<Batch> stripBinsByRelPath(List<Batch> batches, Set<String> excludeRelBins) {
    if (excludeRelBins.isEmpty) return batches;
    return batches.map((b) {
      final filtered = b.rawSegments.where((f) {
        final parts = f.path.split('/raw_segments/');
        return parts.length != 2 || !excludeRelBins.contains(parts.last);
      }).toList();
      if (filtered.length == b.rawSegments.length) return b;
      return Batch(
        dateString: b.dateString,
        date: b.date,
        rawSegments: filtered,
        draftRecordings: b.draftRecordings,
        finalizedRecordings: b.finalizedRecordings,
        markerTimestamps: b.markerTimestamps,
        discards: b.discards,
      );
    }).toList();
  }

  /// Deletes 0-byte raw bins and strips them from [batches].
  ///
  /// The local file is created before the first byte arrives (see
  /// `_readStorageBytesToFileLocked`), so any transfer that opens it and then
  /// delivers nothing leaves one behind. If its WAL is later dropped, nothing is
  /// left that could ever reclaim it: a bin is deleted only when a recording that
  /// consumed it is finalized, and a bin with no audio feeds no recording.
  ///
  /// NOT the firmware's `emptyBinRotations`. A rotation that closes a bin nothing
  /// was written to still carries the 36-byte 0xFFFFFFFB header the ring appends
  /// right after `start_abs = head_abs`, so it arrives here as a 36-byte file —
  /// which this sweep deliberately does not touch, because a header-only bin is
  /// NOT inert: its header re-anchors `segmentStartTime`, the inter-file gap logic
  /// runs on it, and it moves `_lastSegmentEndTime`. Removing those would merge
  /// two gaps into one and could split a recording that currently survives.
  ///
  /// The cost of keeping a 0-byte bin was never the disk. Its presence alone kept
  /// `activeBatches` non-empty, so every processing cycle spawned an isolate and
  /// loaded the Silero model to decode nothing at all, on battery, for the life of
  /// the install.
  ///
  /// Deleting one changes no audio. [VadAudioProcessor.processSegmentFile] returns
  /// on `fileLength == 0` before it reads any header and before it touches
  /// `_lastSegmentEndTime`, so a 0-byte bin is ALREADY a no-op: it can neither end
  /// a recording nor bridge the gap between two real bins, and the inter-file gap
  /// either side of it is computed identically whether it is in the list or not.
  /// It can never appear in a recording's `.meta` bin list or in a discard record
  /// either — both are built from decoded frames, and it has none.
  ///
  /// [incompleteRelBins] is the mid-transfer protection set and is not optional: a
  /// bin being downloaded RIGHT NOW is also 0 bytes, and deleting one destroys the
  /// resume target (the next sync rewinds to 0 and re-fetches the whole file,
  /// duplicating its audio). `Wal.isIncompleteTransfer` requires
  /// `storageTotalBytes > 0`, so it separates the two cases exactly. A null set
  /// means the WAL state is unreadable — skip the sweep entirely, the same
  /// fail-closed rule the `delete_segments` handler follows.
  static Future<List<Batch>> pruneEmptyRawBins(List<Batch> batches, Set<String>? incompleteRelBins) async {
    if (incompleteRelBins == null) return batches;

    final removed = <String>{};
    final folders = <String>{};
    for (final file in batches.expand((b) => b.rawSegments)) {
      final parts = file.path.split('/raw_segments/');
      if (parts.length != 2) continue;
      final rel = parts.last;
      if (incompleteRelBins.contains(rel)) continue;
      try {
        if (await file.length() != 0) continue;
        await file.delete();
        removed.add(rel);
        folders.add(file.parent.path);
      } catch (e) {
        // A bin that cannot be read or deleted is left exactly where it is; the
        // next run tries again. Never fatal — this is housekeeping.
        Logger.debug('RecordingsManager: could not prune empty bin $rel ($e)');
      }
    }
    if (removed.isEmpty) return batches;

    Logger.debug('RecordingsManager: pruned ${removed.length} orphaned 0-byte raw bin(s)');
    for (final folderPath in folders) {
      final folder = Directory(folderPath);
      try {
        if (await folder.exists() && await folder.list().isEmpty) await folder.delete();
      } catch (_) {}
    }
    return stripBinsByRelPath(batches, removed);
  }

  /// Test seam for the mid-transfer bin lookup ([WalSync.incompleteBinRelPaths]).
  /// Production resolves it through [ServiceManager], which unit tests never
  /// initialize — without a stub every run would take the fail-closed branch and
  /// the bin-deletion path would go unexercised. Throwing from the stub simulates
  /// an unreadable wals.json.
  @visibleForTesting
  static Future<Set<String>> Function()? incompleteBinResolverForTest;

  static Future<Set<String>> _resolveIncompleteRelBins() {
    final override = incompleteBinResolverForTest;
    if (override != null) return override();
    return ServiceManager.instance().wal.getSyncs().incompleteBinRelPaths();
  }

  /// Processes all batches as one continuous audio stream.
  ///
  /// Segments are sorted by (deviceSessionId, segmentIndex) across all batches so a
  /// recording that spans midnight is never artificially cut. Output files are
  /// moved into `recordings/<date>/` based on each recording's actual start
  /// timestamp, not the batch date they were grouped under.
  Future<void> processAll(
    List<Batch> batches,
    Function(double progress, Duration? eta) onProgress, {
    bool backgroundMode = false,
    bool finalizeDrafts = false,
    VoidCallback? onRecordingFinalized,
    ProcessingSettings? settingsOverride,
    // Recover Discard only: re-derive just a byte slice of a segment, anchored at
    // the discard's true start, keyed by absolute bin path. Absent ⇒ whole-file
    // processing with bin-derived timestamps (normal). See [RecoverSlice].
    Map<String, RecoverSlice>? recoverSlices,
    // Absolute bin paths to preserve from the post-process delete sweep even
    // though this run consumes them. Recover Discard seeds this with the bins of
    // SIBLING discards so recovering one ghost can't delete a bin another ghost
    // still needs (the shared-bin data-loss path).
    Set<String> seedProtectedBinPaths = const {},
    // Recover Discard only: finalize the end-of-run remainder as a standalone
    // recording instead of a stitchable `_draft`, so the recovered clip isn't
    // merged into an abutting recording.
    bool finalizeRemainingDirectly = false,
  }) async {
    // Strip bins that already produced a discard record. They stay on disk
    // for the 48 h recovery window, but re-running VAD on them just re-derives
    // the same outcome and appends a duplicate line to discards.jsonl every
    // cycle. Recover/Delete/sweep all remove the record, after which the bin
    // naturally re-enters the processing set. Uses the global persisted set
    // (see [discardedRelBinPaths]) so this strip and the "minutes to process"
    // estimate never disagree.
    //
    // Only strip in background mode when no settings override is provided.
    // Manual runs (Process button, Recover Discard) honor the
    // explicit set of bins provided.
    if (backgroundMode && settingsOverride == null) {
      batches = stripBinsByRelPath(batches, await discardedRelBinPaths());
    }

    // Bins still mid-transfer (walOffset < the device-advertised size — see
    // Wal.isIncompleteTransfer). Such a bin holds only a PREFIX of the recording,
    // and its local file is what the next sync RESUMES INTO, so it drives two
    // different guards:
    //
    //  1. DECODE (auto/background only, below): decoding a prefix cuts a draft
    //     short of the real audio. Force paths deliberately decode the newest,
    //     still-arriving bin — that is the button's purpose — so only auto runs
    //     with no settingsOverride strip it, matching the discard strip's gate.
    //  2. DELETE (every mode, via [_incompleteProtectedPaths] in the
    //     `delete_segments` handler): this pass prunes every bin it consumes, and
    //     deleting a half-arrived one destroys the resume target. The next sync
    //     then rewinds to 0 and re-fetches the WHOLE file, whose re-decode
    //     DUPLICATES the prefix into a second recording (observed: an interrupted
    //     active bin folded into a draft, then re-fetched and re-opened as its own
    //     overlapping recording, ~4 min duplicated). Deleting is never the right
    //     move for a mid-transfer bin in ANY mode: retained, it is simply
    //     re-processed once whole, and the draft it fed re-stitches over it.
    //
    // Fail closed: an unreadable WAL means a bin's sync status is unknown. An
    // auto run skips entirely (it can afford to wait); a user-initiated run still
    // processes but deletes nothing this pass, leaving reclamation to the next
    // [pruneConsumedBins]. wals.json is rewritten by every sync, so either way the
    // next cycle self-heals. See the twin guard at
    // RecordingsController.isProcessableBin / _incompleteBins.
    final bool autoRun = backgroundMode && settingsOverride == null;
    Set<String>? incompleteRelBins;
    try {
      incompleteRelBins = await _resolveIncompleteRelBins();
    } catch (e) {
      Logger.error('RecordingsManager: processAll incomplete-bin set unavailable '
          '(${autoRun ? 'skipping run' : 'retaining every consumed bin'}, fail-closed): $e');
      if (autoRun) return;
    }
    if (autoRun && incompleteRelBins != null) {
      batches = stripBinsByRelPath(batches, incompleteRelBins);
    }

    // Before the gate, not after: an empty bin is exactly what keeps this run
    // alive to decode nothing. Uses incompleteRelBins directly rather than the
    // autoRun-gated strip above — a force run deliberately keeps its mid-transfer
    // bin, and that bin is 0 bytes too.
    batches = await pruneEmptyRawBins(batches, incompleteRelBins);

    final activeBatches = batches.where((b) => b.rawSegments.isNotEmpty).toList();
    final hasDrafts = batches.any((b) => b.draftRecordings.isNotEmpty);

    if (activeBatches.isEmpty && !(finalizeDrafts && hasDrafts)) return;
    if (_isProcessingAny) throw Exception("Another processing task is already in progress.");

    _isProcessingAny = true;
    _cancelRequested = false;
    SharedPreferencesUtil().extractionInProgress = true;

    try {
      final directory = await getApplicationDocumentsDirectory();

      // Disk space guard — bail before processing if free space is critically low.
      final allRawFiles = activeBatches.expand((b) => b.rawSegments).toList();
      final rawTotalBytes = allRawFiles.fold<int>(0, (sum, f) {
        try {
          return sum + f.lengthSync();
        } catch (_) {
          return sum;
        }
      });
      minutesRemaining = rawTotalBytes / 252000.0;
      processingProgress.value = 0.0;
      if (rawTotalBytes > 50 * 1024 * 1024) {
        try {
          final probe = File('${directory.path}/.disk_probe');
          final sink = probe.openWrite();
          sink.add(Uint8List(1024 * 1024));
          await sink.flush();
          await sink.close();
          await probe.delete();
        } catch (e) {
          Logger.error(
            'RecordingsManager: Disk space probe failed ($e). '
            'Skipping processing to preserve raw segments.',
          );
          return;
        }
      }

      final tempProcessingPath = '${directory.path}/processing_temp/combined';
      final tempDir = Directory(tempProcessingPath);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      await tempDir.create(recursive: true);

      // Moves any completed recordings from tempDir to their live recordings/<date>/ folder
      // and fires onRecordingFinalized for each audio file moved.
      Future<void> moveTempFilesToLive() async {
        if (!await tempDir.exists()) return;
        // Move .meta sidecars before .m4a/.wav so the sidecar is always present
        // by the time onRecordingFinalized fires and the scan reads the file.
        final folderEntities = await tempDir.list().toList();
        final entities = folderEntities.whereType<File>().where((f) {
          final name = f.path.split('/').last;
          // Ignore temp files used during encoding to avoid race conditions
          // where the main isolate moves a file while the background isolate is still writing it.
          if (name.contains('.tmp')) return false;
          // Only move known finalized file types
          return name.endsWith('.m4a') || name.endsWith('.wav') || name.endsWith('.meta') || name.endsWith('.bin');
        }).toList()
          ..sort((a, b) {
            final aIsMeta = a.path.endsWith('.meta') ? 0 : 1;
            final bIsMeta = b.path.endsWith('.meta') ? 0 : 1;
            return aIsMeta.compareTo(bIsMeta);
          });
        for (final entity in entities) {
          final fileName = entity.path.split('/').last;
          final nameNoExt = fileName.split('.').first;
          final parts = nameNoExt.split('_');

          // Format: recording_<ts> or recording_<ts>_draft
          int? millis;
          if (parts.length >= 2) {
            final tsStr = parts.contains('draft') ? parts[parts.length - 2] : parts.last;
            millis = int.tryParse(tsStr);
          }

          final dateStr =
              (millis != null && millis > 946684800000) ? _dateStringFromMillis(millis) : activeBatches.last.dateString;
          final liveDir = Directory('${directory.path}/recordings/$dateStr');
          await liveDir.create(recursive: true);
          final dest = '${liveDir.path}/$fileName';
          try {
            await File(dest).delete();
          } on FileSystemException catch (_) {}

          // If we are moving a draft, delete any existing finalized version.
          // If we are moving a finalized file, delete any existing draft version.
          // Only do this for audio files to avoid deleting the meta we just moved (since meta comes first).
          final isAudio = fileName.endsWith('.m4a') || fileName.endsWith('.wav');
          if (isAudio) {
            try {
              if (fileName.contains('_draft')) {
                await File(dest.replaceAll('_draft', '')).delete();
                await File(dest.replaceAll(RegExp(r'_draft\.(m4a|wav)$'), '.meta')).delete();
              } else {
                await File(dest.replaceAllMapped(RegExp(r'\.(m4a|wav)$'), (m) => '_draft${m[0]}')).delete();
                await File(dest.replaceAll(RegExp(r'\.(m4a|wav)$'), '_draft.meta')).delete();
              }
            } on FileSystemException catch (_) {}
          }

          await entity.rename(dest);
          if (fileName.endsWith('.m4a')) {
            final legacyWav = File(
              '${liveDir.path}/${fileName.replaceAll('.m4a', '')}.wav',
            );
            try {
              await legacyWav.delete();
            } on FileSystemException catch (_) {}
            onRecordingFinalized?.call();
            notifyRecordingsChanged();
          } else if (fileName.endsWith('.wav')) {
            onRecordingFinalized?.call();
            notifyRecordingsChanged();
          }
        }
      }

      // Combine segments from all batches, sorted chronologically by timestamp.
      final allSegments = activeBatches.expand((b) => b.rawSegments).toList();

      if (allSegments.isNotEmpty) {
        allSegments.sort((a, b) {
          final nameA = a.path.split('/').last;
          final nameB = b.path.split('/').last;
          return nameA.compareTo(nameB);
        });

        // Pre-compute segment timestamps and session IDs on the main isolate.
        const kMinValidEpoch = 946684800;
        final segmentStartTimesMs = <int>[];
        final segmentStartUptimesMs = <int>[];
        final segmentSessionIds = <int?>[];
        final segmentDerivedFlags = <bool>[];
        final segmentFileSizes = <int>[];
        final segmentByteRangesList = <List<List<int>>?>[];
        for (final file in allSegments) {
          segmentFileSizes.add(file.lengthSync());
          final slice = recoverSlices?[file.path];
          segmentByteRangesList.add(slice?.ranges);
          final stem = file.path.split('/').last.split('.').first;
          final parts = stem.split('_');
          final timerStart = int.tryParse(parts[0]);
          final sessionId = parts.length > 1 ? int.tryParse(parts[1]) : null;

          segmentSessionIds.add(sessionId);

          if (slice?.anchorMs != null) {
            // Recover Discard, first bin: the slice starts mid-bin, so anchor at
            // the discard's recorded start instead of the bin-head timestamp.
            // (Later sliced bins have anchorMs == null and fall through to the
            // normal bin-head time below, then stitch onto the same recording.)
            segmentStartTimesMs.add(slice!.anchorMs!);
            segmentStartUptimesMs.add(0);
            segmentDerivedFlags.add(false);
          } else if (timerStart != null && timerStart > kMinValidEpoch) {
            segmentStartTimesMs.add(timerStart * 1000);
            segmentStartUptimesMs.add(0); // Hardware syncs RTC -> uptime in filename is lost
            segmentDerivedFlags.add(false);
          } else {
            segmentStartTimesMs.add(
              file.lastModifiedSync().toUtc().millisecondsSinceEpoch,
            );
            segmentStartUptimesMs.add((timerStart ?? 0) * 1000);
            segmentDerivedFlags.add(true);
          }
        }

        final Set<String> deletedSegmentFolders = {};

        // Pre-copy the Silero VAD model from rootBundle to a temp file on the
        // main isolate. flutter_onnxruntime's createSessionFromAsset uses
        // ServicesBinding.instance internally, which isn't available in a
        // background isolate — so the isolate loads from a filesystem path
        // via createSession(path) instead. Cached across runs.
        String? sileroModelPath;
        final effectiveVadEnabled = settingsOverride?.vadEnabled ?? SharedPreferencesUtil().vadEnabled;
        if (effectiveVadEnabled) {
          try {
            final dir = await getApplicationSupportDirectory();
            final cached = File('${dir.path}/silero_vad_v6.onnx');
            if (!await cached.exists()) {
              final data = await rootBundle.load('assets/models/silero_vad.onnx');
              await cached.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
            }
            sileroModelPath = cached.path;
          } catch (e) {
            Logger.error('RecordingsManager: Failed to cache Silero model ($e) — AAD mode in isolate.');
          }
        }

        Map<String, dynamic>? checkpointState;
        int checkpointResumeIndex = 0;
        List<String> checkpointPendingDeletes = [];
        final checkpointFile = File('${directory.path}/vad_checkpoint.json');
        // Priority-latch sentinel (see VadAudioProcessor.persistPriorityLatch). Lives
        // beside the checkpoint in the stable app-documents dir so it outlives a run;
        // unlike the checkpoint it is NOT deleted on clean completion, which is exactly
        // what lets a Priority Recording keep force-capturing across a sync boundary.
        final priorityLatchFile = File('${directory.path}/vad_priority_latch.json');
        try {
          if (await checkpointFile.exists()) {
            final content = await checkpointFile.readAsString();
            final data = jsonDecode(content) as Map<String, dynamic>;
            final savedPaths = (data['paths'] as List).cast<String>();
            final lastIndex = data['lastIndex'] as int;
            final currentPaths = allSegments.map((f) => f.path).toList();

            // Fast path: segment list identical up to lastIndex — full state restore.
            bool exactMatch = lastIndex >= 0 && lastIndex + 1 < currentPaths.length;
            if (exactMatch) {
              for (int k = 0; k <= lastIndex && k < savedPaths.length && k < currentPaths.length; k++) {
                if (currentPaths[k] != savedPaths[k]) {
                  exactMatch = false;
                  break;
                }
              }
            }

            if (exactMatch) {
              checkpointState = data['state'] as Map<String, dynamic>?;
              checkpointResumeIndex = lastIndex + 1;
              checkpointPendingDeletes = (data['pendingDeletes'] as List?)?.cast<String>() ?? [];
              Logger.debug(
                  'RecordingsManager: Resuming from checkpoint — skipping $checkpointResumeIndex/${currentPaths.length} segments.');
            } else {
              // Segment list shifted: new downloads were added or processed segments
              // were deleted from disk between runs. Find the first segment whose
              // timestamp is strictly later than the last completed segment so we
              // skip already-processed bins without requiring index alignment.
              // VAD state cannot be safely restored (preceding paths changed) but
              // the draft files on disk bridge the conversation gap.
              final lastCompletedPath = lastIndex >= 0 && lastIndex < savedPaths.length ? savedPaths[lastIndex] : null;
              final lastCompletedTs = lastCompletedPath != null
                  ? (int.tryParse(lastCompletedPath.split('/').last.split('_').first) ?? 0)
                  : 0;

              if (lastCompletedTs > 946684800) {
                // Epoch-seconds threshold avoids matching uptime-tick filenames.
                final resumeIdx = currentPaths.indexWhere((p) {
                  final ts = int.tryParse(p.split('/').last.split('_').first) ?? 0;
                  return ts > lastCompletedTs;
                });
                if (resumeIdx >= 0) {
                  checkpointResumeIndex = resumeIdx;
                  checkpointState = null; // fresh VAD state — drafts on disk bridge the gap
                  checkpointPendingDeletes = (data['pendingDeletes'] as List?)?.cast<String>() ?? [];
                  Logger.debug(
                      'RecordingsManager: Checkpoint shifted — resuming at $resumeIdx/${currentPaths.length} (ts>$lastCompletedTs), fresh state.');
                } else {
                  Logger.debug('RecordingsManager: Checkpoint segment list changed — starting fresh.');
                  await checkpointFile.delete();
                }
              } else {
                Logger.debug('RecordingsManager: Checkpoint segment list changed — starting fresh.');
                await checkpointFile.delete();
              }
            }
          }
        } catch (e) {
          Logger.error('RecordingsManager: Checkpoint load failed ($e) — starting fresh.');
          try {
            await checkpointFile.delete();
          } catch (_) {}
        }

        final mainBatchRunner = VadBatchRunnerChannel();
        bool success = false;
        try {
          final receivePort = ReceivePort();
          final exitPort = ReceivePort();
          bool isolateDone = false;

          final startTime = DateTime.now();
          int processedBytes = segmentFileSizes.sublist(0, checkpointResumeIndex).fold<int>(0, (a, b) => a + b);

          _activeIsolate = await Isolate.spawn(
            processingIsolateEntry,
            IsolateParams(
              sendPort: receivePort.sendPort,
              rootIsolateToken: RootIsolateToken.instance!,
              sileroModelPath: sileroModelPath,
              settings: settingsOverride ?? ProcessingSettings.fromPrefs(),
              tempProcessingPath: tempProcessingPath,
              segmentPaths: allSegments.map((f) => f.path).toList(),
              segmentFileSizes: segmentFileSizes,
              segmentStartTimesMs: segmentStartTimesMs,
              segmentStartUptimesMs: segmentStartUptimesMs,
              segmentSessionIds: segmentSessionIds,
              segmentDerivedFlags: segmentDerivedFlags,
              segmentByteRanges: segmentByteRangesList,
              backgroundMode: backgroundMode,
              finalizeRemainingDirectly: finalizeRemainingDirectly,
              devLogsEnabled: SharedPreferencesUtil().devLogsToFileEnabled,
              checkpointState: checkpointState,
              checkpointResumeIndex: checkpointResumeIndex,
              checkpointPath: checkpointFile.path,
              checkpointPendingDeletes: checkpointPendingDeletes,
              // Disabled for Recover Discard: a recovered slice is a self-contained
              // clip and must not read or write live priority state.
              priorityStatePath: finalizeRemainingDirectly ? null : priorityLatchFile.path,
            ),
            onExit: exitPort.sendPort,
          );

          // If the isolate dies without sending 'done'/'error', close receivePort so we don't hang.
          exitPort.listen((_) {
            if (!isolateDone) receivePort.close();
            exitPort.close();
          });

          // Absolute bin paths that have been claimed by an in-flight discard
          // record this run. The delete_segments handler must skip these so the
          // recovery sweep (or AM) gets a chance to keep them around. Seeded with
          // [seedProtectedBinPaths] so a Recover run also preserves bins that
          // sibling discards still reference.
          final Set<String> discardProtectedPaths = {...seedProtectedBinPaths};

          // Absolute paths of bins still mid-transfer — never deletable, in any
          // mode (see the resolve above). `null` means the WAL state was
          // unreadable on a user-initiated run: status unknown for EVERY bin, so
          // nothing is deleted this pass. Retaining a consumed bin is the benign
          // direction — coverage keeps it from being re-decoded and the next
          // [pruneConsumedBins] reclaims it — while deleting a half-arrived one
          // costs a full re-download.
          final Set<String>? incompleteProtectedPaths =
              incompleteRelBins?.map((rel) => '${directory.path}/raw_segments/$rel').toSet();

          await for (final msg in receivePort) {
            if (msg is! Map) continue;
            switch (msg['type'] as String) {
              case 'control_port':
                _activeIsolateControlPort = msg['port'] as SendPort;
                // Forward a pending cancel if the user already called cancelProcessing().
                if (_cancelRequested) {
                  _activeIsolateControlPort?.send('cancel');
                }
              case 'vad_batch_init':
                try {
                  await mainBatchRunner.init(msg['modelPath'] as String);
                  if (mainBatchRunner.available) {
                    (msg['replyPort'] as SendPort).send('ok');
                  } else {
                    (msg['replyPort'] as SendPort).send('plugin_missing');
                  }
                } catch (e) {
                  (msg['replyPort'] as SendPort).send(e.toString());
                }
              case 'vad_batch_run':
                try {
                  final result = await mainBatchRunner.runVadBatch(
                    msg['samples'] as Float32List,
                    resetStateFirst: msg['resetStateFirst'] as bool,
                  );
                  (msg['replyPort'] as SendPort).send(result);
                } catch (e) {
                  (msg['replyPort'] as SendPort).send(e.toString());
                }
              case 'vad_batch_dispose':
                try {
                  await mainBatchRunner.dispose();
                  if (msg['replyPort'] != null) {
                    (msg['replyPort'] as SendPort).send('ok');
                  }
                } catch (e) {
                  if (msg['replyPort'] != null) {
                    (msg['replyPort'] as SendPort).send(e.toString());
                  }
                }
              case 'vad_status':
                // The isolate reports whether a VAD-wanted run fell back to AAD
                // (Silero unavailable). Persist so the UI can warn; auto-clears
                // when Silero loads again. Only sent on vadEnabled runs.
                final fallback = msg['fallback'] as bool? ?? false;
                if (SharedPreferencesUtil().lastVadFallbackActive != fallback) {
                  SharedPreferencesUtil().lastVadFallbackActive = fallback;
                }
                if (fallback) {
                  Logger.error('RecordingsManager: VAD requested but Silero unavailable — AAD fallback '
                      'active this run (every frame counts as speech; no on-phone silence split).');
                }
              case 'heartbeat':
                // Liveness from the decode/save loops — re-anchors the stall
                // watchdog so a slow-but-progressing run isn't killed as a wedge.
                processingLiveness.value++;
              case 'marker_edl':
                // Persist EDLs eagerly so a mid-run isolate death does not
                // strand markers in memory only (B3). A throw from any single
                // _writeMarkerEdl must NOT escape the receivePort loop — that
                // would kill move/delete_segments/done for the rest of the
                // batch. Log per-EDL failure and continue (D7).
                final items = (msg['items'] as List).cast<Map<String, dynamic>>();
                for (final edl in items) {
                  try {
                    await _writeMarkerEdl(directory.path, edl);
                  } catch (e) {
                    Logger.error('RecordingsManager: _writeMarkerEdl failed for ${edl['markerMs']}: $e');
                  }
                }
              case 'draft_hard_end':
                // A session-end stop whose recording is already on disk as a
                // `_draft`. Stamp the draft itself so the Phase 3 stitch pass
                // below closes it — and so a kill before that pass still leaves
                // the boundary recorded for the next run to act on.
                for (final markerMs in (msg['markerMs'] as List).cast<int>()) {
                  try {
                    await _markDraftHardEnded(directory.path, markerMs);
                  } catch (e) {
                    Logger.error('RecordingsManager: draft hard-end stamp failed for $markerMs: $e');
                  }
                }
              case 'discard_records':
                final items = (msg['items'] as List).cast<Map<String, dynamic>>();
                for (final rec in items) {
                  await _persistDiscardRecord(directory.path, rec);
                  for (final rel in (rec['relativeBins'] as List).cast<String>()) {
                    discardProtectedPaths.add('${directory.path}/raw_segments/$rel');
                  }
                }
                onRecordingFinalized?.call();
              case 'move':
                await moveTempFilesToLive();
              case 'delete_segments':
                final paths = (msg['paths'] as List).cast<String>();
                for (final path in paths) {
                  if (incompleteProtectedPaths == null) {
                    Logger.debug('RecordingsManager: retaining raw segment — sync status unknown: $path');
                    continue;
                  }
                  if (incompleteProtectedPaths.contains(path)) {
                    // Still arriving over BLE: this file is the next sync's resume
                    // target. Leave it exactly where it is — relocating it (as the
                    // discard branch below does) would break the resume just as
                    // surely as deleting it.
                    Logger.debug('RecordingsManager: retaining mid-transfer raw segment: $path');
                    continue;
                  }
                  if (discardProtectedPaths.contains(path)) {
                    // A discard claims this fully-processed bin → retain it OUT
                    // of the processing pool by relocating to discarded_segments/
                    // instead of leaving it in raw_segments/, where a Force
                    // Process could re-append it to a neighbour or the
                    // session-delete sweep could wipe it. No-op if already
                    // relocated (a sibling bin during Recover).
                    if (await retainDiscardBin(directory.path, path)) {
                      deletedSegmentFolders.add(File(path).parent.path);
                    }
                    continue;
                  }
                  final f = File(path);
                  if (await f.exists()) {
                    Logger.debug(
                      'RecordingsManager: Deleting raw segment: $path',
                    );
                    await f.delete();
                    deletedSegmentFolders.add(f.parent.path);
                  }
                }
              case 'progress':
                final segmentBytes = msg['processed_bytes'] as int;
                processedBytes += segmentBytes;
                final index = msg['index'] as int;
                final totalSegments = msg['total'] as int;

                final progressVal = rawTotalBytes > 0 ? processedBytes / rawTotalBytes : ((index + 1) / totalSegments);
                final progress = (progressVal * 0.9).clamp(0.0, 0.9);

                Duration? eta;
                if (progressVal >= 0.05 && processedBytes > 0) {
                  final elapsed = DateTime.now().difference(startTime);
                  final remainingBytes = rawTotalBytes - processedBytes;
                  final etaMs = (elapsed.inMilliseconds * remainingBytes) ~/ processedBytes;
                  eta = Duration(milliseconds: etaMs);
                }
                processingProgress.value = progressVal;
                onProgress(progress, eta);
              case 'done':
                isolateDone = true;
                success = true;
                final wasCancelled = msg['cancelled'] as bool? ?? false;
                receivePort.close();
                // Checkpoint preserved on cancel so the next run can resume from it.
                if (!wasCancelled) {
                  try {
                    if (await checkpointFile.exists()) await checkpointFile.delete();
                  } catch (_) {}
                }
              case 'error':
                isolateDone = true;
                receivePort.close();
                try {
                  if (await checkpointFile.exists()) await checkpointFile.delete();
                } catch (_) {}
                throw Exception(msg['message']);
            }
          }

          _activeIsolateControlPort = null;

          if (!success) {
            throw Exception('Isolate died prematurely without reporting completion.');
          }

          await Future.delayed(const Duration(milliseconds: 200));
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        } catch (e) {
          Logger.error("RecordingsManager: Combined processing failed: $e");
          rethrow;
        } finally {
          _activeIsolateControlPort = null;
          await mainBatchRunner.dispose();
        }

        // Clean up any device-session folders that are now empty after progressive deletion.
        for (final folderPath in deletedSegmentFolders) {
          final folder = Directory(folderPath);
          if (await folder.exists()) {
            try {
              if (await folder.list().isEmpty) await folder.delete();
            } catch (_) {}
          }
        }
      }

      // Phase 3: Post-Sync Stitch Pass
      // After processing is complete, look for drafts and stitch them if within threshold.
      final isM4a = SharedPreferencesUtil().audioSaveFormat == 'm4a';
      if (isM4a) isTranscoding.value = true;
      try {
        await _stitchDraftRecordings(finalizeAll: finalizeDrafts);
      } finally {
        isTranscoding.value = false;
      }

      onProgress(1.0, Duration.zero);
    } finally {
      _isProcessingAny = false;
      _activeIsolate = null;
      _activeIsolateControlPort = null;
      processingProgress.value = 0.0;
      isTranscoding.value = false;
      SharedPreferencesUtil().extractionInProgress = false;
    }
  }

  /// Scans for draft recordings across all dates and stitches them with subsequent
  /// recordings if the gap is within the 2-minute threshold.
  ///
  /// The chronological-next lookup is **global across date folders** so a
  /// recording that crossed local midnight (draft in day-N folder, next in
  /// day-(N+1) folder, since `_saveRecordingCore` places files by their
  /// `startTime.toLocal()` date) gets stitched into a single recording
  /// instead of two split files. `_stitchWav` keeps the draft's
  /// filename and folder, deleting nextFile wherever it lived.
  Future<void> _stitchDraftRecordings({bool finalizeAll = false}) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;

    final splitSeconds = SharedPreferencesUtil().vadSplitSeconds;
    // A threshold of 0 means "no silence-based boundary", NOT "every gap is a
    // boundary" — the same reading that made the VAD processor save one file per
    // 20 ms frame. Manual mode pins vadSplitSeconds to 0, and both look-ahead
    // tests below are `accumulated + gap >= thresholdMs` with both terms
    // non-negative (`gap < 0` is skipped just above the first one), so at 0 the
    // very first event examined finalizes the draft. That is why a manual
    // recording spanning two sync cycles came back as two recordings instead of
    // one: the draft was closed before the next cycle's audio could stitch onto
    // it. At 0 the boundary is the firmware's own 0xFFFFFFFC and nothing else.
    // Force Process is unaffected — it finalizes through its own `finalizeAll`
    // branches, not this one.
    final thresholdMs = splitSeconds > 0 ? splitSeconds * 1000 : null;

    // Drafts this call has already tried to close. Every finalize below sets
    // scanNeeded and re-scans, on the assumption the file is no longer a draft --
    // but _finalizeDraft swallows its own exceptions, so a rename that fails leaves
    // the draft on disk and the rescan finds it again, forever. Pre-existing shape;
    // the hard-boundary rules add two more paths into it, which is reason enough to
    // bound it. A successful finalize never revisits (the file stops matching
    // `_draft.`), so this only ever fires on failure.
    final finalizeAttempted = <String>{};

    bool scanNeeded = true;
    while (scanNeeded) {
      scanNeeded = false;

      final dateFolders = (await recordingsDir.list().toList()).whereType<Directory>().toList();

      // Build a single chronologically-sorted list of "events" (audio files and
      // ghost discards) across every date folder so the "next event after a
      // draft" lookup can cross day boundaries.
      final allAudioFiles = <File>[];
      for (final folder in dateFolders) {
        final entities = (await folder.list().toList()).whereType<File>().toList();
        allAudioFiles.addAll(entities.where((f) {
          final p = f.path;
          return (p.endsWith('.m4a') || p.endsWith('.wav')) && !p.contains('.tmp');
        }));
      }

      // Load all discard records across all dates to build the unified timeline.
      final allDiscards = <DiscardRecord>[];
      for (final folder in dateFolders) {
        final dateStr = folder.path.split('/').last;
        final folderDiscards = await getDiscardsForDate(dateStr);
        allDiscards.addAll(folderDiscards);
      }

      final allEvents = [
        ...allAudioFiles.map(
            (f) => (audio: f, discard: null as DiscardRecord?, timestamp: _extractTimestamp(f.path), durationMs: 0)),
        ...allDiscards.map((d) => (
              audio: null as File?,
              discard: d,
              timestamp: d.startTime.millisecondsSinceEpoch,
              durationMs: d.duration.inMilliseconds
            )),
      ];

      allEvents.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      final draftFiles = allAudioFiles.where((f) => f.path.contains('_draft.')).toList();
      if (draftFiles.isEmpty) break;

      for (final draftFile in draftFiles) {
        // Only skip a draft a previous pass already TRIED to finalize; a draft that
        // merely stitched must be revisited, since a chain folds several recordings
        // in across successive rescans.
        if (finalizeAttempted.contains(draftFile.path)) continue;
        final draftTs = _extractTimestamp(draftFile.path);
        final draftExt = draftFile.path.split('.').last;
        final draftMeta = File(draftFile.path.replaceAllMapped(RegExp(r'\.' + draftExt + r'$'), (_) => '.meta'));

        if (!await draftMeta.exists()) {
          // No meta, can't stitch accurately. Finalize it.
          finalizeAttempted.add(draftFile.path);
          await _finalizeDraft(draftFile, isForceSynced: finalizeAll);
          scanNeeded = true;
          break;
        }

        // Get draft duration from meta
        final metaBytes = await draftMeta.readAsBytes();
        if (metaBytes.length < 8) {
          finalizeAttempted.add(draftFile.path);
          await _finalizeDraft(draftFile, isForceSynced: finalizeAll);
          scanNeeded = true;
          break;
        }
        final durationMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
        final draftEndTs = draftTs + durationMs;

        // The draft already ends at a hard firmware boundary — it absorbed the
        // recording that closed at one, or was itself closed there. Nothing may be
        // appended, whatever the gap says. This is the half of the rule that
        // survives runs: the successor's own hardStart stamp is set in memory and
        // dies with the checkpoint when a run completes cleanly, which is exactly
        // what happens when the boundary is the last thing in the last synced bin.
        if (metaMarksHardEnd(metaBytes)) {
          Logger.debug('RecordingsManager: Finalizing draft $draftTs — it ends at a hard marker boundary.');
          // Not the bolt: that marks a draft a Force Process closed because nothing
          // followed it. This one closed because the device said it was over.
          finalizeAttempted.add(draftFile.path);
          await _finalizeDraft(draftFile, isForceSynced: false);
          scanNeeded = true;
          break;
        }

        // Find the next chronological event across all folders.
        final currentIndex = allEvents.indexWhere((e) => e.audio?.path == draftFile.path);
        if (currentIndex == -1 || currentIndex == allEvents.length - 1) {
          // No next event anywhere.
          if (finalizeAll) {
            // Manual user trigger (Force Process) always finalizes immediately.
            finalizeAttempted.add(draftFile.path);
            await _finalizeDraft(draftFile, isForceSynced: true);
            scanNeeded = true;
            break;
          }
          continue;
        }

        // Whether any real speech recording follows this draft anywhere in the
        // timeline. If not, the draft is the last actual recording and a Force
        // Process should mark it force-synced (bolt) — trailing discards/ghosts
        // after it don't count as "later audio".
        final hasLaterAudio = allEvents.skip(currentIndex + 1).any((e) => e.audio != null);

        // Look ahead and accumulate non-speech duration (gaps + ghosts)
        int accumulatedNonSpeechMs = 0;
        int currentPointerTs = draftEndTs;
        final intermediateEvents = <({File? audio, DiscardRecord? discard, int timestamp, int durationMs})>[];

        bool finalizeNow = false;
        File? audioToStitch;

        for (int i = currentIndex + 1; i < allEvents.length; i++) {
          final event = allEvents[i];
          final gap = event.timestamp - currentPointerTs;

          if (gap < 0) continue; // safety: ignore events that somehow overlap or precede

          if (thresholdMs != null && accumulatedNonSpeechMs + gap >= thresholdMs) {
            finalizeNow = true;
            break;
          }

          accumulatedNonSpeechMs += gap;

          if (event.audio != null) {
            audioToStitch = event.audio;
            break;
          } else if (event.discard != null) {
            if (thresholdMs != null && accumulatedNonSpeechMs + event.durationMs >= thresholdMs) {
              finalizeNow = true;
              break;
            }
            accumulatedNonSpeechMs += event.durationMs;
            currentPointerTs = event.timestamp + event.durationMs;
            intermediateEvents.add(event);
          }
        }

        if (finalizeNow) {
          Logger.debug(
              'RecordingsManager: Finalizing draft $draftTs — non-speech threshold (${thresholdMs}ms) exceeded.');
          // Bolt only when this is a Force Process and no speech follows — i.e.
          // the boundary was a trailing gap/discard, not a real next recording.
          finalizeAttempted.add(draftFile.path);
          await _finalizeDraft(draftFile, isForceSynced: finalizeAll && !hasLaterAudio);
          scanNeeded = true;
          break;
        }

        // A next recording that BEGINS at a hard firmware boundary is not
        // stitchable at any gap. The processor already cuts at 0xFFFFFFF8 /
        // 0xFFFFFFFC within a run, but it ends each run by flushing whatever is
        // open as a `_draft`, and the gap rule above then rejoins both sides of
        // that cut on the next pass — gap 0, since the audio really is
        // contiguous. That is how a 2 h Priority Recording surfaced as 2 h 18 m:
        // ~15 min of pre-tap auto conversation glued to its front and ~3 min of
        // post-stop audio to its back. Close the draft at the boundary instead.
        if (audioToStitch != null && await _startsAtHardBoundary(audioToStitch)) {
          Logger.debug('RecordingsManager: Finalizing draft $draftTs — next recording '
              '${audioToStitch.path.split('/').last} starts at a hard marker boundary.');
          // Never the bolt: a real recording demonstrably follows this draft.
          finalizeAttempted.add(draftFile.path);
          await _finalizeDraft(draftFile, isForceSynced: false);
          scanNeeded = true;
          break;
        }

        if (audioToStitch != null) {
          // Found speech within threshold! Stitch all intermediate ghosts and then the speech file.
          int lastEndTs = draftEndTs;
          bool success = true;

          for (final inter in intermediateEvents) {
            final gap = inter.timestamp - lastEndTs;
            final interSuccess = await _stitchDiscard(draftFile, inter.discard!, gap);
            if (!interSuccess) {
              success = false;
              break;
            }
            lastEndTs = inter.timestamp + inter.durationMs;
          }

          if (success) {
            final int nextTs = allEvents.firstWhere((e) => e.audio == audioToStitch).timestamp;

            // Re-read meta since it may have been updated by _stitchDiscard
            final updatedMetaBytes = await draftMeta.readAsBytes();
            final updatedDurationMs = ByteData.sublistView(updatedMetaBytes).getUint32(4, Endian.little);
            final updatedEndTs = draftTs + updatedDurationMs;
            final gapToAudio = nextTs - updatedEndTs;

            // Clock jump check
            bool isClockJump = false;
            final nextMeta = File(audioToStitch.path.replaceAllMapped(RegExp(r'\.' + draftExt + r'$'), (_) => '.meta'));
            if (await nextMeta.exists()) {
              try {
                final nextMetaBytes = await nextMeta.readAsBytes();
                if (updatedMetaBytes.length >= 416 && nextMetaBytes.length >= 416) {
                  final dSid = ByteData.sublistView(updatedMetaBytes).getUint32(408, Endian.little);
                  final nSid = ByteData.sublistView(nextMetaBytes).getUint32(408, Endian.little);
                  final dUp = ByteData.sublistView(updatedMetaBytes).getUint32(412, Endian.little);
                  final nUp = ByteData.sublistView(nextMetaBytes).getUint32(412, Endian.little);

                  if (dSid == nSid && dUp > 0 && nUp > dUp) {
                    final uGap = (nUp * 1000) - ((dUp * 1000) + updatedDurationMs);
                    if (uGap.abs() < 5000 && gapToAudio.abs() > 10000) isClockJump = true;
                  }
                }
              } catch (_) {}
            }

            final gapMs = (isClockJump || gapToAudio < 10000) ? 0 : gapToAudio;
            if (draftExt == 'wav') {
              Logger.debug(
                  'RecordingsManager: Stitching draft $draftTs with next ${audioToStitch.path.split('/').last} (gap=${gapMs}ms)');
            } else {
              Logger.debug('RecordingsManager: Converting draft $draftTs — $draftExt cannot be stitched, finalizing');
            }
            final finalSuccess = await _performStitch(draftFile, audioToStitch, gapMs);
            if (finalSuccess) {
              // The folded ghosts' audio now lives in this conversation — retire
              // their discard records (and the bins they solely own) so they stop
              // showing as recoverable rows that would re-derive a duplicate
              // slice. WAV-only: the M4A path stitches silence, not real audio,
              // so its ghosts stay recoverable.
              if (draftExt == 'wav' && intermediateEvents.isNotEmpty) {
                await retireFoldedGhosts(intermediateEvents.map((e) => e.discard!).toList());
              }
              scanNeeded = true;
              break;
            }
          }
        } else if (finalizeAll) {
          // Force Process and the only events after this draft are trailing
          // discards/ghosts under threshold (no speech follows). The draft is
          // the last actual recording, so finalize it now with the bolt instead
          // of leaving it open as a draft.
          Logger.debug('RecordingsManager: Force-finalizing draft $draftTs — only trailing discards follow (bolt).');
          finalizeAttempted.add(draftFile.path);
          await _finalizeDraft(draftFile, isForceSynced: true);
          scanNeeded = true;
          break;
        }
      }
    }
  }

  /// True when [audioFile]'s `.meta` marks it as beginning at a hard firmware
  /// boundary — a 0xFFFFFFF8 Priority Recording start, or the audio that resumed
  /// after a 0xFFFFFFFC stop. Missing/short/unreadable meta answers false, which
  /// is the pre-feature behaviour (stitch on the gap rule alone).
  Future<bool> _startsAtHardBoundary(File audioFile) async {
    final meta = File(audioFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta'));
    try {
      if (!await meta.exists()) return false;
      return metaMarksHardStart(await meta.readAsBytes());
    } catch (e) {
      Logger.error('RecordingsManager: hard-start read failed for ${meta.path}: $e');
      return false;
    }
  }

  /// Reads the `hardStart` bit (0x02) out of the fourth flag byte of a `.meta`.
  /// Written by `VadAudioProcessor._saveMetadata`, which documents why the flags
  /// share that byte with `isSilero` instead of taking bytes of their own.
  @visibleForTesting
  static bool metaMarksHardStart(Uint8List metaBytes) => _metaFlagBit(metaBytes, 0x02);

  /// Reads the `hardEnd` bit (0x04). The durable half of a boundary: [hardStart]
  /// can only be carried by a recording that gets written, and the audio after a
  /// boundary often arrives runs later (the firmware rotates the bin at a priority
  /// stop, so the successor is in the bin a sync cannot fetch yet).
  @visibleForTesting
  static bool metaMarksHardEnd(Uint8List metaBytes) => _metaFlagBit(metaBytes, 0x04);

  static bool _metaFlagBit(Uint8List metaBytes, int mask) {
    if (metaBytes.length < 417) return false;
    final flagOffset = 417 + metaBytes[416];
    if (metaBytes.length <= flagOffset + 3) return false;
    return (metaBytes[flagOffset + 3] & mask) != 0;
  }

  /// Stamps the `hardEnd` bit onto the newest `_draft` starting at or before
  /// [markerMs] — the recording a 0xFFFFFFFC stop closed, in the case where the
  /// run that wrote that draft had already finished by the time the stop's own
  /// bin arrived. [metaMarksHardEnd] is then all [_stitchDraftRecordings] needs
  /// to close it, and the bit is on disk, so a kill before that pass loses
  /// nothing.
  ///
  /// Newest-before-the-marker rather than every draft: several can coexist (a
  /// run interrupted mid-conversation leaves one behind), and a stop ends only
  /// the recording immediately preceding it. Drafts that start after the marker
  /// hold audio the device captured later and must stay open.
  Future<void> _markDraftHardEnded(String docsPath, int markerMs) async {
    final recordingsDir = Directory('$docsPath/recordings');
    if (!await recordingsDir.exists()) return;

    File? newest;
    int newestTs = -1;
    for (final folder in (await recordingsDir.list().toList()).whereType<Directory>()) {
      for (final f in (await folder.list().toList()).whereType<File>()) {
        final p = f.path;
        if (!p.contains('_draft.') || !(p.endsWith('.wav') || p.endsWith('.m4a'))) continue;
        final ts = _extractTimestamp(p);
        if (ts <= 0 || ts > markerMs || ts <= newestTs) continue;
        newestTs = ts;
        newest = f;
      }
    }
    if (newest == null) {
      Logger.debug('RecordingsManager: session-end stop at $markerMs — no open draft precedes it, nothing to close.');
      return;
    }

    final meta = File(newest.path.replaceAll(RegExp(r'\.(m4a|wav|ogg)$'), '.meta'));
    // A draft with no (or a truncated) `.meta` is already finalized unconditionally
    // by _stitchDraftRecordings — there is nothing to carry the bit on, and nothing
    // that needs it.
    if (!await meta.exists()) return;
    final bytes = await meta.readAsBytes();
    // A meta long enough to pass _stitchDraftRecordings' own `< 8` finalize but too
    // short to carry flags (a torn write) would otherwise be dropped in silence —
    // and silence here looks exactly like the bug this method exists to fix, so say
    // so. Nothing else will close this draft but Force Process.
    if (bytes.length < 417 || bytes.length <= 417 + bytes[416] + 3) {
      Logger.error('RecordingsManager: draft $newestTs has a ${bytes.length} B meta with no flag bytes — '
          'cannot mark the hard end; it stays open until Force Process.');
      return;
    }
    final flagOffset = 417 + bytes[416];
    bytes[flagOffset + 3] |= 0x04;
    await meta.writeAsBytes(bytes, flush: true);
    Logger.debug('RecordingsManager: session-end stop at $markerMs — draft $newestTs marked as ending at a hard '
        'marker boundary.');
  }

  @visibleForTesting
  Future<void> markDraftHardEndedForTest(String docsPath, int markerMs) => _markDraftHardEnded(docsPath, markerMs);

  @visibleForTesting
  Future<void> stitchDraftRecordingsForTest({bool finalizeAll = false}) =>
      _stitchDraftRecordings(finalizeAll: finalizeAll);

  /// Appends the audio from a [DiscardRecord] (ghost) into the [draftFile],
  /// preceded by [gapMs] of silence.
  Future<bool> _stitchDiscard(File draftFile, DiscardRecord ghost, int gapMs) async {
    // Muted intervals (and any bin-less ghost) have no audio to recover/stitch.
    if (ghost.relativeBins.isEmpty) return false;
    final ext = draftFile.path.split('.').last;
    final directory = await getApplicationDocumentsDirectory();

    try {
      // 1. Re-process the ghost bins into a temporary audio file of the same format
      final tempAudio = File('${draftFile.parent.path}/ghost_${ghost.startTime.millisecondsSinceEpoch}.tmp.$ext');
      if (await tempAudio.exists()) await tempAudio.delete();

      final decoder = SimpleOpusDecoder(
        sampleRate: 16000,
        channels: 1,
      );
      try {
        if (ext == 'wav') {
          final sink = await tempAudio.open(mode: FileMode.write);
          // Placeholder 44-byte WAV header, fixed up later by _stitchWav/_mergeMeta
          await sink.writeFrom(Uint8List(44));

          for (final relPath in ghost.relativeBins) {
            // Resolve discarded_segments-first: a fully-processed ghost's bin has
            // been relocated out of raw_segments/, so the old hardcoded
            // raw_segments/ path would miss it and silently stitch silence.
            final bin = await resolveDiscardBin(directory.path, relPath);
            if (!await bin.exists()) continue;

            final bytes = await bin.readAsBytes();
            final byteData = ByteData.sublistView(bytes);

            // Byte-slice to the discard's OWN recorded ranges, mirroring
            // _recoverDiscardCore: a bin shared with a neighbouring recording must
            // contribute only the discard's bytes — a whole-bin decode would fold
            // the neighbour's audio into the conversation too (the overlap bug the
            // Recover path already fixed). A legacy record with no ranges falls
            // back to a whole-bin decode.
            final ranges = ghost.binRanges[relPath] ?? const <List<int>>[];
            final sliced = ranges.isNotEmpty;
            int offset = sliced ? ranges.first[0] : 0;
            final decodeUntil = sliced ? min(ranges.last[1], bytes.length) : bytes.length;

            while (offset < decodeUntil) {
              // Jump the read head over the gaps between disjoint slices so audio
              // between two discarded stretches (owned by a recording) is skipped.
              if (sliced) {
                offset = nextSliceOffset(ranges, offset);
                if (offset < 0 || offset >= decodeUntil) break;
              }
              if (offset + 4 > bytes.length) break;
              final frameLen = byteData.getUint32(offset, Endian.little);
              if (frameLen == 0 || frameLen == 0xFFFFFFFF) {
                offset += 4;
                continue;
              }
              // Skip all inline control frames: metadata header 0xFFFFFFFB (36 B)
              // and every 20-B marker 0xFFFFFFF8..0xFFFFFFFE (priority-start,
              // mute-off, mute-on, session-end, VAD-resume, button-tap). The old
              // >= 0xFFFFFFFB bound let mute (F9/FA) and priority-start (F8)
              // markers fall through and be decoded as garbage opus.
              if (frameLen >= 0xFFFFFFF8) {
                offset += (frameLen == 0xFFFFFFFB ? 36 : 20);
                continue;
              }
              if (offset + 4 + frameLen > bytes.length) break;

              final opus = Uint8List.sublistView(bytes, offset + 4, offset + 4 + frameLen);
              try {
                final pcm = decoder.decode(input: opus);
                await sink.writeFrom(pcm.buffer.asUint8List());
              } catch (_) {}
              offset += 4 + ((frameLen + 3) & ~3);
            }
          }
          await sink.close();
        } else {
          // M4A: We don't have a high-level M4A encoder on the main isolate.
          // Fall back to silence-only stitching for this format to maintain timeline.
          return await _stitchSilence(draftFile, gapMs + ghost.duration.inMilliseconds);
        }
      } finally {
        decoder.destroy();
      }

      if (await tempAudio.exists() && (await tempAudio.length()) > 44) {
        final success = await _performStitch(draftFile, tempAudio, gapMs);
        if (await tempAudio.exists()) await tempAudio.delete();
        return success;
      } else {
        return await _stitchSilence(draftFile, gapMs + ghost.duration.inMilliseconds);
      }
    } catch (e) {
      Logger.error('RecordingsManager: Ghost stitch failed ($e) — falling back to silence');
      return await _stitchSilence(draftFile, gapMs + ghost.duration.inMilliseconds);
    }
  }

  Future<bool> _stitchSilence(File draftFile, int durationMs) async {
    if (durationMs <= 0) return true;
    final ext = draftFile.path.split('.').last;
    if (ext != 'wav') {
      // For compressed formats, we just update the metadata duration;
      // chaining doesn't physically pad silence.
      await _mergeMeta(draftFile, null, durationMs);
      return true;
    }

    try {
      final sink = await draftFile.open(mode: FileMode.append);
      // 16kHz, 16-bit mono = 32000 bytes/sec
      final silenceBytes = Uint8List((durationMs * 32).toInt());
      await sink.writeFrom(silenceBytes);
      await sink.close();
      await _mergeMeta(draftFile, null, durationMs);
      return true;
    } catch (e) {
      Logger.error('RecordingsManager: Silence stitch failed: $e');
      return false;
    }
  }

  int _extractTimestamp(String path) {
    final name = path.split('/').last;
    final nameNoExt = name.split('.').first;
    final parts = nameNoExt.split('_');
    if (parts.length < 2) return 0;

    // Format: recording_<ts> or recording_<ts>_draft
    final tsStr = parts.contains('draft') ? parts[parts.length - 2] : parts.last;
    return int.tryParse(tsStr) ?? 0;
  }

  Future<void> _finalizeDraft(File file, {bool isForceSynced = false}) async {
    final path = file.path;
    if (!path.contains('_draft.')) return;
    final currentExt = path.split('.').last;
    final targetExt = SharedPreferencesUtil().audioSaveFormat;
    final oldFilename = path.split('/').last;

    final metaPath = path.replaceAll(RegExp(r'\.(m4a|wav|ogg)$'), '.meta');

    try {
      String finalAudioPath;
      bool transcoded = false;

      if (currentExt == 'wav' && targetExt == 'm4a') {
        // Transcode from WAV to M4A
        finalAudioPath = path.replaceAll('_draft.wav', '.m4a');
        if (await File(finalAudioPath).exists()) await File(finalAudioPath).delete();

        final success = await _transcodeWavToM4a(file, finalAudioPath);
        if (success) {
          await file.delete();
          transcoded = true;
        } else {
          finalAudioPath = path.replaceAll('_draft.', '.');
          if (await File(finalAudioPath).exists()) await File(finalAudioPath).delete();
          await file.rename(finalAudioPath);
        }
      } else {
        finalAudioPath = path.replaceAll('_draft.', '.');
        if (await File(finalAudioPath).exists()) await File(finalAudioPath).delete();
        await file.rename(finalAudioPath);
      }

      final newFilename = finalAudioPath.split('/').last;
      final newMetaPath = metaPath.replaceAll('_draft.', '.');

      if (await File(metaPath).exists()) {
        final bytes = await File(metaPath).readAsBytes();
        var outBytes = bytes;

        // 1. Update flags (passthrough, forceSynced, capEnded).
        // Layout at flagOffset: [0]=passthrough, [1]=forceSynced, [2]=capEnded.
        // capEnded is set by VAD when the recording was written; we preserve it across
        // draft promotion (Force Process / stitch fallback should not relabel a cap-end
        // recording as silence-end).
        if (bytes.length >= 417) {
          final keyLen = bytes[416];
          final flagOffset = 417 + keyLen;
          if (bytes.length < flagOffset + 3) {
            // Extend to fit all 3 flag bytes, preserving any existing earlier bytes.
            final existingPassthrough = (bytes.length > flagOffset) ? bytes[flagOffset] : 0;
            final existingCapEnded = (bytes.length > flagOffset + 2) ? bytes[flagOffset + 2] : 0;
            final newBytes = Uint8List(flagOffset + 3);
            newBytes.setRange(0, bytes.length, bytes);
            newBytes[flagOffset] = existingPassthrough;
            newBytes[flagOffset + 1] = isForceSynced ? 1 : 0;
            newBytes[flagOffset + 2] = existingCapEnded;
            outBytes = newBytes;
          } else {
            outBytes[flagOffset + 1] = isForceSynced ? 1 : 0;
            // capEnded byte preserved as-is at flagOffset + 2.
          }
        }

        // 2. Update uploadKey extension if transcoded
        if (transcoded) {
          final keyLen = outBytes[416];
          final key = String.fromCharCodes(outBytes, 417, 417 + keyLen);
          final newKey = key.replaceAll('.$currentExt', '.m4a');
          final newKeyBytes = Uint8List.fromList(newKey.codeUnits);

          final builder = BytesBuilder();
          builder.add(outBytes.sublist(0, 416));
          builder.addByte(newKeyBytes.length);
          builder.add(newKeyBytes);
          if (outBytes.length > 417 + keyLen) {
            builder.add(outBytes.sublist(417 + keyLen));
          }
          outBytes = builder.takeBytes();
        }

        if (await File(newMetaPath).exists()) await File(newMetaPath).delete();
        await File(newMetaPath).writeAsBytes(outBytes);
        await File(metaPath).delete();
      }

      // Update any .edl files that were pointing to this draft
      int? finalDurationMs;
      try {
        final metaBytes = await File(newMetaPath).readAsBytes();
        if (metaBytes.length >= 8) {
          finalDurationMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
        }
      } catch (_) {}

      final dir = file.parent;
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        for (final entity in entities) {
          if (entity is File && entity.path.endsWith('.edl')) {
            try {
              final content = await entity.readAsString();
              final json = jsonDecode(content) as Map<String, dynamic>;
              if (json['segmentFilename'] == oldFilename) {
                json['segmentFilename'] = newFilename;
                // Only overwrite cropEndMs when the user has NOT customized
                // the crop window. _reanchorMarkerEdls may have shifted
                // cropStart/End into a smaller user-saved range earlier in
                // this stitch chain; blindly resetting cropEndMs to full
                // duration destroys those edits (NEW2/C2).
                if (finalDurationMs != null) {
                  final userSaved = json['userSaved'] as bool? ?? false;
                  final cropStart = json['cropStartMs'] as int? ?? 0;
                  final cropEnd = json['cropEndMs'] as int? ?? 0;
                  final isDefaultCrop = !userSaved && cropStart == 0;
                  if (isDefaultCrop) {
                    json['cropEndMs'] = finalDurationMs;
                  } else if (cropEnd > finalDurationMs) {
                    // Preserve user crop but clamp to playable length.
                    json['cropEndMs'] = finalDurationMs;
                  }
                }
                await _writeJsonAtomic(entity, json);
                Logger.debug('RecordingsManager: Updated EDL ${entity.path} for finalized draft');
              }
            } catch (e) {
              Logger.error('RecordingsManager: Failed to update EDL ${entity.path}: $e');
            }
          }
        }
      }

      Logger.debug('RecordingsManager: Finalized draft $path -> $finalAudioPath');
    } catch (e) {
      Logger.error('RecordingsManager: Failed to finalize draft $path: $e');
    }
  }

  Future<bool> _transcodeWavToM4a(File wavFile, String m4aPath) async {
    String? sessionId;
    try {
      final bytes = await wavFile.readAsBytes();
      if (bytes.length < 44) return false;

      final data = ByteData.sublistView(bytes);
      final sampleRate = data.getUint32(24, Endian.little);
      // View past the 44-byte WAV header instead of deep-copying the entire PCM payload
      // (can be many MB for long recordings). `bytes` is read-only after readAsBytes().
      final pcmBytes = Uint8List.sublistView(bytes, 44);

      sessionId = await AacEncoder.startEncoder(sampleRate, m4aPath);
      const chunkSize = 4096;
      for (int i = 0; i < pcmBytes.length; i += chunkSize) {
        final end = (i + chunkSize > pcmBytes.length) ? pcmBytes.length : i + chunkSize;
        // View, not copy: encodeBuffer marshals synchronously over the MethodChannel.
        await AacEncoder.encodeBuffer(sessionId, Uint8List.sublistView(pcmBytes, i, end));
      }
      await AacEncoder.finishEncoder(sessionId);
      return true;
    } catch (e) {
      Logger.error('RecordingsManager: Transcoding failed: $e');
      if (sessionId != null) {
        try {
          await AacEncoder.finishEncoder(sessionId);
        } catch (_) {}
      }
      return false;
    }
  }

  Future<bool> _performStitch(File draftFile, File nextFile, int gapMs) async {
    final ext = draftFile.path.split('.').last;
    if (nextFile.path.split('.').last != ext) {
      // Cannot stitch different formats easily. Finalize.
      await _finalizeDraft(draftFile);
      return false;
    }

    try {
      if (ext == 'wav') {
        return await _stitchWav(draftFile, nextFile, gapMs);
      } else if (ext == 'm4a') {
        // M4A stitching requires decode/re-encode which we can't do easily here.
        // Finalize and start fresh.
        await _finalizeDraft(draftFile);
        return false;
      }
    } catch (e) {
      Logger.error('RecordingsManager: Stitch failed: $e');
      await _finalizeDraft(draftFile);
    }
    return false;
  }

  Future<bool> _stitchWav(File draftFile, File nextFile, int gapMs) async {
    // Read draft, skip header to get PCM.
    final draftBytes = await draftFile.readAsBytes();
    final nextBytes = await nextFile.readAsBytes();

    if (draftBytes.length < 44 || nextBytes.length < 44) return false;

    final int? draftDurationMsOrNull = await _readMetaDurationMs(draftFile);
    if (draftDurationMsOrNull == null) {
      Logger.error(
          'RecordingsManager: _stitchWav aborting — missing/short meta for ${draftFile.path}; finalizing draft to preserve marker offsets');
      await _finalizeDraft(draftFile);
      return false;
    }
    final int draftDurationMs = draftDurationMsOrNull;

    const sampleRate = 16000;
    const channels = 1;
    final silenceSamples = (gapMs * sampleRate) ~/ 1000;
    final silenceBytes = Uint8List(silenceSamples * channels * 2);

    final combinedPcm = BytesBuilder();
    // Views past the WAV headers: BytesBuilder.add() copies (copy:true default), so the
    // prior sublist() was a redundant full-payload deep copy on top of that copy.
    combinedPcm.add(Uint8List.sublistView(draftBytes, 44));
    combinedPcm.add(silenceBytes);
    combinedPcm.add(Uint8List.sublistView(nextBytes, 44));

    final totalPcmBytes = combinedPcm.length;
    final header = _generateWavHeader(totalPcmBytes, sampleRate, channels);

    final outSink = draftFile.openWrite();
    outSink.add(header);
    outSink.add(combinedPcm.takeBytes());
    await outSink.close();

    // Update Meta
    await _mergeMeta(draftFile, nextFile, gapMs);

    final reanchorOk = await _reanchorMarkerEdls(
      fromFilename: nextFile.path.split('/').last,
      toFilename: draftFile.path.split('/').last,
      offsetShiftMs: draftDurationMs + gapMs,
      newDurationMs: await _readMetaDurationMs(draftFile),
      folders: [draftFile.parent, nextFile.parent],
    );

    if (!reanchorOk) {
      Logger.error('RecordingsManager: _stitchWav leaving ${nextFile.path} undeleted — re-anchor had errors');
      return true;
    }

    // Delete next (and merge Omi bin so the upload sends the full recording)
    await _stitchBinIfPresent(draftFile, nextFile);
    await nextFile.delete();
    final nextMeta = File(nextFile.path.replaceAll(RegExp(r'\.wav$'), '.meta'));
    if (await nextMeta.exists()) await nextMeta.delete();

    return true;
  }

  /// Appends [nextFile]'s raw Opus bin to [draftFile]'s bin, then deletes the next bin.
  /// No-op if either bin is absent (Omi disabled, or first run predates this fix).
  Future<void> _stitchBinIfPresent(File draftFile, File nextFile) async {
    final draftTs = _extractTimestamp(draftFile.path);
    final nextTs = _extractTimestamp(nextFile.path);
    if (draftTs == 0 || nextTs == 0) return;

    final draftBin = File('${draftFile.parent.path}/recording_fs320_$draftTs.bin');
    final nextBin = File('${nextFile.parent.path}/recording_fs320_$nextTs.bin');

    if (!await nextBin.exists() || !await draftBin.exists()) return;

    try {
      final nextBytes = await nextBin.readAsBytes();
      final sink = await draftBin.open(mode: FileMode.append);
      await sink.writeFrom(nextBytes);
      await sink.close();
      await nextBin.delete();
      Logger.debug('RecordingsManager: Stitched Omi bin $draftTs ← $nextTs (+${nextBytes.length} B)');
    } catch (e) {
      Logger.error('RecordingsManager: _stitchBinIfPresent failed: $e');
    }
  }

  /// Reads the `.meta` sidecar's 4-byte LE duration (offset 4). Returns null
  /// if the sidecar is missing or too short.
  Future<int?> _readMetaDurationMs(File audioFile) async {
    try {
      final base = audioFile.path.substring(0, audioFile.path.lastIndexOf('.'));
      final metaBytes = await File('$base.meta').readAsBytes();
      if (metaBytes.length < 8) return null;
      return ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
    } catch (_) {
      return null;
    }
  }

  /// Re-points any EDL in [folders] whose `segmentFilename == fromFilename`
  /// to [toFilename], shifting `markerOffsetMs` by [offsetShiftMs] (the
  /// draft's wall-clock duration + inter-file gap). Returns true iff every
  /// matching EDL was rewritten successfully — the caller should refuse to
  /// delete `fromFilename` if this returns false (D2).
  ///
  /// Crop bounds are shifted ONLY when the EDL was user-saved or had a
  /// non-default crop (NEW6/E5); for unset-default crops the shift would
  /// hide the entire stitched-in prefix from the player's visible window.
  ///
  /// Scans every folder in [folders] so cross-day-folder stitches don't
  /// orphan EDLs that live under the next file's date (NEW5/E3).
  Future<bool> _reanchorMarkerEdls({
    required String fromFilename,
    required String toFilename,
    required int offsetShiftMs,
    int? newDurationMs,
    required List<Directory> folders,
  }) async {
    bool allOk = true;
    final seenFolders = <String>{};
    for (final folder in folders) {
      if (!seenFolders.add(folder.path)) continue;
      if (!await folder.exists()) continue;
      final entities = await folder.list().toList();
      for (final entity in entities) {
        if (entity is! File || !entity.path.endsWith('.edl')) continue;
        Map<String, dynamic>? json;
        try {
          json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        } catch (e) {
          Logger.error('RecordingsManager: Failed to read EDL ${entity.path} during reanchor: $e');
          continue; // not a target EDL by definition; safe to skip
        }
        if (json['segmentFilename'] != fromFilename) continue;
        try {
          final userSaved = json['userSaved'] as bool? ?? false;
          final origCropStart = json['cropStartMs'] as int? ?? 0;
          final origCropEnd = json['cropEndMs'] as int? ?? 0;
          // "Default" crop = start==0 and end is either 0 or the original
          // nextFile duration (the value _writeMarkerEdl sets at first write).
          // Only shift when the user actually committed an edit.
          final isDefaultCrop = !userSaved && origCropStart == 0;
          json['segmentFilename'] = toFilename;
          json['markerOffsetMs'] = (json['markerOffsetMs'] as int? ?? 0) + offsetShiftMs;
          if (!isDefaultCrop) {
            json['cropStartMs'] = origCropStart + offsetShiftMs;
            json['cropEndMs'] = origCropEnd + offsetShiftMs;
            if (newDurationMs != null && newDurationMs > 0) {
              if ((json['cropEndMs'] as int) > newDurationMs) json['cropEndMs'] = newDurationMs;
              if ((json['cropStartMs'] as int) > newDurationMs) json['cropStartMs'] = newDurationMs;
            }
          } else if (newDurationMs != null && newDurationMs > 0) {
            // Default crop covers the combined file end-to-end.
            json['cropStartMs'] = 0;
            json['cropEndMs'] = newDurationMs;
          }
          await _writeJsonAtomic(entity, json);
          Logger.debug(
              'RecordingsManager: Re-anchored EDL ${entity.path.split('/').last}: $fromFilename → $toFilename (+${offsetShiftMs}ms)${isDefaultCrop ? " [default crop]" : " [preserved crop]"}');
        } catch (e) {
          Logger.error('RecordingsManager: Failed to re-anchor EDL ${entity.path}: $e');
          allOk = false; // signal caller to leave nextFile in place for recovery
        }
      }
    }
    return allOk;
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

  Future<void> _mergeMeta(File draftFile, File? nextFile, int gapMs) async {
    final draftMetaPath = draftFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta');
    final draftMetaFile = File(draftMetaPath);
    if (!await draftMetaFile.exists()) return;

    final dBytes = await draftMetaFile.readAsBytes();
    if (dBytes.length < 8) return;

    final dMeta = ByteData.sublistView(dBytes);
    const sampleRate = 16000;
    final dSamples = dMeta.getUint32(0, Endian.little);
    final gapSamples = (gapMs * sampleRate) ~/ 1000;

    int nSamples = 0;
    Uint8List? nBytes;
    if (nextFile != null) {
      final nextMetaPath = nextFile.path.replaceAll(RegExp(r'\.(ogg|wav|m4a)$'), '.meta');
      final nextMetaFile = File(nextMetaPath);
      if (await nextMetaFile.exists()) {
        nBytes = await nextMetaFile.readAsBytes();
        if (nBytes.length >= 8) {
          nSamples = ByteData.sublistView(nBytes).getUint32(0, Endian.little);
        }
      }
    }

    final totalSamples = dSamples + gapSamples + nSamples;
    final totalDurationMs = (totalSamples * 1000) ~/ sampleRate;

    // We reuse the existing draft meta buffer to preserve all flags, keys, and bin refs.
    // Only the first 8 bytes (samples, duration) and potentially peaks are updated.
    final outBytes = Uint8List.fromList(dBytes);
    final outData = ByteData.view(outBytes.buffer);

    outData.setUint32(0, totalSamples, Endian.little);
    outData.setUint32(4, totalDurationMs, Endian.little);

    // Merge peaks if we have a next file with peaks
    if (nBytes != null && nBytes.length >= 408 && dBytes.length >= 408) {
      final nMeta = ByteData.sublistView(nBytes);
      for (int i = 0; i < 200; i++) {
        final p1 = dMeta.getUint16(8 + i * 2, Endian.little);
        final p2 = nMeta.getUint16(8 + i * 2, Endian.little);
        outData.setUint16(8 + i * 2, max(p1, p2), Endian.little);
      }
    }

    // Carry the appended recording's hardEnd onto the draft. The draft's own flag
    // bytes are otherwise preserved wholesale, so without this the boundary would be
    // dropped the moment the recording that ended at it is folded in — and the next
    // pass would happily append across it.
    if (nBytes != null && metaMarksHardEnd(nBytes) && outBytes.length >= 417) {
      final flagOffset = 417 + outBytes[416];
      if (outBytes.length > flagOffset + 3) outBytes[flagOffset + 3] |= 0x04;
    }

    await draftMetaFile.writeAsBytes(outBytes, flush: true);
  }

  static String fmtDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  /// Atomically writes JSON to [target]: write to `<target>.tmp` then rename,
  /// so a concurrent reader never observes a truncated/partial file (NEW3/C5).
  /// Static + public so the marker player's crop-save path (which runs on the
  /// main isolate, not through this manager instance) shares the same
  /// crash-safety as the isolate EDL writers instead of a raw writeAsString.
  static Future<void> writeJsonAtomic(File target, Object payload) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(target.path);
  }

  Future<void> _writeJsonAtomic(File target, Object payload) => writeJsonAtomic(target, payload);

  @visibleForTesting
  Future<void> writeMarkerEdlTest(String docsPath, Map<String, dynamic> edl) => _writeMarkerEdl(docsPath, edl);

  @visibleForTesting
  Future<bool> reanchorMarkerEdlsTest({
    required String fromFilename,
    required String toFilename,
    required int offsetShiftMs,
    int? newDurationMs,
    required List<Directory> folders,
  }) =>
      _reanchorMarkerEdls(
        fromFilename: fromFilename,
        toFilename: toFilename,
        offsetShiftMs: offsetShiftMs,
        newDurationMs: newDurationMs,
        folders: folders,
      );

  /// Persists one marker EDL sidecar. Called eagerly per `marker_edl`
  /// isolate message so an isolate crash mid-run still leaves the marker
  /// on disk.
  ///
  /// Collision policy when an EDL already exists at `marker_<ms>.edl`:
  ///   1. If existing EDL was user-saved (cropped or explicit Save),
  ///      preserve it untouched — just update its segmentFilename to track
  ///      the rename (B3). User edits never get orphaned to `_<n>.edl`.
  ///   2. Same markerMs + same segmentFilename → noop.
  ///   3. Otherwise the new write lands at `marker_<ms>_<n>.edl`.
  Future<void> _writeMarkerEdl(String docsPath, Map<String, dynamic> edl) async {
    final filename = (edl['filename'] as String?) ?? '';
    final markerMs = edl['markerMs'] as int;
    final offsetMs = edl['offsetMs'] as int;
    final durationMs = edl['durationMs'] as int;
    final isHighPriority = (edl['isHighPriority'] as bool?) ?? false;

    int? millis;
    if (filename.isNotEmpty) {
      final nameNoExt = filename.contains('.') ? filename.substring(0, filename.lastIndexOf('.')) : filename;
      final parts = nameNoExt.split('_');
      final tsStr = parts.contains('draft') ? parts[parts.length - 2] : parts.last;
      millis = int.tryParse(tsStr);
    }
    final dateStr =
        (millis != null && millis > 946684800000) ? _dateStringFromMillis(millis) : _dateStringFromMillis(markerMs);
    final liveDir = Directory('$docsPath/recordings/$dateStr');
    await liveDir.create(recursive: true);

    final payload = {
      'markerTimestampMs': markerMs,
      'segmentFilename': filename,
      'markerOffsetMs': offsetMs,
      'cropStartMs': 0,
      'cropEndMs': durationMs,
      'userSaved': false,
      'isHighPriority': isHighPriority,
    };

    final File edlFile = File('${liveDir.path}/marker_$markerMs.edl');
    if (await edlFile.exists()) {
      try {
        final existing = jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
        final existingFilename = existing['segmentFilename'] as String? ?? '';
        if (existingFilename == filename) {
          // Same marker, same segment — preserve any user crop edits.
          return;
        }
        final userSaved = existing['userSaved'] as bool? ?? false;
        if (userSaved) {
          // User explicitly Saved → preserve their work. Re-point
          // segmentFilename + offsetMs to the new audio anchor but keep
          // cropStart/cropEnd and userSaved untouched. `userSaved` is the
          // only reliable signal: it's set exclusively by the player's
          // _saveConversation path, and any non-default crop the user
          // committed went through that same path.
          //
          // A `cropEndMs > 0` heuristic was tried earlier but matches
          // every default EDL (the isolate writes cropEndMs = encoded
          // duration), so it'd freeze stale cropEndMs values against the
          // new segment.
          existing['segmentFilename'] = filename;
          existing['markerOffsetMs'] = offsetMs;
          // Carry forward the high-priority flag (re-derived from the marker on
          // every pass). A pre-feature user-saved EDL has no isHighPriority key,
          // so without this a re-point after a file rename would silently drop a
          // Priority Recording marker's red status.
          existing['isHighPriority'] = isHighPriority;
          await _writeJsonAtomic(edlFile, existing);
          Logger.debug('RecordingsManager: Preserved user edits on marker_$markerMs.edl, re-pointed to $filename');
          return;
        }
      } catch (_) {
        // Corrupt/unparseable EDL — fall through and overwrite.
      }
      // No user edits to preserve: overwrite in place. Two physical taps
      // cannot share a UTC ms (firmware ms resolution, taps take much
      // longer than 1 ms), so the only way an EDL at this filename exists
      // is the same physical tap from a previous run; the new payload is
      // the authoritative one (B4/D1).
    }
    await _writeJsonAtomic(edlFile, payload);
    Logger.debug(
        'RecordingsManager: Wrote EDL ${edlFile.path.split('/').last} → ${filename.isEmpty ? "(orphan)" : filename} at ${offsetMs}ms');

    // If the audio file is from a different day than the tap, a previous run may
    // have written an orphan EDL into the markerMs date folder. Delete it now
    // that we have the real paired EDL in the correct folder.
    if (filename.isNotEmpty) {
      final orphanDateStr = _dateStringFromMillis(markerMs);
      if (orphanDateStr != dateStr) {
        final orphanFile = File('$docsPath/recordings/$orphanDateStr/marker_$markerMs.edl');
        if (await orphanFile.exists()) {
          try {
            final orphan = jsonDecode(await orphanFile.readAsString()) as Map<String, dynamic>;
            final orphanFilename = orphan['segmentFilename'] as String? ?? '';
            final orphanUserSaved = orphan['userSaved'] as bool? ?? false;
            if (orphanFilename.isEmpty && !orphanUserSaved) {
              await orphanFile.delete();
              Logger.debug('RecordingsManager: Deleted cross-midnight orphan marker_$markerMs.edl from $orphanDateStr');
            }
          } catch (_) {}
        }
      }
    }
  }

  /// Scans all `recordings/<date>/` folders for `marker_*.edl` files and
  /// returns a list of [MarkerConversation] sorted by markerTime descending.
  /// Pending conversations (no backing m4a yet) are included with [isPending] = true.
  Future<List<MarkerConversation>> getMarkerConversations() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return [];

    final entities = await recordingsDir.list().toList();
    final dateFolders = entities.whereType<Directory>().toList();

    // Build a one-shot filename → File index across all date folders so that
    // missing-segment recovery is O(1) per marker instead of O(folders) (B14).
    final Map<String, File> filenameIndex = {};
    for (final folder in dateFolders) {
      try {
        await for (final entity in folder.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          // First write wins — date folder placement is deterministic.
          filenameIndex.putIfAbsent(name, () => entity);
        }
      } catch (_) {}
    }

    // Step 1: Rapidly scan all date folders for EDL files
    final List<MarkerConversation> allConversations = [];
    for (final dateFolder in dateFolders) {
      final edlFiles = await dateFolder
          .list()
          .where((e) => e is File && e.uri.pathSegments.last.startsWith('marker_') && e.path.endsWith('.edl'))
          .cast<File>()
          .toList();

      for (final edlFile in edlFiles) {
        try {
          final json = jsonDecode(await edlFile.readAsString()) as Map<String, dynamic>;
          final markerMs = json['markerTimestampMs'] as int;
          final segmentFilename = json['segmentFilename'] as String?;

          File? segmentFile;
          if (segmentFilename != null && segmentFilename.isNotEmpty) {
            // Resolve the segment from the index — also covers draft files so
            // markers in not-yet-finalized drafts show up as playable instead
            // of stuck "Processing…" (B4).
            segmentFile = filenameIndex[segmentFilename];
            if (segmentFile == null) {
              // Fall back: maybe the draft was finalized to a non-draft name.
              if (segmentFilename.contains('_draft.')) {
                final finalizedName = segmentFilename.replaceAll('_draft.', '.');
                segmentFile = filenameIndex[finalizedName];
              } else {
                // Or vice-versa: file is still a draft on disk.
                final draftName = segmentFilename.replaceAllMapped(RegExp(r'\.(m4a|wav|ogg)$'), (m) => '_draft${m[0]}');
                segmentFile = filenameIndex[draftName];
              }
            }
          }

          // Clamp cropEnd to the segment's actual encoded duration. Pre-0.12.0
          // EDLs stored wall-clock chunk duration which can exceed the playable
          // file length when frames were silently dropped during decode. The
          // in-memory MC always gets the clamped value; if the on-disk EDL
          // was over the encoded duration AND not user-saved (no risk of
          // overwriting user crop intent), persist the clamp back to disk
          // so the next load doesn't re-clamp (B9).
          int cropEndMs = json['cropEndMs'] as int? ?? 0;
          if (segmentFile != null) {
            try {
              final base = segmentFile.path.substring(0, segmentFile.path.lastIndexOf('.'));
              final metaBytes = await File('$base.meta').readAsBytes();
              if (metaBytes.length >= 8) {
                final encodedMs = ByteData.sublistView(metaBytes).getUint32(4, Endian.little);
                if (encodedMs > 0 && (cropEndMs == 0 || cropEndMs > encodedMs)) {
                  final originalOnDisk = cropEndMs;
                  cropEndMs = encodedMs;
                  final userSaved = json['userSaved'] as bool? ?? false;
                  if (!userSaved && originalOnDisk > encodedMs) {
                    json['cropEndMs'] = encodedMs;
                    try {
                      await _writeJsonAtomic(edlFile, json);
                      Logger.debug(
                          'RecordingsManager: Migrated EDL ${edlFile.path.split('/').last} cropEndMs $originalOnDisk→$encodedMs');
                    } catch (e) {
                      Logger.error('RecordingsManager: cropEnd migration write failed: $e');
                    }
                  }
                }
              }
            } catch (_) {}
          }

          allConversations.add(MarkerConversation(
            markerTime: DateTime.fromMillisecondsSinceEpoch(markerMs),
            segment: segmentFile,
            markerOffsetMs: json['markerOffsetMs'] as int? ?? 0,
            cropStartMs: json['cropStartMs'] as int? ?? 0,
            cropEndMs: cropEndMs,
            edlFile: edlFile,
            userSaved: json['userSaved'] as bool? ?? false,
            isHighPriority: json['isHighPriority'] as bool? ?? false,
          ));
        } catch (e) {
          Logger.error('RecordingsManager: Failed to parse EDL ${edlFile.path}: $e');
        }
      }
    }

    // Step 2: Group EDLs by exact markerMs and pick one canonical per ms.
    // Two physical button taps cannot share a UTC ms (firmware ms resolution,
    // taps take much longer than 1 ms), so any group of >1 here is a bug or
    // legacy data — pick the preferred (userSaved > non-pending > earliest
    // basename) and warn on the rest so testing surfaces them in logs.
    final Map<int, List<MarkerConversation>> byMs = {};
    for (final mc in allConversations) {
      byMs.putIfAbsent(mc.markerTime.millisecondsSinceEpoch, () => []).add(mc);
    }
    final List<MarkerConversation> deduped = [];
    for (final group in byMs.values) {
      if (group.length == 1) {
        deduped.add(group.first);
        continue;
      }
      group.sort((a, b) {
        final saveCmp = (b.userSaved ? 1 : 0) - (a.userSaved ? 1 : 0);
        if (saveCmp != 0) return saveCmp;
        final pendCmp = (a.isPending ? 1 : 0) - (b.isPending ? 1 : 0);
        if (pendCmp != 0) return pendCmp;
        return a.edlFile.path.split('/').last.compareTo(b.edlFile.path.split('/').last);
      });
      deduped.add(group[0]);
      Logger.error(
          'RecordingsManager: ${group.length} EDLs at markerMs=${group[0].markerTime.millisecondsSinceEpoch} — keeping ${group[0].edlFile.path.split('/').last}, dropping ${group.skip(1).map((m) => m.edlFile.path.split('/').last).join(", ")}');
    }

    deduped.sort((a, b) => b.markerTime.compareTo(a.markerTime));
    return deduped;
  }

  /// Derives the date-folder name (YYYY-MM-DD) from epoch milliseconds.
  ///
  /// **Convention**: all date folders use the *local* timezone so that
  /// recordings appear under the date the user experienced them.  Session IDs
  /// and device markers use UTC internally, but folder placement is always
  /// local.  A recording that starts before midnight local time and ends after
  /// midnight is placed under the *start* date.
  static String _dateStringFromMillis(int millis) => fmtDate(DateTime.fromMillisecondsSinceEpoch(millis).toLocal());

  /// Background auto-process: processes all batches as one continuous stream.
  /// Bins still mid-transfer (walOffset < device-advertised size) are held back on
  /// BOTH delete paths: the incomplete-transfer guard inside [processAll]
  /// (backgroundMode gate) keeps them out of the VAD pass and its consume-prune,
  /// and the same set is handed to [pruneConsumedBins] below so its
  /// exact-membership sweep can't reclaim one either. A partially-synced active bin
  /// is therefore neither decoded nor deleted until fully landed — this is what
  /// stops an interrupted bin being re-fetched and duplicated into a second
  /// recording. Safe to call from a background timer; no-op if a marker process is
  /// running.
  static Future<void> processAllCompletedSessions() async {
    if (_isProcessingAny) return;
    // Resolve the mid-transfer set BEFORE anything deletes a bin. [processAll]
    // re-reads it for its own strip (it is called directly elsewhere), but the
    // prune below runs first and deletes by exact membership only — which is
    // blind to sync state — so the check has to happen up here or a bin the next
    // sync must resume into can be gone before the guard is ever consulted.
    // Fail closed on the same rule as processAll: unknown sync state ⇒ delete
    // nothing and process nothing this cycle; wals.json is rewritten by every
    // sync, so the next one self-heals.
    Set<String> incompleteRelBins;
    try {
      incompleteRelBins = await _resolveIncompleteRelBins();
    } catch (e) {
      Logger.error('RecordingsManager: processAllCompletedSessions skipping run — incomplete-bin set '
          'unavailable, cannot safely prune (fail-closed): $e');
      return;
    }
    // Idempotency guard: drop any bins whose audio is already covered by an
    // existing recording on disk. Catches the kill-mid-cleanup case where a
    // previous run wrote the .wav but didn't get to delete its source bins
    // (the bug that produces near-duplicate recordings 0.5s apart).
    await pruneConsumedBins(protectedRelBins: incompleteRelBins);
    final manager = RecordingsManager();
    final batches = await manager.getBatches();
    // Always-on idempotency guard: skip bins already fully covered by an existing
    // recording so a re-VAD can't mint a near-duplicate. Cheap here — pruneConsumedBins
    // (above) already deleted covered bins on the normal path, so the set is usually
    // empty; this acts as a final safety check.
    final Set<String> covered = await coveredBinPaths(batches.expand((b) => b.rawSegments).toList());
    final processableBatches = covered.isEmpty
        ? batches
        : batches.map((b) {
            final filtered = b.rawSegments.where((f) => !covered.contains(f.path)).toList();
            if (filtered.length == b.rawSegments.length) return b;
            return Batch(
              dateString: b.dateString,
              date: b.date,
              rawSegments: filtered,
              draftRecordings: b.draftRecordings,
              finalizedRecordings: b.finalizedRecordings,
              markerTimestamps: b.markerTimestamps,
              discards: b.discards,
            );
          }).toList();
    final activeBatches = processableBatches.where((b) => b.rawSegments.isNotEmpty).toList();
    if (activeBatches.isEmpty) return;
    try {
      await manager.processAll(activeBatches, (_, __) {}, backgroundMode: true);
    } catch (e) {
      Logger.error(
        'RecordingsManager: Background processAllCompletedSessions error: $e',
      );
    }
  }

  /// Force-process all batches including the newest segment per DeviceSession.
  /// Used by the debug Force Process button — same as pressing the Process button
  /// on each batch but operates across all days at once.
  /// No-op if a process is already running.
  ///
  /// [reprocessCovered] (default false) preserves the original intent of
  /// "pressing Process on each batch": it RESPECTS coverage, so bins already
  /// owned by a recording are skipped and finalized recordings are left alone.
  /// Without this guard, retention (which keeps every bin forever) turned this
  /// into "re-derive my entire history every time" — overwriting finalized
  /// recordings and getting slower without bound. Set it true ONLY for the
  /// adjustment-mode "re-run VAD on saved bins" path, which intentionally
  /// rebuilds recordings from already-owned bins.
  static Future<void> forceProcessAll({bool reprocessCovered = false}) async {
    if (_isProcessingAny) return;
    // Same idempotency guard as processAllCompletedSessions — see that method.
    // Force DOES decode a mid-transfer bin on purpose (that is the point of the
    // button), but deleting one is never wanted: it is the file the next sync
    // resumes into. Protect the mid-transfer set here, and when it can't be read
    // skip only the prune — the user-requested processing still runs.
    Set<String>? incompleteRelBins;
    try {
      incompleteRelBins = await _resolveIncompleteRelBins();
    } catch (e) {
      Logger.error('RecordingsManager: forceProcessAll skipping prune — incomplete-bin set unavailable: $e');
    }
    if (incompleteRelBins != null) {
      await pruneConsumedBins(protectedRelBins: incompleteRelBins);
    }
    final manager = RecordingsManager();
    final batches = await manager.getBatches();

    final List<Batch> candidateBatches;
    if (reprocessCovered) {
      candidateBatches = batches;
    } else {
      // Skip bins already covered by an existing recording — same filter the
      // normal Process button and background sync use. This is what keeps a
      // routine Force Process from re-deriving (and overwriting) finalized
      // recordings now that retention keeps their source bins on disk.
      final covered = await coveredBinPaths(batches.expand((b) => b.rawSegments).toList());
      candidateBatches = covered.isEmpty
          ? batches
          : batches.map((b) {
              final filtered = b.rawSegments.where((f) => !covered.contains(f.path)).toList();
              if (filtered.length == b.rawSegments.length) return b;
              return Batch(
                dateString: b.dateString,
                date: b.date,
                rawSegments: filtered,
                draftRecordings: b.draftRecordings,
                finalizedRecordings: b.finalizedRecordings,
                markerTimestamps: b.markerTimestamps,
                discards: b.discards,
              );
            }).toList();
    }

    final activeBatches =
        candidateBatches.where((b) => b.rawSegments.isNotEmpty || b.draftRecordings.isNotEmpty).toList();
    if (activeBatches.isEmpty) {
      Logger.debug('RecordingsManager: forceProcessAll — nothing to process '
          '(reprocessCovered=$reprocessCovered; covered bins skipped)');
      return;
    }
    Logger.info('RecordingsManager: forceProcessAll — ${activeBatches.expand((b) => b.rawSegments).length} bin(s), '
        'reprocessCovered=$reprocessCovered');
    try {
      await manager.processAll(
        activeBatches,
        (_, __) {},
        backgroundMode: false,
        finalizeDrafts: true,
      );
    } catch (e) {
      Logger.error('RecordingsManager: forceProcessAll error: $e');
    }
  }

  /// Deletes orphaned `.tmp.m4a` files left by interrupted encoding runs.
  /// Call once at app startup before processing begins.
  static Future<void> cleanupOrphanedTempFiles() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;
    await for (final entity in recordingsDir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.tmp.m4a')) {
        try {
          await entity.delete();
          Logger.debug(
            'RecordingsManager: Deleted orphaned temp file ${entity.path}',
          );
        } catch (e) {
          Logger.error(
            'RecordingsManager: Failed to delete orphaned temp file ${entity.path}: $e',
          );
        }
      }
    }
  }

  /// Deletes a single processed conversation and its associated meta/bin files.
  static Future<void> deleteConversation(Conversation conversation) async {
    await deleteConversations([conversation]);
  }

  /// Deletes multiple processed conversations and their associated meta/bin/marker files.
  /// Efficiently groups by directory to minimize directory listings for EDL cleanup.
  static Future<void> deleteConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) return;

    // Group conversations by directory to minimize directory listings for EDL cleanup
    final Map<String, List<Conversation>> byDir = {};
    for (final c in conversations) {
      final dir = c.file.parent.path;
      byDir.putIfAbsent(dir, () => []).add(c);
    }

    for (final dirPath in byDir.keys) {
      final convsInDir = byDir[dirPath]!;
      final filenames = convsInDir.map((c) => c.file.path.split('/').last).toSet();

      // 1. Delete audio, meta, bin files. Batch the SharedPreferences write so we
      // pay one disk sync instead of one per conversation, and run the per-conversation
      // file deletes concurrently (each touches disjoint paths).
      final keysToRemove = convsInDir.map((c) => c.uploadKey).whereType<String>().toSet();
      if (keysToRemove.isNotEmpty) {
        await SharedPreferencesUtil().removeUploadedFromHeypocket(keysToRemove);
      }
      await Future.wait(convsInDir.map((c) async {
        final file = c.file;
        // Drop the exists() probe and let delete() fail-soft — one syscall per file instead of two.
        try {
          await file.delete();
        } on FileSystemException catch (_) {}
        final metaPath = '${file.path.substring(0, file.path.lastIndexOf('.'))}.meta';
        final metaFile = File(metaPath);
        try {
          await metaFile.delete();
        } on FileSystemException catch (_) {}
        try {
          final ts = file.path.split('/').last.split('_').last.split('.').first;
          final binPath = '${file.parent.path}/recording_fs320_$ts.bin';
          final binFile = File(binPath);
          try {
            await binFile.delete();
          } on FileSystemException catch (_) {}
        } catch (_) {}
      }));

      // 2. Delete EDL files for all deleted conversations in this directory at once.
      // Reads + deletes run concurrently — each EDL is an independent JSON sidecar.
      try {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          final dirEntities = await dir.list().toList();
          await Future.wait(dirEntities.map((entity) async {
            if (entity is! File || !entity.path.endsWith('.edl')) return;
            try {
              final json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
              if (filenames.contains(json['segmentFilename'])) {
                await entity.delete();
              }
            } catch (_) {}
          }));
        }
      } catch (e) {
        Logger.error('RecordingsManager: Failed to cleanup EDLs in $dirPath: $e');
      }
    }
  }

  /// Deletes a marker.
  static Future<void> deleteMarkerConversation(MarkerConversation mc) async {
    if (await mc.edlFile.exists()) {
      await mc.edlFile.delete();
      Logger.debug('RecordingsManager: Deleted marker ${mc.edlFile.path}');
    }
  }

  /// Deletes processed recordings (.m4a/.wav/.meta/.bin) for a day.

  /// Safe to call while nothing is playing.
  Future<void> deleteDay(Batch batch) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory(
      '${directory.path}/recordings/${batch.dateString}',
    );

    // Drop discard records for this day. In the full-delete path, also delete
    // the referenced raw bins so they can't resurrect deleted recordings on the
    // next sync.
    for (final d in batch.discards) {
      await removeDiscardRecord(d, deleteBins: true);
    }

    // Wipe the day's raw .bin segments too, bypassing the 48h discard hold.
    // Without this, the next sync silently reprocesses them and resurrects
    // the recordings the user just deleted.
    final touchedSessionDirs = <Directory>{};
    int deletedBins = 0;
    for (final bin in batch.rawSegments) {
      try {
        if (await bin.exists()) {
          await bin.delete();
          deletedBins++;
        }
        touchedSessionDirs.add(bin.parent);
      } catch (e) {
        Logger.error('RecordingsManager: deleteDay failed to delete bin ${bin.path}: $e');
      }
    }
    for (final dir in touchedSessionDirs) {
      try {
        if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
      } catch (_) {}
    }
    if (deletedBins > 0) {
      Logger.debug(
        'RecordingsManager: Deleted $deletedBins raw bins for ${batch.dateString}',
      );
    }

    if (await recordingsDir.exists()) {
      await recordingsDir.delete(recursive: true);
      Logger.debug(
        'RecordingsManager: Deleted processed recordings for ${batch.dateString}',
      );
    }

    // Markers are grouped in the UI by their own wall-clock date (markerTime),
    // but a marker's EDL is filed under its backing *segment's* date folder (see
    // _writeMarkerEdl). For a marker tapped just after midnight but anchored to
    // audio that started before midnight, those dates differ — so the recursive
    // folder delete above misses the EDL, and the marker keeps showing under this
    // day in the markers-only view. Sweep every folder for marker EDLs whose
    // markerTimestampMs falls on this local date and delete those too.
    try {
      final recordingsRoot = Directory('${directory.path}/recordings');
      if (await recordingsRoot.exists()) {
        await for (final folder in recordingsRoot.list()) {
          if (folder is! Directory) continue;
          await for (final entity in folder.list()) {
            if (entity is! File) continue;
            final name = entity.uri.pathSegments.last;
            if (!name.startsWith('marker_') || !name.endsWith('.edl')) continue;
            try {
              final json = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
              final markerMs = json['markerTimestampMs'] as int?;
              if (markerMs == null || _dateStringFromMillis(markerMs) != batch.dateString) continue;
              await entity.delete();
              Logger.debug(
                'RecordingsManager: deleteDay removed stray marker $name (display date ${batch.dateString})',
              );
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      Logger.error('RecordingsManager: deleteDay marker sweep failed: $e');
    }
  }

  /// Sets flag byte [3] bit 0x20 on [meta] — "the phone re-filed this".
  ///
  /// Read-modify-write of a single bit rather than a rewrite of the sidecar: the
  /// bins-JSON tail is located from the meta's own length, so anything that changes the
  /// length shifts that tail out from under every reader. Flag byte [3] already exists
  /// on any `.meta` this can be called for (the processor writes all four), so no byte
  /// is being added — see the no-fifth-flag-byte rule in CLAUDE.md.
  ///
  /// Best-effort: a meta too short to carry flags means a recording written by an older
  /// build or a torn write. The move still happened and is still right; all that is lost
  /// is the revert arrow, so this logs and returns rather than failing the correction.
  static Future<void> _stampClockCorrected(File meta) async {
    try {
      if (!await meta.exists()) return;
      final bytes = await meta.readAsBytes();
      if (bytes.length < 417) return;
      final flagOffset = 417 + bytes[416];
      if (bytes.length <= flagOffset + 3) {
        Logger.debug('RecordingsManager: ${meta.path} has no flag byte [3]; re-filed but not markable.');
        return;
      }
      if ((bytes[flagOffset + 3] & 0x20) != 0) return;
      bytes[flagOffset + 3] |= 0x20;
      await meta.writeAsBytes(bytes, flush: true);
    } catch (e) {
      Logger.error('RecordingsManager: failed to stamp clock-corrected flag on ${meta.path}: $e');
    }
  }

  /// Re-files recordings whose timestamps the Omi got wrong, using the phone as the
  /// clock of record. Returns the number of sessions moved.
  ///
  /// The Omi has no clock. It learns the time from a phone and forgets it on every
  /// restart, and the counter it falls back to is 24-bit at 6.4 ms — it wraps every
  /// ~29.8 h in the direction that makes a long gap look SHORT. So a device left off for
  /// 31 h comes back believing 1.2 h passed and files a day of audio under a confidently
  /// wrong date, with nothing on the device able to contradict it.
  ///
  /// The phone can, for any session it saw running: an anchor pairs that session's
  /// uptime with real wall-clock time, and every recording's `.meta` carries the uptime
  /// it started at, which places the whole session exactly.
  ///
  /// Three rules, in [clockVerdict]:
  ///   - a recording whose own timestamp already agrees is never touched;
  ///   - one with no timestamp at all is given one;
  ///   - one the anchor can PROVE wrong is overwritten.
  /// The gap between "a bit of drift" and "the counter wrapped" is four orders of
  /// magnitude, so no tuned threshold decides this.
  ///
  /// Whole sessions move together, because a session has exactly one offset: if its
  /// clock was wrong, every recording in it is wrong by the same amount. A session with
  /// no anchor — one that had already ended before the phone ever saw it — is left
  /// alone, since the gap between two boots is unmeasurable once both counters reset.
  ///
  /// Idempotent by construction. Once moved, a session's recordings agree with their
  /// anchor, so the next pass reads `alreadyCorrect` and does nothing; and a user who
  /// reverts drops the anchor, so nothing re-applies it.
  static Future<int> applyClockAnchors() async {
    final prefs = SharedPreferencesUtil();
    final anchors = DeviceClockAnchorSet.decode(prefs.deviceClockAnchors);
    if (anchors.isEmpty) return 0;
    var ledger = ClockCorrectionLedger.decode(prefs.clockCorrectionLedger);

    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return 0;

    // Group this session's finalized recordings. Drafts are skipped: they are still
    // being appended to and are not surfaced, and the pass that promotes them will
    // produce a finalized file this can correct on a later run.
    final bySession = <int, List<Conversation>>{};
    for (final folder in (await recordingsDir.list().toList()).whereType<Directory>()) {
      for (final f in (await folder.list().toList()).whereType<File>()) {
        final path = f.path;
        if (!(path.endsWith('.m4a') || path.endsWith('.wav') || path.endsWith('.ogg'))) continue;
        if (path.contains('_draft.')) continue;
        final conv = Conversation.fromFile(f);
        final sid = conv.sessionId;
        if (sid == null || sid == 0) continue;
        if (anchors.forSession(sid) == null) continue;
        // The user undid this session's correction. Their decision outranks the anchor,
        // and permanently: the anchor is re-observed on every connect while the Omi stays
        // on this boot, so without this the very next pass would re-file the session and
        // silently reverse them.
        if (ledger.isReverted(sid)) continue;
        bySession.putIfAbsent(sid, () => []).add(conv);
      }
    }

    var moved = 0;
    for (final entry in bySession.entries) {
      final anchor = anchors.forSession(entry.key)!;
      final convs = entry.value;

      var needsMove = false;
      for (final c in convs) {
        final verdict = clockVerdict(
          anchor: anchor,
          recordedSessionId: c.sessionId,
          startUptimeSec: c.startUptime,
          claimedStartMs: c.startTime.millisecondsSinceEpoch,
          isUnknown: c.isUnknown,
        );
        if (verdict == ClockVerdict.correctWrong || verdict == ClockVerdict.fileUnknown) {
          needsMove = true;
          break;
        }
      }
      if (!needsMove) continue;

      // The base only supplies the offset, and every recording in the session yields
      // the same one, so any with a usable uptime will do. The earliest is chosen so
      // the folder-migration step inside promoteSessionToDate keys off the session's
      // first recording rather than an arbitrary later one.
      Conversation? base;
      for (final c in convs) {
        final up = c.startUptime;
        if (up == null || up <= 0) continue;
        if (base == null || up < base.startUptime!) base = c;
      }
      if (base == null) continue;

      final newStartMs = anchor.startMsFor(base.startUptime!);
      // Captured BEFORE the move, because the move is what destroys it: the offset lives
      // only in the filenames, and promoteSessionToDate rewrites them. Without this an
      // undo has nothing to restore.
      final originalOffsetMs = base.startTime.millisecondsSinceEpoch - (base.startUptime! * 1000);
      try {
        await promoteSessionToDate(
          base,
          DateTime.fromMillisecondsSinceEpoch(newStartMs),
          markClockCorrected: true,
        );
        ledger = ledger.recordCorrection(entry.key, originalOffsetMs);
        prefs.clockCorrectionLedger = ledger.encode();
        moved++;
        Logger.debug('RecordingsManager: clock anchor re-filed session ${entry.key} '
            '(${convs.length} recording(s)) to ${DateTime.fromMillisecondsSinceEpoch(newStartMs)}');
      } catch (e) {
        Logger.error('RecordingsManager: clock-anchor re-file failed for session ${entry.key}: $e');
      }
    }
    return moved;
  }

  /// Undoes [applyClockAnchors] for one session, and discards the anchor that did it.
  ///
  /// Dropping the anchor is not tidy-up, it is the point: leave it in place and the very
  /// next processing pass reads the same verdict, re-files the session, and silently
  /// undoes the user's decision. The anchor is the correction's authority, so revoking
  /// the correction has to revoke the authority.
  static Future<void> revertClockCorrection(Conversation conv) async {
    final sessionId = conv.sessionId;
    if (sessionId == null || sessionId == 0) return;

    final prefs = SharedPreferencesUtil();

    // Both halves are needed, and dropping the anchor is the lesser one. The anchor comes
    // straight back on the next diagnostics read — every reconnect, while the Omi stays on
    // this boot — so only the ledger entry makes the rejection stick.
    prefs.deviceClockAnchors = DeviceClockAnchorSet.decode(prefs.deviceClockAnchors).without(sessionId).encode();
    final ledger = ClockCorrectionLedger.decode(prefs.clockCorrectionLedger);
    prefs.clockCorrectionLedger = ledger.markReverted(sessionId).encode();

    final uptime = conv.startUptime;
    // The offset these recordings carried before the app moved them. It cannot be derived
    // now — the move rewrote the filenames it lived in — so a session with no ledger entry
    // is one this build cannot put back, and saying so beats inventing a date. (Reading
    // the uptime as an epoch, which an earlier version of this did, lands in 1970 rather
    // than on whatever the Omi had filed.)
    final originalOffsetMs = ledger.originalOffsetFor(sessionId);
    if (uptime == null || uptime <= 0 || originalOffsetMs == null) {
      Logger.debug('RecordingsManager: session $sessionId marked as user-rejected, but its original '
          'timestamps are not recorded — files left where they are.');
      notifyRecordingsChanged();
      return;
    }
    await promoteSessionToDate(conv, DateTime.fromMillisecondsSinceEpoch((uptime * 1000) + originalOffsetMs));
    await _clearClockCorrectedForSession(sessionId);
    notifyRecordingsChanged();
  }

  /// Clears bit 0x20 across a session, so the revert arrow disappears with the revert.
  static Future<void> _clearClockCorrectedForSession(int sessionId) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return;
    for (final folder in (await recordingsDir.list().toList()).whereType<Directory>()) {
      for (final f in (await folder.list().toList()).whereType<File>()) {
        if (!f.path.endsWith('.meta')) continue;
        try {
          final bytes = await f.readAsBytes();
          if (bytes.length < 417) continue;
          final bd = ByteData.sublistView(bytes);
          if (bd.getUint32(408, Endian.little) != sessionId) continue;
          final flagOffset = 417 + bytes[416];
          if (bytes.length <= flagOffset + 3) continue;
          if ((bytes[flagOffset + 3] & 0x20) == 0) continue;
          bytes[flagOffset + 3] &= ~0x20;
          await f.writeAsBytes(bytes, flush: true);
        } catch (_) {}
      }
    }
  }

  /// Batch-updates the starting timestamp for an entire hardware session.
  ///
  /// This renames and moves all processed recordings, .meta sidecars, .bin raw syncs,
  /// and .edl markers belonging to the same sessionId.
  /// [markClockCorrected] stamps flag byte [3] bit 0x20 on every `.meta` this moves,
  /// marking the recording as re-filed by the phone rather than timestamped by the Omi.
  /// Only [applyClockAnchors] passes it — the manual date picker leaves the bit alone,
  /// because a date the user chose by hand has nothing to revert *to*.
  static Future<void> promoteSessionToDate(Conversation base, DateTime newStartTime,
      {bool markClockCorrected = false}) async {
    final sessionId = base.sessionId;
    final startUptime = base.startUptime;
    if (startUptime == null || startUptime == 0) {
      throw Exception('Cannot promote session: startUptime is missing or zero.');
    }

    final rtcOffsetMs = newStartTime.millisecondsSinceEpoch - (startUptime * 1000);
    final directory = await getApplicationDocumentsDirectory();

    // 1. Identify all affected finalized recordings across all date folders.
    final List<Conversation> sessionConversations = [];
    final recordingsDir = Directory('${directory.path}/recordings');
    if (await recordingsDir.exists()) {
      final dateFolders = (await recordingsDir.list().toList()).whereType<Directory>().toList();
      for (final folder in dateFolders) {
        final audioFiles = await folder
            .list()
            .where((e) => e is File && (e.path.endsWith('.m4a') || e.path.endsWith('.wav')))
            .cast<File>()
            .toList();

        for (final file in audioFiles) {
          final conv = Conversation.fromFile(file);
          if (conv.sessionId == sessionId && sessionId != null) {
            sessionConversations.add(conv);
          } else if (file.path == base.file.path) {
            // Fallback for single-file promotion if sessionId is missing
            sessionConversations.add(conv);
          }
        }
      }
    }

    // 2. Perform renames and moves for processed recordings
    for (final conv in sessionConversations) {
      final convUptime = conv.startUptime ?? (conv.startTime.millisecondsSinceEpoch ~/ 1000);
      final newConvStartMs = (convUptime * 1000) + rtcOffsetMs;
      final newDateStr = _dateStringFromMillis(newConvStartMs);
      final targetDir = Directory('${directory.path}/recordings/$newDateStr');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);

      final extension = conv.file.path.split('.').last;
      final newAudioPath = '${targetDir.path}/recording_$newConvStartMs.$extension';
      final newMetaPath = '${targetDir.path}/recording_$newConvStartMs.meta';

      final basePath = conv.file.path.substring(0, conv.file.path.lastIndexOf('.'));
      final metaFile = File('$basePath.meta');

      // Update .meta content with new UTC time if we were to be super thorough,
      // but fromFile relies on filename timestamp, so renaming the file is enough.

      if (await metaFile.exists()) await metaFile.rename(newMetaPath);
      await conv.file.rename(newAudioPath);
      if (markClockCorrected) await _stampClockCorrected(File(newMetaPath));

      // Handle legacy .bin sidecar if present
      final oldBinPath = '$basePath.bin';
      if (await File(oldBinPath).exists()) {
        final newBinPath = '${targetDir.path}/recording_$newConvStartMs.bin';
        await File(oldBinPath).rename(newBinPath);
      }

      // 3. Move and update .edl markers in the same date folder
      final parentDir = conv.file.parent;
      final markerFiles = await parentDir
          .list()
          .where((e) => e is File && e.path.split('/').last.startsWith('marker_') && e.path.endsWith('.edl'))
          .cast<File>()
          .toList();

      for (final edlFile in markerFiles) {
        try {
          final content = await edlFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final segmentFilename = json['segmentFilename'] as String?;
          if (segmentFilename == conv.file.path.split('/').last) {
            final oldMarkerMs = json['markerTimestampMs'] as int;
            // Marker uptime = oldMarkerMs (since it was Dec 1969/Jan 1970)
            final newMarkerMs = oldMarkerMs + rtcOffsetMs;

            final updatedJson = Map<String, dynamic>.from(json);
            updatedJson['markerTimestampMs'] = newMarkerMs;
            updatedJson['segmentFilename'] = newAudioPath.split('/').last;

            await edlFile.delete(); // Delete old EDL
            final newEdlFile = File('${targetDir.path}/marker_$newMarkerMs.edl');
            await newEdlFile.writeAsString(jsonEncode(updatedJson));
          }
        } catch (e) {
          Logger.error('RecordingsManager: Failed to migrate EDL ${edlFile.path}: $e');
        }
      }
    }

    // 4. Handle raw_segments folder migration
    final rawSegmentsDir = Directory('${directory.path}/raw_segments');
    if (await rawSegmentsDir.exists()) {
      final sessionFolderName = sessionId != null ? 'session_$sessionId' : null;
      final baseUptime = base.startUptime ?? 0;
      final oldUnknownFolderName = 'unknown_$baseUptime';

      Directory? sourceFolder;
      if (sessionFolderName != null) {
        final dir = Directory('${rawSegmentsDir.path}/$sessionFolderName');
        if (await dir.exists()) sourceFolder = dir;
      }
      if (sourceFolder == null) {
        final dir = Directory('${rawSegmentsDir.path}/$oldUnknownFolderName');
        if (await dir.exists()) sourceFolder = dir;
      }

      if (sourceFolder != null) {
        final newBaseStartMs = baseUptime + rtcOffsetMs;
        final targetFolder = Directory('${rawSegmentsDir.path}/$newBaseStartMs');

        if (await targetFolder.exists()) {
          // Merge contents if target already exists (unlikely but safe)
          await for (final entity in sourceFolder.list()) {
            if (entity is File) {
              await entity.rename('${targetFolder.path}/${entity.path.split('/').last}');
            }
          }
          await sourceFolder.delete(recursive: true);
        } else {
          await sourceFolder.rename(targetFolder.path);
        }

        // 5. Update .bin filenames in the promoted raw folder to match new UTC base
        // Format: {uptime}_{sessionId}.bin -> {newUtc}_{sessionId}.bin
        await for (final entity in targetFolder.list()) {
          if (entity is File && entity.path.endsWith('.bin')) {
            final name = entity.path.split('/').last;
            final parts = name.split('_');
            final uptime = int.tryParse(parts[0]) ?? 0;
            if (uptime < 946684800000) {
              final newUtc = uptime + rtcOffsetMs;
              final sid = parts.length > 1 ? parts[1] : '0.bin';
              final newName = '${newUtc}_$sid';
              await entity.rename('${targetFolder.path}/$newName');
            }
          }
        }
      }
    }

    notifyRecordingsChanged();
  }

  // --- Discard ledger (delegated to DiscardStore) ----------------------------

  static Future<void> _persistDiscardRecord(String docsPath, Map<String, dynamic> rec) =>
      DiscardStore.persistDiscardRecord(docsPath, rec);

  static Future<Set<String>> discardedRelBinPaths() => DiscardStore.discardedRelBinPaths();

  static Future<Set<String>> discardedRelBinPathsExcludingSpan(int spanStartMs, int spanEndMs) =>
      DiscardStore.discardedRelBinPathsExcludingSpan(spanStartMs, spanEndMs);

  static Future<List<DiscardRecord>> getDiscardsForDate(String dateString) =>
      DiscardStore.getDiscardsForDate(dateString);

  static Future<void> removeDiscardRecord(DiscardRecord d, {required bool deleteBins}) =>
      DiscardStore.removeDiscardRecord(d, deleteBins: deleteBins);

  /// Recover/fold byte-slice gating: given disjoint, ascending `[start,end]`
  /// [ranges] and a read head at [offset], returns where decoding should resume —
  /// [offset] itself if it sits inside a range, the next range's start if it fell
  /// in a gap, or -1 once it is past the final range. Mirrors the byte-slice
  /// stepping the VAD processor uses for Recover so the draft-stitch fold
  /// ([_stitchDiscard]) decodes only the discard's own bytes.
  @visibleForTesting
  static int nextSliceOffset(List<List<int>> ranges, int offset) {
    var idx = 0;
    while (idx < ranges.length && offset >= ranges[idx][1]) {
      idx++;
    }
    if (idx >= ranges.length) return -1;
    if (offset < ranges[idx][0]) return ranges[idx][0];
    return offset;
  }

  /// Retires discard ghosts whose audio the draft-stitch pass just folded into a
  /// stitched conversation. Their `discards.jsonl` records are removed (so they
  /// stop surfacing as recoverable rows that would re-derive a duplicate slice),
  /// and each bin they SOLELY own is deleted — but only when it is already out of
  /// the processing pool (relocated to `discarded_segments/`) and not referenced
  /// by any remaining active discard. A bin a sibling discard still needs, or one
  /// left in `raw_segments/` (possibly a draft straddle), is kept.
  @visibleForTesting
  static Future<void> retireFoldedGhosts(List<DiscardRecord> ghosts) async {
    if (ghosts.isEmpty) return;
    // Remove the records first so a bin shared only AMONG the folded ghosts is
    // not mutually "protected" by a sibling that is also being retired.
    for (final g in ghosts) {
      await removeDiscardRecord(g, deleteBins: false);
    }
    final stillReferenced = await discardedRelBinPaths();
    final directory = await getApplicationDocumentsDirectory();
    final handled = <String>{};
    for (final g in ghosts) {
      for (final rel in g.relativeBins) {
        if (!handled.add(rel)) continue;
        if (stillReferenced.contains(rel)) continue; // a remaining discard owns it
        final bin = await resolveDiscardBin(directory.path, rel);
        // Only delete a bin already retired from the pool; a raw_segments/ bin
        // could be a draft straddle, so leave it to the safe-to-delete pass.
        if (!bin.path.replaceAll('\\', '/').contains('/$discardedSegmentsDirName/')) continue;
        if (!await bin.exists()) continue;
        try {
          await bin.delete();
          Logger.debug('RecordingsManager: retireFoldedGhosts deleted folded bin $rel');
        } catch (e) {
          Logger.error('RecordingsManager: retireFoldedGhosts delete bin failed for $rel: $e');
        }
        final folder = bin.parent;
        try {
          if (await folder.exists() && await folder.list().isEmpty) await folder.delete();
        } catch (_) {}
      }
    }
  }

  /// Subfolder (sibling of `raw_segments/`) where a bin is relocated once it has
  /// been fully processed AND claimed by a discard record. Keeping discarded
  /// bins out of `raw_segments/` makes them invisible to the processing pool (no
  /// reprocess, no append into a neighbouring recording) and to the session-id
  /// delete + prune sweeps — which all scan `raw_segments/` only — while still
  /// retaining them for Recover. See [retainDiscardBin] (relocation) and
  /// [resolveDiscardBin] (lookup).
  static const String discardedSegmentsDirName = 'discarded_segments';

  /// Physical location of a discard's bin: the relocated copy under
  /// `discarded_segments/` once it has been retired from the pool, else the
  /// original `raw_segments/` path (a draft-straddle bin still in the pool, or a
  /// legacy install predating the relocation).
  static Future<File> resolveDiscardBin(String docsPath, String rel) async {
    final moved = File('$docsPath/$discardedSegmentsDirName/$rel');
    if (await moved.exists()) return moved;
    return File('$docsPath/raw_segments/$rel');
  }

  /// Relocates a discard-claimed bin out of `raw_segments/` into
  /// `discarded_segments/`, preserving the `<session>/<file>.bin` tail. Returns
  /// true iff a move happened. No-op (false) when [absPath] is not under
  /// `raw_segments/` — e.g. a sibling bin already relocated, re-touched during a
  /// Recover run.
  @visibleForTesting
  static Future<bool> retainDiscardBin(String docsPath, String absPath) async {
    const marker = '/raw_segments/';
    final norm = absPath.replaceAll('\\', '/');
    final i = norm.lastIndexOf(marker);
    if (i < 0) return false; // already under discarded_segments/ (or unexpected) — leave as-is
    final rel = norm.substring(i + marker.length);
    final src = File(absPath);
    if (!await src.exists()) return false;
    final dest = File('$docsPath/$discardedSegmentsDirName/$rel');
    try {
      await dest.parent.create(recursive: true);
      try {
        await src.rename(dest.path);
      } on FileSystemException {
        // Cross-device or rename-unsupported — fall back to copy+delete. The
        // invariant is "in discarded_segments/, gone from raw_segments/": a
        // lingering raw copy is the dangerous state (it re-enters the processing
        // pool and re-exposes the Force-Process append / session-delete wipe
        // bugs), so if copy+delete throws, recopy and re-delete rather than bail
        // with the source still in the pool. A leftover duplicate is the
        // least-bad terminal outcome and only after repeated FS failures.
        FileSystemException? lastErr;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await src.copy(dest.path);
            await src.delete();
            lastErr = null;
            break;
          } on FileSystemException catch (e) {
            lastErr = e;
            Logger.error('RecordingsManager: retain copy+delete attempt ${attempt + 1} failed for $rel: $e');
          }
        }
        if (lastErr != null) throw lastErr;
      }
      Logger.debug('RecordingsManager: retained discard bin → $discardedSegmentsDirName/$rel');
      return true;
    } catch (e) {
      Logger.error('RecordingsManager: failed to retain discard bin $absPath: $e');
      return false;
    }
  }

  static Future<Set<String>> activeDiscardProtectedPaths() => DiscardStore.activeDiscardProtectedPaths();

  /// Reclaims expired discard records and their referenced bins. No-op when a
  /// processing run is already in flight (to avoid racing the per-segment delete
  /// handler).
  static Future<void> runRecoverySweep() async {
    if (_isProcessingAny) return;
    await DiscardStore.reclaimExpired();
  }

  // ---------------------------------------------------------------------------
  // Coverage helpers — shared by pruneConsumedBins (normal mode, deletes) and
  // coveredBinPaths (read-only filter before the VAD run).
  // ---------------------------------------------------------------------------

  /// Builds merged `[startMs, endMs]` coverage intervals from every recording
  /// (finalized + drafts) on disk. See [pruneConsumedBins] for the coverage rule.
  static Future<List<List<int>>> _buildMergedCoverageIntervals() async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/recordings');
    if (!await recordingsDir.exists()) return [];

    const int leftSlackMs = 10 * 60 * 1000;
    final int silenceSlackMs = SharedPreferencesUtil().vadSplitSeconds * 1000;

    final List<List<int>> intervals = [];
    await for (final dayFolder in recordingsDir.list()) {
      if (dayFolder is! Directory) continue;
      await for (final entity in dayFolder.list()) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!(path.endsWith('.wav') || path.endsWith('.m4a'))) continue;
        if (path.endsWith('.tmp.m4a') || path.contains('.tmp.')) continue;
        final isDraft = path.contains('_draft.');
        final conv = Conversation.fromFile(entity);
        if (conv.isUnknown) continue;
        final recStartMs = conv.startTime.millisecondsSinceEpoch;
        if (recStartMs <= 0) continue;
        final recEndMs = recStartMs + conv.duration.inMilliseconds;
        final rightEdge = (conv.capEnded || isDraft) ? recEndMs : recEndMs + silenceSlackMs;
        intervals.add([recStartMs - leftSlackMs, rightEdge]);
      }
    }
    if (intervals.isEmpty) return [];

    intervals.sort((a, b) => a[0].compareTo(b[0]));
    final List<List<int>> merged = [intervals.first];
    for (int i = 1; i < intervals.length; i++) {
      final last = merged.last;
      final cur = intervals[i];
      if (cur[0] <= last[1]) {
        if (cur[1] > last[1]) last[1] = cur[1];
      } else {
        merged.add(cur);
      }
    }
    return merged;
  }

  /// Returns the subset of [candidates] whose `[binStart, binEnd]` is fully
  /// covered by an existing recording. Does not delete anything — used in
  /// skip bins that already have a recording.
  static Future<Set<String>> coveredBinPaths(List<File> candidates) async {
    if (candidates.isEmpty) return const {};
    final merged = await _buildMergedCoverageIntervals();
    if (merged.isEmpty) return const {};

    const double opusBytesPerMs = 4050 / 1000;
    const int binHeaderBytes = 36;

    final covered = <String>{};
    for (final bin in candidates) {
      final folderName = p.basename(bin.parent.path);
      if (folderName.startsWith('session_') || folderName.startsWith('unknown_') || folderName.startsWith('.')) {
        continue;
      }
      final binName = p.basename(bin.path);
      final parts = binName.split('.').first.split('_');
      if (parts.isEmpty) continue;
      final timerStart = int.tryParse(parts.first);
      if (timerStart == null || timerStart < 946684800) continue;
      int binSize;
      try {
        binSize = await bin.length();
      } catch (_) {
        continue;
      }
      if (binSize <= binHeaderBytes) continue;
      final binStartMs = timerStart * 1000;
      final binDurationMs = (((binSize - binHeaderBytes) / opusBytesPerMs)).ceil();
      final binEndMs = binStartMs + binDurationMs;
      for (final iv in merged) {
        if (binStartMs >= iv[0] && binEndMs <= iv[1]) {
          covered.add(bin.path);
          break;
        }
      }
    }
    return covered;
  }

  /// Deletes raw .bin segments that a finalized recording has already consumed.
  /// Idempotency guard against the mid-processing kill path where VAD wrote a
  /// `recording_<ts>.wav` but the app was killed (e.g. by an APK update) before
  /// the `delete_segments` IPC ran. Without this guard, the leftover bins re-VAD
  /// on next launch and produce a near-duplicate .wav with a slightly different
  /// VAD cut.
  ///
  /// Pruning is by EXACT bin membership, not a geometric time window. Every
  /// finalized recording's `.meta` records the exact set of bins it consumed
  /// (`relativeBins`, written by `_saveRecording`), so a bin is deleted iff:
  ///   • some finalized recording lists it in `relativeBins`  (its audio is now
  ///     safely re-encoded into the .m4a/.wav, so the raw copy is redundant), AND
  ///   • no draft lists it      — an in-progress draft's last bin may still hold
  ///     un-decoded tail that the next cycle will process, AND
  ///   • no discard references it — the bin is the only copy of recoverable audio
  ///     behind a ghost row's "recover" action.
  ///
  /// This replaces the old geometric coverage window. That window padded each
  /// recording with a 10-minute LEFT slack (to catch the bin straddling the
  /// recording's start, whose silent head VAD trimmed) and a vadSplitSeconds
  /// RIGHT slack (provably-silent tail). The left slack over-reached: a bin
  /// sitting a few minutes BEFORE a recording — e.g. a short below-min-speech
  /// discard — fell inside the window and was swept, silently breaking
  /// recoverDiscard. The exact-membership rule needs no slack: the straddle bin
  /// at a recording's start is still reclaimed because the recording lists it
  /// (its speech frames were consumed; only the already-trimmed silent head is
  /// lost, which is the intent), while unrelated neighbours are never touched.
  /// Recordings whose legacy `.meta` predates the bin-list field contribute no
  /// entries and so simply retain their bins (conservative).
  ///
  /// use [coveredBinPaths] to skip bins during VAD without deleting.
  ///
  /// [protectedRelBins] adds caller-supplied `raw_segments/`-relative paths to the
  /// protected set — used to pass the still-mid-transfer bins
  /// ([WalSync.incompleteBinRelPaths]). A partially-transferred bin is the file the
  /// next sync resumes INTO, so deleting it forces a full re-fetch even though the
  /// exact-membership rule below thinks its audio is safely consumed (reachable when
  /// a Force run, or an app version predating the mid-transfer guard, finalized a
  /// recording over the prefix). Callers resolve the set themselves and skip the
  /// prune entirely when it can't be read — see [processAllCompletedSessions].
  ///
  /// Returns the number of bins deleted.
  static Future<int> pruneConsumedBins({Set<String> protectedRelBins = const {}}) async {
    final directory = await getApplicationDocumentsDirectory();
    final rawDir = Directory('${directory.path}/raw_segments');
    if (!await rawDir.exists()) return 0;

    // Bins consumed by a finalized recording (candidates for deletion) vs. bins
    // that must be preserved. `discardedRelBinPaths` seeds the protected set
    // (ghost-row recovery); draft recordings add to it (in-progress tail);
    // [protectedRelBins] carries the caller's mid-transfer set.
    // `silence_trimmed` is intentionally NOT protected — it is recording-adjacent
    // trailing silence already folded into the recording, safe to drop.
    final consumed = <String>{};
    final protectedBins = await discardedRelBinPaths();
    protectedBins.addAll(protectedRelBins);
    final recordingsDir = Directory('${directory.path}/recordings');
    if (await recordingsDir.exists()) {
      await for (final dayFolder in recordingsDir.list()) {
        if (dayFolder is! Directory) continue;
        await for (final entity in dayFolder.list()) {
          if (entity is! File) continue;
          final path = entity.path;
          if (!(path.endsWith('.wav') || path.endsWith('.m4a')) || path.contains('.tmp.')) continue;
          final conv = Conversation.fromFile(entity);
          if (path.contains('_draft.')) {
            protectedBins.addAll(conv.relativeBins); // in-progress: keep every bin it touches
          } else {
            consumed.addAll(conv.relativeBins);
          }
        }
      }
    }
    final deletable = consumed.difference(protectedBins);
    if (deletable.isEmpty) return 0;

    int deletedCount = 0;
    final touchedFolders = <Directory>{};
    await for (final folder in rawDir.list()) {
      if (folder is! Directory) continue;
      final folderName = p.basename(folder.path);
      if (folderName.startsWith('.')) continue;
      await for (final binEntity in folder.list()) {
        if (binEntity is! File || !binEntity.path.endsWith('.bin')) continue;
        final binName = p.basename(binEntity.path);
        if (!deletable.contains('$folderName/$binName')) continue;
        try {
          await binEntity.delete();
          deletedCount++;
          touchedFolders.add(folder);
          Logger.debug('RecordingsManager: pruneConsumedBins deleted $binName (consumed by a finalized recording)');
        } catch (e) {
          Logger.error('RecordingsManager: pruneConsumedBins failed to delete ${binEntity.path}: $e');
        }
      }
    }

    // Drop any session folders that just emptied — keeps raw_segments/ tidy.
    for (final folder in touchedFolders) {
      try {
        if (await folder.exists() && await folder.list().isEmpty) {
          await folder.delete();
        }
      } catch (_) {}
    }

    return deletedCount;
  }

  /// Deletes raw .bin segments belonging to any of [sessionIds], bypassing the
  /// 48h discard hold. Used after deleting conversations from a tab so an
  /// emptied session does not silently reprocess on the next sync.
  static Future<int> deleteBinsForSessions(Set<int> sessionIds) async {
    if (sessionIds.isEmpty) return 0;
    final directory = await getApplicationDocumentsDirectory();
    final rawDir = Directory('${directory.path}/raw_segments');
    if (!await rawDir.exists()) return 0;

    int deleted = 0;
    final touchedFolders = <Directory>{};
    await for (final entity in rawDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      final name = entity.path.split('/').last;
      final parts = name.split('_');
      if (parts.length < 2) continue;
      final sid = int.tryParse(parts[1].split('.').first);
      if (sid == null || !sessionIds.contains(sid)) continue;
      try {
        await entity.delete();
        deleted++;
        touchedFolders.add(entity.parent);
      } catch (e) {
        Logger.error('RecordingsManager: deleteBinsForSessions failed for ${entity.path}: $e');
      }
    }
    for (final dir in touchedFolders) {
      try {
        if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
      } catch (_) {}
    }
    if (deleted > 0) {
      Logger.debug('RecordingsManager: Deleted $deleted bins for orphaned sessions ${sessionIds.toList()}');
    }
    return deleted;
  }
}
