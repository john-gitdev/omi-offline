import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/logger.dart';

// ─── Data structures ──────────────────────────────────────────────────────────

class _MetaAnchor {
  final int frameIndex; // audio frame index (after this many audio frames)
  final int utcMs;
  const _MetaAnchor(this.frameIndex, this.utcMs);
}

class _ChunkMeta {
  final File file;
  final int chunkIndex; // index in batch.rawChunks
  final DateTime startTime;
  final int frameCount; // audio frames only (not metadata packets)
  final List<_MetaAnchor> metaAnchors;

  const _ChunkMeta({
    required this.file,
    required this.chunkIndex,
    required this.startTime,
    required this.frameCount,
    required this.metaAnchors,
  });

  DateTime get endTime => startTime.add(Duration(milliseconds: frameCount * 20));
}

class _ChunkVad {
  final _ChunkMeta chunk;
  final Uint8List speechFlags; // 1=speech, 0=silence, one per audio frame
  final Int32List byteOffsets; // byte offset of each frame's 4-byte length prefix
  final Int16List frameLengths; // Opus payload length per frame
  final Int64List frameTimesMs; // epoch-ms per frame, monotonic

  const _ChunkVad({
    required this.chunk,
    required this.speechFlags,
    required this.byteOffsets,
    required this.frameLengths,
    required this.frameTimesMs,
  });

  int get approxBytes => speechFlags.length + byteOffsets.lengthInBytes + frameLengths.lengthInBytes + frameTimesMs.lengthInBytes;
}

class _VadState {
  double noiseFloorDbfs = -40.0;
  int hangoverFrames = 0;
  int noiseFloorInitFrames = 50;
}

class _Window {
  int startChunkIdx;
  int startFrameIdx;
  int endChunkIdx;
  int endFrameIdx;
  DateTime startTime;
  bool isComplete;
  List<DateTime> starTimes;

  _Window({
    required this.startChunkIdx,
    required this.startFrameIdx,
    required this.endChunkIdx,
    required this.endFrameIdx,
    required this.startTime,
    required this.isComplete,
    required this.starTimes,
  });
}

// ─── Constants ────────────────────────────────────────────────────────────────

const int _frameDurationMs = 20;
const int _sampleRate = 16000;
const int _channels = 1;
const int _waveformBuckets = 200;
const int _bucketSize = 800;
const double _noiseFloorAlphaRise = 0.995;
const double _noiseFloorAlphaFall = 0.98;
const int _warmupFrames = 1500; // 30 seconds
const int _starToleranceFrames = 250; // ±5 seconds
const int _maxWindowFrames = 2 * 3600 * 1000 ~/ _frameDurationMs; // 2hr cap
const int _safetyMarginChunks = 2;
const int _cacheMaxBytes = 5 * 1024 * 1024; // 5 MB

// ─── ManualRecordingExtractor ─────────────────────────────────────────────────

class ManualRecordingExtractor {
  final int _splitFrames;
  final double _snrMarginDb;
  final int _hangoverFrameCount;

  ManualRecordingExtractor()
      : _splitFrames = SharedPreferencesUtil().offlineSplitSeconds * 1000 ~/ _frameDurationMs,
        _snrMarginDb = SharedPreferencesUtil().offlineSnrMarginDb,
        _hangoverFrameCount =
            max(0, (SharedPreferencesUtil().offlineHangoverSeconds * 1000).round() ~/ _frameDurationMs);

  void destroy() {}

  Future<({List<String> savedPaths, int lastSafeChunkIndex})> process(
    DailyBatch batch,
    String tempOutputDir, {
    bool forceFlush = false,
  }) async {
    if (batch.rawChunks.isEmpty) {
      return (savedPaths: <String>[], lastSafeChunkIndex: -1);
    }

    final chunks = await _buildChunkMeta(batch);
    if (chunks.isEmpty) return (savedPaths: <String>[], lastSafeChunkIndex: -1);

    final newestEnd = chunks.last.endTime;
    final twoHrCutoff = newestEnd.subtract(const Duration(hours: 2));

    // Fast path — no stars
    if (batch.starredTimestamps.isEmpty) {
      final lastSafe = _cutoffIndex(chunks, twoHrCutoff);
      return (savedPaths: <String>[], lastSafeChunkIndex: lastSafe);
    }

    // Full path — stars present
    final mergedRanges = _computeMergedRanges(batch.starredTimestamps, chunks);
    final vadCache = await _runVadPass(chunks, mergedRanges);

    final windows = _findWindows(batch.starredTimestamps, chunks, vadCache);
    final merged = _mergeWindows(windows, chunks);

    final savedPaths = <String>[];
    for (final w in merged) {
      final path = await _encodeWindow(w, chunks, vadCache, tempOutputDir);
      if (path != null) savedPaths.add(path);
    }

    final lastSafe = _computeLastSafe(chunks, merged, twoHrCutoff, forceFlush, newestEnd);
    return (savedPaths: savedPaths, lastSafeChunkIndex: lastSafe);
  }

