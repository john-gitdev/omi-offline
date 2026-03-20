import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/audio/aac_encoder.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:opus_dart/opus_dart.dart';

// ─── Private Data Structures ──────────────────────────────────────────────────

class _SegmentMeta {
  final File file;
  final int segmentIndex;
  final DateTime startTime;
  final int frameCount;
  final List<_MetaAnchor> metaAnchors;

  _SegmentMeta({
    required this.file,
    required this.segmentIndex,
    required this.startTime,
    required this.frameCount,
    required this.metaAnchors,
  });

  DateTime get endTime => startTime.add(Duration(milliseconds: frameCount * 20));
}

class _MetaAnchor {
  final int frameIndex;
  final int utcMs;
  _MetaAnchor(this.frameIndex, this.utcMs);
}

class _SegmentVad {
  final _SegmentMeta segment;
  final Uint8List speechFlags;
  final Int32List byteOffsets;
  final Int16List frameLengths;
  final Int64List frameTimesMs;

  _SegmentVad({
    required this.segment,
    required this.speechFlags,
    required this.byteOffsets,
    required this.frameLengths,
    required this.frameTimesMs,
  });

  int get approxBytes =>
      speechFlags.length + byteOffsets.lengthInBytes + frameLengths.lengthInBytes + frameTimesMs.lengthInBytes;
}

class _VadState {
  double noiseFloorDbfs = -50.0;
  int warmupFrames = 50;
}

class _Window {
  int startSegmentIdx;
  int startFrameIdx;
  int endSegmentIdx;
  int endFrameIdx;
  DateTime startTime;
  bool isComplete;
  final List<DateTime> markerTimes;

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

const int _sampleRate = 16000;
const int _channels = 1;
const int _frameDurationMs = 20;
const int _warmupFrames = 50;
const int _markerToleranceFrames = 250; // ±5s scan range for speech
const int _splitFrames = 100; // 2s silence to split
const int _maxWindowFrames = 15000; // 5 minute max window
const int _waveformBuckets = 200;
const int _bucketSize = 800; // samples per bucket
const int _safetyMarginSegments = 2;
const int _cacheMaxBytes = 5 * 1024 * 1024; // 5 MB

// ─── ManualRecordingExtractor ─────────────────────────────────────────────────

class ManualRecordingExtractor {
  final int _splitFrames;
  final double _snrMarginDb;
  final SimpleOpusDecoder? _providedDecoder;

  ManualRecordingExtractor({SimpleOpusDecoder? decoder})
      : _splitFrames = (SharedPreferencesUtil().offlineSplitSeconds * 1000) ~/ _frameDurationMs,
        _snrMarginDb = SharedPreferencesUtil().offlineSnrMarginDb,
        _providedDecoder = decoder;

  void destroy() {}

  /// Extracts conversation recordings from a [Batch] based on markers.
  ///
  /// Returns a record containing the list of saved M4A file paths and the index
  /// of the last raw segment that is safe to delete.
  Future<({List<String> savedPaths, int lastSafeSegmentIndex})> process(Batch batch, String tempOutputDir,
      {bool forceFlush = false}) async {
    final segments = await _buildSegmentMeta(batch);
    if (segments.isEmpty) return (savedPaths: <String>[], lastSafeSegmentIndex: -1);

    final newestEnd = segments.last.endTime;
    final twoHrCutoff = newestEnd.subtract(const Duration(hours: 2));

    // Fast path — no markers
    if (batch.markerTimestamps.isEmpty) {
      final lastSafe = _cutoffIndex(segments, twoHrCutoff);
      return (savedPaths: <String>[], lastSafeSegmentIndex: lastSafe);
    }

    // Full path — markers present
    final mergedRanges = _computeMergedRanges(batch.markerTimestamps, segments);
    final vadCache = await _runVadPass(segments, mergedRanges);

    final windows = _findWindows(batch.markerTimestamps, segments, vadCache);
    final merged = _mergeWindows(windows, segments);

    final savedPaths = <String>[];
    for (final w in merged) {
      final path = await _encodeWindow(w, segments, vadCache, tempOutputDir);
      if (path != null) savedPaths.add(path);
    }

    final lastSafe = _computeLastSafe(segments, merged, twoHrCutoff, forceFlush, newestEnd);
    return (savedPaths: savedPaths, lastSafeSegmentIndex: lastSafe);
  }

