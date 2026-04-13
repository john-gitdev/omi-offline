1. **In `_IsolateParams` (`app/lib/services/recordings_manager.dart`)**
   - Add `final List<int> segmentFileSizes;` to pass the sizes of the segments to the isolate.

2. **In `_processingIsolateEntry` (`app/lib/services/recordings_manager.dart`)**
   - Accept `segmentFileSizes` in the parameter object.
   - Send `segmentFileSizes[i]` back to the main isolate via the `params.sendPort.send({'type': 'progress', ...})` message, or just send the bytes per segment instead of sending an arbitrary completion percentage.
   - Better yet: Send back the number of processed bytes instead of just the percentage, e.g., `params.sendPort.send({'type': 'progress', 'processed_bytes': params.segmentFileSizes[i]})`. Note that we are accumulating processed bytes in the main thread to avoid resetting state.

3. **In `RecordingsManager.processAll` (`app/lib/services/recordings_manager.dart`)**
   - Compute `rawTotalBytes` as the sum of `segmentFileSizes`. This is actually already being computed for the disk space guard:
     ```dart
     final rawTotalBytes = allRawFiles.fold<int>(0, (sum, f) { ... });
     ```
   - Make sure to pass `segmentFileSizes` to `_IsolateParams`.
   - Before spawning the isolate, record `final startTime = DateTime.now();`.
   - Also set `int processedBytes = 0;`.
   - Update the signature of `onProgress` or add `onEtaUpdate(Duration)`:
     ```dart
     Future<void> processAll(List<Batch> batches, Function(double progress, Duration? eta) onProgress, ...)
     ```
   - In the `progress` message handler:
     ```dart
     case 'progress':
       final segmentBytes = msg['processed_bytes'] as int;
       processedBytes += segmentBytes;
       double progress = processedBytes / rawTotalBytes;
       Duration? eta;
       if (progress >= 0.05) { // >= 5% done
         final elapsed = DateTime.now().difference(startTime);
         final remainingBytes = rawTotalBytes - processedBytes;
         final etaMs = (elapsed.inMilliseconds * remainingBytes) ~/ processedBytes;
         eta = Duration(milliseconds: etaMs);
       }
       onProgress(progress, eta);
     ```

4. **In `RecordingsController` (`app/lib/pages/recordings/recordings_controller.dart`)**
   - Remove `_totalMinutes` computation that acts as proxy for ETA (e.g. `totalMin = totalBytes / 252000.0`).
   - Remove `_minutesRemaining` since we can just track `Duration? _processingEta` directly. Or we can keep `_minutesRemaining` but update it from the new ETA duration! The task says `Update the processing banner widget to display "~X min remaining" using the ETA`.
   - Let's replace `_minutesRemaining` with `int? _etaMinutes` or keep `double _minutesRemaining` but computed accurately from the new `Duration? eta`.
   - Update all callers of `processAll` to accept `(progress, eta)` and update the `_minutesRemaining` (or similar state).

5. **In `SyncProcessCard` (`app/lib/pages/recordings/sync_process_card.dart`)**
   - In `SyncProcessState.processing`, update `subText` to display:
     ```dart
     subText = data.minutesRemaining != null && data.minutesRemaining > 0
         ? '~${data.minutesRemaining.ceil()} min remaining'
         : 'Calculating ETA…';
     ```
     Wait, the issue says "~X min remaining", "Suppress display until >= 5% processed". So if it's less than 5%, we could show a fallback message or just not show the min remaining.

6. **Complete pre-commit steps to ensure proper testing, verification, review, and reflection are done.**

7. **Submit the changes.**