  // ─── Phase 1: Build chunk metadata ─────────────────────────────────────────

  Future<List<_ChunkMeta>> _buildChunkMeta(DailyBatch batch) async {
    final result = <_ChunkMeta>[];
    for (int i = 0; i < batch.rawChunks.length; i++) {
      final file = batch.rawChunks[i];
      final meta = await _parseSingleChunkMeta(file, i);
      result.add(meta);
    }
    return result;
  }

  Future<_ChunkMeta> _parseSingleChunkMeta(File file, int chunkIndex) async {
    // Resolve startTime from SharedPreferences anchors
    final sessionIdStr = file.parent.path.split('/').last;
    final int? sessionId = int.tryParse(sessionIdStr);
    final chunkFileName = file.path.split('/').last.replaceAll('.bin', '');
    final chunkIdxStr = chunkFileName.contains('_') ? chunkFileName.split('_').last : null;
    final chunkPrefsIdx = chunkIdxStr != null ? int.tryParse(chunkIdxStr) : null;

    DateTime startTime;
    if (sessionId != null && chunkPrefsIdx != null) {
      final anchorUtc = SharedPreferencesUtil().getInt('anchor_utc_${sessionId}_$chunkPrefsIdx', defaultValue: 0);
      final anchorUptime = SharedPreferencesUtil().getInt('anchor_uptime_${sessionId}_$chunkPrefsIdx', defaultValue: 0);
      if (anchorUtc > 0) {
        startTime = DateTime.fromMillisecondsSinceEpoch(anchorUtc * 1000);
      } else if (anchorUptime > 0) {
        final sessionAnchorUtc = SharedPreferencesUtil().getInt('anchor_utc_$sessionId', defaultValue: 0);
        final sessionAnchorUptime = SharedPreferencesUtil().getInt('anchor_uptime_$sessionId', defaultValue: 0);
        if (sessionAnchorUtc > 0 && sessionAnchorUptime > 0) {
          final realUtcSecs = sessionAnchorUtc - ((sessionAnchorUptime - anchorUptime) ~/ 1000);
          startTime = DateTime.fromMillisecondsSinceEpoch(realUtcSecs * 1000);
        } else {
          startTime = file.lastModifiedSync();
        }
      } else {
        startTime = file.lastModifiedSync();
      }
    } else {
      startTime = file.lastModifiedSync();
    }

    // Scan file for metadata packets and count audio frames — no PCM decoding
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      Logger.error('ManualRecordingExtractor: failed to read $file: $e');
      return _ChunkMeta(file: file, chunkIndex: chunkIndex, startTime: startTime, frameCount: 0, metaAnchors: []);
    }

    final bd = ByteData.sublistView(bytes);
    int off = 0;
    int audioFrameCount = 0;
    final anchors = <_MetaAnchor>[];

    while (off + 4 <= bytes.length) {
      final len = bd.getUint32(off, Endian.little);
      if (off + 4 + len > bytes.length) break;
      if (len == 255) {
        // Metadata packet — extract UTC timestamp
        try {
          final utcSecs = bd.getUint32(off + 4, Endian.little);
          if (utcSecs > 0) {
            anchors.add(_MetaAnchor(audioFrameCount, utcSecs * 1000));
          } else if (sessionId != null) {
            // Fall back to uptime-relative computation
            final uptimeMs = bd.getUint32(off + 8, Endian.little);
            final sessAnchorUtc = SharedPreferencesUtil().getInt('anchor_utc_$sessionId', defaultValue: 0);
            final sessAnchorUptime = SharedPreferencesUtil().getInt('anchor_uptime_$sessionId', defaultValue: 0);
            if (sessAnchorUtc > 0 && sessAnchorUptime > 0) {
              final realUtcSecs = sessAnchorUtc - ((sessAnchorUptime - uptimeMs) ~/ 1000);
              anchors.add(_MetaAnchor(audioFrameCount, realUtcSecs * 1000));
            }
          }
        } catch (_) {}
      } else {
        audioFrameCount++;
      }
      off += 4 + len;
    }

    // If no anchors found from metadata packets, synthesize one from startTime
    if (anchors.isEmpty) {
      anchors.add(_MetaAnchor(0, startTime.millisecondsSinceEpoch));
    }

