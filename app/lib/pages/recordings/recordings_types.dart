enum RecordingFilterMode { visible, hidden, all }

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