  // ─── Phase 1: Build segment metadata ─────────────────────────────────────────

  Future<List<_SegmentMeta>> _buildSegmentMeta(Batch batch) async {
    final segments = <_SegmentMeta>[];
    for (int i = 0; i < batch.rawSegments.length; i++) {
      final file = batch.rawSegments[i];
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) continue;

      final byteData = ByteData.sublistView(bytes);

      DateTime? startTime;
      int audioFrameCount = 0;
      final anchors = <_MetaAnchor>[];

      int off = 0;
      while (off + 4 <= bytes.length) {
        final len = byteData.getUint32(off, Endian.little);
        off += 4;
        if (off + len > bytes.length) break;

        if (len == 255) {
          // Metadata packet
          if (off + 16 <= bytes.length) {
            final utcSecs = byteData.getUint32(off, Endian.little);
            if (utcSecs > 0) {
              final utcMs = utcSecs * 1000;
              if (startTime == null && audioFrameCount == 0) {
                startTime = DateTime.fromMillisecondsSinceEpoch(utcMs);
              }
              anchors.add(_MetaAnchor(audioFrameCount, utcMs));
            }
          }
        } else {
          audioFrameCount++;
        }
        off += len;
      }

      if (startTime == null) {
        try {
          startTime = file.lastModifiedSync();
        } catch (_) {
          startTime = DateTime.now();
        }
      }

      // Ensure at least one anchor at frame 0
      if (anchors.isEmpty) {
        anchors.add(_MetaAnchor(0, startTime.millisecondsSinceEpoch));
      }

      segments.add(_SegmentMeta(
        file: file,
        segmentIndex: i,
        startTime: startTime,
        frameCount: audioFrameCount,
        metaAnchors: anchors,
      ));
    }
    return segments;
  }

  // ─── Phase 2: Compute VAD scan ranges ───────────────────────────────────────