    return _ChunkMeta(
      file: file,
      chunkIndex: chunkIndex,
      startTime: startTime,
      frameCount: audioFrameCount,
      metaAnchors: anchors,
    );
  }

  // ─── Phase 2: Compute merged scan ranges ───────────────────────────────────

  /// Returns list of `[startChunkIdx, endChunkIdx]` (inclusive, merged).
  List<(int, int)> _computeMergedRanges(List<DateTime> stars, List<_ChunkMeta> chunks) {
    if (chunks.isEmpty) return [];

    final raw = <(int, int)>[];
    for (final star in stars) {
      final centerChunk = _findChunkForTime(chunks, star);
      // Extend scan range back 2 hours and forward by maxWindowFrames * 20ms
      final backMs = 2 * 3600 * 1000;
      final fwdMs = _maxWindowFrames * _frameDurationMs;
      final rangeStart = star.subtract(Duration(milliseconds: backMs));
      final rangeEnd = star.add(Duration(milliseconds: fwdMs));
      final startChunk = max(0, _findChunkForTime(chunks, rangeStart));
      final endChunk = min(chunks.length - 1, _findChunkForTime(chunks, rangeEnd));
      if (startChunk <= endChunk) {
        raw.add((startChunk, endChunk));
      } else {
        raw.add((centerChunk, centerChunk));
      }
    }

    // Sort and merge overlapping / adjacent intervals
    raw.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final r in raw) {
      if (merged.isEmpty) {
        merged.add(r);
      } else {
        final last = merged.last;
        if (r.$1 <= last.$2 + 1) {
          merged[merged.length - 1] = (last.$1, max(last.$2, r.$2));
        } else {
          merged.add(r);
        }
      }
    }
    return merged;
  }

  // ─── Phase 3: Single ordered VAD pass ─────────────────────────────────────

  Future<Map<int, _ChunkVad>> _runVadPass(List<_ChunkMeta> chunks, List<(int, int)> ranges) async {
    final cache = <int, _ChunkVad>{};
    int cacheBytes = 0;

    for (final range in ranges) {
      final vadState = _VadState();

      // Compute warmup start
      var warmupChunk = range.$1;
      var warmupFrame = -_warmupFrames; // offset from firstFrameInChunk=0 of first range chunk
      // Walk back until warmupFrame >= 0 or no more previous chunks
      while (warmupFrame < 0 && warmupChunk > 0) {
        warmupChunk--;
        warmupFrame += chunks[warmupChunk].frameCount;
      }
      if (warmupFrame < 0) warmupFrame = 0;

      // Determine contiguous chunk range including warmup
      final decodeStart = warmupChunk;
      final decodeEnd = range.$2;

      for (int ci = decodeStart; ci <= decodeEnd; ci++) {
        final chunk = chunks[ci];
        if (chunk.frameCount == 0) continue;

        final bytes = await chunk.file.readAsBytes();
        final bd = ByteData.sublistView(bytes);

        final speechFlags = Uint8List(chunk.frameCount);
        final byteOffsets = Int32List(chunk.frameCount);
        final frameLengths = Int16List(chunk.frameCount);
        final frameTimesMs = Int64List(chunk.frameCount);

        // Compute per-frame timestamps using metaAnchors with monotonicity clamping
        int anchorIdx = 0;
        int prevMs = chunk.metaAnchors.isNotEmpty ? chunk.metaAnchors[0].utcMs : chunk.startTime.millisecondsSinceEpoch;

        // Track which frames are within the actual scan range (not just warmup)
        final isWarmupChunk = ci < range.$1;
        final warmupFrameStart = (ci == warmupChunk) ? warmupFrame : 0;

        int off = 0;
        int audioIdx = 0;
        final decoder = Platform.isIOS || Platform.isAndroid
            ? SimpleOpusDecoder(sampleRate: _sampleRate, channels: _channels)
            : null;

        try {
          while (off + 4 <= bytes.length) {
            final len = bd.getUint32(off, Endian.little);
            if (off + 4 + len > bytes.length) break;
            if (len == 255) {
              off += 4 + len;
              continue; // metadata already processed in _buildChunkMeta
            }

            final byteOff = off;
            off += 4 + len;

            if (audioIdx >= chunk.frameCount) break;

            // Advance anchor to the most recent one at or before audioIdx
            while (anchorIdx + 1 < chunk.metaAnchors.length &&
                chunk.metaAnchors[anchorIdx + 1].frameIndex <= audioIdx) {
              anchorIdx++;
            }
            final anchor = chunk.metaAnchors[anchorIdx];
            final rawMs = anchor.utcMs + (audioIdx - anchor.frameIndex) * _frameDurationMs;

            // Monotonicity clamp
            final int frameMs;
            final drift = rawMs - prevMs;
            if (drift < _frameDurationMs && drift > -100) {
              // Small regression or tiny forward step — clamp to monotonic
              frameMs = prevMs + _frameDurationMs;
            } else {
              // Trust anchor (large re-sync or normal forward progression)
              frameMs = rawMs;
            }
            prevMs = frameMs;

            frameTimesMs[audioIdx] = frameMs;
            byteOffsets[audioIdx] = byteOff;
            frameLengths[audioIdx] = len;

            // Decode for VAD only if within warmup range or main range
            final skipVad = isWarmupChunk && audioIdx < warmupFrameStart;
            if (!skipVad && decoder != null) {
              if (audioIdx % 50 == 0) await Future.delayed(Duration.zero);
              try {
                final opus = Uint8List.sublistView(bytes, byteOff + 4, byteOff + 4 + len);
                final pcm = decoder.decode(input: opus);
                final flag = _vadStep(pcm, vadState);
                if (!isWarmupChunk) {
                  speechFlags[audioIdx] = flag ? 1 : 0;
                }
              } catch (_) {}
            }

            audioIdx++;
          }
        } finally {
          decoder?.destroy();
        }

        if (!isWarmupChunk) {
          final vad = _ChunkVad(
            chunk: chunk,
            speechFlags: speechFlags,
            byteOffsets: byteOffsets,
            frameLengths: frameLengths,
            frameTimesMs: frameTimesMs,
          );
          cache[ci] = vad;
          cacheBytes += vad.approxBytes;

          // Evict completed earlier ranges if over budget
          if (cacheBytes > _cacheMaxBytes) {
            cacheBytes = _evictCache(cache, range.$1);
          }
        }
      }
    }

    return cache;
  }

  bool _vadStep(Int16List pcm, _VadState state) {
    final dbfs = _calculateDbfs(pcm);

    if (state.noiseFloorInitFrames > 0) {
      state.noiseFloorDbfs = min(state.noiseFloorDbfs, dbfs + 3);
      state.noiseFloorInitFrames--;
    }

    final rawSpeech = dbfs > state.noiseFloorDbfs + _snrMarginDb;

    if (!rawSpeech) {
      if (dbfs > state.noiseFloorDbfs) {
        state.noiseFloorDbfs = _noiseFloorAlphaRise * state.noiseFloorDbfs + (1 - _noiseFloorAlphaRise) * dbfs;
      } else {
        state.noiseFloorDbfs = _noiseFloorAlphaFall * state.noiseFloorDbfs + (1 - _noiseFloorAlphaFall) * dbfs;
      }
    }

    if (rawSpeech) {
      state.hangoverFrames = _hangoverFrameCount;
      return true;
    } else if (state.hangoverFrames > 0) {
      state.hangoverFrames--;
      return true;
    }
    return false;
  }

  double _calculateDbfs(Int16List pcm) {
    if (pcm.isEmpty) return -100.0;
    double sum = 0;
    for (final s in pcm) {
      sum += s * s;
    }
    final rms = sqrt(sum / pcm.length);
    if (rms == 0) return -100.0;
    return 20 * log(rms / 32768) / ln10;
  }

  int _evictCache(Map<int, _ChunkVad> cache, int activeRangeStart) {
    int freed = 0;
    final toEvict = cache.keys.where((k) => k < activeRangeStart).toList();
    for (final k in toEvict) {
      freed += cache[k]!.approxBytes;
      cache.remove(k);
    }
    return freed;
  }

  // ─── Phase 4: Find windows per star ────────────────────────────────────────

  List<_Window> _findWindows(List<DateTime> stars, List<_ChunkMeta> chunks, Map<int, _ChunkVad> vadCache) {
    final windows = <_Window>[];

    for (final star in stars) {
      final (chunkIdx: ci, frameIdx: fi) = _locateStar(chunks, vadCache, star);
      if (ci < 0 || ci >= chunks.length) continue;

      // Skip if already covered by a complete window
      if (_coveredByComplete(windows, chunks, ci, fi)) continue;

      // Find nearest speech frame, biased backward
      final (speechChunk: speechCi, speechFrame: speechFi) = _findNearestSpeech(chunks, vadCache, ci, fi);

      if (speechCi < 0) {
        // No speech found within tolerance — skip this star
        continue;
      }

      // Backward scan from speech frame for conversation start
      final (startChunkIdx: startCi, startFrameIdx: startFi, hitBoundary: _) =
          _scanBackward(chunks, vadCache, speechCi, speechFi);

      // Forward scan from star frame for conversation end
      final (endChunkIdx: endCi, endFrameIdx: endFi, isComplete: complete) =
          _scanForward(chunks, vadCache, ci, fi);

      // Derive start time from frameTimesMs if available
      final startVad = vadCache[startCi];
      DateTime startTime;
      if (startVad != null && startFi < startVad.frameTimesMs.length) {
        startTime = DateTime.fromMillisecondsSinceEpoch(startVad.frameTimesMs[startFi]);
      } else {
        startTime = chunks[startCi].startTime.add(Duration(milliseconds: startFi * _frameDurationMs));
      }

      windows.add(_Window(
        startChunkIdx: startCi,
        startFrameIdx: startFi,
        endChunkIdx: endCi,
        endFrameIdx: endFi,
        startTime: startTime,
        isComplete: complete,
        starTimes: [star],
      ));
    }

    return windows;
  }

  bool _coveredByComplete(List<_Window> windows, List<_ChunkMeta> chunks, int ci, int fi) {
    for (final w in windows) {
      if (!w.isComplete) continue;
      if (_globalFrame(chunks, ci, fi) >= _globalFrame(chunks, w.startChunkIdx, w.startFrameIdx) &&
          _globalFrame(chunks, ci, fi) <= _globalFrame(chunks, w.endChunkIdx, w.endFrameIdx)) {
        return true;
      }
    }
    return false;
  }

  int _globalFrame(List<_ChunkMeta> chunks, int ci, int fi) {
    int total = 0;
    for (int i = 0; i < ci && i < chunks.length; i++) {
      total += chunks[i].frameCount;
    }
    return total + fi;
  }

  ({int chunkIdx, int frameIdx}) _locateStar(
      List<_ChunkMeta> chunks, Map<int, _ChunkVad> vadCache, DateTime star) {
    final ci = _findChunkForTime(chunks, star);
    if (ci < 0 || ci >= chunks.length) return (chunkIdx: -1, frameIdx: 0);

    final vad = vadCache[ci];
    if (vad == null || vad.frameTimesMs.isEmpty) {
      // Approximate
      final ms = star.difference(chunks[ci].startTime).inMilliseconds;
      final fi = (ms ~/ _frameDurationMs).clamp(0, max(0, chunks[ci].frameCount - 1)).toInt();
      return (chunkIdx: ci, frameIdx: fi);
    }

    // Binary search in frameTimesMs
    final tMs = star.millisecondsSinceEpoch;
    final times = vad.frameTimesMs;
    int lo = 0, hi = times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (times[mid] <= tMs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (chunkIdx: ci, frameIdx: lo);
  }

  /// Backward-biased: scan [markerFrame-250, markerFrame] first;
  /// extend forward only if nothing found behind.
  ({int speechChunk, int speechFrame}) _findNearestSpeech(
      List<_ChunkMeta> chunks, Map<int, _ChunkVad> vadCache, int ci, int fi) {
    // Scan backward first
    for (int delta = 0; delta <= _starToleranceFrames; delta++) {
      final (c, f) = _offsetFrame(chunks, ci, fi, -delta);
      if (c < 0) break;
      final vad = vadCache[c];
      if (vad != null && f < vad.speechFlags.length && vad.speechFlags[f] == 1) {
        return (speechChunk: c, speechFrame: f);
      }
    }
    // Extend forward
    for (int delta = 1; delta <= _starToleranceFrames; delta++) {
      final (c, f) = _offsetFrame(chunks, ci, fi, delta);
      if (c < 0) break;
      final vad = vadCache[c];
      if (vad != null && f < vad.speechFlags.length && vad.speechFlags[f] == 1) {
        return (speechChunk: c, speechFrame: f);
      }
    }
    return (speechChunk: -1, speechFrame: 0);
  }

  /// Scan backward from (ci, fi) until [_splitFrames] consecutive silence or chunk 0/frame 0.
  ({int startChunkIdx, int startFrameIdx, bool hitBoundary}) _scanBackward(
      List<_ChunkMeta> chunks, Map<int, _ChunkVad> vadCache, int ci, int fi) {
    int consec = 0;
    int cur = -1; // current absolute frame (walking backward)
    var (scanCi, scanFi) = (ci, fi);

    while (true) {
      final vad = vadCache[scanCi];
      final isSilence = vad == null || scanFi >= vad.speechFlags.length || vad.speechFlags[scanFi] == 0;

      if (isSilence) {
        consec++;
        if (consec >= _splitFrames) {
          // Found start boundary — return frame after the silence block
          final (bc, bf) = _offsetFrame(chunks, scanCi, scanFi, consec);
          return (startChunkIdx: bc < 0 ? 0 : bc, startFrameIdx: bc < 0 ? 0 : bf, hitBoundary: true);
        }
      } else {
        consec = 0;
      }

      // Step backward
      if (scanFi > 0) {
        scanFi--;
      } else if (scanCi > 0) {
        scanCi--;
        scanFi = max(0, chunks[scanCi].frameCount - 1);
      } else {
        // Hit beginning of all available data
        return (startChunkIdx: 0, startFrameIdx: 0, hitBoundary: false);
      }

      cur--;
      if (cur < -(chunks.fold(0, (s, c) => s + c.frameCount))) break;
    }
    return (startChunkIdx: 0, startFrameIdx: 0, hitBoundary: false);
  }

  /// Scan forward from (ci, fi) until [_splitFrames] consecutive silence or [_maxWindowFrames] total.
  ({int endChunkIdx, int endFrameIdx, bool isComplete}) _scanForward(
      List<_ChunkMeta> chunks, Map<int, _ChunkVad> vadCache, int ci, int fi) {
    int consec = 0;
    int totalFrames = 0;
    var scanCi = ci;
    var scanFi = fi;

    while (totalFrames < _maxWindowFrames) {
      final vad = vadCache[scanCi];
      final isSilence = vad == null || scanFi >= vad.speechFlags.length || vad.speechFlags[scanFi] == 0;

      if (isSilence) {
        consec++;
        if (consec >= _splitFrames) {
          // End boundary found — return frame before the silence block
          final endFi = scanFi - consec + 1;
          if (endFi >= 0) {
            return (endChunkIdx: scanCi, endFrameIdx: endFi, isComplete: true);
          } else {
            // Silence block started in previous chunk — backtrack
            final (bc, bf) = _offsetFrame(chunks, scanCi, 0, endFi);
            return (endChunkIdx: bc < 0 ? 0 : bc, endFrameIdx: bc < 0 ? 0 : bf, isComplete: true);
          }
        }
      } else {
        consec = 0;
      }

      totalFrames++;

      // Step forward
      if (scanFi + 1 < (vadCache[scanCi]?.speechFlags.length ?? chunks[scanCi].frameCount)) {
        scanFi++;
      } else if (scanCi + 1 < chunks.length) {
        scanCi++;
        scanFi = 0;
        // consec intentionally NOT reset — silence count carries across chunk boundaries
      } else {
        // Hit end of all available data
        return (endChunkIdx: scanCi, endFrameIdx: scanFi, isComplete: false);
      }
    }

    // Hit maxWindowFrames cap
    Logger.debug('ManualRecordingExtractor: window truncated at maxWindowFrames cap');
    return (endChunkIdx: scanCi, endFrameIdx: scanFi, isComplete: false);
  }

  // ─── Phase 5: Merge overlapping windows ────────────────────────────────────

  List<_Window> _mergeWindows(List<_Window> windows, List<_ChunkMeta> chunks) {
    if (windows.isEmpty) return [];

    windows.sort((a, b) =>
        _globalFrame(chunks, a.startChunkIdx, a.startFrameIdx)
            .compareTo(_globalFrame(chunks, b.startChunkIdx, b.startFrameIdx)));

    final merged = <_Window>[];
    for (final w in windows) {
      if (merged.isEmpty) {
        merged.add(w);
        continue;
      }
      final last = merged.last;
      final lastEnd = _globalFrame(chunks, last.endChunkIdx, last.endFrameIdx);
      final wStart = _globalFrame(chunks, w.startChunkIdx, w.startFrameIdx);
      if (wStart <= lastEnd) {
        // Overlapping — extend last
        if (_globalFrame(chunks, w.endChunkIdx, w.endFrameIdx) > lastEnd) {
          last.endChunkIdx = w.endChunkIdx;
          last.endFrameIdx = w.endFrameIdx;
          last.isComplete = last.isComplete || w.isComplete;
        }
        last.starTimes.addAll(w.starTimes);
      } else {
        merged.add(w);
      }
    }

    // Re-apply maxWindowFrames cap per merged window using median star
    for (final w in merged) {
      final windowFrames =
          _globalFrame(chunks, w.endChunkIdx, w.endFrameIdx) - _globalFrame(chunks, w.startChunkIdx, w.startFrameIdx);
      if (windowFrames > _maxWindowFrames) {
        final medianStar = _medianStar(w.starTimes);
        final starLoc = _locateStar(chunks, {}, medianStar);
        final medianGlobal = _globalFrame(chunks, starLoc.chunkIdx, starLoc.frameIdx);
        final startGlobal = _globalFrame(chunks, w.startChunkIdx, w.startFrameIdx);
        final endGlobal = _globalFrame(chunks, w.endChunkIdx, w.endFrameIdx);
        final midPoint = (startGlobal + endGlobal) ~/ 2;
        if (medianGlobal <= midPoint) {
          // Median is in first half — trim from end
          final newEnd = startGlobal + _maxWindowFrames;
          final (nc, nf) = _frameAt(chunks, newEnd);
          w.endChunkIdx = nc;
          w.endFrameIdx = nf;
        } else {
          // Median is in second half — trim from start
          final newStart = endGlobal - _maxWindowFrames;
          final (nc, nf) = _frameAt(chunks, max(0, newStart));
          w.startChunkIdx = nc;
          w.startFrameIdx = nf;
        }
      }
    }

    return merged;
  }

  DateTime _medianStar(List<DateTime> stars) {
    if (stars.isEmpty) return DateTime.now();
    final sorted = List<DateTime>.from(stars)..sort();
    return sorted[sorted.length ~/ 2];
  }

  // ─── Phase 6: Encode window ─────────────────────────────────────────────────

  Future<String?> _encodeWindow(
      _Window w, List<_ChunkMeta> chunks, Map<int, _ChunkVad> vadCache, String outputDir) async {
    final startVad = vadCache[w.startChunkIdx];
    final timestamp = startVad != null && w.startFrameIdx < startVad.frameTimesMs.length
        ? startVad.frameTimesMs[w.startFrameIdx]
        : w.startTime.millisecondsSinceEpoch;

    final m4aPath = '$outputDir/recording_$timestamp.m4a';
    final decoder = Platform.isIOS || Platform.isAndroid
        ? SimpleOpusDecoder(sampleRate: _sampleRate, channels: _channels)
        : null;

    final peakAmplitudes = List<double>.filled(_waveformBuckets, 0.0);
    final batchBuffer = BytesBuilder(copy: false);
    int batchFrameCount = 0;
    int totalSamples = 0;
    const batchFrames = 15;

    String? aacSession;
    try {
      aacSession = await AacEncoder.startEncoder(_sampleRate, m4aPath);
    } on Exception catch (e) {
      Logger.error('ManualRecordingExtractor: AAC startEncoder failed: $e');
      decoder?.destroy();
      return null;
    }

    Future<void> flushBatch() async {
      if (batchBuffer.isEmpty) return;
      final data = batchBuffer.toBytes();
      batchBuffer.clear();
      batchFrameCount = 0;
      await AacEncoder.encodeChunk(aacSession!, Uint8List.fromList(data));
    }

    String? currentFilePath;
    RandomAccessFile? currentRaf;
    int nextExpectedOffset = -1;
    int frameCount = 0;

    try {
      for (int ci = w.startChunkIdx; ci <= w.endChunkIdx; ci++) {
        final vad = vadCache[ci];
        if (vad == null) continue;

        final frameStart = ci == w.startChunkIdx ? w.startFrameIdx : 0;
        final frameEnd = ci == w.endChunkIdx ? w.endFrameIdx : vad.speechFlags.length - 1;

        for (int fi = frameStart; fi <= frameEnd; fi++) {
          if (fi >= vad.byteOffsets.length) break;
          if (frameCount++ % 50 == 0) await Future.delayed(Duration.zero);

          final ref_file = chunks[ci].file;
          if (ref_file.path != currentFilePath) {
            await currentRaf?.close();
            currentRaf = await ref_file.open(mode: FileMode.read);
            currentFilePath = ref_file.path;
            nextExpectedOffset = -1;
          }

          final frameDataOffset = vad.byteOffsets[fi] + 4;
          if (nextExpectedOffset != frameDataOffset) {
            await currentRaf!.setPosition(frameDataOffset);
          }

          final len = vad.frameLengths[fi];
          final opusBytes = Uint8List.fromList(await currentRaf!.read(len));
          nextExpectedOffset = frameDataOffset + len;

          if (decoder == null) continue;
          Int16List pcm;
          try {
            pcm = decoder.decode(input: opusBytes);
          } catch (_) {
            continue;
          }

          for (int s = 0; s < pcm.length; s++) {
            final bucket = min(_waveformBuckets - 1, (totalSamples + s) ~/ _bucketSize);
            final amp = pcm[s].abs() / 32768.0;
            if (amp > peakAmplitudes[bucket]) peakAmplitudes[bucket] = amp;
          }
          totalSamples += pcm.length;

          batchBuffer.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
          batchFrameCount++;
          if (batchFrameCount >= batchFrames) await flushBatch();
        }
      }

      await flushBatch();
      await AacEncoder.finishEncoder(aacSession!);
    } on Exception catch (e) {
      Logger.error('ManualRecordingExtractor: AAC encoding failed: $e');
      await currentRaf?.close();
      decoder?.destroy();
      return null;
    } finally {
      await currentRaf?.close();
      decoder?.destroy();
    }

    // Write .meta sidecar
    final durationMs = (totalSamples * 1000) ~/ _sampleRate;
    final metaBytes = ByteData(408);
    metaBytes.setUint32(0, totalSamples, Endian.little);
    metaBytes.setUint32(4, durationMs, Endian.little);
    for (int i = 0; i < _waveformBuckets; i++) {
      final peak16 = (peakAmplitudes[i] * 65535.0).round().clamp(0, 65535);
      metaBytes.setUint16(8 + i * 2, peak16, Endian.little);
    }
    final metaOut = List<int>.from(metaBytes.buffer.asUint8List());
    final deviceId = SharedPreferencesUtil().btDevice.id.replaceAll(':', '').toUpperCase();
    if (deviceId.length >= 6) {
      final mac6 = deviceId.substring(0, 6);
      final uploadKey = '${mac6}_recording_$timestamp.m4a';
      final keyBytes = uploadKey.codeUnits;
      if (keyBytes.length <= 255) {
        metaOut.add(keyBytes.length);
        metaOut.addAll(keyBytes);
      }
    }
    await File('$outputDir/recording_$timestamp.meta').writeAsBytes(metaOut);

    Logger.debug('ManualRecordingExtractor: saved recording_$timestamp.m4a (${durationMs}ms)');
    return m4aPath;
  }

  // ─── Phase 7: Compute lastSafeChunkIndex ────────────────────────────────────

  int _computeLastSafe(
      List<_ChunkMeta> chunks, List<_Window> mergedWindows, DateTime twoHrCutoff, bool forceFlush, DateTime newestEnd) {
    if (forceFlush) {
      // Keep last 60s of chunks
      final keepFrom = newestEnd.subtract(const Duration(seconds: 60));
      final boundary = _lastChunkEndBefore(chunks, keepFrom);
      return max(-1, boundary - _safetyMarginChunks);
    }

    final incompleteWindows = mergedWindows.where((w) => !w.isComplete).toList();
    final recoverableIncomplete = incompleteWindows.where((w) => w.startTime.isAfter(twoHrCutoff)).toList();

    if (recoverableIncomplete.isNotEmpty) {
      // Keep everything up to earliest recoverable incomplete window start
      DateTime earliest = recoverableIncomplete.first.startTime;
      for (final w in recoverableIncomplete) {
        if (w.startTime.isBefore(earliest)) earliest = w.startTime;
      }
      final boundary = _lastChunkEndBefore(chunks, earliest);
      return max(-1, boundary - _safetyMarginChunks);
    }

    // No incomplete windows — delete up to max(twoHrCutoff, lastCompleteWindowEnd)
    DateTime deleteBefore = twoHrCutoff;
    for (final w in mergedWindows) {
      if (w.isComplete) {
        final endTime = w.endChunkIdx < chunks.length
            ? chunks[w.endChunkIdx].startTime.add(Duration(milliseconds: w.endFrameIdx * _frameDurationMs))
            : twoHrCutoff;
        if (endTime.isAfter(deleteBefore)) deleteBefore = endTime;
      }
    }

    final boundary = _lastChunkEndBefore(chunks, deleteBefore);
    return max(-1, boundary - _safetyMarginChunks);
  }

  int _lastChunkEndBefore(List<_ChunkMeta> chunks, DateTime boundary) {
    int result = -1;
    for (int i = 0; i < chunks.length; i++) {
      if (!chunks[i].endTime.isAfter(boundary)) {
        result = i;
      }
    }
    return result;
  }

  int _cutoffIndex(List<_ChunkMeta> chunks, DateTime twoHrCutoff) {
    return max(-1, _lastChunkEndBefore(chunks, twoHrCutoff) - _safetyMarginChunks);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  int _findChunkForTime(List<_ChunkMeta> chunks, DateTime t) {
    if (chunks.isEmpty) return 0;
    int result = 0;
    for (int i = 0; i < chunks.length; i++) {
      if (!chunks[i].startTime.isAfter(t)) {
        result = i;
      } else {
        break;
      }
    }
    // Gap rule: if t is after result's endTime and before next chunk's startTime, return result
    final c = chunks[result];
    if (result + 1 < chunks.length) {
      final next = chunks[result + 1];
      if (!t.isBefore(c.endTime) && t.isBefore(next.startTime)) {
        return result; // in gap — return previous
      }
    }
    return result;
  }

  /// Returns (chunkIdx, frameIdx) for a global frame offset from (ci, fi).
  (int, int) _offsetFrame(List<_ChunkMeta> chunks, int ci, int fi, int delta) {
    var c = ci;
    var f = fi + delta;

    while (f < 0 && c > 0) {
      c--;
      f += chunks[c].frameCount;
    }
    while (c < chunks.length && f >= chunks[c].frameCount) {
      f -= chunks[c].frameCount;
      c++;
    }
    if (c >= chunks.length) return (-1, 0);
    if (f < 0) return (-1, 0);
    return (c, f);
  }

  /// Returns (chunkIdx, frameIdx) for an absolute global frame index.
  (int, int) _frameAt(List<_ChunkMeta> chunks, int globalFrame) {
    int remaining = globalFrame;
    for (int i = 0; i < chunks.length; i++) {
      if (remaining < chunks[i].frameCount) return (i, remaining);
      remaining -= chunks[i].frameCount;
    }
    // Clamp to last frame
    final last = chunks.length - 1;
    return (last, max(0, chunks[last].frameCount - 1));
  }
}

