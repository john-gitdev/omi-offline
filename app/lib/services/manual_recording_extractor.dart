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

class _SegmentMeta {
  final File file;
  final int segmentIndex; // index in batch.rawSegments
  final DateTime startTime;
  final int frameCount; // audio frames only (not metadata packets)
  final List<_MetaAnchor> metaAnchors;

  const _SegmentMeta({
    required this.file,
    required this.segmentIndex,
    required this.startTime,
    required this.frameCount,
    required this.metaAnchors,
  });

  DateTime get endTime => startTime.add(Duration(milliseconds: frameCount * 20));
}

class _SegmentVad {
  final _SegmentMeta segment;
  final Uint8List speechFlags; // 1=speech, 0=silence, one per audio frame
  final Int32List byteOffsets; // byte offset of each frame's 4-byte length prefix
  final Int16List frameLengths; // Opus payload length per frame
  final Int64List frameTimesMs; // epoch-ms per frame, monotonic

  const _SegmentVad({
    required this.segment,
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
  int startSegmentIdx;
  int startFrameIdx;
  int endSegmentIdx;
  int endFrameIdx;
  DateTime startTime;
  bool isComplete;
  List<DateTime> markerTimes;

  _Window({
    required this.startSegmentIdx,
    required this.startFrameIdx,
    required this.endSegmentIdx,
    required this.endFrameIdx,
    required this.startTime,
    required this.isComplete,
    required this.markerTimes,
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
const int _markerToleranceFrames = 250; // ±5 seconds
const int _maxWindowFrames = 2 * 3600 * 1000 ~/ _frameDurationMs; // 2hr cap
const int _safetyMarginSegments = 2;
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

  Future<({List<String> savedPaths, int lastSafeSegmentIndex})> process(
    DailyBatch batch,
    String tempOutputDir, {
    bool forceFlush = false,
  }) async {
    if (batch.rawSegments.isEmpty) {
      return (savedPaths: <String>[], lastSafeSegmentIndex: -1);
    }

    final chunks = await _buildSegmentMeta(batch);
    if (chunks.isEmpty) return (savedPaths: <String>[], lastSafeSegmentIndex: -1);

    final newestEnd = chunks.last.endTime;
    final twoHrCutoff = newestEnd.subtract(const Duration(hours: 2));

    // Fast path — no markers
    if (batch.markerTimestamps.isEmpty) {
      final lastSafe = _cutoffIndex(chunks, twoHrCutoff);
      return (savedPaths: <String>[], lastSafeSegmentIndex: lastSafe);
    }

    // Full path — markers present
    final mergedRanges = _computeMergedRanges(batch.markerTimestamps, chunks);
    final vadCache = await _runVadPass(chunks, mergedRanges);

    final windows = _findWindows(batch.markerTimestamps, chunks, vadCache);
    final merged = _mergeWindows(windows, chunks);

    final savedPaths = <String>[];
    for (final w in merged) {
      final path = await _encodeWindow(w, chunks, vadCache, tempOutputDir);
      if (path != null) savedPaths.add(path);
    }

    final lastSafe = _computeLastSafe(chunks, merged, twoHrCutoff, forceFlush, newestEnd);
    return (savedPaths: savedPaths, lastSafeSegmentIndex: lastSafe);
  }

  // ─── Phase 1: Build chunk metadata ─────────────────────────────────────────

  Future<List<_SegmentMeta>> _buildSegmentMeta(DailyBatch batch) async {
    final result = <_SegmentMeta>[];
    for (int i = 0; i < batch.rawSegments.length; i++) {
      final file = batch.rawSegments[i];
      final meta = await _parseSingleSegmentMeta(file, i);
      result.add(meta);
    }
    return result;
  }

  Future<_SegmentMeta> _parseSingleSegmentMeta(File file, int segmentIndex) async {
    // Resolve startTime from SharedPreferences anchors
    final deviceSessionIdStr = file.parent.path.split('/').last;
    final int? deviceSessionId = int.tryParse(deviceSessionIdStr);
    final segmentFileName = file.path.split('/').last.replaceAll('.bin', '');
    final segmentIdxStr = segmentFileName.contains('_') ? segmentFileName.split('_').last : null;
    final segmentPrefsIdx = segmentIdxStr != null ? int.tryParse(segmentIdxStr) : null;

    DateTime startTime;
    if (deviceSessionId != null && segmentPrefsIdx != null) {
      final anchorUtc = SharedPreferencesUtil()
          .getInt('anchor_utc_device_session_${deviceSessionId}_$segmentPrefsIdx', defaultValue: 0);
      final anchorUptime = SharedPreferencesUtil()
          .getInt('anchor_uptime_device_session_${deviceSessionId}_$segmentPrefsIdx', defaultValue: 0);
      if (anchorUtc > 0) {
        startTime = DateTime.fromMillisecondsSinceEpoch(anchorUtc * 1000);
      } else if (anchorUptime > 0) {
        final sessionAnchorUtc =
            SharedPreferencesUtil().getInt('anchor_utc_device_session_$deviceSessionId', defaultValue: 0);
        final sessionAnchorUptime =
            SharedPreferencesUtil().getInt('anchor_uptime_device_session_$deviceSessionId', defaultValue: 0);
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
      return _SegmentMeta(file: file, segmentIndex: segmentIndex, startTime: startTime, frameCount: 0, metaAnchors: []);
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
          } else if (deviceSessionId != null) {
            // Fall back to uptime-relative computation
            final uptimeMs = bd.getUint32(off + 8, Endian.little);
            final sessAnchorUtc =
                SharedPreferencesUtil().getInt('anchor_utc_device_session_$deviceSessionId', defaultValue: 0);
            final sessAnchorUptime =
                SharedPreferencesUtil().getInt('anchor_uptime_device_session_$deviceSessionId', defaultValue: 0);
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

    return _SegmentMeta(
      file: file,
      segmentIndex: segmentIndex,
      startTime: startTime,
      frameCount: audioFrameCount,
      metaAnchors: anchors,
    );
  }

  // ─── Phase 2: Compute merged scan ranges ───────────────────────────────────

  /// Returns list of `[startSegmentIdx, endSegmentIdx]` (inclusive, merged).
  List<(int, int)> _computeMergedRanges(List<DateTime> markers, List<_SegmentMeta> chunks) {
    if (chunks.isEmpty) return [];

    final raw = <(int, int)>[];
    for (final marker in markers) {
      final centerSegment = _findSegmentForTime(chunks, marker);
      // Extend scan range back 2 hours and forward by maxWindowFrames * 20ms
      final backMs = 2 * 3600 * 1000;
      final fwdMs = _maxWindowFrames * _frameDurationMs;
      final rangeStart = marker.subtract(Duration(milliseconds: backMs));
      final rangeEnd = marker.add(Duration(milliseconds: fwdMs));
      final startChunk = max(0, _findSegmentForTime(chunks, rangeStart));
      final endChunk = min(chunks.length - 1, _findSegmentForTime(chunks, rangeEnd));
      if (startChunk <= endChunk) {
        raw.add((startChunk, endChunk));
      } else {
        raw.add((centerSegment, centerSegment));
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

  Future<Map<int, _SegmentVad>> _runVadPass(List<_SegmentMeta> chunks, List<(int, int)> ranges) async {
    final cache = <int, _SegmentVad>{};
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
              continue; // metadata already processed in _buildSegmentMeta
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

            // Warmup frames that land inside the first range chunk (when warmupChunk == range.$1):
            // isWarmupChunk is false but these frames still need to warm up the noise floor
            // without having their (cold-VAD) speech flags stored.
            final isWarmupFrame = ci == range.$1 && audioIdx < warmupFrameStart;

            // Decode for VAD only if within warmup range or main range
            final skipVad = isWarmupChunk && audioIdx < warmupFrameStart;
            if (!skipVad && decoder != null) {
              if (audioIdx % 50 == 0) await Future.delayed(Duration.zero);
              try {
                final opus = Uint8List.sublistView(bytes, byteOff + 4, byteOff + 4 + len);
                final pcm = decoder.decode(input: opus);
                final flag = _vadStep(pcm, vadState);
                if (!isWarmupChunk && !isWarmupFrame) {
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
          final vad = _SegmentVad(
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
            cacheBytes -= _evictCache(cache, range.$1);
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

  int _evictCache(Map<int, _SegmentVad> cache, int activeRangeStart) {
    int freed = 0;
    final toEvict = cache.keys.where((k) => k < activeRangeStart).toList();
    for (final k in toEvict) {
      freed += cache[k]!.approxBytes;
      cache.remove(k);
    }
    return freed;
  }

  // ─── Phase 4: Find windows per marker ──────────────────────────────────────

  List<_Window> _findWindows(List<DateTime> markers, List<_SegmentMeta> chunks, Map<int, _SegmentVad> vadCache) {
    final windows = <_Window>[];

    for (final marker in markers) {
      final (chunkIdx: ci, frameIdx: fi) = _locateMarker(chunks, vadCache, marker);
      if (ci < 0 || ci >= chunks.length) continue;

      // Skip if already covered by a complete window
      if (_coveredByComplete(windows, chunks, ci, fi)) continue;

      // Find nearest speech frame, biased backward
      final (speechChunk: speechCi, speechFrame: speechFi) = _findNearestSpeech(chunks, vadCache, ci, fi);

      if (speechCi < 0) {
        // No speech found within tolerance — skip this marker
        continue;
      }

      // Backward scan from speech frame for conversation start
      final (startSegmentIdx: startCi, startFrameIdx: startFi, hitBoundary: _) =
          _scanBackward(chunks, vadCache, speechCi, speechFi);

      // Forward scan from marker frame for conversation end
      final (endSegmentIdx: endCi, endFrameIdx: endFi, isComplete: complete) =
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
        startSegmentIdx: startCi,
        startFrameIdx: startFi,
        endSegmentIdx: endCi,
        endFrameIdx: endFi,
        startTime: startTime,
        isComplete: complete,
        markerTimes: [marker],
      ));
    }

    return windows;
  }

  bool _coveredByComplete(List<_Window> windows, List<_SegmentMeta> chunks, int ci, int fi) {
    for (final w in windows) {
      if (!w.isComplete) continue;
      if (_globalFrame(chunks, ci, fi) >= _globalFrame(chunks, w.startSegmentIdx, w.startFrameIdx) &&
          _globalFrame(chunks, ci, fi) <= _globalFrame(chunks, w.endSegmentIdx, w.endFrameIdx)) {
        return true;
      }
    }
    return false;
  }

  int _globalFrame(List<_SegmentMeta> chunks, int ci, int fi) {
    int total = 0;
    for (int i = 0; i < ci && i < chunks.length; i++) {
      total += chunks[i].frameCount;
    }
    return total + fi;
  }

  ({int chunkIdx, int frameIdx}) _locateMarker(
      List<_SegmentMeta> chunks, Map<int, _SegmentVad> vadCache, DateTime marker) {
    final ci = _findSegmentForTime(chunks, marker);
    if (ci < 0 || ci >= chunks.length) return (chunkIdx: -1, frameIdx: 0);

    final vad = vadCache[ci];
    if (vad == null || vad.frameTimesMs.isEmpty) {
      // Approximate
      final ms = marker.difference(chunks[ci].startTime).inMilliseconds;
      final fi = (ms ~/ _frameDurationMs).clamp(0, max(0, chunks[ci].frameCount - 1)).toInt();
      return (chunkIdx: ci, frameIdx: fi);
    }

    // Binary search in frameTimesMs
    final tMs = marker.millisecondsSinceEpoch;
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
      List<_SegmentMeta> chunks, Map<int, _SegmentVad> vadCache, int ci, int fi) {
    // Scan backward first
    for (int delta = 0; delta <= _markerToleranceFrames; delta++) {
      final (c, f) = _offsetFrame(chunks, ci, fi, -delta);
      if (c < 0) break;
      final vad = vadCache[c];
      if (vad != null && f < vad.speechFlags.length && vad.speechFlags[f] == 1) {
        return (speechChunk: c, speechFrame: f);
      }
    }
    // Extend forward
    for (int delta = 1; delta <= _markerToleranceFrames; delta++) {
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
  ({int startSegmentIdx, int startFrameIdx, bool hitBoundary}) _scanBackward(
      List<_SegmentMeta> chunks, Map<int, _SegmentVad> vadCache, int ci, int fi) {
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
          return (startSegmentIdx: bc < 0 ? 0 : bc, startFrameIdx: bc < 0 ? 0 : bf, hitBoundary: true);
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
        return (startSegmentIdx: 0, startFrameIdx: 0, hitBoundary: false);
      }

      cur--;
      if (cur < -(chunks.fold(0, (s, c) => s + c.frameCount))) break;
    }
    return (startSegmentIdx: 0, startFrameIdx: 0, hitBoundary: false);
  }

  /// Scan forward from (ci, fi) until [_splitFrames] consecutive silence or [_maxWindowFrames] total.
  ({int endSegmentIdx, int endFrameIdx, bool isComplete}) _scanForward(
      List<_SegmentMeta> chunks, Map<int, _SegmentVad> vadCache, int ci, int fi) {
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
            return (endSegmentIdx: scanCi, endFrameIdx: endFi, isComplete: true);
          } else {
            // Silence block started in previous chunk — backtrack
            final (bc, bf) = _offsetFrame(chunks, scanCi, 0, endFi);
            return (endSegmentIdx: bc < 0 ? 0 : bc, endFrameIdx: bc < 0 ? 0 : bf, isComplete: true);
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
        return (endSegmentIdx: scanCi, endFrameIdx: scanFi, isComplete: false);
      }
    }

    // Hit maxWindowFrames cap
    Logger.debug('ManualRecordingExtractor: window truncated at maxWindowFrames cap');
    return (endSegmentIdx: scanCi, endFrameIdx: scanFi, isComplete: false);
  }

  // ─── Phase 5: Merge overlapping windows ────────────────────────────────────

  List<_Window> _mergeWindows(List<_Window> windows, List<_SegmentMeta> chunks) {
    if (windows.isEmpty) return [];

    windows.sort((a, b) =>
        _globalFrame(chunks, a.startSegmentIdx, a.startFrameIdx)
            .compareTo(_globalFrame(chunks, b.startSegmentIdx, b.startFrameIdx)));

    final merged = <_Window>[];
    for (final w in windows) {
      if (merged.isEmpty) {
        merged.add(w);
        continue;
      }
      final last = merged.last;
      final lastEnd = _globalFrame(chunks, last.endSegmentIdx, last.endFrameIdx);
      final wStart = _globalFrame(chunks, w.startSegmentIdx, w.startFrameIdx);
      if (wStart <= lastEnd) {
        // Overlapping — extend last
        if (_globalFrame(chunks, w.endSegmentIdx, w.endFrameIdx) > lastEnd) {
          last.endSegmentIdx = w.endSegmentIdx;
          last.endFrameIdx = w.endFrameIdx;
          last.isComplete = last.isComplete || w.isComplete;
        }
        last.markerTimes.addAll(w.markerTimes);
      } else {
        merged.add(w);
      }
    }

    // Re-apply maxWindowFrames cap per merged window using median marker
    for (final w in merged) {
      final windowFrames =
          _globalFrame(chunks, w.endSegmentIdx, w.endFrameIdx) - _globalFrame(chunks, w.startSegmentIdx, w.startFrameIdx);
      if (windowFrames > _maxWindowFrames) {
        final medianMarker = _medianMarker(w.markerTimes);
        final markerLoc = _locateMarker(chunks, {}, medianMarker);
        final medianGlobal = _globalFrame(chunks, markerLoc.chunkIdx, markerLoc.frameIdx);
        final startGlobal = _globalFrame(chunks, w.startSegmentIdx, w.startFrameIdx);
        final endGlobal = _globalFrame(chunks, w.endSegmentIdx, w.endFrameIdx);
        final midPoint = (startGlobal + endGlobal) ~/ 2;
        if (medianGlobal <= midPoint) {
          // Median is in first half — trim from end
          final newEnd = startGlobal + _maxWindowFrames;
          final (nc, nf) = _frameAt(chunks, newEnd);
          w.endSegmentIdx = nc;
          w.endFrameIdx = nf;
        } else {
          // Median is in second half — trim from start
          final newStart = endGlobal - _maxWindowFrames;
          final (nc, nf) = _frameAt(chunks, max(0, newStart));
          w.startSegmentIdx = nc;
          w.startFrameIdx = nf;
        }
      }
    }

    return merged;
  }

  DateTime _medianMarker(List<DateTime> markers) {
    if (markers.isEmpty) return DateTime.now();
    final sorted = List<DateTime>.from(markers)..sort();
    return sorted[sorted.length ~/ 2];
  }

  // ─── Phase 6: Encode window ─────────────────────────────────────────────────

  Future<String?> _encodeWindow(
      _Window w, List<_SegmentMeta> chunks, Map<int, _SegmentVad> vadCache, String outputDir) async {
    final startVad = vadCache[w.startSegmentIdx];
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
      for (int ci = w.startSegmentIdx; ci <= w.endSegmentIdx; ci++) {
        final vad = vadCache[ci];
        if (vad == null) continue;

        final frameStart = ci == w.startSegmentIdx ? w.startFrameIdx : 0;
        final frameEnd = ci == w.endSegmentIdx ? w.endFrameIdx : vad.speechFlags.length - 1;

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

  // ─── Phase 7: Compute lastSafeSegmentIndex ────────────────────────────────────

  int _computeLastSafe(
      List<_SegmentMeta> chunks, List<_Window> mergedWindows, DateTime twoHrCutoff, bool forceFlush, DateTime newestEnd) {
    if (forceFlush) {
      // Keep last 60s of chunks
      final keepFrom = newestEnd.subtract(const Duration(seconds: 60));
      final boundary = _lastSegmentEndBefore(chunks, keepFrom);
      return max(-1, boundary - _safetyMarginSegments);
    }

    final incompleteWindows = mergedWindows.where((w) => !w.isComplete).toList();
    final recoverableIncomplete = incompleteWindows.where((w) => w.startTime.isAfter(twoHrCutoff)).toList();

    if (recoverableIncomplete.isNotEmpty) {
      // Keep everything up to earliest recoverable incomplete window start
      DateTime earliest = recoverableIncomplete.first.startTime;
      for (final w in recoverableIncomplete) {
        if (w.startTime.isBefore(earliest)) earliest = w.startTime;
      }
      final boundary = _lastSegmentEndBefore(chunks, earliest);
      return max(-1, boundary - _safetyMarginSegments);
    }

    // No incomplete windows — delete up to max(twoHrCutoff, lastCompleteWindowEnd)
    DateTime deleteBefore = twoHrCutoff;
    for (final w in mergedWindows) {
      if (w.isComplete) {
        final endTime = w.endSegmentIdx < chunks.length
            ? chunks[w.endSegmentIdx].startTime.add(Duration(milliseconds: w.endFrameIdx * _frameDurationMs))
            : twoHrCutoff;
        if (endTime.isAfter(deleteBefore)) deleteBefore = endTime;
      }
    }

    final boundary = _lastSegmentEndBefore(chunks, deleteBefore);
    return max(-1, boundary - _safetyMarginSegments);
  }

  int _lastSegmentEndBefore(List<_SegmentMeta> chunks, DateTime boundary) {
    int result = -1;
    for (int i = 0; i < chunks.length; i++) {
      if (!chunks[i].endTime.isAfter(boundary)) {
        result = i;
      }
    }
    return result;
  }

  int _cutoffIndex(List<_SegmentMeta> chunks, DateTime twoHrCutoff) {
    return max(-1, _lastSegmentEndBefore(chunks, twoHrCutoff) - _safetyMarginSegments);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  int _findSegmentForTime(List<_SegmentMeta> chunks, DateTime t) {
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
  (int, int) _offsetFrame(List<_SegmentMeta> chunks, int ci, int fi, int delta) {
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
  (int, int) _frameAt(List<_SegmentMeta> chunks, int globalFrame) {
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