  /// Returns list of `[startSegmentIdx, endSegmentIdx]` (inclusive, merged).
  List<(int, int)> _computeMergedRanges(List<DateTime> markers, List<_SegmentMeta> segments) {
    if (segments.isEmpty) return [];

    final raw = <(int, int)>[];
    for (final marker in markers) {
      final centerSegment = _findSegmentForTime(segments, marker);
      // Extend scan range back 2 hours and forward by maxWindowFrames * 20ms
      final backMs = 2 * 3600 * 1000;
      final fwdMs = _maxWindowFrames * _frameDurationMs;
      final rangeStart = marker.subtract(Duration(milliseconds: backMs));
      final rangeEnd = marker.add(Duration(milliseconds: fwdMs));
      final startSegment = max(0, _findSegmentForTime(segments, rangeStart));
      final endSegment = min(segments.length - 1, _findSegmentForTime(segments, rangeEnd));
      if (startSegment <= endSegment) {
        raw.add((startSegment, endSegment));
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

  Future<Map<int, _SegmentVad>> _runVadPass(List<_SegmentMeta> segments, List<(int, int)> ranges) async {
    final cache = <int, _SegmentVad>{};
    int cacheBytes = 0;

    for (final range in ranges) {
      final vadState = _VadState();

      // Compute warmup start
      var warmupSegment = range.$1;
      var warmupFrame = -_warmupFrames; // offset from firstFrameInSegment=0 of first range segment
      // Walk back until warmupFrame >= 0 or no more previous segments
      while (warmupFrame < 0 && warmupSegment > 0) {
        warmupSegment--;
        warmupFrame += segments[warmupSegment].frameCount;
      }
      if (warmupFrame < 0) warmupFrame = 0;

      // Determine contiguous segment range including warmup
      final decodeStart = warmupSegment;
      final decodeEnd = range.$2;

      for (int ci = decodeStart; ci <= decodeEnd; ci++) {
        final segment = segments[ci];
        if (segment.frameCount == 0) continue;

        final bytes = await segment.file.readAsBytes();
        final bd = ByteData.sublistView(bytes);

        final speechFlags = Uint8List(segment.frameCount);
        final byteOffsets = Int32List(segment.frameCount);
        final frameLengths = Int16List(segment.frameCount);
        final frameTimesMs = Int64List(segment.frameCount);

        // Compute per-frame timestamps using metaAnchors with monotonicity clamping
        int anchorIdx = 0;
        int prevMs = segment.metaAnchors.isNotEmpty ? segment.metaAnchors[0].utcMs : segment.startTime.millisecondsSinceEpoch;

        // Track which frames are within the actual scan range (not just warmup)
        final isWarmupSegment = ci < range.$1;
        final warmupFrameStart = (ci == warmupSegment) ? warmupFrame : 0;

        int off = 0;
        int audioIdx = 0;
        final decoder = _providedDecoder ??
            ((Platform.isIOS || Platform.isAndroid)
                ? SimpleOpusDecoder(sampleRate: _sampleRate, channels: _channels)
                : null);

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

            if (audioIdx >= segment.frameCount) break;

            // Advance anchor to the most recent one at or before audioIdx
            while (anchorIdx + 1 < segment.metaAnchors.length &&
                segment.metaAnchors[anchorIdx + 1].frameIndex <= audioIdx) {
              anchorIdx++;
            }
            final anchor = segment.metaAnchors[anchorIdx];
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

            // Warmup frames that land inside the first range segment (when warmupSegment == range.$1):
            // isWarmupSegment is false but these frames still need to warm up the noise floor
            // without having their (cold-VAD) speech flags stored.
            final isWarmupFrame = ci == range.$1 && audioIdx < warmupFrameStart;

            // Decode for VAD only if within warmup range or main range
            final skipVad = isWarmupSegment && audioIdx < warmupFrameStart;
            if (!skipVad && decoder != null) {
              if (audioIdx % 50 == 0) await Future.delayed(Duration.zero);
              try {
                final opus = Uint8List.sublistView(bytes, byteOff + 4, byteOff + 4 + len);
                final pcm = decoder.decode(input: opus);
                final flag = _vadStep(pcm, vadState);
                if (!isWarmupSegment && !isWarmupFrame) {
                  speechFlags[audioIdx] = flag ? 1 : 0;
                }
              } catch (_) {}
            }

            audioIdx++;
          }
        } finally {
          decoder?.destroy();
        }

        if (!isWarmupSegment) {
          final vad = _SegmentVad(
            segment: segment,
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
    double energy = 0;
    for (var s in pcm) {
      energy += s * s;
    }
    final rms = sqrt(energy / pcm.length);
    final dbfs = 20 * log(max(1.0, rms) / 32768.0) / ln10;

    if (state.warmupFrames > 0) {
      state.noiseFloorDbfs = min(state.noiseFloorDbfs, dbfs + 3);
      state.warmupFrames--;
    }

    final speech = dbfs > state.noiseFloorDbfs + _snrMarginDb;
    if (!speech) {
      if (dbfs > state.noiseFloorDbfs) {
        state.noiseFloorDbfs = 0.999 * state.noiseFloorDbfs + 0.001 * dbfs;
      } else {
        state.noiseFloorDbfs = 0.99 * state.noiseFloorDbfs + 0.01 * dbfs;
      }
    }
    return speech;
  }

  int _evictCache(Map<int, _SegmentVad> cache, int currentRangeStart) {
    int bytesFreed = 0;
    final keys = cache.keys.toList()..sort();
    for (final k in keys) {
      if (k < currentRangeStart - _safetyMarginSegments) {
        bytesFreed += cache[k]!.approxBytes;
        cache.remove(k);
      }
    }
    return bytesFreed;
  }

  // ─── Phase 4: Identify windows ───────────────────────────────────────────

  List<_Window> _findWindows(List<DateTime> markers, List<_SegmentMeta> segments, Map<int, _SegmentVad> vadCache) {
    final windows = <_Window>[];

    for (final marker in markers) {
      final (segmentIdx: ci, frameIdx: fi) = _locateMarker(segments, vadCache, marker);
      if (ci < 0 || ci >= segments.length) continue;

      // Skip if already covered by a complete window
      if (_coveredByComplete(windows, segments, ci, fi)) continue;

      // Find nearest speech frame, biased backward
      final (speechSegment: speechCi, speechFrame: speechFi) = _findNearestSpeech(segments, vadCache, ci, fi);

      if (speechCi < 0) {
        // No speech found within tolerance — skip this marker
        continue;
      }

      // Backward scan from speech frame for conversation start
      final (startSegmentIdx: startCi, startFrameIdx: startFi, hitBoundary: _) =
          _scanBackward(segments, vadCache, speechCi, speechFi);

      // Forward scan from marker frame for conversation end
      final (endSegmentIdx: endCi, endFrameIdx: endFi, isComplete: complete) =
          _scanForward(segments, vadCache, ci, fi);

      // Derive start time from frameTimesMs if available
      final startVad = vadCache[startCi];
      DateTime startTime;
      if (startVad != null && startFi < startVad.frameTimesMs.length) {
        startTime = DateTime.fromMillisecondsSinceEpoch(startVad.frameTimesMs[startFi]);
      } else {
        startTime = segments[startCi].startTime.add(Duration(milliseconds: startFi * _frameDurationMs));
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

  bool _coveredByComplete(List<_Window> windows, List<_SegmentMeta> segments, int ci, int fi) {
    for (final w in windows) {
      if (!w.isComplete) continue;
      if (_globalFrame(segments, ci, fi) >= _globalFrame(segments, w.startSegmentIdx, w.startFrameIdx) &&
          _globalFrame(segments, ci, fi) <= _globalFrame(segments, w.endSegmentIdx, w.endFrameIdx)) {
        return true;
      }
    }
    return false;
  }

  int _globalFrame(List<_SegmentMeta> segments, int ci, int fi) {
    int total = 0;
    for (int i = 0; i < ci && i < segments.length; i++) {
      total += segments[i].frameCount;
    }
    return total + fi;
  }

  ({int segmentIdx, int frameIdx}) _locateMarker(
      List<_SegmentMeta> segments, Map<int, _SegmentVad> vadCache, DateTime marker) {
    final ci = _findSegmentForTime(segments, marker);
    if (ci < 0 || ci >= segments.length) return (segmentIdx: -1, frameIdx: 0);

    final vad = vadCache[ci];
    if (vad == null || vad.frameTimesMs.isEmpty) {
      // Approximate
      final ms = marker.difference(segments[ci].startTime).inMilliseconds;
      final fi = (ms ~/ _frameDurationMs).clamp(0, max(0, segments[ci].frameCount - 1)).toInt();
      return (segmentIdx: ci, frameIdx: fi);
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
    return (segmentIdx: ci, frameIdx: lo);
  }

  /// Backward-biased: scan [markerFrame-250, markerFrame] first;
  /// extend forward only if nothing found behind.
  ({int speechSegment, int speechFrame}) _findNearestSpeech(
      List<_SegmentMeta> segments, Map<int, _SegmentVad> vadCache, int ci, int fi) {
    // Scan backward first
    for (int delta = 0; delta <= _markerToleranceFrames; delta++) {
      final (c, f) = _offsetFrame(segments, ci, fi, -delta);
      if (c < 0) break;
      final vad = vadCache[c];
      if (vad != null && f < vad.speechFlags.length && vad.speechFlags[f] == 1) {
        return (speechSegment: c, speechFrame: f);
      }
    }
    // Extend forward
    for (int delta = 1; delta <= _markerToleranceFrames; delta++) {
      final (c, f) = _offsetFrame(segments, ci, fi, delta);
      if (c < 0) break;
      final vad = vadCache[c];
      if (vad != null && f < vad.speechFlags.length && vad.speechFlags[f] == 1) {
        return (speechSegment: c, speechFrame: f);
      }
    }
    return (speechSegment: -1, speechFrame: 0);
  }

  /// Scan backward from (ci, fi) until [_splitFrames] consecutive silence or segment 0/frame 0.
  ({int startSegmentIdx, int startFrameIdx, bool hitBoundary}) _scanBackward(
      List<_SegmentMeta> segments, Map<int, _SegmentVad> vadCache, int ci, int fi) {
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
          final (bc, bf) = _offsetFrame(segments, scanCi, scanFi, consec);
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
        scanFi = max(0, segments[scanCi].frameCount - 1);
      } else {
        // Hit beginning of all available data
        return (startSegmentIdx: 0, startFrameIdx: 0, hitBoundary: false);
      }

      cur--;
      if (cur < -(segments.fold(0, (s, c) => s + c.frameCount))) break;
    }
    return (startSegmentIdx: 0, startFrameIdx: 0, hitBoundary: false);
  }

  /// Scan forward from (ci, fi) until [_splitFrames] consecutive silence or [_maxWindowFrames] total.
  ({int endSegmentIdx, int endFrameIdx, bool isComplete}) _scanForward(
      List<_SegmentMeta> segments, Map<int, _SegmentVad> vadCache, int ci, int fi) {
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
            // Silence block started in previous segment — backtrack
            final (bc, bf) = _offsetFrame(segments, scanCi, 0, endFi);
            return (endSegmentIdx: bc < 0 ? 0 : bc, endFrameIdx: bc < 0 ? 0 : bf, isComplete: true);
          }
        }
      } else {
        consec = 0;
      }

      totalFrames++;

      // Step forward
      if (scanFi + 1 < (vadCache[scanCi]?.speechFlags.length ?? segments[scanCi].frameCount)) {
        scanFi++;
      } else if (scanCi + 1 < segments.length) {
        scanCi++;
        scanFi = 0;
        // consec intentionally NOT reset — silence count carries across segment boundaries
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

  List<_Window> _mergeWindows(List<_Window> windows, List<_SegmentMeta> segments) {
    if (windows.isEmpty) return [];

    windows.sort((a, b) =>
        _globalFrame(segments, a.startSegmentIdx, a.startFrameIdx)
            .compareTo(_globalFrame(segments, b.startSegmentIdx, b.startFrameIdx)));

    final merged = <_Window>[];
    for (final w in windows) {
      if (merged.isEmpty) {
        merged.add(w);
        continue;
      }
      final last = merged.last;
      final lastEnd = _globalFrame(segments, last.endSegmentIdx, last.endFrameIdx);
      final wStart = _globalFrame(segments, w.startSegmentIdx, w.startFrameIdx);
      if (wStart <= lastEnd) {
        // Overlapping — extend last
        if (_globalFrame(segments, w.endSegmentIdx, w.endFrameIdx) > lastEnd) {
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
          _globalFrame(segments, w.endSegmentIdx, w.endFrameIdx) - _globalFrame(segments, w.startSegmentIdx, w.startFrameIdx);
      if (windowFrames > _maxWindowFrames) {
        final medianMarker = _medianMarker(w.markerTimes);
        final markerLoc = _locateMarker(segments, {}, medianMarker);
        final medianGlobal = _globalFrame(segments, markerLoc.segmentIdx, markerLoc.frameIdx);
        final startGlobal = _globalFrame(segments, w.startSegmentIdx, w.startFrameIdx);
        final endGlobal = _globalFrame(segments, w.endSegmentIdx, w.endFrameIdx);
        final midPoint = (startGlobal + endGlobal) ~/ 2;
        if (medianGlobal <= midPoint) {
          // Median is in first half — trim from end
          final newEnd = startGlobal + _maxWindowFrames;
          final (nc, nf) = _frameAt(segments, newEnd);
          w.endSegmentIdx = nc;
          w.endFrameIdx = nf;
        } else {
          // Median is in second half — trim from start
          final newStart = endGlobal - _maxWindowFrames;
          final (nc, nf) = _frameAt(segments, max(0, newStart));
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
      _Window w, List<_SegmentMeta> segments, Map<int, _SegmentVad> vadCache, String outputDir) async {
    final startVad = vadCache[w.startSegmentIdx];
    final timestamp = startVad != null && w.startFrameIdx < startVad.frameTimesMs.length
        ? startVad.frameTimesMs[w.startFrameIdx]
        : w.startTime.millisecondsSinceEpoch;

    final m4aPath = '$outputDir/recording_$timestamp.m4a';
    final decoder = _providedDecoder ??
        ((Platform.isIOS || Platform.isAndroid)
            ? SimpleOpusDecoder(sampleRate: _sampleRate, channels: _channels)
            : null);
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

          final refFile = segments[ci].file;
          if (refFile.path != currentFilePath) {
            await currentRaf?.close();
            currentRaf = await refFile.open(mode: FileMode.read);
            currentFilePath = refFile.path;
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
      List<_SegmentMeta> segments, List<_Window> mergedWindows, DateTime twoHrCutoff, bool forceFlush, DateTime newestEnd) {
    if (forceFlush) {
      // Keep last 60s of segments
      final keepFrom = newestEnd.subtract(const Duration(seconds: 60));
      final boundary = _lastSegmentEndBefore(segments, keepFrom);
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
      final boundary = _lastSegmentEndBefore(segments, earliest);
      return max(-1, boundary - _safetyMarginSegments);
    }

    // No incomplete windows — delete up to max(twoHrCutoff, lastCompleteWindowEnd)
    DateTime deleteBefore = twoHrCutoff;
    for (final w in mergedWindows) {
      if (w.isComplete) {
        final endTime = w.endSegmentIdx < segments.length
            ? segments[w.endSegmentIdx].startTime.add(Duration(milliseconds: w.endFrameIdx * _frameDurationMs))
            : twoHrCutoff;
        if (endTime.isAfter(deleteBefore)) deleteBefore = endTime;
      }
    }

    final boundary = _lastSegmentEndBefore(segments, deleteBefore);
    return max(-1, boundary - _safetyMarginSegments);
  }

  int _lastSegmentEndBefore(List<_SegmentMeta> segments, DateTime boundary) {
    int result = -1;
    for (int i = 0; i < segments.length; i++) {
      if (!segments[i].endTime.isAfter(boundary)) {
        result = i;
      }
    }
    return result;
  }

  int _cutoffIndex(List<_SegmentMeta> segments, DateTime twoHrCutoff) {
    return max(-1, _lastSegmentEndBefore(segments, twoHrCutoff) - _safetyMarginSegments);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  int _findSegmentForTime(List<_SegmentMeta> segments, DateTime t) {
    if (segments.isEmpty) return 0;
    int result = 0;
    for (int i = 0; i < segments.length; i++) {
      if (!segments[i].startTime.isAfter(t)) {
        result = i;
      } else {
        break;
      }
    }
    // Gap rule: if t is after result's endTime and before next segment's startTime, return result
    final c = segments[result];
    if (result + 1 < segments.length) {
      final next = segments[result + 1];
      if (!t.isBefore(c.endTime) && t.isBefore(next.startTime)) {
        return result; // in gap — return previous
      }
    }
    return result;
  }

  /// Returns (segmentIdx, frameIdx) for a global frame offset from (ci, fi).
  (int, int) _offsetFrame(List<_SegmentMeta> segments, int ci, int fi, int delta) {
    var c = ci;
    var f = fi + delta;

    while (f < 0 && c > 0) {
      c--;
      f += segments[c].frameCount;
    }
    while (c < segments.length && f >= segments[c].frameCount) {
      f -= segments[c].frameCount;
      c++;
    }
    if (c >= segments.length) return (-1, 0);
    if (f < 0) return (-1, 0);
    return (c, f);
  }

  /// Returns (segmentIdx, frameIdx) for an absolute global frame index.
  (int, int) _frameAt(List<_SegmentMeta> segments, int globalFrame) {
    int remaining = globalFrame;
    for (int i = 0; i < segments.length; i++) {
      if (remaining < segments[i].frameCount) return (i, remaining);
      remaining -= segments[i].frameCount;
    }
    // Clamp to last frame
    final last = segments.length - 1;
    return (last, max(0, segments[last].frameCount - 1));
  }
}
