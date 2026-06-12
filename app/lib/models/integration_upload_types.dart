import 'package:omi/models/recordings/recordings_models.dart';
import 'package:omi/pages/recordings/passthrough_integration.dart';

enum UploadStatus { none, partial, all, failed, unavailable }

/// Per-integration upload state for one recording, surfaced in the detail sheet.
enum IntegrationUploadState {
  /// Upload in flight right now.
  uploading,

  /// Confirmed delivered to this integration.
  delivered,

  /// Available but the last attempt failed — either a manual upload failed, or
  /// the auto-upload retry budget is exhausted.
  failed,

  /// Available, not delivered, no upload in flight — actionable.
  pending,

  /// Enqueued for upload, waiting its turn behind the single sequential worker.
  /// Not actionable — it's already on its way.
  queued,

  /// This integration cannot upload this recording at all (e.g. Omi with no
  /// processing-time .bin, or HeyPocket with the audio file gone).
  unavailable,
}

class IntegrationStatus {
  final String name;
  final IntegrationUploadState state;

  /// When [state] is `failed`, the time of the most recent failed attempt (for
  /// the "Last Upload Failed at" label). Null otherwise or if no time recorded.
  final DateTime? failedAt;

  /// For chunked integrations (Omi Cloud), how many segments have been delivered
  /// and the total — drives the "X/Total chunks" label so a partial/failed-midway
  /// upload shows its progress. Null for single-shot integrations or ≤1 chunk.
  final int? deliveredSegments;
  final int? totalSegments;

  const IntegrationStatus(this.name, this.state, {this.failedAt, this.deliveredSegments, this.totalSegments});

  bool get isActionable => state == IntegrationUploadState.pending || state == IntegrationUploadState.failed;
}

class UploadFailure {
  final String integration;
  final Object error;
  UploadFailure(this.integration, this.error);
}

/// One enqueued upload: a specific [conversation] to a specific [integration].
/// Drained one at a time within that integration's lane (the controller's
/// `_UploadLane`, via `RecordingsController._pumpLane`) so we never fan parallel
/// jobs at a server. [force] re-uploads an already-delivered recording; [manual]
/// jobs (explicit user taps) are drained ahead of auto-sweep jobs and ignore
/// server backoff.
class UploadJob {
  final PassthroughIntegration integration;
  final Conversation conversation;
  final bool force;
  final bool manual;
  UploadJob(this.integration, this.conversation, {this.force = false, this.manual = false});

  /// Matches the `_syncingKeys` registry so in-flight and queued jobs dedup
  /// against each other across every entry point.
  String get key => '${integration.name}_${conversation.file.path}';
}
