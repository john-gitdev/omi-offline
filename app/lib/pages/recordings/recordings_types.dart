enum RecordingFilterMode { visible, hidden, all }

/// Row kind a multi-select session is scoped to. Selection is always confined
/// to a single day *and* a single type, so a selection never mixes recordings
/// and discards — which keeps the action bar's available actions unambiguous.
enum RecordingRowType { recording, ghost }

enum SyncProcessState {
  idle,
  syncing,
  processing,
  stopping,
  resume,
  error,
  successUi,
}

/// Snapshot of sync/process progress passed into [SyncProcessCard].
class SyncCardData {
  final SyncProcessState state;
  final bool isForcePipeline;
  final int syncedCount;
  final int totalCount;
  final double syncSpeed;
  final double minutesRemaining;
  final double totalMinutes;
  final double processingProgress;
  final bool isTranscoding;
  final String audioSaveFormat;
  final String lastActiveStage;

  const SyncCardData({
    required this.state,
    required this.isForcePipeline,
    required this.syncedCount,
    required this.totalCount,
    required this.syncSpeed,
    required this.minutesRemaining,
    required this.totalMinutes,
    required this.processingProgress,
    required this.isTranscoding,
    required this.audioSaveFormat,
    required this.lastActiveStage,
  });
}
